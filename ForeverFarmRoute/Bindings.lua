-- /farm bindings: mouse wheel down = Interact (soft target), mouse wheel
-- up = mount (Dire Wolf), middle mouse button = auto run. Off by default;
-- only active while FarmRoute is enabled and the player has turned it on.
-- Override binding only: the player's saved key bindings are never changed.
-- Bindings can't change in combat, so changes wait until combat ends.
local ADDON, NS = ...

local f = CreateFrame("Frame")
local applied = false

-- Mouse wheel up = mount. A secure macro button the wheel "clicks".
-- Wheel notches only press (never release), so it fires on the press.
local MOUNT_MACRO = "/cast Dire Wolf"
local mount = CreateFrame("Button", "ForeverFarmRouteMountButton", UIParent, "SecureActionButtonTemplate")
mount:SetSize(1, 1)
mount:SetPoint("TOPLEFT", UIParent, "TOPLEFT", -10, 10)
mount:RegisterForClicks("AnyDown")
mount:SetAttribute("type", "macro")
mount:SetAttribute("macrotext", MOUNT_MACRO)

local function Want()
    local db = NS.db
    return db ~= nil and db.bindings == true and not db.disabled
end

local function Sync()
    if InCombatLockdown() then return end
    local want = Want()
    if want == applied then return end
    if want then
        SetOverrideBinding(f, true, "MOUSEWHEELDOWN", "INTERACTTARGET")
        SetOverrideBindingClick(f, true, "MOUSEWHEELUP", "ForeverFarmRouteMountButton")
        SetOverrideBinding(f, true, "BUTTON3", "TOGGLEAUTORUN")
    else
        ClearOverrideBindings(f)
    end
    applied = want
end
NS.SyncBindings = Sync

f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:RegisterEvent("PLAYER_REGEN_ENABLED")
f:SetScript("OnEvent", Sync)

-- The centred HUD map sits under the cursor, and frames that take the mouse
-- wheel (the Minimap's zoom, EllesmereUI's zoom overlay) swallow the wheel
-- before the bindings see it. While the bindings and the HUD are on, switch
-- the wheel off on those frames; give it back afterwards.
local muted = {} -- frame -> true while we turned its wheel off
local mutedMouse = {} -- overlay child -> true while we turned its clicks off
local function OriginalWheel(frame, on)
    local mt = getmetatable(frame)
    local fn = mt and type(mt.__index) == "table" and mt.__index.EnableMouseWheel or frame.EnableMouseWheel
    if fn then pcall(fn, frame, on) end
end
local function MuteWheel(frame)
    if frame and frame.IsMouseWheelEnabled and frame:IsMouseWheelEnabled() then
        OriginalWheel(frame, false)
        muted[frame] = true
    end
end
local function MuteTree(frame)
    if not frame then return end
    MuteWheel(frame)
    if frame.GetChildren then
        for _, child in ipairs({ frame:GetChildren() }) do
            MuteWheel(child)
            -- Overlays such as EllesmereUI's zoom/ping layer also catch the
            -- middle button over the map; let clicks through to the bindings.
            local name = child.GetName and child:GetName()
            local ours = type(name) == "string" and name:find("^ForeverFarmRouteGathering") -- node hover needs its mouse
            if not ours and child.IsMouseEnabled and child:IsMouseEnabled() and child:IsShown() then
                pcall(child.EnableMouse, child, false)
                mutedMouse[child] = true
            end
        end
    end
end
local function SyncWheel()
    if NS.ScanOwnsMap and NS.ScanOwnsMap() then return end -- the scanner sets these itself
    local hud = _G.ForeverFarmHUD_HUD
    if applied and hud and hud:IsShown() then
        MuteTree(Minimap)
        MuteTree(hud)
    elseif not InCombatLockdown() and (next(muted) or next(mutedMouse)) then
        for frame in pairs(muted) do OriginalWheel(frame, true) end
        for frame in pairs(mutedMouse) do pcall(frame.EnableMouse, frame, true) end
        wipe(muted)
        wipe(mutedMouse)
    end
end

-- Follow /farm hide and /farm show, and frames that turn their wheel back on.
local acc = 0
f:SetScript("OnUpdate", function(_, dt)
    acc = acc + dt
    if acc < 0.25 then return end
    acc = 0
    Sync()
    SyncWheel()
end)
