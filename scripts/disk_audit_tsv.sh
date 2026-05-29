#!/usr/bin/env bash
# 共享盘多维空间占用统计 -> TSV（避免逗号破坏 CSV；字段对齐课程 grep/sed/awk 要求）
# 用法: disk_audit_tsv.sh [扫描根目录，默认来自配置 LAB_OPS_SCAN_ROOT]

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$ROOT_DIR/../lib/common.sh"
lab_ops_load_config

SCAN_ROOT="${1:-$LAB_OPS_SCAN_ROOT}"
DATE="$(date +%Y-%m-%d)"
OUT="${LAB_OPS_REPORT_DIR}/disk_usage_${DATE}.tsv"
ERR="${LAB_OPS_LOG_DIR}/disk_audit_errors.log"

lab_ops_log "disk_audit: scan_root=$SCAN_ROOT -> $OUT"

if [[ ! -d "$SCAN_ROOT" ]]; then
  lab_ops_log "ERROR: scan root is not a directory: $SCAN_ROOT"
  exit 1
fi

# GNU find + awk；%U 用户名 %s 字节 %P 相对路径（相对 SCAN_ROOT），避免 basename 空格问题用 %p 再在 awk 取文件名
(
  cd "$SCAN_ROOT" || exit 1
  # shellcheck disable=SC2016
  nice -n 10 find . -xdev -type f -printf '%u\t%s\t%P\n' 2>>"$ERR"
) | awk -v OFS='\t' -v date="$DATE" -v root="$SCAN_ROOT" '
function basename_seg(p,   a, n) {
  n = split(p, a, "/");
  return a[n];
}
function file_ext(fname,   a, n) {
  n = split(fname, a, ".");
  if (n <= 1) return "(no_ext)";
  return a[n];
}
BEGIN {
  print "Date", "User", "File_Type", "Total_Files", "Total_Size_MB";
}
{
  user = $1;
  size = $2 + 0;
  rel = $3;
  for (i = 4; i <= NF; i++) rel = rel "\t" $i;
  fname = basename_seg(rel);
  ext = file_ext(fname);
  key = user SUBSEP ext;
  cnt[key]++;
  sum[key] += size;
  u[key] = user;
  e[key] = ext;
}
END {
  for (k in cnt) {
    mb = sum[k] / 1024 / 1024;
    printf "%s\t%s\t%s\t%d\t%.6f\n", date, u[k], e[k], cnt[k], mb;
  }
}' | LC_ALL=C sort -t "$(printf '\t')" -k2,2 -k3,3 >"$OUT"

lab_ops_log "disk_audit: done lines=$(wc -l <"$OUT")"
