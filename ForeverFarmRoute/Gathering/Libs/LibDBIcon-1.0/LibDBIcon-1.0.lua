-- LibDBIcon-1.0 compatible embedded minimap display.
-- API and behavior follow the established LibDBIcon convention.
local MAJOR, MINOR = "ForeverDualGathering-LibDBIcon-1.0", 41
if not LibStub then error(MAJOR .. " requires LibStub") end
local LDB = LibStub("LibDataBroker-1.1", true)
if not LDB then error(MAJOR .. " requires LibDataBroker-1.1") end
local lib = LibStub:NewLibrary(MAJOR, MINOR)
if not lib then return end

lib.objects = lib.objects or {}
lib.callbacks = lib.callbacks or LibStub("ForeverDualGathering-CallbackHandler-1.0"):New(lib)

local shapes = {
    ["ROUND"] = {true, true, true, true},
    ["SQUARE"] = {false, false, false, false},
    ["CORNER-TOPLEFT"] = {false, false, false, true},
    ["CORNER-TOPRIGHT"] = {false, false, true, false},
    ["CORNER-BOTTOMLEFT"] = {false, true, false, false},
    ["CORNER-BOTTOMRIGHT"] = {true, false, false, false},
    ["SIDE-LEFT"] = {false, true, false, true},
    ["SIDE-RIGHT"] = {true, false, true, false},
    ["SIDE-TOP"] = {false, false, true, true},
    ["SIDE-BOTTOM"] = {true, true, false, false},
    ["TRICORNER-TOPLEFT"] = {false, true, true, true},
    ["TRICORNER-TOPRIGHT"] = {true, false, true, true},
    ["TRICORNER-BOTTOMLEFT"] = {true, true, false, true},
    ["TRICORNER-BOTTOMRIGHT"] = {true, true, true, false},
}

local function updatePosition(button)
    local db = button.db
    local angle = math.rad((db and db.minimapPos) or 225)
    local x, y = math.cos(angle), math.sin(angle)
    local q = 1
    if x < 0 then q = q + 1 end
    if y > 0 then q = q + 2 end
    local shapeName = (GetMinimapShape and GetMinimapShape()) or "ROUND"
    local shape = shapes[shapeName] or shapes.ROUND
    local width,height=Minimap:GetWidth(),Minimap:GetHeight()
    local function dimension(value,fallback)
        if issecretvalue and issecretvalue(value) or type(value)~='number' or value~=value or value<=0 or value==math.huge then return fallback end
        return value
    end
    width=dimension(width,140);height=dimension(height,width)
    -- Match the small outside-rim offset used by current LibDBIcon addons.
    local rx,ry=width/2+5,height/2+5
    local radius
    if shape[q] then
        -- Follow the actual round/elliptical rim, keeping the saved polar
        -- angle stable when skins resize the native minimap.
        radius=1/math.sqrt((x/rx)^2+(y/ry)^2)
    else
        -- Intersect the saved-angle ray with the outside rectangle.
        radius=math.min(math.abs(x)>1e-9 and rx/math.abs(x) or math.huge,
            math.abs(y)>1e-9 and ry/math.abs(y) or math.huge)
    end
    x,y=x*radius,y*radius
    button:ClearAllPoints()
    button:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

local defaultCoords = {0, 1, 0, 1}
local function updateIconCoords(button)
    local coords = button.dataObject.iconCoords or defaultCoords
    local inset = button.isMouseDown and 0 or 0.05
    local dx = (coords[2] - coords[1]) * inset
    local dy = (coords[4] - coords[3]) * inset
    button.icon:SetTexCoord(coords[1] + dx, coords[2] - dx, coords[3] + dy, coords[4] - dy)
end

local function onEnter(button)
    if button.isMoving then return end
    local obj = button.dataObject
    if obj.OnTooltipShow then
        GameTooltip:SetOwner(button, "ANCHOR_LEFT")
        obj.OnTooltipShow(GameTooltip)
        GameTooltip:Show()
    elseif obj.OnEnter then
        obj.OnEnter(button)
    end
end

local function onLeave(button)
    GameTooltip:Hide()
    if button.dataObject.OnLeave then button.dataObject.OnLeave(button) end
end

local function onClick(button, mouseButton)
    if button.dataObject.OnClick then button.dataObject.OnClick(button, mouseButton) end
end

local function onDragUpdate(button)
    local mx, my = Minimap:GetCenter()
    if not mx or not my then return end
    local px, py = GetCursorPosition()
    local scale = Minimap:GetEffectiveScale()
    px, py = px / scale, py / scale
    button.db.minimapPos = math.deg(math.atan2(py - my, px - mx)) % 360
    updatePosition(button)
end

local function onDragStart(button)
    button.isMoving = true
    button.isMouseDown = true
    updateIconCoords(button)
    button:LockHighlight()
    GameTooltip:Hide()
    button:SetScript("OnUpdate", onDragUpdate)
