local ADDON_NAME, FRNS_ = ...; local NS = FRNS_.Gathering

ForeverFarmRouteGatheringDB = ForeverFarmRouteGatheringDB or {}

local DEFAULTS = {
    version = 14,
    toggleKey = nil,
    nodeLocations = {version = 1, maps = {}},
    refinedNodeHints = {version = 1, maps = {}},
    hud = {
        enabled = false,
        size = 430,
        overlayStrata = "HIGH",
        overlayLevel = 200,
        positionStyle = "ARROW",
        positionSize = 40,
        positionOpacity = 1,
        positionColor = "WHITE",
        mapAlpha = 0.08,
        zoom = 0,
        locked = true,
        mouseMode = false,
        mouseModifier = "NONE",
        rotationMode = "ON",
        hideAddonOverlays = false,
        autoTracking = false,
        autoTrackingWithHUD = false,
        autoTrackingWithFarmHUD = true, -- FarmRoute: swap while the /farm HUD is open
        trackingSwapsPaused = false,
        autoTrackingInDungeons = false,
        restoreTracking = true,
        includeTreasure = false,
        rememberNodes = true,
        experimentalHUD = false,
        showScanStatus = false,
        nodeIconSize = 14,
        trackingInterval = 2, -- FarmRoute: swap every 2 s, scan right after
        x = 0,
        y = 0,
    },
    quickScan = {duration = 1.5, trigger = "swap", interval = 10},
    minimap = {
        fullTimeScanning = false,
        hide = false,
        minimapPos = 220,
    },
}

local function DeepCopyDefaults(src, dst)
    for k, v in pairs(src) do
        if type(v) == "table" then
            if type(dst[k]) ~= "table" then
                dst[k] = {}
            end
            DeepCopyDefaults(v, dst[k])
        elseif dst[k] == nil then
            dst[k] = v
        end
    end
end

local function Print(first, second)
    -- Accept both NS.Print(message) and legacy NS:Print(message) safely.
    local msg = second ~= nil and second or first
    DEFAULT_CHAT_FRAME:AddMessage("|cffff8c42FarmRoute Gathering:|r " .. tostring(msg))
end

NS.Print = Print

