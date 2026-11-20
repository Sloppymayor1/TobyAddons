local ADDON_NAME, FRNS_ = ...; local NS = FRNS_.Gathering

local function IsHUDActive()
    return NS.db and (NS.db.hud.enabled or NS.MinimapScanActive) and NS._minimapState ~= nil
end

local function GetMinimapConfig(module)
    return module.db and module.db.profile and module.db.profile.minimap
end

local function EnforceHUDMinimap(setter)
    if NS.MinimapScanActive then
        local scan=NS.CursorSweepTrial
        if scan and scan.TraceCaptureLayoutWriter then scan:TraceCaptureLayoutWriter(setter) end
        if scan and scan.RepairCaptureLayout then scan:RepairCaptureLayout() end
        return
    end
    if IsHUDActive() and not NS._keepingMinimapInHUD then
        if InCombatLockdown and InCombatLockdown() and Minimap:IsProtected() then
            -- Opacity is safe here; protected geometry uses the secure handlers.
            local alpha = Minimap:GetAlpha()
            if not (issecretvalue and issecretvalue(alpha)) and alpha ~= NS.db.hud.mapAlpha then
                NS._keepingMinimapInHUD = true
                pcall(Minimap.SetAlpha, Minimap, NS.db.hud.mapAlpha)
                NS._keepingMinimapInHUD = nil
            end
        else
            NS:KeepMinimapInHUD()
        end
    end
end

local ELLESMERE_CONTROL_GLOBALS = {
    "_EBS_ClockBg", "_EBS_LocationBg", "_EBS_FpsBg", "_EBS_CoordFrame",
    "EllesmereUIMicroMenu",
}

local ELLESMERE_INDICATOR_KEYS = {
    _tracking = true, _gameTime = true, _mail = true, _crafting = true, _friends = true,
}

local function IsEllesmereControl(object)
    local key = object._indicatorKey
    if type(key) == "string" and not (issecretvalue and issecretvalue(key))
        and ELLESMERE_INDICATOR_KEYS[key]
    then
        return true
    end

    -- Ellesmere's anonymous addon-button toggle has its own background and
    -- normal texture. Identify its filter atlas instead of hiding unnamed frames.
    local normal = object._norm
    if object._bg and normal and type(normal.GetAtlas) == "function" then
        local ok, atlas = pcall(normal.GetAtlas, normal)
        return ok and not (issecretvalue and issecretvalue(atlas)) and atlas == "Map-Filter-Button"
    end
    return false
end

local function IsEllesmereMouseOverlay(object)
    -- Ellesmere's anonymous full-map interceptor handles middle click and
    -- wheel zoom, but captures side buttons even when Minimap is not clickable.
    if not object.GetParent or not object.GetScript or not object.CanPropagateMouseMotion
        or not object.ShouldButtonPassThrough then return false end
    local ok, matches = pcall(function()
        return object:GetParent() == Minimap
            and type(object:GetScript("OnMouseUp")) == "function"
            and type(object:GetScript("OnMouseWheel")) == "function"
            and object:CanPropagateMouseMotion()
            and object:ShouldButtonPassThrough("LeftButton")
            and object:ShouldButtonPassThrough("RightButton")
            and not object:ShouldButtonPassThrough("MiddleButton")
    end)
    return ok and not (issecretvalue and issecretvalue(matches)) and matches
end

local function HideEllesmereControl(object)
    NS._hidingEllesmereControl = true
    NS:HideMinimapControl(object)
    NS._hidingEllesmereControl = nil
end

local function TrackEllesmereControlVisibility(object, shown)
    if not IsHUDActive() or NS._hidingEllesmereControl then return end
    local state = NS._ellesmereControls and NS._ellesmereControls[object]
    if not state then return end
    state.shown = shown
    if shown then HideEllesmereControl(object) end
end

