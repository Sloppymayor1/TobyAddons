-- FarmRoute: dot test on the /farm HUD (measure only: nothing is remembered or
-- drawn).
--
-- Spawn-spot checks before swaps found no dots in game (2026-11-20): the
-- spawn list misses most real spawn spots on this server. A sweep of the whole
-- map could find dots without that list, but only if one read covers a wide
-- enough area, quickly enough. This test measures both on a dot known to be
-- there: the one under the resting cursor.
--
-- This client only reports the minimap dot under the REAL cursor. The test
-- hides the map, slides it a few pixels at a time so that dot moves off the
-- cursor (right, then left), reads each position for a few frames, then puts
-- the dot back under the cursor and counts the frames until it reads again.
-- Runs alternate between hidden dots (icon scale 0, what a sweep would use)
-- and dots at their /farm size, so the log shows whether bigger dots are hit
-- from further away. Only the map's position, opacity and dot size change,
-- never its parent, size, shape, zoom or rotation. Remembered icons and route
-- lines stay put: they sit on FarmRoute's fixed map frame while the HUD is
-- open. Herb/ore swaps wait while a test runs.
local _, FR = ...
local G = FR.Gathering

local CURSOR_STILL = 0.25     -- the cursor must rest on a dot this long first
local GAP = 20                -- seconds between tests
local MAX_TESTS = 12          -- tests per session (until /reload)
local STEP_FRAMES = 3         -- frames each map position is read
local BACK_FRAMES = 4         -- frames read once the dot is back under the cursor
local NUDGES = { 8, 16, 32 }  -- screen pixels the dot is moved off the cursor
local MAX_ROWS = 60           -- test records kept for the saved log

local function Public(v) return not (issecretvalue and issecretvalue(v)) end
local function Num(v) return Public(v) and type(v) == "number" and v == v and math.abs(v) < math.huge end
local function Count(t, key) t[key] = (t[key] or 0) + 1 end

local function NewMode() return { runs = 0, inPlace = 0, inPlaceRuns = 0, reach = {}, back = {} } end
-- restReads: what the hover read showed each time the cursor came to rest
-- (once per rest); notStarted: why a test didn't start on a dot (once per
-- rest and reason); under/tooltip: frame under the cursor and tooltip owner
-- when a dot was under the resting cursor.
local log = { tests = 0, finished = 0, spoiled = 0, frames = 0, seconds = 0, maxFrames = 0,
    ended = {}, rows = {}, hidden = NewMode(), shown = NewMode(),
    restReads = {}, notStarted = {}, under = {}, tooltip = {} }
G.DotTestLog = log

local function TrackedKind()
    local ok, spell = pcall(G.GetActiveGatheringTracking, G)
    if not ok or not Public(spell) then return end
    return spell == 2383 and "herb" or spell == 2580 and "ore" or nil
end

-- true = the minimap mouse-over shows a dot, false = readable and empty,
-- nil = can't tell.
local function ReadDot()
    if not (C_TooltipInfo and C_TooltipInfo.GetMinimapMouseover) then return nil end
    local ok, data = pcall(C_TooltipInfo.GetMinimapMouseover)
    if not ok or not Public(data) or type(data) ~= "table" then return nil end
    local lines = data.lines
    if not Public(lines) or type(lines) ~= "table" or not Public(lines[1]) then return nil end
    return lines[1] ~= nil
end

local function FrameName(f)
    if not f then return "none" end
    local ok, name = pcall(f.GetName, f)
    if ok and Public(name) and type(name) == "string" then return name end
    local okT, kind = pcall(f.GetObjectType, f)
    return "unnamed " .. (okT and Public(kind) and type(kind) == "string" and kind or "frame")
end

