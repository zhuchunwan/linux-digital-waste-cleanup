#!/usr/bin/env bash
# 修复 Windows 编辑后产生的 CRLF 行尾，确保在 WSL/Linux 下正常执行
# 用法: bash fix_crlf.sh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

echo "正在移除 Windows 风格行尾 (CRLF -> LF)..."

for f in lib/*.sh scripts/*.sh config/*.conf config/*.example crontab.example USAGE.txt; do
  if [[ -f "$f" ]]; then
    sed -i 's/\r$//' "$f"
    echo "  $f"
  fi
done

echo "完成。所有脚本已转换为 LF 行尾。"
chmod +x scripts/fix_crlf.sh
