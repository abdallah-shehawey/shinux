# whatsapp

A small WhatsApp Web client for GTK4 + WebKitGTK 6.

It loads `web.whatsapp.com`, so it is the same client WhatsApp serves to a
browser — nothing here reimplements the protocol, and nothing puts an account
at risk.

Four things it fixes that the other Linux clients get wrong:

  * **Image paste.** WebKitGTK hands the page an empty `clipboardData` for
    images, so WhatsApp's own handler finds nothing and drops the paste. The
    clipboard is read on the GTK side instead.
  * **The user agent.** WebKitGTK's site-specific quirks rewrite it for
    whatsapp.com and beat anything the application sets, so WhatsApp believed it
    was talking to Safari on a Mac and offered a Mac download.
  * **Notifications.** WhatsApp Web suppresses them while it thinks the window
    is focused, so nothing arrived when the app was open in front of you.
  * **Emoji.** They are drawn from 152 sprite sheets, and nothing on the machine
    was keeping them — not WhatsApp's service worker, not WebKit's disk cache —
    so 4.7 MB came down again on every launch and the emoji panel sat full of
    blank squares until it finished. The client keeps them itself now: the first
    run downloads them once, every run after it draws emoji offline.

Starts hidden at login and lives in the tray; closing the window keeps it
connected. To stop it starting at login, remove
`/etc/xdg/autostart/io.github.shehawey.whatsapp.desktop`, or turn it off in your
desktop's startup applications.

Source: https://github.com/abdallah-shehawey/whatsapp
