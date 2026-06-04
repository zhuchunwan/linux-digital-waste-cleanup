#!/usr/bin/env bash
# 简化版总程序：运行后显示 8 个功能，用户输入编号选择。

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$ROOT_DIR/../lib/common.sh"
lab_ops_load_config

prompt_dir() {
  local default_dir="${1:-$LAB_OPS_SCAN_ROOT}" input
  read -r -p "请输入文件夹路径 [默认: ${default_dir}]: " input || input=""
  printf '%s' "${input:-$default_dir}"
}

add_whitelist_path() {
  local input abs
  echo ""
  echo "当前文件白名单: $LAB_OPS_FILE_WHITELIST"
  if [[ -s "$LAB_OPS_FILE_WHITELIST" ]]; then
    echo "已有白名单内容:"
    grep -v '^[[:space:]]*#' "$LAB_OPS_FILE_WHITELIST" | sed '/^[[:space:]]*$/d' || true
  else
    echo "当前没有白名单路径。"
  fi
  echo ""
  read -r -p "请输入要加入白名单的文件或文件夹路径: " input || input=""
  if [[ -z "$input" ]]; then
    echo "未输入路径，返回菜单。"
    return 0
  fi
  abs="$(lab_ops_abs_path "$input")"
  if grep -Fxq "$abs" "$LAB_OPS_FILE_WHITELIST" 2>/dev/null; then
    echo "该路径已在白名单中: $abs"
    return 0
  fi
  printf '%s\n' "$abs" >>"$LAB_OPS_FILE_WHITELIST"
  echo "已加入白名单: $abs"
  echo "后续磁盘审计、重复文件清理、过期文件打包、日志清理都会跳过该路径。"
}

show_menu() {
  echo ""
  echo "╔══════════════════════════════════════════════════════════════╗"
  echo "║      实验室 Linux 数字垃圾治理系统                         ║"
  echo "╚══════════════════════════════════════════════════════════════╝"
  echo "报表目录 : $LAB_OPS_REPORT_DIR"
  echo "日志目录 : $LAB_OPS_LOG_DIR"
  echo "白名单   : $LAB_OPS_FILE_WHITELIST"
  echo ""
  echo "  1. 磁盘空间审计：显示文件夹下文件名称和大小"
  echo "  2. 重复文件清理：显示重复文件，30 秒内确认后删除重复副本"
  echo "  3. 白名单功能：手动添加不会被扫描或删除的文件/文件夹"
  echo "  4. 过期文件管理：超过 30 天未使用的文件自动打包压缩"
  echo "  5. Docker 资产巡检与回收"
  echo "  6. 构造测试混乱现场"
  echo "  7. 过期日志清理：自动删除 30 天之前的日志文件"
  echo "  8. 退出"
  echo ""
}

while true; do
  show_menu
  if ! read -r -p "请输入功能编号: " choice; then
    echo "未读取到输入，已退出。"
    exit 0
  fi
  case "$choice" in
    1)
      target="$(prompt_dir "$LAB_OPS_SCAN_ROOT")"
      "$ROOT_DIR/disk_audit_txt.sh" "$target"
      ;;
    2)
      target="$(prompt_dir "$LAB_OPS_SCAN_ROOT")"
      "$ROOT_DIR/dedupe_hardlink.sh" "$target"
      ;;
    3)
      add_whitelist_path
      ;;
    4)
      target="$(prompt_dir "$LAB_OPS_SCAN_ROOT")"
      "$ROOT_DIR/archive_cold_data.sh" "$target"
      ;;
    5)
      "$ROOT_DIR/docker_audit.sh"
      ;;
    6)
      target="$(prompt_dir "$LAB_OPS_HOME/test/mess")"
      "$ROOT_DIR/make_mess.sh" "$target"
      ;;
    7)
      "$ROOT_DIR/cleanup_logs.sh"
      ;;
    8)
      echo "已退出。"
      exit 0
      ;;
    *)
      echo "无效编号，请输入 1-8。"
      ;;
  esac
  echo ""
  read -r -p "按回车返回菜单，或输入 q 退出: " again || again="q"
  [[ "$again" == "q" || "$again" == "Q" ]] && exit 0
done
