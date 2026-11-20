local ADDON_NAME_, FRNS_ = ...; local NS = FRNS_.Gathering
-- Opt-in layout experiment. No soft cursor, virtual hover or system cursor writes.
-- A positive subpixel size can still rasterize as a moving one-pixel speck.
-- Detection geometry uses the separately preserved original iconScale.
local HIDDEN_ICON_SCALE=0
-- A workflow holds mode-specific rules; capture, readers, guards and cleanup
-- stay in this shared scanner. New modes opt into overrides outside a scan.
local Workflow={}
Workflow.__index=Workflow
local workflowDefaults={knownLocations=true,validation=true,refinement=true,knownOnly=false,
    knownProbeLimit=2,activeBudget=10,elapsedBudget=20,updateInterval=1/60,
    emptySettle=1/60,resourceSettle=1/30,confirmationDelay=.012,dwell=.25}
function Workflow:New(overrides)
    local options={}
    for key,value in pairs(workflowDefaults) do options[key]=value end
    for key,value in pairs(overrides or {}) do
        local default=workflowDefaults[key]
        assert(default~=nil,'unknown scan workflow option: '..tostring(key))
        if type(default)=='boolean' then assert(type(value)=='boolean','boolean scan option required')
        else assert(type(value)=='number' and value==value and value>0 and value<math.huge,'positive finite scan option required') end
        options[key]=value
    end
    return setmetatable({options=options},self)
end
function Workflow:Allows(stage)return self.options[stage]==true end
function Workflow:CanProbeKnown(streak)
    return self:Allows('knownLocations') and (streak or 0)<self.options.knownProbeLimit
end
function Workflow:BudgetExpired(scan,now)
    return scan.visitActiveStart~=nil and (scan.activeSeconds or 0)-scan.visitActiveStart>=self.options.activeBudget
        or scan.visitStartedAt~=nil and now-scan.visitStartedAt>=self.options.elapsedBudget
end
function Workflow:IsSwapReady(scan,now)
    return self:BudgetExpired(scan,now) or scan.passReady==true and not scan.refinement and not scan.refinePending
        and not scan.validationBatchActive and not scan.nodeValidation
end
function Workflow:SampleDelay(resource)return resource and self.options.resourceSettle or self.options.emptySettle end
function Workflow:CaptureDelay(fast)return fast and self.options.emptySettle or self.options.resourceSettle end
function Workflow:ConfirmationDelay()return self.options.confirmationDelay end
function Workflow:Dwell()return self.options.dwell end
function Workflow:UpdateInterval()return self.options.updateInterval end
NS.CursorScanWorkflow=Workflow
-- A quick pass has no later raster read to recover an early empty tooltip.
-- Let native blips/hover data settle at each saved location before accepting
-- either an empty response or the first positive confirmation vote.
NS.CursorScanWorkflows={hud=Workflow:New(),quick=Workflow:New({knownOnly=true,validation=false,refinement=false,
    emptySettle=.1,resourceSettle=.1,dwell=.2})}
NS.CursorScanWorkflows.farmDiscovery=Workflow:New({knownLocations=false,validation=false,refinement=false})
NS.CursorScanWorkflows.hudQuick=Workflow:New({knownOnly=true,validation=false,refinement=false,
    emptySettle=.1,resourceSettle=.1,dwell=.2})
local trial = {size = 0, alpha = 0, index = 0, moves = 0,workflow=NS.CursorScanWorkflows.hud}
function NS:SetCursorScanWorkflow(workflow)
    assert(not trial.saved,'stop the scanner before changing its workflow')
    assert(getmetatable(workflow)==Workflow,'scan workflow instance required')
    trial.workflow=workflow
end
NS.CursorSweepTrial = trial
local function combat() return InCombatLockdown and InCombatLockdown() end
local function publicNumber(v)
    return not (issecretvalue and issecretvalue(v)) and type(v) == 'number' and v == v
end
local function say(text) NS.Print('Cursor trial: '..text) end
local function copy(t) local r = {}; for k,v in pairs(t) do r[k]=v end; return r end
-- Soft interaction is independent of world mouse hover. Do not require
-- UnitExists: Forever game objects can return false for that API.
local function softRead(fn,...)
    if type(fn)~='function' then return end
    local ok,value=pcall(fn,...)
    if ok and not (issecretvalue and issecretvalue(value)) then return value end
end
-- Match the live-tested hands-off selection setup; all changes use the
-- existing ownership journal and restore when capture stops.
local softSettings={SoftTargetInteract='3',SoftTargetInteractRange='15',SoftTargetInteractOnlyInRange='0',
    SoftTargetInteractArc='2',SoftTargetIconGameObject='1'}
function trial:EnableNearbyInteraction()
    self.softCVars={};self.softResourceName=nil;self.softResource=nil
    if not (UnitIsGameObject and UnitName) then self.softStatus='API unavailable';return end
    local getter=GetCVar or C_CVar and C_CVar.GetCVar
    local setter=SetCVar or C_CVar and C_CVar.SetCVar
    self.softStatus='reading existing interaction settings'
    if not getter or not setter then return end
    for key,wanted in pairs(softSettings) do
        local original=softRead(getter,key)
        if type(original)=='string' and original~=wanted then
            pcall(setter,key,wanted)
            if softRead(getter,key)==wanted then self.softCVars[key]={original=original,applied=wanted} end
        end
    end
    self.softStatus='nearby interaction detection enabled'
end
function trial:RestoreNearbyInteraction()
    local getter=GetCVar or C_CVar and C_CVar.GetCVar
    local setter=SetCVar or C_CVar and C_CVar.SetCVar
    for key,entry in pairs(self.softCVars or {}) do
        -- Preserve a later setting selected by the player or another addon.
        if setter and softRead(getter,key)==entry.applied then pcall(setter,key,entry.original) end
    end
    self.softCVars=nil;self.softResourceName=nil;self.softResource=nil
end
function trial:NearbyGatheringObject()
    if softRead(UnitIsGameObject,'softinteract')~=true then return false end
    local name=softRead(UnitName,'softinteract')
    if type(name)~='string' or name=='' or not NS.LookupNodeResource then return false end
    if name~=self.softResourceName then
        self.softResourceName=name;self.softResource=false
        for _,kind in ipairs({'herb','ore','treasure'}) do
            if NS:LookupNodeResource(name,kind) then self.softResource=true;break end
        end
        -- Retry unknown names: localized item metadata may arrive later.
        if not self.softResource then self.softResourceName=nil end
    end
    return self.softResource==true
end
-- Session-only bounded diagnostics. Events and point timings use separate
-- rings so empty-space traffic cannot erase the last resource/swap decision.
function trial:Trace(event,detail,point)
    if NS.RecordNodePlacement then NS:RecordNodePlacement(point and 'points' or 'events',tostring(event)..'; '..tostring(detail or '')) end
    if self.logging==false then return end
    self.traceBuffers=self.traceBuffers or {}
    local key=point and 'points' or 'events'
    local ring=self.traceBuffers[key] or {next=1,count=0};self.traceBuffers[key]=ring
    local now=GetTime()
    local line=string.format('+%.2fs %s %s',math.max(0,now-(self.traceOrigin or now)),event,tostring(detail or ''))
    ring[ring.next]=line:gsub('[\r\n]',' '):sub(1,260)
    ring.next=ring.next%128+1;ring.count=math.min(128,ring.count+1)
