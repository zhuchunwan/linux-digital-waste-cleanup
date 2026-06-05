#!/usr/bin/env bash
# 过期文件或文件夹管理：判断用户指定的单个目标，压缩到原路径旁并在验证成功后删除原目标。

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$ROOT_DIR/../lib/common.sh"
lab_ops_load_config

TARGET_INPUT="${1:-}"
DAYS="${LAB_OPS_COLD_DAYS:-30}"
TIME_FIELD="${LAB_OPS_COLD_TIME_FIELD:-atime}"
DATE="$(date +%Y-%m-%d)"
REPORT="$(lab_ops_report_path "expired_targets.txt" "$DATE")"
ERR="${LAB_OPS_LOG_DIR}/cold_archive_errors.log"

if [[ -z "$TARGET_INPUT" ]]; then
  echo "错误：请指定需要判断并压缩的文件或文件夹完整路径。" >&2
  exit 1
fi

if [[ ! "$DAYS" =~ ^[1-9][0-9]*$ ]]; then
  echo "错误：LAB_OPS_COLD_DAYS 必须是大于 0 的整数。" >&2
  exit 1
fi

if [[ -L "$TARGET_INPUT" ]]; then
  echo "错误：为避免指向错误位置，功能 4 不处理软链接: $TARGET_INPUT" >&2
  lab_ops_log "archive: refused symlink target=$TARGET_INPUT"
  exit 1
fi

if [[ ! -f "$TARGET_INPUT" && ! -d "$TARGET_INPUT" ]]; then
  echo "错误：目标不是有效的普通文件或文件夹: $TARGET_INPUT" >&2
  lab_ops_log "archive: invalid target=$TARGET_INPUT"
  exit 1
fi

command -v tar >/dev/null || {
  echo "错误：找不到 tar 命令。" >&2
  lab_ops_log "archive: tar not found"
  exit 1
}

case "$TIME_FIELD" in
  atime) FIND_PRINTF='%A@'; STAT_FORMAT='%X'; TIME_DESC="访问时间" ;;
  mtime) FIND_PRINTF='%T@'; STAT_FORMAT='%Y'; TIME_DESC="修改时间" ;;
  ctime) FIND_PRINTF='%C@'; STAT_FORMAT='%Z'; TIME_DESC="元数据变更时间" ;;
  *)
    echo "错误：LAB_OPS_COLD_TIME_FIELD 只能是 atime、mtime 或 ctime。" >&2
    exit 1
    ;;
esac

TARGET_PATH="$(realpath -e -- "$TARGET_INPUT")"
TARGET_PARENT="$(dirname "$TARGET_PATH")"
TARGET_NAME="$(basename "$TARGET_PATH")"
PROJECT_PATH="$(cd "$LAB_OPS_HOME" && pwd -P)"
CUTOFF_EPOCH="$(date -d "-${DAYS} days" +%s 2>/dev/null || date -v-"${DAYS}d" +%s)"

if [[ "$TARGET_PATH" == "/" ]]; then
  echo "错误：禁止压缩或删除系统根目录 /。" >&2
  lab_ops_log "archive: refused root target"
  exit 1
fi

if [[ "$PROJECT_PATH" == "$TARGET_PATH" || "$PROJECT_PATH" == "$TARGET_PATH/"* ]]; then
  echo "错误：目标是本项目目录或其上级目录，为避免程序删除自身，已拒绝处理: $TARGET_PATH" >&2
  lab_ops_log "archive: refused project or ancestor target=$TARGET_PATH project=$PROJECT_PATH"
  exit 1
fi

if lab_ops_is_path_whitelisted "$TARGET_PATH" \
  || { [[ -d "$TARGET_PATH" ]] && lab_ops_contains_whitelisted_path "$TARGET_PATH"; }; then
  echo "目标受白名单保护，不会压缩或删除: $TARGET_PATH"
  lab_ops_log "archive: target protected by whitelist path=$TARGET_PATH"
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

unique_archive_path() {
  local target="$1" candidate stamp
  candidate="${target}.tar.gz"
  if [[ ! -e "$candidate" ]]; then
    printf '%s' "$candidate"
    return
  fi
  stamp="$(date +%Y%m%d_%H%M%S)"
  printf '%s_%s.tar.gz' "$target" "$stamp"
}

latest_epoch_for_target() {
  local target="$1" target_epoch content_epoch latest_epoch
  target_epoch="$(stat -c "$STAT_FORMAT" "$target" 2>>"$ERR" || echo 0)"
  latest_epoch="$target_epoch"

  if [[ -d "$target" ]]; then
    content_epoch="$(
      find "$target" -xdev -type f -printf "${FIND_PRINTF}\n" 2>>"$ERR" \
        | awk 'BEGIN { max = 0 } { if (($1 + 0) > max) max = $1 + 0 } END { printf "%.0f\n", max }'
    )"
    if ((content_epoch > latest_epoch)); then
      latest_epoch="$content_epoch"
    fi
  fi

  printf '%s\n' "$latest_epoch"
}

TARGET_TYPE="文件"
[[ -d "$TARGET_PATH" ]] && TARGET_TYPE="文件夹"
LATEST_EPOCH="$(latest_epoch_for_target "$TARGET_PATH")"

if [[ ! "$LATEST_EPOCH" =~ ^[0-9]+$ ]] || ((LATEST_EPOCH <= 0)); then
  echo "错误：无法读取目标时间: $TARGET_PATH" >&2
  lab_ops_log "archive: unreadable timestamp target=$TARGET_PATH"
  exit 1
fi

