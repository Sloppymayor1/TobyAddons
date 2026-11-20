local _, FRNS_ = ...; local NS = FRNS_.Gathering
-- Manual presentation/lifecycle adapter. Shared HUD scan engine only.
-- Hover handoff is armed only by explicit activation; login never starts it.
local mode=assert(NS.ReplacementMinimapHover,"load MinimapHover before ExperimentalMinimap")
local events
NS.ExperimentalMinimap=mode
local function combat()return InCombatLockdown and InCombatLockdown()end
local function refresh()
    if NS.UpdateAll then NS:UpdateAll() end
    if NS.TerrainMinimap then NS.TerrainMinimap:Update() end
end
local function setEnabled(enabled)
    local trial=NS.CursorSweepTrial
    if enabled and combat() then
        NS.Print('Start the experimental minimap outside combat.')
        refresh();return false
    end
    if not enabled then
        if mode.presentation=='hud' then NS.db.minimap.fullTimeScanning=false;refresh();return true end
        mode.presentation=nil
        mode.armed=nil;mode.hovering=nil;mode.hoverRequested=nil;mode.resumeAfter=nil
        mode:StopHoverPolling()
        if NS.MinimapScanActive then NS:SetExperimentalNodeScanEnabled(false)
        else NS.db.minimap.fullTimeScanning=false;refresh() end
        return true
    end
    if NS.MinimapScanActive and trial and trial.saved then mode:StartHoverPolling();return true end
    if mode.presentation=='hud' then mode:Disarm() end
    if NS.db.hud.enabled then NS:SetHUDEnabled(false) end
    if NS.db.hud.enabled or not trial or trial.saved then return false end
    mode.presentation='minimap';mode.armed=true
    NS.CursorScanWorkflows.minimap=NS.CursorScanWorkflows.minimap or NS.CursorScanWorkflow:New()
    NS:SetCursorScanWorkflow(NS.CursorScanWorkflows.minimap)
    if NS.TerrainMinimap then NS.TerrainMinimap:CaptureOriginalGeometry() end
    NS.db.minimap.launcherMode='minimap'
    if mode:PointerOverMap() then
        mode.hovering=true;NS.db.minimap.fullTimeScanning=true
        NS:SetCursorScanWorkflow(NS.CursorScanWorkflows.hud)
        mode:StartHoverPolling();refresh();return true
    end
    NS.MinimapScanActive=true
    NS.db.minimap.fullTimeScanning=true
    NS.db.minimap.launcherMode='minimap'
    if not NS:SetExperimentalNodeScanEnabled(true) then
        if not trial.saved then mode:OnScannerStopped() end
        return false
    end
    refresh()
    local map=NS.TerrainMinimap
    if not (map and map.frame and map.frame:IsShown()) then
        NS:SetExperimentalNodeScanEnabled(false)
        NS.Print('Experimental minimap: replacement terrain unavailable here; normal minimap restored.')
        return false
    end
    mode:StartHoverPolling()
    return true
end
function NS:SetExperimentalMinimapEnabled(enabled)
    if self.QuickScanner and (self.QuickScanner.enabled or self.db and self.db.minimap.scanner=="quick") then
        return self.QuickScanner:SetEnabled(enabled)
    end
    if mode.shuttingDown or mode.transitioning or not self.db or not self.db.minimap then return false end
    if mode.deathPaused and not mode.deathTransition then
        mode.deathResume=enabled and 'minimap' or nil
        return true
    end
    mode.transitioning=true
    local ok,result=pcall(setEnabled,enabled==true)
    mode.transitioning=nil
    if not ok then
        -- Keep the existing scanner's restoration path for setup errors.
        if self.MinimapScanActive then
            self:SetExperimentalNodeScanEnabled(false)
            if not (self.CursorSweepTrial and self.CursorSweepTrial.saved) then mode:OnScannerStopped() end
        end
        self.Print('Experimental minimap: '..tostring(result))
        return false
    end
    if not result and not self.MinimapScanActive and not mode.hovering then
        mode.armed=nil;mode:StopHoverPolling()
    end
    return result
end
-- Keep this session choice in memory only. Releasing to ghost is still dead;
-- resurrection and protected layout restoration must both be safe to resume.
function mode:UpdateDeathPause()
    if self.shuttingDown or not NS.db or not NS.db.hud then return end
    local dead=UnitIsDeadOrGhost and UnitIsDeadOrGhost('player')
    if dead and not self.deathPaused then
        self.deathPaused=true
        self.deathResume=self.armed and (self.presentation or 'minimap') or NS.MinimapScanActive and 'minimap'
            or NS.db.hud.enabled and 'hud' or nil
    end
    if not self.deathPaused or combat() then return end
    self.deathTransition=true
    if dead then
        if self.presentation=='hud' then self:Disarm()
        elseif self.armed or NS.MinimapScanActive then NS:SetExperimentalMinimapEnabled(false) end
        if NS.db.hud.enabled then NS:SetHUDEnabled(false) end
    else
        local resume=self.deathResume
        self.deathPaused=nil;self.deathResume=nil
        if resume=='minimap' then NS:SetExperimentalMinimapEnabled(true)
        elseif resume=='hud' then NS:SetHUDEnabled(true) end
    end
    self.deathTransition=nil
end
events=CreateFrame('Frame')
mode.events=events
if NS.ReplacementMinimap then NS.ReplacementMinimap.hover=mode end
events:RegisterEvent('PLAYER_LOGIN');events:RegisterEvent('PLAYER_LOGOUT')
for _,event in ipairs({'PLAYER_DEAD','PLAYER_ALIVE','PLAYER_UNGHOST','PLAYER_ENTERING_WORLD','PLAYER_REGEN_ENABLED'}) do events:RegisterEvent(event) end
events:SetScript('OnEvent',function(_,event)
    if event=='PLAYER_LOGOUT' then
        mode.shuttingDown=true;mode.armed=nil;mode.hovering=nil;mode.hoverRequested=nil;mode.resumeAfter=nil
        mode:StopHoverPolling()
        return -- No capture/layout changes while the UI is being torn down.
    end
    if event~='PLAYER_LOGIN' then mode:UpdateDeathPause();return end
    -- Never restore active capture on login/reload, even from an older saved preference.
    mode.shuttingDown=nil;mode.armed=nil;mode.hovering=nil;mode.hoverRequested=nil;mode.resumeAfter=nil
    mode:StopHoverPolling()
    if NS.db and NS.db.minimap then NS.db.minimap.fullTimeScanning=false end
    refresh()
end)
-- Do not reassign Blizzard's shared SlashCmdList global.
SLASH_FDGMINIMAP1='/fdgminimap'
SlashCmdList.FDGMINIMAP=function(message)
    local command=(message or ''):lower():match('^%s*(%S+)')
    if command=='on' then NS:SetExperimentalMinimapEnabled(true)
    elseif command=='off' then NS:SetExperimentalMinimapEnabled(false)
    else NS.Print('Experimental minimap: /fdgminimap on|off. Manual activation only; hover shows the normal minimap. Automatic startup remains disabled.') end
end
