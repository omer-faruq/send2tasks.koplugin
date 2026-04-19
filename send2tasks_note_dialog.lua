-- send2tasks_note_dialog.lua
--
-- Multi-line note composer used by both the tools menu entry and the
-- highlight-popup entry point. Follows the "first line is the task
-- title, the rest becomes the notes" convention, mirroring how Git/Unix
-- commit messages are composed.
--
-- The gear icon at the top-left opens a quick settings pop-up that lets
-- the user switch accounts and task lists without leaving the compose
-- screen. A third "Due…" button in the bottom row lets the user attach
-- a due date to the new task.
local Blitbuffer = require("ffi/blitbuffer")
local ButtonDialog = require("ui/widget/buttondialog")
local Device = require("device")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local NetworkMgr = require("ui/network/manager")
local Notification = require("ui/widget/notification")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local T = require("ffi/util").template

local Api = require("send2tasks_api")

local Screen = Device.screen

local NoteDialog = {}

-- ---------------------------------------------------------------------------
-- Book context collection
-- ---------------------------------------------------------------------------

local function collectBookContext(plugin)
    local ctx = {}
    if not plugin.ui or not plugin.ui.document then return ctx end
    local props = plugin.ui.doc_props or {}
    local title = props.title
    if not title or title == "" then
        local filepath = plugin.ui.document.file
        if filepath then
            local filename = filepath:match("([^/\\]+)$") or filepath
            title = filename:match("(.+)%.[^%.]+$") or filename
        end
    end
    ctx.title = title
    ctx.author = props.authors

    local cur_page, total_page
    if plugin.ui.paging and plugin.ui.view and plugin.ui.view.state then
        cur_page = plugin.ui.view.state.page
    elseif plugin.ui.document.getCurrentPage then
        local ok, page = pcall(function() return plugin.ui.document:getCurrentPage() end)
        if ok then cur_page = page end
    end
    if plugin.ui.document.getPageCount then
        local ok, total = pcall(function() return plugin.ui.document:getPageCount() end)
        if ok then total_page = total end
    end
    ctx.cur_page = cur_page
    ctx.total_page = total_page
    return ctx
end

local function formatBookSuffix(ctx)
    if not ctx.title or ctx.title == "" then return nil end
    local parts = { ctx.title }
    if ctx.author and ctx.author ~= "" then
        table.insert(parts, " — " .. ctx.author)
    end
    if ctx.cur_page and ctx.total_page then
        table.insert(parts, string.format(" · p.%d/%d", ctx.cur_page, ctx.total_page))
    elseif ctx.cur_page then
        table.insert(parts, string.format(" · p.%d", ctx.cur_page))
    end
    return table.concat(parts)
end

-- ---------------------------------------------------------------------------
-- Title/notes splitting
-- ---------------------------------------------------------------------------

-- Google Tasks task titles must be short; everything after the first
-- newline becomes the notes field. Empty notes are stripped so a
-- single-line input still produces a clean task.
local function splitTitleAndNotes(raw)
    if type(raw) ~= "string" then return "", "" end
    raw = raw:gsub("^%s+", "")
    local first_line, rest = raw:match("^([^\r\n]*)\r?\n?(.*)$")
    first_line = first_line or ""
    rest = rest or ""
    first_line = first_line:gsub("%s+$", "")
    rest = rest:gsub("^%s+", ""):gsub("%s+$", "")
    return first_line, rest
end

-- Produce a short, sensible default task title from a highlight. We cap
-- at 80 chars at the last whitespace boundary and append an ellipsis
-- when the source is longer.
local function deriveTitleFromHighlight(highlight)
    if not highlight or highlight == "" then return "" end
    local single = highlight:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    if #single <= 80 then return single end
    local cut = single:sub(1, 80)
    local last_space = cut:find(" [^ ]*$")
    if last_space and last_space > 40 then
        cut = cut:sub(1, last_space - 1)
    end
    return cut .. "…"
end

