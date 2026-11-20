local _, FRNS_ = ...; local NS = FRNS_.Gathering

-- Exact observed/database labels -> stable resource identity -> Blizzard item artwork.
-- No substring inference, interaction, events, scanning or saved-variable writes.
local resources = {
    {2447, "peacebloom", "herb"}, {2449, "earthroot", "herb"}, {765, "silverleaf", "herb"},
    {785, "mageroyal", "herb"}, {2450, "briarthorn", "herb"}, {2453, "bruiseweed", "herb"},
    {3355, "wild steelbloom", "herb"}, {3356, "kingsblood", "herb"}, {3357, "liferoot", "herb"},
    {3358, "khadgar's whisker", "herb"}, {3369, "grave moss", "herb"}, {3818, "fadeleaf", "herb"},
    {3819, "wintersbite", "herb"}, {3820, "stranglekelp", "herb"}, {3821, "goldthorn", "herb"},
    {4625, "firebloom", "herb"}, {8831, "purple lotus", "herb"}, {8836, "arthas' tears", "herb"},
    {8838, "sungrass", "herb"}, {8839, "blindweed", "herb"}, {8845, "ghost mushroom", "herb"},
    {8846, "gromsblood", "herb"}, {13463, "dreamfoil", "herb"}, {13464, "golden sansam", "herb"},
    {13465, "mountain silversage", "herb"}, {13466, "plaguebloom", "herb"},
    {13467, "icecap", "herb"}, {13468, "black lotus", "herb"},
    {11370, "dark iron", "ore"}, {7911, "truesilver", "ore"}, {3858, "mithril", "ore"},
    {10620, "thorium", "ore"}, {2770, "copper", "ore"}, {2775, "silver", "ore"},
    {2771, "tin", "ore"}, {2772, "iron", "ore"}, {2776, "gold", "ore"},
}
local chestNames = {}
-- Exact Classic container names, not substring matches on arbitrary map labels.
-- English fallback only; translated labels live in guarded locale files.
for _, name in ipairs({
    "Battered Chest",
    "Buccaneer's Strongbox",
    "Burial Chest",
    "Dark Iron Treasure Chest",
    "Large Battered Chest",
    "Large Darkwood Chest",
    "Large Iron Bound Chest",
    "Large Mithril Bound Chest",
    "Large Solid Chest",
    "Solid Chest",
    "Tattered Chest",
    "Treasure Chest",
    "Arena Treasure Chest",
    "Traveler's Cache",
    "Ornamented Chest",
    "A Small Pack",
    "Waterlogged Footlocker",
    "Rusty Chest",
    "Mithril Bound Trunk",
    "Sturdy Locked Chest",
    "Reinforced Locked Chest",
    "Ironbound Locked Chest",
    "Heavy Locked Chest",
    "Primitive Chest",
}) do chestNames[name:lower()] = true end

-- Exact client-observed Forever variants. Reuse the related herb's artwork,
-- while keeping a distinct node identity and relying on live difficulty data.
local herbVariants = {
    ["wilted peacebloom"] = 2447,
    ["stunted silverleaf"] = 765,
}

local byName, byID = {herb = {}, ore = {}, treasure = {}}, {}
local defaults = {herb = "Interface\\Icons\\INV_Misc_Herb_07",
    ore = "Interface\\Icons\\INV_Ore_Copper_01", treasure = "Interface\\Icons\\INV_Misc_TreasureChest01"}
local function key(name)
    if type(name) ~= "string" or (issecretvalue and issecretvalue(name)) then return end
    return name:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
        :gsub("|T.-|t", ""):gsub("|A.-|a", ""):gsub("\226\128\153", "'")
        :gsub("%s*%b()", ""):match("^%s*(.-)%s*$"):lower()
end
local function add(kind, name, item, id)
    local entry = {kind = kind, name = name, item = item, id = id or item}
    byName[kind][key(name)] = entry
    byID[kind .. ":" .. tostring(entry.id)] = byID[kind .. ":" .. tostring(entry.id)] or entry
    return entry
end
for _, row in ipairs(resources) do
    if row[3] == "herb" then add("herb", row[2], row[1]) end
