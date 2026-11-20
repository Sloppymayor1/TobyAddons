local _, FRNS_ = ...; local NS = FRNS_.Gathering
-- Separate HUD artwork. Never changes the replacement minimap or capture surface.
local view={tiles={}}
NS.ExperimentalHUDTerrain=view
local function number(v)
 return not (issecretvalue and issecretvalue(v)) and type(v)=='number' and v==v and math.abs(v)<1e8
end
-- Screen corners to north-up layout coordinates, matching gathering projection.
function view:Coordinates(rect,span,radius,c,s)
 local result={}
 for _,corner in ipairs({{-1,1},{-1,-1},{1,1},{1,-1}}) do
  local east=(corner[1]*c-corner[2]*s)*radius
  local north=(corner[1]*s+corner[2]*c)*radius
  local u=(0.5+east/span-rect.x)/rect.w
  local v=(0.5-north/span-rect.y)/rect.h
  if rect.cave then
   local q=rect.coords
   result[#result+1]=q[1]+u*(q[5]-q[1])+v*(q[3]-q[1])
   result[#result+1]=q[2]+u*(q[6]-q[2])+v*(q[4]-q[2])
  else
   result[#result+1]=rect.l+u*(rect.r-rect.l)
   result[#result+1]=rect.t+v*(rect.b-rect.t)
  end
 end
 return result
end
-- Draw outdoor tiles as adjoining quads, rather than full-HUD textures
-- sampling black beyond each tile. Shared edges keep identical geometry.
function view:Vertices(rect,span,radius,c,s,size)
 local points={}
 for i,corner in ipairs({{0,0},{0,1},{1,0},{1,1}}) do
  local east=(rect.x+corner[1]*rect.w-0.5)*span
  local north=(0.5-rect.y-corner[2]*rect.h)*span
  points[i]={(east*c+north*s)/radius*size/2,(north*c-east*s)/radius*size/2}
 end
 return points
end
-- Outdoor layout uses the live HUD radius, including close zoom levels.
function view:Layout(continent,x,y,span)
 local data=NS.TerrainTiles and NS.TerrainTiles[continent]
 if not data or not number(x) or not number(y) then return {} end
 local tile=1600/3
 local cx,cy=32-y/tile,32-x/tile
 local half=span/tile/2
 local left,top=cx-half,cy-half
 local result={}
 for col=math.max(0,math.floor(left)),math.min(63,math.floor(cx+half)) do
  for row=math.max(0,math.floor(top)),math.min(63,math.floor(cy+half)) do
   local id=data[col*64+row]
   local l,r=math.max(left,col),math.min(cx+half,col+1)
   local t,b=math.max(top,row),math.min(cy+half,row+1)
   if id and r>l and b>t then
    result[#result+1]={id=id,x=(l-left)/span*tile,y=(t-top)/span*tile,
     w=(r-l)/span*tile,h=(b-t)/span*tile,l=l-col,r=r-col,t=t-row,b=b-row}
   end
  end
 end
 return result
end
-- Use the native shape captured before HUD/capture ownership, never the
-- invisible sampling minimap's temporary full-square mask.
function view:ApplyShape(texture)
 if not texture or not texture.AddMaskTexture or not self.artwork.CreateMaskTexture then return end
 local original=NS.TerrainMinimap and NS.TerrainMinimap.original
 local display=NS.CursorSweepTrial and NS.CursorSweepTrial.hudDisplay
 local hudMask=display and display.mask
 -- Native minimap terrain retains its octagonal footprint with a white HUD
 -- mask. Reproduce that footprint rather than replacing it with a circle.
 if type(hudMask)=='string' and hudMask:find('Media\\HUDMask.tga',1,true) then
  hudMask='Interface\\AddOns\\ForeverFarmRoute\\Gathering\\Media\\HUDTerrainMask.tga'
 end
 local square=not hudMask and original and original.round==false
 if square then
  if texture.hudShapeMasked then texture:RemoveMaskTexture(self.shapeMask);texture.hudShapeMasked=nil end
  return
 end
 if not self.shapeMask then
  self.shapeMask=self.artwork:CreateMaskTexture()
  self.shapeMask:SetAllPoints(self.artwork)
 end
 local mask=hudMask or original and original.mask or 'Interface\\CHARACTERFRAME\\TempPortraitAlphaMask'
 if self.shapeMaskSource~=mask then
  self.shapeMask:SetTexture(mask,'CLAMPTOBLACKADDITIVE','CLAMPTOBLACKADDITIVE')
  self.shapeMaskSource=mask
 end
 if not texture.hudShapeMasked then texture:AddMaskTexture(self.shapeMask);texture.hudShapeMasked=true end
end
function view:Update()
 if NS.MinimapScanActive then self:Hide("minimap scanning");return end
 local hud=NS.db and NS.db.hud
 local source=NS.TerrainMinimap
 if not (hud and hud.experimentalTerrain and hud.enabled and NS.CursorSweepActive and NS.HUDFrame and source) then
  self:Hide('inactive or option off');return
 end
 local ctx=NS:GetGatheringNodeContext()
 ctx=ctx and NS:GetCursorHUDDrawContext(ctx)
 if not ctx or not number(ctx.radius) or not number(ctx.cos) or not number(ctx.sin) then self:Hide('view context unavailable');return end
 local cont,x,y=source:Position()
 local indoors=IsIndoors and IsIndoors()
 if issecretvalue and issecretvalue(indoors) then self:Hide('interior status unavailable');return end
 local span=ctx.radius*2*math.sqrt(2)
 self.radius=ctx.radius
 if ctx.radius<=0 or span>6400 then self:Hide('view radius unsupported');return end
 local layout,reason
 if indoors then
  span=math.max(50,math.min(1600,span))
  layout,reason=source:CaveLayout(cont,x,y,span)
 else layout=self:Layout(cont,x,y,span) end
 if #layout==0 then self:Hide(reason or 'terrain artwork or world position unavailable');return end
 if not self.frame then
  local f=CreateFrame('Frame',nil,NS.HUDFrame);self.frame=f
  f:SetPoint('CENTER',NS.HUDFrame,'CENTER');f:EnableMouse(false)
  f:SetClipsChildren(true)
  self.artwork=CreateFrame('Frame',nil,f);self.artwork:SetAllPoints(f);self.artwork:EnableMouse(false)
  local bg=self.artwork:CreateTexture(nil,'BACKGROUND');bg:SetAllPoints();bg:SetColorTexture(0.02,0.02,0.02,1)
  self.background=bg
 end
 local f=self.frame
 local size=number(hud.size) and math.max(1,hud.size-48) or 382
 f:SetSize(size,size);f:SetFrameStrata('LOW');f:SetFrameLevel(NS.HUDFrame:GetFrameLevel())
 self:ApplyShape(self.background)
 -- Native HUD terrain is one translucent map layer. A second dark backing
 -- compounds its opacity and causes a darker patch at every quick handoff.
 if NS.CursorSweepTrial and NS.CursorSweepTrial.hudDisplay then self.background:Hide()
 else self.background:Show() end
 f:SetAlpha(number(hud.mapAlpha) and math.max(0,math.min(1,hud.mapAlpha)) or 0.08)
 for i,rect in ipairs(layout) do
  local tex=self.tiles[i]
  if not tex then
   tex=self.artwork:CreateTexture(nil,'ARTWORK');tex:SetAllPoints(self.artwork);self.tiles[i]=tex
   if tex.SetSnapToPixelGrid then tex:SetSnapToPixelGrid(false) end
   if tex.SetTexelSnappingBias then tex:SetTexelSnappingBias(0) end
  end
  if rect.cave then
   for vertex=1,4 do tex:SetVertexOffset(vertex,0,0) end
   tex:SetTexture(rect.id,'CLAMPTOBLACKADDITIVE','CLAMPTOBLACKADDITIVE')
   tex:SetTexCoord(unpack(self:Coordinates(rect,span,ctx.radius,ctx.cos,ctx.sin)))
  else
   tex:SetTexture(rect.id,'CLAMP','CLAMP')
   tex:SetTexCoord(rect.l,rect.r,rect.t,rect.b)
   local vertices=self:Vertices(rect,span,ctx.radius,ctx.cos,ctx.sin,size)
   for vertex,point in ipairs(vertices) do
    local left=vertex<=2
    local top=vertex==1 or vertex==3
    tex:SetVertexOffset(vertex,point[1]-(left and -size/2 or size/2),point[2]-(top and size/2 or -size/2))
   end
  end
  self:ApplyShape(tex)
  tex:Show()
 end
 for i=#layout+1,#self.tiles do self.tiles[i]:Hide() end
 f:Show();self.reason='showing terrain'
end
function view:Hide(reason)
 self.reason=reason or self.reason
 if self.frame then self.frame:Hide() end
end
function view:Diagnostic()
 return 'Experimental HUD terrain: '..tostring(self.reason or 'not updated')..'; radius='..tostring(self.radius or '?')..'; last error='..tostring(self.lastError or 'none')
end
SLASH_FDGHUDTERRAIN1='/fdghudterrain'
SlashCmdList.FDGHUDTERRAIN=function()NS.Print(view:Diagnostic())end
local driver=CreateFrame('Frame')
local elapsed=0
driver:SetScript('OnUpdate',function(_,dt)
 elapsed=elapsed+dt;if elapsed<0.05 then return end;elapsed=0
 local ok,err=pcall(view.Update,view)
 if not ok then
  view.lastError=tostring(err):gsub('[\r\n]',' '):sub(1,160)
  view:Hide('display error')
 end
end)