end
-- Resource provenance only: never retain arbitrary tooltip/player/quest text.
-- At most four changed responses per placement; the existing 128-event ring
-- bounds retention. Repeated identical samples do not generate events.
function trial:TraceNativeRead(hits,reliable,nonempty,now)
    if self.logging==false then return end
    if self.nativeReadPlacement~=self.at then
        self.nativeReadPlacement=self.at;self.nativeReadSignature=nil;self.nativeReadCount=0
    end
    local labels={}
    for i=1,math.min(4,#hits) do
        local hit=hits[i]
        labels[#labels+1]=tostring(hit.resource.name or hit.resource.id):sub(1,40)
            ..'@'..table.concat(hit.tooltipSources or {},',')
    end
    local detail=(reliable and 'public' or 'unreadable')..'; hits='..#hits..'; '
        ..(#hits>0 and table.concat(labels,' | ') or nonempty and 'non-resource' or 'empty')
    if detail==self.nativeReadSignature then return end
    self.nativeReadSignature=detail
    -- Keep an empty transition after a resource, without tracing empty space.
    if #hits==0 and reliable and not self.nativeReadHadResource then return end
    if not reliable then detail=detail..'; anonymous exclusion='..tostring(NS.AnonymousReadExclusion or 'none') end
    self.nativeReadHadResource=#hits>0
    if (self.nativeReadCount or 0)>=4 then return end
    self.nativeReadCount=(self.nativeReadCount or 0)+1
    self:Trace('native read',string.format('point=%s age=%.0fms %s',tostring(self.index),
        self.at and math.max(0,(now-self.at)*1000) or 0,detail))
end
function trial:DumpTrace(points,count)
    local key=points and 'points' or 'events'
    local ring=self.traceBuffers and self.traceBuffers[key]
    count=math.max(1,math.min(80,math.floor(tonumber(count) or (points and 30 or 40))))
    say('log '..key..': '..tostring(ring and ring.count or 0)..' retained; logging='..tostring(self.logging~=false))
    if not ring then return end
    for age=math.min(count,ring.count),1,-1 do
        local i=(ring.next-age-1)%128+1
        say(ring[i])
    end
end
function trial:TraceProbe(result,now)
    if self.workflow:Allows('knownOnly') and self.knownTarget then
        local target=self.knownTarget
        self:Trace('quick point',string.format('%s map=%s xy=%.3f,%.3f %s %s age=%.0fms',
            tostring(target.kind),tostring(target.map),target.x*100,target.y*100,
            target.quickOrigin and 'nearby' or 'saved centre',result,
            self.at and math.max(0,(now-self.at)*1000) or 0),true)
        return
    end
    local spot=self.spots and self.spots[self.index]
    self:Trace('point',string.format('%s %d/%d phase=%d offset=(%.1f,%.1f) %s dwell=%.0fms attempts=%d',
        tostring(self.scanKind or 'none'),self.index or 0,#(self.spots or {}),self.scanPhase or 0,
        spot and spot[1] or 0,spot and spot[2] or 0,result,
        self.at and math.max(0,(now-self.at)*1000) or 0,
        self.discoveryAttempts and self.discoveryAttempts[self.index] or 0),true)
end
local function saveMap()
    local s = {parent=Minimap:GetParent(), scale=Minimap:GetScale(), alpha=Minimap:GetAlpha(),
        width=Minimap:GetWidth(), height=Minimap:GetHeight(), points={}}
    for i=1,Minimap:GetNumPoints() do s.points[i]={Minimap:GetPoint(i)} end
    return s
end
-- Suppress native quest areas during capture; the replacement renderer uses
-- the original preference, which is restored and recovered across reloads.
local function questAreaIndex()
    local filter=Enum and Enum.MinimapTrackingFilter and Enum.MinimapTrackingFilter.QuestPOIs
    if filter==nil or not C_Minimap or not C_Minimap.GetTrackingFilter or not C_Minimap.GetNumTrackingTypes then return end
    local count=C_Minimap.GetNumTrackingTypes()
    if not publicNumber(count) then return end
    for i=1,math.min(count,128) do
        local value=C_Minimap.GetTrackingFilter(i)
        if not (issecretvalue and issecretvalue(value)) and type(value)=='table'
            and not (issecretvalue and issecretvalue(value.filterID)) and value.filterID==filter then return i end
    end
end
local function questAreaOwner()
    if type(UnitGUID)~='function' then return end
    local ok,guid=pcall(UnitGUID,'player')
    if ok and not (issecretvalue and issecretvalue(guid)) and type(guid)=='string' then return guid end
end
-- questPOI controls the native quest point/arrow display. Capture only owns
-- its temporary0 value; do not clear the selected quest or overwrite later edits.
function trial:QuestArrow(hidden,retainRecovery)
    local db,owner=NS.db,questAreaOwner()
    if not db or not owner then return false end
    local records=db.questArrowRecovery
    local record=type(records)=='table' and records[owner]
    if self.questArrowOriginal==nil and type(record)=='string'and (record=='0'or record=='1')then
        self.questArrowOriginal=record
    end
    if not hidden and self.questArrowOriginal==nil then return true end
    if combat()then return false end
    local getter=GetCVar or C_CVar and C_CVar.GetCVar
    local setter=SetCVar or C_CVar and C_CVar.SetCVar
    local current=softRead(getter,'questPOI')
    if not setter or (current~='0'and current~='1')then return false end
    if hidden and self.questArrowOriginal==nil then self.questArrowOriginal=current end
    local original=self.questArrowOriginal
    if original==nil then return true end
    if retainRecovery and current~='0'then original=current;self.questArrowOriginal=current end
    if type(db.questArrowRecovery)~='table'then db.questArrowRecovery={}end
    db.questArrowRecovery[owner]=original
    local wanted=hidden and '0'or (current=='0'and original or current)
    if current~=wanted then
        local ok=pcall(setter,'questPOI',wanted)
        if not ok or softRead(getter,'questPOI')~=wanted then return false end
    end
    self.questArrowStatus=hidden and 'hidden during scan'or 'user setting restored'
    if not hidden then
        self.questArrowOriginal=nil
        if not retainRecovery then
            db.questArrowRecovery[owner]=nil
            if not next(db.questArrowRecovery)then db.questArrowRecovery=nil end
        end
    end
    return true
end
-- Own only the three service filters that interfere with native node probes.
-- Resolve indices afresh: tracking menu indices can change between sessions.
function trial:ServiceTracking(hidden,retainRecovery)
    local db,owner=NS.db,questAreaOwner()
    if not db or not owner or combat() then return false end
    local api=C_Minimap
    if not api or not api.GetNumTrackingTypes or not api.GetTrackingFilter
        or not api.GetTrackingInfo or not api.SetTracking then return false end
    local filters=Enum and Enum.MinimapTrackingFilter or {}
    local records=type(db.serviceTrackingRecovery)=='table' and db.serviceTrackingRecovery or {}
    local original=type(records[owner])=='table' and records[owner] or {}
    local complete=true
    for _,name in ipairs({'Mailbox','Innkeeper','TaxiNode'}) do
        local id=filters[name]
        if publicNumber(id) then
            local ok,count=pcall(api.GetNumTrackingTypes)
            local index
            if ok and publicNumber(count) then
                for i=1,math.min(count,128) do
                    local filter=softRead(api.GetTrackingFilter,i)
                    if not (issecretvalue and issecretvalue(filter)) and type(filter)=='table'
                        and publicNumber(filter.filterID) and filter.filterID==id then index=i;break end
                end
            end
            local info=index and softRead(api.GetTrackingInfo,index)
            local readable=not (issecretvalue and issecretvalue(info)) and type(info)=='table'
                and not (issecretvalue and issecretvalue(info.active)) and type(info.active)=='boolean'
            if readable then
                if hidden and type(original[name])~='boolean' then original[name]=info.active end
                if retainRecovery and info.active and type(original[name])=='boolean' then original[name]=true end
                if type(original[name])=='boolean' then
                    records[owner]=original;db.serviceTrackingRecovery=records
                    local wanted=not hidden and original[name] or false
                    if info.active~=wanted then pcall(api.SetTracking,index,wanted) end
                    local confirmed=softRead(api.GetTrackingInfo,index)
                    if not (issecretvalue and issecretvalue(confirmed)) and type(confirmed)=='table'
                        and not (issecretvalue and issecretvalue(confirmed.active)) and confirmed.active==wanted then
                        if not hidden and not retainRecovery then original[name]=nil end
                    else complete=false end
                end
            elseif hidden or type(original[name])=='boolean' then complete=false end
        elseif type(original[name])=='boolean' then complete=false end
    end
    if not next(original) then records[owner]=nil end
    if not next(records) then db.serviceTrackingRecovery=nil end
    return complete
end
function trial:QuestAreas(hidden,retainRecovery)
    self:ServiceTracking(hidden,retainRecovery)
    self:QuestArrow(hidden,retainRecovery)
    local db=NS.db
    local owner=questAreaOwner()
    if not owner then self.questRefresh=hidden;return false end
    local recovery=db and db.questAreaRecovery
    local record=type(recovery)=='table' and recovery[owner]
    local filter=Enum and Enum.MinimapTrackingFilter and Enum.MinimapTrackingFilter.QuestPOIs
    if self.questAreasOriginal==nil and type(record)=='table' and record.filterID==filter
        and type(record.active)=='boolean' then self.questAreasOriginal=record.active end
    if not hidden and self.questAreasOriginal==nil then self.questRefresh=nil;return true end
    if combat() then self.questRefresh=hidden;return false end
    if not C_Minimap or not C_Minimap.SetTracking or not C_Minimap.GetTrackingInfo then self.questRefresh=hidden;return false end
    local ok,index=pcall(questAreaIndex)
    if not ok or not index then self.questRefresh=hidden;return false end
    local success,info=pcall(C_Minimap.GetTrackingInfo,index)
    if not success or issecretvalue and issecretvalue(info) or type(info)~='table'
        or issecretvalue and issecretvalue(info.active) or type(info.active)~='boolean' then self.questRefresh=hidden;return false end
    -- Capture normally leaves this filter off. An enabled value at logout can
    -- be the user's explicit repair; do not persist an older disabled snapshot.
    if retainRecovery and self.saved and info.active then self.questAreasOriginal=true end
    if hidden and self.questAreasOriginal==nil then self.questAreasOriginal=info.active end
    local wanted=self.questAreasOriginal
    if wanted==nil then self.questRefresh=nil;return true end
    -- Record before hiding; never overwrite the user's original with our
    -- temporary disabled value. This record survives a combat logout/reload.
    if db then
        if type(db.questAreaRecovery)~='table' then db.questAreaRecovery={} end
        db.questAreaRecovery[owner]={filterID=filter,active=self.questAreasOriginal}
    end
    if hidden then wanted=false end
    if info.active~=wanted then
        local applied,result=pcall(C_Minimap.SetTracking,index,wanted)
        if not applied or issecretvalue and issecretvalue(result) or result==false then self.questRefresh=hidden;return false end
        local confirmed,newInfo=pcall(C_Minimap.GetTrackingInfo,index)
        if not confirmed or issecretvalue and issecretvalue(newInfo) or type(newInfo)~='table'
            or issecretvalue and issecretvalue(newInfo.active) or newInfo.active~=wanted then self.questRefresh=hidden;return false end
    end
    if not hidden and not retainRecovery then
        self.questAreasOriginal=nil
        if db and type(db.questAreaRecovery)=='table' then
            db.questAreaRecovery[owner]=nil
            if not next(db.questAreaRecovery)then db.questAreaRecovery=nil end
        end
    end
    self.questRefresh=nil
    return true
end
-- Suppress only native minimap tooltip artwork; C_TooltipInfo remains untouched.
local function read(object,method)
    local ok,value=pcall(function()
        if not object or issecretvalue and issecretvalue(object) then return end
        if object.IsForbidden and object:IsForbidden() then return end
        if type(object[method])=='function' then return object[method](object) end
    end)
    if ok and not (issecretvalue and issecretvalue(value)) then return value end
end
local function inspectable(object)
    local ok,value=pcall(function()
        if not object or issecretvalue and issecretvalue(object) then return false end
        if object.IsForbidden and object:IsForbidden() then return false end
        if not object.GetParent then return false end
        object:GetParent() -- Some forbidden client objects expose no IsForbidden.
        return true
    end)
    return ok and value==true
end
local function captureFrame(frame)
    for _=1,12 do
        if not inspectable(frame) then return false end
        if frame==Minimap then return true end
        if frame==UIParent then return false end
        frame=read(frame,'GetParent')
    end
    return false
end
-- Unknown or inaccessible ordering pauses conservatively.
local strataOrder={BACKGROUND=1,LOW=2,MEDIUM=3,HIGH=4,DIALOG=5,FULLSCREEN=6,FULLSCREEN_DIALOG=7,TOOLTIP=8}
function trial:BelowCapture(frame)
    if not inspectable(frame) then return false end
    local theirs,ours=read(frame,'GetFrameStrata'),read(Minimap,'GetFrameStrata')
    if not strataOrder[theirs] or not strataOrder[ours] then return false end
    if strataOrder[theirs]~=strataOrder[ours] then return strataOrder[theirs]<strataOrder[ours] end
    local level,ourLevel=read(frame,'GetFrameLevel'),read(Minimap,'GetFrameLevel')
    return publicNumber(level) and publicNumber(ourLevel) and level<ourLevel
end
local function attached(frame)
    if NS.IsStationaryMinimapControl and NS:IsStationaryMinimapControl(frame) then return false end
    if not inspectable(frame) then return false end
    if frame==Minimap or frame==NS.HUDFrame or frame==UIParent or frame==WorldFrame then return false end
    if captureFrame(frame) then return true end
    local count=read(frame,'GetNumPoints')
    if publicNumber(count) and frame.GetPoint then
        for i=1,math.min(count,12)do
            local ok,_,anchor=pcall(frame.GetPoint,frame,i)
            if ok and anchor and captureFrame(anchor) then return true end
        end
    end
    return false
end
-- Questie pools named buttons between minimap and world-map use. Only its
-- currently assigned minimap buttons may bypass the broad protected-frame
-- exclusion, and all writes remain outside combat.
local function questiePin(frame,active)
    local name=read(frame,'GetName')
    if type(name)~='string' or not name:match('^QuestieFrame%d+$') then return false end
    local ok,valid=pcall(function()
        return publicNumber(frame.frameId) and name=='QuestieFrame'..frame.frameId
            and (not active or frame.miniMapIcon==true and type(frame.data)=='table' and captureFrame(frame))
    end)
    return ok and valid==true
end
local function questieAssignment(frame,state)
    local ok,same=pcall(function()return questiePin(frame,true) and frame.data==state.questieData end)
    return ok and same
end
function trial:ReleaseQuestieControl(frame,state)
    if combat() then state.releasePending=true;return end
    if self.controls then self.controls[frame]=nil end -- hooks must be inert before restoration
    if not inspectable(frame) then return end
    -- Restore only values still owned by capture; never Show a pooled button.
    local alpha=read(frame,'GetAlpha')==0
    local mouse=read(frame,'IsMouseEnabled')==false
    local click=read(frame,'IsMouseClickEnabled')==false
    local motion=read(frame,'IsMouseMotionEnabled')==false
    if alpha and state.alpha~=nil and frame.SetAlpha then pcall(frame.SetAlpha,frame,state.alpha) end
    if mouse and state.mouse~=nil and frame.EnableMouse then pcall(frame.EnableMouse,frame,state.mouse) end
    if click and state.click~=nil and frame.SetMouseClickEnabled then pcall(frame.SetMouseClickEnabled,frame,state.click) end
    if motion and state.motion~=nil and frame.SetMouseMotionEnabled then pcall(frame.SetMouseMotionEnabled,frame,state.motion) end
end
function trial:QuietControl(frame,state)
    if combat() or self.controlsWriting or not self.saved or self.stopping or not attached(frame) then return end
    if state.questieData and (state.releasePending or not questieAssignment(frame,state)) then
        self:ReleaseQuestieControl(frame,state);return
    end
    if read(frame,'IsProtected') and not state.questieData then return end
    self.controlsWriting=true
    if state.alpha~=nil and frame.SetAlpha and read(frame,'GetAlpha')~=0 then pcall(frame.SetAlpha,frame,0) end
    if state.mouse~=nil and frame.EnableMouse and read(frame,'IsMouseEnabled')~=false then pcall(frame.EnableMouse,frame,false) end
    if state.click~=nil and frame.SetMouseClickEnabled and read(frame,'IsMouseClickEnabled')~=false then pcall(frame.SetMouseClickEnabled,frame,false) end
    if state.motion~=nil and frame.SetMouseMotionEnabled and read(frame,'IsMouseMotionEnabled')~=false then pcall(frame.SetMouseMotionEnabled,frame,false) end
    self.controlsWriting=nil
    if GameTooltip and read(GameTooltip,'GetOwner')==frame and GameTooltip.Hide then GameTooltip:Hide() end
end
function trial:QuietMinimapControls()
    if combat() or not self.saved or self.stopping then return end
    self.controls=self.controls or {};self.controlHooks=self.controlHooks or setmetatable({}, {__mode='k'})
    -- Resume bounded slices instead of inspecting the entire Questie pool in
    -- one update. Count inactive/foreign/duplicate frames against the slice too.
    local began=debugprofilestop and debugprofilestop()
    local scan=self.controlScan
    if not scan then
        scan={items={},next=1,visited={},budget=512};self.controlScan=scan
        for frame,state in pairs(self.controls)do
            if state.questieData and #scan.items<8192 then scan.items[#scan.items+1]={frame,0,'owned',state} end
        end
        scan.items[#scan.items+1]={Minimap,0}
        local parent=read(Minimap,'GetParent')
        if parent and parent.GetChildren then
            local ok,children=pcall(function()return {parent:GetChildren()}end)
            if ok then for _,child in ipairs(children)do
                if #scan.items>=16384 then break end
                scan.items[#scan.items+1]={child,0,'sibling'}
            end end
        end
    end
    local function enqueue(frame,depth)
        if #scan.items<16384 then scan.items[#scan.items+1]={frame,depth} end
    end
    local function visit(frame,depth,kind,state)
        if kind=='owned' then
            if self.controls[frame]==state and (state.releasePending or not questieAssignment(frame,state)) then
                self:ReleaseQuestieControl(frame,state)
            end
            return
        end
        if scan.visited[frame] or depth>6 then return end
        scan.visited[frame]=true
        if kind=='sibling' and not attached(frame) then return end
        if not inspectable(frame) then return end
        local isQuestie=questiePin(frame,false)
        local questie=isQuestie and questiePin(frame,true)
        if isQuestie and not questie then return end
        if scan.budget<=0 and not questie then return end
        scan.budget=scan.budget-1
        if attached(frame) and (questie or not read(frame,'IsProtected'))
            and not (NS._hiddenMinimapControlAlphas and NS._hiddenMinimapControlAlphas[frame]~=nil) then
            local state=self.controls[frame]
            if not state then
                state={alpha=read(frame,'GetAlpha'),click=read(frame,'IsMouseClickEnabled'),
                    motion=read(frame,'IsMouseMotionEnabled'),parent=read(frame,'GetParent'),
                    template=frame.pinTemplate,provider=frame.provider,
                    questieData=questie and frame.data or nil}
                if questie then state.mouse=read(frame,'IsMouseEnabled') end
                self.controls[frame]=state
            end
            if not self.controlHooks[frame] and hooksecurefunc then
                self.controlHooks[frame]=true
                for _,method in ipairs({'SetAlpha','SetMouseClickEnabled','SetMouseMotionEnabled','EnableMouse','Show','SetParent','Unload'})do
                    if type(frame[method])=='function' then
                        pcall(hooksecurefunc,frame,method,function()
                            if self.controlsWriting then return end
                            local current=self.controls and self.controls[frame]
                            if current then
                                if current.questieData and not questieAssignment(frame,current) then
                                    self:ReleaseQuestieControl(frame,current)
                                else self:QuietControl(frame,current) end
                            end
                        end)
                    end
                end
            end
            self:QuietControl(frame,state)
        end
        if questie then return end
        if frame.GetChildren then
            local ok,children=pcall(function()return {frame:GetChildren()}end)
            if ok then for _,child in ipairs(children)do enqueue(child,depth+1) end end
        end
        if frame.GetRegions then
            local ok,regions=pcall(function()return {frame:GetRegions()}end)
            if ok then for _,region in ipairs(regions)do enqueue(region,depth+1) end end
        end
    end
    local processed=0
    while scan.next<=#scan.items and processed<32 do
        local item=scan.items[scan.next];scan.next=scan.next+1;processed=processed+1
        visit(item[1],item[2],item[3],item[4])
        -- A time budget supplements the deterministic item bound in the client.
        if began and debugprofilestop()-began>=1 then break end
    end
    self.controlSliceItems=processed
    if scan.next>#scan.items then self.controlScan=nil end
end
function trial:RestoreMinimapControls()
    if combat() then return end
    self.controlScan=nil
    local controls=self.controls;self.controls=nil
    for frame,state in pairs(controls or {})do
        -- A released/reassigned pooled pin must not receive the old owner's state.
        if state.questieData then
            self:ReleaseQuestieControl(frame,state)
        elseif inspectable(frame) and read(frame,'GetParent')==state.parent and frame.pinTemplate==state.template and frame.provider==state.provider
            and not read(frame,'IsProtected') then
            if state.alpha~=nil and frame.SetAlpha then pcall(frame.SetAlpha,frame,state.alpha) end
            if state.click~=nil and frame.SetMouseClickEnabled then pcall(frame.SetMouseClickEnabled,frame,state.click) end
            if state.motion~=nil and frame.SetMouseMotionEnabled then pcall(frame.SetMouseMotionEnabled,frame,state.motion) end
        end
    end
end
function trial:PassiveTerrainFocus(frame)
    local terrain=NS.TerrainMinimap and NS.TerrainMinimap.frame
    if not terrain or frame~=terrain or read(frame,'IsShown')~=true then return false end
    return read(frame,'IsMouseEnabled')==false
        or read(frame,'IsMouseClickEnabled')==false and read(frame,'IsMouseMotionEnabled')==false
end
function trial:WorldCaptureFocus()
    if not GetMouseFoci then return false end
    local foci=GetMouseFoci();local focus=type(foci)=='table' and foci[1]
    return not focus or focus==WorldFrame or captureFrame(focus) or self:PassiveTerrainFocus(focus) or self:BelowCapture(focus)
end
function trial:ShouldHideTooltip()
    if not self.saved or self.stopping or not GameTooltip then return false end
    if NS.TerrainMarkers and NS.TerrainMarkers.IsRestedXPHoverOwner
        and NS.TerrainMarkers:IsRestedXPHoverOwner(GameTooltip:GetOwner()) then return false end
    return self.minimapTooltip or captureFrame(GameTooltip:GetOwner())
        -- Idle stops reads, but leaves the hidden capture minimap under the
        -- cursor. Its unmarked/Questie-augmented tooltip still belongs to us.
        or (self.placed or self.discoveryIdle) and not self.normalTooltip and self:WorldCaptureFocus()
end
-- Native FadeOut changes alpha inside the engine, bypassing Lua setter
-- hooks. A hidden parent keeps capture artwork invisible through that fade.
function trial:ParkCaptureTooltip(tooltip,hide)
    if not inspectable(tooltip) or not tooltip.SetParent or not tooltip.IsVisible then return end
    if combat() and read(tooltip,'IsProtected')==true then return end
    local host=self.tooltipParkHost
    local parent=read(tooltip,'GetParent')
    if self.tooltipParked and parent~=host then
        -- Another controller took ownership; never restore our stale parent.
        self.tooltipParked=nil;self.tooltipOriginalParent=nil;self.tooltipOriginalStrata=nil
    end
    if hide then
        if host==nil then
            host=CreateFrame('Frame',nil,UIParent)
            if not host.Hide then self.tooltipParkHost=false;return end
            host:Hide();self.tooltipParkHost=host
        end
        if not host or self.tooltipParked or read(tooltip,'IsProtected')==true then return end
        self.tooltipOriginalParent=parent
        self.tooltipOriginalStrata=read(tooltip,'GetFrameStrata')
        self.tooltipParked=true
        tooltip:SetParent(host)
    elseif self.tooltipParked then
        local original=self.tooltipOriginalParent or UIParent
        local strata=self.tooltipOriginalStrata
        self.tooltipParked=nil;self.tooltipOriginalParent=nil;self.tooltipOriginalStrata=nil
        tooltip:SetParent(original)
        if tooltip.SetFrameStrata then tooltip:SetFrameStrata(type(strata)=='string' and strata or 'TOOLTIP') end
    end
end
-- Questie's waypoint hover deliberately uses a second tooltip, not
-- GameTooltip. Scope suppression to that exact frame and minimap owner.
function trial:UpdateQuestieWaypointTooltip()
    if self.questieTooltipWriting then return end
    local tip=_G.QuestieWaypointMinimapTooltip
    if not tip or not inspectable(tip) then return end
    if self.questieTooltipFrame~=tip then
        self.questieTooltipFrame=tip;self.questieTooltipState={}
        if hooksecurefunc and tip.HookScript then
            tip:HookScript('OnShow',function()self:UpdateQuestieWaypointTooltip()end)
            if tip.SetOwner then hooksecurefunc(tip,'SetOwner',function()self:UpdateQuestieWaypointTooltip()end)end
        end
    end
    local state=self.questieTooltipState
    local minimapOwner=captureFrame(read(tip,'GetOwner'))
    local hide=self.saved and not self.stopping and (self.placed or self.discoveryIdle) and minimapOwner
    self.questieTooltipWriting=true
    local ok,err=pcall(function()
        -- Close obsolete capture content before restoring its visible parent.
        if not hide and state.tooltipParked and minimapOwner and tip.Hide then tip:Hide()end
        self.ParkCaptureTooltip(state,tip,hide)
    end)
    self.questieTooltipWriting=nil
    if not ok then self.questieTooltipError=tostring(err):gsub('[\r\n]',' '):sub(1,160)end
end
function trial:InstallQuestieWaypointTooltipHook(now)
    if self.questieTooltipModuleHook or now<(self.nextQuestieTooltipHook or 0) then return end
    self.nextQuestieTooltipHook=now+1
    if not hooksecurefunc or type(QuestieLoader)~='table' or type(QuestieLoader.ImportModule)~='function' then return end
    local ok,module=pcall(QuestieLoader.ImportModule,QuestieLoader,'MapIconTooltip')
    if not ok or type(module)~='table' or type(module.ShowOnTooltip)~='function' then return end
    self.questieTooltipModuleHook=true
    -- The tooltip is created lazily. This post-hook covers its very first
    -- Show in the same Lua call, before it can render a first-frame flash.
    hooksecurefunc(module,'ShowOnTooltip',function(_,tip)
        if tip==_G.QuestieWaypointMinimapTooltip then self:UpdateQuestieWaypointTooltip()end
    end)
end
function trial:UpdateTooltip()
    self:UpdateQuestieWaypointTooltip()
    local tooltip=GameTooltip
    if not tooltip or self.tooltipWriting or not tooltip.GetOwner then return end
    local hide=self:ShouldHideTooltip()
    self.tooltipWriting=true
    local ok,err=pcall(self.ParkCaptureTooltip,self,tooltip,hide)
    self.tooltipWriting=nil
    if not ok then self.tooltipParkError=tostring(err):gsub('[\r\n]',' '):sub(1,160) end
    if hide then
        if self.tooltipAlpha==nil then self.tooltipAlpha=tooltip:GetAlpha() end
        if tooltip:GetAlpha()~=0 then
            self.tooltipWriting=true;tooltip:SetAlpha(0);self.tooltipWriting=nil
        end
    elseif self.tooltipAlpha~=nil then
        local alpha=self.tooltipAlpha;self.tooltipAlpha=nil
        self.tooltipWriting=true;tooltip:SetAlpha(alpha);self.tooltipWriting=nil
    end
end
function trial:MarkTooltipSource(minimap)
    self.minimapTooltip=minimap or nil
    if minimap then self.normalTooltip=nil end
    self:UpdateTooltip()
end
-- Modern clients rebuild already-shown tooltips through typed data callbacks,
-- without necessarily calling the legacy setters or OnShow again.
function trial:TooltipDataSource(tooltip,kind)
    if tooltip~=GameTooltip then return end
    local types=Enum and Enum.TooltipDataType
    if not types or not publicNumber(kind) then return end
    self.tooltipDataType=kind
    if types.MinimapMouseover~=nil and kind==types.MinimapMouseover then
        self.tooltipSource='native minimap data';self:MarkTooltipSource(true)
    elseif kind==types.Unit or kind==types.Item or kind==types.Spell or kind==types.Object then
        self.tooltipSource='ordinary typed data'
        self.normalTooltip=true;self:MarkTooltipSource(false)
    end
end
function trial:InstallTooltipDataHooks()
    if self.tooltipDataHooks or not TooltipDataProcessor or not TooltipDataProcessor.AddTooltipPostCall then return end
    local types=Enum and Enum.TooltipDataType
    if not types then return end
    self.tooltipDataHooks=true
    for _,name in ipairs({'MinimapMouseover','Unit','Item','Spell','Object'})do
        local kind=types[name]
        if publicNumber(kind) then
            TooltipDataProcessor.AddTooltipPostCall(kind,function(tooltip)
                trial:TooltipDataSource(tooltip,kind)
            end)
        end
    end
end
function trial:InstallTooltipHooks()
    self:InstallQuestieWaypointTooltipHook(GetTime())
    self:InstallTooltipDataHooks()
    if self.tooltipHooks or not GameTooltip or not hooksecurefunc then return end
    self.tooltipHooks=true
    hooksecurefunc(GameTooltip,'SetOwner',function()trial.normalTooltip=nil;trial:MarkTooltipSource(false)end)
    if GameTooltip.ClearLines then hooksecurefunc(GameTooltip,'ClearLines',function()trial:MarkTooltipSource(false)end) end
    if GameTooltip.SetMinimapMouseover then
        hooksecurefunc(GameTooltip,'SetMinimapMouseover',function()trial:MarkTooltipSource(true)end)
    end
    -- Real world/item tooltips take priority over the moving capture surface.
    for _,method in ipairs({'SetUnit','SetHyperlink','SetBagItem','SetInventoryItem'}) do
        if GameTooltip[method] then
            hooksecurefunc(GameTooltip,method,function()
                trial.normalTooltip=true
                trial:MarkTooltipSource(false)
            end)
        end
    end
    GameTooltip:HookScript('OnHide',function()
        if trial.tooltipWriting then return end
        trial.normalTooltip=nil
        trial:MarkTooltipSource(false)
    end)
    hooksecurefunc(GameTooltip,'SetAlpha',function()trial:UpdateTooltip()end)
    GameTooltip:HookScript('OnShow',function()trial:UpdateTooltip()end)
    GameTooltip:HookScript('OnUpdate',function()trial:UpdateTooltip()end)
end
function trial:RestoreMap(paused,retainCaptureGeometry,reason)
    if not self.map or combat() then return end
    local s=self.map
    NS._keepingMinimapInHUD=true
    local ok,err=pcall(function()
        Minimap:SetParent(s.parent); Minimap:SetSize(s.width,s.height)
        local scale=retainCaptureGeometry and self.size/s.width/s.parent:GetEffectiveScale() or s.scale
        Minimap:SetScale(scale)
        Minimap:ClearAllPoints()
        for _,p in ipairs(s.points) do Minimap:SetPoint(unpack(p)) end
        Minimap:SetAlpha(paused and 0 or s.alpha)
        if self.iconScale and Minimap.SetIconScale then Minimap:SetIconScale((paused or NS.MinimapScanActive) and HIDDEN_ICON_SCALE or self.iconScale) end
    end)
    NS._keepingMinimapInHUD=nil
    if not ok then error(err) end
    self.lastMapRestore={at=GetTime(),reason=reason or (paused and "paused restore" or "stop"),
        sample=self:CaptureGeometrySample(),retained=retainCaptureGeometry==true}
    if paused then self:RefreshCaptureInput() end
end
function trial:PreserveHUDAppearance()
    if not self.saved then return end
    -- Session tracking controls must survive hover Stop/Start and logout restoration.
    self.saved.trackingSwapsPaused=NS.db.hud.trackingSwapsPaused
    self.saved.pausedTrackingSpell=NS.db.hud.pausedTrackingSpell
    self.saved.showScanStatus=NS.db.hud.showScanStatus
    for _,key in ipairs({'size','x','y','rotationMode','overlayStrata','overlayLevel',
        'positionStyle','positionSize','positionOpacity','positionColor','nodeIconSize','nodeIconOpacity','experimentalHUD','mapAlpha','experimentalTerrain','autoTrackingWithHUD','autoTracking'})do
        self.saved[key]=NS.db.hud[key]
    end
end
function trial:Stop(reason)
    self.nextContinuousQuery=nil
    NS.CursorSweepReady=false
    if self.saved and self.workflow:Allows('knownOnly') then
        local layout=self.placed and self:MeasureLayout()
        self:Trace('quick stop',tostring(reason or self.quickStopReason or 'external stop request')
            ..'; placements='..tostring(self.moves or 0)..'; probes='..tostring(self.knownProbes or 0)
            ..'; accepted='..tostring(self.confirmedProbes or 0)..'; gate='..tostring(self.captureGate or 'not sampled')
            ..'; layout before restore='..(layout and string.format('%.1fpx',layout) or 'not placed'))
    end
    if self.saved then self:Trace('stop','requested') end
    if self.CancelValidation then self:CancelValidation() end
    if not self.saved then return end
    if combat() then self.stopping=true; return end
    self:RestoreNearbyInteraction()
    if self.AbortRefinement then self:AbortRefinement("trial stopped") end
    self.pausedRefinements={};self.validationBatchActive=false;self.validationQueue=nil
    self:RestoreMinimapControls()
    local quick=NS.QuickScanner
    if NS.ReplacementMinimap and not (quick and quick.farmPass and quick.farmMap) then NS.ReplacementMinimap:Stop() end
    self:RestoreMap()
    self:QuestAreas(false)
    if self.keep then NS.KeepMinimapInHUD=self.keep end
    NS.CursorSweepActive=nil; NS.CursorSweepReady=nil
    self:PreserveHUDAppearance()
    local saved=self.saved
    self.saved=nil; self.stopping=nil; self.map=nil; self.placed=nil
    self.hudQuickPass=nil;self.hudQuickRestorePending=nil
    if NS.QuickScanner then
        if not self.hudQuickReturning then NS.QuickScanner.hudEnabled=nil end
        if NS.QuickScanner.pending and NS.QuickScanner.pending.hud then NS.QuickScanner.pending=nil end
    end
    self.hudQuickReturning=nil
    self:UpdateTooltip()
    for k in pairs(NS.db.hud) do NS.db.hud[k]=nil end
    for k,v in pairs(saved) do NS.db.hud[k]=v end
    -- SetHUDEnabled compares the current flag before restoring geometry.
    self.presentation:Finish(saved)
    self.presentation=nil
    self:RestoreNativeZoom(saved.enabled)
    NS:SetManualNodeHoverEnabled(true)
    NS:UpdateRememberedNodes()
    if NS.RestoreCursorMinimapPins then NS:RestoreCursorMinimapPins() end
    if NS.RefreshExperimentalNodeScanControl then NS:RefreshExperimentalNodeScanControl() end
    if NS.ReplacementMinimapHover then NS.ReplacementMinimapHover:OnScannerStopped()
    else say('stopped; original HUD and minimap preferences restored.') end
    if NS.QuickScanner and NS.QuickScanner.RefreshHUDMinimap then NS.QuickScanner:RefreshHUDMinimap() end
end
-- Scheduling hints only: these views never authorize absence or history writes.
function trial:DiscoveryView()
    local c=NS.GetGatheringNodeContext and NS:GetGatheringNodeContext()
    if not c then return end
    local v={}
    for _,key in ipairs({'map','x','y','w','h','radius','width','scale','cos','sin','iconScale'})do
        local n=c[key]
        if not publicNumber(n) or math.abs(n)==math.huge then return end
        v[key]=n
    end
    if v.w<=0 or v.h<=0 or v.radius<=0 or v.width<=0 or v.scale<=0 or v.iconScale<=0 then return end
    v.size=self.discoverySize or self.size
    if not publicNumber(v.size) or v.size<=0 or math.abs(v.size)==math.huge then return end
    return v
end
local function compatibleDiscovery(a,b)
    if not a or not b or a.map~=b.map then return false end
    for _,key in ipairs({'w','h','radius','width','scale','cos','sin','iconScale','size'})do
        if math.abs(a[key]-b[key])>0.00001 then return false end
    end
    return true
end
local function discoveryTravel(a,b)
    return math.sqrt(((a.x-b.x)*b.w)^2+((a.y-b.y)*b.h)^2)
end
function trial:SampleDiscoveryView()
    local c=self:DiscoveryView()
    local a=self.passView
    if not compatibleDiscovery(a,c) then self.passStable=false
    elseif self.passLastView then
        self.passTravel=(self.passTravel or 0)+discoveryTravel(c,self.passLastView)
        if self.passTravel>c.radius/(c.width*c.scale) then self.passStable=false end
    end
    self.passLastView=c
    return c
end
function trial:CompleteDiscoveryVisit()
    local c=self:SampleDiscoveryView()
    if self.coveredCount~=#self.spots or not compatibleDiscovery(self.passView,c) then return end
    local kind=self.scanKind
    if kind~='herb' and kind~='ore' and kind~='treasure' then return end
    self.discoveryVisits=self.discoveryVisits or {}
    self.discoveryVisits[kind]={view=c,at=GetTime(),stable=self.passStable==true}
end
function trial:DiscoveryIdle(now,busy)
    local c=self:DiscoveryView()
    local visit=self.discoveryVisits and self.discoveryVisits[self.scanKind]
    local idle=not busy and visit and visit.stable and compatibleDiscovery(visit.view,c)
        and now>=visit.at and now<visit.at+3
        and discoveryTravel(c,visit.view)<=c.radius/(c.width*c.scale)
    if visit and (not compatibleDiscovery(visit.view,c) or c and discoveryTravel(c,visit.view)>c.radius/(c.width*c.scale)) then
        visit.stable=false
    end
    if idle then
        if not self.discoveryIdle then
            -- Replay this unfinished placement on wake; never reuse its answer.
            if not self.knownTarget then self.index=math.max(0,self.index-1) end
            self.knownTarget=nil;self.discoveryPlacementIndex=nil
            self.discoveryIdle=true
        end
        self.placed=nil;self.captureAt=nil;self.at=nil;self.discoveryAnswer=nil
        NS.CursorSweepReady=false;self.reason='idle discovery; refresh within 3s'
        return true
    end
    self.discoveryIdle=nil
    return false
end
function trial:WakeDiscovery()
    if self.discoveryVisits then
        for _,visit in pairs(self.discoveryVisits)do visit.stable=false end
    end
end
-- Each completed pass moves the interior grid onto different gaps. Only a
-- fresh, independently centred footprint may reduce the discovery spacing.
function trial:BuildDiscoveryPattern()
    self.spots={}
    -- Staggered rows cover native hit areas with fewer redundant reads.
    local step=math.max(2,math.min(20,14*(self.iconScale or 1)))
    if #self.dotDiameters>=3 then
        local smallest=math.huge
        for _,diameter in ipairs(self.dotDiameters)do smallest=math.min(smallest,diameter)end
        self.smallestDiscoveryDiameter=math.min(self.smallestDiscoveryDiameter or smallest,smallest)
        step=math.max(2,math.min(step,self.smallestDiscoveryDiameter*.80*(self.iconScale or 1)))
    end
    self.discoveryStep=step
    local limit=(self.discoverySize or self.size)/2-4
    local rowGap=step*math.sqrt(3)/2
    local rows=math.ceil(limit/rowGap)
    local phase=self.scanPhase or 0
    local shiftX=phase==1 and step/2 or 0
    local shiftY=phase*rowGap/3
    for row=-rows,rows do
        local y=row*rowGap+shiftY
        for column=-math.ceil(limit/step),math.ceil(limit/step) do
            local x=column*step+(row%2)*step/2+shiftX
            if x*x+y*y<=limit*limit then self.spots[#self.spots+1]={x,y} end
        end
    end
    -- Explicit edge ring avoids gaps where the circular viewport cuts a row.
    local count=math.ceil(2*math.pi*limit/step)
    for i=1,count do
        local angle=2*math.pi*i/count
        self.spots[#self.spots+1]={limit*math.cos(angle),limit*math.sin(angle)}
    end
    local raster=self.spots
    local current=self:DiscoveryView()
    local visit=self.discoveryVisits and self.discoveryVisits[self.scanKind]
    self.terrainPriorityPoints=0
    if visit and compatibleDiscovery(visit.view,current) then
        local old=visit.view
        local entering,interior={},{}
        local unit=2*current.radius/(current.width*current.scale)
        local limit=(old.size/2-4-step/2)*unit
        for _,point in ipairs(raster)do
            local e=(current.x-old.x)*current.w+(point[1]*current.cos-point[2]*current.sin)*unit
            local n=(old.y-current.y)*current.h+(point[1]*current.sin+point[2]*current.cos)*unit
            local list=e*e+n*n>limit*limit and entering or interior
            list[#list+1]=point
        end
        raster={}
        for _,point in ipairs(entering)do raster[#raster+1]=point end
        for _,point in ipairs(interior)do raster[#raster+1]=point end
        self.terrainPriorityPoints=#entering
    end
    self.priorityView=current;self.terrainPromoted=false
    self.passView=current;self.passLastView=current;self.passTravel=0;self.passStable=current~=nil
    self.rasterPointCount=#raster;self.spots={}
    local unit=4*(self.iconScale or 1)
    local near={{0,0},{unit,0},{0,unit},{-unit,0},{0,-unit},
        {unit,unit},{-unit,unit},{-unit,-unit},{unit,-unit},
        {2*unit,0},{0,2*unit},{-2*unit,0},{0,-2*unit}}
    local nearby=1
    for i,point in ipairs(raster)do
        if (i-1)%4==0 then
            local p=near[nearby]
            self.spots[#self.spots+1]={p[1],p[2],close=true}
            nearby=nearby%#near+1
        end
        self.spots[#self.spots+1]=point
    end
    self.coveredPoints={};self.coveredCount=0;self.discoveryAttempts={};self.deferredPoints=0
end
function trial:PromoteEnteringTerrain()
    if self.terrainPromoted or not self.priorityView then return end
    local c=self:DiscoveryView()
    local visit=self.discoveryVisits and self.discoveryVisits[self.scanKind]
    if not visit or not compatibleDiscovery(visit.view,c) or not compatibleDiscovery(self.priorityView,c) then return end
    local unit=2*c.radius/(c.width*c.scale)
    if discoveryTravel(c,self.priorityView)<self.discoveryStep*unit then return end
    -- One stable partition of the remaining raster per pass. Near-player
    -- slots stay fixed; every interior point still gets its turn this pass.
    local front,back,slots={},{},{}
    local old=visit.view
    local limit=math.max(0,old.size/2-4-self.discoveryStep/2)*unit
    for i=self.index+1,#self.spots do
        local p=self.spots[i]
        if not p.close then
            local e=(c.x-old.x)*c.w+(p[1]*c.cos-p[2]*c.sin)*unit
            local n=(old.y-c.y)*c.h+(p[1]*c.sin+p[2]*c.cos)*unit
            local list=e*e+n*n>limit*limit and front or back
            list[#list+1]={point=p,covered=self.coveredPoints[i],attempts=self.discoveryAttempts[i]}
            slots[#slots+1]=i
        end
    end
    for j,i in ipairs(slots)do
        local entry=j<=#front and front[j] or back[j-#front]
        self.spots[i],self.coveredPoints[i],self.discoveryAttempts[i]=entry.point,entry.covered,entry.attempts
    end
    self.terrainPromoted=true;self.terrainPriorityPoints=#front
end
function trial:LearnDiscoveryFootprint(group,ctx)
    if not group.hitbox or not publicNumber(group.hitbox.radius) or not ctx.iconScale or ctx.iconScale<=0 then return end
    local diameter=2*group.hitbox.radius/(2*ctx.radius/(ctx.width*ctx.scale))/ctx.iconScale
    if not publicNumber(diameter) or diameter<3 or diameter>80 then return end
    self.dotDiameters=self.dotDiameters or {}
    self.dotDiameters[#self.dotDiameters+1]=diameter
    if #self.dotDiameters>16 then table.remove(self.dotDiameters,1) end
end
-- Database coordinates only schedule real native reads. No cache/history writes.
function trial:KnownLocationOffset(target,c)
    if not target or not c or target.map~=c.map or target.kind~=self.scanKind then return end
    for _,key in ipairs({'x','y','w','h','radius','width','scale','cos','sin'})do
        if not publicNumber(c[key])then return end
    end
    if c.w<=0 or c.h<=0 or c.radius<=0 or c.width<=0 or c.scale<=0 then return end
    local e,n=(target.x-c.x)*c.w,(c.y-target.y)*c.h
    local pixel=2*c.radius/(c.width*c.scale)
    local x,y=(e*c.cos+n*c.sin)/pixel,(n*c.cos-e*c.sin)/pixel
    local limit=(self.discoverySize or 0)/2-4
    if limit<=0 or x*x+y*y>limit*limit then return end
    return {x,y},e*e+n*n
end
function trial:RememberDeferredDiscovery(owner,resource,spot,c,now)
    if not resource.anonymous then return end
    self.deferredDiscoveries=self.deferredDiscoveries or {}
    local reach=2*2*c.radius/(c.width*c.scale)
    for _,entry in ipairs(self.deferredDiscoveries)do
        if entry.owner==owner and entry.map==c.map
            and ((entry.x-spot.x)*c.w)^2+((entry.y-spot.y)*c.h)^2<=reach^2 then
            entry.at=now;return
        end
    end
    if #self.deferredDiscoveries>=128 then return end
    self.deferredDiscoveries[#self.deferredDiscoveries+1]={owner=owner,map=c.map,kind=resource.kind,
        x=spot.x,y=spot.y,at=now,attempts=0}
end
function trial:ReleaseDeferredDiscoveries(node,c)
    for _,entry in ipairs(self.deferredDiscoveries or {})do
        if entry.owner==node and entry.map==c.map then entry.ready=true end
    end
end
function trial:NextDeferredDiscovery(now,c)
    local queue=self.deferredDiscoveries or {}
    for i=#queue,1,-1 do
        if now-queue[i].at>30 or queue[i].attempts>=2 then table.remove(queue,i) end
    end
    for _,entry in ipairs(queue)do
        if entry.ready and entry.kind==self.scanKind and now>=(entry.retryAt or 0) then
            local point=self:KnownLocationOffset(entry,c)
            if point then
                entry.attempts=entry.attempts+1;entry.retryAt=now+2
                self.knownStreak=(self.knownStreak or 0)+1
                self.knownProbes=(self.knownProbes or 0)+1
                self.knownLastPriority='deferred neighbour after refinement'
                if self.Trace then self:Trace('deferred neighbour recheck','fresh native probe; attempt='..entry.attempts) end
                return entry,point
            end
        end
    end
end
function trial:NextExpiringObservation(now,c)
    for _,node in ipairs(NS.GatheringNodeCache or {})do
        if node.cursorSweepObservation and node.map==c.map and node.kind==self.scanKind
            and publicNumber(node.seen) and now>=(node.expiryRecheckAt or 0) then
            local ttl=NS.GetGatheringObservationTTL and NS:GetGatheringObservationTTL(node) or node.observationTTL or 30
            if now-node.seen>=ttl-5 and now-node.seen<=ttl then
                local spot=node.manualRefined and node or node.manualLastHit or node
                if publicNumber(spot.x) and publicNumber(spot.y) then
                    local target={map=node.map,kind=node.kind,x=spot.x,y=spot.y}
                    local point=self:KnownLocationOffset(target,c)
                    if point then
                        node.expiryRecheckAt=now+2
                        self.knownStreak=(self.knownStreak or 0)+1
                        self.knownProbes=(self.knownProbes or 0)+1
                        self.knownLastPriority='live observation nearing expiry'
                        if self.Trace then self:Trace('expiry recheck','fresh native probe; kind='..node.kind) end
                        return target,point
                    end
                end
            end
        end
    end
end
local quickLocationIndexes=setmetatable({}, {__mode="k"})
-- Prepare only public historical coordinates while idle. This never captures
-- the minimap or treats a saved location as evidence of a live resource.
function trial:WarmQuickLocations()
    local c=NS.GetGatheringNodeContext and NS:GetGatheringNodeContext()
    if self.saved and (self.workflow~=NS.CursorScanWorkflows.hudQuick or self.hudQuickPass)
        or not c or not publicNumber(c.map) or not NS.NewNodeLocationIndex then return end
    local imported=NS.GetImportedNodeLocations and NS:GetImportedNodeLocations(c.map)
    local sources={NS.db and NS.db.nodeLocations or {},NS.BundledNodeLocations or {},imported or {},
        NS.db and NS.db.refinedNodeHints or {},NS.BundledRefinedNodeHints or {}}
    for _,source in ipairs(sources) do
        local rows=source.version==1 and source.maps and source.maps[c.map]
        if type(rows)=='table' then
            local index=quickLocationIndexes[rows]
            if not index then index=NS:NewNodeLocationIndex(rows);quickLocationIndexes[rows]=index end
            if not index:Ready() then index:Build(128);return end
        end
    end
end
-- History only schedules native reads. Try saved centres first, then at most
-- four nearby samples for each centre that actually returned public empty.
local function takeQuickLocation(scan,context,queue)
    queue=queue or scan.quickQueue
    local best,bestPoint,bestDistance
    -- Each ready batch is bounded to128. Database/bucket insertion order
    -- must not spend the short pass on farther locations before nearer ones.
    for i,target in ipairs(queue) do
        local point,distance=scan:KnownLocationOffset(target,context)
        if point and not (target.quickOrigin and target.quickOrigin.quickHit) then
            if not best or distance<bestDistance then best,bestPoint,bestDistance=i,point,distance end
        end
    end
    if best then
        local target=table.remove(queue,best)
        scan.knownProbes=(scan.knownProbes or 0)+1
        scan:Trace('quick target',string.format('#%d %s map=%s xy=%.3f,%.3f %s distance=%.1fyd queued=%d',
            scan.knownProbes,tostring(target.kind),tostring(target.map),target.x*100,target.y*100,
            target.quickOrigin and 'nearby' or 'saved centre',math.sqrt(bestDistance),#queue))
        return target,bestPoint
    end
    for i=#queue,1,-1 do queue[i]=nil end
end
function trial:QueueQuickNearby(c)
    local target=self.knownTarget
    if not self.workflow:Allows('knownOnly') or not target or target.quickOrigin or target.quickOffsetsQueued
        or not c or c.map~=target.map or not publicNumber(c.w) or not publicNumber(c.h) or c.w<=0 or c.h<=0 then return end
    target.quickOffsetsQueued=true
    self.quickNearby=self.quickNearby or {}
    -- World-yard offsets remain consistent across zones, zoom and UI scale.
    -- Four diagonals reach 28 yards from the saved centre; never a full raster.
    for _,offset in ipairs({{-20,-20},{20,-20},{-20,20},{20,20}}) do
        if #self.quickNearby>=128 then break end
        local probe={map=target.map,kind=target.kind,x=target.x+offset[1]/c.w,
            y=target.y+offset[2]/c.h,quickOrigin=target}
        if probe.x>=0 and probe.x<=1 and probe.y>=0 and probe.y<=1 and self:KnownLocationOffset(probe,c) then
            self.quickNearby[#self.quickNearby+1]=probe
        end
    end
end
local function queueQuickLocation(scan,row,c)
    if row and row.kind==scan.scanKind and publicNumber(row.x) and publicNumber(row.y) then
        local key=row.kind..':'..tostring(row.x)..':'..tostring(row.y)
        local target={map=c.map,kind=row.kind,x=row.x,y=row.y}
        if not scan.quickSeen[key] and scan:KnownLocationOffset(target,c) and #scan.quickQueue<128 then
            scan.quickSeen[key]=true
            scan.quickQueue[#scan.quickQueue+1]=target
        end
    end
end
function trial:NextQuickLocation()
    if self.nextContinuousQuery and GetTime()<self.nextContinuousQuery then return nil,nil,true end
    self.nextContinuousQuery=nil
    local c=NS.GetGatheringNodeContext and NS:GetGatheringNodeContext()
    if not c or not NS.NewNodeLocationIndex then return end
    for _,key in ipairs({'map','x','y','w','h','radius'}) do
        if not publicNumber(c[key]) or math.abs(c[key])==math.huge then return end
    end
    if c.w<=0 or c.h<=0 or c.radius<=0 then return end
    if not self.quickQueue then
        local imported=NS.GetImportedNodeLocations and NS:GetImportedNodeLocations(c.map)
        self.quickSources={NS.db and NS.db.nodeLocations or {},NS.BundledNodeLocations or {},imported or {},
        NS.db and NS.db.refinedNodeHints or {},NS.BundledRefinedNodeHints or {}}
        self.quickQueue={};self.quickSeen={};self.quickIndexes={};self.quickQueries={};self.quickDone={};self.quickSource=1;self.quickMap=c.map
    end
    if c.map~=self.quickMap then return end
    self.quickQueries=self.quickQueries or {}
    self.quickDone=self.quickDone or {}
    local buildBudget,queryBudget,pending=128,128,false
    -- Merge ready sources before choosing a target. An unbuilt later source
    -- may not block already queued probes or other ready source queries.
    for slot,source in ipairs(self.quickSources) do
        if not self.quickDone[slot] then
            local rows=source.version==1 and source.maps and source.maps[c.map]
            if type(rows)~='table' then self.quickDone[slot]=true
            else
                local index=self.quickIndexes[slot] or quickLocationIndexes[rows]
                if (not index or not index:Ready()) and #self.quickQueue>0 then
                    pending=true
                else
                    if not index then index=NS:NewNodeLocationIndex(rows);quickLocationIndexes[rows]=index end
                    self.quickIndexes[slot]=index
                    local built=index.built
                    local ready=index:Build(buildBudget)
                    buildBudget=buildBudget-math.max(0,index.built-built)
                    if not ready then
                        for i=built+1,index.built do queueQuickLocation(self,rows[i],c) end
                        pending=true
                    else
                        local query=self.quickQueries[slot] or index:Query(c.x,c.y,2*c.radius/c.w,2*c.radius/c.h)
                        self.quickQueries[slot]=query
                        while queryBudget>0 do
                            queryBudget=queryBudget-1
                            local row,done=index:Next(query)
                            queueQuickLocation(self,row,c)
                            if done then self.quickDone[slot]=true;self.quickQueries[slot]=nil;break end
                        end
                        if not self.quickDone[slot] then pending=true end
                    end
                end
            end
        end
    end
    local target,point=takeQuickLocation(self,c)
    if target then return target,point end
    if pending then return nil,nil,true end
    if self.quickNearby then return takeQuickLocation(self,c,self.quickNearby) end
end
function trial:NextKnownLocation(now)
    if self.workflow:Allows('knownOnly') then return self:NextQuickLocation() end
    if not self.workflow:Allows('knownLocations') then return end
    if self.validationBatchActive or self.nodeValidation or type(self.scanKind)~='string' then return end
    if not NS.GetGatheringNodeContext or not NS.NewNodeLocationIndex then return end
    local c=NS:GetGatheringNodeContext()
    if not c or not publicNumber(c.map) or not publicNumber(c.x) or not publicNumber(c.y)
        or not publicNumber(c.w) or not publicNumber(c.h) or c.w<=0 or c.h<=0
        or not publicNumber(c.radius) or c.radius<=0 then return end
    if self.knownMap~=c.map then
        self.knownMap=c.map;self.knownIndexes={};self.knownCooldowns={};self.knownStreak=0
        self.knownViews={};self.knownEntered={};self.knownVisible={}
    end
    if not self.workflow:CanProbeKnown(self.knownStreak) then self.knownStreak=0;return end
    local expiring,expiryPoint=self:NextExpiringObservation(now,c)
    if expiring then return expiring,expiryPoint end
    local deferred,point=self:NextDeferredDiscovery(now,c)
    if deferred then return deferred,point end
    -- Keep a separate last viewport per tracker. Movement while ore is active
    -- must also reveal newly entered herb locations when herbs return.
    local previous=self.knownViews[self.scanKind]
    local view={}
    for _,key in ipairs({'map','x','y','w','h','radius','width','scale','cos','sin'})do view[key]=c[key] end
    self.knownViews[self.scanKind]=view
    local imported=NS.GetImportedNodeLocations and NS:GetImportedNodeLocations(c.map)
    local sources={NS.db and NS.db.nodeLocations or {},NS.BundledNodeLocations or {},imported or {},
        NS.db and NS.db.anonymousRefinedNodeHints or {}}
    local best,bestDistance,bestKey,bestRank
    for slot,source in ipairs(sources)do
        local rows=source.version==1 and source.maps and source.maps[c.map]
        if type(rows)=='table' then
            local index=self.knownIndexes[slot]
            if not index or index.rows~=rows then index=NS:NewNodeLocationIndex(rows);self.knownIndexes[slot]=index end
            index:Build(128)
            -- Queries also have a hard budget; continue dense neighborhoods on
            -- later turns instead of blocking a frame or the fallback sweep.
            local q=index.knownQuery
            if not q or q.radius~=c.radius or q.w~=c.w or q.h~=c.h
                or ((q.cx-c.x)*c.w)^2+((q.cy-c.y)*c.h)^2>(c.radius/2)^2 then
                q=index:Query(c.x,c.y,2*c.radius/c.w,2*c.radius/c.h)
                q.cx,q.cy,q.radius,q.w,q.h=c.x,c.y,c.radius,c.w,c.h;index.knownQuery=q
            end
            for _=1,128 do
                local row,done=index:Next(q)
                if done then index.knownQuery=nil;break end
                if row and row.kind==self.scanKind and publicNumber(row.x) and publicNumber(row.y) then
                    local key=row.kind..':'..tostring(row.x)..':'..tostring(row.y)
                    local target={x=row.x,y=row.y,map=c.map,kind=row.kind}
                    local point,d=self:KnownLocationOffset(target,c)
                    if point then
                        if self.knownVisible[key]==false
                            or previous and not self:KnownLocationOffset(target,previous) then
                            self.knownEntered[key]=true
                        end
                        self.knownVisible[key]=true
                        if now>=(self.knownCooldowns[key] or 0)then
                            -- Entering the view wins over untouched older
                            -- coordinates, which win over five-second retries.
                            local rank=self.knownEntered[key] and 0 or not self.knownCooldowns[key] and 1 or 2
                            -- Personal refined generic centres should get a
                            -- fresh check before the larger named/history set.
                            -- Retries retain normal cooldown/rank and the grid
                            -- still owns every third discovery turn.
                            if slot==4 and row.anonymous==true and not self.knownCooldowns[key] then rank=-1 end
                            if not bestRank or rank<bestRank or rank==bestRank and d<bestDistance then
                                best,bestDistance,bestKey,bestRank=target,d,key,rank
                            end
                        end
                    else
                        self.knownVisible[key]=false;self.knownEntered[key]=nil
                    end
                end
            end
        else self.knownIndexes[slot]=nil end
    end
    if best then
        self.knownEntered[bestKey]=nil
        self.knownLastPriority=bestRank==-1 and "saved generic refined centre" or bestRank==0 and "newly entered" or bestRank==1 and "unchecked coordinate" or "coordinate retry"
        self.knownCooldowns[bestKey]=now+5
        self.knownStreak=(self.knownStreak or 0)+1
        self.knownProbes=(self.knownProbes or 0)+1
        return best,self:KnownLocationOffset(best,c)
    end
    self.knownStreak=0
end
function trial:AdvanceBackgroundDiscovery(now)
    self:FinishDiscoveryPoint()
    self.knownTarget=nil
    self.knownTarget=self:NextKnownLocation(now)
    if not self.knownTarget then self:AdvanceDiscovery() end
    self.backgroundDiscoverySerial=(self.backgroundDiscoverySerial or 0)+1
end
function trial:UpdateDiscoveryCompletion()
    local deferred=0
    for i=1,#self.spots do
        if not self.coveredPoints[i] then
            if (self.discoveryAttempts[i] or 0)<2 then self.deferredPoints=deferred;return false end
            deferred=deferred+1
        end
    end
    self.deferredPoints=deferred;self.lastDeferredPoints=deferred;self.passReady=true
    return true
end
function trial:FinishDiscoveryPoint()
    -- Only an actually held discovery point can spend a read attempt. Two
    -- full dwell budgets without usable confirmation defer it for this visit;
    -- they never count as public empty or authorize deleting a marked node.
    if not self.knownTarget and self.index>0 and self.discoveryPlacementIndex==self.index and self.placed and self.at and GetTime()-self.at>=self.workflow:Dwell()-0.000001
        and not self.coveredPoints[self.index] then
        self.discoveryAttempts[self.index]=(self.discoveryAttempts[self.index] or 0)+1
        self:TraceProbe('unconfirmed full dwell',GetTime())
    end
    self.discoveryPlacementIndex=nil
end
function trial:AdvanceDiscovery()
    self:FinishDiscoveryPoint()
    if self.index>=#self.spots then
        self:Trace('pass end',string.format('%s coverage=%d/%d phase=%d',tostring(self.scanKind),self.coveredCount or 0,#self.spots,self.scanPhase or 0))
        self.completedPasses=(self.completedPasses or 0)+1
        if self:UpdateDiscoveryCompletion() then
            self:CompleteDiscoveryVisit()
            self.scanPhase=((self.scanPhase or 0)+1)%3;self:BuildDiscoveryPattern()
        end
        self.index=0
    end
    self:PromoteEnteringTerrain()
    self.index=self.index+1
end
function trial:SwapBudgetExpired()
    return self.workflow:BudgetExpired(self,GetTime())
end
function NS:IsCursorSweepSwapReady()
    if trial.workflow==NS.CursorScanWorkflows.hudQuick then return not trial.hudQuickPass end
    if not self.CursorSweepActive then return true end
    return trial.workflow:IsSwapReady(trial,GetTime())
end
function trial:Start()
    assert(not combat(),'start outside combat')
    if self.saved then say('already running; /fdgcursor stop restores normal layout.');return end
    assert(NS.db and NS.db.hud and NS.ManualNodeHoverSourceReady,'physical Remember nodes required')
    self.presentation=NS.ScanPresentations[NS.MinimapScanActive and "minimap" or "hud"]
    self.saved=copy(NS.db.hud)
    self.lastRefinementStop=nil
    self.lastMapRestore=nil;self.lastPause=nil;self.pauseCounts={}
    self.traceBuffers={};self.traceOrigin=GetTime();self.traceLastPause=nil;self.traceLastLabel=nil
    self:Trace('start','build66; discovery timing + resource/refinement decisions')
    self.trackingCursors={};self.scanKind=nil;self.trackingChanges=0;self.pausedRefinements={};self.resumedRefinements=0
    self.nodeValidation=nil;self.nextNodeValidation=nil;self.validationKind=nil;self.missingRetired=0
    self.validationBatchActive=false;self.validationQueue=nil
    self.nativeCapture=true
    self.interiorReadRetries=0;self.interiorReadRecoveries=0
    self.refinementQueue={};self.refinementDiscoveryRemaining=nil;self.backgroundDiscoverySerial=0
    self.deferredDiscoveries={}
    self.approachSample=nil;self.approachMotion=nil;self.nextApproachPreempt=nil;self.refinementPriority=nil
    self.quickQueue=nil;self.quickSource=nil;self.quickSeen=nil;self.quickQuery=nil;self.quickIndexes=nil
    self.quickNearby=nil;self.nextContinuousQuery=nil
    self.hudQuickPass=nil;self.hudQuickRestorePending=nil
    self.quickDeadline=self.workflow:Allows("knownOnly") and GetTime()+(NS.GetQuickScanDuration and NS:GetQuickScanDuration() or 1.5) or nil
    self.quickRepairAt=nil;self.quickLayoutConflict=nil
    -- FarmRoute: forget the last scan's placement. Left set, the first layout
    -- check of this scan (before anything is placed) compared the map with
    -- the old spot and cancelled every scan after the first.
    self.expectedX,self.expectedY=nil,nil
    self.quickStopReason=nil;self.captureGate=nil;self.captureGateAt=nil;self.captureGateCount=0
    self.layoutWriterSeen=nil;self.layoutWriterCount=0;self.layoutMismatchLogged=nil
    self.knownMap=nil;self.knownTarget=nil;self.knownStreak=0;self.knownProbes=0
    self.appliedSize=nil;self.geometryRepairs=0;self.lastGeometryRepair=nil;self.geometryRepairSignature=nil;self.geometryRepairLoggedAt=nil;self.geometryRepairRepeats=0;self.nextOverlayCheck=nil;self.controlScan=nil;self.savedHintsReused=0
    self.activeSeconds=0;self.pauseSeconds={};self.timingLast=nil;self.visitActiveStart=nil;self.visitStartedAt=nil
    self.emptyProbes=0;self.nonresourceProbes=0;self.nearbyProbes=0
    self.discoveryConsumedAt=nil
    self.refineStatus='discovering native nodes';self.discoveryStatus='starting';self.confirmedProbes=0;self.positiveProbes=0
    self:QuestAreas(true)
    self.minimapTooltip=nil;self.normalTooltip=nil;self:InstallTooltipHooks();self:UpdateTooltip()
    local quick=NS.QuickScanner
    local farm=quick and quick.farmPass and quick.farmMap
    self.iconScale=farm and farm.iconScale or NS.GetNativeGatheringIconScale and NS:GetNativeGatheringIconScale() or NS._minimapIconScale or 1
    -- The selected presentation owns layout; sampling is shared.
    self.presentation:Prepare(self)
    self.nativeZoom=read(Minimap,'GetZoom')
    self.nativeZoomCVars={minimapZoom=softRead(GetCVar or C_CVar and C_CVar.GetCVar,'minimapZoom'),minimapInsideZoom=softRead(GetCVar or C_CVar and C_CVar.GetCVar,'minimapInsideZoom')}
    self.captureZoom=0
    self.size=Minimap:GetWidth()*Minimap:GetEffectiveScale()
    assert(publicNumber(self.size) and self.size>0,'native minimap size unavailable')
    self.discoverySize,self.refinementSize=self.size,self.size*(self.refineMultiplier or 1)
    NS.db.hud.rememberNodes=true
    if NS.ReplacementMinimap then NS.ReplacementMinimap:Start() end
    self.presentation:Begin(self)
    NS:SetManualNodeHoverEnabled(true)
    self.map=saveMap(); self.keep=NS.KeepMinimapInHUD
    NS.CursorSweepActive=true; NS.CursorSweepReady=false
    if not farm then self:EnableNearbyInteraction() end
    self.clientRotation=NS._minimapState and NS._minimapState.rotateMinimap
    self.presentation:Update(self)
    if not NS.MinimapScanActive and NS.UpdateHUDPositionIcon then NS:UpdateHUDPositionIcon();NS:UpdateHUDInteraction() end
    NS.KeepMinimapInHUD=function(core, ...)
        if not NS.CursorSweepActive then return trial.keep(core, ...) end
        if trial.placed and not trial:Blocked() then trial:RepairCaptureLayout() end
    end
    self.discoveryVisits={};self.discoveryIdle=nil
    self.scanStates={};self.scanPhase=0;self.dotDiameters={};self.smallestDiscoveryDiameter=nil;self.completedPasses=0;self.passReady=false;self.lastDeferredPoints=nil;self.discoveryPlacementIndex=nil
    -- Zoom repair may rebuild the pattern, so initialize discovery first.
    self:MaintainCaptureZoom()
    self:BuildDiscoveryPattern()
    self.steeringWasActive=nil;self.steeringPlaced=nil
    local freeX,freeY=GetCursorPosition()
    self.freeCursorX=publicNumber(freeX) and freeX or nil;self.freeCursorY=publicNumber(freeY) and freeY or nil
    if self.steeringTest then self:ResetSteeringStats() end
    self.nextFollow=nil;self.index=0; self.moves=0; self.placed=nil; self.reason='starting'
    if self.QueueRetainedObservations then self:QueueRetainedObservations(GetTime()) end
    if NS.ReplacementMinimap then NS.ReplacementMinimap:Update() end
    if self.workflow==NS.CursorScanWorkflows.hudQuick then self.hudQuickPass=true end
    if NS.ReplacementMinimapHover and not self.workflow:Allows("knownOnly") then NS.ReplacementMinimapHover:Arm(NS.MinimapScanActive and "minimap" or "hud") end
    if NS.UpdateAll then NS:UpdateAll() end
    if NS.RefreshExperimentalNodeScanControl then NS:RefreshExperimentalNodeScanControl() end
end
function trial:RefinementStopDiagnostic(now)
    local stop=self.lastRefinementStop
    if not stop then return 'last refinement stop=none' end
    return string.format('last refinement stop=%s; probes=%d; age=%.1fs; kind=%s',
        stop.reason,stop.reads,math.max(0,(now or GetTime())-stop.at),tostring(stop.kind))
end
function trial:PauseProgressDiagnostic(now)
    now=now or GetTime()
    local totals={}
    for reason,seconds in pairs(self.pauseSeconds or {}) do
        totals[#totals+1]=string.format('%s %.1fs/%d',reason,seconds,(self.pauseCounts or {})[reason] or 0)
    end
    table.sort(totals)
    local job=self.refinement or self.refinePending
    local last=self.lastPause
    return 'pause totals='..(#totals>0 and table.concat(totals,', ') or 'none')
        ..'; last='..(last and string.format('%s %.1fs ago',last.reason,math.max(0,now-last.at)) or 'none')
        ..'; current job='..(job and string.format('%s; probes=%d; phase=%s; progress age=%.1fs; discovery slice=%s',
            tostring(job.node and job.node.kind),job.reads or 0,tostring(job.phase or 'reacquisition'),
            math.max(0,now-(job.lastProgressAt or job.start or now)),tostring(self.refinementDiscovery==true)) or 'none')
end
function trial:SteeringActive()
    return self.steeringTest and IsMouseButtonDown and IsMouseButtonDown('RightButton') or false
end
function trial:ResetSteeringStats()
    self.steeringStats={reads=0,empty=0,nonempty=0,unknown=0,changes=0,resources=0}
    self.steeringLookup={};self.steeringLookupCount=0
    self.steeringSampleAt=nil
end
function trial:SteeringSample(now)
    if not self.steeringPlaced or not self.captureAt or now<self.captureAt or self.steeringSampleAt==self.at then return end
    self.steeringSampleAt=self.at
    local stats=self.steeringStats
    if not stats then self:ResetSteeringStats();stats=self.steeringStats end
    stats.reads=stats.reads+1
    local getter=C_TooltipInfo and C_TooltipInfo.GetMinimapMouseover
    local ok,data=pcall(function()return getter and getter()end)
    local function public(value)return not (issecretvalue and issecretvalue(value))end
    local labels={}
    local valid=ok and public(data) and type(data)=='table' and public(data.lines) and type(data.lines)=='table'
    if valid then
        for i=1,32 do
            local line=data.lines[i]
            if not public(line) or line~=nil and type(line)~='table' then valid=false;break end
            if line then
                for _,field in ipairs({'leftText','rightText'})do
                    local text=line[field]
                    if not public(text) or text~=nil and type(text)~='string' then valid=false;break end
                    if type(text)=='string' then
                        text=text:gsub('|c%x%x%x%x%x%x%x%x',''):gsub('|r',''):gsub('|T.-|t',''):gsub('|A.-|a','')
                        for label in text:sub(1,2048):gmatch('[^\r\n]+')do
                            if label:match('%S')then
                                if #labels>=16 then valid=false;break end
                                labels[#labels+1]=label:sub(1,100)
                            end
                        end
                    end
                end
            end
            if not valid then break end
        end
        if not public(data.lines[33]) or data.lines[33]~=nil then valid=false end
    end
    if not valid then stats.unknown=stats.unknown+1;stats.last='unreadable/secret native data'
    else
        table.sort(labels);local signature=table.concat(labels,' | ')
        if stats.signature~=nil and signature~=stats.signature then stats.changes=stats.changes+1 end
        stats.signature=signature;stats.last=signature~='' and signature:sub(1,240) or 'public empty'
        if #labels==0 then stats.empty=stats.empty+1 else stats.nonempty=stats.nonempty+1 end
        if NS.LookupNodeResource then
            local resource=false
            for _,label in ipairs(labels)do
                local known=self.steeringLookup[label]
                if known==nil and self.steeringLookupCount<128 then
                    known=false
                    for _,kind in ipairs({'herb','ore','treasure'})do
                        if NS:LookupNodeResource(label,kind)then known=true;break end
                    end
                    self.steeringLookup[label]=known;self.steeringLookupCount=self.steeringLookupCount+1
                end
                if known then resource=true;break end
            end
            if resource then stats.resources=stats.resources+1 end
        end
    end
    -- Diagnostic probes advance, but these reads never enter the live cache.
    self.nextDiscovery=true
end
function trial:Blocked()
    if self.loading then return 'loading screen' end
    if NS.ReplacementMinimapHover and NS.ReplacementMinimapHover.hoverRequested then return 'normal minimap hover' end
    if self.stopping then return 'waiting to restore after combat' end
    if NS.TerrainMarkers and NS.TerrainMarkers.rxpHover then return 'RestedXP marker hover' end
    -- Mounted travel may keep using an unprotected native capture frame.
    -- Start/stop, tracking, input and restoration retain their combat guards.
    if combat() and (softRead(IsMounted)~=true or read(Minimap,'IsProtected')==true) then return 'combat' end
    if not (NS.MinimapScanActive or NS.db.hud.enabled) or not NS.db.hud.rememberNodes then return 'HUD or Remember nodes off' end
    if UnitIsDeadOrGhost and UnitIsDeadOrGhost('player') then return 'dead' end
    if IsFlying and IsFlying() then return 'flying' end
    if UnitOnTaxi and UnitOnTaxi('player') then return 'flight path' end
    local steering=self:SteeringActive()
    if IsMouselooking and IsMouselooking() and not steering then return 'camera' end
    if IsMouseButtonDown and (IsMouseButtonDown('LeftButton') or IsMouseButtonDown('RightButton')) and not steering then return 'mouse button' end
    if IsInInstance then local inside=IsInInstance(); if inside then return 'instance' end end
    if NS.QuickScanner and NS.QuickScanner.farmPass then
        if LootFrame and read(LootFrame,'IsShown') then return 'looting' end
        for _,reader in pairs({UnitCastingInfo,UnitChannelInfo}) do
            local ok,casting=pcall(reader,'player')
            if not ok or issecretvalue and issecretvalue(casting) or casting~=nil then return 'casting' end
        end
    elseif self:NearbyGatheringObject() then return 'nearby gathering object' end
    -- IsShown remains true for a faded tooltip or one beneath a hidden parent.
    -- Only visible ordinary artwork should hold capture paused.
    local tooltipVisible=GameTooltip and read(GameTooltip,'IsShown')
    if tooltipVisible and GameTooltip.IsVisible then tooltipVisible=read(GameTooltip,'IsVisible') end
    local tooltipAlpha=GameTooltip and (read(GameTooltip,'GetEffectiveAlpha') or read(GameTooltip,'GetAlpha'))
    if publicNumber(tooltipAlpha) and tooltipAlpha<=0 then tooltipVisible=false end
    if not steering and tooltipVisible
        and not self:ShouldHideTooltip() then
        return 'normal tooltip'
    end
    if GetMouseFoci then
        local foci=GetMouseFoci()
        local focus=type(foci)=='table' and foci[1]
        -- Require genuine world focus or native map itself; never scan through UI.
        if focus and focus~=WorldFrame and not captureFrame(focus) and not self:PassiveTerrainFocus(focus) and not self:BelowCapture(focus) then return 'window under cursor' end
    else return 'mouse focus API unavailable' end
end
function trial:MeasureLayout()
    local x,y=Minimap:GetCenter()
    local scale=Minimap:GetEffectiveScale()
    if not (publicNumber(x) and publicNumber(y) and publicNumber(scale)) then return end
    local cursorX,cursorY=GetCursorPosition()
    if not (publicNumber(cursorX) and publicNumber(cursorY)) then return end
    self.actualX,self.actualY=x*scale,y*scale
    self.cursorDistance=math.sqrt((self.actualX-cursorX)^2+(self.actualY-cursorY)^2)
    if self.expectedX and self.expectedY then
        self.layoutError=math.sqrt((self.actualX-self.expectedX)^2+(self.actualY-self.expectedY)^2)
    end
    return self.layoutError
end
-- Bounded public geometry/call-site metadata only. Never record setter
-- arguments or tooltip content, and never repair from this diagnostic.
function trial:TraceCaptureLayoutWriter(setter)
    if NS._keepingMinimapInHUD or not self.saved or not self.placed
        or not self.workflow:Allows('knownOnly') or self.logging==false then return end
    local mismatch=self:MeasureLayout()
    if mismatch and mismatch<=2 then return end
    self.layoutWriterSeen=self.layoutWriterSeen or {}
    setter=type(setter)=='string' and setter or 'other layout callback'
    if self.layoutWriterSeen[setter] or (self.layoutWriterCount or 0)>=6 then return end
    self.layoutWriterSeen[setter]=true;self.layoutWriterCount=(self.layoutWriterCount or 0)+1
    local stack=debugstack and debugstack(3,5,0) or 'caller stack unavailable'
    self:Trace('layout writer',setter..'; error='..tostring(mismatch))
    local count=0
    for line in tostring(stack):gmatch('[^\r\n]+') do
        if count>=4 then break end
        self:Trace('layout caller',line);count=count+1
    end
end
function trial:TraceCaptureLayoutMismatch()
    if self.layoutMismatchLogged or self.logging==false then return end
    self.layoutMismatchLogged=true
    local point,relative,relativePoint,dx,dy=Minimap:GetPoint(1)
    local relativeName=relative==UIParent and 'UIParent' or read(relative,'GetName') or 'unnamed'
    self:Trace('capture geometry',string.format('expected=%.1f,%.1f actual=%.1f,%.1f scale=%s UIscale=%s clamped=%s',
        self.expectedX or 0,self.expectedY or 0,self.actualX or 0,self.actualY or 0,
        tostring(Minimap:GetEffectiveScale()),tostring(UIParent:GetEffectiveScale()),tostring(read(Minimap,'IsClampedToScreen'))))
    self:Trace('capture anchor',tostring(point)..' -> '..tostring(relativeName)..':'..tostring(relativePoint)
        ..' offsets='..tostring(dx)..','..tostring(dy))
end
function trial:RestoreNativeZoom(keepHUD)
    if not keepHUD and publicNumber(self.nativeZoom) and Minimap.SetZoom then
        pcall(Minimap.SetZoom,Minimap,self.nativeZoom)
    end
    local setter=SetCVar or C_CVar and C_CVar.SetCVar
    if setter then
        for key,value in pairs(self.nativeZoomCVars or {}) do
            if type(value)=='string' or publicNumber(value) then pcall(setter,key,value) end
        end
    end
end
function trial:MaintainCaptureZoom()
    if combat() then return end
    if Minimap.EnableMouseWheel then pcall(Minimap.EnableMouseWheel,Minimap,false) end
    local current=read(Minimap,'GetZoom')
    if publicNumber(self.captureZoom) and publicNumber(current) and current~=self.captureZoom and Minimap.SetZoom then
        local ok=pcall(Minimap.SetZoom,Minimap,self.captureZoom)
        if ok then
            if self.AbortRefinement then self:AbortRefinement('capture zoom changed; reacquire') end
            self.scanStates={};self.trackingCursors={};self.passReady=false
            self:BuildDiscoveryPattern();self.index=0;self.placed=nil;self.captureAt=nil
            NS.CursorSweepReady=false
        end
    end
end
function trial:RefreshCaptureInput()
    if combat() then return end
    -- Resizing/reparenting can reset native input internally, bypassing the
    -- Lua setter hooks. Reassert the established hover-only/all-button routes.
    if NS.UpdateHUDMouseInteraction then NS:UpdateHUDMouseInteraction() end
    if NS.HideEllesmereControls then NS:HideEllesmereControls() end
    if Minimap.EnableMouseWheel then pcall(Minimap.EnableMouseWheel,Minimap,false) end
end
function trial:CaptureGeometrySample()
    return {scale=read(Minimap,'GetEffectiveScale'),width=read(Minimap,'GetWidth'),height=read(Minimap,'GetHeight'),
        zoom=read(Minimap,'GetZoom'),radius=softRead(C_Minimap and C_Minimap.GetViewRadius),indoors=softRead(IsIndoors)}
end
function trial:GeometryRepairDiagnostic()
    local event=self.lastGeometryRepair
    if not event then return 'geometry repair=none recorded this scan' end
    local function value(v)
        if publicNumber(v) then return string.format('%.4f',v) end
        if type(v)=='boolean' then return tostring(v) end
        return 'unknown'
    end
    local parts={'geometry repair age='..string.format('%.1fs',math.max(0,GetTime()-event.at)),
        'stage='..event.stage,'refining='..tostring(event.refining),'repeat count='..tostring(self.geometryRepairRepeats or 1)}
    local restore=event.restore
    if restore then
        local matched=true
        for _,key in ipairs({'scale','width','height'}) do
            local a,b=event.before[key],restore.sample[key]
            if not publicNumber(a) or not publicNumber(b) or math.abs(a-b)>.001 then matched=false end
        end
        parts[#parts+1]='prior restore='..restore.reason
        parts[#parts+1]=string.format('restore-to-repair=%.2fs; restored geometry matches=%s',math.max(0,event.at-restore.at),tostring(matched))
    end
    for _,key in ipairs({'scale','width','height','zoom','radius','indoors'}) do
        parts[#parts+1]=key..'='..value(event.before[key])..' -> '..value(event.after[key])
    end
    return table.concat(parts,'; ')
end
-- Identical recurring repairs must not displace node/timing events.
function trial:TraceGeometryRepair()
    local event=self.lastGeometryRepair
    local function signature(sample)
        local parts={}
        for _,key in ipairs({'scale','width','height','zoom','radius','indoors'}) do
            local v=sample[key]
            parts[#parts+1]=publicNumber(v) and string.format(key=='scale' and '%.4f' or '%.2f',v) or tostring(v)
        end
        return table.concat(parts,',')
    end
    local key=event.stage..':'..signature(event.before)..':'..signature(event.after)
    if key~=self.geometryRepairSignature then
        self.geometryRepairSignature=key;self.geometryRepairRepeats=0;self.geometryRepairLoggedAt=nil
    end
    self.geometryRepairRepeats=(self.geometryRepairRepeats or 0)+1
    if not self.geometryRepairLoggedAt or event.at-self.geometryRepairLoggedAt>=10 then
        self.geometryRepairLoggedAt=event.at
        self:Trace('geometry repair',self:GeometryRepairDiagnostic()..'; repeated='..self.geometryRepairRepeats)
    end
end
function trial:EnsureCaptureGeometry(stage)
    local parent=self.map.parent or UIParent
    local parentScale=parent:GetEffectiveScale()
    NS._keepingMinimapInHUD=true
    local repaired=false
    local before
    local function markRepair()
        if not repaired then before=self:CaptureGeometrySample();repaired=true end
    end
    local ok,err=pcall(function()
        if Minimap:GetParent()~=parent then markRepair();Minimap:SetParent(parent) end
        local wantedScale=self.size/self.map.width/parentScale
        if math.abs(Minimap:GetScale()-wantedScale)>.00001 then markRepair();Minimap:SetScale(wantedScale) end
        if math.abs(Minimap:GetWidth()-self.map.width)>.01 or math.abs(Minimap:GetHeight()-self.map.height)>.01 then
            markRepair();Minimap:SetSize(self.map.width,self.map.height)
        end
    end)
    NS._keepingMinimapInHUD=nil
    if not ok then error(err) end
    if repaired then
        self.geometryRepairs=(self.geometryRepairs or 0)+1
        self.lastGeometryRepair={at=GetTime(),stage=stage or 'capture layout',before=before,
            after=self:CaptureGeometrySample(),restore=self.lastMapRestore,refining=self.refinement~=nil or self.refinePending~=nil}
        self:TraceGeometryRepair()
        self:RefreshCaptureInput()
    end
    if not NS.MinimapScanActive and NS.ResizeEllesmereHUDClip and NS.HUDFrame then
        NS._keepingMinimapInHUD=true
        local ok,err=pcall(NS.ResizeEllesmereHUDClip,NS,self.size/NS.HUDFrame:GetEffectiveScale())
        NS._keepingMinimapInHUD=nil
        if not ok then error(err) end
    end
end
function trial:RepairCaptureLayout()
    if NS._keepingMinimapInHUD or combat() or not self.expectedX or not self.map then return end
    if self.workflow:Allows('knownOnly') and self.quickLayoutConflict then return end
    -- Setter hooks also fire for unchanged icon/alpha/layout writes. Only a
    -- real geometry/opacity change may invalidate a pending native read.
    local scale=Minimap:GetEffectiveScale()
    local width,height=Minimap:GetWidth(),Minimap:GetHeight()
    local alpha=Minimap:GetAlpha()
    local error=self:MeasureLayout()
    if publicNumber(scale) and publicNumber(width) and publicNumber(height) and publicNumber(alpha)
        and Minimap:GetParent()==(self.map.parent or UIParent)
        and math.abs(width-self.map.width)<.01 and math.abs(height-self.map.height)<.01
        and math.abs(width*scale-self.size)<.01 and math.abs(alpha-self.alpha)<.001
        and error and error<.01 then return end
    if self.workflow:Allows('knownOnly') then
        -- Several native setters can trigger the same skin hooks in one
        -- client frame. One repair is enough; reads still check real geometry.
        local now=GetTime()
        if self.quickRepairAt==now then return end
        self.quickRepairAt=now
    end
    local reasons={}
    if Minimap:GetParent()~=(self.map.parent or UIParent) then reasons[#reasons+1]='parent' end
    if publicNumber(width) and math.abs(width-self.map.width)>=.01 then reasons[#reasons+1]='width' end
    if publicNumber(height) and math.abs(height-self.map.height)>=.01 then reasons[#reasons+1]='height' end
    if publicNumber(scale) and publicNumber(width) and math.abs(width*scale-self.size)>=.01 then reasons[#reasons+1]='scale' end
    if publicNumber(alpha) and math.abs(alpha-self.alpha)>=.001 then reasons[#reasons+1]='alpha' end
    if not error or error>=.01 then reasons[#reasons+1]='anchor' end
    self.lastRepairReason=table.concat(reasons,',')
    self:EnsureCaptureGeometry()
    NS._keepingMinimapInHUD=true
    local ok,err=pcall(function()
        local scale=Minimap:GetEffectiveScale()
        Minimap:ClearAllPoints()
        Minimap:SetPoint('CENTER',UIParent,'BOTTOMLEFT',self.expectedX/scale,self.expectedY/scale)
        Minimap:SetAlpha(self.alpha)
    end)
    NS._keepingMinimapInHUD=nil
    if not ok then error(err) end
    self:RefreshCaptureInput()
    -- This synchronous hook restores the SAME intended target before the next
    -- client render. Probe changes in Tick own warmup/vote invalidation; doing
    -- that here lets a busy skin permanently prevent the first tooltip read.
    self.geometryRepairs=(self.geometryRepairs or 0)+1
    if self.workflow:Allows('knownOnly') then
        local remaining=self:MeasureLayout()
        if not remaining or remaining>2 then
            self.quickLayoutConflict=true;NS.CursorSweepReady=false
        end
    end
end
function trial:CanCapture()
    local function gate(reason)
        if self.workflow:Allows('knownOnly') then
            if self.captureGateAt~=self.at then self.captureGateAt=self.at;self.captureGateCount=0;self.captureGate=nil end
            if self.captureGate~=reason and self.captureGateCount<6 then
                self.captureGateCount=self.captureGateCount+1
                self:Trace('capture gate',reason..'; placement age='..string.format('%.0fms',self.at and (GetTime()-self.at)*1000 or 0))
            end
            self.captureGate=reason
        end
        return false
    end
    if self:SteeringActive() then return false end -- Read-only steering diagnostic owns these samples.
    local fast=self.nativeCapture and (not self.refinement or self.refinementDiscovery) and not self.refinePending and not self.nextDiscovery
        and self.captureAt and GetTime()>=self.captureAt
    local blocked=self:Blocked()
    if blocked then
        -- The physical reader can notice a camera/input pause before Tick.
        -- Never carry a half-confirmed discovery across that interruption.
        self.discoveryAnswer=nil
        return gate('blocked: '..blocked)
    end
    if not self.placed then return gate('not placed') end
    if not (NS.CursorSweepReady or fast) then return gate('settling or awaiting next placement') end
    local error=self:MeasureLayout()
    if not error or error>2 then
        if self.workflow:Allows('knownOnly') then self:TraceCaptureLayoutMismatch() end
        return gate('layout error='..tostring(error))
    end
    local x,y=GetCursorPosition()
    if not (publicNumber(x) and publicNumber(y) and (x-self.x)^2+(y-self.y)^2<=12^2) then return gate('cursor moved beyond 12px') end
    if self.workflow:Allows('knownOnly') then self.captureGate='ready' end
    return true
end
function trial:IsRefinementOnly(ctx)
    if not self.discoverySize then return false end
    -- Include the final sample after a job changes the requested size, while
    -- the native frame still has the enlarged geometry.
    if self.size and self.size>self.discoverySize+.5 then return true end
    if ctx and publicNumber(ctx.width) and publicNumber(ctx.scale)
        and ctx.width*ctx.scale>self.discoverySize+.5 then return true end
    return self.refineMultiplier==2 and (self.refinement~=nil or self.refinePending~=nil)
end
function trial:DiscoveryRead(ctx,spot,hits,now,nonempty)
    if self.validationBatchActive then self.discoveryStatus="checking marked nodes after tracking swap";return false end
    if self:IsRefinementOnly(ctx) then self.discoveryStatus='targeted refinement; discovery paused';return false end
    now=now or GetTime();hits=hits or {}
    if not self.at or now-self.at<self.workflow:SampleDelay(false)-0.000001 then self.discoveryStatus='waiting for fresh native sample';return false end
    if #hits>0 then
        local labels={}
        for _,hit in ipairs(hits)do labels[#labels+1]=tostring(hit.resource.kind)..':'..tostring(hit.resource.name or hit.resource.id) end
        local key=tostring(self.at)..table.concat(labels,',')
        if key~=self.traceLastLabel then
            self.traceLastLabel=key;self:Trace('resource read',table.concat(labels,',')..'; point='..tostring(self.index)..'; kind='..tostring(self.scanKind))
        end
    end
    if #hits>0 and now-self.at<self.workflow:SampleDelay(true)-0.000001 then self.discoveryStatus='settling resource candidate';return false end
    if self.discoveryConsumedAt==self.at and (#hits==0 or self.discoveryConsumedResource) then return false end
    local names={}
    for _,entry in ipairs(hits)do names[#names+1]=entry.resource.kind..':'..tostring(entry.resource.id) end
    table.sort(names);local signature=table.concat(names,';')
    local answer=self.discoveryAnswer
    local moved=false
    if answer and ctx and spot and answer.x then
        local p=2*ctx.radius/(ctx.width*ctx.scale)
        moved=((spot.x-answer.x)*ctx.w)^2+((spot.y-answer.y)*ctx.h)^2>(p*.75)^2
    end
    if #hits>0 and (not answer or answer.placement~=self.at or answer.signature~=signature or now-answer.at>.15 or moved) then
        self.discoveryAnswer={placement=self.at,signature=signature,at=now,x=spot and spot.x,y=spot and spot.y}
        self.discoveryStatus=moved and 'resource confirmation moved beyond0.75px' or 'confirming native labels'
        self.untilTime=math.max(self.untilTime or now,math.min(self.at+.30,now+.15))
        return false
    end
    if #hits>0 and now-answer.at<self.workflow:ConfirmationDelay() then return false end
    self.discoveryConsumedAt=self.at;self.discoveryConsumedResource=#hits>0
    if self.workflow:Allows('knownOnly') and self.knownTarget then
        if #hits>0 then
            local origin=self.knownTarget.quickOrigin or self.knownTarget
            origin.quickHit=true
        elseif nonempty==false then self:QueueQuickNearby(ctx) end
    end
    self.discoveryAnswer=nil
    self:TraceProbe(#hits>0 and 'resource confirmed' or nonempty and 'non-resource' or 'empty',now)
    if #hits>0 then self:Trace('candidate confirmed',signature..'; point='..tostring(self.index)) end
    self.discoveryStatus=#hits>0 and 'confirmed resource labels' or 'single-frame public empty/non-resource'
    if not self.knownTarget and self.spots and self.spots[self.index] and self.coveredPoints and not self.coveredPoints[self.index] then
        self.coveredPoints[self.index]=true;self.coveredCount=self.coveredCount+1
        self:UpdateDiscoveryCompletion()
    end
    self.confirmedProbes=(self.confirmedProbes or 0)+1
    if #hits>0 then self.positiveProbes=(self.positiveProbes or 0)+1
    elseif nonempty==false then self.emptyProbes=(self.emptyProbes or 0)+1
    elseif nonempty==true then self.nonresourceProbes=(self.nonresourceProbes or 0)+1 end
    if not self.knownTarget and self.spots and self.spots[self.index] and self.spots[self.index].close then self.nearbyProbes=(self.nearbyProbes or 0)+1 end
    if self.refinementDiscovery and self.refinement then
        local job=self.refinement
        self.refinementDiscoveryRemaining=(self.refinementDiscoveryRemaining or 1)-1
        if self.refinementDiscoveryRemaining>0 then
            self:AdvanceBackgroundDiscovery(now)
        else
            -- Complex overlap profiles need a short run of edge votes to
            -- finish. Keep their precision, but yield after four votes rather
            -- than interrupting every vote with three discovery points.
            job.nextDiscoveryAt=job.reads+(job.background and job.phase~='profile' and 1 or 4)
            self.refinementDiscovery=nil
        end
        NS.CursorSweepReady=false
        return true
    end
    if not self.refinement and not self.refinePending then
        self.nextDiscovery=true;NS.CursorSweepReady=false
    end
    return true
end
-- A HUD pass restores the complete normal HUD through the shared Stop path.
function trial:EndHUDQuickPass(reason)
    if not self.saved then return end
    self.hudQuickPass=nil
    self.hudQuickReturning=true
    self:Stop(reason or 'HUD quick pass complete')
end
function trial:BeginHUDQuickPass(kind,now)
    if self.saved or combat() or not NS.db.hud.enabled then return false end
    NS:SetCursorScanWorkflow(NS.CursorScanWorkflows.hudQuick)
    if not NS:SetExperimentalNodeScanEnabled(true) then return false end
    self.scanKind=kind;self.hudQuickPass=true;self.quickDeadline=now+(NS.GetQuickScanDuration and NS:GetQuickScanDuration() or 1.5)
    return true
end
function trial:Tick(now)
    if not self.saved then return end
    if self.workflow==NS.CursorScanWorkflows.hudQuick then
        if self.stopping then self:Stop();return end
        local kind=NS.GetCursorSweepTrackingKind and NS:GetCursorSweepTrackingKind()
        if now>=self.quickDeadline or combat() or self.quickLayoutConflict or kind~=self.scanKind then
            self:EndHUDQuickPass('deadline, tracking change or unsafe capture');return
        end
    end
    if self.workflow:Allows('knownOnly') and self.quickLayoutConflict then
        self:Stop('native minimap layout conflict');self.reason='native minimap layout conflict';return
    end
    if self.workflow:Allows('knownOnly') then
        local blocked=self:Blocked()
        -- Camera travel and ordinary tooltips are short interruptions, not
        -- evidence that the rest of this automatic pass should be discarded.
        -- Shared pause handling below rejects reads and restores the map;
        -- the original wall-clock deadline still bounds any later resume.
        local transient=blocked=='camera' or blocked=='mouse button' or blocked=='normal tooltip'
        local reason=self.stopping and 'deferred restoration' or now>=(self.quickDeadline or now) and 'scan duration deadline'
            or combat() and 'combat' or blocked and not transient and blocked
            or NS.GetCursorSweepTrackingKind and self.scanKind and NS:GetCursorSweepTrackingKind()~=self.scanKind
                and ('tracking changed '..tostring(self.scanKind)..' -> '..tostring(NS:GetCursorSweepTrackingKind()))
        if reason then
            if self.workflow==NS.CursorScanWorkflows.hudQuick then self:EndHUDQuickPass(reason) else self:Stop(reason) end
            return
        end
    end
    self:InstallQuestieWaypointTooltipHook(now)
    self:UpdateQuestieWaypointTooltip()
    if now>=(self.nextOverlayCheck or 0) then
        self.nextOverlayCheck=now+.2
        if NS.SuppressCursorMinimapPins then NS:SuppressCursorMinimapPins() end
        self:PerformanceCheckpoint('other-pins')
        if NS.HideEllesmereControls then NS:HideEllesmereControls() end
        self:PerformanceCheckpoint('skin-controls')
        self:QuietMinimapControls()
        self:PerformanceCheckpoint('pin-sweep')
    elseif self.controlScan then
        self:QuietMinimapControls()
        self:PerformanceCheckpoint('pin-sweep')
    end
    local steering=self:SteeringActive()
    if not steering and not (IsMouselooking and IsMouselooking()) then
        local freeX,freeY=GetCursorPosition()
        if publicNumber(freeX) and publicNumber(freeY) then self.freeCursorX,self.freeCursorY=freeX,freeY end
    end
    if self.RefinementDiagnosticLines and now>=(self.nextRefinementTrace or 0)then
        self.nextRefinementTrace=now+5
        for _,line in ipairs(self:RefinementDiagnosticLines(now))do self:Trace('refinement progress',line)end
    end
    local reason=self:Blocked()
    self:PerformanceCheckpoint('guards')
    local pauseKey=reason or 'none'
    if pauseKey~=self.traceLastPause then
        self.traceLastPause=pauseKey;self:Trace('pause',pauseKey)
        if reason then
            self.lastPause={reason=reason,at=now}
            self.pauseCounts=self.pauseCounts or {}
            self.pauseCounts[reason]=(self.pauseCounts[reason] or 0)+1
        end
    end
    local dt=self.timingLast and math.max(0,math.min(.25,now-self.timingLast)) or 0
    self.timingLast=now
    self.pauseSeconds=self.pauseSeconds or {}
    if reason then self.pauseSeconds[reason]=(self.pauseSeconds[reason] or 0)+dt
    else self.activeSeconds=(self.activeSeconds or 0)+dt end
    if reason then
        self.passStable=false;self:WakeDiscovery()
        if self.CancelValidation then self:CancelValidation(reason) end
        if self.SuspendRefinement then self:SuspendRefinement(reason,now) end
        NS.CursorSweepReady=false;self.captureAt=nil; self.reason=reason
        local idleCapture=self.discoveryIdle
        self.discoveryIdle=nil
        if (self.placed or idleCapture) and not combat() then self:RestoreMap(true,false,reason); self.placed=nil end
        self:UpdateTooltip()
        return
    end
    self:MaintainCaptureZoom()
    if NS.ReplacementMinimap then NS.ReplacementMinimap:Maintain() end
    self:SampleDiscoveryView()
    if steering then
        if self.SuspendRefinement then self:SuspendRefinement('steering diagnostic',now) end
        self:SteeringSample(now)
    elseif self.ResumeRefinement then self:ResumeRefinement(now) end
    if now>=(self.nextServiceAttempt or 0) then
        self.nextServiceAttempt=now+.5;self:ServiceTracking(true)
    end
    if self.questRefresh~=nil and now>=(self.nextQuestAttempt or 0)then
        self.nextQuestAttempt=now+.5;self:QuestAreas(self.questRefresh)
    end
    self.presentation:Update(self)
    if self.workflow:Allows('validation') and not steering and self.PrepareValidation and NS.GetCursorSweepTrackingKind then
        self:PrepareValidation(NS:GetCursorSweepTrackingKind(),now)
    end
    if self.workflow:Allows("refinement") and self.TrackRefinement and NS.GetCursorSweepTrackingKind then
        self:TrackRefinement(NS:GetCursorSweepTrackingKind(),now)
    else
        local job=self.refinement or self.refinePending
        if job and NS.IsCursorSweepKindTracked and not NS:IsCursorSweepKindTracked(job.node.kind) then
            self:AbortRefinement('target tracking changed; back to native discovery')
        end
    end
    if NS.GetCursorSweepTrackingKind then
        local kind=NS:GetCursorSweepTrackingKind()
        if kind~=self.scanKind then
            self.trackingCursors=self.trackingCursors or {}
            if self.scanKind then
                self.trackingCursors[self.scanKind]=self.index
                self.scanStates[self.scanKind]={spots=self.spots,phase=self.scanPhase,covered=self.coveredPoints,
                    count=self.coveredCount,raster=self.rasterPointCount,step=self.discoveryStep,attempts=self.discoveryAttempts,view=self.passView,lastView=self.passLastView,travel=self.passTravel,stable=self.passStable,priorityView=self.priorityView,promoted=self.terrainPromoted,priorityCount=self.terrainPriorityPoints}
            end
            local previousKind=self.scanKind
            self.scanKind=kind
            self:WakeDiscovery()
            local state=self.scanStates[kind]
            local freshPattern=not state
            if state then
                self.spots,self.scanPhase,self.coveredPoints,self.coveredCount=state.spots,state.phase,state.covered,state.count
                self.rasterPointCount,self.discoveryStep=state.raster,state.step
                self.discoveryAttempts=state.attempts or {}
                self.passView,self.passLastView,self.passTravel,self.passStable=state.view,state.lastView,state.travel,false
                self.priorityView,self.terrainPromoted=state.priorityView,state.promoted
                self.terrainPriorityPoints=state.priorityCount or 0
                -- A completed visit must earn a fresh pass on its next turn.
                if self.coveredCount==#self.spots then
                    freshPattern=true
                    self.scanPhase=(self.scanPhase+1)%3;self:BuildDiscoveryPattern()
                end
            else self.scanPhase=0;self:BuildDiscoveryPattern() end
            self.passReady=false
            self.index=freshPattern and 0 or math.max(0,(self.trackingCursors[kind] or 1)-1)
            self:Trace('tracker',tostring(previousKind)..' -> '..tostring(kind)..'; previous active='..string.format('%.1fs',math.max(0,(self.activeSeconds or 0)-(self.visitActiveStart or self.activeSeconds or 0))))
            self.visitActiveStart=self.activeSeconds or 0;self.visitStartedAt=now
            self.knownTarget=nil;self.knownStreak=0
            self.scanKind=kind;self.trackingChanges=(self.trackingChanges or 0)+1
            self.placed=nil;self.refineSerial=nil;self.discoveryAnswer=nil;self.nextDiscovery=nil
            self.captureAt=nil;NS.CursorSweepReady=false
        end
    end
    -- Repair transient skin/layout scale before a new job snapshots its context.
    self:EnsureCaptureGeometry('before refinement queue')
    if self.workflow:Allows('refinement') and not steering and self.PumpRefinementQueue then self:PumpRefinementQueue(now) end
    self:PerformanceCheckpoint('queue')
    -- Repair external skin/layout writes before the refiner validates context.
    self:EnsureCaptureGeometry()
    self:PerformanceCheckpoint('geometry')
    local x,y=GetCursorPosition()
    local scale=UIParent:GetEffectiveScale()
    if steering then
        if not self.steeringWasActive then
            self.steerAnchorX,self.steerAnchorY=self.freeCursorX or x,self.freeCursorY or y
        end
        x,y=self.steerAnchorX,self.steerAnchorY
    end
    if not (publicNumber(x) and publicNumber(y) and publicNumber(scale) and scale>0) then
        NS.CursorSweepReady=false; self.reason='unreadable cursor'; return
    end
    if not steering then self.freeCursorX,self.freeCursorY=x,y end
    self.steeringWasActive=steering
    -- Follow normal pointer travel every frame while holding each relative scan
    -- point long enough to settle. Only abrupt jumps restart the settling delay.
    local jump=self.placed and ((x-self.x)^2+(y-self.y)^2>12^2)
    local refinePoint,serial
    if self.workflow:Allows('refinement') and not steering and self.RefinementPoint then refinePoint,serial=self:RefinementPoint(now) end
    if self.workflow:Allows('validation') and not steering and self.ValidationPoint then
        local point,id=self:ValidationPoint(now)
        if point then refinePoint,serial=point,id end
    end
    local job=self.refinement
    if not steering and job and not job.pendingPublication and self.discoverySize==self.refinementSize and (self.refinementDiscovery or job.reads>=(job.nextDiscoveryAt or 4)) then
        if not self.refinementDiscovery then
            self.refinementDiscovery=true;job.answer=nil
            self.refinementDiscoveryRemaining=job.background and 3 or 1
            if job.background then self:AdvanceBackgroundDiscovery(now) else self:AdvanceDiscovery() end
        end
        -- An unreadable tooltip cannot finish DiscoveryRead. Background
        -- discovery still owns a finite dwell, just like ordinary discovery:
        -- move on without calling it empty or spending a confirmed slice.
        local discoverySerial=job.background and -200000-(self.backgroundDiscoverySerial or 0) or -100000-self.index
        if self.placed and self.refineSerial==discoverySerial and self.untilTime and now>=self.untilTime then
            if job.background then self:AdvanceBackgroundDiscovery(now) else self:AdvanceDiscovery() end
        end
        local discoverySpot
        if job.background and self.knownTarget then
            discoverySpot=self:KnownLocationOffset(self.knownTarget,NS:GetGatheringNodeContext())
            if not discoverySpot then
                self:AdvanceBackgroundDiscovery(now)
                discoverySpot=self.knownTarget and self:KnownLocationOffset(self.knownTarget,NS:GetGatheringNodeContext())
            end
        end
        refinePoint=discoverySpot or self.spots[self.index]
        serial=job.background and -200000-(self.backgroundDiscoverySerial or 0) or -100000-self.index
    end
    -- Cursor resets/restored visits can leave a current dwell without a
    -- discovery point. Recover before indexing it, even if the dwell is fresh.
    if refinePoint and not self.refinementDiscovery or steering then self.knownTarget=nil end
    local knownPoint=self.knownTarget and NS.GetGatheringNodeContext
        and self:KnownLocationOffset(self.knownTarget,NS:GetGatheringNodeContext())
    if self:DiscoveryIdle(now,steering or refinePoint~=nil or self.refinement~=nil or self.refinePending~=nil
        or self.validationBatchActive or self.nodeValidation~=nil) then return end
    local lostKnown=self.knownTarget and not knownPoint
    local advance=lostKnown or not self.placed or self.nextDiscovery or now>=self.untilTime or serial~=self.refineSerial or self.appliedSize~=self.size
        or not refinePoint and not self.knownTarget and not self.spots[self.index]
    self.nextDiscovery=nil
    if advance and not refinePoint then
        -- Never charge a database probe to the grid point it interrupted.
        local wasKnown=self.knownTarget~=nil
        self:FinishDiscoveryPoint()
        self.knownTarget=nil
        if not steering and not self.refinement and not self.refinePending and not self.validationBatchActive then
            local pending
            self.knownTarget,knownPoint,pending=self:NextKnownLocation(now)
            if self.workflow:Allows('knownOnly') and not self.knownTarget then
                if not pending and self.knownProbes==0 and NS.QuickScanner and NS.QuickScanner.farmPass then
                    self.workflow=NS.CursorScanWorkflows.farmDiscovery
                    self:Trace('farm discovery','no nearby saved locations; using FDG area discovery')
                elseif not pending and self.quickDeadline==math.huge then
                    -- Repeat bounded known-location queries, yielding between cycles.
                    -- Reset query bookkeeping only; historical rows stay untouched.
                    self.quickQueue=nil;self.quickNearby=nil
                    self.nextContinuousQuery=now+.5
                    pending=true
                end
                if pending then NS.CursorSweepReady=false;self.placed=nil;return end
                if self.workflow:Allows('knownOnly') then
                    if self.workflow==NS.CursorScanWorkflows.hudQuick then self:EndHUDQuickPass('known-location queue exhausted')
                    else self:Stop('known-location queue exhausted') end
                    return
                end
            end
        end
        if not self.knownTarget then
            if wasKnown then self.discoveryPlacementIndex=nil end
            self:AdvanceDiscovery()
        end
    end
    self.refineSerial=serial
    local spot=refinePoint or self.knownTarget and knownPoint or self.spots[self.index]
    if not spot then
        NS.CursorSweepReady=false;self.captureAt=nil;self.placed=nil
        self.index=0;self.reason='discovery point unavailable; retrying'
        return
    end
    local cx,cy=x-spot[1],y-spot[2]
    local width,height=UIParent:GetWidth()*scale,UIParent:GetHeight()*scale
    local half=self.size/2
    if cx<half or cy<half or cx>width-half or cy>height-half then
        NS.CursorSweepReady=false
        if self.placed then self:RestoreMap(true,true,'screen edge') end
        self.placed=nil; self.reason='screen edge';self:TraceProbe('screen edge: unavailable',now); return
    end
    local discoveryPoint=not refinePoint or self.refinementDiscovery
    -- Centering can start voting after one client render. Missing-node
    -- validation keeps its original two-frame transport and absence guards.
    local settle=self.workflow:CaptureDelay(discoveryPoint or not self.nodeValidation and (self.refinement or self.refinePending))
    if advance or jump then
        NS.CursorSweepReady=false;self.at=now;self.untilTime=now+self.workflow:Dwell();self.captureAt=now+settle;self.discoveryAnswer=nil
    end
    self:PerformanceCheckpoint('probes')
    NS._keepingMinimapInHUD=true
    local ok,err=pcall(function()
        local mapScale=Minimap:GetEffectiveScale()
        assert(publicNumber(mapScale) and mapScale>0,'unreadable capture map scale')
        local px,py=cx/mapScale,cy/mapScale
        local point,relative,relativePoint,dx,dy=Minimap:GetPoint(1)
        if Minimap:GetNumPoints()~=1 or point~='CENTER' or relative~=UIParent or relativePoint~='BOTTOMLEFT' then
            Minimap:ClearAllPoints();Minimap:SetPoint('CENTER',UIParent,'BOTTOMLEFT',px,py)
        elseif dx~=px or dy~=py then
            Minimap:SetPoint('CENTER',UIParent,'BOTTOMLEFT',px,py)
        end
        if Minimap:GetAlpha()~=self.alpha then Minimap:SetAlpha(self.alpha) end
        if Minimap.SetIconScale and NS._minimapIconScale~=HIDDEN_ICON_SCALE then Minimap:SetIconScale(HIDDEN_ICON_SCALE) end
    end)
    NS._keepingMinimapInHUD=nil
    if not ok then error(err) end
    self.steeringPlaced=steering
    self.appliedSize=self.size
    self.expectedX,self.expectedY=cx,cy
    self:MeasureLayout()
    self.x,self.y=x,y
    self.placed=true; self.moves=self.moves+1
    self:UpdateTooltip()
    self.discoveryPlacementIndex=(not refinePoint or self.refinementDiscovery) and self.index or nil
    NS.CursorSweepReady=not jump and self.layoutError and self.layoutError<=2 and now-self.at>=settle-0.000001
    self.reason=steering and 'read-only steering diagnostic at last free cursor' or NS.CursorSweepReady and 'capturing while following cursor' or 'settling scan point'

end
local frame=CreateFrame('Frame')
frame:SetScript('OnUpdate',function(_,elapsed)
    if NS.UpdateHUDScanStatus and GetTime()>=(trial.nextStatusUpdate or 0) then
        trial.nextStatusUpdate=GetTime()+.1
        NS:UpdateHUDScanStatus()
    end
    if trial.performanceSample then trial:RecordPerformanceFrame(elapsed) end
    if NS.ProcessRefinedNodeHintSaves then NS:ProcessRefinedNodeHintSaves() end
    if not trial.saved and NS.db and (NS.db.serviceTrackingRecovery or NS.db.questAreaRecovery or trial.questAreasOriginal~=nil or NS.db.questArrowRecovery or trial.questArrowOriginal~=nil)
        and GetTime()>=(trial.nextQuestRecovery or 0) then
        trial.nextQuestRecovery=GetTime()+.5;trial:QuestAreas(false)
    end
    if not trial.saved then return end
    local now=GetTime()
    if trial.nextFollow and now<trial.nextFollow then return end
    trial.nextFollow=now+trial.workflow:UpdateInterval()
    local perf=trial.performanceSample
    local started=perf and debugprofilestop and debugprofilestop()
    if started then perf.stageClock=started end
    local ok,err=pcall(trial.Tick,trial,now)
    if started and trial.performanceSample==perf then
        trial:PerformanceCheckpoint('finish')
        trial:RecordPerformanceCPU(debugprofilestop()-started)
    end
    if not ok then
        NS.CursorSweepReady=false
        trial.lastError=tostring(err);say('error: '..tostring(err))
        local restored,restoreError=pcall(trial.Stop,trial)
        if not restored then say('restoration error: '..tostring(restoreError)) end
    end
end)
frame:RegisterEvent('PLAYER_REGEN_DISABLED'); frame:RegisterEvent('PLAYER_REGEN_ENABLED')
frame:RegisterEvent('PLAYER_LOGIN'); frame:RegisterEvent('PLAYER_LEAVING_WORLD'); frame:RegisterEvent('PLAYER_ENTERING_WORLD');frame:RegisterEvent('PLAYER_LOGOUT')
-- Older clients may not expose this event; polling in Blocked remains valid.
pcall(frame.RegisterEvent,frame,'PLAYER_SOFT_INTERACT_CHANGED')
pcall(frame.RegisterEvent,frame,'ADDON_ACTION_BLOCKED')
pcall(frame.RegisterEvent,frame,'ADDON_ACTION_FORBIDDEN')
for _,event in ipairs({'PLAYER_STARTED_MOVING','MINIMAP_UPDATE_TRACKING','MINIMAP_UPDATE_ZOOM','LOOT_OPENED','LOOT_CLOSED','UNIT_SPELLCAST_SUCCEEDED'})do frame:RegisterEvent(event) end
frame:SetScript('OnEvent',function(_,event,unit,action)
    if event=='ADDON_ACTION_BLOCKED' or event=='ADDON_ACTION_FORBIDDEN' then
        -- Observe the client's rejection only; never retry the protected call.
        if not (issecretvalue and issecretvalue(unit)) and unit==ADDON_NAME_ then
            local text=not (issecretvalue and issecretvalue(action)) and type(action)=='string'
                and action:gsub('[\r\n|]',' '):sub(1,160) or 'unknown'
            trial.blockedAction={at=GetTime(),event=event,action=text,inCombat=combat()==true,
                mode=NS.MinimapScanActive and 'minimap' or trial.saved and 'HUD scan' or 'scanner off'}
            trial:Trace('blocked action',text..'; mode='..trial.blockedAction.mode..'; combat='..tostring(trial.blockedAction.inCombat))
            say('blocked action='..text..'; mode='..trial.blockedAction.mode..'; combat='..tostring(trial.blockedAction.inCombat)..'; /fdgdiag retains this report.')
        end
        return
    end
    if event=='UNIT_SPELLCAST_SUCCEEDED' and (issecretvalue and issecretvalue(unit) or unit~='player') then return end
    if not trial.saved and NS.db and (NS.db.serviceTrackingRecovery or NS.db.questAreaRecovery or NS.db.questArrowRecovery) and (event=='PLAYER_LOGIN' or event=='PLAYER_ENTERING_WORLD' or event=='PLAYER_REGEN_ENABLED')then
        trial:QuestAreas(false)
    end
    if event=='PLAYER_REGEN_ENABLED' and NS.pendingExperimentalHUDMode then
        NS.pendingExperimentalHUDMode=nil
        if NS.db and NS.db.hud.enabled then NS:HandleExperimentalHUDToggle(true) end
        return
    end
    if not trial.saved then return end
    trial:WakeDiscovery()
    NS.CursorSweepReady=false
    if event=='PLAYER_SOFT_INTERACT_CHANGED' then
        trial.discoveryAnswer=nil
        trial:Tick(GetTime())
        return
    end
    if event=='PLAYER_LOGOUT' then
        -- Restore persisted zoom preferences without a native-frame layout write.
        trial:RestoreNativeZoom(true)
        trial:RestoreNearbyInteraction()
        trial:PreserveHUDAppearance()
        -- The client's tracking preferences may already have been serialized.
        -- Keep recovery even after a confirmed write; the next addon instance
        -- must recover the original choice if native saved state is still off.
        trial:QuestAreas(false,true)
        local rotation=trial.clientRotation
        local setter=SetCVar or C_CVar and C_CVar.SetCVar
        if setter and (rotation=='0' or rotation=='1') then pcall(setter,'rotateMinimap',rotation) end
        for k in pairs(NS.db.hud) do NS.db.hud[k]=nil end
        for k,v in pairs(trial.saved) do NS.db.hud[k]=v end
    elseif event=='PLAYER_REGEN_ENABLED' then
        if trial.stopping then trial:Stop() else trial:RestoreMap(true);trial.placed=nil end
    elseif event=='PLAYER_LEAVING_WORLD' then
        trial.loading=true
        if not combat() then trial:RestoreMap(true);trial.placed=nil end
    elseif event=='PLAYER_ENTERING_WORLD' then trial.loading=nil;trial.placed=nil;trial:QuestAreas(true) end
end)
function NS:RefreshExperimentalNodeScanControl()
    if self.UpdateHUDScanStatus then self:UpdateHUDScanStatus() end
    if self.UpdateExperimentalHUDOptions then self:UpdateExperimentalHUDOptions() end
    local hud=self.OptionsPanel and self.OptionsPanel.pages and self.OptionsPanel.pages.hud
    if hud and hud.experimentalNodes then hud.experimentalNodes:SetChecked(self.db and self.db.hud.experimentalHUD==true) end
end
function NS:HandleExperimentalHUDToggle(enabled)
    if self._experimentalHUDInternal then return false end
    if self.ExperimentalMinimap and self.ExperimentalMinimap.hovering and self.SetExperimentalMinimapEnabled then
        if self.ExperimentalMinimap.presentation=='hud' then self.ExperimentalMinimap:Disarm()
        else self:SetExperimentalMinimapEnabled(false) end
    end
    if self.MinimapScanActive and self.SetExperimentalMinimapEnabled then
        self:SetExperimentalMinimapEnabled(false);return true
    end
    local quick=self.QuickScanner
    if quick and quick.hudHovering and not enabled and not self.db.hud.enabled then
        quick.hudEnabled=nil;quick.hudHovering=nil;quick.pending=nil
        self.Print(self.L.HUD_OFF)
        return true
    end
    if enabled and self.db.hud.experimentalHUD and self.db.hud.scanner=='quick' and quick then
        if trial.saved then
            trial.saved.enabled=true
            self:SetExperimentalNodeScanEnabled(false)
        end
        quick.hudEnabled=true;quick.pending=nil;quick.nextTimedScan=nil
        return false -- Apply the normal HUD; capture waits for an automatic switch.
    end
    if quick then
        quick.hudEnabled=nil
        quick.hudHovering=nil
        if quick.pending and quick.pending.hud then quick.pending=nil end
    end
    if enabled and self.db.hud.experimentalHUD then
        local workflow=self.db.hud.scanner=='quick' and self.CursorScanWorkflows.hudQuick or self.CursorScanWorkflows.hud
        if trial.saved and trial.workflow~=workflow then
            trial.saved.enabled=false
            self:SetExperimentalNodeScanEnabled(false)
        end
        if not trial.saved then self:SetCursorScanWorkflow(workflow) end
        self:SetExperimentalNodeScanEnabled(true);return true
    end
    if trial.saved then
        trial.saved.enabled=enabled==true
        self:SetExperimentalNodeScanEnabled(false);return true
    end
    return false
end
function NS:SetExperimentalHUDSelected(enabled)
    if not self.db or not self.db.hud then return false end
    self.db.hud.experimentalHUD=enabled==true
    if trial.saved then trial.saved.experimentalHUD=self.db.hud.experimentalHUD end
    if self.db.hud.enabled then
        if combat() then self.pendingExperimentalHUDMode=true
        else self:HandleExperimentalHUDToggle(true) end
    end
    self:RefreshExperimentalNodeScanControl()
    return true
end
function NS:SetExperimentalNodeScanEnabled(enabled)
    if enabled and (combat() or trial.stopping) then
        say(trial.stopping and 'waiting to finish restoring the previous HUD.' or 'start outside combat.')
        self:RefreshExperimentalNodeScanControl();return false
    end
    local ok,err=true,nil
    if enabled then
        if not trial.saved then ok,err=pcall(trial.Start,trial) end
    else ok,err=pcall(trial.Stop,trial) end
    if not ok then
        trial.lastError=tostring(err);say(tostring(err))
        if trial.saved then
            if not trial.keep then trial.keep=self.KeepMinimapInHUD end
            local restored,restoreError=pcall(trial.Stop,trial)
            if not restored then say(tostring(restoreError)) end
        end
    end
    self:RefreshExperimentalNodeScanControl()
    return ok and (enabled and self.CursorSweepActive==true or not enabled)
end
-- On-demand, bounded support snapshot; no layout changes or profiling toggle.
function NS:PrintHUDDiagnostic()
    local function value(fn,...)
        if type(fn)~='function' then return '?' end
        local ok,v=pcall(fn,...)
        if not ok or (issecretvalue and issecretvalue(v)) then return '?' end
        if publicNumber(v) then return string.format('%.1f',v) end
        if type(v)=='string' then return v:sub(1,100):gsub('[\r\n|]',' ') end
        if type(v)=='boolean' then return tostring(v) end
        return '?'
    end
    local function visual(object,method)
        return value(object and object[method],object)
    end
    local hud=self.db and self.db.hud or {}
    local metadata=C_AddOns and C_AddOns.GetAddOnMetadata or GetAddOnMetadata
    local loaded=C_AddOns and C_AddOns.IsAddOnLoaded or IsAddOnLoaded
    say('diag1 v='..value(metadata,'ForeverFarmRoute','Version')..'; FPS='..value(GetFramerate)
        ..'; experimental='..tostring(hud.experimentalHUD==true)..'; active='..tostring(self.CursorSweepActive==true)
        ..'; mode='..(self.MinimapScanActive and 'full-time minimap' or trial.saved and 'HUD scan' or 'scanner off')
        ..'; HUD/layer='..visual(self.HUDFrame,'IsVisible')..'/'..visual(self.NodeOverlay,'IsVisible'))
    say('layout HUD='..visual(self.HUDFrame,'GetWidth')..'x'..visual(self.HUDFrame,'GetHeight')
        ..'; scale UI/map='..visual(UIParent,'GetEffectiveScale')..'/'..visual(Minimap,'GetEffectiveScale')
        ..'; capture='..tostring(trial.size)..'; error px='..tostring(trial.layoutError or '?')
        ..'; opacity='..tostring(hud.nodeIconOpacity or 'default'))
    say('scan kind='..tostring(trial.scanKind or 'none')..'; pause='..tostring(trial.saved and trial:Blocked() or 'off')
        ..'; reads/hits='..tostring(trial.confirmedProbes or 0)..'/'..tostring(trial.positiveProbes or 0)
        ..'; coverage='..tostring(trial.coveredCount or 0)..'/'..tostring(#(trial.spots or {}))
        ..'; queued='..tostring(#(trial.refinementQueue or {}))..'; refine='..tostring(trial.refineStatus or 'none')
        ..'; '..trial:RefinementStopDiagnostic(GetTime())..'; '..trial:PauseProgressDiagnostic(GetTime()))
    say(trial:GeometryRepairDiagnostic())
    local blocked=trial.blockedAction
    local blockedText=blocked and (blocked.action..'; combat='..tostring(blocked.inCombat)..'; mode='..blocked.mode
        ..'; age='..string.format('%.1fs',math.max(0,GetTime()-blocked.at))) or 'none recorded'
    say('state='..tostring(trial.reason or 'off')..'; recheck='..tostring(trial.validationStatus or 'none')
        ..'; last error='..tostring(trial.lastError or 'none')..'; blocked action='..blockedText)
    if GameTooltip and (trial.saved or trial.tooltipDataType~=nil) then
        say('tooltip source='..tostring(trial.tooltipSource or 'legacy/unclassified')..'; data type='..tostring(trial.tooltipDataType or '?')
            ..'; shown/alpha='..visual(GameTooltip,'IsShown')..'/'..visual(GameTooltip,'GetAlpha')
            ..'; native/normal='..tostring(trial.minimapTooltip==true)..'/'..tostring(trial.normalTooltip==true)
            ..'; idle='..tostring(trial.discoveryIdle==true)..'; suppressed='..tostring(trial:ShouldHideTooltip()==true)
            ..'; parked/visible='..tostring(trial.tooltipParked==true)..'/'..visual(GameTooltip,'IsVisible')
            ..'; park error='..tostring(trial.tooltipParkError or 'none'))
    end
    local waypointTip=_G.QuestieWaypointMinimapTooltip
    if waypointTip then
        say('Questie waypoint tooltip shown/visible='..visual(waypointTip,'IsShown')..'/'..visual(waypointTip,'IsVisible')
            ..'; parked='..tostring(trial.questieTooltipState and trial.questieTooltipState.tooltipParked==true)
            ..'; show hook='..tostring(trial.questieTooltipModuleHook==true)..'; error='..tostring(trial.questieTooltipError or 'none'))
    end
    local addons={}
    local count=C_AddOns and C_AddOns.GetNumAddOns or GetNumAddOns
    local info=C_AddOns and C_AddOns.GetAddOnInfo or GetAddOnInfo
    local total=tonumber(value(count)) or 0
    for i=1,math.min(total,512) do
        local name=value(info,i)
        -- Modern APIs return a table instead of the legacy first name result.
        if name=='?' and C_AddOns and info==C_AddOns.GetAddOnInfo then
            local ok,row=pcall(info,i)
            if ok and type(row)=='table' then name=value(function()return row.name end) end
        end
        if name~='?' and value(loaded,name)=='true' then addons[#addons+1]=name end
        if #addons>=16 then break end
    end
    say('Questie='..value(loaded,'Questie')..'; loaded addons (max16/512 checked): '..(#addons>0 and table.concat(addons,', ') or 'unavailable'))
    if self.GetCompactNodeDiagnostic then
        for _,line in ipairs(self:GetCompactNodeDiagnostic())do say(line)end
    end
    if self.TerrainMarkers and self.TerrainMarkers.GetCompactDiagnostic then
        say(self.TerrainMarkers:GetCompactDiagnostic())
    end
    if self.TerrainQuestAreas then
        say('quest areas='..tostring(self.TerrainQuestAreas.reason)
            ..'; visible='..visual(self.TerrainQuestAreas.clip,'IsVisible'))
    end
end
-- Opt-in frame histogram: fixed 1001 buckets, no per-frame chat or global profiler.
function trial:PerformanceCheckpoint(name)
    local p=self.performanceSample
    if not p or not p.stageClock or not debugprofilestop then return end
    local now=debugprofilestop();local duration=math.max(0,now-p.stageClock)
    p.stageClock=now;p.stages=p.stages or {}
    p.stages[name]=math.max(p.stages[name] or 0,duration)
end
function trial:RecordPerformanceCPU(ms)
    local p=self.performanceSample
    if not p or not publicNumber(ms) or ms<0 then return end
    p.cpuCount=p.cpuCount+1;p.cpuTotal=p.cpuTotal+ms;p.cpuMax=math.max(p.cpuMax,ms)
end
function trial:StartPerformanceSample()
    if self.performanceSample then say('frame recording already running; finishes after 10 seconds.');return end
    local loaded=C_AddOns and C_AddOns.IsAddOnLoaded or IsAddOnLoaded
    local ok,questie=pcall(function()return loaded and loaded('Questie')end)
    self.performanceSample={frames=0,seconds=0,max=0,slow50=0,slow100=0,buckets={},
        cpuCount=0,cpuTotal=0,cpuMax=0,active=NS.CursorSweepActive==true,
        questie=ok and type(questie)=='boolean' and tostring(questie) or '?'}
    say('Recording frame times for 10 seconds; keep playing through the stutter. Results print automatically.')
end
function trial:RecordPerformanceFrame(elapsed)
    local p=self.performanceSample
    if not p or not publicNumber(elapsed) or elapsed<=0 or elapsed==math.huge then return end
    p.frames=p.frames+1;p.seconds=p.seconds+elapsed
    local ms=elapsed*1000
    p.max=math.max(p.max,ms)
    if ms>50 then p.slow50=p.slow50+1 end
    if ms>100 then p.slow100=p.slow100+1 end
    local bucket=math.min(1001,math.max(1,math.ceil(ms)))
    p.buckets[bucket]=(p.buckets[bucket] or 0)+1
    if p.seconds<10 then return end
    self.performanceSample=nil;self.lastPerformanceSample=p
    local function percentile(fraction)
        local seen=0
        for i=1,1001 do
            seen=seen+(p.buckets[i] or 0)
            if seen>=math.ceil(p.frames*fraction) then return i==1001 and '>1000' or tostring(i) end
        end
        return '?'
    end
    say(string.format('perf1 %.1fs; frames=%d; avg FPS=%.1f; Questie=%s; experimental active=%s->%s',
        p.seconds,p.frames,p.frames/p.seconds,p.questie,tostring(p.active),tostring(NS.CursorSweepActive==true)))
    say(string.format('Frame ms: avg=%.1f; p95<=%s; p99<=%s; worst=%.1f; >50ms=%d; >100ms=%d',
        p.seconds*1000/p.frames,percentile(.95),percentile(.99),p.max,p.slow50,p.slow100))
    say(p.cpuCount>0 and string.format('Scanner Tick CPU ms: avg=%.2f; worst=%.2f; calls=%d (excludes other addon updates/rendering)',
        p.cpuTotal/p.cpuCount,p.cpuMax,p.cpuCount) or 'Scanner Tick CPU: unavailable/no ticks; other addon updates/rendering not measured')
    local stages={}
    for _,name in ipairs({'other-pins','skin-controls','pin-sweep','guards','queue','geometry','probes','finish'})do
        if p.stages and p.stages[name] then stages[#stages+1]=name..'='..string.format('%.1f',p.stages[name]) end
    end
    if #stages>0 then say('Tick stage worst ms: '..table.concat(stages,', ')) end
end
SLASH_FDGDIAG1='/fdgdiag'
SlashCmdList.FDGDIAG=function(message)
    if NS.NodePlacementTraceCommand and NS:NodePlacementTraceCommand(message) then return end
    if (message or ''):lower():match('^%s*perf%s*$') then trial:StartPerformanceSample()
    else NS:PrintHUDDiagnostic() end
end
SLASH_FDGCURSOR1='/fdgcursor'
SlashCmdList.FDGCURSOR=function(message)
    local command=(message or ''):lower():match('^%s*(.-)%s*$')
    if command=='start' then NS:SetExperimentalNodeScanEnabled(true)
    elseif command=='refine2x' or command=='refine1x' then
        if combat() then say('change refinement size outside combat');return end
        if trial.AbortRefinement then trial:AbortRefinement('refinement size changed') end
        trial.pausedRefinements={};trial.validationBatchActive=false;trial.validationQueue=nil
        if trial.CancelValidation then trial:CancelValidation("refinement mode changed")end
        trial.refineMultiplier=command=='refine2x' and 2 or 1
        if trial.discoverySize then trial.refinementSize=trial.discoverySize*trial.refineMultiplier end
        trial:RefreshCaptureInput()
        say('refinement scale '..trial.refineMultiplier..'x; discovery keeps normal native size.')
    elseif command=='steering on' then
        trial.steeringTest=true;trial:ResetSteeringStats()
        say('steering diagnostic ON: hold right mouse over clear world space, then release and /fdgcursor report. Held-button reads are read-only.')
    elseif command=='steering off' then
        trial.steeringTest=nil;trial.steeringWasActive=nil;trial.steeringPlaced=nil
        say('steering diagnostic OFF; normal camera pause restored.')
    elseif command:match('^size ') then say('capture now keeps the normal native minimap size; no small-map resizing.')
    elseif command=='stop' then NS:SetExperimentalNodeScanEnabled(false)
    elseif command=='log on' then
        trial.logging=true;say('logging on; session memory only, bounded128 events +128 points.')
    elseif command=='log off' then trial.logging=false;say('logging off; retained entries remain readable.')
    elseif command=='log clear' then trial.traceBuffers={};trial.traceOrigin=GetTime();say('log cleared.')
    elseif command=='log' or command:match('^log %d+$') then trial:DumpTrace(false,command:match('(%d+)$'))
    elseif command=='log points' or command:match('^log points %d+$') then trial:DumpTrace(true,command:match('(%d+)$'))
    elseif command=='report' then
        say((trial.saved and 'active' or 'off')..'; '..tostring(trial.reason)..'; moves='..trial.moves..'; size='..trial.size)
        say('nearby interaction: '..tostring(trial.softStatus or 'off')..'; gathering object='..tostring(trial:NearbyGatheringObject()))
        if trial.placed then trial:MeasureLayout() end
        say(string.format('build cursor-follow-76; follow cap=60Hz; tooltip cap=60Hz; last layout error=%s px; map centre to cursor=%s px',
            trial.layoutError and string.format('%.1f',trial.layoutError) or 'unknown',
            trial.cursorDistance and string.format('%.1f',trial.cursorDistance) or 'unknown'))
        say('north-up capture; current pause='..tostring(trial:Blocked() or 'none')..'; scan kind='..tostring(trial.scanKind or 'unknown')..'; tracker changes='..tostring(trial.trackingChanges or 0)..'; resumed centering='..tostring(trial.resumedRefinements or 0)..'; last repair='..tostring(trial.lastRepairReason or 'none')..'; scale/layout repairs='..tostring(trial.geometryRepairs or 0)..'; boundary refinements='..tostring(trial.refined or 0)..'; '..tostring(trial.refineStatus or 'waiting for resource'))
        local function inputFlag(method,...)
            if type(Minimap[method])~='function' then return 'unavailable' end
            local ok,value=pcall(Minimap[method],Minimap,...)
            if not ok or issecretvalue and issecretvalue(value) then return 'unknown' end
            return type(value)=='boolean' and tostring(value) or 'unknown'
        end
        local zoom=read(Minimap,'GetZoom')
        local ok,radius=pcall(function()return C_Minimap and C_Minimap.GetViewRadius and C_Minimap.GetViewRadius()end)
        say('capture zoom='..tostring(zoom)..'; preserved native zoom='..tostring(trial.nativeZoom)..'; view radius='..tostring(ok and publicNumber(radius) and radius or 'unknown')..' yd')
        say('native input: click='..inputFlag('IsMouseClickEnabled')..'; motion='..inputFlag('IsMouseMotionEnabled')
            ..'; right pass-through='..inputFlag('ShouldButtonPassThrough','RightButton'))
        local pauses={}
        for reason,seconds in pairs(trial.pauseSeconds or {})do pauses[#pauses+1]=string.format('%s=%.1fs',reason,seconds)end
        table.sort(pauses)
        say(string.format('observed unpaused=%.1fs; pauses: %s; public discovery reads=%d; nearby probes=%d; empty=%d; non-resource=%d',
            trial.activeSeconds or 0,#pauses>0 and table.concat(pauses,', ') or 'none',trial.confirmedProbes or 0,
            trial.nearbyProbes or 0,trial.emptyProbes or 0,trial.nonresourceProbes or 0))
        say(string.format('scan coverage=%d/%d; phase=%d; spacing=%.1fpx; swap ready=%s; unresolved deferred=%d',trial.coveredCount or 0,#(trial.spots or {}),trial.scanPhase or 0,trial.discoveryStep or 0,tostring(NS:IsCursorSweepSwapReady()),trial.lastDeferredPoints or trial.deferredPoints or 0))
        say('discovery scheduling: entering-first='..tostring(trial.terrainPriorityPoints or 0)..'; idle='..tostring(trial.discoveryIdle==true)..'; stationary refresh<=3s after complete pass')
        say(string.format('tracker visit unpaused=%.1fs/10s; elapsed=%.1fs/20s; swap reason=%s',math.max(0,(trial.activeSeconds or 0)-(trial.visitActiveStart or trial.activeSeconds or 0)),math.max(0,GetTime()-(trial.visitStartedAt or GetTime())),trial:SwapBudgetExpired() and 'visit time limit; unfinished work preserved' or NS:IsCursorSweepSwapReady() and 'scan completed' or 'scan in progress'))
        if trial.RefinementDiagnosticLines then for _,line in ipairs(trial:RefinementDiagnosticLines(GetTime()))do say('refinement detail: '..line)end end
        say(trial:RefinementStopDiagnostic(GetTime()))
        say('known-location discovery probes='..tostring(trial.knownProbes or 0)..'; last='..tostring(trial.knownLastPriority or 'none')..'; entering locations first; up to two per grid point; cooldown=5s')
        local chestCount,chestQueued=0,0
        for _,node in ipairs(NS.GatheringNodeCache or {})do if node.kind=='treasure' then chestCount=chestCount+1 end end
        for _,entry in ipairs(trial.refinementQueue or {})do if entry.node.kind=='treasure' then chestQueued=chestQueued+1 end end
        say('treasure tracking='..tostring(NS.IsCursorSweepKindTracked and NS:IsCursorSweepKindTracked('treasure') or false)..'; chest observations='..chestCount..'; chest refinement queued='..chestQueued)
        say('centering: queued='..tostring(#(trial.refinementQueue or {}))..'; priority='..tostring(trial.refinementPriority or 'none')..'; discovery first, background slices; interior text retries='..tostring(trial.interiorReadRetries or 0)..'; recovered='..tostring(trial.interiorReadRecoveries or 0))
        local generic=NS.db and NS.db.anonymousRefinedNodeHints
        local genericRows=generic and generic.maps and generic.maps[trial.knownMap]
        say('saved measured hints: '..tostring(NS.refinedNodeHintStatus or 'none written this session')..'; reused='..tostring(trial.savedHintsReused or 0)
            ..'; saved generic on map='..tostring(type(genericRows)=='table' and #genericRows or 0))
        say('diagnostic log='..tostring(trial.logging~=false)..'; /fdgcursor log for events; /fdgcursor log points for timings')
        say('automatic swaps='..tostring(NS.IsAutoTrackingEnabled and NS:IsAutoTrackingEnabled() or (not NS.db.hud.autoTrackingWithHUD and NS.db.hud.autoTracking==true))..'; user paused='..tostring(NS.db.hud.trackingSwapsPaused==true)..'; stationary swaps='..tostring(NS.CursorSweepActive==true))
        say('missing-node rechecks: '..tostring(trial.validationStatus or 'waiting')..'; retired='..tostring(trial.missingRetired or 0)..'; swap checked='..tostring(trial.validationBatchChecked or 0)..'/'..tostring(trial.validationBatchTotal or 0)..'; deferred='..tostring(trial.validationBatchDeferred or 0))
        if trial.steeringTest then
            local stats=trial.steeringStats or {}
            say(string.format('steering READ-ONLY: reads=%d, public empty=%d, nonempty=%d, unreadable=%d, label changes=%d, resource reads=%d',
                stats.reads or 0,stats.empty or 0,stats.nonempty or 0,stats.unknown or 0,stats.changes or 0,stats.resources or 0))
            say('last steering native text: '..tostring(stats.last or 'none'))
        end
        if NS.DebugNodeGathering then NS:DebugNodeGathering() end
    else say('/fdgcursor start | stop | report | steering on/off. Normal native-size discovery; refine2x enables local double-size refinement, refine1x restores same size. Measured centres save as personal hints; fresh live verification is required for reuse.') end
end
BINDING_HEADER_FDGCURSOR='FDG cursor trial'
BINDING_NAME_FDGCURSOR_TOGGLE='Start / stop cursor sweep'
function FDGCursorToggle() SlashCmdList.FDGCURSOR(trial.saved and 'stop' or 'start') end