function NS:HideEllesmereControls()
    if not IsHUDActive() then return end
    self._ellesmereControls = self._ellesmereControls or {}
    self._ellesmereControlGuards = self._ellesmereControlGuards or setmetatable({}, { __mode = "k" })

    local function Suppress(object)
        if self.IsStationaryMinimapControl and self:IsStationaryMinimapControl(object) then return end
        local ok,shown=pcall(function()
            if not object or object==Minimap or object==NS.MinimapButton
                or issecretvalue and issecretvalue(object)
                or object.IsForbidden and object:IsForbidden()
                or type(object.Hide)~='function' or type(object.IsShown)~='function' then return end
            return object:IsShown()
        end)
        if not ok or issecretvalue and issecretvalue(shown) or type(shown)~='boolean' then return end
        -- A late named coordinate region may already have been quieted by
        -- cursor capture. Transfer its original opacity to the normal HUD
        -- owner so two restorers cannot overwrite each other's snapshot.
        local trial=self.CursorSweepTrial
        local captured=trial and trial.controls and trial.controls[object]
        if captured then
            if captured.alpha~=nil then
                self._hiddenMinimapControlAlphas=self._hiddenMinimapControlAlphas or {}
                if self._hiddenMinimapControlAlphas[object]==nil then self._hiddenMinimapControlAlphas[object]=captured.alpha end
            end
            trial.controls[object]=nil
        end
        if not self._ellesmereControls[object] then
            self._ellesmereControls[object] = { shown = shown }
        end
        if not self._ellesmereControlGuards[object] and hooksecurefunc then
            hooksecurefunc(object, "Show", function(control)
                TrackEllesmereControlVisibility(control, true)
            end)
            hooksecurefunc(object, "Hide", function(control)
                TrackEllesmereControlVisibility(control, false)
            end)
            if type(object.SetShown) == "function" then
                hooksecurefunc(object, "SetShown", function(control, shown)
                    if not (issecretvalue and issecretvalue(shown)) then
                        TrackEllesmereControlVisibility(control, shown and true or false)
                    end
                end)
            end
            if type(object.HookScript) == "function" then
                object:HookScript("OnShow", function(control)
                    TrackEllesmereControlVisibility(control, true)
                end)
            end
            self._ellesmereControlGuards[object] = true
        end
        HideEllesmereControl(object)
    end

    -- Current native minimaps keep coordinates on the map's parent/cluster,
    -- rather than among Minimap's children. Those frames travel with capture
    -- but are not found by generic child/region scans or skin global names.
    local function CoordinatesOn(host)
        if not host then return end
        local ok,coordinates=pcall(function()return host.PlayerCoords end)
        if not ok or not coordinates or issecretvalue and issecretvalue(coordinates) then return end
        Suppress(coordinates)
        local fine,text=pcall(function()return coordinates.CoordText end)
        if fine and text and not (issecretvalue and issecretvalue(text)) then Suppress(text) end
    end
    CoordinatesOn(Minimap)
    CoordinatesOn(_G.MinimapCluster)
    CoordinatesOn(self._minimapState and self._minimapState.parent)
    local ok,parent=pcall(Minimap.GetParent,Minimap)
    if ok then CoordinatesOn(parent) end
    for _, name in ipairs(ELLESMERE_CONTROL_GLOBALS) do Suppress(_G[name]) end
    Suppress(Minimap.ZoomIn)
    Suppress(Minimap.ZoomOut)
    if Minimap.GetChildren then
        for _, child in ipairs({ Minimap:GetChildren() }) do
            if IsEllesmereControl(child) then
                Suppress(child)
            elseif IsEllesmereMouseOverlay(child) then
                -- Prepare this outside combat too: a protected Show may revive
                -- the invisible interceptor during lockdown.
                Suppress(child)
            end
        end
    end
end

function NS:RestoreEllesmereControls()
    local controls = self._ellesmereControls
    self._ellesmereControls = nil
    if not controls then return end
    for object, state in pairs(controls) do
        if state.shown then object:Show() else object:Hide() end
    end
end

local BLOB_RING_SETTERS = { "SetQuestBlobRingScalar", "SetArchBlobRingScalar" }

function NS:HideHUDMinimapRings()
    if not IsHUDActive() then return end
    local state = self._minimapState
    state.blobRingScalars = state.blobRingScalars or {}
    self._minimapBlobRingScalars = self._minimapBlobRingScalars or {}
    for _, setter in ipairs(BLOB_RING_SETTERS) do
        if type(Minimap[setter]) == "function" then
            if state.blobRingScalars[setter] == nil then
                local original = self._minimapBlobRingScalars[setter]
                if original == nil then
                    local config = self._ellesmereModule and GetMinimapConfig(self._ellesmereModule)
                    original = (not config or config.shape == "circle" or config.shape == "textured_circle") and 1 or 0
                end
                state.blobRingScalars[setter] = original
            end
            if self._minimapBlobRingScalars[setter] ~= 0 then
                self._hidingHUDRings = true
                local ok = pcall(Minimap[setter], Minimap, 0)
                self._hidingHUDRings = nil
                if ok then self._minimapBlobRingScalars[setter] = 0 end
            end
        end
    end
