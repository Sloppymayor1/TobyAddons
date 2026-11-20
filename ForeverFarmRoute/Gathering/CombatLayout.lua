local ADDON_NAME, FRNS_ = ...; local NS = FRNS_.Gathering

-- Prepare protected geometry outside combat, then let the secure state handler
-- reassert it on combat transitions. Ordinary addon Lua cannot move a protected
-- Minimap after lockdown begins.
local APPLY_LAYOUT = [[
    if not self:GetAttribute("hud-enabled") then return end
    local map = self:GetFrameRef("minimap")
    local parent = self:GetFrameRef("map-parent")
    -- IsProtected is safe even for an unprotected handle. Other handle methods
    -- fail in combat on an unprotected Minimap; ordinary Lua handles that case.
    if not map or not parent or not map:IsProtected() then return end
    if map:GetParent() ~= parent then
        local _, explicitParent = parent:IsProtected()
        -- SetParent's target must be explicitly protected, including outside
        -- combat. UIParent and Ellesmere's clip may only be indirectly protected.
        map:SetParent(explicitParent and parent or self)
    end
    local width = self:GetAttribute("map-width")
    local height = self:GetAttribute("map-height")
    if map:GetWidth() ~= width then map:SetWidth(width) end
    if map:GetHeight() ~= height then map:SetHeight(height) end
    local scale = self:GetAttribute("map-scale")
    if map:GetScale() ~= scale then map:SetScale(scale) end
    local point, relative, relativePoint, dx, dy = map:GetPoint(1)
    if map:GetNumPoints() ~= 1 or point ~= "CENTER" or relative ~= self
        or relativePoint ~= "CENTER" or dx ~= 0 or dy ~= 0 then
        map:ClearAllPoints()
        map:SetPoint("CENTER", self, "CENTER", 0, 0)
    end
    if not map:IsShown() then map:Show() end
]]

local PLACE_ANCHOR = [[
    self:ClearAllPoints()
    self:SetPoint("CENTER", "$screen", "CENTER",
        self:GetAttribute("hud-x") or 0, self:GetAttribute("hud-y") or 0)
    self:SetWidth(self:GetAttribute("host-size"))
    self:SetHeight(self:GetAttribute("host-size"))
]]

function NS:InstallHUDCombatAnchor()
    if self.HUDCombatAnchor or not RegisterStateDriver or not SecureHandlerExecute
        or (InCombatLockdown and InCombatLockdown()) then return end
    local anchor = CreateFrame("Frame", "ForeverFarmRouteGathering_CombatAnchor", UIParent, "SecureHandlerStateTemplate")
    if not anchor.SetFrameRef then return end
    anchor:SetSize(1, 1)
    anchor:SetFrameRef("minimap", Minimap)
    anchor:SetAttribute("_onstate-hudcombat", APPLY_LAYOUT)
    self.HUDCombatAnchor = anchor
    RegisterStateDriver(anchor, "hudcombat", "[combat] combat; peaceful")
    if SecureHandlerWrapScript then
        -- Blizzard can re-show the map as part of its combat layout. Repair
        -- after OnShow in the same secure context, with no timer or polling.
        -- Wrapped scripts receive the Minimap as self and our anchor as control.
        -- Returning a message from the pre-handler enables the post-handler.
        SecureHandlerWrapScript(Minimap, "OnShow", anchor, "return true, true", "local self = control\n" .. APPLY_LAYOUT)
    end
end

function NS:ApplyHUDCombatLayout(width, height, scale)
    local anchor = self.HUDCombatAnchor
    if not anchor then return false end
    if InCombatLockdown and InCombatLockdown() then return Minimap:IsProtected() end
    -- Refresh references only outside combat, after Ellesmere's parent guard
    -- has run. During combat the secure handler uses this prepared reference.
    local parent = self:GetHUDMinimapParent()
    local dirty = false
    local function SetValue(name, value)
        if anchor:GetAttribute(name) ~= value then
            anchor:SetAttribute(name, value)
            dirty = true
        end
    end
    if self._hudCombatParent ~= parent then
        anchor:SetFrameRef("map-parent", parent)
        self._hudCombatParent = parent
        dirty = true
    end
    SetValue("hud-x", self.db.hud.x or 0)
    SetValue("hud-y", self.db.hud.y or 0)
    SetValue("map-width", width)
    SetValue("map-height", height)
    SetValue("map-scale", scale)
    SetValue("host-size", width * scale)
    SetValue("hud-enabled", true)
    if dirty then SecureHandlerExecute(anchor, PLACE_ANCHOR) end
    if not Minimap:IsProtected() then return false end
    -- Restore an unprotected clipping parent through ordinary Lua outside
    -- combat; a restricted SetParent cannot use that parent as its target.
    if Minimap:GetParent() ~= parent then
        Minimap:SetParent(parent)
        dirty = true
    end
    local point, relative, relativePoint, x, y = Minimap:GetPoint(1)
    local secret = issecretvalue and (issecretvalue(point) or issecretvalue(relative)
        or issecretvalue(relativePoint) or issecretvalue(x) or issecretvalue(y))
    if dirty or secret or Minimap:GetParent() ~= parent or Minimap:GetNumPoints() ~= 1
        or point ~= "CENTER" or relative ~= anchor or relativePoint ~= "CENTER" or x ~= 0 or y ~= 0
        or Minimap:GetWidth() ~= width or Minimap:GetHeight() ~= height
        or Minimap:GetScale() ~= scale or not Minimap:IsShown() then
        SecureHandlerExecute(anchor, APPLY_LAYOUT)
    end
    return true
end

function NS:DisableHUDCombatLayout()
    if self.HUDCombatAnchor then self.HUDCombatAnchor:SetAttribute("hud-enabled", false) end
end
