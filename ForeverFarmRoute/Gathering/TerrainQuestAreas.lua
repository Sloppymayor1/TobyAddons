local _, FRNS_ = ...; local NS = FRNS_.Gathering
local map=NS.TerrainMinimap
local areas={reason='inactive'}
NS.TerrainQuestAreas=areas
local function public(v)return not (issecretvalue and issecretvalue(v))end
local function number(v)return public(v) and type(v)=='number' and v==v and math.abs(v)<1e8 end
local function safe(fn,...)
    if type(fn)~='function' then return end
    local ok,a,b=pcall(fn,...)
    if ok and public(a) and public(b) then return a,b end
end
-- The client owns quest geometry. No guessed circles or external quest database.
function areas:Geometry()
    if not C_Map or not CreateVector2D then return end
    local id=safe(C_Map.GetBestMapForUnit,'player')
    if not number(id) then return end
    local cont,p0=safe(C_Map.GetWorldPosFromMapPos,id,CreateVector2D(0,0))
    local cont1,p1=safe(C_Map.GetWorldPosFromMapPos,id,CreateVector2D(1,1))
    if not p0 or not p1 or not number(cont) or cont~=cont1 then return end
    local x0,y0=safe(p0.GetXY,p0)
    local x1,y1=safe(p1.GetXY,p1)
    if not (number(x0) and number(y0) and number(x1) and number(y1)) or x0<=x1 or y0<=y1 then return end
    return id,cont,x0,y0,x1,y1
end
function areas:Create()
    -- This frame clips the full-zone quest renderer to the small terrain view.
    local clip=CreateFrame('Frame',nil,map.frame)
    clip:SetAllPoints(map.frame);clip:SetFrameLevel(map.frame:GetFrameLevel()+1)
    clip:EnableMouse(false)
    if not clip.SetClipsChildren then clip:Hide();self.reason='clipping unavailable';return false end
    clip:SetClipsChildren(true)
    local ok,blob=pcall(CreateFrame,'QuestPOIFrame',nil,clip)
    if not ok or not blob or not blob.SetMapID or not blob.DrawBlob or not blob.DrawNone then
        clip:Hide();self.reason='quest renderer unavailable';return false
    end
    blob:EnableMouse(false)
    blob:SetFillTexture('Interface\\Minimap\\UI-QuestBlobMinimap-Inside')
    blob:SetBorderTexture('Interface\\Minimap\\UI-QuestBlobMinimap-Outside')
    -- Native minimap look: clear terrain inside a pale glowing boundary.
    blob:SetFillAlpha(0);blob:SetBorderAlpha(220);blob:SetBorderScalar(1)
    self.clip,self.blob=clip,blob
    return true
end
-- QuestPOIFrame is a native blob renderer, not a maskable Texture. For round
-- minimaps, non-overlapping rectangular scissor bands approximate the circle
-- from inside. All bands render the same native quest geometry; none extend
-- beyond the terrain's edge. Pool them and redraw only when quest/map changes.
function areas:RoundView(id,quest,xOffset,yOffset,zoneWidth,zoneHeight,w,h)
    self.bands=self.bands or {}
    self.roundVisible=true
    self.roundFrames=(self.roundFrames or 0)+1
    local count=64
    for i=1,count do
        local band=self.bands[i]
        if not band then
            local clip=CreateFrame('Frame',nil,map.frame)
            clip:SetFrameLevel(map.frame:GetFrameLevel()+1);clip:EnableMouse(false)
            clip:SetClipsChildren(true)
            local blob=CreateFrame('QuestPOIFrame',nil,clip)
            blob:SetFrameLevel(clip:GetFrameLevel())
            blob:EnableMouse(false)
            blob:SetFillTexture('Interface\\Minimap\\UI-QuestBlobMinimap-Inside')
            blob:SetBorderTexture('Interface\\Minimap\\UI-QuestBlobMinimap-Outside')
            blob:SetFillAlpha(0);blob:SetBorderAlpha(220);blob:SetBorderScalar(1)
            band={clip=clip,blob=blob};self.bands[i]=band
        end
        local top,bottom=(i-1)/count,i/count
        local extent=math.max(math.abs(top*2-1),math.abs(bottom*2-1))
        local width=w*math.sqrt(math.max(0,1-extent*extent))
        if width>0 then
            local centerY=h*(0.5-(top+bottom)/2)
            band.clip:ClearAllPoints();band.clip:SetPoint('CENTER',map.frame,'CENTER',0,centerY)
            band.clip:SetSize(width,h/count)
            band.blob:ClearAllPoints()
            band.blob:SetPoint('TOPLEFT',map.frame,'CENTER',xOffset,yOffset)
            band.blob:SetSize(zoneWidth,zoneHeight)
            band.clip:Show();band.blob:Show()
            if self.roundFrames<=2 or band.id~=id or band.quest~=quest
                or band.zoneWidth~=zoneWidth or band.zoneHeight~=zoneHeight then
                band.blob:SetMapID(id);band.blob:DrawNone();band.blob:DrawBlob(quest,true)
                band.id,band.quest=id,quest
                band.zoneWidth,band.zoneHeight=zoneWidth,zoneHeight
            end
            band.clip:Show();band.blob:Show()
        else band.clip:Hide() end
    end
