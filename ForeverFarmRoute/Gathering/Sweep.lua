-- FarmRoute: node sweep on the /farm HUD (/farm scan).
--
-- Herbs and ore stay drawn across Find Herbs / Find Minerals swaps. The game
-- only reports a minimap dot under the REAL cursor, and only for the kind
-- being tracked, so while the /farm HUD is open:
--  * the game's own dots are hidden (icon scale 0) and the map is invisible
--    (the HUD's faint map picture goes with it);
--  * each frame the hidden map is slid so one spot sits under the resting
--    cursor, and the next frame reads whether a dot is there (the dot test of
--    20 Nov 2026 showed that read is right on the very next frame, with the
--    dots hidden or not, and that bigger dots are not hit from further away);
--  * every herb and ore found is drawn here, both kinds, until checks of its
--    spot (while that kind is tracked) find it gone.
-- Spots are a world-fixed grid a little finer than the read window, checked
-- nearest first; a found node's spot is checked again every NODE_RECHECK s,
-- an empty spot every EMPTY_RECHECK s. A read only counts when the cursor, the
-- map and the tracking held still and the map was the frame under the cursor,
-- and only hidden-name lines count (herb and ore names are hidden on this
-- client), so party members and other blips never count as nodes. Whenever
-- there is nothing to check, the cursor is moving or busy, or a fight starts,
-- the map goes back to its place, still hidden; when the HUD closes or the
-- sweep is switched off, everything comes back as it was.
local _, FR = ...
local G = FR.Gathering

local CELL_PX = 9           -- grid spacing in screen pixels at the HUD's view
local EMPTY_RECHECK = 120   -- seconds before an empty spot is checked again (per kind)
local NODE_RECHECK = 20     -- seconds before a found node's spot is checked again
local FORGET = 900          -- seconds a node is kept without any check (out of view)
local TRACK_SETTLE = 0.4    -- seconds after a tracking swap before reads count
local CURSOR_REST = 0.15    -- the cursor must rest this long before sweeping
local REFINE_PX = 5         -- probes this far around a hit to centre the node
local MERGE_PX = 8          -- a hit this close to a known node of its kind is that node
local CENTRE_PX = 7         -- spots this close to the player arrow are skipped
local EDGE_PX = 4           -- margin inside the map edge
local TEXTURES = { herb = "Interface\\AddOns\\ForeverFarmRoute\\Gathering\\Media\\TrackingHerb",
    ore = "Interface\\AddOns\\ForeverFarmRoute\\Gathering\\Media\\TrackingOre" }
local REFINE = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }
-- Where in its cell a spot is read on its 1st, 2nd, ... check, so a dot near a
-- cell corner is caught on a later check if the first one missed it.
local JITTER = { { 0, 0 }, { 0.25, 0.25 }, { -0.25, -0.25 }, { 0.25, -0.25 }, { -0.25, 0.25 } }

local function Public(v) return not (issecretvalue and issecretvalue(v)) end
local function Num(v) return Public(v) and type(v) == "number" and v == v and math.abs(v) < math.huge end
local function Count(t, key) t[key] = (t[key] or 0) + 1 end

local log = { reads = 0, hits = 0, found = 0, refreshed = 0, removed = 0, kept = 0, sweepFrames = 0,
    parkedFrames = 0, discarded = {}, parked = {} }
G.SweepLog = log

local nodes = {}                          -- { kind, map, x, y, seen, checked }
G.SweepNodes = nodes
local checked = { herb = {}, ore = {} }   -- [cell key] = { t = time, n = checks }
local grid = {}                           -- map, cell size (yards), spiral of cell offsets
local saved, restoreAfterCombat, active
local pending, refine, idleUntil = nil, nil, 0
local cursor = { since = 0 }
local kindNow, kindSince = nil, 0

function G:SweepOwnsHUD() return active == true end

local function TrackedKind()
    local ok, spell = pcall(G.GetActiveGatheringTracking, G)
    if not ok or not Public(spell) then return end
    return spell == 2383 and "herb" or spell == 2580 and "ore" or nil
end

