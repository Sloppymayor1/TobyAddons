-- ForeverFarmRoute: route lines, a bidirectional guide arrow and a fading colour
-- trail drawn over the minimap / ForeverFarmHUD. Uses only the public UI API.
local ADDON, NS = ...

local MEDIA = "Interface\\AddOns\\ForeverFarmRoute\\Media\\"
local floor, sqrt, sin, cos, abs, max, min = math.floor, math.sqrt, math.sin, math.cos, math.abs, math.max, math.min
local atan2 = math.atan2 or atan2
local PI, TAU = math.pi, math.pi * 2

local db
local pendingBurst -- route point just reached; Draw pops it on the minimap

local DEFAULTS = {
    showRoute = true,
    showArrow = true,
    showTrail = true,
    showDot = true,
    showNodes = true,
    showWorldMap = true,
    showFx = true,
    comboWindow = 10,
    grindYards = 15,
    worldMapFog = false,
    fogYards = 300,
    iconAlpha = 0.6,
    routeWidth = 3,
    routeColor = { 0.25, 0.92, 1.0 },
    trailSeconds = 10,
    trailWidth = 4,
    reachYards = 25,
    yardScale = 1,
    arrowLocked = false,
    staticMap = true, -- the HUD map keeps north up instead of turning with you
    -- FDG's farming map on the /farm HUD (/farm scan). Off by default: it hides
    -- the game's own herb/ore dots and only shows nodes its scan finds.
    nodeScan = false,
    dotScale = 1.6, -- size of the game's own node dots on the HUD (1 = normal)
    arrowPos = { "CENTER", "CENTER", 0, -220 },
    routes = {},
    builtinSeen = {},
    active = nil,
}

local function CopyDefaults(src, dst)
    for k, v in pairs(src) do
        if type(v) == "table" then
            if type(dst[k]) ~= "table" then dst[k] = {} end
            if #v > 0 and #dst[k] == 0 then
                for i, x in ipairs(v) do dst[k][i] = x end
            else
                CopyDefaults(v, dst[k])
            end
        elseif dst[k] == nil then
            dst[k] = v
        end
    end
end

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff40e0ffFarmRoute:|r " .. tostring(msg))
end

