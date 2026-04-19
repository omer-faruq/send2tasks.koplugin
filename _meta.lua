local _ = require("gettext")

return {
    name = "send2tasks",
    fullname = _("Send to Google Tasks"),
    description = _([[Send quick notes and highlights from KOReader to Google Tasks. Uses Google's official Tasks REST API with OAuth 2.0 device flow (no password leaves the device). Supports multiple accounts, multiple task lists per account, optional due dates, a highlight-menu button, and automatic retry once the device is online.]]),
    version = "1.0.0",
}