-- Build the default value shown in the input box when the dialog opens.
-- Convention: line 1 = title (auto-derived from the highlight); blank
-- line; quoted highlight; blank line; book reference line.
local function buildInitialText(plugin, highlighted_text)
    if not highlighted_text or highlighted_text == "" then return "" end
    local lines = {}
    table.insert(lines, deriveTitleFromHighlight(highlighted_text))
    table.insert(lines, "")
    table.insert(lines, "“" .. highlighted_text .. "”")
    if plugin:readSetting("include_book_context", true) then
        local ctx = collectBookContext(plugin)
        local suffix = formatBookSuffix(ctx)
        if suffix then
            table.insert(lines, "")
            table.insert(lines, "— " .. suffix)
        end
    end
    return table.concat(lines, "\n")
end

-- ---------------------------------------------------------------------------
-- Due-date picker
-- ---------------------------------------------------------------------------

-- Ordered list of { id, label, offset_days } entries used by the picker.
-- "offset_days" is nil for the "no due date" choice.
local DUE_OPTIONS = {
    { id = "none",       label = _("No due date"),  offset_days = nil },
    { id = "today",      label = _("Today"),        offset_days = 0 },
    { id = "tomorrow",   label = _("Tomorrow"),     offset_days = 1 },
    { id = "in_3_days",  label = _("In 3 days"),    offset_days = 3 },
    { id = "in_1_week",  label = _("In 1 week"),    offset_days = 7 },
}

local function findDueOption(id)
    for _, opt in ipairs(DUE_OPTIONS) do
        if opt.id == id then return opt end
    end
    return DUE_OPTIONS[1]
end

-- ---------------------------------------------------------------------------
-- Sending
-- ---------------------------------------------------------------------------

local function dispatchSend(plugin, account_id, list_id, title, notes, due_rfc3339)
    local token, err = plugin:getValidAccessToken(account_id)
    if not token then return false, err end
    local ok, result = Api.createTask(token, list_id, title, notes, due_rfc3339)
    if ok then return true, result end
    -- If we got a 401 the cached token went stale between check and
    -- request; force a refresh and retry once.
    if tostring(result or ""):find("HTTP 401") or tostring(result or ""):find("%(401%)") then
        plugin:saveAccountState(account_id, "access_token_expires_at", 0)
        local token2, err2 = plugin:getValidAccessToken(account_id)
        if not token2 then return false, err2 end
        return Api.createTask(token2, list_id, title, notes, due_rfc3339)
    end
    return false, result
end

local function sendTask(plugin, title, notes, due_rfc3339)
    local account, label, account_id = plugin:getActiveAccount()
    if not account then
        UIManager:show(InfoMessage:new{
            icon = "notice-warning",
            text = _("No Google Tasks account configured. Edit send2tasks_configuration.lua first."),
            timeout = 5,
        })
        return
    end
    if not plugin:hasRefreshToken(account_id) then
        UIManager:show(InfoMessage:new{
            icon = "notice-warning",
            text = T(_("Account '%1' is missing a refresh_token.\n\nOpen send2tasks_configuration.lua and paste the refresh_token obtained from OAuth Playground. See README.md for step-by-step instructions."), label),
            timeout = 8,
        })
        return
    end
    local list_id = plugin:getDefaultTaskListId(account_id) or "@default"

    local perform = function()
        Trapper:wrap(function()
            local trap = InfoMessage:new{
                text = T(_("Sending task to %1…"), label),
                timeout = nil,
            }
            UIManager:show(trap)
            local ok, err = dispatchSend(plugin, account_id, list_id, title, notes, due_rfc3339)
            UIManager:close(trap)
            if ok then
                UIManager:show(Notification:new{
                    text = T(_("Sent to %1"), label),
                })
            else
                UIManager:show(InfoMessage:new{
                    icon = "notice-warning",
                    text = T(_("Failed to send to %1:\n%2"), label, err or _("Unknown error")),
                    timeout = 6,
                })
            end
        end)
    end

    if NetworkMgr:isOnline() then
        perform()
        return
    end

    UIManager:show(Notification:new{
        text = _("Offline — the task will be sent once online."),
    })
    NetworkMgr:runWhenOnline(perform)
end

-- ---------------------------------------------------------------------------
-- Dialog plumbing
-- ---------------------------------------------------------------------------

local function buildDialogTitle(plugin, due_option)
    local _acc, label = plugin:getActiveAccount()
    local base
    if label then
        base = T(_("Send to %1"), label)
    else
        base = _("Send to Google Tasks")
    end
    if due_option and due_option.id ~= "none" then
        return base .. " · " .. due_option.label
    end
    return base