end

function NS:InstallHUDMinimapGuards()
    if self._hudMinimapGuardsInstalled or not Minimap or not hooksecurefunc then return end

    -- A delayed watchdog lets a normal map layout render between corrections.
    -- Post-hooks repair the layout in the setter's call, including local/deferred
    -- Ellesmere rebuilds that bypass its global options bridge.
    local setters = {
        "ClearAllPoints", "SetPoint", "SetAllPoints", "SetParent",
        "SetScale", "SetSize", "SetWidth", "SetHeight",
        "SetAlpha", "SetZoom", "Hide",
    }
    for _, name in ipairs(setters) do
        if type(Minimap[name]) == "function" then
            hooksecurefunc(Minimap, name, function()EnforceHUDMinimap(name)end)
        end
    end
    if Minimap.HookScript then Minimap:HookScript("OnShow", EnforceHUDMinimap) end
    -- Some clients expose texture setters without getters. Observe writes so
    -- an unchanged HUD never reloads the same textures on every repair.
    if type(Minimap.SetMaskTexture) == "function" then
        hooksecurefunc(Minimap, "SetMaskTexture", function(_, texture)
            NS._minimapMaskTexture = not (issecretvalue and issecretvalue(texture)) and texture or nil
            EnforceHUDMinimap()
        end)
    end
    if type(Minimap.SetIconScale) == "function" then
        hooksecurefunc(Minimap, "SetIconScale", function(_, scale)
            if not (issecretvalue and issecretvalue(scale)) and type(scale) == "number" and scale >= 0 then
                NS._minimapIconScale = scale
            end
        end)
    end
    if type(Minimap.EnableMouseWheel) == "function" then
        hooksecurefunc(Minimap, "EnableMouseWheel", function(_, enabled)
            if issecretvalue and issecretvalue(enabled) then
                NS._minimapMouseWheel = nil
            else
                NS._minimapMouseWheel = enabled
            end
            EnforceHUDMinimap()
        end)
    end
    for _, setter in ipairs(BLOB_RING_SETTERS) do
        if type(Minimap[setter]) == "function" then
            hooksecurefunc(Minimap, setter, function(_, scalar)
                if issecretvalue and issecretvalue(scalar) then return end
                NS._minimapBlobRingScalars = NS._minimapBlobRingScalars or {}
                NS._minimapBlobRingScalars[setter] = scalar
                if IsHUDActive() and not NS._hidingHUDRings then
                    local state = NS._minimapState
                    state.blobRingScalars = state.blobRingScalars or {}
                    state.blobRingScalars[setter] = scalar
                    NS:HideHUDMinimapRings()
                end
            end)
        end
    end
    self._hudMinimapGuardsInstalled = true
end

function NS:InstallEllesmereCompatibility()
    if self._ellesmereModule then return end

    local eui = _G.EllesmereUI
    if not eui or not eui.Lite or type(eui.Lite.GetAddon) ~= "function" then return end
    local module = eui.Lite.GetAddon("EllesmereUIMinimap", true)
    if not module or type(module._MapAlpha) ~= "function" then return end

    -- Adapt the live API from our addon; never edit Ellesmere's files or profile.
    -- Inactive wrappers preserve the original arguments and return values.
    local mapAlpha = module._MapAlpha
    module._MapAlpha = function(...)
        if IsHUDActive() then return NS.db.hud.mapAlpha end
        return mapAlpha(...)
    end

    -- Ellesmere's layout helpers replay the normal saved anchor after size /
    -- zoom updates, including through SetPointBase. Do not fight that replay
    -- with repair hooks: defer only this native map's anchors while either
    -- minimap or HUD capture owns it. Direct scanner setters and all other frames still work.
    for _, name in ipairs({"ClearFramePoints", "SetFramePoint"}) do
        local original = eui[name]
        if type(original) == "function" then
            eui[name] = function(frame, ...)
                local scan = NS.CursorSweepTrial
                if frame == Minimap and scan and scan.saved then return end
                return original(frame, ...)
            end
        end
    end

    local function OverrideVisibilityQuery(name, hudValue)
        local original = eui[name]
        if type(original) ~= "function" then return end
        eui[name] = function(config, ...)
            if IsHUDActive() and config == GetMinimapConfig(module) then
                return hudValue
            end
            return original(config, ...)
        end
    end

    -- Ellesmere's own updater removes its combat driver when the dependency
    -- query returns false. Its mouseover poll also respects this scoped override.
    OverrideVisibilityQuery("EvalVisibility", true)
    OverrideVisibilityQuery("VisDependsOnCombat", false)
    OverrideVisibilityQuery("VisWantsMouseover", false)

    self._ellesmereModule = module
    self:InstallHUDMinimapGuards()
    -- The full minimap rebuild calls this API after creating/showing its labels
    -- and controls. Suppress newly created controls before that rebuild returns.
    if hooksecurefunc and type(module._ApplyAddonCompartment) == "function" then
        hooksecurefunc(module, "_ApplyAddonCompartment", function()
            if IsHUDActive() then
                NS:HideKnownMinimapAttachments()
                NS:HideEllesmereControls()
                if NS.db.hud.hideAddonOverlays then NS:HideAddonMinimapOverlays() end
            end
        end)
    end
