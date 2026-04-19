-- send2tasks_auth.lua
--
-- OAuth 2.0 refresh-token based authentication for the Google Tasks API.
--
-- Google's "Limited Input Device" (device flow) only supports a tiny
-- set of scopes (openid, email, profile, Drive appdata/file, YouTube);
-- the Tasks scope is NOT allowed there, so we cannot sign in directly
-- from the e-reader. Instead the user obtains a refresh_token once
-- (via the OAuth Playground or a similar helper — see README.md) and
-- stores it in send2tasks_configuration.lua. This module is then used
-- to swap that long-lived refresh_token for short-lived access tokens
-- on demand.
--
-- Reference:
--   https://developers.google.com/identity/protocols/oauth2/web-server#offline
local http = require("socket.http")
local https = require("ssl.https")
local json = require("json")
local logger = require("logger")
local ltn12 = require("ltn12")
local socketutil = require("socketutil")
local url = require("socket.url")

local Auth = {}

local USER_AGENT = "KOReader send2tasks/1.0"

-- OAuth endpoints.
local TOKEN_URL  = "https://oauth2.googleapis.com/token"
local REVOKE_URL = "https://oauth2.googleapis.com/revoke"

-- Scope required to create and read tasks.
Auth.SCOPE = "https://www.googleapis.com/auth/tasks"

-- ---------------------------------------------------------------------------
-- Generic form-encoded POST helper
-- ---------------------------------------------------------------------------

-- Percent-encode a single value for application/x-www-form-urlencoded.
local function urlencode(value)
    if value == nil then return "" end
    return (url.escape(tostring(value)))
end

-- Build an x-www-form-urlencoded body from a {key=value,...} table. The
-- order is not important for the OAuth endpoints we call.
local function encodeForm(params)
    local parts = {}
    for k, v in pairs(params) do
        table.insert(parts, urlencode(k) .. "=" .. urlencode(v))
    end
    return table.concat(parts, "&")
end

local function safeJsonDecode(payload)
    if not payload or payload == "" then return nil end
    local ok, decoded = pcall(function() return json.decode(payload) end)
    if ok then return decoded end
    return nil
end

-- Perform a form POST and return ok(bool), decoded_body(table|nil),
-- err(string|nil), http_code(number|nil).
local function postForm(target_url, params)
    local body = encodeForm(params or {})
    local sink = {}

    https.cert_verify = false
    socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)

    local request_opts = {
        url = target_url,
        method = "POST",
        headers = {
            ["Content-Type"]   = "application/x-www-form-urlencoded",
            ["Content-Length"] = tostring(#body),
            ["Accept"]         = "application/json",
            ["User-Agent"]     = USER_AGENT,
        },
        source = ltn12.source.string(body),
        sink = ltn12.sink.table(sink),
    }

    local requester = target_url:match("^https://") and https.request or http.request
    local _, code, _, status = requester(request_opts)
    socketutil:reset_timeout()

    local response_body = table.concat(sink or {})
    local decoded = safeJsonDecode(response_body)

    if code == socketutil.TIMEOUT_CODE
        or code == socketutil.SSL_HANDSHAKE_CODE
        or code == socketutil.SINK_TIMEOUT_CODE then
        return false, nil, "Request timed out", nil
    end

    local numeric_code = tonumber(code)
    if numeric_code and numeric_code >= 200 and numeric_code < 300 then
        return true, decoded, nil, numeric_code
    end

    if decoded and decoded.error then
        local err_text = decoded.error_description or decoded.error
        return false, decoded, tostring(err_text), numeric_code
    end

    if not numeric_code then
        logger.warn("send2tasks: network error:", status or code)
        return false, nil, "Network error: " .. tostring(status or code), nil
    end

    return false, decoded, string.format("HTTP %s: %s", tostring(numeric_code), status or ""), numeric_code
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Exchange a refresh_token for a fresh access_token. Returns ok, data_or_err.
-- On success `data` has access_token and expires_in (seconds).
function Auth.refreshAccessToken(client_id, client_secret, refresh_token)
    if not refresh_token or refresh_token == "" then
        return false, "Missing refresh token"
    end
    local ok, decoded, err = postForm(TOKEN_URL, {
        client_id     = client_id,
        client_secret = client_secret,
        refresh_token = refresh_token,
        grant_type    = "refresh_token",
    })
    if not ok then return false, err or "Failed to refresh token" end
    if not decoded or not decoded.access_token then
        return false, "Unexpected refresh-token response"
    end
    return true, decoded
end

--- Revoke a token (access or refresh). Best-effort; returns ok, err.
function Auth.revokeToken(token)
    if not token or token == "" then return true end
    local ok, _decoded, err = postForm(REVOKE_URL, {
        token = token,
    })
    return ok, err
end

return Auth
