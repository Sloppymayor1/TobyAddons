local ADDON_NAME, FRNS_ = ...; local NS = FRNS_.Gathering

-- Profession information is refreshed after skill/equipment events, never per
-- icon or per frame. Tooltip colors take precedence over Classic estimates.
local skills, dirty, revision = {}, true, 0
local professionIDs = { herb = 182, ore = 186 }
local professionSpells = { herb = 2366, ore = 2575 }
local localizedNames = {}
local availableProfessions = {}
local professionNames = {
    herb = { "Herbalism", "Kräuterkunde", "Herboristería", "Herboristerie", "약초 채집", "약초채집" },
    ore = { "Mining", "Bergbau", "Minería", "Minage", "채광" },
}
local minimums = {
    [2447] = 1, [2449] = 15, [765] = 1, [785] = 50, [2450] = 70, [2453] = 100,
    [3355] = 115, [3356] = 125, [3357] = 150, [3358] = 185, [3369] = 120,
    [3818] = 160, [3819] = 195, [3820] = 85, [3821] = 170, [4625] = 205,
    [8831] = 210, [8836] = 220, [8838] = 230, [8839] = 235, [8845] = 245,
    [8846] = 250, [13463] = 270, [13464] = 260, [13465] = 280,
    [13466] = 285, [13467] = 290, [13468] = 300,
    [2770] = 1, [2771] = 65, [2775] = 75, [2772] = 125, [2776] = 155,
    [3858] = 175, [7911] = 230, [11370] = 230, [10620] = 245,
}
NS.GatheringDifficultyColors = {
    red = { 1, 0.12, 0.12 }, orange = { 1, 0.5, 0.1 },
    yellow = { 1, 1, 0.1 }, green = { 0.25, 1, 0.25 },
}

local function public(value) return not (issecretvalue and issecretvalue(value)) end
local function number(value)
    return public(value) and type(value) == "number" and value == value and math.abs(value) < math.huge
end
local function safe(fn, ...)
    if type(fn) ~= "function" then return false end
    return pcall(fn, ...)
end
local function plain(text)
    return text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("%s*%b()", "")
        :match("^%s*(.-)%s*$"):lower()
end
local function professionKind(name, id)
    if number(id) then
        for kind, skillID in pairs(professionIDs) do if id == skillID then return kind end end
    end
    if not public(name) or type(name) ~= "string" then return end
    name = plain(name)
    if localizedNames[name] then return localizedNames[name] end
    for kind, aliases in pairs(professionNames) do
        for _, alias in ipairs(aliases) do if name == alias:lower() then return kind end end
    end
end
local function record(kind, rank, maxRank, modifier)
    if not kind or not number(rank) or rank < 0 then return end
    skills[kind] = { rank = rank, maxRank = number(maxRank) and maxRank or 300,
        modifier = number(modifier) and modifier or 0 }
end
local function readInfo(info, kind)
    if not public(info) or type(info) ~= "table" then return end
    record(kind or professionKind(info.name or info.skillName, info.skillID or info.skillLineID),
        info.rank or info.skillRank, info.maxRank or info.skillMaxRank, info.modifier or info.skillModifier)
end
local function refresh()
    if not dirty then return end
    dirty = false
    skills = {}
    revision = revision + 1
    localizedNames = {}
    for kind, spell in pairs(professionSpells) do
        local ok, info = safe(C_Spell and C_Spell.GetSpellInfo or GetSpellInfo, spell)
        if ok and public(info) then
            local label = type(info) == "table" and info.name or info
            if public(label) and type(label) == "string" then localizedNames[label:lower()] = kind end
        end
    end
    local api = C_SkillInfo
    if api and api.GetSkillLineInfoByID then
        for kind, id in pairs(professionIDs) do
            local ok, info = safe(api.GetSkillLineInfoByID, id)
            if ok then
                if info == nil then record(kind, 0, 300, 0) else readInfo(info, kind) end
            end
        end
    end
    local ok, p1, p2 = safe(GetProfessions)
    if ok and GetProfessionInfo then
        local complete = true
        for _, index in pairs({ p1, p2 }) do
            if number(index) then
                local success, name, _, rank, maxRank, _, _, id, modifier = safe(GetProfessionInfo, index)
                if success and public(name) and number(rank) then
                    local kind = professionKind(name, id)
                    if not skills[kind] then record(kind, rank, maxRank, modifier) end
                else complete = false end
            elseif not public(index) then complete = false end
        end
        if complete then
            for kind in pairs(professionIDs) do if not skills[kind] then record(kind, 0, 300, 0) end end
        end
    end
    if not skills.herb or not skills.ore then
        local reader = api and api.GetSkillLineInfo or GetSkillLineInfo
        local success, count = safe(api and api.GetNumSkillLines or GetNumSkillLines)
        if success and number(count) and count >= 0 and reader then
            local complete = count <= 500
            for index = 1, math.min(count, 500) do
                local valid, name, header, expanded, rank, _, modifier, maxRank = safe(reader, index)
                if valid and public(name) and public(header) then
                    if type(name) == "table" then
                        readInfo(name)
                        if not public(name.rank or name.skillRank)
                            or (public(name.isHeader) and name.isHeader
                                and (not public(name.isExpanded) or name.isExpanded ~= true)) then complete = false end
                    elseif header then
                        -- Collapsed categories omit their professions from this list.
                        if not public(expanded) or expanded ~= true then complete = false end
                    else
                        record(professionKind(name), rank, maxRank, modifier)
                        if not number(rank) then complete = false end
                    end
                else complete = false end
            end
            if complete then
                for kind in pairs(professionIDs) do if not skills[kind] then record(kind, 0, 300, 0) end end
            end
        end
    end
    availableProfessions = {}
    local reader = IsPlayerSpell or IsSpellKnown
    for kind, spell in pairs(professionSpells) do
        local skill = skills[kind]
        if skill then
            availableProfessions[kind] = skill.rank > 0
        else
            -- Custom clients may expose tracking spells but no profession API.
            local tracker = kind == "herb" and 2383 or 2580
            local ok, known = safe(reader, spell)
            local trackingOK, trackingKnown = safe(reader, tracker)
            availableProfessions[kind] = (ok and public(known) and known == true)
                or (trackingOK and public(trackingKnown) and trackingKnown == true) or false
        end
    end
