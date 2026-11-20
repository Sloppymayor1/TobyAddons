-- Mining and Herbalism share a timed combo and running loot value.
-- Mining scores once per node. Herbalism reveals and scores each herb in turn.
local ADDON, NS = ...

local MEDIA = "Interface\\AddOns\\ForeverFarmRoute\\Media\\"
local FONT = "Fonts\\FRIZQT__.TTF"
local sin, cos, exp, random, max, min, floor = math.sin, math.cos, math.exp, math.random, math.max, math.min, math.floor

local MAX_LINES = 8
local COMBO_SOUNDS = { "slap2.wav", "6S.wav", "BILLYEAH.wav", "GAYBAA.wav" }
local LOOT_SOUND_DELAY = 0.12 -- Give the other loot messages from this mine time to arrive.
local HERB_BEAT = 0.4
local REWARD_BY_ITEM = {
    [12363] = 1, -- Arcane Crystal
    [12361] = 2, -- Blue Sapphire
    [12800] = 2, -- Azerothian Diamond
    [12364] = 3, -- Huge Emerald
    [12799] = 3, -- Large Opal
    [7910] = 3,  -- Star Ruby
}
local REWARDS = {
    { sound = "Areeeeeee.wav", soundLength = 1.36, color = {1, 0.20, 0.20}, aura = {0.72, 0.25, 1}, power = 2.2, duration = 1.45 },
    { sound = "Master.wav", soundLength = 1.21, color = {1, 0.53, 0.16}, aura = {0.25, 0.70, 1}, power = 1.5, duration = 0.8 },
    { sound = "Exalt.wav", soundLength = 3.30, aura = {0.22, 1, 0.85}, power = 1 },
}
local unpack = unpack or table.unpack

local function DB() return NS.db end
local function Window()
    local db = DB()
    return db and db.comboWindow or 10
end

-------------------------------------------------------------------------------
-- Value estimate: Auctionator price when known, else vendor price
-------------------------------------------------------------------------------
local function UnitValue(link)
    local api = Auctionator and Auctionator.API and Auctionator.API.v1
    if api and api.GetAuctionPriceByItemLink then
        local ok, price = pcall(api.GetAuctionPriceByItemLink, ADDON, link)
        if ok and type(price) == "number" and price > 0 then return price, true end
    end
    local sell = select(11, NS.GetItemInfo(link))
    return sell or 0, false
end

-- Compact money with the coin icon: 1.25 (gold), 5.43 (silver), 87 (copper)
local COIN = "|TInterface\\MoneyFrame\\UI-%sIcon:0:0:2:0|t"
local function Money(copper, plain)
    copper = floor(copper + 0.5)
    local amount, coin, color
    if copper >= 10000 then
        amount, coin, color = string.format("%.2f", copper / 10000), "Gold", "|cffffd100"
    elseif copper >= 100 then
        amount, coin, color = string.format("%.2f", copper / 100), "Silver", "|cffe6e6e6"
    else
        amount, coin, color = tostring(copper), "Copper", "|cffeda55f"
    end
    return (plain and amount or color .. amount .. "|r") .. COIN:format(coin)
end

-------------------------------------------------------------------------------
-- Display
-------------------------------------------------------------------------------
local root = CreateFrame("Frame", "ForeverFarmRouteCelebration", UIParent)
root:SetSize(10, 10)
root:SetPoint("CENTER", UIParent, "CENTER", 0, 270)
root:SetFrameStrata("HIGH")
root:SetFrameLevel(50)
root:Hide()

local backGlow = root:CreateTexture(nil, "BACKGROUND")
backGlow:SetTexture(MEDIA .. "Glow")
backGlow:SetBlendMode("ADD")
backGlow:SetPoint("CENTER", 0, -10)

local text = CreateFrame("Frame", nil, root)
text:SetSize(10, 10)
text:SetPoint("CENTER")
text:SetFrameLevel(root:GetFrameLevel() + 10)

local function MakeText(size, y)
    local fs = text:CreateFontString(nil, "OVERLAY")
    fs:SetFont(FONT, size, "THICKOUTLINE")
    fs:SetPoint("CENTER", text, "CENTER", 0, y)
    fs:SetShadowOffset(2, -2)
    fs:SetShadowColor(0, 0, 0, 0.8)
    return fs
end

