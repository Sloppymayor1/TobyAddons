local ADDON_NAME, FRNS_ = ...; local NS = FRNS_.Gathering

-- Live observations share a session cache across tracking changes. Refined
-- zone positions are also saved in the account's SavedVariables for reuse;
-- saved locations alone never establish that a node is currently present.
NS.ManualNodeHoverEnabled = true
local nodes, icons = {}, {}
local collected = {}
local overlays = {}
local overlayMode
local renderStates=setmetatable({}, {__mode="k"})
NS.GatheringNodeCache = nodes
-- Prototype-only read access. Extra returns are coordinate history, never live spawns.
_G.FDGWorldMarkersNodeSource = function() return nodes, NS.db and NS.db.nodeLocations, NS.BundledNodeLocations end
local driver = CreateFrame("Frame")
driver:Hide()
NS.GatheringNodeDriver = driver
local scan, nextScan, nextDraw, nextKind, nextPrune = nil, 0, 0, 0, 0
local validation, validationCursor, nextValidation = nil, 0, 0
local validationReady = {}
local TRACKING_SETTLE, EMPTY_RECHECK = 1, 0.5
local MANUAL_EMPTY_STILL, MANUAL_EMPTY_MOVING = 0.15, 0.25
local cursors = {}
local locationIndexes = {}
local activeKind, activeTreasure, currentMap, reportedUnavailable
local playerMoving, lastMovement, lastPosition = false, -math.huge, nil
local lootOpen = false
local TTL, MAX_NODES, MAX_ICONS = 180, 128, 64
local FARM_NODE_TTL = 600 -- FarmRoute: see GetGatheringObservationTTL
local PIXEL_STEP, PROBES_PER_FRAME, BUDGET_MS = 12, 12, 0.5
local GRID_DIVISIONS = 3
local CENTER_VERSION = 2 -- Prior axis-only verification could accept a connected midpoint.
local function public(value) return not (issecretvalue and issecretvalue(value)) end
local function number(value)
    return public(value) and type(value) == "number" and value == value and math.abs(value) < math.huge
end
local function gatheringSpellKind(spellID)
    if spellID==2366 then return "herb" end
    if spellID==2575 then return "ore" end
    -- Accept another gather rank only when the client's public localized name
    -- agrees with its known gathering spell. Tracking and unrelated casts differ.
    local getter=C_Spell and C_Spell.GetSpellName or GetSpellInfo
    if not getter then return end
    local ok,name=pcall(getter,spellID)
    if not ok or not public(name) or type(name)~="string" or name=="" then return end
    for _,entry in ipairs({{2366,"herb"},{2575,"ore"}}) do
        local valid,base=pcall(getter,entry[1])
        if valid and public(base) and type(base)=="string" and name==base then return entry[2] end
    end
end
local function hasNodeSource(kind)
    if kind ~= "treasure" then
        return NS.HasGatheringProfession and NS:HasGatheringProfession(kind)
    end
    return NS.db and NS.db.hud.includeTreasure and NS.CanUseFindTreasure and NS:CanUseFindTreasure()
end
local function isKindActive(kind)
    if kind == "treasure" then return activeTreasure end
    return kind == activeKind
end
function NS:GetCursorSweepTrackingKind()
    local ok,spell,treasure=pcall(self.GetActiveGatheringTracking,self)
    if not ok or not public(spell) then return 'none' end
    if spell==2383 and hasNodeSource('herb') then return 'herb' end
    if spell==2580 and hasNodeSource('ore') then return 'ore' end
    if public(treasure) and treasure==true and hasNodeSource('treasure') then return 'treasure' end
    return 'none'
end
function NS:IsCursorSweepKindTracked(kind)
    local ok,spell,treasure=pcall(self.GetActiveGatheringTracking,self)
    if not ok or not public(spell) then return false end
    if kind=='treasure' then return public(treasure) and treasure==true and hasNodeSource(kind) end
    return hasNodeSource(kind) and (kind=='herb' and spell==2383 or kind=='ore' and spell==2580) or false
end
local function updateActiveKind()
    local ok, spell, treasure = pcall(NS.GetActiveGatheringTracking, NS)
    if not ok or not public(spell) then spell = nil end
    treasure = ok and public(treasure) and treasure == true and hasNodeSource("treasure") or false
    local kind = spell == 2383 and "herb" or spell == 2580 and "ore" or nil
    if kind and not hasNodeSource(kind) then kind = nil end
    kind = kind or (treasure and "treasure" or nil)
    if kind == activeKind and treasure == activeTreasure then return end
    local now = GetTime()
    if kind and kind ~= "treasure" and kind ~= activeKind then validationReady[kind] = now + TRACKING_SETTLE end
    if treasure and not activeTreasure then validationReady.treasure = now + TRACKING_SETTLE end
    -- Experimental memories retain observed arrows until a matching fresh
    -- reading replaces them. Legacy memories keep their one-change limit.
    for _, node in ipairs(nodes) do
        if not node.cursorSweepObservation and not isKindActive(node.kind) then node.elevationTag = nil end
        if node.kind == activeKind or node.kind == kind or treasure ~= activeTreasure and node.kind == "treasure" then
            node.missingAt = nil
        end
    end
    -- Suspended rough observations follow the same one-change arrow limit.
    for _, cursor in pairs(cursors) do
        for _, group in ipairs(cursor.found or {}) do
            if not isKindActive(group.kind) then group.elevationTag = nil end
        end
    end
    if treasure ~= activeTreasure then cursors = {} end
    scan, validation = nil, nil
    nextScan, nextValidation, nextDraw = 0, 0, 0
    activeKind, activeTreasure = kind, treasure
end
local elevationFiles = {
    ["interface/minimap/minimap-positionarrows"] = true,
    ["interface/minimap/minimap-positionarrowup"] = true,
    ["interface/minimap/minimap-positionarrowdown"] = true,
}
local elevationFileIDs
local function elevationAsset(asset)
    local path = asset:gsub("\\", "/"):lower():gsub("%.blp$", "")
    if elevationFiles[path] then return path end
    local fileID = tonumber(asset)
    if fileID and GetFileIDFromPath then
        if not elevationFileIDs then
            elevationFileIDs = {}
            for name in pairs(elevationFiles) do
                local ok, id = pcall(GetFileIDFromPath, name .. ".blp")
                if not ok or not number(id) or id <= 0 then ok, id = pcall(GetFileIDFromPath, name) end
                if ok and number(id) and id > 0 then elevationFileIDs[id] = name end
            end
        end
        return elevationFileIDs[fileID]
    end
end
local function elevationTag(label)
    -- Keep the exact client-supplied image and crop, without inferring height
    -- from map positions or changing an observed symbol.
    for tag, asset in label:gmatch("(|T([^:|]+)[^|]*|t)") do
        if elevationAsset(asset) then return tag end
    end
    for tag, atlas in label:gmatch("(|A:([^:|]+)[^|]*|a)") do
        atlas = atlas:lower()
        if atlas == "minimap-positionarrowup" or atlas == "minimap-positionarrowdown" then return tag end
    end
