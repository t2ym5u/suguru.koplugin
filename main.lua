local _dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
package.path = _dir .. "?.lua;" .. _dir .. "common/?.lua;" .. package.path

local function lrequire(name)
    local key = _dir .. name
    if not package.loaded[key] then
        package.loaded[key] = assert(loadfile(_dir .. name .. ".lua"))()
    end
    return package.loaded[key]
end

local PluginBase = require("plugin_base")
local _          = require("gettext")

local SuguruScreen = lrequire("screen")

local SuguruPlugin = PluginBase:extend{
    name      = "suguru",
    menu_text = _("Suguru"),
    menu_hint = "tools",
}

function SuguruPlugin:createScreen()
    return SuguruScreen:new{ plugin = self }
end

return SuguruPlugin
