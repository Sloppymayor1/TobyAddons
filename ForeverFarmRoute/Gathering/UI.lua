local ADDON_NAME, FRNS_ = ...; local NS = FRNS_.Gathering
local L = NS.L
-- Blizzard_Minimap/Camelot/Skin.lua uses this atlas for both rotation modes.
-- Its initial write can precede our hooks, and Forever has no mask getter.
local STOCK_MINIMAP_MASK = "ui-hud-minimap-frame-generic-mask"
local MOUSE_BUTTONS = {"LeftButton", "RightButton", "MiddleButton", "Button4", "Button5"}
local unpack = unpack or table.unpack

local function Clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

local function SafeInCombat()
    return InCombatLockdown and InCombatLockdown()
end

local function SafeGetCVar(name)
    if GetCVar then
        local ok, value = pcall(GetCVar, name)
        if ok then return value end
    end
    if C_CVar and C_CVar.GetCVar then
        local ok, value = pcall(C_CVar.GetCVar, name)
        if ok then return value end
    end
    return nil
end

local function SafeSetCVar(name, value)
    local ok = false

    if SetCVar then
        ok = pcall(SetCVar, name, tostring(value))
    elseif C_CVar and C_CVar.SetCVar then
        ok = pcall(C_CVar.SetCVar, name, tostring(value))
    end

    if ok and Minimap_UpdateRotationSetting then
        pcall(Minimap_UpdateRotationSetting)
    end

    return ok
end

local function CreateBackdrop(frame, alpha)
    local bg = frame:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetTexture("Interface\\Buttons\\WHITE8X8")
    bg:SetVertexColor(0.035, 0.035, 0.045, alpha or 0.94)
    frame._bg = bg
end

local function SetAddonFont(fs, size, flags)
    if fs then pcall(fs.SetFont, fs, STANDARD_TEXT_FONT, size or 12, flags) end
end

local function MakeText(parent, size, anchor, x, y, text)
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    SetAddonFont(fs, size)
    fs:SetPoint(anchor or "TOPLEFT", parent, anchor or "TOPLEFT", x or 0, y or 0)
    fs:SetText(text or "")
    return fs
end

local POSITION_COLORS = {
    CYAN={0.3,0.9,1}, WHITE={1,1,1}, GOLD={1,0.8,0.2}, GREEN={0.3,1,0.35}, PINK={1,0.4,0.8},
}

function NS:RenderHUDPositionIcon(f, hud)
    if not f or not hud then return end
    local style = hud.positionStyle or "CROSS"
    if style == "NONE" then
        f.positionLayer:Hide()
        f.dualCenter:Hide()
        f.positionTexture:Hide()
        return
    end
    local color = POSITION_COLORS[hud.positionColor] or POSITION_COLORS.CYAN
    local size, opacity = hud.positionSize or 18, hud.positionOpacity or 1
    f.positionLayer:Show()
    f.positionLayer:SetAlpha(opacity)
    if style == "CROSS" then
        f.positionTexture:Hide()
        SetAddonFont(f.dualCenter, size, "OUTLINE")
        f.dualCenter:SetTextColor(color[1], color[2], color[3])
        f.dualCenter:Show()
    else
        f.dualCenter:Hide()
        local texture = style == "ARROW" and "Interface\\Minimap\\MinimapArrow"
            or style == "RING" and "Interface\\AddOns\\ForeverFarmRoute\\Gathering\\Media\\WorldMarkersRing.tga"
            or "Interface\\Common\\CommonMaskCircle"
        f.positionTexture:SetTexture(texture)
        if f.positionTexture.SetRotation then f.positionTexture:SetRotation(0) end
        f.positionTexture:SetSize(size, size)
        f.positionTexture:SetVertexColor(color[1], color[2], color[3])
        f.positionTexture:Show()
    end
end

local function MakeButton(parent, width, height, text, callback)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(width, height)
    b:SetText(text or "")
    b:SetScript("OnClick", callback)

    local fs = b.GetFontString and b:GetFontString()
    if fs then
        local _, size, flags = fs:GetFont()
        SetAddonFont(fs, size or 12, flags)
    end

    return b
end

-- Small anchored menus work on the supported clients without menu API dependencies.
local openHUDMenu
local function MakeHUDDropdown(parent, choices, getValue, selectValue)
    local button = MakeButton(parent, 210, 28, "", function() end)
    MakeText(button, 12, "RIGHT", -8, 0, "v")
    local menu = CreateFrame("Frame", nil, button)
    menu:SetPoint("TOPRIGHT", button, "BOTTOMRIGHT", 0, -2)
    menu:SetSize(230, #choices * 28 + 8)
    menu:SetFrameStrata("TOOLTIP")
    CreateBackdrop(menu, 1)
    menu:EnableMouse(true)
    menu:Hide()
    button.menu, button.options = menu, {}
    for i, choice in ipairs(choices) do
        local value, label = choice[1], choice[2]
        local row = MakeButton(menu, 222, 28, label, function()
            menu:Hide()
            if button.experimentalDisabled then return end
            selectValue(value)
        end)
        row:SetPoint("TOPLEFT", 4, -4 - (i - 1) * 28)
        button.options[value] = row
        row.choiceLabel = label
    end
    button:SetScript("OnClick", function()
        if button.experimentalDisabled then return end
        if menu:IsShown() then menu:Hide(); return end
        if openHUDMenu then openHUDMenu:Hide() end
        for value, row in pairs(button.options) do
            row:SetText((value == getValue() and "* " or "") .. row.choiceLabel)
        end
        openHUDMenu = menu
        menu:Show()
    end)
    button:HookScript("OnHide", function() menu:Hide() end)
    menu:EnableKeyboard(true)
    menu:SetScript("OnKeyDown", function(self, key)
        if self.SetPropagateKeyboardInput then self:SetPropagateKeyboardInput(key ~= "ESCAPE") end
        if key == "ESCAPE" then self:Hide() end
    end)
    return button
end


local function MakeCheckbox(parent, text, callback)
    local c = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    c.text = c:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    local _, size, flags = c.text:GetFont()
    SetAddonFont(c.text, size or 12, flags)
    c.text:SetPoint("LEFT", c, "RIGHT", 4, 0)
    c.text:SetText(text or "")
    c:SetScript("OnClick", function(self)
        callback(self:GetChecked() and true or false)
    end)
    return c
end

local function MakeSlider(parent, width, minv, maxv, step)
    local s = CreateFrame("Slider", nil, parent, "OptionsSliderTemplate")
    s:SetWidth(width)
    s:SetMinMaxValues(minv, maxv)
    s:SetValueStep(step)
    if s.SetObeyStepOnDrag then s:SetObeyStepOnDrag(true) end
    return s
end

-- HUD -----------------------------------------------------------------------

function NS:CreateHUD()
    if self.HUDFrame then return end

    local f = CreateFrame("Frame", "ForeverFarmRouteGathering_HUD", UIParent)
    f:SetSize(430, 430)
    f:SetPoint("CENTER")
    f:SetFrameStrata("LOW")
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:Hide()
    self.HUDFrame = f

    local dark = f:CreateTexture(nil, "BACKGROUND")
    dark:SetPoint("CENTER")
    dark:SetTexture("Interface\\Buttons\\WHITE8X8")
    dark:SetVertexColor(0, 0, 0, 0.0)
    f.dark = dark

    local outer = f:CreateTexture(nil, "ARTWORK")
    outer:SetPoint("CENTER")
    outer:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    outer:SetTexCoord(0, 1, 0, 1)
    f.outer = outer
    f.outer:Hide()

    local position = CreateFrame("Frame", nil, f)
    position:SetAllPoints(f)
    position:EnableMouse(false)
    f.positionLayer = position
    f.dualCenter = MakeText(position, 18, "CENTER", 0, 0, "+")
    f.dualCenter:Hide()
    f.positionTexture = position:CreateTexture(nil, "OVERLAY")
    f.positionTexture:SetPoint("CENTER", position, "CENTER", 0, 0)
    f.positionTexture:Hide()

    local north = MakeText(f, 18, "TOP", 0, -8, "N")
    north:SetTextColor(1.0, 0.5, 0.15)
    local south = MakeText(f, 15, "BOTTOM", 0, 8, "S")
    local west = MakeText(f, 15, "LEFT", 8, 0, "W")
    local east = MakeText(f, 15, "RIGHT", -8, 0, "E")
    f.north, f.south, f.west, f.east = north, south, west, east
    north:Hide()
    south:Hide()
    west:Hide()
    east:Hide()

    local coord = MakeText(f, 13, "BOTTOM", 0, 28, "")
    coord:SetTextColor(1, 0.82, 0.45)
    f.coord = coord
    coord:Hide()

    local hint = MakeText(f, 11, "TOP", 0, -32, self.L.TITLE)
    hint:SetTextColor(0.85, 0.85, 0.85)
    f.hint = hint
    hint:Hide()

    f:SetScript("OnDragStart", function(frame)
        if NS.db.hud.locked then return end
        frame:StartMoving()
    end)
    f:SetScript("OnDragStop", function(frame)
        frame:StopMovingOrSizing()
        local _, _, _, x, y = frame:GetPoint(1)
        NS.db.hud.x = math.floor((x or 0) + 0.5)
        NS.db.hud.y = math.floor((y or 0) + 0.5)
        if NS.db.hud.enabled then
            NS:ApplyHUDLayout()
        end
    end)

    local mouseElapsed, overlayElapsed, arrowElapsed = 0, 0, 0
    self._hudInteractionPoll = function(_, dt)
        if not NS.db or not NS.db.hud.enabled then return end
        if NS.db.hud.positionStyle=="ARROW" then
            arrowElapsed=arrowElapsed+dt
            if arrowElapsed>=.05 then arrowElapsed=0;NS:UpdateHUDPositionFacing() end
        end
        if SafeInCombat() then return end
        mouseElapsed = mouseElapsed + dt
        overlayElapsed = overlayElapsed + dt
        if mouseElapsed >= 0.1 then
            mouseElapsed = 0
            if NS.db.hud.mouseModifier and NS.db.hud.mouseModifier ~= "NONE" then
                NS:UpdateHUDMouseInteraction()
            end
        end
        if overlayElapsed >= 1 then
            overlayElapsed = 0
            if NS.db.hud.hideAddonOverlays then NS:HideAddonMinimapOverlays() end
        end
    end
    self:InstallHUDMinimapGuards()
    if self.InstallHUDCombatAnchor then self:InstallHUDCombatAnchor() end

    self:ResizeHUDVisuals()
end

function NS:UpdateHUDInteraction()
    if not self.HUDFrame or not self.db then return end
    if not self._hudDragPassThrough and self.HUDFrame.SetPassThroughButtons and not SafeInCombat() then
        self._hudDragPassThrough = pcall(self.HUDFrame.SetPassThroughButtons, self.HUDFrame,
            "RightButton", "MiddleButton", "Button4", "Button5")
    end
    self.HUDFrame:EnableMouse(not self.db.hud.locked)
    local modifier = self.db.hud.mouseModifier or "NONE"
    local poll = ((self.CursorSweepActive or self.db.hud.keepMinimap) and self.db.hud.positionStyle=="ARROW" or modifier ~= "NONE" or self.db.hud.hideAddonOverlays) and self._hudInteractionPoll or nil
    if self.HUDFrame:GetScript("OnUpdate") ~= poll then
        self.HUDFrame:SetScript("OnUpdate", poll)
    end
end

function NS:ResizeHUDVisuals()
    if not self.HUDFrame or not self.db then return end
    local size = self.db.hud.size
    local f = self.HUDFrame
    f:SetSize(size, size)
    f.dark:SetSize(size - 12, size - 12)
    f.outer:SetSize(size + 44, size + 44)
    f.outer:SetAlpha(0)
    f.outer:Hide()
    self:UpdateHUDPositionIcon()
    self:UpdateHUDInteraction()
end

local function ScanStatusCoordinate(value)
    return type(value) == "number" and value == value and math.abs(value) < math.huge
end

function NS:SetScanStatusShown(enabled)
    self.db.hud.showScanStatus=enabled==true
    local pages=self.OptionsPanel and self.OptionsPanel.pages
    if pages then
        for _,name in ipairs({'hud','minimap'}) do
            local control=pages[name] and pages[name].showScanStatus
            if control then control:SetChecked(self.db.hud.showScanStatus) end
        end
    end
    self:UpdateHUDScanStatus()
end

function NS:UpdateHUDScanStatus()
    local hud, trial, button = self.db and self.db.hud, self.CursorSweepTrial, self.ScanStatusButton
    if self.HUDFrame and self.HUDFrame.scanStatus then self.HUDFrame.scanStatus:Hide() end
    local hover=self.ReplacementMinimapHover
    local nativeHover=hover and hover.armed and hover.hovering
    if not (hud and hud.showScanStatus == true and (self.CursorSweepActive or nativeHover) and trial) then
        if button then button:Hide() end
        return
    end
    if not button then
        button = CreateFrame("Button", "ForeverFarmRouteGathering_ScanStatus", UIParent)
        self.ScanStatusButton = button
        button:SetSize(36, 36)
        button:SetFrameStrata("HIGH")
        button:SetFrameLevel(220)
        button:SetMovable(true)
        button:SetClampedToScreen(true)
        button:EnableMouse(true)
        button:RegisterForDrag("LeftButton")
        local position = self.db.minimap.scanStatusPosition
        if type(position) == "table" and ScanStatusCoordinate(position.x) and ScanStatusCoordinate(position.y) then
            button:SetPoint("CENTER", UIParent, "CENTER", position.x, position.y)
        else
            button:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -66, -180)
        end
        local icon = button:CreateTexture(nil, "ARTWORK")
        icon:SetAllPoints(button)
        icon:SetTexture("Interface\\AddOns\\ForeverFarmRoute\\Gathering\\Media\\GatheringIcon.tga")
        button.icon = icon
        local badge = button:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        badge:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", 3, -3)
        button.badge = badge
        local pauseText = button:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        pauseText:SetPoint("RIGHT", button, "LEFT", -8, 0)
        pauseText:SetWidth(240)
        pauseText:SetJustifyH("RIGHT")
        pauseText:SetTextColor(1, .65, .2)
        pauseText:Hide()
        button.pauseText = pauseText
        local function FinishDrag(widget)
            if not widget.dragging then return end
            widget:StopMovingOrSizing()
            widget.dragging = nil
            local x, y = widget:GetCenter()
            local px, py = UIParent:GetCenter()
            if ScanStatusCoordinate(x) and ScanStatusCoordinate(y) and ScanStatusCoordinate(px) and ScanStatusCoordinate(py) then
                x, y = x - px, y - py
                NS.db.minimap.scanStatusPosition = {x=x, y=y}
                widget:ClearAllPoints()
                widget:SetPoint("CENTER", UIParent, "CENTER", x, y)
            end
        end
        button:SetScript("OnDragStart", function(widget)
            widget.dragging = true
            widget:StartMoving()
        end)
        button:SetScript("OnDragStop", FinishDrag)
        button:SetScript("OnEnter", function(widget)
            if not GameTooltip then return end
            GameTooltip:SetOwner(widget, "ANCHOR_LEFT")
            GameTooltip:AddLine(widget.statusText or "Scan status", 1, 1, 1)
            GameTooltip:AddLine("Left-drag to move", .7, .7, .7)
            GameTooltip:Show()
        end)
        local function ClearTooltip(widget)
            if GameTooltip and GameTooltip:GetOwner() == widget then GameTooltip:Hide() end
        end
        button:SetScript("OnLeave", ClearTooltip)
        button:SetScript("OnHide", function(widget) FinishDrag(widget); ClearTooltip(widget) end)
    end
    local reason = nativeHover and "normal minimap hover" or trial:Blocked()
    local idle = not reason and trial.discoveryIdle
    local text = reason and ("Scan: paused - " .. reason)
        or idle and "Scan: waiting for refresh" or "Scan: running"
    if button.statusText ~= text then
        button.statusText = text
        local r, g, b = .4, 1, .5
        if reason then r, g, b = 1, .65, .2
        elseif idle then r, g, b = .5, .75, 1 end
        button.icon:SetVertexColor(r, g, b)
        button.badge:SetText(reason and "II" or idle and "..." or ">")
        button.badge:SetTextColor(r, g, b)
        if reason then
            button.pauseText:SetText("Paused: " .. reason)
            button.pauseText:Show()
        else button.pauseText:Hide() end
        if GameTooltip and GameTooltip:GetOwner() == button then button:GetScript("OnEnter")(button) end
    end
    button:Show()
