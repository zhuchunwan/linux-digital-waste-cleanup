#!/usr/bin/env bash
# 内容感知：对目录下最多 N 个文件调用 file，输出 TSV: path<TAB>mime
# 用法: classify_by_magic.sh <目录> [最大文件数，默认 500]

set -euo pipefail

DIR="${1:?directory required}"
MAX="${2:-500}"

command -v file >/dev/null || {
  echo "file command missing" >&2
  exit 1
}

[[ -d "$DIR" ]] || {
  echo "not a directory: $DIR" >&2
  exit 1
}

find "$DIR" -type f 2>/dev/null | head -n "$MAX" | while IFS= read -r f; do
  mime="$(file -b --mime-type "$f" 2>/dev/null || echo unknown)"
  printf '%s\t%s\n' "$f" "$mime"
done
