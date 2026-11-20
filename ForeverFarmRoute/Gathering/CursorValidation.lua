local _, FRNS_ = ...; local NS = FRNS_.Gathering
local trial=NS.CursorSweepTrial
-- Targeted real-hover rechecks; only public empty samples can retire a live
-- picture. This module never queries virtual hover or touches saved history.
local function distance(a,b,c)return ((a.x-b.x)*c.w)^2+((a.y-b.y)*c.h)^2 end
local function pixel(c)return 2*c.radius/(c.width*c.scale)end
local function present(node)
    for _,n in ipairs(NS.GatheringNodeCache)do if n==node then return true end end
end
local function snapshot(c)
    local v={};for _,field in ipairs({'map','w','h','width','height','scale','radius','cos','sin','iconScale'})do v[field]=c[field] end;return v
end
local function sameView(c,v)
    local tolerance={w=.001,h=.001,width=.01,height=.01,scale=.00001,radius=.001,cos=.00001,sin=.00001,iconScale=.00001}
    for field,value in pairs(v)do
        if tolerance[field] then
            if math.abs(c[field]-value)>tolerance[field] then return false end
        elseif c[field]~=value then return false end
    end
    return true
end
local function anchor(node,c)
    if node.manualRefined then return node end
    local hit=node.manualLastHit
    if not node.manualProvisional or not hit or type(hit.pixel)~='number' or type(hit.iconScale)~='number'
        or math.abs(hit.pixel-pixel(c))>.001 or math.abs(hit.iconScale-c.iconScale)>.00001 then return end
    return hit
end
local function eligible(node,c)
    if not (node.cursorSweepObservation or node.manualProvisional) or node.map~=c.map
        or not NS.IsCursorSweepKindTracked or not NS:IsCursorSweepKindTracked(node.kind) then return false end
    local p=pixel(c);local at=anchor(node,c)
    if not at then return false end
    if node.manualRefined and node.uncertainty and node.uncertainty>p*3*c.iconScale then return false end
    if distance(at,c,c)>(c.radius-p*12*c.iconScale)^2 then return false end
    for _,other in ipairs(NS.GatheringNodeCache)do
        if other~=node and other.map==node.map and other.kind==node.kind and other.id==node.id
            and distance(at,anchor(other,c) or other,c)<(p*18*c.iconScale)^2 then return false end
    end
    return true
end
local offsets={{0,0},{4,0},{-4,0},{0,4},{0,-4}}
local function target(job,c)
    if not job.rough then return job.node end
    local offset=offsets[job.point]
    local x,y=offset[1]*pixel(c)*c.iconScale,offset[2]*pixel(c)*c.iconScale
    return {x=job.anchor.x+(x*c.cos-y*c.sin)/c.w,y=job.anchor.y-(y*c.cos+x*c.sin)/c.h}
end
function trial:ResetValidationEvidence()
    local job=self.nodeValidation
    if job then job.count=0;job.since=nil;job.last=nil;job.player=nil end
