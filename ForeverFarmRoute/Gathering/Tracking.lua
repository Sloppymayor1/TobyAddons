local ADDON_NAME, FRNS_ = ...; local NS = FRNS_.Gathering

local HERBS, MINERALS, TREASURE = 2383, 2580, 2481
local previousAuto, previousRestore, previousTreasure
local elapsed = 0
local lootOpen = false
local paused, switching = false, false
local pendingSpell, unconfirmedSpell, pendingNeedsMovement
local pausedRestorePending = false
local lastTracking
local recoveryGeneration = 0
local frame = CreateFrame("Frame")
frame:Hide()

local function IsPublic(value)
    return not (issecretvalue and issecretvalue(value))
end

local function IsDeadOrGhost()
    if type(UnitIsDeadOrGhost) ~= "function" then return false end
    local ok, dead = pcall(UnitIsDeadOrGhost, "player")
    return not ok or not IsPublic(dead) or not not dead
end

-- The minimap tracking click shares sound/interface/uchatscrollbutton.ogg.
-- Mute only that file for our API call, and always release it after an error.
local TRACKING_SWITCH_SOUND = 567407
local function SetTrackingQuietly(setTracking, index)
    local unmute
    if type(MuteSoundFile) == "function" and type(UnmuteSoundFile) == "function" then
        unmute = UnmuteSoundFile
        pcall(MuteSoundFile, TRACKING_SWITCH_SOUND)
    end
    local ok, result = pcall(setTracking, index, true)
    if unmute then pcall(unmute, TRACKING_SWITCH_SOUND) end
    return ok, result
end

local function Knows(spellID)
    if not IsPlayerSpell then return false end
    local ok, known = pcall(IsPlayerSpell, spellID)
    return ok and IsPublic(known) and known
end

function NS:CanUseFindTreasure()
    if type(UnitRace) ~= "function" then return false end
    local ok, _, race = pcall(UnitRace, "player")
    return ok and IsPublic(race) and race == "Dwarf" and Knows(TREASURE) == true
end

function NS:IsAutoTrackingEnabled()
    local hud = self.db and self.db.hud
    if not hud then return false end
    if hud.autoTrackingWithFarmHUD ~= false and self:FarmHUDOpen() then return true end
    if hud.autoTrackingWithHUD then return hud.enabled == true or self.MinimapScanActive == true end
    return hud.autoTracking == true
end

local function WantsTreasure()
    return NS.db and NS.db.hud.includeTreasure and NS:CanUseFindTreasure()
end

local function SpellDetails(spellID)
    if C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellTexture then
        local named, name = pcall(C_Spell.GetSpellName, spellID)
        local textured, texture = pcall(C_Spell.GetSpellTexture, spellID)
        return named and IsPublic(name) and name or nil, textured and IsPublic(texture) and texture or nil
    end
end

-- Resolve filters from a complete public client snapshot; indices are not IDs.
local trackerSpells = {HERBS, MINERALS, TREASURE}
local function GatheringTracking()
    local countReader = C_Minimap and C_Minimap.GetNumTrackingTypes
    local infoReader = C_Minimap and C_Minimap.GetTrackingInfo
    if not countReader or not infoReader then return end
    local ok, count = pcall(countReader)
    if not ok or not IsPublic(count) or type(count) ~= "number" or count ~= count or count == math.huge then return end
    local details, indices = {}, {}
    for _, spell in ipairs(trackerSpells) do
        local name, texture = SpellDetails(spell)
        details[spell] = {name = name, texture = texture}
    end
    local current, activeSpells, otherSpellActive = nil, {}, false
    for index = 1, count do
        local success, info = pcall(infoReader, index)
        if not success or not IsPublic(info) then return end
        if type(info) == "table" then
            local name, texture, active, spellID = info.name, info.texture, info.active, info.spellID
            if not IsPublic(spellID) then return end
            local matched
            for _, spell in ipairs(trackerSpells) do
                local detail = details[spell]
                if spellID == spell or (not spellID and IsPublic(name) and IsPublic(texture)
                    and ((detail.name and name == detail.name) or (detail.texture and texture == detail.texture))) then
                    matched = spell
                    break
                end
            end
            if matched then
                if not IsPublic(active) or type(active) ~= "boolean" then return end
                indices[matched] = index
                if active then
                    activeSpells[matched] = true
                    if matched ~= TREASURE then current = matched end
                end
            elseif IsPublic(info.type) and (info.type == "spell" or type(spellID) == "number") then
                if not IsPublic(active) or type(active) ~= "boolean" then return end
                if active then otherSpellActive = true end
            end
        end
    end
    return current, indices, activeSpells, otherSpellActive
