#!/usr/bin/env bash
# 文件大小初筛 + MD5 精筛；重复文件硬链接到同一 inode（保留字典序最小路径为主文件）
# 用法: dedupe_hardlink.sh [扫描根目录]

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$ROOT_DIR/../lib/common.sh"
lab_ops_load_config

SCAN_ROOT="${1:-$LAB_OPS_SCAN_ROOT}"
MIN_BYTES="${LAB_OPS_DEDUPE_MIN_BYTES:-1024}"
PLAN_LOG="${LAB_OPS_LOG_DIR}/dedupe_plan.log"

# 解析 -y 参数
AUTO_YES=0
for arg in "$@"; do
  case "$arg" in
    -y|--yes|--force) AUTO_YES=1; export LAB_OPS_FORCE=1 ;;
  esac
done

lab_ops_log "dedupe: scan_root=$SCAN_ROOT min_bytes=$MIN_BYTES dry_run=$LAB_OPS_DRY_RUN"

if [[ ! -d "$SCAN_ROOT" ]]; then
  lab_ops_log "ERROR: not a directory: $SCAN_ROOT"
  exit 1
fi

command -v md5sum >/dev/null || {
  lab_ops_log "ERROR: md5sum not found"
  exit 1
}

TMPDIR="${TMPDIR:-/tmp}"
WORKDIR="$(mktemp -d "$TMPDIR/lab-dedupe.XXXXXX")"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

LIST="$WORKDIR/by_size.tsv"
DUP_SAME_SIZE="$WORKDIR/dup_same_size.tsv"

nice -n 10 find "$SCAN_ROOT" -xdev -type f -size "+${MIN_BYTES}c" -printf '%s\t%p\n' 2>>"${LAB_OPS_LOG_DIR}/dedupe_errors.log" \
  | LC_ALL=C sort -t "$(printf '\t')" -k1,1n >"$LIST"

awk '
function path_field(   p) {
  p = $0;
  sub(/^[^\t]+\t/, "", p);
  return p;
}
function flush(   i) {
  if (n < 2) return;
  for (i = 1; i <= n; i++) print sz "\t" paths[i];
}
NR == 1 { sz = $1; n = 1; paths[1] = path_field(); next }
{
  if ($1 == sz) {
    n++;
    paths[n] = path_field();
    next;
  }
  flush();
  sz = $1;
  n = 1;
  paths[1] = path_field();
}
END { flush(); }
' "$LIST" >"$DUP_SAME_SIZE"

# 正式模式下的二次确认
if ! lab_ops_is_true "$LAB_OPS_DRY_RUN"; then
  dup_count=$(wc -l <"$DUP_SAME_SIZE")
  if [[ "$AUTO_YES" == "0" ]]; then
    lab_ops_confirm "去重模块: 发现 ${dup_count} 组相同大小的文件待处理。
将对 MD5 一致的重复文件执行硬链接替换 (ln -f)。
去重计划详见: ${PLAN_LOG}" 30 || {
      lab_ops_log "dedupe: 用户取消去重操作"
      echo "  去重操作已取消。" >&2
      exit 0
    }
  else
    lab_ops_log "dedupe: -y 模式，跳过交互确认"
  fi
fi

flush_md5_bucket() {
  ((${#bucket[@]} < 2)) && {
    bucket=()
    return
  }
  declare -A paths_by_hash=()
  local p h
  for p in "${bucket[@]}"; do
    h="$(md5sum "$p" | awk '{print $1}')"
    if [[ -n "${paths_by_hash[$h]:-}" ]]; then
      paths_by_hash[$h]="${paths_by_hash[$h]}"$'\n'"$p"
    else
      paths_by_hash[$h]="$p"
    fi
  done
  local keeper dup sorted
  for h in "${!paths_by_hash[@]}"; do
    mapfile -t sorted < <(printf '%s\n' "${paths_by_hash[$h]}" | LC_ALL=C sort)
    ((${#sorted[@]} < 2)) && continue
    keeper="${sorted[0]}"
    for ((i = 1; i < ${#sorted[@]}; i++)); do
      dup="${sorted[$i]}"
      if lab_ops_is_true "$LAB_OPS_DRY_RUN"; then
        printf 'DRY_RUN ln -f %q %q\n' "$keeper" "$dup" | tee -a "$PLAN_LOG" >&2
      else
        ln -f "$keeper" "$dup"
        lab_ops_log "dedupe: ln -f keeper=$keeper dup=$dup"
      fi
    done
  done
  bucket=()
}

cur_sz=""
bucket=()
while IFS=$'\t' read -r sz path; do
  if [[ -z "${cur_sz}" ]]; then
    cur_sz="$sz"
    bucket=("$path")
    continue
  fi
  if [[ "$sz" != "$cur_sz" ]]; then
    flush_md5_bucket
    cur_sz="$sz"
    bucket=("$path")
  else
    bucket+=("$path")
  fi
done <"$DUP_SAME_SIZE"
flush_md5_bucket

lab_ops_log "dedupe: finished."