-- true = a herb or ore dot is under the cursor (its name is hidden on this
-- client), false = readable and none, nil = can't tell.
local function ReadNode()
    if not (C_TooltipInfo and C_TooltipInfo.GetMinimapMouseover) then return nil end
    local ok, data = pcall(C_TooltipInfo.GetMinimapMouseover)
    if not ok or not Public(data) or type(data) ~= "table" then return nil end
    local lines = data.lines
    if not Public(lines) or type(lines) ~= "table" then return nil end
    for i = 1, 32 do
        local line = lines[i]
        if not Public(line) then return nil end
        if line == nil then return false end
        if type(line) == "table" then
            local text = line.leftText
            if not Public(text) and type(text) == "string" then return true end
        end
    end
    return false
end

local function MouseFocus()
    local foci = GetMouseFoci and GetMouseFoci()
    if type(foci) == "table" then return foci[1] end
    return GetMouseFocus and GetMouseFocus()
end

-- Screen-pixel offset of a map spot from the map centre (+x east, +y north on
-- screen, turned with the map), and back.
local function Pixel(ctx) return 2 * ctx.radius / (ctx.width * ctx.scale) end
local function Offset(ctx, x, y)
    local e, n = (x - ctx.x) * ctx.w, (ctx.y - y) * ctx.h
    local p = Pixel(ctx)
    return (e * ctx.cos + n * ctx.sin) / p, (n * ctx.cos - e * ctx.sin) / p
end
local function Spot(ctx, dx, dy)
    local p = Pixel(ctx)
    local e, n = (dx * ctx.cos - dy * ctx.sin) * p, (dx * ctx.sin + dy * ctx.cos) * p
    return ctx.x + e / ctx.w, ctx.y - n / ctx.h
end

local function Round() return (GetMinimapShape and GetMinimapShape() or "ROUND") == "ROUND" end
local function Inside(ctx, dx, dy, margin)
    local half = ctx.width * ctx.scale / 2 - margin
    if half <= 0 then return false end
    if Round() then return dx * dx + dy * dy <= half * half end
    return math.abs(dx) <= half and math.abs(dy) <= half
end

