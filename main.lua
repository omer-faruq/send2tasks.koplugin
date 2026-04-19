-- send2tasks plugin entry point.
--
-- Responsibilities:
--   * Load the optional send2tasks_configuration.lua file that holds
--     OAuth 2.0 client ids/secrets for one or more Google accounts.
--   * Register a "Send note to Google Tasks" entry under the tools menu.
--   * Optionally inject a button into the highlight pop-up that lets
--     the user send the selected text (plus a note) to the active
--     account/task-list.
--   * Manage the OAuth refresh token life-cycle: store refresh tokens
--     obtained via the device flow, swap them for fresh access tokens,
--     and retry transparently on expiry.
--   * Expose helpers used by the UI modules (quick settings pop-up,
--     highlight refresh, task-list picker, authorize/revoke).
local DataStorage = require("datastorage")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local LuaSettings = require("luasettings")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local lfs = require("libs/libkoreader-lfs")
local _ = require("gettext")

local Auth = require("send2tasks_auth")
local NoteDialog = require("send2tasks_note_dialog")
local SettingsModule = require("send2tasks_settings")

-- ---------------------------------------------------------------------------
-- Configuration loading
-- ---------------------------------------------------------------------------

local PLUGIN_NAME = "send2tasks"
local PLUGIN_DIR = DataStorage:getDataDir() .. "/plugins/" .. PLUGIN_NAME .. ".koplugin/"
local CONFIG_FILE_PATH = PLUGIN_DIR .. "send2tasks_configuration.lua"
local SETTINGS_FILE = DataStorage:getSettingsDir() .. "/send2tasks.lua"
local HIGHLIGHT_BUTTON_ID = "send2tasks"

-- Refresh the access token this many seconds before the reported
-- expiry to avoid racing with the API.
local ACCESS_TOKEN_SKEW = 60

local function fileExists(path)
    return lfs.attributes(path, "mode") == "file"
end

local function loadConfigurationFile()
    if not fileExists(CONFIG_FILE_PATH) then
        return nil, nil
    end
    local ok, result = pcall(function() return dofile(CONFIG_FILE_PATH) end)
    if not ok then
        logger.warn("send2tasks: configuration load failed:", result)
        return nil, tostring(result)
    end
    if type(result) ~= "table" then
        return nil, "send2tasks_configuration.lua did not return a table."
    end
    return result, nil
end

local CONFIGURATION, CONFIG_ERROR = loadConfigurationFile()

-- ---------------------------------------------------------------------------
-- Plugin definition
-- ---------------------------------------------------------------------------

local Send2Tasks = InputContainer:extend{
    name = PLUGIN_NAME,
    is_doc_only = false,
    settings = nil,
    CONFIGURATION = nil,
}

-- ---------------------------------------------------------------------------
-- Settings helpers (LuaSettings wrapper)
-- ---------------------------------------------------------------------------

function Send2Tasks:readSetting(key, default)
    if not self.settings then
        self.settings = LuaSettings:open(SETTINGS_FILE)
    end
    local val = self.settings:readSetting(key)
    if val == nil then return default end
    return val
end

function Send2Tasks:saveSetting(key, value)
    if not self.settings then
        self.settings = LuaSettings:open(SETTINGS_FILE)
    end
    self.settings:saveSetting(key, value)
    self.settings:flush()
end

function Send2Tasks:onFlushSettings()
    if self.settings then self.settings:flush() end
end

-- Per-account settings are nested under `accounts.<id>` inside the
-- settings file. We keep a small helper table API so the rest of the
-- module does not juggle key paths.
function Send2Tasks:readAccountState(account_id, key, default)
    local all = self:readSetting("accounts", {}) or {}
    local bucket = all[account_id]
    if type(bucket) ~= "table" then return default end
    local val = bucket[key]
    if val == nil then return default end
    return val
end

function Send2Tasks:saveAccountState(account_id, key, value)
    local all = self:readSetting("accounts", {}) or {}
    if type(all[account_id]) ~= "table" then all[account_id] = {} end
    all[account_id][key] = value
    self:saveSetting("accounts", all)
end

function Send2Tasks:clearAccountState(account_id)
    local all = self:readSetting("accounts", {}) or {}
    all[account_id] = nil
    self:saveSetting("accounts", all)
end

function Send2Tasks:resetRememberedSettings()
    if not self.settings then
        self.settings = LuaSettings:open(SETTINGS_FILE)
    end
    self.settings:reset({})
    self.settings:flush()
    self:refreshHighlightButton()
end

function Send2Tasks:isConfigured()
    return self.CONFIGURATION ~= nil
end

-- ---------------------------------------------------------------------------
-- Account resolution (mirrors send2notion.getConfiguredTargets layout)
-- ---------------------------------------------------------------------------

