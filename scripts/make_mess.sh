#!/usr/bin/env bash
# ============================================================================
# 混乱现场模拟脚本 — 组员 B (Docker / 日志运维)
# ============================================================================
# 用途: 在安全的测试目录中构造过期日志、冗余文件等"数字垃圾"，
#       供 log_cleanup.sh / docker_audit.sh / dedupe_hardlink.sh 测试使用。
#       不会影响系统真实文件，所有操作限定在可配置的 MESS_DIR 内。
#
# 用法:
#   ./make_mess.sh                 使用默认目录 (test/mess/)
#   ./make_mess.sh /tmp/test_mess  指定目标目录
#   ./make_mess.sh clean           清理生成的混乱数据
# ============================================================================

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MESS_DIR="${1:-$ROOT_DIR/test/mess}"

# ── 清理模式 ────────────────────────────────────────────────────────────────
if [[ "${1:-}" == "clean" ]]; then
  if [[ -d "$ROOT_DIR/test/mess" ]]; then
    echo "正在清理测试混乱数据: $ROOT_DIR/test/mess"
    rm -rf "$ROOT_DIR/test/mess"
    echo "已清理。"
    exit 0
  else
    echo "测试混乱数据目录不存在，无需清理。"
    exit 0
  fi
fi

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║       混乱现场模拟脚本 — 安全测试数据生成器                 ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo "  目标目录 : $MESS_DIR"
echo ""

# ── 创建目录结构 ────────────────────────────────────────────────────────────
mkdir -p "$MESS_DIR"/{logs,service_logs,old_runs,deep/nested/logs,empty_dir}

# ── 辅助函数：用旧时间戳创建文件 ────────────────────────────────────────────
# 参数: make_old_file <路径> <内容> <YYYYMMDDHHMM> [大小_KB]
make_old_file() {
  local path="$1"
  local content="${2:-dummy log content}"
  local fake_time="${3:-202401011200}"   # 默认 2024-01-01（距今远超 30 天）
  mkdir -p "$(dirname "$path")"
  echo "$content" > "$path"
  touch -t "$fake_time" "$path"
  echo "  ✓ $path (mtime=$(date -d "$fake_time" '+%Y-%m-%d' 2>/dev/null || echo "$fake_time"))"
}

# 生成指定大小的日志文件（单位 KB）
make_sized_old_file() {
  local path="$1"
  local size_kb="${2:-100}"
  local fake_time="${3:-202401011200}"
  mkdir -p "$(dirname "$path")"
  dd if=/dev/urandom of="$path" bs=1024 count="$size_kb" 2>/dev/null
  touch -t "$fake_time" "$path"
  local actual_size
  actual_size=$(du -h "$path" | cut -f1)
  echo "  ✓ $path (${actual_size}, mtime=faked)"
}

# ── 1. 过期系统日志（模拟 /var/log 中积压的旧日志）─────────────────────────
echo "── [1/6] 生成过期系统日志 ──"
make_old_file "$MESS_DIR/logs/syslog.1"           "[2024-01-01] system boot sequence..."           "202401011200"
make_old_file "$MESS_DIR/logs/syslog.2.gz"        "[2024-01-02] kernel: CPU thermal throttle..."    "202401021200"
make_old_file "$MESS_DIR/logs/kern.log.1"         "[2024-01-03] kernel: usb 1-3: new device..."    "202401031200"
make_old_file "$MESS_DIR/logs/auth.log.1"         "[2024-02-01] sshd: Accepted publickey..."        "202402011200"
make_old_file "$MESS_DIR/logs/dpkg.log.1"         "[2024-03-01] install ok installed..."            "202403011200"
make_old_file "$MESS_DIR/logs/apt/history.log"    "[2024-03-15] Commandline: apt install..."         "202403151200"
make_old_file "$MESS_DIR/logs/nginx/access.log.1" "[2024-04-01] GET /api/train 200 0.123..."        "202404011200"
make_old_file "$MESS_DIR/logs/nginx/error.log.1"  "[2024-04-01] upstream timed out..."              "202404011200"

# 一个较新的文件（不应被清理）
make_old_file "$MESS_DIR/logs/nginx/access.log"   "[2025-06-01] GET /status 200 ..."               "202506011200"