end
function trial:CancelValidation(reason)
    local job=self.nodeValidation
    if job and job.batch then
        if reason=='node still present' or reason=='missing node retired after sustained public empty hover' then
            self.validationBatchChecked=(self.validationBatchChecked or 0)+1
        else
            self.validationBatchDeferred=(self.validationBatchDeferred or 0)+1
            -- A tooltip/camera interruption is not a completed check. Give
            -- this node one more turn before resuming parked centering.
            -- Bound retries per tracking visit so blocked nodes cannot starve
            -- discovery or tracking swaps. Every retry starts fresh evidence.
            if reason~='tracking changed' and self.validationQueue then
                self.validationRetries=self.validationRetries or {}
                local retries=self.validationRetries[job.node] or 0
                if retries<1 then
                    self.validationRetries[job.node]=retries+1
                    self.validationQueue[#self.validationQueue+1]=job.node
                end
            end
        end
    end
    self.nodeValidation=nil;self.validationStatus=reason or 'recheck deferred'
end
function trial:PrepareValidation(tracking,now)
    if tracking==self.validationKind then return end
    self:CancelValidation('tracking changed')
    self.validationKind=tracking;self.validationReadyAt=now+1
    self.validationQueue={};self.validationQueueIndex=1;self.validationRetries={}
    self.validationBatchChecked=0;self.validationBatchDeferred=0
    for _,node in ipairs(NS.GatheringNodeCache)do
        if (node.cursorSweepObservation or node.manualProvisional) and (node.manualRefined or node.manualLastHit)
            and NS:IsCursorSweepKindTracked(node.kind) then
            self.validationQueue[#self.validationQueue+1]=node
        end
    end
    -- Short tracking windows check least-recently checked memories first, so
    -- later nodes do not starve when a whole batch cannot finish before a swap.
    table.sort(self.validationQueue,function(a,b)return (a.cursorNextValidation or 0)<(b.cursorNextValidation or 0)end)
    self.validationBatchTotal=#self.validationQueue
    self.validationBatchActive=self.validationBatchTotal>0
    if self.validationBatchActive then
        if self.TrackRefinement then self:TrackRefinement(tracking,now,true)end
        self.validationStatus='tracking swapped; checking marked nodes before new discovery'
        self.placed=nil;self.captureAt=nil;self.discoveryAnswer=nil;self.nextDiscovery=nil
        NS.CursorSweepReady=false
    end
end
function trial:ValidationPoint(now)
    self:PrepareValidation(NS:GetCursorSweepTrackingKind(),now)
    if self.refinement or self.refinePending or self.refinementDiscovery
        or self.size~=self.discoverySize then self:CancelValidation();return end
    local c=NS:GetGatheringNodeContext()
    if not c or math.abs(c.width*c.scale-self.discoverySize)>.5 then self:CancelValidation();return end
    if now<(self.validationReadyAt or 0)then return end
    local job=self.nodeValidation
    if job and (not present(job.node) or not eligible(job.node,c) or not sameView(c,job.view) or now-job.start>(job.rough and 6 or job.playerBackground and 2 or 1))then
        self:CancelValidation('recheck context changed/expired');job=nil
    end
    local chosen,batch
    if not job and self.validationBatchActive then
        while self.validationQueue[self.validationQueueIndex]do
            local node=self.validationQueue[self.validationQueueIndex]
            self.validationQueueIndex=self.validationQueueIndex+1
            if present(node) and eligible(node,c) then chosen,batch=node,true;break end
            self.validationBatchDeferred=self.validationBatchDeferred+1
        end
        if not chosen then
            self.validationBatchActive=false;self.validationStatus='marked-node swap checks complete'
            self.placed=nil;self.captureAt=nil;self.nextDiscovery=nil;NS.CursorSweepReady=false
            self.nextNodeValidation=now+1
            return
        end
    end
    if not job and not chosen and now>=(self.nextNodeValidation or 0)then
        for _,node in ipairs(NS.GatheringNodeCache)do
            if eligible(node,c) and now-(node.seen or now)>=2 and now>=(node.cursorNextValidation or 0)
                and (not chosen or (node.cursorNextValidation or 0)<(chosen.cursorNextValidation or 0))then chosen=node end
        end
    end
    if chosen then
        chosen.cursorNextValidation=now+3
        self.validationSerial=(self.validationSerial or 0)+1
        job={node=chosen,view=snapshot(c),start=now,count=0,batch=batch,serial=-900000-self.validationSerial};self.nodeValidation=job
        if not chosen.manualRefined then
            local hit=anchor(chosen,c)
            job.rough=true;job.point=1;job.anchor={x=hit.x,y=hit.y}
        end
        self.nextNodeValidation=now+1
        self.validationStatus='checking '..tostring(chosen.name or chosen.id)
    end
    if not job then return end
    local at=target(job,c)
    local e,n=(at.x-c.x)*c.w,(c.y-at.y)*c.h
    return {(e*c.cos+n*c.sin)/pixel(c),(n*c.cos-e*c.sin)/pixel(c)},job.serial
end
function trial:ValidationRead(c,spot,hits,reliable,nonempty,now,knownPlayersOnly)
    local j=self.nodeValidation
    if not j then return false end
    if not present(j.node) or not eligible(j.node,c) or not sameView(c,j.view) or now-j.start>(j.rough and 6 or j.playerBackground and 2 or 1) then
        self:CancelValidation('recheck context changed');return true
    end
    if not reliable then self:CancelValidation('unreadable recheck');return true end
    if distance(target(j,c),spot,c)>(pixel(c)*.75)^2 then
        j.count=0;j.since=nil;return true
    end
    for _,hit in ipairs(hits)do
        if hit.resource.id==j.node.id and hit.resource.kind==j.node.kind then
            if NS.ObserveCursorSweepNodeHint then NS:ObserveCursorSweepNodeHint(j.node,hit)end
            j.node.seen=now;self:CancelValidation('node still present');return true
        end
    end
    if #hits>0 or nonempty and not knownPlayersOnly then self:CancelValidation('nonempty recheck; retained');return true end
    local background=nonempty and knownPlayersOnly or false
    if j.playerBackground~=background then j.count=0;j.since=nil;j.last=nil;j.player=nil end
    j.playerBackground=background
    if background then self.validationStatus='checking target absence beneath known player labels' end
    local travel=j.player and math.sqrt(distance(j.player,c,c))/pixel(c) or 0
    if j.last and (now-j.last>.15 or travel>1.5)then j.count=0;j.since=nil end
    j.player={x=c.x,y=c.y};j.last=now;j.since=j.since or now;j.count=j.count+1
    if j.count>=(background and 6 or 3) and now-j.since>=(background and .75 or .25) then
        if j.rough and j.point<#offsets then
            j.point=j.point+1;j.count=0;j.since=nil;j.last=nil;j.player=nil
            self.validationSerial=(self.validationSerial or 0)+1;j.serial=-900000-self.validationSerial
            self.placed=nil;self.captureAt=nil;NS.CursorSweepReady=false
            self.validationStatus='checking last-hit neighborhood '..j.point..'/'..#offsets
            return true
        end
        for i,node in ipairs(NS.GatheringNodeCache)do
            if node==j.node then table.remove(NS.GatheringNodeCache,i);break end
        end
        self.missingRetired=(self.missingRetired or 0)+1
        self:CancelValidation('missing node retired after sustained public empty hover')
    end
    return true
end