end
local function elevationSide(tag)
    local asset = tag:match("^|T([^:|]+)") or tag:match("^|A:([^:|]+)")
    if not asset then return end
    local path = elevationAsset(asset) or asset:lower()
    if path == "interface/minimap/minimap-positionarrowup" or path == "minimap-positionarrowup" then return "up" end
    if path == "interface/minimap/minimap-positionarrowdown" or path == "minimap-positionarrowdown" then return "down" end
    if path ~= "interface/minimap/minimap-positionarrows" then return end
    local fields = {}
    for field in (tag:sub(3, -3) .. ":"):gmatch("(.-):") do fields[#fields + 1] = field end
    local height, top, bottom = tonumber(fields[7]), tonumber(fields[10]), tonumber(fields[11])
    if not height or height <= 0 or not top or not bottom or top < 0 or bottom <= top or bottom > height then return end
    -- Blizzard's 16x32 PositionArrows sheet has up in its top half and down
    -- in its bottom half. Use the observed crop only to choose the anchor.
    if bottom <= height / 2 then return "up" end
    if top >= height / 2 then return "down" end
end
local function clean(text)
    return text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|T.-|t", "")
        :gsub("|A.-|a", ""):gsub("\226\128\153", "'"):gsub("%s*%b()", ""):match("^%s*(.-)%s*$")
end
local function resourceFor(label, kind)
    local entry = NS:LookupNodeResource(clean(label), kind)
    if not entry then return end
    return {id = entry.id, kind = kind, name = clean(label), icon = NS:GetNodeResourceIcon(entry, kind)}
end

-- A grey resource title is the client's underground hint. Profession-line
-- grey means trivial gathering difficulty and must never set this flag.
-- Unknown colors preserve the last observation. Cave metadata is saved only
-- alongside a verified, settled coordinate; it never establishes a live spawn.
local function undergroundTitle(label, line, resource)
    local r, g, b
    for red, green, blue, start in label:gmatch("|c%x%x(%x%x)(%x%x)(%x%x)()") do
        -- Native minimap titles can leave the final color open. A new color,
        -- a reset or the end of the label ends this span; an arrow's color
        -- must not override a differently colored resource name after it.
        local finish = label:find("|[cr]", start)
        local text = label:sub(start, finish and finish - 1 or -1)
        local colored = resourceFor(text, resource.kind)
        if colored and colored.id == resource.id then
            r, g, b = tonumber(red, 16) / 255, tonumber(green, 16) / 255, tonumber(blue, 16) / 255
            break
        end
    end
    if not r then
        local color = line.leftColor
        if not public(color) or type(color) ~= "table" then return end
        r, g, b = color.r, color.g, color.b
        if not (number(r) and number(g) and number(b)) then
            if not public(color.GetRGB) or type(color.GetRGB) ~= "function" then return end
            local ok
            ok, r, g, b = pcall(color.GetRGB, color)
            if not ok then return end
        end
    end
    if not (number(r) and number(g) and number(b))
        or math.min(r, g, b) < 0 or math.max(r, g, b) > 1 then return end
    local low, high = math.min(r, g, b), math.max(r, g, b)
    return low >= 0.2 and high <= 0.8 and high - low <= 0.08
end
local function observeUnderground(node, label, line, resource)
    local underground = undergroundTitle(label, line, resource)
    if underground ~= nil then
        node.underground = underground
        if node.locationRecord and node.centered and not node.centerMoving then
            node.locationRecord.underground = underground
        end
    end
end

local function supported()
    return Minimap and (NS.ManualNodeHoverEnabled and type(GetCursorPosition)=="function" or not NS.ManualNodeHoverEnabled and Minimap.SetUsingSoftCursor and Minimap.UpdateMouseoverAtPoint)
        and C_TooltipInfo and C_TooltipInfo.GetMinimapMouseover and C_Minimap and C_Minimap.GetViewRadius
        and C_Map and C_Map.GetBestMapForUnit and C_Map.GetPlayerMapPosition and C_Map.GetMapWorldSize
end

local function nativeIconScale()
    if NS.CursorSweepActive and NS.CursorSweepTrial.iconScale then return NS.CursorSweepTrial.iconScale end
    local scale = NS._minimapIconScale
    if number(scale) and scale > 0 then return scale end
    -- The setter has no getter. Before its first observed write, read the
    -- active skin's setting or Blizzard's Edit Mode value without changing it.
    local module = NS._ellesmereModule
    local config = module and module.db and module.db.profile and module.db.profile.minimap
        or (_EMM_DB and _EMM_DB.profile and _EMM_DB.profile.minimap)
    if config and number(config.iconScale) and config.iconScale > 0 then return config.iconScale / 100 end
    local setting = Enum and Enum.EditModeMinimapSetting and Enum.EditModeMinimapSetting.IconScale
    if setting ~= nil and MinimapCluster and MinimapCluster.GetSettingValue then
        local ok, value = pcall(MinimapCluster.GetSettingValue, MinimapCluster, setting)
        if ok and number(value) and value > 0 then return value / 100 end
    end
    return 1
end

function NS:GetNativeGatheringIconScale() return nativeIconScale() end

local function context()
    local map = C_Map.GetBestMapForUnit("player")
    if not number(map) then return end
    local pos = C_Map.GetPlayerMapPosition(map, "player")
    if not public(pos) or not pos or not pos.GetXY then return end
    local x, y = pos:GetXY()
    local w, h = C_Map.GetMapWorldSize(map)
    local radius = C_Minimap.GetViewRadius()
    local width, height, scale = Minimap:GetWidth(), Minimap:GetHeight(), Minimap:GetEffectiveScale()
    local left, bottom = Minimap:GetLeft(), Minimap:GetBottom()
    if not (number(x) and number(y) and number(w) and number(h) and w > 0 and h > 0
        and number(radius) and radius > 0 and number(width) and width > 0 and number(height) and height > 0
        and number(scale) and scale > 0 and number(left) and number(bottom)) then return end
    local getter = GetCVar or (C_CVar and C_CVar.GetCVar)
    local rotating = getter and getter("rotateMinimap") == "1"
    local facing = rotating and GetPlayerFacing and GetPlayerFacing() or 0
    if not number(facing) then return end
    return { map = map, x = x, y = y, w = w, h = h, radius = radius, width = width, height = height,
        scale = scale, iconScale = nativeIconScale(), left = left, bottom = bottom,
        cos = math.cos(facing), sin = math.sin(facing) }
end
local function readContext()
    local ok, ctx = pcall(context)
    return ok and ctx or nil
end
local function distance(a, b, ctx)
    return ((a.x - b.x) * ctx.w)^2 + ((a.y - b.y) * ctx.h)^2
end
local function locationIndex(source, map, slot)
    local rows = type(source) == "table" and source.version == 1
        and type(source.maps) == "table" and source.maps[map]
    if type(rows) ~= "table" then locationIndexes[slot] = nil; return end
    local index = locationIndexes[slot]
    if not index or index.rows ~= rows then
        index = NS:NewNodeLocationIndex(rows)
        locationIndexes[slot] = index
    end
    return index
end
local function matchingLocation(index, node, ctx, radius)
    if not index then return nil, false end
    local match
    local query = index:Query(node.x, node.y, (radius or 3) / ctx.w, (radius or 3) / ctx.h)
    local done = false
    while not done do
        local saved
        saved, done = index:Next(query)
        if saved and saved.kind == node.kind and saved.id == node.id
            and number(saved.uncertainty) and saved.uncertainty > 0 then
            local tolerance = radius or math.min(3, node.uncertainty + saved.uncertainty)
            if distance(node, saved, ctx) <= tolerance^2 then
                if match and (match.x ~= saved.x or match.y ~= saved.y) then return nil, true end
                -- Exact duplicate rows are one location; retain the best precision.
                if not match or saved.uncertainty < match.uncertainty then match = saved end
            end
        end
    end
    return match, false
end
local function reuseLocation(node, saved, fresh)
    if not fresh and node.x == saved.x and node.y == saved.y then
        node.uncertainty = saved.uncertainty
        return true
    end
    for _, checked in ipairs(node.locationChecks or {}) do
        if checked.x == saved.x and checked.y == saved.y
            and (not fresh or checked.time and GetTime() - checked.time <= TRACKING_SETTLE) then
            local matched = checked.matched and (not fresh or checked.single)
            if matched then node.x, node.y, node.uncertainty = saved.x, saved.y, saved.uncertainty end
            return matched
        end
    end
    -- Old saved data can contain a previous false midpoint. A precise saved
    -- coordinate still needs a positive live tooltip before it moves an icon.
    node.locationCandidate = {x = saved.x, y = saved.y}
    return nil
end
local function anchorSavedLocation(node, ctx)
    if not node.centered or not node.centerMoving or node.savedAnchor then return end
    local personal = locationIndex(NS.db.nodeLocations, node.map, "personal")
    local shared = locationIndex(NS.BundledNodeLocations, node.map, "bundled")
    if personal and not personal:Ready() or shared and not shared:Ready() then return end
    -- Moving native dots can lag behind player coordinates. Search only the
    -- measured hitbox, and refuse competing historical positions in that area.
    local radius = math.max(3, node.hitRadius or node.uncertainty)
    local saved, ambiguous = matchingLocation(personal, node, ctx, radius)
    if ambiguous then return end
    if not saved then
        saved, ambiguous = matchingLocation(shared, node, ctx, radius)
        if ambiguous then return end
    end
    if not saved or saved.uncertainty > node.uncertainty then return end
    -- Reading known X/Y is independent of saving a new measurement. Require
    -- a recent, single-resource live read at that exact saved position first.
    if reuseLocation(node, saved, true) then
        node.savedAnchor = saved
        if node.underground == nil and type(saved.underground) == "boolean" then
            node.underground = saved.underground
        end
    end
end
-- Enclose the intersection of two possible-location disks. This retains
-- bounded evidence without assuming the player stands at the resource centre.
-- Identical samples cannot improve precision; precise native centres bypass it.
local function refineGatheredLocation(saved, node, ctx, index)
    if not saved.gatheredApproximate or saved.centerVersion then return end
    local r,R=saved.uncertainty,node.uncertainty
    local dx,dy=(node.x-saved.x)*ctx.w,(node.y-saved.y)*ctx.h
    local d2=dx*dx+dy*dy
    if d2<=0 or d2<=math.abs(r*r-R*R)+0.000001 then return end
    local d=math.sqrt(d2)
    if d>=r+R then return end -- Inconsistent evidence never rewrites history.
    local along=(d2+r*r-R*R)/(2*d)
    local radius=math.sqrt(math.max(0,r*r-along*along))
    if radius>=r or radius<=0 then return end
    local oldX,oldY=saved.x,saved.y
    saved.x=saved.x+dx*(along/d)/ctx.w
    saved.y=saved.y+dy*(along/d)/ctx.h
    saved.uncertainty=radius
    saved.gatherConstraints=math.min(1000000,(number(saved.gatherConstraints) and saved.gatherConstraints or 1)+1)
    index:Move(saved,oldX,oldY)
    if NS.PersonalNodeLocationsChanged then NS:PersonalNodeLocationsChanged() end
end

local function saveLocation(node, ctx, gathered)
    if node.anonymous then return end -- No resource identity to save.
    if node.cursorSweepObservation then return true end -- Trial anchors need ordinary physical confirmation.
    if not NS.db or not gathered and (not node.centered or node.centerMoving) then return end
    local db = NS.db.nodeLocations
    if type(db) ~= "table" or db.version ~= 1 or type(db.maps) ~= "table" then
        db = {version = 1, maps = {}}
        NS.db.nodeLocations = db
    end
    local locations = db.maps[node.map]
    if type(locations) ~= "table" then locations = {}; db.maps[node.map] = locations end
    local group = type(db.groups) == "table" and db.groups[node.map]
    if group ~= "Kalimdor" and group ~= "EasternKingdoms" and group ~= "Dungeons" then
        group = NS.GetNodeLocationMapGroup and NS:GetNodeLocationMapGroup(node.map)
    end
    if group then
        if type(db.groups) ~= "table" then db.groups = {} end
        db.groups[node.map] = group
    end
    local personal = locationIndex(db, node.map, "personal")
    local shared = locationIndex(NS.BundledNodeLocations, node.map, "bundled")
    -- Indexing is incremental. Defer this save rather than searching a large
    -- unindexed tail or accidentally adding a duplicate before it is checked.
    if gathered then
        personal:Build(128)
        if shared then shared:Build(128) end
    end
    if not personal:Ready() or shared and not shared:Ready() then return false end
    local match, ambiguous = matchingLocation(personal, node, ctx)
    -- Nearby spawn points must not be arbitrarily snapped together.
    if ambiguous then return true end
    local precision = 0.75 / (ctx.width * ctx.scale / 2) * ctx.radius
    local function agrees(saved)
        return saved.centerVersion == CENTER_VERSION or not node.measuredCenter
            or distance(saved, node.measuredCenter, ctx) <= precision^2
    end
    if match and node.gatheredApproximate and match.uncertainty <= node.uncertainty then
        refineGatheredLocation(match,node,ctx,personal)
        return true -- Confirmed collection must not wait for a now-absent live dot.
    end
    if match and match.uncertainty <= node.uncertainty then
        local reused = false
        if agrees(match) then reused = reuseLocation(node, match) end
        if reused == nil then return false end
        if not reused then match = nil end
    end
    local previousX, previousY, previousCave = match and match.x, match and match.y, match and match.underground
    if match then
        -- Keep the most precise observation across sessions/zoom levels.
        if match.uncertainty > node.uncertainty then
            local oldX, oldY = match.x, match.y
            match.x, match.y, match.uncertainty = node.x, node.y, node.uncertainty
            match.gatheredApproximate = node.gatheredApproximate or nil
            personal:Move(match, oldX, oldY)
        end
        node.locationRecord = match
    else
        -- The distributed author's list is a fallback, never a replacement
        -- for the player's own coordinates or their additional discoveries.
        local supplied = not node.gatheredApproximate and matchingLocation(shared, node, ctx)
        if supplied and not agrees(supplied) then supplied = nil end
        if supplied and supplied.uncertainty < node.uncertainty then
            if reuseLocation(node, supplied) == nil then return false end
        end
        local row = {id = node.id, kind = node.kind,
            x = node.x, y = node.y, uncertainty = node.uncertainty,
            gatheredApproximate = node.gatheredApproximate or nil}
        if node.underground == nil and supplied and supplied.x == node.x and supplied.y == node.y
            and type(supplied.underground) == "boolean" then
            node.underground = supplied.underground
        end
        locations[#locations + 1] = row
        personal:Append(row)
        node.locationRecord = row
    end
    if type(node.underground) == "boolean" then
        node.locationRecord.underground = node.underground
    elseif type(node.locationRecord.underground) == "boolean" then
        -- The resource was detected live and its coordinate matched. Saved
        -- cave status is a fallback only when the fresh title color is unknown.
        node.underground = node.locationRecord.underground
    end
    -- Only a completed, settled center measurement earns fast-path provenance.
    -- Reusing an old positive hitbox coordinate is not proof of its center.
    local measured = node.measuredCenter
    local trusted = node.trustedCenter
    if not gathered and measured and distance(measured, node.locationRecord, ctx) <= precision^2
        or trusted and trusted.centerVersion == CENTER_VERSION and trusted.x == node.locationRecord.x and trusted.y == node.locationRecord.y then
        node.locationRecord.centerVersion = CENTER_VERSION
    end
    if NS.PersonalNodeLocationsChanged and (not match or previousX ~= node.locationRecord.x
        or previousY ~= node.locationRecord.y or previousCave ~= node.locationRecord.underground) then
        NS:PersonalNodeLocationsChanged()
    end
    -- A later measurement's hitbox rounding cannot revoke provenance earned
    -- by an earlier verified center. Every use still requires a live match.
    return true
end
-- Preserve measured positions; confirmed casts may supply explicitly approximate player positions.
-- Pending writes survive zone/cache clears while large indexes build incrementally.
local pendingGathered = {}
local function saveGathered()
    local entry = pendingGathered[1]
    if entry and (not entry.retryAt or GetTime()>=entry.retryAt) then
        local ok,result=pcall(saveLocation,entry.node,entry.ctx,true)
        if ok and result~=false then table.remove(pendingGathered,1)
        elseif not ok then entry.error,entry.retryAt=tostring(result),GetTime()+1 end
    end
end
local function recentlyCollected(resource, spot, ctx)
    local uncertainty = 2 * PIXEL_STEP / (ctx.width * ctx.scale / 2) * ctx.radius
    for _, node in ipairs(collected) do
        local radius=node.requiresEmpty and math.max(node.radius,9*ctx.iconScale*2*ctx.radius/(ctx.width*ctx.scale))
            or math.max(node.radius,uncertainty)
        if node.map == ctx.map and node.kind == resource.kind and node.id == resource.id
            and distance(node, spot, ctx) < radius^2 then return true end
    end
    return false
end
local function resetGatherClearance()
    if NS.CursorSweepActive and NS.CursorSweepTrial.ResetValidationEvidence then NS.CursorSweepTrial:ResetValidationEvidence() end
    for _,record in ipairs(collected)do
        if record.requiresEmpty then record.emptySince=nil;record.emptyCount=0;record.emptyLast=nil end
    end
end
local function clearGatheredSweepHover(ctx,spot,reliable,nonempty,now)
    if not NS.CursorSweepActive then return false end
    local p=2*ctx.radius/(ctx.width*ctx.scale)
    for i=#collected,1,-1 do
        local record=collected[i]
        if record.requiresEmpty and record.map==ctx.map and isKindActive(record.kind)
            and distance(record,spot,ctx)<=(p*2)^2 then
            if not reliable or nonempty then
                record.emptySince=nil;record.emptyCount=0;record.emptyLast=nil
            else
                local view=string.format('%s:%.2f:%.2f:%.5f:%.2f:%.5f:%.5f',ctx.map,ctx.width,ctx.height,ctx.scale,ctx.radius,ctx.cos,ctx.sin)
                if record.emptyView~=view or not record.emptyLast or now-record.emptyLast>.15 then
                    record.emptySince=now;record.emptyCount=0
                end
                record.emptyView=view;record.emptyLast=now;record.emptyCount=(record.emptyCount or 0)+1
                -- Hold this real scan point to observe clearance, not to infer
                -- absence from a different point or from elapsed time alone.
                NS.CursorSweepTrial.untilTime=math.max(NS.CursorSweepTrial.untilTime or 0,now+.2)
                if record.emptyCount>=3 and now-record.emptySince>=.15 then table.remove(collected,i) end
                return true
            end
        end
    end
    return false
end
local function clear()
    for i = #nodes, 1, -1 do nodes[i] = nil end
    for i = #collected, 1, -1 do collected[i] = nil end
    scan = nil
    cursors = {}
    locationIndexes = {}
    validation, validationCursor, nextValidation = nil, 0, 0
    validationReady = {}
    playerMoving, lastMovement, lastPosition = false, -math.huge, nil
end
-- A first-hit picture is short-lived evidence, not a five-minute position.
function NS:GetGatheringObservationTTL(node)
    local ttl=node.observationTTL or TTL
    if node.manualExpiresAt and number(node.seen) then ttl=math.min(ttl,node.manualExpiresAt-node.seen) end
    if node.cursorSweepObservation and not node.manualRefined and not node.centered and not node.fastLocation then
        ttl=math.min(ttl,30)
    end
    local scan=self.CursorSweepTrial
    if node.cursorSweepObservation and number(node.seen) and self.CursorSweepActive and scan and scan.saved then
        -- One fixed grace window per positive sighting, never a renewal.
        -- Retain it on resume so a fresh native recheck has a chance to run.
        if GetTime()>=node.seen+ttl and scan.traceLastPause and scan.traceLastPause~='none' then
            node.expiryGraceSeen=node.seen
        end
        if node.expiryGraceSeen==node.seen then ttl=ttl+5 end
    end
    -- FarmRoute: remember nodes for a farming lap (10 minutes), not 30-60 s.
    -- Gathered nodes and nodes a later scan finds gone are still removed.
    if node.anonymous and not (node.manualRefined or node.centered or node.fastLocation) and self:FarmHUDOpen() then
        return math.min(ttl,30)
    end
    return math.max(ttl, FARM_NODE_TTL)
end
local function prune(now)
    for i = #nodes, 1, -1 do
        if now - nodes[i].seen > NS:GetGatheringObservationTTL(nodes[i]) then
            local expired=nodes[i]
            if NS.CursorSweepActive and NS.CursorSweepTrial and NS.CursorSweepTrial.Trace then
                NS.CursorSweepTrial:Trace('observation expired',tostring(expired.kind)..':'..tostring(expired.name or expired.id)
                    ..string.format('; no positive=%.1fs; ttl=%ds; refined=%s',now-expired.seen,NS:GetGatheringObservationTTL(expired),tostring(expired.manualRefined==true)))
            end
            table.remove(nodes,i)
        end
    end
end

local function hideIcons(pool)
    for _, icon in ipairs(pool or icons) do
        if icon.shown then
            icon.image:Hide(); icon.border:Hide(); icon.elevation:Hide(); icon.cave:Hide();if icon.letter then icon.letter:Hide() end;if icon.anonymousImage then icon.anonymousImage:Hide()end;if icon.anonymousBorder then icon.anonymousBorder:Hide()end;if icon.anonymousThird then icon.anonymousThird:Hide()end;if icon.anonymousFourth then icon.anonymousFourth:Hide()end
            icon.shown, icon.ringShown, icon.elevationShown, icon.caveShown = false, false, false, false
        end
    end
    if not pool and overlays.dualHUD then
        hideIcons(overlays.dualHUD.icons)
        overlays.dualHUD.layer:Hide()
    end
end
local function createOverlay()
    local mode = NS.db.hud.enabled and not NS.db.hud.keepMinimap and "hud" or "minimap"
    if overlays.dualHUD and not (NS.db.hud.enabled and NS.db.hud.keepMinimap) then overlays.dualHUD.layer:Hide() end
    if overlayMode == mode then return true end
    local existing = overlays[mode]
    if not existing then
        if InCombatLockdown and InCombatLockdown() then return false end
        -- FarmRoute: the minimap layer sits on UIParent and follows the map
        -- (followMap), so it doesn't inherit the /farm HUD's near-invisible
        -- minimap opacity.
        local parent = mode == "hud" and NS.HUDFrame or UIParent
        local layer = CreateFrame("Frame", "ForeverFarmRouteGathering_NodeOverlay_" .. mode, parent)
        layer:SetAllPoints(mode == "hud" and parent or Minimap)
        layer:SetFrameStrata(Minimap:GetFrameStrata())
        layer:SetFrameLevel(Minimap:GetFrameLevel() + 8)
        layer:EnableMouse(false)
        existing = { layer = layer, icons = {} }
        overlays[mode] = existing
    end
    hideIcons()
    if NS.NodeOverlay then NS.NodeOverlay:Hide() end
    NS.NodeOverlay, icons, overlayMode = existing.layer, existing.icons, mode
    scan = nil
    nextDraw, nextScan = 0, 0
    return true
end
local function createIcon(layer)
    layer = layer or NS.NodeOverlay
    local border = layer:CreateTexture(nil, "OVERLAY")
    border:SetTexture("Interface\\Common\\CommonMaskCircle")
    border:SetSize(17.5, 17.5)
    local image = layer:CreateTexture(nil, "OVERLAY", nil, 1)
    image:SetSize(14, 14)
    image:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    image:SetDesaturation(0)
    local mask
    if layer.CreateMaskTexture and image.AddMaskTexture then
        mask = layer:CreateMaskTexture()
        mask:SetTexture("Interface\\CHARACTERFRAME\\TempPortraitAlphaMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
        mask:SetAllPoints(image)
        image:AddMaskTexture(mask)
    end
    border:SetPoint("CENTER", image, "CENTER")
    border:Hide()
    local elevation = layer:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    elevation:Hide()
    local cave = layer:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    cave:SetText("|cff55ddffC|r")
    cave:SetPoint("LEFT", image, "RIGHT", 2, 0)
    cave:Hide()
    local anonymousBorder=layer:CreateTexture(nil,'OVERLAY',nil,1);anonymousBorder:Hide()
    local anonymousImage=layer:CreateTexture(nil,'OVERLAY',nil,2)
    anonymousImage:SetAllPoints(image);anonymousImage:Hide()
    local third=layer:CreateTexture(nil,'OVERLAY',nil,2);third:Hide()
    local fourth=layer:CreateTexture(nil,'OVERLAY',nil,2);fourth:Hide()
    return { anonymousThird=third,anonymousFourth=fourth,image = image, border = border, elevation = elevation, cave = cave, anonymousImage=anonymousImage, anonymousBorder=anonymousBorder, artworkMask=mask }
end
-- FarmRoute: keep the minimap icon layer over the map. While the scanner
-- borrows the real minimap, follow its drawn stand-in instead; hide the
-- icons whenever neither is on screen.
local function followMap(layer)
    local anchor, above = Minimap, 8
    local stand = NS.MinimapScanActive and NS.TerrainMinimap and NS.TerrainMinimap.frame
    local holder = _G.ForeverFarmRouteMapHolder
    if holder and holder:IsShown() then
        -- /farm HUD: FarmRoute's fixed frame at the map's resting place, so
        -- icons stay put while a node probe briefly moves the real map.
        anchor = holder
    elseif stand and stand:IsShown() then anchor, above = stand, 34 end
    if layer.followed ~= anchor then
        layer:ClearAllPoints()
        layer:SetAllPoints(anchor)
        layer.followed = anchor
    end
    local strata = anchor:GetFrameStrata()
    if layer:GetFrameStrata() ~= strata then layer:SetFrameStrata(strata) end
    local level = anchor:GetFrameLevel() + above
    if layer:GetFrameLevel() ~= level then layer:SetFrameLevel(level) end
    local visible = anchor:IsVisible() and 1 or 0
    if layer:GetAlpha() ~= visible then layer:SetAlpha(visible) end
end

local function drawLayer(ctx, now, layer, pool, mode)
    if not layer or not ctx then hideIcons(pool); return end
    if mode == "minimap" then followMap(layer) end
    if mode=="hud" then
        local strata,level=NS.db.hud.overlayStrata or "HIGH",NS.db.hud.overlayLevel or 110
        if layer:GetFrameStrata()~=strata then layer:SetFrameStrata(strata) end
        if layer:GetFrameLevel()~=level then layer:SetFrameLevel(level) end
    end
    if mode == "minimap" then
        -- The layer is a UIParent child (FarmRoute), so icons already have
        -- their usual screen size at scale 1.
        if math.abs(layer:GetScale() - 1) > 0.0001 then layer:SetScale(1) end
    end
    local overlayScale = layer:GetEffectiveScale()
    if not number(overlayScale) or overlayScale <= 0 then hideIcons(pool); return end
    local elevationScale = ctx.scale / overlayScale * ctx.iconScale
    local iconSize = NS.db.hud.nodeIconSize
    if mode == "minimap" and NS:FarmHUDOpen() then iconSize = NS.db.hud.farmIconSize or 22 end
    if not number(iconSize) then iconSize = 14 end
    iconSize = math.max(8, math.min(32, math.floor(iconSize + 0.5)))
    local opacity = NS.db.hud.nodeIconOpacity
    if not number(opacity) then opacity = 80 end
    opacity = math.max(0, math.min(100, opacity)) / 100
    local margin = iconSize * 0.625
    local half = ctx.width * ctx.scale / overlayScale / 2
    if mode == "hud" and (NS.db.hud.keepMinimap or NS.CursorSweepActive) then half = (NS.db.hud.size - 48) / 2 end
    local halfHeight, round = half, false
    if mode == "minimap" then
        local shape = GetMinimapShape and GetMinimapShape() or "ROUND"
        local config = _EMM_DB and _EMM_DB.profile and _EMM_DB.profile.minimap
        if config then
            if config.shape == "rectangular" then shape = "RECTANGULAR"
            elseif config.shape == "circle" or config.shape == "textured_circle" then shape = "ROUND"
            elseif config.shape == "square" then shape = "SQUARE" end
        end
        round = shape == "ROUND"
        if shape == "RECTANGULAR" then halfHeight = half * 0.75 end
    end
    local count = 0
    for _, node in ipairs(nodes) do
        local rendered={at=now,status='waiting for eligible current-map observation'}
        renderStates[node]=rendered
        local ambiguous=NS:IsCursorObservationAmbiguous(node,ctx,now)
        if ambiguous then rendered.status='extra picture pending separate centre verification' end
        if not ambiguous and (node.centered or node.fastLocation or node.manualProvisional) and node.map == ctx.map and now - node.seen <= NS:GetGatheringObservationTTL(node) then
            -- A FarmRoute probe has already checked a specific spawn spot.
            -- Artwork can load separately from the marker position.
            local displayX,displayY=node.farmProbeX or node.x,node.farmProbeY or node.y
            local manualCoordinateOnly=node.anonymous and not node.farmProbeKey and (node.quickScanObservation or NS.CursorSweepActive and NS.CursorSweepTrial and NS.CursorSweepTrial.workflow and NS.CursorSweepTrial.workflow:Allows('knownOnly') or not node.cursorSweepObservation and not NS.CursorSweepActive)
            if manualCoordinateOnly then
                local known,alternative,reason,anchor,types
                if NS.GetAnonymousNodeArtwork then known,alternative,reason,anchor,types=NS:GetAnonymousNodeArtwork(node) end
                node.anonymousArtworkStatus=reason or 'location services unavailable'
                if not node.manualKeyAnchor then node.manualPossibleTypes=types end
                if known and anchor then
                    displayX,displayY=anchor.x,anchor.y
                    node.farmDisplayX,node.farmDisplayY=anchor.x,anchor.y
                elseif node.farmDisplayX then
                    -- FarmRoute: keep the last spawn spot found for this node
                    -- so a lookup that's briefly unavailable doesn't make the
                    -- icon hop between positions.
                    displayX,displayY=node.farmDisplayX,node.farmDisplayY
                elseif reason=='historical index building' or reason=='historical query budget reached' then
                    displayX,displayY=nil,nil
                else
                    -- FarmRoute: zones without spawn data (e.g. Mount Hyjal)
                    -- would never show a hovered node; show it where it was seen.
                    displayX,displayY=node.x,node.y
                    node.anonymousArtworkStatus='shown at observed position ('..tostring(reason)..')'
                end
            end
            local east, north = ((displayX or node.x) - ctx.x) * ctx.w, (ctx.y - (displayY or node.y)) * ctx.h
            local dx = (east * ctx.cos + north * ctx.sin) / ctx.radius * half
            local dy = (north * ctx.cos - east * ctx.sin) / ctx.radius * half
            local inside = displayX~=nil and math.abs(dx) < half - margin and math.abs(dy) < halfHeight - margin
                and (not round or dx^2 + dy^2 < (half - margin)^2)
            rendered.status=displayX==nil and 'manual hover waiting for saved coordinates' or inside and 'icon pool full' or 'outside draw bounds'
            rendered.x,rendered.y=dx,dy
            rendered.displayX,rendered.displayY=displayX,displayY
            if inside and count < MAX_ICONS then
                rendered.status='drawn'
                count = count + 1
                local icon = pool[count] or createIcon(layer)
                pool[count] = icon
                rendered.image,rendered.layer,rendered.elevation=icon.image,layer,icon.elevation
                if icon.size ~= iconSize then
                    icon.image:SetSize(iconSize, iconSize)
                    icon.border:SetSize(iconSize * 1.25, iconSize * 1.25)
                    icon.cave:SetFont(STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF",
                        math.max(8, math.floor(iconSize * 0.65 + 0.5)), "OUTLINE")
                    icon.size = iconSize
                end
                if icon.resource ~= node.id then icon.image:SetTexture(node.icon); icon.resource = node.id end
                local difficulty
                if not node.anonymous and node.kind ~= "treasure" then difficulty = NS:GetGatheringNodeDifficulty(node) end
                local color = NS.GatheringDifficultyColors[difficulty]
                if icon.difficulty ~= difficulty then
                    icon.difficulty = difficulty
                    if color then icon.border:SetVertexColor(color[1], color[2], color[3]) end
                end
                if icon.x ~= dx or icon.y ~= dy then
                    icon.image:ClearAllPoints()
                    icon.image:SetPoint("CENTER", layer, "CENTER", dx, dy)
                    icon.x, icon.y = dx, dy
                end
                -- Keep resource artwork in full color. A separate C identifies
                -- observed caves without making copper and tin look alike.
                if node.underground and not icon.caveShown then
                    icon.cave:Show(); icon.caveShown = true
                elseif not node.underground and icon.caveShown then
                    icon.cave:Hide(); icon.caveShown = false
                end
                local alpha = isKindActive(node.kind) and opacity or 1
                local confidence = mode == 'hud' and NS.db.hud.experimentalHUD and NS.TerrainMarkers
                if confidence then alpha = confidence:ResourceAlpha(node) end
                rendered.alpha=alpha
                local indicatorAlpha = confidence and 1 or alpha
                icon.elevation:SetAlpha(indicatorAlpha); icon.cave:SetAlpha(indicatorAlpha)
                if icon.alpha ~= alpha then
                    icon.image:SetAlpha(alpha); icon.border:SetAlpha(alpha)
                    icon.alpha = alpha
                end
                -- The HUD uses native arrows for each active tracker and draws
                -- cached arrows only for inactive types, avoiding doubled arrows.
                -- Normal minimap pictures retain their existing addon arrows.
                -- Cached HUD arrow spacing follows native map scale,
                -- independently of the resource picture size.
                local tag = node.elevationTag
                if tag and (mode ~= "hud" or NS.db.hud.keepMinimap or NS.CursorSweepActive or not isKindActive(node.kind)) then
                    if icon.elevationScale ~= elevationScale then
                        icon.elevation:SetScale(elevationScale)
                        icon.elevationScale = elevationScale
                    end
                    if icon.elevationTag ~= tag then
                        icon.elevationSide = elevationSide(tag)
                        icon.elevation:ClearAllPoints()
                        if mode == "hud" and icon.elevationSide then
                            icon.elevation:SetPoint("CENTER", icon.image, "CENTER", 0,
                                icon.elevationSide == "down" and -12 or 12)
                        elseif icon.elevationSide == "down" then
                            icon.elevation:SetPoint("TOP", icon.image, "BOTTOM", 0, 0)
                        elseif icon.elevationSide == "up" then
                            icon.elevation:SetPoint("BOTTOM", icon.image, "TOP", 0, 0)
                        end
                        icon.elevation:SetText(tag)
                        icon.elevationTag = tag
                    end
                    if icon.elevationSide and not icon.elevationShown then
                        icon.elevation:Show(); icon.elevationShown = true
                    elseif not icon.elevationSide and icon.elevationShown then
                        icon.elevation:Hide(); icon.elevationShown = false
                    end
                elseif icon.elevationShown then
                    icon.elevation:Hide(); icon.elevationShown = false
                end
                if not icon.shown then icon.image:Show(); icon.shown = true end
                if color and not icon.ringShown then icon.border:Show(); icon.ringShown = true
                elseif not color and icon.ringShown then icon.border:Hide(); icon.ringShown = false end
                if NS.RenderAnonymousNodeIcon then
                    if not node.anonymous then icon.image:Show() end
                    NS:RenderAnonymousNodeIcon(icon,node,iconSize,alpha)
                end
            end
        end
    end
    for i = count + 1, #pool do
        local icon = pool[i]
        if icon.shown then
            icon.image:Hide(); icon.border:Hide(); icon.elevation:Hide(); icon.cave:Hide();if icon.letter then icon.letter:Hide() end;if icon.anonymousImage then icon.anonymousImage:Hide()end;if icon.anonymousBorder then icon.anonymousBorder:Hide()end;if icon.anonymousThird then icon.anonymousThird:Hide()end;if icon.anonymousFourth then icon.anonymousFourth:Hide()end
            icon.shown, icon.ringShown, icon.elevationShown, icon.caveShown = false, false, false, false
        end
    end
end

-- Reuse the measured live cache, with independent texture pools for each view.
-- The native minimap remains the only source of discovery and elevation evidence.
function NS:GetCursorHUDDrawContext(ctx)
    if not self.CursorSweepActive or not ctx then return ctx end
    local mode=self.db.hud.rotationMode or "CLIENT"
    local client=self.CursorSweepTrial and self.CursorSweepTrial.clientRotation
        or self._minimapState and self._minimapState.rotateMinimap
    local rotating=mode=="ON" or mode=="CLIENT" and client=="1"
    local facing=rotating and GetPlayerFacing and GetPlayerFacing() or 0
    if not number(facing) then return end
    local projected={}
    for key,value in pairs(ctx)do projected[key]=value end
    local display=self.CursorSweepTrial and self.CursorSweepTrial.hudDisplay
    if display and display.map==ctx.map and number(display.radius) and display.radius>0 then
        projected.radius=display.radius
    end
    projected.cos,projected.sin=math.cos(facing),math.sin(facing)
    return projected
end
-- An edge read proves presence, not a second spawn. Keep the observation
-- queued, but withhold its extra picture until geometry separates neighbors.
function NS:IsCursorObservationAmbiguous(node,ctx,now)
    if not ctx or not (NS.CursorSweepActive or node.cursorSweepObservation) or node.manualRefined or node.centered or node.fastLocation then return false end
    local pixel=2*ctx.radius/(ctx.width*ctx.scale)
    local index
    for i,other in ipairs(nodes)do if other==node then index=i;break end end
    if not index then return false end
    for i,other in ipairs(nodes)do
        if other~=node and other.map==node.map and other.kind==node.kind and other.id==node.id and other.name==node.name
            and number(other.seen) and now-other.seen>=0 and now-other.seen<=NS:GetGatheringObservationTTL(other) then
            local measured=other.manualRefined or other.centered or other.fastLocation
            if measured or i<index then
                local radius=18
                if measured then
                    local area=other.manualPositiveFootprint
                    radius=math.max(9,area and area.radius or 9)+1
                end
                local separation=distance(other,node,ctx)
                local hit=node.manualLastHit
                if hit and number(hit.x) and number(hit.y) then separation=math.min(separation,distance(other,hit,ctx)) end
                if not measured then
                    local prior=other.manualLastHit
                    if prior and number(prior.x) and number(prior.y) then
                        separation=math.min(separation,distance(prior,node,ctx))
                        if hit and number(hit.x) and number(hit.y) then separation=math.min(separation,distance(prior,hit,ctx)) end
                    end
                end
                -- Fresh reads can renew an old rough record without moving
                -- its artwork. Compare actual hit aliases too, or one real
                -- chest can keep a far-off second picture alive indefinitely.
                if separation<=(pixel*ctx.iconScale*radius)^2 then return true end
            end
        end
    end
    return false
end
local hudView -- FarmRoute: the HUD's zoom and rotation, kept from outside scans
local function draw(ctx, now)
    NS.LastNodeDrawAttempt=now
    local display=overlayMode=="hud" and NS:GetCursorHUDDrawContext(ctx) or ctx
    -- FarmRoute: during a scan the real minimap sits under the cursor at
    -- another size, zoom and rotation. Keep drawing with the HUD's own view
    -- (its last zoom and rotation, the stand-in's size) so icons keep moving
    -- with the map instead of jumping or freezing.
    if overlayMode=="minimap" and NS.NodeOverlay and ctx then
        if NS.MinimapScanActive then
            if not hudView then return end
            followMap(NS.NodeOverlay)
            display={}
            for k,v in pairs(ctx) do display[k]=v end
            display.radius,display.cos,display.sin=hudView.radius,hudView.cos,hudView.sin
            display.width,display.height=NS.NodeOverlay:GetWidth(),NS.NodeOverlay:GetHeight()
            display.scale=NS.NodeOverlay:GetEffectiveScale()
        else
            hudView={radius=ctx.radius,cos=ctx.cos,sin=ctx.sin}
        end
    end
    local terrain=NS.QuickScanner and NS.QuickScanner.farmMap and NS.TerrainMinimap.frame
    if terrain and terrain:IsShown() then hideIcons(icons)
    else drawLayer(display, now, NS.NodeOverlay, icons, overlayMode) end
    NS.LastNodeDrawComplete=now
    local dual = overlays.dualHUD
    if not (NS.db.hud.enabled and NS.db.hud.keepMinimap and NS.HUDFrame and ctx) then
        if dual then dual.layer:Hide() end
        return
    end
    if not dual then
        if InCombatLockdown and InCombatLockdown() then return end
        local layer = CreateFrame("Frame", "ForeverFarmRouteGathering_NodeOverlay_dualHUD", NS.HUDFrame)
        layer:SetAllPoints(NS.HUDFrame)
        layer:EnableMouse(false)
        dual = {layer = layer, icons = {}}
        overlays.dualHUD = dual
    end
    local projected = {}
    for key, value in pairs(ctx) do projected[key] = value end
    local rotation = NS.db.hud.rotationMode
    if rotation == "ON" or rotation == "OFF" then
        local facing = rotation == "ON" and GetPlayerFacing and GetPlayerFacing() or 0
        if not number(facing) then dual.layer:Hide(); return end
        projected.cos, projected.sin = math.cos(facing), math.sin(facing)
    end
    local strata, level = NS.db.hud.overlayStrata or "HIGH", (NS.db.hud.overlayLevel or 110) + 1
    if dual.layer:GetFrameStrata() ~= strata then dual.layer:SetFrameStrata(strata) end
    if dual.layer:GetFrameLevel() ~= level then dual.layer:SetFrameLevel(level) end
    dual.layer:Show()
    drawLayer(projected, now, dual.layer, dual.icons, "hud")
end

local function addSample(resource, x, y, ctx, saved)
    local east = (x - ctx.width / 2) / (ctx.width / 2) * ctx.radius
    local north = (y - ctx.height / 2) / (ctx.width / 2) * ctx.radius
    local spot = { x = ctx.x + (east * ctx.cos - north * ctx.sin) / ctx.w,
        y = ctx.y - (north * ctx.cos + east * ctx.sin) / ctx.h }
    -- Keep the collected spot hidden through repeated gathering and looting.
    -- It becomes eligible for discovery again once the player starts moving.
    if recentlyCollected(resource, spot, ctx) then return end
    if not playerMoving and GetTime() - lastMovement >= TRACKING_SETTLE then
        -- The grid repeatedly crosses already measured dots after swaps.
        -- Their interior needs live validation, not another expensive center
        -- job. Leave their outer edges available to discover a nearby dot.
        local inset = 0.75 / (ctx.width * ctx.scale / 2) * ctx.radius
        for _, node in ipairs(nodes) do
            local box = node.hitbox
            if node.centered and not node.centerMoving and node.map == ctx.map and node.id == resource.id
                and box and box.width == ctx.width and box.scale == ctx.scale
                and box.viewRadius == ctx.radius and box.iconScale == ctx.iconScale then
                local inside = math.max(0, box.radius - inset)
                if distance(node, spot, ctx) < inside^2 then return end
            end
        end
    end
    local radius = 24 / (ctx.width * ctx.scale / 2) * ctx.radius
    for _, group in ipairs(scan.found) do
        -- Once measured, use this dot's own hitbox instead of swallowing
        -- another same-resource dot within the coarse grouping radius.
        local limit = group.hitRadius or radius
        if saved and (group.centered or group.fastLocation) then
            limit = math.max(3, group.uncertainty + saved.uncertainty)
        end
        local seed = group.fastLocation or group.seedLocation
        local differentSaved = saved and seed and (saved.x ~= seed.x or saved.y ~= seed.y)
        if not differentSaved and group.id == resource.id and distance(group, spot, ctx) < limit^2 then
            local n = group.samples + 1
            -- Keep an actual positive hit until a center is verified. Averaging
            -- hits from two neighboring dots can create an empty midpoint.
            if not group.centered then
                local hits = group.pendingHits or {}
                local spacing = 4 / (ctx.width * ctx.scale / 2) * ctx.radius
                local nearby = distance(group, spot, ctx) < spacing^2
                for _, hit in ipairs(hits) do
                    if distance(hit, spot, ctx) < spacing^2 then nearby = true; break end
                end
                if not nearby then
                    if #hits < 8 then
                        hits[#hits + 1] = spot
                    else
                        local closest = 1
                        for i = 2, #hits do
                            if distance(group, hits[i], ctx) < distance(group, hits[closest], ctx) then closest = i end
                        end
                        if distance(group, spot, ctx) > distance(group, hits[closest], ctx) then hits[closest] = spot end
                    end
                end
                group.pendingHits = hits
            end
            group.samples = n
            return group
        end
    end
    if #scan.found < MAX_ICONS then
        local group = { id = resource.id, name = resource.name, kind = resource.kind,
            icon = resource.icon, map = ctx.map, x = spot.x, y = spot.y, samples = 1,
            uncertainty = 2 * PIXEL_STEP / (ctx.width * ctx.scale / 2) * ctx.radius }
        scan.found[#scan.found + 1] = group
        -- Publish a positive hit this frame, before a tracking change can
        -- discard the in-progress sweep during its usual 0.2 second delay.
        scan.nextPublish = 0
        return group
    end
end
local function fastSavedLocation(saved, ctx)
    if saved.centerVersion ~= CENTER_VERSION or not number(saved.uncertainty) or saved.uncertainty <= 0
        or saved.uncertainty > 2 / (ctx.width * ctx.scale / 2) * ctx.radius
        or playerMoving or GetTime() - lastMovement < TRACKING_SETTLE then return false end
    local personal = locationIndex(NS.db.nodeLocations, ctx.map, "personal")
    local shared = locationIndex(NS.BundledNodeLocations, ctx.map, "bundled")
    if personal and not personal:Ready() or shared and not shared:Ready() then return false end
    local match, ambiguous = matchingLocation(personal, saved, ctx, 3)
    if ambiguous or match and (match.x ~= saved.x or match.y ~= saved.y) then return false end
    -- A bundled point cannot bypass an older personal record's normal checks.
    if scan.savedSource == 2 and match then return false end
    match, ambiguous = matchingLocation(shared, saved, ctx, 3)
    return not ambiguous and not (match and (match.x ~= saved.x or match.y ~= saved.y))
end
local function probe(x, y, ctx, saved)
    Minimap:UpdateMouseoverAtPoint((ctx.left + x) * ctx.scale, (ctx.bottom + y) * ctx.scale)
    local tooltip = C_TooltipInfo.GetMinimapMouseover()
    if not public(tooltip) or type(tooltip) ~= "table" or not public(tooltip.lines) or type(tooltip.lines) ~= "table" then return end
    local group, liveCount, reliable, savedMatched = nil, 0, true, false
    local fast = saved and fastSavedLocation(saved, ctx)
    -- Count every readable resource title before accepting a saved shortcut.
    -- A positive title inside overlapping hitboxes is not a unique live match.
    if saved then
        for _, line in ipairs(tooltip.lines) do
            if not public(line) or type(line) ~= "table" or not public(line.leftText) then
                reliable = false
            elseif type(line.leftText) == "string" then
                for label in line.leftText:gmatch("[^\n]+") do
                    if resourceFor(label, scan.kind) or scan.treasure and resourceFor(label, "treasure") then
                        liveCount = liveCount + 1
                    end
                end
            end
        end
    end
    fast = fast and reliable and liveCount == 1
    for _, line in ipairs(tooltip.lines) do
        if public(line) and type(line) == "table" and public(line.leftText) and type(line.leftText) == "string" then
            for label in line.leftText:gmatch("[^\n]+") do
                local resource = resourceFor(label, scan.kind)
                if not resource and scan.treasure and scan.kind ~= "treasure" then resource = resourceFor(label, "treasure") end
                if resource then
                    if saved and resource.id == saved.id and resource.kind == saved.kind then savedMatched = true end
                    local seed = saved and reliable and liveCount == 1 and resource.id == saved.id
                        and resource.kind == saved.kind and not playerMoving
                        and GetTime() - lastMovement >= TRACKING_SETTLE and saved or nil
                    local candidate = fast and seed or nil
                    group = addSample(resource, x, y, ctx, seed)
                    if group then
                        if seed and not group.centered and not group.fastLocation and not group.seedLocation then
                            -- Every live-checked saved point can seed ordinary
                            -- centering. Only trusted provenance may also draw
                            -- it early; an older row remains an unseen seed.
                            local spacing = 4 / (ctx.width * ctx.scale / 2) * ctx.radius
                            if distance(group, seed, ctx) >= spacing^2 then
                                group.pendingHits = group.pendingHits or {}
                                if #group.pendingHits < 8 then
                                    group.pendingHits[#group.pendingHits + 1] = {x = group.x, y = group.y}
                                end
                            end
                            if scan.centerJob and scan.centerJob.group == group then scan.centerJob = nil end
                            group.x, group.y, group.seedLocation, group.centerTried = seed.x, seed.y, seed, nil
                            group.samples = group.samples + 1
                            scan.nextPublish = 0
                        end
                        if candidate and not group.centered and not group.fastLocation then
                            group.uncertainty, group.fastLocation = saved.uncertainty, saved
                            if group.underground == nil and type(saved.underground) == "boolean" then group.underground = saved.underground end
                            group.samples = group.samples + 1
                            scan.nextPublish = 0
                        end
                        group.elevationTag = elevationTag(label)
                        observeUnderground(group, label, line, resource)
                    end
                end
            end
            if group and group.kind ~= "treasure" then
                local difficulty = NS:GetGatheringTooltipDifficulty(line, group.kind)
                if difficulty then
                    group.tooltipDifficulty = difficulty
                    group.tooltipSkillRevision = NS:GetGatheringSkillRevision()
                end
            end
        end
    end
    return savedMatched and reliable and liveCount == 1
end
-- Saved coordinates are probe targets, never proof of an active spawn. Small
-- native hitboxes can sit entirely between the general discovery grid points.
local function probeSavedLocation(ctx)
    -- Reopen nearby queries when movement/zoom brings a new area into view.
    local region = locationIndexes.personal or locationIndexes.bundled
    if region then
        local x1, x2, y1, y2 = region:Bounds(ctx.x, ctx.y, ctx.radius / ctx.w, ctx.radius / ctx.h)
        local bounds = scan.savedBounds
        if not bounds or bounds[1] ~= x1 or bounds[2] ~= x2 or bounds[3] ~= y1 or bounds[4] ~= y2 then
            scan.savedBounds = {x1, x2, y1, y2}
            scan.savedSource, scan.savedQuery, scan.savedSeen, scan.savedDone = 1, nil, {}, false
            scan.savedRetryAt, scan.savedRetryNeeded = nil, nil
        end
    end
    if scan.savedDone or scan.savedSource > 2 then
        -- A saved point can be empty during a tracking handoff and live a
        -- moment later. Do not leave it unchecked for the entire interlaced
        -- grid/profile sweep; repeat nearby queries with a centering interval.
        scan.savedDone = true
        if not scan.savedRetryNeeded then return false end
        if playerMoving or GetTime() - lastMovement < TRACKING_SETTLE then return false end
        scan.savedRetryAt = scan.savedRetryAt or GetTime() + 2
        if GetTime() < scan.savedRetryAt then return false end
        scan.savedSource, scan.savedQuery, scan.savedSeen, scan.savedDone = 1, nil, {}, false
        scan.savedRetryAt, scan.savedRetryNeeded = nil, nil
    end
    -- Both indexes must be ready before checking personal precedence/conflicts.
    -- Keep construction incremental under the shared frame/time budget.
    for _, slot in ipairs({"personal", "bundled"}) do
        local source
        if slot == "personal" then source = NS.db.nodeLocations else source = NS.BundledNodeLocations end
        local index = locationIndex(source, ctx.map, slot)
        if index and not index:Ready() then index:Build(128); return true end
    end
    local slot = scan.savedSource == 1 and "personal" or "bundled"
    local source
    if scan.savedSource == 1 then source = NS.db.nodeLocations else source = NS.BundledNodeLocations end
    local index = locationIndex(source, ctx.map, slot)
    if index and not index:Ready() then index:Build(128); return true end
    if not index then
        scan.savedSource, scan.savedQuery = scan.savedSource + 1, nil
        if scan.savedSource > 2 then scan.savedDone = true end
        return true
    end
    if not scan.savedQuery or scan.savedQuery.index ~= index then
        scan.savedQuery = index:Query(ctx.x, ctx.y, ctx.radius / ctx.w, ctx.radius / ctx.h)
    end
    local saved, done = index:Next(scan.savedQuery)
    if done then
        scan.savedSource, scan.savedQuery = scan.savedSource + 1, nil
        if scan.savedSource > 2 then scan.savedDone = true end
    end
    if not saved or not (saved.kind == scan.kind or scan.treasure and saved.kind == "treasure") then return true end
    local precision = 0.75 / (ctx.width * ctx.scale / 2) * ctx.radius
    for _, node in ipairs(nodes) do
        if node.map == ctx.map and node.id == saved.id and node.kind == saved.kind
            and (node.centered or node.fastLocation) and not node.centerMoving and distance(node, saved, ctx) <= precision^2 then
            -- Visible settled pictures already receive live validation. Saved
            -- retries are for missing pictures, not another trace of this one.
            return true
        end
    end
    local east, north = (saved.x - ctx.x) * ctx.w, (ctx.y - saved.y) * ctx.h
    local dx = (east * ctx.cos + north * ctx.sin) / ctx.radius * ctx.width / 2
    local dy = (north * ctx.cos - east * ctx.sin) / ctx.radius * ctx.width / 2
    local x, y = ctx.width / 2 + dx, ctx.height / 2 + dy
    if x >= 1 and y >= 1 and x <= ctx.width - 1 and y <= ctx.height - 1
        and dx^2 + dy^2 < (ctx.width / 2 - 1)^2 then
        scan.savedSeen = scan.savedSeen or {}
        local key = ("%s:%s:%s:%.17g:%.17g"):format(saved.kind, type(saved.id), tostring(saved.id), saved.x, saved.y)
        if not scan.savedSeen[key] then
            scan.savedSeen[key] = true
            if not probe(x, y, ctx, saved) then scan.savedRetryNeeded = true end
        end
    end
    return true
end
local function profileProbe(profile, offset, ctx)
    local shift = offset / ctx.scale / (ctx.width / 2) * ctx.radius
    local cos, sin = math.cos(profile.angle), math.sin(profile.angle)
    local axisCos, axisSin = ctx.cos * cos - ctx.sin * sin, ctx.sin * cos + ctx.cos * sin
    local x, y = profile.x - shift * axisSin / ctx.w, profile.y - shift * axisCos / ctx.h
    return {group = profile.group, x = x, y = y, axis = 1, sign = -1,
        reach = 2, inside = 0, cos = ctx.cos, sin = ctx.sin, profile = profile, profileOffset = offset,
        probeCos = cos, probeSin = sin, axisCos = axisCos, axisSin = axisSin, moving = profile.moving}
end
local function circlePoint(profile, u, v, ctx)
    local cos, sin = math.cos(profile.angle), math.sin(profile.angle)
    local axisCos, axisSin = ctx.cos * cos - ctx.sin * sin, ctx.sin * cos + ctx.cos * sin
    local unit = ctx.radius / (ctx.width * ctx.scale / 2)
    return profile.originX + (u * axisCos - v * axisSin) * unit / ctx.w,
        profile.originY - (u * axisSin + v * axisCos) * unit / ctx.h
end
local function circleCandidates(profile, negative, ctx)
    local middle, positive = profile.middle, profile.positive
    if middle.half <= 0 or positive.half <= 0 or negative.half <= 0 then return end
    local cos, sin = math.cos(profile.angle), math.sin(profile.angle)
    local axisCos, axisSin = ctx.cos * cos - ctx.sin * sin, ctx.sin * cos + ctx.cos * sin
    local unit = (ctx.width * ctx.scale / 2) / ctx.radius
    local function along(section)
        return ((section.x - profile.originX) * ctx.w * axisCos
            + (profile.originY - section.y) * ctx.h * axisSin) * unit
    end
    local fits = {}
    for _, side in ipairs({-1, 1}) do
        -- Three nearby points on one outer edge describe its own circular
        -- lobe, even when the opposite edge belongs to a neighboring dot.
        local a = along(middle) + side * middle.half
        local b = along(positive) + side * positive.half - a
        local c = along(negative) + side * negative.half - a
        if math.abs(b + c) >= 0.7 then
            local u = (b*b + c*c + 32) / (2 * (b + c))
            local v = (b*b + 16 - 2*u*b) / 8
            local radius = math.sqrt(u*u + v*v)
            if radius >= 6 and radius <= 24 then
                local fit = {u = a + u, v = v, radius = radius, side = side}
                fit.x, fit.y = circlePoint(profile, fit.u, fit.v, ctx)
                fits[#fits + 1] = fit
            end
        end
    end
    table.sort(fits, function(a, b) return distance(a, profile.seed, ctx) < distance(b, profile.seed, ctx) end)
    return fits
end
local function circleCheck(profile, ctx)
    local fit = profile.circleFits[profile.circleIndex]
    while fit do
        local offset = profile.circleSide == 1 and 8 or -8
        local square = fit.radius^2 - (offset - fit.v)^2
        if square > 0 then
            local u = fit.u + fit.side * (math.sqrt(square) + (profile.circleOutside and 0.125 or -0.125))
            local x, y = circlePoint(profile, u, offset, ctx)
            return {group = profile.group, x = x, y = y, axis = 3, circleCheck = profile,
                cos = ctx.cos, sin = ctx.sin, moving = profile.moving}
        end
        if profile.circleSide == 1 then profile.circleSide = 2
        else profile.circleSide, profile.circleIndex = 1, profile.circleIndex + 1 end
        fit = profile.circleFits[profile.circleIndex]
    end
end
local function profileResult(profile, result, ctx, resume)
    -- Every cross-section is measured with live probes. Find a local widest
    -- section instead of accepting the midpoint of two connected hitboxes.
    if not resume then profile.reads = profile.reads + 1 end
    local function finish(best)
        return {group = profile.group, x = best.x, y = best.y, axis = 3,
            cos = ctx.cos, sin = ctx.sin, profileDone = true, profileRadius = best.half,
            halfWidth = best.half, halfHeight = best.half, moving = profile.moving}
    end
    local function walk()
        local offset = profile.best.offset + profile.direction * 4
        if math.abs(offset) >= profile.extent or profile.reads >= 20 then return nil end
        return profileProbe(profile, offset, ctx)
    end
    if profile.phase == 0 then
        if result.half == 0 then return nil end
        profile.middle, profile.phase = result, 1
        profile.x, profile.y = result.x, result.y
        return profileProbe(profile, 4, ctx)
    elseif profile.phase == 1 then
        profile.positive, profile.phase = result, 2
        return profileProbe(profile, -4, ctx)
    elseif profile.phase == 2 then
        if profile.circleAngle ~= profile.angle then
            profile.circleAngle = profile.angle
            profile.circleFits = circleCandidates(profile, result, ctx) or {}
            profile.circleIndex, profile.circleSide, profile.circleOutside = 1, 1, false
            profile.circleResult = result
            local check = circleCheck(profile, ctx)
            if check then return check end
        end
        local widest = math.max(profile.middle.half, profile.positive.half, result.half)
        if not profile.choice or widest < profile.choice.widest then
            profile.choice = {middle = profile.middle, positive = profile.positive, negative = result,
                widest = widest, angle = profile.angle}
        end
        profile.angleIndex = profile.angleIndex + 1
        local angle = profile.angles[profile.angleIndex]
        if angle then
            profile.angle, profile.phase = angle, 0
            profile.x, profile.y = profile.originX, profile.originY
            return profileProbe(profile, 0, ctx)
        end
        -- Compare neighboring sections too: a direction through both lobes
        -- can be narrow at the seed and much wider just a few pixels away.
        local choice = profile.choice
        profile.middle, profile.positive, result = choice.middle, choice.positive, choice.negative
        profile.x, profile.y, profile.angle = choice.middle.x, choice.middle.y, choice.angle
        local best = profile.middle
        if profile.positive.half > best.half then best = profile.positive end
        if result.half > best.half then best = result end
        if profile.positive.half > profile.middle.half and result.half > profile.middle.half then
            -- Both lobes can be wider than their shared midpoint. Refine the
            -- lobe belonging to the original positive hit, so repeated seeds
            -- from the second dot do not always converge on the first one.
            best = distance(profile.positive, profile.seed, ctx) < distance(result, profile.seed, ctx)
                and profile.positive or result
        end
        if best == profile.middle then return finish(best) end
        profile.previous, profile.best = profile.middle, best
        profile.direction, profile.phase = best.offset > 0 and 1 or -1, 3
        return walk()
    elseif profile.phase == 3 then
        if result.half > profile.best.half then
            profile.previous, profile.best = profile.best, result
            return walk()
        end
        -- Interpolate within the measured bracket, then measure that section
        -- and confirm its center separately before publishing or saving it.
        local left, middle, right = profile.previous.half^2, profile.best.half^2, result.half^2
        local curvature = left - 2 * middle + right
        if curvature >= -0.01 then return finish(profile.best) end
        local shift = profile.direction * 4 * (left - right) / (2 * curvature)
        shift = math.max(-4, math.min(4, shift))
        if math.abs(shift) < 0.125 then return finish(profile.best) end
        profile.phase = 4
        return profileProbe(profile, profile.best.offset + shift, ctx)
    end
    return finish(result.half >= profile.best.half and result or profile.best)
end
local rectangleSeed, rectangleGate
local function centerProfile(job, ctx, x, y)
    local angle = job.halfWidth < job.halfHeight and 0 or math.pi / 2
    local nearest
    local reach = 4 * PIXEL_STEP / (ctx.width * ctx.scale / 2) * ctx.radius
    for _, node in ipairs(nodes) do
        local separation = distance(node, job.group, ctx)
        if node.centered and node.map == ctx.map and node.id == job.group.id and node.hitRadius
            and separation > node.hitRadius^2 and separation < reach^2 and (not nearest or separation < nearest) then
            -- Expose the new lobe's far edge instead of cutting through the
            -- known node and repeatedly converging on its center.
            local east, north = (job.group.x - node.x) * ctx.w, (node.y - job.group.y) * ctx.h
            local sx, sy = east * ctx.cos + north * ctx.sin, north * ctx.cos - east * ctx.sin
            if sx == 0 then angle = sy >= 0 and math.pi / 2 or -math.pi / 2
            else
                angle = math.atan(sy / sx)
                if sx < 0 then angle = angle + math.pi end
            end
            nearest = separation
        end
    end
    local angles = {angle, math.pi / 4, -math.pi / 4}
    if math.min(job.halfWidth, job.halfHeight) >= 6 then
        -- The perpendicular cut exposes the far lobe when the first set of
        -- sections crosses the connection between two close dots.
        angles = {angle, angle + math.pi / 2, math.pi / 4, -math.pi / 4}
    end
    local profile = {group = job.group, x = x, y = y, originX = x, originY = y,
        seed = {x = job.group.x, y = job.group.y}, moving = job.moving,
        angle = angle, angles = angles, angleIndex = 1,
        extent = math.max(job.halfWidth, job.halfHeight) * 1.5, phase = 0, reads = 0}
    return rectangleGate({original = job, fallback = profileProbe(profile, 0, ctx)}, ctx, 1)
end
rectangleGate = function(gate, ctx, step)
    -- Test a shifted straight edge before spending a whole trace on a box.
    -- Circular hitboxes continue with their ordinary profile after four reads.
    local original = gate.original
    local normal = (original.y - original.group.y) * ctx.h * ctx.cos
        - (original.group.x - original.x) * ctx.w * ctx.sin
    local unit = ctx.radius / (ctx.width * ctx.scale / 2)
    local x = original.halfWidth + (step % 2 == 0 and 0.5 or -0.5)
    local y = original.halfWidth * (step <= 2 and 0.6 or -0.6)
    return {group = original.group, axis = 3, rectangleGate = gate, rectangleStep = step,
        x = original.x - normal * ctx.sin / ctx.w + (x * ctx.cos - y * ctx.sin) * unit / ctx.w,
        y = original.y - normal * ctx.cos / ctx.h - (y * ctx.cos + x * ctx.sin) * unit / ctx.h,
        cos = ctx.cos, sin = ctx.sin, moving = gate.fallback.moving}
end
rectangleSeed = function(original, fallback, ctx, index)
    -- A count increase means another same-title hitbox joined this ray. Its
    -- first subsequent decrease exposes the original box's edge even though
    -- the neighboring tooltip remains present. Start in a single-title area.
    if index > 5 then return fallback end
    local x, y = original.group.x, original.group.y
    if index > 1 then
        local horizontal = index < 4
        local radius = horizontal and original.halfWidth or original.halfHeight
        local shift = math.max(0, radius - 2) * (index % 2 == 0 and -1 or 1)
            / (ctx.width * ctx.scale / 2) * ctx.radius
        x, y = original.x, original.y
        if horizontal then x, y = x + shift * ctx.cos / ctx.w, y - shift * ctx.sin / ctx.h
        else x, y = x - shift * ctx.sin / ctx.w, y - shift * ctx.cos / ctx.h end
    end
    return {group = original.group, x = x, y = y, axis = 1, sign = -1,
        reach = 2, inside = 0, cos = ctx.cos, sin = ctx.sin, moving = fallback.moving,
        rectangle = {original = original, fallback = fallback, index = index}}
end
local function nextRectangle(job, ctx)
    local box = job.rectangle
    return rectangleSeed(box.original, box.fallback, ctx, box.index + 1)
end
local function rectangleEdge(box, ctx, step)
    local pair = math.floor((step - 1) / 2)
    local edge, sample = math.floor(pair / 3), pair % 3 - 1
    local horizontal, sign = edge < 2, edge % 2 == 0 and -1 or 1
    local outside = step % 2 == 0
    local across = sample * 0.6
    local x = horizontal and sign * (box.halfWidth + (outside and 0.5 or -0.5)) or across * box.halfWidth
    local y = horizontal and across * box.halfHeight or sign * (box.halfHeight + (outside and 0.5 or -0.5))
    local unit = ctx.radius / (ctx.width * ctx.scale / 2)
    return {group = box.group, axis = 3, rectangleEdge = box, rectangleStep = step,
        x = box.x + (x * ctx.cos - y * ctx.sin) * unit / ctx.w,
        y = box.y - (y * ctx.cos + x * ctx.sin) * unit / ctx.h,
        cos = ctx.cos, sin = ctx.sin, moving = box.moving}
end
local function rejectFastLocation(group)
    local saved = group.fastLocation
    for _, node in ipairs(nodes) do
        if saved and node.fastLocation == saved then node.fastLocation = nil end
    end
    group.fastLocation = nil
    group.samples = group.samples + 1
    scan.nextPublish = 0
end
local function shapeCheck(job, ctx, step)
    local angle = math.pi / 4 + math.floor((step - 1) / 2) * math.pi / 2
    local radius = math.max(job.halfWidth, job.halfHeight) + (step % 2 == 1 and -0.75 or 0.75)
    local east, north = math.cos(angle) * radius, math.sin(angle) * radius
    local unit = ctx.radius / (ctx.width * ctx.scale / 2)
    return {group = job.group, axis = 3, shapeCheck = job, shapeStep = step,
        x = job.x + (east * ctx.cos - north * ctx.sin) * unit / ctx.w,
        y = job.y - (north * ctx.cos + east * ctx.sin) * unit / ctx.h,
        cos = ctx.cos, sin = ctx.sin, moving = job.moving}
end
-- Refine an observed hit, never an invented location. Measure opposite edges
-- of its tooltip hitbox and use their midpoint, horizontally then vertically.
-- Each call uses one probe and shares discovery's frame/time limits. The seed
-- stays in zone coordinates so player movement between frames is accounted for.
local function refineCenter(ctx)
    local job = scan.centerJob
    if job and job.group.fastLocation and (playerMoving or GetTime() - lastMovement < TRACKING_SETTLE) then
        job.group.centerTried, scan.centerJob = nil, nil
        return false
    end
    if not job then
        for _, group in ipairs(scan.found) do
            if group.centered and group.pendingHits then
                -- A coarse group may have seen more than one real dot. Check
                -- the retained hits again after measuring the first hitbox.
                while #group.pendingHits > 0 do
                    local hit = table.remove(group.pendingHits)
                    if distance(group, hit, ctx) >= group.hitRadius^2 then
                        job = {group = group, x = hit.x, y = hit.y, probeOnly = true, cos = ctx.cos, sin = ctx.sin}
                        break
                    end
                end
                if #group.pendingHits == 0 then group.pendingHits = nil end
                if job then scan.centerJob = job; break end
            end
            if group.locationCandidate and GetTime() >= (group.locationRetryAt or 0) then
                job = {group = group, x = group.locationCandidate.x, y = group.locationCandidate.y,
                    locationOnly = true, cos = ctx.cos, sin = ctx.sin}
                scan.centerJob = job
                break
            elseif not group.centerTried and not (group.fastLocation
                and (playerMoving or GetTime() - lastMovement < TRACKING_SETTLE)) then
                group.centerTried = true
                if group.recenterNode then group.recenterTriedAt = GetTime() end
                job = { group = group, x = group.x, y = group.y, axis = 1, sign = -1,
                    reach = 2, inside = 0, cos = ctx.cos, sin = ctx.sin }
                scan.centerJob = job
                break
            end
        end
    end
    if not job then return false end
    if playerMoving or GetTime() - lastMovement < TRACKING_SETTLE then job.moving = true end
    if job.profile and job.moving then job.profile.moving = true end
    if job.circleCheck and job.moving then job.circleCheck.moving = true end
    if job.shapeCheck and job.moving then job.shapeCheck.moving = true end
    if job.rectangle and job.moving then job.rectangle.fallback.moving = true end
    if job.rectangleGate and job.moving then job.rectangleGate.fallback.moving = true end
    if job.rectangleEdge and job.moving then
        job.rectangleEdge.moving, job.rectangleEdge.rectangle.fallback.moving = true, true
    end
    if job.cos ~= ctx.cos or job.sin ~= ctx.sin then
        -- Edges measured along different orientations cannot be combined.
        scan.centerJob = nil
        return false
    end
    local east, north = (job.x - ctx.x) * ctx.w, (ctx.y - job.y) * ctx.h
    local x = ctx.width / 2 + (east * ctx.cos + north * ctx.sin) / ctx.radius * ctx.width / 2
    local y = ctx.height / 2 + (north * ctx.cos - east * ctx.sin) / ctx.radius * ctx.width / 2
    local offset = job.confirmed and job.sign * job.reach / ctx.scale or 0
    local probeCos, probeSin = job.probeCos or 1, job.probeSin or 0
    if job.axis == 1 then x, y = x + offset * probeCos, y + offset * probeSin
    else x, y = x - offset * probeSin, y + offset * probeCos end
    local dx, dy = x - ctx.width / 2, y - ctx.height / 2
    -- A clipped hitbox has no trustworthy midpoint. Leave the coarse estimate.
    if x < 1 or y < 1 or x > ctx.width - 1 or y > ctx.height - 1
        or dx^2 + dy^2 > (ctx.width / 2 - 1)^2 then
        scan.centerJob = nil
        return false
    end
    if job.probeOnly then
        probe(x, y, ctx)
        scan.centerJob = nil
        return true
    end
    Minimap:UpdateMouseoverAtPoint((ctx.left + x) * ctx.scale, (ctx.bottom + y) * ctx.scale)
    local tooltip = C_TooltipInfo.GetMinimapMouseover()
    local matched, unknown, matchedCount = false, not public(tooltip), 0
    if not unknown and tooltip ~= nil then
        if type(tooltip) ~= "table" or not public(tooltip.lines) or type(tooltip.lines) ~= "table" then
            unknown = true
        else
            for _, line in ipairs(tooltip.lines) do
                if not public(line) or type(line) ~= "table" or not public(line.leftText) then
                    unknown = true
                elseif type(line.leftText) == "string" then
                    for label in line.leftText:gmatch("[^\n]+") do
                        local resource = resourceFor(label, job.group.kind)
                        if resource and resource.id == job.group.id then
                            matched, matchedCount = true, matchedCount + 1
                            if not job.locationOnly then
                                job.group.elevationTag = elevationTag(label)
                                observeUnderground(job.group, label, line, resource)
                            end
                        end
                    end
                end
            end
        end
    end
    if job.locationOnly then
        if unknown then
            job.group.locationRetryAt = GetTime() + 1
        else
            local checks = job.group.locationChecks or {}
            local result = {x = job.x, y = job.y, matched = matched, single = matchedCount == 1, time = GetTime()}
            local replaced = false
            for i, checked in ipairs(checks) do
                if checked.x == job.x and checked.y == job.y then checks[i], replaced = result, true; break end
            end
            if not replaced then checks[#checks + 1] = result end
            job.group.locationChecks, job.group.locationCandidate = checks, nil
            job.group.samples = job.group.samples + 1
            scan.nextPublish = 0
        end
        scan.centerJob = nil
        return true
    end
    if job.rectangleGate then
        local gate = job.rectangleGate
        if unknown then scan.centerJob = nil
        elseif job.rectangleStep % 2 == 1 then
            gate.insideCount = matchedCount
            scan.centerJob = rectangleGate(gate, ctx, job.rectangleStep + 1)
        elseif gate.insideCount > matchedCount then
            scan.centerJob = rectangleSeed(gate.original, gate.fallback, ctx, 1)
        elseif job.rectangleStep < 4 then
            scan.centerJob = rectangleGate(gate, ctx, job.rectangleStep + 1)
        else scan.centerJob = gate.fallback end
        return true
    end
    if job.rectangleEdge then
        local box = job.rectangleEdge
        if unknown then scan.centerJob = nil
        elseif job.rectangleStep % 2 == 1 then
            box.edgeCount = matchedCount
            scan.centerJob = rectangleEdge(box, ctx, job.rectangleStep + 1)
        elseif box.edgeCount <= matchedCount then
            -- Every sampled straight edge must lose at least one resource
            -- title. A round lobe or a fabricated union midpoint fails here.
            scan.centerJob = box.rectangle.fallback
        elseif job.rectangleStep < 24 then
            scan.centerJob = rectangleEdge(box, ctx, job.rectangleStep + 1)
        else
            box.rectangleVerified, box.profileDone, box.rectangle = true, true, nil
            scan.centerJob = box -- one more fresh center read before publishing
        end
        return true
    end
    if job.rectangle and (unknown or not job.confirmed and matchedCount ~= 1) and job.axis ~= 3 then
        scan.centerJob = unknown and nil or nextRectangle(job, ctx)
        return true
    end
    if job.circleCheck then
        local profile = job.circleCheck
        if unknown then scan.centerJob = nil; return true end
        if matched and not profile.circleOutside then
            profile.circleOutside = true
        elseif not matched and profile.circleOutside then
            -- Check a fourth edge point independently: just inside must hit,
            -- just outside must miss. Then confirm the fitted center itself.
            local fit = profile.circleFits[profile.circleIndex]
            scan.centerJob = {group = job.group, x = fit.x, y = fit.y, axis = 3,
                cos = ctx.cos, sin = ctx.sin, profileDone = true, circleVerified = true,
                halfWidth = fit.radius, halfHeight = fit.radius, profileRadius = fit.radius, moving = profile.moving}
            return true
        else
            profile.circleOutside = false
            if profile.circleSide == 1 then profile.circleSide = 2
            else profile.circleSide, profile.circleIndex = 1, profile.circleIndex + 1 end
        end
        scan.centerJob = circleCheck(profile, ctx) or profileResult(profile, profile.circleResult, ctx, true)
        return true
    end
    if job.shapeCheck then
        local original = job.shapeCheck
        if unknown then scan.centerJob = nil
        elseif matched ~= (job.shapeStep % 2 == 1) then
            scan.centerJob = centerProfile(original, ctx, original.x, original.y)
        elseif job.shapeStep < 8 then
            scan.centerJob = shapeCheck(original, ctx, job.shapeStep + 1)
        else
            original.shapeChecked = true
            scan.centerJob = original
        end
        return true
    end
    if unknown or (not job.confirmed and not matched) then
        if not unknown and not matched and not job.confirmed and job.group.fastLocation and not job.profile then
            rejectFastLocation(job.group)
        end
        if job.profile and not unknown then
            scan.centerJob = profileResult(job.profile, {offset = job.profileOffset, half = 0, angle = job.profile.angle}, ctx)
        elseif not unknown and job.axis == 3 and not job.profileDone then
            -- Crossing two neighboring hitboxes can put the axis midpoint
            -- in empty space. Restart from the original observed hit.
            scan.centerJob = centerProfile(job, ctx, job.group.x, job.group.y)
        else
            scan.centerJob = nil
        end
        return true
    end
    if job.axis == 3 then
        if job.rectangle then
            if math.abs(job.halfWidth - job.halfHeight) > 0.5
                or math.min(job.halfWidth, job.halfHeight) < 2 or math.max(job.halfWidth, job.halfHeight) > 24 then
                scan.centerJob = job.rectangle.fallback
            else
                scan.centerJob = rectangleEdge(job, ctx, 1)
            end
            return true
        end
        local saved = job.group.fastLocation
        local precision = 0.75 / (ctx.width * ctx.scale / 2) * ctx.radius
        if job.profileDone and saved and not job.trustedCenter and distance(job, saved, ctx) > precision^2 then
            -- Overlapping lobes can still suggest a middle point. A trusted
            -- historical center wins over that disagreement, but check it live
            -- again before completing the background job. This is reuse of
            -- existing provenance, never a new center measurement.
            scan.centerJob = {group = job.group, x = saved.x, y = saved.y, axis = 3,
                cos = ctx.cos, sin = ctx.sin, profileDone = true, trustedCenter = saved,
                halfWidth = job.halfWidth, halfHeight = job.halfHeight, profileRadius = job.profileRadius}
            return true
        end
        if job.profileDone and not job.rectangleVerified and matchedCount ~= 1 then
            if job.trustedCenter then
                rejectFastLocation(job.group)
            end
            scan.centerJob = nil
            return true
        end
        -- Opposite-edge midpoints are only candidates. Confirm the final
        -- two-dimensional point itself before moving or saving the marker.
        local needsProfile = matchedCount > 1 or math.abs(job.halfWidth - job.halfHeight) > 2
            or job.halfWidth > job.halfHeight + 0.5
        local hitLimit = (math.min(job.halfWidth, job.halfHeight) + 2) / (ctx.width * ctx.scale / 2) * ctx.radius
        -- Coarse hits from a disconnected same-resource dot are discovery
        -- seeds. They do not make this independently checked center ambiguous.
        if not needsProfile then
            for _, node in ipairs(nodes) do
                if node ~= job.group and node.centered and node.id == job.group.id and node.map == ctx.map then
                    local separation = distance(node, job, ctx)
                    local precise = math.max(3, node.uncertainty + 2 / (ctx.width * ctx.scale / 2) * ctx.radius)
                    local observedRadius = node.hitRadius and math.max(0, node.hitRadius - node.uncertainty) or hitLimit
                    local candidateRadius = math.min(job.halfWidth, job.halfHeight)
                        / (ctx.width * ctx.scale / 2) * ctx.radius
                    if separation > precise^2 and separation < (observedRadius + candidateRadius)^2 then
                        needsProfile = true
                        break
                    end
                end
            end
        end
        if not job.profileDone and needsProfile then
            scan.centerJob = centerProfile(job, ctx, job.x, job.y)
            return true
        end
        if not job.profileDone and not job.shapeChecked and math.max(job.halfWidth, job.halfHeight) > 11 then
            -- A union of two overlapping hitboxes can look round in the two
            -- axis cuts. Its diagonal edges must agree before accepting it.
            scan.centerJob = shapeCheck(job, ctx, 1)
            return true
        end
        local group = job.group
        group.x, group.y, group.centered = job.x, job.y, true
        group.fastLocation = nil
        group.seedLocation = nil
        group.measuredCenter = not job.trustedCenter and {x = job.x, y = job.y} or nil
        group.trustedCenter = job.trustedCenter
        group.uncertainty = 2 / (ctx.width * ctx.scale / 2) * ctx.radius
        group.centerMoving = job.moving == true
        group.hitRadius = (job.profileRadius or math.max(job.halfWidth, job.halfHeight))
            / (ctx.width * ctx.scale / 2) * ctx.radius + group.uncertainty
        group.hitbox = nil
        if not job.trustedCenter and (job.circleVerified or job.rectangleVerified or not job.profileDone) then
            -- A reused saved center or an older profile's union width does
            -- not establish a safe interior to exclude from discovery.
            local interior = job.circleVerified and job.profileRadius or math.min(job.halfWidth, job.halfHeight)
            group.hitbox = {radius = interior / (ctx.width * ctx.scale / 2) * ctx.radius, width = ctx.width,
                scale = ctx.scale, viewRadius = ctx.radius, iconScale = ctx.iconScale}
        end
        group.samples = group.samples + 1
        scan.nextPublish = 0
        scan.centerJob = nil
        return true
    end
    if not job.confirmed then
        job.confirmed, job.boundaryCount, job.seedCount = true, matchedCount, matchedCount
        return true
    end
    local inside = matched
    if job.rectangle then
        inside = matchedCount >= job.boundaryCount
        if inside and not job.outside then job.boundaryCount = matchedCount end
    end
    if inside then job.inside = job.reach else job.outside = job.reach end
    if not job.outside then
        if job.reach >= 48 then scan.centerJob = nil; return true end
        -- Walk the connected hitbox in short steps. Exponential jumps can
        -- leap over an empty gap and mistake the next same-name dot for an edge.
        job.reach = math.min(48, job.reach + 2)
    elseif job.outside - job.inside > (job.profile and 0.0078125 or job.rectangle and 0.125 or 0.75) then
        job.reach = (job.inside + job.outside) / 2
    else
        -- Use confirmed edges to form a candidate, then verify it separately.
        local edge = job.inside
        if job.sign == -1 then
            job.negative, job.sign = edge, 1
            job.boundaryCount = job.seedCount
            job.inside, job.outside, job.reach = 0, nil, 2
        else
            local shift = (edge - job.negative) / 2 / ctx.scale / (ctx.width / 2) * ctx.radius
            if job.profile then
                local axisCos, axisSin = job.axisCos or ctx.cos, job.axisSin or ctx.sin
                if job.axis == 1 then
                    job.x, job.y = job.x + shift * axisCos / ctx.w, job.y - shift * axisSin / ctx.h
                else
                    job.x, job.y = job.x - shift * axisSin / ctx.w, job.y - shift * axisCos / ctx.h
                end
                scan.centerJob = profileResult(job.profile,
                    {offset = job.profileOffset, half = (edge + job.negative) / 2,
                        x = job.x, y = job.y, angle = job.profile.angle}, ctx)
            elseif job.axis == 1 then
                job.halfWidth = (edge + job.negative) / 2
                job.x, job.y = job.x + shift * ctx.cos / ctx.w, job.y - shift * ctx.sin / ctx.h
                job.axis, job.sign, job.confirmed = 2, -1, false
                job.inside, job.outside, job.reach = 0, nil, 2
            else
                job.x, job.y = job.x - shift * ctx.sin / ctx.w, job.y - shift * ctx.cos / ctx.h
                job.halfHeight = (edge + job.negative) / 2
                job.axis, job.confirmed = 3, false
            end
        end
    end
    return true
end
local function publish(ctx, now)
    prune(now)
    local merge = math.max(6, 18 / (ctx.width * ctx.scale / 2) * ctx.radius)
    for _, found in ipairs(scan.found) do
        if found.published ~= found.samples or found.centered and not found.centerMoving and not found.locationSaved then
            anchorSavedLocation(found, ctx)
            local existing, nearest
            for _, node in ipairs(nodes) do
                local nodeAnchor, foundAnchor = node.fastLocation or node.savedAnchor, found.fastLocation or found.savedAnchor
                local differentAnchors = nodeAnchor and foundAnchor and (node.x ~= found.x or node.y ~= found.y)
                local limit = merge
                if (node.centered or node.fastLocation) and (found.centered or found.fastLocation) then
                    limit = math.min(merge, math.max(3, node.uncertainty + found.uncertainty))
                    if not (node.savedAnchor and found.savedAnchor) and node.centerMoving and found.centerMoving then
                        -- Opposite directions can put two provisional world
                        -- anchors on opposite sides of the same lagging blip.
                        limit = math.max(limit, (node.hitRadius or limit) + (found.hitRadius or limit))
                    elseif not (node.savedAnchor and found.savedAnchor) and (node.centerMoving or found.centerMoving) then
                        limit = math.max(limit, math.min(node.hitRadius or node.fastLocation and merge or limit,
                            found.hitRadius or found.fastLocation and merge or limit))
                    end
                else
                    -- Unrefined hits describe an area, not distinct centers.
                    -- Opposite edges of one tooltip hitbox must share a
                    -- picture until refinement can distinguish their dots.
                    limit = math.max(merge, node.uncertainty + found.uncertainty)
                end
                -- The first positive hit may already be in the cache. After
                -- refinement it can land on another cached observation of
                -- this same dot; finding itself first must not keep both.
                local separation = distance(node, found, ctx)
                if not differentAnchors and node ~= found and node.map == ctx.map and node.id == found.id
                    and separation < limit^2 and (not nearest or separation < nearest) then
                    existing, nearest = node, separation
                end
            end
            if not existing and found.centered and found.recenterNode then
                for _, node in ipairs(nodes) do
                    if node == found.recenterNode then existing = node; break end
                end
            end
            if existing then
                for i = #nodes, 1, -1 do
                    if nodes[i] == found or found.centered and nodes[i] == found.recenterNode and nodes[i] ~= existing then
                        table.remove(nodes, i)
                    end
                end
            else
                for _, node in ipairs(nodes) do
                    if node == found then existing = found; break end
                end
            end
            if found.centered and not found.centerMoving and not found.locationSaved then
                if existing and existing ~= found and existing.centered and not existing.centerMoving then
                    -- Repeated refinement belongs to this live observation;
                    -- do not save tiny hitbox variations as new spawn points.
                    found.x, found.y, found.uncertainty = existing.x, existing.y, existing.uncertainty
                end
                if found.underground == nil and existing then found.underground = existing.underground end
                found.locationSaved = saveLocation(found, ctx)
            end
            if existing then
                -- Once centered, keep this observation anchored in zone space.
                -- Fresh hitbox estimates must not shift a still-live marker.
                if found.centered and not (existing.fastLocation and found.centerMoving)
                    and (not existing.centered or found.locationSaved and not existing.locationSaved
                    or found.locationSaved and found.locationRecord and found.uncertainty < existing.uncertainty
                    or existing.centerMoving and (not found.centerMoving or found.savedAnchor and not existing.savedAnchor)) then
                    existing.x, existing.y = found.x, found.y
                    existing.uncertainty = found.uncertainty
                    existing.centered = found.centered
                    existing.hitRadius = found.hitRadius
                    existing.centerMoving = found.centerMoving
                    existing.locationSaved = found.locationSaved
                    existing.savedAnchor = found.savedAnchor
                    existing.fastLocation = nil
                    existing.seedLocation = nil
                elseif found.fastLocation and not existing.centered and not existing.fastLocation then
                    existing.x, existing.y, existing.uncertainty = found.x, found.y, found.uncertainty
                    existing.fastLocation = found.fastLocation
                end
                if found.centered and not found.centerMoving then existing.hitbox = found.hitbox end
                if found.savedAnchor and existing.x == found.x and existing.y == found.y then existing.savedAnchor = found.savedAnchor end
                existing.seen = now
                existing.missingAt = nil
                existing.name = found.name
                existing.elevationTag = found.elevationTag
                if found.underground ~= nil then existing.underground = found.underground end
                if found.locationRecord then existing.locationRecord = found.locationRecord end
                existing.tooltipDifficulty, existing.tooltipSkillRevision = found.tooltipDifficulty, found.tooltipSkillRevision
            else
                if #nodes >= MAX_NODES then
                    local oldest = 1
                    for i = 2, #nodes do if nodes[i].seen < nodes[oldest].seen then oldest = i end end
                    table.remove(nodes, oldest)
                end
                found.seen = now
                nodes[#nodes + 1] = found
            end
            found.published = found.samples
        end
    end
    scan.nextPublish = now + 0.2
end
local function commit(ctx, now)
    publish(ctx, now)
    if scan.phase < GRID_DIVISIONS^2 - 1 then
        -- Interlace coarse passes into a finer net. Keep the original
        -- fast first pass, then cover its gaps without an idle rescan delay.
        scan.phase, scan.index = scan.phase + 1, 0
        for _, group in ipairs(scan.found) do
            if not group.centered then group.centerTried = nil end
        end
        draw(ctx, now)
        return
    end
    -- Unobserved nodes of the other tracking type remain until expiry/gathering.
    cursors[scan.kind] = nil
    scan = nil
    local speed = GetUnitSpeed and GetUnitSpeed("player")
    nextScan = now + (number(speed) and speed > 0 and 1.5 or 4)
    draw(ctx, now)
end

local function gridPoint(index, columns, rows)
    local cx, cy = math.floor(columns / 2), math.floor(rows / 2)
    if index == 0 then return cx, cy end
    -- Visit the centre first, expanding one square ring at a time. Grid indices
    -- can be resumed on the next visit to this tracking type without allocation.
    local ring = math.ceil((math.sqrt(index + 1) - 1) / 2)
    local offset, side = index - (2 * ring - 1)^2, 2 * ring
    if offset < side then return cx - ring + offset, cy - ring
    elseif offset < 2 * side then return cx + ring, cy - ring + offset - side
    elseif offset < 3 * side then return cx + ring - offset + 2 * side, cy + ring
    else return cx - ring, cy + ring - offset + 3 * side end
end

-- Recheck one nearby remembered dot at a time while its own tracker is active.
-- A small grid tolerates the estimated position and minimap hitbox. One complete
-- public empty check disproves a marker; secret data or API failures prove nothing.
-- Work shares the discovery scanner's per-frame probe and profiling budgets.
local function canValidateNode(node, ctx)
    if not isKindActive(node.kind) or node.map ~= ctx.map then return false end
    local east, north = (node.x - ctx.x) * ctx.w, (ctx.y - node.y) * ctx.h
    local uncertainty = node.uncertainty
    -- Include the estimate's uncertainty when excluding circular edges and
    -- the shorter vertical view of a rectangular minimap.
    return east^2 + north^2 < (ctx.radius * 0.65)^2
        and math.sqrt(east^2 + north^2) + uncertainty < ctx.radius * 0.95
        and math.abs(north * ctx.cos - east * ctx.sin) + uncertainty < ctx.radius * 0.72
end

local function validateNode(ctx, now)
    if not validation then
        if now < nextValidation then return false end
        for _ = 1, #nodes do
            validationCursor = validationCursor % #nodes + 1
            local node = nodes[validationCursor]
            -- Keep edge observations: clipped native dots cannot be disproved.
            if (not node.missingAt or now - node.missingAt >= EMPTY_RECHECK)
                and canValidateNode(node, ctx) then
                local extent = math.max(1, math.ceil(node.uncertainty / ctx.radius * ctx.width * ctx.scale / 2 / PIXEL_STEP))
                validation = { node = node, point = 0, extent = extent, seen = node.seen,
                    scale = ctx.scale, radius = ctx.radius, width = ctx.width }
                break
            end
        end
        if not validation then nextValidation = now + 0.25; return false end
    end
    local check, matched = validation, false
    local node = check.node
    local east, north = (node.x - ctx.x) * ctx.w, (ctx.y - node.y) * ctx.h
    -- Movement/rotation can bring a candidate to an unsafe edge between probes.
    if not canValidateNode(node, ctx)
        or check.scale ~= ctx.scale or check.radius ~= ctx.radius or check.width ~= ctx.width then
        validation = nil
        return false
    end
    local col, row = gridPoint(check.point, check.extent * 2, check.extent * 2)
    -- Positive observations are useful immediately, but a tracking transition
    -- can briefly expose no native dots. Such empty reads prove no absence.
    if now < (validationReady[node.kind] or 0) then check.unknown = true end
    local x = ctx.width / 2 + (east * ctx.cos + north * ctx.sin) / ctx.radius * ctx.width / 2
    local y = ctx.height / 2 + (north * ctx.cos - east * ctx.sin) / ctx.radius * ctx.width / 2
    local step = PIXEL_STEP
    if node.centered then
        -- A precise marker needs only its own uncertainty checked. The coarse
        -- grid can otherwise hit a neighboring dot of the same resource.
        step = math.min(PIXEL_STEP, math.max(1, node.uncertainty / ctx.radius * ctx.width * ctx.scale / 2))
    end
    Minimap:UpdateMouseoverAtPoint((ctx.left + x) * ctx.scale + (col - check.extent) * step,
        (ctx.bottom + y) * ctx.scale + (row - check.extent) * step)
    local tooltip = C_TooltipInfo.GetMinimapMouseover()
    if not public(tooltip) or (tooltip ~= nil and (type(tooltip) ~= "table"
        or not public(tooltip.lines) or type(tooltip.lines) ~= "table")) then
        check.unknown = true
    elseif tooltip then
        for _, line in ipairs(tooltip.lines) do
            if not public(line) or type(line) ~= "table" or not public(line.leftText) then
                check.unknown = true
            elseif type(line.leftText) == "string" then
                for label in line.leftText:gmatch("[^\n]+") do
                    local resource = resourceFor(label, node.kind)
                    if resource and resource.id == node.id then
                        matched = true
                        node.elevationTag = elevationTag(label)
                        observeUnderground(node, label, line, resource)
                    end
                end
                if matched and node.kind ~= "treasure" then
                    local difficulty = NS:GetGatheringTooltipDifficulty(line, node.kind)
                    if difficulty then
                        node.tooltipDifficulty = difficulty
                        node.tooltipSkillRevision = NS:GetGatheringSkillRevision()
                    end
                end
            end
        end
    end
    check.point = check.point + 1
    if matched or check.point >= (check.extent * 2 + 1)^2 then
        if matched then
            node.seen = now
            node.missingAt = nil
        elseif not check.unknown and node.seen <= check.seen then
            if node.missingAt and now - node.missingAt >= EMPTY_RECHECK then
                for i, cached in ipairs(nodes) do
                    if cached == node then table.remove(nodes, i); break end
                end
                draw(ctx, now)
            else
                node.missingAt = now
            end
        else
            node.missingAt = nil
        end
        validation, nextValidation = nil, now + 0.1
    end
    return true
end

-- Physical source for the existing cache/renderer. Never requests a virtual hit.
local manual = {captures = 0, combatCaptures = 0, savedMatches = 0, returnMatches = 0, ambiguousReturns = 0, visitedKinds = {}, returningKinds = {}}
-- Explicit, session-only support recording. Separate rings preserve scan events
-- against high-rate input traffic. Never retain arbitrary tooltip contents.
local placementTrace
local placementAutoStarted=false
local function prunePlacementRing(ring,cutoff)
    while ring.count>0 do
        local oldest=(ring.next-ring.count-1)%4096+1
        if ring.times[oldest]>=cutoff then break end
        ring[oldest],ring.times[oldest]=nil,nil
        ring.count=ring.count-1
    end
end
function NS:RecordNodePlacement(channel, detail)
    local t=placementTrace
    if not t or not t.active then return end
    local now=GetTime()
    local ring=t[channel]
    if not ring then ring={next=1,count=0,dropped=0,times={}};t[channel]=ring end
    prunePlacementRing(ring,now-t.window)
    local mode=self.CursorSweepActive and (self.MinimapScanActive and 'experimental minimap' or 'experimental HUD')
        or self.QuickScanner and self.QuickScanner.hudMapDisplay and 'experimental HUD idle'
        or self.db.hud.enabled and 'normal HUD' or 'normal minimap'
    local line=mode..'; '..detail
    -- Bound repeated reads per state; empty traffic cannot consume the ring
    -- at frame rate. Counts describe calls, not independent node detections.
    ring.states=ring.states or {}
    local stateKey=channel=='input' and line:gsub('; map=.*$','') or line
    local previous=ring.states[stateKey]
    if channel=='input' or channel=='display' then
        local interval=channel=='display' and 10 or 1
        if previous and now-previous.at<interval then previous.count=previous.count+1;return end
        ring.repeats=previous and previous.count or 0
        if not previous then
            if (ring.stateCount or 0)>=128 then ring.states={};ring.stateCount=0 end
            ring.stateCount=(ring.stateCount or 0)+1
        end
        ring.states[stateKey]={at=now,count=0}
    end
    ring.times[ring.next]=now
    ring[ring.next]=string.format('+%.2fs %s%s',now-t.started,line,
        (ring.repeats or 0)>0 and '; previous repeats='..ring.repeats or '')
    ring.repeats=0
    ring.next=ring.next%4096+1
    if ring.count==4096 then ring.dropped=ring.dropped+1 end
    ring.count=math.min(4096,ring.count+1)
end
-- Reusable copy window; opening it takes a snapshot and leaves recording alone.
function NS:ShowNodePlacementReport(text)
    local window=self.NodePlacementReportWindow
    if not window then
        window=CreateFrame('Frame','FDGNodePlacementReport',UIParent,'BasicFrameTemplateWithInset')
        self.NodePlacementReportWindow=window
        window:SetSize(820,560)
        window:SetPoint('CENTER')
        window:SetFrameStrata('DIALOG')
        window:SetClampedToScreen(true)
        window:EnableMouse(true)
        window:SetMovable(true)
        window:RegisterForDrag('LeftButton')
        window:SetScript('OnDragStart',window.StartMoving)
        window:SetScript('OnDragStop',window.StopMovingOrSizing)
        window.TitleText:SetText('Node placement diagnostic report')
        local help=window:CreateFontString(nil,'OVERLAY','GameFontHighlightSmall')
        help:SetPoint('TOPLEFT',16,-34)
        help:SetText('Full recording snapshot. Ctrl+A then Ctrl+C to copy. Escape closes. Reopen report to refresh.')
        local scroll=CreateFrame('ScrollFrame',nil,window,'UIPanelScrollFrameTemplate')
        scroll:SetPoint('TOPLEFT',16,-58)
        scroll:SetPoint('BOTTOMRIGHT',-34,16)
        local edit=CreateFrame('EditBox',nil,scroll)
        edit:SetMultiLine(true)
        edit:SetAutoFocus(false)
        edit:SetFontObject('ChatFontNormal')
        edit:SetWidth(760)
        edit:SetHeight(470)
        edit:SetMaxLetters(0)
        edit:SetScript('OnEscapePressed',function() window:Hide() end)
        edit:SetScript('OnTextChanged',function() scroll:UpdateScrollChildRect() end)
        edit:SetScript('OnCursorChanged',function(_,_,y,_,height)
            local offset=scroll:GetVerticalScroll()
            y=-y
            if y<offset then scroll:SetVerticalScroll(y)
            elseif y+height>offset+scroll:GetHeight() then scroll:SetVerticalScroll(y+height-scroll:GetHeight()) end
        end)
        scroll:SetScrollChild(edit)
        window.edit,window.scroll=edit,scroll
        window:SetScript('OnHide',function() edit:ClearFocus() end)
        UISpecialFrames=UISpecialFrames or {}
        UISpecialFrames[#UISpecialFrames+1]='FDGNodePlacementReport'
    end
    window:Show()
    window.edit:SetText(text)
    window.edit:SetFocus()
    window.edit:HighlightText()
    window.scroll:SetVerticalScroll(0)
end
function NS:NodePlacementTraceCommand(message)
    local command,arg=(message or ''):lower():match('^%s*(%S*)%s*(.-)%s*$')
    local function out(line) self.Print('Node trace: '..line) end
    if command=='start' then
        local minutes=math.max(1,math.min(5,tonumber(arg) or 5))
        placementTrace={active=true,started=GetTime(),window=minutes*60}
        self:RecordNodePlacement('events','rolling recording started; window='..minutes..' minutes')
        out('continuously recording the last '..minutes..' minutes across all map modes; /fdgdiag report [page], /fdgdiag stop. Session only; reload clears recording.')
    elseif command=='stop' then
        if placementTrace then self:RecordNodePlacement('events','recording stopped');placementTrace.active=false;placementTrace.stopped=GetTime() end
        out('stopped; /fdgdiag report [page] retains recorded history.')
    elseif command=='report' then
        local t=placementTrace
        if not t then out('no recording; /fdgdiag start [minutes] (default 5, maximum 5)');return end
        local rows,headers={},{}
        for _,key in ipairs({'events','points','input','display'}) do
            local ring=t[key]
            if ring then
                prunePlacementRing(ring,(t.stopped or GetTime())-t.window)
                headers[#headers+1]=key..': retained='..ring.count..'; overwritten='..ring.dropped
                for i=1,ring.count do rows[#rows+1]=key..' '..ring[(ring.next-ring.count+i-2)%4096+1] end
            end
        end
        table.sort(rows,function(a,b) return (tonumber(a:match('%+(%d+%.%d+)s')) or 0)<(tonumber(b:match('%+(%d+%.%d+)s')) or 0) end)
        if arg=='' then
            local header=string.format('Node placement report; %s; elapsed=%.1fs; last %.0fs rolling window; full retained history; reload clears recording',t.active and 'recording' or 'finished',GetTime()-t.started,t.window)
            self:ShowNodePlacementReport(header..'\n'..table.concat(headers,'\n')..'\n\n'..table.concat(rows,'\n'))
            return true
        end
        for _,line in ipairs(headers) do out(line) end
        local pages=math.max(1,math.ceil(#rows/35))
        local page=math.max(1,math.min(pages,math.floor(tonumber(arg) or pages)))
        out(string.format('%s; elapsed=%.1fs; page=%d/%d (default latest); chronological; reload clears history',t.active and 'recording' or 'finished',GetTime()-t.started,page,pages))
        for i=(page-1)*35+1,math.min(#rows,page*35) do out(rows[i]) end
    else return false end
    return true
end
local function placementInput(reason,ctx)
    if not placementTrace or not placementTrace.active then return end
    local detail='tracking='..tostring(activeKind)..'; '..reason
    if ctx then detail=detail..string.format('; map=%s player=%.4f,%.4f native=%.1fx%.1f scale=%.3f radius=%.1f origin=%.1f,%.1f',tostring(ctx.map),ctx.x,ctx.y,ctx.width,ctx.height,ctx.scale,ctx.radius,ctx.left,ctx.bottom) end
    NS:RecordNodePlacement('input',detail)
end

-- FarmRoute: copy the rolling node trace into the saved file on /reload or
-- logout, so it can be read outside the game (ForeverFarmRouteGatheringDB.lastTrace).
function NS:SnapshotNodeTrace(status)
    local t=placementTrace
    if not self.db then return end
    local rows={}
    if t then
        for _,key in ipairs({'events','points','display','input'}) do
            local ring=t[key]
            if ring then
                for i=1,ring.count do
                    local line=tostring(ring[(ring.next-ring.count+i-2)%4096+1])
                    -- Idle heartbeats crowd out the scan details.
                    if not line:find('heartbeat',1,true) then rows[#rows+1]=key..' '..line end
                end
            end
        end
        table.sort(rows,function(a,b) return (tonumber(a:match('%+(%d+%.%d+)s')) or 0)<(tonumber(b:match('%+(%d+%.%d+)s')) or 0) end)
        while #rows>2500 do table.remove(rows,1) end
    end
    self.db.lastTrace={saved=date and date('%Y-%m-%d %H:%M:%S') or '?',status=status,rows=rows}
end

NS.ManualNodeHoverSourceReady = true
function NS:SetManualNodeHoverEnabled(value)
    self.ManualNodeHoverEnabled = true -- 2.0 exclusively uses physical hover.
    scan, validation = nil, nil
    cursors = {}
    manual.pending, manual.latch, manual.absence, manual.passive = nil, nil, nil, nil
    manual.visitedKinds,manual.returningKinds,manual.lastKind={},{},nil
    self:UpdateRememberedNodes()
end
function NS:ObserveCursorSweepNodeHint(node,hit)
    if not node or not hit or not hit.resource or hit.resource.id~=node.id or hit.resource.kind~=node.kind
        or not public(hit.label) or type(hit.label)~='string' then return end
    local now=GetTime()
    node.seen=now -- A unique matching positive always renews live expiry.
    -- Match 1.1.2: a fresh matching label replaces the observed symbol,
    -- including clearing it when the client supplies no elevation arrow.
    -- Experimental arrows survive tracker changes until their next reading.
    node.elevationTag=elevationTag(hit.label)
    -- Artificial map motion cannot establish height geometry, but the native
    -- resource title colour remains a direct observation of the cave hint.
    if public(hit.line) and type(hit.line)=='table' then
        observeUnderground(node,hit.label,hit.line,hit.resource)
    end
end
-- Aggregate all cached observations, with one bounded example for support.
function NS:GetCompactNodeDiagnostic(limit)
    local counts,total,example={},0,nil
    for _,node in ipairs(nodes)do
        local r=renderStates[node]
        local status=r and r.status or 'no draw'
        if r and r.x and (not example or status=='outside draw bounds') then
            example=string.format('%s: %s; offset=%.1f,%.1f; refined=%s',tostring(node.name or node.id),status,r.x,r.y or 0,tostring(node.manualRefined==true))
            if node.anonymous then
                example=example..'; artwork='..tostring(node.anonymousArtworkStatus or 'not rendered')
                    ..'; uncertainty='..tostring(node.uncertainty)..' yd'
            end
            if status=='outside draw bounds' then break end
        end
    end
    for _,node in ipairs(nodes)do
        total=total+1;local r=renderStates[node];local status=r and r.status or 'no draw'
        counts[status]=(counts[status] or 0)+1
    end
    local summary={}
    for status,count in pairs(counts)do summary[#summary+1]=status..'='..count end
    table.sort(summary)
    local report={'nodes='..total..'; '..table.concat(summary,', ')..'; draw age='..(self.LastNodeDrawComplete and string.format('%.2fs',GetTime()-self.LastNodeDrawComplete) or '?')
        ..'; group mask='..tostring(self.AnonymousGroupMaskStatus or 'not sampled')
        ..'; anonymous exclusion='..tostring(self.AnonymousReadExclusion or 'none')
        ..'; quest mask='..tostring(self.AnonymousQuestMaskStatus or 'not sampled')..'; capture error='..tostring(manual.lastError or 'none'),example or 'node example=none'}
    for i=1,math.min(#nodes,limit or 12) do
        local node=nodes[i]
        local r=renderStates[node]
        local origin=node.manualKeyAnchor and 'manual bind' or node.quickScanObservation and 'quick scan'
            or node.cursorSweepObservation and 'full scan' or node.farmProbeKey and 'FarmRoute scan' or 'physical hover'
        local function xy(x,y)
            if not number(x) or not number(y) then return 'unplaced' end
            return string.format('%.3f,%.3f',x*100,y*100)
        end
        report[#report+1]=string.format('node #%d %s; origin=%s; map=%s; observed=%s; displayed=%s; age=%.1fs; ttl=%.1fs; %s; artwork=%s',
            i,tostring(node.name or node.id),origin,tostring(node.map),xy(node.x,node.y),
            r and xy(r.displayX,r.displayY) or 'unplaced',
            number(node.seen) and math.max(0,GetTime()-node.seen) or 0,self:GetGatheringObservationTTL(node),
            r and r.status or 'no draw',tostring(node.anonymousArtworkStatus or 'named'))
    end
    return report
end
function NS:DebugNodeGathering()
    local report=manual.lastGather
    local text="Node gathering [cursor-follow-76]: last player success="..tostring(manual.lastSuccessSpell or "none")
    if report then
        text=text.."; gather="..report.spellID.."; "..report.outcome
        if report.nearestDistance then text=text..string.format("; nearest observed %.1f yd",report.nearestDistance) end
        if report.targetName then text=text.."; cast target="..report.targetName
        elseif report.targetEvidence then text=text.."; target evidence="..report.targetEvidence end
        if report.name then text=text.."; "..report.name end
        if report.at then text=text..string.format("; gather %.1f s ago (memories %d, matching kind %d)",GetTime()-report.at,report.memoryCount,report.sameKindCount) end
    else text=text.."; no recognized gather received" end
    text=text.."; reconciled duplicates="..tostring(manual.reconciledDuplicates or 0).."; refinements="..tostring(manual.refinements or 0).."; refinement="..tostring(manual.refinementStatus or "waiting for crossings")
    text=text.."; tracking="..tostring(activeKind or "none").."; last hover="..tostring(manual.lastHover or "none")
        .."; candidate="..tostring(manual.lastCandidate or "none").."; memories="..#nodes
    text=text.."; completed crossings="..tostring(manual.completedCrossings or 0)
        .."; last geometry="..tostring(manual.lastGeometry or "no independent pair yet")
    text=text.."; quest boundary reads="..tostring(manual.questBoundaryReads or 0)
    text=text.."; rejected tooltip="..tostring(manual.lastRejectedTooltip or "none")
    if manual.lastHoverAt then text=text..string.format("; last resource hover %.1f s ago",GetTime()-manual.lastHoverAt) end
    if pendingGathered[1] and pendingGathered[1].error then text=text.."; location save deferred: "..pendingGathered[1].error end
    local trial=self.CursorSweepTrial
    text=text.."; cursor trial="..(self.CursorSweepActive and "active" or "off")
        .."; boundary module="..(trial and trial.RefinementRead and "loaded" or "missing")
    if trial then
        text=text.."; boundary refinements="..tostring(trial.refined or 0)
            .."; boundary status="..tostring(trial.refineStatus or "waiting")
            .."; discovery="..tostring(trial.discoveryStatus or "waiting").."; positive probes="..tostring(trial.positiveProbes or 0)
        text=text..'; marked-node rechecks='..(trial.ValidationPoint and tostring(trial.validationStatus or 'waiting') or 'module not loaded')
            ..'; swap checked='..tostring(trial.validationBatchChecked or 0)..'/'..tostring(trial.validationBatchTotal or 0)
            ..'; missing retired='..tostring(trial.missingRetired or 0)
        if trial.steeringTest then
            local stats=trial.steeringStats or {}
            text=text.."; steering READ-ONLY="..tostring(stats.reads or 0).." reads/"..tostring(stats.changes or 0).." label changes"
        end
        if trial.refinement then text=text.."; probe="..tostring(trial.refinement.phase).."/"..tostring(trial.refinement.axis).."/"..tostring(trial.refinement.serial) end
    end
    local function readVisual(object,method)
        if not object or type(object[method])~='function' then return 'unavailable' end
        local ok,value=pcall(object[method],object)
        if not ok or not public(value) then return 'unknown' end
        if type(value)=='number' then return string.format('%.2f',value) end
        if type(value)=='boolean' or type(value)=='string' then return tostring(value) end
        return 'unset'
    end
    text=text..'; renderer='..tostring(overlayMode or 'none')..'; HUD visible='..readVisual(self.HUDFrame,'IsVisible')
        ..'; layer visible='..readVisual(self.NodeOverlay,'IsVisible')..'; configured node opacity='..tostring(self.db.hud.nodeIconOpacity)
    if self.LastNodeDrawComplete then text=text..string.format('; last completed draw %.2fs ago',GetTime()-self.LastNodeDrawComplete) end
    if self.LastNodeDrawAttempt and (not self.LastNodeDrawComplete or self.LastNodeDrawAttempt>self.LastNodeDrawComplete)then
        text=text..'; draw interrupted before completion'
    end
    if manual.lastError then text=text..'; capture error='..tostring(manual.lastError) end
    local ctx=readContext()
    for i,node in ipairs(nodes) do
        local state=node.manualRefined and 'refined' or 'approximate hover anchor'
        if trial and trial.refinement and trial.refinement.node==node then state='centering in progress' end
        local detail=string.format('Node %d: %s; %s; uncertainty=%.1f yd',i,tostring(node.name or node.id),state,node.uncertainty or 0)
        if ctx and node.map==ctx.map then
            local e,n=(node.x-ctx.x)*ctx.w,(ctx.y-node.y)*ctx.h
            local half=ctx.width*ctx.scale/2
            local px=(e*ctx.cos+n*ctx.sin)/ctx.radius*half
            local py=(n*ctx.cos-e*ctx.sin)/ctx.radius*half
            detail=detail..string.format('; native-map offset=(%.1f,%.1f)px; uncertainty=%.1fpx',px,py,(node.uncertainty or 0)/ctx.radius*half)
            local hit=node.manualLastHit
            if hit and number(hit.x) and number(hit.y) then
                local e,n=(hit.x-ctx.x)*ctx.w,(ctx.y-hit.y)*ctx.h
                detail=detail..string.format('; last-positive offset=(%.1f,%.1f)px',(e*ctx.cos+n*ctx.sin)/ctx.radius*half,(n*ctx.cos-e*ctx.sin)/ctx.radius*half)
            end
        end
        local rendered=renderStates[node]
        detail=detail..'; render='..tostring(rendered and rendered.status or 'no draw recorded')
        if rendered then
            detail=detail..'; image shown='..readVisual(rendered.image,'IsShown')
                ..'; image visible='..readVisual(rendered.image,'IsVisible')
                ..'; effective alpha='..readVisual(rendered.image,'GetEffectiveAlpha')
                ..'; texture='..readVisual(rendered.image,'GetTexture')
                ..'; height hint='..tostring(node.elevationTag and elevationSide(node.elevationTag) or 'none')
                ..'; height arrow shown='..readVisual(rendered.elevation,'IsShown')
            if rendered.x then detail=detail..string.format('; HUD offset=(%.1f,%.1f); assigned alpha=%.2f',rendered.x,rendered.y,rendered.alpha or 0)end
        end
        self.Print(detail)
    end
    local held=0
    for _,record in ipairs(collected)do if record.requiresEmpty then held=held+1 end end
    self.Print(text.."; chest loot="..tostring(manual.chestLootStatus or "none").."; gathered locations awaiting native clearance="..held)
end
local chestOpening,chestLoot,gatherTarget
local function beginChestLoot()
    chestLoot=nil
    if not chestOpening or GetTime()-chestOpening.at>15 then manual.chestLootStatus="no fresh recognized chest opening";return end
    local ctx=readContext()
    if not ctx or ctx.map~=chestOpening.map or distance(ctx,chestOpening,ctx)>25 then return end
    if type(GetNumLootItems)~="function" or type(GetLootSourceInfo)~="function" then manual.chestLootStatus="loot source unavailable";return end
    local ok,count=pcall(GetNumLootItems)
    if not ok or not number(count) or count<1 or count>64 or count%1~=0 then return end
    local guid
    for slot=1,count do
        local sources={pcall(GetLootSourceInfo,slot)}
        if not sources[1] or #sources<3 then manual.chestLootStatus="unreadable loot source";return end
        for i=2,#sources,2 do
            local source=sources[i]
            if not public(source) or type(source)~="string" or not source:match("^GameObject%-")
                or guid and guid~=source then manual.chestLootStatus="loot is not one recognized chest source";return end
            guid=source
        end
    end
    chestLoot={opening=chestOpening,count=count,cleared={},at=GetTime()}
    manual.chestLootStatus="recognized chest; waiting for complete loot"
end
local function clearChestLootSlot(slot)
    local loot=chestLoot
    if not loot or not number(slot) or slot<1 or slot>loot.count or slot%1~=0 then return end
    loot.cleared[slot]=true
    for i=1,loot.count do if not loot.cleared[i]then return end end
    chestLoot=nil;chestOpening=nil
    local ctx=readContext()
    if not ctx or ctx.map~=loot.opening.map or GetTime()-loot.at>60 or distance(ctx,loot.opening,ctx)>25 then return end
    local candidate
    for _,node in ipairs(nodes)do
        if node.map==ctx.map and node.kind=="treasure" and node.id==loot.opening.id then
            local tolerance=12
            if not node.manualRefined and node.manualLastHit then
                tolerance=math.min(40,12+node.manualLastHit.pixel*9*node.manualLastHit.iconScale)
            end
            if math.min(distance(node,ctx,ctx),distance(node.manualLastHit or node,ctx,ctx))<=tolerance^2 then
                if candidate then manual.chestLootStatus="ambiguous nearby chest memories; retained";return end
                candidate=node
            end
        end
    end
    if not candidate then manual.chestLootStatus="looted chest had no unique nearby observation";return end
    -- Exact completed chest loot confirms this unique observed resource.
    -- Save its observed coordinate and uncertainty, including scanner observations,
    -- without granting measured-center provenance or changing other trial saves.
    do
        local snapshot={}
        for key,value in pairs(candidate)do snapshot[key]=value end
        snapshot.cursorSweepObservation=nil
        if candidate.importedAnchor and candidate.manualLastHit then
            snapshot.x,snapshot.y=candidate.manualLastHit.x,candidate.manualLastHit.y
            snapshot.uncertainty=candidate.manualLastHit.pixel*2
        end
        pendingGathered[#pendingGathered+1]={node=snapshot,ctx=ctx}
    end
    if #collected>=MAX_NODES then table.remove(collected,1)end
    local observed=candidate.manualRefined and candidate or candidate.manualLastHit or candidate
    collected[#collected+1]={map=candidate.map,kind=candidate.kind,id=candidate.id,x=observed.x,y=observed.y,
        radius=math.max(12,candidate.uncertainty or 0),expires=GetTime()+(NS.CursorSweepActive and 300 or 10),
        requiresEmpty=NS.CursorSweepActive and true or nil}
    if NS.CursorSweepActive and NS.CursorSweepTrial.AbortRefinement then
        local job=NS.CursorSweepTrial.refinement or NS.CursorSweepTrial.refinePending
        if job and job.node==candidate then NS.CursorSweepTrial:AbortRefinement("chest looted")end
    end
    for i,node in ipairs(nodes)do if node==candidate then table.remove(nodes,i);break end end
    manual.chestLootStatus="removed fully looted "..tostring(candidate.name)
    draw(ctx,GetTime())
    saveGathered()
end
function NS:GetGatheringNodeContext() return readContext() end
function NS:CursorSweepRefined(node,ctx)
    manual.refinements=(manual.refinements or 0)+1
    manual.refinementStatus="refined from cursor sweep boundaries"
    if not self.CursorSweepActive or not node or not ctx then return end
    local function measured(n)
        return n.manualRefined and n.manualProvisional and n.cursorSweepObservation
            and not n.savedAnchor and not n.locationRecord and not n.fastLocation and not n.centered
    end
    if not measured(node) then return end
    if self.CursorSweepTrial and self.CursorSweepTrial.ReleaseDeferredDiscoveries then
        self.CursorSweepTrial:ReleaseDeferredDiscoveries(node,ctx)
    end
    local candidate,index
    local currentPixel=2*ctx.radius/(ctx.width*ctx.scale)
    for i,old in ipairs(nodes) do
        if old~=node and measured(old) and old.map==node.map and old.kind==node.kind
            and old.id==node.id and old.name==node.name and number(old.cursorSweepRefinementPixel)
            and number(node.cursorSweepRefinementPixel) then
            -- One physical pixel at the finer measured view. Rough hit-area
            -- overlap never approves a merge; both centres must be measured.
            local tolerance=math.min(currentPixel,old.cursorSweepRefinementPixel,node.cursorSweepRefinementPixel)
            if distance(old,node,ctx)<=tolerance^2 then
                if candidate then return end -- Competing measured centres defer.
                candidate,index=old,i
            end
        end
    end
    if not candidate then return end
    local keep,drop=candidate,node
    if number(node.uncertainty) and number(candidate.uncertainty) and node.uncertainty<candidate.uncertainty then
        keep,drop=node,candidate
    end
    keep.seen=math.max(keep.seen or 0,drop.seen or 0)
    if keep==candidate then keep.manualLastHit=node.manualLastHit or keep.manualLastHit end
    for i,old in ipairs(nodes)do if old==drop then table.remove(nodes,i);break end end
    manual.reconciledDuplicates=(manual.reconciledDuplicates or 0)+1
    manual.refinementStatus="reconciled independently measured duplicate"
end
function NS:GetManualNodeHoverStatus()
    return manual, nodes
end
local function manualSavedAnchor(node, spot, ctx, now, single, settled)
    if not single or not settled or node.manualRefined then return end
    local pixel = 2 * ctx.radius / (ctx.width * ctx.scale)
    local candidate
    for _, source in ipairs({{NS.db.nodeLocations, "personal"}, {NS.BundledNodeLocations, "bundled"}}) do
        local index = locationIndex(source[1], ctx.map, source[2])
        if index then
            if not index:Build(128) then return end
            local saved, ambiguous = matchingLocation(index, {x=spot.x,y=spot.y,id=node.id,kind=node.kind,uncertainty=node.uncertainty}, ctx, 3)
            if ambiguous then return end
            if saved then
                if candidate and (candidate.x ~= saved.x or candidate.y ~= saved.y) then return end
                if not candidate or saved.uncertainty < candidate.uncertainty then candidate = saved end
            end
        end
    end
    if not candidate or candidate.centerVersion ~= CENTER_VERSION or candidate.uncertainty > node.uncertainty
        or distance(candidate,spot,ctx) > (pixel*0.75)^2 then return end
    node.locationChecks = {{x = candidate.x, y = candidate.y, time = now, matched = true, single = true}}
    if reuseLocation(node, candidate, true) then
        if node.fastLocation ~= candidate then manual.savedMatches = manual.savedMatches + 1 end
        node.fastLocation, node.savedAnchor = candidate, candidate
        node.importedAnchor = nil
        -- Historical centre is an anchor, not a newly measured centre.
        node.manualProvisional = nil
    end
end
-- Imported coordinates can suggest one bounded placement only after a real
-- settled single-resource hover. They never earn precision or centre trust.
local function manualImportedAnchor(node, spot, ctx, single, settled)
    if not single or not settled or node.kind == "treasure" or node.savedAnchor
        or node.fastLocation or node.centered or node.manualRefined or node.importedAnchor
        or not NS.GetImportedNodeLocations then return end
    local pixel = 2 * ctx.radius / (ctx.width * ctx.scale)
    local radius = math.min(12, pixel * 8 * ctx.iconScale)
    -- Personal observations and the existing author history take priority,
    -- including records too approximate to earn verified-centre reuse.
    for _, source in ipairs({{NS.db.nodeLocations,"personal"},{NS.BundledNodeLocations,"bundled"}}) do
        local index = locationIndex(source[1],ctx.map,source[2])
        if index then
            if not index:Build(128) then return end
            local saved, ambiguous = matchingLocation(index,node,ctx,radius)
            if saved or ambiguous then return end
        end
    end
    local source = NS:GetImportedNodeLocations(ctx.map)
    local index = locationIndex(source,ctx.map,"imported")
    if not index or not index:Build(128) then return end
    local saved, ambiguous = matchingLocation(index,
        {x=spot.x,y=spot.y,id=node.id,kind=node.kind,uncertainty=node.uncertainty},ctx,radius)
    if not saved or ambiguous then return end
    -- A neighbouring live observation prevents guessing which native dot owns
    -- the historical coordinate. Never merge discoveries through imported data.
    for _, other in ipairs(nodes) do
        if other ~= node and other.map == ctx.map
            and distance(other,spot,ctx) <= (radius+pixel*2)^2 then return end
    end
    local displacement = math.sqrt(distance(saved,spot,ctx))
    node.x,node.y = saved.x,saved.y
    node.uncertainty = math.max(node.uncertainty+displacement,
        math.sqrt(ctx.w^2+ctx.h^2)*0.0005)
    node.importedAnchor = saved
    -- Keep manualProvisional. A database hint is not a physical centre read.
end
-- Positive association and empty-hover absence have different evidence needs.
-- A weak quest/resource boundary may support reuse on an actual resource read
-- without proving that empty map space means the remembered node is absent.
local function measuredPositiveMatch(resource,spot,ctx,now)
    local pixel=2*ctx.radius/(ctx.width*ctx.scale)
    local candidate,nearby= nil,0
    for _,old in ipairs(nodes) do
        if old.map==ctx.map and old.id==resource.id and old.kind==resource.kind and old.name==resource.name
            and now-old.seen<=NS:GetGatheringObservationTTL(old)
            and math.min(distance(old,spot,ctx),distance(old.manualLastHit or old,spot,ctx))<=(pixel*24*ctx.iconScale)^2 then
            nearby=nearby+1
            local area=old.manualPositiveFootprint
            if area and distance(area,spot,ctx)<=(pixel*ctx.iconScale*area.radius)^2 then candidate=old end
        end
    end
    if candidate and nearby==1 then return candidate end
    if candidate then return nil,true end -- Never merge or seed another overlapping memory.
end

-- Infer provisional geometry only from naturally visited, public samples.
-- Opposing empty/positive transitions form chords; repeated stationary frames
-- do not add geometric evidence. This never earns saved-centre provenance.
local function passiveSample(ctx, now, spot, hits, reliable, empty, questBoundary)
    local key = table.concat({ctx.map,ctx.w,ctx.h,ctx.width,ctx.height,ctx.scale,ctx.radius,
        ctx.cos,ctx.sin,ctx.left,ctx.bottom,ctx.iconScale}, ':')
    local otherResourceBoundary=false
    local currentTrace=manual.passive and manual.passive.key==key and manual.passive.trace
    if reliable and currentTrace and #hits>0 then
        local target=currentTrace.node
        local matching
        for _,hit in ipairs(hits) do
            local resource=hit.resource
            if resource.kind==target.kind and resource.id==target.id and resource.name==target.name then matching=hit end
        end
        if matching then
            -- An exclusively entered resource keeps its own label identity
            -- while another resource label joins the native tooltip.
            hits={matching}
        else
            -- A different recognized resource marks target-label absence,
            -- not empty map space. Retain weak-boundary safeguards and prevent
            -- this synthetic negative from starting the neighbour's trace.
            hits={};empty=true;questBoundary=true;otherResourceBoundary=true
        end
    end
    if not reliable or #hits>1 or #hits==0 and not empty then
        manual.lastRejectedTooltip=manual.tooltipDetail or "unclassified tooltip"
        manual.refinementStatus=not reliable and "unreadable tooltip fields" or #hits>1 and "multiple resource identities" or "public non-resource tooltip text"
        if reliable then
            -- Public player/POI labels are not empty boundaries. Discard only
            -- the unfinished trace; completed node-local geometry remains
            -- usable under its existing view key and 30-second lifetime.
            if manual.passive then
                manual.passive.previous,manual.passive.trace,manual.passive.continuousNode=nil,nil,nil
            end
        else
            manual.passive=nil
        end
        return
    end
    local node
    local pixel=2*ctx.radius/(ctx.width*ctx.scale)
    if #hits==1 then
        local resource=hits[1].resource
        for _,old in ipairs(nodes)do
            if old.map==ctx.map and old.id==resource.id and old.kind==resource.kind and old.name==resource.name
                and now-old.seen <= NS:GetGatheringObservationTTL(old)
                and math.min(distance(old,spot,ctx),distance(old.manualLastHit or old,spot,ctx))<(pixel*24*ctx.iconScale)^2 then
                -- Different public resource labels distinguish their traces;
                -- two nearby memories with the same identity still defer.
                if node then manual.refinementStatus="nearby competing same-resource memory";manual.passive=nil;return end
                node=old
            end
        end
        if not node then
            manual.refinementStatus="no live memory near the actual resource hover";manual.lastCandidate="none";manual.passive=nil;return
        end
        manual.lastCandidate=node.fastLocation and "saved anchor" or node.centered and "centred anchor" or "provisional memory"
        if not node.manualProvisional and not node.manualLastHit then
            manual.refinementStatus="candidate has no physical hover evidence";manual.passive=nil;return
        end
    end
    local state=manual.passive
    if not state or state.key~=key then manual.passiveEpoch=(manual.passiveEpoch or 0)+1;state={key=key,epoch=manual.passiveEpoch,originX=ctx.x,originY=ctx.y};manual.passive=state end
    -- Keep every crossing in one world-fixed pixel plane as the player travels.
    -- Zoom/rotation/layout changes still start a new evidence epoch.
    local east,north=(spot.x-state.originX)*ctx.w,-(spot.y-state.originY)*ctx.h
    local x=(east*ctx.cos+north*ctx.sin)/pixel+ctx.width*ctx.scale/2
    local y=(-east*ctx.sin+north*ctx.cos)/pixel+ctx.height*ctx.scale/2
    state.continuousNode=nil
    local previous=state.previous
    local sample={x=x,y=y,node=node,time=now,playerX=ctx.x,playerY=ctx.y,questBoundary=questBoundary,otherResourceBoundary=otherResourceBoundary}
    local motion=previous and math.sqrt(((ctx.x-previous.playerX)*ctx.w)^2+((ctx.y-previous.playerY)*ctx.h)^2)/pixel or 0
    -- Native hover labels can lag travel. Reject abrupt travel and include a
    -- 150ms motion allowance in accepted provisional uncertainty.
    if previous and (motion>1.5 or motion>0 and now-previous.time>0.15) then manual.passive=nil;return end
    local motionGap=previous and motion*0.15/math.max(0.01,now-previous.time) or 0
    if node and distance(node.manualLastHit or node,spot,ctx)<=(pixel*2)^2 then sample.linked=node end
    state.previous=sample
    if not previous then return end
    local dx,dy=x-previous.x,y-previous.y
    local step=math.sqrt(dx*dx+dy*dy)
    local maxStep=now-previous.time<=1/30+.001 and 12*ctx.iconScale or 3
    if now-previous.time>0.15 or step>maxStep+.001 then
        if node or previous.node or state.trace then
            manual.refinementStatus=string.format("crossing rejected: %.1f px / %.0f ms (limit %.1f px)",step,(now-previous.time)*1000,maxStep)
        end
        state.trace=nil;return
    end
    -- Link only fresh, bounded real positive samples on one isolated node.
    -- Empty/unknown reads, neighbours, layout changes and cursor jumps break it.
    if node and previous.node==node and previous.linked==node then
        sample.linked=node
        state.continuousNode=node
    end
    if not previous.node and node then
        if previous.otherResourceBoundary then state.trace=nil;return end
        state.trace={node=node,entryX=(x+previous.x)/2,entryY=(y+previous.y)/2,
            minX=x,maxX=x,minY=y,maxY=y,gap=step,motionGap=motionGap,count=1,points={{x=x,y=y}},questBoundary=previous.questBoundary}
        return
    end
    local trace=state.trace
    if not trace or previous.node~=trace.node or node and node~=trace.node then state.trace=nil;return end
    trace.motionGap=math.max(trace.motionGap,motionGap)
    if node then
        trace.minX=math.min(trace.minX,x);trace.maxX=math.max(trace.maxX,x)
        trace.minY=math.min(trace.minY,y);trace.maxY=math.max(trace.maxY,y)
        if step>0.25 then
            trace.count=trace.count+1
            if #trace.points>=64 then state.trace=nil;return end
            trace.points[#trace.points+1]={x=x,y=y}
        end
        return
    end
    state.trace=nil
    local exitX,exitY=(x+previous.x)/2,(y+previous.y)/2
    local dx,dy=exitX-trace.entryX,exitY-trace.entryY
    local length=math.sqrt(dx*dx+dy*dy)
    if length<4 or length>32*ctx.iconScale then
        manual.refinementStatus="crossing too short or too broad; needs empty boundaries";return
    end
    local ux,uy=dx/length,dy/length
    -- A straight crossing defines a chord at any angle. Curved/reversing
    -- cursor paths cannot supply its perpendicular-bisector constraint.
    local lastProjection=-math.huge
    for _,point in ipairs(trace.points) do
        local px,py=point.x-trace.entryX,point.y-trace.entryY
        local projection=px*ux+py*uy
        if math.abs(px*uy-py*ux)>1 or projection<lastProjection-.5 then return end
        lastProjection=projection
    end
    local chord={x=(exitX+trace.entryX)/2,y=(exitY+trace.entryY)/2,
        ux=ux,uy=uy,half=length/2,gap=math.max(trace.gap,step),motionGap=trace.motionGap,time=now,sparse=trace.count<2,
        questBoundary=trace.questBoundary or sample.questBoundary}
    node=trace.node
    manual.completedCrossings=(manual.completedCrossings or 0)+1
    local evidence=node.passiveChords
    if not evidence or evidence.key~=state.epoch then evidence={key=state.epoch};node.passiveChords=evidence end
    -- Keep independently directed chords. Near-parallel repeated passes do
    -- not constrain the second centre coordinate.
    local other=evidence.first
    if not other or now-other.time>30 then manual.refinementStatus="one crossing; waiting for another direction";evidence.first=chord;return end
    local determinant=other.ux*chord.uy-other.uy*chord.ux
    if math.abs(determinant)<.5 then manual.refinementStatus="crossings too parallel";evidence.first=chord;return end
    local validation
    if other.sparse or chord.sparse then
        validation=evidence.validation
        if not validation or now-validation.time>30 then
            evidence.validation=chord
            manual.refinementStatus="two sparse crossings; waiting for a third confirming pass";return
        end
        if math.abs(other.ux*validation.uy-other.uy*validation.ux)<.5 then
            evidence.validation=chord;return
        end
        -- Solve using the independent earlier pair, then require the new
        -- crossing to agree. One brief positive read never moves an icon alone.
        validation,chord=chord,validation
        determinant=other.ux*chord.uy-other.uy*chord.ux
    end
    local horizontal,vertical=other,chord
    local a=other.x*other.ux+other.y*other.uy
    local b=chord.x*chord.ux+chord.y*chord.uy
    local cx=(a*chord.uy-other.uy*b)/determinant
    local cy=(other.ux*b-a*chord.ux)/determinant
    local r1=math.sqrt(other.half^2+(other.x-cx)^2+(other.y-cy)^2)
    local r2=math.sqrt(chord.half^2+(chord.x-cx)^2+(chord.y-cy)^2)
    manual.lastGeometry=string.format("radii %.1f/%.1f px; direction independence %.2f",r1,r2,math.abs(determinant))
    if math.abs(r1-r2)>1 or math.max(r1,r2)>16*ctx.iconScale then
        manual.refinementStatus="crossing radii inconsistent or too large";return
    end
    if validation then
        local residual=math.abs((cx-validation.x)*validation.ux+(cy-validation.y)*validation.uy)
        local radius=math.sqrt(validation.half^2+(validation.x-cx)^2+(validation.y-cy)^2)
        if residual>math.max(1,validation.gap/2)
            or math.abs(radius-r1)>math.max(1,validation.gap/2)
            or radius>16*ctx.iconScale then
            manual.refinementStatus="sparse crossings disagree";return
        end
    end
    local east=(cx/ctx.scale-ctx.width/2)/(ctx.width/2)*ctx.radius
    local north=(cy/ctx.scale-ctx.height/2)/(ctx.width/2)*ctx.radius
    local centre={x=state.originX+(east*ctx.cos-north*ctx.sin)/ctx.w,
        y=state.originY-(north*ctx.cos+east*ctx.sin)/ctx.h}
    local uncertainty=pixel*math.max(0.75,math.max(horizontal.gap,vertical.gap)/2+0.5)+pixel*math.max(horizontal.motionGap,vertical.motionGap)
    if validation or horizontal.questBoundary or vertical.questBoundary then
        -- Well-sampled non-empty boundaries can solve after two crossings,
        -- retaining the conservative uncertainty previously used for three.
        uncertainty=math.max(uncertainty,pixel*(math.sqrt(horizontal.gap^2+vertical.gap^2)/(2*math.abs(determinant))+.5)
            +pixel*math.max(horizontal.motionGap,vertical.motionGap,validation and validation.motionGap or 0))
    end
    -- A rough first hit may lie at the edge of the measured native footprint.
    -- Bound correction by that footprint plus sampling uncertainty, rather
    -- than rejecting every valid centre more than eight pixels from the seed.
    local correctionPixels=math.min(18*ctx.iconScale,
        math.max(8*ctx.iconScale,math.max(r1,r2)+uncertainty/pixel))
    manual.lastGeometry=manual.lastGeometry..string.format("; shift %.1f px; uncertainty %.1f px; correction limit %.1f px",math.sqrt(distance(node,centre,ctx))/pixel,uncertainty/pixel,correctionPixels)
    if distance(node,centre,ctx)>(pixel*correctionPixels)^2 then
        manual.refinementStatus="estimated centre beyond measured correction bound"
        manual.lastGeometry=manual.lastGeometry.."; rejected by correction bound";return
    end
    if (node.manualRefined or node.fastLocation or node.savedAnchor or node.centered)
        and node.uncertainty<=uncertainty then
        manual.refinementStatus="existing anchor is more precise than current crossings";return
    end
    -- Historical placement is a starting point, not a reason to discard real
    -- boundary geometry. Correct only the session marker when evidence is
    -- better, and detach historical trust/references without mutating records.
    node.fastLocation,node.savedAnchor,node.locationRecord,node.locationSource=nil,nil,nil,nil
    node.locationChecks,node.locationCandidate=nil,nil
    node.centered,node.measuredCenter=nil,nil
    node.manualProvisional=true
    node.x,node.y,node.uncertainty=centre.x,centre.y,uncertainty
    node.manualRefined=true
    node.importedAnchor=nil
    -- This bounded area is only consulted after a real positive resource read.
    -- It is never used by absence/deletion logic, including weak boundaries.
    node.manualPositiveFootprint={x=centre.x,y=centre.y,
        radius=math.min(18*ctx.iconScale,math.max(r1,r2)+math.min(3*ctx.iconScale,uncertainty/pixel))/ctx.iconScale}
    -- Observed native hit area, not the tooltip window's visual dimensions.
    -- Store a conservative interior in native icon units for future zooms.
    if horizontal.questBoundary or vertical.questBoundary or validation and validation.questBoundary then
        -- A quest or different resource label means the target was not read,
        -- not that the native area is empty. Never authorize absence from it.
        node.manualHoverFootprint=nil
    else
        node.manualHoverFootprint={x=centre.x,y=centre.y,
            radius=math.max(0,math.min(r1,r2)-uncertainty/pixel-1)/ctx.iconScale}
    end
    manual.refinements=(manual.refinements or 0)+1
    manual.refinementStatus="refined from physical crossings"
    -- Keep manualProvisional; no saving, centreVersion, hitbox trust or height evidence.
end

local recheckPlayerNames,recheckPlayerNamesAt
function NS:IsKnownMinimapPlayerText(data,now)
    if type(UnitName)~='function' or not public(data) or type(data)~='table' or not public(data.lines)
        or type(data.lines)~='table' then return false end
    if not recheckPlayerNamesAt or now-recheckPlayerNamesAt>.5 then
        local names={}
        local function add(unit)
            local ok,name,realm=pcall(UnitName,unit)
            if ok and public(name) and type(name)=='string' and name~='' then
                names[clean(name)]=true
                if public(realm) and type(realm)=='string' and realm~='' then names[clean(name..'-'..realm)]=true end
            end
        end
        add('player')
        for i=1,4 do add('party'..i)end
        local ok,raid=false,false
        if type(IsInRaid)=='function' then ok,raid=pcall(IsInRaid) end
        if ok and public(raid) and raid==true then for i=1,40 do add('raid'..i)end end
        recheckPlayerNames,recheckPlayerNamesAt=names,now
    end
    local any=false
    for i=1,32 do
        local line=data.lines[i]
        if not public(line) or line~=nil and type(line)~='table' then return false end
        if line then
            for _,field in ipairs({'leftText','rightText'})do
                local value=line[field]
                if not public(value) or value~=nil and type(value)~='string' then return false end
                if value then
                    for label in value:gmatch('[^\r\n]+')do
                        local text=clean(label)
                        if text~='' then
                            if not recheckPlayerNames[text] then return false end
                            any=true
                        end
                    end
                end
            end
        end
    end
    return any and public(data.lines[33]) and data.lines[33]==nil
end
local function automaticScanOwnsSession()
    local mode=NS.ExperimentalMinimap
    return NS.MinimapScanActive or mode and mode.armed
        or NS.db and NS.db.minimap and NS.db.minimap.fullTimeScanning
end
local function physicalUpdate(ctx, now)
    -- Idle HUD replacement hides the native map. Pointer intersections with
    -- that hidden surface are not intentional physical minimap hovers.
    if not NS.CursorSweepActive and (automaticScanOwnsSession()
        or NS.QuickScanner and (NS.QuickScanner.hudMapDisplay or NS.QuickScanner.farmMap)) then
        manual.pending,manual.latch,manual.absence,manual.passive=nil,nil,nil,nil
        resetGatherClearance()
        placementInput("blocked: idle replacement owns hidden native map",ctx)
        return
    end
    local quick=NS.CursorSweepActive and NS.CursorSweepTrial.workflow and NS.CursorSweepTrial.workflow:Allows("knownOnly")
    if manual.nextRead and now < manual.nextRead then return end
    manual.nextRead=now+(NS.CursorSweepActive and 1/60 or 1/120)
    if NS.CursorSweepActive then
        -- Artificial map motion cannot establish absence or passive geometry.
        manual.absence, manual.passive = nil, nil
        if not NS.CursorSweepTrial:CanCapture() then placementInput("blocked: scanner capture gate; "..tostring(NS.CursorSweepTrial.reason),ctx); resetGatherClearance();manual.pending = nil; return end
    end
    if lootOpen or UnitIsDeadOrGhost and UnitIsDeadOrGhost("player")
        or UnitOnTaxi and UnitOnTaxi("player") then placementInput("blocked: loot/death/taxi",ctx);resetGatherClearance();manual.pending, manual.absence, manual.passive = nil, nil, nil; return end
    for _, fn in ipairs({UnitCastingInfo or false, UnitChannelInfo or false}) do
        if type(fn)=="function"then
            local ok,value=pcall(fn,"player")
            if not ok or not public(value) or value~=nil then placementInput("blocked: casting/channel or unreadable casting state",ctx);resetGatherClearance();manual.pending,manual.absence,manual.passive=nil,nil,nil;return end
        end
    end
    local x, y = GetCursorPosition()
    if not (number(x) and number(y)) then placementInput("blocked: tooltip unavailable/unreadable",ctx);resetGatherClearance();manual.pending, manual.absence, manual.passive = nil, nil, nil; return end
    local px, py = (x / ctx.scale - ctx.left), (y / ctx.scale - ctx.bottom)
    if px < 0 or py < 0 or px > ctx.width or py > ctx.height then placementInput("cursor outside native map",ctx);manual.pending, manual.absence, manual.passive = nil, nil, nil; return end
    placementInput(string.format("native read; cursor=%.1f,%.1f",px,py),ctx)
    local data = C_TooltipInfo.GetMinimapMouseover()
    if not public(data) or type(data) ~= "table" or not public(data.lines) or type(data.lines) ~= "table" then resetGatherClearance();manual.pending, manual.absence, manual.passive = nil, nil, nil; return end
    if manual.lastKind ~= activeKind then
        manual.returningKinds[activeKind or "none"] = activeKind and manual.visitedKinds[activeKind] or false
        if activeKind then manual.visitedKinds[activeKind] = true end
        manual.lastKind = activeKind
    end
    local hits, keys, reliable, nonempty = {}, {}, true, false
    local publicLabels, unreadable, questOnly = {}, nil, true
    local hasResourceLabel=false
    local farm=NS:FarmHUDOpen()
    local farmHover=farm and not NS.CursorSweepActive
    local anonymous=NS.GetAnonymousGatheringResource and NS:GetAnonymousGatheringResource(data,ctx,px,py)
    if anonymous and farm and validationReady[anonymous.kind]
        and now<validationReady[anonymous.kind]-TRACKING_SETTLE+0.2 then anonymous=nil end
    if not anonymous or farm then
    for i = 1, 32 do
        local line = data.lines[i]
        if not public(line) or line ~= nil and type(line) ~= "table" then reliable = false;unreadable="line "..i
        elseif line then
            for _, field in ipairs({"leftText", "rightText"}) do
                local value = line[field]
                if not public(value) or value ~= nil and type(value) ~= "string" then reliable = false;unreadable="line "..i.." "..field
                elseif type(value) == "string" then
                    if value:match("%S") then
                        nonempty = true
                        -- Native progress counters may color each number or
                        -- split the title/fraction across lines in one field.
                        if not clean(value):match("%d+%s*/%s*%d+") then questOnly=false end
                        if #publicLabels<3 then
                            publicLabels[#publicLabels+1]=value:gsub("|c%x%x%x%x%x%x%x%x",""):gsub("|r",""):gsub("|T.-|t","[art]"):gsub("[\r\n]"," "):sub(1,80)
                        end
                    end
                    for label in value:sub(1, 2048):gmatch("[^\r\n]+") do
                        if label:match("%S") and (resourceFor(label,"herb") or resourceFor(label,"ore") or resourceFor(label,"treasure")) then
                            questOnly=false;hasResourceLabel=true
                        end
                        local resource = activeKind and resourceFor(label, activeKind)
                        if not resource and activeTreasure then resource = resourceFor(label, "treasure") end
                        if not resource and farmHover then resource=resourceFor(label,'herb') or resourceFor(label,'ore') end
                        if resource and hasNodeSource(resource.kind) then
                            local key = resource.kind .. ":" .. resource.id .. ":" .. resource.name
                            if not keys[key] then
                                local hit={resource=resource,label=label,line=line,tooltipCount=1,tooltipSources={}}
                                hits[#hits + 1] = hit
                                keys[key] = hit
                            elseif field=='leftText' then
                                -- Preserve native repeated-title counts for1.1.2
                                -- overlap geometry without publishing extra identities.
                                keys[key].tooltipCount=keys[key].tooltipCount+1
                            end
                            local sources=keys[key].tooltipSources
                            if #sources<8 then sources[#sources+1]=i..(field=='leftText' and 'L' or 'R') end
                        end
                    end
                end
            end
        end
    end
    end
    -- A readable resource name takes precedence over an inferred tracker type.
    if anonymous and not hasResourceLabel then
        local key=anonymous.kind..':'..anonymous.id..':'..anonymous.name
        hits[1]={resource=anonymous,label=anonymous.name,line=data.lines[1],tooltipCount=1,tooltipSources={'1L'}}
        keys[key]=hits[1];reliable=true;nonempty=true;questOnly=false;hasResourceLabel=true
    elseif anonymous and farm and #hits>0 then
        reliable=true -- The anonymous reader already validated the tooltip structure.
    end
    if not public(data.lines[33]) or data.lines[33] ~= nil then reliable = false;unreadable="tooltip exceeds 32 lines" end
    if NS.CursorSweepActive and NS.CursorSweepTrial.TraceNativeRead then
        NS.CursorSweepTrial:TraceNativeRead(hits,reliable,nonempty,now)
    end
    manual.tooltipDetail=not reliable and "unreadable "..(unreadable or "field")
        or #hits>1 and "multiple resources: "..table.concat(publicLabels," / ")
        or #hits==0 and nonempty and "public text: "..table.concat(publicLabels," / ")
        or #hits==0 and "public empty" or "recognized resource"
    placementInput('read result='..(not reliable and 'unreadable' or #hits>0 and 'recognized resource' or nonempty and 'non-resource text' or 'empty')..'; hits='..#hits..'; exclusion='..tostring(NS.AnonymousReadExclusion)..'; resource='..tostring(hits[1] and hits[1].resource.name or 'none'),ctx)
    local east, north = (px - ctx.width / 2) / (ctx.width / 2) * ctx.radius,
        (py - ctx.height / 2) / (ctx.width / 2) * ctx.radius
    local spot = {x = ctx.x + (east * ctx.cos - north * ctx.sin) / ctx.w,
        y = ctx.y - (north * ctx.cos + east * ctx.sin) / ctx.h}
    local settled = not playerMoving and now - lastMovement >= TRACKING_SETTLE
    local pixel = 2 * ctx.radius / (ctx.width * ctx.scale)
    if reliable and #hits>0 then
        manual.lastHover=hits[1].resource.kind..":"..hits[1].resource.name
        manual.lastHoverAt=now
    end
    if clearGatheredSweepHover(ctx,spot,reliable,nonempty,now) then return end
    if NS.CursorSweepActive and NS.CursorSweepTrial.ValidationRead
        and NS.CursorSweepTrial:ValidationRead(ctx,spot,hits,reliable,nonempty,now,
            reliable and nonempty and #hits==0 and NS:IsKnownMinimapPlayerText(data,now)) then return end
    -- Snapshot before the refiner may finish/abort and request small geometry.
    local refinementOnly=NS.CursorSweepActive and NS.CursorSweepTrial.IsRefinementOnly
        and NS.CursorSweepTrial:IsRefinementOnly(ctx)
    if NS.CursorSweepActive and NS.CursorSweepTrial.RefinementRead
        and NS.CursorSweepTrial:RefinementRead(ctx,spot,hits,reliable,nonempty,now,not hasResourceLabel) then return end
    if refinementOnly then return end -- Enlarged samples never create/refresh live memories.
    if NS.CursorSweepActive and reliable and NS.CursorSweepTrial.DiscoveryRead
        and NS.CursorSweepTrial:DiscoveryRead(ctx,spot,hits,now,nonempty)==false then return end
    local capturesBefore,refinementsBefore=manual.captures,manual.refinements
    -- Explicit dismissal can be undone by a fresh physical rehover. Require
    -- sustained public empty reads first, so a lingering positive tooltip
    -- cannot immediately restore the dismissed picture. Gathering suppression
    -- has no explicitDismiss marker and keeps its existing timeout.
    for i=#collected,1,-1 do
        local dismissed=collected[i]
        if dismissed.explicitDismiss and dismissed.map==ctx.map then
            if reliable and not nonempty and #hits==0 then
                dismissed.emptySince=dismissed.emptySince or now
                if now-dismissed.emptySince>=0.15 then table.remove(collected,i) end
            else
                dismissed.emptySince=nil
            end
        end
    end
    -- Quest progress can bracket a provisional crossing; sparse samples
    -- need extra confirmation. Absence/dismissal still requires empty reads.
    if reliable and nonempty and questOnly and #hits==0 then
        manual.questBoundaryReads=(manual.questBoundaryReads or 0)+1
    end
    passiveSample(ctx,now,spot,hits,reliable,not nonempty or questOnly,nonempty and questOnly)
    if #hits == 0 then
        manual.pending = nil
        if reliable then manual.latch = nil end
        if not reliable or nonempty then manual.absence = nil; return end
        local target
        for _, node in ipairs(nodes) do
            if isKindActive(node.kind) and node.map == ctx.map then
                local footprint=node.manualHoverFootprint
                local lastHit=node.manualLastHit
                local inArea=not node.importedAnchor and distance(node,spot,ctx)<=(pixel*2)^2
                if footprint and distance(footprint,spot,ctx)<=(pixel*ctx.iconScale*footprint.radius)^2 then inArea=true end
                -- A real positive point remains useful even when the provisional
                -- picture is offset. Do not extrapolate its edge across zooms.
                if lastHit and lastHit.pixel==pixel and lastHit.iconScale==ctx.iconScale
                    and distance(lastHit,spot,ctx)<=(pixel*.75)^2 then inArea=true end
                if inArea then
                    if target then manual.absence=nil;return end
                    target=node
                end
            end
        end
        if not target then manual.absence = nil; return end
        if now < (validationReady[target.kind] or 0) then manual.absence=nil;return end
        local key=table.concat({ctx.map,ctx.width,ctx.height,ctx.scale,ctx.radius,ctx.cos,ctx.sin,ctx.left,ctx.bottom}, ':')
        local p = manual.absence
        local travel=p and math.sqrt(((ctx.x-p.playerX)*ctx.w)^2+((ctx.y-p.playerY)*ctx.h)^2)/pixel or 0
        -- Follow the same world spot, rather than demanding a frozen screen
        -- pointer while the native map scrolls beneath it.
        if not p or p.node ~= target or p.key~=key or now-p.time>0.15 or travel>1.5
            or distance(p,spot,ctx) > (pixel*3)^2 then
            manual.absence = {node=target,key=key,x=spot.x,y=spot.y,playerX=ctx.x,playerY=ctx.y,
                time=now,since=now,count=1,moving=not settled};return
        end
        p.x,p.y=spot.x,spot.y
        p.playerX,p.playerY,p.time=ctx.x,ctx.y,now
        p.moving=p.moving or not settled
        p.count = p.count + 1
        if p.count >= 3 and now - p.since >= (p.moving and MANUAL_EMPTY_MOVING or MANUAL_EMPTY_STILL) then
            for i, node in ipairs(nodes) do if node == target then table.remove(nodes, i); break end end
            manual.absence = nil
        end
        return
    end
    manual.absence = nil
    if not reliable then manual.pending = nil; return end
    local signature = {}; for key in pairs(keys) do signature[#signature + 1] = key end
    table.sort(signature); signature = table.concat(signature, ";")
    local pending = manual.pending
    if not pending or pending.signature ~= signature or (x-pending.x)^2+(y-pending.y)^2 > 1
        or pending.width ~= ctx.width or pending.scale ~= ctx.scale or pending.radius ~= ctx.radius
        or pending.cos ~= ctx.cos or pending.sin ~= ctx.sin then
        manual.pending = {signature = signature, x = x, y = y, since = now,
            width = ctx.width, scale = ctx.scale, radius = ctx.radius, cos = ctx.cos, sin = ctx.sin}
        pending = manual.pending
    end
    local stableHover = now - pending.since >= 0.25
    -- Publish a rough memory on the first real positive read, even in motion.
    -- Stable dwell remains required for historical placement hints.
    -- Continuous stale text must not seed another distant dot.
    local latch = manual.latch
    local continuousNode=manual.passive and manual.passive.continuousNode
    local measuredAmbiguous
    if #hits==1 then
        local measuredNode
        measuredNode,measuredAmbiguous=measuredPositiveMatch(hits[1].resource,spot,ctx,now)
        continuousNode=continuousNode or measuredNode
    end
    if continuousNode and distance(continuousNode,spot,ctx)>(pixel*18*ctx.iconScale)^2 then continuousNode=nil end
    if latch and latch.signature == signature and distance(latch, spot, ctx) > (pixel * 2)^2
        and not continuousNode then
        -- Confirmed sweep labels may revisit a different edge of one known
        -- hit area. Renew one unique bounded observation without moving its
        -- anchor, creating a second icon, or bypassing collection suppression.
        if NS.CursorSweepActive and #hits==1 and not recentlyCollected(hits[1].resource,spot,ctx) then
            local resource=hits[1].resource
            local repeated,ambiguous
            for _,old in ipairs(nodes)do
                if old.map==ctx.map and old.id==resource.id and old.kind==resource.kind and old.name==resource.name
                    and distance(old.manualLastHit or old,spot,ctx)<=(pixel*18*ctx.iconScale)^2 then
                    if repeated then ambiguous=true end
                    repeated=old
                end
            end
            if repeated and not ambiguous then NS:ObserveCursorSweepNodeHint(repeated,hits[1]) end
        end
        placementInput("withheld: stale tooltip latch moved without unique association",ctx)
        return
    end
    manual.latch = {signature = signature, x = spot.x, y = spot.y}
    for _, hit in ipairs(hits) do
        local resource = hit.resource
        if not recentlyCollected(resource, spot, ctx) then
            local node, best
            -- Each label keeps its own measured association even when another
            -- resource shares the tooltip. A Tin+Iron read must not bypass Tin's
            -- confirmed session footprint and publish a second Tin picture.
            local measured,ambiguous
            if #hits>1 then measured,ambiguous=measuredPositiveMatch(resource,spot,ctx,now) end
            if ambiguous then placementInput("withheld: ambiguous measured association",ctx);return end
            if measured then node=measured end
            if not node and continuousNode and continuousNode.id==resource.id and continuousNode.kind==resource.kind
                and continuousNode.name==resource.name then node=continuousNode end
            for _, old in ipairs(nodes) do
                if old.map == ctx.map and old.kind == resource.kind and old.id == resource.id and old.name == resource.name then
                    local d = distance(old, spot, ctx)
                    if old.manualLastHit then d = math.min(d, distance(old.manualLastHit, spot, ctx)) end
                    if d <= (pixel * 2)^2 and (not best or d < best) then node, best = old, d end
                end
            end
            if not node then
                local inside
                for _,old in ipairs(nodes) do
                    local area=old.manualHoverFootprint
                    if old.map==ctx.map and old.kind==resource.kind and old.id==resource.id and old.name==resource.name
                        and now-old.seen<=NS:GetGatheringObservationTTL(old) and area
                        and distance(area,spot,ctx)<=(pixel*ctx.iconScale*area.radius)^2 then
                        if inside then return end
                        inside=old
                    end
                end
                node=inside
            end
            if not node then
                -- Returning after a tracking change or player travel: opposite
                -- sides of one hit area need not repeat the same physical pixel.
                -- This is a provisional association, never centre evidence.
                local candidate, ambiguous, traveled
                -- Both observations may sit at opposite edges of the hit area.
                local hitRadius = pixel * 9 * ctx.iconScale
                for _, old in ipairs(nodes) do
                    if old.map == ctx.map and old.kind == resource.kind and old.id == resource.id and old.name == resource.name
                        and now-old.seen <= NS:GetGatheringObservationTTL(old) then
                        local d = distance(old,spot,ctx)
                        local tolerance = (old.manualAnchorHitRadius or hitRadius) + hitRadius
                        if d <= tolerance^2 then
                            if candidate then ambiguous = true end
                            candidate = old
                            local pose = old.manualObservationPose
                            if pose and (distance(pose, ctx, ctx) > (pixel * 2)^2
                                or pose.hitRadius ~= hitRadius) then traveled = true end
                        end
                    end
                end
                if ambiguous and (manual.returningKinds[resource.kind] or traveled) then
                    manual.ambiguousReturns = manual.ambiguousReturns + 1
                    -- Do not create a third icon or arbitrarily pick a neighbour.
                    return
                elseif candidate and not ambiguous and (manual.returningKinds[resource.kind] or traveled) then
                    node = candidate
                    manual.returnMatches = manual.returnMatches + 1
                end
            end
            if not node and measuredAmbiguous then placementInput("withheld: multiple measured matches",ctx);return end
            if not node and not stableHover and not NS.CursorSweepActive then
                -- A fresh edge beside an existing same-resource memory is
                -- ambiguous; let physical continuity/refinement associate it,
                -- or a stable hover establish a separate discovery.
                for _,old in ipairs(nodes) do
                    if old.map==ctx.map and old.id==resource.id and old.kind==resource.kind and old.name==resource.name
                        and now-old.seen<=NS:GetGatheringObservationTTL(old)
                        and distance(old,spot,ctx)<=(pixel*18*ctx.iconScale)^2 then return end
                end
            end
            if not node and NS.CursorSweepActive then
                -- Stable tooltip text proves a resource exists, not that this
                -- is a second spawn. Defer overlapping positional uncertainty.
                local hitRadius=pixel*9*ctx.iconScale
                local deferred,ambiguous
                for _,old in ipairs(nodes)do
                    if old.map==ctx.map and old.kind==resource.kind and old.id==resource.id and old.name==resource.name
                        and now-old.seen<=NS:GetGatheringObservationTTL(old) then
                        local priorRadius=old.manualRefined and (old.uncertainty or 0)
                            or math.max(old.uncertainty or 0,old.manualAnchorHitRadius or hitRadius)
                        local separation=distance(old,spot,ctx)
                        if not old.manualRefined and old.manualLastHit then separation=math.min(separation,distance(old.manualLastHit,spot,ctx)) end
                        if separation<=(priorRadius+hitRadius)^2 then
                            if deferred then ambiguous=true end
                            deferred=old
                        end
                    end
                end
                if deferred then
                    if NS.CursorSweepTrial.RememberDeferredDiscovery then
                        NS.CursorSweepTrial:RememberDeferredDiscovery(deferred,resource,spot,ctx,now)
                    end
                    if NS.CursorSweepTrial.Trace then NS.CursorSweepTrial:Trace('candidate deferred',tostring(resource.name or resource.id)..'; existing same-resource uncertainty overlaps') end
                    if not ambiguous then
                        deferred.seen=now
                        deferred.manualLastHit={x=spot.x,y=spot.y,pixel=pixel,iconScale=ctx.iconScale}
                        NS:ObserveCursorSweepNodeHint(deferred,hit)
                    end
                    manual.lastCandidate="second icon deferred: same-resource position uncertain"
                    manual.refinementStatus="keeping existing icon; possible duplicate or close neighbour"
                    if not ambiguous and #hits==1 and not deferred.manualRefined
                        and NS.CursorSweepTrial.ConsiderRefinement and not quick then
                        -- Re-measure from the actual positive; do not move the
                        -- existing picture or publish another one to start a job.
                        NS.CursorSweepTrial:ConsiderRefinement(deferred,ctx,spot,now)
                    end
                    return
                end
            end
            if not node then
                if #nodes >= MAX_NODES then table.remove(nodes, 1) end
                node = {id = resource.id, name = resource.name, kind = resource.kind, icon = resource.icon, anonymous=resource.anonymous==true,
                    map = ctx.map, x = spot.x, y = spot.y, uncertainty = pixel * 2, manualProvisional = true,
                    manualAnchorHitRadius = pixel * 9 * ctx.iconScale}
                nodes[#nodes + 1] = node
                manual.captures = manual.captures + 1
                manual.lastCandidate="new provisional memory"
                manual.refinementStatus="new memory; waiting for boundary crossings"
                if InCombatLockdown and InCombatLockdown() then manual.combatCaptures = manual.combatCaptures + 1 end
            end
            placementInput("accepted: observation created/renewed; resource="..tostring(resource.name).."; candidate="..tostring(manual.lastCandidate),ctx)
            node.quickScanObservation=quick or nil
            node.cursorSweepObservation = NS.CursorSweepActive and not quick or nil
            -- A hidden-name hover is a hit inside the native dot, not its centre.
            -- Use the scanner's bounded region for historical artwork lookup too.
            if (NS.CursorSweepActive or node.anonymous) and not node.manualRefined then node.uncertainty=math.max(node.uncertainty or 0,pixel*(9*ctx.iconScale+12)) end
            node.seen = now
            node.manualObservationPose = {x = ctx.x, y = ctx.y, hitRadius = pixel * 9 * ctx.iconScale}
            node.manualLastHit = {x = spot.x, y = spot.y, pixel=pixel, iconScale=ctx.iconScale}
            if settled or not node.observationTTL then node.observationTTL = settled and 300 or 60 end
            if NS.CursorSweepActive then NS:ObserveCursorSweepNodeHint(node,hit)
            else node.elevationTag = elevationTag(hit.label) end
            if not NS.CursorSweepActive then observeUnderground(node, hit.label, hit.line, resource) end
            for i = 1, math.min(32, #data.lines) do
                local difficulty = NS:GetGatheringTooltipDifficulty(data.lines[i], node.kind)
                if difficulty then node.tooltipDifficulty, node.tooltipSkillRevision = difficulty, NS:GetGatheringSkillRevision() end
            end
            if NS.CursorSweepActive and NS.CursorSweepTrial.ConsiderRefinement and not quick then
                NS.CursorSweepTrial:ConsiderRefinement(node,ctx,spot,now)
            end
            -- Original indices and saved-match safeguards, without new writes.
            if not NS.CursorSweepActive then
                manualSavedAnchor(node, spot, ctx, now, #hits == 1, settled and stableHover)
                manualImportedAnchor(node, spot, ctx, #hits == 1, settled and stableHover)
            end
        end
    end
    -- Only new captures/refinements need an extra immediate draw. Ordinary
    -- refreshes keep the shared draw cadence instead of redrawing at read rate.
    return manual.captures~=capturesBefore or manual.refinements~=refinementsBefore
end

local function canProbe()
    if lootOpen then return false end
    if InCombatLockdown and InCombatLockdown() then return false end
    -- Mapped instances use the same validated projection and busy guards.
    if UnitIsDeadOrGhost and UnitIsDeadOrGhost("player") then return false end
    if UnitOnTaxi and UnitOnTaxi("player") then return false end
    if UnitCastingInfo then
        local casting = UnitCastingInfo("player")
        if not public(casting) or casting ~= nil then return false end
    end
    if UnitChannelInfo then
        local channel = UnitChannelInfo("player")
        if not public(channel) or channel ~= nil then return false end
    end
    if not (Minimap.IsMouseOver and Minimap:IsMouseOver()) then return true end
    -- The click-through HUD covers the world cursor without receiving map
    -- input. Geometric hover alone must not starve discovery there. Keep the
    -- normal hover pause for interactive/drag-enabled maps and unknown state.
    if NS.db.hud.enabled and NS.db.hud.locked ~= false and type(Minimap.IsMouseEnabled) == "function" then
        local ok, enabled = pcall(Minimap.IsMouseEnabled, Minimap)
        if ok and public(enabled) and enabled == false then return true end
    end
    return false
end
local function placementOnUpdate(_, dt)
    saveGathered()
    local now = GetTime()
    if #collected > 0 then
        if NS.ManualNodeHoverEnabled then
            -- Walking away must not turn a lingering physical tooltip into a
            -- fresh observation. Bound this grace period so later real hovers
            -- can discover a remaining or respawned node.
            for i = #collected, 1, -1 do
                if collected[i].expires and now >= collected[i].expires then table.remove(collected,i) end
            end
        else
            local speed = GetUnitSpeed and GetUnitSpeed("player")
            if number(speed) and speed > 0 then
                for i = #collected, 1, -1 do collected[i] = nil end
                scan, validation = nil, nil
                cursors = {}
                nextScan, nextValidation = 0, 0
            end
        end
    end
    if now >= nextPrune then prune(now); nextPrune = now + 1 end
    if not scan and not validation and now < nextDraw and now < nextScan and now < nextValidation then return end
    if Minimap.IsVisible and not Minimap:IsVisible() then
        placementInput("blocked: native minimap not visible");hideIcons(); scan, validation = nil, nil; nextDraw, nextScan = now + 0.1, now + 0.2; return
    end
    local ctx = readContext()
    if not ctx then placementInput("blocked: native map context unavailable");scan, validation = nil, nil; manual.passive=nil; hideIcons(); return end
    if currentMap ~= ctx.map then clear(); manual.pending, manual.latch, manual.absence = nil, nil, nil; manual.visitedKinds,manual.returningKinds,manual.lastKind={},{},nil; currentMap = ctx.map; nextScan = 0 end
    local speed
    if NS.ManualNodeHoverEnabled then
        local ok,value=pcall(GetUnitSpeed,"player")
        if ok and number(value)then speed=value end
    else speed=GetUnitSpeed and GetUnitSpeed("player")end
    local motionTolerance = 0.1 / (ctx.width * ctx.scale / 2) * ctx.radius
    playerMoving = NS.ManualNodeHoverEnabled and not number(speed) or number(speed) and speed > 0 or lastPosition and distance(ctx, lastPosition, ctx) > motionTolerance^2 or false
    if playerMoving then lastMovement = now end
    lastPosition = {x = ctx.x, y = ctx.y}
    if now >= nextKind then
        updateActiveKind()
        nextKind = now + 0.1
    end
    if now >= nextDraw then draw(ctx, now); nextDraw = now + 0.1 end
    if NS.ManualNodeHoverEnabled then
        scan, validation = nil, nil
        local ok, err = pcall(physicalUpdate, ctx, now)
        if ok and err then draw(ctx, now) end -- Show new physical observations in this frame.
        if not ok then manual.pending, manual.absence, manual.passive = nil, nil, nil; manual.lastError = tostring(err) end
        return
    end
end

local function onUpdate(frame,dt)
    placementOnUpdate(frame,dt)
    local t=placementTrace
    if not t or not t.active then return end
    local now=GetTime()
    if now<(t.nextSnapshot or 0) then return end
    t.nextSnapshot=now+1
    placementInput('heartbeat; capture error='..tostring(manual.lastError or 'none')..'; candidate='..tostring(manual.lastCandidate)..'; detail='..tostring(manual.tooltipDetail and (manual.tooltipDetail:match('^unreadable.*') or 'available') or 'none'))
    for _,line in ipairs(NS:GetCompactNodeDiagnostic(MAX_NODES)) do NS:RecordNodePlacement('display',line) end
end

local fojjiDJ, fojjiPaused
local function updateFojji(active)
    if not active and not fojjiPaused then return end
    local dj = FojjiCoreNS and FojjiCoreNS.DJ
    if dj and dj.Nodes and type(dj.Nodes.Update) == "function" and type(dj.Option) == "function" then
        if fojjiDJ ~= dj then
            local original = dj.Option
            dj.Option = function(self, key, ...)
                if self == dj and key == "minimapNodes" and fojjiPaused then return false end
                return original(self, key, ...)
            end
            fojjiDJ, fojjiPaused = dj, nil
        end
        if fojjiPaused ~= active then fojjiPaused = active; pcall(dj.Nodes.Update) end
    end
end

-- Explicit manual lookup uses public pointer/map geometry, never tooltip text.
function NS:RememberNodeAtCursor()
    local ctx
    local function trace(detail)
        self:RecordNodePlacement('events','manual key; '..detail)
    end
    local function fail(message)
        trace('failed; '..message)
        if self.Print then self.Print(message) end
        return false
    end
    trace('pressed; tracking='..tostring(self:GetActiveGatheringTracking())
        ..'; hover candidate='..tostring(manual.lastCandidate or 'none'))
    if self.CursorSweepActive or automaticScanOwnsSession() then return fail('Turn off experimental scanning before remembering a node manually.') end
    if not self.db or not self.db.hud.rememberNodes then return fail('Enable Remember nodes first.') end
    if not Minimap.IsMouseOver or not Minimap:IsMouseOver() then return fail('Point at a node on the minimap first.') end
    ctx=readContext()
    if not ctx then return fail('Minimap position unavailable.') end
    local x,y=GetCursorPosition()
    if not (number(x) and number(y)) then return fail('Cursor position unavailable.') end
    local px,py=x/ctx.scale-ctx.left,y/ctx.scale-ctx.bottom
    trace(string.format('geometry; map=%s player=%.3f,%.3f cursor=%.1f,%.1f native=%.1fx%.1f scale=%.3f radius=%.1f',
        tostring(ctx.map),ctx.x*100,ctx.y*100,px,py,ctx.width,ctx.height,ctx.scale,ctx.radius))
    if px<0 or py<0 or px>ctx.width or py>ctx.height then return fail('Cursor outside native map.') end
    local spell=self:GetActiveGatheringTracking()
    local kind=spell==2383 and 'herb' or spell==2580 and 'ore'
    if not kind then return fail('Activate herb or ore tracking first.') end
    local east,north=(px-ctx.width/2)/(ctx.width/2)*ctx.radius,(py-ctx.height/2)/(ctx.width/2)*ctx.radius
    local pixel=2*ctx.radius/(ctx.width*ctx.scale)
    local probe={anonymous=true,kind=kind,map=ctx.map,uncertainty=pixel*(9*ctx.iconScale+12),
        x=ctx.x+(east*ctx.cos-north*ctx.sin)/ctx.w,y=ctx.y-(north*ctx.cos+east*ctx.sin)/ctx.h}
    local known,alternative,reason,anchor,types=self:GetAnonymousNodeArtwork(probe,true)
    trace(string.format('lookup; kind=%s map=%s cursor world=%.3f,%.3f; reason=%s; anchor=%s',
        kind,tostring(ctx.map),probe.x*100,probe.y*100,tostring(reason),
        anchor and string.format('%.3f,%.3f',anchor.x*100,anchor.y*100) or 'none'))
    if not known or not anchor then return fail('No usable saved node in scanner lookup range: '..tostring(reason)) end
    local now=GetTime()
    local node
    for _,old in ipairs(nodes) do
        if old.manualKeyAnchor and old.map==ctx.map and old.kind==kind and old.x==anchor.x and old.y==anchor.y then node=old;break end
    end
    if not node then
        if #nodes>=MAX_NODES then table.remove(nodes,1) end
        node={anonymous=true,id=kind=='herb' and -2383 or -2580,name='Manually remembered '..kind,kind=kind,
            map=ctx.map,x=anchor.x,y=anchor.y,uncertainty=anchor.uncertainty,manualProvisional=true,manualKeyAnchor=true}
        nodes[#nodes+1]=node
    end
    node.seen=now;node.observationTTL=300
    node.manualExpiresAt=now+300;node.manualPossibleTypes=types
    trace(string.format('added saved %s; map=%s xy=%.3f,%.3f; TTL=300s; saved-coordinate lookup only',
        kind,tostring(ctx.map),anchor.x*100,anchor.y*100))
    draw(ctx,now)
    if self.Print then self.Print('Added saved '..kind..' node at its database coordinates.') end
    return true
end

-- Explicit dismissal affects session observations only, never saved history.
function NS:DismissRememberedNodeAtCursor()
    if not self.ManualNodeHoverEnabled
        or not self.db or not self.db.hud.rememberNodes
        or not Minimap.IsMouseOver or not Minimap:IsMouseOver() then return false end
    local ctx = readContext()
    if not ctx then return false end
    local x,y = GetCursorPosition()
    if not (number(x) and number(y)) then return false end
    local px,py = x/ctx.scale-ctx.left,y/ctx.scale-ctx.bottom
    if px<0 or py<0 or px>ctx.width or py>ctx.height then return false end
    local east,north=(px-ctx.width/2)/(ctx.width/2)*ctx.radius,
        (py-ctx.height/2)/(ctx.width/2)*ctx.radius
    local spot={x=ctx.x+(east*ctx.cos-north*ctx.sin)/ctx.w,
        y=ctx.y-(north*ctx.cos+east*ctx.sin)/ctx.h}
    local pixel=2*ctx.radius/(ctx.width*ctx.scale)
    local nearest,best,second=nil,(12*ctx.iconScale*pixel)^2,math.huge
    for i,node in ipairs(nodes) do
        if node.map==ctx.map then
            local d=distance(node,spot,ctx)
            if d<best then second,nearest,best=best,i,d
            elseif d<second then second=d end
        end
    end
    if not nearest or math.sqrt(second)-math.sqrt(best)<pixel then return false end
    local node=nodes[nearest]
    if #collected>=MAX_NODES then table.remove(collected,1) end
    local observed=node.manualLastHit or node
    collected[#collected+1]={map=node.map,kind=node.kind,id=node.id,
        x=observed.x,y=observed.y,radius=math.max(12,node.uncertainty or 0),expires=GetTime()+10,explicitDismiss=true}
    table.remove(nodes,nearest)
    manual.pending,manual.latch,manual.absence,manual.passive=nil,nil,nil,nil
    draw(ctx,GetTime())
    return true
end

function NS:UpdateRememberedNodes()
    local hasSource = hasNodeSource("herb") or hasNodeSource("ore") or hasNodeSource("treasure")
    local wanted = self.db and self.db.hud.rememberNodes and hasSource and (not self.db.hud.enabled or self.HUDFrame)
    -- Remove observations whose profession/racial or inclusion was removed.
    for i = #nodes, 1, -1 do
        if not hasNodeSource(nodes[i].kind) then table.remove(nodes, i) end
    end
    local available = supported()
    if wanted and not available and not reportedUnavailable then
        reportedUnavailable = true
        self.Print(self.L.NODE_SCAN_UNAVAILABLE)
    end
    local active = wanted and available and true or false
    if self.UpdateHUDMouseInteraction then self:UpdateHUDMouseInteraction()end
    updateFojji(active)
    if active then
        updateActiveKind()
        if not createOverlay() then return end
        self.NodeOverlay:Show()
        if driver:GetScript("OnUpdate") ~= onUpdate then
            nextScan, nextDraw, nextKind, nextPrune = 0, 0, 0, 0
            scan, validation, activeKind, activeTreasure = nil, nil, nil, nil
            validationCursor, nextValidation = 0, 0
            driver:SetScript("OnUpdate", onUpdate)
            driver:Show()
        end
    else
        driver:SetScript("OnUpdate", nil)
        driver:Hide()
        scan, validation = nil, nil
        hideIcons()
        if self.NodeOverlay then self.NodeOverlay:Hide() end
        if overlays.dualHUD then overlays.dualHUD.layer:Hide() end
        -- Native hover temporarily restores the normal Remember nodes setting.
        -- Keep live observations for the explicitly enabled minimap session;
        -- their original timestamps, expiry and zone cleanup still apply.
        local minimap=self.ExperimentalMinimap
        local handoff=minimap and minimap.armed and (minimap.hovering or self.MinimapScanActive)
        if self.db and not self.db.hud.rememberNodes and not handoff then clear() end
    end
end

for _, event in ipairs({ "MINIMAP_UPDATE_TRACKING", "PLAYER_ENTERING_WORLD", "ZONE_CHANGED_NEW_AREA", "SKILL_LINES_CHANGED", "SPELLS_CHANGED",
    "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED", "UNIT_SPELLCAST_SUCCEEDED", "GET_ITEM_INFO_RECEIVED", "ADDON_LOADED", "LOOT_OPENED", "LOOT_CLOSED", "LOOT_SLOT_CLEARED", "UNIT_SPELLCAST_SENT", "UNIT_SPELLCAST_FAILED", "UNIT_SPELLCAST_INTERRUPTED" }) do
    driver:RegisterEvent(event)
end
driver:SetScript("OnEvent", function(_, event, unit, targetOrCast, spellID, sentSpellID)
    -- First world entry follows both login and /reload. Later loading screens
    -- must not reset retained history or restart a stopped recording.
    if event=="PLAYER_ENTERING_WORLD" and not placementAutoStarted then
        placementAutoStarted=true
        if not placementTrace then
            NS:NodePlacementTraceCommand('start 5')
            NS:RecordNodePlacement('events','automatic recording started on login/reload')
        end
    end
    if event=="UNIT_SPELLCAST_SUCCEEDED" and unit=="player" and number(spellID) then
        manual.lastSuccessSpell=spellID
    end
    if event=="UNIT_SPELLCAST_SENT" and unit=="player" then
        chestOpening=nil;chestLoot=nil;gatherTarget=nil
        manual.gatherTargetEvidence='unavailable cast target'
        if public(targetOrCast) and type(targetOrCast)=='string' then
            manual.gatherTargetEvidence=targetOrCast=='' and 'empty cast target' or 'unrecognized cast target'
        end
        -- A successful matching cast can distinguish nearby herb identities;
        -- the gather spell alone only identifies the gathering profession.
        if public(targetOrCast) and type(targetOrCast)=='string'
            and public(spellID) and type(spellID)=='string' and number(sentSpellID) then
            local kind=gatheringSpellKind(sentSpellID)
            local target=kind and resourceFor(targetOrCast,kind)
            local c=target and readContext()
            if target and c then
                gatherTarget={id=target.id,name=target.name,kind=kind,map=c.map,cast=spellID,at=GetTime()}
                manual.gatherTargetEvidence='recognized cast target'
            end
        end
        local resource=public(targetOrCast) and type(targetOrCast)=="string" and resourceFor(targetOrCast,"treasure")
        local ctx=resource and readContext()
        if resource and ctx then chestOpening={id=resource.id,map=ctx.map,x=ctx.x,y=ctx.y,at=GetTime()} end
    elseif (event=="UNIT_SPELLCAST_FAILED" or event=="UNIT_SPELLCAST_INTERRUPTED") and unit=="player" then
        chestOpening=nil;chestLoot=nil;gatherTarget=nil
    elseif event=="LOOT_SLOT_CLEARED" then clearChestLootSlot(unit)
    elseif event == "SKILL_LINES_CHANGED" or event == "SPELLS_CHANGED" then
        if NS.InvalidateGatheringSkills then NS:InvalidateGatheringSkills() end
        scan, validation, activeKind, activeTreasure = nil, nil, nil, nil
        cursors = {}
        nextKind, nextScan = 0, 0
        NS:UpdateRememberedNodes()
    elseif event == "MINIMAP_UPDATE_TRACKING" then
        manual.pending, manual.latch, manual.absence = nil, nil, nil
        -- Completed node-local chords may combine within their existing 30s
        -- window after a tracker returns. Never connect an unfinished crossing
        -- or positive continuity across a tracking change.
        if manual.passive then
            manual.passive.previous,manual.passive.trace,manual.passive.continuousNode=nil,nil,nil
        end
        updateActiveKind()
        if manual.lastKind ~= activeKind then
            manual.returningKinds[activeKind or "none"] = activeKind and manual.visitedKinds[activeKind] or false
            if activeKind then manual.visitedKinds[activeKind] = true end
            manual.lastKind = activeKind
        end
        scan, validation = nil, nil
        nextKind, nextScan, nextValidation = 0, 0, 0
    elseif event == "PLAYER_REGEN_DISABLED" then scan, validation = nil, nil
    elseif event == "PLAYER_REGEN_ENABLED" then nextScan = 0; NS:UpdateRememberedNodes()
    elseif event == "PLAYER_ENTERING_WORLD" or event == "ZONE_CHANGED_NEW_AREA" then
        clear(); hideIcons(); currentMap = nil; lootOpen = false
        if NS.InvalidateGatheringSkills then NS:InvalidateGatheringSkills() end
        NS:UpdateRememberedNodes()
    elseif event == "LOOT_OPENED" then lootOpen = true; scan, validation = nil, nil;resetGatherClearance();beginChestLoot()
    elseif event == "LOOT_CLOSED" then lootOpen = false; nextScan = 0;chestOpening=nil;chestLoot=nil
    elseif event == "GET_ITEM_INFO_RECEIVED" then names, nameCount = {}, 0
    elseif event == "ADDON_LOADED" and unit == "FojjiCore_DungeonJournal" then NS:UpdateRememberedNodes()
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" and NS.db and NS.db.hud.rememberNodes and unit == "player" and number(spellID)
        and gatheringSpellKind(spellID) then
        local report={spellID=spellID,outcome="checking",at=GetTime(),memoryCount=#nodes,sameKindCount=0}
        manual.lastGather=report
        scan, validation = nil, nil
        cursors = {}
        nextScan = GetTime() + 0.5
        local ctx = readContext()
        if not ctx then report.outcome="no readable map context";return end
        local kind = gatheringSpellKind(spellID)
        if not NS:HasGatheringProfession(kind) then report.outcome="profession unavailable";return end
        local target=gatherTarget;gatherTarget=nil
        local targetID=target and target.kind==kind and target.map==ctx.map and public(targetOrCast)
            and target.cast==targetOrCast and GetTime()-target.at<=15 and target.id or nil
        report.targetID=targetID;report.targetName=targetID and target.name or nil
        report.targetEvidence=targetID and 'matched cast target' or target and 'cast target failed identity/map/age guard'
            or manual.gatherTargetEvidence or 'no cast target event' 
        local function matchesGather(node)
            if not targetID or node.id==targetID then return true end
            -- Historical options are incomplete (e.g. Truesilver at a saved
            -- Iron/Silver/Gold spawn). A manual-key icon is only a location
            -- hypothesis; a successful nearby gather of its kind clears it.
            if node.manualKeyAnchor and not node.cursorSweepObservation then return true end
            -- Manual database artwork lists possible identities, not a known
            -- live species. A successful matching cast clears the whole icon.
            if node.anonymous then
                if NS:FarmHUDOpen() and not next(node.manualPossibleTypes or {}) then return true end
                for _,entry in ipairs(node.manualPossibleTypes or {})do
                    if entry.id==targetID then return true end
                end
            end
            return false
        end
        local nearest, best, second = nil, 12^2, 12^2
        for i, node in ipairs(nodes) do
            if node.map == ctx.map and node.kind == kind and matchesGather(node) then
                report.sameKindCount=report.sameKindCount+1
                local d = distance(node.importedAnchor and node.manualLastHit or node, ctx, ctx)
                if node.manualLastHit then d=math.min(d,distance(node.manualLastHit,ctx,ctx)) end
                local yards=math.sqrt(d)
                report.nearestDistance=math.min(report.nearestDistance or yards,yards)
                if d < best then second, nearest, best = best, i, d
                elseif d < second then second = d end
            end
        end
        if nearest and nodes[nearest].anonymous and NS:FarmHUDOpen() and math.sqrt(second)-math.sqrt(best)<=1 then
            nearest=nil
            report.ambiguousRough=true
        end
        local roughRadius
        if not nearest and NS.ManualNodeHoverEnabled then
            -- The real mouse can hit the edge of a native dot: its rough
            -- anchor and last hit may both lie outside the gathering range.
            -- Use the bounded observed hit-area allowance only for one unique
            -- provisional candidate; competing memories defer removal.
            local candidate, allowance, ambiguous
            for i,node in ipairs(nodes) do
                local hit=node.manualLastHit
                if node.map==ctx.map and node.kind==kind and matchesGather(node) and node.manualProvisional
                    and hit and number(hit.pixel) and number(hit.iconScale)
                    and GetTime()-node.seen<=NS:GetGatheringObservationTTL(node) then
                    local radius=math.min(40,12+hit.pixel*9*hit.iconScale)
                    if distance(hit,ctx,ctx)<=radius^2 then
                        if candidate then ambiguous=true end
                        candidate,allowance=i,radius
                    end
                end
            end
            if candidate and not ambiguous then
                for i,other in ipairs(nodes) do
                    if i~=candidate and other.map==ctx.map and other.kind==kind and matchesGather(other)
                        and math.min(distance(other,ctx,ctx),distance(other.manualLastHit or other,ctx,ctx))<=allowance^2 then
                        ambiguous=true
                    end
                end
            end
            if candidate and not ambiguous then
                nearest,roughRadius=candidate,allowance
                best=distance(nodes[candidate].manualLastHit,ctx,ctx)
                second=math.huge
            elseif ambiguous then report.ambiguousRough=true end
        end
        report.outcome=report.ambiguousRough and "ambiguous rough observations" or "no matching observation within 12 yd"
        -- A matched public cast target establishes species independently of
        -- anonymous dots or historical artwork. With no unique measured node,
        -- the player's successful-gather position is only a 12-yard estimate.
        local confirmedGatherSaved=false
        if targetID then
            local candidate=nearest and nodes[nearest]
            local measured=candidate and not candidate.anonymous and candidate.id==targetID
                and (candidate.manualRefined or candidate.centered)
                and math.sqrt(second)-math.sqrt(best)>1
                and number(candidate.uncertainty) and candidate.uncertainty<=12
            local snapshot
            if measured then
                snapshot={}
                for key,value in pairs(candidate) do snapshot[key]=value end
                snapshot.cursorSweepObservation=nil
            else
                snapshot={id=targetID,kind=kind,name=target.name,map=ctx.map,
                    x=ctx.x,y=ctx.y,uncertainty=12,gatheredApproximate=true}
            end
            pendingGathered[#pendingGathered+1]={node=snapshot,ctx=ctx}
            confirmedGatherSaved=true
            report.savedPosition=measured and "measured node" or "approximate gathering position"
            saveGathered()
        end
        if nearest then
            local node, now = nodes[nearest], GetTime()
            -- A successful gather identifies a nearby resource type, not which of
            -- two equally close observations supplied it. Do not persist ties.
            if not confirmedGatherSaved and not NS.CursorSweepActive and math.sqrt(second) - math.sqrt(best) > 1 then
                local snapshot = {}
                for key, value in pairs(node) do snapshot[key] = value end
                if node.importedAnchor and node.manualLastHit then
                    snapshot.x,snapshot.y = node.manualLastHit.x,node.manualLastHit.y
                    snapshot.uncertainty = node.manualLastHit.pixel*2
                end
                if roughRadius then snapshot.uncertainty=math.max(snapshot.uncertainty or 0,roughRadius-12) end
                pendingGathered[#pendingGathered + 1] = {node = snapshot, ctx = ctx}
            end
            if #collected >= MAX_NODES then table.remove(collected, 1) end
            local observed = NS.CursorSweepActive and node.manualRefined and node or node.manualLastHit or node
            collected[#collected + 1] = { map = node.map, kind = node.kind, id = node.id,
                x = observed.x, y = observed.y, radius = math.max(12, node.uncertainty or 0, roughRadius or 0),
                expires = NS.CursorSweepActive and now+300 or NS.ManualNodeHoverEnabled and now+10 or nil,
                requiresEmpty = NS.CursorSweepActive and true or nil }
            if NS.CursorSweepActive and NS.CursorSweepTrial.AbortRefinement then
                local job=NS.CursorSweepTrial.refinement or NS.CursorSweepTrial.refinePending
                if job and job.node==node then NS.CursorSweepTrial:AbortRefinement('target gathered') end
            end
            table.remove(nodes, nearest)
            local queue=NS.CursorSweepActive and NS.CursorSweepTrial and NS.CursorSweepTrial.refinementQueue
            if queue then
                for i=#queue,1,-1 do if queue[i].node==node then table.remove(queue,i) end end
            end
            report.outcome,report.name="removed",node.name
            draw(ctx, now)
            saveGathered()
        end
    end
end)

NS.NodeMemoryModuleSourceReady=true