end

local function onDragStop(button)
    button:SetScript("OnUpdate", nil)
    button.isMoving = nil
    button.isMouseDown = nil
    updateIconCoords(button)
    button:UnlockHighlight()
end

local function applyLock(button)
    if button.db and button.db.lock then
        button:SetScript("OnDragStart", nil)
        button:SetScript("OnDragStop", nil)
    else
        button:SetScript("OnDragStart", onDragStart)
        button:SetScript("OnDragStop", onDragStop)
    end
end

local function createButton(name, object, db)
    local button = CreateFrame("Button", "LibDBIcon10_" .. name, Minimap)
    button.dataObject = object
    button.db = db or { minimapPos = 225 }
    button:SetSize(31, 31)
    button:SetFrameStrata("MEDIUM")
    button:SetFrameLevel(8)
    button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    button:RegisterForDrag("LeftButton")
    button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    local background = button:CreateTexture(nil, "BACKGROUND")
    background:SetSize(20, 20)
    background:SetPoint("TOPLEFT", 7, -5)
    background:SetTexture("Interface\\Minimap\\UI-Minimap-Background")

    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetSize(17, 17)
    icon:SetPoint("TOPLEFT", 7, -6)
    icon:SetTexture(object.icon)
    button.icon = icon

    local overlay = button:CreateTexture(nil, "OVERLAY")
    overlay:SetSize(53, 53)
    overlay:SetPoint("TOPLEFT")
    overlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

    button:SetScript("OnEnter", onEnter)
    button:SetScript("OnLeave", onLeave)
    button:SetScript("OnClick", onClick)
    button:SetScript("OnMouseDown", function(self) self.isMouseDown = true; updateIconCoords(self) end)
    button:SetScript("OnMouseUp", function(self) self.isMouseDown = nil; updateIconCoords(self) end)
    applyLock(button)
    updateIconCoords(button)
    updatePosition(button)
    if button.db.hide then button:Hide() else button:Show() end

    lib.objects[name] = button
    lib.callbacks:Fire("LibDBIcon_IconCreated", button, name)
    return button
end

function lib:Register(name, object, db)
    if self.objects[name] then return end
    if not object or not object.icon then error("Can't register LDB object without icon") end
    createButton(name, object, db)
end

function lib:IsRegistered(name)
    return self.objects[name] ~= nil
end

function lib:GetMinimapButton(name)
    return self.objects[name]
end

function lib:Refresh(name, db)
    local button = self.objects[name]
    if not button then return end
    if db then button.db = db end
    button.icon:SetTexture(button.dataObject.icon)
    updateIconCoords(button)
    applyLock(button)
    updatePosition(button)
    if button.db and button.db.hide then button:Hide() else button:Show() end
end

function lib:Hide(name)
    local button = self.objects[name]
    if button then button:Hide() end
end

function lib:Show(name)
    local button = self.objects[name]
    if button then updatePosition(button); button:Show() end
end

function lib:Lock(name)
    local button = self.objects[name]
    if not button then return end
    button.db.lock = true
    applyLock(button)
end

function lib:Unlock(name)
    local button = self.objects[name]
    if not button then return end
    button.db.lock = nil
    applyLock(button)
end

function lib:IconCallback(_, name, key, value)
    local button = self.objects[name]
    if not button then return end
    if key == "icon" then
        button.icon:SetTexture(value)
    elseif key == "iconCoords" then
        updateIconCoords(button)
    end
end

if not lib._ldbCallbacks then
    LDB.RegisterCallback(lib, "LibDataBroker_AttributeChanged__icon", "IconCallback")
    LDB.RegisterCallback(lib, "LibDataBroker_AttributeChanged__iconCoords", "IconCallback")
    lib._ldbCallbacks = true
end

-- Skin size changes can happen after PLAYER_LOGIN. Update only buttons still
-- owned by this library, leaving button bags' anchors alone. Protected native
-- resizing during combat waits for PLAYER_REGEN_ENABLED.
local function refreshPositions()
    if InCombatLockdown and InCombatLockdown()then return end
    for name,button in pairs(lib.objects)do
        local managed=false
        for _,entry in pairs(_G.MBB_Buttons or {})do
            if entry=="LibDBIcon10_"..name then managed=true;break end
        end
        if not managed and button.GetParent and button:GetParent()==Minimap then updatePosition(button) end
    end
end
if not lib._loginFrame then lib._loginFrame=CreateFrame("Frame") end
lib._loginFrame:RegisterEvent("PLAYER_LOGIN")
lib._loginFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
lib._loginFrame:SetScript("OnEvent",refreshPositions)
if not lib._sizeHook and Minimap.HookScript then
    Minimap:HookScript("OnSizeChanged",refreshPositions)
    lib._sizeHook=true
end
