local ADDON_NAME, FRNS_ = ...; local NS = FRNS_.Gathering

local LDB = LibStub("LibDataBroker-1.1")
local LDBIcon = LibStub("ForeverDualGathering-LibDBIcon-1.0")

local OBJECT_NAME = "ForeverFarmRouteGathering"
local LAUNCHER_ICON = "Interface\\AddOns\\ForeverFarmRoute\\Gathering\\Media\\GatheringIcon.tga"
local BUTTON_FRAME_NAME = "LibDBIcon10_" .. OBJECT_NAME
local launcher
local playerLoggedIn = false

local function GetTooltipText()
    if NS.db and NS.db.minimap and NS.db.minimap.launcherMode=='minimap' then
        return "Left click: Open settings\nShift-left click: Pause/resume auto-swap\nRight click: Toggle experimental minimap"
    end
    if NS.L and NS.L.MINIMAP_TOOLTIP then
        return NS.L.MINIMAP_TOOLTIP
    end
    return "Left click: Open settings\nShift-left click: Pause/resume auto-swap\nRight click: Toggle farming HUD"
end

local function BuildLauncher()

    if launcher then return launcher end

    launcher = LDB:GetDataObjectByName(OBJECT_NAME)
    if launcher then
        launcher.icon = LAUNCHER_ICON
        return launcher
    end

    launcher = LDB:NewDataObject(OBJECT_NAME, {
        type = "launcher",

        icon = LAUNCHER_ICON,

        OnClick = function(_, button)
            if button == "LeftButton" then
                if IsShiftKeyDown and IsShiftKeyDown() then
                    if NS.ToggleTrackingSwapsPaused then NS:ToggleTrackingSwapsPaused() end
                elseif NS.OpenSettings then
                    NS:OpenSettings()
                end
            elseif button == "RightButton" then
                if NS.db and NS.db.minimap and NS.db.minimap.launcherMode=='minimap' and NS.SetExperimentalMinimapEnabled then
                    NS:SetExperimentalMinimapEnabled(not NS.db.minimap.fullTimeScanning)
                elseif NS.ToggleHUD then
                    NS:ToggleHUD()
                end
            end
        end,

        OnTooltipShow = function(tooltip)
            tooltip:AddLine(NS.L.TITLE, 1.0, 0.52, 0.16)
            local paused = NS.db and NS.db.hud and NS.db.hud.trackingSwapsPaused
            local enabled = NS.IsAutoTrackingEnabled and NS:IsAutoTrackingEnabled()
            local state = paused and "MINIMAP_AUTOSWAP_PAUSED" or enabled and "MINIMAP_AUTOSWAP_ON" or "MINIMAP_AUTOSWAP_OFF"
            local fallback = paused and "Auto-swap: Paused" or enabled and "Auto-swap: On" or "Auto-swap: Off"
            tooltip:AddLine(NS.L[state] or fallback, 1, 1, 1)
            if NS.db and NS.db.minimap and NS.db.minimap.launcherMode=='minimap' then
                tooltip:AddLine('Experimental minimap: '..(NS.db.minimap.fullTimeScanning and 'On' or 'Off'),1,1,1)
            end
            for line in string.gmatch(GetTooltipText(), "[^\n]+") do
                tooltip:AddLine(line, 1, 1, 1)
            end
        end,
    })

    return launcher
end

local function GetButton()
    local button = LDBIcon:GetMinimapButton(OBJECT_NAME)
    if not button then
        button = _G[BUTTON_FRAME_NAME]
    end
    if button then
        NS.MinimapButton = button
    end
    return button
end

-- A separate launcher cannot inherit the capture minimap's hidden parent/alpha.
local function UpdateHUDLauncher(visible)
    local button = NS.HUDSettingsButton
    if visible and not button then
        button = CreateFrame("Button", "ForeverFarmRouteGathering_HUDSettings", UIParent)
        button:SetSize(32, 32)
        local position = NS.db.minimap.hudLauncherPosition
        local function Coordinate(value)
            return type(value) == "number" and value == value and math.abs(value) < math.huge
        end
        if type(position) == "table" and Coordinate(position.x) and Coordinate(position.y) then
            button:SetPoint("CENTER", UIParent, "CENTER", position.x, position.y)
        else
            button:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -24, -180)
        end
        button:SetMovable(true)
        button:SetClampedToScreen(true)
        button:RegisterForDrag("LeftButton")
        local function FinishDrag(self)
            if not self.dragging then return end
            self:StopMovingOrSizing()
            self.dragging = nil
            local x, y = self:GetCenter()
            local parentX, parentY = UIParent:GetCenter()
            if Coordinate(x) and Coordinate(y) and Coordinate(parentX) and Coordinate(parentY) then
                x, y = x - parentX, y - parentY
                NS.db.minimap.hudLauncherPosition = {x = x, y = y}
                self:ClearAllPoints()
                self:SetPoint("CENTER", UIParent, "CENTER", x, y)
            end
        end
        button:SetScript("OnMouseDown", function(self) self.dragged = nil end)
        button:SetScript("OnDragStart", function(self)
            self.dragging, self.dragged = true, true
            self:StartMoving()
        end)
        button:SetScript("OnDragStop", FinishDrag)
        button:SetFrameStrata("MEDIUM")
        button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        button:SetNormalTexture(LAUNCHER_ICON)
        button:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
        button:SetScript("OnClick", function(self, mouseButton)
            if not self.dragged then BuildLauncher().OnClick(self, mouseButton) end
        end)
        button:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_LEFT")
            BuildLauncher().OnTooltipShow(GameTooltip)
            GameTooltip:AddLine("Left-drag: Move this button", 0.65, 0.65, 0.65)
            GameTooltip:Show()
        end)
        local function ClearTooltip(self)
            if GameTooltip:GetOwner() == self then GameTooltip:Hide() end
        end
        button:SetScript("OnLeave", ClearTooltip)
        button:SetScript("OnHide", function(self) FinishDrag(self); ClearTooltip(self) end)
        NS.HUDSettingsButton = button
    end
    if button then button:SetShown(visible and true or false) end
