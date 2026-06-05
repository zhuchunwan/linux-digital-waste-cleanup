#!/usr/bin/env bash
# Shared helpers for lab-ops scripts (bash 4+).

set -euo pipefail

# 在由业务脚本 source 本文件后调用；用调用者的路径定位项目根（业务脚本位于 lab-ops/scripts/）
lab_ops_load_config() {
  local root
  root="$(cd "$(dirname "${BASH_SOURCE[1]}")/.." && pwd)"
  export LAB_OPS_HOME="$root"
  if [[ -f "$root/config/lab_ops.conf" ]]; then
    # shellcheck disable=SC1090
    source "$root/config/lab_ops.conf"
  elif [[ -f "$root/config/lab_ops.conf.example" ]]; then
    # shellcheck disable=SC1090
    source "$root/config/lab_ops.conf.example"
  fi
  LAB_OPS_SCAN_ROOT="${LAB_OPS_SCAN_ROOT:-$root/test}"
  LAB_OPS_REPORT_DIR="${LAB_OPS_REPORT_DIR:-$root/reports}"
  LAB_OPS_LOG_DIR="${LAB_OPS_LOG_DIR:-$root/logs}"
  LAB_OPS_DRY_RUN="${LAB_OPS_DRY_RUN:-1}"
  LAB_OPS_DEDUPE_MIN_BYTES="${LAB_OPS_DEDUPE_MIN_BYTES:-1024}"
  LAB_OPS_DOCKER_EXITED_DAYS="${LAB_OPS_DOCKER_EXITED_DAYS:-7}"
  LAB_OPS_DOCKER_WHITELIST="${LAB_OPS_DOCKER_WHITELIST:-$root/config/docker_whitelist.txt}"
  LAB_OPS_FILE_WHITELIST="${LAB_OPS_FILE_WHITELIST:-$root/config/file_whitelist.txt}"
  LAB_OPS_COLD_DAYS="${LAB_OPS_COLD_DAYS:-30}"
  LAB_OPS_COLD_TIME_FIELD="${LAB_OPS_COLD_TIME_FIELD:-atime}"
  LAB_OPS_LOG_RETENTION_DAYS="${LAB_OPS_LOG_RETENTION_DAYS:-30}"
  LAB_OPS_REPORT_RETENTION_DAYS="${LAB_OPS_REPORT_RETENTION_DAYS:-$LAB_OPS_LOG_RETENTION_DAYS}"
  LAB_OPS_LOG_TARGETS="${LAB_OPS_LOG_TARGETS:-$LAB_OPS_LOG_DIR}"
  mkdir -p "$LAB_OPS_REPORT_DIR" "$LAB_OPS_LOG_DIR" "$(dirname "$LAB_OPS_FILE_WHITELIST")"
  touch "$LAB_OPS_FILE_WHITELIST"
}

lab_ops_log() {
  local msg="[$(date -Iseconds)] $*"
  echo "$msg" | tee -a "${LAB_OPS_LOG_DIR}/lab_ops.log" >&2
}

lab_ops_report_path() {
  local name="$1"
  local day="${2:-$(date +%Y-%m-%d)}"
  local dir="${LAB_OPS_REPORT_DIR}/${day}"
  mkdir -p "$dir"
  printf '%s/%s\n' "$dir" "$name"
}

lab_ops_is_true() {
  [[ "$1" == "1" || "$1" == "true" || "$1" == "yes" ]]
}

lab_ops_abs_path() {
  local path="$1" dir base
  if command -v realpath >/dev/null 2>&1; then
    realpath -m "$path" 2>/dev/null && return 0
  fi
  dir="$(dirname "$path")"
  base="$(basename "$path")"
  if [[ -d "$dir" ]]; then
    printf '%s/%s\n' "$(cd "$dir" && pwd -P)" "$base"
  else
    printf '%s\n' "$path"
  fi
}

lab_ops_is_path_whitelisted() {
  local path="$1" abs line wl_abs
  [[ -f "${LAB_OPS_FILE_WHITELIST:-}" ]] || return 1
  abs="$(lab_ops_abs_path "$path")"
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" ]] && continue
    wl_abs="$(lab_ops_abs_path "$line")"
    if [[ "$abs" == "$wl_abs" || "$abs" == "$wl_abs/"* ]]; then
      return 0
    fi
  done <"$LAB_OPS_FILE_WHITELIST"
  return 1
}

lab_ops_contains_whitelisted_path() {
  local dir="$1" dir_abs line wl_abs
  [[ -f "${LAB_OPS_FILE_WHITELIST:-}" ]] || return 1
  dir_abs="$(lab_ops_abs_path "$dir")"
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" ]] && continue
    wl_abs="$(lab_ops_abs_path "$line")"
    if [[ "$wl_abs" == "$dir_abs" || "$wl_abs" == "$dir_abs/"* ]]; then
      return 0
    fi
  done <"$LAB_OPS_FILE_WHITELIST"
  return 1
}

# 二次确认机制：在非 dry-run 模式下强制要求用户交互确认
# 用法: lab_ops_confirm "提示信息" [timeout_seconds]
# 环境变量 LAB_OPS_FORCE=1 可跳过确认（供 cron 等无人值守场景）
# 返回 0=确认继续, 1=取消
lab_ops_confirm() {
  local prompt="${1:-是否继续执行？}"
  local timeout_sec="${2:-30}"

  # cron / 后台无人值守模式：通过环境变量跳过
  if lab_ops_is_true "${LAB_OPS_FORCE:-0}"; then
    lab_ops_log "确认: LAB_OPS_FORCE=1，跳过交互确认"
    return 0
  fi

  # 非交互式终端（如管道、cron）自动拒绝
  if [[ ! -t 0 ]]; then
    lab_ops_log "确认: 非交互式终端，自动拒绝。设置 LAB_OPS_FORCE=1 可跳过"
    return 1
  fi

  echo "" >&2
  echo "╔══════════════════════════════════════════════════════════════╗" >&2
  echo "║  ⚠  二次确认 - 预计清理清单已生成，请仔细检查报告内容    ║" >&2
  echo "╚══════════════════════════════════════════════════════════════╝" >&2
  echo "$prompt" >&2
  echo "" >&2

  local answer
  read -r -t "$timeout_sec" -p "确认执行以上操作? (y/N) [默认 N, ${timeout_sec}s 超时自动拒绝]: " answer 2>/dev/null || true

  if [[ -z "$answer" ]]; then
    echo "" >&2
    lab_ops_log "确认: 超时或空输入，操作已取消"
    return 1
  fi

  case "$(echo "$answer" | tr '[:upper:]' '[:lower:]')" in
    y|yes)
      lab_ops_log "确认: 用户已确认，继续执行"
      return 0
      ;;
    *)
      lab_ops_log "确认: 用户取消操作 (输入=$answer)"
      return 1
      ;;
  esac
}
