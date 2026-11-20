-- API compatibility for the Forever client (modern engine): use whichever
-- version of each call exists, and treat "secret" values (which the engine can
-- return in restricted situations and which can't be used in maths) as missing.
-- Also records FarmRoute's own Lua errors into its saved settings so they can
-- be read after a /reload.
local ADDON, NS = ...

NS.GetItemInfo = (C_Item and C_Item.GetItemInfo) or _G.GetItemInfo or function() end

function NS.GetCVar(name)
    if C_CVar and C_CVar.GetCVar then return C_CVar.GetCVar(name) end
    if _G.GetCVar then return _G.GetCVar(name) end
end

function NS.ItemIcon(item)
    if C_Item and C_Item.GetItemIconByID and type(item) == "number" then
        local icon = C_Item.GetItemIconByID(item)
        if icon then return icon end
    end
    if C_Item and C_Item.GetItemIconByID and type(item) == "string" then
        local id = tonumber(item:match("item:(%d+)"))
        local icon = id and C_Item.GetItemIconByID(id)
        if icon then return icon end
    end
    if _G.GetItemIcon then return _G.GetItemIcon(item) end
    return select(10, NS.GetItemInfo(item))
end

-- A usable number: not nil and not a secret value.
function NS.Num(v)
    if v == nil then return nil end
    if issecretvalue and issecretvalue(v) then return nil end
    return v
end

-------------------------------------------------------------------------------
-- Error recorder: FarmRoute errors go to ForeverFarmRouteDB.errors (last 30).
-------------------------------------------------------------------------------
local pending = {}

local function Record(msg)
    msg = tostring(msg)
    if not msg:find(ADDON, 1, true) then return end
    local entry = { msg = msg, stack = debugstack and debugstack(3, 8, 0) or nil, time = date and date("%H:%M:%S") or nil }
    local db = _G.ForeverFarmRouteDB
    local list = db and db.errors or pending
    if db and not db.errors then
        db.errors = {}
        list = db.errors
    end
    -- Same message repeated (e.g. every frame): count it instead of filling the list.
    for _, e in ipairs(list) do
        if e.msg == msg then
            e.count = (e.count or 1) + 1
            return
        end
    end
    if #list >= 30 then table.remove(list, 1) end
    list[#list + 1] = entry
end

function NS.FlushPendingErrors()
    local db = _G.ForeverFarmRouteDB
    if not db or #pending == 0 then return end
    db.errors = db.errors or {}
    for _, e in ipairs(pending) do db.errors[#db.errors + 1] = e end
    wipe(pending)
end

if geterrorhandler and seterrorhandler then
    local previous = geterrorhandler()
    seterrorhandler(function(msg, ...)
        pcall(Record, msg)
        if previous then return previous(msg, ...) end
    end)
end