-- What sits under the cursor and who owns the visible tooltip, for the log.
-- Neither stops a test: it only starts with a minimap dot under the cursor,
-- so the tooltip on show is that dot's (2026-11-20: requiring the minimap as
-- owner and mouse focus stopped every test in game).
local function CursorContext()
    local foci = GetMouseFoci and GetMouseFoci()
    local focus
    if type(foci) == "table" then focus = foci[1] elseif GetMouseFocus then focus = GetMouseFocus() end
    local tip = "hidden"
    if GameTooltip and GameTooltip:IsVisible() then
        tip = GameTooltip.GetOwner and FrameName(GameTooltip:GetOwner()) or "shown"
    end
    return FrameName(focus), tip
end

-- Why a test can't start right now (nil = it can).
local function Blocked()
    if InCombatLockdown() then return "combat" end
    if IsMouselooking and IsMouselooking() then return "camera" end
    if IsMouseButtonDown and (IsMouseButtonDown("LeftButton") or IsMouseButtonDown("RightButton")) then return "mouse button" end
    if UnitIsDeadOrGhost and UnitIsDeadOrGhost("player") then return "dead" end
    if UnitOnTaxi and UnitOnTaxi("player") then return "flight path" end
    for _, reader in ipairs({ UnitCastingInfo or false, UnitChannelInfo or false }) do
        if reader then
            local ok, casting = pcall(reader, "player")
            if not ok or not Public(casting) or casting ~= nil then return "casting" end
        end
    end
    if LootFrame and LootFrame:IsShown() then return "loot window" end
end

-- nil when tests may run, otherwise why not.
local function NotWanted()
    local db = FR.db
    if not db or db.disabled then return "FarmRoute off" end
    if db.dotTest == false then return "test switched off" end
    if not G:FarmHUDOpen() then return "HUD closed" end
    -- An FDG scan or FDG's farming map has the map.
    if FR.ScanOwnsMap and FR.ScanOwnsMap() then return "FDG scan has the map" end
end

local test     -- the running test
local saved    -- the map's resting state while the test has it
local restoreAfterCombat

local function Restore()
    local s = saved
    if not s then return end
    pcall(Minimap.ClearAllPoints, Minimap)
    for _, p in ipairs(s.points) do pcall(Minimap.SetPoint, Minimap, unpack(p)) end
    if s.clamped then pcall(Minimap.SetClampedToScreen, Minimap, true) end
    pcall(Minimap.SetAlpha, Minimap, s.alpha)
    if Minimap.SetIconScale then pcall(Minimap.SetIconScale, Minimap, s.iconScale) end
    local hdb = ForeverFarmHUDDB and ForeverFarmHUDDB.hud
    if hdb and s.hudAlphaSaved then hdb.mapAlpha = s.hudAlpha end
    -- The dot is back under the cursor, so its tooltip stays; just give the
    -- tooltip its opacity back. (Hiding it during a read empties the read.)
    if GameTooltip and s.tipAlpha then pcall(GameTooltip.SetAlpha, GameTooltip, s.tipAlpha) end
    -- If the game refused the move (combat lockdown), try again after combat.
    local p = s.points[1]
    local _, rel, _, x, y = Minimap:GetPoint(1)
    if InCombatLockdown() and p and (rel ~= p[2] or x ~= p[4] or y ~= p[5]) then
        restoreAfterCombat = true
        return
    end
    saved, restoreAfterCombat = nil, nil
    FR.probing, G.probing = nil, nil
end

-- While the test has the map: keep it invisible (the /farm HUD re-applies its
-- opacity setting several times a second) and the game tooltip see-through.
local function KeepHidden()
    local a = Minimap:GetAlpha()
    if not Public(a) or a ~= 0 then pcall(Minimap.SetAlpha, Minimap, 0) end
    if GameTooltip then
        local t = GameTooltip:GetAlpha()
        if not Public(t) or t ~= 0 then pcall(GameTooltip.SetAlpha, GameTooltip, 0) end
    end
end