end

function NS:UpdateHUDPositionIcon()
    local f, hud = self.HUDFrame, self.db and self.db.hud
    if not f or not hud then return end
    if self.MinimapScanActive or not (hud.keepMinimap or self.CursorSweepActive) then
        f.positionLayer:Hide(); f.dualCenter:Hide(); f.positionTexture:Hide()
        return
    end
    self:RenderHUDPositionIcon(f, hud)
    if hud.positionStyle == "ARROW" then self:UpdateHUDPositionFacing() end
    local layer, level = hud.overlayStrata or "HIGH", hud.overlayLevel or 110
    if f.positionLayer:GetFrameStrata() ~= layer then f.positionLayer:SetFrameStrata(layer) end
    if f.positionLayer:GetFrameLevel() ~= level then f.positionLayer:SetFrameLevel(level) end
end

function NS:UpdateHUDPositionFacing()
    local f, hud = self.HUDFrame, self.db and self.db.hud
    if self.MinimapScanActive or not f or not hud or not (hud.keepMinimap or self.CursorSweepActive) or hud.positionStyle ~= "ARROW" or not f.positionTexture.SetRotation then return end
    local mode = hud.rotationMode or "CLIENT"
    local nativeRotation = mode == "CLIENT" and (self.CursorSweepActive and self.CursorSweepTrial and self.CursorSweepTrial.clientRotation or SafeGetCVar("rotateMinimap")) or nil
    if mode == "CLIENT" and nativeRotation ~= "0" and nativeRotation ~= "1" then f.positionTexture:Hide(); return end
    local rotating = mode == "ON" or mode == "CLIENT" and nativeRotation == "1"
    local facing = 0
    if not rotating then
        if type(GetPlayerFacing) ~= "function" then f.positionTexture:Hide(); return end
        local ok, value = pcall(GetPlayerFacing)
        if not ok then f.positionTexture:Hide(); return end
        facing = value
    end
    if type(facing) == "number" and not (issecretvalue and issecretvalue(facing)) and facing == facing and math.abs(facing) < math.huge then
        f.positionTexture:SetRotation(facing)
        f.positionTexture:Show()
    else
        f.positionTexture:Hide()
    end
end

function NS:CaptureMinimapState()
    if self._minimapState or not Minimap then return end
    self:CaptureManualHoverInput()
    local state = {
        parent = Minimap:GetParent(),
        scale = Minimap:GetScale(),
        alpha = Minimap:GetAlpha(),
        mouse = Minimap:IsMouseEnabled(),
        strata = Minimap:GetFrameStrata(),
        level = Minimap:GetFrameLevel(),
        width = Minimap:GetWidth(),
        height = Minimap:GetHeight(),
        points = {},
        rotateMinimap = SafeGetCVar("rotateMinimap"),
        shown = not Minimap.IsShown or Minimap:IsShown(),
        maskTexture = self._minimapMaskTexture or STOCK_MINIMAP_MASK,
    }

    if Minimap.IsMouseWheelEnabled then
        local ok, enabled = pcall(Minimap.IsMouseWheelEnabled, Minimap)
        if ok then
            state.mouseWheel = enabled
        end
    end

    if Minimap.GetZoom then
        local ok, zoom = pcall(Minimap.GetZoom, Minimap)
        if ok then
            state.zoom = zoom
        end
    end

    if Minimap.GetMaskTexture then
        local ok, maskTexture = pcall(Minimap.GetMaskTexture, Minimap)
        if ok and not (issecretvalue and issecretvalue(maskTexture)) and maskTexture then
            state.maskTexture = maskTexture
        end
    end
    local n = Minimap:GetNumPoints() or 0
    for i = 1, n do
        local p, rel, rp, x, y = Minimap:GetPoint(i)
        state.points[#state.points + 1] = {p, rel, rp, x, y}
    end
    self._minimapState = state
end


local KNOWN_MINIMAP_DECORATIONS = {
    "MinimapBackdrop",
    "MinimapBorder",
    "MinimapBorderTop",
    "MinimapCompassTexture",
    "MinimapCompassTextureUnderlay",
    "MinimapNorthTag",
    "MiniMapTracking",
    "MiniMapTrackingButton",
    "MiniMapWorldMapButton",
    "MinimapZoneText",
    "MinimapZoneTextButton",
    "MinimapZoomIn",
    "MinimapZoomOut",
    "GameTimeFrame",
    "TimeManagerClockButton",
    "QueueStatusMinimapButton",
}

local knownDecorationGuards = setmetatable({}, { __mode = "k" })
local controlAlphaGuards = setmetatable({}, { __mode = "k" })

function NS:HideMinimapControl(object)
    if self.IsStationaryMinimapControl and self:IsStationaryMinimapControl(object) then return end
    -- A secure Show can revive a hidden button during combat. Keep its opacity
    -- zero and prepare click-through before combat so invisible controls cannot
    -- block camera dragging when the game shows them again.
    self:PassHUDMouseButtons(object, true)
    if object.GetAlpha and object.SetAlpha then
        self._hiddenMinimapControlAlphas = self._hiddenMinimapControlAlphas or {}
        local alphas = self._hiddenMinimapControlAlphas
        local ok, alpha = pcall(object.GetAlpha, object)
        if ok and not (issecretvalue and issecretvalue(alpha)) then
            if alphas[object] == nil then alphas[object] = alpha end
            if not controlAlphaGuards[object] and hooksecurefunc then
                hooksecurefunc(object, "SetAlpha", function(control, value)
                    local saved = NS._hiddenMinimapControlAlphas
                    if not NS.db or not (NS.db.hud.enabled or NS.MinimapScanActive and NS._minimapState) or not saved or saved[control] == nil
                        or NS._hidingMinimapControlAlpha or (issecretvalue and issecretvalue(value))
                    then return end
                    saved[control] = value
                    if value ~= 0 then
                        NS._hidingMinimapControlAlpha = true
                        pcall(control.SetAlpha, control, 0)
                        NS._hidingMinimapControlAlpha = nil
                    end
                end)
                controlAlphaGuards[object] = true
            end
            if alpha ~= 0 then
                self._hidingMinimapControlAlpha = true
                pcall(object.SetAlpha, object, 0)
                self._hidingMinimapControlAlpha = nil
            end
        end
    end
    if not (SafeInCombat() and object.IsProtected and object:IsProtected()) then
        pcall(object.Hide, object)
    end
end

local function KeepKnownDecorationHidden(object)
    if not NS.db or not (NS.db.hud.enabled or NS.MinimapScanActive and NS._minimapState) then return end
    local ok, shown = pcall(object.IsShown, object)
    if ok and not (issecretvalue and issecretvalue(shown)) and shown then
        NS._hiddenKnownMinimapFrames = NS._hiddenKnownMinimapFrames or {}
        NS._hiddenKnownMinimapFrames[object] = true
        NS:HideMinimapControl(object)
    end
end

local function HideKnownMinimapDecorations(storage)
    local function Suppress(object)
        if object and object ~= Minimap and object.Hide and object.IsShown then
            if not knownDecorationGuards[object] and hooksecurefunc then
                hooksecurefunc(object, "Show", KeepKnownDecorationHidden)
                if object.SetShown then hooksecurefunc(object, "SetShown", KeepKnownDecorationHidden) end
                if object.HookScript then object:HookScript("OnShow", KeepKnownDecorationHidden) end
                knownDecorationGuards[object] = true
            end
            local ok, shown = pcall(object.IsShown, object)
            if ok and not (issecretvalue and issecretvalue(shown)) and shown then storage[object] = true end
            NS:HideMinimapControl(object)
        end
    end
    for _, name in ipairs(KNOWN_MINIMAP_DECORATIONS) do Suppress(_G[name]) end
    -- This anonymous native frame covers the lower-right zoom corner.
    Suppress(Minimap.ZoomHitArea)
end

local THIRD_PARTY_MINIMAP_PATTERNS = {
    "^LibDBIcon10_",
    "RareScanner",
    "HandyNotes",
    "GatherMate",
    "Gatherer",
    "SilverDragon",
    "Questie",
    "TomTom",
    "Routes",
    "Carbonite",
}

local function IsSupportedThirdPartyMinimapFrame(frame)
    if not frame or frame == NS.MinimapButton or frame == NS.HUDFrame or frame == NS.OptionsPanel then
        return false
    end

    if not frame.GetName then return false end

    local ok, name = pcall(frame.GetName, frame)
    if not ok or type(name) ~= "string" or name == "" then
        return false
    end

    -- Never treat known Blizzard minimap objects as third-party overlays.
    for _, blizzardName in ipairs(KNOWN_MINIMAP_DECORATIONS) do
        if name == blizzardName then
            return false
        end
    end

    for _, pattern in ipairs(THIRD_PARTY_MINIMAP_PATTERNS) do
        if name:find(pattern) then
            return true
        end
    end

    return false
end

local function CollectSupportedThirdPartyMinimapFrames(out)
    if not Minimap or not Minimap.GetChildren then return end

    -- Deliberately inspect direct Minimap children only. Do not recurse into
    -- Blizzard's internal minimap hierarchy and do not scan arbitrary frames.
    local children = { Minimap:GetChildren() }

    for _, child in ipairs(children) do
        if IsSupportedThirdPartyMinimapFrame(child) then
            local ok, shown = true, true
            if child.IsShown then
                ok, shown = pcall(child.IsShown, child)
            end

            if ok and shown then
                out[child] = true
            end
        end
    end
end

local function RestoreFrameSet(frames)
    if not frames then return end
    for frame in pairs(frames) do
        if frame and frame.Show then
            pcall(frame.Show, frame)
        end
    end
end

function NS:HideKnownMinimapAttachments()
    self._hiddenKnownMinimapFrames = self._hiddenKnownMinimapFrames or {}
    HideKnownMinimapDecorations(self._hiddenKnownMinimapFrames)
end

-- SilverDragon's anonymous pool pins travel with the native capture map.
-- Scope suppression to its exact installed templates; never touch world pins.
local function IsCursorOverlayPin(frame)
    local template=frame and frame.pinTemplate
    return not (issecretvalue and issecretvalue(template))
        and (template=='SilverDragonOverlayMinimapPinTemplate' or template=='SilverDragonOverlayMinimapRoutePinTemplate')
end
function NS:SuppressCursorMinimapPins()
    if self._cursorOverlayBusy or SafeInCombat() or not self.CursorSweepActive or not Minimap.GetChildren then return end
    self._cursorOverlayBusy=true
    self._cursorOverlayPins=self._cursorOverlayPins or {}
    self._cursorOverlayGuards=self._cursorOverlayGuards or setmetatable({}, {__mode='k'})
    local privateTooltip
    if LibStub then
        local ok,tooltip=pcall(function()
            local ace=LibStub('AceAddon-3.0',true)
            local addon=ace and ace:GetAddon('SilverDragon',true)
            local overlay=addon and addon:GetModule('Overlay',true)
            return overlay and not overlay.lootwindow and overlay.tooltip
        end)
        if ok then privateTooltip=tooltip end
    end
    local function HideOwnedTooltip(tooltip,pin)
        if tooltip and tooltip.GetOwner and tooltip.Hide then
            local ok,owner=pcall(tooltip.GetOwner,tooltip)
            if ok and not (issecretvalue and issecretvalue(owner)) and owner==pin then tooltip:Hide() end
        end
    end
    for _,pin in ipairs({Minimap:GetChildren()})do
        if IsCursorOverlayPin(pin) and pin.GetParent and pin:GetParent()==Minimap then
            if not self._cursorOverlayGuards[pin] and hooksecurefunc and pin.Show then
                hooksecurefunc(pin,'Show',function()self:SuppressCursorMinimapPins()end)
                self._cursorOverlayGuards[pin]=true
            end
            HideOwnedTooltip(GameTooltip,pin)
            HideOwnedTooltip(privateTooltip,pin)
            if pin.IsShown and pin:IsShown() then
                self._cursorOverlayPins[pin]={template=pin.pinTemplate,provider=pin.provider}
                pin:Hide()
            end
        end
    end
    self._cursorOverlayBusy=nil
end
function NS:RestoreCursorMinimapPins()
    if SafeInCombat() then return end
    local pins=self._cursorOverlayPins;self._cursorOverlayPins=nil
    for pin,state in pairs(pins or {})do
        if IsCursorOverlayPin(pin) and pin.pinTemplate==state.template and pin.provider==state.provider
            and pin:GetParent()==Minimap and pin.Show then pin:Show() end
    end
end
function NS:HideAddonMinimapOverlays()
    if not Minimap then return end

    self._hiddenAddonMinimapFrames = self._hiddenAddonMinimapFrames or {}

    local candidates = {}
    CollectSupportedThirdPartyMinimapFrames(candidates)

    for frame in pairs(candidates) do
        -- Already-recorded frames may have been shown again by their addon.
        if frame and frame.Hide then
            local hidden = pcall(frame.Hide, frame)
            if hidden then
                self._hiddenAddonMinimapFrames[frame] = true
            end
        end
    end
end

function NS:RestoreAddonMinimapOverlays()
    RestoreFrameSet(self._hiddenAddonMinimapFrames)
    self._hiddenAddonMinimapFrames = nil
end

-- Launcher buttons belong to the normal minimap, independently of map-pin
-- overlay preferences. Keep a separate journal so changing that preference
-- cannot expose launchers while the HUD owns the native map.
local hudLauncherGuards=setmetatable({}, {__mode="k"})
function NS:HideHUDAddonButtons()
    if not (self.db and self.db.hud.enabled and Minimap and Minimap.GetChildren) then return end
    self._hiddenHUDAddonButtons=self._hiddenHUDAddonButtons or {}
    local function hide(button)
        if not button or not button.GetName or not button.Hide or not button.IsShown then return end
        local ok,name=pcall(button.GetName,button)
        if not ok or type(name)~='string'
            or not (name:find('^LibDBIcon10_') or name=='EllesmereUIMinimapButton') then return end
        if not hudLauncherGuards[button] and hooksecurefunc then
            local function guard()
                if NS.db and NS.db.hud.enabled then NS:HideHUDAddonButtons() end
            end
            hooksecurefunc(button,'Show',guard)
            if button.SetShown then hooksecurefunc(button,'SetShown',guard) end
            hudLauncherGuards[button]=true
        end
        local readable,shown=pcall(button.IsShown,button)
        if readable and not (issecretvalue and issecretvalue(shown)) and shown then
            if not (SafeInCombat() and button.IsProtected and button:IsProtected()) then
                local hidden=pcall(button.Hide,button)
                if hidden then NS._hiddenHUDAddonButtons[button]=true end
            end
        end
    end
    for _,button in ipairs({Minimap:GetChildren()}) do hide(button) end
    hide(_G.EllesmereUIMinimapButton)
    local eui=_G.EllesmereUI
    if eui and self._hudEllesmereLauncherHooked~=eui and hooksecurefunc
        and type(eui.CreateMinimapButton)=='function' then
        hooksecurefunc(eui,'CreateMinimapButton',function()NS:HideHUDAddonButtons()end)
        self._hudEllesmereLauncherHooked=eui
    end
    -- Library callbacks also cover launchers registered after HUD activation.
    local lib=LibStub and LibStub('LibDBIcon-1.0',true)
    if lib and not self._hudLauncherLibraryHooked and hooksecurefunc and type(lib.Register)=='function' then
        hooksecurefunc(lib,'Register',function()NS:HideHUDAddonButtons()end)
        self._hudLauncherLibraryHooked=true
    end
end

function NS:HideMinimapAttachments()
    if not Minimap then return end

    self:HideKnownMinimapAttachments()
    self:HideHUDAddonButtons()

    if self.db and self.db.hud and self.db.hud.hideAddonOverlays then
        self:HideAddonMinimapOverlays()
    else
        self:RestoreAddonMinimapOverlays()
    end
end

function NS:RestoreMinimapAttachments()
    RestoreFrameSet(self._hiddenHUDAddonButtons)
    self._hiddenHUDAddonButtons=nil
    local alphas = self._hiddenMinimapControlAlphas
    self._hiddenMinimapControlAlphas = nil
    if alphas then
        for object, alpha in pairs(alphas) do pcall(object.SetAlpha, object, alpha) end
    end
    RestoreFrameSet(self._hiddenKnownMinimapFrames)
    RestoreFrameSet(self._hiddenAddonMinimapFrames)
    self._hiddenKnownMinimapFrames = nil
    self._hiddenAddonMinimapFrames = nil
end

function NS:RestoreMinimap()
    if not Minimap or not self._minimapState then return end
    local s = self._minimapState
    self._manualInputRestoring = true
    if self.DisableHUDCombatLayout then self:DisableHUDCombatLayout() end
    self:RestoreHUDMouseButtons()

    if s.blobRingScalars then
        for setter, scalar in pairs(s.blobRingScalars) do pcall(Minimap[setter], Minimap, scalar) end
    end

    -- Restore the original parent before restoring points. This keeps anchors
    -- in the same frame family as the normal Blizzard minimap.
    if s.parent then
        pcall(Minimap.SetParent, Minimap, s.parent)
    end

    Minimap:ClearAllPoints()
    if #s.points > 0 then
        for _, p in ipairs(s.points) do
            pcall(Minimap.SetPoint, Minimap, p[1], p[2], p[3], p[4], p[5])
        end
    else
        Minimap:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -20, -20)
    end

    if s.width and s.height then pcall(Minimap.SetSize, Minimap, s.width, s.height) end
    if s.scale ~= nil then pcall(Minimap.SetScale, Minimap, s.scale) end
    if s.alpha ~= nil then pcall(Minimap.SetAlpha, Minimap, s.alpha) end
    if s.mouse ~= nil then pcall(Minimap.EnableMouse, Minimap, s.mouse and true or false) end
    if s.strata then pcall(Minimap.SetFrameStrata, Minimap, s.strata) end
    if s.level then pcall(Minimap.SetFrameLevel, Minimap, s.level) end

    if s.zoom ~= nil and Minimap.SetZoom then
        pcall(Minimap.SetZoom, Minimap, s.zoom)
    end

    if s.mouseWheel ~= nil and Minimap.EnableMouseWheel then
        pcall(Minimap.EnableMouseWheel, Minimap, s.mouseWheel and true or false)
    end

    if s.rotateMinimap ~= nil then
        SafeSetCVar("rotateMinimap", s.rotateMinimap)
    end

    if Minimap.SetMaskTexture then
        pcall(
            Minimap.SetMaskTexture,
            Minimap,
            s.maskTexture or STOCK_MINIMAP_MASK
        )
    end

    if s.shown == false then
        pcall(Minimap.Hide, Minimap)
    else
        pcall(Minimap.Show, Minimap)
    end

    self._minimapState = nil
    self._manualInputRestoring = nil
    self:RestoreManualHoverInput()