LATEST_TIME="$(date -d "@${LATEST_EPOCH}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -r "$LATEST_EPOCH" '+%Y-%m-%d %H:%M:%S')"
SIZE="$(du -sb -- "$TARGET_PATH" 2>>"$ERR" | awk '{print $1}' || echo 0)"
ARCHIVE_PATH="$(unique_archive_path "$TARGET_PATH")"

lab_ops_log "archive: target=$TARGET_PATH type=$TARGET_TYPE days=$DAYS field=$TIME_FIELD report=$REPORT"

{
  echo ""
  echo "============================================================"
  echo "过期文件或文件夹检查"
  echo "检查目标: $TARGET_PATH"
  echo "目标类型: $TARGET_TYPE"
  echo "判断规则: 目标的最新${TIME_DESC}超过 ${DAYS} 天"
  if [[ -d "$TARGET_PATH" ]]; then
    echo "文件夹说明: 同时检查内部文件，任一文件近期使用都会保护整个文件夹"
  fi
  echo "目标最新${TIME_DESC}: $LATEST_TIME"
  echo "目标原始大小: $(human_size "$SIZE")"
  echo "计划压缩到: $ARCHIVE_PATH"
  echo "生成时间: $(date '+%Y-%m-%d %H:%M:%S')"
} | tee -a "$REPORT"

if ((LATEST_EPOCH >= CUTOFF_EPOCH)); then
  echo "检查结果: 目标未超过 ${DAYS} 天未使用，不进行压缩或删除。" | tee -a "$REPORT"
  lab_ops_log "archive: target not expired target=$TARGET_PATH latest_epoch=$LATEST_EPOCH"
  exit 0
fi

echo "检查结果: 目标已超过 ${DAYS} 天未使用，列为压缩候选。" | tee -a "$REPORT"
echo "确认后将生成压缩包并验证；只有验证成功才会删除原${TARGET_TYPE}。" | tee -a "$REPORT"

if [[ ! -t 0 ]]; then
  echo "当前不是交互式终端，自动返回，不压缩或删除目标。"
  lab_ops_log "archive: non-interactive terminal, cancelled target=$TARGET_PATH"
  exit 0
fi

answer=""
read -r -t 30 -p "确认压缩并删除原${TARGET_TYPE}吗？请输入 y 确认，30 秒未确认自动返回: " answer || true
echo ""
case "$answer" in
  y|Y|yes|YES)
    if [[ -L "$TARGET_PATH" || ( ! -f "$TARGET_PATH" && ! -d "$TARGET_PATH" ) ]]; then
      echo "目标已不存在或已变成软链接，操作取消: $TARGET_PATH" >&2
      lab_ops_log "archive: target disappeared or became symlink before execute target=$TARGET_PATH"
      exit 1
    fi

    if lab_ops_is_path_whitelisted "$TARGET_PATH" \
      || { [[ -d "$TARGET_PATH" ]] && lab_ops_contains_whitelisted_path "$TARGET_PATH"; }; then
      echo "目标现在受白名单保护，操作取消: $TARGET_PATH"
      lab_ops_log "archive: target became protected before execute target=$TARGET_PATH"
      exit 0
    fi

    # 扫描目录本身可能更新目录 atime，因此 atime + 文件夹使用首次扫描结果。
    if [[ "$TIME_FIELD" != "atime" || ! -d "$TARGET_PATH" ]]; then
      CURRENT_EPOCH="$(latest_epoch_for_target "$TARGET_PATH")"
      if ((CURRENT_EPOCH >= CUTOFF_EPOCH)); then
        echo "目标在确认前已被使用或修改，操作取消: $TARGET_PATH"
        lab_ops_log "archive: target became active before execute target=$TARGET_PATH"
        exit 0
      fi
    fi

    if tar -czf "$ARCHIVE_PATH" -C "$TARGET_PARENT" -- "$TARGET_NAME" 2>>"$ERR" \
      && tar -tzf "$ARCHIVE_PATH" >/dev/null 2>>"$ERR"; then
      if [[ -d "$TARGET_PATH" ]]; then
        remove_ok=1
        rm -rf -- "$TARGET_PATH" || remove_ok=0
      else
        remove_ok=1
        rm -f -- "$TARGET_PATH" || remove_ok=0
      fi
      if ((remove_ok == 0)); then
        echo "压缩包验证成功，但删除原${TARGET_TYPE}失败: $TARGET_PATH" | tee -a "$REPORT" >&2
        echo "压缩包已保留: $ARCHIVE_PATH" | tee -a "$REPORT" >&2
        lab_ops_log "archive: remove failed type=$TARGET_TYPE source=$TARGET_PATH archive=$ARCHIVE_PATH"
        exit 1
      fi
      {
        echo "已压缩并删除原${TARGET_TYPE}: $TARGET_PATH"
        echo "压缩包: $ARCHIVE_PATH"
      } | tee -a "$REPORT"
      lab_ops_log "archive: compressed_and_removed type=$TARGET_TYPE source=$TARGET_PATH archive=$ARCHIVE_PATH original_bytes=$SIZE"
    else
      rm -f -- "$ARCHIVE_PATH"
      echo "压缩或验证失败，已保留原${TARGET_TYPE}: $TARGET_PATH" | tee -a "$REPORT" >&2
      lab_ops_log "archive: failed type=$TARGET_TYPE source=$TARGET_PATH archive=$ARCHIVE_PATH"
      exit 1
    fi
    ;;
  *)
    echo "未确认或超时，已返回，不压缩或删除目标。"
    lab_ops_log "archive: cancelled or timeout target=$TARGET_PATH"
    ;;
esac