-------------------------------------------------------------------------------
-- Import / export
-------------------------------------------------------------------------------
-- Format: FFR1:<mapID>:<zone name>:<route name>:x,y;x,y;...  (x,y = map %)
-- Optional 6th field: ore spawn markers  x,y,type;x,y,type;...
function NS.ParseImport(str)
    str = (str or ""):gsub("[\r\n\t]", ""):match("^%s*(.-)%s*$")
    local mapID, zone, name, body, nodeBody = str:match("^FFR1:(%d+):([^:]*):([^:]+):([^:]+):?(.*)$")
    if not mapID then return nil, "not a FarmRoute string (it should start with FFR1:)" end
    local pts = {}
    for x, y in body:gmatch("(%-?[%d%.]+),(%-?[%d%.]+)") do
        x, y = tonumber(x), tonumber(y)
        if x and y then
            pts[#pts + 1] = x / 100
            pts[#pts + 1] = y / 100
        end
    end
    if #pts < 4 then return nil, "a route needs at least two points" end
    local nodes = {}
    for x, y, t in (nodeBody or ""):gmatch("(%-?[%d%.]+),(%-?[%d%.]+),(%d+)") do
        nodes[#nodes + 1] = tonumber(x) / 100
        nodes[#nodes + 1] = tonumber(y) / 100
        nodes[#nodes + 1] = tonumber(t)
    end
    return { name = name, mapID = tonumber(mapID), zone = zone, pts = pts, nodes = nodes }
end

function NS.Export(route)
    local parts = {}
    for i = 1, #route.pts, 2 do
        parts[#parts + 1] = string.format("%.2f,%.2f", route.pts[i] * 100, route.pts[i + 1] * 100)
    end
    local s = string.format("FFR1:%d:%s:%s:%s", route.mapID or 0, route.zone or "", route.name, table.concat(parts, ";"))
    local nodes = route.nodes
    if nodes and #nodes >= 3 then
        local np = {}
        for i = 1, #nodes, 3 do
            np[#np + 1] = string.format("%.2f,%.2f,%d", nodes[i] * 100, nodes[i + 1] * 100, nodes[i + 2])
        end
        s = s .. ":" .. table.concat(np, ";")
    end
    return s
end

-- Ore spawn markers. Type 1/2 = not yet known (grey/white icon on the source
-- map); any type >= 1000 is the ore's item ID, set in the import string.
local UNKNOWN_ORE_ICON = "Interface\\Icons\\Spell_Nature_Earthquake" -- Find Minerals

-- Ore item ID -> icon file ID (Wowhead "Ore's and Their Icon ID's").
local ORE_ICONS = {
    [2770] = 134566,  -- Copper Ore
    [2771] = 134579,  -- Tin Ore
    [2775] = 135242,  -- Silver Ore
    [2776] = 134571,  -- Gold Ore
    [2772] = 134572,  -- Iron Ore
    [3858] = 134576,  -- Mithril Ore
    [7911] = 134580,  -- Truesilver Ore
    [10620] = 134578, -- Thorium Ore
}

local function ItemIcon(id)
    if ORE_ICONS[id] then return ORE_ICONS[id] end
    if C_Item and C_Item.GetItemIconByID then
        local icon = C_Item.GetItemIconByID(id)
        if icon then return icon end
    end
    return NS.ItemIcon(id)
end

-- Ring tint per ore (by item ID); unknown spots are grey.
local ORE_COLOURS = {
    [2770] = { 1.00, 0.60, 0.30 },  -- Copper
    [2771] = { 0.70, 0.78, 0.70 },  -- Tin
    [2772] = { 0.62, 0.72, 0.95 },  -- Iron
    [2775] = { 0.85, 0.87, 0.92 },  -- Silver
    [2776] = { 1.00, 0.85, 0.20 },  -- Gold
    [3858] = { 0.95, 0.95, 0.75 },  -- Mithril
    [7911] = { 0.40, 0.95, 1.00 },  -- Truesilver
    [10620] = { 0.30, 1.00, 0.50 }, -- Thorium
}
local function OreColour(t)
    local col = ORE_COLOURS[t]
    if col then return col[1], col[2], col[3] end
    return 0.8, 0.8, 0.8
end

-- Texture and whether the ore is known, for a marker type.
local function NodeTexture(t)
    if t and t >= 1000 then
        local icon = ItemIcon(t)
        if icon then return icon, true end
    end
    return UNKNOWN_ORE_ICON, false
end

-------------------------------------------------------------------------------
-- World positions (yards). E = east, N = north.
-------------------------------------------------------------------------------
local function Vec(x, y)
    if CreateVector2D then return CreateVector2D(x, y) end
    return { x = x, y = y }
end

local ZONE_TYPE = (Enum and Enum.UIMapType and Enum.UIMapType.Zone) or 3

local function ResolveMap(mapID, zone)
    local info = mapID and C_Map.GetMapInfo(mapID)
    if info and (not zone or zone == "" or info.name == zone) then return mapID end
    if zone and zone ~= "" then
        for id = 1, 3000 do
            local i = C_Map.GetMapInfo(id)
            if i and i.name == zone and i.mapType == ZONE_TYPE then return id end
        end
    end
    return info and mapID or nil
end

local function PlayerWorld()
    local map = C_Map.GetBestMapForUnit("player")
    if not map then return end
    local pos = C_Map.GetPlayerMapPosition(map, "player")
    if not pos then return end
    local px, py = pos:GetXY()
    if not NS.Num(px) or not NS.Num(py) then return end
    local cont, w = C_Map.GetWorldPosFromMapPos(map, pos)
    if not cont or not w then return end
    local wx, wy = w:GetXY()
    if not NS.Num(wx) or not NS.Num(wy) then return end
    return cont, -wy, wx
end

local function ZoneMapForPlayer()
    local m = C_Map.GetBestMapForUnit("player")
    local first = m
    while m do
        local info = C_Map.GetMapInfo(m)
        if not info then break end
        if info.mapType == ZONE_TYPE then return m, info.name end
        if info.mapType and info.mapType < ZONE_TYPE then break end
        m = info.parentMapID
    end
    local info = first and C_Map.GetMapInfo(first)
    return first, info and info.name
end

-- Compiled copy of the active route in world yards.
local compiled, compiledFor, compileRetryAt = nil, nil, 0
local courseRoute, course

local function WaypointKeys(pts)
    local keys = {}
    for i = 1, #pts, 2 do
        keys[#keys + 1] = string.format("%.17g,%.17g", pts[i], pts[i + 1])
    end
    return keys
end

local function ActiveRoute()
    return db and db.active and db.routes[db.active]
end

local function Invalidate()
    compiled, compiledFor, compileRetryAt = nil, nil, 0
    pendingBurst = nil
    if course then course.reverseTime = 0 end
end

local function Compiled()
    local route = ActiveRoute()
    if not route then return nil end
    if compiledFor == route then return compiled end
    if GetTime() < compileRetryAt then return nil end
    local mapID = ResolveMap(route.mapID, route.zone)
    if not mapID then
        compileRetryAt = GetTime() + 5
        return nil
    end
    local c = { E = {}, N = {}, n = 0 }
    local mapCont, w0 = C_Map.GetWorldPosFromMapPos(mapID, Vec(0, 0))
    local _, w1 = C_Map.GetWorldPosFromMapPos(mapID, Vec(1, 1))
    local n0, west0, n1, west1
    if w0 and w1 then
        n0, west0 = w0:GetXY()
        n1, west1 = w1:GetXY()
        c.yw, c.yh = abs(west0 - west1), abs(n0 - n1)
    end
    for i = 1, #route.pts, 2 do
        local x, y = route.pts[i], route.pts[i + 1]
        local cont, w = C_Map.GetWorldPosFromMapPos(mapID, Vec(x, y))
        local wx, wy
        if cont and w then
            wx, wy = w:GetXY()
        elseif mapCont and n0 and (x < 0 or x > 1 or y < 0 or y > 1) then
            -- Part of the Armory extends beyond the northern edge of the zone map.
            cont = mapCont
            wx = n0 + (n1 - n0) * y
            wy = west0 + (west1 - west0) * x
        else
            compileRetryAt = GetTime() + 2
            return nil
        end
        c.n = c.n + 1
        c.E[c.n], c.N[c.n] = -wy, wx
        c.cont = cont
    end
    local tight = NS.BUILTIN_TIGHT_WAYPOINTS and NS.BUILTIN_TIGHT_WAYPOINTS[route.name]
    if tight and c.n == tight.last
        and abs(route.pts[2 * tight.first - 1] - tight.firstX) < 0.00001
        and abs(route.pts[2 * tight.first] - tight.firstY) < 0.00001 then
        c.tight = tight
    end
    c.nE, c.nN, c.nT, c.nn = {}, {}, {}, 0
    local nodes = route.nodes or {}
    for i = 1, #nodes, 3 do
        local cont, w = C_Map.GetWorldPosFromMapPos(mapID, Vec(nodes[i], nodes[i + 1]))
        if cont == c.cont and w then
            local wx, wy = w:GetXY()
            c.nn = c.nn + 1
            c.nE[c.nn], c.nN[c.nn], c.nT[c.nn] = -wy, wx, nodes[i + 2]
        end
    end
    c.pts = route.pts
    c.keys = WaypointKeys(c.pts)
    local branch = NS.BUILTIN_BRANCHES and NS.BUILTIN_BRANCHES[route.name]
    if branch and route.pts[branch.first * 2 - 1] == branch.pts[1]
        and route.pts[branch.first * 2] == branch.pts[2]
        and route.pts[branch.last * 2 - 1] == branch.pts[#branch.pts - 1]
        and route.pts[branch.last * 2] == branch.pts[#branch.pts] then
        local function Path(pts)
            local path = { E = {}, N = {}, pts = pts, n = #pts / 2 }
            for i = 1, path.n do
                local _, w = C_Map.GetWorldPosFromMapPos(mapID, Vec(pts[i * 2 - 1], pts[i * 2]))
                if not w then return nil end
                local wx, wy = w:GetXY()
                if not NS.Num(wx) or not NS.Num(wy) then return nil end
                path.E[i], path.N[i] = -wy, wx
            end
            return path
        end
        local blue, alternate = {}, {}
        for i = branch.first * 2 - 1, branch.last * 2 do blue[#blue + 1] = route.pts[i] end
        for i = 1, (branch.first - 1) * 2 do alternate[#alternate + 1] = route.pts[i] end
        for _, v in ipairs(branch.pts) do alternate[#alternate + 1] = v end
        for i = branch.last * 2 + 1, #route.pts do alternate[#alternate + 1] = route.pts[i] end
        c.blue, c.red, c.alternate = Path(blue), Path(branch.pts), Path(alternate)
        if c.blue and c.red and c.alternate then
            c.main = { E = c.E, N = c.N, n = c.n, pts = c.pts, keys = c.keys }
            c.alternate.keys = WaypointKeys(c.alternate.pts)
            c.redFirst, c.redLast = branch.first, branch.first + c.red.n - 2
            c.other, c.iron = c.red, false
        end
    end
    if courseRoute ~= route then
        courseRoute, course = route, { skipped = {}, reverseTime = 0 }
    end
    c.course, c.mapID = course, mapID
    compiled, compiledFor = c, route
    return c
end

-------------------------------------------------------------------------------
-- Route proximity and targeting
-------------------------------------------------------------------------------
local SKIP_SECONDS = 90
local REVERSE_SECONDS = 3
local GRIND_YARDS = 15
local RED, WHITE = { 1, 0.18, 0.18 }, { 1, 1, 1 }

local function NearestSegment(path, pE, pN, open, previous, direction)
    local best, bestE, bestN, bestIndex = math.huge, 0, 0, nil
    local bestOffset = math.huge
    local count = open and path.n - 1 or path.n
    for a = 1, count do
        local b = a % path.n + 1
        local ax, ay = path.E[a] - pE, path.N[a] - pN
        local dx, dy = path.E[b] - path.E[a], path.N[b] - path.N[a]
        local len2 = dx * dx + dy * dy
        local t = len2 > 0 and max(0, min(1, -(ax * dx + ay * dy) / len2)) or 0
        local ex, ey = ax + t * dx, ay + t * dy
        local d2 = ex * ex + ey * ey
        local offset = previous and abs(a - previous) or 0
        offset = min(offset, path.n - offset)
        if previous and a == (previous - 1 + (direction or 1)) % path.n + 1 then offset = 0.5 end
        -- At crossings and overlapping stretches, prefer the segment we were following.
        if d2 < best - 0.000001 or (abs(d2 - best) <= 0.000001 and offset < bestOffset) then
            best, bestE, bestN, bestIndex, bestOffset = d2, dx, dy, a, offset
        end
    end
    return best, bestE, bestN, bestIndex
end

local function UpdateBranch(c, pE, pN)
    local direction = c.course.direction
    if not c.main then return NearestSegment(c, pE, pN, false, c.segment, direction) end
    local mainD2, mainE, mainN, mainIndex = NearestSegment(c.main, pE, pN, false, not c.iron and c.segment, direction)
    local redD2, redE, redN = NearestSegment(c.red, pE, pN, true)
    local mainD, redD = sqrt(mainD2), sqrt(redD2)
    local iron = c.iron
    -- Attach only inside the leash, with a small margin to avoid junction flicker.
    if redD <= GRIND_YARDS and redD + 5 < mainD then iron = true
    elseif mainD <= GRIND_YARDS and mainD + 5 < redD then iron = false end
    if iron ~= c.iron then
        local path = iron and c.alternate or c.main
        c.E, c.N, c.n, c.pts, c.keys = path.E, path.N, path.n, path.pts, path.keys
        c.iron, c.other = iron, iron and c.blue or c.red
        c.segment, c.target, pendingBurst = nil, nil, nil
    end
    local index, lineE, lineN = mainIndex, mainE, mainN
    if iron then
        local _
        _, lineE, lineN, index = NearestSegment(c, pE, pN, false, c.segment, direction)
    end
    -- Grinding can use either branch, while navigation stays on the active path.
    if redD2 < mainD2 then
        return redD2, redE, redN, index, lineE, lineN
    end
    return mainD2, mainE, mainN, index, lineE, lineN
end

local function SegmentColour(c, i)
    if c.iron and i >= c.redFirst and i <= c.redLast then return RED end
    return db.routeColor
end

local function TightWaypoint(c, i)
    return c.tight and i >= c.tight.first and i <= c.tight.last
end

local function UpdateCourse(c, segment, lineE, lineN, dE, dN, dt)
    c.segment = segment
    local course = c.course
    if segment and dE then
        local along = lineE * dE + lineN * dN
        local step2 = dE * dE + dN * dN
        local line2 = lineE * lineE + lineN * lineN
        if along * along > 0.1225 * step2 * line2 then
            local direction = along > 0 and 1 or -1
            if not course.direction then
                course.direction = direction
            elseif direction ~= course.direction then
                course.reverseTime = course.reverseTime + dt
                if course.reverseTime < REVERSE_SECONDS - 0.000001 then return end
                course.direction = direction
            end
        end
    end
    course.reverseTime = 0
end

local function InReach(c, i, pE, pN)
    local ex, ey = c.E[i] - pE, c.N[i] - pN
    local reach = db.reachYards or 25
    if TightWaypoint(c, i) then reach = min(reach, 6) end
    return ex * ex + ey * ey <= reach * reach
end

local function UpdateTarget(c, segment, pE, pN, now)
    if c.target and InReach(c, c.target, pE, pN) then pendingBurst = c.target end
    c.target = nil
    if not segment then return end

    local direction = c.course.direction or 1
    local target = direction == 1 and segment % c.n + 1 or segment
    for _ = 1, c.n do
        local key = c.keys[target]
        local skippedUntil = c.course.skipped[key]
        if not skippedUntil or now >= skippedUntil then
            c.course.skipped[key] = nil
            if not InReach(c, target, pE, pN) then
                c.target = target
                return target
            end
        end
        target = (target - 1 + direction) % c.n + 1
    end
end

-------------------------------------------------------------------------------
-- Drawing helpers
-------------------------------------------------------------------------------
local overlay = CreateFrame("Frame", "ForeverFarmRouteOverlay", UIParent)
if overlay.SetClipsChildren then overlay:SetClipsChildren(true) end
overlay:Hide()

local function NewLinePool(layer, sub, parent)
    local pool = { used = 0, items = {} }
    function pool:Begin() self.used = 0 end
    function pool:Get()
        self.used = self.used + 1
        local l = self.items[self.used]
        if not l then
            l = (parent or overlay):CreateLine(nil, layer, nil, sub)
            self.items[self.used] = l
        end
        l:Show()
        return l
    end
    function pool:Finish()
        for i = self.used + 1, #self.items do self.items[i]:Hide() end
    end
    return pool
end

local function NewTexPool(texture, layer, sub, parent)
    local pool = { used = 0, items = {} }
    function pool:Begin() self.used = 0 end
    function pool:Get()
        self.used = self.used + 1
        local t = self.items[self.used]
        if not t then
            t = (parent or overlay):CreateTexture(nil, layer, nil, sub)
            t:SetTexture(texture)
            self.items[self.used] = t
        end
        t:Show()
        return t
    end
    function pool:Finish()
        for i = self.used + 1, #self.items do self.items[i]:Hide() end
    end
    return pool
end

local trailLines = NewLinePool("BORDER", 1)
local shadowLines = NewLinePool("ARTWORK", 0)
local routeLines = NewLinePool("ARTWORK", 2)
local guideLines = NewLinePool("ARTWORK", 3)
local pointDots = NewTexPool(MEDIA .. "Dot", "OVERLAY", 0)
local nodeRings = NewTexPool(MEDIA .. "Ring", "BORDER", 2)
local nodeIcons = NewTexPool(MEDIA .. "Dot", "BORDER", 3)

local targetGlow = overlay:CreateTexture(nil, "OVERLAY", nil, 1)
targetGlow:SetTexture(MEDIA .. "Glow")
targetGlow:SetBlendMode("ADD")
local targetRing = overlay:CreateTexture(nil, "OVERLAY", nil, 2)
targetRing:SetTexture(MEDIA .. "Ring")

local playerGlow = overlay:CreateTexture(nil, "OVERLAY", nil, 5)
playerGlow:SetTexture(MEDIA .. "Glow")
playerGlow:SetBlendMode("ADD")
playerGlow:SetPoint("CENTER")
local playerDot = overlay:CreateTexture(nil, "OVERLAY", nil, 6)
playerDot:SetTexture(MEDIA .. "Dot")
playerDot:SetPoint("CENTER")
playerDot:SetSize(10, 10)

local function HSV(h)
    h = (h % 1) * 6
    local i = floor(h)
    local f = h - i
    local q = 1 - f
    if i == 0 then return 1, f, 0
    elseif i == 1 then return q, 1, 0
    elseif i == 2 then return 0, 1, f
    elseif i == 3 then return 0, q, 1
    elseif i == 4 then return f, 0, 1
    end
    return 1, 0, q
end

-- Clipping to the visible minimap (square or round).
local clipT0, clipT1
local function Edge(p, q)
    if p == 0 then return q >= 0 end
    local r = q / p
    if p < 0 then
        if r > clipT1 then return false end
        if r > clipT0 then clipT0 = r end
    else
        if r < clipT0 then return false end
        if r < clipT1 then clipT1 = r end
    end
    return true
end

local square, lim = true, 100

local function Clip(x1, y1, x2, y2)
    local dx, dy = x2 - x1, y2 - y1
    if square then
        clipT0, clipT1 = 0, 1
        if Edge(-dx, x1 + lim) and Edge(dx, lim - x1) and Edge(-dy, y1 + lim) and Edge(dy, lim - y1) then
            return true, x1 + clipT0 * dx, y1 + clipT0 * dy, x1 + clipT1 * dx, y1 + clipT1 * dy
        end
        return false
    end
    local r2 = lim * lim
    local c = x1 * x1 + y1 * y1 - r2
    if c <= 0 and x2 * x2 + y2 * y2 <= r2 then return true, x1, y1, x2, y2 end
    local a = dx * dx + dy * dy
    if a < 1e-6 then return false end
    local b = 2 * (x1 * dx + y1 * dy)
    local disc = b * b - 4 * a * c
    if disc <= 0 then return false end
    local s = sqrt(disc)
    local ta, tb = max(0, (-b - s) / (2 * a)), min(1, (-b + s) / (2 * a))
    if ta >= tb then return false end
    return true, x1 + ta * dx, y1 + ta * dy, x1 + tb * dx, y1 + tb * dy
end

local function Seg(pool, x1, y1, x2, y2, w, r, g, b, a)
    local ok
    ok, x1, y1, x2, y2 = Clip(x1, y1, x2, y2)
    if not ok then return end
    local l = pool:Get()
    l:SetStartPoint("CENTER", overlay, x1, y1)
    l:SetEndPoint("CENTER", overlay, x2, y2)
    l:SetThickness(w)
    l:SetColorTexture(r, g, b, a)
end

local function Inside(x, y)
    if square then return abs(x) <= lim and abs(y) <= lim end
    return x * x + y * y <= lim * lim
end

local function ClampToEdge(x, y)
    if square then
        local m = max(abs(x), abs(y))
        if m > lim then return x * lim / m, y * lim / m end
        return x, y
    end
    local d = sqrt(x * x + y * y)
    if d > lim then return x * lim / d, y * lim / d end
    return x, y
end

local OUTDOOR = { [0] = 466 + 2 / 3, 400, 333 + 1 / 3, 266 + 2 / 6, 200, 133 + 1 / 3 }
local INDOOR = { [0] = 300, 240, 180, 120, 80, 50 }

-- Diagnostics: how often each input came back protected ("secret") or missing.
-- /farm diag prints it; it is saved, so it can be read after a /reload.
local function Diag(key)
    local d = db.diag
    if not d then d = {}; db.diag = d end
    local e = d[key]
    if not e then e = { count = 0 }; d[key] = e end
    e.count = e.count + 1
    e.last = date and date("%H:%M:%S") or GetTime()
    e.combat = InCombatLockdown and InCombatLockdown() or false
end

-- The minimap's view radius in yards. Held at the last good value when the
-- game hands back a protected one, so the drawing never jumps in scale.
local lastRadius
-- While a gathering scan has borrowed the minimap, its zoom and rotation are
-- the scanner's; keep using the HUD's own (last seen outside a scan).
local function ScanActive() return NS.ScanOwnsMap ~= nil and NS.ScanOwnsMap() end
local function FarmScanMap()
    local gathering = NS.Gathering
    local map = gathering and gathering.QuickScanner and gathering.QuickScanner.farmMap and gathering.TerrainMinimap
    return map and map.frame and map.frame:IsShown() and map or nil
end
local hudRotating
local function Rotating()
    local map = FarmScanMap()
    if map then return map.farmRotating end
    if hudRotating ~= nil and ScanActive() then return hudRotating end
    hudRotating = NS.GetCVar("rotateMinimap") == "1"
    return hudRotating
end

local function ViewRadius()
    local farmMap = FarmScanMap()
    if farmMap then return farmMap:GetDisplaySpan() * 0.5 * (db.yardScale or 1) end
    if lastRadius and ScanActive() then return lastRadius * (db.yardScale or 1) end
    local r
    if C_Minimap and C_Minimap.GetViewRadius then
        local raw = C_Minimap.GetViewRadius()
        r = NS.Num(raw)
        if raw ~= nil and r == nil then Diag("viewRadius") end
    end
    if not r or r <= 0 then
        local rawZoom = Minimap:GetZoom()
        local z = NS.Num(rawZoom)
        if rawZoom ~= nil and z == nil then Diag("zoom") end
        if z then
            local t = (IsIndoors and IsIndoors()) and INDOOR or OUTDOOR
            r = (t[z] or t[0]) / 2
        end
    end
    if r and r > 0 then lastRadius = r end
    return (r or lastRadius or OUTDOOR[0] / 2) * (db.yardScale or 1)
end

-- Your facing (radians). When the game hides it, keep the last known value
-- and, while you move, follow your direction of travel (you face where you run).
local lastFacing
local function Facing(moveE, moveN)
    local raw = GetPlayerFacing and GetPlayerFacing()
    local f = NS.Num(raw)
    if f then
        lastFacing = f
        return f
    end
    Diag(raw == nil and "facingMissing" or "facingSecret")
    if moveE and (moveE * moveE + moveN * moveN) > 0.01 then
        lastFacing = atan2(-moveE, moveN) % TAU
    end
    return lastFacing
end

-------------------------------------------------------------------------------
-- Trail (world yards, fades with age)
-------------------------------------------------------------------------------
local tE, tN, tT, tB = {}, {}, {}, {}
local head, tail, trailCont = 1, 0, nil

local function ClearTrail()
    tE, tN, tT, tB = {}, {}, {}, {}
    head, tail = 1, 0
end

local function RecordTrail(cont, e, n, now)
    if cont ~= trailCont then
        ClearTrail()
        trailCont = cont
    end
    local fade = db.trailSeconds or 10
    while head <= tail and now - tT[head] > fade do
        tE[head], tN[head], tT[head], tB[head] = nil, nil, nil, nil
        head = head + 1
    end
    if head > tail then head, tail = 1, 0 end
    if head > 2000 then
        local nE, nN, nT, nB, j = {}, {}, {}, {}, 0
        for i = head, tail do
            j = j + 1
            nE[j], nN[j], nT[j], nB[j] = tE[i], tN[i], tT[i], tB[i]
        end
        tE, tN, tT, tB, head, tail = nE, nN, nT, nB, 1, j
    end
    local gap = true
    if tail >= head then
        local dx, dy = e - tE[tail], n - tN[tail]
        local d2 = dx * dx + dy * dy
        if d2 < 2.25 then return end
        gap = d2 > 3600 or now - tT[tail] > max(5, fade / 48)
        -- Bound drawing cost even at mounted speed or with a long fade setting.
        if not gap and now - tT[tail] < max(0.15, fade / 96) then return end
    end
    tail = tail + 1
    tE[tail], tN[tail], tT[tail], tB[tail] = e, n, now, gap
    while tail - head + 1 > 96 do
        tE[head], tN[head], tT[head], tB[head] = nil, nil, nil, nil
        head = head + 1
    end
end

-------------------------------------------------------------------------------
-- Guide arrow (independent of other guide addons)
-------------------------------------------------------------------------------
local arrow = CreateFrame("Button", "ForeverFarmRouteArrow", UIParent)
arrow:SetSize(64, 64)
arrow:SetFrameStrata("HIGH")
arrow:SetClampedToScreen(true)
arrow:SetMovable(true)
arrow:RegisterForDrag("LeftButton")
arrow:RegisterForClicks("RightButtonUp")
arrow:Hide()

arrow.tex = arrow:CreateTexture(nil, "ARTWORK")
arrow.tex:SetTexture(MEDIA .. "Arrow")
arrow.tex:SetSize(56, 56)
arrow.tex:SetPoint("CENTER")

arrow.dist = arrow:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
arrow.dist:SetPoint("TOP", arrow, "BOTTOM", 0, 4)
arrow.label = arrow:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
arrow.label:SetPoint("TOP", arrow.dist, "BOTTOM", 0, -1)

arrow:SetScript("OnDragStart", function(self)
    if not db.arrowLocked then self:StartMoving() end
end)
arrow:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local p, _, rp, x, y = self:GetPoint(1)
    db.arrowPos = { p, rp, x, y }
end)
arrow:SetScript("OnClick", function()
    NS.SkipTarget()
end)
arrow:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:AddLine("FarmRoute arrow", 0.25, 0.9, 1)
    GameTooltip:AddLine("Drag: move    Right-click: skip this point", 1, 1, 1)
    GameTooltip:AddLine("/farm lock makes it click-through", 0.7, 0.7, 0.7)
    GameTooltip:Show()
end)
arrow:SetScript("OnLeave", function() GameTooltip:Hide() end)

local function ApplyArrowSettings()
    arrow:ClearAllPoints()
    local p = db.arrowPos
    arrow:SetPoint(p[1] or "CENTER", UIParent, p[2] or "CENTER", p[3] or 0, p[4] or -220)
    arrow:EnableMouse(not db.arrowLocked)
end

local moveDE, moveDN -- your last step (yards), for facing when the game hides it

local function UpdateArrow(c, target, pE, pN)
    if not (db.showArrow and c and target) then
        arrow:Hide()
        return
    end
    local ex, ny = c.E[target] - pE, c.N[target] - pN
    local facing = Facing(moveDE, moveDN)
    if not facing then
        arrow:Hide()
        return
    end
    local rel = (atan2(-ex, ny) - facing) % TAU
    if rel > PI then rel = rel - TAU end
    arrow.tex:SetRotation(rel)
    arrow.tex:SetVertexColor(0.25, 0.92, 1)
    arrow.dist:SetFormattedText("%d yd", floor(sqrt(ex * ex + ny * ny) + 0.5))
    arrow.label:SetFormattedText("Point %d / %d", target, c.n)
    arrow:Show()
end

-------------------------------------------------------------------------------
-- Keep the minimap centred in ForeverFarmHUD (EllesmereUI compatibility)
-------------------------------------------------------------------------------
local MinimapMethods = getmetatable(Minimap) and getmetatable(Minimap).__index

local function CallOriginal(name, ...)
    local f = MinimapMethods and MinimapMethods[name] or Minimap[name]
    if f then pcall(f, Minimap, ...) end
end

-- True while a node probe (or Dual Gathering's own scanner, if switched on in
-- /fdg) has briefly moved the real minimap under the cursor. Pulling it back
-- mid-probe would spoil the read.
local function ScanOwnsMap()
    local G = NS.Gathering
    return G ~= nil and (G.MinimapScanActive or (G.CursorSweepTrial and G.CursorSweepTrial.saved ~= nil)
        or (G.QuickScanner and G.QuickScanner.farmMap ~= nil)) and true or false
end
NS.ScanOwnsMap = ScanOwnsMap

-- A fixed stand-in for where the HUD map sits: same centre, size and scale
-- as the minimap at rest in the /farm HUD. Route lines and node icons are
-- drawn on this, so they stay put while a probe moves the real map.
local mapHolder = CreateFrame("Frame", "ForeverFarmRouteMapHolder", UIParent)
mapHolder:EnableMouse(false)
mapHolder:Hide()
local function SyncMapHolder()
    local hud = _G.ForeverFarmHUD_HUD
    local hdb = ForeverFarmHUDDB and ForeverFarmHUDDB.hud
    if not hud or not hud:IsShown() or not hdb or not hdb.enabled then
        if mapHolder:IsShown() then mapHolder:Hide() end
        return
    end
    if ScanOwnsMap() then return end -- keep the at-rest geometry while the map is away
    local mEff, uEff = NS.Num(Minimap:GetEffectiveScale()), NS.Num(UIParent:GetEffectiveScale())
    local w, h = NS.Num(Minimap:GetWidth()), NS.Num(Minimap:GetHeight())
    if not (mEff and uEff and w and h) or uEff <= 0 then return end
    local scale = mEff / uEff
    if abs(mapHolder:GetScale() - scale) > 0.0001 then mapHolder:SetScale(scale) end
    if abs(mapHolder:GetWidth() - w) > 0.01 or abs(mapHolder:GetHeight() - h) > 0.01 then mapHolder:SetSize(w, h) end
    if mapHolder:GetNumPoints() == 0 or select(2, mapHolder:GetPoint(1)) ~= hud then
        mapHolder:ClearAllPoints()
        mapHolder:SetPoint("CENTER", hud, "CENTER", 0, 0)
    end
    mapHolder:SetFrameStrata(Minimap:GetFrameStrata())
    mapHolder:SetFrameLevel(Minimap:GetFrameLevel())
    if not mapHolder:IsShown() then mapHolder:Show() end
end
NS.SyncMapHolder = SyncMapHolder

local function GuardHUD()
    local hud = _G.ForeverFarmHUD_HUD
    local hdb = ForeverFarmHUDDB and ForeverFarmHUDDB.hud
    if not hud or not hud:IsShown() or not hdb or not hdb.enabled or ScanOwnsMap() then return end
    if not InCombatLockdown() then
        if Minimap:GetParent() ~= hud then CallOriginal("SetParent", hud) end
        local p, rel, _, x, y = Minimap:GetPoint(1)
        if Minimap:GetNumPoints() ~= 1 or p ~= "CENTER" or rel ~= hud or abs(x or 0) > 0.5 or abs(y or 0) > 0.5 then
            CallOriginal("ClearAllPoints")
            CallOriginal("SetPoint", "CENTER", hud, "CENTER", 0, 0)
        end
        local want = max(32, (hdb.size or 430) - 48)
        if abs(Minimap:GetWidth() - want) > 0.5 or abs(Minimap:GetHeight() - want) > 0.5 then
            CallOriginal("SetSize", want, want)
        end
        if abs(Minimap:GetScale() - 1) > 0.001 then CallOriginal("SetScale", 1) end
    end
    -- Alpha 0 means ForeverFarmHUD hid the map for combat; leave that alone.
    local a = NS.Num(Minimap:GetAlpha())
    local wantA = hdb.mapAlpha or 0.08
    if a and a > 0.001 and abs(a - wantA) > 0.01 then CallOriginal("SetAlpha", wantA) end
end

-- Mouse on the HUD map, as Dual Gathering's HUD does it: the map always
-- receives mouse-over, so node dots that pass under the resting cursor are
-- read and remembered, while every click passes through to the world. The
-- hold-to-mouse key (or ForeverFarmHUD's mouse mode) makes clicks land on
-- the map instead. The map's own settings come back when the HUD closes.
local ALL_BUTTONS = { "LeftButton", "RightButton", "MiddleButton", "Button4", "Button5" }
local hoverSaved, hoverClicks
local function Read(method)
    local f = Minimap[method]
    if not f then return nil end
    local ok, v = pcall(f, Minimap)
    if ok and not (issecretvalue and issecretvalue(v)) then return v end
end
local function ApplyHoldMouse()
    if InCombatLockdown() or ScanOwnsMap() then return end
    local hud = _G.ForeverFarmHUD_HUD
    local hdb = ForeverFarmHUDDB and ForeverFarmHUDDB.hud
    local open = hud and hud:IsShown() and hdb and hdb.enabled and db and not db.disabled
    if not open then
        if hoverSaved then
            CallOriginal("SetMouseClickEnabled", hoverSaved.click ~= false)
            CallOriginal("SetMouseMotionEnabled", hoverSaved.motion ~= false)
            hoverSaved, hoverClicks = nil, nil
        end
        return
    end
    if not hoverSaved then
        hoverSaved = { click = Read("IsMouseClickEnabled"), motion = Read("IsMouseMotionEnabled") }
    end
    local mod = hdb.mouseModifier
    local down = (mod == "SHIFT" and IsShiftKeyDown())
        or (mod == "ALT" and IsAltKeyDown())
        or (mod == "CTRL" and IsControlKeyDown())
    local clicks = (hdb.mouseMode or down) and true or false
    if Read("IsMouseEnabled") ~= true then CallOriginal("EnableMouse", true) end
    if Read("IsMouseMotionEnabled") ~= true then CallOriginal("SetMouseMotionEnabled", true) end
    if hoverClicks ~= clicks or Read("IsMouseClickEnabled") ~= clicks then
        hoverClicks = clicks
        CallOriginal("SetMouseClickEnabled", clicks)
        if clicks then CallOriginal("SetPassThroughButtons")
        else CallOriginal("SetPassThroughButtons", unpack(ALL_BUTTONS)) end
    end
end

-- EllesmereUI Minimap already knows how to share the map with a farming HUD
-- named "FarmHud" (hides its border, keeps the map centred). Point it at
-- ForeverFarmHUD's HUD frame when no real FarmHud is installed.
-- Another addon (EllesmereUI on entering combat) can set the map back to full
-- opacity while the HUD is up; put the HUD transparency back the same instant
-- instead of waiting for the next guard pass (that wait was a visible flash).
local alphaHooked
local function HookMapAlpha()
    if alphaHooked or not hooksecurefunc or not Minimap.SetAlpha then return end
    alphaHooked = true
    hooksecurefunc(Minimap, "SetAlpha", function(_, value)
        if mapHolder.capturing then
            if NS.Num(value) ~= 0 then CallOriginal("SetAlpha", 0) end
            return
        end
        if not db or db.disabled or ScanOwnsMap() then return end
        local hud = _G.ForeverFarmHUD_HUD
        local hdb = ForeverFarmHUDDB and ForeverFarmHUDDB.hud
        if not hud or not hud:IsShown() or not hdb or not hdb.enabled then return end
        local v = NS.Num(value)
        local wantA = hdb.mapAlpha or 0.08
        if v and v > 0.001 and abs(v - wantA) > 0.01 then CallOriginal("SetAlpha", wantA) end
    end)
end

-- EllesmereUI snaps the map back to FarmHud's centre whenever anything moves
-- it, which undid every gathering scan. So it gets a stand-in the size of the
-- HUD that shows and hides with it, but reads as hidden while a scan has the
-- map. (EllesmereUI only checks IsShown in those hooks.)
local function LinkEllesmere()
    local hud = _G.ForeverFarmHUD_HUD
    if _G.FarmHud == nil and hud then
        local proxy = CreateFrame("Frame", "ForeverFarmRouteFarmHud", hud)
        proxy:SetAllPoints(hud)
        proxy:EnableMouse(false)
        local isShown = proxy.IsShown
        proxy.IsShown = function(self)
            return isShown(self) and hud:IsShown() and not ScanOwnsMap()
        end
        _G.FarmHud = proxy
    end
    HookMapAlpha()
end

-------------------------------------------------------------------------------
-- Main update
-------------------------------------------------------------------------------
-- While the gathering scanner borrows the real minimap (it moves it, unseen,
-- under the cursor for a second or two), its drawn stand-in map holds the
-- HUD's place; keep the route on the stand-in, not on the moving minimap.
local function MapFrame()
    SyncMapHolder()
    local farmMap = FarmScanMap()
    if farmMap then return farmMap.frame, 32 end
    if mapHolder:IsShown() then return mapHolder, 6 end -- /farm HUD: fixed frame
    local G = NS.Gathering
    local stand = G and G.MinimapScanActive and G.TerrainMinimap and G.TerrainMinimap.frame
    if stand and stand:IsShown() then return stand, 32 end
    return Minimap, 6
end

local function SyncOverlay()
    local anchor, above = MapFrame()
    if overlay:GetNumPoints() == 0 or select(2, overlay:GetPoint(1)) ~= anchor then
        overlay:ClearAllPoints()
        overlay:SetAllPoints(anchor)
    end
    local strata = anchor:GetFrameStrata()
    if overlay:GetFrameStrata() ~= strata then overlay:SetFrameStrata(strata) end
    local level = anchor:GetFrameLevel() + above
    if overlay:GetFrameLevel() ~= level then overlay:SetFrameLevel(level) end
end

local function Draw(c, target, pE, pN, now, grindE, grindN)
    trailLines:Begin(); shadowLines:Begin(); routeLines:Begin(); guideLines:Begin(); pointDots:Begin()
    nodeIcons:Begin(); nodeRings:Begin()
    targetRing:Hide(); targetGlow:Hide()

    local half = overlay:GetWidth() / 2
    local radius = ViewRadius()
    if half > 4 and radius > 0 then
        local k = half / radius
        local cs, sn = 1, 0
        if Rotating() then
            local map = FarmScanMap()
            local f = map and map.rotation or Facing(moveDE, moveDN) or 0
            cs, sn = cos(f), sin(f)
        end
        local map = FarmScanMap()
        if map and map.original then square = map.original.round == false
        else square = GetMinimapShape ~= nil and GetMinimapShape() == "SQUARE" end
        lim = half - 1

        local function P(e, n)
            local dx, dy = (e - pE) * k, (n - pN) * k
            return dx * cs + dy * sn, -dx * sn + dy * cs
        end

        if db.showTrail and tail > head then
            local fade = db.trailSeconds or 10
            local w = db.trailWidth or 4
            local px, py = P(tE[head], tN[head])
            for i = head + 1, tail do
                local x, y = P(tE[i], tN[i])
                if not tB[i] then
                    local f = 1 - (now - tT[i]) / fade
                    if f > 0 then
                        local r, g, b = HSV(tT[i] * 0.06)
                        Seg(trailLines, px, py, x, y, w * (0.35 + 0.65 * f), r, g, b, f ^ 1.3)
                    end
                end
                px, py = x, y
            end
        end

        if c and c.nn > 0 and db.showNodes then
            -- Spawn spots from the source map, not live nodes (the game does not
            -- expose tracking blips to addons). Drawn as a hollow ring around the
            -- spot, tinted by ore, with a small ore badge beside it, so the real
            -- tracking blip in the middle is never covered.
            local a = db.iconAlpha or 0.6
            local R = db.markerRing or 22
            for i = 1, c.nn do
                local x, y = P(c.nE[i], c.nN[i])
                if Inside(x, y) then
                    local r, g, b = OreColour(c.nT[i])
                    local ring = nodeRings:Get()
                    ring:SetPoint("CENTER", overlay, "CENTER", x, y)
                    ring:SetSize(R, R)
                    ring:SetVertexColor(r, g, b, a)
                    local tex = NodeTexture(c.nT[i])
                    local icon = nodeIcons:Get()
                    icon:SetTexture(tex)
                    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                    icon:SetPoint("CENTER", overlay, "CENTER", x + R * 0.45, y + R * 0.45)
                    icon:SetSize(10, 10)
                    icon:SetVertexColor(1, 1, 1, a)
                end
            end
        end

        if c and db.showRoute then
            local w = db.routeWidth or 3
            local n = c.n
            local before = target and (target == 1 and n or target - 1)
            local fx, fy = P(c.E[1], c.N[1])
            local ax, ay = fx, fy
            for i = 1, n do
                local j = i % n + 1
                local bx, by
                if j == 1 then bx, by = fx, fy else bx, by = P(c.E[j], c.N[j]) end
                Seg(shadowLines, ax, ay, bx, by, w + 2.5, 0, 0, 0, 0.55)
                local col = SegmentColour(c, i)
                if i == before or i == target then
                    local highlight = col == RED and RED or WHITE
                    Seg(routeLines, ax, ay, bx, by, w + 1, highlight[1], highlight[2], highlight[3], 1)
                else
                    Seg(routeLines, ax, ay, bx, by, w, col[1], col[2], col[3], 0.9)
                end
                if Inside(ax, ay) then
                    local d = pointDots:Get()
                    d:SetSize(7, 7)
                    d:SetPoint("CENTER", overlay, "CENTER", ax, ay)
                    d:SetVertexColor(col[1], col[2], col[3], 1)
                end
                ax, ay = bx, by
            end

            if c.other then
                local col = c.iron and db.routeColor or RED
                for i = 1, c.other.n - 1 do
                    local ax, ay = P(c.other.E[i], c.other.N[i])
                    local bx, by = P(c.other.E[i + 1], c.other.N[i + 1])
                    Seg(shadowLines, ax, ay, bx, by, w + 2.5, 0, 0, 0, 0.55)
                    Seg(routeLines, ax, ay, bx, by, w, col[1], col[2], col[3], 0.9)
                end
            end
            if target then
                local tx, ty = P(c.E[target], c.N[target])
                Seg(guideLines, 0, 0, tx, ty, 1.5, 1, 1, 1, 0.35)
                local ex, ey = ClampToEdge(tx, ty)
                local pulse = 0.5 + 0.5 * sin(now * 5)
                local s = (ex == tx and ey == ty) and 20 or 14
                targetRing:ClearAllPoints()
                targetRing:SetPoint("CENTER", overlay, "CENTER", ex, ey)
                targetRing:SetSize(s + 6 * pulse, s + 6 * pulse)
                targetRing:SetVertexColor(1, 1, 1, 0.9)
                targetRing:Show()
                targetGlow:ClearAllPoints()
                targetGlow:SetPoint("CENTER", overlay, "CENTER", ex, ey)
                targetGlow:SetSize(s * 2, s * 2)
                targetGlow:SetVertexColor(0.3, 0.95, 1, 0.35 + 0.35 * pulse)
                targetGlow:Show()
            end
        end
    end

    -- Effects in minimap space (projection uses the same view as the lines).
    if db.showFx and half > 4 and radius > 0 then
        local k = half / radius
        local cs, sn = 1, 0
        if Rotating() then
            local map = FarmScanMap()
            local f = map and map.rotation or Facing(moveDE, moveDN) or 0
            cs, sn = cos(f), sin(f)
        end
        if pendingBurst and c and c.E[pendingBurst] then
            local dx, dy = (c.E[pendingBurst] - pE) * k, (c.N[pendingBurst] - pN) * k
            local col = db.routeColor
            NS.FX.Burst(overlay, dx * cs + dy * sn, -dx * sn + dy * cs, col[1], col[2], col[3])
        end
        if grindE then
            local sx, sy = grindE * cs + grindN * sn, -grindE * sn + grindN * cs
            local len = sqrt(sx * sx + sy * sy)
            if len > 0 then NS.FX.Sparks(overlay, 0, 0, sx / len, sy / len, 2) end
        end
    end
    pendingBurst = nil

    trailLines:Finish(); shadowLines:Finish(); routeLines:Finish(); guideLines:Finish(); pointDots:Finish()
    nodeIcons:Finish(); nodeRings:Finish()

    if db.showDot then
        local r, g, b = HSV(now * 0.06)
        local pulse = 0.5 + 0.5 * sin(now * 3)
        playerDot:SetVertexColor(r, g, b, 1)
        playerGlow:SetVertexColor(r, g, b, 0.45 + 0.25 * pulse)
        playerGlow:SetSize(26 + 6 * pulse, 26 + 6 * pulse)
        playerDot:Show(); playerGlow:Show()
    else
        playerDot:Hide(); playerGlow:Hide()
    end
end

-------------------------------------------------------------------------------
-- World map: the active route drawn on its zone map (redrawn only on change)
-------------------------------------------------------------------------------
local wm = {}

local function WorldMapCanvas()
    return WorldMapFrame and WorldMapFrame.ScrollContainer and WorldMapFrame.ScrollContainer.Child
end

local function SetupWorldMap(canvas)
    local f = CreateFrame("Frame", nil, canvas)
    f:SetAllPoints(canvas)
    f:EnableMouse(false)
    wm.frame = f
    wm.shadow = NewLinePool("ARTWORK", 0, f)
    wm.lines = NewLinePool("ARTWORK", 2, f)
    wm.nodes = NewTexPool(MEDIA .. "Dot", "OVERLAY", 0, f)
    wm.dots = NewTexPool(MEDIA .. "Dot", "OVERLAY", 1, f)
    wm.ring = f:CreateTexture(nil, "OVERLAY", nil, 3)
    wm.ring:SetTexture(MEDIA .. "Ring")
    wm.glow = f:CreateTexture(nil, "OVERLAY", nil, 2)
    wm.glow:SetTexture(MEDIA .. "Glow")
    wm.glow:SetBlendMode("ADD")
end

-- Sit with the map's link/travel lines: above the terrain art (including
-- EllesmereUI's map reveal layer), below quest and town icons.
local function WorldMapLevel(canvas)
    local mgr = WorldMapFrame.GetPinFrameLevelsManager and WorldMapFrame:GetPinFrameLevelsManager()
    if mgr and mgr.GetValidFrameLevel then
        local ok, level = pcall(mgr.GetValidFrameLevel, mgr, "PIN_FRAME_LEVEL_MAP_LINK")
        if ok and level then return level end
        ok, level = pcall(mgr.GetValidFrameLevel, mgr, "PIN_FRAME_LEVEL_MAP_EXPLORATION")
        if ok and level then return level + 1 end
    end
    return canvas:GetFrameLevel() + 100
end

-- Distance in yards from a map point (0-1) to a stretch of route.
local function NearYards(c, px, py, x1, y1, x2, y2)
    local ax, ay = (x1 - px) * c.yw, (y1 - py) * c.yh
    local bx, by = (x2 - px) * c.yw, (y2 - py) * c.yh
    local dx, dy = bx - ax, by - ay
    local len2 = dx * dx + dy * dy
    local t = 0
    if len2 > 0 then t = max(0, min(1, -(ax * dx + ay * dy) / len2)) end
    local ex, ey = ax + t * dx, ay + t * dy
    return sqrt(ex * ex + ey * ey)
end

local function DrawWorldMap()
    local canvas = WorldMapCanvas()
    if not canvas or not WorldMapFrame:IsShown() then return end
    local route = ActiveRoute()
    local c = route and Compiled()
    local mapID = WorldMapFrame:GetMapID()
    local show = c and mapID == c.mapID and db.showWorldMap
    local target = c and c.target
    local W, H = canvas:GetWidth(), canvas:GetHeight()
    -- Fog: only the route near where you stand (no fixed start point).
    local fogX, fogY
    if show and db.worldMapFog and c.yw then
        local pos = C_Map.GetPlayerMapPosition(c.mapID, "player")
        if pos then fogX, fogY = pos:GetXY() end
        if not NS.Num(fogX) or not NS.Num(fogY) then fogX, fogY = nil, nil end
    end
    local key = table.concat({ tostring(show), tostring(route and route.name), tostring(target), tostring(c and c.iron),
        tostring(db.showNodes), floor(W), floor(H), tostring(db.worldMapFog),
        fogX and floor(fogX * c.yw / 15) or "-", fogY and floor(fogY * c.yh / 15) or "-" }, "|")
    if key == wm.key and c == wm.compiled then return end
    wm.key, wm.compiled = key, c

    if not wm.frame then SetupWorldMap(canvas) end
    if not show or W < 10 then
        wm.frame:Hide()
        return
    end
    wm.frame:SetFrameLevel(WorldMapLevel(canvas))
    wm.frame:Show()
    local fogR = db.fogYards or 300
    local function Visible(x1, y1, x2, y2)
        if not fogX then return not db.worldMapFog end
        return NearYards(c, fogX, fogY, x1, y1, x2 or x1, y2 or y1) <= fogR
    end
    wm.shadow:Begin(); wm.lines:Begin(); wm.nodes:Begin(); wm.dots:Begin()

    local f = wm.frame
    local pts = c.pts
    local n = #pts / 2
    local w = max(2, W / 330)
    local before = target and (target == 1 and n or target - 1)
    for i = 1, n do
        local j = i % n + 1
        if Visible(pts[2 * i - 1], pts[2 * i], pts[2 * j - 1], pts[2 * j]) then
        local x1, y1 = pts[2 * i - 1] * W, -pts[2 * i] * H
        local x2, y2 = pts[2 * j - 1] * W, -pts[2 * j] * H
        local l = wm.shadow:Get()
        l:SetStartPoint("TOPLEFT", f, x1, y1)
        l:SetEndPoint("TOPLEFT", f, x2, y2)
        l:SetThickness(w + 2)
        l:SetColorTexture(0, 0, 0, 0.6)
        l = wm.lines:Get()
        l:SetStartPoint("TOPLEFT", f, x1, y1)
        l:SetEndPoint("TOPLEFT", f, x2, y2)
        l:SetThickness(w)
        local col = SegmentColour(c, i)
        if i == before or i == target then
            local highlight = col == RED and RED or WHITE
            l:SetThickness(w + 1)
            l:SetColorTexture(highlight[1], highlight[2], highlight[3], 1)
        else
            l:SetColorTexture(col[1], col[2], col[3], 0.95)
        end
        local d = wm.dots:Get()
        d:SetSize(w * 2.2, w * 2.2)
        d:SetPoint("CENTER", f, "TOPLEFT", x1, y1)
        d:SetVertexColor(col[1], col[2], col[3], 1)
        end
    end

    if c.other then
        local pts = c.other.pts
        local col = c.iron and db.routeColor or RED
        for i = 1, #pts - 2, 2 do
            if Visible(pts[i], pts[i + 1], pts[i + 2], pts[i + 3]) then
                local l = wm.lines:Get()
                l:SetStartPoint("TOPLEFT", f, pts[i] * W, -pts[i + 1] * H)
                l:SetEndPoint("TOPLEFT", f, pts[i + 2] * W, -pts[i + 3] * H)
                l:SetThickness(w)
                l:SetColorTexture(col[1], col[2], col[3], 0.95)
            end
        end
    end
    if db.showNodes and route.nodes then
        local nodes = route.nodes
        for i = 1, #nodes, 3 do
            if Visible(nodes[i], nodes[i + 1]) then
                local tex, known = NodeTexture(nodes[i + 2])
                local d = wm.nodes:Get()
                d:SetTexture(tex)
                d:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                d:SetBlendMode("BLEND")
                d:SetDesaturated(not known)
                d:SetSize(w * (known and 5 or 4), w * (known and 5 or 4))
                d:SetPoint("CENTER", f, "TOPLEFT", nodes[i] * W, -nodes[i + 1] * H)
                d:SetVertexColor(1, 1, 1, known and 1 or 0.8)
            end
        end
    end

    if target and target <= n then
        local x, y = pts[2 * target - 1] * W, -pts[2 * target] * H
        wm.ring:ClearAllPoints()
        wm.ring:SetPoint("CENTER", f, "TOPLEFT", x, y)
        wm.ring:SetSize(w * 9, w * 9)
        wm.ring:Show()
        wm.glow:ClearAllPoints()
        wm.glow:SetPoint("CENTER", f, "TOPLEFT", x, y)
        wm.glow:SetSize(w * 14, w * 14)
        wm.glow:SetVertexColor(0.3, 0.95, 1, 0.6)
        wm.glow:Show()
    else
        wm.ring:Hide()
        wm.glow:Hide()
    end

    wm.shadow:Finish(); wm.lines:Finish(); wm.nodes:Finish(); wm.dots:Finish()
end

local lastE, lastN, lastCont, lastTickAt, missSince, lastCourse
local function Tick()
    local now = GetTime()
    local cont, pE, pN = PlayerWorld()
    if not cont then
        -- Position unavailable (protected, loading, instance). A blip of a
        -- frame or two keeps the last drawing; only a real gap hides it, so
        -- the overlay doesn't flash.
        Diag("position")
        DrawWorldMap()
        NS.grinding = false
        if lastCourse then lastCourse.reverseTime = 0 end
        lastCont = nil
        missSince = missSince or now
        if now - missSince > 0.25 then
            overlay:Hide()
            arrow:Hide()
        end
        return
    end
    missSince = nil
    RecordTrail(cont, pE, pN, now)
    local dE, dN, dt
    if lastCont == cont then
        local ex, ey = pE - lastE, pN - lastN
        dt = now - lastTickAt
        local d2 = ex * ex + ey * ey
        -- Reject jitter, long position gaps and teleports.
        if dt > 0 and dt <= 0.5 and d2 > 0.0025 and d2 <= (100 * dt) ^ 2 then
            dE, dN = ex, ey
            moveDE, moveDN = dE, dN
        end
    end
    lastE, lastN, lastCont, lastTickAt = pE, pN, cont, now

    local c = Compiled()
    local target, grindE, grindN
    if c and c.cont == cont then
        local distance2, lineE, lineN, segment, courseE, courseN = UpdateBranch(c, pE, pN)
        local courseStep = lastCourse == c.course and dE
        UpdateCourse(c, segment, courseE or lineE, courseN or lineN, courseStep, dN, dt)
        target = UpdateTarget(c, segment, pE, pN, now)
        if dE and distance2 <= GRIND_YARDS * GRIND_YARDS then
            local along = lineE * dE + lineN * dN
            if along > 0 then grindE, grindN = lineE, lineN
            elseif along < 0 then grindE, grindN = -lineE, -lineN
            else grindE, grindN = dE, dN end
        end
    elseif c then
        c.target = nil
        c = nil
    end
    if lastCourse and (not c or lastCourse ~= c.course) then lastCourse.reverseTime = 0 end
    lastCourse = c and c.course
    NS.grinding = grindE ~= nil
    UpdateArrow(c, target, pE, pN)
    DrawWorldMap()

    if Minimap:IsVisible() then
        SyncOverlay()
        overlay:Show()
        Draw(c, target, pE, pN, now, grindE, grindN)
    else
        overlay:Hide()
    end
end

-------------------------------------------------------------------------------
-- Actions
-------------------------------------------------------------------------------
function NS.SkipTarget()
    local c = Compiled()
    if c and c.target then
        c.course.skipped[c.keys[c.target]] = GetTime() + SKIP_SECONDS
        c.target = nil
    end
end

local function Resync()
    local c = Compiled()
    local cont, pE, pN = PlayerWorld()
    if c and cont and c.cont == cont then
        local _, _, _, segment = UpdateBranch(c, pE, pN)
        c.segment = segment
        if UpdateTarget(c, segment, pE, pN, GetTime()) then
            Print("Pointing at the next waypoint along the route.")
        else
            Print("No next waypoint on this route.")
        end
    else
        Print("You are not on this route's continent.")
    end
end

local UseRoute

-- Entering a zone that has a route while the active route is for another zone:
-- switch to that zone's route.
function NS.PickRouteForZone()
    local map, zone = ZoneMapForPlayer()
    if not map then return end
    local active = ActiveRoute()
    if active and (active.mapID == map or (zone and active.zone == zone)) then return end
    for name, route in pairs(db.routes) do
        if route.mapID == map or (zone and route.zone == zone) then
            UseRoute(name)
            return
        end
    end
end

function UseRoute(name)
    if not db.routes[name] then
        Print("No route called '" .. tostring(name) .. "'. Type /farm list")
        return
    end
    db.active = name
    courseRoute, course = nil, nil
    Invalidate()
    Print("Active route: " .. name)
end

local function AddRoute(route, makeActive)
    db.routes[route.name] = route
    if makeActive or not db.active then UseRoute(route.name) end
end

-- Paste / copy box
local box
local function ShowBox(title, text, acceptLabel, onAccept)
    if not box then
        local f = CreateFrame("Frame", "ForeverFarmRouteBox", UIParent)
        f:SetSize(540, 280)
        f:SetPoint("CENTER")
        f:SetFrameStrata("DIALOG")
        f:EnableMouse(true)
        f:SetMovable(true)
        f:RegisterForDrag("LeftButton")
        f:SetScript("OnDragStart", f.StartMoving)
        f:SetScript("OnDragStop", f.StopMovingOrSizing)
        local bg = f:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(0.04, 0.05, 0.07, 0.94)
        local bar = f:CreateTexture(nil, "BORDER")
        bar:SetPoint("TOPLEFT"); bar:SetPoint("TOPRIGHT"); bar:SetHeight(2)
        bar:SetColorTexture(0.25, 0.9, 1, 1)
        f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        f.title:SetPoint("TOPLEFT", 12, -10)

        local sf = CreateFrame("ScrollFrame", "ForeverFarmRouteBoxScroll", f, "UIPanelScrollFrameTemplate")
        sf:SetPoint("TOPLEFT", 12, -32)
        sf:SetPoint("BOTTOMRIGHT", -32, 44)
        local sbg = f:CreateTexture(nil, "BORDER")
        sbg:SetPoint("TOPLEFT", sf, -4, 4); sbg:SetPoint("BOTTOMRIGHT", sf, 4, -4)
        sbg:SetColorTexture(0, 0, 0, 0.5)

        local eb = CreateFrame("EditBox", nil, sf)
        eb:SetMultiLine(true)
        eb:SetAutoFocus(false)
        eb:SetMaxLetters(0)
        eb:SetFontObject(ChatFontNormal)
        eb:SetWidth(480)
        eb:SetHeight(200)
        eb:SetScript("OnEscapePressed", function() f:Hide() end)
        sf:SetScrollChild(eb)
        sf:SetScript("OnMouseDown", function() eb:SetFocus() end)
        f.edit = eb

        f.ok = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        f.ok:SetSize(110, 22)
        f.ok:SetPoint("BOTTOMRIGHT", -12, 12)
        local close = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        close:SetSize(90, 22)
        close:SetPoint("RIGHT", f.ok, "LEFT", -8, 0)
        close:SetText(CLOSE or "Close")
        close:SetScript("OnClick", function() f:Hide() end)
        tinsert(UISpecialFrames, "ForeverFarmRouteBox")
        box = f
    end
    box.title:SetText(title)
    box.edit:SetText(text or "")
    box.ok:SetText(acceptLabel or OKAY or "OK")
    box.ok:SetShown(onAccept ~= nil)
    box.ok:SetScript("OnClick", function()
        if onAccept and onAccept(box.edit:GetText()) ~= false then box:Hide() end
    end)
    box:Show()
    box.edit:SetFocus()
    if text and text ~= "" then box.edit:HighlightText() end
end

local function ImportText(text)
    local route, err = NS.ParseImport(text)
    if not route then
        Print("Import failed: " .. err)
        return false
    end
    AddRoute(route, true)
    Print(string.format("Imported '%s' (%d points).", route.name, #route.pts / 2))
end

local recording
local function RecordPoint()
    local route = recording and db.routes[recording]
    if not route then
        Print("Start a route first: /farm new <name>")
        return
    end
    local map, zone = ZoneMapForPlayer()
    if map ~= route.mapID then
        Print("You are in a different zone than this route.")
        return
    end
    local pos = C_Map.GetPlayerMapPosition(map, "player")
    if not pos then return end
    local x, y = pos:GetXY()
    if not NS.Num(x) or not NS.Num(y) then return end
    route.pts[#route.pts + 1] = x
    route.pts[#route.pts + 1] = y
    Invalidate()
    Print(string.format("Point %d added (%.1f, %.1f).", #route.pts / 2, x * 100, y * 100))
end

-------------------------------------------------------------------------------
-- Slash command
-------------------------------------------------------------------------------
local function Toggle(key, label)
    db[key] = not db[key]
    Print(label .. (db[key] and " on" or " off"))
end

-- /farm hide: switch everything off until /farm show (or /farm hide again).
local function SetDisabled(off)
    db.disabled = off and true or false
    if off then
        lastCont = nil
        if lastCourse then lastCourse.reverseTime = 0 end
        overlay:Hide()
        arrow:Hide()
        if wm.frame then wm.frame:Hide() end
        if NS.FX then NS.FX.Clear() end
        if _G.ForeverFarmRouteCelebration then _G.ForeverFarmRouteCelebration:Hide() end
        local hdb = ForeverFarmHUDDB and ForeverFarmHUDDB.hud
        if hdb and hdb.enabled and SlashCmdList.FOREVERFARMHUD then SlashCmdList.FOREVERFARMHUD("toggle") end
        Print("Off. Type /farm show (or /farm hide) to turn it back on.")
    else
        Print("On.")
    end
    wm.key = nil
end

local HELP = {
    "/farm  - toggle the farming HUD    /farm hide | show  - switch FarmRoute off/on",
    "/farm import | export | list | use <name> | delete <name>",
    "/farm route | arrow | trail | dot | nodes | map  - show/hide each part",
    "Hold Shift over the HUD to mouse over ore blips (game tooltip)",
    "/farm skip  - skip this point     /farm sync  - find the next waypoint",
    "/farm lock  - lock arrow (click-through)    /farm trail clear",
    "/farm fog [yd]  - world map: whole route / only near you",
    "/farm track  - swap Find Herbs / Find Minerals while the HUD is open (on by default)",
    "/farm icons <8-32>  - node icon size on the HUD    /fdg  - gathering settings",
    "/farm scan [on | off]  - FDG's farming map on the HUD; hides the game's own dots (off by default)",
    "/farm dots <1-3>  - size of the game's node dots on the HUD (1.6 by default)",
    "/farm static  - HUD map keeps north up / turns with you (north up by default)",
    "/farm bindings  - wheel down = Interact, wheel up = Dire Wolf, middle click = auto run; off by default",
    "/farm fx  - effects on/off    /farm combo <sec>  - gathering combo window",
    "/farm test [1-3]  - preview mining loot    /farm test herb  - preview an herb stack and bonus",
    "/farm fade <sec> | reach <yd> | width <px> | scale <n>",
    "/farm new <name>, /farm add, /farm undo  - record your own route",
}

SLASH_FOREVERFARMROUTE1 = "/farm"
SLASH_FOREVERFARMROUTE2 = "/ffr"
SLASH_FOREVERFARMROUTESTATIC1 = "/static"
SlashCmdList.FOREVERFARMROUTESTATIC = function() SlashCmdList.FOREVERFARMROUTE("static") end
SlashCmdList.FOREVERFARMROUTE = function(msg)
    msg = (msg or ""):match("^%s*(.-)%s*$")
    local cmd, rest = msg:match("^(%S*)%s*(.-)$")
    cmd = (cmd or ""):lower()

    if cmd == "hide" then
        SetDisabled(not db.disabled)
        return
    elseif cmd == "show" then
        if db.disabled then SetDisabled(false) end
        return
    elseif db.disabled and cmd ~= "help" then
        Print("FarmRoute is off. Type /farm show to turn it on.")
        return
    end

    if cmd == "" or cmd == "toggle" then
        if SlashCmdList.FOREVERFARMHUD then
            SlashCmdList.FOREVERFARMHUD("toggle")
        else
            Print("ForeverFarmHUD is not loaded.")
        end
    elseif cmd == "help" then
        for _, line in ipairs(HELP) do Print(line) end
    elseif cmd == "import" then
        ShowBox("Paste a FarmRoute import string", "", "Import", ImportText)
    elseif cmd == "export" then
        local route = ActiveRoute()
        if not route then Print("No active route.") return end
        ShowBox("Copy with Ctrl+C: " .. route.name, NS.Export(route))
    elseif cmd == "list" then
        for name, route in pairs(db.routes) do
            Print((name == db.active and "> " or "  ") .. name .. " (" .. (#route.pts / 2) .. " points, " .. (route.zone or "?") .. ")")
        end
    elseif cmd == "use" then
        UseRoute(rest)
    elseif cmd == "delete" then
        if db.routes[rest] then
            db.routes[rest] = nil
            if db.active == rest then db.active = next(db.routes); Invalidate() end
            Print("Deleted " .. rest)
        else
            Print("No route called '" .. rest .. "'.")
        end
    elseif cmd == "route" then
        Toggle("showRoute", "Route lines")
    elseif cmd == "arrow" then
        Toggle("showArrow", "Arrow")
    elseif cmd == "trail" then
        if rest:lower() == "clear" then ClearTrail() Print("Trail cleared.")
        else Toggle("showTrail", "Trail") end
    elseif cmd == "dot" then
        Toggle("showDot", "Player dot")
    elseif cmd == "nodes" then
        Toggle("showNodes", "Ore spawn markers")
    elseif cmd == "map" then
        Toggle("showWorldMap", "Route on the world map")
    elseif cmd == "diag" then
        if rest:lower() == "clear" then db.diag = nil Print("Diagnostics cleared.") return end
        local d = db.diag or {}
        local any = false
        for key, e in pairs(d) do
            any = true
            Print(string.format("%s: %d time(s), last %s%s", key, e.count, tostring(e.last), e.combat and " (in combat)" or ""))
        end
        if not any then Print("No protected or missing values recorded.") end
    elseif cmd == "errors" then
        local list = db.errors or {}
        if rest:lower() == "clear" then db.errors = nil Print("Error log cleared.") return end
        Print(#list .. " recorded error(s)" .. (#list > 0 and " (/farm errors clear to reset):" or ""))
        for i, e in ipairs(list) do Print(i .. ". " .. (e.count and (e.count .. "x ") or "") .. e.msg) end
    elseif cmd == "debugloot" then
        Toggle("debugLoot", "Loot debug messages")
    elseif cmd == "track" then
        local G = NS.Gathering
        if not (G and G.db and G.UpdateAutoTracking) then
            Print("Gathering isn't loaded: fully restart the game (a /reload doesn't load new addon files).")
            return
        end
        local hud = G.db.hud
        hud.autoTrackingWithFarmHUD = hud.autoTrackingWithFarmHUD == false
        if hud.autoTrackingWithFarmHUD and hud.trackingSwapsPaused and G.SetTrackingSwapsPaused then
            G:SetTrackingSwapsPaused(false)
        end
        G:UpdateAutoTracking()
        Print("Herb/Mineral tracking swap while the HUD is open: " .. (hud.autoTrackingWithFarmHUD and "on" or "off"))
    elseif cmd == "icons" then
        local G = NS.Gathering
        local n = tonumber(rest)
        if not (G and G.db) then Print("Gathering isn't loaded.") return end
        if n then G.db.hud.farmIconSize = math.max(8, math.min(32, math.floor(n + 0.5))) end
        Print("Node icon size on the HUD: " .. (G.db.hud.farmIconSize or 22))
    elseif cmd == "dots" then
        local n = tonumber(rest)
        if n then db.dotScale = math.max(1, math.min(3, n)) end
        Print("Node dot size on the HUD: " .. db.dotScale .. "x  (/farm dots <1-3>)")
    elseif cmd == "scan" then
        if rest:lower() == "off" then db.nodeScan = false
        elseif rest:lower() == "on" then db.nodeScan = true
        else db.nodeScan = not db.nodeScan end
        local gathering = NS.Gathering
        if not db.nodeScan and gathering and gathering.QuickScanner then gathering.QuickScanner:StopFarmMinimap() end
        Print("FDG quick scan and farming map: " .. (db.nodeScan and "on" or "off"))
    elseif cmd == "static" then
        db.staticMap = not db.staticMap
        Print("HUD map: " .. (db.staticMap and "north up" or "turns with you")
            .. (InCombatLockdown() and " (after combat)" or ""))
    elseif cmd == "bindings" then
        db.bindings = not db.bindings
        Print("Wheel down = Interact, wheel up = Dire Wolf, middle button = auto run: " .. (db.bindings and "on" or "off")
            .. (InCombatLockdown() and " (after combat)" or ""))
        if NS.SyncBindings then NS.SyncBindings()
        else Print("Bindings.lua isn't loaded: fully restart the game (a /reload doesn't load new addon files).") end
    elseif cmd == "fx" then
        Toggle("showFx", "Effects and gathering celebrations")
    elseif cmd == "test" then
        if rest:lower() == "herb" then NS.TestHarvestCelebration()
        else NS.TestCelebration(tonumber(rest)) end
    elseif cmd == "combo" and tonumber(rest) then
        db.comboWindow = max(3, min(120, tonumber(rest)))
        Print("Combo: keep gathering within " .. db.comboWindow .. " s")
    elseif cmd == "fog" then
        db.worldMapFog = not db.worldMapFog
        if tonumber(rest) then db.fogYards = max(50, min(2000, tonumber(rest))) end
        Print(db.worldMapFog and ("World map: only the route within " .. db.fogYards .. " yd of you")
            or "World map: whole route")
    elseif cmd == "skip" or cmd == "next" then
        NS.SkipTarget()
    elseif cmd == "sync" or cmd == "nearest" then
        Resync()
    elseif cmd == "lock" then
        Toggle("arrowLocked", "Arrow lock")
        ApplyArrowSettings()
    elseif cmd == "fade" and tonumber(rest) then
        db.trailSeconds = max(5, min(600, tonumber(rest)))
        Print("Trail fades over " .. db.trailSeconds .. " s")
    elseif cmd == "reach" and tonumber(rest) then
        db.reachYards = max(5, min(100, tonumber(rest)))
        Print("A point counts as reached within " .. db.reachYards .. " yd")
    elseif cmd == "width" and tonumber(rest) then
        db.routeWidth = max(1, min(12, tonumber(rest)))
    elseif cmd == "scale" and tonumber(rest) then
        db.yardScale = max(0.25, min(4, tonumber(rest)))
        Print("Minimap distance scale " .. db.yardScale)
    elseif cmd == "new" and rest ~= "" then
        local map, zone = ZoneMapForPlayer()
        if not map then Print("Cannot read your zone here.") return end
        AddRoute({ name = rest, mapID = map, zone = zone, pts = {} }, true)
        recording = rest
        Print("Recording '" .. rest .. "' in " .. (zone or "?") .. ". Walk the route and type /farm add at each turn.")
    elseif cmd == "add" then
        RecordPoint()
    elseif cmd == "undo" then
        local route = recording and db.routes[recording]
        if route and #route.pts >= 2 then
            route.pts[#route.pts] = nil
            route.pts[#route.pts] = nil
            Invalidate()
            Print("Removed the last point.")
        end
    else
        for _, line in ipairs(HELP) do Print(line) end
    end
end

-------------------------------------------------------------------------------
-- Startup
-------------------------------------------------------------------------------
local driver = CreateFrame("Frame")
driver:RegisterEvent("ADDON_LOADED")
driver:RegisterEvent("PLAYER_ENTERING_WORLD")
driver:RegisterEvent("ZONE_CHANGED_NEW_AREA")
driver:RegisterEvent("MODIFIER_STATE_CHANGED")
driver:SetScript("OnEvent", function(self, event, arg1)
    if event == "MODIFIER_STATE_CHANGED" then
        if db and not db.disabled then ApplyHoldMouse() end
    elseif event == "ADDON_LOADED" and arg1 == ADDON then
        ForeverFarmRouteDB = ForeverFarmRouteDB or {}
        CopyDefaults(DEFAULTS, ForeverFarmRouteDB)
        db = ForeverFarmRouteDB
        db.grindYards = GRIND_YARDS
        db.dir, db.target = nil, nil
        -- 2026-11-20: the trail now lasts about 10 s; move saved settings over once.
        if not db.trail10 then db.trailSeconds, db.trail10 = 10, true end
        -- 2026-11-20: FDG's farming map hid the game's dots on /farm and made
        -- herb/ore swaps erratic; switch it off once for saved settings.
        if not db.scanOff3 then db.nodeScan, db.scanOff3 = false, true end
        -- 2026-11-20: back to a north-up HUD map (a test left it rotating, and
        -- each scan turns it north-up, so it flipped every swap).
        if not db.static2 then db.staticMap, db.static2 = true, true end
        NS.db = db
        NS.FlushPendingErrors()
        -- Shift is the default hold-to-mouse key (once; your later choice in
        -- ForeverFarmHUD's settings is kept).
        local hdb = ForeverFarmHUDDB and ForeverFarmHUDDB.hud
        if hdb and not db.shiftDefaultDone then
            if hdb.mouseModifier == nil or hdb.mouseModifier == "NONE" then hdb.mouseModifier = "SHIFT" end
            db.shiftDefaultDone = true
        end
        for _, str in ipairs(NS.BUILTIN_ROUTES or {}) do
            local route = NS.ParseImport(str)
            -- Load a built-in route once, and again whenever its string changes.
            if route and db.builtinSeen[route.name] ~= str then
                db.builtinSeen[route.name] = str
                db.routes[route.name] = route
                db.active = db.active or route.name
            end
        end
        if db.active and not db.routes[db.active] then db.active = next(db.routes) end
        ApplyArrowSettings()
        LinkEllesmere()

        local acc, guard = 0, 0
        self:SetScript("OnUpdate", function(_, elapsed)
            if db.disabled then return end
            acc, guard = acc + elapsed, guard + elapsed
            if guard >= 0.25 then
                guard = 0
                GuardHUD()
                ApplyHoldMouse()
            end
            if acc >= 0.033 then
                acc = 0
                Tick()
            end
        end)
    elseif event == "PLAYER_ENTERING_WORLD" or event == "ZONE_CHANGED_NEW_AREA" then
        if event == "PLAYER_ENTERING_WORLD" then LinkEllesmere() end
        Invalidate()
        if db and not db.disabled then NS.PickRouteForZone() end
    end
end)
