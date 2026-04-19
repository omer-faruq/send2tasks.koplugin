-- Send to Google Tasks configuration
--
-- Copy this file to `send2tasks_configuration.lua` in the same folder
-- and fill in your OAuth 2.0 client id, client secret, and refresh
-- token. You can define as many "accounts" as you like (for example a
-- personal and a work Google account); the active one is chosen from
-- the settings menu or from the gear icon inside the note screen.
--
-- Why a refresh_token here?
-- -------------------------
-- Google's "Limited Input Device" OAuth flow (the one used for TVs and
-- e-readers) does NOT support the Google Tasks scope, so we cannot sign
-- in from the e-reader itself. Instead you perform a one-time sign-in
-- on a regular computer (via the OAuth Playground) which hands you back
-- a long-lived refresh_token; that token is what lives here. The plugin
-- then trades it for a short-lived access_token whenever it needs to
-- send a task.
--
-- ---------------------------------------------------------------------------
-- Step 1. Create an OAuth 2.0 client in Google Cloud Console
-- ---------------------------------------------------------------------------
-- 1. Open https://console.cloud.google.com/ and create (or pick) a
--    Google Cloud project.
-- 2. "APIs & Services" → "Library" → enable the **Google Tasks API**.
-- 3. "APIs & Services" → "OAuth consent screen":
--      - User type: "External"
--      - Fill in the minimal required fields (app name, support email,
--        developer contact).
--      - Under "Audience" → "Test users", add your own Google account
--        so you can sign in while the project is in "Testing" state.
-- 4. "APIs & Services" → "Credentials" → "Create credentials" → "OAuth
--    client ID":
--      - Application type: **Web application**
--        (important: NOT "TVs and Limited Input devices" — that flow
--         does not support the Tasks scope.)
--      - Name: whatever you like (e.g. "KOReader send2tasks").
--      - Authorized redirect URIs: add exactly
--            https://developers.google.com/oauthplayground
--        (this is required so the OAuth Playground can use your
--         credentials in step 2.)
-- 5. Copy the generated client_id (ends with
--    `.apps.googleusercontent.com`) and client_secret (usually starts
--    with `GOCSPX-`) into the fields below.
--
-- ---------------------------------------------------------------------------
-- Step 2. Obtain a refresh_token via OAuth Playground
-- ---------------------------------------------------------------------------
-- 1. Open https://developers.google.com/oauthplayground in a browser.
-- 2. Click the gear icon (⚙) on the top-right → "OAuth 2.0 configuration"
--    → tick "Use your own OAuth credentials".
--    Paste your client_id and client_secret there, then close the panel.
-- 3. In the left-hand "Select & authorize APIs" list, paste or type
--    this scope into the input field at the bottom and click
--    "Authorize APIs":
--        https://www.googleapis.com/auth/tasks
-- 4. Sign in with the Google account you want to post tasks to, and
--    grant access when prompted.
-- 5. On the next screen ("Step 2 / Exchange authorization code for
--    tokens"), click "Exchange authorization code for tokens".
-- 6. Copy the "Refresh token" value (it looks like
--    "1//0gXXX...") and paste it into the refresh_token field below.
--
-- You only need to do this once per account. Google rotates access
-- tokens automatically; the refresh_token is long-lived (until you
-- revoke it from https://myaccount.google.com/permissions).
--
-- ---------------------------------------------------------------------------
-- Fields
-- ---------------------------------------------------------------------------
-- For every account:
--   name          : friendly label shown in menus (optional).
--   client_id     : OAuth 2.0 client id (required).
--   client_secret : OAuth 2.0 client secret (required).
--   refresh_token : long-lived OAuth refresh token (required).
--
-- The `default_account` key controls which account is selected before
-- the user has chosen one manually. If it is missing or invalid, the
-- first account in the table is used.

local CONFIGURATION = {
    default_account = "personal",

    accounts = {
        personal = {
            name          = "Personal",
            client_id     = "REPLACE_WITH_YOUR_CLIENT_ID.apps.googleusercontent.com",
            client_secret = "REPLACE_WITH_YOUR_CLIENT_SECRET",
            refresh_token = "REPLACE_WITH_YOUR_REFRESH_TOKEN",
        },

        -- Example of a second account (uncomment and fill in to use):
        -- work = {
        --     name          = "Work",
        --     client_id     = "...apps.googleusercontent.com",
        --     client_secret = "GOCSPX-...",
        --     refresh_token = "1//0gXXX...",
        -- },
    },
}

return CONFIGURATION
