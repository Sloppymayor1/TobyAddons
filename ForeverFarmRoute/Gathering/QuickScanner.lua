local _, FRNS_ = ...; local NS = FRNS_.Gathering
-- Explicit session opt-in. Confirmed automatic swaps or the selected interval
-- enqueue work; native tracking events never start capture here.
local quick={}
NS.QuickScanner=quick
local function combat()return InCombatLockdown and InCombatLockdown()end
local function refresh()if NS.UpdateAll then NS:UpdateAll() end end
-- The HUD mode owns its stationary minimap even between automatic passes.
-- Hover releases native ownership through the same internal HUD toggle used
-- by scan presentation; it neither disarms the mode nor enqueues capture.
local function normalHUD(enabled)
    local previous=NS._experimentalHUDInternal
    NS._experimentalHUDInternal=true
    local ok,err=pcall(NS.SetHUDEnabled,NS,enabled)
    NS._experimentalHUDInternal=previous
    if not ok then error(err) end
end
function quick:RefreshHUDMinimap()
    local map=NS.ReplacementMinimap or NS.TerrainMinimap
    if not map or not map.Start or not map.Stop then return end
    local trial=NS.CursorSweepTrial
    if not self.hudEnabled then
        self.hudHovering=nil
        if self.hudMapDisplay and not trial.saved and not combat() then
            self.hudMapDisplay=nil;map:Stop()
        end
        return
    end
    if combat() or self.shuttingDown then return end
    local hover=NS.ReplacementMinimapHover
    local over=hover and hover:PointerOverMap()
    if over then
        if self.pending and self.pending.hud then self.pending=nil end
        if trial.saved then
            if trial.workflow~=NS.CursorScanWorkflows.hudQuick then return end
            trial:EndHUDQuickPass('normal minimap hover')
            if trial.saved then return end
        end
        self.hudHovering=true;self.hudMapDisplay=nil
        map:Stop()
        if NS.db.hud.enabled then normalHUD(false) end
    else
        if self.hudHovering then
            if IsMouseButtonDown and (IsMouseButtonDown('LeftButton') or IsMouseButtonDown('RightButton')) then return end
            self.hudHovering=nil;normalHUD(true)
        end
        if NS.db.hud.enabled and not trial.saved then
            local controls=NS.StationaryMinimapControls
            if controls and not controls.saved and NS._minimapState then
                -- Mode can be selected while an ordinary HUD is already open.
                -- Re-enter synchronously so capture snapshots native controls
                -- before HUD anchors move, rather than saving centre-screen XY.
                normalHUD(false);normalHUD(true)
            end
            if not self.hudMapDisplay or not map.active then
                self.hudMapDisplay=true;map:Start()
            end
            if map.Maintain then map:Maintain() end
        end
    end
end
-- ForeverFarmHUD hosts /farm. FDG owns its replacement map and capture.
function quick:QueueFarmScan(now)
    local kind=NS:GetCursorSweepTrackingKind()
    if kind=='herb' or kind=='ore' then self.pending={kind=kind,at=now+.1,expires=now+.4,farm=true} end
end

function quick:StopFarmMinimap()
    local farm=self.farmMap
    if not farm or combat() then return end
    if self.farmPass and NS.CursorSweepTrial.saved then NS:SetExperimentalNodeScanEnabled(false) end
    if self.farmPass and NS.CursorSweepTrial.saved then return end
    if self.pending and self.pending.farm then self.pending=nil end
    self.farmMap=nil
    self.farmHovering=nil
    farm.holder.capturing=nil
    farm.holder.releaseCapture=nil
    NS.ReplacementMinimap:Stop()
    if Minimap:GetParent()==farm.parent then
        Minimap:SetAlpha(ForeverFarmHUDDB.hud.mapAlpha or farm.alpha)
        if Minimap.SetIconScale then Minimap:SetIconScale(farm.iconScale) end
    end
end

