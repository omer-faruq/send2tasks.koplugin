# Send to Google Tasks — KOReader plugin

Send quick notes and highlights from KOReader straight to **Google Tasks**,
using Google's official REST API.

![status](https://img.shields.io/badge/status-alpha-orange)

## Why Google Tasks instead of Google Keep?

Google Keep has **no public API**. The only way to reach it from a third-party
app is to reverse-engineer the internal protocol (as `gkeepapi` does in
Python), which is fragile and can break any time Google changes the
endpoints. Google Tasks, on the other hand, has a stable, documented REST
API — so this plugin should keep working for years.

For most "capture an idea / a quote / a follow-up from the book I'm
reading" use cases, a task is a better home anyway: you get due dates,
notification reminders on your phone, and full integration with Gmail
and Calendar.

## Features

- Send a note from the **Tools menu** or directly from the **highlight
  popup** (with the highlighted text auto-quoted in the notes field).
- Optional **due date** chooser (today / tomorrow / in 3 days / in 1 week).
- Automatic **retry when the device comes online** if you fire a task
  while offline.
- Multiple **Google accounts** (e.g. personal + work) — switch the active
  one from the gear icon inside the note screen.
- Multiple **task lists** per account — pick the default one from the
  settings menu or from the gear icon.
- **Automatic access-token refresh**: you sign in once on your PC, paste
  the refresh_token into the config, and KOReader trades it for short-lived
  access tokens on demand.
- One-tap **connection test** and **cache clear** from the settings menu.

## Why not sign in from the e-reader?

KOReader runs on e-ink readers that have no browser, so we cannot use
Google's regular redirect-based OAuth flow. Google does offer a
"Limited Input Device" (device flow) for exactly this situation, but
Google **restricts that flow to a tiny set of scopes** — openid, email,
profile, Drive appdata/file and YouTube. The Tasks scope is not on
that list, so attempts to use the device flow fail with:

> Invalid device flow scope: https://www.googleapis.com/auth/tasks

The workaround is a one-time sign-in on a regular computer that hands
back a long-lived **refresh_token**. You paste that token into
`send2tasks_configuration.lua`, and from then on everything works
hands-free.

## Files and prefix rule

All files (except `main.lua` and `_meta.lua`) are prefixed with
`send2tasks_` to comply with the KOReader plugin-development rule:

```
send2tasks.koplugin/
├── _meta.lua
├── main.lua
├── send2tasks_auth.lua                    -- OAuth 2.0 refresh-token exchange
├── send2tasks_api.lua                     -- Google Tasks REST client
├── send2tasks_note_dialog.lua             -- compose screen
├── send2tasks_settings.lua                -- settings + quick switch
├── send2tasks_configuration.sample.lua    -- template (copy me)
├── .gitignore
└── README.md
```

## 1. Create OAuth 2.0 credentials in Google Cloud

1. Open <https://console.cloud.google.com/> and create (or select) a
   project. Any name works.
2. **Enable the Google Tasks API**
   - *APIs & Services → Library*
   - Search for "Google Tasks API" and click *Enable*.
3. **Configure the OAuth consent screen**
   - *APIs & Services → OAuth consent screen*
   - User type: **External**
   - Fill the required fields (app name, support email, developer
     contact).
   - While the project is still in "Testing" mode, add your own Google
     account under *Audience → Test users*.
4. **Create OAuth client credentials**
   - *APIs & Services → Credentials → Create credentials → OAuth client ID*
   - Application type: **Web application**
     > ⚠️ Important: do *not* pick "TVs and Limited Input devices". The
     > device-flow OAuth clients do not support the Google Tasks scope.
   - Name: whatever you like (e.g. "KOReader send2tasks").
   - **Authorized redirect URIs**: add exactly
     ```
     https://developers.google.com/oauthplayground
     ```
     This is required so the OAuth Playground in step 2 can talk to
     your credentials.
5. Copy the generated **Client ID** (ends with
   `.apps.googleusercontent.com`) and **Client secret** (usually starts
   with `GOCSPX-`). You will need both in step 2.

## 2. Get a refresh_token via OAuth Playground

This is a one-off step performed on a regular computer. Google's
OAuth Playground acts as a trusted "consent browser" on your behalf.

1. Open <https://developers.google.com/oauthplayground> on your PC.
2. Click the **gear icon ⚙** in the top-right corner and open
   *OAuth 2.0 configuration*.
3. Check the box **Use your own OAuth credentials** and paste:
   - *OAuth Client ID*: the one you created in step 1.
   - *OAuth Client secret*: the one you created in step 1.
4. Close the gear panel.
5. In the left pane *Step 1 — Select & authorize APIs*, scroll to the
   text box at the bottom (below the API list), paste:
   ```
   https://www.googleapis.com/auth/tasks
   ```
   and click **Authorize APIs**.
6. Google asks you to sign in; use the Google account whose Tasks you
   want to post to. Approve the consent prompt.
7. You are taken to *Step 2 — Exchange authorization code for tokens*.
   Click **Exchange authorization code for tokens**.
8. A **Refresh token** value appears (starts with `1//0g`). Copy it.

Keep this window open or copy all three values (client_id,
client_secret, refresh_token) to a safe place — you are about to paste
them into the plugin.

## 3. Drop the credentials into the plugin

In the plugin folder (`plugins/send2tasks.koplugin/`) copy the sample
file:

```
cp send2tasks_configuration.sample.lua send2tasks_configuration.lua
```

Then edit `send2tasks_configuration.lua` and replace the three
placeholders:

```lua
return {
    default_account = "personal",
    accounts = {
        personal = {
            name          = "Personal",
            client_id     = "XXXXXXXX.apps.googleusercontent.com",
            client_secret = "GOCSPX-XXXXXXXX",
            refresh_token = "1//0gXXXXXXXX",
        },
    },
}
```

You can define more than one account (e.g. `work = { ... }` with its
own client_id / client_secret / refresh_token) and switch between them
from the gear icon on the compose screen.

## 4. Test the connection (optional but recommended)

From inside KOReader:

**Tools → Send note to Google Tasks → Settings → Test active account
connection**

You should see "Connected. Found N task list(s).". If it fails, see
the troubleshooting section below.

## 5. (Optional) Pick a default task list

**Tools → Send note to Google Tasks → Settings → Default task list**

Pick one of your existing Google Tasks lists. If a list you want
doesn't appear, create it in the Google Tasks web UI or mobile app and
then tap *Refresh list* in the picker.

If you never set a default, the plugin uses `@default` — Google's
primary "My Tasks" list.

## 6. Using the plugin

- **Tools → Send note to Google Tasks**
  Opens a compose screen. First line becomes the task title, the rest
  becomes the notes. Tap the **Due…** button to attach a due date, or
  leave it empty.
- **Highlight popup → Send to Google Tasks**
  The highlighted text is pre-filled inside the notes field with a
  suggested title derived from its first sentence. Edit to taste and
  hit **Send**.
- **Gear icon (top-left of compose screen)**
  - Switch the **active account** with one tap.
  - Change the **default task list**.
  - Toggle the highlight-menu button.
  - Toggle the "include book title/page in notes" option.

## Security notes

- The plugin stores `client_id`, `client_secret`, and `refresh_token`
  in plain text inside `send2tasks_configuration.lua`. The `.gitignore`
  already excludes that file so you won't accidentally commit it.
- Access tokens (short-lived, ~1 hour) are cached in
  `settings/send2tasks.lua` inside KOReader's config folder. You can
  delete that file any time to force a fresh access-token request.
- To revoke the plugin's access entirely, open
  <https://myaccount.google.com/permissions> on your PC and remove the
  app. You can then obtain a new refresh_token from the Playground and
  paste it back.

## Troubleshooting

- **"Account '…' is missing a refresh_token"**
  You copied the sample file but did not paste a real refresh_token
  yet. Follow step 2 and fill in the `refresh_token` field.
- **"Could not obtain an access token: invalid_grant"**
  The refresh_token was revoked (either you reset access from My
  Account, or Google rotated it after inactivity). Repeat step 2 and
  paste the new refresh_token.
- **"Could not obtain an access token: invalid_client"**
  The `client_id` / `client_secret` do not match a registered OAuth
  client. Double-check copy-paste; make sure you used the **Web
  application** type in Cloud Console and added
  `https://developers.google.com/oauthplayground` as an authorized
  redirect URI.
- **"Google Tasks API error (403): PERMISSION_DENIED"**
  The Google Tasks API isn't enabled on the project, or the scope you
  authorized was wrong. Revisit step 1 (enable Tasks API) and step 2
  (authorize `https://www.googleapis.com/auth/tasks`).
- **"Request timed out"**
  Device is offline or can't reach `oauth2.googleapis.com` /
  `tasks.googleapis.com`. Check Wi-Fi.
- **Plugin does nothing / refuses to open the note dialog**
  You probably haven't copied `send2tasks_configuration.sample.lua` to
  `send2tasks_configuration.lua` yet. The plugin stays dormant until
  the configuration file exists.

## License

Same as KOReader: GNU AGPLv3.
