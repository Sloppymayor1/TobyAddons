local _, FRNS_ = ...; local NS = FRNS_.Gathering
-- Independent terrain artwork only. Reads original geometry only; never moves or reparents native Minimap.
local map = {tiles = {}, reason = 'inactive', hideTerrainArtwork = false}
NS.TerrainMinimap = map
-- One replacement map, composed by either scanner presentation.
NS.ReplacementMinimap = map
function map:UsesNativeView()
    return self.active or NS.MinimapScanActive==true
end
function map:Start()
    self.active=true
    if NS.StationaryMinimapControls then NS.StationaryMinimapControls:Start() end
    self:Update()
end
function map:Stop()
    self.active=nil
    if NS.StationaryMinimapControls then NS.StationaryMinimapControls:Stop() end
    if self.frame then self.frame:Hide() end
end
function map:Maintain()
    if NS.StationaryMinimapControls then NS.StationaryMinimapControls:Maintain() end
end
local TILE = 1600 / 3
local function number(v)
    return not (issecretvalue and issecretvalue(v)) and type(v)=='number' and v==v and math.abs(v)<1e8
end
local function settings()
    return NS.db and NS.db.hud
end
local function clamp(v, low, high, fallback)
    return number(v) and math.max(low,math.min(high,v)) or fallback
end
local function visible(region)
    if region.IsVisible and not region:IsVisible() then return false end
    if region.GetEffectiveAlpha then
        local alpha=region:GetEffectiveAlpha()
        if not number(alpha) or alpha<=0 then return false end
    end
    return true
