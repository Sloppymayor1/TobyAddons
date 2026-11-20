local _, FRNS_ = ...; local NS = FRNS_.Gathering
-- English entries always live in NodeCatalogue.lua. Allocate only the active pack.
local locale = "enUS"
if type(GetLocale) == "function" then
    local ok, value = pcall(GetLocale)
    if ok and type(value) == "string" and not (issecretvalue and issecretvalue(value)) then locale = value end
end
NS.activeNodeLocale = locale
NS.NodeLocales = {}
