-- send2tasks_settings.lua
--
-- Builds the settings user interface. Two entry points are exposed:
--   * `Settings.showQuickSwitch` : small pop-up opened from the gear icon
--     on the note screen. Lets the user pick the active account, the
--     default task list, and toggle the most commonly used options.
--   * `Settings.buildMenu`       : list of menu entries injected into
--     the plugin's main menu under Tools.
--
-- Since the Google Tasks scope is not available through the OAuth 2.0
-- device flow, the user obtains a refresh_token once (via OAuth
-- Playground; see README.md) and stores it in
-- send2tasks_configuration.lua. This module therefore only manages
-- UI around picking the active account, choosing a default task list,
-- and testing the connection; the actual token exchange lives in
-- send2tasks_auth.lua and is driven by main.lua.
local Blitbuffer = require("ffi/blitbuffer")
local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local Notification = require("ui/widget/notification")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local T = require("ffi/util").template

local Api = require("send2tasks_api")

local Settings = {}

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function currentListLabel(plugin, account_id)
    local list_id = plugin:getDefaultTaskListId(account_id)
    local lists = plugin:getCachedTaskLists(account_id) or {}
    for _, item in ipairs(lists) do
        if item.id == list_id then return item.title or item.id end
    end
    if list_id == "@default" then return _("(default list)") end
    return list_id or _("(default list)")
end

local function accountRowMarker(is_active) return is_active and "◉ " or "○ " end

-- ---------------------------------------------------------------------------
-- "Missing refresh_token" guidance
-- ---------------------------------------------------------------------------

-- Shown whenever an action requires a refresh_token but none is
-- configured. The user cannot fix this from inside KOReader — they
-- need to edit the configuration file — so we point them at README.md.
local function showRefreshTokenMissing(label)
    local text
    if label then
        text = T(_("Account '%1' is missing a refresh_token.\n\nOpen send2tasks_configuration.lua and paste the refresh_token obtained from OAuth Playground (see README.md)."), label)
    else
        text = _("No refresh_token is configured.\n\nOpen send2tasks_configuration.lua and paste the refresh_token obtained from OAuth Playground (see README.md).")
    end
    UIManager:show(InfoMessage:new{
        icon = "notice-warning",
        text = text,
        timeout = 8,
    })
end

-- ---------------------------------------------------------------------------
-- Task list fetch + picker
-- ---------------------------------------------------------------------------

local function refreshTaskLists(plugin, account_id, on_done)
    local token, err = plugin:getValidAccessToken(account_id)
    if not token then
        if on_done then on_done(false, err) end
        return
    end
    Trapper:wrap(function()
        local trap = InfoMessage:new{
            text = _("Fetching task lists…"),
            timeout = nil,
        }
        UIManager:show(trap)
        local ok, lists = Api.listTaskLists(token)
        UIManager:close(trap)
        if not ok then
            if on_done then on_done(false, lists) end
            return
        end
        plugin:saveCachedTaskLists(account_id, lists)
        if on_done then on_done(true, lists) end
    end)
end