end
-- Capture screen geometry before the base HUD takes ownership. Anchoring to the
-- live Minimap would follow the invisible cursor-scanning surface instead.
function map:CaptureOriginalGeometry()
    if not Minimap or not Minimap.GetCenter then return end
    local x,y=Minimap:GetCenter()
    local scale=Minimap:GetEffectiveScale()
    local uiScale=UIParent:GetEffectiveScale()
    local w,h=Minimap:GetWidth(),Minimap:GetHeight()
    if not (number(x) and number(y) and number(scale) and number(uiScale)
        and number(w) and number(h)) or scale<=0 or uiScale<=0 or w<=0 or h<=0 then return end
    self.original={x=x*scale/uiScale,y=y*scale/uiScale,width=w*scale/uiScale,height=h*scale/uiScale}
    local ok,radius=pcall(function()return C_Minimap and C_Minimap.GetViewRadius and C_Minimap.GetViewRadius()end)
    local okZoom,zoom=pcall(function()return Minimap:GetZoom()end)
    local getter=GetCVar or C_CVar and C_CVar.GetCVar
    local function zoomPreference(key)
        local success,value=pcall(function()return getter and getter(key)end)
        return success and tonumber(value) or okZoom and number(zoom) and zoom or 0
    end
    self.original.outdoorZoom=zoomPreference('minimapZoom')
    self.original.indoorZoom=zoomPreference('minimapInsideZoom')
    self.original.radius=ok and number(radius) and radius or nil
    self.original.indoors=IsIndoors and IsIndoors() or false
    local skin=EllesmereUI and EllesmereUI._ModuleNS and EllesmereUI._ModuleNS.EllesmereUIMinimap
    if skin and type(skin.MinimapShape)=='function' then
        local ok,shape=pcall(skin.MinimapShape)
        if ok and type(shape)=='string' then
            self.original.round=shape~='square' and shape~='rectangular'
        end
    end
    -- Read the same active style/profile and colour resolver that Ellesmere's
    -- ApplyMinimap uses. Render only into our own stationary border host.
    if skin and skin.MinimapStyle and EllesmereUI.ApplyBorderStyle then
        local ok,style=pcall(skin.MinimapStyle)
        local internal=skin._internals
        local addon=internal and internal.EBS
        local profile=addon and addon.db and addon.db.profile and addon.db.profile.minimap
        if ok and style=='eui' and self.original.round==false and profile and internal.GetBorderStyleColor then
            local success,r,g,b,a=pcall(internal.GetBorderStyleColor,profile)
            if success and number(r) and number(g) and number(b) and number(a) then
                self.original.skinBorder={size=profile.borderSize or 1,r=r,g=g,b=b,a=a,
                    texture=profile.borderTexture or 'solid',pixels=profile.borderSizePx,
                    offset=profile.borderTextureOffset,offsetY=profile.borderTextureOffsetY,
                    shiftX=profile.borderTextureShiftX,shiftY=profile.borderTextureShiftY,
                    behind=profile.borderBehind==true}
            end
        end
    end
    if self.original.round==nil and GetMinimapShape then
        local ok,shape=pcall(GetMinimapShape)
        if ok and shape=='ROUND' then self.original.round=true
        elseif ok and shape=='SQUARE' then self.original.round=false end
    end
    if Minimap.GetMaskTexture then
        local ok,mask=pcall(Minimap.GetMaskTexture,Minimap)
        if ok and not (issecretvalue and issecretvalue(mask))
            and (type(mask)=='string' or type(mask)=='number') then self.original.mask=mask end
    end
    -- Read the decoration before capture hides it. Copy artwork only; never
    -- retain, reparent or hook the native border or its interactive children.
    self.original.border=nil
    local border=MinimapCompassTexture or MinimapBorder
    if border then
        local ok,art=pcall(function()
            if not visible(border) then return end
            local bx,by=border:GetCenter()
            local bs=border:GetEffectiveScale()/uiScale
            local texture=border:GetTexture()
            local atlas=border.GetAtlas and border:GetAtlas()
            if not texture or not number(bx) or not number(by) or not number(bs) then return end
            local parent=border.GetParent and border:GetParent()
            local delta=parent and parent.GetFrameLevel and Minimap.GetFrameLevel
                and parent:GetFrameLevel()-Minimap:GetFrameLevel() or 3
            local layer,sublevel='ARTWORK',0
            if border.GetDrawLayer then layer,sublevel=border:GetDrawLayer() end
            return {levelDelta=delta,layer=layer,sublevel=sublevel,texture=texture,atlas=atlas,x=bx*bs-self.original.x,y=by*bs-self.original.y,
                width=border:GetWidth()*bs,height=border:GetHeight()*bs,
                coords={border:GetTexCoord()},
                blend=border.GetBlendMode and border:GetBlendMode() or 'BLEND',
                alpha=border.GetEffectiveAlpha and border:GetEffectiveAlpha() or 1,
                color=border.GetVertexColor and {border:GetVertexColor()} or {1,1,1,1},
                rotation=border.GetRotation and border:GetRotation() or 0}
        end)
        if ok then self.original.border=art end
    end
    self.original.orb={}
    -- Some skins draw the sun/moon in an unnamed child. Inspect a bounded
    -- set of children for the public cycle atlases, without touching them.
    local visited=0
    local function inspect(frame,depth)
        if not frame or depth>2 or visited>=64 then return end
        visited=visited+1
        if frame.IsForbidden and frame:IsForbidden() then return end
        if not visible(frame) then return end
        if frame.GetRegions then
            for _,region in ipairs({frame:GetRegions()}) do
                local atlas=region.GetAtlas and region:GetAtlas()
                if atlas=='UI-HUD-Minimap-Frame-Cycle' or atlas=='UI-HUD-Minimap-DayCycle'
                    or atlas=='UI-HUD-Minimap-NightCycle' then
                    local rx,ry=region:GetCenter()
                    local rs=region:GetEffectiveScale()/uiScale
                    if number(rx) and number(ry) and number(rs) and region:IsShown() and visible(region) then
                        self.original.orb[#self.original.orb+1]={atlas=atlas,
                            x=rx*rs-self.original.x,y=ry*rs-self.original.y,
                            width=region:GetWidth()*rs,height=region:GetHeight()*rs}
                    end
                end
            end
        end
        if frame.GetChildren then
            for _,child in ipairs({frame:GetChildren()}) do inspect(child,depth+1) end
        end
    end
    pcall(inspect,Minimap,0)
    if #self.original.orb==0 and MinimapCluster then
        visited=0;pcall(inspect,MinimapCluster,0)
    end
    -- The native dial uses client-specific atlas names, not necessarily the
    -- three skin cycle atlases above. Read its explicit background/rim pair.
    local diel=MinimapCluster and MinimapCluster.DielFrame
    if diel then
        local ok,parts=pcall(function()
            if not diel:IsVisible() or diel:GetEffectiveAlpha()<=0 then return end
            local result={}
            local function copy(region,rim)
                local atlas=region and region.GetAtlas and region:GetAtlas()
                if not atlas or not region:IsShown() then return end
                local rx,ry=region:GetCenter();local rs=region:GetEffectiveScale()/uiScale
                if not number(rx) or not number(ry) or not number(rs) then return end
                result[#result+1]={atlas=atlas,source=region,rim=rim,
                    x=rx*rs-self.original.x,y=ry*rs-self.original.y,
                    width=region:GetWidth()*rs,height=region:GetHeight()*rs}
            end
            copy(diel.Background,false)
            for _,region in ipairs({diel:GetRegions()}) do
                if region~=diel.Background then copy(region,true) end
            end
            return result
        end)
        if ok and parts and #parts>0 then self.original.orb=parts end
    end