end

local function ArrayContains(tbl, value)
    if type(tbl) ~= "table" then return false end
    for _, entry in pairs(tbl) do
        if entry == value then return true end
    end
    return false
end

local function TryCollectWithMBB()
    if NS.db and NS.db.minimap and NS.db.minimap.hide then return false end
    -- Optional integration only. ForeverDualGathering does not require MBB.
    if type(_G.MBB_AddButton) ~= "function"
        or type(_G.MBB_PrepareButton) ~= "function"
        or type(_G.MBB_Buttons) ~= "table"
    then
        return false
    end

    if InCombatLockdown and InCombatLockdown() then
        return false
    end

    local button = GetButton()
    if not button then return false end

    -- Already managed by MBB.
    if ArrayContains(_G.MBB_Buttons, BUTTON_FRAME_NAME) then
        return true
    end

    -- MBB's normal scanner can miss late LibDBIcon buttons on Forever.
    -- Prepare it explicitly, then add it to the MBB list.
    if not button.oshow then
        local ok = pcall(_G.MBB_PrepareButton, BUTTON_FRAME_NAME)
        if not ok then return false end
    end

    -- MBB_AddButton itself removes the button from MBB_Exclude when needed.
    local ok = pcall(_G.MBB_AddButton, BUTTON_FRAME_NAME)
    if not ok then return false end

    if type(_G.MBB_SetPositions) == "function" then
        pcall(_G.MBB_SetPositions)
    end

    return ArrayContains(_G.MBB_Buttons, BUTTON_FRAME_NAME)
end

function NS:IsMinimapButtonManagedByMBB()
    return ArrayContains(_G.MBB_Buttons, BUTTON_FRAME_NAME)
end

function NS:CreateMinimapButton()
    if not playerLoggedIn then return end
    if not self.db or not self.db.minimap or not Minimap then return end

    local object = BuildLauncher()
    if not object then
        self.Print((self.L and self.L.LDB_CREATE_FAILED) or "The LibDataBroker launcher could not be created.")
        return
    end

    if not LDBIcon:IsRegistered(OBJECT_NAME) then
        LDBIcon:Register(OBJECT_NAME, object, self.db.minimap)
    else
        LDBIcon:Refresh(OBJECT_NAME, self.db.minimap)
    end
    local button = GetButton()
    TryCollectWithMBB()
    self:UpdateMinimapButton()
end

function NS:UpdateMinimapButton()
    if not playerLoggedIn then return end
    if not self.db or not self.db.minimap then return end

    if not LDBIcon:IsRegistered(OBJECT_NAME) then
        self:CreateMinimapButton()
        if not LDBIcon:IsRegistered(OBJECT_NAME) then return end
    end
    -- Let LibDBIcon own placement and stored minimapPos unless MBB has
    -- taken over the button's placement.
    local managedByMBB = ArrayContains(_G.MBB_Buttons, BUTTON_FRAME_NAME)
    UpdateHUDLauncher(not self.db.minimap.hide and self.db.hud and self.db.hud.enabled and not managedByMBB)

    if not managedByMBB then
        LDBIcon:Refresh(OBJECT_NAME, self.db.minimap)
    end

    local button = GetButton()
    if self.db.minimap.hide then
        if button then button.isvisible = false end
        LDBIcon:Hide(OBJECT_NAME)
        if managedByMBB and type(_G.MBB_SetPositions) == "function" then
            pcall(_G.MBB_SetPositions)
        end
        -- MBB can replace Hide with bookkeeping; use its original method too.
        if button then
            if button.ohide then button:ohide() else button:Hide() end
        end
        return
    end

    if self.db.hud and self.db.hud.enabled then
        if managedByMBB then
            -- MBB is independent from the moved minimap. Keep the launcher in
            -- the bag so settings remain reachable while the HUD is active.
            if button then
                button.isvisible = true
            end
            if type(_G.MBB_SetPositions) == "function" then
                pcall(_G.MBB_SetPositions)
            end
        else
            -- Standalone LibDBIcon buttons are anchored to the real Minimap,
            -- which is currently in the center as the HUD, so hide that copy.
            LDBIcon:Hide(OBJECT_NAME)
            if button then button:Hide() end
        end

        return
    end

    -- Outside HUD mode the launcher is available again.
    -- If MBB is installed, hand it back to MBB instead of forcing it onto
    -- the minimap edge ourselves.
    if TryCollectWithMBB() then
        button = GetButton()
        if button then
            button.isvisible = true
        end
        if type(_G.MBB_SetPositions) == "function" then
            pcall(_G.MBB_SetPositions)
        end
        return
    end

    -- Standalone case: no extra frame manipulation here.
    -- The same LibDBIcon frame that renders correctly inside MBB is shown
    -- exactly as LibDBIcon created it.
    LDBIcon:Show(OBJECT_NAME)