local function Borrow(hideDots)
    local alpha = Minimap:GetAlpha()
    if not Num(alpha) then return false end
    local points = {}
    for i = 1, Minimap:GetNumPoints() do points[i] = { Minimap:GetPoint(i) } end
    if #points == 0 then return false end
    local iconScale = G._minimapIconScale
    if not Num(iconScale) or iconScale <= 0 then iconScale = FR.NodeSize() end
    local tipAlpha = GameTooltip and GameTooltip:GetAlpha()
    if not Num(tipAlpha) then tipAlpha = 1 end
    saved = { points = points, alpha = alpha, iconScale = iconScale, tipAlpha = tipAlpha,
        clamped = Minimap.IsClampedToScreen and Minimap:IsClampedToScreen() == true }
    FR.probing, G.probing = true, true
    local hdb = ForeverFarmHUDDB and ForeverFarmHUDDB.hud
    if hdb then saved.hudAlphaSaved, saved.hudAlpha, hdb.mapAlpha = true, hdb.mapAlpha, 0 end
    pcall(Minimap.SetAlpha, Minimap, 0)
    if hideDots and Minimap.SetIconScale then pcall(Minimap.SetIconScale, Minimap, 0) end
    if saved.clamped then pcall(Minimap.SetClampedToScreen, Minimap, false) end
    KeepHidden()
    return true
end

-- Slide the map so the dot sits `offset` screen pixels right of its resting
-- place (negative = left).
local function Place(t, offset)
    pcall(Minimap.ClearAllPoints, Minimap)
    pcall(Minimap.SetPoint, Minimap, "CENTER", UIParent, "BOTTOMLEFT", (t.mx + offset) / t.scale, t.my / t.scale)
end

-- nil while the map really sits where it was put and the cursor hasn't moved;
-- otherwise why this read can't be trusted.
local function Moved(t, offset)
    local cx, cy = GetCursorPosition()
    if not (Num(cx) and Num(cy)) or math.abs(cx - t.cx) > 2 or math.abs(cy - t.cy) > 2 then return "cursor moved" end
    local mx, my = Minimap:GetCenter()
    if not (Num(mx) and Num(my)) then return "map position unreadable" end
    mx, my = mx * t.scale, my * t.scale
    if math.abs(mx - (t.mx + offset)) <= 2 and math.abs(my - t.my) <= 2 then return nil end
    if offset ~= 0 and math.abs(mx - t.mx) <= 2 and math.abs(my - t.my) <= 2 then return "map snapped back" end
    return "map moved"
end

local function StepOffset(step)
    return step.dir == 0 and 0 or step.dir * NUDGES[step.i]
end

local function StepLabel(step)
    if step.back then return "back" end
    if step.dir == 0 then return "0" end
    return (step.dir > 0 and "+" or "-") .. NUDGES[step.i]
end

local function Begin(t, step, now)
    t.step, t.stepFrames, t.reads, t.placedAt = step, 0, "", now
    Place(t, StepOffset(step))
end

local function EndTest(reason, now)
    local t = test
    test = nil
    Restore()
    if not t then return end
    Count(log.ended, reason)
    log.frames = log.frames + t.frames
    log.seconds = log.seconds + (now - t.startedAt)
    log.maxFrames = math.max(log.maxFrames, t.frames)
    local m = log[t.mode]
    local finished = reason == "done" or reason == "hidden dots unreadable"
    if finished then
        log.finished = log.finished + 1
        m.runs = m.runs + 1
        Count(m.reach, "+" .. (t.reach[1] or 0) .. "/-" .. (t.reach[-1] or 0))
        if t.backFrame ~= nil then Count(m.back, t.backFrame) end
    else
        log.spoiled = log.spoiled + 1
    end
    local steps = table.concat(t.done, " ")
    if t.step and t.reads ~= "" then steps = steps .. (steps ~= "" and " " or "") .. StepLabel(t.step) .. ":" .. t.reads end
    local fps = GetFramerate and GetFramerate()
    local speed = GetUnitSpeed and GetUnitSpeed("player")
    log.rows[#log.rows + 1] = string.format("%.1f %s %s dots=%s | %s | %s | reach +%d/-%d | %s yd/px fps=%s speed=%s",
        now, t.kind or "?", t.mode, tostring(t.dotScale), reason, steps, t.reach[1] or 0, t.reach[-1] or 0,
        t.ydPerPx and string.format("%.2f", t.ydPerPx) or "?", Num(fps) and string.format("%.0f", fps) or "?",
        Num(speed) and string.format("%.1f", speed) or "?")
    if #log.rows > MAX_ROWS then table.remove(log.rows, 1) end
    -- One short line per test, so it's clear the test is running.
    if FR.Print and reason ~= "logout" then
        FR.Print(string.format("Dot test %d/%d %s (%s dots).", log.tests, MAX_TESTS,
            finished and "done" or ("stopped: " .. reason), t.mode == "hidden" and "hidden" or "shown"))
    end