function quick:RefreshFarmMinimap(now)
    if combat() or self.shuttingDown or not NS.db then return end
    local route=FRNS_.db
    local hud=ForeverFarmHUDDB and ForeverFarmHUDDB.hud
    local modifier=hud and hud.mouseModifier
    local interacting=hud and (hud.mouseMode or modifier=='SHIFT' and IsShiftKeyDown()
        or modifier=='ALT' and IsAltKeyDown() or modifier=='CTRL' and IsControlKeyDown())
    local requested=route and route.nodeScan and not route.disabled and NS:FarmHUDOpen()
        and NS.db.hud.rememberNodes and not (self.enabled or self.hudEnabled or NS.db.hud.enabled or interacting)
    local farm,trial,map=self.farmMap,NS.CursorSweepTrial,NS.ReplacementMinimap
    local hover=NS.ReplacementMinimapHover
    if farm then
        if not requested or not (map.frame and map.frame:IsShown()) then
            self:StopFarmMinimap()
        else
            local over=hover:PointerOverMap()
            if over then
                if self.pending and self.pending.farm then self.pending=nil end
                if self.farmPass and trial.saved then NS:SetExperimentalNodeScanEnabled(false) end
            elseif self.farmHovering then
                self:QueueFarmScan(now)
            end
            self.farmHovering=over
            map:Maintain()
        end
        return
    end
    if not requested or trial.saved or now<(self.nextFarmCheck or 0) then return end
    self.nextFarmCheck=now+.1
    local parent=_G.ForeverFarmHUD_HUD
    if Minimap:GetParent()~=parent then return end
    FRNS_.SyncMapHolder()
    local holder=_G.ForeverFarmRouteMapHolder
    if not holder or not holder:IsShown() then return end
    map:CaptureOriginalGeometry()
    if not map.original then return end
    local alpha=Minimap:GetAlpha()
    if issecretvalue and issecretvalue(alpha) or type(alpha)~='number' then return end
    self.farmMap={parent=parent,holder=holder,alpha=alpha,iconScale=NS:GetNativeGatheringIconScale()}
    local ok,err=pcall(map.Start,map)
    if not ok or not (map.frame and map.frame:IsShown()) then
        self:StopFarmMinimap()
        if not ok then NS.Print('Farming minimap: '..tostring(err)) end
        self.nextFarmCheck=now+1
        return
    end
    holder.capturing=true
    holder.releaseCapture=function() self:StopFarmMinimap() end
    Minimap:SetAlpha(0)
    if Minimap.SetIconScale then Minimap:SetIconScale(0) end
    self.farmHovering=hover:PointerOverMap()
    if not self.farmHovering then self:QueueFarmScan(now) end
end

function quick:SetEnabled(enabled)
    if enabled and (combat() or self.shuttingDown) then
        NS.Print('Enable quick scanning outside combat.');return false
    end
    local wasEnabled=self.enabled==true
    if enabled and self.farmMap then self:StopFarmMinimap() end
    if enabled and NS.ReplacementMinimapHover and NS.ReplacementMinimapHover.armed then NS.ReplacementMinimapHover:Disarm() end
    self.enabled=enabled==true or nil;self.pending=nil;self.nextTimedScan=nil
    if not enabled and self.running and NS.CursorSweepTrial.workflow==NS.CursorScanWorkflows.quick then NS:SetExperimentalNodeScanEnabled(false) end
    if NS.db and NS.db.minimap then NS.db.minimap.fullTimeScanning=false end
    if wasEnabled~=(self.enabled==true) then
        NS.Print(self.enabled and 'Farming minimap enabled.' or 'Farming minimap disabled.')
    end
    refresh();return true
end
function NS:SetMinimapScanner(scanner)
    if scanner~='quick' then return false end
    if combat() then self.Print('Change scanners outside combat.');refresh();return false end
    -- Selecting a scanner leaves activation explicit and session-only.
    if quick.enabled then quick:SetEnabled(false) end
    if self.ExperimentalMinimap and (self.ExperimentalMinimap.armed or self.MinimapScanActive) then
        self:SetExperimentalMinimapEnabled(false)
    end
    self.db.minimap.scanner=scanner
    refresh();return true
end
function NS:OnAutomaticGatheringSwitch(spell)
    if self.db.quickScan and self.db.quickScan.trigger=="interval" then return end
    if not (quick.enabled or quick.hudEnabled or quick.farmMap) or quick.shuttingDown or combat() then return end
    local kind=spell==2383 and 'herb' or spell==2580 and 'ore'
    if not kind then return end
    quick.pending={kind=kind,at=GetTime()+.1,expires=GetTime()+.4,hud=quick.hudEnabled==true,farm=quick.farmMap~=nil}
