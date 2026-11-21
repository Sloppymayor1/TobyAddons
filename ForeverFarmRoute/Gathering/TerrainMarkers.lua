local _, FRNS_ = ...; local NS = FRNS_.Gathering
local map=NS.TerrainMinimap
local markers={pool={},resourcePool={},rxpPool={},rxpFrames={}}
NS.TerrainMarkers=markers
local function public(v)return not (issecretvalue and issecretvalue(v))end
local function number(v)return public(v) and type(v)=='number' and v==v and math.abs(v)<1e8 end
-- Location confidence uses world yards so zoom changes cannot change opacity.
-- Unknown precision stays visibly provisional; refinement flags alone are not precision.
function markers:LocationAlpha(node)
    local uncertainty=node.uncertainty
    if not number(uncertainty) or uncertainty<0 then return 0.4 end
    return 1-0.6*math.max(0,math.min(1,(uncertainty-5)/75))
end
local function safe(fn,...)
    if type(fn)~='function' then return end
    local ok,a,b,c=pcall(fn,...)
    if ok and public(a) and public(b) and public(c) then return a,b,c end
end
local function effectiveScale(region,owner)
    local scale=region and safe(region.GetEffectiveScale,region)
    if number(scale) and scale>0 then return scale end
    local parent=region and safe(region.GetParent,region)
    scale=parent and safe(parent.GetEffectiveScale,parent)
    if number(scale) and scale>0 then return scale end
    return owner and safe(owner.GetEffectiveScale,owner)
