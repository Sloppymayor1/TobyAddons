-- Auctionator Shuffle: shows profit for buying inputs on the AH, crafting them,
-- and selling the outputs after the auction house cut. Prices come from our own
-- depth scans, falling back to Auctionator.
-- Two tabs in Auctionator's auction house window:
--   Shuffles - user profiles of simple conversions (ore -> bar, ...). /shuffle
--   Crafts   - every profession craft (CraftData.lua), split into Consumable and Equipment. /shuffle crafts

local ADDON, ns = ...
ADDON = ADDON or "AuctionatorShuffle"
ns = ns or {}
local AH_CUT = 0.05

-- Default profiles. Each recipe: inputs/outputs are { {itemID, quantity}, ... }.
local DEFAULT_SECTIONS = {
  {
    name = "Mining",
    recipes = {
      { inputs = { { 2770, 1 } }, outputs = { { 2840, 1 } } },             -- Copper Ore -> Copper Bar
      { inputs = { { 2771, 1 } }, outputs = { { 3576, 1 } } },             -- Tin Ore -> Tin Bar
      { inputs = { { 2840, 1 }, { 3576, 1 } }, outputs = { { 2841, 2 } } }, -- Copper + Tin Bar -> 2 Bronze Bar
      { inputs = { { 2775, 1 } }, outputs = { { 2842, 1 } } },             -- Silver Ore -> Silver Bar
      { inputs = { { 2772, 1 } }, outputs = { { 3575, 1 } } },             -- Iron Ore -> Iron Bar
      { inputs = { { 3575, 1 }, { 3857, 1 } }, outputs = { { 3859, 1 } } }, -- Iron Bar + Coal -> Steel Bar
      { inputs = { { 2776, 1 } }, outputs = { { 3577, 1 } } },             -- Gold Ore -> Gold Bar
      { inputs = { { 3858, 1 } }, outputs = { { 3860, 1 } } },             -- Mithril Ore -> Mithril Bar
      { inputs = { { 7911, 1 } }, outputs = { { 6037, 1 } } },             -- Truesilver Ore -> Truesilver Bar
      { inputs = { { 10620, 1 } }, outputs = { { 12359, 1 } } },           -- Thorium Ore -> Thorium Bar
      { inputs = { { 11370, 8 } }, outputs = { { 11371, 1 } } },           -- 8 Dark Iron Ore -> Dark Iron Bar
    },
  },
  {
    -- Processing skinned leather and hides (Leatherworking combines and cures, per Wowhead's Forever list).
    name = "Skinning",
    recipes = {
      { inputs = { { 2934, 3 } }, outputs = { { 2318, 1 } } },              -- 3 Ruined Leather Scraps -> Light Leather
      { inputs = { { 2318, 4 } }, outputs = { { 2319, 1 } } },              -- 4 Light Leather -> Medium Leather
      { inputs = { { 2319, 5 } }, outputs = { { 4234, 1 } } },              -- 5 Medium Leather -> Heavy Leather
      { inputs = { { 4234, 6 } }, outputs = { { 4304, 1 } } },              -- 6 Heavy Leather -> Thick Leather
      { inputs = { { 4304, 6 } }, outputs = { { 8170, 1 } } },              -- 6 Thick Leather -> Rugged Leather
      { inputs = { { 783, 1 }, { 4289, 1 } }, outputs = { { 4231, 1 } } },  -- Light Hide + Salt -> Cured Light Hide
      { inputs = { { 4232, 1 }, { 4289, 1 } }, outputs = { { 4233, 1 } } }, -- Medium Hide + Salt -> Cured Medium Hide
      { inputs = { { 4235, 1 }, { 4289, 3 } }, outputs = { { 4236, 1 } } }, -- Heavy Hide + 3 Salt -> Cured Heavy Hide
      { inputs = { { 8169, 1 }, { 8150, 1 } }, outputs = { { 8172, 1 } } }, -- Thick Hide + Deeprock Salt -> Cured Thick Hide
      { inputs = { { 8171, 1 }, { 15409, 1 } }, outputs = { { 15407, 2 } } }, -- Rugged Hide + Refined Deeprock Salt -> 2 Cured Rugged Hide
    },
  },
}

local CATEGORIES = { "Consumable", "Equipment" }

local function CopyTable(t)
  local copy = {}
  for k, v in pairs(t) do copy[k] = type(v) == "table" and CopyTable(v) or v end
  return copy
end

local function Print(msg)
  DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99Shuffle:|r " .. msg)
end

local function FindSection(name)
  for i, section in ipairs(AuctionatorShuffleDB.sections) do
    if section.name:lower() == name:lower() then return section, i end
  end
end

local function SelectedSection()
  return FindSection(AuctionatorShuffleDB.selected or "") or AuctionatorShuffleDB.sections[1]
end

-- WoW Forever uses the modern auction house (AuctionHouseFrame); older clients use AuctionFrame.
local function AuctionHouseOpen()
  return (AuctionHouseFrame and AuctionHouseFrame:IsShown()) or (AuctionFrame and AuctionFrame:IsShown()) or false
end

-- The global GetItemInfo is gone on modern clients; C_Item replaces it.
local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
local GetItemIcon = (C_Item and C_Item.GetItemIconByID) or GetItemIcon
local GetItemInfoInstant = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant

local RefreshAll, UpdatePanels -- defined with the views below
local DepthPrice, SaveDepth -- defined in "Depth scanning"; the Snipe full scan uses them too
local refreshQueued = false
local function QueueRefresh()
  if refreshQueued then return end
  refreshQueued = true
  C_Timer.After(0.3, function() refreshQueued = false; RefreshAll() end)
end

-- Weapons (class 2) and armor (class 4) are "Equipment"; everything else is "Consumable".
local equipCache = {}
local function IsEquipment(itemID)
  local cached = equipCache[itemID]
  if cached ~= nil then return cached end
  local classID = select(6, GetItemInfoInstant(itemID))
  if classID == nil then return false end
  equipCache[itemID] = classID == 2 or classID == 4
  return equipCache[itemID]
end

---------------------------------------------------------------------------
-- Prices and maths
---------------------------------------------------------------------------

-- Our own scan (see "Depth scanning") prices stackable items at the DEPTH_QTY-th cheapest
-- unit, so a handful of cheap stragglers don't count. Gear sells one piece at a time, so it
-- is priced at the EQUIP_RANK_FRACTION point of its listings (never below the 3rd cheapest)
-- and capped at EQUIP_SPIKE_CAP x its recent median, which ignores outliers at both ends.
-- Items not scanned yet use Auctionator's lowest price.
local DEPTH_QTY = 50
local EQUIP_MIN_RANK = 3
local EQUIP_RANK_FRACTION = 0.2
local EQUIP_SPIKE_CAP = 1.25
local HISTORY_KEEP_DAYS = 14
local VENDOR = ns.VENDOR_PRICES or {}

local function Today() return math.floor(time() / 86400) end

local function GetDepth(itemID)
  return AuctionatorShuffleDB.depth and AuctionatorShuffleDB.depth[itemID]
end

-- Returns price, source ("vendor", "depth" or "auctionator").
local function GetPrice(itemID)
  local depth = GetDepth(itemID)
  local price
  if depth then
    price = depth.price -- nil when the last scan found none listed
  else
    price = Auctionator.API.v1.GetAuctionPriceByItemID(ADDON, itemID)
  end
  local vendor = VENDOR[itemID]
  if vendor and (not price or vendor < price) then return vendor, "vendor" end
  return price, price and (depth and "depth" or "auctionator") or nil
end

local function GetAge(itemID)
  local depth = GetDepth(itemID)
  if depth then return math.floor((time() - depth.time) / 86400) end
  return Auctionator.API.v1.GetAuctionAgeByItemID(ADDON, itemID)
end

-- Sum price * quantity. Returns total (nil if any price is missing) and the oldest data age in days.
local function SumSide(side)
  local total, oldest = 0, 0
  for _, entry in ipairs(side) do
    local price, source = GetPrice(entry[1])
    if not price then return nil, nil end
    total = total + price * entry[2]
    if source ~= "vendor" then oldest = math.max(oldest, GetAge(entry[1]) or 99) end
  end
  return total, oldest
end

-- Stability rules for the recommendations.
local STABLE_MIN_VOLUME = 1000 -- Shuffles: at least this many of every item listed
local STABLE_MAX_SWING = 0.25  -- price may vary at most 25% over the history window
local HISTORY_DAYS = 7
local MIN_LISTINGS = 10        -- Crafts: the made item needs this many listed to show/recommend
local EQUIP_MIN_SOLD = 2       -- Crafts: gear needs this many seen selling in HISTORY_DAYS to recommend

-- Latest listed quantity and price swing (fraction) over the last HISTORY_DAYS days.
-- Uses our depth-scan history when the item has been scanned, else Auctionator's history.
local function ItemStats(itemID)
  local depth = GetDepth(itemID)
  local history = AuctionatorShuffleDB.history and AuctionatorShuffleDB.history[itemID]
  if depth and history then
    local lo, hi = math.huge, 0
    for day, range in pairs(history) do
      if day > Today() - HISTORY_DAYS then
        lo = math.min(lo, range[1])
        hi = math.max(hi, range[2])
      end
    end
    if lo > 0 and lo < math.huge then return depth.listed, (hi - lo) / lo end
  end

  local db = Auctionator.Database
  if not (db and db.GetPriceHistory) then return nil, nil end
  local auctionatorHistory = db:GetPriceHistory(tostring(itemID)) -- newest day first
  if #auctionatorHistory == 0 then return nil, nil end
  local lo, hi = math.huge, 0
  for i = 1, math.min(HISTORY_DAYS, #auctionatorHistory) do
    local day = auctionatorHistory[i]
    if day.minSeen then lo = math.min(lo, day.minSeen) end
    if day.maxSeen then hi = math.max(hi, day.maxSeen) end
  end
  local swing = (lo > 0 and lo < math.huge) and (hi - lo) / lo or nil
  return auctionatorHistory[1].available, swing
end

-- Cost, revenue after the AH cut, profit and margin. result.cost is nil when a price is missing.
local function EvaluatePrices(recipe)
  local result = { recipe = recipe }
  local cost, ageIn = SumSide(recipe.inputs)
  local gross, ageOut = SumSide(recipe.outputs)
  if cost and gross then
    result.cost = cost
    result.gross = gross
    result.revenue = math.floor(gross * (1 - AH_CUT))
    result.profit = result.revenue - cost
    result.margin = cost > 0 and (result.profit / cost * 100) or 0
    result.age = math.max(ageIn, ageOut)
  end
  return result
end

-- Shuffles: the thinnest-listed and most volatile item of the recipe decide stability.
local function EvaluateShuffle(recipe)
  local result = EvaluatePrices(recipe)
  if not result.cost then return result end
  local volume, swing, known = math.huge, 0, true
  for _, side in ipairs({ recipe.inputs, recipe.outputs }) do
    for _, entry in ipairs(side) do
      local available, itemSwing = ItemStats(entry[1])
      if available == nil or itemSwing == nil then
        known = false
      else
        volume = math.min(volume, available)
        swing = math.max(swing, itemSwing)
      end
    end
  end
  if known then
    result.volume = volume
    result.swing = swing
    result.stable = volume >= STABLE_MIN_VOLUME and swing <= STABLE_MAX_SWING
  end
  return result
end

---------------------------------------------------------------------------
-- Sales tracking (gear). Each gear auction has its own ID and a time-left band.
-- An auction that vanishes between two scans long before it could have expired
-- was bought (or cancelled by its seller), so it counts as a sale.
---------------------------------------------------------------------------

local TIME_LEFT_MIN_SECONDS = { [0] = 0, [1] = 1800, [2] = 7200, [3] = 43200 } -- Short, Medium, Long, Very long

local function RecordSales(itemID, current)
  local db = AuctionatorShuffleDB
  db.sales = db.sales or {}
  local sales = db.sales[itemID] or { days = {} }
  db.sales[itemID] = sales
  local now = time()
  if sales.snap then
    local elapsed = now - sales.snapTime
    local sold = 0
    for auctionID, band in pairs(sales.snap) do
      if not current[auctionID] and elapsed < (TIME_LEFT_MIN_SECONDS[band] or 0) then sold = sold + 1 end
    end
    local today = Today()
    if sold > 0 then sales.days[today] = (sales.days[today] or 0) + sold end
    sales.tracked = true
    for day in pairs(sales.days) do
      if day <= today - HISTORY_KEEP_DAYS then sales.days[day] = nil end
    end
  end
  sales.snap = current
  sales.snapTime = now
end

-- Auctions seen selling over HISTORY_DAYS, or nil until two scans have been compared.
local function SoldCount(itemID)
  local sales = AuctionatorShuffleDB.sales and AuctionatorShuffleDB.sales[itemID]
  if not (sales and sales.tracked) then return nil end
  local total = 0
  for day, count in pairs(sales.days) do
    if day > Today() - HISTORY_DAYS then total = total + count end
  end
  return total
end

---------------------------------------------------------------------------
-- Known recipes (per character), read whenever a profession window is open.
---------------------------------------------------------------------------

local function CharacterKey()
  return (UnitName("player") or "?") .. "-" .. (GetRealmName() or "?")
end

local function KnownData()
  local db = AuctionatorShuffleDB
  db.known = db.known or {}
  local key = CharacterKey()
  db.known[key] = db.known[key] or { spells = {}, items = {}, names = {} }
  db.known[key].names = db.known[key].names or {}
  return db.known[key]
end

local function HasKnownData()
  local known = KnownData()
  return next(known.spells) ~= nil or next(known.items) ~= nil or next(known.names) ~= nil
end

local GetSpellName = (C_Spell and C_Spell.GetSpellName) or function(id) return (GetSpellInfo(id)) end

-- Known if the game says this character has the recipe spell, or the profession
-- window listed it (by spell, made item, or recipe name).
local function IsKnown(recipe)
  if IsPlayerSpell and IsPlayerSpell(recipe.spell) then return true end
  local known = KnownData()
  if known.spells[recipe.spell] or known.items[recipe.outputs[1][1]] then return true end
  if next(known.names) then
    local name = GetSpellName(recipe.spell) or GetItemInfo(recipe.outputs[1][1])
    if name and known.names[name] then return true end
  end
  return false
end

-- Recipes are only ever added, so a filtered profession window never forgets any.
local function ReadTradeSkillUnsafe()
  local known = KnownData()
  local added = 0
  local function AddSpell(id) if id and not known.spells[id] then known.spells[id] = true; added = added + 1 end end
  local function AddItem(id) if id and not known.items[id] then known.items[id] = true; added = added + 1 end end
  local function AddName(name) if name and not known.names[name] then known.names[name] = true; added = added + 1 end end

  if C_TradeSkillUI and C_TradeSkillUI.GetAllRecipeIDs then
    for _, recipeID in ipairs(C_TradeSkillUI.GetAllRecipeIDs() or {}) do
      local info = C_TradeSkillUI.GetRecipeInfo(recipeID)
      if info and info.learned then
        AddSpell(recipeID)
        AddName(info.name)
      end
    end
  end
  if GetNumTradeSkills and GetTradeSkillInfo then
    for i = 1, GetNumTradeSkills() or 0 do
      local name, kind = GetTradeSkillInfo(i)
      if kind and kind ~= "header" and kind ~= "subheader" then
        AddName(name)
        local recipeLink = GetTradeSkillRecipeLink and GetTradeSkillRecipeLink(i)
        AddSpell(recipeLink and tonumber(recipeLink:match("enchant:(%d+)")))
        local itemLink = GetTradeSkillItemLink and GetTradeSkillItemLink(i)
        AddItem(itemLink and tonumber(itemLink:match("item:(%d+)")))
      end
    end
  end
  if added > 0 then QueueRefresh() end
end

local function ReadTradeSkill()
  local ok, err = pcall(ReadTradeSkillUnsafe)
  if not ok then Print("|cffff4040couldn't read known recipes:|r " .. tostring(err)) end
end

---------------------------------------------------------------------------
-- Crafts
---------------------------------------------------------------------------

-- Built once from CraftData.lua: [profession] = { recipe, ... }
local craftRecipes, professions = {}, {}
for profession, rows in pairs(ns.CRAFT_DATA or {}) do
  local list = {}
  for _, row in ipairs(rows) do
    local inputs = {}
    for i = 1, #row[5], 2 do table.insert(inputs, { row[5][i], row[5][i + 1] }) end
    table.insert(list, { spell = row[1], outputs = { { row[2], row[3] } }, skill = row[4], inputs = inputs })
  end
  craftRecipes[profession] = list
  table.insert(professions, profession)
end
table.sort(professions)

-- Plans that teach crafts (PlanData.lua): by spell ID, or by recipe name when the ID is unknown.
local planBySpell, planByName = {}, {}
for _, rows in pairs(ns.PLAN_DATA or {}) do
  for _, row in ipairs(rows) do
    local plan = { item = row[1], name = row[3], sources = row[4], drops = row[5], vendors = row[6], quests = row[7], objects = row[8] }
    if row[2] and row[2] > 0 then planBySpell[row[2]] = plan end
    planByName[row[3]:lower()] = planByName[row[3]:lower()] or plan
  end
end

local planCache = {}
local function PlanFor(recipe)
  local cached = planCache[recipe.spell]
  if cached ~= nil then return cached or nil end
  local plan = planBySpell[recipe.spell]
  if not plan then
    local name = GetSpellName(recipe.spell)
    plan = name and planByName[name:lower()]
    if not plan then
      local itemName = GetItemInfo(recipe.outputs[1][1])
      if not (name or itemName) then return nil end -- names still loading; try again later
      plan = itemName and planByName[itemName:lower()]
    end
  end
  planCache[recipe.spell] = plan or false
  return plan
end

local function CraftState()
  local db = AuctionatorShuffleDB
  db.craft = db.craft or {}
  local state = db.craft
  if not craftRecipes[state.profession or ""] then state.profession = craftRecipes.Blacksmithing and "Blacksmithing" or professions[1] end
  state.category = state.category or "Consumable"
  db.blocked = db.blocked or {}
  return state
end

local function CraftCategory(recipe)
  return IsEquipment(recipe.outputs[1][1]) and "Equipment" or "Consumable"
end

local function IsBlocked(recipe)
  return AuctionatorShuffleDB.blocked and AuctionatorShuffleDB.blocked[recipe.spell] or false
end

local function EvaluateCraft(recipe)
  local result = EvaluatePrices(recipe)
  local itemID = recipe.outputs[1][1]
  local depth = GetDepth(itemID)
  result.listed = depth and depth.listed
  result.equipment = IsEquipment(itemID)
  result.sold = result.equipment and SoldCount(itemID) or nil
  result.blocked = IsBlocked(recipe)
  if result.cost and result.listed then
    local _, swing = ItemStats(itemID)
    result.swing = swing or 0
    result.stable = not result.blocked and result.listed >= MIN_LISTINGS and result.swing <= STABLE_MAX_SWING and
      (not result.equipment or (result.sold or 0) >= EQUIP_MIN_SOLD)
  end
  return result
end

-- Recipes in the selected profession and category that pass the Show Known / blocked filters.
local function CraftCandidates()
  local state = CraftState()
  local list, counts = {}, { total = 0, unknown = 0, blocked = 0 }
  for _, recipe in ipairs(craftRecipes[state.profession] or {}) do
    if CraftCategory(recipe) == state.category then
      counts.total = counts.total + 1
      if IsBlocked(recipe) and not state.showBlocked then
        counts.blocked = counts.blocked + 1
      elseif state.showKnown and not IsKnown(recipe) then
        counts.unknown = counts.unknown + 1
      else
        table.insert(list, recipe)
      end
    end
  end
  return list, counts
end

-- Results to show, after the listing filter.
local function CraftResults()
  local state = CraftState()
  local candidates, counts = CraftCandidates()
  counts.unscanned, counts.low = 0, 0
  local results = {}
  for _, recipe in ipairs(candidates) do
    local result = EvaluateCraft(recipe)
    if state.lowListings or (result.listed or 0) >= MIN_LISTINGS then
      table.insert(results, result)
    elseif result.listed == nil then
      counts.unscanned = counts.unscanned + 1
    else
      counts.low = counts.low + 1
    end
  end
  return results, counts
end

---------------------------------------------------------------------------
-- Vendor shuffles: buy mats on the AH, craft, sell the made item to a vendor.
---------------------------------------------------------------------------

local vendorItemsPending = false
local VENDOR_MIN_CRAFTS = 5 -- each AH-bought mat needs enough listed for this many crafts to recommend

-- Selected vendor or disenchant shuffle ("vendor:Blacksmithing" / "disenchant:Blacksmithing"
-- in the profile picker). Returns profession, kind ("vendor" or "disenchant"), or nil.
local function VendorProfession()
  local selected = AuctionatorShuffleDB and AuctionatorShuffleDB.selected
  if not selected then return nil end
  local kind, profession = selected:match("^(%a+):(.+)$")
  if (kind == "vendor" or kind == "disenchant") and craftRecipes[profession] then return profession, kind end
  return nil
end

-- Disenchanting, by the item's REQUIRED level, from the WoW Forever table at
-- https://www.wow-professions.com/forever/disenchanting-guide#disenchanting-table avg = average count
-- of the "min-max" range. Uncommon gear gives dust, essence or a shard; rare gives a shard;
-- epic gives Nexus Crystals at 51+.
local DISENCHANT_SPELL = 13262
local DISENCHANT_TIERS = {
  { maxLevel = 10, dust = { 10940, 1.5 }, essence = { 10938, 1.5 } },
  { maxLevel = 15, dust = { 10940, 2.5 }, essence = { 10939, 1.5 }, shard = 10978 },
  { maxLevel = 20, dust = { 10940, 5 },   essence = { 10998, 1.5 }, shard = 10978 },
  { maxLevel = 25, dust = { 11083, 1.5 }, essence = { 11082, 1.5 }, shard = 11084 },
  { maxLevel = 30, dust = { 11083, 3.5 }, essence = { 11134, 1.5 }, shard = 11138 },
  { maxLevel = 35, dust = { 11137, 1.5 }, essence = { 11135, 1.5 }, shard = 11139 },
  { maxLevel = 40, dust = { 11137, 3.5 }, essence = { 11174, 1.5 }, shard = 11177 },
  { maxLevel = 45, dust = { 11176, 1.5 }, essence = { 11175, 1.5 }, shard = 11178 },
  { maxLevel = 50, dust = { 11176, 3.5 }, essence = { 16202, 1.5 }, shard = 14343 },
  { maxLevel = 55, dust = { 16204, 1.5 }, essence = { 16203, 1.5 }, shard = 14344 },
  { maxLevel = 60, dust = { 16204, 3.5 }, essence = { 16203, 2 },   shard = 14344 },
}
local NEXUS_CRYSTAL = 20725
local DISENCHANT_MATS = { 10940, 11083, 11137, 11176, 16204, 10938, 10939, 10998, 11082, 11134, 11135, 11174, 11175,
  16202, 16203, 10978, 11084, 11138, 11139, 11177, 11178, 14343, 14344, NEXUS_CRYSTAL }

-- Possible results of disenchanting an item: { {itemID, chance, averageCount}, ... },
-- or nil plus a reason when it can't be worked out (yet).
-- Green gear the game refuses to disenchant ("That item is not a valid target"):
-- the enchanter-made Magic wands.
local NO_DISENCHANT = { [11287] = true, [11288] = true } -- Lesser / Greater Magic Wand

local function DisenchantOutcomes(itemID)
  if NO_DISENCHANT[itemID] then return nil, "can't be disenchanted" end
  local _, _, quality, _, minLevel = GetItemInfo(itemID) -- 5th return: required level
  if quality == nil then return nil, "loading" end
  local classID = select(6, GetItemInfoInstant(itemID))
  if not (classID == 2 or classID == 4) or quality < 2 then return nil, "can't be disenchanted" end
  minLevel = math.max(1, minLevel or 1)
  local tier = DISENCHANT_TIERS[#DISENCHANT_TIERS]
  for _, t in ipairs(DISENCHANT_TIERS) do
    if minLevel <= t.maxLevel then tier = t break end
  end
  if quality >= 4 then
    -- Epics up to item level 60 give 1 Nexus Crystal about 80% of the time and 2-4 Large
    -- Brilliant Shards otherwise (Wowhead Forever: Lifestone 22 of 28, Myrmidon's Signet
    -- 6 of 9); above item level 60, 1-2 Nexus Crystals (1.5 on average).
    if minLevel >= 51 then
      local itemLevel = select(4, GetItemInfo(itemID)) or 0
      if itemLevel > 60 then return { { NEXUS_CRYSTAL, 1, 1.5 } } end
      return { { NEXUS_CRYSTAL, 0.8, 1 }, { 14344, 0.2, 3 } }
    end
    return tier.shard and { { tier.shard, 1, 1 } } or nil, "no shard at this level"
  elseif quality == 3 then
    return tier.shard and { { tier.shard, 1, 1 } } or nil, "no shard at this level"
  end
  -- Uncommon: armor mostly gives dust, weapons mostly essence; 5% shard (when the tier has one).
  local weapon = classID == 2
  local shardChance = tier.shard and 0.05 or 0
  local dustChance = (weapon and 0.20 or 0.75) + (weapon and 0 or shardChance == 0 and 0.05 or 0)
  local essenceChance = 1 - dustChance - shardChance
  local outcomes = { { tier.dust[1], dustChance, tier.dust[2] }, { tier.essence[1], essenceChance, tier.essence[2] } }
  if tier.shard then table.insert(outcomes, { tier.shard, shardChance, 1 }) end
  return outcomes
end

-- What a disenchant result really sells for: you have to undercut the cheapest listing,
-- so it is the lower of the depth price and the cheapest listing (never the 50-deep price,
-- and never the priciest listing of a thin market).
local function SellPrice(itemID)
  local depth = GetDepth(itemID)
  if depth then
    if not depth.price then return nil end
    return math.min(depth.price, depth.lowest or depth.price)
  end
  return Auctionator.API.v1.GetAuctionPriceByItemID(ADDON, itemID)
end

-- Expected auction value (after the 5% cut) of disenchanting one item, or nil.
-- A result with no auction price counts as worth nothing, which keeps the value on the
-- safe side instead of hiding the item: higher-level shards and Nexus Crystals are often
-- missing from the AH. Second return: true when some result had no price.
-- Only when the likely results (over half the chance) are all unpriced is there no value.
local function DisenchantValue(outcomes)
  local total, missingChance = 0, 0
  for _, outcome in ipairs(outcomes) do
    local price = SellPrice(outcome[1])
    if price then
      total = total + outcome[2] * outcome[3] * price
    else
      missingChance = missingChance + outcome[2]
    end
  end
  if missingChance > 0.5 then return nil, true end
  return math.floor(total * (1 - AH_CUT)), missingChance > 0
end

local function VendorState()
  local db = AuctionatorShuffleDB
  db.vendor = db.vendor or {}
  db.blocked = db.blocked or {}
  return db.vendor
end

-- Seconds per craft from the recipe spell's cast time, or nil if the game doesn't say.
local function CraftSeconds(spellID)
  local castTime
  if C_Spell and C_Spell.GetSpellInfo then
    local info = C_Spell.GetSpellInfo(spellID)
    castTime = info and info.castTime
  elseif GetSpellInfo then
    castTime = select(4, GetSpellInfo(spellID))
  end
  return castTime and castTime > 0 and castTime / 1000 or nil
end

-- Seconds per craft of a Shuffles profile recipe: its own spell if it has one, else the
-- smelting spell or the Crafts-tab recipe that makes its first output. nil if unknown.
local SMELT_SPELLS = {
  [2840] = 2657, [3576] = 3304, [2841] = 2659, [2842] = 2658, [3575] = 3307, [3859] = 3569,
  [3577] = 3308, [3860] = 10097, [6037] = 10098, [12359] = 16153, [11371] = 14891,
}
local craftSpellByOutput
local function ShuffleSeconds(recipe)
  if type(recipe.spell) == "number" then return CraftSeconds(recipe.spell) end
  if not craftSpellByOutput then
    craftSpellByOutput = {}
    for _, list in pairs(craftRecipes) do
      for _, craft in ipairs(list) do
        local output = craft.outputs[1][1]
        craftSpellByOutput[output] = craftSpellByOutput[output] or craft.spell
      end
    end
  end
  local output = recipe.outputs[1] and recipe.outputs[1][1]
  local spell = output and (SMELT_SPELLS[output] or craftSpellByOutput[output])
  return spell and CraftSeconds(spell)
end

local function EvaluateVendor(recipe, kind)
  local result = { recipe = recipe, blocked = IsBlocked(recipe), kind = kind }
  local output = recipe.outputs[1]
  local sellEach = select(11, GetItemInfo(output[1]))
  if sellEach == nil and C_Item and C_Item.RequestLoadItemDataByID then
    C_Item.RequestLoadItemDataByID(output[1]) -- GET_ITEM_INFO_RECEIVED refreshes the table when it arrives
    vendorItemsPending = true
  end
  result.castTime = CraftSeconds(recipe.spell)
  if kind == "disenchant" then
    local outcomes, reason = DisenchantOutcomes(output[1])
    if reason == "loading" then vendorItemsPending = true end
    result.deOutcomes, result.deReason = outcomes, reason
    local each = outcomes and DisenchantValue(outcomes)
    result.vendor = each and each * output[2]
    -- Each made item also takes one Disenchant cast.
    local deSeconds = CraftSeconds(DISENCHANT_SPELL)
    if result.castTime and deSeconds then result.castTime = result.castTime + deSeconds * output[2] end
  else
    result.vendor = sellEach and sellEach * output[2]
  end
  local cost, age = SumSide(recipe.inputs)
  if cost and result.vendor then
    result.cost = cost
    result.profit = result.vendor - cost
    result.margin = cost > 0 and (result.profit / cost * 100) or 0
    result.age = age
    if result.castTime then result.perHour = math.floor(result.profit * 3600 / result.castTime) end
    -- Recommendable when every AH-bought mat was scanned with enough listed to keep crafting.
    local buyable = true
    for _, entry in ipairs(recipe.inputs) do
      if not VENDOR[entry[1]] then
        local depth = GetDepth(entry[1])
        if not (depth and depth.price and depth.listed >= entry[2] * VENDOR_MIN_CRAFTS) then buyable = false end
      end
    end
    result.buyable = buyable
    result.stable = buyable and not result.blocked and result.vendor > 0
  end
  return result
end

-- Recipes of a profession that pass the Show Known / blocked filters. Disenchant
-- shuffles only use gear of uncommon quality or better (unknown quality is kept until it loads).
local function VendorCandidates(profession, kind)
  local state = VendorState()
  local list, counts = {}, { total = 0, unknown = 0, blocked = 0 }
  for _, recipe in ipairs(craftRecipes[profession] or {}) do
    local output = recipe.outputs[1][1]
    local quality = select(3, GetItemInfo(output))
    local usable = kind ~= "disenchant" or (IsEquipment(output) and (quality == nil or quality >= 2))
    if usable then counts.total = counts.total + 1 end
    if not usable then
      -- not something you can disenchant
    elseif IsBlocked(recipe) and not state.showBlocked then
      counts.blocked = counts.blocked + 1
    elseif state.showKnown and not IsKnown(recipe) then
      counts.unknown = counts.unknown + 1
    else
      table.insert(list, recipe)
    end
  end
  return list, counts
end

---------------------------------------------------------------------------
-- Snipes: after an Auctionator full scan, find auctions selling for less than
-- their vendor price or their expected disenchant value.
---------------------------------------------------------------------------

local SNIPE_BATCH = 500 -- auctions checked per frame while reading a full scan
local snipeProcessing = nil -- { done, total } while a full scan is being read

local function SnipeState()
  local db = AuctionatorShuffleDB
  db.snipe = db.snipe or { showDisenchant = true, showVendor = true }
  db.blocked = db.blocked or {}
  return db.snipe
end

-- Vendor price each, safe disenchant value each (or nil), disenchant outcomes.
-- Disenchant results are random and mat prices move while you sell, so snipes count an
-- item as worth DE_SAFETY less than its expected value (already after the AH cut).
local DE_SAFETY = 0.01
local DE_SECONDS = 3.5 -- one disenchant, loot included, for the snipe Per Hour column
local function SnipeValues(itemID)
  local vendorEach = select(11, GetItemInfo(itemID)) or 0
  local outcomes = DisenchantOutcomes(itemID)
  local disenchantEach = outcomes and DisenchantValue(outcomes)
  if disenchantEach then disenchantEach = math.floor(disenchantEach * (1 - DE_SAFETY)) end
  return vendorEach, disenchantEach, outcomes
end

-- Reads Auctionator's full scan results (each: replicateInfo = GetReplicateItemInfo returns)
-- and keeps every auction priced under what the item is worth to a vendor or as enchanting mats.
local function ProcessFullScan(scanData)
  if type(scanData) ~= "table" or not AuctionatorShuffleDB then return end

  -- First, price every enchanting material straight from this scan's listings (the same
  -- outlier-proof depth price as "Scan mats"), so all gear is valued with fresh prices.
  local isMat, matListings = {}, {}
  for _, itemID in ipairs(DISENCHANT_MATS) do isMat[itemID] = true end
  for i = 1, #scanData do
    local info = scanData[i] and scanData[i].replicateInfo
    local count, buyout, itemID = info and info[3], info and info[10], info and info[17]
    if itemID and isMat[itemID] and count and count > 0 and buyout and buyout > 0 then
      matListings[itemID] = matListings[itemID] or {}
      table.insert(matListings[itemID], { math.floor(buyout / count), count })
    end
  end
  local matsPriced = 0
  for itemID, entries in pairs(matListings) do
    SaveDepth(itemID, DepthPrice(itemID, entries, 0))
    matsPriced = matsPriced + 1
  end

  local items, worth = {}, {}
  local pending = {} -- [itemID] = auctions of items whose details hadn't loaded yet
  local stats = { gear = {}, unvalued = {}, bands = {} }
  local index = 1
  snipeProcessing = { done = 0, total = #scanData }

  -- Worth of one item, or nil while its details are still loading.
  local function Worth(itemID)
    if worth[itemID] ~= nil then return worth[itemID] end
    if GetItemInfo(itemID) == nil then return nil end
    local vendorEach, disenchantEach, outcomes = SnipeValues(itemID)
    if outcomes and not stats.gear[itemID] then
      stats.gear[itemID] = true
      local minLevel = select(5, GetItemInfo(itemID)) or 1
      local band = math.min(6, math.floor((math.max(1, minLevel) - 1) / 10) + 1)
      stats.bands[band] = (stats.bands[band] or 0) + 1
      if not disenchantEach then stats.unvalued[itemID] = true end
    end
    worth[itemID] = math.max(vendorEach, disenchantEach or 0)
    return worth[itemID]
  end

  local function Keep(itemID, unit, count)
    items[itemID] = items[itemID] or { auctions = {} }
    table.insert(items[itemID].auctions, { unit, count })
  end

  local function Finish()
    snipeProcessing = nil
    local stillLoading = 0
    for itemID, auctions in pairs(pending) do
      local itemWorth = Worth(itemID)
      if itemWorth then
        for _, auction in ipairs(auctions) do
          if auction[1] < itemWorth then Keep(itemID, auction[1], auction[2]) end
        end
      else
        stillLoading = stillLoading + 1
      end
    end
    local found, gearCount, unvaluedCount = 0, 0, 0
    for _ in pairs(items) do found = found + 1 end
    for _ in pairs(stats.gear) do gearCount = gearCount + 1 end
    for _ in pairs(stats.unvalued) do unvaluedCount = unvaluedCount + 1 end
    AuctionatorShuffleDB.snipes = { time = time(), items = items, scanned = #scanData }
    Print(string.format("Snipe: checked %s auctions, %d items selling under their vendor or disenchant value.",
      BreakUpLargeNumbers and BreakUpLargeNumbers(#scanData) or #scanData, found))
    local bandText = {}
    for band = 1, 6 do
      table.insert(bandText, string.format("%s: %d", band == 6 and "51+" or ((band - 1) * 10 + 1 .. "-" .. band * 10),
        stats.bands[band] or 0))
    end
    Print(string.format("Snipe: priced %d of %d enchanting materials from this scan (the rest weren't listed; their last known price is kept).",
      matsPriced, #DISENCHANT_MATS))
    Print(string.format("Snipe: %d different green/blue/epic gear items listed, by required level - %s.",
      gearCount, table.concat(bandText, ", ")))
    if unvaluedCount > 0 then
      Print(string.format("Snipe: %d of them have no disenchant value because their dust/essence has no auction price yet. Scan mats on a disenchant shuffle to price them.",
        unvaluedCount))
    end
    if stillLoading > 0 then
      Print(string.format("Snipe: %d items still had no details from the game and were skipped this scan.", stillLoading))
    end
    RefreshAll()
  end

  local ticker
  ticker = C_Timer.NewTicker(0, function()
    for i = index, math.min(index + SNIPE_BATCH - 1, #scanData) do
      local info = scanData[i] and scanData[i].replicateInfo
      local count, buyout, itemID = info and info[3], info and info[10], info and info[17]
      if itemID and count and count > 0 and buyout and buyout > 0 then
        local unit = math.floor(buyout / count)
        local itemWorth = Worth(itemID)
        if itemWorth == nil then
          -- Details not loaded yet: ask the game and check this auction once they arrive.
          if not pending[itemID] then
            pending[itemID] = {}
            if C_Item and C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(itemID) end
          end
          table.insert(pending[itemID], { unit, count })
        elseif unit < itemWorth then
          Keep(itemID, unit, count)
        end
      end
    end
    index = index + SNIPE_BATCH
    snipeProcessing.done = math.min(index - 1, #scanData)
    if index > #scanData then
      ticker:Cancel()
      if next(pending) then
        C_Timer.After(3, Finish) -- give the game a moment to send the missing item details
      else
        Finish()
      end
    end
  end)
end

if Auctionator.FullScan and Auctionator.FullScan.Events and Auctionator.FullScan.Events.ScanComplete then
  Auctionator.EventBus:Register({
    ReceiveEvent = function(_, eventName, scanData)
      if eventName == Auctionator.FullScan.Events.ScanComplete then ProcessFullScan(scanData) end
    end,
  }, { Auctionator.FullScan.Events.ScanComplete })
end

local function StartFullScan()
  if not AuctionHouseOpen() then
    Print("Open the auction house to run a full scan.")
    return
  end
  local frame = Auctionator.State and Auctionator.State.FullScanFrameRef
  if not (frame and frame.InitiateScan) then
    Print("Auctionator's full scan isn't available on this auction house.")
    return
  end
  frame:InitiateScan() -- Auctionator prints the wait time if it ran in the last 15 minutes
end

-- One row per item: the better of vendoring or disenchanting, with how many units are
-- listed below that value and the total profit from buying them all.
local function SnipeResults()
  local state = SnipeState()
  local snipes = AuctionatorShuffleDB.snipes
  local results, counts = {}, { blocked = 0 }
  if not snipes then return results, counts end
  for itemID, data in pairs(snipes.items) do
    local vendorEach, disenchantEach, outcomes = SnipeValues(itemID)
    local best
    for method, each in pairs({ Vendor = state.showVendor and vendorEach or 0,
                                Disenchant = state.showDisenchant and disenchantEach or 0 }) do
      if each and each > 0 then
        local atProfit, total, lowest = 0, 0, nil
        for _, auction in ipairs(data.auctions) do
          if auction[1] < each then
            atProfit = atProfit + auction[2]
            total = total + (each - auction[1]) * auction[2]
            lowest = math.min(lowest or auction[1], auction[1])
          end
        end
        if atProfit > 0 and (not best or total > best.profit) then
          best = { method = method, value = each, lowest = lowest, atProfit = atProfit, profit = total }
        end
      end
    end
    if best then
      local recipe = { inputs = {}, outputs = { { itemID, 1 } }, spell = "snipe:" .. itemID }
      best.recipe = recipe
      best.itemID = itemID
      best.auctions = data.auctions
      best.outcomes = outcomes
      best.vendorEach, best.disenchantEach = vendorEach, disenchantEach
      best.cost = best.lowest
      best.profitEach = best.value - best.lowest
      best.margin = best.lowest > 0 and (best.profitEach / best.lowest * 100) or 0
      -- Profit per hour of disenchanting them all (average profit per item, one DE each).
      if best.method == "Disenchant" then
        best.perHour = math.floor(best.profit / best.atProfit * 3600 / DE_SECONDS)
      end
      best.blocked = IsBlocked(recipe)
      best.stable = not best.blocked
      if best.blocked and not state.showBlocked then
        counts.blocked = counts.blocked + 1
      else
        table.insert(results, best)
      end
    end
  end
  return results, counts
end

local function ToggleBlocked(recipe)
  local db = AuctionatorShuffleDB
  db.blocked = db.blocked or {}
  db.blocked[recipe.spell] = not db.blocked[recipe.spell] or nil
  RefreshAll()
end

-- Most profitable stable result (by `key`, default profit per craft), or nil.
local function PickRecommended(results, key)
  key = key or "profit"
  local best
  for _, result in ipairs(results) do
    if result.stable and result.profit > 0 and result[key] and (not best or result[key] > best[key]) then
      best = result
    end
  end
  return best
end

---------------------------------------------------------------------------
-- Formatting
---------------------------------------------------------------------------

local pendingItems = false

local function ItemName(itemID)
  local name = GetItemInfo(itemID)
  if name then return name end
  pendingItems = true
  if C_Item and C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(itemID) end
  return nil
end

local function EntryText(entry)
  local qty = entry[2] > 1 and (entry[2] .. "x ") or ""
  return qty .. (ItemName(entry[1]) or ("item:" .. entry[1]))
end

local function SideText(side)
  local parts = {}
  for _, entry in ipairs(side) do table.insert(parts, EntryText(entry)) end
  return table.concat(parts, " + ")
end

local function Money(copper)
  local sign = copper < 0 and "-" or ""
  copper = math.floor(math.abs(copper) + 0.5)
  local g = math.floor(copper / 10000)
  local s = math.floor((copper % 10000) / 100)
  local c = copper % 100
  local text
  if g > 0 then
    text = string.format("%d|cffffd700g|r %02d|cffc7c7cfs|r %02d|cffeda55fc|r", g, s, c)
  elseif s > 0 then
    text = string.format("%d|cffc7c7cfs|r %02d|cffeda55fc|r", s, c)
  else
    text = string.format("%d|cffeda55fc|r", c)
  end
  return sign .. text
end

-- Two largest coin units only ("4g 27s", "97s 26c"), for narrow columns.
local function MoneyShort(copper)
  local sign = copper < 0 and "-" or ""
  copper = math.floor(math.abs(copper) + 0.5)
  local g = math.floor(copper / 10000)
  local s = math.floor((copper % 10000) / 100)
  local c = copper % 100
  if g > 0 then
    return sign .. string.format("%d|cffffd700g|r %02d|cffc7c7cfs|r", g, s)
  elseif s > 0 then
    return sign .. string.format("%d|cffc7c7cfs|r %02d|cffeda55fc|r", s, c)
  end
  return sign .. string.format("%d|cffeda55fc|r", c)
end

local function AgeText(age)
  if age == nil then return "" end
  if age >= 99 then return "|cffff8040old|r" end
  if age == 0 then return "|cff20ff20today|r" end
  local color = age >= 3 and "|cffff8040" or "|cffffd100"
  return color .. age .. "d|r"
end

local function Number(n)
  return BreakUpLargeNumbers and BreakUpLargeNumbers(n) or tostring(n)
end

local function Ordinal(n)
  local suffix = "th"
  if n % 100 < 11 or n % 100 > 13 then
    suffix = ({ "st", "nd", "rd" })[n % 10] or "th"
  end
  return n .. suffix
end

---------------------------------------------------------------------------
-- Depth scanning: reads every listing of each item (through Auctionator's
-- single-item search helper, which handles throttling and cache retries) and
-- prices the item from its listings (see "Prices and maths").
---------------------------------------------------------------------------

local SCAN_TIMEOUT = 10 -- seconds to wait for one item before skipping it

local scan = nil -- { queue = {itemIDs}, index, timer, skipped, kind }

-- Progress text while a scan runs; with `kind`, only for scans of that kind ("snipe" or nil).
local function ScanProgressText(kind)
  if not scan or scan.kind ~= kind then return nil end
  return string.format("Scanning %d/%d", math.min(scan.index, #scan.queue), #scan.queue)
end

-- entries: list of { unitPrice, quantity }.
-- Returns price, lowest price, total listed, and the unit rank the price was taken at.
function DepthPrice(itemID, entries, totalListed)
  table.sort(entries, function(a, b) return a[1] < b[1] end)
  local units = 0
  for _, entry in ipairs(entries) do units = units + entry[2] end
  local rank = DEPTH_QTY
  if IsEquipment(itemID) then rank = math.max(EQUIP_MIN_RANK, math.ceil(units * EQUIP_RANK_FRACTION)) end

  local cumulative, depthPrice = 0, nil
  for _, entry in ipairs(entries) do
    cumulative = cumulative + entry[2]
    if cumulative >= rank then
      depthPrice = entry[1]
      break
    end
  end
  -- Fewer than `rank` listed: use the most expensive listing (thin market).
  depthPrice = depthPrice or (entries[#entries] and entries[#entries][1])
  return depthPrice, entries[1] and entries[1][1], math.max(totalListed or 0, units), rank
end

-- Median of the daily price midpoints from earlier days (today excluded), or nil.
local function RecentMedian(itemID)
  local history = AuctionatorShuffleDB.history and AuctionatorShuffleDB.history[itemID]
  if not history then return nil end
  local mids, today = {}, Today()
  for day, range in pairs(history) do
    if day < today and day > today - HISTORY_DAYS then table.insert(mids, (range[1] + range[2]) / 2) end
  end
  if #mids == 0 then return nil end
  table.sort(mids)
  return mids[math.ceil(#mids / 2)]
end

function SaveDepth(itemID, price, lowest, listed, rank)
  local db = AuctionatorShuffleDB
  db.depth = db.depth or {}
  db.history = db.history or {}

  -- Gear: a sudden spike (e.g. the cheap ones sold out) is capped at the recent median.
  local stored, capped = price, false
  if IsEquipment(itemID) then
    local median = RecentMedian(itemID)
    if median and price > median * EQUIP_SPIKE_CAP then
      stored, capped = math.floor(median * EQUIP_SPIKE_CAP), true
    end
  end
  db.depth[itemID] = { price = stored, raw = price, capped = capped, lowest = lowest, listed = listed, rank = rank, time = time() }

  local history = db.history[itemID] or {}
  db.history[itemID] = history
  local today = Today()
  local range = history[today]
  history[today] = range and { math.min(range[1], price), math.max(range[2], price) } or { price, price }
  for day in pairs(history) do
    if day <= today - HISTORY_KEEP_DAYS then history[day] = nil end
  end
end

local ScanNext

local function FinishScan(message)
  if scan and scan.timer then scan.timer:Cancel() end
  scan = nil
  Print(message)
  RefreshAll()
end

-- Snipe rescan: replaces an item's snipe listings with the ones still under its worth
-- (entries: { unitPrice, quantity }), and drops the item when none are left.
local function UpdateSnipeListings(itemID, entries)
  local snipes = AuctionatorShuffleDB.snipes
  if not snipes then return end
  local vendorEach, disenchantEach = SnipeValues(itemID)
  local worth = math.max(vendorEach, disenchantEach or 0)
  local kept = {}
  for _, entry in ipairs(entries) do
    if entry[1] < worth then table.insert(kept, { entry[1], entry[2] }) end
  end
  snipes.items[itemID] = #kept > 0 and { auctions = kept } or nil
end

local function ItemDone(itemID, entries, totalListed)
  if not scan or scan.queue[scan.index] ~= itemID then return end
  if scan.timer then scan.timer:Cancel() end
  if scan.kind == "snipe" then UpdateSnipeListings(itemID, entries) end
  if #entries > 0 then
    SaveDepth(itemID, DepthPrice(itemID, entries, totalListed))
  else
    -- Nothing listed: record zero listings (and no price) so a stale price isn't used.
    AuctionatorShuffleDB.depth = AuctionatorShuffleDB.depth or {}
    AuctionatorShuffleDB.depth[itemID] = { listed = 0, time = time() }
    scan.skipped = scan.skipped + 1
  end
  scan.index = scan.index + 1
  QueueRefresh()
  ScanNext()
end

function ScanNext()
  if not scan then return end
  if not AuctionHouseOpen() then
    FinishScan("Scan stopped: the auction house closed.")
    return
  end
  local itemID = scan.queue[scan.index]
  if not itemID then
    FinishScan(string.format("Scan done: %d items priced%s.", #scan.queue - scan.skipped,
      scan.skipped > 0 and (", " .. scan.skipped .. " with no listings") or ""))
    return
  end
  local sorts = { { sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false } }
  Auctionator.AH.SendSearchQueryByItemKey(C_AuctionHouse.MakeItemKey(itemID), sorts, false)
  scan.timer = C_Timer.NewTimer(SCAN_TIMEOUT, function()
    if scan and scan.queue[scan.index] == itemID then ItemDone(itemID, {}, 0) end
  end)
end

-- Listens to Auctionator's "search results ready" events for the item being scanned.
local scanListener = {
  ReceiveEvent = function(_, eventName, arg)
    if not scan then return end
    if eventName == Auctionator.AH.Events.CommoditySearchResultsReady then
      local itemID = arg
      local entries = {}
      for i = 1, C_AuctionHouse.GetNumCommoditySearchResults(itemID) do
        local info = C_AuctionHouse.GetCommoditySearchResultInfo(itemID, i)
        if info and info.unitPrice and info.quantity then table.insert(entries, { info.unitPrice, info.quantity }) end
      end
      ItemDone(itemID, entries, C_AuctionHouse.GetCommoditySearchResultsQuantity(itemID))
    elseif eventName == Auctionator.AH.Events.ItemSearchResultsReady then
      local itemKey = arg
      if not scan or scan.queue[scan.index] ~= itemKey.itemID then return end
      local entries, auctions = {}, {}
      for i = 1, C_AuctionHouse.GetNumItemSearchResults(itemKey) do
        local info = C_AuctionHouse.GetItemSearchResultInfo(itemKey, i)
        if info and info.buyoutAmount and info.quantity and info.quantity > 0 then
          table.insert(entries, { math.floor(info.buyoutAmount / info.quantity), info.quantity })
        end
        if info and info.auctionID then auctions[info.auctionID] = info.timeLeft or 0 end
      end
      -- Only compare complete result sets, or missing pages would look like sales.
      if C_AuctionHouse.HasFullItemSearchResults(itemKey) then RecordSales(itemKey.itemID, auctions) end
      ItemDone(itemKey.itemID, entries, C_AuctionHouse.GetItemSearchResultsQuantity(itemKey))
    end
  end,
}
local scanListenerRegistered = false

-- recipes: list of { inputs, outputs }. Second click while scanning cancels.
-- kind "snipe" also refreshes the Snipe tab's listings of each scanned item.
local function ScanRecipes(recipes, label, emptyReason, kind)
  if scan then
    FinishScan("Scan cancelled.")
    return
  end
  if not AuctionHouseOpen() then
    Print("Open the auction house to scan.")
    return
  end
  if not (Auctionator.AH and Auctionator.AH.SendSearchQueryByItemKey and C_AuctionHouse) then
    Print("This auction house doesn't support depth scans.")
    return
  end
  if not scanListenerRegistered then
    Auctionator.EventBus:Register(scanListener, {
      Auctionator.AH.Events.CommoditySearchResultsReady,
      Auctionator.AH.Events.ItemSearchResultsReady,
    })
    scanListenerRegistered = true
  end

  local queue, seen = {}, {}
  for _, recipe in ipairs(recipes) do
    for _, side in ipairs({ recipe.outputs, recipe.inputs }) do
      for _, entry in ipairs(side) do
        if not seen[entry[1]] and not VENDOR[entry[1]] then
          seen[entry[1]] = true
          table.insert(queue, entry[1])
        end
      end
    end
  end
  if #queue == 0 then
    Print(label .. " has no items to scan." .. (emptyReason and (" " .. emptyReason) or ""))
    return
  end
  scan = { queue = queue, index = 1, skipped = 0, kind = kind }
  Print(string.format("Scanning %d items from %s (click Scan again to cancel).", #queue, label))
  ScanNext()
end

---------------------------------------------------------------------------
-- Snipe buying. The game requires a real click or key press for every purchase,
-- so this can't run by itself: each press of Buy next (or Shift + mouse wheel while
-- the Snipe tab is open) buys the next cheapest listing under the item's worth.
---------------------------------------------------------------------------

local BUY_COOLDOWN = 0.25 -- seconds; extra wheel ticks inside this window are ignored
local buy = nil -- { itemID, cap, method, state, queue / quantity, expected, confirmTotal, lastBuy }

-- Disenchant whitelist: the shuffle wheel only ever disenchants these items.
-- Buying a disenchant snipe adds the item automatically.
local function Whitelist()
  AuctionatorShuffleDB.whitelist = AuctionatorShuffleDB.whitelist or {}
  return AuctionatorShuffleDB.whitelist
end

local function AddToWhitelist(itemID, quiet)
  local list = Whitelist()
  if list[itemID] then return end
  list[itemID] = true
  if not quiet then
    Print("Added to whitelist: " .. (select(2, GetItemInfo(itemID)) or ("item:" .. itemID)))
  end
end

local function NoteSnipePurchase()
  if buy and buy.method == "Disenchant" then AddToWhitelist(buy.itemID) end
end

local function StoreSnipeListings(itemID, auctions)
  local snipes = AuctionatorShuffleDB.snipes
  if not (snipes and snipes.items) then return end
  snipes.items[itemID] = #auctions > 0 and { auctions = auctions } or nil
end

local function RequestBuyListings()
  if not (buy and AuctionHouseOpen()) then return end
  buy.state = "loading"
  local sorts = { { sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false } }
  Auctionator.AH.SendSearchQueryByItemKey(C_AuctionHouse.MakeItemKey(buy.itemID), sorts, false)
end

local function SelectSnipe(result)
  if scan then
    Print("Wait for the price scan to finish first.")
    return
  end
  if not AuctionHouseOpen() then
    Print("Open the auction house to buy.")
    return
  end
  buy = { itemID = result.itemID, cap = result.value, method = result.method, queue = {} }
  RequestBuyListings()
  RefreshAll()
end

-- Fresh listings for the selected item: keep only the ones under its worth (and not yours).
local buyListener = {
  ReceiveEvent = function(_, eventName, arg)
    if not buy or buy.state ~= "loading" then return end
    if eventName == Auctionator.AH.Events.CommoditySearchResultsReady and arg == buy.itemID then
      local quantity, total, stored = 0, 0, {}
      for i = 1, C_AuctionHouse.GetNumCommoditySearchResults(arg) do
        local info = C_AuctionHouse.GetCommoditySearchResultInfo(arg, i)
        if info and info.unitPrice and info.unitPrice < buy.cap then
          local qty = (info.quantity or 0) - (info.numOwnerItems or 0)
          if qty > 0 then
            quantity = quantity + qty
            total = total + qty * info.unitPrice
            table.insert(stored, { info.unitPrice, qty })
          end
        end
      end
      buy.commodity, buy.quantity, buy.expected = true, quantity, total
      buy.state = quantity > 0 and "ready" or "empty"
      StoreSnipeListings(arg, stored)
      RefreshAll()
    elseif eventName == Auctionator.AH.Events.ItemSearchResultsReady and arg.itemID == buy.itemID then
      local queue, stored = {}, {}
      for i = 1, C_AuctionHouse.GetNumItemSearchResults(arg) do
        local info = C_AuctionHouse.GetItemSearchResultInfo(arg, i)
        if info and info.auctionID and info.buyoutAmount and info.quantity and info.quantity > 0 and not info.containsOwnerItem then
          local unit = math.floor(info.buyoutAmount / info.quantity)
          if unit < buy.cap then
            table.insert(queue, { auctionID = info.auctionID, unit = unit, buyout = info.buyoutAmount, qty = info.quantity })
            table.insert(stored, { unit, info.quantity })
          end
        end
      end
      table.sort(queue, function(a, b) return a.unit < b.unit end)
      buy.commodity, buy.queue = false, queue
      buy.state = #queue > 0 and "ready" or "empty"
      StoreSnipeListings(arg.itemID, stored)
      RefreshAll()
    end
  end,
}
Auctionator.EventBus:Register(buyListener, {
  Auctionator.AH.Events.CommoditySearchResultsReady,
  Auctionator.AH.Events.ItemSearchResultsReady,
})

-- Called by the Buy next button (a real click or bound key press).
local function BuyNext()
  if not buy then return end
  if not AuctionHouseOpen() then
    buy = nil
    RefreshAll()
    return
  end
  local now = GetTime()
  if buy.lastBuy and now - buy.lastBuy < BUY_COOLDOWN then return end

  -- Only ever buy at a profit: re-check what the item is worth right now (enchanting mat
  -- prices can change after a scan) and drop any listing that's no longer under it.
  local vendorEach, disenchantEach = SnipeValues(buy.itemID)
  local worthNow = buy.method == "Disenchant" and disenchantEach or vendorEach
  if not worthNow or worthNow <= 0 then
    Print("Can't tell what this is worth right now, so nothing was bought.")
    return
  end
  if worthNow < buy.cap then
    buy.cap = worthNow
    if not buy.commodity then
      local kept = {}
      for _, auction in ipairs(buy.queue) do
        if auction.unit < worthNow then table.insert(kept, auction) end
      end
      buy.queue = kept
      if #kept == 0 and buy.state == "ready" then
        buy.state = "empty"
        Print("Worth dropped to " .. Money(worthNow) .. " each; nothing left at a profit.")
        RefreshAll()
        return
      end
    elseif buy.state == "ready" then
      Print("Worth dropped to " .. Money(worthNow) .. " each; reloading listings.")
      RequestBuyListings()
      RefreshAll()
      return
    end
  end

  if buy.state == "ready" and buy.commodity then
    if GetMoney() < buy.expected then
      Print("Not enough gold for that.")
      return
    end
    buy.state = "pricing"
    buy.lastBuy = now
    C_AuctionHouse.StartCommoditiesPurchase(buy.itemID, buy.quantity)
  elseif buy.state == "ready" then
    local auction = buy.queue[1]
    if GetMoney() < auction.buyout then
      Print("Not enough gold for that.")
      return
    end
    table.remove(buy.queue, 1)
    buy.lastBuy = now
    buy.bought = (buy.bought or 0) + auction.qty
    buy.profit = (buy.profit or 0) + (buy.cap - auction.unit) * auction.qty
    C_AuctionHouse.PlaceBid(auction.auctionID, auction.buyout)
    NoteSnipePurchase()
    local stored = {}
    for _, left in ipairs(buy.queue) do table.insert(stored, { left.unit, left.qty }) end
    StoreSnipeListings(buy.itemID, stored)
    if #buy.queue == 0 then
      buy.state = "loading"
      C_Timer.After(1, RequestBuyListings) -- look again for anything new under the cap
    end
    RefreshAll()
  elseif buy.state == "confirm" then
    buy.lastBuy = now
    buy.bought = (buy.bought or 0) + buy.quantity
    buy.profit = (buy.profit or 0) + buy.cap * buy.quantity - buy.confirmTotal
    C_AuctionHouse.ConfirmCommoditiesPurchase(buy.itemID, buy.quantity)
    NoteSnipePurchase()
    buy.state = "loading"
    C_Timer.After(1.5, RequestBuyListings)
    RefreshAll()
  elseif buy.state == "empty" then
    RequestBuyListings()
    RefreshAll()
  end
end

-- Stack purchases: the server quotes the real total first; only confirm if it's still under the cap.
local buyEvents = CreateFrame("Frame")
for _, event in ipairs({ "COMMODITY_PRICE_UPDATED", "COMMODITY_PRICE_UNAVAILABLE", "COMMODITY_PURCHASE_FAILED",
                         "AUCTION_HOUSE_CLOSED" }) do
  pcall(buyEvents.RegisterEvent, buyEvents, event)
end
buyEvents:SetScript("OnEvent", function(_, event, unitPrice, totalPrice)
  if event == "AUCTION_HOUSE_CLOSED" then
    buy = nil
    return
  end
  if not buy then return end
  if event == "COMMODITY_PRICE_UPDATED" and buy.state == "pricing" then
    if totalPrice and totalPrice < buy.cap * buy.quantity then
      buy.state, buy.confirmTotal = "confirm", totalPrice
    else
      C_AuctionHouse.CancelCommoditiesPurchase()
      Print("Price went up past what it's worth; reloading listings.")
      RequestBuyListings()
    end
  elseif event == "COMMODITY_PRICE_UNAVAILABLE" or event == "COMMODITY_PURCHASE_FAILED" then
    RequestBuyListings()
  end
  RefreshAll()
end)

local function BuyButtonText()
  if not buy then return "Click a snipe to buy it", false end
  local cap = buy.cap
  if buy.state == "loading" then return "Loading listings...", false end
  if buy.state == "pricing" then return "Checking price...", false end
  if buy.state == "empty" then return "None left under " .. MoneyShort(cap) .. " (click to recheck)", true end
  if buy.state == "confirm" then
    return string.format("Confirm %d for %s (+%s)", buy.quantity, MoneyShort(buy.confirmTotal),
      MoneyShort(cap * buy.quantity - buy.confirmTotal)), true
  end
  if buy.commodity then
    return string.format("Buy %d for %s (+%s)", buy.quantity, MoneyShort(buy.expected),
      MoneyShort(cap * buy.quantity - buy.expected)), true
  end
  local auction = buy.queue[1]
  return string.format("Buy %dx for %s (+%s)  ·  %d left", auction.qty, MoneyShort(auction.buyout),
    MoneyShort((cap - auction.unit) * auction.qty), #buy.queue), true
end

-- Opens Auctionator's Shopping tab on one item's listings.
local function SearchItem(itemID)
  if not AuctionHouseOpen() then
    Print("Open the auction house to jump to that item.")
    return
  end
  local name = ItemName(itemID)
  if not name then
    Print("Item name still loading. Click again in a second.")
    return
  end
  Auctionator.API.v1.MultiSearchExact(ADDON, { name })
end

---------------------------------------------------------------------------
-- Profit table (used by both AH tabs and the standalone windows)
---------------------------------------------------------------------------

local ROW_HEIGHT = 26
local ICON_SIZE = 22
local REAGENT_ICON = 18
local SCROLLBAR_SPACE = 26
local BLOCK_SPACE = 26 -- Crafts: block button at the end of each row

-- Fixed-width numeric columns; the first column takes the remaining width.
local SHUFFLE_COLUMNS = {
  { key = "name", title = "Recipe", justify = "LEFT", defaultDesc = false },
  { key = "cost", title = "Buy cost", width = 105, justify = "RIGHT", defaultDesc = true },
  { key = "revenue", title = "Sells for (-5%)", width = 115, justify = "RIGHT", defaultDesc = true },
  { key = "profit", title = "Profit", width = 105, justify = "RIGHT", defaultDesc = true },
  { key = "perHour", title = "Per Hour", width = 100, justify = "RIGHT", defaultDesc = true },
  { key = "margin", title = "Margin", width = 65, justify = "RIGHT", defaultDesc = true },
  { key = "age", title = "Data", width = 55, justify = "RIGHT", defaultDesc = false },
}
-- The Recipe column shows the plan that teaches the craft, only while it's unknown.
local CRAFT_COLUMNS = {
  { key = "name", title = "Craft", justify = "LEFT", defaultDesc = false },
  { key = "recipe", title = "Recipe", width = 52, justify = "CENTER", recipe = true },
  { key = "cost", title = "Mats cost", width = 74, justify = "RIGHT", defaultDesc = true },
  { key = "revenue", title = "Sells (-5%)", width = 78, justify = "RIGHT", defaultDesc = true },
  { key = "profit", title = "Profit", width = 80, justify = "RIGHT", defaultDesc = true },
  { key = "margin", title = "Margin", width = 56, justify = "RIGHT", defaultDesc = true },
  { key = "listed", title = "Listed", width = 50, justify = "RIGHT", defaultDesc = true },
  { key = "sold", title = "Sold 7d", width = 56, justify = "RIGHT", defaultDesc = true },
  { key = "age", title = "Data", width = 44, justify = "RIGHT", defaultDesc = false },
}
-- Vendor shuffles: buy mats on the AH, craft, sell the result to a vendor (no AH cut).
local VENDOR_COLUMNS = {
  { key = "name", title = "Craft", justify = "LEFT", defaultDesc = false },
  { key = "recipe", title = "Recipe", width = 52, justify = "CENTER", recipe = true },
  { key = "produces", title = "DE into", width = 72, justify = "LEFT", nosort = true }, -- disenchant shuffles only
  { key = "vendor", title = "Sell price", width = 76, justify = "RIGHT", defaultDesc = true },
  { key = "cost", title = "Mats cost", width = 76, justify = "RIGHT", defaultDesc = true },
  { key = "profit", title = "Profit", width = 80, justify = "RIGHT", defaultDesc = true },
  { key = "castTime", title = "Time", width = 48, justify = "RIGHT", defaultDesc = false },
  { key = "perHour", title = "Gold/h", width = 84, justify = "RIGHT", defaultDesc = true },
  { key = "age", title = "Data", width = 44, justify = "RIGHT", defaultDesc = false },
}
-- Snipes: auctions selling for less than their disenchant value or vendor price.
local SNIPE_COLUMNS = {
  { key = "name", title = "Item", justify = "LEFT", defaultDesc = false },
  { key = "produces", title = "DE into", width = 72, justify = "LEFT", nosort = true }, -- icons, filled by PlaceCraftIcons
  { key = "method", title = "Use", width = 56, justify = "CENTER", defaultDesc = false },
  { key = "lowest", title = "Cheapest", width = 80, justify = "RIGHT", defaultDesc = false },
  { key = "value", title = "Worth", width = 80, justify = "RIGHT", defaultDesc = true },
  { key = "profitEach", title = "Profit each", width = 78, justify = "RIGHT", defaultDesc = true },
  { key = "atProfit", title = "At profit", width = 60, justify = "RIGHT", defaultDesc = true },
  { key = "profit", title = "Total profit", width = 84, justify = "RIGHT", defaultDesc = true },
  { key = "perHour", title = "Per Hour", width = 78, justify = "RIGHT", defaultDesc = true },
}
local function FixedWidth(columns)
  local total = 0
  for _, col in ipairs(columns) do total = total + (col.width or 0) end
  return total
end

local function SortState(view)
  local db = AuctionatorShuffleDB
  if view.mode == "craft" then
    db.craftSort = db.craftSort or { key = "profit", desc = true }
    return db.craftSort
  elseif view.mode == "vendor" then
    db.vendorSort = db.vendorSort or { key = "perHour", desc = true }
    return db.vendorSort
  elseif view.mode == "snipe" then
    db.snipeSort = db.snipeSort or { key = "profit", desc = true }
    return db.snipeSort
  end
  db.sort = db.sort or { key = "profit", desc = true }
  return db.sort
end

local function SortValue(result, key)
  if key == "name" then
    return (ItemName(result.recipe.outputs[1][1]) or ""):lower()
  end
  return result[key]
end

local function SortResults(view, results)
  local sort = SortState(view)
  table.sort(results, function(a, b)
    -- Rows without prices always sink to the bottom.
    if (a.cost == nil) ~= (b.cost == nil) then return a.cost ~= nil end
    local va, vb = SortValue(a, sort.key), SortValue(b, sort.key)
    if va == nil or vb == nil or va == vb then
      if (va == nil) ~= (vb == nil) then return va ~= nil end
      return SortValue(a, "name") < SortValue(b, "name")
    end
    if sort.desc then return va > vb else return va < vb end
  end)
end

local views = {}
local viewCount = 0

local function ShowRowTooltip(row)
  local result = row.result
  if not result then return end
  local recipe = result.recipe
  local view = row.view
  GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
  if view.mode == "snipe" then
    GameTooltip:AddLine(ItemName(result.itemID) or ("item:" .. result.itemID), 1, 1, 1)
    GameTooltip:AddLine(" ")
    GameTooltip:AddDoubleLine("Vendor pays", result.vendorEach and result.vendorEach > 0 and Money(result.vendorEach) or "nothing",
      0.9, 0.9, 0.9, 1, 1, 1)
    if result.disenchantEach then
      GameTooltip:AddDoubleLine("Disenchant value (after 5% cut)", Money(result.disenchantEach), 0.9, 0.9, 0.9, 1, 1, 1)
      for _, outcome in ipairs(result.outcomes or {}) do
        GameTooltip:AddLine(string.format("      %.0f%%  %sx %s", outcome[2] * 100,
          outcome[3] % 1 == 0 and outcome[3] or string.format("%.1f", outcome[3]),
          ItemName(outcome[1]) or ("item:" .. outcome[1])), 0.55, 0.55, 0.55)
      end
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(string.format("Listed under %s each (%s):", Money(result.value),
      result.method == "Disenchant" and "disenchant" or "vendor"), 1, 0.82, 0)
    local profitable = {}
    for _, auction in ipairs(result.auctions) do
      if auction[1] < result.value then table.insert(profitable, auction) end
    end
    table.sort(profitable, function(a, b) return a[1] < b[1] end)
    for i, auction in ipairs(profitable) do
      if i > 12 then
        GameTooltip:AddLine(string.format("  ...and %d more", #profitable - 12), 0.6, 0.6, 0.6)
        break
      end
      GameTooltip:AddDoubleLine(string.format("  %dx at %s", auction[2], Money(auction[1])),
        "|cff20ff20+" .. Money((result.value - auction[1]) * auction[2]) .. "|r", 0.9, 0.9, 0.9, 1, 1, 1)
    end
    GameTooltip:AddDoubleLine("Buy all of them", "|cff20ff20+" .. Money(result.profit) .. "|r", 1, 0.82, 0, 1, 1, 1)
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Prices are from the last full scan; some may already be gone.", 0.5, 0.5, 0.5, true)
    GameTooltip:AddLine("Click the row to pick it, then Shift + mouse wheel (or Buy next) buys one at a time.", 0.2, 1, 0.2, true)
    GameTooltip:AddLine("Shift-click the row to buy one straight away.", 0.2, 1, 0.2, true)
    GameTooltip:AddLine(result.blocked and "Click the tick on the right to unblock" or "Click the X on the right to hide this item",
      0.5, 0.5, 0.5)
    GameTooltip:Show()
    return
  end
  GameTooltip:AddLine(SideText(recipe.outputs), 1, 1, 1)
  if recipe.skill then GameTooltip:AddLine("Skill " .. recipe.skill .. (IsKnown(recipe) and "  |cff20ff20known|r" or ""), 0.6, 0.6, 0.6) end
  GameTooltip:AddLine(" ")
  local function AddItemLines(side)
    for _, entry in ipairs(side) do
      local price, source = GetPrice(entry[1])
      GameTooltip:AddDoubleLine("  " .. EntryText(entry), price and Money(price * entry[2]) or "no price", 0.9, 0.9, 0.9, 1, 1, 1)
      local depth = GetDepth(entry[1])
      if source == "vendor" then
        GameTooltip:AddLine("      vendor price", 0.55, 0.55, 0.55)
      elseif depth and not depth.price then
        GameTooltip:AddLine("      none listed at the last scan", 1, 0.5, 0.25)
      elseif depth then
        local where = IsEquipment(entry[1]) and (Ordinal(depth.rank or EQUIP_MIN_RANK) .. " cheapest")
          or string.format("%d deep", depth.rank or DEPTH_QTY)
        GameTooltip:AddLine(string.format("      %s each at %s · lowest %s · %s listed",
          Money(depth.price), where, Money(depth.lowest or depth.price), Number(depth.listed)), 0.55, 0.55, 0.55)
        if depth.capped then
          GameTooltip:AddLine("      capped near its recent price (listings now " .. Money(depth.raw) .. ")", 1, 0.5, 0.25)
        end
      elseif price then
        GameTooltip:AddLine("      lowest listing only - Scan for the outlier-proof price", 1, 0.5, 0.25)
      end
    end
  end
  GameTooltip:AddLine("Buy:", 1, 0.82, 0)
  AddItemLines(recipe.inputs)
  if view.mode == "vendor" and result.kind == "disenchant" then
    GameTooltip:AddLine("Disenchant " .. EntryText(recipe.outputs[1]) .. " into:", 1, 0.82, 0)
    if result.deOutcomes then
      for _, outcome in ipairs(result.deOutcomes) do
        local price = SellPrice(outcome[1])
        GameTooltip:AddDoubleLine(string.format("  %.0f%%  %sx %s", outcome[2] * 100, outcome[3] % 1 == 0 and outcome[3] or
          string.format("%.1f", outcome[3]), ItemName(outcome[1]) or ("item:" .. outcome[1])),
          price and (Money(price) .. " each") or "no price - Scan mats", 0.9, 0.9, 0.9, 1, 1, 1)
      end
      GameTooltip:AddDoubleLine("  Expected value (after 5% AH cut)", result.vendor and Money(result.vendor) or "needs prices",
        0.9, 0.9, 0.9, 1, 1, 1)
    else
      GameTooltip:AddLine("  " .. (result.deReason == "loading" and "item info loading..." or (result.deReason or "unknown")),
        1, 0.5, 0.25)
    end
    GameTooltip:AddLine(" ")
  elseif view.mode == "vendor" then
    GameTooltip:AddLine("Sell to a vendor:", 1, 0.82, 0)
    GameTooltip:AddDoubleLine("  " .. EntryText(recipe.outputs[1]), result.vendor and Money(result.vendor) or "loading...",
      0.9, 0.9, 0.9, 1, 1, 1)
    GameTooltip:AddLine(" ")
  end
  if view.mode == "vendor" then
    if result.cost then
      GameTooltip:AddDoubleLine("Profit per craft", Money(result.profit), 1, 0.82, 0, 1, 1, 1)
      GameTooltip:AddDoubleLine("Margin", string.format("%+.0f%%", result.margin), 0.9, 0.9, 0.9, 1, 1, 1)
    end
    GameTooltip:AddDoubleLine(result.kind == "disenchant" and "Craft + disenchant time" or "Craft time",
      result.castTime and string.format("%.1f sec", result.castTime) or "unknown",
      0.9, 0.9, 0.9, 1, 1, 1)
    if result.perHour then
      GameTooltip:AddDoubleLine("Gold per hour", Money(result.perHour), 1, 0.82, 0, 1, 1, 1)
      GameTooltip:AddLine(string.format("%d crafts an hour, nonstop, if you can buy enough mats.",
        math.floor(3600 / result.castTime)), 0.5, 0.5, 0.5, true)
    end
    if result.cost and not result.buyable then
      GameTooltip:AddLine("Not recommended: scan the mats and make sure enough are listed for " .. VENDOR_MIN_CRAFTS ..
        "+ crafts.", 1, 0.5, 0.25, true)
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(result.blocked and "Click the tick on the right to unblock" or "Click the X on the right to block this craft",
      0.5, 0.5, 0.5)
    GameTooltip:Show()
    return
  end
  GameTooltip:AddLine("Sell:", 1, 0.82, 0)
  AddItemLines(recipe.outputs)
  if result.cost then
    GameTooltip:AddDoubleLine("  AH cut (5%)", "-" .. Money(result.gross - result.revenue), 0.9, 0.9, 0.9, 1, 0.4, 0.4)
    GameTooltip:AddLine(" ")
    GameTooltip:AddDoubleLine("Profit per craft", Money(result.profit), 1, 0.82, 0, 1, 1, 1)
  end
  if view.mode == "craft" then
    if result.equipment then
      GameTooltip:AddDoubleLine("Seen selling (" .. HISTORY_DAYS .. " days)", result.sold and tostring(result.sold) or "needs 2 scans",
        0.9, 0.9, 0.9, 1, 1, 1)
      GameTooltip:AddLine("Counts auctions that vanished long before they could expire (bought or cancelled).", 0.5, 0.5, 0.5, true)
    end
    if result.swing then
      GameTooltip:AddDoubleLine("Price swing (" .. HISTORY_DAYS .. " days)", string.format("%.0f%%", result.swing * 100), 0.9, 0.9, 0.9, 1, 1, 1)
    end
    if result.stable then
      GameTooltip:AddLine("Sells reliably", 0.2, 1, 0.2)
    elseif result.cost and result.listed then
      GameTooltip:AddLine(string.format("Not recommended: needs %d+ listed, under %d%% swing%s", MIN_LISTINGS,
        STABLE_MAX_SWING * 100, result.equipment and (", " .. EQUIP_MIN_SOLD .. "+ seen selling") or ""), 1, 0.5, 0.25, true)
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(result.blocked and "Click the tick on the right to unblock" or "Click the X on the right to block this craft",
      0.5, 0.5, 0.5)
  else
    if result.volume then
      GameTooltip:AddDoubleLine("Fewest listed of any item", Number(result.volume), 0.9, 0.9, 0.9, 1, 1, 1)
      GameTooltip:AddDoubleLine("Price swing (" .. HISTORY_DAYS .. " days)", string.format("%.0f%%", result.swing * 100),
        0.9, 0.9, 0.9, 1, 1, 1)
      if result.stable then
        GameTooltip:AddLine("Stable", 0.2, 1, 0.2)
      else
        GameTooltip:AddLine("Unstable (needs " .. STABLE_MIN_VOLUME .. "+ listed and under " ..
          (STABLE_MAX_SWING * 100) .. "% swing)", 1, 0.5, 0.25)
      end
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Shift + right-click to remove from this profile", 0.5, 0.5, 0.5)
  end
  GameTooltip:Show()
end

local function RemoveRecipe(recipe)
  local section = SelectedSection()
  if not section then return end
  for i, r in ipairs(section.recipes) do
    if r == recipe then
      table.remove(section.recipes, i)
      Print("Removed " .. SideText(recipe.outputs) .. " from " .. section.name .. ".")
      RefreshAll()
      return
    end
  end
end

-- Item icon button: hover for the item tooltip, click to open its AH listings.
local function GetItemButton(pool, parent, index, size)
  local button = pool[index]
  if button then return button end
  button = CreateFrame("Button", nil, parent)
  button:SetSize(size, size)
  button.texture = button:CreateTexture(nil, "ARTWORK")
  button.texture:SetAllPoints()
  button.texture:SetTexCoord(0.07, 0.93, 0.07, 0.93)
  button.count = button:CreateFontString(nil, "OVERLAY", size < ICON_SIZE and "NumberFontNormalSmall" or "NumberFontNormal")
  button.count:SetPoint("BOTTOMRIGHT", 1, 0)
  button:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
  button:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetItemByID(self.itemID)
    GameTooltip:AddLine(" ")
    for _, line in ipairs(self.extra or {}) do GameTooltip:AddLine(line, 1, 0.82, 0) end
    GameTooltip:AddLine("Click to show this item's listings", 0.2, 1, 0.2)
    GameTooltip:Show()
  end)
  button:SetScript("OnLeave", function() GameTooltip:Hide() end)
  button:SetScript("OnClick", function(self) SearchItem(self.itemID) end)
  pool[index] = button
  return button
end

local function SetItemButton(button, entry, parent, x, y, point)
  button.itemID = entry[1]
  button.texture:SetTexture(GetItemIcon(entry[1]) or 134400)
  button.count:SetText(entry[2] > 1 and entry[2] or "")
  button:ClearAllPoints()
  button:SetPoint(point, parent, point, x, y)
  button:Show()
end

-- Lays out "inputs > outputs" item buttons from x along parent's left edge.
-- Everything is anchored to the parent frame itself (never to sibling regions),
-- which avoids anchor loops. Returns the x just past the last icon.
local function PlaceRecipeIcons(pool, arrow, parent, recipe, x, y, size, point)
  for _, button in ipairs(pool) do button:Hide() end
  local index = 0
  local function Place(entry)
    index = index + 1
    SetItemButton(GetItemButton(pool, parent, index, size), entry, parent, x, y, point)
    x = x + size + 3
  end
  for _, entry in ipairs(recipe.inputs) do Place(entry) end
  arrow:ClearAllPoints()
  arrow:SetPoint(point, parent, point, x + 2, y - (point == "TOPLEFT" and size / 2 - 7 or 0))
  arrow:Show()
  x = x + 14
  for _, entry in ipairs(recipe.outputs) do Place(entry) end
  return x
end

-- Craft rows: made item's icon on the left, small material icons at the right end of the
-- name column, and the plan in the Recipe column while the craft is unknown.
-- Returns the name text's left and right padding.
-- What an item disenchants into, as icons from x (with chance and price on hover).
local function PlaceOutcomeIcons(row, outcomes, x)
  for i, outcome in ipairs(outcomes) do
    local button = GetItemButton(row.outcomeIcons, row, i, REAGENT_ICON)
    SetItemButton(button, { outcome[1], 1 }, row, x, 0, "LEFT")
    local price = SellPrice(outcome[1])
    button.extra = {
      string.format("%.0f%% chance, %s on average", outcome[2] * 100,
        outcome[3] % 1 == 0 and tostring(outcome[3]) or string.format("%.1f", outcome[3])),
      price and ("Sells for " .. Money(price) .. " each (cheapest listing)") or "No price yet - Scan mats",
    }
    x = x + REAGENT_ICON + 4
  end
end

local function PlaceCraftIcons(row, nameWidth)
  local recipe = row.result.recipe
  for _, button in ipairs(row.reagentIcons) do button:Hide() end
  SetItemButton(GetItemButton(row.outIcons, row, 1, ICON_SIZE), recipe.outputs[1], row, 4, 0, "LEFT")
  local startX = nameWidth - 6 - #recipe.inputs * (REAGENT_ICON + 2)
  local x = startX
  for i, entry in ipairs(recipe.inputs) do
    SetItemButton(GetItemButton(row.reagentIcons, row, i, REAGENT_ICON), entry, row, x, 0, "LEFT")
    x = x + REAGENT_ICON + 2
  end

  local planButton = row.planButton
  planButton:ClearAllPoints()
  if not row.cells.recipe then -- tables without a Recipe column (Snipe)
    planButton:Hide()
    -- Snipe: what the item disenchants into, in the "DE into" column right after the name.
    for _, button in ipairs(row.outcomeIcons) do button:Hide() end
    local result = row.result
    if row.cells.produces and result.outcomes then
      PlaceOutcomeIcons(row, result.outcomes, nameWidth + 2)
      row.cells.produces:SetText("")
    elseif row.cells.produces then
      row.cells.produces:SetText("|cff6a6a6a-|r")
    end
    return 4 + ICON_SIZE + 6, 0
  end
  -- Disenchant shuffles: what the made item disenchants into, after the Recipe column.
  for _, button in ipairs(row.outcomeIcons) do button:Hide() end
  if row.cells.produces then
    local outcomes = row.result.kind == "disenchant" and row.result.deOutcomes
    if outcomes then PlaceOutcomeIcons(row, outcomes, nameWidth + 52 + 2) end
    row.cells.produces:SetText("")
  end
  local known = IsKnown(recipe)
  local plan = not known and PlanFor(recipe)
  if plan then
    planButton.plan = plan
    planButton.texture:SetTexture(GetItemIcon(plan.item) or 134939)
    planButton:SetPoint("LEFT", row, "LEFT", nameWidth + (52 - ICON_SIZE) / 2, 0)
    planButton:Show()
    row.cells.recipe:SetText("")
  else
    planButton:Hide()
    row.cells.recipe:SetText(known and "" or "|cff8a8a8aTrainer|r")
  end
  return 4 + ICON_SIZE + 6, nameWidth - startX + 4
end

local function ZoneName(areaID)
  if not (areaID and areaID > 0 and C_Map and C_Map.GetAreaInfo) then return nil end
  local ok, name = pcall(C_Map.GetAreaInfo, areaID)
  return ok and name or nil
end

local SOURCE_NAMES = {
  [1] = "Crafted", [2] = "Drops from mobs", [4] = "Quest reward", [5] = "Sold by a vendor",
  [16] = "Fishing", [21] = "Found in containers",
}

local function IsSoulbound(itemID)
  return select(14, GetItemInfo(itemID)) == 1
end

-- Plan tooltip: auction price when it can be traded, plus where it comes from.
local function ShowPlanTooltip(button)
  local plan = button.plan
  if not plan then return end
  GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
  GameTooltip:SetItemByID(plan.item)
  GameTooltip:AddLine(" ")
  local soulbound = IsSoulbound(plan.item)
  if not soulbound then
    local price = GetPrice(plan.item)
    local depth = GetDepth(plan.item)
    if price then
      GameTooltip:AddDoubleLine("Auction price", Money(price), 1, 0.82, 0, 1, 1, 1)
      if depth and depth.listed then GameTooltip:AddLine(Number(depth.listed) .. " listed at the last scan", 0.6, 0.6, 0.6) end
    else
      GameTooltip:AddLine("No auction price yet - Scan, or none are listed", 1, 0.5, 0.25)
    end
    GameTooltip:AddLine(" ")
  end

  GameTooltip:AddLine(soulbound and "Soulbound - get it from:" or "Comes from:", 1, 0.82, 0)
  local lines = 0
  local function Line(text)
    GameTooltip:AddLine("  " .. text, 0.9, 0.9, 0.9)
    lines = lines + 1
  end
  local function Where(areaID)
    local zone = ZoneName(areaID)
    return zone and (" - " .. zone) or ""
  end
  for _, drop in ipairs(plan.drops or {}) do
    Line(string.format("%s%s %s", drop[1], Where(drop[2]),
      drop[3] and drop[3] > 0 and string.format("|cff8a8a8a(%.1f%%)|r", drop[3]) or "|cff8a8a8a(<0.1%)|r"))
  end
  for _, vendor in ipairs(plan.vendors or {}) do Line("Sold by " .. vendor[1] .. Where(vendor[2])) end
  for _, quest in ipairs(plan.quests or {}) do Line("Quest: " .. quest) end
  for _, object in ipairs(plan.objects or {}) do Line("Found in " .. object[1] .. Where(object[2])) end
  if lines == 0 then
    for _, code in ipairs(plan.sources or {}) do
      if SOURCE_NAMES[code] then Line(SOURCE_NAMES[code] .. " |cff8a8a8a(where: Not Known)|r") end
    end
  end
  if lines == 0 then Line("Not Known") end

  if not soulbound then
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Click to show its listings", 0.2, 1, 0.2)
  end
  GameTooltip:Show()
end

local function CreateRow(view, index)
  local row = CreateFrame("Button", nil, view.content)
  row.view = view
  row:SetHeight(ROW_HEIGHT)
  row:SetPoint("TOPLEFT", 0, -(index - 1) * ROW_HEIGHT)
  row:SetPoint("RIGHT", view.content, "RIGHT")
  row:RegisterForClicks("AnyUp")

  local stripe = row:CreateTexture(nil, "BACKGROUND")
  stripe:SetAllPoints()
  stripe:SetColorTexture(1, 1, 1, index % 2 == 0 and 0.035 or 0)

  local highlight = row:CreateTexture(nil, "HIGHLIGHT")
  highlight:SetAllPoints()
  highlight:SetColorTexture(1, 0.82, 0, 0.10)

  -- Clickable item icons (filled per recipe).
  row.icons, row.outIcons, row.reagentIcons, row.outcomeIcons = {}, {}, {}, {}
  row.arrow = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  row.arrow:SetText(">")
  row.arrow:Hide()
  row.iconWidth = 0

  row.cells = {}
  for _, col in ipairs(view.columns) do
    local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    fs:SetJustifyH(col.justify)
    fs:SetWordWrap(false)
    row.cells[col.key] = fs
  end

  if view.mode ~= "shuffle" then -- crafts and vendor shuffles: plan icon and block button
    local planButton = CreateFrame("Button", nil, row)
    planButton:SetSize(ICON_SIZE, ICON_SIZE)
    planButton.texture = planButton:CreateTexture(nil, "ARTWORK")
    planButton.texture:SetAllPoints()
    planButton.texture:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    planButton:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    planButton:SetScript("OnEnter", ShowPlanTooltip)
    planButton:SetScript("OnLeave", function() GameTooltip:Hide() end)
    planButton:SetScript("OnClick", function(self) if self.plan then SearchItem(self.plan.item) end end)
    planButton:Hide()
    row.planButton = planButton

    local block = CreateFrame("Button", nil, row)
    block:SetSize(18, 18)
    block:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    block.texture = block:CreateTexture(nil, "ARTWORK")
    block.texture:SetAllPoints()
    block:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    block:SetScript("OnClick", function()
      if row.result then
        GameTooltip:Hide()
        ToggleBlocked(row.result.recipe)
      end
    end)
    block:SetScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      if row.result and row.result.blocked then
        GameTooltip:AddLine("Unblock craft")
      else
        GameTooltip:AddLine("Block craft")
        GameTooltip:AddLine("Hides it from the list and recommendations.", 0.8, 0.8, 0.8, true)
        GameTooltip:AddLine("Tick Show Blocked to bring it back.", 0.8, 0.8, 0.8, true)
      end
      GameTooltip:Show()
    end)
    block:SetScript("OnLeave", function() GameTooltip:Hide() end)
    row.block = block
  end

  row:SetScript("OnEnter", ShowRowTooltip)
  row:SetScript("OnLeave", function() GameTooltip:Hide() end)
  row.selected = row:CreateTexture(nil, "BACKGROUND", nil, 1)
  row.selected:SetAllPoints()
  row.selected:SetColorTexture(0.2, 1, 0.2, 0.12)
  row.selected:Hide()

  row:SetScript("OnClick", function(self, button)
    if button == "LeftButton" and self.result and view.mode == "snipe" then
      -- Shift-click buys one right away once the item's listings are loaded; otherwise it
      -- selects the item (the game needs a fresh click for the buy itself).
      if IsShiftKeyDown() and buy and buy.itemID == self.result.itemID and buy.state ~= "loading" then
        BuyNext()
      else
        SelectSnipe(self.result)
        if IsShiftKeyDown() then Print("Loading listings - shift-click again to buy.") end
      end
      return
    end
    if button == "RightButton" and IsShiftKeyDown() and self.result and view.mode == "shuffle" then
      GameTooltip:Hide()
      RemoveRecipe(self.result.recipe)
    end
  end)

  view.rows[index] = row
  return row
end

-- Positions header and row cells; the first column stretches to fill the width.
local function LayoutView(view)
  local width = view.frame:GetWidth() - SCROLLBAR_SPACE
  if width <= 0 then return end
  local craft = view.mode ~= "shuffle" -- crafts and vendor shuffles share the craft row layout
  local columnsWidth = width - (craft and BLOCK_SPACE or 0)
  local nameWidth = math.max(craft and 150 or 150, columnsWidth - view.fixedWidth)
  local function Place(cells, leftPad, rightPad)
    local x = 0
    for _, col in ipairs(view.columns) do
      local w = col.width or nameWidth
      local fs = cells[col.key]
      fs:ClearAllPoints()
      if col.key == "name" then
        fs:SetPoint("LEFT", x + leftPad, 0)
        fs:SetWidth(math.max(20, w - leftPad - rightPad - 6))
      elseif col.recipe or col.nosort then
        fs:SetPoint("LEFT", x, 0)
        fs:SetWidth(w)
      else
        fs:SetPoint("LEFT", x, 0)
        fs:SetWidth(w - 8)
      end
      x = x + w
    end
  end
  Place(view.headerCells, 6, 0)
  for _, row in ipairs(view.rows) do
    if craft and row.result and row:IsShown() then
      local left, right = PlaceCraftIcons(row, nameWidth)
      Place(row.cells, left, right)
    else
      Place(row.cells, row.iconWidth + 6, 0)
    end
  end
  view.content:SetWidth(width)
end

local function UpdateHeaders(view)
  local sort = SortState(view)
  for _, col in ipairs(view.columns) do
    local button = view.headerButtons[col.key]
    if col.key == sort.key then
      button.arrow:Show()
      if sort.desc then button.arrow:SetTexCoord(0, 0.5625, 0, 1) else button.arrow:SetTexCoord(0, 0.5625, 1, 0) end
      view.headerCells[col.key]:SetTextColor(1, 1, 1)
    else
      button.arrow:Hide()
      view.headerCells[col.key]:SetTextColor(1, 0.82, 0)
    end
  end
end

local BANNER_ICON = 34
local BANNER_REWARD_WIDTH = 230 -- space kept clear on the right for the big profit text

local function UpdateBanner(view, best)
  local banner = view.banner
  for _, button in ipairs(banner.icons) do button:Hide() end
  banner.arrow:Hide()
  local craft = view.mode == "craft"
  local vendor = view.mode == "vendor"

  if view.mode == "snipe" and best then
    local x = PlaceRecipeIcons(banner.icons, banner.arrow, banner, best.recipe, 8, -24, BANNER_ICON, "TOPLEFT")
    banner.arrow:Hide() -- no inputs: just the item
    banner.name:ClearAllPoints()
    banner.name:SetPoint("TOPLEFT", banner, "TOPLEFT", x + 10 - 14, -26)
    banner.name:SetPoint("RIGHT", banner, "RIGHT", -BANNER_REWARD_WIDTH, 0)
    banner.detail:SetPoint("RIGHT", banner, "RIGHT", -BANNER_REWARD_WIDTH, 0)
    banner.name:SetText((ItemName(best.itemID) or ("item:" .. best.itemID)) .. "  |cff8a8a8a" ..
      (best.method == "Disenchant" and "disenchant" or "vendor") .. "|r")
    banner.detail:SetText(string.format("|cffb0b0b0%s at profit  ·  cheapest %s  ·  worth %s each|r",
      Number(best.atProfit), Money(best.lowest), Money(best.value)))
    banner.profit:SetText("|cff3cff3c+|r" .. Money(best.profit))
    banner.margin:SetText(string.format("|cff3cff3c%+.0f%% on the cheapest|r", best.margin))
    banner.coin:Show()
    return
  end

  if not best then
    if view.mode == "snipe" then
      banner.name:SetText("|cff8a8a8aNo snipes yet|r")
      banner.detail:SetText("|cff8a8a8aRun a full scan to find auctions selling under their vendor or disenchant value.|r")
      banner.profit:SetText("")
      banner.margin:SetText("")
      banner.coin:Hide()
      banner.name:ClearAllPoints()
      banner.name:SetPoint("TOPLEFT", banner, "TOPLEFT", 8, -26)
      banner.name:SetPoint("RIGHT", banner, "RIGHT", -12, 0)
      banner.detail:SetPoint("RIGHT", banner, "RIGHT", -12, 0)
      return
    end
    banner.name:SetText(craft and "|cff8a8a8aNo reliable, profitable craft yet|r" or vendor and
      "|cff8a8a8aNo profitable vendor shuffle yet|r" or "|cff8a8a8aNo stable, profitable shuffle yet|r")
    if vendor then
      banner.detail:SetText(string.format("|cff8a8a8aNeeds a profit after buying the mats, and every mat scanned with enough listed for %d+ crafts.|r",
        VENDOR_MIN_CRAFTS))
    elseif craft then
      banner.detail:SetText(string.format("|cff8a8a8aNeeds a profit, %d+ listed, under %d%% price swing, and for gear %d+ seen selling over %d days of scans.|r",
        MIN_LISTINGS, STABLE_MAX_SWING * 100, EQUIP_MIN_SOLD, HISTORY_DAYS))
    else
      banner.detail:SetText(string.format("|cff8a8a8aNeeds a profit, %d+ of every item listed, and under %d%% price swing over %d days of scans.|r",
        STABLE_MIN_VOLUME, STABLE_MAX_SWING * 100, HISTORY_DAYS))
    end
    banner.profit:SetText("")
    banner.margin:SetText("")
    banner.coin:Hide()
    banner.name:ClearAllPoints()
    banner.name:SetPoint("TOPLEFT", banner, "TOPLEFT", 8, -26)
    banner.name:SetPoint("RIGHT", banner, "RIGHT", -12, 0)
    banner.detail:SetPoint("RIGHT", banner, "RIGHT", -12, 0)
    return
  end

  -- Input icons > output icons, each clickable to search the AH.
  local recipe = best.recipe
  local size = ((craft or vendor) and #recipe.inputs > 4) and 26 or BANNER_ICON
  local x = PlaceRecipeIcons(banner.icons, banner.arrow, banner, recipe, 8, -24 - (BANNER_ICON - size) / 2, size, "TOPLEFT")

  banner.name:ClearAllPoints()
  banner.name:SetPoint("TOPLEFT", banner, "TOPLEFT", x + 10, -26)
  banner.name:SetPoint("RIGHT", banner, "RIGHT", -BANNER_REWARD_WIDTH, 0)
  banner.detail:SetPoint("RIGHT", banner, "RIGHT", -BANNER_REWARD_WIDTH, 0)
  if vendor then
    banner.name:SetText(SideText(recipe.outputs))
    banner.detail:SetText(string.format("|cffb0b0b0mats %s  ·  %s %s  ·  %s profit per craft  ·  %.1fs each|r",
      Money(best.cost), best.kind == "disenchant" and "disenchants for" or "vendors for", Money(best.vendor),
      Money(best.profit), best.castTime or 0))
    -- Big green reward: gold per hour, with profit per craft underneath.
    banner.profit:SetText("|cff3cff3c+|r" .. Money(best.perHour) .. "|cff3cff3c/h|r")
    banner.margin:SetText(string.format("|cff3cff3c%+.0f%% margin|r", best.margin))
    banner.coin:Show()
    return
  elseif craft then
    banner.name:SetText(SideText(recipe.outputs))
    banner.detail:SetText(string.format("|cffb0b0b0%s listed  ·  %s%.0f%% swing  ·  mats %s, sells %s after cut|r",
      Number(best.listed), best.equipment and ((best.sold or 0) .. " sold in " .. HISTORY_DAYS .. "d  ·  ") or "",
      best.swing * 100, Money(best.cost), Money(best.revenue)))
  else
    banner.name:SetText(SideText(recipe.outputs) .. "  |cff8a8a8afrom " .. SideText(recipe.inputs) .. "|r")
    banner.detail:SetText(string.format("|cffb0b0b0%s+ listed of each item  ·  %.0f%% price swing  ·  buy %s, sell %s after cut|r",
      Number(best.volume), best.swing * 100, Money(best.cost), Money(best.revenue)))
  end

  -- Big green reward: profit per craft with the margin underneath.
  banner.profit:SetText("|cff3cff3c+|r" .. Money(best.profit))
  banner.margin:SetText(string.format("|cff3cff3c%+.0f%% margin|r", best.margin))
  banner.coin:Show()
end

local function CraftStatusText(counts, shown)
  local state = CraftState()
  local parts = { string.format("Showing %d of %d", shown, counts.total) }
  if counts.unscanned > 0 then table.insert(parts, counts.unscanned .. " not scanned") end
  if counts.low > 0 then table.insert(parts, counts.low .. " under " .. MIN_LISTINGS .. " listed") end
  if counts.unknown > 0 then table.insert(parts, counts.unknown .. " not known") end
  if counts.blocked > 0 then table.insert(parts, counts.blocked .. " blocked") end
  local text = "|cffb0b0b0" .. table.concat(parts, "  ·  ") .. "|r"
  if state.showKnown and counts.unknown == counts.total and counts.total > 0 and not HasKnownData() then
    text = "|cffff8040No known recipes found. Open your " .. (state.profession or "profession") ..
      " window once, or untick Show Known.|r"
  end
  return text
end

local function RefreshViewUnsafe(view)
  pendingItems = false
  UpdateHeaders(view)
  local craft = view.mode == "craft"
  local vendor = view.mode == "vendor"
  local snipe = view.mode == "snipe"

  local results, emptyText = {}, nil
  if snipe then
    for _, check in ipairs(view.checks) do check:SetChecked(check.get() and true or false) end
    local counts
    results, counts = SnipeResults()
    local snipes = AuctionatorShuffleDB.snipes
    if snipes then
      local minutes = math.floor((time() - snipes.time) / 60)
      local parts = { string.format("Full scan %s", minutes < 1 and "just now" or minutes < 120 and (minutes .. " min ago")
        or (math.floor(minutes / 60) .. " h ago")), #results .. " items at profit" }
      if counts.blocked > 0 then table.insert(parts, counts.blocked .. " blocked") end
      view.status:SetText((minutes >= 30 and "|cffff8040" or "|cffb0b0b0") .. table.concat(parts, "  ·  ") .. "|r")
      emptyText = "Nothing at profit in the last full scan. Prices move fast; scan again later."
    else
      view.status:SetText("|cffb0b0b0No full scan yet|r")
      emptyText = "Click Full scan (or Auctionator's Full Scan) to look for auctions worth more to a vendor or as enchanting mats."
    end
  elseif vendor then
    local profession, kind = VendorProfession()
    view.kind = kind
    UIDropDownMenu_SetText(view.dropdown, profession and (profession .. " (" .. kind .. ")") or "(none)")
    view.headerCells.vendor:SetText(kind == "disenchant" and "DE value" or "Sell price")
    view.headerCells.produces:SetText(kind == "disenchant" and "DE into" or "")
    view.hint:SetText(kind == "disenchant" and "Buy mats, craft, disenchant, sell the enchanting mats"
      or "Buy mats, craft, sell to a vendor (no AH cut)")
    for _, check in ipairs(view.checks) do check:SetChecked(check.get() and true or false) end
    if profession then
      local candidates, counts = VendorCandidates(profession, kind)
      local unpriced = 0
      for _, recipe in ipairs(candidates) do
        local result = EvaluateVendor(recipe, kind)
        table.insert(results, result)
        if not result.cost then unpriced = unpriced + 1 end
      end
      local parts = { string.format("Showing %d of %d", #results, counts.total) }
      if unpriced > 0 then table.insert(parts, unpriced .. " missing a price") end
      if counts.unknown > 0 then table.insert(parts, counts.unknown .. " not known") end
      if counts.blocked > 0 then table.insert(parts, counts.blocked .. " blocked") end
      view.status:SetText("|cffb0b0b0" .. table.concat(parts, "  ·  ") .. "|r")
    end
    emptyText = "Nothing to show. Untick Show Known, or tick Show Blocked."
  elseif craft then
    local state = CraftState()
    UIDropDownMenu_SetText(view.dropdown, state.profession or "(none)")
    for name, button in pairs(view.categoryButtons) do
      if name == state.category then button:LockHighlight() else button:UnlockHighlight() end
    end
    for _, check in ipairs(view.checks) do check:SetChecked(check.get() and true or false) end
    local counts
    results, counts = CraftResults()
    view.status:SetText(CraftStatusText(counts, #results))
    if counts.unscanned > 0 and #results == 0 then
      emptyText = "Click Scan to price these crafts (gear needs two scans, a few hours apart, to see what sells)."
    else
      emptyText = "Nothing to show. Try Low Listings or Show Blocked, or untick Show Known."
    end
  else
    local section = SelectedSection()
    UIDropDownMenu_SetText(view.dropdown, section and section.name or "(no profiles)")
    if section then
      for _, recipe in ipairs(section.recipes) do
        local result = EvaluateShuffle(recipe)
        result.castTime = ShuffleSeconds(recipe)
        if result.profit and result.castTime then
          result.perHour = math.floor(result.profit * 3600 / result.castTime)
        end
        table.insert(results, result)
      end
    end
    emptyText = section and ("No recipes in " .. section.name .. ". Add with /shuffle add " .. section.name .. " ...")
      or "No profiles. Add one with /shuffle add, or /shuffle reset."
  end

  SortResults(view, results)
  UpdateBanner(view, PickRecommended(results, vendor and "perHour" or "profit"))
  view.empty:SetShown(#results == 0)
  view.empty:SetText(emptyText)

  for i, result in ipairs(results) do
    local row = view.rows[i] or CreateRow(view, i)
    local recipe = result.recipe
    row.result = result

    row.selected:SetShown(snipe and buy ~= nil and buy.itemID == result.itemID)
    if snipe then
      row.iconWidth = 0
      row.cells.name:SetText(ItemName(result.itemID) or ("item:" .. result.itemID))
      row:SetAlpha(result.blocked and 0.45 or 1)
      row.block.texture:SetTexture(result.blocked and "Interface\\Buttons\\UI-CheckBox-Check" or "Interface\\Buttons\\UI-GroupLoot-Pass-Up")
      row.cells.method:SetText(result.method == "Disenchant" and "|cffb080ffDE|r" or "|cffffd100Vendor|r")
      row.cells.lowest:SetText(MoneyShort(result.lowest))
      row.cells.value:SetText(MoneyShort(result.value))
      row.cells.profitEach:SetText("|cff20ff20+|r" .. MoneyShort(result.profitEach))
      row.cells.atProfit:SetText("|cffffffff" .. Number(result.atProfit) .. "|r")
      row.cells.profit:SetText("|cff20ff20+|r" .. MoneyShort(result.profit))
      row.cells.perHour:SetText(result.perHour and ("|cff20ff20+|r" .. MoneyShort(result.perHour) .. "|cff20ff20/h|r") or "|cff6a6a6a-|r")
    elseif vendor then
      row.iconWidth = 0
      row.cells.name:SetText(SideText(recipe.outputs) .. "  |cff6a6a6a" .. (recipe.skill or "") .. "|r")
      row:SetAlpha(result.blocked and 0.45 or 1)
      row.block.texture:SetTexture(result.blocked and "Interface\\Buttons\\UI-CheckBox-Check" or "Interface\\Buttons\\UI-GroupLoot-Pass-Up")
      row.cells.vendor:SetText(result.vendor and MoneyShort(result.vendor) or "|cff8a8a8a...|r")
      row.cells.castTime:SetText(result.castTime and string.format("%.1fs", result.castTime) or "|cff8a8a8a?|r")
      if result.cost then
        local color = result.profit > 0 and "|cff20ff20" or (result.profit < 0 and "|cffff4040" or "|cffcccccc")
        row.cells.cost:SetText(MoneyShort(result.cost))
        row.cells.profit:SetText(color .. (result.profit > 0 and "+" or "") .. "|r" .. MoneyShort(result.profit))
        row.cells.perHour:SetText(result.perHour and (color .. (result.perHour > 0 and "+" or "") .. "|r" .. MoneyShort(result.perHour))
          or "|cff8a8a8a?|r")
        row.cells.age:SetText(AgeText(result.age))
      else
        row.cells.cost:SetText("|cff8a8a8ano price|r")
        row.cells.profit:SetText("")
        row.cells.perHour:SetText("")
        row.cells.age:SetText("|cff8a8a8ascan|r")
      end
    elseif craft then
      row.iconWidth = 0
      row.cells.name:SetText(SideText(recipe.outputs) .. "  |cff6a6a6a" .. (recipe.skill or "") .. "|r")
      row:SetAlpha(result.blocked and 0.45 or 1)
      row.block.texture:SetTexture(result.blocked and "Interface\\Buttons\\UI-CheckBox-Check" or "Interface\\Buttons\\UI-GroupLoot-Pass-Up")
      if result.listed == nil then
        row.cells.listed:SetText("|cff8a8a8a?|r")
      else
        row.cells.listed:SetText((result.listed < MIN_LISTINGS and "|cffff8040" or "|cffffffff") .. Number(result.listed) .. "|r")
      end
      if result.equipment then
        row.cells.sold:SetText(result.sold and ((result.sold > 0 and "|cff20ff20" or "|cff8a8a8a") .. result.sold .. "|r") or "|cff8a8a8a?|r")
      else
        row.cells.sold:SetText("|cff6a6a6a-|r")
      end
    else
      row.iconWidth = PlaceRecipeIcons(row.icons, row.arrow, row, recipe, 4, 0, ICON_SIZE, "LEFT")
      row.cells.name:SetText(SideText(recipe.outputs) .. "  |cff8a8a8afrom " .. SideText(recipe.inputs) .. "|r")
    end

    if vendor or snipe then
      -- These rows were filled above.
    elseif result.cost then
      local color = result.profit > 0 and "|cff20ff20" or (result.profit < 0 and "|cffff4040" or "|cffcccccc")
      local money = craft and MoneyShort or Money -- craft columns are narrower
      row.cells.cost:SetText(money(result.cost))
      row.cells.revenue:SetText(money(result.revenue))
      row.cells.profit:SetText(color .. (result.profit > 0 and "+" or "") .. "|r" .. money(result.profit))
      row.cells.margin:SetText(string.format("%s%+.0f%%|r", color, result.margin))
      row.cells.age:SetText(AgeText(result.age))
      if row.cells.perHour then
        row.cells.perHour:SetText(result.perHour and (color .. (result.perHour > 0 and "+" or "") .. "|r" .. money(result.perHour) .. color .. "/h|r")
          or "|cff8a8a8a-|r")
      end
    else
      row.cells.cost:SetText("|cff8a8a8ano price|r")
      row.cells.revenue:SetText("")
      row.cells.profit:SetText("")
      row.cells.margin:SetText("")
      row.cells.age:SetText("|cff8a8a8ascan|r")
      if row.cells.perHour then row.cells.perHour:SetText("") end
    end
    row:Show()
  end
  for i = #results + 1, #view.rows do
    view.rows[i]:Hide()
    view.rows[i].result = nil
  end
  view.content:SetHeight(math.max(1, #results * ROW_HEIGHT))
  LayoutView(view)
end

-- Any error shows up in chat and in the table instead of leaving it silently empty.
local function RefreshView(view)
  if not view.frame:IsVisible() then return end
  local ok, err = pcall(RefreshViewUnsafe, view)
  if not ok then
    Print("|cffff4040error:|r " .. tostring(err))
    view.empty:SetText("|cffff4040Error: " .. tostring(err) .. "|r")
    view.empty:Show()
  end
end

function RefreshAll()
  if UpdatePanels then UpdatePanels() end
  for _, view in ipairs(views) do RefreshView(view) end
end

local function CreateCheck(view, parent, x, y, label, tooltip, get, set)
  local check = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
  check:SetSize(24, 24)
  check:SetPoint("TOPLEFT", x, y)
  local fs = check:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  fs:SetPoint("LEFT", check, "RIGHT", 2, 1)
  fs:SetText(label)
  check:SetHitRectInsets(0, -(fs:GetStringWidth() + 6), 0, 0)
  check.get = get
  check:SetScript("OnClick", function(self)
    set(self:GetChecked() and true or false)
    RefreshAll()
  end)
  check:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine(label)
    GameTooltip:AddLine(tooltip, 0.8, 0.8, 0.8, true)
    GameTooltip:Show()
  end)
  check:SetScript("OnLeave", function() GameTooltip:Hide() end)
  table.insert(view.checks, check)
  return check
end

-- Shuffles toolbar: profile picker, scan, refresh.
-- Profile picker shared by the Shuffles tab's two tables: your profiles, then one
-- vendor shuffle per profession (buy mats, craft, sell to a vendor).
local function CreateProfileDropdown(view, parent)
  local dropdown = CreateFrame("Frame", "AuctionatorShuffleProfileDropDown" .. viewCount, parent, "UIDropDownMenuTemplate")
  dropdown:SetPoint("TOPLEFT", -10, -4)
  UIDropDownMenu_SetWidth(dropdown, 170)
  UIDropDownMenu_Initialize(dropdown, function()
    if not AuctionatorShuffleDB then return end -- saved data loads after this file runs
    local selectedProfession, selectedKind = VendorProfession()
    for _, section in ipairs(AuctionatorShuffleDB.sections) do
      local info = UIDropDownMenu_CreateInfo()
      info.text = section.name
      info.checked = not selectedProfession and SelectedSection() == section
      info.func = function()
        AuctionatorShuffleDB.selected = section.name
        RefreshAll()
      end
      UIDropDownMenu_AddButton(info)
    end
    for _, group in ipairs({ { "vendor", "Vendor shuffles" }, { "disenchant", "Disenchant shuffles" } }) do
      local kind = group[1]
      local title = UIDropDownMenu_CreateInfo()
      title.text = group[2]
      title.isTitle = true
      title.notCheckable = true
      UIDropDownMenu_AddButton(title)
      for _, profession in ipairs(professions) do
        local info = UIDropDownMenu_CreateInfo()
        info.text = profession .. " (" .. kind .. ")"
        info.checked = selectedProfession == profession and selectedKind == kind
        info.func = function()
          AuctionatorShuffleDB.selected = kind .. ":" .. profession
          RefreshAll()
        end
        UIDropDownMenu_AddButton(info)
      end
    end
  end)
  view.dropdown = dropdown
  return dropdown
end

local function CreateShuffleToolbar(view, parent)
  local dropdown = CreateProfileDropdown(view, parent)

  local scanButton = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  scanButton:SetSize(130, 24)
  scanButton:SetPoint("LEFT", dropdown, "RIGHT", -4, 2)
  scanButton:SetText("Scan profile")
  scanButton:SetScript("OnClick", function()
    local section = SelectedSection()
    if section then ScanRecipes(section.recipes, section.name) end
  end)
  scanButton:SetScript("OnUpdate", function(self)
    self:SetEnabled(AuctionHouseOpen())
    self:SetText(ScanProgressText() or "Scan profile")
  end)

  local refreshButton = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  refreshButton:SetSize(90, 24)
  refreshButton:SetPoint("LEFT", scanButton, "RIGHT", 6, 0)
  refreshButton:SetText("Refresh")
  refreshButton:SetScript("OnClick", function() RefreshView(view) end)

  local hint = parent:CreateFontString(nil, "OVERLAY", "GameFontDisable")
  hint:SetPoint("TOPRIGHT", -10, -12)
  hint:SetText("Hover a row for the breakdown  ·  /shuffle help")
end

-- Crafts toolbar: profession, Consumable/Equipment, scan; filters and status underneath.
local function CreateCraftToolbar(view, parent)
  local dropdown = CreateFrame("Frame", "AuctionatorShuffleProfessionDropDown" .. viewCount, parent, "UIDropDownMenuTemplate")
  dropdown:SetPoint("TOPLEFT", -10, -4)
  UIDropDownMenu_SetWidth(dropdown, 130)
  UIDropDownMenu_Initialize(dropdown, function()
    if not AuctionatorShuffleDB then return end
    for _, profession in ipairs(professions) do
      local info = UIDropDownMenu_CreateInfo()
      info.text = profession
      info.checked = CraftState().profession == profession
      info.func = function()
        CraftState().profession = profession
        RefreshAll()
      end
      UIDropDownMenu_AddButton(info)
    end
  end)
  view.dropdown = dropdown

  view.categoryButtons = {}
  local previous, gap = dropdown, -4
  for _, category in ipairs(CATEGORIES) do
    local button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    button:SetSize(110, 24)
    button:SetPoint("LEFT", previous, "RIGHT", gap, previous == dropdown and 2 or 0)
    button:SetText(category)
    button:SetScript("OnClick", function()
      CraftState().category = category
      RefreshAll()
    end)
    view.categoryButtons[category] = button
    previous, gap = button, 4
  end

  local scanButton = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  scanButton:SetSize(130, 24)
  scanButton:SetPoint("LEFT", previous, "RIGHT", 14, 0)
  scanButton:SetScript("OnClick", function()
    local state = CraftState()
    local candidates, counts = CraftCandidates()
    local reason = string.format("(%d recipes: %d hidden as not known, %d blocked.)", counts.total, counts.unknown, counts.blocked)
    if counts.total == 0 then
      reason = "(No recipe data loaded - restart the game client fully; /reload doesn't load new addon files.)"
    elseif counts.unknown > 0 and not HasKnownData() then
      reason = reason .. " Open your " .. (state.profession or "profession") .. " window once, or untick Show Known."
    end
    -- Also price the plans of crafts you don't know yet (soulbound plans can't be listed).
    local toScan = {}
    for _, recipe in ipairs(candidates) do
      table.insert(toScan, recipe)
      local plan = not IsKnown(recipe) and PlanFor(recipe)
      if plan and not IsSoulbound(plan.item) then table.insert(toScan, { inputs = {}, outputs = { { plan.item, 1 } } }) end
    end
    ScanRecipes(toScan, (state.profession or "Crafts") .. " " .. state.category, reason)
  end)
  scanButton:SetScript("OnUpdate", function(self)
    self:SetEnabled(AuctionHouseOpen())
    self:SetText(ScanProgressText() or ("Scan " .. CraftState().category))
  end)
  scanButton:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine("Scan " .. CraftState().category)
    GameTooltip:AddLine("Reads every listing of each made item and its materials. Tick Show Known first to scan only your recipes (much faster).",
      0.8, 0.8, 0.8, true)
    GameTooltip:AddLine("Gear: scan again a few hours later to see which pieces actually sell.", 0.8, 0.8, 0.8, true)
    GameTooltip:Show()
  end)
  scanButton:SetScript("OnLeave", function() GameTooltip:Hide() end)

  view.checks = {}
  local function Toggle(key) return function() return CraftState()[key] end, function(value) CraftState()[key] = value end end
  local getKnown, setKnown = Toggle("showKnown")
  CreateCheck(view, parent, 8, -32, "Show Known", "Only show recipes this character knows. Open your profession window once to load them.",
    getKnown, setKnown)
  local getLow, setLow = Toggle("lowListings")
  CreateCheck(view, parent, 128, -32, "Low Listings", "Also show crafts whose item has fewer than " .. MIN_LISTINGS ..
    " listed (or hasn't been scanned yet). These are hard to sell and easy to misprice.", getLow, setLow)
  local getBlocked, setBlocked = Toggle("showBlocked")
  CreateCheck(view, parent, 250, -32, "Show Blocked", "Show crafts you blocked (dimmed) so you can unblock them.", getBlocked, setBlocked)

  view.status = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  view.status:SetPoint("TOPLEFT", parent, "TOPLEFT", 380, -38)
  view.status:SetPoint("RIGHT", parent, "RIGHT", -10, 0)
  view.status:SetJustifyH("RIGHT")
  view.status:SetWordWrap(false)
end

-- Vendor shuffle toolbar: profile picker, scan mats; filters and status underneath.
local function CreateVendorToolbar(view, parent)
  local dropdown = CreateProfileDropdown(view, parent)

  local scanButton = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  scanButton:SetSize(130, 24)
  scanButton:SetPoint("LEFT", dropdown, "RIGHT", -4, 2)
  scanButton:SetScript("OnClick", function()
    local profession, kind = VendorProfession()
    if not profession then return end
    -- Only the materials matter: the made item goes to a vendor or gets disenchanted.
    local toScan = {}
    if kind == "disenchant" then
      local mats = {}
      for _, itemID in ipairs(DISENCHANT_MATS) do table.insert(mats, { itemID, 1 }) end
      table.insert(toScan, { inputs = mats, outputs = {} })
    end
    for _, recipe in ipairs((VendorCandidates(profession, kind))) do
      table.insert(toScan, { inputs = recipe.inputs, outputs = {} })
      local plan = not IsKnown(recipe) and PlanFor(recipe)
      if plan and not IsSoulbound(plan.item) then table.insert(toScan, { inputs = {}, outputs = { { plan.item, 1 } } }) end
    end
    ScanRecipes(toScan, profession .. (kind == "disenchant" and " materials and enchanting mats" or " materials"))
  end)
  scanButton:SetScript("OnUpdate", function(self)
    self:SetEnabled(AuctionHouseOpen())
    self:SetText(ScanProgressText() or "Scan mats")
  end)
  scanButton:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine("Scan mats")
    GameTooltip:AddLine("Prices the materials (and unknown recipes) of every craft shown. Tick Show Known first to scan only your recipes.",
      0.8, 0.8, 0.8, true)
    GameTooltip:AddLine("Disenchant shuffles also price every dust, essence, shard and Nexus Crystal.", 0.8, 0.8, 0.8, true)
    GameTooltip:Show()
  end)
  scanButton:SetScript("OnLeave", function() GameTooltip:Hide() end)

  local hint = parent:CreateFontString(nil, "OVERLAY", "GameFontDisable")
  hint:SetPoint("TOPRIGHT", -10, -12)
  hint:SetText("Buy mats, craft, sell to a vendor (no AH cut)")
  view.hint = hint

  view.checks = {}
  local function Toggle(key) return function() return VendorState()[key] end, function(value) VendorState()[key] = value end end
  local getKnown, setKnown = Toggle("showKnown")
  CreateCheck(view, parent, 8, -32, "Show Known", "Only show recipes this character knows.", getKnown, setKnown)
  local getBlocked, setBlocked = Toggle("showBlocked")
  CreateCheck(view, parent, 128, -32, "Show Blocked", "Show crafts you blocked (dimmed) so you can unblock them.", getBlocked, setBlocked)

  view.status = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  view.status:SetPoint("TOPLEFT", parent, "TOPLEFT", 260, -38)
  view.status:SetPoint("RIGHT", parent, "RIGHT", -10, 0)
  view.status:SetJustifyH("RIGHT")
  view.status:SetWordWrap(false)
end

-- Snipe toolbar: full scan button; method filters and status underneath.
local function CreateSnipeToolbar(view, parent)
  local scanButton = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  scanButton:SetSize(150, 24)
  scanButton:SetPoint("TOPLEFT", 6, -4)
  scanButton:SetScript("OnClick", StartFullScan)
  scanButton:SetScript("OnUpdate", function(self)
    local frame = Auctionator.State and Auctionator.State.FullScanFrameRef
    self:SetEnabled(AuctionHouseOpen() and not snipeProcessing and not (frame and frame.inProgress))
    if snipeProcessing then
      self:SetText(string.format("Checking %d%%", snipeProcessing.done * 100 / math.max(1, snipeProcessing.total)))
    elseif frame and frame.inProgress then
      self:SetText("Full scan running...")
    else
      self:SetText("Full scan")
    end
  end)
  scanButton:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine("Full scan")
    GameTooltip:AddLine("Runs Auctionator's full auction house scan, then checks every auction against its vendor price and expected disenchant value.",
      0.8, 0.8, 0.8, true)
    GameTooltip:AddLine("The game allows one full scan every 15 minutes. Auctionator's own Full Scan button fills this tab too.",
      0.8, 0.8, 0.8, true)
    GameTooltip:Show()
  end)
  scanButton:SetScript("OnLeave", function() GameTooltip:Hide() end)

  -- Buy next: one purchase per click. Shift + mouse wheel presses it while this tab is open.
  local buttonName = "AuctionatorShuffleBuyNextButton" .. viewCount -- bindings click buttons by name
  local buyButton = CreateFrame("Button", buttonName, parent, "UIPanelButtonTemplate")
  buyButton:SetSize(330, 24)
  buyButton:SetPoint("LEFT", scanButton, "RIGHT", 8, 0)
  buyButton:RegisterForClicks("AnyUp")
  buyButton:SetScript("OnClick", BuyNext)
  buyButton:SetScript("OnUpdate", function(self)
    local text, enabled = BuyButtonText()
    self:SetText(text)
    self:SetEnabled(enabled and AuctionHouseOpen())
  end)
  buyButton:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine("Buy next")
    GameTooltip:AddLine("Click a row to pick an item, then each press buys the cheapest listing still under its worth - no popup.",
      0.8, 0.8, 0.8, true)
    GameTooltip:AddLine("Shift + mouse wheel presses this button while the Snipe tab is open.", 0.2, 1, 0.2, true)
    GameTooltip:AddLine("Stacks (dust, cloth...) take two presses: one to get the price, one to confirm.", 0.8, 0.8, 0.8, true)
    if buy and buy.bought then
      GameTooltip:AddLine(" ")
      GameTooltip:AddDoubleLine("Bought so far", string.format("%d (+%s)", buy.bought, Money(buy.profit or 0)), 1, 0.82, 0, 1, 1, 1)
    end
    GameTooltip:Show()
  end)
  buyButton:SetScript("OnLeave", function() GameTooltip:Hide() end)
  if buttonName then
    -- Bind Shift + wheel to the button only while the tab is visible, so it never hijacks scrolling elsewhere.
    parent:HookScript("OnShow", function()
      if InCombatLockdown() then return end
      SetOverrideBindingClick(buyButton, true, "SHIFT-MOUSEWHEELUP", buttonName, "LeftButton")
      SetOverrideBindingClick(buyButton, true, "SHIFT-MOUSEWHEELDOWN", buttonName, "LeftButton")
    end)
    parent:HookScript("OnHide", function()
      if not InCombatLockdown() then ClearOverrideBindings(buyButton) end
    end)
  end

  -- Scan mats: prices only the enchanting materials (quick), without a full scan.
  local matsButton = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  matsButton:SetSize(120, 24)
  matsButton:SetPoint("LEFT", buyButton, "RIGHT", 8, 0)
  matsButton:SetScript("OnClick", function()
    local mats = {}
    for _, itemID in ipairs(DISENCHANT_MATS) do table.insert(mats, { itemID, 1 }) end
    ScanRecipes({ { inputs = mats, outputs = {} } }, "enchanting materials")
  end)
  matsButton:SetScript("OnUpdate", function(self)
    self:SetEnabled(AuctionHouseOpen() and not snipeProcessing)
    self:SetText(ScanProgressText() or "Scan mats")
  end)
  matsButton:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine("Scan mats")
    GameTooltip:AddLine("Prices every dust, essence, shard and Nexus Crystal (" .. #DISENCHANT_MATS ..
      " items) at the 50-deep price. Quick, and no 15-minute wait like a full scan.", 0.8, 0.8, 0.8, true)
    GameTooltip:AddLine("Disenchant values update straight away; a full scan is still needed to find new snipes.", 0.8, 0.8, 0.8, true)
    GameTooltip:AddLine("Click again while it runs to cancel.", 0.8, 0.8, 0.8, true)
    GameTooltip:Show()
  end)
  matsButton:SetScript("OnLeave", function() GameTooltip:Hide() end)

  -- Rescans only the items listed on the Snipe tab right now, so their listings and
  -- profit are current without waiting for the next full scan.
  local rescanButton = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  rescanButton:SetSize(110, 24)
  rescanButton:SetPoint("LEFT", matsButton, "RIGHT", 8, 0)
  rescanButton:SetScript("OnClick", function()
    if not AuctionatorShuffleDB.snipes then
      Print("Run a full scan first - there's no snipe list to rescan yet.")
      return
    end
    local items = {}
    for _, result in ipairs((SnipeResults())) do table.insert(items, { result.itemID, 1 }) end
    ScanRecipes({ { inputs = items, outputs = {} } }, "the snipe list", "Nothing is listed at a profit.", "snipe")
  end)
  rescanButton:SetScript("OnUpdate", function(self)
    self:SetEnabled(AuctionHouseOpen() and not snipeProcessing)
    self:SetText(ScanProgressText("snipe") or "Rescan list")
  end)
  rescanButton:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine("Rescan list")
    GameTooltip:AddLine("Checks the current listings of every item shown below: sold or relisted ones update, and items with nothing left under their worth drop off.", 0.8, 0.8, 0.8, true)
    GameTooltip:AddLine("Click again while it runs to cancel.", 0.8, 0.8, 0.8, true)
    GameTooltip:Show()
  end)
  rescanButton:SetScript("OnLeave", function() GameTooltip:Hide() end)

  view.checks = {}
  local function Toggle(key) return function() return SnipeState()[key] end, function(value) SnipeState()[key] = value end end
  local getDE, setDE = Toggle("showDisenchant")
  CreateCheck(view, parent, 8, -32, "Disenchant", "Show items worth more as enchanting mats (expected value after the 5% AH cut).",
    getDE, setDE)
  local getVendor, setVendor = Toggle("showVendor")
  CreateCheck(view, parent, 118, -32, "Vendor", "Show items a vendor pays more for than they cost.", getVendor, setVendor)
  local getBlocked, setBlocked = Toggle("showBlocked")
  CreateCheck(view, parent, 210, -32, "Show Blocked", "Show items you blocked (dimmed) so you can unblock them.", getBlocked, setBlocked)

  view.status = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  view.status:SetPoint("TOPLEFT", parent, "TOPLEFT", 340, -38)
  view.status:SetPoint("RIGHT", parent, "RIGHT", -10, 0)
  view.status:SetJustifyH("RIGHT")
  view.status:SetWordWrap(false)
end

local function CreateView(parent, mode)
  viewCount = viewCount + 1
  local view = { frame = parent, mode = mode, rows = {}, headerCells = {}, headerButtons = {}, checks = {} }
  view.columns = mode == "craft" and CRAFT_COLUMNS or mode == "vendor" and VENDOR_COLUMNS or mode == "snipe" and SNIPE_COLUMNS
    or SHUFFLE_COLUMNS
  view.fixedWidth = FixedWidth(view.columns)
  local top = mode ~= "shuffle" and 26 or 0 -- crafts and vendor shuffles have a second toolbar line

  -- Solid backdrop so the auction house art behind the tab doesn't show through.
  local bg = parent:CreateTexture(nil, "BACKGROUND", nil, -8)
  bg:SetAllPoints()
  bg:SetColorTexture(0.05, 0.05, 0.05, 0.92)

  if mode == "craft" then
    CreateCraftToolbar(view, parent)
  elseif mode == "vendor" then
    CreateVendorToolbar(view, parent)
  elseif mode == "snipe" then
    CreateSnipeToolbar(view, parent)
  else
    CreateShuffleToolbar(view, parent)
  end

  -- Recommendation banner: most profitable result that passes the stability rules.
  local banner = CreateFrame("Frame", nil, parent)
  banner:SetPoint("TOPLEFT", 6, -38 - top)
  banner:SetPoint("RIGHT", parent, "RIGHT", -SCROLLBAR_SPACE, 0)
  banner:SetHeight(72)
  banner.icons = {}
  local bannerBg = banner:CreateTexture(nil, "BACKGROUND")
  bannerBg:SetAllPoints()
  bannerBg:SetColorTexture(1, 0.82, 0, 0.07)
  for _, point in ipairs({ "TOP", "BOTTOM" }) do
    local line = banner:CreateTexture(nil, "ARTWORK")
    line:SetPoint(point .. "LEFT")
    line:SetPoint(point .. "RIGHT")
    line:SetHeight(1)
    line:SetColorTexture(1, 0.82, 0, 0.4)
  end
  banner.title = banner:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  banner.title:SetPoint("TOPLEFT", 8, -6)
  banner.title:SetText(mode == "craft" and "Recommended Craft" or mode == "vendor" and "Recommended Vendor Shuffle"
    or mode == "snipe" and "Best Snipe" or "Recommended Shuffle")
  banner.arrow = banner:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  banner.arrow:SetText(">")
  banner.name = banner:CreateFontString(nil, "OVERLAY", "GameFontHighlightMedium")
  banner.name:SetJustifyH("LEFT")
  banner.detail = banner:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  banner.detail:SetPoint("TOPLEFT", banner.name, "BOTTOMLEFT", 0, -4)
  banner.detail:SetJustifyH("LEFT")
  banner.detail:SetWordWrap(false)
  banner.name:SetWordWrap(false)

  -- Reward block on the right: coin, big profit, margin underneath.
  banner.profit = banner:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
  banner.profit:SetPoint("TOPRIGHT", banner, "TOPRIGHT", -14, -10)
  banner.profit:SetShadowOffset(2, -2)
  banner.margin = banner:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  banner.margin:SetPoint("TOPRIGHT", banner, "TOPRIGHT", -14, -42)
  banner.margin:SetShadowOffset(1, -1)
  banner.coin = banner:CreateTexture(nil, "ARTWORK")
  banner.coin:SetTexture("Interface\\Icons\\INV_Misc_Coin_02")
  banner.coin:SetTexCoord(0.07, 0.93, 0.07, 0.93)
  banner.coin:SetSize(30, 30)
  banner.coin:SetPoint("RIGHT", banner.profit, "LEFT", -8, 0)
  banner.coin:Hide()
  view.banner = banner

  -- Sortable column headers.
  local header = CreateFrame("Frame", nil, parent)
  header:SetPoint("TOPLEFT", 6, -116 - top)
  header:SetPoint("RIGHT", parent, "RIGHT", -SCROLLBAR_SPACE, 0)
  header:SetHeight(22)
  local headerLine = header:CreateTexture(nil, "ARTWORK")
  headerLine:SetPoint("BOTTOMLEFT")
  headerLine:SetPoint("BOTTOMRIGHT")
  headerLine:SetHeight(1)
  headerLine:SetColorTexture(1, 0.82, 0, 0.35)

  for _, col in ipairs(view.columns) do
    local button = CreateFrame("Button", nil, header)
    local fs = button:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    fs:SetJustifyH(col.justify)
    fs:SetText(col.title)
    view.headerCells[col.key] = fs
    button:SetAllPoints(fs)
    local arrow = button:CreateTexture(nil, "OVERLAY")
    arrow:SetTexture("Interface\\Buttons\\UI-SortArrow")
    arrow:SetSize(9, 8)
    -- Arrow sits just outside the text: left of right-aligned titles, right of left-aligned ones.
    if col.justify == "RIGHT" then
      arrow:SetPoint("RIGHT", fs, "RIGHT", -(fs:GetStringWidth() + 4), 0)
    else
      arrow:SetPoint("LEFT", fs, "LEFT", fs:GetStringWidth() + 4, 0)
    end
    button.arrow = arrow
    button:SetScript("OnClick", function()
      if col.recipe or col.nosort then return end -- icons only, nothing to sort by
      local sort = SortState(view)
      if sort.key == col.key then
        sort.desc = not sort.desc
      else
        sort.key = col.key
        sort.desc = col.defaultDesc
      end
      RefreshAll()
    end)
    button:SetScript("OnEnter", function() fs:SetTextColor(1, 1, 1) end)
    button:SetScript("OnLeave", function() UpdateHeaders(view) end)
    view.headerButtons[col.key] = button
  end
  -- Header cells live in the header frame but are placed by LayoutView like row cells.
  for _, fs in pairs(view.headerCells) do fs:SetParent(header) end

  local scroll = CreateFrame("ScrollFrame", "AuctionatorShuffleScroll" .. viewCount, parent, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", 6, -140 - top)
  scroll:SetPoint("BOTTOMRIGHT", -SCROLLBAR_SPACE, 6)
  view.content = CreateFrame("Frame", nil, scroll)
  view.content:SetSize(600, 1)
  scroll:SetScrollChild(view.content)

  view.empty = view.content:CreateFontString(nil, "OVERLAY", "GameFontDisable")
  view.empty:SetPoint("TOPLEFT", 8, -10)
  view.empty:Hide()

  parent:HookScript("OnShow", function() RefreshView(view) end)
  parent:HookScript("OnSizeChanged", function() LayoutView(view) end)
  table.insert(views, view)
  return view
end

-- Called from AuctionatorShuffle.xml when Auctionator creates a tab's frame.
-- The Shuffles tab holds two tables on top of each other: your profiles, and the vendor
-- shuffles. The profile picker decides which one shows.
local shufflePanels = {}
function UpdatePanels()
  local vendor = VendorProfession() ~= nil
  for _, panel in ipairs(shufflePanels) do
    panel.shuffle:SetShown(not vendor)
    panel.vendor:SetShown(vendor)
  end
end

local function CreateShufflePanel(parent)
  local shuffleBody = CreateFrame("Frame", nil, parent)
  shuffleBody:SetAllPoints()
  local vendorBody = CreateFrame("Frame", nil, parent)
  vendorBody:SetAllPoints()
  vendorBody:Hide()
  CreateView(shuffleBody, "shuffle")
  CreateView(vendorBody, "vendor")
  table.insert(shufflePanels, { shuffle = shuffleBody, vendor = vendorBody })
  parent:HookScript("OnShow", UpdatePanels)
end

local function BuildPanel(frame, mode)
  if mode == "craft" or mode == "snipe" then CreateView(frame, mode) else CreateShufflePanel(frame) end
end

-- Called from AuctionatorShuffle.xml when Auctionator creates a tab's frame.
function AuctionatorShuffle_BuildTab(frame, mode)
  BuildPanel(frame, mode or "shuffle")
end

Auctionator.Tabs.Register({
  name = "Shuffles",
  textLabel = "Shuffles",
  tabTemplate = "AuctionatorShuffleTabTemplate",
  tabHeader = "Shuffles",
  tabFrameName = "AuctionatorShuffleTabFrame",
  tabOrder = 5,
})

Auctionator.Tabs.Register({
  name = "Crafts",
  textLabel = "Crafts",
  tabTemplate = "AuctionatorShuffleCraftTabTemplate",
  tabHeader = "Crafts",
  tabFrameName = "AuctionatorShuffleCraftTabFrame",
  tabOrder = 6,
})

Auctionator.Tabs.Register({
  name = "Snipe",
  textLabel = "Snipe",
  tabTemplate = "AuctionatorShuffleSnipeTabTemplate",
  tabHeader = "Snipe",
  tabFrameName = "AuctionatorShuffleSnipeTabFrame",
  tabOrder = 7,
})

-- Widen the auction house window so it reaches past the last added tab (Snipe), which
-- otherwise sticks out beyond its right edge. Only ever grows from its normal width.
do
  local baseWidth
  local function WidenAuctionHouse()
    local lib = LibStub and LibStub("LibAHTab-1-0", true)
    local tabs = lib and lib.internalState and lib.internalState.Tabs
    local last = tabs and tabs[#tabs]
    local frame = AuctionHouseFrame
    if not (frame and last and last:GetRight() and frame:GetRight()) or InCombatLockdown() then return end
    baseWidth = baseWidth or frame:GetWidth()
    local width = frame:GetWidth() + (last:GetRight() - frame:GetRight()) + 6
    frame:SetWidth(math.max(baseWidth, width))
  end
  local widener = CreateFrame("Frame")
  widener:RegisterEvent("AUCTION_HOUSE_SHOW")
  widener:SetScript("OnEvent", function() C_Timer.After(0, WidenAuctionHouse) end)
end

-- Standalone windows for checking margins away from the auction house.
local function CreateWindow(name, title, width, height, mode)
  local window = CreateFrame("Frame", name, UIParent, "BasicFrameTemplateWithInset")
  window:SetSize(width, height)
  window:SetPoint("CENTER")
  window:SetMovable(true)
  window:EnableMouse(true)
  window:RegisterForDrag("LeftButton")
  window:SetScript("OnDragStart", window.StartMoving)
  window:SetScript("OnDragStop", window.StopMovingOrSizing)
  window:SetClampedToScreen(true)
  window:SetFrameStrata("HIGH")
  window:Hide()
  tinsert(UISpecialFrames, name)
  window.TitleText = window.TitleText or window:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  window.TitleText:SetPoint("TOP", 0, -5)
  window.TitleText:SetText(title)
  local body = CreateFrame("Frame", nil, window)
  body:SetPoint("TOPLEFT", 8, -26)
  body:SetPoint("BOTTOMRIGHT", -6, 8)
  BuildPanel(body, mode)
  return window
end

local shuffleWindow = CreateWindow("AuctionatorShuffleFrame", "Shuffles", 820, 500, "shuffle")
local craftWindow = CreateWindow("AuctionatorShuffleCraftFrame", "Crafts", 900, 560, "craft")
local snipeWindow = CreateWindow("AuctionatorShuffleSnipeFrame", "Snipe", 860, 520, "snipe")

do -- commands and disenchant wheel
---------------------------------------------------------------------------
-- Commands
---------------------------------------------------------------------------

-- "2 [Copper Bar] + [Tin Bar]" -> { {2840, 2}, {3576, 1} }
local function ParseSide(text)
  local side = {}
  for part in text:gmatch("[^+]+") do
    local id = part:match("item:(%d+)")
    if not id then return nil end
    local qty = tonumber(part:match("^%s*(%d+)")) or 1
    table.insert(side, { tonumber(id), qty })
  end
  return #side > 0 and side or nil
end

---------------------------------------------------------------------------
-- Disenchant wheel: a hidden secure button whose macro is rewritten right before
-- every press to target the next whitelisted item in your bags, so any number of
-- different items fit (a normal macro is limited to 255 characters).
---------------------------------------------------------------------------

local SHUFFLE_MACRO = "Shuffle"
local WHEEL_BUTTON = "AuctionatorShuffleWheelButton"
local wheelEmptyWarned = false

-- itemID, locked, bound, link of a bag slot.
local function ContainerItem(bag, slot)
  if C_Container and C_Container.GetContainerItemInfo then
    local info = C_Container.GetContainerItemInfo(bag, slot)
    if not info then return nil end
    return info.itemID, info.isLocked, info.isBound, info.hyperlink
  end
  local _, _, locked, _, _, _, link, _, _, itemID, bound = GetContainerItemInfo(bag, slot)
  return itemID, locked, bound, link
end


local function NumSlots(bag)
  if C_Container and C_Container.GetContainerNumSlots then return C_Container.GetContainerNumSlots(bag) end
  return GetContainerNumSlots(bag)
end

-- Next whitelisted item in the bags, as bag, slot, itemID (or nil). Normally the first one;
-- after the game refused an item, the first one after it (wrapping round), so a stubborn
-- item can't block the rest and still gets tried again.
local function NextDisenchantTarget(after)
  local list = Whitelist()
  local first, afterMatch, passed = nil, nil, after == nil
  for bag = 0, NUM_BAG_SLOTS or 4 do
    for slot = 1, NumSlots(bag) or 0 do
      local itemID, locked = ContainerItem(bag, slot)
      if itemID and not locked and list[itemID] and DisenchantOutcomes(itemID) then
        first = first or { bag, slot, itemID }
        if passed and not afterMatch then afterMatch = { bag, slot, itemID } end
      end
      if after and bag == after.bag and slot == after.slot then passed = true end
    end
  end
  local pick = afterMatch or first
  if pick then return pick[1], pick[2], pick[3] end
end

-- Whitelisted items ready to disenchant, and disenchantable unbound items NOT on the whitelist.
local function CountDisenchantTargets()
  local list, ready, notListed = Whitelist(), 0, 0
  for bag = 0, NUM_BAG_SLOTS or 4 do
    for slot = 1, NumSlots(bag) or 0 do
      local itemID, _, bound = ContainerItem(bag, slot)
      if itemID and DisenchantOutcomes(itemID) then
        if list[itemID] then
          ready = ready + 1
        elseif not bound then
          notListed = notListed + 1
        end
      end
    end
  end
  return ready, notListed
end

-- Adds every disenchantable item in the bags that isn't bound to you (bought, not worn).
local function WhitelistBags()
  local added = 0
  for bag = 0, NUM_BAG_SLOTS or 4 do
    for slot = 1, NumSlots(bag) or 0 do
      local itemID, _, bound = ContainerItem(bag, slot)
      if itemID and not bound and not Whitelist()[itemID] and DisenchantOutcomes(itemID) then
        AddToWhitelist(itemID)
        added = added + 1
      end
    end
  end
  Print(added > 0 and string.format("Whitelisted %d item%s from your bags.", added, added == 1 and "" or "s")
    or "No unbound disenchantable items in your bags that aren't whitelisted already.")
end

-- True while casting, looting or on the global cooldown: Disenchant can't start then.
local function Busy()
  if UnitCastingInfo("player") or UnitChannelInfo("player") then return true end
  if LootFrame and LootFrame:IsShown() then return true end
  if GetNumLootItems and GetNumLootItems() > 0 then return true end -- still collecting (auto loot)
  local start, duration
  if C_Spell and C_Spell.GetSpellCooldown then
    local info = C_Spell.GetSpellCooldown(DISENCHANT_SPELL)
    start, duration = info and info.startTime, info and info.duration
  elseif GetSpellCooldown then
    start, duration = GetSpellCooldown(DISENCHANT_SPELL)
  end
  return start and duration and duration > 0 and start + duration > GetTime() or false
end

local wheelButton = CreateFrame("Button", WHEEL_BUTTON, UIParent, "SecureActionButtonTemplate")

-- The game refused the item the wheel just picked (busy, mistimed press, ...). Nothing is
-- ever removed or skipped for good: the next press simply tries the next whitelisted item
-- in the bags, and the refused one comes round again after the others.
local function HandleRefusedItem()
  local pending = wheelButton.pending
  if not pending then return end
  wheelButton.pending = nil
  wheelButton.lastUse = nil -- the next press may try again straight away
  wheelButton.rotateAfter = { bag = pending.bag, slot = pending.slot }
end
wheelButton:SetAttribute("type", "macro")
wheelButton:SetAttribute("macrotext", "")
-- Both: /click and key bindings send up and/or down depending on client settings.
wheelButton:RegisterForClicks("AnyUp", "AnyDown")

-- Two presses per item, so an item is never equipped by mistake:
--   1. "/cast Disenchant" only - readies the spell (the cursor waits for an item).
--   2. "/use bag slot" only, and only while OUR Disenchant is readied - picks the item.
-- A lone "/use" on an item equips it, so step 2 never runs unless step 1 worked.
local ARM_TIMEOUT = 10 -- seconds a readied Disenchant counts as ours
wheelButton:SetScript("PreClick", function(self)
  if InCombatLockdown() then return end
  local text = ""
  local now = GetTime()
  local recent = self.lastUse and now - self.lastUse < 0.6 -- the cast may not show as started yet
  if not IsPlayerSpell(DISENCHANT_SPELL) then
    Print("You don't know Disenchant.")
  elseif SpellIsTargeting() then
    -- Our Disenchant stays readied after the game refuses an item, so keep using it,
    -- but give the game a moment to answer the last pick before trying the next item.
    local looting = (LootFrame and LootFrame:IsShown()) or (GetNumLootItems and GetNumLootItems() > 0)
    if self.armedAt and now - self.armedAt < ARM_TIMEOUT and not recent and not looting then
      local bag, slot, itemID = NextDisenchantTarget(self.rotateAfter)
      if bag then
        text = "/use " .. bag .. " " .. slot
        self.lastUse = now
        self.pending = { bag = bag, slot = slot, itemID = itemID, time = now }
        -- Backup check: if no cast started shortly after, the game refused this item.
        C_Timer.After(0.7, function()
          local pending = self.pending
          if not pending or pending.itemID ~= itemID or pending.bag ~= bag or pending.slot ~= slot then return end
          if UnitCastingInfo("player") or ContainerItem(bag, slot) ~= itemID then
            self.pending = nil -- it's being (or was) disenchanted
            self.rotateAfter = nil -- back to taking items in bag order
            return
          end
          HandleRefusedItem()
        end)
      else
        text = "/stopspelltarget"
        self.armedAt = nil
      end
    end
    -- Otherwise some other spell is waiting for a target: leave it alone.
  elseif not recent and not Busy() then
    if NextDisenchantTarget() then
      wheelEmptyWarned = false
      text = "/cast " .. (GetSpellName(DISENCHANT_SPELL) or "Disenchant")
      self.armedAt = now
    elseif not wheelEmptyWarned then
      wheelEmptyWarned = true
      Print("Nothing on the whitelist left in your bags to disenchant.")
    end
  end
  self:SetAttribute("macrotext", text)
end)

-- Shuffle mode: mouse wheel up/down presses the disenchant wheel button. Your macro named
-- "Shuffle" is set to press it too, for an action bar slot. Bindings can't change in
-- combat, so it switches off when combat starts.
local shuffleModeOwner = CreateFrame("Frame")
local shuffleModeOn = false

local function PointShuffleMacro()
  local body = "#showtooltip " .. (GetSpellName(DISENCHANT_SPELL) or "Disenchant") .. "\n/click " .. WHEEL_BUTTON
  if GetMacroInfo(SHUFFLE_MACRO) then
    EditMacro(SHUFFLE_MACRO, SHUFFLE_MACRO, nil, body)
  elseif (GetNumMacros() or 0) < (MAX_ACCOUNT_MACROS or 120) then
    CreateMacro(SHUFFLE_MACRO, "INV_Enchant_Disenchant", body)
  end
end

local function SetShuffleMode(on)
  if InCombatLockdown() then
    Print("Can't change shuffle mode in combat.")
    return
  end
  if on then
    PointShuffleMacro()
    SetOverrideBindingClick(shuffleModeOwner, true, "MOUSEWHEELUP", WHEEL_BUTTON, "LeftButton")
    SetOverrideBindingClick(shuffleModeOwner, true, "MOUSEWHEELDOWN", WHEEL_BUTTON, "LeftButton")
    wheelEmptyWarned = false
    local ready, notListed = CountDisenchantTargets()
    Print(string.format("Shuffle mode |cff20ff20on|r: mouse wheel disenchants whitelisted items (%d in your bags). /shuffle mode to stop.",
      ready))
    if notListed > 0 then
      Print(string.format("|cffffd100%d other disenchantable item%s in your bags %s on the whitelist.|r Type /shuffle whitelist bags to add them.",
        notListed, notListed == 1 and "" or "s", notListed == 1 and "isn't" or "aren't"))
    end
  else
    ClearOverrideBindings(shuffleModeOwner)
    Print("Shuffle mode |cffff4040off|r: mouse wheel is back to normal.")
  end
  shuffleModeOn = on
end

local function ToggleShuffleMode()
  SetShuffleMode(not shuffleModeOn)
end

shuffleModeOwner:RegisterEvent("PLAYER_REGEN_DISABLED")
shuffleModeOwner:RegisterEvent("UI_ERROR_MESSAGE")
shuffleModeOwner:SetScript("OnEvent", function(_, event, ...)
  if event == "UI_ERROR_MESSAGE" then
    -- An error right after the wheel picked an item means the game refused that item.
    local pending = wheelButton.pending
    if pending and GetTime() - pending.time < 1 then
      local _, message = ...
      local _, _, _, link = ContainerItem(pending.bag, pending.slot)
      Print(string.format("|cffff8040Game refused|r %s (bag %d slot %d): %s - trying the next item.",
        link or ("item:" .. pending.itemID), pending.bag, pending.slot, tostring(message)))
      HandleRefusedItem()
    end
    return
  end
  -- Entering combat: override bindings are still allowed in the instant before lockdown.
  if shuffleModeOn then
    ClearOverrideBindings(shuffleModeOwner)
    shuffleModeOn = false
    Print("Shuffle mode off (combat started).")
  end
end)

local function ShowHelp()
  Print("/shuffle - open the Shuffles tab (or a window away from the AH)")
  Print("/shuffle crafts - open the Crafts tab (or a window away from the AH)")
  Print("/shuffle snipe - open the Snipe tab (or a window away from the AH)")
  Print("/shuffle mode - toggle: mouse wheel disenchants whitelisted items in your bags, one per tick")
  Print("/shuffle whitelist [item]  - add an item (shift-click it in); /shuffle unwhitelist [item]; /shuffle whitelist  - list")
  Print("/shuffle whitelist bags  - add every disenchantable item in your bags that isn't bound to you")
  Print("/shuffle add <Profile> [qty] [item] + [qty] [item] = [qty] [item]  (shift-click items in)")
  Print("   e.g. /shuffle add Mining 8 [Dark Iron Ore] = 1 [Dark Iron Bar]")
  Print("Shift + right-click a shuffle row to remove it.  Click a column header to sort.")
  Print("/shuffle delprofile <Profile>  - delete a whole profile")
  Print("/shuffle reset  - restore the default profiles")
  Print("/shuffle unblock  - unblock every blocked craft")
end

local function OpenTab(tabName, window)
  local tab = _G["AuctionatorTabs_" .. tabName]
  if AuctionHouseOpen() and tab then
    tab:Click()
  else
    window:SetShown(not window:IsShown())
  end
end

SLASH_AUCTIONATORSHUFFLE1 = "/shuffle"
SlashCmdList.AUCTIONATORSHUFFLE = function(msg)
  msg = strtrim(msg or "")
  local cmd, rest = msg:match("^(%S*)%s*(.-)$")
  cmd = cmd:lower()

  if cmd == "" then
    OpenTab("Shuffles", shuffleWindow)
  elseif cmd == "crafts" or cmd == "craft" then
    OpenTab("Crafts", craftWindow)
  elseif cmd == "mode" then
    ToggleShuffleMode()
  elseif cmd == "whitelist" and rest:lower() == "bags" then
    WhitelistBags()
  elseif cmd == "whitelist" or cmd == "unwhitelist" then
    local ids = {}
    for id in rest:gmatch("item:(%d+)") do table.insert(ids, tonumber(id)) end
    if #ids == 0 and tonumber(rest) then ids = { tonumber(rest) } end
    if #ids == 0 then
      local names = {}
      for itemID in pairs(Whitelist()) do table.insert(names, (select(2, GetItemInfo(itemID))) or ("item:" .. itemID)) end
      table.sort(names)
      Print(#names == 0 and "The disenchant whitelist is empty." or ("Disenchant whitelist: " .. table.concat(names, ", ")))
      return
    end
    for _, itemID in ipairs(ids) do
      if cmd == "whitelist" then
        AddToWhitelist(itemID)
      else
        Whitelist()[itemID] = nil
        Print("Removed from whitelist: " .. ((select(2, GetItemInfo(itemID))) or ("item:" .. itemID)))
      end
    end
  elseif cmd == "snipe" then
    OpenTab("Snipe", snipeWindow)
  elseif cmd == "add" then
    local sectionName, recipeText = rest:match("^(%S+)%s+(.+)$")
    local left, right = (recipeText or ""):match("^(.-)=(.+)$")
    local inputs = left and ParseSide(left)
    local outputs = right and ParseSide(right)
    if not (sectionName and inputs and outputs) then
      Print("Couldn't read that. Example: /shuffle add Mining 1 [Copper Ore] = 1 [Copper Bar]")
      return
    end
    local section = FindSection(sectionName)
    if not section then
      section = { name = sectionName, recipes = {} }
      table.insert(AuctionatorShuffleDB.sections, section)
      Print("Created profile " .. sectionName .. ".")
    end
    table.insert(section.recipes, { inputs = inputs, outputs = outputs })
    AuctionatorShuffleDB.selected = section.name
    Print("Added to " .. section.name .. ": " .. SideText(inputs) .. " -> " .. SideText(outputs))
    RefreshAll()
  elseif cmd == "delprofile" then
    local section, index = FindSection(rest)
    if not section then Print("No profile called " .. rest .. ".") return end
    table.remove(AuctionatorShuffleDB.sections, index)
    Print("Deleted profile " .. section.name .. ".")
    RefreshAll()
  elseif cmd == "reset" then
    AuctionatorShuffleDB.sections = CopyTable(DEFAULT_SECTIONS)
    AuctionatorShuffleDB.selected = nil
    Print("Profiles reset to defaults.")
    RefreshAll()
  elseif cmd == "unblock" then
    AuctionatorShuffleDB.blocked = {}
    Print("All crafts unblocked.")
    RefreshAll()
  else
    ShowHelp()
  end
end

end -- commands and disenchant wheel

do -- profession window and quick undercut
---------------------------------------------------------------------------
-- Profession window: Auctionator's To Craft / Profit lines, redone with this addon's scan
-- prices and the amount in the Create box, plus craft time and gold per hour.
---------------------------------------------------------------------------

local function DurationText(seconds)
  seconds = math.floor(seconds + 0.5)
  local h, m, s = math.floor(seconds / 3600), math.floor(seconds % 3600 / 60), seconds % 60
  if h > 0 then return string.format("%dh %dm", h, m) end
  if m > 0 then return string.format("%dm %ds", m, s) end
  return s .. "s"
end

local function Coins(copper)
  return GetMoneyString and GetMoneyString(copper, true) or Money(copper)
end

local function ColoredMoney(copper)
  if copper < 0 then return "|cffff4040-|r" .. Coins(-copper) end
  return "|cff20ff20+|r" .. Coins(copper)
end

-- How many to craft: the number box next to Create on the crafting page (1 if unknown).
local function CraftCount()
  local page = ProfessionsFrame and ProfessionsFrame.CraftingPage
  local box = page and page.CreateMultipleInputBox
  local value = box and box.GetValue and box:GetValue()
  return (type(value) == "number" and value >= 1) and math.floor(value) or 1
end

-- Replaces Auctionator's To Craft / Profit text with two short lines that all use this
-- addon's scan prices, for the amount in the Create box:
--   To Craft: <materials>   Profit: <best of AH / vendor / disenchant>
--   Time: <total craft time>   <gold per hour>/h
-- Returns nil when the recipe makes no item (Auctionator's text is kept then).
local function ProfessionLines(schematicForm)
  local recipeInfo = schematicForm and schematicForm.GetRecipeInfo and schematicForm:GetRecipeInfo()
  local recipeID = recipeInfo and recipeInfo.recipeID
  local schematic = recipeID and C_TradeSkillUI.GetRecipeSchematic(recipeID, false)
  local output = schematic and schematic.outputItemID
  if not output then return nil end
  local made = math.max(1, schematic.quantityMin or 1)
  local count = CraftCount()

  local recipe = { inputs = {}, outputs = { { output, made } } }
  local basic = Enum and Enum.CraftingReagentType and Enum.CraftingReagentType.Basic or 1
  for _, slot in ipairs(schematic.reagentSlotSchematics or {}) do
    local required = slot.required
    if required == nil then required = slot.reagentType == basic end
    local reagent = slot.reagents and slot.reagents[1] and slot.reagents[1].itemID
    if required and reagent then table.insert(recipe.inputs, { reagent, slot.quantityRequired or 1 }) end
  end

  local cost = SumSide(recipe.inputs)
  local best, method
  if cost then
    local price = GetPrice(output)
    if price then best, method = math.floor(price * made * (1 - AH_CUT)) - cost, nil end
    local vendorEach = select(11, GetItemInfo(output)) or 0
    if vendorEach > 0 and (not best or vendorEach * made - cost > best) then best, method = vendorEach * made - cost, "vendor" end
    local outcomes = DisenchantOutcomes(output)
    local deEach = outcomes and DisenchantValue(outcomes)
    if deEach and (not best or deEach * made - cost > best) then best, method = deEach * made - cost, "DE" end
  end

  local first = "To Craft: " .. (cost and ("|cffffffff" .. Coins(cost * count) .. "|r") or "|cff8a8a8ano price|r")
  if best then
    first = first .. "    Profit: " .. ColoredMoney(best * count) .. (method and (" |cff8a8a8a" .. method .. "|r") or "")
  end

  local seconds = CraftSeconds(recipeID) or ShuffleSeconds({ outputs = { { output, 1 } } })
  if seconds and method == "DE" then seconds = seconds + (CraftSeconds(DISENCHANT_SPELL) or 0) * made end
  local second
  if seconds then
    second = "Time: |cffffffff" .. DurationText(seconds * count) .. "|r"
    if best then second = second .. "    " .. ColoredMoney(math.floor(best * 3600 / seconds)) .. "|cffffffff/h|r" end
  end
  return second and { first, second } or { first }
end

if Auctionator.CraftingInfo and Auctionator.CraftingInfo.GetInfoText then
  local originalInfoText = Auctionator.CraftingInfo.GetInfoText
  Auctionator.CraftingInfo.GetInfoText = function(schematicForm, ...)
    local ok, lines = pcall(ProfessionLines, schematicForm)
    if ok and lines then return table.concat(lines, "\n"), #lines end
    local text, count = originalInfoText(schematicForm, ...)
    if not ok then
      text = (count > 0 and (text .. "\n") or "") .. "|cffff4040Shuffle error:|r " .. tostring(lines)
      count = count + 1
    end
    return text, count
  end
end

-- Refresh the lines when the amount to craft changes.
local function RefreshProfessionLines()
  local info = _G.AuctionatorCraftingInfoProfessionsFrame
  if info and info:IsVisible() then info:UpdateTotal() end
end
local professionWatcher = CreateFrame("Frame")
professionWatcher:RegisterEvent("TRADE_SKILL_SHOW")
professionWatcher:SetScript("OnEvent", function(self)
  local page = ProfessionsFrame and ProfessionsFrame.CraftingPage
  local box = page and page.CreateMultipleInputBox
  if box and not self.hooked then
    self.hooked = true
    if box.SetValue then hooksecurefunc(box, "SetValue", RefreshProfessionLines) end
    if box.HookScript then pcall(box.HookScript, box, "OnTextChanged", RefreshProfessionLines) end
  end
end)


-- Quick undercut (Auctionator's Cancelling tab). One press per step, because the game
-- allows one cancel or post per click, repeating:
--   1. scan: runs Auctionator's Undercut Scan (reloads your auctions, finds undercut ones);
--   2. delist: cancels the next undercut auction (the one Auctionator's Cancel Undercut would);
--   3. relist: posts a new stack of that item from your bags, 1 copper under the cheapest listing;
--   then back to 1. When a scan finds nothing undercut, the next press posts another stack
--   of the last item relisted (if any is left in your bags) at the current cheapest price.
-- Stack size: a 1-200 slider with an editable box, remembered per item (default 60).
-- Cancelled items go to the mailbox, so the new stack comes from what's in your bags.
do
  local QUICK_DURATION = 2 -- 24 hours
  local QUICK_DEFAULT, QUICK_MAX = 60, 200
  local QUICK_PRESETS = { [10940] = 50, [2841] = 50, [3860] = 20 } -- Strange Dust, Bronze Bar, Mithril Bar
  local quick = nil -- { itemID, itemKey, price, commodity, ready } or { rescan = true } or { scanning = true }
  local lastPost = nil -- { itemID, itemKey, price, commodity } of the last relist
  local pendingCancel = nil -- { container, auction, id } while a cancel waits for the server
  local CANCEL_TIMEOUT = 5 -- seconds without AUCTION_CANCELED before a cancel counts as dropped

  -- The server silently drops a cancel sent while its message throttle is busy (often right
  -- after the Undercut Scan's searches); Auctionator then waits forever and has already taken
  -- the auction off its undercut list. Put it back so either button can try again.
  local function CancelFailed()
    local pending = pendingCancel
    pendingCancel = nil
    if not pending then return end
    local list = pending.container.undercutAuctions
    if pending.auction and list then
      local present = false
      for _, info in ipairs(list) do
        if info.auctionID == pending.id then present = true end
      end
      if not present then table.insert(list, 1, pending.auction) end
    end
    pending.container:SetCancel()
    if quick and not quick.ready then quick = nil end
    Print("The auction house dropped that cancel (it was busy). Press again.")
  end

  -- Wraps Auctionator's "cancel next undercut" (its button, its key shortcut and Quick
  -- undercut all go through it): waits until the server can take a cancel, and recovers
  -- when one is dropped instead of getting stuck.
  local function GuardCancels(container)
    local original = container.CancelNextAuction
    container.CancelNextAuction = function(self, ...)
      local auction = self.undercutAuctions and self.undercutAuctions[1]
      if not auction then return end
      if C_AuctionHouse.IsThrottledMessageSystemReady and not C_AuctionHouse.IsThrottledMessageSystemReady() then
        if quick and not quick.ready then quick = nil end
        Print("The auction house is busy - press again in a moment.")
        return
      end
      pendingCancel = { container = self, auction = auction, id = auction.auctionID }
      original(self, ...)
      local id = auction.auctionID
      C_Timer.After(CANCEL_TIMEOUT, function()
        if pendingCancel and pendingCancel.id == id then CancelFailed() end
      end)
    end
  end

  local function StackFor(itemID)
    local saved = AuctionatorShuffleDB.quickStacks and itemID and AuctionatorShuffleDB.quickStacks[itemID]
    return saved or (itemID and QUICK_PRESETS[itemID]) or QUICK_DEFAULT
  end

  local function FindInBags(itemID)
    for bag = 0, NUM_BAG_SLOTS or 4 do
      for slot = 1, C_Container.GetContainerNumSlots(bag) do
        local info = C_Container.GetContainerItemInfo(bag, slot)
        if info and info.itemID == itemID and not info.isLocked then
          return ItemLocation:CreateFromBagAndSlot(bag, slot)
        end
      end
    end
  end

  -- Who undercut an auction: the seller(s) of the cheapest listing that isn't yours, read
  -- from the Undercut Scan's search results (still cached), and its price. nil if unknown.
  local function Undercutter(auction, commodity)
    local function OwnerText(owners)
      if type(owners) ~= "table" or #owners == 0 then return nil end
      for _, owner in ipairs(owners) do
        if owner == "player" then return nil end
      end
      return table.concat(owners, ", ")
    end
    local itemID = auction.itemKey.itemID
    if commodity then
      for i = 1, C_AuctionHouse.GetNumCommoditySearchResults(itemID) do
        local info = C_AuctionHouse.GetCommoditySearchResultInfo(itemID, i)
        local who = info and OwnerText(info.owners)
        if who then return who, info.unitPrice end
      end
      return nil
    end
    local keys = { auction.itemKey, { itemID = itemID, itemLevel = 0, itemSuffix = 0, battlePetSpeciesID = 0 } }
    for _, key in ipairs(keys) do
      for i = 1, C_AuctionHouse.GetNumItemSearchResults(key) do
        local info = C_AuctionHouse.GetItemSearchResultInfo(key, i)
        local who = info and OwnerText(info.owners)
        if who then return who, info.buyoutAmount end
      end
    end
  end

  local function CreateQuickUndercut()
    local cancelButton = _G.AuctionatorCancelUndercutButton
    local container = cancelButton and cancelButton:GetParent()
    if not container or container.quickUndercut or not container.StartScanButton then return end

    GuardCancels(container)
    local button = CreateFrame("Button", "AuctionatorShuffleQuickUndercutButton", container, "UIPanelButtonTemplate")
    container.quickUndercut = button
    -- Shift + mouse wheel presses it while the Cancelling tab is open.
    button:SetScript("OnShow", function(self)
      if InCombatLockdown() then return end
      SetOverrideBindingClick(self, true, "SHIFT-MOUSEWHEELUP", self:GetName(), "LeftButton")
      SetOverrideBindingClick(self, true, "SHIFT-MOUSEWHEELDOWN", self:GetName(), "LeftButton")
    end)
    button:SetScript("OnHide", function(self)
      if not InCombatLockdown() then ClearOverrideBindings(self) end
    end)
    if button:IsVisible() then button:GetScript("OnShow")(button) end
    local lastPress = 0
    local PRESS_COOLDOWN = 0.5 -- seconds; extra wheel ticks in one flick are ignored
    button:SetSize(150, 22)
    button:SetPoint("TOPRIGHT", container.StartScanButton, "TOPLEFT", -6, 0)

    -- The item the stack size belongs to: the one being undercut now, or next in line.
    local function CurrentItem()
      if quick then return quick.itemID end
      local auction = container.undercutAuctions and container.undercutAuctions[1]
      return auction and auction.itemKey.itemID
    end

    local box = CreateFrame("EditBox", nil, container, "InputBoxTemplate")
    box:SetSize(34, 20)
    box:SetPoint("RIGHT", button, "LEFT", -6, 0)
    box:SetAutoFocus(false)
    box:SetNumeric(true)
    box:SetMaxLetters(3)
    box:SetJustifyH("CENTER")

    local slider = CreateFrame("Slider", nil, container)
    slider:SetSize(110, 16)
    slider:SetPoint("RIGHT", box, "LEFT", -10, 0)
    slider:SetOrientation("HORIZONTAL")
    slider:SetMinMaxValues(1, QUICK_MAX)
    slider:SetValueStep(1)
    slider:SetObeyStepOnDrag(true)
    local track = slider:CreateTexture(nil, "BACKGROUND")
    track:SetColorTexture(0, 0, 0, 0.6)
    track:SetPoint("LEFT", 0, 0)
    track:SetPoint("RIGHT", 0, 0)
    track:SetHeight(6)
    slider:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")

    local syncing, shownItem = false, false
    local function SetStack(n, save)
      n = math.max(1, math.min(QUICK_MAX, math.floor(n)))
      syncing = true
      slider:SetValue(n)
      if box:GetNumber() ~= n then box:SetNumber(n) end
      syncing = false
      local itemID = CurrentItem()
      if save and itemID then
        AuctionatorShuffleDB.quickStacks = AuctionatorShuffleDB.quickStacks or {}
        AuctionatorShuffleDB.quickStacks[itemID] = n
      end
    end
    slider:SetScript("OnValueChanged", function(_, value)
      if not syncing then SetStack(value, true) end
    end)
    box:SetScript("OnTextChanged", function(self, userInput)
      local n = self:GetNumber()
      if userInput and not syncing and n and n > 0 then SetStack(n, true) end
    end)
    box:SetScript("OnEnterPressed", box.ClearFocus)
    box:SetScript("OnEscapePressed", box.ClearFocus)
    SetStack(StackFor(CurrentItem()), false)

    local function StackSize() return math.max(1, math.floor(slider:GetValue())) end

    button:SetScript("OnClick", function()
      if GetTime() - lastPress < PRESS_COOLDOWN then return end
      lastPress = GetTime()
      local undercut = container.undercutAuctions and #container.undercutAuctions > 0
      if (quick and quick.rescan) or (not quick and not undercut) then
        -- Step 1: scan (reload your auctions and find what's undercut now).
        quick = nil
        if container.StartScanButton:IsEnabled() then
          container:StartScan()
          quick = { scanning = true }
        end
        return
      end
      if quick and quick.ready then
        -- Step 2: post the new stack.
        local itemID = quick.itemID
        local have = C_Item.GetItemCount(itemID)
        local location = FindInBags(itemID)
        if have == 0 or not location then
          Print("Quick undercut: no " .. (ItemName(itemID) or ("item:" .. itemID)) .. " in your bags to post (cancelled auctions go to your mailbox).")
          quick = nil
          return
        end
        local quantity = math.min(StackSize(), have)
        if quick.commodity then
          C_AuctionHouse.PostCommodity(location, QUICK_DURATION, quantity, quick.price)
        else
          C_AuctionHouse.PostItem(location, QUICK_DURATION, quantity, nil, quick.price)
        end
        Print(string.format("Quick undercut: posted %d x %s at %s each.", quantity,
          ItemName(itemID) or ("item:" .. itemID), Money(quick.price)))
        lastPost = { itemID = itemID, itemKey = quick.itemKey, price = quick.price, commodity = quick.commodity }
        quick = { rescan = true }
        return
      end
      if quick then return end -- still waiting for the cancel to go through
      -- Step 1: cancel the next undercut auction and remember the price to beat.
      local auction = container.undercutAuctions and container.undercutAuctions[1]
      if not auction then
        Print("Quick undercut: nothing undercut. Run Undercut Scan first.")
        return
      end
      local minPrice = container.seenItemMinPrice and container.seenItemMinPrice[Auctionator.Utilities.ItemKeyString(auction.itemKey)]
      if not minPrice or minPrice <= 1 then
        Print("Quick undercut: no price to undercut for that item.")
        return
      end
      local keyInfo = C_AuctionHouse.GetItemKeyInfo(auction.itemKey)
      quick = { itemID = auction.itemKey.itemID, itemKey = auction.itemKey, price = minPrice - 1,
        commodity = keyInfo and keyInfo.isCommodity }
      local okWho, who, theirPrice = pcall(Undercutter, auction, quick.commodity)
      if not okWho then who = nil end
      quick.undercutBy = who
      container:CancelNextAuction() -- clears `quick` again if the auction house is busy
      if quick then
        Print(string.format("Quick undercut: %s was undercut by |cffffd100%s|r at %s.",
          ItemName(quick.itemID) or ("item:" .. quick.itemID), who or "an unknown seller", Money(theirPrice or minPrice)))
      end
    end)

    button:SetScript("OnUpdate", function(self)
      -- Show the saved stack size whenever the item in line changes.
      local itemID = CurrentItem()
      if itemID ~= shownItem then
        shownItem = itemID
        SetStack(StackFor(itemID), false)
      end
      local scanning = not container.StartScanButton:IsEnabled()
      local undercut = container.undercutAuctions and #container.undercutAuctions > 0
      -- A scan we started just finished: delist what's undercut, or with nothing undercut,
      -- offer another stack of the last relisted item if some is left in the bags.
      if quick and quick.scanning and not scanning then
        quick = nil
        if not undercut and lastPost and C_Item.GetItemCount(lastPost.itemID) > 0 then
          local seen = lastPost.itemKey and container.seenItemMinPrice
            and container.seenItemMinPrice[Auctionator.Utilities.ItemKeyString(lastPost.itemKey)]
          quick = { itemID = lastPost.itemID, itemKey = lastPost.itemKey, commodity = lastPost.commodity,
            price = seen or lastPost.price, ready = true }
        end
      end
      if scanning and not (quick and quick.ready) then
        self:SetText("Scanning...")
        self:SetEnabled(false)
      elseif (quick and quick.rescan) or (not quick and not undercut) then
        self:SetText("Scan")
        self:SetEnabled(true)
      elseif quick and quick.ready then
        self:SetText("Post " .. StackSize() .. " at " .. MoneyShort(quick.price))
        self:SetEnabled(true)
      elseif quick then
        self:SetText("Cancelling...")
        self:SetEnabled(false)
      else
        self:SetText("Delist")
        self:SetEnabled(true)
      end
    end)
    button:SetScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_TOP")
      GameTooltip:AddLine("Quick undercut")
      GameTooltip:AddLine("Repeats Scan > Delist > Relist, one press each: scans for undercut auctions, cancels the next one, then posts a new stack of that item from your bags 1 copper under the cheapest listing. If a scan finds nothing undercut, the next press posts another stack of the last relisted item at the current cheapest price (when you still have some).", 0.8, 0.8, 0.8, true)
      GameTooltip:AddLine("Stack size: the slider and box on the left (1-200), remembered for each item.", 0.8, 0.8, 0.8, true)
      GameTooltip:AddLine("Shortcut: Shift + mouse wheel, one step per tick.", 0.8, 0.8, 0.8, true)
      GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function() GameTooltip:Hide() end)
  end

  local watcher = CreateFrame("Frame")
  watcher:RegisterEvent("AUCTION_HOUSE_SHOW")
  watcher:RegisterEvent("AUCTION_CANCELED")
  watcher:RegisterEvent("AUCTION_HOUSE_CLOSED")
  pcall(watcher.RegisterEvent, watcher, "AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED")
  watcher:SetScript("OnEvent", function(_, event)
    if event == "AUCTION_HOUSE_SHOW" then
      C_Timer.After(0.5, CreateQuickUndercut)
    elseif event == "AUCTION_CANCELED" then
      pendingCancel = nil
      if quick and not quick.rescan and not quick.scanning then quick.ready = true end
    elseif event == "AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED" then
      if pendingCancel then CancelFailed() end
    else
      quick, pendingCancel = nil, nil
    end
  end)
end

end -- profession window and quick undercut (blocks keep the file under Lua's 200-local limit)

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("GET_ITEM_INFO_RECEIVED")
-- Profession window events differ between clients; register whichever exist.
local TRADE_SKILL_EVENTS = { TRADE_SKILL_SHOW = true, TRADE_SKILL_UPDATE = true, TRADE_SKILL_LIST_UPDATE = true, NEW_RECIPE_LEARNED = true }
for event in pairs(TRADE_SKILL_EVENTS) do pcall(events.RegisterEvent, events, event) end

local tradeSkillQueued = false
events:SetScript("OnEvent", function(_, event, arg1)
  if event == "ADDON_LOADED" and arg1 == ADDON then
    if type(AuctionatorShuffleDB) ~= "table" or type(AuctionatorShuffleDB.sections) ~= "table" then
      AuctionatorShuffleDB = { sections = CopyTable(DEFAULT_SECTIONS) }
    end
    -- An older version took items off the whitelist when the game refused them, which
    -- removed good items by mistake. Put them all back and drop that list.
    if type(AuctionatorShuffleDB.noDisenchant) == "table" then
      AuctionatorShuffleDB.whitelist = AuctionatorShuffleDB.whitelist or {}
      for itemID in pairs(AuctionatorShuffleDB.noDisenchant) do AuctionatorShuffleDB.whitelist[itemID] = true end
      AuctionatorShuffleDB.noDisenchant = nil
    end
    -- Add default profiles introduced since this save was made (once; deleted ones stay deleted).
    local db = AuctionatorShuffleDB
    db.addedDefaults = db.addedDefaults or {}
    for _, section in ipairs(DEFAULT_SECTIONS) do
      if not db.addedDefaults[section.name] then
        if not FindSection(section.name) then table.insert(db.sections, CopyTable(section)) end
        db.addedDefaults[section.name] = true
      end
    end
    CraftState()
    Auctionator.API.v1.RegisterForDBUpdate(ADDON, QueueRefresh)
  elseif event == "GET_ITEM_INFO_RECEIVED" and (pendingItems or vendorItemsPending) then
    vendorItemsPending = false
    QueueRefresh()
  elseif TRADE_SKILL_EVENTS[event] and AuctionatorShuffleDB and not tradeSkillQueued then
    tradeSkillQueued = true
    C_Timer.After(0.5, function() tradeSkillQueued = false; ReadTradeSkill() end)
  end
end)