end

function NS:HasGatheringProfession(kind)
    refresh()
    return availableProfessions[kind] == true
end

function NS:InvalidateGatheringSkills()
    dirty = true
end
function NS:GetGatheringSkillRevision()
    refresh()
    return revision
end

-- The tooltip's profession line carries the client difficulty color. Ignore
-- resource-title colors: titles can be yellow even when gathering is blocked.
function NS:GetGatheringTooltipDifficulty(line, kind)
    refresh()
    if not public(line) or type(line) ~= "table" or not public(line.leftText)
        or type(line.leftText) ~= "string" or professionKind(line.leftText) ~= kind then return end
    local r, g, b
    local color = line.leftColor
    if public(color) and type(color) == "table" then
        r, g, b = color.r, color.g, color.b
        if not (number(r) and number(g) and number(b)) and color.GetRGB then
            local ok
            ok, r, g, b = safe(color.GetRGB, color)
            if not ok then r, g, b = nil, nil, nil end
        end
    end
    if not (number(r) and number(g) and number(b)) then
        local red, green, blue = line.leftText:match("|c%x%x(%x%x)(%x%x)(%x%x)")
        if red then
            r, g, b = tonumber(red, 16) / 255, tonumber(green, 16) / 255, tonumber(blue, 16) / 255
        end
    end
    if not (number(r) and number(g) and number(b)) then return end
    if r > 0.8 and g < 0.3 and b < 0.3 then return "red" end
    if r > 0.8 and g > 0.8 and b < 0.3 then return "yellow" end
    if r > 0.8 and g >= 0.3 and g <= 0.8 and b < 0.5 then return "orange" end
    if g > 0.5 and r < 0.5 and b < 0.5 then return "green" end
    if math.max(r, g, b) - math.min(r, g, b) < 0.1 and r < 0.85 then return "grey" end
end

function NS:GetGatheringNodeDifficulty(node)
    refresh()
    local skill = skills[node.kind]
    local observed = node.tooltipSkillRevision == revision and node.tooltipDifficulty or nil
    if observed == "red" then return "red" end
    if skill and skill.rank == 0 then return "red" end
    local minimum = minimums[node.id]
    if node.id == 10620 and type(node.name) == "string" then
        local label = node.name:lower()
        for _, rich in ipairs({ "rich", "reiche", "rico", "riche", "풍부한" }) do
            if label:find(rich, 1, true) then minimum = 275; break end
        end
    end
    local effective = skill and skill.rank + skill.modifier
    if minimum and effective and effective < minimum then return "red" end
    if skill and (skill.rank >= 300 or (skill.maxRank > 0 and skill.rank >= skill.maxRank)) then return end
    if observed then return observed ~= "grey" and observed or nil end
    if not minimum or not effective then return end
    local yellow, green, grey = minimum + 25, minimum + 50, minimum + 100
    if node.id == 2770 then yellow, green, grey = 25, 50, 100 end
    if effective >= grey then return end
    if effective >= green then return "green" end
    if effective >= yellow then return "yellow" end
    return "orange"
end

local events = CreateFrame("Frame")
for _, event in ipairs({ "SKILL_LINES_CHANGED", "PLAYER_ENTERING_WORLD", "PLAYER_EQUIPMENT_CHANGED",
    "UNIT_AURA", "SPELLS_CHANGED" }) do events:RegisterEvent(event) end
events:SetScript("OnEvent", function(_, event, unit)
    if event ~= "UNIT_AURA" or unit == "player" then NS:InvalidateGatheringSkills() end
end)