end
function quick:Update(now)
    local trial=NS.CursorSweepTrial
    self:RefreshHUDMinimap()
    self:RefreshFarmMinimap(now)
    local continuous=NS.GetQuickScanDuration and NS:GetQuickScanDuration()==math.huge
    local timed=continuous or NS.db.quickScan and NS.db.quickScan.trigger=='interval'
    if timed and (self.enabled or self.hudEnabled or self.farmMap) and not self.shuttingDown then
        local interval=continuous and .5 or NS.GetQuickScanInterval and NS:GetQuickScanInterval() or 10
        self.nextTimedScan=self.nextTimedScan or now+interval
        if now>=self.nextTimedScan then
            -- Missed intervals are skipped; never queue a backlog after blockers.
            self.nextTimedScan=now+interval
            if not combat() and not trial.saved and not self.pending
                and not (UnitIsDeadOrGhost and UnitIsDeadOrGhost('player')) then
                local kind=NS:GetCursorSweepTrackingKind()
                if kind=='herb' or kind=='ore' then
                    self.pending={kind=kind,at=now+.1,expires=now+.4,hud=self.hudEnabled==true,farm=self.farmMap~=nil}
                end
            end
        end
    else self.nextTimedScan=nil end
    if self.hudEnabled then
        local pending=self.pending
        if pending and pending.hud and now>=pending.at then
            self.pending=nil
            if now<=pending.expires and not trial.saved and NS.db.hud.enabled and not self.shuttingDown and not combat()
                and not (UnitIsDeadOrGhost and UnitIsDeadOrGhost('player'))
                and NS:GetCursorSweepTrackingKind()==pending.kind then
                trial:BeginHUDQuickPass(pending.kind,now)
            end
        elseif not pending and not trial.saved and not combat() and not self.shuttingDown
            and now>=(self.nextPrepare or 0) and trial.WarmQuickLocations then
            self.nextPrepare=now+.05;trial:WarmQuickLocations()
        end
        return
    end
    if self.running then
        local discovery=self.farmPass and trial.workflow==NS.CursorScanWorkflows.farmDiscovery
        local expired=discovery and (trial.passReady or trial:SwapBudgetExpired()) or not discovery and now>=self.deadline
        if not trial.saved or not discovery and trial.workflow~=NS.CursorScanWorkflows.quick then
            if self.farmPass then
                self.farmFinished=(self.farmFinished or 0)+1
                self.farmHits=(self.farmHits or 0)+(trial.positiveProbes or 0)
                self.farmPass=nil
            end
            self.running=nil;refresh()
        elseif not (self.enabled or self.farmMap) or self.shuttingDown or combat() or expired
            or NS.GetCursorSweepTrackingKind and NS:GetCursorSweepTrackingKind()~=self.kind then
            trial.quickStopReason=not (self.enabled or self.farmMap) and 'quick scanner disabled' or self.shuttingDown and 'shutdown'
                or combat() and 'combat' or expired and (discovery and 'FDG discovery pass ended' or 'scan duration deadline')
                or 'tracking changed '..tostring(self.kind)..' -> '..tostring(NS.GetCursorSweepTrackingKind and NS:GetCursorSweepTrackingKind())
            NS:SetExperimentalNodeScanEnabled(false)
        end
        return
    end
    local pending=self.pending
    if not pending and (self.enabled or self.farmMap) and not self.shuttingDown and not combat() and not trial.saved
        and now>=(self.nextPrepare or 0) and trial.WarmQuickLocations then
        self.nextPrepare=now+.05
        trial:WarmQuickLocations()
    end
    if not pending or now<pending.at then return end
    self.pending=nil
    local farm=pending.farm and self.farmMap
    if now>pending.expires or not (self.enabled or farm) or self.shuttingDown or combat() or trial.saved
        or NS.db.hud.enabled or UnitIsDeadOrGhost and UnitIsDeadOrGhost('player')
        or not NS.GetCursorSweepTrackingKind or NS:GetCursorSweepTrackingKind()~=pending.kind then return end
    local map=NS.ReplacementMinimap or NS.TerrainMinimap
    if map and not farm then map:CaptureOriginalGeometry() end
    if NS.ReplacementMinimapHover:PointerOverMap() then return end
    if NS.TerrainMarkers and NS.TerrainMarkers.SampleNativePins then
        local ok,err=pcall(NS.TerrainMarkers.SampleNativePins,NS.TerrainMarkers)
        if not ok then NS.TerrainMarkers.nativePinSample={status='sampling unavailable',lines={}} end
    end
    NS:SetCursorScanWorkflow(NS.CursorScanWorkflows.quick)
    NS.MinimapScanActive=true
    self.running=true;self.kind=pending.kind;self.deadline=now+(NS.GetQuickScanDuration and NS:GetQuickScanDuration() or 1.5)
    self.farmPass=farm and true or nil
    if not NS:SetExperimentalNodeScanEnabled(true) then
        if trial.saved then NS:SetExperimentalNodeScanEnabled(false) end
        if not trial.saved then
            self.running=nil;self.farmPass=nil;NS.MinimapScanActive=nil
            NS:SetCursorScanWorkflow(NS.CursorScanWorkflows.hud)
        end
    elseif farm then
        self.farmStarts=(self.farmStarts or 0)+1
    end
end
local events=CreateFrame('Frame')
quick.events=events
events:RegisterEvent('PLAYER_LOGIN');events:RegisterEvent('PLAYER_LOGOUT')
events:RegisterEvent('PLAYER_DEAD');events:RegisterEvent('PLAYER_LEAVING_WORLD')
events:SetScript('OnEvent',function(_,event)
    quick.pending=nil
    if event=='PLAYER_LOGIN' then quick.enabled=nil;quick.hudEnabled=nil;quick.shuttingDown=nil
    elseif event=='PLAYER_LOGOUT' then quick.enabled=nil;quick.shuttingDown=true
    elseif quick.running then NS:SetExperimentalNodeScanEnabled(false) end
end)
events:SetScript('OnUpdate',function()quick:Update(GetTime())end)
