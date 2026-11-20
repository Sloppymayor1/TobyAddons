local _, FRNS_ = ...; local NS = FRNS_.Gathering
local map=NS.TerrainMinimap
local quests={points={},pool={},dirty=true}
NS.TerrainQuests=quests
local function public(v)return not (issecretvalue and issecretvalue(v))end
local function number(v)return public(v) and type(v)=='number' and v==v and math.abs(v)<1e8 end
local function safe(fn,...)
    if type(fn)~='function' then return end
    local ok,v=pcall(fn,...)
    if ok and public(v) then return v end
end
function quests:Refresh(id,now)
    self.points={};self.mapID=id;self.nextRefresh=now+1;self.dirty=nil
    local seen={}
    local function add(info,kind)
        if not public(info) or type(info)~='table' or not number(info.questID)
            or not number(info.x) or not number(info.y) or info.x<0 or info.x>1 or info.y<0 or info.y>1
            or not public(info.isMapIndicatorQuest) or info.isMapIndicatorQuest then return end
        local key=kind..':'..info.questID
        if seen[key] then return end
        local cont,x,y=NS.TerrainMarkers:World(id,CreateVector2D(info.x,info.y))
        if not number(cont) or not number(x) or not number(y) then return end
        seen[key]=true
        self.points[#self.points+1]={continent=cont,x=x,y=y,kind=kind,questID=info.questID,mapX=info.x,mapY=info.y}
    end
    -- Quest-line data is loaded on request, independently of the minimap's
    -- engine-rendered nearby questgiver icons. Retry at the refresh cadence.
    self.requestAvailable=C_QuestLine and type(C_QuestLine.RequestQuestLinesForMap)=='function' or false
    if self.requestAvailable then safe(C_QuestLine.RequestQuestLinesForMap,id) end
    local offers=C_QuestLine and safe(C_QuestLine.GetAvailableQuestLines,id)
    self.offerCount=type(offers)=='table' and #offers or nil
    if type(offers)=='table' then
        for i=1,math.min(#offers,256) do
            local info=offers[i]
            if public(info) and type(info)=='table' and number(info.questID)
                and public(info.inProgress) and not info.inProgress and public(info.isHidden) and not info.isHidden
                and public(info.startMapID) and (info.startMapID==nil or info.startMapID==id)
                and not (C_QuestLog and safe(C_QuestLog.IsOnQuest,info.questID)==true)
                and not (C_QuestLog and safe(C_QuestLog.IsQuestFlaggedCompleted,info.questID)==true) then add(info,'available') end
        end
    end
    local active=C_QuestLog and safe(C_QuestLog.GetQuestsOnMap,id)
    self.activeCount=type(active)=='table' and #active or nil
    if type(active)=='table' then
        for i=1,math.min(#active,256) do
            local info=active[i]
            if public(info) and type(info)=='table' and number(info.questID)
                and safe(C_QuestLog.ReadyForTurnIn,info.questID)==true then add(info,'turnin') end
        end
    end
end
-- Use the same public marker positions as the renderer, independently of
-- terrain visibility. An overlap withholds anonymous inference, never votes empty.
function quests:IsScanMarker(ctx,px,py)
    if not ctx or not number(ctx.map) or not number(px) or not number(py) then return false end
    for _,key in ipairs({'x','y','w','h','radius','width','height','scale','cos','sin'}) do
        if not number(ctx[key]) then return false end
    end
    if ctx.radius<=0 or ctx.width<=0 or ctx.height<=0 or ctx.scale<=0 then return false end
    local now=GetTime()
    if self.dirty or self.mapID~=ctx.map or now>=(self.nextRefresh or 0) then self:Refresh(ctx.map,now) end
    local sx,sy=(px-ctx.width/2)*ctx.scale,(py-ctx.height/2)*ctx.scale
    for _,point in ipairs(self.points) do
        if number(point.mapX) and number(point.mapY) then
            local east,north=(point.mapX-ctx.x)*ctx.w,(ctx.y-point.mapY)*ctx.h
            -- Questgiver icons outside the native view are not edge arrows.
            if east*east+north*north<=ctx.radius*ctx.radius then
                local x=(east*ctx.cos+north*ctx.sin)/ctx.radius*ctx.width*ctx.scale/2
                local y=(north*ctx.cos-east*ctx.sin)/ctx.radius*ctx.height*ctx.scale/2
                if (sx-x)^2+(sy-y)^2<=20^2 then
                    return true,point.kind=='turnin' and 'quest hand-in marker area' or 'available quest marker area'
                end
            end
        end
    end
    return false
end
function quests:Update()
    self.drawn=0;self.reason='terrain hidden or map API unavailable'
    for _,pin in ipairs(self.pool) do pin.image:Hide();pin.text:Hide() end
    if not map.frame or not map.frame:IsShown() or not C_Map or not CreateVector2D then return end
    -- Available quests and turn-ins are separate from objective POI shading.
    -- Do not gate these markers on the questPOI CVar or capture's POI snapshot.
    local id=safe(C_Map.GetBestMapForUnit,'player')
    if not number(id) then self.reason='map ID unavailable';return end
    local now=GetTime()
    if self.dirty or id~=self.mapID or now>=(self.nextRefresh or 0) then self:Refresh(id,now) end
    local ok,cont,x,y=pcall(map.Position,map)
    if not ok or not number(cont) or not number(x) or not number(y) then self.reason='world position unavailable';return end
    if not self.layer then
        self.layer=CreateFrame('Frame',nil,map.frame)
        self.layer:SetAllPoints(map.frame);self.layer:SetFrameLevel(map.frame:GetFrameLevel()+3);self.layer:EnableMouse(false)
    end
    local span=NS.db.hud.terrainSpan
    span=map.GetDisplaySpan and map:GetDisplaySpan() or (number(span) and math.max(200,math.min(1600,span)) or 600)
    local w,h=map.frame:GetWidth(),map.frame:GetHeight()
    local count=0
    for _,point in ipairs(self.points) do
        local dx,dy=(y-point.y)/span,(point.x-x)/span
        if point.continent==cont and math.abs(dx)<=0.44 and math.abs(dy)<=0.44 and count<128 then
            count=count+1
            local pin=self.pool[count]
            if not pin then
                pin={image=self.layer:CreateTexture(nil,'OVERLAY'),text=self.layer:CreateFontString(nil,'OVERLAY','GameFontNormalLarge')}
                pin.image:SetSize(20,20);pin.text:SetTextColor(1,0.82,0);self.pool[count]=pin
            end
            pin.image:ClearAllPoints();pin.text:ClearAllPoints()
            pin.image:SetPoint('CENTER',map.frame,'CENTER',dx*w,dy*h)
            pin.text:SetPoint('CENTER',map.frame,'CENTER',dx*w,dy*h)
            local atlas=point.kind=='turnin' and 'UI-QuestIcon-TurnIn-Normal' or 'QuestNormal'
            local info=C_Texture and safe(C_Texture.GetAtlasInfo,atlas)
            if info and pin.image.SetAtlas then pin.image:SetAtlas(atlas);pin.image:Show()
            else pin.text:SetText(point.kind=='turnin' and '?' or '!');pin.text:Show() end
        end
    end
    self.drawn=count;self.reason='updated'
end
function quests:Diagnostic()
    return 'native quests='..tostring(self.reason or 'not updated')..'; map='..tostring(self.mapID or '?')
        ..'; request API='..tostring(self.requestAvailable==true)..'; offers/active/accepted/drawn='
        ..tostring(self.offerCount or '?')..'/'..tostring(self.activeCount or '?')..'/'..#self.points..'/'..tostring(self.drawn or 0)
        ..'; error='..tostring(self.lastError or 'none')
end
-- Independent of terrain visibility and cached replacement markers.
function quests:TestAPI()
    if self.testPending then NS.Print('Quest API test already waiting.');return end
    local id=C_Map and safe(C_Map.GetBestMapForUnit,'player')
    if not number(id) or not C_Timer or type(C_Timer.After)~='function' then
        NS.Print('Quest API test: map or timer unavailable.');return
    end
    local capture=NS.CursorSweepActive==true
    local function count(fn)
        local list=safe(fn,id)
        return type(list)=='table' and tostring(#list) or 'unavailable/error'
    end
    local before=count(C_QuestLine and C_QuestLine.GetAvailableQuestLines)
    local request=C_QuestLine and C_QuestLine.RequestQuestLinesForMap
    local ok=false
    if type(request)=='function' then ok=pcall(request,id) end
    self.testPending=true
    NS.Print('Quest API test: map='..id..'; capture='..tostring(capture)..'; offers before='..before..'; request='..tostring(ok)..'; waiting 3 seconds.')
    C_Timer.After(3,function()
        self.testPending=nil
        if safe(C_Map.GetBestMapForUnit,'player')~=id or (NS.CursorSweepActive==true)~=capture then
            NS.Print('Quest API test: map or capture changed; repeat while standing still.');return
        end
        NS.Print('Quest API test: map='..id..'; capture='..tostring(capture)
            ..'; offers after='..count(C_QuestLine and C_QuestLine.GetAvailableQuestLines)
            ..'; active='..count(C_QuestLog and C_QuestLog.GetQuestsOnMap))
    end)
end
SLASH_FDGQUESTTEST1='/fdgquesttest'
SlashCmdList.FDGQUESTTEST=function()quests:TestAPI()end
local events=CreateFrame('Frame')
for _,event in ipairs({'QUEST_LOG_UPDATE','QUEST_POI_UPDATE','QUEST_ACCEPTED','QUEST_REMOVED','QUEST_TURNED_IN','ZONE_CHANGED_NEW_AREA'}) do
    events:RegisterEvent(event)
end
events:SetScript('OnEvent',function()quests.dirty=true end)
local update=map.Update
function map:Update(...)
    update(self,...)
    local ok,err=pcall(quests.Update,quests)
    if not ok then
        quests.reason='display error';quests.lastError=tostring(err):gsub('[\r\n]',' '):sub(1,160)
        for _,pin in ipairs(quests.pool) do pin.image:Hide();pin.text:Hide() end
    end
end
