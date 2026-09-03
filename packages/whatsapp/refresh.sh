#!/usr/bin/env bash
# Rebuild src/ from the whatsapp source tree.
#
# Unlike the shell-script packages in this repo, whatsapp is compiled, and the
# builder here only copies src/ verbatim. So the binary is staged ahead of time
# and committed; run this whenever the source changes, then `make bump`.
#
#   SRC=/path/to/whatsapp ./refresh.sh
set -euo pipefail

SRC="${SRC:-$HOME/My_Projects/whatsapp}"
PKG="$(cd "$(dirname "$0")" && pwd)"

[ -f "$SRC/Makefile" ] || { echo "no whatsapp source at $SRC" >&2; exit 1; }

make -C "$SRC" clean >/dev/null
make -C "$SRC" >/dev/null

rm -rf "$PKG/src"
make -C "$SRC" install DESTDIR="$PKG/src" PREFIX=/usr >/dev/null

# Autostart is shipped system-wide rather than written into a home directory,
# so the package can cleanly remove it again.
install -Dm644 "$SRC/data/io.github.shehawey.whatsapp-autostart.desktop" \
        "$PKG/src/etc/xdg/autostart/io.github.shehawey.whatsapp.desktop"
sed -i 's|@BINDIR@|/usr/bin|g' "$PKG/src/etc/xdg/autostart/io.github.shehawey.whatsapp.desktop"

echo "staged $(find "$PKG/src" -type f | wc -l) files into $PKG/src"