end
local capture=NS.CaptureMinimapState
if capture then
    NS.CaptureMinimapState=function(core,...)
        -- The minimap adapter already snapshots before HUD setup hides its
        -- chrome and changes its mask. Do not overwrite that native snapshot.
        if not core._minimapState and not ((map.active or NS.MinimapScanActive) and map.original) then map:CaptureOriginalGeometry() end
        -- Preserve control positions while the native map is still at its
        -- normal corner. HUD layout will move that map to the player next.
        if not core._minimapState and core.QuickScanner and core.QuickScanner.hudEnabled
            and core.StationaryMinimapControls then core.StationaryMinimapControls:Start() end
        return capture(core,...)
    end
end
-- World x runs north and y west; texture columns run east and rows south.
function map:Layout(continent, x, y, span)
    local data=NS.TerrainTiles and NS.TerrainTiles[continent]
    if not data or not number(x) or not number(y) then return {} end
    span=clamp(span,50,1600,600)
    local cx,cy=32-y/TILE,32-x/TILE
    local half=span/TILE/2
    local left,top=cx-half,cy-half
    local result={}
    for col=math.max(0,math.floor(left)),math.min(63,math.floor(cx+half)) do
        for row=math.max(0,math.floor(top)),math.min(63,math.floor(cy+half)) do
            local id=data[col*64+row]
            local l,r=math.max(left,col),math.min(cx+half,col+1)
            local t,b=math.max(top,row),math.min(cy+half,row+1)
            if id and r>l and b>t then
                result[#result+1]={id=id,x=(l-left)/(2*half),y=(t-top)/(2*half),
                    w=(r-l)/(2*half),h=(b-t)/(2*half),l=l-col,r=r-col,t=t-row,b=b-row}
            end
        end
    end
    return result
end
-- Cave artwork and every overlay share this span. Prefer the actual native
-- indoor radius; outdoor preferences must not make small caves look miniature.
function map:ViewSpan(indoors)
    local db=settings() or {}
    if self:UsesNativeView() then
        local ok,radius=pcall(function()return C_Minimap and C_Minimap.GetViewRadius and C_Minimap.GetViewRadius()end)
        if ok and number(radius) and radius>0 then
            local original=self.original
            if original then
                if original.radius and indoors==original.indoors then return clamp(original.radius*2,50,1600,300) end
                -- Native indoor/outdoor zoom steps have different proportions.
                local steps=indoors and {[0]=300,240,180,120,80,50}
                    or {[0]=466+2/3,400,333+1/3,266+2/3,200,133+1/3}
                local zoom=indoors and original.indoorZoom or original.outdoorZoom
                local trial=NS.CursorSweepTrial
                if trial and trial.saved and trial.captureZoom==0 and steps[zoom or 0] then
                    return clamp(radius*2*steps[zoom or 0]/steps[0],50,1600,300)
                end
            end
            return clamp(radius*2,50,1600,300)
        end
    end
    if not indoors then return clamp(db.terrainSpan,200,1600,600) end
    if number(db.terrainCaveSpan) then return clamp(db.terrainCaveSpan,50,1600,300) end
    local ok,radius=pcall(function()return C_Minimap and C_Minimap.GetViewRadius and C_Minimap.GetViewRadius()end)
    if ok and number(radius) and radius>0 then return clamp(radius*2,50,1600,300) end
    return 300
end
function map:GetDisplaySpan()
    return self.displaySpan or clamp((settings() or {}).terrainSpan,200,1600,600)
