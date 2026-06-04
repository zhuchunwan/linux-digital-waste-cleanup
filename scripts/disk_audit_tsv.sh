#!/usr/bin/env bash
# 磁盘空间审计：显示指定文件夹下每个文件的名称和大小。
# 兼容旧文件名 disk_audit_tsv.sh，实际输出为 TXT。

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$ROOT_DIR/../lib/common.sh"
lab_ops_load_config

SCAN_ROOT="${1:-$LAB_OPS_SCAN_ROOT}"
DATE="$(date +%Y-%m-%d)"
OUT="${LAB_OPS_REPORT_DIR}/disk_audit_${DATE}.txt"
ERR="${LAB_OPS_LOG_DIR}/disk_audit_errors.log"

if [[ ! -d "$SCAN_ROOT" ]]; then
  echo "错误：不是有效文件夹: $SCAN_ROOT" >&2
  lab_ops_log "disk_audit: invalid directory $SCAN_ROOT"
  exit 1
fi

SCAN_ROOT="$(cd "$SCAN_ROOT" && pwd -P)"
lab_ops_log "disk_audit: scan_root=$SCAN_ROOT report=$OUT"

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

{
  echo "磁盘空间审计报告"
  echo "扫描目录: $SCAN_ROOT"
  echo "生成时间: $(date '+%Y-%m-%d %H:%M:%S')"
  echo "白名单文件: $LAB_OPS_FILE_WHITELIST"
  echo ""
  printf '%-36s %-14s %s\n' "文件名" "大小" "完整路径"
  printf '%-36s %-14s %s\n' "------------------------------------" "--------------" "----------------------------------------"
} | tee "$OUT"

count=0
total=0
while IFS= read -r -d '' file; do
  if lab_ops_is_path_whitelisted "$file"; then
    lab_ops_log "disk_audit: skip whitelist file=$(basename "$file") path=$file"
    continue
  fi
  size="$(stat -c %s "$file" 2>>"$ERR" || echo 0)"
  count=$((count + 1))
  total=$((total + size))
  printf '%-36s %-14s %s\n' "$(basename "$file")" "$(human_size "$size")" "$file" | tee -a "$OUT"
done < <(find "$SCAN_ROOT" -xdev -type f -print0 2>>"$ERR")

{
  echo ""
  echo "文件总数: $count"
  echo "总大小: $(human_size "$total")"
} | tee -a "$OUT"

lab_ops_log "disk_audit: done files=$count total_bytes=$total report=$OUT"