function NS:InitDB()
    ForeverFarmRouteGatheringDB = ForeverFarmRouteGatheringDB or {}

    local oldVersion = tonumber(ForeverFarmRouteGatheringDB.version) or 0
    local legacyMinimapPos
    if ForeverFarmRouteGatheringDB.minimap then
        legacyMinimapPos = ForeverFarmRouteGatheringDB.minimap.minimapPos
            or ForeverFarmRouteGatheringDB.minimap.angle
            or ForeverFarmRouteGatheringDB.minimap.minimapAngle
            or ForeverFarmRouteGatheringDB.minimap.minimapPosition
    end

    DeepCopyDefaults(DEFAULTS, ForeverFarmRouteGatheringDB)
    -- Quick scanning is the only supported selection; activation stays session-only.
    ForeverFarmRouteGatheringDB.hud.scanner = "quick"
    ForeverFarmRouteGatheringDB.minimap.scanner = "quick"
    ForeverFarmRouteGatheringDB.minimap.fullTimeScanning = false
    -- Earlier HUD-linked settings allowed both choices; retain the effective mode.
    if ForeverFarmRouteGatheringDB.hud.autoTrackingWithHUD then
        ForeverFarmRouteGatheringDB.hud.autoTracking = false
    end
    -- The hotkey pause lasts only for this session; saved automation wins on login.
    ForeverFarmRouteGatheringDB.hud.trackingSwapsPaused = false
    ForeverFarmRouteGatheringDB.hud.pausedTrackingSpell = nil
    -- The retired height experiment recorded a placeholder Z coordinate.
    -- Remove only its optional fields; retain every location and other data.
    for _, rows in pairs(ForeverFarmRouteGatheringDB.nodeLocations.maps) do
        if type(rows) == "table" then
            for _, row in pairs(rows) do
                if type(row) == "table" then
                    row.heightZ, row.heightWorld, row.heightRadius = nil, nil, nil
                end
            end
        end
    end
    -- Language selection has been removed; keep the interface in English.
    ForeverFarmRouteGatheringDB.language = nil

    -- 0.1.0 used a nearly opaque minimap by default.
    -- Migrate existing test installs to the intended transparent HUD behavior.
    if oldVersion < 2 then
        if ForeverFarmRouteGatheringDB.hud and (ForeverFarmRouteGatheringDB.hud.mapAlpha == nil or ForeverFarmRouteGatheringDB.hud.mapAlpha >= 0.50) then
            ForeverFarmRouteGatheringDB.hud.mapAlpha = 0.08
        end
    end

    -- 0.1.0-0.1.2 stored the custom minimap button angle as db.minimap.angle.
    -- LibDBIcon uses db.minimap.minimapPos. Preserve the existing position.
    if ForeverFarmRouteGatheringDB.minimap then
        if oldVersion < 3 and legacyMinimapPos ~= nil then
            ForeverFarmRouteGatheringDB.minimap.minimapPos = legacyMinimapPos
        end
        ForeverFarmRouteGatheringDB.minimap.angle = nil
        ForeverFarmRouteGatheringDB.minimap.minimapAngle = nil
        ForeverFarmRouteGatheringDB.minimap.minimapPosition = nil
    end

    -- Dungeon rotation is opt-in; preserve explicit saved choices.
    if type(ForeverFarmRouteGatheringDB.hud.autoTrackingInDungeons) ~= "boolean" then
        ForeverFarmRouteGatheringDB.hud.autoTrackingInDungeons = false
    end

    -- Validate temporary mouse modifier.
    if ForeverFarmRouteGatheringDB.hud then
        local modifier = ForeverFarmRouteGatheringDB.hud.mouseModifier
        if modifier ~= "NONE" and modifier ~= "ALT" and modifier ~= "CTRL" and modifier ~= "SHIFT" then
            ForeverFarmRouteGatheringDB.hud.mouseModifier = "NONE"
        end
    end

    local hud = ForeverFarmRouteGatheringDB.hud
    local strata = {LOW=true, MEDIUM=true, HIGH=true, DIALOG=true}
    local styles = {CROSS=true, DOT=true, RING=true, ARROW=true, NONE=true}
    local colors = {CYAN=true, WHITE=true, GOLD=true, GREEN=true, PINK=true}
    if not strata[hud.overlayStrata] then hud.overlayStrata = "HIGH" end
    if not styles[hud.positionStyle] then hud.positionStyle = "ARROW" end
    if not colors[hud.positionColor] then hud.positionColor = "WHITE" end
    for _, spec in ipairs({{"overlayLevel",200,1,200}, {"positionSize",40,8,64}, {"positionOpacity",1,0.1,1}}) do
        local value = tonumber(hud[spec[1]])
        if not value or value ~= value or math.abs(value) == math.huge then value = spec[2] end
        value = math.max(spec[3], math.min(spec[4], value))
        hud[spec[1]] = spec[1] == "positionOpacity" and value or math.floor(value + 0.5)
    end

    -- Validate HUD minimap rotation mode.
    if ForeverFarmRouteGatheringDB.hud then
        local rotationMode = ForeverFarmRouteGatheringDB.hud.rotationMode
        if rotationMode ~= "CLIENT" and rotationMode ~= "ON" and rotationMode ~= "OFF" then
            ForeverFarmRouteGatheringDB.hud.rotationMode = "ON"
        end
    end

    -- 1.2.0/1.2.1 hid every visible Minimap child when third-party
    -- overlay hiding was enabled. On Forever this can include Blizzard's
    -- own internal minimap frames and may leave the normal minimap empty
    -- after HUD mode is disabled. Reset the option once on upgrade; the
    -- new implementation below only targets known third-party frames.
    if oldVersion < 14 and ForeverFarmRouteGatheringDB.hud then
        ForeverFarmRouteGatheringDB.hud.hideAddonOverlays = false
    end

    -- Preserve the user's launcher visibility preference across reloads.
    if ForeverFarmRouteGatheringDB.minimap then
        ForeverFarmRouteGatheringDB.minimap.hideExplicit = nil
    end

    -- The in-HUD settings launcher has been removed.
    ForeverFarmRouteGatheringDB.hud.showHUDLauncher = nil
    -- The decorative HUD ring is always hidden; its old opacity had no effect.
    ForeverFarmRouteGatheringDB.hud.ringAlpha = nil
    -- HUD wheel input always passes through; toggles always wait for combat.
    ForeverFarmRouteGatheringDB.hud.captureMouseWheel = nil
    ForeverFarmRouteGatheringDB.hud.combatToggle = nil
    -- Forever no longer allows changing the native minimap player texture.
    ForeverFarmRouteGatheringDB.hud.hidePlayerArrow = nil

    if type(ForeverFarmRouteGatheringDB.hud.restoreTracking) ~= "boolean" then
        ForeverFarmRouteGatheringDB.hud.restoreTracking = true
    end

    if type(ForeverFarmRouteGatheringDB.hud.experimentalHUD) ~= "boolean" then
        ForeverFarmRouteGatheringDB.hud.experimentalHUD = false
    end

    -- FarmRoute 2026-11-20: swap every 2 s and scan for 1.5 s right after; move saved settings over once.
    if not ForeverFarmRouteGatheringDB.farmTiming1 then
        ForeverFarmRouteGatheringDB.farmTiming1 = true
        ForeverFarmRouteGatheringDB.hud.trackingInterval = 2
        ForeverFarmRouteGatheringDB.quickScan.duration = 1.5
        ForeverFarmRouteGatheringDB.quickScan.trigger = "swap"
    end
    local interval = tonumber(ForeverFarmRouteGatheringDB.hud.trackingInterval) or 3.5
    if interval ~= interval then interval = 3.5 end
    ForeverFarmRouteGatheringDB.hud.trackingInterval = math.max(2, math.min(10, math.floor(interval * 2 + 0.5) / 2))
    local iconSize = tonumber(ForeverFarmRouteGatheringDB.hud.nodeIconSize) or 14
    if iconSize ~= iconSize then iconSize = 14 end
    ForeverFarmRouteGatheringDB.hud.nodeIconSize = math.max(8, math.min(32, math.floor(iconSize + 0.5)))
    ForeverFarmRouteGatheringDB.hud.farmIconSize = nil -- FarmRoute's /farm size sets HUD icons now

    ForeverFarmRouteGatheringDB.version = 14
    self.db = ForeverFarmRouteGatheringDB
