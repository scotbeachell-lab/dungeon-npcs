# Dungeon NPCs

A small Godot 4 dungeon built from Kenney's **Mini Dungeon** kit (CC0). Human and orc NPCs wander around, chat, gossip, trade, brawl, sit on chairs and loot chests.
**Postie Pip**, the mail carrier (gold name, mail bag on their back), tells you when new Gmail arrives.
**Herald Hruk** (purple name, banner on their back) announces your Google Calendar events.

Open `project.godot` in Godot 4.3+ and press **F5**.

| Key | Action |
| --- | --- |
| WASD / arrow keys | Pan the camera |
| Q / E | Rotate the camera |
| Mouse wheel | Zoom |
| Tab / Esc | Follow the next NPC / free the camera |
| 1 / 2 | Spawn a human / an orc |

## Starting with Windows

A shortcut called **Dungeon NPCs** in your Startup folder launches the game when you sign in to Windows.
It runs with `-- --corner`, which makes the window small and puts it in the top-left corner.

To change its size or position, edit `%APPDATA%\Godot\app_userdata\Dungeon NPCs\window.cfg`:

```ini
[window]

width_percent=33    ; % of the desktop width
height_percent=33   ; % of the desktop height (not counting the taskbar)
x=0                 ; move right by this many pixels
y=0                 ; move down by this many pixels
```

- To open the Startup folder, press **Win + R** and type `shell:startup`.
- To stop it starting automatically, delete the shortcut there, or turn it off in **Task Manager → Startup apps**.
- The shortcut points at this project folder and at Godot in `Documents\Godot_v4.7.2-stable_mono_win64`. If you move either one, update the shortcut.

## Setting up Gmail for the mail carrier

The game reads your inbox over IMAP using a Google **App Password**.
It only looks at the sender and subject of unread mail. It opens the inbox read-only, so nothing is marked as read, moved or deleted.

1. Turn on **2-Step Verification** for your Google account: <https://myaccount.google.com/security>.
2. Create an App Password at <https://myaccount.google.com/apppasswords>. Name it something like "Dungeon NPCs" and copy the 16-character code.
3. Run the game once. That creates the settings file:

   `%APPDATA%\Godot\app_userdata\Dungeon NPCs\gmail.cfg`

   Paste that path into File Explorer's address bar to open the folder.
4. Open `gmail.cfg` in Notepad and fill it in:

   ```ini
   [gmail]

   email="you@gmail.com"
   app_password="abcd efgh ijkl mnop"
   check_every_seconds=60
   ```

5. Restart the game. The top-right corner shows the mail status (for example `Mail: 2 unread - checked 14:05`).
   On startup, Pip tells you how many unread emails are waiting. After that, Pip walks up and announces each new email's sender and subject, a banner appears, and the Godot window flashes in the taskbar.

**Keep `gmail.cfg` private.** Anyone with that app password can read your email.
To stop access, delete the app password at <https://myaccount.google.com/apppasswords>.
The file lives outside the project folder, so sharing or uploading the project won't include it.

Mail is only checked while the game is running.

## Setting up Google Calendar for the herald

The herald reads your calendar through its **secret iCal address**, a private read-only link. No password is needed.

1. Open <https://calendar.google.com> on a computer.
2. Click the **gear icon**, then **Settings**.
3. In the left sidebar under **Settings for my calendars**, click your calendar (usually your name).
4. Scroll to the bottom and find **Secret address in iCal format**. Click the copy icon. It looks like
   `https://calendar.google.com/calendar/ical/.../private-.../basic.ics`.
5. Open `%APPDATA%\Godot\app_userdata\Dungeon NPCs\calendar.cfg` in Notepad and paste it in:

   ```ini
   [calendar]

   ics_url="https://calendar.google.com/calendar/ical/.../basic.ics"
   remind_minutes_before=10
   ```

6. Restart the game. The top-right corner shows `Calendar: N upcoming - updated HH:MM`.

What the herald announces:

- **On startup**: how many events you have left today, the next one, and any all-day events.
- **Before each event** (10 minutes by default): "In 10 minutes: …", including the location if there is one.
- **When an event starts**: "Starting now: …".

The calendar is re-downloaded every 15 minutes. Repeating events, skipped dates and moved occurrences are handled.
Times are read in this computer's time zone.

**Keep the secret address private.** Anyone with it can see your calendar.
You can reset it from the same settings page, which turns off the old link.

### Troubleshooting

- **Calendar "download failed (HTTP 404)"**: the address is wrong or was reset. Copy it again.
- **Testing without Google Calendar**: `Godot.exe --path . -- --fake-calendar`

- **"not set up"**: `gmail.cfg` is missing the email or the app password.
- **"sign-in failed"**: the app password is wrong or was revoked. Use an app password, not your normal Google password.
- **Testing without Gmail**: run with fake mail:
  `Godot.exe --path . -- --fake-mail`
