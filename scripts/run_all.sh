#!/usr/bin/env bash
# 串起：磁盘审计 ->（可选）去重 -> Docker 巡检 ->（可选）日志清理；建议由 cron 在凌晨调用
# 环境变量与配置见 config/lab_ops.conf.example
#
# 用法:
#   ./run_all.sh [目录]           默认扫描目录，交互确认
#   ./run_all.sh [目录] -y        跳过确认，直接执行（供 cron 使用）
#   ./run_all.sh [目录] --yes     同上
#   ./run_all.sh [目录] --force   同上（同时设置 LAB_OPS_FORCE=1）
#
# 二次确认机制:
#   Dry-run 模式 (LAB_OPS_DRY_RUN=1): 仅生成报表，不执行实际操作，无需确认
#   正式模式   (LAB_OPS_DRY_RUN=0): 生成报表后，需用户确认才执行清理操作
#   Cron 无人值守: 设置 LAB_OPS_FORCE=1 或传 -y 参数跳过确认

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$ROOT_DIR/../lib/common.sh"
lab_ops_load_config

# 解析命令行参数
SCAN="${1:-$LAB_OPS_SCAN_ROOT}"
shift 2>/dev/null || true
AUTO_YES=0
for arg in "$@"; do
  case "$arg" in
    -y|--yes|--force)
      AUTO_YES=1
      export LAB_OPS_FORCE=1
      ;;
    *)
      SCAN="$arg"
      ;;
  esac
done

lab_ops_log "run_all: start scan_root=$SCAN dry_run=$LAB_OPS_DRY_RUN"

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║      实验室 Linux 数字垃圾深度治理与自动化运维流水线      ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo "  扫描目录 : $SCAN"
echo "  报表目录 : $LAB_OPS_REPORT_DIR"
echo "  日志目录 : $LAB_OPS_LOG_DIR"
echo "  运行模式 : $([[ "$LAB_OPS_DRY_RUN" == "1" ]] && echo 'DRY-RUN (仅预览报表，不执行实际操作)' || echo '正式模式 (将执行清理操作!)')"
echo "  文件去重 : $([[ "${LAB_OPS_RUN_DEDUPE:-0}" == "1" ]] && echo '启用' || echo '跳过')"
echo "  Docker巡检: $([[ "${LAB_OPS_RUN_DOCKER:-1}" == "1" ]] && echo '启用' || echo '跳过')"
echo "  日志清理 : $([[ "${LAB_OPS_RUN_LOG_CLEANUP:-0}" == "1" ]] && echo '启用' || echo '跳过')"
echo ""

# ============================================================
# 步骤 1: 磁盘审计（始终执行，生成 TSV 报表，纯只读安全）
# ============================================================
lab_ops_log "run_all: [1/3] 磁盘审计..."
if command -v ionice >/dev/null; then
  nice -n 10 ionice -c2 -n7 "$ROOT_DIR/disk_audit_tsv.sh" "$SCAN"
else
  nice -n 10 "$ROOT_DIR/disk_audit_tsv.sh" "$SCAN"
fi
echo "  ✓ 磁盘审计报表已生成"

# ============================================================
# 二次确认（仅在正式模式下，在实际执行清理前进行）
# ============================================================
if ! lab_ops_is_true "$LAB_OPS_DRY_RUN"; then
  echo ""
  echo "────────────────────────────────────────────────────────────"
  echo "  预计清理操作:"
  echo "    磁盘审计报表: ${LAB_OPS_REPORT_DIR}/disk_usage_*.tsv"

  if [[ "${LAB_OPS_RUN_DEDUPE:-0}" == "1" ]]; then
    echo "    文件去重计划: ${LAB_OPS_LOG_DIR}/dedupe_plan.log"
    echo "    → 将对重复文件执行硬链接替换 (ln -f)"
  fi

  if [[ "${LAB_OPS_RUN_DOCKER:-1}" == "1" ]]; then
    echo "    Docker 审计报告: ${LAB_OPS_REPORT_DIR}/docker_audit_*.txt"
    echo "    → 将清理超期退出容器 / 虚悬镜像 / 僵尸数据卷"
  fi

  if [[ "${LAB_OPS_RUN_LOG_CLEANUP:-0}" == "1" ]]; then
    echo "    日志清理报告: ${LAB_OPS_REPORT_DIR}/log_cleanup_*.tsv"
    echo "    → 将清理超过 ${LAB_OPS_LOG_RETENTION_DAYS:-30} 天的过期日志文件"
  fi

  echo "    运行日志: ${LAB_OPS_LOG_DIR}/lab_ops.log"
  echo "────────────────────────────────────────────────────────────"
  echo ""

  if [[ "$AUTO_YES" == "0" ]]; then
    lab_ops_confirm "即将对 [$SCAN] 目录执行实际的清理操作。
⚠ 请先确认上述报告内容无误。
   若需要先预览，请设置 LAB_OPS_DRY_RUN=1 重新运行。" 45 || {
      lab_ops_log "run_all: 用户取消操作，流水线终止"
      echo "  操作已取消。建议先以 DRY_RUN=1 模式运行预览报表。"
      exit 0
    }
  else
    lab_ops_log "run_all: -y/--force 模式，跳过交互确认"
  fi
  echo ""
fi

# ============================================================
# 步骤 2: 文件去重（可选）
# ============================================================
if [[ "${LAB_OPS_RUN_DEDUPE:-0}" == "1" ]]; then
  lab_ops_log "run_all: [2/3] 文件去重..."
  "$ROOT_DIR/dedupe_hardlink.sh" "$SCAN"
  echo "  ✓ 文件去重完成 (dry_run=$LAB_OPS_DRY_RUN)"
fi

# ============================================================
# 步骤 3: Docker 巡检
# ============================================================
if [[ "${LAB_OPS_RUN_DOCKER:-1}" == "1" ]]; then
  lab_ops_log "run_all: [3/4] Docker 巡检..."
  "$ROOT_DIR/docker_audit.sh"
  echo "  ✓ Docker 巡检完成 (dry_run=$LAB_OPS_DRY_RUN)"
fi

# ============================================================
# 步骤 4: 日志清理（可选，默认关闭；组员 B 负责）
# ============================================================
if [[ "${LAB_OPS_RUN_LOG_CLEANUP:-0}" == "1" ]]; then
  lab_ops_log "run_all: [4/4] 日志清理..."
  "$ROOT_DIR/log_cleanup.sh" "$SCAN" "${LAB_OPS_LOG_RETENTION_DAYS:-30}"
  echo "  ✓ 日志清理完成 (dry_run=$LAB_OPS_DRY_RUN)"
fi

lab_ops_log "run_all: done."
echo ""
echo "  流水线执行完毕。"
