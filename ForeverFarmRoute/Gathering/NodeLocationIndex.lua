local _, FRNS_ = ...; local NS = FRNS_.Gathering

-- Only the current zone is indexed by the scanner. Buckets hold references to
-- existing rows, so coordinates and resource records are never copied.
local CELLS = 64
local Index = {}
Index.__index = Index
local function valid(row)
    return type(row) == "table" and type(row.x) == "number" and type(row.y) == "number"
        and row.x >= 0 and row.x <= 1 and row.y >= 0 and row.y <= 1
end
local function cell(value)
    return math.max(0, math.min(CELLS - 1, math.floor(value * CELLS)))
end
local function key(x, y) return y * CELLS + x end

function NS:NewNodeLocationIndex(rows)
    return setmetatable({rows = rows, cells = {}, built = 0}, Index)
end
function Index:Add(row)
    if not valid(row) then return end
    local id = key(cell(row.x), cell(row.y))
    local bucket = self.cells[id]
    if not bucket then bucket = {}; self.cells[id] = bucket end
    bucket[#bucket + 1] = row
end
function Index:Build(limit)
    if self.built > #self.rows then self.cells, self.built = {}, 0 end
    local last = math.min(#self.rows, self.built + limit)
    for i = self.built + 1, last do self:Add(self.rows[i]) end
    self.built = last
    return self.built == #self.rows
end
function Index:Ready() return self.built == #self.rows end
function Index:Append(row)
    -- The caller has already appended to the persistent array.
    if self.built == #self.rows - 1 then self:Add(row); self.built = self.built + 1 end
end
function Index:Move(row, oldX, oldY)
    if key(cell(row.x), cell(row.y)) == key(cell(oldX), cell(oldY)) then return end
    local bucket = self.cells[key(cell(oldX), cell(oldY))]
    for i, candidate in ipairs(bucket or {}) do
        if candidate == row then table.remove(bucket, i); self:Add(row); return end
    end
end
function Index:Bounds(x, y, rx, ry)
    return cell(x - rx), cell(x + rx), cell(y - ry), cell(y + ry)
end
function Index:Query(x, y, rx, ry)
    local x1, x2, y1, y2 = self:Bounds(x, y, rx, ry)
    return {index = self, x1 = x1, x2 = x2, y1 = y1, y2 = y2, x = x1, y = y1, offset = 0}
end
function Index:Next(query)
    -- Empty cells are cheap to skip, but keep the work bounded for large views.
    for _ = 1, 32 do
        if query.y > query.y2 then return nil, true end
        local bucket = self.cells[key(query.x, query.y)]
        query.offset = query.offset + 1
        local row = bucket and bucket[query.offset]
        if row then return row, false end
        query.offset, query.x = 0, query.x + 1
        if query.x > query.x2 then query.x, query.y = query.x1, query.y + 1 end
    end
    return nil, query.y > query.y2
end

-- Record only map classification, using the client hierarchy when available.
function NS:GetNodeLocationMapGroup(map)
    if not (C_Map and C_Map.GetMapInfo) then return end
    local mapTypes = Enum and Enum.UIMapType
    local function public(value) return not (issecretvalue and issecretvalue(value)) end
    for _ = 1, 12 do
        if map == 1414 then return "Kalimdor" end
        if map == 1415 then return "EasternKingdoms" end
        local ok, info = pcall(C_Map.GetMapInfo, map)
        if not ok or not public(info) or type(info) ~= "table" or not public(info.mapType) then return end
        if mapTypes and mapTypes.Dungeon and info.mapType == mapTypes.Dungeon then return "Dungeons" end
        local parent = info.parentMapID
        if not public(parent) or type(parent) ~= "number" or parent <= 0 or parent == map then return end
        map = parent
    end
end