end

function NS:RefreshNormalMinimap()
    -- Ask Blizzard to rebuild the normal minimap state after we hand it back.
    if Minimap_Update then pcall(Minimap_Update) end
    if Minimap_UpdateZoom then pcall(Minimap_UpdateZoom) end
    if Minimap_UpdateRotationSetting then pcall(Minimap_UpdateRotationSetting) end
end

function NS:IsTemporaryMouseModifierDown()
    if not self.db or not self.db.hud then return false end

    local modifier = self.db.hud.mouseModifier or "NONE"

    if modifier == "ALT" then
        return IsAltKeyDown and IsAltKeyDown() and true or false
    elseif modifier == "CTRL" then
        return IsControlKeyDown and IsControlKeyDown() and true or false
    elseif modifier == "SHIFT" then
        return IsShiftKeyDown and IsShiftKeyDown() and true or false
    end

    return false
end

function NS:ApplyHUDRotation()
    if not self.db or not self.db.hud or not self.db.hud.enabled then return end

    -- The hidden capture map is independent of the HUD drawing orientation.
    local mode = self.CursorSweepActive and "OFF" or self.db.hud.rotationMode or "CLIENT"
    local wanted
    if mode == "ON" then
        wanted = "1"
    elseif mode == "OFF" then
        wanted = "0"
    elseif self._minimapState then
        wanted = self._minimapState.rotateMinimap
    end
    if wanted ~= nil and SafeGetCVar("rotateMinimap") ~= wanted then
        SafeSetCVar("rotateMinimap", wanted)
    end
end