-- The grid: CELL_PX at the current view, in yards, fixed to the world.
local function SyncGrid(ctx)
    local size = CELL_PX * Pixel(ctx)
    local reach = math.floor((ctx.width * ctx.scale / 2 - EDGE_PX) / CELL_PX) + 1
    if grid.map == ctx.map and grid.size and math.abs(grid.size - size) <= grid.size * 0.05 and grid.reach == reach then return end
    if grid.map ~= ctx.map or not grid.size or math.abs(grid.size - size) > grid.size * 0.05 then
        checked = { herb = {}, ore = {} } -- a new map or view scale: the old cells don't line up
    end
    local spiral = {}
    for di = -reach, reach do
        for dj = -reach, reach do spiral[#spiral + 1] = { di, dj, di * di + dj * dj } end
    end
    table.sort(spiral, function(a, b) return a[3] < b[3] end)
    grid.map, grid.size, grid.reach, grid.spiral = ctx.map, size, reach, spiral
end

local function CellOf(ctx, x, y)
    return math.floor(x * ctx.w / grid.size), math.floor(y * ctx.h / grid.size)
end
local function CellKey(i, j) return i * 100000 + j end
local function CellSpot(ctx, i, j, n)
    local jit = JITTER[(n % #JITTER) + 1]
    return (i + 0.5 + jit[1]) * grid.size / ctx.w, (j + 0.5 + jit[2]) * grid.size / ctx.h
end

local function PixelDistance(ctx, a, x, y)
    local e, n = (a.x - x) * ctx.w, (a.y - y) * ctx.h
    return math.sqrt(e * e + n * n) / Pixel(ctx)
end

local function NearestNode(ctx, kind, x, y, within)
    local best, bestD
    for _, node in ipairs(nodes) do
        if node.kind == kind and node.map == ctx.map then
            local d = PixelDistance(ctx, node, x, y)
            if d <= within and (not bestD or d < bestD) then best, bestD = node, d end
        end
    end
    return best
end

-------------------------------------------------------------------------------
-- The map: borrowed (hidden, ours to move), parked (hidden, at its place) or
-- given back.
-------------------------------------------------------------------------------
local function Holder() return _G.ForeverFarmRouteMapHolder end

local tipHidden
local function ShowTooltip()
    if tipHidden and GameTooltip then pcall(GameTooltip.SetAlpha, GameTooltip, tipHidden) end
    tipHidden = nil
end
local function HideTooltip()
    if not GameTooltip then return end
    if not tipHidden then
        local a = GameTooltip:GetAlpha()
        tipHidden = Num(a) and a > 0 and a or 1
    end
    local a = GameTooltip:GetAlpha()
    if not Public(a) or a ~= 0 then pcall(GameTooltip.SetAlpha, GameTooltip, 0) end
end

local function KeepHidden()
    local a = Minimap:GetAlpha()
    if not Public(a) or a ~= 0 then pcall(Minimap.SetAlpha, Minimap, 0) end
    if Minimap.SetIconScale and G._minimapIconScale ~= 0 then pcall(Minimap.SetIconScale, Minimap, 0) end
end

local function Borrow()
    local alpha = Minimap:GetAlpha()
    if not Num(alpha) then return false end
    local points = {}
    for i = 1, Minimap:GetNumPoints() do points[i] = { Minimap:GetPoint(i) } end
    if #points == 0 then return false end
    -- The dots' size before the sweep: the normal minimap's, or the /farm size
    -- if Init.lua SyncDots already set it (it then remembers the normal one).
    local iconScale = G._minimapIconScale
    saved = { points = points, alpha = alpha, iconScale = Num(iconScale) and iconScale > 0 and iconScale or 1,
        clamped = Minimap.IsClampedToScreen and Minimap:IsClampedToScreen() == true }
    FR.probing, G.probing = true, true
    local holder = Holder()
    if holder then holder.capturing = true end -- the /farm HUD keeps the map at opacity 0
    if saved.clamped then pcall(Minimap.SetClampedToScreen, Minimap, false) end
    KeepHidden()
    active = true
    return true
end

local parkedAt
local function Park(reason)
    pending, refine = nil, nil
    ShowTooltip()
    if reason then Count(log.parked, reason) end
    if not saved or parkedAt then return end
    if InCombatLockdown() then return end
    pcall(Minimap.ClearAllPoints, Minimap)
    for _, p in ipairs(saved.points) do pcall(Minimap.SetPoint, Minimap, unpack(p)) end
    parkedAt = true
end

local function Release()
    if not saved then active = nil return end
    pending, refine = nil, nil
    ShowTooltip()
    local s = saved
    pcall(Minimap.ClearAllPoints, Minimap)
    for _, p in ipairs(s.points) do pcall(Minimap.SetPoint, Minimap, unpack(p)) end
    if s.clamped then pcall(Minimap.SetClampedToScreen, Minimap, true) end
    local holder = Holder()
    if holder then holder.capturing = nil end
    pcall(Minimap.SetAlpha, Minimap, s.alpha)
    -- The game's dots come back at their size from before; with the HUD still
    -- open, Init.lua SyncDots then sets the /farm size (and remembers this one).
    if Minimap.SetIconScale then pcall(Minimap.SetIconScale, Minimap, s.iconScale) end
    local p = s.points[1]
    local _, rel, _, x, y = Minimap:GetPoint(1)
    if InCombatLockdown() and p and (rel ~= p[2] or x ~= p[4] or y ~= p[5]) then
        restoreAfterCombat = true
        return
    end
    saved, restoreAfterCombat, active, parkedAt = nil, nil, nil, nil
    FR.probing, G.probing = nil, nil
end
G.SweepRelease = Release

local function Place(ctx, x, y, purpose, extra, now)
    local dx, dy = Offset(ctx, x, y)
    local mx, my = cursor.x - dx, cursor.y - dy
    pcall(Minimap.ClearAllPoints, Minimap)
    pcall(Minimap.SetPoint, Minimap, "CENTER", UIParent, "BOTTOMLEFT", mx / ctx.scale, my / ctx.scale)
    parkedAt = nil
    HideTooltip() -- a dot under the cursor would show the game's tooltip for it
    pending = { x = x, y = y, purpose = purpose, extra = extra, kind = kindNow, cx = cursor.x, cy = cursor.y,
        mx = mx, my = my, scale = ctx.scale, at = now }
end

-------------------------------------------------------------------------------
-- What to check next
-------------------------------------------------------------------------------
local function NextNodeCheck(ctx, kind, now)
    for _, node in ipairs(nodes) do
        if node.kind == kind and node.map == ctx.map and now - node.checked >= NODE_RECHECK then
            local dx, dy = Offset(ctx, node.x, node.y)
            if Inside(ctx, dx, dy, EDGE_PX) and dx * dx + dy * dy >= CENTRE_PX * CENTRE_PX then return node end
        end
    end
end

local function NextCell(ctx, kind, now)
    local pi, pj = CellOf(ctx, ctx.x, ctx.y)
    local seen = checked[kind]
    local recheck
    for _, o in ipairs(grid.spiral) do
        local i, j = pi + o[1], pj + o[2]
        local key = CellKey(i, j)
        local c = seen[key]
        if not c or (not recheck and now - c.t >= EMPTY_RECHECK) then
            local x, y = CellSpot(ctx, i, j, c and c.n or 0)
            local dx, dy = Offset(ctx, x, y)
            if Inside(ctx, dx, dy, EDGE_PX) and dx * dx + dy * dy >= CENTRE_PX * CENTRE_PX then
                if not c then return key, x, y end
                recheck = { key, x, y }
            end
        end
    end
    if recheck then return recheck[1], recheck[2], recheck[3] end
end

local function MarkCell(ctx, kind, x, y, now)
    local key = CellKey(CellOf(ctx, x, y))
    local c = checked[kind][key]
    if c then c.t, c.n = now, c.n + 1 else checked[kind][key] = { t = now, n = 1 } end
end

-- Probes around a spot, then a verdict: a node there (centred on the hits) or not.
local function StartRefine(ctx, kind, x, y, node, now)
    refine = { kind = kind, x = x, y = y, node = node, i = 0, hits = 0, sx = 0, sy = 0, cell = { x, y } }
    if not node then refine.hits, refine.sx, refine.sy = 1, x, y end -- the hit that started it
end

local function FinishRefine(ctx, now)
    local r = refine
    refine = nil
    MarkCell(ctx, r.kind, r.cell[1], r.cell[2], now)
    if r.hits == 0 then
        if r.node then
            for i, node in ipairs(nodes) do if node == r.node then table.remove(nodes, i) break end end
            log.removed = log.removed + 1
        end
        return
    end
    local x, y = r.sx / r.hits, r.sy / r.hits
    local node = r.node or NearestNode(ctx, r.kind, x, y, MERGE_PX)
    if node then
        node.x, node.y, node.seen, node.checked = x, y, now, now
        if r.node then log.kept = log.kept + 1 else log.refreshed = log.refreshed + 1 end
    else
        nodes[#nodes + 1] = { kind = r.kind, map = ctx.map, x = x, y = y, seen = now, checked = now }
        log.found = log.found + 1
    end
end

local function NextRefineProbe(ctx)
    local r = refine
    while r.i < #REFINE do
        r.i = r.i + 1
        local dx, dy = Offset(ctx, r.x, r.y)
        dx, dy = dx + REFINE[r.i][1] * REFINE_PX, dy + REFINE[r.i][2] * REFINE_PX
        if Inside(ctx, dx, dy, EDGE_PX) then return Spot(ctx, dx, dy) end
    end
end

-- The verdict of last frame's placement.
local function Apply(ctx, p, dot, now)
    log.reads = log.reads + 1
    if dot then log.hits = log.hits + 1 end
    if p.purpose == "cell" then
        if not dot then MarkCell(ctx, p.kind, p.x, p.y, now) return end
        local known = NearestNode(ctx, p.kind, p.x, p.y, MERGE_PX)
        if known then
            known.seen, known.checked = now, now
            log.refreshed = log.refreshed + 1
            MarkCell(ctx, p.kind, p.x, p.y, now)
            return
        end
        StartRefine(ctx, p.kind, p.x, p.y, nil, now)
    elseif p.purpose == "node" then
        local node = p.extra
        if dot then node.seen, node.checked = now, now return end
        -- Not at its spot: look around it before letting it go.
        StartRefine(ctx, p.kind, node.x, node.y, node, now)
    elseif p.purpose == "refine" and refine then
        if dot then refine.hits, refine.sx, refine.sy = refine.hits + 1, refine.sx + p.x, refine.sy + p.y end
    end
end

-------------------------------------------------------------------------------
-- Drawing: both kinds, on a layer over FarmRoute's fixed map frame.
-------------------------------------------------------------------------------
local layer = CreateFrame("Frame", "ForeverFarmRouteSweepNodes", UIParent)
layer:EnableMouse(false)
layer:Hide()
local icons = {}

local function Draw(ctx, now)
    local holder = Holder()
    if not (holder and holder:IsShown() and ctx) then layer:Hide() return end
    if layer.followed ~= holder then
        layer:ClearAllPoints(); layer:SetAllPoints(holder); layer.followed = holder
    end
    local strata, level = holder:GetFrameStrata(), holder:GetFrameLevel() + 8
    if layer:GetFrameStrata() ~= strata then layer:SetFrameStrata(strata) end
    if layer:GetFrameLevel() ~= level then layer:SetFrameLevel(level) end
    if not layer:IsShown() then layer:Show() end
    local ui = UIParent:GetEffectiveScale()
    local size = FR.NodeIconPixels and FR.NodeIconPixels() or 42
    local shown = 0
    for i = #nodes, 1, -1 do
        local node = nodes[i]
        if now - node.checked > FORGET then table.remove(nodes, i) end
    end
    for _, node in ipairs(nodes) do
        if node.map == ctx.map then
            local dx, dy = Offset(ctx, node.x, node.y)
            if Inside(ctx, dx, dy, 0) then
                shown = shown + 1
                local icon = icons[shown]
                if not icon then
                    icon = layer:CreateTexture(nil, "OVERLAY")
                    icons[shown] = icon
                end
                if icon.kind ~= node.kind then icon:SetTexture(TEXTURES[node.kind]); icon.kind = node.kind end
                -- The layer is a UIParent child at scale 1 (like Dual Gathering's
                -- HUD icons), so a 14 px icon is the normal size; offsets are
                -- screen pixels turned into UIParent units.
                icon:SetSize(size, size)
                icon:ClearAllPoints()
                icon:SetPoint("CENTER", layer, "CENTER", dx / ui, dy / ui)
                icon:Show()
            end
        end
    end
    for i = shown + 1, #icons do icons[i]:Hide() end
    log.drawn = shown
end

-------------------------------------------------------------------------------
-- Every frame
-------------------------------------------------------------------------------
local function Wanted()
    local db = FR.db
    return db and not db.disabled and db.sweep ~= false and G:FarmHUDOpen()
        and not (FR.FDGScanOwnsMap and FR.FDGScanOwnsMap())
end

-- nil when a spot can be checked this frame, otherwise why not.
local function CursorBusy(now)
    if InCombatLockdown() then return "combat" end
    if IsMouselooking and IsMouselooking() then return "camera" end
    if IsMouseButtonDown and (IsMouseButtonDown("LeftButton") or IsMouseButtonDown("RightButton")) then return "mouse button" end
    if UnitIsDeadOrGhost and UnitIsDeadOrGhost("player") then return "dead" end
    if UnitOnTaxi and UnitOnTaxi("player") then return "flight path" end
    if not (Num(cursor.x) and Num(cursor.y)) then return "cursor unreadable" end
    if now - cursor.since < CURSOR_REST then return "cursor moving" end
    if not kindNow then return "no herb/ore tracking" end
    if now - kindSince < TRACK_SETTLE then return "tracking swap" end
end

local runner = CreateFrame("Frame")
runner:SetScript("OnUpdate", function()
    local now = GetTime()
    local x, y = GetCursorPosition()
    if not (Num(x) and Num(y)) or x ~= cursor.x or y ~= cursor.y then cursor.x, cursor.y, cursor.since = x, y, now end
    local kind = TrackedKind()
    if kind ~= kindNow then kindNow, kindSince, idleUntil = kind, now, 0 end

    if not Wanted() then
        if saved then Release() end
        layer:Hide()
        return
    end
    if not saved and not InCombatLockdown() and not Borrow() then layer:Hide() return end
    if not saved then layer:Hide() return end
    KeepHidden()
    local ctx = G.GetGatheringNodeContext and G:GetGatheringNodeContext()
    if not ctx then Park("no map position") layer:Hide() return end
    SyncGrid(ctx)

    -- 1. Last frame's placement.
    local p = pending
    if p and p.at ~= now then
        pending = nil
        local why
        if math.abs(cursor.x - p.cx) > 1 or math.abs(cursor.y - p.cy) > 1 then why = "cursor moved"
        elseif kindNow ~= p.kind or now - kindSince < TRACK_SETTLE then why = "tracking swap"
        elseif MouseFocus() ~= Minimap then why = "window under cursor"
        else
            local mx, my = Minimap:GetCenter()
            if not (Num(mx) and Num(my)) or math.abs(mx * p.scale - p.mx) > 2 or math.abs(my * p.scale - p.my) > 2 then
                why = "map moved"
            end
        end
        local dot = not why and ReadNode()
        if not why and dot == nil then why = "unreadable" end
        if why then
            Count(log.discarded, why)
            if refine and p.purpose == "refine" then refine = nil end
        else
            Apply(ctx, p, dot, now)
        end
    elseif p then
        Draw(ctx, now)
        return -- placed earlier in this same frame; read it next frame
    end

    -- 2. The next spot.
    local busy = CursorBusy(now)
    if not busy then
        local focus = MouseFocus()
        if focus and focus ~= WorldFrame and focus ~= Minimap then busy = "window under cursor" end
    end
    if busy then
        Park(busy)
        log.parkedFrames = log.parkedFrames + 1
        Draw(ctx, now)
        return
    end
    if refine and refine.kind ~= kindNow then refine = nil end
    if refine then
        local rx, ry = NextRefineProbe(ctx)
        if rx then
            Place(ctx, rx, ry, "refine", nil, now)
        else
            FinishRefine(ctx, now)
        end
    end
    if not pending and now >= idleUntil then
        local node = NextNodeCheck(ctx, kindNow, now)
        if node then
            Place(ctx, node.x, node.y, "node", node, now)
        else
            local key, cx, cy = NextCell(ctx, kindNow, now)
            if key then Place(ctx, cx, cy, "cell", key, now) else idleUntil = now + 0.5 end
        end
    end
    if pending then
        log.sweepFrames = log.sweepFrames + 1
    else
        Park(nil)
        log.parkedFrames = log.parkedFrames + 1
    end
    Draw(ctx, now)
end)

local function Join(t)
    local list = {}
    for k, n in pairs(t) do list[#list + 1] = tostring(k) .. "=" .. n end
    table.sort(list)
    return #list > 0 and table.concat(list, " ") or "none"
end

function G:SweepSummary()
    local herbs, ores = 0, 0
    for _, node in ipairs(nodes) do if node.kind == "herb" then herbs = herbs + 1 else ores = ores + 1 end end
    return string.format("remembered herbs=%d ore=%d (drawn now %d) | found=%d refreshed=%d kept after a look round=%d removed=%d"
        .. " | reads=%d hits=%d | frames sweeping=%d parked=%d | reads thrown out: %s | parked because: %s",
        herbs, ores, log.drawn or 0, log.found, log.refreshed, log.kept, log.removed, log.reads, log.hits,
        log.sweepFrames, log.parkedFrames, Join(log.discarded), Join(log.parked))
end

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_REGEN_DISABLED")
events:RegisterEvent("PLAYER_REGEN_ENABLED")
events:RegisterEvent("PLAYER_LOGOUT")
events:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_REGEN_DISABLED" then
        -- Fires just before combat lockdown: park the map while that's allowed.
        if saved then Park("combat") end
    elseif event == "PLAYER_REGEN_ENABLED" then
        if restoreAfterCombat then Release() end
    elseif event == "PLAYER_LOGOUT" then
        Release()
        local db = ForeverFarmRouteGatheringDB
        if type(db) == "table" then
            db.dotTest = nil -- the dot test's old log
            db.sweep = { saved = date("%Y-%m-%d %H:%M:%S"), summary = G:SweepSummary() }
        end
    end
end)
