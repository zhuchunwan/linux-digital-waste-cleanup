#!/usr/bin/env bash
# 过期文件管理：递归扫描用户指定目录，将过期普通文件原地压缩并在验证成功后删除原文件。

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$ROOT_DIR/../lib/common.sh"
lab_ops_load_config

SCAN_INPUT="${1:-}"
DAYS="${LAB_OPS_COLD_DAYS:-30}"
TIME_FIELD="${LAB_OPS_COLD_TIME_FIELD:-atime}"
DATE="$(date +%Y-%m-%d)"
REPORT="$(lab_ops_report_path "expired_files.txt" "$DATE")"
ERR="${LAB_OPS_LOG_DIR}/cold_archive_errors.log"

if [[ -z "$SCAN_INPUT" ]]; then
  echo "错误：请指定需要扫描的文件夹路径。" >&2
  exit 1
fi

if [[ ! "$DAYS" =~ ^[1-9][0-9]*$ ]]; then
  echo "错误：LAB_OPS_COLD_DAYS 必须是大于 0 的整数。" >&2
  exit 1
fi

if [[ -L "$SCAN_INPUT" ]]; then
  echo "错误：为避免指向错误位置，功能 4 不扫描软链接文件夹: $SCAN_INPUT" >&2
  lab_ops_log "archive: refused symlink scan_root=$SCAN_INPUT"
  exit 1
fi

if [[ ! -d "$SCAN_INPUT" ]]; then
  echo "错误：扫描路径不是有效的文件夹: $SCAN_INPUT" >&2
  lab_ops_log "archive: invalid scan_root=$SCAN_INPUT"
  exit 1
fi

command -v tar >/dev/null || {
  echo "错误：找不到 tar 命令。" >&2
  lab_ops_log "archive: tar not found"
  exit 1
}

case "$TIME_FIELD" in
  atime) STAT_FORMAT='%X'; TIME_DESC="访问时间" ;;
  mtime) STAT_FORMAT='%Y'; TIME_DESC="修改时间" ;;
  ctime) STAT_FORMAT='%Z'; TIME_DESC="元数据变更时间" ;;
  *)
    echo "错误：LAB_OPS_COLD_TIME_FIELD 只能是 atime、mtime 或 ctime。" >&2
    exit 1
    ;;
esac

SCAN_ROOT="$(cd "$SCAN_INPUT" && pwd -P)"
PROJECT_PATH="$(cd "$LAB_OPS_HOME" && pwd -P)"
CUTOFF_EPOCH="$(date -d "-${DAYS} days" +%s 2>/dev/null || date -v-"${DAYS}d" +%s)"

if [[ "$SCAN_ROOT" == "/" ]]; then
  echo "错误：禁止扫描并清理系统根目录 /。" >&2
  lab_ops_log "archive: refused root scan"
  exit 1
fi

if [[ "$PROJECT_PATH" == "$SCAN_ROOT" || "$PROJECT_PATH" == "$SCAN_ROOT/"* ]]; then
  echo "错误：扫描路径是本项目目录或其上级目录，为避免程序处理自身，已拒绝: $SCAN_ROOT" >&2
  lab_ops_log "archive: refused project or ancestor scan_root=$SCAN_ROOT project=$PROJECT_PATH"
  exit 1
fi

if lab_ops_is_path_whitelisted "$SCAN_ROOT"; then
  echo "扫描目录受白名单保护，不会压缩或删除其中的文件: $SCAN_ROOT"
  lab_ops_log "archive: scan root protected by whitelist path=$SCAN_ROOT"
  exit 0
fi

human_size() {
  awk -v bytes="$1" 'BEGIN {
    split("B KB MB GB TB", unit, " ");
    value = bytes + 0;
    i = 1;
    while (value >= 1024 && i < 5) {
      value = value / 1024;
      i++;
    }
    if (i == 1) printf "%d %s", value, unit[i];
    else printf "%.2f %s", value, unit[i];
  }'
}

