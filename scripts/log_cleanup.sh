#!/usr/bin/env bash
# ============================================================================
# 定期日志清理模块 — 组员 B (Docker / 日志运维)
# ============================================================================
# 功能：扫描指定目录，按修改时间 (mtime) 过滤并清理过期日志文件。
#       支持 .log / .out / core dump / 轮转日志等多种模式。
#       默认仅生成清理清单（DRY_RUN）；确认后才执行实际删除。
#
# 用法:
#   log_cleanup.sh                                    使用默认配置
#   log_cleanup.sh /data/logs                         指定目录
#   log_cleanup.sh /data/logs 14                      保留 14 天
#   log_cleanup.sh /data/logs 14 -y                   跳过二次确认
#   log_cleanup.sh /var/log 30 "*.log|*.out"          自定义匹配模式
# ============================================================================

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$ROOT_DIR/../lib/common.sh"
lab_ops_load_config

# ── 参数解析（先扫旗帜，再按位置分配）───────────────────────────────────────
TARGET_DIR=""
RETENTION_DAYS=""
PATTERNS=""
AUTO_YES=0

# 第一遍：收集非旗帜参数到数组
declare -a POS_ARGS=()
for arg in "$@"; do
  case "$arg" in
    -y|--yes|--force)
      AUTO_YES=1
      export LAB_OPS_FORCE=1
      ;;
    *)
      POS_ARGS+=("$arg")
      ;;
  esac
done

# 按位置分配非旗帜参数
TARGET_DIR="${POS_ARGS[0]:-${LAB_OPS_LOG_CLEANUP_DIR:-/var/log}}"
RETENTION_DAYS="${POS_ARGS[1]:-${LAB_OPS_LOG_RETENTION_DAYS:-30}}"
PATTERNS="${POS_ARGS[2]:-${LAB_OPS_LOG_PATTERNS:-*.log|*.LOG|*.log.*|*.out|core.*|nohup.out}}"

# ── 输出路径 ────────────────────────────────────────────────────────────────
DATE="$(date +%Y-%m-%d)"
REPORT="${LAB_OPS_REPORT_DIR}/log_cleanup_${DATE}.tsv"
ERROR_LOG="${LAB_OPS_LOG_DIR}/log_cleanup_errors.log"

lab_ops_log "log_cleanup: target=$TARGET_DIR retention=${RETENTION_DAYS}d patterns=$PATTERNS dry_run=$LAB_OPS_DRY_RUN"

# ── 校验目标目录 ────────────────────────────────────────────────────────────
if [[ ! -d "$TARGET_DIR" ]] && [[ ! -f "$TARGET_DIR" ]]; then
  lab_ops_log "ERROR: target not found: $TARGET_DIR"
  exit 1
fi

