#!/usr/bin/env bash
# Build a safe "messy lab" fixture tree for demos. Docker fixture creation is
# optional: set LAB_OPS_MAKE_DOCKER=1 and ensure a local busybox/alpine image.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${1:-$ROOT_DIR/../test/mess}"
TARGET="$(mkdir -p "$TARGET" && cd "$TARGET" && pwd -P)"

echo "Creating messy fixture under: $TARGET"

mkdir -p "$TARGET"/{datasets,models,logs,papers,images,tmp}

payload="$TARGET/datasets/shared_payload.bin"
dd if=/dev/zero of="$payload" bs=1024 count=2 status=none
cp "$payload" "$TARGET/datasets/shared_payload_copy.bin"
cp "$payload" "$TARGET/models/model_weight_duplicate.pt"

printf 'epoch,loss\n1,0.42\n2,0.33\n' >"$TARGET/datasets/train metrics.csv"
printf '{"task":"demo","ok":true}\n' >"$TARGET/datasets/config.json"
printf 'old service log\n' >"$TARGET/logs/service.log"
printf 'very old stderr\n' >"$TARGET/logs/train.err"
printf 'paper notes\n' >"$TARGET/papers/notes without extension"
printf 'temporary scratch\n' >"$TARGET/tmp/run scratch.tmp"

if command -v convert >/dev/null; then
  convert -size 4x4 xc:white "$TARGET/images/tiny.png" >/dev/null 2>&1 || true
else
  printf '\x89PNG\r\n\x1a\n' >"$TARGET/images/tiny.png"
fi

touch -a -d '45 days ago' "$TARGET/datasets/shared_payload_copy.bin" "$TARGET/logs/service.log" "$TARGET/logs/train.err" "$TARGET/tmp/run scratch.tmp" 2>/dev/null || true
touch -m -d '45 days ago' "$TARGET/datasets/shared_payload_copy.bin" "$TARGET/logs/service.log" "$TARGET/logs/train.err" "$TARGET/tmp/run scratch.tmp" 2>/dev/null || true

if [[ "${LAB_OPS_MAKE_DOCKER:-0}" == "1" ]]; then
  if command -v docker >/dev/null; then
    image=""
    if docker image inspect busybox >/dev/null 2>&1; then
      image="busybox"
    elif docker image inspect alpine >/dev/null 2>&1; then
      image="alpine"
    fi
    if [[ -n "$image" ]]; then
      docker create --name "lab_ops_dead_$(date +%s)" "$image" sh -c 'exit 0' >/dev/null
      docker volume create "lab_ops_orphan_$(date +%s)" >/dev/null
      echo "Docker fixtures created with image: $image"
    else
      echo "Docker enabled, but no local busybox/alpine image found; skipped Docker fixtures." >&2
    fi
  else
    echo "Docker command not found; skipped Docker fixtures." >&2
  fi
fi

echo "Messy fixture ready."
