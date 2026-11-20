local _, FRNS_ = ...; local NS = FRNS_.Gathering
-- Presentation adapters own layout; CursorSweep owns all sampling and scheduling.
local function baseHUD(enabled)
    local previous=NS._experimentalHUDInternal
    NS._experimentalHUDInternal=true
    local ok,err=pcall(NS.SetHUDEnabled,NS,enabled)
    NS._experimentalHUDInternal=previous
    if not ok then error(err) end
end
local hud={}
function hud:Prepare(scan)
    -- Save the displayed HUD before restoring the native map for capture.
    -- Its zoom/mask are independent of the scanner's zero-zoom geometry.
    if scan then
        scan.hudDisplay=nil
        if NS.db.hud.enabled and NS.GetGatheringNodeContext then
            local context=NS:GetGatheringNodeContext()
            if context and type(context.radius)=='number' and context.radius>0 then
                local mask=NS._minimapMaskTexture
                if Minimap.GetMaskTexture then
                    local ok,value=pcall(Minimap.GetMaskTexture,Minimap)
                    if ok and not (issecretvalue and issecretvalue(value)) then mask=value or mask end
                end
                scan.hudDisplay={radius=context.radius,mask=mask,map=context.map}
            end
        end
    end
    if NS.db.hud.enabled then baseHUD(false) end
    if NS.ReplacementMinimap then NS.ReplacementMinimap:CaptureOriginalGeometry() end
end
function hud:Begin(scan)
    local options=NS.db.hud
    options.zoom=scan.captureZoom
    options.keepMinimap=false;options.locked=true;options.mouseMode=true
    options.mapAlpha=0
    baseHUD(true)
    options.mapAlpha=scan.saved.mapAlpha
end
function hud:Update()
    if NS.ApplyHUDRotation then NS:ApplyHUDRotation() end
end
function hud:Finish(saved)
    NS.db.hud.enabled=true
    baseHUD(false)
    if saved.enabled then baseHUD(true) end
end
local minimap={}
function minimap:Prepare(scan)
    assert(not NS.db.hud.enabled,'stop HUD before starting minimap capture')
    if NS.HUDFrame then NS.HUDFrame:Hide() end
    -- Same native-blip suppression as 2.6, applied before capture reparenting
    -- rather than waiting for the first scan Tick after a tracker swap.
    self.nativeIconScale=scan and scan.iconScale or NS._minimapIconScale or 1
    if Minimap and Minimap.SetIconScale then Minimap:SetIconScale(0) end
    NS:CaptureMinimapState()
end
function minimap:Begin(scan)
    self.active=true
    -- This host is independent of HUDFrame and stays visible for native hover.
    self.host=self.host or CreateFrame('Frame',nil,UIParent)
    self.host:SetAllPoints(UIParent)
    self.host:EnableMouse(false)
    self.host:Show()
    if NS.InstallEllesmereCompatibility then NS:InstallEllesmereCompatibility() end
    Minimap:SetParent(self.host)
    Minimap:SetAlpha(0)
    if NS.PassHUDMouseButtons then NS:PassHUDMouseButtons(Minimap,true) end
    if NS.HideMinimapAttachments then NS:HideMinimapAttachments() end
    scan:RefreshCaptureInput()
end
function minimap:Update()
    if not NS.db.hud.enabled and NS.HUDFrame and NS.HUDFrame:IsShown() then NS.HUDFrame:Hide() end
    -- Native capture is north-up; display orientation belongs to its renderer.
    local get=GetCVar or C_CVar and C_CVar.GetCVar
    local set=SetCVar or C_CVar and C_CVar.SetCVar
    if get and set and get('rotateMinimap')~='0' then set('rotateMinimap','0') end
end
function minimap:Finish()
    self.active=nil
    NS:RestoreMinimap()
    if NS.RestoreMinimapAttachments then NS:RestoreMinimapAttachments() end
    if NS.RestoreEllesmereControls then NS:RestoreEllesmereControls() end
    local quick=NS.QuickScanner
    local farm=quick and quick.farmPass and quick.farmMap
    if not farm and NS.RefreshNormalMinimap then NS:RefreshNormalMinimap() end
    -- Native geometry is restored now; only then expose its player arrow.
    if Minimap and Minimap.SetIconScale and self.nativeIconScale then Minimap:SetIconScale(farm and 0 or self.nativeIconScale) end
    self.nativeIconScale=nil
    if self.host then self.host:Hide() end
end
NS.ScanPresentations={hud=hud,minimap=minimap}
