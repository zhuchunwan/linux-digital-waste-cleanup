#!/usr/bin/env bash
# Compatibility wrapper for the TXT disk audit report.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$ROOT_DIR/disk_audit_tsv.sh" "$@"