end

-- The step that follows a finished one, or nil when the test is done.
local function NextStep(t, step, hit)
    if step.back then return nil end
    if step.dir == 0 then return hit and { dir = 1, i = 1 } or nil end
    if hit then t.reach[step.dir] = NUDGES[step.i] end
    if hit and step.i < #NUDGES then return { dir = step.dir, i = step.i + 1 } end
    if step.dir > 0 then return { dir = -1, i = 1 } end
    return { dir = 0, back = true }
end

local function Start(now, cx, cy)
    local mx, my = Minimap:GetCenter()
    local scale = Minimap:GetEffectiveScale()
    if not (Num(mx) and Num(my) and Num(scale)) or scale <= 0 then return false end
    log.tests = log.tests + 1
    local mode = log.tests % 2 == 1 and "hidden" or "shown"
    if not Borrow(mode == "hidden") then log.tests = log.tests - 1 return false end
    local width = Minimap:GetWidth()
    local radius = C_Minimap and C_Minimap.GetViewRadius and C_Minimap.GetViewRadius()
    test = { mode = mode, kind = TrackedKind(), cx = cx, cy = cy, mx = mx * scale, my = my * scale, scale = scale,
        startedAt = now, frames = 0, done = {}, reach = {},
        dotScale = mode == "hidden" and 0 or saved.iconScale,
        ydPerPx = Num(radius) and Num(width) and width > 0 and radius / (width * scale / 2) or nil }
    Begin(test, mode == "hidden" and { dir = 0 } or { dir = 1, i = 1 }, now)
    return true
end