function NS:PassHUDMouseButtons(frame, allButtons)
    if SafeInCombat() or not frame or not frame.SetPassThroughButtons or not frame.ShouldButtonPassThrough then return end
    self._hudButtonPassThrough = self._hudButtonPassThrough or {}
    if self._hudButtonPassThrough[frame] then return end
    local original, wanted = {}, {}
    for _, button in ipairs(MOUSE_BUTTONS) do
        local ok, passes = pcall(frame.ShouldButtonPassThrough, frame, button)
        if not ok or (issecretvalue and issecretvalue(passes)) or type(passes) ~= "boolean" then return end
        if passes then original[#original + 1] = button end
        if passes or allButtons or button ~= "LeftButton" then wanted[#wanted + 1] = button end
    end
    if #wanted == #original or pcall(frame.SetPassThroughButtons, frame, unpack(wanted)) then
        self._hudButtonPassThrough[frame] = original
    end
end

function NS:RestoreHUDMouseButtons()
    local frames = self._hudButtonPassThrough
    self._hudButtonPassThrough = nil
    if frames then
        for frame, original in pairs(frames) do
            pcall(frame.SetPassThroughButtons, frame, unpack(original))
        end
    end
end

function NS:DisableHUDMouseWheel()
    if not Minimap or not Minimap.EnableMouseWheel or not self.db or not self.db.hud then
        return
    end

    local current = self._minimapMouseWheel
    if current == nil and Minimap.IsMouseWheelEnabled then
        local ok, value = pcall(Minimap.IsMouseWheelEnabled, Minimap)
        if ok and not (issecretvalue and issecretvalue(value)) then
            current = value
            self._minimapMouseWheel = value
        end
    end
    -- Keep wheel bindings available while the farming HUD covers the screen.
    if current ~= false then
        local ok = pcall(Minimap.EnableMouseWheel, Minimap, false)
        if ok then self._minimapMouseWheel = false end
    end
end

-- Physical Remember nodes uses native hover motion while world clicks pass
-- through the HUD. Prepare outside combat; never write protected input in combat.
function NS:ManualHoverHUDWanted()
    local hud=self.db and self.db.hud
    return self.ManualNodeHoverSourceReady and self.ManualNodeHoverEnabled and hud
        and hud.rememberNodes and (self.MinimapScanActive and self.ScanPresentations and self.ScanPresentations.minimap.active
            or hud.enabled and self.HUDFrame and not hud.keepMinimap)
end
function NS:CaptureManualHoverInput()
    if self._manualInputStates or SafeInCombat() or not self.ManualNodeHoverSourceReady
        or not self.ManualNodeHoverEnabled or not self.db.hud.rememberNodes or self.db.hud.keepMinimap and not self.MinimapScanActive then return end
    local states={}
    for _,frame in ipairs(self.MinimapScanActive and {Minimap} or {Minimap,self.HUDFrame})do
        local state={frame=frame}
        if frame.SetMouseClickEnabled and frame.IsMouseClickEnabled then
            local ok,value=pcall(frame.IsMouseClickEnabled,frame)
            if not ok or issecretvalue and issecretvalue(value) or type(value)~='boolean' then return end
            state.click=value
            if frame==Minimap and frame.SetMouseMotionEnabled and frame.IsMouseMotionEnabled then
                ok,value=pcall(frame.IsMouseMotionEnabled,frame)
                if not ok or issecretvalue and issecretvalue(value) or type(value)~='boolean' then return end
                state.motion=value
            end
        end
        if state.click==nil and frame.IsMouseEnabled and frame.EnableMouse then
            local ok,value=pcall(frame.IsMouseEnabled,frame)
            if not ok or issecretvalue and issecretvalue(value) or type(value)~='boolean' then return end
            state.mouse=value
        end
        if frame.SetPassThroughButtons and frame.ShouldButtonPassThrough then
            state.buttons={}
            for _,button in ipairs(MOUSE_BUTTONS)do
                local ok,value=pcall(frame.ShouldButtonPassThrough,frame,button)
                if not ok or issecretvalue and issecretvalue(value) or type(value)~='boolean' then return end
                if value then state.buttons[#state.buttons+1]=button end
            end
        end
        states[frame]=state
    end
    self._manualInputStates=states
    self._manualInputGuards=self._manualInputGuards or {}
    if hooksecurefunc then
        for frame in pairs(states)do
            if not self._manualInputGuards[frame] then
                for _,method in ipairs({'EnableMouse','SetMouseClickEnabled','SetMouseMotionEnabled','SetPassThroughButtons'})do
                    if type(frame[method])=='function' then hooksecurefunc(frame,method,function()self:UpdateManualHoverInput()end)end
                end
                self._manualInputGuards[frame]=true
            end
        end
    end
end
function NS:RestoreManualHoverInput()
    if self._manualInputBusy or not self._manualInputStates or SafeInCombat()then return end
    self._manualInputBusy=true
    local states=self._manualInputStates;self._manualInputStates=nil
    for frame,state in pairs(states)do
        if state.mouse~=nil then pcall(frame.EnableMouse,frame,state.mouse)end
        if state.click~=nil then pcall(frame.SetMouseClickEnabled,frame,state.click)end
        if state.motion~=nil then pcall(frame.SetMouseMotionEnabled,frame,state.motion)end
        if state.buttons then pcall(frame.SetPassThroughButtons,frame,unpack(state.buttons))end
    end
    self._manualInputBusy=nil
end
function NS:UpdateManualHoverInput()
    if self._manualInputBusy or self._manualInputRestoring then return true end
    local wanted=self:ManualHoverHUDWanted()
    if not wanted then
        if self._manualInputStates and SafeInCombat()then return true end
        self:RestoreManualHoverInput();return false
    end
    if SafeInCombat()then return true end
    self:CaptureManualHoverInput()
    if not self._manualInputStates then return false end
    self._manualInputBusy=true
    for frame,state in pairs(self._manualInputStates)do
        local editing=frame==self.HUDFrame and self.db.hud.locked==false
        if state.buttons then pcall(frame.SetPassThroughButtons,frame,unpack(editing and state.buttons or MOUSE_BUTTONS))end
        if state.mouse~=nil then pcall(frame.EnableMouse,frame,frame==Minimap or editing)end
        if state.motion~=nil then pcall(frame.SetMouseMotionEnabled,frame,true)end
        if state.click~=nil then pcall(frame.SetMouseClickEnabled,frame,editing)end
    end
    self._manualInputBusy=nil
    return true
end

function NS:UpdateHUDMouseInteraction()
    if self:UpdateManualHoverInput() then return end
    if not Minimap or not self.db or not self.db.hud.enabled then return end
    local wanted = (self.db.hud.mouseMode and true or false) or self:IsTemporaryMouseModifierDown()
    local current = Minimap:IsMouseEnabled()
    if (issecretvalue and issecretvalue(current)) or current ~= wanted then
        Minimap:EnableMouse(wanted)
    end
end

local function ApplyHUDMinimapState(self)
    self:HideHUDMinimapRings()
    self:DisableHUDMouseWheel()

    -- Remove Blizzard's circular minimap clipping while HUD mode is active.
    -- This is reapplied here because Blizzard or other UI addons may restore
    -- the normal circular mask during minimap updates.
    local hudMask = "Interface\\AddOns\\ForeverFarmRoute\\Gathering\\Media\\HUDMask.tga"
    local currentMask = self._minimapMaskTexture
    if currentMask == nil and Minimap.GetMaskTexture then
        local ok, value = pcall(Minimap.GetMaskTexture, Minimap)
        if ok and not (issecretvalue and issecretvalue(value)) then currentMask = value end
    end
    if Minimap.SetMaskTexture and currentMask ~= hudMask then
        local ok = pcall(
            Minimap.SetMaskTexture,
            Minimap,
            hudMask
        )
        if ok then self._minimapMaskTexture = hudMask end
    end
    local size = self.db.hud.size
    local originalWidth = (self._minimapState and self._minimapState.width) or Minimap:GetWidth()
    if not originalWidth or originalWidth <= 0 then originalWidth = 140 end

    local state = self._minimapState
    local wantedMapSize = size - 48
    local scale = wantedMapSize / originalWidth
    local secureLayout = self.ApplyHUDCombatLayout
        and self:ApplyHUDCombatLayout(state.width, state.height, scale)

    if not secureLayout then
        if state and state.width and state.height
            and (Minimap:GetWidth() ~= state.width or Minimap:GetHeight() ~= state.height)
        then
            Minimap:SetSize(state.width, state.height)
        end

        local parent = self:GetHUDMinimapParent()
        if Minimap:GetParent() ~= parent then Minimap:SetParent(parent) end
        local numPoints = Minimap:GetNumPoints()
        local point, relativeTo, relativePoint, x, y
        if numPoints == 1 then point, relativeTo, relativePoint, x, y = Minimap:GetPoint(1) end
        local secretPoint = issecretvalue and (issecretvalue(point) or issecretvalue(relativeTo)
            or issecretvalue(relativePoint) or issecretvalue(x) or issecretvalue(y))
        if numPoints ~= 1 or secretPoint or point ~= "CENTER" or relativeTo ~= self.HUDFrame
            or relativePoint ~= "CENTER" or x ~= 0 or y ~= 0
        then
            Minimap:ClearAllPoints()
            Minimap:SetPoint("CENTER", self.HUDFrame, "CENTER", 0, 0)
        end
        local currentScale = Minimap:GetScale()
        if (issecretvalue and issecretvalue(currentScale)) or math.abs(currentScale - scale) > 0.0001 then
            Minimap:SetScale(scale)
        end
    end
    local currentAlpha = Minimap:GetAlpha()
    if (issecretvalue and issecretvalue(currentAlpha)) or math.abs(currentAlpha - self.db.hud.mapAlpha) > 0.001 then
        Minimap:SetAlpha(self.db.hud.mapAlpha)
    end
    self:ResizeEllesmereHUDClip(wantedMapSize)

    local wantedZoom = self.db.hud.zoom or 0
    local okZoom, currentZoom
    if Minimap.GetZoom then okZoom, currentZoom = pcall(Minimap.GetZoom, Minimap) end
    if Minimap.SetZoom and (not okZoom or (issecretvalue and issecretvalue(currentZoom)) or currentZoom ~= wantedZoom) then
        pcall(Minimap.SetZoom, Minimap, wantedZoom)
    end

    if not (Minimap.IsFrameStrataFixed and Minimap:IsFrameStrataFixed()) and Minimap:GetFrameStrata() ~= "LOW" then
        Minimap:SetFrameStrata("LOW")
    end
    local wantedLevel = math.max(1, self.HUDFrame:GetFrameLevel() + 1)
    if not (Minimap.IsFrameLevelFixed and Minimap:IsFrameLevelFixed()) and Minimap:GetFrameLevel() ~= wantedLevel then
        Minimap:SetFrameLevel(wantedLevel)
    end
    self:UpdateHUDMouseInteraction()
    if Minimap.IsShown and not Minimap:IsShown() then Minimap:Show() end
end

function NS:KeepMinimapInHUD()
    if not Minimap or not self.HUDFrame or not self.db.hud.enabled or self._keepingMinimapInHUD then return end

    -- The setters above are also observed by our secure post-hooks. Suppress
    -- nested corrections and always release the guard if a client API fails.
    self._keepingMinimapInHUD = true
    local ok, err = pcall(ApplyHUDMinimapState, self)
    self._keepingMinimapInHUD = nil
    if not ok then error(err, 0) end
end

function NS:ApplyHUDLayout()
    if not self.db.hud.enabled then return end
    self:ApplyHUDRotation()
    self:ResizeHUDVisuals()
    self.HUDFrame:ClearAllPoints()
    self.HUDFrame:SetPoint("CENTER", UIParent, "CENTER", self.db.hud.x or 0, self.db.hud.y or 0)
    self:KeepMinimapInHUD()
end

local function ApplyHUDEnabledState(enabled)
    if enabled == NS.db.hud.enabled then
        return true
    end

    if enabled then
        NS:CaptureMinimapState()
        NS.db.hud.enabled = true
        NS:PassHUDMouseButtons(Minimap)
        NS:BeginEllesmereHUD()

        if NS.UpdateMinimapButton then
            NS:UpdateMinimapButton()
        end

        NS:HideMinimapAttachments()
        NS.HUDFrame:Show()
        NS:ApplyHUDLayout()
        if not NS.MinimapScanActive and not NS._experimentalHUDInternal then NS.Print(NS.L.HUD_ON) end
    else
        NS.db.hud.enabled = false
        NS.HUDFrame:Hide()

        NS:RestoreMinimap()
        NS:RestoreMinimapAttachments()
        NS:RefreshNormalMinimap()
        NS:EndEllesmereHUD()

        if NS.UpdateMinimapButton then
            NS:UpdateMinimapButton()
        end

        if not NS.MinimapScanActive and not NS._experimentalHUDInternal then NS.Print(NS.L.HUD_OFF) end
    end

    NS:UpdateAll()
    return true
end

function NS:UpdateExperimentalHUDOptions()
    local hud=self.OptionsPanel and self.OptionsPanel.pages.hud
    if not hud or not hud.experimentalAppearance then return end
    local enabled=self.db and self.db.hud.experimentalHUD==true
    hud.experimentalAppearance:SetAlpha(enabled and 1 or .35)
    local function control(widget)
        widget.experimentalDisabled=not enabled
        if widget.SetEnabled then widget:SetEnabled(enabled)
        elseif enabled and widget.Enable then widget:Enable()
        elseif not enabled and widget.Disable then widget:Disable() end
        if widget.EnableMouse then widget:EnableMouse(enabled) end
        if not enabled and widget.menu then widget.menu:Hide() end
        for _,row in pairs(widget.options or {})do
            row.experimentalDisabled=not enabled
            if row.SetEnabled then row:SetEnabled(enabled) end
            if row.EnableMouse then row:EnableMouse(enabled) end
        end
    end
    for _,widget in pairs(hud.positionButtons)do control(widget)end
    if hud.scanner then control(hud.scanner) end
    control(hud.rotationButton);control(hud.positionReset)
    for _,widget in pairs(hud.styleTiles)do control(widget)end
    for _,widget in pairs(hud.colorTiles)do control(widget)end
    for _,row in pairs(hud.positionSliders)do control(row.slider)end
end

function NS:SetHUDEnabled(enabled)
    enabled = enabled and true or false
    local mode=self.ExperimentalMinimap
    if mode and mode.deathPaused and not mode.deathTransition then
        mode.deathResume=enabled and 'hud' or nil
        return
    end


    if SafeInCombat() then
        self.pendingToggle = enabled
        self.Print(self.L.COMBAT_BLOCK)
        return
    end

    local wasEnabled=self.db.hud.enabled==true
    if self.HandleExperimentalHUDToggle and self:HandleExperimentalHUDToggle(enabled) then
        if not self._experimentalHUDInternal and not self.MinimapScanActive
            and wasEnabled~=(self.db.hud.enabled==true) then
            self.Print(self.db.hud.enabled and self.L.HUD_ON or self.L.HUD_OFF)
        end
        return
    end
    ApplyHUDEnabledState(enabled)
    if not self._experimentalHUDInternal and self.QuickScanner and self.QuickScanner.RefreshHUDMinimap then
        self.QuickScanner:RefreshHUDMinimap()
    end
end

function NS:ToggleHUD()
    if self.db and self.db.minimap then self.db.minimap.launcherMode="hud" end
    local hover=self.ReplacementMinimapHover
    local active=self.db.hud.enabled or self.QuickScanner and self.QuickScanner.hudHovering
        or hover and hover.armed and hover.presentation=='hud'
    self:SetHUDEnabled(not active)
end

function NS:UpdateCoordinates()
    if not self.HUDFrame or not self.HUDFrame:IsShown() then return end
    local mapID = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
    if mapID and C_Map.GetPlayerMapPosition then
        local pos = C_Map.GetPlayerMapPosition(mapID, "player")
        if pos and pos.GetXY then
            local x, y = pos:GetXY()
            if x and y and x > 0 and y > 0 then
                self.HUDFrame.coord:SetFormattedText("%.1f / %.1f", x * 100, y * 100)
                return
            end
        end
    end
    self.HUDFrame.coord:SetText(self.L.NO_COORDS)
end


local function ReadTrackingInfo(index)
    if GetTrackingInfo then
        local ok, name, texture, active = pcall(GetTrackingInfo, index)
        if ok then
            return name, active
        end
    end

    if C_Minimap and C_Minimap.GetTrackingInfo then
        local ok, info = pcall(C_Minimap.GetTrackingInfo, index)
        if ok and type(info) == "table" then
            return info.name, info.active
        end
    end

    return nil, nil
end

local function GetTrackingCount()
    if GetNumTrackingTypes then
        local ok, count = pcall(GetNumTrackingTypes)
        if ok and type(count) == "number" then
            return count
        end
    end

    if C_Minimap and C_Minimap.GetNumTrackingTypes then
        local ok, count = pcall(C_Minimap.GetNumTrackingTypes)
        if ok and type(count) == "number" then
            return count
        end
    end

    return nil
end

function NS:GetActiveTrackingText()
    local count = GetTrackingCount()
    if not count then
        return self.L.TRACKING_UNKNOWN
    end

    local active = {}
    for i = 1, count do
        local name, enabled = ReadTrackingInfo(i)
        if enabled and name and name ~= "" then
            active[#active + 1] = name
        end
    end

    if #active == 0 then
        return self.L.TRACKING_NONE
    end

    return table.concat(active, ", ")
end

function NS:UpdateTrackingStatus()
    if not self.OptionsPanel or not self.OptionsPanel.pages or not self.OptionsPanel.pages.welcome then
        return
    end

    local w = self.OptionsPanel.pages.welcome
    if not w.tracking then return end

    local text = self:GetActiveTrackingText()
    if text == self.L.TRACKING_NONE or text == self.L.TRACKING_UNKNOWN then
        w.tracking:SetText(text)
    else
        w.tracking:SetText(string.format(self.L.TRACKING_STATUS, text))
    end
end

-- Settings → AddOns --------------------------------------------------------

-- Each native category owns a scrollable canvas so controls stay reachable
-- at smaller UI scales, including on clients using Interface Options.
local function MakeSettingsPage(name, height)
    local panel = CreateFrame("Frame", "ForeverFarmRouteGathering_Settings_" .. name, UIParent)
    panel:Hide()
    local scroll = CreateFrame("ScrollFrame", nil, panel, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 0, 0)
    scroll:SetPoint("BOTTOMRIGHT", -28, 8)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(480, height)
    content:SetPoint("TOPLEFT", scroll, "TOPLEFT", 0, 0)
    scroll:SetScrollChild(content)
    scroll:SetScript("OnSizeChanged", function(_, width)
        content:SetWidth(math.max(480, width))
    end)
    content.panel = panel
    panel:SetScript("OnShow", function() NS:UpdateAll() end)
    -- Canvas settings save immediately, as the old window did.
    panel.OnCommit = function() end
    panel.OnDefault = function() end
    panel.OnRefresh = function() NS:UpdateAll() end
    return content
end

function NS:CreateSettingsPages()
    if self.OptionsPanel then return end

    local welcome = MakeSettingsPage("welcome", 340)
    local f = welcome.panel
    self.OptionsPanel = f
    f.pages = { welcome = welcome }
    welcome.head = MakeText(welcome, 22, "TOPLEFT", 20, -20, "")
    welcome.head:SetTextColor(1, 0.52, 0.16)
    f.title = welcome.head
    welcome.version = MakeText(welcome, 12, "TOPLEFT", 20, -45, "")
    welcome.version:SetTextColor(0.65, 0.65, 0.65)
    f.toggleBtn = MakeButton(welcome, 220, 30, "", function() NS:ToggleHUD() end)
    f.toggleBtn:SetPoint("TOPLEFT", 20, -290)

    welcome.separator = welcome:CreateTexture(nil, "BORDER")
    welcome.separator:SetTexture("Interface\\Buttons\\WHITE8X8")
    welcome.separator:SetVertexColor(0.35, 0.35, 0.40, 0.55)
    welcome.separator:SetHeight(1)
    welcome.separator:SetPoint("TOPLEFT", 20, -60)
    welcome.separator:SetPoint("TOPRIGHT", -20, -60)

    welcome.status = MakeText(welcome, 16, "TOPLEFT", 20, -86, "")

    welcome.tracking = MakeText(welcome, 13, "TOPLEFT", 20, -116, "")
    welcome.tracking:SetWidth(420)
    welcome.tracking:SetJustifyH("LEFT")

    welcome.note = MakeText(welcome, 12, "TOPLEFT", 20, -150, "")
    welcome.note:SetWidth(420)
    welcome.note:SetJustifyH("LEFT")
    welcome.note:SetJustifyV("TOP")
    welcome.note:SetTextColor(1, 0.78, 0.38)

    welcome.slash = MakeText(welcome, 12, "TOPLEFT", 20, -226, "")
    welcome.slash:SetWidth(420)
    welcome.slash:SetJustifyH("LEFT")
    welcome.slash:SetJustifyV("TOP")
    welcome.slash:SetTextColor(0.82, 0.82, 0.82)

    -- HUD page --------------------------------------------------------------
    local hud = MakeSettingsPage("hud", 1830)
    f.pages.hud = hud

    hud.head = MakeText(hud, 22, "TOPLEFT", 20, -20, "")
    hud.head:SetTextColor(1, 0.52, 0.16)

    hud.sizeLabel = MakeText(hud, 13, "TOPLEFT", 20, -78, "")
    hud.sizeValue = MakeText(hud, 12, "TOPRIGHT", -28, -78, "")
    hud.sizeSlider = MakeSlider(hud, 380, 280, 1000, 10)
    hud.sizeSlider:SetPoint("TOPLEFT", 28, -106)
    hud.sizeSlider:SetScript("OnValueChanged", function(_, value)
        if not NS.db then return end
        value = math.floor(value / 10 + 0.5) * 10
        NS.db.hud.size = value
        hud.sizeValue:SetText(tostring(value))
        NS:ResizeHUDVisuals()
        if NS.db.hud.enabled then NS:ApplyHUDLayout() end
    end)

    hud.mapAlphaLabel = MakeText(hud, 13, "TOPLEFT", 20, -170, "")
    hud.mapAlphaValue = MakeText(hud, 12, "TOPRIGHT", -28, -170, "")
    hud.mapAlphaSlider = MakeSlider(hud, 380, 0.0, 1.0, 0.01)
    hud.mapAlphaSlider:SetPoint("TOPLEFT", 28, -198)
    hud.mapAlphaSlider:SetScript("OnValueChanged", function(_, value)
        if not NS.db then return end
        NS.db.hud.mapAlpha = Clamp(value, 0.0, 1.0)
        hud.mapAlphaValue:SetFormattedText("%d%%", math.floor(NS.db.hud.mapAlpha * 100 + 0.5))
        if NS.db.hud.enabled then NS:KeepMinimapInHUD() end
    end)

    hud.experimentalTerrain = MakeCheckbox(hud, "Show terrain in experimental HUD", function(value)
        NS.db.hud.experimentalTerrain = value
        if NS.ExperimentalHUDTerrain then NS.ExperimentalHUDTerrain:Update() end
    end)
    hud.experimentalTerrain:SetPoint("TOPLEFT", 20, -230)

    hud.zoomLabel = MakeText(hud, 13, "TOPLEFT", 20, -262, "")
    hud.zoomValue = MakeText(hud, 12, "TOPRIGHT", -28, -262, "")
    hud.zoomSlider = MakeSlider(hud, 380, 0, 5, 1)
    hud.zoomSlider:SetPoint("TOPLEFT", 28, -290)
    hud.zoomSlider:SetScript("OnValueChanged", function(_, value)
        if not NS.db then return end
        value = math.floor(value + 0.5)
        NS.db.hud.zoom = Clamp(value, 0, 5)
        hud.zoomValue:SetText(tostring(NS.db.hud.zoom))
        if NS.db.hud.enabled then NS:KeepMinimapInHUD() end
    end)

    hud.zoomHint = MakeText(hud, 10, "TOPLEFT", 28, -319, "")
    hud.zoomHint:SetWidth(410)
    hud.zoomHint:SetJustifyH("LEFT")
    hud.zoomHint:SetTextColor(0.65, 0.65, 0.65)

    hud.lock = MakeCheckbox(hud, "", function(value)
        NS.db.hud.locked = value
        NS:UpdateHUDInteraction()
    end)
    hud.lock:SetPoint("TOPLEFT", 20, -372)

    hud.showScanStatus = MakeCheckbox(hud, "Show movable scan status icon", function(value)
        NS:SetScanStatusShown(value)
    end)
    hud.showScanStatus:SetPoint("TOPLEFT", 20, -402)

    hud.resetPos = MakeButton(hud, 220, 30, "", function() NS:ResetHUDPosition() end)
    hud.resetPos:SetPoint("TOPLEFT", 20, -430)

    hud.experimentalHead = MakeText(hud, 16, "TOPLEFT", 20, -480, "Experimental")
    hud.experimentalNodes = MakeCheckbox(hud, "Use experimental HUD", function(value)
        if NS.SetExperimentalHUDSelected then NS:SetExperimentalHUDSelected(value) end
        hud.experimentalNodes:SetChecked(NS.db.hud.experimentalHUD==true)
        NS:UpdateExperimentalHUDOptions()
    end)
    hud.experimentalNodes:SetPoint("TOPLEFT", 20, -510)
    hud.experimentalNodes.text:SetWidth(390)
    hud.experimentalNodes.text:SetJustifyH("LEFT")
    hud.scanner = MakeText(hud, 12, "TOPLEFT", 235, -510, "Quick scan")
    hud.experimentalHint = MakeText(hud, 10, "TOPLEFT", 48, -543,
        "Quick scan shows the normal HUD between passes. These duration and timing settings are shared with Experimental minimap. Continuous scans while enabled.")
    hud.experimentalHint:SetWidth(390)
    hud.experimentalHint:SetJustifyH("LEFT")
    hud.experimentalHint:SetTextColor(0.65, 0.65, 0.65)

    local appearance = CreateFrame("Frame", nil, hud)
    appearance:SetPoint("TOPLEFT", hud, "TOPLEFT", 0, -210)
    appearance:SetPoint("BOTTOMRIGHT", hud, "BOTTOMRIGHT", 0, -210)
    appearance:EnableMouse(false)
    hud.experimentalAppearance = appearance
    hud.positionHead = MakeText(appearance, 16, "TOPLEFT", 20, -590, "HUD appearance")
    hud.positionHint = MakeText(appearance, 11, "TOPLEFT", 20, -620,
        "Customize the position marker and resource drawing layer. Move the HUD to move your position marker and resources together.")
    hud.positionHint:SetWidth(420)
    hud.positionHint:SetJustifyH("LEFT")
    hud.positionButtons = {}
    for _, spec in ipairs({
        {"overlayStrata", "Drawing layer", {"LOW", "MEDIUM", "HIGH", "DIALOG"}, 690},
    }) do
        local key, label, choices, y = unpack(spec)
        MakeText(appearance, 13, "TOPLEFT", 20, -y, label)
        local labels = {LOW="Low", MEDIUM="Medium", HIGH="High", DIALOG="Dialog"}
        local entries = {}
        for _, value in ipairs(choices) do entries[#entries + 1] = {value, labels[value]} end
        local button = MakeHUDDropdown(appearance, entries, function() return NS.db.hud[key] end, function(value)
            if not NS.db.hud.experimentalHUD then return end
            NS.db.hud[key] = value
            NS:UpdateAll()
        end)
        button:SetPoint("TOPLEFT", 235, -y + 7)
        hud.positionButtons[key] = button
    end
    MakeText(appearance, 13, "TOPLEFT", 20, -740, "HUD rotation")
    hud.rotationButton = MakeHUDDropdown(appearance, {
        {"ON", "Rotate with character"}, {"OFF", "North up"}, {"CLIENT", "Follow minimap setting"},
    }, function() return NS.db.hud.rotationMode end, function(value)
        if not NS.db.hud.experimentalHUD then return end
        NS.db.hud.rotationMode = value
        NS:UpdateAll()
        if NS.db.hud.enabled and NS.ApplyHUDRotation then NS:ApplyHUDRotation() end
    end)
    hud.rotationButton:SetPoint("TOPLEFT", 235, -733)
    hud.rotationHint = MakeText(appearance, 10, "TOPLEFT", 20, -775,
        "Rotate with character: resources turn and arrow points forward. North up: arrow turns with your character.")
    hud.rotationHint:SetWidth(420)
    hud.rotationHint:SetJustifyH("LEFT")

    -- Visible choices replace the cycling icon/colour buttons.
    local function ChoiceTile(x, y, label, height)
        local button = CreateFrame("Button", nil, appearance)
        button:SetSize(height, height)
        button:SetPoint("TOPLEFT", x, -y)
        button.border = button:CreateTexture(nil, "BACKGROUND")
        button.border:SetAllPoints(button)
        button.border:SetTexture("Interface\\Buttons\\WHITE8X8")
        button.border:SetVertexColor(0.32, 0.28, 0.21, 1)
        local inner = button:CreateTexture(nil, "BACKGROUND", nil, 1)
        inner:SetPoint("TOPLEFT", button, "TOPLEFT", 1, -1)
        inner:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -1, 1)
        inner:SetTexture("Interface\\Buttons\\WHITE8X8")
        inner:SetVertexColor(0.035, 0.03, 0.025, 1)
        button.caption = MakeText(button, 11, "TOP", 0, -height - 8, label)
        button.caption:ClearAllPoints()
        button.caption:SetPoint("TOP", button, "BOTTOM", 0, -7)
        button.caption:SetWidth(82)
        button.caption:SetJustifyH("CENTER")
        if button.caption.SetWordWrap then button.caption:SetWordWrap(false) end
        button:SetScript("OnEnter", function() if not button.selected then button.border:SetVertexColor(0.9, 0.72, 0.3, 1) end end)
        button:SetScript("OnLeave", function() if not button.selected then button.border:SetVertexColor(0.32, 0.28, 0.21, 1) end end)
        return button
    end
    MakeText(appearance, 13, "TOPLEFT", 20, -820, "Position icon")
    hud.styleTiles = {}
    for index, spec in ipairs({{"CROSS","Cross"},{"DOT","Dot"},{"RING","Ring"},{"ARROW","Player arrow"},{"NONE","Hidden"}}) do
        local style = spec[1]
        local button = ChoiceTile(30 + (index - 1) * 85, 847, spec[2], 52)
        local view = {positionLayer = CreateFrame("Frame", nil, button)}
        view.positionLayer:SetSize(52, 42)
        view.positionLayer:SetPoint("CENTER", button, "CENTER", 0, 0)
        view.positionLayer:EnableMouse(false)
        view.dualCenter = MakeText(view.positionLayer, 28, "CENTER", 0, 0, "+")
        view.positionTexture = view.positionLayer:CreateTexture(nil, "ARTWORK")
        view.positionTexture:SetPoint("CENTER", view.positionLayer, "CENTER", 0, 0)
        button.view = view
        if style == "RING" then
            view.ringHole = view.positionLayer:CreateTexture(nil, "ARTWORK", nil, 1)
            view.ringHole:SetTexture("Interface\\Common\\CommonMaskCircle")
            view.ringHole:SetSize(20, 20)
            view.ringHole:SetPoint("CENTER", view.positionLayer, "CENTER", 0, 0)
            view.ringHole:SetVertexColor(0.035, 0.03, 0.025, 1)
        end
        if style == "NONE" then
            local hidden = MakeText(button, 24, "CENTER", 0, 0, "/")
            hidden:SetTextColor(0.6, 0.6, 0.6)
        end
        button:SetScript("OnClick", function() if not NS.db.hud.experimentalHUD then return end; NS.db.hud.positionStyle = style; NS:UpdateAll() end)
        hud.styleTiles[style] = button
    end
    MakeText(appearance, 13, "TOPLEFT", 20, -940, "Position colour")
    hud.colorTiles = {}
    for index, spec in ipairs({{"CYAN","Cyan"},{"WHITE","White"},{"GOLD","Gold"},{"GREEN","Green"},{"PINK","Pink"}}) do
        local key = spec[1]
        local button = ChoiceTile(40 + (index - 1) * 85, 965, spec[2], 32)
        local swatch = button:CreateTexture(nil, "ARTWORK")
        swatch:SetTexture("Interface\\Common\\CommonMaskCircle")
        swatch:SetSize(16, 16)
        swatch:SetPoint("CENTER", button, "CENTER", 0, 0)
        local color = POSITION_COLORS[key]
        swatch:SetVertexColor(color[1], color[2], color[3])
        button:SetScript("OnClick", function() if not NS.db.hud.experimentalHUD then return end; NS.db.hud.positionColor = key; NS:UpdateAll() end)
        hud.colorTiles[key] = button
    end

    hud.positionSliders = {}
    for _, spec in ipairs({
        {"positionSize", "Position icon size", 8, 64, 1, 1040},
        {"positionOpacity", "Position icon opacity", 10, 100, 5, 1140},
        {"overlayLevel", "Drawing order", 1, 200, 1, 1240},
    }) do
        local key, label, low, high, step, y = unpack(spec)
        MakeText(appearance, 13, "TOPLEFT", 20, -y, label)
        local row = {value = MakeText(appearance, 13, "TOPRIGHT", -28, -y, "")}
        row.slider = MakeSlider(appearance, 380, low, high, step)
        row.slider:SetPoint("TOPLEFT", 28, -y - 30)
        row.slider:SetScript("OnValueChanged", function(_, value)
            if hud.positionRefreshing or not NS.db.hud.experimentalHUD then return end
            value = math.max(low, math.min(high, math.floor(value + 0.5)))
            NS.db.hud[key] = key == "positionOpacity" and value / 100 or value
            NS:UpdateAll()
        end)
        hud.positionSliders[key] = row
    end
    hud.positionReset = MakeButton(appearance, 220, 30, "Reset HUD icon options", function()
        if not NS.db.hud.experimentalHUD then return end
        NS.db.hud.overlayStrata, NS.db.hud.overlayLevel = "HIGH", 200
        NS.db.hud.positionStyle, NS.db.hud.positionColor = "ARROW", "WHITE"
        NS.db.hud.positionSize, NS.db.hud.positionOpacity = 40, 1
        NS.db.hud.rotationMode = "ON"
        NS:UpdateAll()
    end)
    hud.positionReset:SetPoint("TOPLEFT", 20, -1340)

    hud.previewTitle = MakeText(appearance, 13, "TOPLEFT", 20, -1390, "Position icon preview")
    hud.preview = {}
    local preview = CreateFrame("Frame", nil, appearance)
    preview:SetSize(420, 100)
    preview:SetPoint("TOPLEFT", 20, -1415)
    preview:EnableMouse(false)
    CreateBackdrop(preview, 0.9)
    hud.preview.positionLayer = CreateFrame("Frame", nil, preview)
    hud.preview.positionLayer:SetAllPoints(preview)
    hud.preview.positionLayer:EnableMouse(false)
    hud.preview.dualCenter = MakeText(hud.preview.positionLayer, 18, "CENTER", 0, 0, "+")
    hud.preview.positionTexture = hud.preview.positionLayer:CreateTexture(nil, "OVERLAY")
    hud.preview.positionTexture:SetPoint("CENTER", hud.preview.positionLayer, "CENTER", 0, 0)
    hud.previewHint = MakeText(appearance, 11, "TOPLEFT", 20, -1530,
        "Actual icon size, colour and opacity. Hidden shows no icon. The live player arrow follows your facing; this sample points up. Drawing order is visible on the live HUD.")
    hud.previewHint:SetWidth(420)
    hud.previewHint:SetJustifyH("LEFT")

    local mini = MakeSettingsPage("minimap", 570)
    f.pages.minimap = mini
    mini.head = MakeText(mini, 22, "TOPLEFT", 20, -20, "Experimental minimap")
    mini.enabled = MakeCheckbox(mini, "Use experimental minimap", function(value)
        if NS.SetExperimentalMinimapEnabled then NS:SetExperimentalMinimapEnabled(value) end
    end)
    mini.enabled:SetPoint("TOPLEFT", 20, -75)
    mini.showScanStatus = MakeCheckbox(mini, "Show movable scan status icon", function(value)
        NS:SetScanStatusShown(value)
    end)
    mini.showScanStatus:SetPoint("TOPLEFT", 20, -115)
    mini.scannerLabel=MakeText(mini, 14, "TOPLEFT", 20, -165, "Scanner")
    mini.scannerLabel:SetText("Quick scan")
    mini.scannerHint=MakeText(mini, 11, "TOPLEFT", 48, -255,
        "Quick scan checks known locations and returns to the normal minimap. Swap timing requires automatic tracking. Interval timing scans the currently tracked resource. Duration is a maximum; scans can finish earlier. Continuous repeats known-location scans while enabled and disables timing controls.")
    mini.scannerHint:SetWidth(390)
    mini.scannerHint:SetJustifyH("LEFT")

    local function quickOption(parent, key, y, title, choices)
        MakeText(parent, 12, "TOPLEFT", 20, y, title)
        local widget=MakeHUDDropdown(parent, choices,
            function() return NS.db.quickScan[key] end,
            function(value)
                if key=="interval" and (NS:GetQuickScanDuration()==math.huge or value<NS:GetQuickScanDuration()) then return end
                NS.db.quickScan[key]=value
                if NS:GetQuickScanDuration()~=math.huge then
                    NS.db.quickScan.interval=NS:GetQuickScanInterval()
                end
                if NS.QuickScanner then NS.QuickScanner.nextTimedScan=nil end
                NS:UpdateAll()
            end)
        widget:SetPoint("TOPLEFT", 220, y+5)
        return widget
    end
    local function quickOptions(parent, y)
        parent.duration=quickOption(parent, "duration", y, "Maximum scan duration", {
            {1.5,"1.5 seconds"},{2,"2 seconds"},{2.5,"2.5 seconds"},{3,"3 seconds"},{"continuous","Continuous"}})
        parent.trigger=quickOption(parent, "trigger", y-60, "Start a scan", {
            {"swap","After each automatic swap"},{"interval","At a regular interval"}})
        parent.interval=quickOption(parent, "interval", y-120, "Time between scans", {
            {3,"3 seconds"},{4,"4 seconds"},{5,"5 seconds"},{6,"6 seconds"},{7,"7 seconds"},{8,"8 seconds"},{9,"9 seconds"},{10,"10 seconds"}})
    end
    quickOptions(mini, -335)
    quickOptions(hud, -605)

    -- Tracking applies to the normal minimap as well as the farming HUD.
    local tracking = MakeSettingsPage("tracking", 790)
    f.pages.tracking = tracking
    tracking.head = MakeText(tracking, 22, "TOPLEFT", 20, -20, "")
    tracking.head:SetTextColor(1, 0.52, 0.16)
    tracking.autoTracking = MakeCheckbox(tracking, "", function(value)
        NS.db.hud.autoTracking = value
        if value then
            NS.db.hud.autoTrackingWithHUD = false
            tracking.autoTrackingWithHUD:SetChecked(false)
        end
        NS:SetTrackingSwapsPaused(false)
    end)
    tracking.autoTracking:SetPoint("TOPLEFT", 20, -80)
    tracking.autoTracking.text:SetWidth(255)
    tracking.autoTracking.text:SetJustifyH("LEFT")

    tracking.trackingIntervalButton = MakeButton(tracking, 110, 26, "", function()
        tracking.trackingIntervalMenu:SetShown(not tracking.trackingIntervalMenu:IsShown())
    end)
    tracking.trackingIntervalButton:SetPoint("TOPRIGHT", -25, -78)

    tracking.trackingIntervalMenu = CreateFrame("Frame", nil, tracking)
    tracking.trackingIntervalMenu:SetSize(110, 386)
    tracking.trackingIntervalMenu:SetPoint("TOPRIGHT", tracking.trackingIntervalButton, "BOTTOMRIGHT", 0, -4)
    tracking.trackingIntervalMenu:SetFrameStrata("DIALOG")
    tracking.trackingIntervalMenu:SetFrameLevel(tracking:GetFrameLevel() + 50)
    CreateBackdrop(tracking.trackingIntervalMenu, 0.99)
    tracking.trackingIntervalMenu:Hide()
    tracking.trackingIntervalMenu.buttons = {}
    for halfSeconds = 4, 20 do
        local seconds = halfSeconds / 2
        local option = MakeButton(tracking.trackingIntervalMenu, 98, 21, "", function()
            NS.db.hud.trackingInterval = seconds
            tracking.trackingIntervalMenu:Hide()
            NS:RefreshTexts()
        end)
        option:SetPoint("TOPLEFT", 6, -6 - ((halfSeconds - 4) * 22))
        tracking.trackingIntervalMenu.buttons[#tracking.trackingIntervalMenu.buttons + 1] = { button = option, seconds = seconds }
    end
    tracking.panel:SetScript("OnHide", function() tracking.trackingIntervalMenu:Hide() end)

    tracking.autoTrackingHint = MakeText(tracking, 10, "TOPLEFT", 48, -113, "")
    tracking.autoTrackingHint:SetWidth(390)
    tracking.autoTrackingHint:SetJustifyH("LEFT")
    tracking.autoTrackingHint:SetJustifyV("TOP")
    tracking.autoTrackingHint:SetTextColor(0.65, 0.65, 0.65)

    tracking.autoTrackingWithHUD = MakeCheckbox(tracking, "Auto-switch Herbs/Ore only while HUD is open", function(value)
        NS.db.hud.autoTrackingWithHUD = value
        if value then
            NS.db.hud.autoTracking = false
            tracking.autoTracking:SetChecked(false)
        end
        NS:SetTrackingSwapsPaused(false)
    end)
    tracking.autoTrackingWithHUD:SetPoint("TOPLEFT", 20, -170)
    tracking.autoTrackingWithHUD.text:SetWidth(390)
    tracking.autoTrackingWithHUDHint = MakeText(tracking, 10, "TOPLEFT", 48, -203,
        "Opening the HUD enables auto-switching; closing it stops switching. Requires both professions and follows the same safety rules.")
    tracking.autoTrackingWithHUDHint:SetWidth(390)
    tracking.autoTrackingWithHUDHint:SetJustifyH("LEFT")

    tracking.autoTrackingInDungeons = MakeCheckbox(tracking, "", function(value)
        NS.db.hud.autoTrackingInDungeons = value
        NS:UpdateAutoTracking()
    end)
    tracking.autoTrackingInDungeons:SetPoint("TOPLEFT", 20, -260)
    tracking.autoTrackingInDungeons.text:SetWidth(390)
    tracking.autoTrackingInDungeons.text:SetJustifyH("LEFT")
    tracking.autoTrackingInDungeonsHint = MakeText(tracking, 10, "TOPLEFT", 48, -293, "")
    tracking.autoTrackingInDungeonsHint:SetWidth(390)
    tracking.autoTrackingInDungeonsHint:SetJustifyH("LEFT")
    tracking.autoTrackingInDungeonsHint:SetJustifyV("TOP")
    tracking.autoTrackingInDungeonsHint:SetTextColor(0.65, 0.65, 0.65)

    tracking.restoreTracking = MakeCheckbox(tracking, "", function(value)
        NS.db.hud.restoreTracking = value
        NS:UpdateAutoTracking()
    end)
    tracking.restoreTracking:SetPoint("TOPLEFT", 20, -350)
    tracking.restoreTracking.text:SetWidth(390)
    tracking.restoreTracking.text:SetJustifyH("LEFT")
    tracking.restoreTrackingHint = MakeText(tracking, 10, "TOPLEFT", 48, -383, "")
    tracking.restoreTrackingHint:SetWidth(390)
    tracking.restoreTrackingHint:SetJustifyH("LEFT")
    tracking.restoreTrackingHint:SetJustifyV("TOP")
    tracking.restoreTrackingHint:SetTextColor(0.65, 0.65, 0.65)

    tracking.includeTreasure = MakeCheckbox(tracking, "", function(value)
        NS.db.hud.includeTreasure = value
        NS:UpdateAutoTracking()
        if NS.UpdateRememberedNodes then NS:UpdateRememberedNodes() end
    end)
    tracking.includeTreasure:SetPoint("TOPLEFT", 20, -440)
    tracking.includeTreasure.text:SetWidth(390)
    tracking.includeTreasure.text:SetJustifyH("LEFT")
    tracking.includeTreasureHint = MakeText(tracking, 10, "TOPLEFT", 48, -473, "")
    tracking.includeTreasureHint:SetWidth(390)
    tracking.includeTreasureHint:SetJustifyH("LEFT")
    tracking.includeTreasureHint:SetJustifyV("TOP")
    tracking.includeTreasureHint:SetTextColor(0.65, 0.65, 0.65)

    tracking.rememberNodes = MakeCheckbox(tracking, "", function(value)
        NS.db.hud.rememberNodes = value
        if NS.UpdateRememberedNodes then NS:UpdateRememberedNodes() end
    end)
    tracking.rememberNodes:SetPoint("TOPLEFT", 20, -530)
    tracking.rememberNodes.text:SetWidth(390)
    tracking.rememberNodes.text:SetJustifyH("LEFT")
    tracking.rememberNodesHint = MakeText(tracking, 10, "TOPLEFT", 48, -563, "")
    tracking.rememberNodesHint:SetWidth(390)
    tracking.rememberNodesHint:SetJustifyH("LEFT")
    tracking.rememberNodesHint:SetJustifyV("TOP")
    tracking.rememberNodesHint:SetTextColor(0.65, 0.65, 0.65)

    tracking.nodeIconSizeLabel = MakeText(tracking, 13, "TOPLEFT", 20, -618, "")
    tracking.nodeIconSizeValue = MakeText(tracking, 12, "TOPRIGHT", -28, -618, "")
    tracking.nodeIconSizeSlider = MakeSlider(tracking, 380, 8, 32, 1)
    tracking.nodeIconSizeSlider:SetPoint("TOPLEFT", 28, -646)
    tracking.nodeIconSizeSlider:SetScript("OnValueChanged", function(_, value)
        if not NS.db then return end
        value = Clamp(math.floor(value + 0.5), 8, 32)
        NS.db.hud.nodeIconSize = value
        tracking.nodeIconSizeValue:SetText(tostring(value))
        if NS.UpdateRememberedNodes then NS:UpdateRememberedNodes() end
    end)
    tracking.nodeIconSizeHint = MakeText(tracking, 10, "TOPLEFT", 28, -675, "")
    tracking.nodeIconSizeHint:SetWidth(390)
    tracking.nodeIconSizeHint:SetJustifyH("LEFT")
    tracking.nodeIconSizeHint:SetTextColor(0.65, 0.65, 0.65)

    -- Advanced page ----------------------------------------------------------
    local advanced = MakeSettingsPage("advanced", 300)
    f.pages.advanced = advanced

    advanced.head = MakeText(advanced, 22, "TOPLEFT", 20, -20, "")
    advanced.head:SetTextColor(1, 0.52, 0.16)

    advanced.rotationLabel = MakeText(advanced, 13, "TOPLEFT", 20, -78, "")
    advanced.rotationButton = MakeButton(advanced, 130, 28, "", function()
        local mode = NS.db.hud.rotationMode or "CLIENT"
        if mode == "CLIENT" then
            mode = "ON"
        elseif mode == "ON" then
            mode = "OFF"
        else
            mode = "CLIENT"
        end

        NS.db.hud.rotationMode = mode
        NS:UpdateAll()
        if NS.db.hud.enabled then
            NS:ApplyHUDRotation()
        end
    end)
    advanced.rotationButton:SetPoint("TOPLEFT", 250, -68)

    advanced.rotationHint = MakeText(advanced, 10, "TOPLEFT", 20, -112, "")
    advanced.rotationHint:SetWidth(420)
    advanced.rotationHint:SetJustifyH("LEFT")
    advanced.rotationHint:SetJustifyV("TOP")
    advanced.rotationHint:SetTextColor(0.65, 0.65, 0.65)

    advanced.hideAddonOverlays = MakeCheckbox(advanced, "", function(value)
        NS.db.hud.hideAddonOverlays = value
        if NS.db.hud.enabled then
            if value then
                NS:HideAddonMinimapOverlays()
            else
                NS:RestoreAddonMinimapOverlays()
            end
        end
        NS:UpdateHUDInteraction()
    end)
    advanced.hideAddonOverlays:SetPoint("TOPLEFT", 20, -180)
    advanced.hideAddonOverlays.text:SetWidth(390)
    advanced.hideAddonOverlays.text:SetJustifyH("LEFT")

    advanced.hideAddonOverlaysHint = MakeText(advanced, 10, "TOPLEFT", 48, -207, "")
    advanced.hideAddonOverlaysHint:SetWidth(390)
    advanced.hideAddonOverlaysHint:SetJustifyH("LEFT")
    advanced.hideAddonOverlaysHint:SetJustifyV("TOP")
    advanced.hideAddonOverlaysHint:SetTextColor(0.65, 0.65, 0.65)

    -- Controls page ---------------------------------------------------------
    local controls = MakeSettingsPage("controls", 855)
    f.pages.controls = controls

    controls.head = MakeText(controls, 22, "TOPLEFT", 20, -20, "")
    controls.head:SetTextColor(1, 0.52, 0.16)

    controls.mouse = MakeCheckbox(controls, "", function(value)
        NS.db.hud.mouseMode = value
        if NS.db.hud.enabled then NS:KeepMinimapInHUD() end
    end)
    controls.mouse:SetPoint("TOPLEFT", 20, -80)
    controls.mouse.text:SetWidth(390)
    controls.mouse.text:SetJustifyH("LEFT")

    controls.mouseHint = MakeText(controls, 10, "TOPLEFT", 48, -107, "")
    controls.mouseHint:SetWidth(380)
    controls.mouseHint:SetJustifyH("LEFT")
    controls.mouseHint:SetTextColor(0.65, 0.65, 0.65)

    controls.tempMouseLabel = MakeText(controls, 12, "TOPLEFT", 48, -145, "")
    controls.tempMouseButton = MakeButton(controls, 110, 26, "", function()
        local current = NS.db.hud.mouseModifier or "NONE"
        if current == "NONE" then
            current = "ALT"
        elseif current == "ALT" then
            current = "CTRL"
        elseif current == "CTRL" then
            current = "SHIFT"
        else
            current = "NONE"
        end

        NS.db.hud.mouseModifier = current
        NS:UpdateAll()
        if NS.db.hud.enabled then NS:KeepMinimapInHUD() end
    end)
    controls.tempMouseButton:SetPoint("LEFT", controls.tempMouseLabel, "RIGHT", 18, 0)

    controls.tempMouseHint = MakeText(controls, 10, "TOPLEFT", 48, -179, "")
    controls.tempMouseHint:SetWidth(380)
    controls.tempMouseHint:SetJustifyH("LEFT")
    controls.tempMouseHint:SetTextColor(0.65, 0.65, 0.65)

    controls.keyLabel = MakeText(controls, 13, "TOPLEFT", 20, -233, "")
    controls.keyButton = MakeButton(controls, 185, 28, "", function(self)
        if NS.BeginToggleKeyCapture then NS:BeginToggleKeyCapture(self) end
    end)
    controls.keyButton:SetPoint("TOPLEFT", 165, -223)

    controls.keyClear = MakeButton(controls, 82, 28, "", function()
        if NS.SetToggleKey then NS:SetToggleKey(nil) end
    end)
    controls.keyClear:SetPoint("LEFT", controls.keyButton, "RIGHT", 8, 0)

    controls.keyHint = MakeText(controls, 10, "TOPLEFT", 20, -266, "")
    controls.keyHint:SetWidth(430)
    controls.keyHint:SetJustifyH("LEFT")
    controls.keyHint:SetTextColor(0.65, 0.65, 0.65)

    controls.dismissKeyLabel = MakeText(controls, 13, "TOPLEFT", 20, -310, "Remove nearest icon:")
    controls.dismissKeyButton = MakeButton(controls, 185, 28, "", function(self)
        if NS.BeginDismissKeyCapture then NS:BeginDismissKeyCapture(self) end
    end)
    controls.dismissKeyButton:SetPoint("TOPLEFT", 165, -300)
    controls.dismissKeyClear = MakeButton(controls, 82, 28, "Clear", function()
        if NS.SetDismissKey then NS:SetDismissKey(nil) end
    end)
    controls.dismissKeyClear:SetPoint("LEFT", controls.dismissKeyButton, "RIGHT", 8, 0)
    controls.dismissKeyHint = MakeText(controls, 10, "TOPLEFT", 20, -340,
        "Click the binding button, then press a key or Shift + right-click this button. Removes the nearest icon; saved history is kept.")
    controls.dismissKeyHint:SetWidth(430)
    controls.dismissKeyHint:SetJustifyH("LEFT")

    controls.pauseKeyLabel = MakeText(controls, 13, "TOPLEFT", 20, -400, "Pause swaps:")
    controls.pauseKeyButton = MakeButton(controls, 185, 28, "", function(self)
        NS:BeginPauseKeyCapture(self)
    end)
    controls.pauseKeyButton:SetPoint("TOPLEFT", 165, -390)
    controls.pauseKeyClear = MakeButton(controls, 82, 28, "Clear", function() NS:SetPauseKey(nil) end)
    controls.pauseKeyClear:SetPoint("LEFT", controls.pauseKeyButton, "RIGHT", 8, 0)
    controls.pauseKeyButton:SetText(NS:GetPauseKeyDisplay())
    controls.pauseKeyHint = MakeText(controls, 10, "TOPLEFT", 20, -430,
        "Press once to pause automatic tracking swaps; press again to resume. Reloading or relogging clears this pause.")
    controls.pauseKeyHint:SetWidth(430)
    controls.pauseKeyHint:SetJustifyH("LEFT")
    controls.pauseKeyHint:SetTextColor(0.65, 0.65, 0.65)
    controls.minimapKeyLabel = MakeText(controls, 13, "TOPLEFT", 20, -490, "Minimap toggle key:")
    controls.minimapKeyButton = MakeButton(controls, 185, 28, "", function(button) NS:BeginMinimapKeyCapture(button) end)
    controls.minimapKeyButton:SetPoint("TOPLEFT", 165, -480)
    controls.minimapKeyClear = MakeButton(controls, 82, 28, "Clear", function() NS:SetMinimapKey(nil) end)
    controls.minimapKeyClear:SetPoint("LEFT", controls.minimapKeyButton, "RIGHT", 8, 0)
    controls.minimapKeyHint = MakeText(controls, 11, "TOPLEFT", 20, -520,
        "Press the assigned key to turn the experimental minimap on or off. Hover restores the normal minimap; leave to resume scanning. Automatic startup remains disabled. Protected restoration waits until combat ends.")
    controls.minimapKeyHint:SetWidth(420);controls.minimapKeyHint:SetJustifyH("LEFT")
    controls.rememberNodeKeyLabel = MakeText(controls, 13, "TOPLEFT", 20, -590, "Remember node key:")
    controls.rememberNodeKeyButton = MakeButton(controls, 185, 28, "", function(button) NS:BeginRememberNodeKeyCapture(button) end)
    controls.rememberNodeKeyButton:SetPoint("TOPLEFT", 165, -580)
    controls.rememberNodeKeyButton:SetText(NS:GetRememberNodeKeyDisplay())
    controls.rememberNodeKeyClear = MakeButton(controls, 82, 28, "Clear", function() NS:SetRememberNodeKey(nil) end)
    controls.rememberNodeKeyClear:SetPoint("LEFT", controls.rememberNodeKeyButton, "RIGHT", 8, 0)
    controls.rememberNodeKeyHint = MakeText(controls, 11, "TOPLEFT", 20, -620, "Point at a minimap node and press the key to add a matching saved node.")
    controls.rememberNodeKeyHint:SetWidth(420)
    controls.rememberNodeKeyHint:SetJustifyH("LEFT")
    controls.panel:SetScript("OnHide", function()
        if NS.CancelRememberNodeKeyCapture then NS:CancelRememberNodeKeyCapture(controls.rememberNodeKeyButton) end
        if NS.CancelMinimapKeyCapture then NS:CancelMinimapKeyCapture(controls.minimapKeyButton) end
        if NS.CancelPauseKeyCapture then NS:CancelPauseKeyCapture(controls.pauseKeyButton) end
        if NS.CancelToggleKeyCapture then NS:CancelToggleKeyCapture(controls.keyButton) end
        if NS.CancelDismissKeyCapture then NS:CancelDismissKeyCapture(controls.dismissKeyButton) end
    end)

    controls.minimapButton = MakeCheckbox(controls, "", function(value)
        NS.db.minimap.hide = not value
        if NS.UpdateMinimapButton then NS:UpdateMinimapButton() end
    end)
    controls.minimapButton:SetPoint("TOPLEFT", 20, -705)
    controls.minimapButton.text:SetWidth(390)
    controls.minimapButton.text:SetJustifyH("LEFT")
    controls.minimapButtonHint = MakeText(controls, 10, "TOPLEFT", 48, -738, "")
    controls.minimapButtonHint:SetWidth(390)
    controls.minimapButtonHint:SetJustifyH("LEFT")
    controls.minimapButtonHint:SetTextColor(0.65, 0.65, 0.65)

    controls.resetAll = MakeButton(controls, 220, 30, "", function()
        if NS.db.hud.enabled then NS:SetHUDEnabled(false) end
        NS:ResetSettings()
    end)
    controls.resetAll:SetPoint("TOPLEFT", 20, -790)

    -- Keep the Welcome tracking status current without chat output.
    if not self.TrackingStatusFrame then
        local trackingFrame = CreateFrame("Frame", nil, welcome)
        self.TrackingStatusFrame = trackingFrame

        pcall(trackingFrame.RegisterEvent, trackingFrame, "MINIMAP_UPDATE_TRACKING")
        pcall(trackingFrame.RegisterEvent, trackingFrame, "PLAYER_ENTERING_WORLD")

        trackingFrame:SetScript("OnEvent", function()
            NS:UpdateTrackingStatus()
        end)

        local trackingElapsed = 0
        trackingFrame:SetScript("OnUpdate", function(_, elapsed)
            if not welcome:IsShown() then return end
            trackingElapsed = trackingElapsed + elapsed
            if trackingElapsed < 1.0 then return end
            trackingElapsed = 0
            NS:UpdateTrackingStatus()
        end)
    end
end

local SETTINGS_PAGES = {
    { name = "tracking", label = "TRACKING_TAB" },
    { name = "hud", label = "HUD_TAB" },
    { name = "minimap", label = "MINIMAP_TAB" },
    { name = "controls", label = "CONTROLS_TAB" },
    { name = "advanced", label = "ADVANCED_TAB" },
}

function NS:RegisterSettingsPanel()
    if self._settingsRegistered then return end
    local modern = Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory
    if not modern and not InterfaceOptions_AddCategory then return end
    self:CreateSettingsPages()
    local panel = self.OptionsPanel
    panel.name = self.L.TITLE
    self.OptionsCategories = {}
    if modern then
        self.OptionsCategory = Settings.RegisterCanvasLayoutCategory(panel, panel.name)
        Settings.RegisterAddOnCategory(self.OptionsCategory)
    else
        InterfaceOptions_AddCategory(panel)
    end
    for _, entry in ipairs(SETTINGS_PAGES) do
        local page = panel.pages[entry.name].panel
        page.name = self.L[entry.label]
        if modern then
            local category
            if Settings.RegisterCanvasLayoutSubcategory then
                category = Settings.RegisterCanvasLayoutSubcategory(self.OptionsCategory, page, page.name)
            else
                -- Some custom clients expose categories without subcategories.
                category = Settings.RegisterCanvasLayoutCategory(page, panel.name .. " — " .. page.name)
            end
            Settings.RegisterAddOnCategory(category)
            self.OptionsCategories[entry.name] = category
        else
            page.parent = panel.name
            InterfaceOptions_AddCategory(page)
        end
    end
    self._settingsRegistered = true
    self:UpdateAll()
end

function NS:OpenSettings(pageName)
    self:RegisterSettingsPanel()
    if not self._settingsRegistered then return end
    local category = self.OptionsCategories[pageName] or self.OptionsCategory
    if category and Settings and Settings.OpenToCategory then
        Settings.OpenToCategory(category:GetID())
    elseif InterfaceOptionsFrame_OpenToCategory then
        local page = self.OptionsPanel.pages[pageName]
        InterfaceOptionsFrame_OpenToCategory(page and page.panel or self.OptionsPanel)
    end
end

function NS:RefreshTexts()
    if not self.OptionsPanel then return end
    local f = self.OptionsPanel
    for _, entry in ipairs(SETTINGS_PAGES) do
        local category = self.OptionsCategories and self.OptionsCategories[entry.name]
        if category and category.SetName then
            local label = self.L[entry.label]
            if not Settings.RegisterCanvasLayoutSubcategory then label = self.L.TITLE .. " — " .. label end
            category:SetName(label)
        end
    end
    f.toggleBtn:SetText(self.db and self.db.hud.enabled and self.L.DISABLE_HUD or self.L.ENABLE_HUD)

    local w = f.pages.welcome
    w.head:SetText(self.L.TITLE)
    local getMetadata = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
    local version = getMetadata and getMetadata(ADDON_NAME, "Version")
    w.version:SetText(version and ("Version " .. version) or "")
    w.note:SetText(self.L.WELCOME_NOTE)
    w.slash:SetText(self.L.SLASH_HELP)
    w.status:SetText(self.MinimapScanActive and "Minimap: full-time scanning" or self.db and self.db.hud.enabled and self.L.STATUS_ON or self.L.STATUS_OFF)
    self:UpdateTrackingStatus()

    local h = f.pages.hud
    h.head:SetText(self.L.HUD_TAB)
    h.sizeLabel:SetText(self.L.HUD_SIZE)
    h.mapAlphaLabel:SetText(self.L.MAP_ALPHA)
    h.zoomLabel:SetText(self.L.HUD_ZOOM)
    h.zoomHint:SetText(self.L.HUD_ZOOM_HINT)
    h.lock.text:SetText(self.L.LOCK_POSITION)
    h.resetPos:SetText(self.L.RESET_POSITION)
    local t = f.pages.tracking
    t.head:SetText(self.L.TRACKING_TAB)
    t.autoTracking.text:SetText(self.L.AUTO_TRACKING)
    t.autoTrackingHint:SetText(self.L.AUTO_TRACKING_HINT)
    t.autoTrackingInDungeons.text:SetText(self.L.AUTO_TRACKING_DUNGEONS)
    t.autoTrackingInDungeonsHint:SetText(self.L.AUTO_TRACKING_DUNGEONS_HINT)
    t.restoreTracking.text:SetText(self.L.RESTORE_TRACKING)
    t.restoreTrackingHint:SetText(self.L.RESTORE_TRACKING_HINT)
    local dwarf = self.CanUseFindTreasure and self:CanUseFindTreasure() or false
    t.includeTreasure:SetShown(dwarf)
    t.includeTreasureHint:SetShown(dwarf)
    t.rememberNodes:SetPoint("TOPLEFT", 20, dwarf and -530 or -440)
    t.rememberNodesHint:SetPoint("TOPLEFT", 48, dwarf and -563 or -473)
    local sizeRow = dwarf and -618 or -528
    t.nodeIconSizeLabel:SetPoint("TOPLEFT", 20, sizeRow)
    t.nodeIconSizeValue:SetPoint("TOPRIGHT", -28, sizeRow)
    t.nodeIconSizeSlider:SetPoint("TOPLEFT", 28, sizeRow - 28)
    t.nodeIconSizeHint:SetPoint("TOPLEFT", 28, sizeRow - 57)
    t.nodeIconSizeLabel:SetText(self.L.NODE_ICON_SIZE)
    t.nodeIconSizeHint:SetText(self.L.NODE_ICON_SIZE_HINT)
    t.includeTreasure.text:SetText(self.L.INCLUDE_TREASURE)
    t.includeTreasureHint:SetText(self.L.INCLUDE_TREASURE_HINT)
    t.rememberNodes.text:SetText(self.L.REMEMBER_NODES)
    t.rememberNodesHint:SetText(self.L.REMEMBER_NODES_HINT)
    t.trackingIntervalButton:SetText(string.format(self.L.TRACKING_INTERVAL, self.db.hud.trackingInterval))
    for _, option in ipairs(t.trackingIntervalMenu.buttons) do
        option.button:SetText(string.format(self.L.TRACKING_INTERVAL, option.seconds))
    end

    local m = f.pages.advanced
    m.head:SetText(self.L.ADVANCED_TAB)
    m.rotationLabel:SetText(self.L.ROTATION_MODE .. ":")
    m.rotationHint:SetText(self.L.ROTATION_HINT)
    m.hideAddonOverlays.text:SetText(self.L.HIDE_ADDON_OVERLAYS)
    m.hideAddonOverlaysHint:SetText(self.L.HIDE_ADDON_OVERLAYS_HINT)

    local c = f.pages.controls
    c.head:SetText(self.L.CONTROLS_TAB)
    c.mouse.text:SetText(self.L.MOUSE_MODE)
    c.mouseHint:SetText(self.L.MOUSE_MODE_HINT)
    c.tempMouseLabel:SetText(self.L.TEMP_MOUSE .. ":")
    c.tempMouseHint:SetText(self.L.TEMP_MOUSE_HINT)
    c.keyLabel:SetText(self.L.KEYBIND .. ":")
    c.keyClear:SetText(self.L.KEYBIND_CLEAR)
    c.keyHint:SetText(self.L.KEYBIND_HINT)
    c.minimapButton.text:SetText(self.L.MINIMAP_BUTTON)
    c.minimapButtonHint:SetText(self.L.MINIMAP_BUTTON_HINT)
    c.resetAll:SetText(self.L.RESET_SETTINGS)
    if self.RefreshKeybindUI then self:RefreshKeybindUI() end
    if self.RefreshMinimapKeybindUI then self:RefreshMinimapKeybindUI() end
end

function NS:UpdateAll()
    if not self.db then return end
    self:RefreshTexts()

    if self.HUDFrame then
        self.HUDFrame.outer:SetAlpha(0)
        self.HUDFrame.outer:Hide()
        self:ResizeHUDVisuals()
    end

    if self.OptionsPanel then
        local h = self.OptionsPanel.pages.hud
        h.sizeSlider:SetValue(self.db.hud.size)
        h.sizeValue:SetText(tostring(self.db.hud.size))
        h.mapAlphaSlider:SetValue(self.db.hud.mapAlpha)
        h.mapAlphaValue:SetFormattedText("%d%%", math.floor(self.db.hud.mapAlpha * 100 + 0.5))
        h.zoomSlider:SetValue(self.db.hud.zoom or 0)
        h.zoomValue:SetText(tostring(self.db.hud.zoom or 0))
        h.lock:SetChecked(self.db.hud.locked)
        h.experimentalNodes:SetChecked(self.db.hud.experimentalHUD==true)
        h.scanner:SetText("Quick scan")
        local mini=self.OptionsPanel.pages.minimap
        mini.enabled:SetChecked(self.db.minimap.fullTimeScanning==true or (self.QuickScanner and self.QuickScanner.enabled==true) or false)
        mini.enabled.text:SetText("Enable quick scanner")
        local options=self.db.quickScan
        local duration=self:GetQuickScanDuration()
        local continuous=duration==math.huge
        for _,page in ipairs({mini,h}) do
            page.duration:SetText(continuous and "Continuous" or tostring(duration).." seconds")
            page.trigger:SetText(continuous and "While enabled" or options.trigger=="interval" and "At a regular interval" or "After each automatic swap")
            page.trigger:SetEnabled(not continuous)
            page.trigger.experimentalDisabled=continuous
            if continuous then page.trigger.menu:Hide() end
            page.interval:SetText(continuous and "Unavailable while continuous" or tostring(self:GetQuickScanInterval()).." seconds")
            page.interval:SetEnabled(not continuous and options.trigger=="interval")
            page.interval.experimentalDisabled=continuous or options.trigger~="interval"
            if page.interval.experimentalDisabled then page.interval.menu:Hide() end
            for value,row in pairs(page.interval.options) do
                row:SetEnabled(not continuous and value>=duration)
            end
        end
        mini.showScanStatus:SetChecked(self.db.hud.showScanStatus==true)
        h.experimentalTerrain:SetChecked(self.db.hud.experimentalTerrain==true)
        h.showScanStatus:SetChecked(self.db.hud.showScanStatus==true)
        h.rotationButton:SetText(self.db.hud.rotationMode == "ON" and "Rotate with character"
            or self.db.hud.rotationMode == "OFF" and "North up" or "Follow minimap setting")
        h.positionRefreshing = true
        local labels = {LOW="Low", MEDIUM="Medium", HIGH="High", DIALOG="Dialog",
            CROSS="Cross", DOT="Dot", RING="Ring", ARROW="Player arrow", NONE="Hidden",
            CYAN="Cyan", WHITE="White", GOLD="Gold", GREEN="Green", PINK="Pink"}
        for key, button in pairs(h.positionButtons) do button:SetText(labels[self.db.hud[key]] or labels[key == "overlayStrata" and "HIGH" or key == "positionColor" and "CYAN" or "CROSS"]) end
        local function SelectTile(button, selected)
            button.selected = selected
            if selected then
                button.border:SetVertexColor(1, 0.82, 0.18, 1)
                button.caption:SetTextColor(1, 0.9, 0.4)
            else
                button.border:SetVertexColor(0.32, 0.28, 0.21, 1)
                button.caption:SetTextColor(0.85, 0.82, 0.75)
            end
        end
        for style, button in pairs(h.styleTiles) do
            self:RenderHUDPositionIcon(button.view, {positionStyle=style,
                positionSize=style == "ARROW" and 40 or style == "DOT" and 14 or 24,
                positionColor="WHITE", positionOpacity=1})
            if style == "RING" then
                -- A clear outline represents the ring in the small gallery;
                -- the large preview below retains the actual live artwork.
                button.view.positionTexture:SetTexture("Interface\\Common\\CommonMaskCircle")
            end
            SelectTile(button, style == self.db.hud.positionStyle)
        end
        for color, button in pairs(h.colorTiles) do SelectTile(button, color == self.db.hud.positionColor) end
        for key, row in pairs(h.positionSliders) do
            local value = (self.db.hud[key] or (key == "overlayLevel" and 110 or key == "positionSize" and 18 or 1)) * (key == "positionOpacity" and 100 or 1)
            row.slider:SetValue(value)
            row.value:SetText(tostring(math.floor(value + 0.5)) .. (key == "positionOpacity" and "%" or ""))
        end
        h.positionRefreshing = false
        self:UpdateExperimentalHUDOptions()
        self:RenderHUDPositionIcon(h.preview, self.db.hud)
        local t = self.OptionsPanel.pages.tracking
        t.autoTrackingWithHUD:SetChecked(self.db.hud.autoTrackingWithHUD and true or false)
        t.autoTracking:SetChecked(self.db.hud.autoTracking and true or false)
        t.autoTrackingInDungeons:SetChecked(self.db.hud.autoTrackingInDungeons and true or false)
        t.restoreTracking:SetChecked(self.db.hud.restoreTracking and true or false)
        t.includeTreasure:SetChecked(self.db.hud.includeTreasure and true or false)
        t.rememberNodes:SetChecked(self.db.hud.rememberNodes and true or false)
        t.nodeIconSizeSlider:SetValue(self.db.hud.nodeIconSize or 14)
        t.nodeIconSizeValue:SetText(tostring(self.db.hud.nodeIconSize or 14))

        local m = self.OptionsPanel.pages.advanced
        local rotationMode = self.db.hud.rotationMode or "CLIENT"
        if rotationMode == "ON" then
            m.rotationButton:SetText(self.L.ROTATION_ON)
        elseif rotationMode == "OFF" then
            m.rotationButton:SetText(self.L.ROTATION_OFF)
        else
            m.rotationButton:SetText(self.L.ROTATION_CLIENT)
        end
        m.hideAddonOverlays:SetChecked(self.db.hud.hideAddonOverlays and true or false)

        local c = self.OptionsPanel.pages.controls
        c.mouse:SetChecked(self.db.hud.mouseMode)
        c.minimapButton:SetChecked(not self.db.minimap.hide)

        local modifier = self.db.hud.mouseModifier or "NONE"
        if modifier == "ALT" then
            c.tempMouseButton:SetText(self.L.TEMP_MOUSE_ALT)
        elseif modifier == "CTRL" then
            c.tempMouseButton:SetText(self.L.TEMP_MOUSE_CTRL)
        elseif modifier == "SHIFT" then
            c.tempMouseButton:SetText(self.L.TEMP_MOUSE_SHIFT)
        else
            c.tempMouseButton:SetText(self.L.TEMP_MOUSE_NONE)
        end

        if self.RefreshKeybindUI then self:RefreshKeybindUI() end
    end

    if self.UpdateMinimapButton then self:UpdateMinimapButton() end
    if self.UpdateAutoTracking then self:UpdateAutoTracking() end
    if self.UpdateRememberedNodes then self:UpdateRememberedNodes() end
end
