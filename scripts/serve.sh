#!/usr/bin/env bash
# Serve docs/ locally so you can point a VM or container at the repository
# before anything is pushed.
set -euo pipefail
source "$(dirname "$0")/config.sh"
port="${1:-8099}"
info "serving ${OUT_DIR#"${ROOT_DIR}/"} on http://127.0.0.1:${port}  (Ctrl-C to stop)"
exec python3 -m http.server "${port}" --bind 0.0.0.0 --directory "${OUT_DIR}"