local function showTaskListPicker(plugin, account_id, after_pick)
    if not plugin:hasRefreshToken(account_id) then
        local _acc, label = plugin:getActiveAccount()
        showRefreshTokenMissing(label)
        return
    end
    local function build(lists)
        local dialog
        local current_id = plugin:getDefaultTaskListId(account_id)
        local buttons = {}
        if #lists == 0 then
            table.insert(buttons, { {
                text = _("No task lists found"),
                background = Blitbuffer.COLOR_WHITE,
                enabled = false,
                callback = function() end,
            } })
        end
        for _, item in ipairs(lists) do
            local marker = item.id == current_id and "◉ " or "○ "
            table.insert(buttons, { {
                text = marker .. (item.title or item.id),
                background = Blitbuffer.COLOR_WHITE,
                callback = function()
                    plugin:setDefaultTaskListId(account_id, item.id)
                    UIManager:close(dialog)
                    if after_pick then after_pick() end
                end,
            } })
        end
        table.insert(buttons, { {
            text = _("Refresh list"),
            background = Blitbuffer.COLOR_WHITE,
            callback = function()
                UIManager:close(dialog)
                refreshTaskLists(plugin, account_id, function(ok, result)
                    if not ok then
                        UIManager:show(InfoMessage:new{
                            icon = "notice-warning",
                            text = T(_("Could not fetch task lists:\n%1"),
                                result or _("unknown error")),
                            timeout = 6,
                        })
                        return
                    end
                    showTaskListPicker(plugin, account_id, after_pick)
                end)
            end,
        } })
        table.insert(buttons, { {
            text = _("Close"),
            background = Blitbuffer.COLOR_WHITE,
            callback = function() UIManager:close(dialog) end,
        } })
        dialog = ButtonDialog:new{
            title = _("Default task list"),
            title_align = "center",
            buttons = buttons,
        }
        UIManager:show(dialog)
    end

    local cached = plugin:getCachedTaskLists(account_id)
    if cached and #cached > 0 then
        build(cached)
    else
        refreshTaskLists(plugin, account_id, function(ok, result)
            if not ok then
                UIManager:show(InfoMessage:new{
                    icon = "notice-warning",
                    text = T(_("Could not fetch task lists:\n%1"),
                        result or _("unknown error")),
                    timeout = 6,
                })
                return
            end
            build(result or {})
        end)
    end
end

-- ---------------------------------------------------------------------------
-- Quick-switch pop-up (gear icon inside the note dialog)
-- ---------------------------------------------------------------------------

local function buildAccountRadioRows(plugin, on_selected)
    local accounts = plugin:getConfiguredAccounts()
    local active_id = plugin:getActiveAccountId()
    local rows = {}
    if #accounts == 0 then
        table.insert(rows, { {
            text = _("No accounts configured"),
            background = Blitbuffer.COLOR_WHITE,
            enabled = false,
            callback = function() end,
        } })
        return rows
    end
    for _, entry in ipairs(accounts) do
        local row = { {
            text = accountRowMarker(entry.id == active_id) .. entry.label,
            background = Blitbuffer.COLOR_WHITE,
            callback = function()
                plugin:setActiveAccountId(entry.id)
                if on_selected then on_selected() end
            end,
        } }
        table.insert(rows, row)
    end
    return rows
end

function Settings.showQuickSwitch(plugin, refresh_callback)
    local dialog
    local buttons = {}

    table.insert(buttons, { {
        text = _("Switch active account"),
        background = Blitbuffer.COLOR_WHITE,
        enabled = false,
        callback = function() end,
    } })

    local account_rows = buildAccountRadioRows(plugin, function()
        UIManager:close(dialog)
        if refresh_callback then refresh_callback() end
    end)
    for _, row in ipairs(account_rows) do
        table.insert(buttons, row)
    end

    local _acc, label, active_id = plugin:getActiveAccount()
    if active_id and plugin:hasRefreshToken(active_id) then
        table.insert(buttons, { {
            text = T(_("List: %1"), currentListLabel(plugin, active_id)),
            background = Blitbuffer.COLOR_WHITE,
            callback = function()
                UIManager:close(dialog)
                showTaskListPicker(plugin, active_id, function()
                    if refresh_callback then refresh_callback() end
                end)
            end,
        } })
    elseif active_id then
        table.insert(buttons, { {
            text = _("⚠ Paste refresh_token in config"),
            background = Blitbuffer.COLOR_WHITE,
            callback = function()
                UIManager:close(dialog)
                showRefreshTokenMissing(label)
            end,
        } })
    end

    local hl_enabled = plugin:readSetting("highlight_button_enabled", true)
    table.insert(buttons, { {
        text = hl_enabled and _("✓ Show button in highlight menu")
            or _("☐ Show button in highlight menu"),
        background = Blitbuffer.COLOR_WHITE,
        callback = function()
            plugin:saveSetting("highlight_button_enabled", not hl_enabled)
            plugin:refreshHighlightButton()
            UIManager:close(dialog)
            Settings.showQuickSwitch(plugin, refresh_callback)
        end,
    } })

    local include_ctx = plugin:readSetting("include_book_context", true)
    table.insert(buttons, { {
        text = include_ctx and _("✓ Include book title/page in notes")
            or _("☐ Include book title/page in notes"),
        background = Blitbuffer.COLOR_WHITE,
        callback = function()
            plugin:saveSetting("include_book_context", not include_ctx)
            UIManager:close(dialog)
            Settings.showQuickSwitch(plugin, refresh_callback)
        end,
    } })

    table.insert(buttons, { {
        text = _("Close"),
        background = Blitbuffer.COLOR_WHITE,
        callback = function() UIManager:close(dialog) end,
    } })

    dialog = ButtonDialog:new{
        title = _("Send to Google Tasks · quick settings"),
        title_align = "center",
        buttons = buttons,
    }
    UIManager:show(dialog)