end

local function showDuePicker(current_id, on_pick)
    local dialog
    local buttons = {}
    for _, opt in ipairs(DUE_OPTIONS) do
        local marker = opt.id == current_id and "◉ " or "○ "
        table.insert(buttons, { {
            text = marker .. opt.label,
            background = Blitbuffer.COLOR_WHITE,
            callback = function()
                UIManager:close(dialog)
                if on_pick then on_pick(opt) end
            end,
        } })
    end
    table.insert(buttons, { {
        text = _("Cancel"),
        background = Blitbuffer.COLOR_WHITE,
        callback = function() UIManager:close(dialog) end,
    } })
    dialog = ButtonDialog:new{
        title = _("Due date"),
        title_align = "center",
        buttons = buttons,
    }
    UIManager:show(dialog)
end

-- Reopen the main compose dialog with updated title/description while
-- preserving the user's text, cursor position, and due selection.
local function reopenDialog(plugin, highlighted_text, preserved_text, due_id)
    NoteDialog.show(plugin, highlighted_text, {
        initial_text = preserved_text,
        due_id = due_id,
    })
end

-- Main entry point. `opts` is used internally when the dialog reopens
-- itself after a switch in active account or due date and should not
-- be passed by external callers.
function NoteDialog.show(plugin, highlighted_text, opts)
    opts = opts or {}
    local due_option = findDueOption(opts.due_id or "none")
    local initial_text
    if opts.initial_text ~= nil then
        initial_text = opts.initial_text
    else
        initial_text = buildInitialText(plugin, highlighted_text)
    end

    local dialog
    local description
    if highlighted_text and highlighted_text ~= "" then
        description = _("First line becomes the task title; the rest becomes the notes.")
    else
        description = _("First line becomes the task title; the rest becomes the notes.")
    end

    dialog = InputDialog:new{
        title = buildDialogTitle(plugin, due_option),
        description = description,
        input = initial_text,
        input_hint = _("Task title\n\nOptional notes on subsequent lines…"),
        input_type = "text",
        allow_newline = true,
        input_multiline = true,
        input_height = 8,
        text_height = math.floor(10 * Screen:scaleBySize(20)),
        width = math.floor(Screen:getWidth() * 0.85),
        title_bar_left_icon = "appbar.settings",
        title_bar_left_icon_tap_callback = function()
            if dialog.onCloseKeyboard then dialog:onCloseKeyboard() end
            plugin:showQuickSettings(function()
                -- Preserve the user's text when refreshing the dialog so
                -- an account or list switch does not wipe the draft.
                local text_now = dialog:getInputText() or ""
                UIManager:close(dialog)
                reopenDialog(plugin, highlighted_text, text_now, due_option.id)
            end)
        end,
        buttons = {{
            {
                text = _("Cancel"),
                id = "close",
                background = Blitbuffer.COLOR_WHITE,
                callback = function()
                    UIManager:close(dialog)
                end,
            },
            {
                text = due_option.id == "none"
                    and _("Due…")
                    or T(_("Due: %1"), due_option.label),
                background = Blitbuffer.COLOR_WHITE,
                callback = function()
                    if dialog.onCloseKeyboard then dialog:onCloseKeyboard() end
                    showDuePicker(due_option.id, function(picked)
                        local text_now = dialog:getInputText() or ""
                        UIManager:close(dialog)
                        reopenDialog(plugin, highlighted_text, text_now, picked.id)
                    end)
                end,
            },
            {
                text = _("Send"),
                is_enter_default = true,
                background = Blitbuffer.COLOR_WHITE,
                callback = function()
                    local raw = dialog:getInputText() or ""
                    local title, notes = splitTitleAndNotes(raw)
                    if title == "" then
                        UIManager:show(InfoMessage:new{
                            text = _("Please enter a task title on the first line."),
                            timeout = 3,
                        })
                        return
                    end
                    local due_rfc3339
                    if due_option and due_option.offset_days then
                        local ts = os.time() + due_option.offset_days * 86400
                        due_rfc3339 = Api.formatDueDate(ts)
                    end
                    UIManager:close(dialog)
                    sendTask(plugin, title, notes, due_rfc3339)
                end,
            },
        }},
    }

    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

return NoteDialog