end

function NS:ResetSettings()
    local questRecovery = self.db and self.db.questAreaRecovery
    local anonymousHints = self.db and self.db.anonymousRefinedNodeHints
    local hints = self.db and self.db.refinedNodeHints
    local locations = self.db and self.db.nodeLocations
    if self.ClearToggleKeybind then
        self:ClearToggleKeybind()
    end
    if self.ClearDismissKeybind then self:ClearDismissKeybind() end
    if self.ClearPauseKeybind then self:ClearPauseKeybind() end
    if self.ClearMinimapKeybind then self:ClearMinimapKeybind() end
    if self.ClearRememberNodeKeybind then self:ClearRememberNodeKeybind() end
    ForeverFarmRouteGatheringDB = {}
    self:InitDB()
    -- Reset display/tracking preferences without deleting learned locations.
    if type(locations) == "table" then self.db.nodeLocations = locations end
    if type(hints) == "table" then self.db.refinedNodeHints = hints end
    if type(anonymousHints) == "table" then self.db.anonymousRefinedNodeHints = anonymousHints end
    if type(questRecovery) == "table" then self.db.questAreaRecovery = questRecovery end
    if self.UpdateAll then self:UpdateAll() end
    if self.L and self.L.SETTINGS_RESET then
        Print(self.L.SETTINGS_RESET)
    end
end

function NS:ResetHUDPosition()
    if not self.db then return end
    self.db.hud.x = 0
    self.db.hud.y = 0
    if self.HUDFrame then
        self.HUDFrame:ClearAllPoints()
        self.HUDFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    end
    if self.db.hud.enabled and self.ApplyHUDLayout then
        self:ApplyHUDLayout()
    end
    Print(self.L.RESET_DONE)
end

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")

eventFrame:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
        NS:InitDB()

        -- Start with the normal minimap before settings initialize live sliders.
        NS.db.hud.enabled = false
        if NS.CreateHUD then NS:CreateHUD() end
        if NS.RegisterSettingsPanel then NS:RegisterSettingsPanel() end

        NS.pendingToggle = nil
        NS:UpdateAll()
    elseif event == "PLAYER_LOGIN" then
        if NS.RegisterSettingsPanel then NS:RegisterSettingsPanel() end
    elseif event == "PLAYER_REGEN_DISABLED" then
        if NS.db and NS.db.hud.enabled then
            NS:HideKnownMinimapAttachments()
            NS:HideEllesmereControls()
            NS:HideHUDMinimapRings()
            if not Minimap:IsProtected() then NS:KeepMinimapInHUD() end
        end
    elseif event == "PLAYER_REGEN_ENABLED" then
        if NS.pendingToggle ~= nil then
            local state = NS.pendingToggle
            NS.pendingToggle = nil
            NS:SetHUDEnabled(state)
        elseif NS.db and NS.db.hud.enabled then
            NS:HideKnownMinimapAttachments()
            NS:KeepMinimapInHUD()
        end
    end
end)

SLASH_FOREVERDUALGATHERING1 = "/fdg"
SLASH_FOREVERDUALGATHERING2 = "/foreverdualgathering"
SlashCmdList.FOREVERDUALGATHERING = function(msg)
    msg = string.lower((msg or ""):match("^%s*(.-)%s*$") or "")
    if msg == "toggle" then
        NS:ToggleHUD()
    elseif msg == "reset" then
        NS:ResetHUDPosition()
    elseif msg == "nodes" then
        if NS.DebugNodeGathering then NS:DebugNodeGathering() end
    elseif msg == "button" then
        if NS.DebugMinimapButton then
            NS:DebugMinimapButton()
        end
    else
        if NS.OpenSettings then NS:OpenSettings() end
        if msg ~= "" and NS.L and NS.L.SLASH_HELP then
            Print(NS.L.SLASH_HELP)
        end
    end
end

-- Clamp persisted values as well as values selected through the options panel.
function NS:GetQuickScanDuration()
    local value=self.db and self.db.quickScan and self.db.quickScan.duration
    if value=="continuous" then return math.huge end
    local v=tonumber(value) or 2
    return math.max(1.5,math.min(3,math.floor(v*2+.5)/2))
end
function NS:GetQuickScanInterval()
    local v=tonumber(self.db and self.db.quickScan and self.db.quickScan.interval) or 10
    return math.max(self:GetQuickScanDuration(),3,math.min(10,math.floor(v+.5)))
end
