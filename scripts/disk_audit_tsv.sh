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
OUT="$(lab_ops_report_path "disk_audit.txt" "$DATE")"
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
  echo ""
  echo "============================================================"
  echo "磁盘空间审计报告"
  echo "扫描目录: $SCAN_ROOT"
  echo "生成时间: $(date '+%Y-%m-%d %H:%M:%S')"
  echo "白名单文件: $LAB_OPS_FILE_WHITELIST"
  echo ""
  printf '%-36s %-14s %-8s %-18s %s\n' "文件名" "大小" "链接数" "Inode" "完整路径"
  printf '%-36s %-14s %-8s %-18s %s\n' "------------------------------------" "--------------" "--------" "------------------" "----------------------------------------"
} | tee -a "$OUT"

count=0
logical_total=0
actual_total=0
declare -A seen_inodes=()
while IFS= read -r -d '' file; do
  if lab_ops_is_path_whitelisted "$file"; then
    lab_ops_log "disk_audit: skip whitelist file=$(basename "$file") path=$file"
    continue
  fi
  size="$(stat -c %s "$file" 2>>"$ERR" || echo 0)"
  link_count="$(stat -c %h "$file" 2>>"$ERR" || echo 1)"
  inode_key="$(stat -c '%d:%i' "$file" 2>>"$ERR" || echo "$file")"
  count=$((count + 1))
  logical_total=$((logical_total + size))
  if [[ -z "${seen_inodes[$inode_key]:-}" ]]; then
    seen_inodes["$inode_key"]=1
    actual_total=$((actual_total + size))
  fi
  printf '%-36s %-14s %-8s %-18s %s\n' "$(basename "$file")" "$(human_size "$size")" "$link_count" "$inode_key" "$file" | tee -a "$OUT"
done < <(find "$SCAN_ROOT" -xdev -type f -print0 2>>"$ERR")

savings=$((logical_total - actual_total))
{
  echo ""
  echo "文件总数: $count"
  echo "路径大小合计: $(human_size "$logical_total")"
  echo "实际占用大小: $(human_size "$actual_total")"
  echo "硬链接节省空间: $(human_size "$savings")"
  echo "说明: 硬链接后多个文件路径仍各自显示原文件大小，但相同 Inode 的内容只占一份实际空间。"
} | tee -a "$OUT"

lab_ops_log "disk_audit: done files=$count logical_bytes=$logical_total actual_bytes=$actual_total saved_bytes=$savings report=$OUT"