end
-- Snapshot public rendered positions before capture moves the native map.
-- Session-only bounded diagnostics; never alter source pins or their anchors.
function markers:SampleNativePins()
    local original=map.original
    self.nativePinSample={at=GetTime(),lines={}}
    local sample=self.nativePinSample
    if not original or not number(original.radius) or original.radius<=0 then sample.status='native geometry unavailable';return end
    local cont,x,y=safe(map.Position,map)
    if not number(cont) or not number(x) or not number(y) then sample.status='player position unavailable';return end
    local rootScale=UIParent and safe(UIParent.GetEffectiveScale,UIParent)
    if not number(rootScale) or rootScale<=0 then sample.status='screen scale unavailable';return end
    local sources={{kind='Questie',points=self:CollectQuestie(cont,x,y,original.radius*2)},
        {kind='RestedXP',points=self:CollectRestedXP(cont,x,y,original.radius*2)}}
    local missingCenter,missingScale=0,0
    sample.providers=string.format('Questie=%d (%s); RestedXP=%d (%s)',#sources[1].points,
        tostring(self.questieStatus or 'not reported'),#sources[2].points,tostring(self.rxpStatus or 'not reported'))
    for _,group in ipairs(sources) do
        for _,point in ipairs(group.points) do
            if #sample.lines>=12 then break end
            local source=point.source
            local art=group.kind=='Questie' and source.texture or source.text
            local cx,cy
            if art then cx,cy=safe(art.GetCenter,art) end
            local scale=effectiveScale(art,source)
            local positionKind='artwork'
            if not number(cx) or not number(cy) then
                cx,cy=safe(source.GetCenter,source)
                scale=effectiveScale(source)
                positionKind='pin-frame'
            end
            if not number(cx) or not number(cy) then missingCenter=missingCenter+1 end
            if not number(scale) then missingScale=missingScale+1 end
            if number(cx) and number(cy) and number(scale) then
                local nx,ny=cx*scale/rootScale-original.x,cy*scale/rootScale-original.y
                local px=point.x*original.width+(point.offsetX or 0)
                local py=point.y*original.height+(point.offsetY or 0)
                local w=art and safe(art.GetWidth,art)
                local h=art and safe(art.GetHeight,art)
                sample.lines[#sample.lines+1]=string.format('%s native=(%.1f,%.1f) mirror=(%.1f,%.1f) delta=(%.1f,%.1f) scale=%.3f size=%.1fx%.1f source=%s',
                    group.kind,nx,ny,px,py,px-nx,py-ny,scale/rootScale,
                    number(w) and w*scale/rootScale or 0,number(h) and h*scale/rootScale or 0,positionKind)
            end
        end
    end
    sample.status=(#sample.lines>0 and 'before quick capture' or 'no readable nearby source artwork')
        ..'; '..sample.providers..'; unavailable centre='..missingCenter..' scale='..missingScale
end
function markers:ReportNativePins()
    local sample=self.nativePinSample
    NS.Print('Pin comparison: '..(sample and sample.status or 'no quick scan sampled yet'))
    if not sample then return end
    for _,line in ipairs(sample.lines) do NS.Print(line) end
end
function markers:ResourceAlpha(node)
    local alpha=self:LocationAlpha(node)
    if NS.IsCursorSweepKindTracked and safe(NS.IsCursorSweepKindTracked,NS,node.kind)==false then
        alpha=math.min(alpha,0.8)
    end
    return alpha
end
function markers:World(id,pos)
    if not number(id) or not public(pos) or not pos or not C_Map then return end
    local continent,world=safe(C_Map.GetWorldPosFromMapPos,id,pos)
    if not number(continent) or not world then return end
    local x,y=safe(world.GetXY,world)
    if number(x) and number(y) then return continent,x,y end
end
function markers:Unit(unit)
    if not C_Map then return end
    local id=safe(C_Map.GetBestMapForUnit,unit)
    if not number(id) then return end
    local pos=safe(C_Map.GetPlayerMapPosition,id,unit)
    if not pos then return end
    local x,y=safe(pos.GetXY,pos)
    if not number(x) or not number(y) or x==0 and y==0 then return end
    return self:World(id,pos)
end
-- Mirror only RXP's registered minimap pins. Guide selection and pin
-- generation stay owned by RXP; scanner-suppressed frame alpha is not data.
-- HBD world coordinates are not C_Map's vector axes and can also carry
-- instance transforms. Convert through the pin's own UI map, never mix them.
function markers:RestedXPWorld(data,coordinates)
    if not public(data) or type(data)~='table' or not number(data.uiMapID)
        or not number(data.instanceID) or not number(data.x) or not number(data.y)
        or not coordinates or not CreateVector2D then return end
    local x,y=safe(coordinates.GetZoneCoordinatesFromWorldInstance,coordinates,
        data.x,data.y,data.instanceID,data.uiMapID)
    if not number(x) or not number(y) or x<0 or x>1 or y<0 or y>1 then return end
    return self:World(data.uiMapID,CreateVector2D(x,y))
end
function markers:CollectRestedXP(continent,x,y,span)
    self.rxpStatus='not available';self.rxpCount=0
    local result={}
    local rxp=_G.RXP
    if not public(rxp) or type(rxp)~='table' or not LibStub or not number(span) or span<=0 then return result end
    local settings=rxp.settings
    local profile=public(settings) and type(settings)=='table' and settings.profile
    if not public(profile) or type(profile)~='table' then return result end
    if not public(profile.hideMiniMapPins) or not public(profile.disableMapPins)
        or profile.hideMiniMapPins or profile.disableMapPins then self.rxpStatus='hidden by RestedXP';return result end
    local hbd=safe(function()return LibStub('HereBeDragons-Pins-2.0',true)end)
    if not public(hbd) or type(hbd)~='table' then return result end
    local coordinates=safe(function()return LibStub('HereBeDragons-2.0',true)end)
    if not public(coordinates) or type(coordinates)~='table' then return result end
    local registry,positions,active=hbd.minimapPinRegistry,hbd.minimapPins,hbd.activeMinimapPins
    if not public(registry) or type(registry)~='table' or not public(positions) or type(positions)~='table'
        or not public(active) or type(active)~='table' then return result end
    local pins=registry[rxp]
    if not public(pins) or type(pins)~='table' then self.rxpStatus='no minimap pins';return result end
    local radius=C_Minimap and safe(C_Minimap.GetViewRadius)
    if not number(radius) or radius<=0 then radius=safe(hbd.GetMinimapView,hbd) end
    if not number(radius) or radius<=0 then self.rxpStatus='native range unavailable';return result end
    self.rxpStatus='native range '..string.format('%.0f',radius)
    local pin
    for _=1,128 do
        pin=next(pins,pin)
        if not pin then break end
        if not public(pin) then self.rxpStatus='unreadable pin';break end
        local data=positions[pin]
        if public(pin) and type(pin)=='table' and public(data) and type(data)=='table'
            and public(active[pin]) and active[pin] and number(data.instanceID)
            and number(data.x) and number(data.y) and public(data.floatOnEdge) then
            local cont,wx,wy=self:RestedXPWorld(data,coordinates)
            local text=public(pin.text) and pin.text
            local label=text and safe(text.GetText,text)
            local model=public(pin.activeObject) and pin.activeObject
            local alpha=1
            if type(model)=='table' then alpha=model.opacity end
            if not public(alpha) then alpha=0 elseif not number(alpha) then alpha=1 end
            alpha=math.max(0,math.min(1,alpha))
            if cont==continent and number(wx) and number(wy) and type(label)=='string' and #label>0 and #label<=256 and alpha>0 then
                local dx,dy=map:ProjectOffset((y-wy)/span,(wx-x)/span)
                if (wx-x)^2+(wy-y)^2<=radius^2 and math.abs(dx)<=.44 and math.abs(dy)<=.44 then
                    local r,g,b=safe(text.GetTextColor,text)
                    if not number(r) or not number(g) or not number(b) then r,g,b=1,.82,0 end
                    local font,size,flags=safe(text.GetFont,text)
                    local scale=effectiveScale(text,pin)
                    local rootScale=UIParent and safe(UIParent.GetEffectiveScale,UIParent)
                    local factor=number(scale) and number(rootScale) and rootScale>0 and scale/rootScale or 1
                    local ox,oy=0,0
                    if text.GetPoint then
                        local ok,anchor,relative,relativeAnchor,dx,dy=pcall(text.GetPoint,text,1)
                        if ok and anchor=='CENTER' and relative==pin and relativeAnchor=='CENTER' and number(dx) and number(dy) then
                            ox,oy=dx*factor,dy*factor
                        end
                    end
                    size=number(size) and math.max(8,math.min(24,size)) or 12
                    result[#result+1]={x=dx,y=dy,text=label,r=r,g=g,b=b,size=size,alpha=alpha,source=pin,model=model,font=font,flags=flags,offsetX=ox,offsetY=oy,fontScale=factor,
                        key=string.format('%d:%.8f:%.8f:%s',data.uiMapID,wx,wy,label)}
                    if #result>=64 then self.rxpStatus='pin limit';break end
                end
            end
        end
    end
    table.sort(result,function(a,b)return a.key<b.key end)
    self.rxpCount=#result
    return result
end
-- Questie's private HBD fork owns these registrations. Never move or reparent
-- its frames: the capture minimap and Questie's world map keep their own pins.
local function questieArtwork(region,factor,baseWidth,baseHeight,optional)
    if not region or optional and safe(region.IsShown,region)~=true then return end
    local texture=safe(region.GetTexture,region)
    local atlas=safe(region.GetAtlas,region)
    if not number(texture) and type(texture)~='string' and type(atlas)~='string' then return end
    local r,g,b=safe(region.GetVertexColor,region)
    r=number(region.r) and region.r or number(r) and r or 1
    g=number(region.g) and region.g or number(g) and g or 1
    b=number(region.b) and region.b or number(b) and b or 1
    local alpha=number(region.a) and region.a or safe(region.GetAlpha,region)
    alpha=number(alpha) and math.max(0,math.min(1,alpha)) or 1
    local coords={0,1,0,1}
    if region.GetTexCoord then
        local ok,values=pcall(function()return {region:GetTexCoord()}end)
        if ok and (#values==4 or #values==8) then
            local valid=true
            for _,v in ipairs(values)do if not number(v) then valid=false end end
            if valid then coords=values end
        end
    end
    local w,h=safe(region.GetWidth,region),safe(region.GetHeight,region)
    return {texture=texture,atlas=atlas,coords=coords,r=r,g=g,b=b,alpha=alpha,
        width=number(w) and w*factor or baseWidth,height=number(h) and h*factor or baseHeight,
        blend=safe(region.GetBlendMode,region) or 'BLEND'}
end
local strataOrder={BACKGROUND=1,LOW=2,MEDIUM=3,HIGH=4,DIALOG=5,FULLSCREEN=6,FULLSCREEN_DIALOG=7,TOOLTIP=8}
function markers:CollectQuestie(continent,x,y,span)
    local result={}
    self.questieStatus='not available';self.questieCount=0
    local questie=_G.Questie
    if not public(questie) or type(questie)~='table' then return result end
    local profile=questie.db and questie.db.profile
    if type(profile)~='table' or profile.enabled~=true or profile.enableMiniMapIcons~=true then
        self.questieStatus='disabled';return result
    end
    -- Current Questie owns these as modules; older releases used private LibStub names.
    -- Resolve both from the same owner so coordinate transforms match its pins.
    local loader=_G.QuestieLoader
    local pins,coordinates
    if public(loader) and type(loader)=='table' and type(loader.ImportModule)=='function' then
        pins=safe(loader.ImportModule,loader,'HBDPins')
        coordinates=safe(loader.ImportModule,loader,'HBD')
    end
    if not pins or not coordinates then
        pins=safe(function()return LibStub and LibStub('HereBeDragonsQuestie-Pins-2.0',true)end)
        coordinates=safe(function()return LibStub and LibStub('HereBeDragonsQuestie-2.0',true)end)
    end
    local registry=pins and pins.minimapPinRegistry and pins.minimapPinRegistry[questie]
    local active=pins and pins.activeMinimapPins
    if type(registry)~='table' or type(active)~='table' or not coordinates then return result end
    local radius=safe(pins.GetMinimapView,pins)
    if not number(radius) or radius<=0 then radius=C_Minimap and safe(C_Minimap.GetViewRadius) end
    if not number(radius) or radius<=0 then self.questieStatus='native range unavailable';return result end
    self.questieStatus='native range '..string.format('%.0f',radius)
    local pin
    for _=1,2048 do
        pin=next(registry,pin)
        if not pin then break end
        if not public(pin) then break end
        local data=pins.minimapPins and pins.minimapPins[pin]
        if public(active[pin]) and active[pin] and type(pin)=='table' and pin.miniMapIcon==true and pin.hidden~=true and pin._hidden_by_flash~=true
            and type(data)=='table' and public(data) and pin.texture then
            local cont,wx,wy=self:RestedXPWorld(data,coordinates)
            local texture=safe(pin.texture.GetTexture,pin.texture)
            if cont==continent and number(wx) and number(wy) and (number(texture) or type(texture)=='string') then
                local dx,dy=map:ProjectOffset((y-wy)/span,(wx-x)/span)
                -- Clip in world yards before projection; never stack distant pins at the edge.
                if (wx-x)^2+(wy-y)^2<=radius^2 and math.abs(dx)<=.44 and math.abs(dy)<=.44 then
                    local r,g,b=safe(pin.texture.GetVertexColor,pin.texture)
                    if not number(r) or not number(g) or not number(b) then r,g,b=1,1,1 end
                    local size=safe(pin.texture.GetWidth,pin.texture) or safe(pin.GetWidth,pin)
                    local height=safe(pin.texture.GetHeight,pin.texture) or safe(pin.GetHeight,pin) or size
                    local scale=effectiveScale(pin.texture,pin)
                    local rootScale=UIParent and safe(UIParent.GetEffectiveScale,UIParent)
                    local factor=number(scale) and number(rootScale) and rootScale>0 and scale/rootScale or 1
                    size=number(size) and math.max(1,math.min(128,size*factor)) or 16
                    height=number(height) and math.max(1,math.min(128,height*factor)) or size
                    local level=safe(pin.GetFrameLevel,pin)
                    local strata=safe(pin.GetFrameStrata,pin)
                    result[#result+1]={source=pin,x=dx,y=dy,texture=texture,r=r,g=g,b=b,size=size,height=height,
                        level=number(level) and level or 0,strata=strataOrder[strata] or 3,key=tostring(pin),
                        main=questieArtwork(pin.texture,factor,size,height),
                        overlay=questieArtwork(pin.overlayTexture,factor,size,height,true),
                        glow=questieArtwork(pin.glowTexture,factor,size,height,true),
                        party=pin.data and pin.data.ObjectiveData and pin.data.ObjectiveData.IsPartyObjective==true}
                    if #result>=256 then self.questieStatus='pin limit';break end
                end
            end
        end
    end
    table.sort(result,function(a,b)
        if a.strata~=b.strata then return a.strata<b.strata end
        if a.level~=b.level then return a.level<b.level end
        return a.key<b.key
    end)
    self.questieCount=#result
    return result
end
-- Patrols are separate from HBD icon registrations. Read Questie's live registry
-- and let its renderer preserve smoothing, outlined colours and configured width.
-- Clip each segment before smoothing: frame clipping alone still leaves the
-- renderer maintaining textures for the entire zone-wide patrol.
local function patrolSegment(ax,ay,bx,by,left,right,bottom,top)
    local dx,dy=bx-ax,by-ay
    local first,last=0,1
    local function edge(p,q)
        if p==0 then return q>=0 end
        local t=q/p
        if p<0 then if t>last then return false end;first=math.max(first,t)
        else if t<first then return false end;last=math.min(last,t) end
        return true
    end
    if edge(-dx,ax-left) and edge(dx,right-ax) and edge(-dy,ay-bottom) and edge(dy,top-ay) then
        return ax+dx*first,ay+dy*first,ax+dx*last,ay+dy*last
    end
end
function markers:DrawQuestiePatrols(continent,x,y,span,width,height)
    self.questiePatrolCount=0
    local loader=_G.QuestieLoader
    local profile=_G.Questie and Questie.db and Questie.db.profile
    if not profile or profile.enabled~=true or profile.enableMiniMapIcons~=true
        or not loader or type(loader.ImportModule)~='function' then
        if self.questiePatrolRoot then self.questiePatrolRoot:Hide() end;return
    end
    local paths=safe(loader.ImportModule,loader,'QuestieWaypoints')
    local renderer=safe(loader.ImportModule,loader,'WaypointRenderer')
    if not paths or type(paths.paths)~='table' or not renderer then
        if self.questiePatrolRoot then self.questiePatrolRoot:Hide() end;return
    end
    local routes={}
    local inspected=0
    for path in pairs(paths.paths) do
        inspected=inspected+1;if inspected>2048 then break end
        local alpha=safe(paths.MinimapAlpha,path)
        if number(alpha) and alpha>0 and type(path.points)=='table' then
            local rank=alpha+(safe(paths.IsHighlighted,path) and 2 or 0)
            local key=path.route or path
            if not routes[key] or rank>routes[key].rank then routes[key]={path=path,alpha=alpha,rank=rank} end
        end
    end
    if not next(routes) then
        if self.questiePatrolRenderer then self.questiePatrolRenderer:Clear() end
        self.questiePatrolViews={};self.questiePatrolEntries={}
        if self.questiePatrolRoot then self.questiePatrolRoot:Hide() end;return
    end
    if not self.questiePatrolRoot then
        local root=CreateFrame('Frame',nil,map.frame)
        root:SetAllPoints(map.frame);root:SetFrameLevel(map.frame:GetFrameLevel()+1)
        root:EnableMouse(false);root:SetClipsChildren(true)
        local canvas=CreateFrame('Frame',nil,root)
        canvas:SetSize(1,1);canvas:SetPoint('TOPLEFT',map.frame,'CENTER',0,0)
        canvas:EnableMouse(false)
        local mask=root:CreateMaskTexture();mask:SetAllPoints(map.frame)
        self.questiePatrolRoot,self.questiePatrolMask=root,mask
        self.questiePatrolRenderer=renderer.New(canvas,{mask})
        self.questiePatrolViews={}
    end
    local round=NS.TerrainQuestAreas and NS.TerrainQuestAreas:IsRoundMinimap()
    local maskTexture=round and 'Interface\\CharacterFrame\\TempPortraitAlphaMask' or 'Interface\\BUTTONS\\WHITE8X8'
    if self.questiePatrolMaskTexture~=maskTexture then
        self.questiePatrolMask:SetTexture(maskTexture);self.questiePatrolMaskTexture=maskTexture
    end
    self.questiePatrolEntries=self.questiePatrolEntries or {}
    self.questiePatrolWorld=self.questiePatrolWorld or setmetatable({},{__mode='k'})
    local views,entries={},{}
    local budget=8192
    for key,item in pairs(routes) do
        local path=item.path
        local world=self.questiePatrolWorld[path]
        if not world or world.points~=path.points or world.map~=path.uiMapId then
            world={points=path.points,map=path.uiMapId,runs={}}
            local run
            for i,point in ipairs(path.points) do
                if i>4096 or budget<=0 then break end
                budget=budget-1
                local cont,wx,wy
                if number(point.x) and number(point.y) then
                    cont,wx,wy=self:World(path.uiMapId,CreateVector2D(point.x/100,point.y/100))
                end
                if number(cont) and number(wx) and number(wy) then
                    if not run or run.continent~=cont then run={continent=cont};world.runs[#world.runs+1]=run end
                    run[#run+1]={x=wx,y=wy}
                    world.minX=math.min(world.minX or wx,wx);world.maxX=math.max(world.maxX or wx,wx)
                    world.minY=math.min(world.minY or wy,wy);world.maxY=math.max(world.maxY or wy,wy)
                else run=nil end
            end
            -- Do not retain partial geometry if the per-update work budget ran out.
            if budget>0 then self.questiePatrolWorld[path]=world end
        end
        local reach=span*.55
        if world.minX and world.minX<=x+reach and world.maxX>=x-reach
            and world.minY<=y+reach and world.maxY>=y-reach then
            local entry=self.questiePatrolEntries[key]
            local rebuild=not entry or entry.world~=world or entry.continent~=continent
                or entry.span~=span or entry.width~=width or entry.height~=height or entry.rotation~=map.rotation
                or math.max(math.abs(x-entry.x),math.abs(y-entry.y))>span*.2
            local color=safe(paths.Color,path)
            local style={thickness=profile.waypointWidth or 2,color=color,alpha=item.alpha,
                frameLevel=self.questiePatrolRoot:GetFrameLevel()}
            if type(color)=='table' then
                if rebuild then
                    local runs={}
                    local reach=span*.8 -- view plus movement margin
                    for _,source in ipairs(world.runs) do
                        if source.continent==continent and #source>=2 then
                            local run
                            for i=2,#source do
                                local a,b=source[i-1],source[i]
                                local ax,ay,bx,by=patrolSegment(a.x,a.y,b.x,b.y,x-reach,x+reach,y-reach,y+reach)
                                if ax then
                                     local px,py=map:ProjectOffset((y-ay)/span,(x-ax)/span)
                                     local qx,qy=map:ProjectOffset((y-by)/span,(x-bx)/span)
                                     px,py=px*width,py*height
                                    local last=run and run[#run]
                                    if not last or math.abs(last.x-px)>.0001 or math.abs(last.y-py)>.0001 then
                                        run={{x=px,y=py}};runs[#runs+1]=run
                                    end
                                     run[#run+1]={x=qx*width,y=qy*height}
                                else run=nil end
                            end
                        end
                    end
                    if #runs>0 then
                        local view=self.questiePatrolRenderer:Draw(self.questiePatrolViews[key],runs,style)
                         entry={world=world,continent=continent,span=span,width=width,height=height,x=x,y=y,view=view,rotation=map.rotation}
                    else entry=nil end
                elseif self.questiePatrolRenderer.Restyle and (not entry.style
                    or entry.style.thickness~=style.thickness or entry.style.alpha~=style.alpha
                    or entry.style.frameLevel~=style.frameLevel
                    or entry.style.color[1]~=color[1] or entry.style.color[2]~=color[2]
                    or entry.style.color[3]~=color[3] or entry.style.color[4]~=color[4]) then
                    self.questiePatrolRenderer:Restyle(entry.view,style)
                end
                if entry then
                    entry.style=style
                    local view=entry.view
                     local dx,dy=map:ProjectOffset((y-entry.y)/span,(entry.x-x)/span)
                     dx,dy=dx*width,dy*height
                    if entry.dx~=dx or entry.dy~=dy then
                        view:ClearAllPoints();view:SetPoint('TOPLEFT',view:GetParent(),'TOPLEFT',dx,dy)
                        entry.dx,entry.dy=dx,dy
                    end
                    if not view:IsShown() then view:Show() end
                    views[key]=view;entries[key]=entry;self.questiePatrolCount=self.questiePatrolCount+1
                end
            end
        end
    end
    for key,view in pairs(self.questiePatrolViews) do
        if not views[key] then self.questiePatrolRenderer:Release(view) end
    end
    self.questiePatrolEntries=entries
    self.questiePatrolViews=views
    self.questiePatrolRoot:Show()
end
function markers:HideQuestie(from)
    if not from and self.questiePatrolRoot then self.questiePatrolRoot:Hide() end
    for i=from or 1,#(self.questiePool or {}) do
        local pin=self.questiePool[i];pin:Hide()
        if pin.questieOverlay then pin.questieOverlay:Hide() end
        if pin.questieGlow then pin.questieGlow:Hide() end
    end
end
local function drawQuestieArtwork(texture,art,party)
    if art.atlas and art.atlas~='' and texture.SetAtlas then texture:SetAtlas(art.atlas)
    else texture:SetTexture(art.texture);texture:SetTexCoord(unpack(art.coords)) end
    texture:SetSize(art.width,art.height)
    texture:SetVertexColor(art.r,art.g,art.b)
    texture:SetAlpha(art.alpha*(party and .5 or 1))
    if texture.SetBlendMode then texture:SetBlendMode(art.blend) end
end
function markers:DrawQuestie(continent,x,y,span,width,height)
    local points=self:CollectQuestie(continent,x,y,span)
    self.questiePool=self.questiePool or {}
    for i,point in ipairs(points) do
        local pin=self.questiePool[i]
        if not pin then
            pin=(self.layer or map.frame):CreateTexture(nil,'OVERLAY',nil,2)
            if pin.SetTexelSnappingBias then pin:SetTexelSnappingBias(0) end
            if pin.SetSnapToPixelGrid then pin:SetSnapToPixelGrid(false) end
            self.questiePool[i]=pin
        end
        local px,py=point.x*width,point.y*height
        if pin.qx~=px or pin.qy~=py then
            pin:ClearAllPoints();pin:SetPoint('CENTER',map.frame,'CENTER',px,py);pin.qx=px;pin.qy=py
        end
        drawQuestieArtwork(pin,point.main,point.party)
        for _,part in ipairs({'glow','overlay'}) do
            local art=point[part]
            local key=part=='glow' and 'questieGlow' or 'questieOverlay'
            local image=pin[key]
            if art then
                if not image then
                    image=(self.layer or map.frame):CreateTexture(nil,'OVERLAY',nil,part=='glow' and 1 or 3)
                    if image.SetTexelSnappingBias then image:SetTexelSnappingBias(0) end
                    if image.SetSnapToPixelGrid then image:SetSnapToPixelGrid(false) end
                    pin[key]=image
                end
                image:ClearAllPoints();image:SetPoint('CENTER',map.frame,'CENTER',px,py)
                drawQuestieArtwork(image,art,point.party);image:Show()
            elseif image then image:Hide() end
        end
        if not pin:IsShown() then pin:Show() end
    end
    self:HideQuestie(#points+1)
    self:DrawQuestiePatrols(continent,x,y,span,width,height)
end
function markers:IsRestedXPHoverOwner(owner)
    return owner~=nil and owner==self.rxpHover and owner.activeObject~=nil
end
function markers:LeaveRestedXP(frame)
    if self.rxpHover~=frame then return end
    self.rxpHover=nil
    if GameTooltip and safe(GameTooltip.GetOwner,GameTooltip)==frame then
        if frame.rxpLeave then safe(frame.rxpLeave,frame) end
        if safe(GameTooltip.GetOwner,GameTooltip)==frame and GameTooltip.Hide then GameTooltip:Hide()end
    end
end
function markers:EnterRestedXP(frame)
    if not frame.activeObject or type(frame.rxpEnter)~='function' then return end
    self.rxpHover=frame
    local trial=NS.CursorSweepTrial
    if trial then
        trial.normalTooltip=true
        if trial.MarkTooltipSource then trial:MarkTooltipSource(false)end
    end
    local ok=pcall(frame.rxpEnter,frame)
    if not ok then self:LeaveRestedXP(frame)end
end
function markers:HideRestedXP(from)
    for i=from or 1,#self.rxpPool do
        local frame=self.rxpFrames[i]
        if frame then self:LeaveRestedXP(frame);frame.activeObject=nil;frame:Hide()end
        self.rxpPool[i]:Hide()
    end
end
function markers:DrawRestedXP(continent,x,y,span,width,height)
    local points=self:CollectRestedXP(continent,x,y,span)
    for i,point in ipairs(points)do
        local frame=self.rxpFrames[i]
        local label=self.rxpPool[i]
        if not frame then
            frame=CreateFrame('Frame',nil,self.layer or map.frame)
            frame:Hide()
            frame:EnableMouse(true)
            if frame.SetMouseClickEnabled then frame:SetMouseClickEnabled(false)end
            if frame.SetMouseMotionEnabled then frame:SetMouseMotionEnabled(true)end
            if frame.EnableMouseWheel then frame:EnableMouseWheel(false)end
            if frame.SetFrameLevel and map.frame.GetFrameLevel then frame:SetFrameLevel(map.frame:GetFrameLevel()+4)end
            frame:SetScript('OnEnter',function(f)self:EnterRestedXP(f)end)
            frame:SetScript('OnLeave',function(f)self:LeaveRestedXP(f)end)
            frame:SetScript('OnHide',function(f)self:LeaveRestedXP(f)end)
            label=frame:CreateFontString(nil,'OVERLAY','GameFontNormal');self.rxpPool[i]=label
            label:SetAllPoints(frame)
            self.rxpFrames[i]=frame
        end
        if frame.key~=point.key or frame.activeObject~=point.model then self:LeaveRestedXP(frame)end
        frame.key=point.key;frame.activeObject=point.model
        frame.rxpEnter=safe(point.source.GetScript,point.source,'OnEnter')
        frame.rxpLeave=safe(point.source.GetScript,point.source,'OnLeave')
        local px,py=point.x*width,point.y*height
        if frame.px~=px or frame.py~=py then
            frame:ClearAllPoints();frame:SetPoint('CENTER',map.frame,'CENTER',px,py);frame.px,frame.py=px,py
        end
        if frame.hitSize~=point.size then
            frame:SetSize(math.max(20,point.size+8),math.max(20,point.size+8));frame.hitSize=point.size
        end
        if frame.labelText~=point.text then label:SetText(point.text);frame.labelText=point.text end
        local size=point.size*(point.fontScale or 1)
        if frame.labelSize~=size or frame.labelFont~=point.font or frame.labelFlags~=point.flags then
            label:SetFontObject('GameFontNormal')
            local font=point.font or safe(label.GetFont,label)
            if font and label.SetFont then label:SetFont(font,size,point.flags or 'OUTLINE')end
            frame.labelSize=size;frame.labelFont=point.font;frame.labelFlags=point.flags
        end
        local ox,oy=point.offsetX or 0,point.offsetY or 0
        if frame.labelX~=ox or frame.labelY~=oy then
            label:ClearAllPoints();label:SetPoint('CENTER',frame,'CENTER',ox,oy)
            frame.labelX,frame.labelY=ox,oy
        end
        label:SetTextColor(point.r,point.g,point.b);label:SetAlpha(point.alpha)
        if safe(label.IsShown,label)~=true then label:Show()end
        if safe(frame.IsShown,frame)~=true then frame:Show()end
    end
    self:HideRestedXP(#points+1)
end
function markers:Collect(continent,x,y,span,now)
    self.candidates=0;self.worldCandidates=0
    local result={}
    local function add(kind,cont,wx,wy,texture,size,alpha)
        if cont~=continent or not number(wx) or not number(wy) then return end
        local east,north=map:ProjectOffset((y-wy)/span,(wx-x)/span)
        -- Keep the whole icon within the terrain; distant waypoints stay on its edge.
        if kind=='waypoint' or kind=='corpse' then
            local ratio=math.max(1,math.abs(east)/0.44,math.abs(north)/0.44)
            east,north=east/ratio,north/ratio
        elseif math.abs(east)>0.44 or math.abs(north)>0.44 then return end
        result[#result+1]={kind=kind,x=east,y=north,texture=texture,size=size,alpha=alpha or 1}
        return result[#result]
    end
    local db=NS.db and NS.db.hud or {}
    local farm=NS.QuickScanner and NS.QuickScanner.farmMap
    local size=number(db.nodeIconSize) and math.max(8,math.min(32,db.nodeIconSize)) or 14
    if farm then size=FRNS_.NodeIconPixels() end -- /farm size
    local cache=NS.GatheringNodeCache or {}
    local context=NS.GetGatheringNodeContext and NS:GetGatheringNodeContext()
    for i=1,math.min(#cache,128) do
        local node=cache[i]
        if node and number(node.seen) and now-node.seen>=0 and now-node.seen<=(NS.GetGatheringObservationTTL and NS:GetGatheringObservationTTL(node) or node.observationTTL or 180)
            and (node.centered or node.fastLocation or node.manualProvisional)
            and not (NS.IsCursorObservationAmbiguous and NS:IsCursorObservationAmbiguous(node,context,now))
            and number(node.x) and number(node.y) and node.icon and CreateVector2D then
            self.candidates=self.candidates+1
            -- Match normal HUD placement: hidden-name quick/manual observations
            -- require a usable historical anchor, never their rough hit point.
            local x,y=node.x,node.y
            if node.anonymous and (node.quickScanObservation or NS.CursorSweepActive and NS.CursorSweepTrial and NS.CursorSweepTrial.workflow and NS.CursorSweepTrial.workflow:Allows('knownOnly') or not node.cursorSweepObservation and not NS.CursorSweepActive) then
                local known,alternative,reason,anchor,types
                if NS.GetAnonymousNodeArtwork then known,alternative,reason,anchor,types=NS:GetAnonymousNodeArtwork(node) end
                node.anonymousArtworkStatus=reason or 'location services unavailable'
                if not node.manualKeyAnchor then node.manualPossibleTypes=types end
                if known and anchor then x,y=anchor.x,anchor.y else x,y=nil,nil end
            end
            if number(x) and number(y) then
                local cont,wx,wy=self:World(node.map,CreateVector2D(x,y))
                if number(cont) and number(wx) and number(wy) then self.worldCandidates=self.worldCandidates+1 end
                local point=add('gathering',cont,wx,wy,node.icon,size,self:ResourceAlpha(node))
                if point then point.node=node end
            end
        end
    end
    local raid=safe(IsInRaid)==true
    local count=raid and safe(GetNumGroupMembers) or safe(GetNumSubgroupMembers)
    count=number(count) and math.min(raid and 40 or 4,math.max(0,count)) or 0
    for i=1,count do
        local unit=(raid and 'raid' or 'party')..i
        if safe(UnitIsUnit,unit,'player')~=true then
            local cont,wx,wy=self:Unit(unit)
            add('party',cont,wx,wy,'Interface\\Minimap\\Ping\\ping5',10)
        end
    end
    if C_Map then
        local point=safe(C_Map.GetUserWaypoint)
        if point and type(point)=='table' and public(point.uiMapID) and public(point.position) then
            local cont,wx,wy=self:World(point.uiMapID,point.position)
            add('waypoint',cont,wx,wy,'Interface\\Minimap\\Ping\\ping5',20)
        end
    end
    if safe(UnitIsDeadOrGhost,'player')==true and C_DeathInfo and C_Map then
        local id=safe(C_Map.GetBestMapForUnit,'player')
        if number(id) then
            local pos=safe(C_DeathInfo.GetCorpseMapPosition,id)
            if pos then
                local px,py=safe(pos.GetXY,pos)
                if number(px) and number(py) and px>=0 and px<=1 and py>=0 and py<=1 and not (px==0 and py==0) then
                    local cont,wx,wy=self:World(id,pos)
                    add('corpse',cont,wx,wy,'Interface\\Minimap\\POIIcons',24)
                end
            end
        end
    end
    return result
end
local function hideResources()
    for _,icon in ipairs(markers.resourcePool) do
        icon.image:Hide();icon.border:Hide();icon.cave:Hide();icon.elevation:Hide();if icon.letter then icon.letter:Hide() end;if icon.anonymousImage then icon.anonymousImage:Hide()end;if icon.anonymousBorder then icon.anonymousBorder:Hide()end
    end
end
function markers:DrawResource(point,width,height,index)
    local icon=self.resourcePool[index]
    if not icon then
        local layer=self.layer or map.frame
        local border=layer:CreateTexture(nil,'OVERLAY',nil,0)
        border:SetTexture('Interface\\Common\\CommonMaskCircle')
        local image=layer:CreateTexture(nil,'OVERLAY',nil,1)
        image:SetTexCoord(0.08,0.92,0.08,0.92)
        image:SetDesaturation(0)
        local mask
        if layer.CreateMaskTexture and image.AddMaskTexture then
            mask=layer:CreateMaskTexture()
            mask:SetTexture('Interface\\CHARACTERFRAME\\TempPortraitAlphaMask','CLAMPTOBLACKADDITIVE','CLAMPTOBLACKADDITIVE')
            mask:SetAllPoints(image);image:AddMaskTexture(mask)
        end
        border:SetPoint('CENTER',image,'CENTER')
        local cave=layer:CreateFontString(nil,'OVERLAY','GameFontNormal')
        cave:SetText('|cff55ddffC|r');cave:SetPoint('LEFT',image,'RIGHT',2,0)
        local elevation=layer:CreateFontString(nil,'OVERLAY','GameFontNormal')
        local anonymousBorder=layer:CreateTexture(nil,'OVERLAY',nil,1);anonymousBorder:Hide()
        local anonymousImage=layer:CreateTexture(nil,'OVERLAY',nil,2);anonymousImage:SetAllPoints(image);anonymousImage:Hide()
        icon={image=image,border=border,cave=cave,elevation=elevation,anonymousImage=anonymousImage,anonymousBorder=anonymousBorder,artworkMask=mask};self.resourcePool[index]=icon
    end
    icon.image:ClearAllPoints()
    icon.image:SetPoint('CENTER',map.frame,'CENTER',point.x*width,point.y*height)
    icon.image:SetTexture(point.texture);icon.image:SetSize(point.size,point.size)
    icon.border:SetSize(point.size*1.25,point.size*1.25)
    icon.cave:SetFont(STANDARD_TEXT_FONT or 'Fonts\\FRIZQT__.TTF',math.max(8,math.floor(point.size*0.65+0.5)),'OUTLINE')
    icon.image:SetAlpha(point.alpha);icon.border:SetAlpha(point.alpha);icon.cave:SetAlpha(1)
    local node=point.node
    local difficulty=not node.anonymous and node.kind~='treasure' and safe(NS.GetGatheringNodeDifficulty,NS,node)
    local color=NS.GatheringDifficultyColors and NS.GatheringDifficultyColors[difficulty]
    if color then icon.border:SetVertexColor(color[1],color[2],color[3]);icon.border:Show() end
    if node.underground then icon.cave:Show() end
    local tag=node.elevationTag
    if type(tag)=='string' then
        local lower=tag:lower()
        local side=lower:find('positionarrowdown',1,true) and 'down' or lower:find('positionarrowup',1,true) and 'up'
        if not side and tag:sub(1,2)=='|T' then
            local fields={}
            for field in (tag:sub(3,-3)..':'):gmatch('(.-):') do fields[#fields+1]=field end
            local height,top,bottom=tonumber(fields[7]),tonumber(fields[10]),tonumber(fields[11])
            if height and top and bottom and height>0 and top>=0 and bottom>top and bottom<=height then
                if bottom<=height/2 then side='up' elseif top>=height/2 then side='down' end
            end
        end
        if side then
            icon.elevation:ClearAllPoints();icon.elevation:SetPoint('CENTER',icon.image,'CENTER',0,side=='down' and -12 or 12)
            icon.elevation:SetText(tag);icon.elevation:SetAlpha(1);icon.elevation:Show()
        end
    end
    icon.image:Show()
    if NS.RenderAnonymousNodeIcon then NS:RenderAnonymousNodeIcon(icon,node,point.size,point.alpha) end
end
function markers:Update()
    self.lastAttempt=GetTime();self.drawn=0;self.candidates=0;self.worldCandidates=0
    self.reason='starting'
    hideResources()
    for _,pin in ipairs(self.pool) do pin:Hide() end
    self.rxpCount=0
    if not map.frame or not map.frame:IsShown() then self:HideRestedXP();self:HideQuestie();self.questieCount=0;self.reason='terrain hidden';return end
    local ok,cont,x,y=pcall(map.Position,map)
    if not ok or not number(cont) or not number(x) or not number(y) then self:HideRestedXP();self:HideQuestie();self.questieCount=0;self.reason='player world position unavailable';return end
    local db=NS.db.hud
    local span=map.GetDisplaySpan and map:GetDisplaySpan() or (number(db.terrainSpan) and math.max(200,math.min(1600,db.terrainSpan)) or 600)
    local points=self:Collect(cont,x,y,span,GetTime())
    if not self.layer and NS.TerrainQuestAreas then
        local layer=CreateFrame('Frame',nil,map.frame)
        layer:SetAllPoints(map.frame);layer:SetFrameLevel(map.frame:GetFrameLevel()+2);layer:EnableMouse(false)
        self.layer=layer
    end
    local width,height=map.frame:GetWidth(),map.frame:GetHeight()
    local regular,resources=0,0
    for _,point in ipairs(points) do
        if point.kind=='gathering' then
            resources=resources+1;self:DrawResource(point,width,height,resources)
        else
        regular=regular+1
        local i=regular
        local pin=self.pool[i]
        if not pin then pin=(self.layer or map.frame):CreateTexture(nil,'OVERLAY',nil,1);self.pool[i]=pin end
        pin:ClearAllPoints();pin:SetPoint('CENTER',map.frame,'CENTER',point.x*width,point.y*height)
        pin:SetSize(point.size,point.size);pin:SetTexture(point.texture);pin:SetTexCoord(0,1,0,1);pin:SetAlpha(point.alpha)
        -- Native CorpsePinTemplate's skull crop; reset for every pooled pin above.
        if point.kind=='corpse' then pin:SetTexCoord(0.56640625,0.6328125,0.001953125,0.03515625) end
        if point.kind=='waypoint' and pin.SetAtlas then pin:SetAtlas('Waypoint-MapPin-Tracked') end
        if point.kind=='party' then pin:SetVertexColor(0.2,1,0.35) else pin:SetVertexColor(1,1,1) end
        pin:Show()
        end
    end
    local rxpOK,rxpError=pcall(self.DrawRestedXP,self,cont,x,y,span,width,height)
    if not rxpOK then
        self.rxpStatus='adapter error';self.rxpCount=0
        self.rxpError=tostring(rxpError):gsub('[\r\n]',' '):sub(1,160)
        self:HideRestedXP()
    end
    local questieOK=pcall(self.DrawQuestie,self,cont,x,y,span,width,height)
    if not questieOK then self:HideQuestie();self.questieCount=0;self.questieStatus='adapter error' end
    self.drawn=resources;self.reason='updated';self.lastSuccess=GetTime()
end
function markers:GetCompactDiagnostic()
    local function value(frame,method)
        local v=frame and safe(frame[method],frame)
        return v==nil and '?' or tostring(v)
    end
    local image=self.resourcePool[1] and self.resourcePool[1].image
    local errorAge=self.lastErrorAt and string.format('%.1fs',math.max(0,GetTime()-self.lastErrorAt)) or '?'
    return 'terrain markers='..tostring(self.reason or 'not updated')
        ..'; map visible/alpha='..value(map.frame,'IsVisible')..'/'..value(map.frame,'GetAlpha')
        ..'; layer visible/alpha='..value(self.layer,'IsVisible')..'/'..value(self.layer,'GetAlpha')
        ..'; candidates/world/drawn='..tostring(self.candidates or 0)..'/'..tostring(self.worldCandidates or 0)..'/'..tostring(self.drawn or 0)
        ..'; first visible/alpha='..value(image,'IsVisible')..'/'..value(image,'GetAlpha')
        ..'; error='..tostring(self.lastError or 'none')..'; error age='..errorAge
        ..'; Questie='..tostring(self.questieStatus or 'not updated')..'/'..tostring(self.questieCount or 0)
        ..'; RestedXP='..tostring(self.rxpStatus or 'not updated')..'/'..tostring(self.rxpCount or 0)
        ..'; '..(NS.TerrainQuests and NS.TerrainQuests:Diagnostic() or 'native quests unavailable')
end
local update=map.Update
function map:Update(...)
    update(self,...)
    local ok,err=pcall(markers.Update,markers)
    if not ok then
        markers.lastError=tostring(err):gsub('[\r\n]',' '):sub(1,160);markers.lastErrorAt=GetTime()
        markers.reason='marker update error';markers.drawn=0
        hideResources();for _,pin in ipairs(markers.pool) do pin:Hide() end
        markers:HideRestedXP();markers.rxpCount=0;markers:HideQuestie();markers.questieCount=0
    end
end