format_epoch() {
  date -d "@$1" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -r "$1" '+%Y-%m-%d %H:%M:%S'
}

unique_archive_path() {
  local target="$1" candidate stamp counter
  candidate="${target}.tar.gz"
  if [[ ! -e "$candidate" ]]; then
    printf '%s' "$candidate"
    return
  fi

  stamp="$(date +%Y%m%d_%H%M%S)"
  candidate="${target}_${stamp}.tar.gz"
  counter=1
  while [[ -e "$candidate" ]]; do
    candidate="${target}_${stamp}_${counter}.tar.gz"
    counter=$((counter + 1))
  done
  printf '%s' "$candidate"
}

declare -a CANDIDATES=()
declare -a CANDIDATE_SIZES=()
scanned=0
whitelist_skipped=0
archive_skipped=0
candidate_total_bytes=0

lab_ops_log "archive: scan_root=$SCAN_ROOT days=$DAYS field=$TIME_FIELD report=$REPORT"

{
  echo ""
  echo "============================================================"
  echo "过期文件扫描报告"
  echo "扫描目录: $SCAN_ROOT"
  echo "判断规则: 文件的${TIME_DESC}超过 ${DAYS} 天"
  echo "处理方式: 在文件原目录生成同名 .tar.gz，验证成功后删除原文件"
  echo "安全规则: 跳过白名单、软链接和已有 .tar.gz 压缩包"
  echo "生成时间: $(date '+%Y-%m-%d %H:%M:%S')"
  echo ""
  printf '%-6s %-14s %-19s %s\n' "序号" "大小" "最后${TIME_DESC}" "完整路径"
  printf '%-6s %-14s %-19s %s\n' "------" "--------------" "-------------------" "----------------------------------------"
} | tee -a "$REPORT"

while IFS= read -r -d '' file; do
  scanned=$((scanned + 1))

  if lab_ops_is_path_whitelisted "$file"; then
    whitelist_skipped=$((whitelist_skipped + 1))
    continue
  fi

  if [[ "$file" == *.tar.gz ]]; then
    archive_skipped=$((archive_skipped + 1))
    continue
  fi

  file_epoch="$(stat -c "$STAT_FORMAT" -- "$file" 2>>"$ERR" || echo 0)"
  file_size="$(stat -c %s -- "$file" 2>>"$ERR" || echo 0)"
  if [[ ! "$file_epoch" =~ ^[0-9]+$ ]] || ((file_epoch <= 0)); then
    lab_ops_log "archive: unreadable timestamp file=$file"
    continue
  fi

  if ((file_epoch < CUTOFF_EPOCH)); then
    CANDIDATES+=("$file")
    CANDIDATE_SIZES+=("$file_size")
    candidate_total_bytes=$((candidate_total_bytes + file_size))
    printf '%-6s %-14s %-19s %s\n' \
      "${#CANDIDATES[@]}" "$(human_size "$file_size")" "$(format_epoch "$file_epoch")" "$file" | tee -a "$REPORT"
  fi
done < <(find "$SCAN_ROOT" -xdev -type f -print0 2>>"$ERR")

{
  echo ""
  echo "扫描文件数: $scanned"
  echo "过期候选数: ${#CANDIDATES[@]}"
  echo "候选原始大小: $(human_size "$candidate_total_bytes")"
  echo "白名单跳过数: $whitelist_skipped"
  echo "已有压缩包跳过数: $archive_skipped"
} | tee -a "$REPORT"

