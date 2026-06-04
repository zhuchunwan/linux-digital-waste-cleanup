#!/usr/bin/env bash
# 重复文件清理：扫描重复文件，显示在屏幕上，用户 30 秒内确认后删除重复副本。

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$ROOT_DIR/../lib/common.sh"
lab_ops_load_config

SCAN_ROOT="${1:-$LAB_OPS_SCAN_ROOT}"
MIN_BYTES="${LAB_OPS_DEDUPE_MIN_BYTES:-1024}"
DATE="$(date +%Y-%m-%d)"
REPORT="${LAB_OPS_REPORT_DIR}/duplicate_files_${DATE}.txt"
PLAN_LOG="${LAB_OPS_LOG_DIR}/dedupe_plan.log"
ERR="${LAB_OPS_LOG_DIR}/dedupe_errors.log"

if [[ ! -d "$SCAN_ROOT" ]]; then
  echo "错误：不是有效文件夹: $SCAN_ROOT" >&2
  lab_ops_log "dedupe: invalid directory $SCAN_ROOT"
  exit 1
fi

command -v md5sum >/dev/null || {
  echo "错误：找不到 md5sum 命令。" >&2
  lab_ops_log "dedupe: md5sum not found"
  exit 1
}

SCAN_ROOT="$(cd "$SCAN_ROOT" && pwd -P)"
: >"$PLAN_LOG"
: >"$REPORT"

lab_ops_log "dedupe: scan_root=$SCAN_ROOT min_bytes=$MIN_BYTES report=$REPORT"

declare -A paths_by_hash=()
declare -A sizes_by_hash=()

while IFS= read -r -d '' file; do
  if lab_ops_is_path_whitelisted "$file"; then
    lab_ops_log "dedupe: skip whitelist file=$(basename "$file") path=$file"
    continue
  fi
  size="$(stat -c %s "$file" 2>>"$ERR" || echo 0)"
  ((size < MIN_BYTES)) && continue
  hash="$(md5sum "$file" 2>>"$ERR" | awk '{print $1}' || true)"
  [[ -z "$hash" ]] && continue
  sizes_by_hash["$hash"]="$size"
  if [[ -n "${paths_by_hash[$hash]:-}" ]]; then
    paths_by_hash["$hash"]="${paths_by_hash[$hash]}"$'\n'"$file"
  else
    paths_by_hash["$hash"]="$file"
  fi
done < <(find "$SCAN_ROOT" -xdev -type f -print0 2>>"$ERR")

{
  echo "重复文件扫描报告"
  echo "扫描目录: $SCAN_ROOT"
  echo "生成时间: $(date '+%Y-%m-%d %H:%M:%S')"
  echo "白名单文件: $LAB_OPS_FILE_WHITELIST"
  echo "小于 ${MIN_BYTES} bytes 的文件已跳过"
  echo ""
} | tee "$REPORT"

duplicate_count=0
release_bytes=0
delete_list=()
group_no=0

for hash in "${!paths_by_hash[@]}"; do
  mapfile -t files < <(printf '%s\n' "${paths_by_hash[$hash]}" | LC_ALL=C sort)
  ((${#files[@]} < 2)) && continue
  group_no=$((group_no + 1))
  keeper="${files[0]}"
  size="${sizes_by_hash[$hash]}"
  {
    echo "重复组 $group_no"
    echo "  MD5: $hash"
    echo "  大小: $size bytes"
    echo "  保留: $(basename "$keeper")"
    echo "        $keeper"
  } | tee -a "$REPORT"
  for ((i = 1; i < ${#files[@]}; i++)); do
    dup="${files[$i]}"
    duplicate_count=$((duplicate_count + 1))
    release_bytes=$((release_bytes + size))
    delete_list+=("$dup")
    {
      echo "  待删除重复文件: $(basename "$dup")"
      echo "        $dup"
    } | tee -a "$REPORT"
    printf 'delete_file=%q path=%q size_bytes=%s keeper=%q\n' "$(basename "$dup")" "$dup" "$size" "$keeper" >>"$PLAN_LOG"
  done
  echo "" | tee -a "$REPORT"
done

if ((duplicate_count == 0)); then
  echo "未发现重复文件。" | tee -a "$REPORT"
  lab_ops_log "dedupe: no duplicates report=$REPORT"
  exit 0
fi

echo "共发现 ${duplicate_count} 个重复副本，预计释放 ${release_bytes} bytes。" | tee -a "$REPORT"
echo "报告已保存: $REPORT"
echo ""

if [[ ! -t 0 ]]; then
  echo "当前不是交互式终端，自动返回，不删除任何文件。"
  lab_ops_log "dedupe: non-interactive terminal, cancelled"
  exit 0
fi

answer=""
read -r -t 30 -p "确认删除以上重复副本吗？请输入 y 确认，30 秒未确认自动返回: " answer || true
echo ""
case "$answer" in
  y|Y|yes|YES)
    for dup in "${delete_list[@]}"; do
      if lab_ops_is_path_whitelisted "$dup"; then
        lab_ops_log "dedupe: skip delete whitelist file=$(basename "$dup") path=$dup"
        continue
      fi
      rm -f -- "$dup"
      echo "已删除: $dup"
      lab_ops_log "dedupe: removed file=$(basename "$dup") path=$dup"
    done
    echo "重复文件清理完成。"
    lab_ops_log "dedupe: removed_count=$duplicate_count release_bytes=$release_bytes"
    ;;
  *)
    echo "未确认或超时，已返回，不删除任何文件。"
    lab_ops_log "dedupe: cancelled or timeout"
    ;;
esac
