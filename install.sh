#!/usr/bin/env bash
set -euo pipefail
BASE_DIR="${HOME}/.orbitbash"
SRC_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$BASE_DIR/lib" "$BASE_DIR/themes" "$BASE_DIR/auth" "$HOME/.local/bin"
# Keep the exact requested ~/.orbitbash layout.
install -m 755 "$SRC_DIR/orbitbash" "$BASE_DIR/orbitbash"
for f in "$SRC_DIR/lib/"*.sh; do install -m 600 "$f" "$BASE_DIR/lib/$(basename "$f")"; done
for f in "$SRC_DIR/themes/"*.theme; do install -m 600 "$f" "$BASE_DIR/themes/$(basename "$f")"; done
mkdir -p "$BASE_DIR/images" "$BASE_DIR/vps" "$BASE_DIR/trash" "$BASE_DIR/backups" "$BASE_DIR/exports" "$BASE_DIR/nodes" "$BASE_DIR/logs" "$BASE_DIR/run/lock" "$BASE_DIR/auth"
touch "$BASE_DIR/config"; chmod 600 "$BASE_DIR/config"
ln -sfn "$BASE_DIR/orbitbash" "$HOME/.local/bin/orbitbash"
printf 'OrbitBash installed at %s\n' "$BASE_DIR"
printf 'PATH link: %s\n' "$HOME/.local/bin/orbitbash"
printf 'Run: orbitbash --check\n'
printf 'The hosted one-line curl|bash command is intentionally left for your later hosting step.\n'
