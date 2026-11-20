local _, FRNS_ = ...; local NS = FRNS_.Gathering
-- Personal measured locations are hints, not live sightings or legacy
-- verified-centre provenance. No height/cave state is saved here.
local indexes,pending={},{}
local anonymousIndexes={}
local bundledIndexes={}
local function number(v)
    return not (issecretvalue and issecretvalue(v)) and type(v)=='number' and v==v and math.abs(v)<math.huge
end
local function position(row)
    return type(row)=='table' and number(row.x) and number(row.y) and row.x>=0 and row.x<=1 and row.y>=0 and row.y<=1
end
local function distance(a,b,c)return ((a.x-b.x)*c.w)^2+((a.y-b.y)*c.h)^2 end
local function pixel(c)return 2*c.radius/(c.width*c.scale)end
local function indexFor(map,create,anonymous)
    if not NS.db or not NS.NewNodeLocationIndex then return end
    local key=anonymous and "anonymousRefinedNodeHints" or "refinedNodeHints"
    local cache=anonymous and anonymousIndexes or indexes
    local db=NS.db[key]
    if not db and create then db={version=1,maps={}};NS.db[key]=db end
    if type(db)~='table' or db.version~=1 or type(db.maps)~='table' then return end
    local rows=db.maps[map]
    if not rows and create then rows={};db.maps[map]=rows end
    if type(rows)~='table' then return end
    local index=cache[map]
    if not index or index.rows~=rows then index=NS:NewNodeLocationIndex(rows);cache[map]=index end
    if not index:Build(128) then return nil,'index building' end
    return index
end
local function query(index,p,c,reach,accept)
    local q=index:Query(p.x,p.y,reach/c.w,reach/c.h)
    local found
    for _=1,256 do
        local row,done=index:Next(q)
        if row and position(row) and row.id==p.id and row.kind==p.kind and distance(row,p,c)<=reach^2 and accept(row) then
            if found then return nil,'ambiguous measured locations' end
            found=row
        end
        if done then return found end
    end
    return nil,'query deferred'
end
function NS:FindRefinedNodeHint(node,c,spot)
    if not node or not position(spot) or not c or not number(c.w) or not number(c.h) or c.w<=0 or c.h<=0 then return end
    local index,reason=indexFor(c.map,false,node.anonymous==true)
    local bundled=not node.anonymous and self.BundledRefinedNodeHints
    local rows=bundled and bundled.maps and bundled.maps[c.map]
    local fallback
    if type(rows)=='table' then
        fallback=bundledIndexes[c.map]
        if not fallback or fallback.rows~=rows then fallback=self:NewNodeLocationIndex(rows);bundledIndexes[c.map]=fallback end
        if not fallback:Build(128) then fallback=nil end
    end
    if not index and not fallback then return nil,reason end
    local p=pixel(c);local reach=(9*c.iconScale+2)*p
    local function lookup(source)
    return query(source,{id=node.id,kind=node.kind,x=spot.x,y=spot.y},c,reach,function(row)
        return row.version==1 and (row.anonymous==true)==(node.anonymous==true) and number(row.uncertainty) and row.uncertainty>0 and row.uncertainty<=p*3
            and number(row.radiusPixels) and row.radiusPixels>=3 and row.radiusPixels<=32
    end)
    end
    local candidate,why
    if index then candidate,why=lookup(index) end
    if not candidate and not why and fallback then candidate,why=lookup(fallback) end
    if not candidate then return nil,why end
    for _,other in ipairs(self.GatheringNodeCache or {})do
        if other~=node and other.map==c.map and other.id==node.id and other.kind==node.kind
            and distance(other,candidate,c)<(p*18*c.iconScale)^2 then return nil,'competing live observation' end
    end
    local copy={};for k,v in pairs(candidate)do copy[k]=v end
    return copy
end
local function save(entry)
    local row,c=entry.row,entry.ctx
    local index=indexFor(c.map,true,row.anonymous==true)
    if not index then return false end
    local match,reason=query(index,row,c,3,function(old)
        return old.version==1 and number(old.pixel) and number(old.uncertainty) and old.uncertainty>0 and distance(old,row,c)<=math.min(3,old.pixel,row.pixel)^2
    end)
    if reason then NS.refinedNodeHintStatus=reason;return reason~='query deferred' end
    if match then
        if row.uncertainty<match.uncertainty then
            local x,y=match.x,match.y
            for k,v in pairs(row)do match[k]=v end
            match.radiusPixels=row.radiusPixels;match.positionOnly=row.positionOnly
            index:Move(match,x,y)
        else
            -- A new full measurement can update the native hit fingerprint
            -- without degrading a more precise historical coordinate.
            if row.radiusPixels then match.radiusPixels=row.radiusPixels;match.positionOnly=nil end
        end
    else
        index.rows[#index.rows+1]=row;index:Append(row)
    end
    NS.refinedNodeHintStatus='saved measured '..tostring(row.kind)..':'..tostring(row.id)
    return true
end
function NS:SaveRefinedNodeHint(node,c,group)
    if not node or not node.manualRefined or not node.cursorSweepObservation or not position(node)
        or not c or not number(c.map) or not group then return false end
    if node.anonymous and not ((node.kind=="herb" and node.id==-2383) or (node.kind=="ore" and node.id==-2580)) then return false end
    local p=pixel(c)
    if not number(node.uncertainty) or node.uncertainty<=0 or node.uncertainty>3*p then
        self.refinedNodeHintStatus='not saved: centre uncertainty exceeds measured hint limit';return false
    end
    local radius=group.hitbox and number(group.hitbox.radius) and group.hitbox.radius/p/c.iconScale
    if not number(radius) or radius<3 or radius>32 then
        if not node.anonymous then return false end
        radius=nil -- Precise centre still schedules a fresh native check.
    end
    local entry={row={version=1,id=node.id,kind=node.kind,x=node.x,y=node.y,uncertainty=node.uncertainty,
        radiusPixels=radius,positionOnly=not radius or nil,pixel=p,anonymous=node.anonymous==true or nil},ctx={map=c.map,w=c.w,h=c.h}}
    local ok,result=pcall(save,entry)
    if ok and result then return true end
    if not ok then entry.retryAt=GetTime()+1;self.refinedNodeHintStatus='save deferred: '..tostring(result) end
    if #pending>=64 then self.refinedNodeHintStatus='save queue full';return false end
    pending[#pending+1]=entry
    if ok then self.refinedNodeHintStatus='measured location queued while indexing' end
    return true
end
function NS:ProcessRefinedNodeHintSaves()
    local entry=pending[1]
    if not entry or entry.retryAt and GetTime()<entry.retryAt then return end
    local ok,result=pcall(save,entry)
    if ok and result then table.remove(pending,1)
    elseif not ok then entry.retryAt=GetTime()+1;self.refinedNodeHintStatus='save deferred: '..tostring(result)end
end
