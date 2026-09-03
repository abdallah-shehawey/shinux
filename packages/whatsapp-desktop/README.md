# whatsapp-desktop

WhatsApp Web in a window of its own, on Chromium: the desktop's own font, a tray
it hides into rather than quitting, and one notification per message with the
sender's picture on it.

The source lives at <https://github.com/abdallah-shehawey/whatsapp-desktop>.

This is the successor to the `whatsapp` package, which is the same idea on GTK4
and WebKitGTK. Both are kept: they install side by side and share nothing.

`src/` is not committed here. It is a copy of Electron, and the binary inside it
is past GitHub's 100 MB per-file limit — run `./refresh.sh` before `make build`.