-- One step per frame while a test runs; otherwise watch for the cursor
-- resting on a dot.
local cursor = { since = 0 }
local nextAt, nextPoll = 0, 0
local runner = CreateFrame("Frame")
runner:SetScript("OnUpdate", function()
    local now = GetTime()
    local x, y = GetCursorPosition()
    if not (Num(x) and Num(y)) or x ~= cursor.x or y ~= cursor.y then cursor.x, cursor.y, cursor.since = x, y, now end
    local t = test
    if not t then
        if now < nextPoll or log.tests >= MAX_TESTS or now - cursor.since < CURSOR_STILL then return end
        nextPoll = now + 0.1
        local seen = cursor.seen
        if not seen or seen.since ~= cursor.since then seen = { since = cursor.since }; cursor.seen = seen end
        local dot = ReadDot()
        local read = dot == true and "dot" or dot == false and "empty" or "unreadable"
        if not seen[read] then seen[read] = true; Count(log.restReads, read) end
        if dot ~= true then return end
        if not seen.context then
            seen.context = true
            local under, tip = CursorContext()
            Count(log.under, under)
            Count(log.tooltip, tip)
        end
        local reason = NotWanted() or Blocked()
        if not reason and now < nextAt then reason = "waiting between tests" end
        if reason then
            if not seen[reason] then seen[reason] = true; Count(log.notStarted, reason) end
            return
        end
        if Start(now, cursor.x, cursor.y) then nextAt = now + GAP end
        return
    end
    -- GetTime() is fixed within a frame: the map moved earlier in this same
    -- frame and the game hasn't drawn it there yet.
    if now == t.placedAt then return end
    t.frames = t.frames + 1
    KeepHidden()
    local offset = StepOffset(t.step)
    local spoiled
    if InCombatLockdown() then spoiled = "combat"
    elseif IsMouselooking and IsMouselooking() then spoiled = "camera"
    elseif IsMouseButtonDown and (IsMouseButtonDown("LeftButton") or IsMouseButtonDown("RightButton")) then spoiled = "mouse button"
    elseif TrackedKind() ~= t.kind then spoiled = "tracking changed"
    else spoiled = Moved(t, offset) end
    if spoiled then return EndTest(spoiled, now) end
    local dot = ReadDot()
    t.stepFrames = t.stepFrames + 1
    t.reads = t.reads .. (dot == true and "1" or dot == false and "0" or "?")
    if t.step.back and dot == true and t.backFrame == nil then t.backFrame = t.stepFrames end
    if t.stepFrames < (t.step.back and BACK_FRAMES or STEP_FRAMES) then return end
    local hit = dot == true
    t.done[#t.done + 1] = StepLabel(t.step) .. ":" .. t.reads
    if t.step.dir == 0 and not t.step.back then
        local m = log[t.mode]
        m.inPlaceRuns = m.inPlaceRuns + 1
        if hit then m.inPlace = m.inPlace + 1 end
    end
    local nextStep = NextStep(t, t.step, hit)
    if not nextStep then
        local reason = "done"
        if t.step.back then
            if t.backFrame == nil then t.backFrame = "never" end
        else
            reason = "hidden dots unreadable" -- not even read in place
        end
        t.step, t.reads = nil, ""
        return EndTest(reason, now)
    end
    Begin(t, nextStep, now)
end)

-- Herb/ore swaps wait while a test runs (the swap would take the dot away);
-- the swap timer simply tries again on its next tick.
local originalRun = G.RunAutoTracking
G.RunAutoTracking = function(self, ...)
    if test then return end
    return originalRun(self, ...)
end

local function Join(t)
    local list = {}
    for k, n in pairs(t) do list[#list + 1] = tostring(k) .. "=" .. n end
    table.sort(list)
    return #list > 0 and table.concat(list, " ") or "none"
end

function G:DotTestSummary()
    local h, s = log.hidden, log.shown
    return string.format("dot tests=%d finished=%d spoiled=%d (of %d max per session)"
        .. " | hidden dots: read in place %d/%d, reach %s, back after frame %s"
        .. " | dots at /farm size: reach %s, back after frame %s"
        .. " | map borrowed %d frames (%.2f s), longest test %d frames | ended: %s"
        .. " | cursor rests: %s | on a dot but not started: %s | under cursor on a dot: %s | tooltip owner on a dot: %s",
        log.tests, log.finished, log.spoiled, MAX_TESTS, h.inPlace, h.inPlaceRuns, Join(h.reach), Join(h.back),
        Join(s.reach), Join(s.back), log.frames, log.seconds, log.maxFrames, Join(log.ended),
        Join(log.restReads), Join(log.notStarted), Join(log.under), Join(log.tooltip))
end

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_REGEN_DISABLED")
events:RegisterEvent("PLAYER_REGEN_ENABLED")
events:RegisterEvent("PLAYER_LOGOUT")
events:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_REGEN_DISABLED" then
        -- Fires just before combat lockdown: hand the map back while that's allowed.
        if test then EndTest("combat started", GetTime()) end
    elseif event == "PLAYER_REGEN_ENABLED" then
        if restoreAfterCombat then Restore() end
    elseif event == "PLAYER_LOGOUT" then
        -- Never save the HUD's opacity setting at a test's 0.
        if test then EndTest("logout", GetTime()) end
        Restore()
        local db = ForeverFarmRouteGatheringDB
        if type(db) == "table" then
            db.swapCheck = nil -- the spot checks' old log
            db.dotTest = { saved = date("%Y-%m-%d %H:%M:%S"), summary = G:DotTestSummary(), rows = log.rows }
        end
    end
end)