local comboText = MakeText(26, 62)
local valueText = MakeText(44, 24)
local lines, auras, lineWidths = {}, {}, {}
for i = 1, MAX_LINES do
    lines[i] = MakeText(22, -12 - (i - 1) * 26)
    local aura = text:CreateTexture(nil, "BACKGROUND")
    aura:SetTexture(MEDIA .. "Glow")
    aura:SetBlendMode("ADD")
    aura:SetPoint("CENTER", lines[i])
    aura:Hide()
    auras[i] = aura
end
local harvestText = MakeText(20, -14)
harvestText:Hide()

-- Countdown bar for the combo window.
local barBg = text:CreateTexture(nil, "ARTWORK")
barBg:SetColorTexture(0, 0, 0, 0.55)
barBg:SetSize(220, 6)
local bar = text:CreateTexture(nil, "OVERLAY")
bar:SetColorTexture(1, 0.75, 0.2, 0.95)
bar:SetHeight(4)

-- Per combo level: slam size, shake, fire rate, glow.
local TIERS = {
    [1] = { size = 44, start = 2.3, shake = 3, fire = 0, glow = 0.15 },
    [2] = { size = 48, start = 2.6, shake = 5, fire = 0, glow = 0.3 },
    [3] = { size = 52, start = 2.9, shake = 7, fire = 45, glow = 0.5 },
    [4] = { size = 58, start = 3.3, shake = 12, fire = 110, glow = 0.8 },
}

local S -- current combo session, including loot totals and active reward effects
local regularSound
local rewardSounds = {}

local function PlayClip(file)
    if PlaySoundFile then
        local ok, played, handle = pcall(PlaySoundFile, MEDIA .. "Sounds\\" .. file, "SFX")
        if ok and played then return handle end
    end
end

local function StopRegularSound()
    if regularSound and StopSound then pcall(StopSound, regularSound, 0) end
    regularSound = nil
end

local function RewardSoundPlaying(now)
    local active = false
    for handle, endsAt in pairs(rewardSounds) do
        local playing
        if C_Sound and C_Sound.IsPlaying then
            playing = C_Sound.IsPlaying(handle)
        else
            playing = now < endsAt
        end
        if playing then
            active = true
        else
            rewardSounds[handle] = nil
        end
    end
    return active
end

local function Flame(tier, width, power)
    local hot = tier >= 4
    local x = (random() - 0.5) * width
    NS.FX.Spawn(root, x, 10 + random() * 14, {
        layer = "BORDER", sub = 1,
        life = 0.5 + random() * (hot and 0.7 or 0.45),
        size = ((hot and 28 or 20) + random() * (hot and 28 or 16)) * power, grow = -0.55,
        vx = (random() - 0.5) * 20 * power ^ 3, vy = (55 + random() * (hot and 130 or 70)) * power,
        sway = 7, swayAmp = 6, fadePow = 1.3, alpha = 0.85,
        r = 1, g = 0.85, b = 0.3, r2 = 0.9, g2 = 0.15, b2 = 0.02,
    })
    if hot and random() < 0.35 then
        NS.FX.Spawn(root, x, 20, {
            layer = "BORDER", sub = 2,
            life = 0.7 + random() * 0.6, size = 3 + random() * 3,
            vx = (random() - 0.5) * 80, vy = 120 + random() * 160, gravity = -60,
            sway = 10, swayAmp = 8, r = 1, g = 0.9, b = 0.5, r2 = 1, g2 = 0.3, b2 = 0,
        })
    end
end

local function Burst(tier, power)
    local n = (tier >= 4 and 70 or (tier >= 3 and 40 or 18)) * power
    for _ = 1, n do
        local a = random() * 6.283
        local v = (110 + random() * (tier >= 4 and 320 or 200)) * power
        NS.FX.Spawn(root, 0, 24, {
            layer = "BORDER", sub = 3,
            life = 0.45 + random() * 0.55, size = (5 + random() * 6) * power, grow = -0.5,
            vx = cos(a) * v, vy = sin(a) * v * 0.6, drag = 2.5, gravity = -120,
            r = 1, g = 0.95, b = 0.55, r2 = 1, g2 = 0.35, b2 = 0.05,
        })
    end
end