-- Return a stable array of { id, label, account = <cfg> } entries.
function Send2Tasks:getConfiguredAccounts()
    if not self.CONFIGURATION then return {} end
    local accounts = self.CONFIGURATION.accounts
    if type(accounts) ~= "table" then return {} end
    local order = self.CONFIGURATION.account_order
    local seen = {}
    local result = {}

    local function append(key)
        if seen[key] or type(accounts[key]) ~= "table" then return end
        seen[key] = true
        local acc = accounts[key]
        local label = (type(acc.name) == "string" and acc.name ~= "") and acc.name or key
        table.insert(result, { id = key, label = label, account = acc })
    end

    if type(order) == "table" then
        for _, key in ipairs(order) do append(key) end
    end
    local remaining = {}
    for key in pairs(accounts) do
        if not seen[key] then table.insert(remaining, key) end
    end
    table.sort(remaining)
    for _, key in ipairs(remaining) do append(key) end
    return result
end

function Send2Tasks:getDefaultAccountId()
    if not self.CONFIGURATION then return nil end
    local default = self.CONFIGURATION.default_account
    if default and type(self.CONFIGURATION.accounts) == "table"
        and type(self.CONFIGURATION.accounts[default]) == "table" then
        return default
    end
    local configured = self:getConfiguredAccounts()
    if #configured > 0 then return configured[1].id end
    return nil
end

function Send2Tasks:getActiveAccountId()
    local stored = self:readSetting("active_account_id")
    if stored and self.CONFIGURATION
        and type(self.CONFIGURATION.accounts) == "table"
        and type(self.CONFIGURATION.accounts[stored]) == "table" then
        return stored
    end
    return self:getDefaultAccountId()
end

function Send2Tasks:setActiveAccountId(account_id)
    if not account_id then return end
    self:saveSetting("active_account_id", account_id)
end

-- Returns the active account config and its display label. Both are
-- `nil` when the plugin is not configured at all.
function Send2Tasks:getActiveAccount()
    local id = self:getActiveAccountId()
    if not id or not self.CONFIGURATION then return nil, nil, nil end
    local acc = self.CONFIGURATION.accounts and self.CONFIGURATION.accounts[id]
    if type(acc) ~= "table" then return nil, nil, nil end
    local label = (type(acc.name) == "string" and acc.name ~= "") and acc.name or id
    return acc, label, id
end

-- ---------------------------------------------------------------------------
-- OAuth token management
-- ---------------------------------------------------------------------------

-- Return the refresh_token configured for `account_id`, or nil when the
-- user has not pasted one into send2tasks_configuration.lua yet.
function Send2Tasks:getRefreshToken(account_id)
    if not account_id or not self.CONFIGURATION then return nil end
    local acc = self.CONFIGURATION.accounts and self.CONFIGURATION.accounts[account_id]
    if type(acc) ~= "table" then return nil end
    local rt = acc.refresh_token
    if type(rt) == "string" and rt ~= "" then return rt end
    return nil
end

function Send2Tasks:hasRefreshToken(account_id)
    return self:getRefreshToken(account_id) ~= nil
end

--- Return a still-valid access token for `account_id`, refreshing it on
-- the fly if the cached one has expired (or is missing). Returns
-- token_or_nil, err_or_nil.
function Send2Tasks:getValidAccessToken(account_id)
    if not account_id then return nil, "No account selected" end
    local acc = self.CONFIGURATION and self.CONFIGURATION.accounts
        and self.CONFIGURATION.accounts[account_id]
    if type(acc) ~= "table" then return nil, "Unknown account" end
    if not acc.client_id or acc.client_id == ""
        or not acc.client_secret or acc.client_secret == "" then
        return nil, "Account is missing OAuth client id/secret"
    end

    local refresh_token = self:getRefreshToken(account_id)
    if not refresh_token then
        return nil, "Account has no refresh_token in send2tasks_configuration.lua"
    end

    local access_token = self:readAccountState(account_id, "access_token")
    local expires_at = tonumber(self:readAccountState(account_id, "access_token_expires_at") or 0) or 0
    local now = os.time()
    if access_token and access_token ~= "" and expires_at - ACCESS_TOKEN_SKEW > now then
        return access_token, nil
    end

    local ok, data = Auth.refreshAccessToken(acc.client_id, acc.client_secret, refresh_token)
    if not ok then
        return nil, data or "Failed to refresh access token"
    end
    local new_token = data.access_token
    local new_expiry = now + (tonumber(data.expires_in) or 3600)
    self:saveAccountState(account_id, "access_token", new_token)
    self:saveAccountState(account_id, "access_token_expires_at", new_expiry)
    return new_token, nil
end

--- Drop the cached access_token for an account. The refresh_token lives
-- in the configuration file and is not touched; revoke it from Google's
-- side via https://myaccount.google.com/permissions if you want a full
-- reset.
function Send2Tasks:forgetAccountTokens(account_id)
    self:clearAccountState(account_id)
end

-- ---------------------------------------------------------------------------
-- Task-list helpers
-- ---------------------------------------------------------------------------

function Send2Tasks:getCachedTaskLists(account_id)
    return self:readAccountState(account_id, "task_lists", {}) or {}
end