end
for name, item in pairs(herbVariants) do add("herb", name, item, "herb:" .. name) end
local oreNodes = {
    {2770, "Copper Vein", "Poor Copper Vein"},
    {2771, "Tin Vein"}, {2775, "Silver Vein", "Ooze Covered Silver Vein"},
    {2772, "Iron Deposit", "Ooze Covered Iron Deposit"},
    {2776, "Gold Vein", "Ooze Covered Gold Vein"},
    {3858, "Mithril Deposit", "Ooze Covered Mithril Deposit"},
    {7911, "Truesilver Deposit", "Ooze Covered Truesilver Deposit"},
    {11370, "Dark Iron Deposit"},
    {10620, "Thorium Vein", "Small Thorium Vein", "Rich Thorium Vein",
        "Ooze Covered Thorium Vein", "Ooze Covered Rich Thorium Vein"},
    {248815, "Heavy Thorium Vein"}, {3340, "Incendicite Mineral Vein"},
    {4278, "Lesser Bloodstone Deposit"}, {5833, "Indurium Mineral Vein"},
}
for _, row in ipairs(oreNodes) do
    for i = 2, #row do add("ore", row[i], row[1]) end
end
add("ore", "Chunk of Amber", 2770, "ore:chunk of amber")
add("ore", "Large Chunk of Amber", 2770, "ore:large chunk of amber")
for name in pairs(chestNames) do add("treasure", name, nil, "treasure:" .. key(name)) end
function NS:LookupNodeResource(name, kind)
    local normalized = key(name)
    if not normalized or not byName[kind] then return end
    if byName[kind][normalized] then return byName[kind][normalized] end
    -- Item metadata may arrive after login. Do not negatively cache unknown names.
    local reader = C_Item and C_Item.GetItemInfo or GetItemInfo
    if reader and kind ~= "treasure" then
        for _, row in ipairs(resources) do
            if row[3] == kind then
                local ok, localized = pcall(reader, row[1])
                if ok and key(localized) == normalized then return add(kind, localized, row[1]) end
            end
        end
    end
end
function NS:GetNodeResourceByID(id, kind)
    local entry = byID[kind .. ":" .. tostring(id)]
    if entry then return entry end
    if kind == "treasure" and type(id) == "string" and id:sub(1, 9) == "treasure:" then
        return {id = id, kind = kind, name = id:sub(10)}
    end
    if type(id) == "string" then
        return self:LookupNodeResource(id:gsub("^herb:", ""):gsub("^ore:", ""):gsub("^treasure:", ""), kind)
    end
end
function NS:GetNodeResourceIcon(entry, kind)
    local reader = C_Item and C_Item.GetItemIconByID or GetItemIcon
    if entry and entry.item and reader then
        local ok, icon = pcall(reader, entry.item)
        if ok and not (issecretvalue and issecretvalue(icon))
            and (type(icon) == "number" or type(icon) == "string") then return icon end
    end
    if kind == "treasure" and C_Spell and C_Spell.GetSpellTexture then
        local ok, icon = pcall(C_Spell.GetSpellTexture, 2481)
        if ok and not (issecretvalue and issecretvalue(icon))
            and (type(icon) == "number" or type(icon) == "string") then return icon end
    end
    return defaults[kind]
end

-- Locale packs register aliases to an existing canonical entry; they cannot invent resources.
local displayNames = {}
function NS:RegisterNodeLocale(locale, rows)
    displayNames[locale] = displayNames[locale] or {}
    for kind, entries in pairs(rows) do
        assert(byName[kind], "Unknown node category")
        for canonical, aliases in pairs(entries) do
            local entry = assert(byName[kind][key(canonical)], "Unknown canonical node: " .. canonical)
            assert(type(aliases) == "table" and #aliases > 0, "Missing aliases")
            for _, alias in ipairs(aliases) do
                local normalized = assert(key(alias), "Invalid alias")
                assert(normalized ~= "", "Empty node alias")
                local existing = byName[kind][normalized]
                assert(not existing or (existing.item == entry.item), "Conflicting node alias: " .. alias)
                byName[kind][normalized] = entry
            end
            local id = kind .. ":" .. tostring(entry.id)
            local primary = byID[id]
            if not displayNames[locale][id] or (primary and key(primary.name) == key(canonical))
                or canonical == "Small Thorium Vein" then
                displayNames[locale][id] = aliases[1]
            end
        end
    end
end
function NS:GetNodeResourceDisplayName(entry)
    if not entry then return end
    local locale = "enUS"
    if type(GetLocale) == "function" then
        local ok, value = pcall(GetLocale)
        if ok and type(value) == "string" and not (issecretvalue and issecretvalue(value)) then locale = value end
    end
    local translations = displayNames[locale]
    return translations and translations[entry.kind .. ":" .. tostring(entry.id)] or entry.name
end