end
function areas:IsRoundMinimap()
    if not NS.MinimapScanActive then return false end
    if map.original and type(map.original.round)=='boolean' then return map.original.round end
    local mask=map.original and map.original.mask
    -- Native round mask file ID, also used by the installed skin. Square and
    -- custom masks keep the existing rectangular clip unless explicitly round.
    if tonumber(mask)==186178 then return true end
    if type(mask)=='string' then
        mask=mask:lower()
        return mask:find('circle',1,true)~=nil or mask:find('portraitalphamask',1,true)~=nil
            or mask:gsub('/','\\')=='textures\\minimapmask'
    end
    -- This client can expose neither GetMaskTexture nor a shape provider.
    -- Its native minimap is round. Unknown must not silently select the
    -- square renderer; retain explicit square file IDs/custom masks above.
    if mask==nil then return true end
    return false
end
function areas:Invalidate()
    for _,band in ipairs(self.bands or {}) do band.quest=nil end
end
local events=CreateFrame('Frame')
events:RegisterEvent('QUEST_LOG_UPDATE')
events:RegisterEvent('QUEST_POI_UPDATE')
events:SetScript('OnEvent',function()areas:Invalidate()end)
function areas:UpdateContent()
    if self.clip then self.clip:Hide();self.blob:DrawNone() end
    if not map.frame or not map.frame:IsShown() then self.reason='inactive';return end
    -- Capture temporarily disables native quest areas. The replacement follows
    -- the user's preference from before capture, rather than that hidden state.
    local enabled=safe(GetCVarBool,'questPOI')
    local capture=NS.CursorSweepTrial
    if capture and capture.saved and capture.workflow and capture.workflow:Allows('knownOnly') then
        self.reason='hidden during quick scan';return
    end
    if capture and capture.saved and type(capture.questAreasOriginal)=='boolean' then
        enabled=capture.questAreasOriginal
    end
    if enabled==false then self.reason='quest areas disabled';return end
    local quest=C_SuperTrack and safe(C_SuperTrack.GetSuperTrackedQuestID)
    if not number(quest) or quest<=0 then self.reason='no selected quest';return end
    local id,cont,x0,y0,x1,y1=self:Geometry()
    local ok,playerCont,x,y=pcall(map.Position,map)
    if not id or not ok or cont~=playerCont or not number(x) or not number(y) then
        self.reason='quest map position unavailable';return
    end
    if not self.blob then
        if self.unavailable then return end
        if not self:Create() then self.unavailable=true;return end
    end
    local span=NS.db.hud.terrainSpan
    span=map.GetDisplaySpan and map:GetDisplaySpan() or (number(span) and math.max(200,math.min(1600,span)) or 600)
    local w,h=map.frame:GetWidth(),map.frame:GetHeight()
    if self:IsRoundMinimap() then
        self:RoundView(id,quest,(y-y0)/span*w,(x0-x)/span*h,
            (y0-y1)/span*w,(x0-x1)/span*h,w,h)
        self.reason='selected quest';return
    end
    self.blob:ClearAllPoints()
    self.blob:SetPoint('TOPLEFT',self.clip,'CENTER',(y-y0)/span*w,(x0-x)/span*h)
    self.blob:SetSize((y0-y1)/span*w,(x0-x1)/span*h)
    self.blob:SetMapID(id);self.blob:DrawBlob(quest,true)
    self.clip:Show();self.blob:Show();self.reason='selected quest'
end
function areas:Update()
    self.roundVisible=false
    self:UpdateContent()
    if not self.roundVisible then
        self.roundFrames=0
        for _,band in ipairs(self.bands or {}) do band.clip:Hide() end
    end
end
local update=map.Update
function map:Update(...)
    update(self,...)
    local ok,err=pcall(areas.Update,areas)
    if not ok then
        if areas.clip then areas.clip:Hide() end
        for _,band in ipairs(areas.bands or {}) do band.clip:Hide() end
        areas.lastError=tostring(err)
        areas.reason='quest renderer unavailable'
    end
end