local function ShowValue()
    local harvest = S.harvest
    if harvest then
        local count, item = harvest.count, harvest.item
        local name = item.link:match("|h%[(.-)%]|h") or item.link
        local label = harvest.bonus and "Bonus!  " or ""
        local bang = harvest.bonus and "!" or string.rep("!", min(2 * count, 8))
        valueText:SetFormattedText("%s|T%s:0|t +%d %s%s", label, item.icon, count, name, bang)
        if harvest.bonus then
            valueText:SetTextColor(0.74, 1, 0.48)
        else
            valueText:SetTextColor(1, 0.95 - min(count - 1, 6) * 0.055, 0.62 - min(count - 1, 6) * 0.07)
        end
        local multiplier = not harvest.bonus and count > 1 and ("|cffffc45ax" .. count .. "|r   ") or ""
        harvestText:SetText(multiplier .. Money(harvest.value) .. "    |cffb8b8b8Total|r  " .. Money(S.total))
        harvestText:Show()
        return
    end
    harvestText:Hide()
    local reward = REWARDS[S.rewardTier]
    local bang = S.combo >= 2 and (" " .. string.rep("!", min(S.combo - 1, 3))) or ""
    valueText:SetText(Money(S.total, reward) .. bang)
    if reward then
        valueText:SetTextColor(unpack(reward.color))
    else
        valueText:SetTextColor(1, 1, 1)
    end
end

