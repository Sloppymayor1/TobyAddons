-- FarmRoute Gathering: Forever Dual Gathering's node memory, icons, tracking
-- swap and HUD, built into FarmRoute (used with permission from Earthbane,
-- 2026-11-19; see LICENSE.txt). Its files share a private namespace,
-- FarmRoute's NS.Gathering, so none of its names clash with FarmRoute's.
local ADDON, FR = ...
local G = {}
FR.Gathering = G

-- True while the /farm HUD (ForeverFarmHUD) is open.
function G:FarmHUDOpen()
    local hud = _G.ForeverFarmHUD_HUD
    return hud ~= nil and hud:IsShown() == true
end

-- The separate Forever Dual Gathering addon would run a second copy of all of
-- this (two tracking swappers, two minimap scanners). Turn it off for the
-- next start; it stays installed and can be re-enabled in the addon list.
local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("PLAYER_LOGOUT") -- also fires on /reload

-- Counters for the saved diagnostic snapshot (see Snapshot below).
local stats = { swaps = 0, recoveries = 0 }
G.FarmRouteStats = stats

-- On /reload or logout, save the node trace and a status line to
-- ForeverFarmRouteGatheringDB.lastTrace so it can be read outside the game.
local function Snapshot()
    if not G.SnapshotNodeTrace then return end
    local quick = G.QuickScanner
    local trial = G.CursorSweepTrial
    local status = string.format("hudOpen=%s nodeScan=%s swaps=%d recoveries=%d | FDG quick starts=%d finished=%d hits=%d active=%s stop=%s",
        tostring(G:FarmHUDOpen()), tostring(FR.db and FR.db.nodeScan), stats.swaps, stats.recoveries,
        quick and quick.farmStarts or 0, quick and quick.farmFinished or 0, quick and quick.farmHits or 0,
        tostring(quick and quick.farmPass == true), tostring(trial and trial.quickStopReason))
    pcall(G.SnapshotNodeTrace, G, status)
end

f:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGOUT" then
        Snapshot()
        return
    end
    -- Count automatic swaps for the snapshot.
    if G.OnAutomaticGatheringSwitch and not G.farmRouteCounting then
        G.farmRouteCounting = true
        local onSwitch = G.OnAutomaticGatheringSwitch
        G.OnAutomaticGatheringSwitch = function(self, ...)
            stats.swaps = stats.swaps + 1
            return onSwitch(self, ...)
        end
    end
    -- The HUD retries paused swaps itself, so drop the "toggle tracking off
    -- and on" advice while it's open.
    if G.Print and G.L and not G.farmRouteQuietPause then
        G.farmRouteQuietPause = true
        local print = G.Print
        G.Print = function(msg, ...)
            if G:FarmHUDOpen() and (msg == G.L.TRACKING_PAUSED or msg == G.L.TRACKING_UNCONFIRMED) then return end
            return print(msg, ...)
        end
    end
    local loaded = C_AddOns and C_AddOns.IsAddOnLoaded or IsAddOnLoaded
    local disable = C_AddOns and C_AddOns.DisableAddOn or DisableAddOn
    if loaded and loaded("ForeverDualGathering") and disable then
        pcall(disable, "ForeverDualGathering")
        DEFAULT_CHAT_FRAME:AddMessage("|cff40e0ffFarmRoute:|r Forever Dual Gathering is now built into FarmRoute, so the separate addon has been turned off. Restart the game (or /reload) to stop running two copies.")
    end
end)

-- /farm static: keep the HUD map north-up while it's open; the player's own
-- minimap rotation setting comes back when it closes or static is turned off.
local savedRotate
local function GetCVarValue(name)
    local get = C_CVar and C_CVar.GetCVar or GetCVar
    return get and get(name)
end
local function SetCVarValue(name, value)
    local set = C_CVar and C_CVar.SetCVar or SetCVar
    if set then pcall(set, name, value) end
end
local function ApplyRotation(value)
    SetCVarValue("rotateMinimap", value)
    if Minimap_UpdateRotationSetting then pcall(Minimap_UpdateRotationSetting) end
end
-- While the HUD is open: north up (static) or turning with the player,
-- whatever the normal minimap uses; that setting comes back on close.
local function SyncStatic(open)
    if InCombatLockdown() then return end
    if FR.ScanOwnsMap and FR.ScanOwnsMap() then return end
    local db = FR.db
    if open and db and not db.disabled then
        local want = db.staticMap ~= false and "0" or "1"
        local current = GetCVarValue("rotateMinimap")
        if current ~= nil and current ~= want then
            if savedRotate == nil then savedRotate = current end
            ApplyRotation(want)
        end
    elseif savedRotate ~= nil then
        ApplyRotation(savedRotate)
        savedRotate = nil
    end
end

-- /farm size: bigger native node dots on the /farm map, set when the HUD
-- opens and put back when it closes.
local savedDotScale
local function SyncDots(open)
    if InCombatLockdown() or not (Minimap and Minimap.SetIconScale) then return end
    if FR.ScanOwnsMap and FR.ScanOwnsMap() then return end
    local db = FR.db
    local want = open and db and not db.disabled and FR.NodeSize() or nil
    if want and want ~= 1 then
        local current = G._minimapIconScale or 1
        if math.abs(current - want) > 0.001 then
            if not savedDotScale then savedDotScale = current end
            pcall(Minimap.SetIconScale, Minimap, want)
        end
    elseif savedDotScale then
        pcall(Minimap.SetIconScale, Minimap, savedDotScale)
        savedDotScale = nil
    end
end

-- Follow the /farm HUD opening and closing.
local wasOpen
local acc, recoverAt = 0, 0
f:SetScript("OnUpdate", function(_, dt)
    acc = acc + dt
    if acc < 0.25 then return end
    acc = 0
    local open = G:FarmHUDOpen()
    if open ~= wasOpen then
        wasOpen = open
        if G.db and G.UpdateAutoTracking then G:UpdateAutoTracking() end
    end
    SyncStatic(open)
    SyncDots(open)
    -- A swap the game didn't confirm (e.g. while alt-tabbed) pauses swapping;
    -- while the HUD is open, try again every few seconds instead of stopping.
    recoverAt = recoverAt + 0.25
    if open and recoverAt >= 4 then
        recoverAt = 0
        local hud = G.db and G.db.hud
        if hud and hud.autoTrackingWithFarmHUD ~= false and not hud.trackingSwapsPaused
            and G.RecoverPausedTracking and not InCombatLockdown() and G:RecoverPausedTracking() then
            stats.recoveries = stats.recoveries + 1
        end
    end
end)