if ((${#CANDIDATES[@]} == 0)); then
  echo "没有发现超过 ${DAYS} 天未使用的文件。" | tee -a "$REPORT"
  lab_ops_log "archive: done no candidates scan_root=$SCAN_ROOT scanned=$scanned"
  exit 0
fi

echo "确认后将逐个生成压缩包；每个压缩包验证成功后，才会删除对应原文件。" | tee -a "$REPORT"
if ! lab_ops_confirm "确认压缩并删除以上 ${#CANDIDATES[@]} 个过期文件吗？" 30; then
  echo "未确认或超时，已返回，不压缩或删除任何文件。" | tee -a "$REPORT"
  lab_ops_log "archive: cancelled scan_root=$SCAN_ROOT candidates=${#CANDIDATES[@]}"
  exit 0
fi

compressed=0
skipped=0
failed=0

for index in "${!CANDIDATES[@]}"; do
  file="${CANDIDATES[$index]}"

  if [[ -L "$file" || ! -f "$file" ]]; then
    echo "跳过：文件已不存在或已变成软链接: $file" | tee -a "$REPORT"
    skipped=$((skipped + 1))
    continue
  fi

  if lab_ops_is_path_whitelisted "$file"; then
    echo "跳过：文件现在受白名单保护: $file" | tee -a "$REPORT"
    skipped=$((skipped + 1))
    continue
  fi

  current_epoch="$(stat -c "$STAT_FORMAT" -- "$file" 2>>"$ERR" || echo 0)"
  if [[ ! "$current_epoch" =~ ^[0-9]+$ ]] || ((current_epoch >= CUTOFF_EPOCH)); then
    echo "跳过：文件在确认前已被使用或修改: $file" | tee -a "$REPORT"
    skipped=$((skipped + 1))
    continue
  fi

  before_id="$(stat -c '%d:%i' -- "$file" 2>>"$ERR" || echo "")"
  before_size="$(stat -c %s -- "$file" 2>>"$ERR" || echo "")"
  before_mtime="$(stat -c %Y -- "$file" 2>>"$ERR" || echo "")"
  parent="$(dirname "$file")"
  name="$(basename "$file")"
  archive_path="$(unique_archive_path "$file")"

  if tar -czf "$archive_path" -C "$parent" -- "$name" 2>>"$ERR" \
    && tar -tzf "$archive_path" >/dev/null 2>>"$ERR"; then
    after_id="$(stat -c '%d:%i' -- "$file" 2>>"$ERR" || echo "")"
    after_size="$(stat -c %s -- "$file" 2>>"$ERR" || echo "")"
    after_mtime="$(stat -c %Y -- "$file" 2>>"$ERR" || echo "")"

    if [[ -z "$before_id" || "$before_id" != "$after_id" || "$before_size" != "$after_size" || "$before_mtime" != "$after_mtime" ]]; then
      rm -f -- "$archive_path"
      echo "跳过：压缩期间源文件发生变化，已删除临时压缩包并保留原文件: $file" | tee -a "$REPORT"
      lab_ops_log "archive: source changed during compression file=$file"
      skipped=$((skipped + 1))
      continue
    fi

    if rm -f -- "$file"; then
      {
        echo "已压缩并删除原文件: $file"
        echo "压缩包: $archive_path"
      } | tee -a "$REPORT"
      lab_ops_log "archive: compressed_and_removed file=$file archive=$archive_path original_bytes=${CANDIDATE_SIZES[$index]}"
      compressed=$((compressed + 1))
    else
      echo "压缩包验证成功，但删除原文件失败；压缩包和原文件均已保留: $file" | tee -a "$REPORT" >&2
      lab_ops_log "archive: remove failed file=$file archive=$archive_path"
      failed=$((failed + 1))
    fi
  else
    rm -f -- "$archive_path"
    echo "压缩或验证失败，已保留原文件: $file" | tee -a "$REPORT" >&2
    lab_ops_log "archive: failed file=$file archive=$archive_path"
    failed=$((failed + 1))
  fi
done

{
  echo ""
  echo "处理完成：成功压缩并删除原文件 $compressed 个，跳过 $skipped 个，失败 $failed 个。"
} | tee -a "$REPORT"
lab_ops_log "archive: done scan_root=$SCAN_ROOT compressed=$compressed skipped=$skipped failed=$failed report=$REPORT"

if ((failed > 0)); then
  exit 1
fi