local function Layout()
    local tier = max(1, min(S.combo, 4))
    local cfg = TIERS[tier]
    local harvest = S.harvest
    local size = harvest and (harvest.bonus and 34 or 30 + min(harvest.count - 1, 7) * 2) or cfg.size
    valueText:SetFont(FONT, size, "THICKOUTLINE")
    ShowValue()

    if S.combo >= 2 or (harvest and S.combo == 1) then
        local label = S.combo <= 2 and "COMBO x%d" or (S.combo == 3 and "x%d  HEATING UP!" or "x%d  ON FIRE!!")
        comboText:SetFont(FONT, 26 + 2 * tier, "THICKOUTLINE")
        label = string.format(label, S.combo)
        if S.lotus then label = label .. string.format("  |cffc77dffLOTUS x%d|r", 2 ^ S.lotus) end
        comboText:SetText(label)
        comboText:Show()
    else
        comboText:Hide()
    end

    local n = min(#S.order, MAX_LINES)
    S.rowY = harvest and -46 or -12
    S.flashLine = nil
    for i = 1, MAX_LINES do
        local fs = lines[i]
        local it = S.items[S.order[i]]
        local reward = it and REWARDS[it.tier]
        local aura = auras[i]
        if i <= n then
            fs:ClearAllPoints()
            fs:SetPoint("CENTER", text, "CENTER", 0, S.rowY - (i - 1) * 26)
            local name = it.name
            if reward and reward.color then
                name = name:gsub("^|c%x%x%x%x%x%x%x%x", ""):gsub("|r$", "")
                fs:SetTextColor(unpack(reward.color))
            else
                fs:SetTextColor(1, 1, 1)
            end
            fs:SetFormattedText("|T%s:0|t %d %s", it.icon or 134400, it.count, name)
            fs:Show()
            if it == S.flashItem and not reward then S.flashLine = i end
        else
            fs:Hide()
        end
        if reward then
            lineWidths[i] = fs:GetStringWidth()
            aura:SetSize(lineWidths[i] + 70, 34)
            local r, g, b = unpack(reward.aura)
            aura:SetVertexColor(r, g, b, 0.40 + 0.12 * reward.power)
        end
        aura:SetShown(reward ~= nil)
    end
    local barY = S.rowY - n * 26 + 8
    barBg:ClearAllPoints()
    barBg:SetPoint("CENTER", text, "CENTER", 0, barY)
    bar:ClearAllPoints()
    bar:SetPoint("LEFT", barBg, "LEFT", 1, 0)
end

local function EndCelebration()
    root:Hide()
    root:SetScript("OnUpdate", nil)
    NS.FX.Clear(root)
    NS.FX.Clear(text)
    S = nil
end

local function OnUpdate(_, dt)
    local db = DB()
    if not db or not db.showFx or db.disabled then
        EndCelebration()
        StopRegularSound()
        return
    end
    local now = GetTime()
    local t = now - S.slamAt
    local left = Window() - (now - S.lastStep)
    local tier = max(1, min(S.combo, 4))
    local cfg = TIERS[tier]
    local harvest = S.harvest

    if S.regularSoundAt and now >= S.regularSoundAt then
        S.regularSoundAt = nil
        if left > 0 and not RewardSoundPlaying(now) then
            StopRegularSound()
            regularSound = PlayClip(COMBO_SOUNDS[tier])
        end
    end

    -- Window over: fade out, then end the session.
    local a = min(1, t / 0.08)
    if left <= 0 then
        local f = 1 + left / 0.6
        if f <= 0 then
            EndCelebration()
            return
        end
        a = a * f
    end
    text:SetAlpha(a)

    -- Herbalism hits settle sooner so every count reads before the next beat.
    local start = harvest and (harvest.bonus and 1.6 or 1.18 + harvest.heat * 0.06) or cfg.start
    local scale = 1 + (start - 1) * exp(-t * 7) * cos(t * 16)
    if scale < 0.85 then scale = 0.85 end
    text:SetScale(scale)

    -- Shake: a hit on each mine, then a low rumble while burning.
    local shake = harvest and (2 + harvest.heat) or cfg.shake
    local amp = shake * (exp(-t * 4) + (tier >= 3 and 0.18 or 0))
    text:ClearAllPoints()
    text:SetPoint("CENTER", root, "CENTER", (random() - 0.5) * 2 * amp, (random() - 0.5) * 2 * amp)

    -- Newest item line flashes gold for a moment.
    if S.flashLine and lines[S.flashLine] then
        local f = max(0, 1 - t / 0.8)
        lines[S.flashLine]:SetTextColor(1, 1 - 0.2 * f, 1 - 0.8 * f)
    end

    if S.rewardTier and now >= S.rewardUntil then
        S.rewardTier = nil
        ShowValue()
    end
    local reward = REWARDS[S.rewardTier]
    local flare = reward and (reward.power - 1) * (S.rewardUntil - now) / reward.duration or 0
    if reward then
        comboText:SetTextColor(unpack(reward.color))
    elseif tier == 3 then
        local f = 0.5 + 0.5 * sin(t * 9)
        comboText:SetTextColor(1, 0.55 + 0.25 * f, 0.1)
    elseif tier >= 4 then
        local f = 0.5 + 0.5 * sin(t * 14)
        comboText:SetTextColor(1, 0.25 + 0.6 * f, 0.05 + 0.2 * f)
    else
        comboText:SetTextColor(1, 0.82, 0.2)
    end

    -- Countdown bar.
    local frac = max(0, min(1, left / Window()))
    bar:SetWidth(max(0.01, 218 * frac))
    bar:SetColorTexture(1, 0.35 + 0.45 * frac, 0.1 + 0.15 * frac, 0.95)

    -- Fire behind the text while the combo is alive.
    local width = max(valueText:GetStringWidth(), comboText:IsShown() and comboText:GetStringWidth() or 0) * scale
    local fireRate = cfg.fire + flare * 220
    if harvest then fireRate = fireRate + 8 + 5 * harvest.heat end
    if fireRate > 0 and left > 0 then
        S.fireAcc = S.fireAcc + min(dt, 0.1) * fireRate
        while S.fireAcc >= 1 do
            S.fireAcc = S.fireAcc - 1
            Flame(tier, width, 1 + flare)
        end
    end
    if left > 0 and now >= (S.nextEmberAt or 0) then
        S.nextEmberAt = now + 0.12
        for i = 1, min(#S.order, MAX_LINES) do
            local rowReward = REWARDS[S.items[S.order[i]].tier]
            if not rowReward then break end
            local power = rowReward.power
            local r, g, b = unpack(rowReward.aura)
            auras[i]:SetVertexColor(r, g, b, 0.40 + 0.12 * power + 0.09 * sin(now * 9 + i))
            NS.FX.Spawn(text, (random() - 0.5) * lineWidths[i], S.rowY - 8 - (i - 1) * 26, {
                layer = "BORDER", life = 0.32 + random() * 0.18, size = 12 + 6 * power, grow = -0.75,
                vx = (random() - 0.5) * 30 * power, vy = 24 + random() * 38 * power, alpha = 0.78,
                r = 1, g = 0.85, b = 0.35, r2 = 1, g2 = 0.20, b2 = 0.04,
            })
        end
    end
    local w = max(width, 220) + 160
    backGlow:SetSize(w, 190 * scale)
    local glow = cfg.glow + flare + (harvest and 0.04 * harvest.heat or 0)
    backGlow:SetVertexColor(1, 0.45, 0.08, min(1, glow) * a * (0.75 + 0.25 * sin(t * 11)))
end

local function BeginStep(now, points, sameMine)
    if not S or now - S.lastStep > Window() then
        NS.FX.Clear(root)
        NS.FX.Clear(text)
        S = { items = {}, order = {}, total = 0, combo = 0, fireAcc = 0 }
    end
    S.combo = S.combo + points
    S.lastStep = now
    if not sameMine then S.slamAt = now end
end

local function TallyItem(item, count, unitValue, tier)
    local key = item.link:match("item:(%d+)") or item.link
    local entry = S.items[key]
    if not entry then
        entry = { icon = item.icon, count = 0, name = item.link, tier = tier }
        S.items[key] = entry
        local pos = #S.order + 1
        while pos > 1 and S.items[S.order[pos - 1]].tier > tier do
            pos = pos - 1
        end
        table.insert(S.order, pos, key)
    end
    entry.count = entry.count + count
    S.total = S.total + unitValue * count
    S.flashItem = entry
end

local function ShowCelebration()
    Layout()
    root:Show()
    root:SetScript("OnUpdate", OnUpdate)
end

-- items: { { link=, icon=, count= }, ... }
-- sameMine: more loot from the mine already counted (no combo step, no slam).
local function AddMine(items, sameMine, preview)
    local db = DB()
    if not db or not db.showFx or #items == 0 then return end
    local now = GetTime()

    sameMine = sameMine and S and now - S.lastStep <= Window()
    BeginStep(now, sameMine and 0 or 1, sameMine)
    S.harvest = nil

    local rewardTier = math.huge
    for _, it in ipairs(items) do
        local key = it.link:match("item:(%d+)") or it.link
        local itemTier = REWARD_BY_ITEM[tonumber(key)] or math.huge
        rewardTier = min(rewardTier, itemTier)
        TallyItem(it, it.count, UnitValue(it.link), itemTier)
    end

    if S.rewardTier and now >= S.rewardUntil then S.rewardTier = nil end
    local reward = REWARDS[rewardTier]
    if reward and reward.duration and (not S.rewardTier or rewardTier <= S.rewardTier) then
        S.rewardTier, S.rewardUntil = rewardTier, now + reward.duration
    end
    ShowCelebration()
    if reward and reward.duration then
        Burst(4, reward.power)
    elseif not sameMine then
        Burst(min(S.combo, 4), 1)
    end
    if reward then
        S.regularSoundAt = nil
        StopRegularSound()
        RewardSoundPlaying(now)
        local sound = reward.sound
        if rewardTier == 1 and not preview and random(100) == 1 then
            sound = "Areeeeeee-boosted.wav"
        end
        local handle = PlayClip(sound)
        if handle then rewardSounds[handle] = now + reward.soundLength end
    elseif not sameMine and not RewardSoundPlaying(now) then
        S.regularSoundAt = now + LOOT_SOUND_DELAY
    end
end

-------------------------------------------------------------------------------
-- Herbalism reveal queue. A stack advances one item at a time, then its
-- bonuses land as separate beats. The queue can span more than one harvest.
-------------------------------------------------------------------------------
local revealQueue = {}
local nextHerbBeat = 0
local ev = CreateFrame("Frame")
local gather

-- Black Lotus: each one dropped doubles the combo, with its own sound for
-- the first, second and third-or-later Lotus in the same combo.
local BLACK_LOTUS = { [13468] = true, [248822] = true }
local LOTUS_SOUNDS = {
    { file = "HHHHAWW.wav", length = 1.85 },
    { file = "Howyalikedathuh.wav", length = 0.98 },
    { file = "Mirror.wav", length = 5.04 },
}

local function RevealHerb(item, count, bonus)
    local now = GetTime()
    BeginStep(now, bonus and 0 or 1)
    local amount = bonus and count or 1
    local lotus = BLACK_LOTUS[tonumber(item.link:match("item:(%d+)"))]
    if lotus then
        S.lotus = (S.lotus or 0) + amount
        S.combo = S.combo * 2 ^ amount
    end
    local heat = bonus and 7 or min(8, min(S.combo, 4) + count - 1)
    TallyItem(item, amount, item.unitValue, math.huge)
    S.harvest = { item = item, count = count, bonus = bonus, heat = heat, value = item.unitValue * count }
    S.regularSoundAt = nil
    ShowCelebration()
    if lotus then
        Burst(4, 2)
        StopRegularSound()
        for handle in pairs(rewardSounds) do
            if StopSound then pcall(StopSound, handle, 0) end
            rewardSounds[handle] = nil
        end
        local sound = LOTUS_SOUNDS[min(S.lotus, #LOTUS_SOUNDS)]
        local handle = PlayClip(sound.file)
        if handle then rewardSounds[handle] = now + sound.length end
        return
    end

    NS.FX.Spawn(root, 0, 24, {
        tex = MEDIA .. "Ring", layer = "BORDER", sub = 3,
        life = 0.28 + heat * 0.023, size = 38 + heat * 6, grow = 3, alpha = 0.8,
        r = bonus and 0.56 or 1, g = bonus and 1 or 0.78, b = 0.28,
    })
    Burst(max(1, min(S.combo, 4)), (bonus and 1.3 or 0.55 + heat * 0.09))
    if not RewardSoundPlaying(now) then
        StopRegularSound()
        regularSound = PlayClip(bonus and "Master.wav" or COMBO_SOUNDS[min(4, S.combo)])
    end
end

-- Some bonus drops are themselves classified as herbs or crafting reagents.
local BONUS_ITEMS = {
    [2452] = true, -- Swiftthistle
    [249399] = true, [249424] = true, [249274] = true, -- Frilled Lichen, Rosecap, Stranglevine
    [268415] = true, [268416] = true, [268417] = true, [268418] = true, -- Herb Seeds
}
local GetItemInfoInstant = C_Item and C_Item.GetItemInfoInstant or _G.GetItemInfoInstant
local TRADE_GOODS = Enum and Enum.ItemClass and Enum.ItemClass.Tradegoods or 7

local function HerbRank(id)
    if BONUS_ITEMS[id] then return 0 end
    -- A Lotus can headline its own pickup, or be the bonus when another herb led the drop.
    if id == 13468 or id == 248822 then return 2 end
    local class, subclass
    if GetItemInfoInstant then class, subclass = select(6, GetItemInfoInstant(id)) end
    if not class then class, subclass = select(12, NS.GetItemInfo(id)) end
    if not class then return 1 end
    return class == TRADE_GOODS and subclass == 9 and 3 or 0
end

local function ConsiderPrimary(harvest, id)
    local rank = HerbRank(id)
    if rank > (harvest.primaryRank or 0) then
        harvest.primary, harvest.primaryRank = id, rank
    end
end

local function FlushHarvest(harvest, finish)
    harvest.flushAt = nil
    local main = harvest.items[harvest.primary]
    if main and main.pending > 0 then
        local first = main.queued + 1
        main.queued = main.queued + main.pending
        main.pending = 0
        harvest.primaryQueued = true
        revealQueue[#revealQueue + 1] = { item = main, count = first, last = main.queued }
    end
    -- With manual looting, keep early bonus receipts behind the rest of the herb.
    if not finish and harvest.lootOpen and (harvest.slots[harvest.primary] or 0) > 0 then return end
    for _, entry in ipairs(harvest.order) do
        if entry.pending > 0 then
            revealQueue[#revealQueue + 1] = { item = entry, count = entry.pending, bonus = true }
            entry.pending = 0
        end
    end
end

local function UpdateHarvest(self)
    local db = DB()
    local now = GetTime()
    if not db or not db.showFx or db.disabled then
        revealQueue, gather, nextHerbBeat = {}, nil, 0
    elseif gather and gather.flushAt and now >= gather.flushAt then
        FlushHarvest(gather)
    end
    local step = revealQueue[1]
    if step and now >= nextHerbBeat then
        RevealHerb(step.item, step.count, step.bonus)
        if step.bonus or step.count == step.last then
            table.remove(revealQueue, 1)
        else
            step.count = step.count + 1
        end
        nextHerbBeat = now + HERB_BEAT
    end
    if #revealQueue == 0 and not (gather and gather.flushAt) then
        self:SetScript("OnUpdate", nil)
    end
end

local function CaptureHarvestLoot(harvest, id, link, icon, count, now)
    if harvest.slots then
        count = min(count, harvest.slots[id] or 0)
        if count <= 0 then return end
        harvest.slots[id] = harvest.slots[id] - count
    end
    local entry = harvest.items[id]
    if not entry then
        if not harvest.slots and not harvest.primaryQueued then ConsiderPrimary(harvest, id) end
        entry = { link = link, icon = icon, unitValue = UnitValue(link), pending = 0, queued = 0 }
        harvest.items[id] = entry
        harvest.order[#harvest.order + 1] = entry
    end
    entry.pending = entry.pending + count
    harvest.flushAt = harvest.flushAt or (now + LOOT_SOUND_DELAY)
    ev:SetScript("OnUpdate", UpdateHarvest)
end

-------------------------------------------------------------------------------
-- Detect gathering casts and confirm items from the player's loot receipts.
-------------------------------------------------------------------------------
local function SpellName(id)
    if C_Spell and C_Spell.GetSpellInfo then
        local info = C_Spell.GetSpellInfo(id)
        return info and info.name
    end
    return GetSpellInfo and (GetSpellInfo(id))
end

local MINING_IDS = { [2575] = true, [2576] = true, [3564] = true, [10248] = true, [29354] = true }
local HERBALISM_IDS = { [2366] = true, [2368] = true, [3570] = true, [11993] = true }
local miningName, herbalismName
local minedAt, counted
local CAPTURE = 4 -- Receipt fallback if the cast didn't expose a loot window.

local function SnapshotHarvestLoot(harvest)
    if not GetNumLootItems or not GetLootSlotLink then return end
    local slots = {}
    for slot = 1, NS.Num(GetNumLootItems()) or 0 do
        local link = NS.Num(GetLootSlotLink(slot))
        local id = link and tonumber(link:match("item:(%d+)"))
        if id then
            local count = GetLootSlotInfo and NS.Num(select(3, GetLootSlotInfo(slot)))
            slots[id] = (slots[id] or 0) + (count and count > 0 and count or math.huge)
            if not harvest.primaryQueued then ConsiderPrimary(harvest, id) end
        end
    end
    if not next(slots) then return end
    harvest.slots, harvest.lootOpen = slots, true
end

-- Your own loot lines start with the text before %s in these globals
-- ("You receive loot: ", "You receive item: "). Match leniently: any of your
-- loot lines that carries an item link counts.
local PREFIXES = {}
for _, key in ipairs({ "LOOT_ITEM_SELF", "LOOT_ITEM_SELF_MULTIPLE", "LOOT_ITEM_PUSHED_SELF", "LOOT_ITEM_PUSHED_SELF_MULTIPLE" }) do
    local fmt = _G[key]
    local prefix = type(fmt) == "string" and fmt:match("^(.-)%%s")
    if prefix and prefix ~= "" then PREFIXES[#PREFIXES + 1] = prefix end
end

local function IsSelfLoot(msg, guid)
    local me = UnitGUID and NS.Num(UnitGUID("player"))
    if guid and me and guid ~= "" and guid == me then return true end
    for _, prefix in ipairs(PREFIXES) do
        if msg:sub(1, #prefix) == prefix then return true end
    end
    return false
end

local function ParseSelfLoot(msg)
    local itemString = msg:match("|H(item:[^|]+)|h")
    if not itemString then return nil end
    local _, link = NS.GetItemInfo(itemString)
    link = link or msg:match("(|c.-|Hitem:.-|h.-|h|r)") or msg:match("(|H.-|h.-|h)")
    -- Count: "x2" right after the link (with or without colour reset / full stop).
    local count = msg:match("|h|r[^%d]-x(%d+)") or msg:match("|hx(%d+)") or msg:match("x(%d+)%.?%s*$")
    return link, tonumber(count) or 1, itemString
end

local function Debug(...)
    local db = DB()
    if db and db.debugLoot then
        DEFAULT_CHAT_FRAME:AddMessage("|cff40e0ffFarmRoute loot:|r " .. string.join(" ", tostringall(...)))
    end
end

ev:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
ev:RegisterEvent("CHAT_MSG_LOOT")
ev:RegisterEvent("LOOT_READY")
ev:RegisterEvent("LOOT_OPENED")
ev:RegisterEvent("LOOT_CLOSED")
ev:SetScript("OnEvent", function(_, event, ...)
    local db = DB()
    if not db or db.disabled then return end
    local now = GetTime()
    if event == "UNIT_SPELLCAST_SUCCEEDED" then
        local _, _, spellID = ...
        if not NS.Num(spellID) then return end
        miningName = miningName or SpellName(2575) or "Mining"
        herbalismName = herbalismName or SpellName(2366) or "Herb Gathering"
        local name = SpellName(spellID)
        local mining = MINING_IDS[spellID] or name == miningName
        local herbalism = HERBALISM_IDS[spellID] or name == herbalismName
        if mining or herbalism then
            if gather then FlushHarvest(gather, true) end
            if #revealQueue > 0 then ev:SetScript("OnUpdate", UpdateHarvest) end
            gather = herbalism and { castAt = now, items = {}, order = {} } or nil
            minedAt, counted = mining and now or nil, false
            Debug(herbalism and "herbalism cast" or "mining cast", spellID, name)
        end
    elseif event == "LOOT_READY" or event == "LOOT_OPENED" then
        if gather and not gather.slots and now - gather.castAt <= CAPTURE then SnapshotHarvestLoot(gather) end
    elseif event == "LOOT_CLOSED" then
        if not gather or not gather.lootOpen then return end
        gather.lootOpen, gather.closedAt = false, now
        gather.flushAt = gather.flushAt or (now + LOOT_SOUND_DELAY)
        ev:SetScript("OnUpdate", UpdateHarvest)
    elseif event == "CHAT_MSG_LOOT" then
        local msg = ...
        local guid = select(12, ...)
        -- The engine can hand back secret values; those can't be read.
        if issecretvalue and (issecretvalue(msg) or issecretvalue(guid)) then return end
        msg = msg or ""
        local castAt = gather and gather.castAt or minedAt
        if not castAt then return end
        local age = now - castAt
        Debug(string.format("%.1fs after cast:", age), (msg:gsub("|", "||")))
        if gather and gather.slots then
            if not gather.lootOpen and now - gather.closedAt > LOOT_SOUND_DELAY then return end
        elseif age > CAPTURE then
            return
        end
        if not IsSelfLoot(msg, guid) then
            Debug("not your loot")
            return
        end
        local link, count, itemString = ParseSelfLoot(msg)
        if not link then
            Debug("no item link found")
            return
        end
        local icon = NS.ItemIcon(itemString) or 134400
        if gather and db.showFx then
            local id = tonumber(itemString:match("item:(%d+)"))
            if id then CaptureHarvestLoot(gather, id, link, icon, count, now) end
        elseif not gather then
            AddMine({ { link = link, icon = icon, count = count } }, counted)
            counted = true
        end
    end
end)

-------------------------------------------------------------------------------
-- Preview: /farm test  (run it again within the window to build a combo)
-------------------------------------------------------------------------------
local TEST_ITEMS = { 2772, 7912, 2770, 2775 } -- Iron Ore, Solid Stone, Copper Ore, Silver Ore
local TEST_REWARDS = { 12363, 12361, 12364 }

function NS.TestCelebration(tier)
    local rewardID = TEST_REWARDS[tier]
    local items = {}
    for n = 1, rewardID and 1 or random(1, 2) do
        local id = rewardID or TEST_ITEMS[n == 1 and 1 or random(2, #TEST_ITEMS)]
        local name, link, _, _, _, _, _, _, _, icon = NS.GetItemInfo(id)
        items[#items + 1] = { link = link or ("|Hitem:" .. id .. "|h[Item " .. id .. "]|h"), icon = icon or 134579,
            count = random(1, 3) }
        if not name then NS.GetItemInfo(id) end
    end
    AddMine(items, false, true)
end

function NS.TestHarvestCelebration()
    local db = DB()
    if not db or not db.showFx or db.disabled then return end
    local items = {}
    for _, sample in ipairs({ { 13468, "Black Lotus", 3 }, { 268415, "Commonplace Herb Seeds", 1 } }) do
        local id, name, count = unpack(sample)
        local _, link = NS.GetItemInfo(id)
        link = link or ("|Hitem:" .. id .. "|h[" .. name .. "]|h")
        items[id] = { link = link, icon = NS.ItemIcon(id) or 134400, unitValue = UnitValue(link), pending = count, queued = 0 }
    end
    FlushHarvest({ primary = 13468, items = items, order = { items[13468], items[268415] } }, true)
    ev:SetScript("OnUpdate", UpdateHarvest)
end