end

-- ---------------------------------------------------------------------------
-- Test current account
-- ---------------------------------------------------------------------------

function Settings.testActiveAccount(plugin)
    local _acc, label, account_id = plugin:getActiveAccount()
    if not account_id then
        UIManager:show(InfoMessage:new{
            text = _("No active account. Edit send2tasks_configuration.lua first."),
            timeout = 4,
        })
        return
    end
    if not plugin:hasRefreshToken(account_id) then
        showRefreshTokenMissing(label)
        return
    end

    Trapper:wrap(function()
        local trap = InfoMessage:new{
            text = T(_("Contacting Google as %1…"), label),
            timeout = nil,
        }
        UIManager:show(trap)
        local token, err = plugin:getValidAccessToken(account_id)
        if not token then
            UIManager:close(trap)
            UIManager:show(InfoMessage:new{
                icon = "notice-warning",
                text = T(_("Could not obtain an access token:\n%1"), err or _("unknown error")),
                timeout = 6,
            })
            return
        end
        local ok, lists = Api.listTaskLists(token)
        UIManager:close(trap)
        if not ok then
            UIManager:show(InfoMessage:new{
                icon = "notice-warning",
                text = T(_("Could not reach Google Tasks:\n%1"), lists or _("unknown error")),
                timeout = 6,
            })
            return
        end
        plugin:saveCachedTaskLists(account_id, lists)
        local n = (type(lists) == "table") and #lists or 0
        UIManager:show(InfoMessage:new{
            text = T(_("Connected. Found %1 task list(s)."), tostring(n)),
            timeout = 4,
        })
    end)
end

-- ---------------------------------------------------------------------------
-- Main menu entries
-- ---------------------------------------------------------------------------

