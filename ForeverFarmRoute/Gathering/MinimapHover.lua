local _, FRNS_ = ...; local NS = FRNS_.Gathering
-- Shared replacement-minimap interaction, independent of the active display.
local mode={}
NS.ReplacementMinimapHover=mode
local function combat()return InCombatLockdown and InCombatLockdown()end
function mode:Arm(presentation)
    if self.shuttingDown or self.deathPaused then return end
    self.presentation=presentation;self.armed=true
    self:StartHoverPolling()
end
function mode:Disarm()
    self.armed=nil;self.presentation=nil;self.hovering=nil
    self.hoverRequested=nil;self.resumeAfter=nil
    self:StopHoverPolling()
end
function mode:StopHoverPolling()
    self.polling=nil;self.hoverElapsed=0
    if self.events then self.events:SetScript('OnUpdate',nil) end
end
function mode:PointerOverMap()
    local r=NS.TerrainMinimap and NS.TerrainMinimap.original
    if not r or not GetCursorPosition or not UIParent or not UIParent.GetEffectiveScale then return false end
    local x,y=GetCursorPosition()
    local scale=UIParent:GetEffectiveScale()
    for _,v in ipairs({x or false,y or false,scale,r.x,r.y,r.width,r.height}) do
        if issecretvalue and issecretvalue(v) or type(v)~='number' or v~=v or math.abs(v)==math.huge then return false end
    end
    return scale>0 and math.abs(x/scale-r.x)<=r.width/2+24 and math.abs(y/scale-r.y)<=r.height/2+24
end
function mode:UpdateHover(now)
    if self.shuttingDown or self.transitioning or self.deathPaused or not self.armed then return end
    if NS.StationaryMinimapControls then NS.StationaryMinimapControls:Maintain() end
    local over=self:PointerOverMap()
    self.hoverRequested=over and NS.CursorSweepTrial and NS.CursorSweepTrial.saved~=nil or false
    if combat() then return end
    if over then
        self.resumeAfter=nil
        if NS.CursorSweepTrial and NS.CursorSweepTrial.saved then
            self.hovering=true;self.transitioning=true
            -- Hover must restore the native map even when experimental mode
            -- was selected while an ordinary HUD was already open.
            if self.presentation=='hud' then NS.CursorSweepTrial.saved.enabled=false end
            local ok,err=pcall(NS.SetExperimentalNodeScanEnabled,NS,false)
            self.transitioning=nil
            if not ok then
                self.armed=nil;self.hovering=nil;self:StopHoverPolling()
                NS.Print('Experimental minimap hover: '..tostring(err))
            end
        end
    elseif self.hovering then
        if IsMouseButtonDown and (IsMouseButtonDown('LeftButton') or IsMouseButtonDown('RightButton')) then
            self.resumeAfter=nil;return
        end
        self.resumeAfter=self.resumeAfter or now+.2
        if now>=self.resumeAfter then
            self.hovering=nil;self.hoverRequested=nil;self.resumeAfter=nil
            if self.presentation=='hud' then NS:SetHUDEnabled(true)
            else NS:SetExperimentalMinimapEnabled(true) end
        end
    end
end
function mode:StartHoverPolling()
    if self.polling then return end
    self.polling=true
    self.events:SetScript('OnUpdate',function(_,elapsed)
        if mode.shuttingDown or not mode.armed then return end
        mode.hoverElapsed=(mode.hoverElapsed or 0)+elapsed
        if mode.hoverElapsed<.05 then return end
        mode.hoverElapsed=0;mode:UpdateHover(GetTime())
    end)
end

function mode:OnScannerStopped()
    NS.MinimapScanActive=nil
    local hoverPause=self.armed and self.hovering and not self.shuttingDown
    if not hoverPause then
        self:Disarm()
    end
    if NS.db and NS.db.minimap then NS.db.minimap.fullTimeScanning=hoverPause==true and self.presentation=='minimap' end
    NS:SetCursorScanWorkflow(NS.CursorScanWorkflows.hud)
    if not self.shuttingDown then
        if NS.UpdateAll then NS:UpdateAll() end
        if NS.TerrainMinimap then NS.TerrainMinimap:Update() end
    end
end
