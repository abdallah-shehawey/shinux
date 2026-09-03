#!/usr/bin/env bash
# Rebuild src/ from the whatsapp-desktop source tree.
#
# Unlike every other package here, src/ is NOT committed: it is a copy of
# Electron, and the 194 MB binary inside it is past GitHub's 100 MB per-file
# limit, so a push carrying it is refused outright. It is generated instead --
# run this before `make build`, on the machine that publishes.
#
#   SRC=/path/to/whatsapp-desktop ./refresh.sh
set -euo pipefail

SRC="${SRC:-$HOME/My_Projects/whatsapp-desktop}"
PKG="$(cd "$(dirname "$0")" && pwd)"
APP_ID="io.github.shehawey.whatsapp-desktop"

[ -f "$SRC/Makefile" ] || { echo "no whatsapp-desktop source at $SRC" >&2; exit 1; }

rm -rf "$PKG/src"
make -C "$SRC" install DESTDIR="$PKG/src" PREFIX=/usr >/dev/null

# Autostart is shipped system-wide rather than written into a home directory,
# so the package can cleanly remove it again.
install -Dm644 "$SRC/data/${APP_ID}-autostart.desktop" \
        "$PKG/src/etc/xdg/autostart/${APP_ID}.desktop"
sed -i 's|@BINDIR@|/usr/bin|g' "$PKG/src/etc/xdg/autostart/${APP_ID}.desktop"

echo "staged $(find "$PKG/src" -type f | wc -l) files, $(du -sh "$PKG/src" | cut -f1), into $PKG/src"
