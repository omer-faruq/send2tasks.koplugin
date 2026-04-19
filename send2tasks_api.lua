-- send2tasks_api.lua
--
-- Minimal Google Tasks REST API client. Only the handful of endpoints
-- needed by the plugin are exposed:
--   * listTaskLists : GET  /users/@me/lists
--   * createTask    : POST /lists/{tasklistId}/tasks
--
-- All requests go through HTTPS and carry an OAuth 2.0 bearer token
-- obtained by send2tasks_auth.lua. The caller is responsible for
-- refreshing that token before it expires (see main.lua:getValidAccessToken).
--
-- Reference:
--   https://developers.google.com/tasks/reference/rest
local http = require("socket.http")
local https = require("ssl.https")
local json = require("json")
local logger = require("logger")
local ltn12 = require("ltn12")
local socketutil = require("socketutil")

local Api = {}

local USER_AGENT = "KOReader send2tasks/1.0"
local API_HOST = "https://tasks.googleapis.com/tasks/v1"

-- ---------------------------------------------------------------------------
-- Low-level request plumbing
-- ---------------------------------------------------------------------------

local function safeJsonDecode(payload)
    if not payload or payload == "" then return nil end
    local ok, decoded = pcall(function() return json.decode(payload) end)
    if ok then return decoded end
    return nil
end

-- Perform an HTTPS request to the Tasks API. Returns ok(bool), decoded
-- body(table|nil), err(string|nil), http_code(number|nil).
-- `http_code` is returned so callers can detect 401 and trigger a token
-- refresh + single retry.
local function doRequest(access_token, method, path, body_table)
    if not access_token or access_token == "" then
        return false, nil, "Missing access token", nil
    end

    local target_url = API_HOST .. path
    local body = ""
    if body_table ~= nil then
        local ok_enc, encoded = pcall(json.encode, body_table)
        if not ok_enc then
            return false, nil, "Failed to encode request body", nil
        end
        body = encoded
    end

    local sink = {}
    https.cert_verify = false
    socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)

    local headers = {
        ["Authorization"]  = "Bearer " .. tostring(access_token),
        ["Accept"]         = "application/json",
        ["User-Agent"]     = USER_AGENT,
    }
    if body ~= "" then
        headers["Content-Type"]   = "application/json"
        headers["Content-Length"] = tostring(#body)
    end

    local request_opts = {
        url = target_url,
        method = method,
        headers = headers,
        sink = ltn12.sink.table(sink),
    }
    if body ~= "" then
        request_opts.source = ltn12.source.string(body)
    end

    local _, code, _, status = https.request(request_opts)
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

    -- Google returns { error = { code, message, status, ... } } on failures.
    if decoded and decoded.error then
        local msg = decoded.error.message or decoded.error.status or "API error"
        return false, decoded, string.format("Google Tasks API error (%s): %s",
            tostring(numeric_code or "?"), tostring(msg)), numeric_code
    end

    if not numeric_code then
        logger.warn("send2tasks: network error:", status or code)
        return false, nil, "Network error: " .. tostring(status or code), nil
    end

    return false, decoded, string.format("HTTP %s: %s", tostring(numeric_code), status or ""), numeric_code
end

-- ---------------------------------------------------------------------------
-- Public helpers
-- ---------------------------------------------------------------------------

--- Raw request exposed so the caller can implement a refresh-and-retry
-- loop when a 401 is returned without duplicating request plumbing.
function Api.rawRequest(access_token, method, path, body_table)
    return doRequest(access_token, method, path, body_table)
end

--- List the user's task lists. Returns ok, items_or_err where items is
-- an array of { id = "...", title = "..." } on success.
function Api.listTaskLists(access_token)
    local ok, decoded, err = doRequest(access_token, "GET", "/users/@me/lists", nil)
    if not ok then return false, err end
    local out = {}
    if decoded and type(decoded.items) == "table" then
        for _, item in ipairs(decoded.items) do
            table.insert(out, { id = item.id, title = item.title or item.id })
        end
    end
    return true, out
end

--- Create a new task. Returns ok, task_id_or_err.
-- Fields:
--   tasklist_id : required, one of the ids returned by listTaskLists
--                 (or the string "@default" for the user's default list).
--   title       : required, task title (short single-line text).
--   notes       : optional, free-form multi-line details.
--   due         : optional, RFC 3339 timestamp string (e.g.
--                 "2026-04-19T00:00:00.000Z"). Google Tasks stores the
--                 date portion only.
function Api.createTask(access_token, tasklist_id, title, notes, due)
    if not tasklist_id or tasklist_id == "" then
        return false, "Missing task list id"
    end
    if not title or title == "" then
        return false, "Task title is required"
    end

    local body = { title = title }
    if notes and notes ~= "" then body.notes = notes end
    if due and due ~= "" then body.due = due end

    local path = "/lists/" .. tasklist_id .. "/tasks"
    local ok, decoded, err = doRequest(access_token, "POST", path, body)
    if not ok then return false, err end
    return true, decoded and decoded.id or nil
end

--- Format a Unix timestamp as the RFC 3339 string Google Tasks expects
-- for the `due` field. Only the date portion is significant for Google
-- Tasks (time is always normalized to midnight UTC), so we use the
-- local date and zero out the time. Returns a string like
-- "2026-04-19T00:00:00.000Z".
function Api.formatDueDate(time)
    local date_str = os.date("%Y-%m-%d", time or os.time())
    return date_str .. "T00:00:00.000Z"
end

return Api