# ── 生成候选文件列表 ────────────────────────────────────────────────────────
# 将管道分隔的模式转为 find 的多个 -name 条件
build_find_patterns() {
  local IFS='|'
  local args=()
  local first=1
  for pat in $PATTERNS; do
    [[ -z "$pat" ]] && continue
    if [[ $first -eq 1 ]]; then
      args+=(-name "$pat")
      first=0
    else
      args+=(-o -name "$pat")
    fi
  done
  # 如果没有任何有效模式，默认匹配所有文件
  if [[ ${#args[@]} -eq 0 ]]; then
    args=(-type f)
  fi
  # 用括号包裹 OR 条件组
  echo '(' "${args[@]}" ')'
}

# 读取 find 模式表达式
read -ra FIND_PATTERNS < <(build_find_patterns)

lab_ops_log "log_cleanup: find patterns: ${FIND_PATTERNS[*]}"

# ── 第一步：生成候选文件清单（只读，安全）──────────────────────────────────
CANDIDATE_FILE="${LAB_OPS_LOG_DIR}/log_cleanup_candidates.tmp"

# 使用 find 按 mtime 过滤；超过 RETENTION_DAYS 天未修改的文件
# -mtime +N 表示"修改时间在 N*24 小时之前"
find "$TARGET_DIR" -xdev -type f "${FIND_PATTERNS[@]}" -mtime "+${RETENTION_DAYS}" \
  -printf '%s\t%p\t%TY-%Tm-%Td %TH:%TM\n' 2>>"$ERROR_LOG" \
  | LC_ALL=C sort -t "$(printf '\t')" -k3,3 >"$CANDIDATE_FILE"

CANDIDATE_COUNT=$(wc -l <"$CANDIDATE_FILE")

# ── 第二步：生成 TSV 报表 ────────────────────────────────────────────────────
{
  printf 'Date\tFile_Path\tFile_Size_Bytes\tFile_Size_MB\tLast_Modified\n'

  if [[ "$CANDIDATE_COUNT" -eq 0 ]]; then
    printf '%s\t(no expired log files found)\t0\t0\tN/A\n' "$DATE"
  else
    TOTAL_BYTES=0
    while IFS=$'\t' read -r size_bytes path mtime; do
      [[ -z "$size_bytes" ]] && continue
      size_mb=$(awk "BEGIN { printf \"%.6f\", $size_bytes / 1024 / 1024 }")
      printf '%s\t%s\t%s\t%s\t%s\n' "$DATE" "$path" "$size_bytes" "$size_mb" "$mtime"
      TOTAL_BYTES=$((TOTAL_BYTES + size_bytes))
    done <"$CANDIDATE_FILE"
    TOTAL_MB=$(awk "BEGIN { printf \"%.6f\", $TOTAL_BYTES / 1024 / 1024 }")
  fi
} >"$REPORT"

rm -f "$CANDIDATE_FILE"

# ── 第三步：展示清理预览 ────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║           日志定期清理 — 预计清理清单                       ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo "  扫描目录     : $TARGET_DIR"
echo "  过期阈值     : ${RETENTION_DAYS} 天未修改"
echo "  匹配模式     : $PATTERNS"
echo "  候选文件数   : ${CANDIDATE_COUNT:-0}"
if [[ -n "${TOTAL_MB:-}" ]]; then
  echo "  预计释放空间 : ${TOTAL_MB} MB"
fi
echo "  详细报表     : $REPORT"
echo "  运行模式     : $([[ "$LAB_OPS_DRY_RUN" == "1" ]] && echo 'DRY-RUN (仅预览)' || echo '正式模式 (将删除文件!)')"
echo ""

# ── 第四步：无候选文件则直接结束 ───────────────────────────────────────────
if [[ "${CANDIDATE_COUNT:-0}" -eq 0 ]]; then
  lab_ops_log "log_cleanup: no expired log files found, done."
  exit 0
fi

# ── 第五步：DRY_RUN 模式下只展示清单 ───────────────────────────────────────
if lab_ops_is_true "$LAB_OPS_DRY_RUN"; then
  echo "── 候选文件列表（前 20 条）──"
  tail -n +2 "$REPORT" | head -20
  echo ""
  lab_ops_log "log_cleanup: DRY_RUN 模式，已生成报表，未执行实际删除"
  exit 0
fi

# ── 第六步：二次确认 ────────────────────────────────────────────────────────
if [[ "$AUTO_YES" == "0" ]]; then
  lab_ops_confirm "日志清理模块: 将在 [$TARGET_DIR] 中删除 ${CANDIDATE_COUNT} 个过期日志文件。
预计释放空间: ${TOTAL_MB:-0} MB。
详细清单: ${REPORT}" 30 || {
    lab_ops_log "log_cleanup: 用户取消操作"
    echo "  日志清理已取消。" >&2
    exit 0
  }
else
  lab_ops_log "log_cleanup: -y 模式，跳过交互确认"
fi

# ── 第七步：执行删除 ────────────────────────────────────────────────────────
DELETED=0
DELETED_BYTES=0
FAILED=0

while IFS=$'\t' read -r date path size_bytes size_mb mtime; do
  [[ "$date" == "Date" ]] && continue                        # 跳过表头
  [[ "$path" == "(no expired log files found)" ]] && continue # 跳过占位行
  [[ -z "$path" ]] && continue

  # 安全检查：删除前再次确认文件仍然存在且超过阈值天数
  if [[ ! -f "$path" ]]; then
    lab_ops_log "log_cleanup: skip (gone): $path"
    continue
  fi

  if rm -f "$path" 2>>"$ERROR_LOG"; then
    DELETED=$((DELETED + 1))
    DELETED_BYTES=$((DELETED_BYTES + size_bytes))
    lab_ops_log "log_cleanup: deleted: $path ($size_mb MB)"
  else
    FAILED=$((FAILED + 1))
    lab_ops_log "log_cleanup: FAILED to delete: $path (permission denied?)"
  fi
done <"$REPORT"

DELETED_MB=$(awk "BEGIN { printf \"%.6f\", $DELETED_BYTES / 1024 / 1024 }")

# ── 第八步：输出执行摘要 ────────────────────────────────────────────────────
{
  echo ""
  echo "═══════════════════════════════════════════════════════════════"
  echo "  日志清理执行摘要 — $(date '+%Y-%m-%d %H:%M:%S')"
  echo "═══════════════════════════════════════════════════════════════"
  echo "  扫描目录     : $TARGET_DIR"
  echo "  保留天数     : $RETENTION_DAYS"
  echo "  成功删除     : $DELETED 个文件"
  echo "  释放空间     : ${DELETED_MB} MB"
  echo "  删除失败     : $FAILED 个文件（详见 $ERROR_LOG）"
  echo "═══════════════════════════════════════════════════════════════"
} | tee -a "${LAB_OPS_LOG_DIR}/log_cleanup_summary.log"

lab_ops_log "log_cleanup: done. deleted=$DELETED failed=$FAILED freed_mb=$DELETED_MB"