end

function NS:BeginEllesmereHUD()
    self:InstallEllesmereCompatibility()
    local module = self._ellesmereModule
    local state = self._minimapState
    -- Named display controls still exist on builds whose full module API
    -- cannot be detected. They must not travel with the hidden capture map.
    self:HideEllesmereControls()
    if not module or not state then return end

    local config = GetMinimapConfig(module)
    local parent = state.parent
    -- Rectangular Ellesmere maps use an addon-owned parent to clip native blips.
    -- Keep that parent so its guard does not fight us, and expand its clip area.
    if config and config.shape == "rectangular"
        and type(module._MinimapBlizz) == "function" and not module._MinimapBlizz()
        and parent and parent ~= UIParent and parent.SetSize
    then
        self._ellesmereClip = {
            frame = parent,
            width = parent:GetWidth(),
            height = parent:GetHeight(),
        }
        self._ellesmereClipGuards = self._ellesmereClipGuards or setmetatable({}, { __mode = "k" })
        if not self._ellesmereClipGuards[parent] and hooksecurefunc then
            hooksecurefunc(parent, "SetSize", EnforceHUDMinimap)
            self._ellesmereClipGuards[parent] = true
        end
    end

    self:HideEllesmereControls()
    if EllesmereUI.RequestVisibilityUpdate then
        EllesmereUI.RequestVisibilityUpdate()
    end
end

function NS:GetHUDMinimapParent()
    if self._hudCombatParent and ((InCombatLockdown and InCombatLockdown())
        or Minimap:GetParent() == self.HUDCombatAnchor) then
        return self._hudCombatParent
    end
    -- Ellesmere has its own synchronous parent guard. Let it own the parent;
    -- our guards own the map's HUD anchors and dimensions within that parent.
    -- Reasserting a different parent here would recurse through both guards.
    if self._ellesmereModule then return Minimap:GetParent() end
    return UIParent
end

function NS:ResizeEllesmereHUDClip(size)
    local clip = self._ellesmereClip
    if not clip then return end
    local frame = clip.frame
    if Minimap:GetParent() ~= frame then return end
    local wanted = size * self.HUDFrame:GetEffectiveScale() / frame:GetEffectiveScale()
    if frame:GetWidth() ~= wanted or frame:GetHeight() ~= wanted then
        frame:SetSize(wanted, wanted)
    end
end

function NS:EndEllesmereHUD()
    self:RestoreEllesmereControls()
    local clip = self._ellesmereClip
    self._ellesmereClip = nil
    if clip then clip.frame:SetSize(clip.width, clip.height) end

    if self._ellesmereModule or (_G._EBS_CoordFrame and type(_G._EMM_ApplyMinimap)=='function') then
        -- Reapply the current profile after our snapshot is restored, including
        -- opacity, the rectangular clip, and secure visibility-driver ownership.
        if type(_G._EMM_ApplyMinimap) == "function" then
            pcall(_G._EMM_ApplyMinimap)
        end
        if EllesmereUI and EllesmereUI.RequestVisibilityUpdate then
            EllesmereUI.RequestVisibilityUpdate()
        end
    end
end
