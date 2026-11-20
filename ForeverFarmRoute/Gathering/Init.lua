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
local stats = { swaps = 0, recoveries = 0, probes = 0, found = 0, empty = 0, other = 0,
    unreadable = 0, misplaced = 0, aborted = 0, blocked = {}, hitFrames = {} }
G.FarmRouteStats = stats

-- On /reload or logout, save the node trace and a status line to
-- ForeverFarmRouteGatheringDB.lastTrace so it can be read outside the game.
local function Snapshot()
    if not G.SnapshotNodeTrace then return end
    local blocked = {}
    for reason, n in pairs(stats.blocked) do blocked[#blocked + 1] = reason .. "=" .. n end
    table.sort(blocked)
    local hits = {}
    for frames, n in pairs(stats.hitFrames) do hits[#hits + 1] = frames .. "f=" .. n end
    table.sort(hits)
    local status = string.format("hudOpen=%s nodeScan=%s swaps=%d recoveries=%d"
        .. " | probes=%d found=%d empty=%d other=%d unreadable=%d misplaced=%d aborted=%d lastError=%s | waits: %s | dot seen after frames: %s",
        tostring(G:FarmHUDOpen()), tostring(FR.db and FR.db.nodeScan), stats.swaps, stats.recoveries,
        stats.probes, stats.found, stats.empty, stats.other, stats.unreadable, stats.misplaced, stats.aborted,
        tostring(stats.lastError), table.concat(blocked, " "), table.concat(hits, " "))
    pcall(G.SnapshotNodeTrace, G, status)
end

f:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGOUT" then
        -- Never save the HUD's opacity setting at a probe's 0.
        if G.FarmProbeRestore then pcall(G.FarmProbeRestore) end
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

-------------------------------------------------------------------------------
-- /farm scan: node probe for the /farm HUD.
-- This client only reports the minimap dot under the real mouse cursor. To
-- check a spawn spot, the map is slid for a moment so that spot sits under
-- the cursor, read, and put straight back: only its position, opacity and
-- dot size change, for a few frames. The read is taken every frame from the
-- first frame after the move; a dot ends the probe at once, an empty spot
-- after PROBE_EMPTY (Dual Gathering's main scanner reads after 1-2 frames).
-- Route lines and node icons sit on FarmRoute's fixed map frame, so they
-- don't move. Spots checked in the last 45 s are skipped, so once an area is
-- known probes are rare.
-------------------------------------------------------------------------------
local PROBE_EMPTY = 0.05 -- seconds (and at least 3 frames) before a spot counts as empty
local PROBE_GAP = 0.3    -- seconds between probes
local CURSOR_STILL = 0.15 -- the cursor must rest this long before a probe starts
local SPOILED_RETRY = 10 -- seconds before retrying a spot whose read was spoiled
local probe = { state = "idle", nextAt = 0 }
local cursor = { x = nil, y = nil, since = 0 }
local saved -- the map's resting state while a probe has it

local function TrackedKind()
    local ok, spell = pcall(G.GetActiveGatheringTracking, G)
    if not ok or (issecretvalue and issecretvalue(spell)) then return end
    return spell == 2383 and "herb" or spell == 2580 and "ore" or nil
end

local function Public(v) return not (issecretvalue and issecretvalue(v)) end

-- true = the minimap mouse-over shows something, false = readable and empty,
-- nil = can't tell.
local function HasDot(data)
    if not Public(data) or type(data) ~= "table" then return nil end
    local lines = data.lines
    if not Public(lines) or type(lines) ~= "table" or not Public(lines[1]) then return nil end
    return lines[1] ~= nil
end

-- Why a probe can't run right now (nil = it can). The cursor must be free and
-- over the game world or the map itself, or the read would be meaningless.
local function Blocked()
    if InCombatLockdown() then return "combat" end
    if IsMouselooking and IsMouselooking() then return "camera" end
    if IsMouseButtonDown and (IsMouseButtonDown("LeftButton") or IsMouseButtonDown("RightButton")) then return "mouse button" end
    if UnitIsDeadOrGhost and UnitIsDeadOrGhost("player") then return "dead" end
    if UnitOnTaxi and UnitOnTaxi("player") then return "flight path" end
    if UnitCastingInfo then
        local ok, casting = pcall(UnitCastingInfo, "player")
        if not ok or not Public(casting) or casting ~= nil then return "casting" end
    end
    if LootFrame and LootFrame:IsShown() then return "loot window" end
    local foci = GetMouseFoci and GetMouseFoci()
    local focus
    if type(foci) == "table" then focus = foci[1] elseif GetMouseFocus then focus = GetMouseFocus() end
    if focus and focus ~= WorldFrame and focus ~= Minimap then return "window under cursor" end
    if GameTooltip and GameTooltip:IsVisible() and not GameTooltip:IsOwned(Minimap) then return "tooltip" end
end

local function Restore()
    if not saved then return end
    local s = saved
    saved = nil
    pcall(Minimap.ClearAllPoints, Minimap)
    for _, p in ipairs(s.points) do pcall(Minimap.SetPoint, Minimap, unpack(p)) end
    if s.clamped then pcall(Minimap.SetClampedToScreen, Minimap, true) end
    pcall(Minimap.SetAlpha, Minimap, s.alpha)
    if s.iconScale and Minimap.SetIconScale then pcall(Minimap.SetIconScale, Minimap, s.iconScale) end
    local hdb = ForeverFarmHUDDB and ForeverFarmHUDDB.hud
    if hdb and s.hudAlphaSaved then hdb.mapAlpha = s.hudAlpha end
    FR.probing, G.probing = nil, nil
    -- The read is done: close the probe's minimap tooltip, then give the
    -- tooltip its opacity back.
    if GameTooltip and GameTooltip:IsOwned(Minimap) then GameTooltip:Hide() end
    if GameTooltip and s.tipAlpha then pcall(GameTooltip.SetAlpha, GameTooltip, s.tipAlpha) end
end
G.FarmProbeRestore = Restore

-- While a probe has the map: keep it invisible (the /farm HUD re-applies its
-- opacity setting several times a second). The game's minimap tooltip is made
-- see-through, never hidden: hiding it stops the game updating what the
-- probe reads (Dual Gathering's own scanner does the same).
local function KeepHidden()
    local a = Minimap:GetAlpha()
    if not Public(a) or a ~= 0 then pcall(Minimap.SetAlpha, Minimap, 0) end
    if GameTooltip then
        local t = GameTooltip:GetAlpha()
        if not Public(t) or t ~= 0 then pcall(GameTooltip.SetAlpha, GameTooltip, 0) end
    end
end

local function Start(now)
    if now < probe.nextAt then return end
    local reason = Blocked()
    if reason then
        stats.blocked[reason] = (stats.blocked[reason] or 0) + 1
        probe.nextAt = now + 0.25
        return
    end
    local kind = TrackedKind()
    if kind ~= probe.kind then probe.kind, probe.kindSince = kind, now end
    -- Give the dots a moment to change after a tracking swap.
    if not kind or now < probe.kindSince + 0.3 then return end
    local ctx = G.GetGatheringNodeContext and G:GetGatheringNodeContext()
    if not ctx then probe.nextAt = now + 0.5 return end
    local target = G:FarmNextProbeTarget(ctx, kind, now)
    if not target then probe.nextAt = now + 0.5 return end
    local cx, cy = GetCursorPosition()
    if not (Public(cx) and Public(cy) and type(cx) == "number" and type(cy) == "number") then probe.nextAt = now + 0.5 return end
    -- If the cursor already rests on a dot, a probe's first read could still
    -- report that dot; wait until it's off (hovering learns that dot anyway).
    local okRest, rest = pcall(C_TooltipInfo.GetMinimapMouseover)
    if not okRest or HasDot(rest) ~= false then
        stats.blocked["cursor on a dot"] = (stats.blocked["cursor on a dot"] or 0) + 1
        probe.nextAt = now + PROBE_GAP
        return
    end
    local dx, dy = G.FarmProbeOffset(ctx, target.x, target.y)
    local alpha = Minimap:GetAlpha()
    if not Public(alpha) or type(alpha) ~= "number" then probe.nextAt = now + 0.5 return end
    local points = {}
    for i = 1, Minimap:GetNumPoints() do points[i] = { Minimap:GetPoint(i) } end
    local clamped = Minimap.IsClampedToScreen and Minimap:IsClampedToScreen() == true
    local iconScale = G._minimapIconScale
    if type(iconScale) ~= "number" then iconScale = tonumber(FR.db and FR.db.dotScale) or 1 end
    local tipAlpha = GameTooltip and GameTooltip:GetAlpha()
    if not Public(tipAlpha) or type(tipAlpha) ~= "number" then tipAlpha = 1 end
    saved = { points = points, alpha = alpha, iconScale = iconScale, clamped = clamped, tipAlpha = tipAlpha }
    FR.probing, G.probing = true, true
    -- The /farm HUD re-applies its opacity setting several times a second;
    -- set that setting to 0 for the probe so the HUD itself keeps the map
    -- invisible. Restore() puts the setting back.
    local hdb = ForeverFarmHUDDB and ForeverFarmHUDDB.hud
    if hdb then saved.hudAlphaSaved, saved.hudAlpha, hdb.mapAlpha = true, hdb.mapAlpha, 0 end
    -- Hide the map and its dots, then slide it so the spot is under the cursor.
    pcall(Minimap.SetAlpha, Minimap, 0)
    if Minimap.SetIconScale then pcall(Minimap.SetIconScale, Minimap, 0) end
    if clamped then pcall(Minimap.SetClampedToScreen, Minimap, false) end
    local cxMap, cyMap = (cx - dx) / ctx.scale, (cy - dy) / ctx.scale
    pcall(Minimap.ClearAllPoints, Minimap)
    pcall(Minimap.SetPoint, Minimap, "CENTER", UIParent, "BOTTOMLEFT", cxMap, cyMap)
    probe.state, probe.frames, probe.startedAt = "settle", 0, now
    probe.target, probe.ctx, probe.cx, probe.cy = target, ctx, cx, cy
    stats.probes = stats.probes + 1
end

local function Finish(now)
    Restore()
    probe.state, probe.nextAt = "idle", now + PROBE_GAP
end

local function Settle(now)
    probe.frames = probe.frames + 1
    KeepHidden()
    local kind = TrackedKind()
    if (IsMouselooking and IsMouselooking()) or InCombatLockdown() or kind ~= probe.target.kind then
        Finish(now)
        stats.aborted = stats.aborted + 1
        G:FarmProbeDefer(probe.target, now, SPOILED_RETRY)
        return
    end
    -- Only trust a read while the map really sits where it was put and the
    -- cursor hasn't moved off the spot.
    local mx, my = Minimap:GetCenter()
    local cx, cy = GetCursorPosition()
    local scale = probe.ctx.scale
    local dx, dy = G.FarmProbeOffset(probe.ctx, probe.target.x, probe.target.y)
    local placed = Public(mx) and Public(my) and type(mx) == "number" and type(my) == "number"
        and math.abs(mx * scale + dx - probe.cx) <= 2 and math.abs(my * scale + dy - probe.cy) <= 2
        and Public(cx) and type(cx) == "number" and math.abs(cx - probe.cx) <= 2 and math.abs(cy - probe.cy) <= 2
    if not placed then
        Finish(now)
        stats.misplaced = stats.misplaced + 1
        G:FarmProbeDefer(probe.target, now, SPOILED_RETRY)
        return
    end
    -- Read every frame: a dot ends the probe at once; an empty spot only
    -- counts once the map has had a few frames there.
    local ok, data = pcall(C_TooltipInfo.GetMinimapMouseover)
    local dot = ok and HasDot(data) == true
    if not dot and (probe.frames < 3 or now - probe.startedAt < PROBE_EMPTY) then return end
    Finish(now)
    if dot then stats.hitFrames[probe.frames] = (stats.hitFrames[probe.frames] or 0) + 1 end
    local result = ok and G:FarmProbeResult(probe.target, data, probe.ctx, now) or "unreadable"
    stats[result] = (stats[result] or 0) + 1
end

local prober = CreateFrame("Frame")
prober:SetScript("OnUpdate", function()
    local db = FR.db
    local want = db and db.nodeScan and not db.disabled and G.db and G.db.hud.rememberNodes
        and G.FarmNextProbeTarget and G:FarmHUDOpen() and not G.MinimapScanActive
    if not want then
        if saved then Restore() end
        probe.state = "idle"
        return
    end
    local now = GetTime()
    -- Only start a probe once the mouse has stopped moving for a moment.
    local x, y = GetCursorPosition()
    if not (Public(x) and Public(y)) or x ~= cursor.x or y ~= cursor.y then
        cursor.x, cursor.y, cursor.since = x, y, now
    end
    if probe.state ~= "settle" and now - cursor.since < CURSOR_STILL then return end
    local ok, err = pcall(probe.state == "settle" and Settle or Start, now)
    if not ok then
        stats.lastError = tostring(err)
        Restore()
        probe.state, probe.nextAt = "idle", now + 1
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

-- /farm dots: bigger native node dots on the /farm map, set when the HUD
-- opens and put back when it closes.
local savedDotScale
local function SyncDots(open)
    if InCombatLockdown() or not (Minimap and Minimap.SetIconScale) then return end
    if FR.ScanOwnsMap and FR.ScanOwnsMap() then return end
    local db = FR.db
    local want = open and db and not db.disabled and tonumber(db.dotScale) or nil
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
