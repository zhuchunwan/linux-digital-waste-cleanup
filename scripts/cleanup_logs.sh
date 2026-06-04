#!/usr/bin/env bash
# 过期日志清理：自动删除超过指定天数的日志文件。

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$ROOT_DIR/../lib/common.sh"
lab_ops_load_config

DAYS="${LAB_OPS_LOG_RETENTION_DAYS:-30}"
DATE="$(date +%Y-%m-%d)"
REPORT="${LAB_OPS_REPORT_DIR}/deleted_logs_${DATE}.txt"
ERR="${LAB_OPS_LOG_DIR}/log_cleanup_errors.log"

lab_ops_log "log_cleanup: targets=${LAB_OPS_LOG_TARGETS} days=$DAYS report=$REPORT"

{
  echo "过期日志清理报告"
  echo "清理规则: 删除超过 ${DAYS} 天的 *.log/*.log.*/*.out/*.err"
  echo "生成时间: $(date '+%Y-%m-%d %H:%M:%S')"
  echo "白名单文件: $LAB_OPS_FILE_WHITELIST"
  echo ""
  printf '%-36s %-14s %s\n' "文件名" "大小(bytes)" "完整路径"
  printf '%-36s %-14s %s\n' "------------------------------------" "--------------" "----------------------------------------"
} | tee "$REPORT"

count=0
total=0
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
    printf '%-36s %-14s %s\n' "$(basename "$file")" "$size" "$file" | tee -a "$REPORT"
    rm -f -- "$file"
    count=$((count + 1))
    total=$((total + size))
    lab_ops_log "log_cleanup: removed file=$(basename "$file") path=$file size_bytes=$size"
  done < <(
    find "$dir" -xdev -type f \
      \( -name '*.log' -o -name '*.log.*' -o -name '*.out' -o -name '*.err' \) \
      -mtime "+${DAYS}" -print0 2>>"$ERR"
  )
done

{
  echo ""
  echo "已删除日志文件数: $count"
  echo "释放空间: ${total} bytes"
} | tee -a "$REPORT"

lab_ops_log "log_cleanup: done removed=$count total_bytes=$total report=$REPORT"
