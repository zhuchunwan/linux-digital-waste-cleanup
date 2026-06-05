#!/usr/bin/env bash
# 过期日志和历史报告清理：自动删除超过指定天数的日志文件与历史报告。

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$ROOT_DIR/../lib/common.sh"
lab_ops_load_config

if [[ -n "${1:-}" ]]; then
  if [[ ! "$1" =~ ^[1-9][0-9]*$ ]]; then
    echo "错误：清理天数必须是大于 0 的整数。" >&2
    exit 1
  fi
  DAYS="$1"
  REPORT_DAYS="$1"
  RUN_MODE="用户手动指定"
else
  DAYS="${LAB_OPS_LOG_RETENTION_DAYS:-30}"
  REPORT_DAYS="${LAB_OPS_REPORT_RETENTION_DAYS:-$DAYS}"
  RUN_MODE="crontab/默认配置"
fi
DATE="$(date +%Y-%m-%d)"
REPORT="$(lab_ops_report_path "deleted_logs.txt" "$DATE")"
ERR="${LAB_OPS_LOG_DIR}/log_cleanup_errors.log"

lab_ops_log "log_cleanup: mode=$RUN_MODE targets=${LAB_OPS_LOG_TARGETS} log_days=$DAYS report_days=$REPORT_DAYS report=$REPORT"

{
  echo ""
  echo "============================================================"
  echo "过期日志与历史报告清理报告"
  echo "执行模式: $RUN_MODE"
  echo "日志清理规则: 删除超过 ${DAYS} 天的 *.log/*.log.*/*.out/*.err"
  echo "报告清理规则: 删除 reports 下超过 ${REPORT_DAYS} 天的历史报告"
  echo "生成时间: $(date '+%Y-%m-%d %H:%M:%S')"
  echo "白名单文件: $LAB_OPS_FILE_WHITELIST"
  echo ""
  printf '%-14s %-36s %-14s %s\n' "类型" "名称" "大小(bytes)" "完整路径"
  printf '%-14s %-36s %-14s %s\n' "--------------" "------------------------------------" "--------------" "----------------------------------------"
} | tee -a "$REPORT"

log_count=0
log_total=0
for dir in $LAB_OPS_LOG_TARGETS; do
  [[ -d "$dir" ]] || {
    lab_ops_log "log_cleanup: skip missing target $dir"
    continue
  }
  while IFS= read -r -d '' file; do
    if lab_ops_is_path_whitelisted "$file"; then
      lab_ops_log "log_cleanup: skip whitelist file=$(basename "$file") path=$file"
      continue
    fi
    size="$(stat -c %s "$file" 2>>"$ERR" || echo 0)"
    printf '%-14s %-36s %-14s %s\n' "日志文件" "$(basename "$file")" "$size" "$file" | tee -a "$REPORT"
    rm -f -- "$file"
    log_count=$((log_count + 1))
    log_total=$((log_total + size))
    lab_ops_log "log_cleanup: removed file=$(basename "$file") path=$file size_bytes=$size"
  done < <(
    find "$dir" -xdev -type f \
      \( -name '*.log' -o -name '*.log.*' -o -name '*.out' -o -name '*.err' \) \
      -mtime "+${DAYS}" -print0 2>>"$ERR"
  )
done

report_count=0
report_total=0
cutoff_date="$(date -d "-${REPORT_DAYS} days" +%Y-%m-%d 2>/dev/null || date -v-"${REPORT_DAYS}d" +%Y-%m-%d)"

if [[ -d "$LAB_OPS_REPORT_DIR" ]]; then
  while IFS= read -r -d '' entry; do
    name="$(basename "$entry")"
    [[ "$name" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || continue
    [[ "$name" < "$cutoff_date" ]] || continue
    if lab_ops_is_path_whitelisted "$entry" || lab_ops_contains_whitelisted_path "$entry"; then
      lab_ops_log "log_cleanup: skip report_dir protected by whitelist=$entry"
      continue
    fi
    size="$(du -sb "$entry" 2>>"$ERR" | awk '{print $1}' || echo 0)"
    printf '%-14s %-36s %-14s %s\n' "报告目录" "$name" "$size" "$entry" | tee -a "$REPORT"
    rm -rf -- "$entry"
    report_count=$((report_count + 1))
    report_total=$((report_total + size))
    lab_ops_log "log_cleanup: removed report_dir=$entry size_bytes=$size"
  done < <(find "$LAB_OPS_REPORT_DIR" -mindepth 1 -maxdepth 1 -type d -print0 2>>"$ERR")

  while IFS= read -r -d '' file; do
    [[ "$file" == "$REPORT" ]] && continue
    if lab_ops_is_path_whitelisted "$file"; then
      lab_ops_log "log_cleanup: skip whitelist report_file=$(basename "$file") path=$file"
      continue
    fi
    size="$(stat -c %s "$file" 2>>"$ERR" || echo 0)"
    printf '%-14s %-36s %-14s %s\n' "报告文件" "$(basename "$file")" "$size" "$file" | tee -a "$REPORT"
    rm -f -- "$file"
    report_count=$((report_count + 1))
    report_total=$((report_total + size))
    lab_ops_log "log_cleanup: removed report_file=$(basename "$file") path=$file size_bytes=$size"
  done < <(find "$LAB_OPS_REPORT_DIR" -mindepth 1 -maxdepth 1 -type f -mtime "+${REPORT_DAYS}" -print0 2>>"$ERR")
fi

{
  echo ""
  echo "已删除日志文件数: $log_count"
  echo "日志释放空间: ${log_total} bytes"
  echo "已删除历史报告项数: $report_count"
  echo "报告释放空间: ${report_total} bytes"
} | tee -a "$REPORT"

lab_ops_log "log_cleanup: done log_removed=$log_count log_bytes=$log_total report_removed=$report_count report_bytes=$report_total report=$REPORT"
