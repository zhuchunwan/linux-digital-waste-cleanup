#!/usr/bin/env bash
# 过期文件管理：超过指定天数未使用的文件自动打包压缩，不删除原文件。

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$ROOT_DIR/../lib/common.sh"
lab_ops_load_config

SCAN_ROOT="${1:-$LAB_OPS_SCAN_ROOT}"
DAYS="${LAB_OPS_COLD_DAYS:-30}"
TIME_FIELD="${LAB_OPS_COLD_TIME_FIELD:-atime}"
MIN_BYTES="${LAB_OPS_COLD_MIN_BYTES:-1}"
DATE="$(date +%Y-%m-%d)"
STAMP="$(date +%Y%m%d_%H%M%S)"
REPORT="${LAB_OPS_REPORT_DIR}/expired_files_${DATE}.txt"
ARCHIVE_FILE="${LAB_OPS_ARCHIVE_DIR}/expired_files_${STAMP}.tar.gz"
ERR="${LAB_OPS_LOG_DIR}/cold_archive_errors.log"

if [[ ! -d "$SCAN_ROOT" ]]; then
  echo "错误：不是有效文件夹: $SCAN_ROOT" >&2
  lab_ops_log "archive: invalid directory $SCAN_ROOT"
  exit 1
fi

case "$TIME_FIELD" in
  atime) FIND_TIME="-atime"; TIME_DESC="访问时间" ;;
  mtime) FIND_TIME="-mtime"; TIME_DESC="修改时间" ;;
  ctime) FIND_TIME="-ctime"; TIME_DESC="元数据变更时间" ;;
  *)
    echo "错误：LAB_OPS_COLD_TIME_FIELD 只能是 atime、mtime 或 ctime。" >&2
    exit 1
    ;;
esac

SCAN_ROOT="$(cd "$SCAN_ROOT" && pwd -P)"
mkdir -p "$LAB_OPS_ARCHIVE_DIR"

TMPDIR="${TMPDIR:-/tmp}"
WORKDIR="$(mktemp -d "$TMPDIR/lab-archive.XXXXXX")"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT
REL_LIST="$WORKDIR/files.rel.null"

lab_ops_log "archive: scan_root=$SCAN_ROOT days=$DAYS field=$TIME_FIELD report=$REPORT"

{
  echo "过期文件打包报告"
  echo "扫描目录: $SCAN_ROOT"
  echo "判断规则: ${TIME_DESC}超过 ${DAYS} 天"
  echo "生成时间: $(date '+%Y-%m-%d %H:%M:%S')"
  echo "白名单文件: $LAB_OPS_FILE_WHITELIST"
  echo ""
  printf '%-36s %-14s %s\n' "文件名" "大小(bytes)" "完整路径"
  printf '%-36s %-14s %s\n' "------------------------------------" "--------------" "----------------------------------------"
} | tee "$REPORT"

count=0
total=0
while IFS= read -r -d '' file; do
  if lab_ops_is_path_whitelisted "$file"; then
    lab_ops_log "archive: skip whitelist file=$(basename "$file") path=$file"
    continue
  fi
  rel="${file#$SCAN_ROOT/}"
  size="$(stat -c %s "$file" 2>>"$ERR" || echo 0)"
  count=$((count + 1))
  total=$((total + size))
  printf '%-36s %-14s %s\n' "$(basename "$file")" "$size" "$file" | tee -a "$REPORT"
  printf '%s\0' "$rel" >>"$REL_LIST"
done < <(
  find "$SCAN_ROOT" -xdev -type f -size "+${MIN_BYTES}c" "$FIND_TIME" "+${DAYS}" -print0 2>>"$ERR"
)

if ((count == 0)); then
  echo "" | tee -a "$REPORT"
  echo "未发现超过 ${DAYS} 天未使用的文件。" | tee -a "$REPORT"
  lab_ops_log "archive: no expired files"
  exit 0
fi

tar --null -czf "$ARCHIVE_FILE" -C "$SCAN_ROOT" --files-from "$REL_LIST"

{
  echo ""
  echo "过期文件数量: $count"
  echo "原始总大小: ${total} bytes"
  echo "压缩包: $ARCHIVE_FILE"
  echo "注意：本功能只打包压缩，不删除原文件。"
} | tee -a "$REPORT"

lab_ops_log "archive: created archive=$ARCHIVE_FILE files=$count total_bytes=$total report=$REPORT"