end
-- WMO bounds identify covered interiors without needing a separate client floor map.
-- Overlapping footprints are deliberately unresolved; no floor identity is invented.
function map:CaveLayout(continent,x,y,span)
    if not number(continent) or not number(x) or not number(y) then return {},'cave position unavailable' end
    local match,index
    for i=1,math.min(#(NS.TerrainCaveTiles or {}),512) do
        local cave=NS.TerrainCaveTiles[i]
        if cave[1]==continent and x>=cave[2] and x<=cave[4] and y>=cave[3] and y<=cave[5] then
            if match then return {},'overlapping cave footprints' end
            match,index=cave,i
        end
    end
    if not match then return {},'cave artwork unavailable' end
    span=clamp(span,50,1600,300)
    local result={}
    local p=match[6]
    for j=1,math.min(#p,128*7),7 do
        local id,wx,wy,side,angle,u1,v0=unpack(p,j,j+6)
        if number(id) and number(wx) and number(wy) and number(side) and side>0
            and number(angle) and number(u1) and number(v0) then
            local c,s=math.cos(angle),math.sin(angle)
            local extent=side*(math.abs(c)+math.abs(s))/2
            local cx,cy=0.5+(y-wy)/span,0.5+(x-wx)/span
            local left,right=math.max(0,cx-extent/span),math.min(1,cx+extent/span)
            local top,bottom=math.max(0,cy-extent/span),math.min(1,cy+extent/span)
            if right>left and bottom>top then
                -- Inverse-rotate world-space corners, then crop the native picture.
                -- Black additive clamping makes samples outside the picture transparent.
                local function uv(a,b)
                    local dx,dy=(a-cx)*span/side,(b-cy)*span/side
                    return (0.5+c*dx-s*dy)*u1,v0+(0.5+s*dx+c*dy)*(1-v0)
                end
                local ulx,uly=uv(left,top)
                local llx,lly=uv(left,bottom)
                local urx,ury=uv(right,top)
                local lrx,lry=uv(right,bottom)
                result[#result+1]={id=id,x=left,y=top,w=right-left,h=bottom-top,
                    coords={ulx,uly,llx,lly,urx,ury,lrx,lry},cave=true}
            end
        end
    end
    return result,'showing cave '..index
end
function map:Position()
    if not C_Map or not C_Map.GetBestMapForUnit or not C_Map.GetPlayerMapPosition
        or not C_Map.GetWorldPosFromMapPos then return end
    local id=C_Map.GetBestMapForUnit('player')
    if not number(id) then return end
    local pos=C_Map.GetPlayerMapPosition(id,'player')
    if not pos or issecretvalue and issecretvalue(pos) then return end
    local continent,world=C_Map.GetWorldPosFromMapPos(id,pos)
    if not number(continent) or not world or issecretvalue and issecretvalue(world) then return end
    local x,y=world:GetXY()
    if number(x) and number(y) then return continent,x,y end
end
function map:Create()
    local f=CreateFrame('Frame','FDGTerrainMinimap',UIParent)
    self.frame=f
    f:SetFrameStrata('MEDIUM');f:SetMovable(false);f:SetClampedToScreen(true)
    f:EnableMouse(false);f:EnableMouseWheel(true)
    if f.SetMouseClickEnabled then f:SetMouseClickEnabled(false) end
    if f.SetMouseMotionEnabled then f:SetMouseMotionEnabled(false) end
    f:SetScript('OnMouseWheel',function(_,delta)
        if self:UsesNativeView() then return end -- native capture owns zoom during scanning
        local db=settings()
        if db then
            local key=self.displayIndoors and 'terrainCaveSpan' or 'terrainSpan'
            db[key]=clamp(self:GetDisplaySpan()*(delta>0 and 0.8 or 1.25),self.displayIndoors and 50 or 200,1600,self.displayIndoors and 300 or 600)
        end
        self:Update()
    end)
    -- Cave pictures contain transparent/uncovered areas that change as we walk.
    -- Keep an opaque backing so those areas never reveal the moving world below.
    local bg=f:CreateTexture(nil,'BACKGROUND');bg:SetAllPoints();bg:SetColorTexture(0.02,0.02,0.02,1)
    self.background=bg
    if f.CreateMaskTexture then
        self.roundMask=f:CreateMaskTexture()
        self.roundMask:SetTexture('Interface\\CHARACTERFRAME\\TempPortraitAlphaMask','CLAMPTOBLACKADDITIVE','CLAMPTOBLACKADDITIVE')
        self.roundMask:SetAllPoints(f)
    end
    local chrome=CreateFrame('Frame',nil,f)
    chrome:SetAllPoints(f);chrome:SetFrameLevel(f:GetFrameLevel()+30);chrome:EnableMouse(false)
    self.chromeLayer=chrome
    self.orbTextures={}
    local borderLayer=CreateFrame('Frame',nil,f)
    borderLayer:SetAllPoints(f);borderLayer:EnableMouse(false)
    self.borderLayer=borderLayer
    self.nativeBorder=borderLayer:CreateTexture(nil,'ARTWORK')
    -- A child frame draws above every texture on the terrain/marker parent.
    local player=CreateFrame('Frame',nil,f)
    player:SetAllPoints(f);player:SetFrameLevel(f:GetFrameLevel()+10);player:EnableMouse(false)
    if player.SetIgnoreParentAlpha then player:SetIgnoreParentAlpha(true) end
    self.playerLayer=player
    local arrow=player:CreateTexture(nil,'OVERLAY');arrow:SetSize(20,20);arrow:SetPoint('CENTER')
    local atlas='UI-HUD-Minimap-Arrow-Player'
    local info=C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(atlas)
    if info and arrow.SetAtlas then
        arrow:SetAtlas(atlas)
    else
        arrow:SetTexture('Interface\\WorldMap\\WorldMapArrow')
    end
    arrow:SetVertexColor(1,1,1);arrow:SetAlpha(1)
    self.arrow=arrow
    local label=f:CreateFontString(nil,'OVERLAY','GameFontNormalSmall');label:SetPoint('BOTTOM',f,'TOP',0,3)
    label:SetText('N  •  Terrain');self.label=label
    f:SetPoint('CENTER',UIParent,'CENTER',0,0)
    self:ResetPosition()
end
function map:StyleTexture(texture)
    if not self.roundMask or not texture.AddMaskTexture then return end
    -- Square tile rectangles already stop at the map bounds. Even a white
    -- mask can feather against its black sampling border; omit it entirely.
    if self:UsesNativeView() and (self.farmRotating or not (self.original and self.original.round==false)) then
        if not texture.fdgRoundMasked then texture:AddMaskTexture(self.roundMask);texture.fdgRoundMasked=true end
    elseif texture.fdgRoundMasked then
        texture:RemoveMaskTexture(self.roundMask);texture.fdgRoundMasked=nil
    end
end

function map:ProjectOffset(east,north)
    local c,s=self.rotationCos or 1,self.rotationSin or 0
    return east*c+north*s, north*c-east*s
end
function map:UpdateSkinBorder()
    local style=self:UsesNativeView() and self.original and self.original.skinBorder
    if not style or not EllesmereUI or not EllesmereUI.ApplyBorderStyle then
        if self.skinBorderHost then self.skinBorderHost:Hide() end
        self.appliedSkinBorder=nil;return
    end
    local host=self.skinBorderHost
    if not host then
        host=CreateFrame('Frame',nil,self.frame);host:EnableMouse(false)
        self.skinBorderHost=host
    end
    host:ClearAllPoints();host:SetAllPoints(self.frame)
    host:SetFrameLevel(math.max(0,self.frame:GetFrameLevel()+(style.behind and -1 or 0)))
    -- Native source calls the shared renderer with this exact argument order.
    -- Its snapshot remains stable throughout one quick pass.
    if self.appliedSkinBorder~=style then
        local px=EllesmereUI.BorderPx and EllesmereUI.BorderPx(style.pixels,style.size,style.texture)
        EllesmereUI.ApplyBorderStyle(host,style.size,style.r,style.g,style.b,style.a,style.texture,
            style.offset,style.offsetY,style.shiftX,style.shiftY,'minimap',style.size,nil,px)
        self.appliedSkinBorder=style
    end
end
function map:UpdateAppearance()
    if self.roundMask then
        -- A native square minimap mask can contain feathered edge values.
        -- Applied as a texture alpha mask these expose our dark backing and
        -- add an inner shadow absent from the native square map.
        local original=self.original
        local mask=original and original.round==false and 'Interface\\Buttons\\WHITE8X8'
            or original and original.mask or 'Interface\\CHARACTERFRAME\\TempPortraitAlphaMask'
        self.roundMask:SetTexture(mask,'CLAMPTOBLACKADDITIVE','CLAMPTOBLACKADDITIVE')
    end
    self:StyleTexture(self.background)
    self:UpdateSkinBorder()
    -- Square skin chrome already surrounds the stationary map. Replaying the
    -- native compass texture adds its baked inner shadow over our terrain.
    local art=self:UsesNativeView() and self.original and self.original.round~=false and self.original.border
    self.nativeBorder:Hide()
    if art then
        self.borderLayer:SetFrameLevel(math.max(0,self.frame:GetFrameLevel()+(art.levelDelta or 3)))
        if self.nativeBorder.SetDrawLayer then self.nativeBorder:SetDrawLayer(art.layer or 'ARTWORK',art.sublevel or 0) end
        if type(art.atlas)=='string' and art.atlas~='' then
            -- Atlas regions may report full-range texture coordinates. Copying
            -- their backing file would display every sprite on that sheet.
            self.nativeBorder:SetAtlas(art.atlas)
        else
            self.nativeBorder:SetTexture(art.texture)
            self.nativeBorder:SetTexCoord(unpack(art.coords))
        end
        -- Match the source skin's compositing, not just its atlas. For example
        -- replaying additive artwork with BLEND can introduce dark inner edges.
        if self.nativeBorder.SetBlendMode then self.nativeBorder:SetBlendMode(art.blend or 'BLEND') end
        self.nativeBorder:SetAlpha(art.alpha or 1)
        self.nativeBorder:SetVertexColor(unpack(art.color or {1,1,1,1}))
        self.nativeBorder:SetRotation(art.rotation or 0)
        self.nativeBorder:ClearAllPoints()
        self.nativeBorder:SetPoint('CENTER',self.frame,'CENTER',art.x,art.y)
        self.nativeBorder:SetSize(art.width,art.height)
        self.nativeBorder:Show()
    end
    local orb=self:UsesNativeView() and self.original and self.original.orb or {}
    for i,part in ipairs(orb or {}) do
        local tex=self.orbTextures[i]
        if not tex then
            tex=self.chromeLayer:CreateTexture(nil,'OVERLAY',nil,(part.rim or part.atlas=='UI-HUD-Minimap-Frame-Cycle') and 2 or 1)
            self.orbTextures[i]=tex
        end
        local atlas=part.atlas
        if part.source then
            local ok,current=pcall(part.source.GetAtlas,part.source)
            if ok and type(current)=='string' then atlas=current end
        elseif (atlas=='UI-HUD-Minimap-DayCycle' or atlas=='UI-HUD-Minimap-NightCycle') and C_DateAndTime and C_DateAndTime.IsDayTime then
            atlas=C_DateAndTime.IsDayTime() and 'UI-HUD-Minimap-DayCycle' or 'UI-HUD-Minimap-NightCycle'
        end
        tex:SetAtlas(atlas);tex:ClearAllPoints()
        tex:SetPoint('CENTER',self.frame,'CENTER',part.x,part.y)
        tex:SetSize(part.width,part.height);tex:Show()
    end
    for i=#(orb or {})+1,#self.orbTextures do self.orbTextures[i]:Hide() end
    if self:UsesNativeView() then self.label:Hide() else self.label:Show() end
end
function map:ResetPosition()
    if not self.frame then return end
    self.frame:ClearAllPoints()
    local farm=NS.QuickScanner and NS.QuickScanner.farmMap
    if farm then
        self.frame:SetPoint('CENTER',farm.holder,'CENTER')
        return
    end
    if self.original then
        self.frame:SetPoint('CENTER',UIParent,'BOTTOMLEFT',self.original.x,self.original.y)
        return
    end
    self.frame:SetPoint('CENTER',UIParent,'CENTER',UIParent:GetWidth()/2-140,UIParent:GetHeight()/2-190)
end
function map:Update()
    local db=settings()
    local hudIdle=NS.QuickScanner and (NS.QuickScanner.hudMapDisplay or NS.QuickScanner.farmMap)
    if not db or not (NS.CursorSweepActive or hudIdle) or db.terrainEnabled==false and not (NS.MinimapScanActive or hudIdle) then
        self.reason='inactive';if self.frame then self.frame:Hide() end;return
    end
    local indoorOK,indoors=pcall(function()return IsIndoors and IsIndoors()end)
    if not indoorOK or issecretvalue and issecretvalue(indoors) then
        self.reason='interior status unavailable';if self.frame then self.frame:Hide() end;return
    end
    self.displayIndoors=indoors==true
    self.displaySpan=self:ViewSpan(self.displayIndoors)
    local facing=GetPlayerFacing and GetPlayerFacing()
    local farm=NS.QuickScanner and NS.QuickScanner.farmMap
    self.farmRotating=farm~=nil and FRNS_.db and FRNS_.db.staticMap==false
    self.rotation=self.farmRotating and number(facing) and facing or 0
    self.rotationCos,self.rotationSin=math.cos(self.rotation),math.sin(self.rotation)
    local artworkSpan=self.farmRotating and math.min(1600,self.displaySpan*math.sqrt(2)) or self.displaySpan
    local ok,cont,x,y=pcall(self.Position,self)
    local layout,reason={},'terrain unavailable'
    if ok then
        if indoors then layout,reason=self:CaveLayout(cont,x,y,artworkSpan)
        else layout=self:Layout(cont,x,y,artworkSpan) end
    end
    if #layout==0 then self.reason=reason;if self.frame then self.frame:Hide() end;return end
    if not self.frame then self:Create() end
    local width,height=clamp(db.terrainSize,120,400,220),clamp(db.terrainSize,120,400,220)
    if self.original then
        width,height=self.original.width,self.original.height
        self:ResetPosition()
    end
    -- FarmRoute: over the see-through /farm HUD, match its map opacity so a
    -- scan doesn't flash a solid map.
    local farmHUD=NS.FarmHUDOpen and NS:FarmHUDOpen() and ForeverFarmHUDDB and ForeverFarmHUDDB.hud
    self.frame:SetSize(width,height);self.frame:SetAlpha(farmHUD and (farmHUD.mapAlpha or 0.08) or 1)
    self:UpdateAppearance()
    local projection=NS.ExperimentalHUDTerrain
    for i,rect in ipairs(layout) do
        local tex=self.tiles[i]
        if not tex then tex=self.frame:CreateTexture(nil,'ARTWORK');self.tiles[i]=tex end
        self:StyleTexture(tex)
        -- Match the warmer native outdoor terrain in the author's paired
        -- Tanaris screenshots. Keep cave artwork and non-native HUD views neutral.
        if self:UsesNativeView() and not rect.cave then
            tex:SetVertexColor(0.892,0.828,0.770)
        else tex:SetVertexColor(1,1,1) end
        tex:ClearAllPoints()
        if self.farmRotating then
            tex:SetPoint('CENTER',self.frame,'CENTER')
            tex:SetSize(width,height)
            if not rect.cave then
                local points=projection:Vertices(rect,artworkSpan,self.displaySpan/2,self.rotationCos,self.rotationSin,width)
                for i,point in ipairs(points) do
                    local left,top=i<=2,i==1 or i==3
                    tex:SetVertexOffset(i,point[1]+(left and width/2 or -width/2),point[2]*height/width+(top and -height/2 or height/2))
                end
                tex.farmWarped=true
            end
        else
            tex:SetPoint('TOPLEFT',self.frame,'TOPLEFT',rect.x*width,-rect.y*height)
            tex:SetSize(rect.w*width,rect.h*height)
        end
        if tex.farmWarped and (not self.farmRotating or rect.cave) then
            for i=1,4 do tex:SetVertexOffset(i,0,0) end
            tex.farmWarped=nil
        end
        if rect.cave then
            tex:SetTexture(rect.id,'CLAMPTOBLACKADDITIVE','CLAMPTOBLACKADDITIVE')
            local coords=self.farmRotating and projection:Coordinates(rect,artworkSpan,self.displaySpan/2,self.rotationCos,self.rotationSin)
            tex:SetTexCoord(unpack(coords or rect.coords))
        else
            tex:SetTexture(rect.id)
            tex:SetTexCoord(rect.l,rect.r,rect.t,rect.b)
        end
        if self.hideTerrainArtwork and self:UsesNativeView() then tex:Hide() else tex:Show() end
    end
    for i=#layout+1,#self.tiles do self.tiles[i]:Hide() end
    if number(facing) then self.arrow:SetRotation(facing-self.rotation) end
    self.reason=indoors and reason or 'showing terrain'
    self.label:SetText(indoors and 'N  •  Cave' or 'N  •  Terrain')
    self.frame:Show()
end
-- On-demand, read-only cave capability report. Never opens or changes the world map.
function map:Report()
    local function public(v)
        return not (issecretvalue and issecretvalue(v))
    end
    local function call(fn,...)
        if type(fn)~='function' then return nil,'unavailable' end
        local ok,v=pcall(fn,...)
        if not ok then return nil,'error' end
        if not public(v) then return nil,'restricted' end
        return v,v==nil and 'none' or 'ok'
    end
    local function value(v)
        if not public(v) then return 'restricted' end
        if number(v) then return tostring(v) end
        if type(v)=='boolean' then return tostring(v) end
        return 'unknown'
    end
    local function say(s) NS.Print('Terrain report: '..s) end
    local areas=NS.TerrainQuestAreas
    if areas then
        local shown=0
        for _,band in ipairs(areas.bands or {}) do
            local visible=call(band.clip.IsShown,band.clip)
            if visible==true then shown=shown+1 end
        end
        local mask=self.original and self.original.mask
        local maskText=public(mask) and (type(mask)=='string' or type(mask)=='number') and tostring(mask) or 'unknown'
        say('quest clip: active='..value(NS.MinimapScanActive==true)..'; round='..value(areas:IsRoundMinimap())
            ..'; shape='..value(self.original and self.original.round)..'; mask='..maskText
            ..'; bands='..shown..'/'..#(areas.bands or {})..'; renderer='..tostring(areas.reason)
            ..'; error='..tostring(areas.lastError or 'none'))
    end
    local api=C_Map or {}
    local indoor,indoorState=call(IsIndoors)
    say('cave-auto-2; indoors='..value(indoor)..' ('..indoorState..'); display='..self.reason)
    local id,state=call(api.GetBestMapForUnit,'player')
    say('player map='..value(id)..' ('..state..')')
    if not number(id) then return end
    say('view span='..value(self:GetDisplaySpan())..'; cave zoom='..(number((settings() or {}).terrainCaveSpan) and 'manual' or 'native automatic'))
    local info,infoState=call(api.GetMapInfo,id)
    if type(info)=='table' then
        say('map type='..value(info.mapType)..'; parent='..value(info.parentMapID))
    else say('map info='..infoState) end
    local pos,posState=call(api.GetPlayerMapPosition,id,'player')
    if type(pos)=='table' then
        say('map position='..value(pos.x)..', '..value(pos.y))
    else say('map position='..posState) end
    local ok,cont,x,y=pcall(self.Position,self)
    say('world position='..(ok and (value(cont)..'; '..value(x)..', '..value(y)) or 'error'))
    local art,artState=call(api.GetMapArtID,id)
    say('art='..value(art)..' ('..artState..')')
    local layers,layerState=call(api.GetMapArtLayers,id)
    if type(layers)=='table' then
        local n=0
        for i=1,8 do
            local layer=layers[i]
            if not public(layer) or type(layer)~='table' then break end
            n=n+1
            local textures,textureState=call(api.GetMapArtLayerTextures,id,i)
            local ids={}
            if type(textures)=='table' then
                for j=1,4 do
                    if textures[j]==nil then break end
                    ids[#ids+1]=value(textures[j])
                end
            end
            say('layer '..i..': '..value(layer.layerWidth)..'x'..value(layer.layerHeight)
                ..'; tile='..value(layer.tileWidth)..'x'..value(layer.tileHeight)
                ..'; texture sample='..table.concat(ids,',')..' ('..textureState..')')
        end
        say('layers inspected='..n..' (limit 8)')
    else say('layers='..layerState) end
    local group,groupState=call(api.GetMapGroupID,id)
    say('floor group='..value(group)..' ('..groupState..')')
    if number(group) then
        local floors,floorState=call(api.GetMapGroupMembersInfo,group)
        if type(floors)=='table' then
            for i=1,8 do
                local floor=floors[i]
                if not public(floor) or type(floor)~='table' then break end
                say('floor '..i..': map='..value(floor.mapID)..'; index='..value(floor.floorIndex))
            end
        else say('floors='..floorState) end
    end
end
SLASH_FDGTERRAIN1='/fdgterrain'
SlashCmdList.FDGTERRAIN=function(message)
    local command,value=(message or ''):lower():match('^(%S*)%s*(.-)$')
    local db=settings();if not db then return end
    if command=='pins' then
        if NS.TerrainMarkers and NS.TerrainMarkers.ReportNativePins then NS.TerrainMarkers:ReportNativePins() end
        return
    elseif command=='report' then map:Report();return
    elseif command=='artwork' then
        if value~='on' and value~='off' then NS.Print('Terrain: /fdgterrain artwork on|off');return end
        map.hideTerrainArtwork=value=='off'
    elseif command=='on' then db.terrainEnabled=true
    elseif command=='off' then db.terrainEnabled=false
    elseif command=='zoom' then
        local key=map.displayIndoors and 'terrainCaveSpan' or 'terrainSpan'
        if value=='auto' then db[key]=nil
        else db[key]=clamp(tonumber(value),map.displayIndoors and 50 or 200,1600,map.displayIndoors and 300 or 600) end
    elseif command=='reset' or command=='auto' then db.terrainManualLayout=nil;db.terrainX=nil;db.terrainY=nil;map:ResetPosition()
    elseif command~='' and command~='status' then
        NS.Print('Terrain: /fdgterrain on|off|artwork on|off|zoom <yards/auto>|auto|reset|status|report');return
    end
    map:Update()
    NS.Print('Terrain: '..map.reason..'; '..map:GetDisplaySpan()..' yards across. Wheel to zoom.')
end
local driver=CreateFrame('Frame')
local elapsed=0
driver:SetScript('OnUpdate',function(_,dt)
    elapsed=elapsed+dt;if elapsed<0.1 then return end;elapsed=0
    local ok,err=pcall(map.Update,map)
    if not ok then
        if map.frame then map.frame:Hide() end
        map.reason="display error"
        if not map.reportedError then NS.Print("Terrain map: "..tostring(err));map.reportedError=true end
    end
end)