function Send2Tasks:saveCachedTaskLists(account_id, lists)
    self:saveAccountState(account_id, "task_lists", lists or {})
end

function Send2Tasks:getDefaultTaskListId(account_id)
    local id = self:readAccountState(account_id, "default_list_id")
    if id and id ~= "" then return id end
    -- If nothing is saved yet, fall back to "@default" which Google
    -- resolves to the user's primary list.
    return "@default"
end

function Send2Tasks:setDefaultTaskListId(account_id, list_id)
    if not account_id or not list_id then return end
    self:saveAccountState(account_id, "default_list_id", list_id)
end

-- ---------------------------------------------------------------------------
-- UI wiring
-- ---------------------------------------------------------------------------

function Send2Tasks:ensureConfigured()
    if self:isConfigured() then return true end
    local lines = { _("Send to Google Tasks is not configured yet.") }
    if CONFIG_ERROR then
        table.insert(lines, "")
        table.insert(lines, CONFIG_ERROR)
    end
    table.insert(lines, "")
    table.insert(lines, _("Copy send2tasks_configuration.sample.lua to send2tasks_configuration.lua in the plugin folder and fill in your OAuth client id and client secret. See README.md for a step-by-step guide."))
    UIManager:show(InfoMessage:new{
        icon = "notice-warning",
        text = table.concat(lines, "\n"),
        timeout = 8,
    })
    return false
end

function Send2Tasks:openNoteDialog(highlighted_text)
    if not self:ensureConfigured() then return end
    NoteDialog.show(self, highlighted_text)
end

function Send2Tasks:showQuickSettings(refresh_callback)
    SettingsModule.showQuickSwitch(self, refresh_callback)
end

-- ---------------------------------------------------------------------------
-- Highlight button lifecycle
-- ---------------------------------------------------------------------------

function Send2Tasks:registerHighlightButton()
    if not self.ui or not self.ui.highlight or not self.ui.highlight.addToHighlightDialog then
        return
    end
    self.ui.highlight:addToHighlightDialog(HIGHLIGHT_BUTTON_ID, function(reader_highlight)
        return {
            text = _("Send to Google Tasks"),
            callback = function()
                local selected = reader_highlight and reader_highlight.selected_text
                local text = selected and selected.text or ""
                if reader_highlight and reader_highlight.highlight_dialog then
                    UIManager:close(reader_highlight.highlight_dialog)
                    reader_highlight.highlight_dialog = nil
                end
                if reader_highlight and reader_highlight.clear then
                    reader_highlight:clear()
                end
                self:openNoteDialog(text)
            end,
        }
    end)
end

function Send2Tasks:unregisterHighlightButton()
    if self.ui and self.ui.highlight and self.ui.highlight.removeFromHighlightDialog then
        self.ui.highlight:removeFromHighlightDialog(HIGHLIGHT_BUTTON_ID)
    end
end

function Send2Tasks:refreshHighlightButton()
    if not self.ui or not self.ui.highlight then return end
    local wants = self:readSetting("highlight_button_enabled", true)
    if wants then
        self:unregisterHighlightButton()
        self:registerHighlightButton()
    else
        self:unregisterHighlightButton()
    end
end

-- ---------------------------------------------------------------------------
-- Main menu registration
-- ---------------------------------------------------------------------------

function Send2Tasks:addToMainMenu(menu_items)
    menu_items.send2tasks = {
        sorting_hint = "tools",
        text = _("Send note to Google Tasks"),
        callback = function() self:openNoteDialog(nil) end,
        hold_callback = function()
            UIManager:show(InfoMessage:new{
                text = _("Opens a quick note screen. The gear icon inside lets you switch accounts and task lists."),
                timeout = 4,
            })
        end,
        sub_item_table_func = function()
            local items = {
                {
                    text = _("Write a new note…"),
                    callback = function() self:openNoteDialog(nil) end,
                },
                {
                    text = _("Settings"),
                    sub_item_table_func = function() return SettingsModule.buildMenu(self) end,
                    separator = true,
                },
            }
            return items
        end,
    }
end

-- ---------------------------------------------------------------------------
-- Dispatcher action (optional gesture binding)
-- ---------------------------------------------------------------------------

function Send2Tasks:onDispatcherRegisterActions()
    Dispatcher:registerAction("send2tasks_note", {
        category = "none",
        event = "Send2TasksOpenNote",
        title = _("Send note to Google Tasks"),
        general = true,
    })
end

function Send2Tasks:onSend2TasksOpenNote()
    self:openNoteDialog(nil)
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

function Send2Tasks:init()
    self.settings = LuaSettings:open(SETTINGS_FILE)
    self.CONFIGURATION = CONFIGURATION

    self:onDispatcherRegisterActions()

    if self.ui and self.ui.menu and self.ui.menu.registerToMainMenu then
        self.ui.menu:registerToMainMenu(self)
    end
end

function Send2Tasks:onReaderReady()
    self:refreshHighlightButton()
end

return Send2Tasks