# ── 2. 用户训练产生的过期日志 ────────────────────────────────────────────────
echo ""
echo "── [2/6] 生成训练 / 服务过期日志 ──"
make_old_file "$MESS_DIR/service_logs/training_nohup.out"     "Epoch 1/100: loss=0.543\nEpoch 2/100: loss=0.321..."   "202401151200"
make_old_file "$MESS_DIR/service_logs/jupyter_old.log"        "[W 2024-02-01] NotebookApp: Kernel shutdown..."        "202402011200"
make_old_file "$MESS_DIR/service_logs/tensorboard_cache.log"  "[2024-03-01] TensorBoard 2.15.1 at http://..."          "202403011200"
make_old_file "$MESS_DIR/service_logs/pip_install.log"        "Successfully installed torch-2.1.0..."                  "202401101200"
make_old_file "$MESS_DIR/service_logs/docker_build.log"       "Step 1/10: FROM nvidia/cuda:12.1..."                    "202401201200"

# 当前仍在使用的日志（不应被清理）
make_old_file "$MESS_DIR/service_logs/current_run.out"        "[2025-06-15] Training in progress... epoch 45/100"     "202506151200"

# ── 3. 深层嵌套目录中的过期日志 ─────────────────────────────────────────────
echo ""
echo "── [3/6] 深层嵌套过期日志 ──"
make_old_file "$MESS_DIR/deep/nested/logs/old_experiment.log"   "experiment_42: final_accuracy=0.934"                  "202403011200"
make_old_file "$MESS_DIR/deep/nested/logs/dead_run.nohup"       "CUDA out of memory. Tried to allocate 2.00 GiB..."     "202404011200"
make_old_file "$MESS_DIR/old_runs/2023-fall/run_001.log"        "Run 001: lr=0.01 batch=64"                             "202310011200"
make_old_file "$MESS_DIR/old_runs/2023-fall/run_002.log"        "Run 002: lr=0.001 batch=128"                           "202310151200"
make_old_file "$MESS_DIR/old_runs/2024-spring/experiment_A.log" "Experiment A: transformer 6 layers"                    "202402011200"
make_old_file "$MESS_DIR/old_runs/2024-spring/experiment_B.log" "Experiment B: CNN ResNet-50"                           "202402151200"

# ── 4. Core dump 模拟文件 ───────────────────────────────────────────────────
echo ""
echo "── [4/6] 生成 Core Dump 模拟文件 ──"
make_sized_old_file "$MESS_DIR/logs/core.python.31415"       512  "202401151200"
make_sized_old_file "$MESS_DIR/logs/core.training.28901"     256  "202403011200"

# ── 5. 无扩展名日志 / 特殊文件名 ───────────────────────────────────────────
echo ""
echo "── [5/6] 边界情况文件 ──"
make_old_file "$MESS_DIR/logs/README"                        "This is a readme, not a log."                         "202401011200"
make_old_file "$MESS_DIR/logs/dotfile"                       "# hidden config"                                       "202401011200"
make_old_file "$MESS_DIR/service_logs/log with spaces.log"   "log file name has spaces"                             "202401011200"

# ── 6. 最近的文件（不应被清理，用于验证脚本不会误删）─────────────────────
echo ""
echo "── [6/6] 近期文件（不应被清理）──"
make_old_file "$MESS_DIR/logs/today_syslog.log"               "Today's fresh log entry..."                           "202506201200"
make_old_file "$MESS_DIR/service_logs/active_service.log"     "Service running normally..."                          "202506201200"

# ── 摘要 ────────────────────────────────────────────────────────────────────
TOTAL_FILES=$(find "$MESS_DIR" -type f | wc -l)
TOTAL_SIZE=$(du -sh "$MESS_DIR" | cut -f1)

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  混乱数据生成完毕！"
echo "  总文件数 : $TOTAL_FILES"
echo "  总大小   : $TOTAL_SIZE"
echo "  目录位置 : $MESS_DIR"
echo ""
echo "  ══ 快速测试指南 ══"
echo ""
echo "  1. 测试日志清理（预览模式）:"
echo "     ./scripts/log_cleanup.sh $MESS_DIR/logs 30"
echo ""
echo "  2. 测试日志清理（正式模式）:"
echo "     LAB_OPS_DRY_RUN=0 ./scripts/log_cleanup.sh $MESS_DIR/logs 30"
echo "     或: LAB_OPS_DRY_RUN=0 ./scripts/log_cleanup.sh $MESS_DIR 30 -y"
echo ""
echo "  3. 查看生成的文件时间戳:"
echo "     ls -la $MESS_DIR/logs/"
echo ""
echo "  4. 清理生成的混乱数据:"
echo "     ./scripts/make_mess.sh clean"
echo "═══════════════════════════════════════════════════════════════"