end

function NS:GetActiveGatheringTracking()
    local spell, _, active = GatheringTracking()
    return spell, active and active[TREASURE] == true
end

local function AvailableGatheringTrackers(indices)
    local available = {}
    for _, spell in ipairs({HERBS, MINERALS}) do
        local kind = spell == HERBS and "herb" or "ore"
        local enabled = Knows(spell) and (not NS.HasGatheringProfession or NS:HasGatheringProfession(kind))
        if enabled and (not indices or indices[spell]) then available[#available + 1] = spell end
    end
    return available
end

local function Contains(available, spell)
    for _, candidate in ipairs(available) do if candidate == spell then return true end end
    return false
end

local function CanSwitch(stationary)
    if paused or not NS.db or (NS.db.hud.trackingSwapsPaused and not pausedRestorePending) or (not pausedRestorePending and not NS:IsAutoTrackingEnabled() and not NS.db.hud.restoreTracking and not WantsTreasure()) or lootOpen then return false end
    if (InCombatLockdown and InCombatLockdown()) or (UnitAffectingCombat and UnitAffectingCombat("player")) then return false end
    if IsDeadOrGhost() or (UnitOnTaxi and UnitOnTaxi("player")) then return false end
    if (IsStealthed and IsStealthed()) or (IsResting and IsResting()) then return false end
    if GetCursorInfo and GetCursorInfo() then return false end
    if C_Secrets then
        if C_Secrets.ShouldUnitStatsBeSecret and C_Secrets.ShouldUnitStatsBeSecret() then return false end
        if C_Secrets.ShouldUnitSpellCastingBeSecret and C_Secrets.ShouldUnitSpellCastingBeSecret("player") then return false end
    end
    if UnitCastingInfo then
        local casting = UnitCastingInfo("player")
        if not IsPublic(casting) or casting ~= nil then return false end
    end
    if UnitChannelInfo then
        local channel = UnitChannelInfo("player")
        if not IsPublic(channel) or channel ~= nil then return false end
    end
    if stationary then return true end
    local speed = GetUnitSpeed and GetUnitSpeed("player")
    return IsPublic(speed) and type(speed) == "number" and speed > 0
end

local function OnCooldown(spellID)
    if C_Secrets and C_Secrets.ShouldCooldownsBeSecret and C_Secrets.ShouldCooldownsBeSecret() then return true end
    local start, duration
    if C_Spell and C_Spell.GetSpellCooldown then
        local info = C_Spell.GetSpellCooldown(spellID)
        if not IsPublic(info) then return true end
        if info then start, duration = info.startTime, info.duration end
    end
    if not IsPublic(start) or not IsPublic(duration) then return true end
    return start and duration and start > 0 and duration > 0 and start + duration > GetTime()
end

local function PauseAutoTracking(unconfirmed)
    -- A later explicit rejection must not retain a recoverable confirmation.
    if not unconfirmed then unconfirmedSpell = nil end
    if paused or not NS.db or (not pausedRestorePending and not NS:IsAutoTrackingEnabled() and not NS.db.hud.restoreTracking and not WantsTreasure()) then return end
    unconfirmedSpell = unconfirmed and pendingSpell or nil
    paused = true
    frame:Hide()
    elapsed = 0
    pendingSpell = nil
    if NS.Print then
        NS.Print(unconfirmed and (NS.L.TRACKING_UNCONFIRMED or NS.L.TRACKING_PAUSED) or NS.L.TRACKING_PAUSED)
    end
end

function NS:RunAutoTracking()
    if not CanSwitch(true) then return end
    local inInstance = IsInInstance and IsInInstance()
    -- Only gathering rotation is opted in; independent recovery keeps its pause.
    if inInstance and not pausedRestorePending and not (NS:IsAutoTrackingEnabled() and NS.db.hud.autoTrackingInDungeons) then return end
    local setTracking = C_Minimap and C_Minimap.SetTracking
    -- The dedicated API can change a filter without a spell-cast event.
    -- Read its live state. Never assume an attempted switch succeeded.
    if type(setTracking) ~= "function" then return end
    local current, indices, activeSpells, otherSpellActive = GatheringTracking()
    if not indices then return end
    local available = AvailableGatheringTrackers()
    lastTracking = current
    -- Confirm the exact requested filter independently: treasure can coexist
    -- with either gathering filter and must never mask their live state.
    if pendingSpell then
        if pendingNeedsMovement and not CanSwitch(NS.CursorSweepActive==true) then return end
        if not activeSpells[pendingSpell] then PauseAutoTracking(true); return end
        if self.OnAutomaticGatheringSwitch and (pendingSpell==HERBS or pendingSpell==MINERALS) then
            self:OnAutomaticGatheringSwitch(pendingSpell)
        end
        pendingSpell = nil
    end
    -- Hold automatic rotation through quick startup and capture.
    local quick = self.QuickScanner
    if quick and ((quick.enabled and (quick.pending or quick.running))
        or quick.hudEnabled and (quick.pending or self.CursorSweepTrial.hudQuickPass)) then return end
    local nextSpell, rotating
    if NS.db.hud.trackingSwapsPaused then
        local target = NS.db.hud.pausedTrackingSpell
        if not pausedRestorePending then return end
        if target ~= HERBS and target ~= MINERALS then
            pausedRestorePending = false
            self:UpdateAutoTracking()
            return
        end
        if current == target then
            pausedRestorePending = false
            self:UpdateAutoTracking()
            return
        end
        if not Contains(available, target) or not indices[target] then return end
        nextSpell = target
    elseif not inInstance and WantsTreasure() and indices[TREASURE] and not activeSpells[TREASURE] then
        -- Repair the racial independently, including alongside a manually
        -- selected gathering filter and while standing still.
        nextSpell = TREASURE
    elseif not inInstance and NS.db.hud.restoreTracking and not otherSpellActive and #available >= 1 and not Contains(available, current) then
        -- Independently restore a missing gathering filter, even while still.
        -- With both professions and no selection, start with herbs.
        nextSpell = available[1]
        if not indices[nextSpell] then return end
    elseif NS:IsAutoTrackingEnabled() and #available >= 2 and indices[HERBS] and indices[MINERALS] and CanSwitch(NS.CursorSweepActive==true) then
        if self.IsCursorSweepSwapReady and not self:IsCursorSweepSwapReady() then return end
        nextSpell = current == HERBS and MINERALS or HERBS
        rotating = true
    else
        return
    end
    if OnCooldown(nextSpell) then return end
    local index = indices[nextSpell]
    switching = true
    local ok, result = SetTrackingQuietly(setTracking, index)
    switching = false
    -- A rejection never triggers a fallback through another API.
    if not ok or (IsPublic(result) and result == false) then
        PauseAutoTracking()
    elseif not paused then
        local active, _, confirmed = GatheringTracking()
        lastTracking = active
        if not confirmed or not confirmed[nextSpell] then
            pendingSpell, pendingNeedsMovement = nextSpell, rotating
        elseif self.OnAutomaticGatheringSwitch and (nextSpell==HERBS or nextSpell==MINERALS) and current~=nextSpell then
            self:OnAutomaticGatheringSwitch(nextSpell)
        end
    end
end

function NS:UpdateAutoTracking()
    -- Actual rejections require an explicit off/on retry. An unconfirmed change
    -- may also recover when a tracking event proves a gathering filter is active.
    local auto = self:IsAutoTrackingEnabled()
    local restore = self.db and self.db.hud.restoreTracking
    local treasure = WantsTreasure()
    local include = self.db and self.db.hud.includeTreasure
    if (not auto and not restore and not include) or (previousAuto and not auto)
        or (previousRestore and not restore) or (previousTreasure and not include) then
        paused, unconfirmedSpell, pendingSpell = false, nil, nil
    end
    previousAuto, previousRestore, previousTreasure = auto, restore, include
    local available = AvailableGatheringTrackers()
    if pendingSpell and not (pendingSpell == TREASURE and treasure) and not Contains(available, pendingSpell) then pendingSpell = nil end
    local enabled = not paused and self.db and (not self.db.hud.trackingSwapsPaused or pausedRestorePending) and not IsDeadOrGhost()
        and (pausedRestorePending or (auto and #available >= 2) or (restore and #available >= 1) or treasure)
        and C_Minimap and type(C_Minimap.SetTracking) == "function"
    if enabled then
        if not frame:IsShown() then
            elapsed = 0
            frame:Show()
        end
    else
        frame:Hide()
        elapsed = 0
        pendingSpell = nil
    end
end

-- FarmRoute: a swap the game didn't confirm or accept (often while the game
-- window is in the background) used to stop swapping until tracking was
-- switched off and on. While the /farm HUD is open, retry on our own.
function NS:RecoverPausedTracking()
    if not paused then return false end
    paused, unconfirmedSpell, pendingSpell = false, nil, nil
    self:UpdateAutoTracking()
    return true
end

-- Hotkey pause is independent of client rejection recovery and lasts this session.
function NS:SetTrackingSwapsPaused(value)
    if not self.db then return end
    -- An explicit pause/resume is also the user's retry after a failed
    -- tracking request. Do not leave the private failure latch set while
    -- the UI reports that automatic swaps have resumed.
    if not value and self.db.hud.trackingSwapsPaused then
        paused, unconfirmedSpell = false, nil
    end
    if value and not self.db.hud.trackingSwapsPaused then
        self.db.hud.pausedTrackingSpell = GatheringTracking()
    elseif not value then
        self.db.hud.pausedTrackingSpell = nil
    end
    pausedRestorePending = false
    self.db.hud.trackingSwapsPaused = value and true or false
    elapsed, pendingSpell, pendingNeedsMovement = 0, nil, nil
    self:UpdateAutoTracking()
end

function NS:ToggleTrackingSwapsPaused()
    if not self.db then return end
    self:SetTrackingSwapsPaused(not self.db.hud.trackingSwapsPaused)
    if self.Print then self.Print(self.db.hud.trackingSwapsPaused and "Automatic tracking swaps paused." or "Automatic tracking swaps resumed.") end
end

-- Life events can precede the client's restored spell/skill data. Recheck
-- availability briefly without opening the HUD or attempting tracking changes.
local recoveryDelays = { 0.25, 0.75, 1, 2 }
local function RefreshAfterResurrection(attempt, generation)
    if generation ~= recoveryGeneration or paused or not NS.db
        or (not pausedRestorePending and not NS:IsAutoTrackingEnabled() and not NS.db.hud.restoreTracking and not NS.db.hud.includeTreasure) then return end
    if attempt > 0 and frame:IsShown() then return end
    if NS.InvalidateGatheringSkills then NS:InvalidateGatheringSkills() end
    NS:UpdateAutoTracking()
    local delay = recoveryDelays[attempt + 1]
    if not frame:IsShown() and delay and C_Timer and type(C_Timer.After) == "function" then
        pcall(C_Timer.After, delay, function() RefreshAfterResurrection(attempt + 1, generation) end)
    end
end

frame:SetScript("OnUpdate", function(_, dt)
    elapsed = elapsed + dt
    if not NS.db then return end
    if elapsed < NS.db.hud.trackingInterval then return end
    elapsed = 0
    NS:RunAutoTracking()
end)

frame:RegisterEvent("LOOT_OPENED")
frame:RegisterEvent("LOOT_CLOSED")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("PLAYER_DEAD")
frame:RegisterEvent("PLAYER_ALIVE")
frame:RegisterEvent("PLAYER_UNGHOST")
frame:RegisterEvent("MINIMAP_UPDATE_TRACKING")
frame:RegisterEvent("SPELLS_CHANGED")
frame:RegisterEvent("SKILL_LINES_CHANGED")
frame:RegisterEvent("ADDON_ACTION_BLOCKED")
frame:RegisterEvent("ADDON_ACTION_FORBIDDEN")
frame:SetScript("OnEvent", function(_, event, addon, api)
    if event == "ADDON_ACTION_BLOCKED" or event == "ADDON_ACTION_FORBIDDEN" then
        if IsPublic(addon) and addon == ADDON_NAME and IsPublic(api) and type(api) == "string" then
            api = api:gsub("%(.*$", "")
            if switching or api == "C_Minimap.SetTracking" or api == "SetTracking" then
                PauseAutoTracking()
            end
        end
        return
    end
    if event == "PLAYER_DEAD" or event == "PLAYER_ALIVE" or event == "PLAYER_UNGHOST" then
        if NS.db and NS.db.hud.trackingSwapsPaused then
            -- Refresh from the last public live selection if the player changed
            -- tracking manually while paused; death may already have cleared it.
            local current = GatheringTracking()
            if event == "PLAYER_DEAD" and current then NS.db.hud.pausedTrackingSpell = current end
            local target = NS.db.hud.pausedTrackingSpell
            pausedRestorePending = (target == HERBS or target == MINERALS) and current ~= target
        end
        recoveryGeneration = recoveryGeneration + 1
        if unconfirmedSpell then paused, unconfirmedSpell = false, nil end
        elapsed, pendingSpell, lastTracking, lootOpen = 0, nil, nil, false
        frame:Hide()
        if NS.InvalidateGatheringSkills then NS:InvalidateGatheringSkills() end
        if event ~= "PLAYER_DEAD" then RefreshAfterResurrection(0, recoveryGeneration) end
        return
    end
    if event == "MINIMAP_UPDATE_TRACKING" then
        if switching then return end
        local current, indices, activeSpells = GatheringTracking()
        if indices then
            if NS.db and NS.db.hud.trackingSwapsPaused and not pausedRestorePending and current then
                NS.db.hud.pausedTrackingSpell = current
            end
            local available = AvailableGatheringTrackers(indices)
            local confirmedTreasure = unconfirmedSpell == TREASURE and WantsTreasure() and activeSpells[TREASURE]
            local confirmedGathering = unconfirmedSpell ~= TREASURE and Contains(available, current)
                and (current == unconfirmedSpell or current ~= lastTracking)
            if unconfirmedSpell and (confirmedTreasure or confirmedGathering) then
                paused, unconfirmedSpell, pendingSpell, elapsed = false, nil, nil, 0
            end
            -- Losing a previously observed filter (e.g. cancelling its buff)
            -- starts a fresh cycle. An unconfirmed request from an already
            -- empty state still pauses normally; never retry it indefinitely.
            if lastTracking and not current and pendingSpell ~= TREASURE then
                pendingSpell, elapsed = nil, 0
            end
            lastTracking = current
        end
        if not frame:IsShown() then
            if NS.InvalidateGatheringSkills then NS:InvalidateGatheringSkills() end
            NS:UpdateAutoTracking()
        end
        return
    end
    if event == "SPELLS_CHANGED" or event == "SKILL_LINES_CHANGED" or event == "PLAYER_ENTERING_WORLD" then
        if NS.InvalidateGatheringSkills then NS:InvalidateGatheringSkills() end
        NS:UpdateAutoTracking()
    end
    if event == "LOOT_OPENED" then
        lootOpen = true
    elseif event == "LOOT_CLOSED" or event == "PLAYER_ENTERING_WORLD" then
        lootOpen = false
    end
end)