function Settings.buildMenu(plugin)
    local items = {}

    -- Active account picker.
    table.insert(items, {
        text_func = function()
            local _acc, label = plugin:getActiveAccount()
            if label then return T(_("Active account: %1"), label) end
            return _("Active account: (none)")
        end,
        sub_item_table_func = function()
            local sub = {}
            local accounts = plugin:getConfiguredAccounts()
            if #accounts == 0 then
                table.insert(sub, {
                    text = _("No accounts configured. Edit send2tasks_configuration.lua."),
                    enabled = false,
                })
                return sub
            end
            for _, entry in ipairs(accounts) do
                local acc_id = entry.id
                local acc_label = entry.label
                table.insert(sub, {
                    text_func = function()
                        local is_active = plugin:getActiveAccountId() == acc_id
                        return accountRowMarker(is_active) .. acc_label
                    end,
                    callback = function(touchmenu_instance)
                        plugin:setActiveAccountId(acc_id)
                        if touchmenu_instance then touchmenu_instance:updateItems() end
                    end,
                    keep_menu_open = true,
                })
            end
            return sub
        end,
        keep_menu_open = true,
    })

    -- Default task list for the active account.
    table.insert(items, {
        text_func = function()
            local _acc, _label, active_id = plugin:getActiveAccount()
            if not active_id then return _("Default task list: (no account)") end
            if not plugin:hasRefreshToken(active_id) then
                return _("Default task list: (no refresh_token)")
            end
            return T(_("Default task list: %1"), currentListLabel(plugin, active_id))
        end,
        callback = function(touchmenu_instance)
            local _acc, label, active_id = plugin:getActiveAccount()
            if not active_id then
                UIManager:show(InfoMessage:new{
                    text = _("Select an active account first."),
                    timeout = 3,
                })
                return
            end
            if not plugin:hasRefreshToken(active_id) then
                showRefreshTokenMissing(label)
                return
            end
            showTaskListPicker(plugin, active_id, function()
                if touchmenu_instance then touchmenu_instance:updateItems() end
            end)
        end,
        keep_menu_open = true,
    })

    -- Highlight-menu toggle.
    table.insert(items, {
        text_func = function()
            local on = plugin:readSetting("highlight_button_enabled", true)
            return on and _("Show button in highlight menu: on")
                or _("Show button in highlight menu: off")
        end,
        callback = function(touchmenu_instance)
            local cur = plugin:readSetting("highlight_button_enabled", true)
            plugin:saveSetting("highlight_button_enabled", not cur)
            plugin:refreshHighlightButton()
            if touchmenu_instance then touchmenu_instance:updateItems() end
        end,
        keep_menu_open = true,
    })

    -- Include book title/page in notes.
    table.insert(items, {
        text_func = function()
            local on = plugin:readSetting("include_book_context", true)
            return on and _("Include book title/page in notes: on")
                or _("Include book title/page in notes: off")
        end,
        callback = function(touchmenu_instance)
            local cur = plugin:readSetting("include_book_context", true)
            plugin:saveSetting("include_book_context", not cur)
            if touchmenu_instance then touchmenu_instance:updateItems() end
        end,
        keep_menu_open = true,
    })

    -- Test active account.
    table.insert(items, {
        text = _("Test active account connection"),
        callback = function() Settings.testActiveAccount(plugin) end,
        keep_menu_open = true,
    })

    -- Clear cached access tokens (forces a refresh on the next send).
    table.insert(items, {
        text = _("Clear cached access tokens"),
        callback = function(touchmenu_instance)
            local _acc, _label, active_id = plugin:getActiveAccount()
            UIManager:show(ConfirmBox:new{
                text = _("Clear the cached access tokens for every account? The refresh_token in your configuration file is kept, so the next send will just request a fresh access token."),
                ok_text = _("Clear"),
                ok_callback = function()
                    local accounts_map = plugin:readSetting("accounts", {}) or {}
                    for k, v in pairs(accounts_map) do
                        if type(v) == "table" then
                            v.access_token = nil
                            v.access_token_expires_at = nil
                        end
                    end
                    plugin:saveSetting("accounts", accounts_map)
                    UIManager:show(Notification:new{ text = _("Cached access tokens cleared.") })
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                    if active_id then -- keep reference to silence unused-local warning
                        return
                    end
                end,
            })
        end,
        keep_menu_open = true,
        separator = true,
    })

    -- Reset all remembered settings (keeps configuration.lua intact).
    table.insert(items, {
        text = _("Reset remembered settings"),
        callback = function()
            UIManager:show(ConfirmBox:new{
                text = _("Reset the active-account selection, cached task lists, and toggles? This does not touch send2tasks_configuration.lua."),
                ok_text = _("Reset"),
                ok_callback = function()
                    plugin:resetRememberedSettings()
                    UIManager:show(Notification:new{ text = _("Settings reset.") })
                end,
            })
        end,
        keep_menu_open = true,
    })

    -- About.
    table.insert(items, {
        text = _("About Send to Google Tasks"),
        callback = function()
            local _acc, label, active_id = plugin:getActiveAccount()
            local lines = {
                _("Send to Google Tasks"),
                "",
                plugin:isConfigured()
                    and T(_("Active account: %1"), label or _("(none)"))
                    or _("send2tasks_configuration.lua not found."),
            }
            if active_id then
                table.insert(lines, plugin:hasRefreshToken(active_id)
                    and _("Status: refresh_token configured")
                    or _("Status: refresh_token missing"))
                if plugin:hasRefreshToken(active_id) then
                    table.insert(lines, T(_("Default list: %1"),
                        currentListLabel(plugin, active_id)))
                end
            end
            table.insert(lines, "")
            table.insert(lines, _("Uses Google's Tasks REST API (https://tasks.googleapis.com). The account's refresh_token is stored in send2tasks_configuration.lua; short-lived access tokens are obtained on demand and cached locally."))
            UIManager:show(InfoMessage:new{
                text = table.concat(lines, "\n"),
                timeout = 10,
            })
        end,
        keep_menu_open = true,
    })

    return items
end

return Settings