end

function NS:SetMinimapButtonLocked(locked)
    if not playerLoggedIn or not self.db or not self.db.minimap then return end

    if not LDBIcon:IsRegistered(OBJECT_NAME) then
        self:CreateMinimapButton()
    end
    if not LDBIcon:IsRegistered(OBJECT_NAME) then return end

    self.db.minimap.lock = locked and true or nil
    if locked then
        LDBIcon:Lock(OBJECT_NAME)
    else
        LDBIcon:Unlock(OBJECT_NAME)
    end
end

function NS:DebugMinimapButton()
    local yes = (self.L and self.L.DEBUG_YES) or "yes"
    local no = (self.L and self.L.DEBUG_NO) or "no"

    local registered = LDBIcon:IsRegistered(OBJECT_NAME) and yes or no
    local button = GetButton()
    local exists = button and yes or no
    local shown = (button and button.IsShown and button:IsShown()) and yes or no
    local parent = "nil"

    if button and button.GetParent then
        local p = button:GetParent()
        if p then
            parent = (p.GetName and p:GetName()) or tostring(p)
        end
    end

    local mbbManaged = ArrayContains(_G.MBB_Buttons, BUTTON_FRAME_NAME) and yes or no
    local mbbExcluded = ArrayContains(_G.MBB_Exclude, BUTTON_FRAME_NAME) and yes or no

    local debugFormat = (self.L and self.L.DEBUG_BUTTON)
        or "Button debug: registered=%s, frame=%s, shown=%s, parent=%s, MBB=%s, MBB-excluded=%s"

    self.Print(string.format(
        debugFormat,
        registered,
        exists,
        shown,
        tostring(parent),
        mbbManaged,
        mbbExcluded
    ))

    if button and button.GetPoint then
        local point, relativeTo, relativePoint, x, y = button:GetPoint(1)
        local relName = relativeTo and relativeTo.GetName and relativeTo:GetName() or tostring(relativeTo)
        local pointFormat = (self.L and self.L.DEBUG_POINT)
            or "Point: %s -> %s / %s / %s, %s"

        self.Print(string.format(
            pointFormat,
            tostring(point),
            tostring(relName),
            tostring(relativePoint),
            tostring(math.floor((x or 0) + 0.5)),
            tostring(math.floor((y or 0) + 0.5))
        ))
    end
end

-- Create only after PLAYER_LOGIN. This is intentionally later than ADDON_LOADED:
-- WoW Forever/Camelot may not have completed minimap setup at addon-load time.
local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("ADDON_LOADED")

events:SetScript("OnEvent", function(_, event, arg1)
    if event == "PLAYER_LOGIN" then
        playerLoggedIn = true
        if NS.db then
            NS:CreateMinimapButton()
            NS:UpdateMinimapButton()
        end
        return
    end

    if event == "PLAYER_ENTERING_WORLD" then
        playerLoggedIn = true
        if NS.db then
            NS:CreateMinimapButton()
            TryCollectWithMBB()
            NS:UpdateMinimapButton()
        end
        return
    end

    if event == "ADDON_LOADED" then
        if arg1 == "MBB"
            or arg1 == "MinimapButtonBag"
            or arg1 == "MinimapButtonBag-TurtleWoW"
        then
            if playerLoggedIn and NS.db then
                TryCollectWithMBB()
                NS:UpdateMinimapButton()
            end
        end
    end
end)

-- A short lightweight verification window catches addons that finish altering
-- the minimap shortly after PLAYER_ENTERING_WORLD.
local watchdog = CreateFrame("Frame")
local elapsed = 0
local checks = 0
watchdog:SetScript("OnUpdate", function(self, dt)
    if not playerLoggedIn or not NS.db then return end
    if checks >= 8 then
        self:SetScript("OnUpdate", nil)
        return
    end

    elapsed = elapsed + dt
    if elapsed >= 0.75 then
        elapsed = 0
        checks = checks + 1
        if not NS.db.hud.enabled then
            NS:UpdateMinimapButton()
        end
    end
end)
