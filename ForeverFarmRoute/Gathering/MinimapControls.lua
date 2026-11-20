local _, FRNS_ = ...; local NS = FRNS_.Gathering
local unpack=unpack or table.unpack
-- Stationary presentation for a deliberately small set of Ellesmere-owned controls.
-- Exact owned controls defer skin layout writes; all methods resume on release.
local controls={}
NS.StationaryMinimapControls=controls
local keys={_tracking=true,_gameTime=true,_mail=true,_crafting=true,_friends=true}
local names={'_EBS_ClockBg','_EBS_LocationBg','_EBS_FpsBg','_EBS_CoordFrame','EllesmereUIMicroMenu'}
local function locked()return InCombatLockdown and InCombatLockdown()end
local function number(v)
    return not (issecretvalue and issecretvalue(v)) and type(v)=='number' and v==v and math.abs(v)<math.huge
end
local function inspectable(f)
    if not f or issecretvalue and issecretvalue(f) then return false end
    return not (f.IsForbidden and f:IsForbidden())
end
local function safe(f)
    local ok,result=pcall(function()
        return inspectable(f) and f~=Minimap and not (f.IsProtected and f:IsProtected())
            and f.GetCenter and f.GetEffectiveScale and f.SetParent and f.GetPoint
    end)
    return ok and result and true or false
end
function controls:CoordinateVisibility(f)
    if self.coordinateVisibilityWriting or not self.saved or not self.saved[f] or not safe(f) then return end
    local module=NS._ellesmereModule
    if not module and EllesmereUI and EllesmereUI.Lite and EllesmereUI.Lite.GetAddon then
        module=EllesmereUI.Lite.GetAddon('EllesmereUIMinimap')
    end
    local profile=module and module.db and module.db.profile and module.db.profile.minimap
    if not profile then return end
    local mode=profile.coordsMode or 'always'
    local hover=NS.ReplacementMinimapHover
    local shown=mode=='always' or mode=='hover' and hover and hover:PointerOverMap() or false
    if f:IsShown()==shown then return end
    self.coordinateVisibilityWriting=true
    if shown then f:Show() else f:Hide() end
    self.coordinateVisibilityWriting=nil
end
-- Bounded session-only counters: no text/coordinates or SavedVariables retained.
function controls:WatchCoordinates()
    local f=_G._EBS_CoordFrame
    if not inspectable(f) or not hooksecurefunc then return end
    self.coordinateWatches=self.coordinateWatches or setmetatable({}, {__mode='k'})
    if self.coordinateWatches[f] then return end
    self.coordinateWatches[f]=true
    for _,method in ipairs({'SetText','Show','Hide','SetShown','SetAlpha','SetPoint','SetParent','SetScale'}) do
        if type(f[method])=='function' then
            hooksecurefunc(f,method,function()
                if not controls.saved then return end
                if method=='Show' or method=='Hide' or method=='SetShown' then controls:CoordinateVisibility(f) end
                local d=controls.coordinateDiagnostic or {};controls.coordinateDiagnostic=d
                d[method]=math.min((d[method] or 0)+1,1000000)
                if method=='SetText' and f.GetText then
                    local text=f:GetText()
                    if not (issecretvalue and issecretvalue(text)) and (text==nil or text=='') then
                        d.empty=math.min((d.empty or 0)+1,1000000)
                    end
                end
            end)
        end
    end
end
if SlashCmdList then
    SLASH_FDGCOORDS1='/fdgcoords'
    SlashCmdList.FDGCOORDS=function()
        local f=_G._EBS_CoordFrame;local d=controls.coordinateDiagnostic or {}
        local ok,state=pcall(function()
            local point,anchor=f:GetPoint(1)
            return string.format('owned=%s parent=%s anchor=%s shown=%s alpha=%s',
                tostring(controls.saved and controls.saved[f]~=nil),
                tostring(f:GetParent()==controls.host),tostring(anchor==controls.host),
                tostring(f:IsShown()),tostring(f:GetAlpha()))
        end)
        local parts={}
        for _,key in ipairs({'SetText','empty','Show','Hide','SetAlpha','SetPoint','SetParent','SetScale'}) do
            parts[#parts+1]=key..'='..tostring(d[key] or 0)
        end
        NS.Print('Coordinates: '..(ok and state or 'region unavailable')..' '..table.concat(parts,' '))
    end
end
function NS:IsStationaryMinimapControl(f)
    if not controls.saved then return false end
    -- Called for arbitrary native/pool objects by the shared suppression code.
    -- Both method lookup and GetParent can reject addon-tainted access.
    local ok,result=pcall(function()
        for _=1,12 do
            if not inspectable(f) then return false end
            if controls.saved[f] then return true end
            f=f.GetParent and f:GetParent()
        end
        return false
    end)
    return ok and result==true
end
-- Defer skin layout writes for exact owned, unprotected controls. Our own
-- writes call the retained methods directly, so synchronous skin callbacks
-- cannot bypass ownership or create a repair loop.
function controls:GuardLayout(f)
    self.layoutMethods=self.layoutMethods or setmetatable({}, {__mode='k'})
    if self.layoutMethods[f] then return end
    local methods={};self.layoutMethods[f]=methods
    for _,method in ipairs({'ClearAllPoints','SetPoint','SetParent','SetScale','SetFrameStrata','SetFrameLevel',
        'ClearAllPointsBase','SetPointBase','SetParentBase','SetScaleBase'}) do
        local original=f[method]
        if type(original)=='function' then
            methods[method]=original
            f[method]=function(frame,...)
                if controls.saved and controls.saved[frame] and safe(frame) then return end
                return original(frame,...)
            end
        end
    end
end
function controls:SetLayout(f,method,...)
    local methods=self.layoutMethods and self.layoutMethods[f]
    local setter=methods and methods[method] or f[method]
    return setter(f,...)
end
function controls:Maintain()
    if not self.saved then return end
    self:WatchCoordinates()
    if _G._EBS_CoordFrame then self:CoordinateVisibility(_G._EBS_CoordFrame) end
    local inCombat=locked()
    -- FontStrings (Ellesmere coordinates) inherit this host's drawing level;
    -- unlike the buttons they cannot receive their own frame level.
    local map=NS.TerrainMinimap and NS.TerrainMinimap.frame
    local level=(map and map.GetFrameLevel and map:GetFrameLevel() or 1)+40
    if not inCombat then
        self.host:SetFrameStrata('MEDIUM')
        self.host:SetFrameLevel(level)
    end
    self.layoutWriting=true
    for f,s in pairs(self.saved) do
        -- The coordinate FontString can be reanchored by the skin while the
        -- native map is moving. Keep this already-parked, unprotected region
        -- stationary in combat too; defer all frame/parent changes as before.
        local coordinate=inCombat and f==_G._EBS_CoordFrame and not f.SetFrameLevel
            and f:GetParent()==self.host
        if (not inCombat or coordinate) and safe(f) then
            if f:GetParent()~=self.host then self:SetLayout(f,'SetParent',self.host) end
            if f.SetFrameStrata and f:GetFrameStrata()~='MEDIUM' then self:SetLayout(f,'SetFrameStrata','MEDIUM') end
            if f.SetFrameLevel then
                if f:GetFrameLevel()~=level then self:SetLayout(f,'SetFrameLevel',level) end
            end
            local scale=s.effective/UIParent:GetEffectiveScale()
            if f:GetScale()~=scale then self:SetLayout(f,'SetScale',scale) end
            local point,anchor,relative,x,y=f:GetPoint(1)
            if f:GetNumPoints()~=1 or point~='CENTER' or anchor~=self.host or relative~='BOTTOMLEFT' or x~=s.x or y~=s.y then
                self:SetLayout(f,'ClearAllPoints');self:SetLayout(f,'SetPoint','CENTER',self.host,'BOTTOMLEFT',s.x,s.y)
            end
        end
    end
    self.layoutWriting=nil
end
-- Explicit session-only diagnostics: observe owned layout without repairs.
function controls:TraceLayout(message)
    if not self.traceEnabled then return end
    self.layoutTrace=self.layoutTrace or {}
    if #self.layoutTrace>=16 then table.remove(self.layoutTrace,1) end
    self.layoutTrace[#self.layoutTrace+1]=string.format('%.3f %s',GetTime and GetTime() or 0,message)
end
function controls:WatchLayout(f)
    if not hooksecurefunc then return end
    self.layoutWatches=self.layoutWatches or setmetatable({}, {__mode='k'})
    if self.layoutWatches[f] then return end
    self.layoutWatches[f]=true
    for _,method in ipairs({'SetPoint','SetParent','SetScale','Show','SetShown'}) do
        if type(f[method])=='function' then
            hooksecurefunc(f,method,function()
                if not controls.traceEnabled or controls.layoutWriting or not controls.saved or not controls.saved[f] then return end
                local ok,mismatch,label=pcall(function()
                    local point,anchor,relative,x,y=f:GetPoint(1)
                    local s=controls.saved[f]
                    return f:GetParent()~=controls.host or f:GetNumPoints()~=1 or point~='CENTER'
                        or anchor~=controls.host or relative~='BOTTOMLEFT' or x~=s.x or y~=s.y
                        or math.abs(f:GetScale()-s.effective/UIParent:GetEffectiveScale())>.0001,
                        f._indicatorKey or f.GetName and f:GetName() or 'anonymous control'
                end)
                if not ok or not mismatch then return end
                local now=GetTime and GetTime() or 0
                if controls.traceLastAt==now and controls.traceLastFrame==f and controls.traceLastMethod==method then return end
                controls.traceLastAt=now;controls.traceLastFrame=f;controls.traceLastMethod=method
                controls:TraceLayout(tostring(label)..' '..method..' moved off replacement anchor')
                if debugstack and (controls.traceStacks or 0)<6 then
                    controls.traceStacks=(controls.traceStacks or 0)+1
                    local readable,stack=pcall(debugstack,3,3,0)
                    if readable and type(stack)=='string' then controls:TraceLayout(stack:gsub('[\r\n]+',' | '):sub(1,500)) end
                end
            end)
        end
    end
end
if SlashCmdList then
    SLASH_FDGCONTROLS1='/fdgcontrols'
    SlashCmdList.FDGCONTROLS=function(message)
        local command=(message or ''):lower():match('^%s*(%S+)')
        if command=='trace' or command=='on' then
            controls.traceEnabled=true;controls.layoutTrace={};controls.traceStacks=0
            NS.Print('Control flash trace enabled. Reproduce, then /fdgcontrols. /fdgcontrols off stops tracing.')
        elseif command=='off' then controls.traceEnabled=nil;NS.Print('Control flash trace disabled.')
        else
            NS.Print('Control flash trace: '..tostring(controls.traceEnabled==true)..'; stationary ownership='..tostring(controls.saved~=nil))
            for _,line in ipairs(controls.layoutTrace or {})do NS.Print(line) end
        end
    end
end
function controls:Start()
    if locked() or self.saved then return end
    self.host=self.host or CreateFrame('Frame',nil,UIParent)
    self.host:SetAllPoints(UIParent);self.host:EnableMouse(false);self.host:Show()
    self.saved={}
    self:TraceLayout('stationary controls begin; HUD='..tostring(NS.db and NS.db.hud.enabled)..'; capture='..tostring(NS.CursorSweepActive==true))
    self.coordinateDiagnostic={}
    self:WatchCoordinates()
    local candidates={}
    for _,name in ipairs(names)do if _G[name] then candidates[#candidates+1]=_G[name] end end
    if Minimap.GetChildren then
        for _,f in ipairs({Minimap:GetChildren()})do
            if safe(f) then
            local key=f._indicatorKey
            if not (issecretvalue and issecretvalue(key)) and type(key)=='string' and keys[key] then candidates[#candidates+1]=f end
            local normal=f._norm
            if f._bg and normal and normal.GetAtlas and normal:GetAtlas()=='Map-Filter-Button' then candidates[#candidates+1]=f end
            end
        end
    end
    -- Read all geometry before changing any parent or anchor.
    for _,f in ipairs(candidates)do
        if safe(f) and not self.saved[f] then
            local x,y=f:GetCenter();local scale=f:GetEffectiveScale();local ui=UIParent:GetEffectiveScale()
            if number(x) and number(y) and number(scale) and number(ui) and ui>0 and scale>0 then
                local s={parent=f:GetParent(),scale=f:GetScale(),effective=scale,x=x*scale/ui,y=y*scale/ui,strata=f.GetFrameStrata and f:GetFrameStrata(),level=f.GetFrameLevel and f:GetFrameLevel(),points={}}
                for i=1,f:GetNumPoints()do s.points[i]={f:GetPoint(i)} end
                self.saved[f]=s
                self:WatchLayout(f)
                self:GuardLayout(f)
            end
        end
    end
    self:Maintain()
end
function controls:Stop()
    if locked() then return end -- shared scanner defers Stop until combat ends
    if self.saved then self:TraceLayout('stationary controls release; HUD='..tostring(NS.db and NS.db.hud.enabled)..'; capture='..tostring(NS.CursorSweepActive==true)) end
    local saved=self.saved;self.saved=nil
    for f,s in pairs(saved or {})do
        f:SetParent(s.parent);f:SetScale(s.scale);f:ClearAllPoints()
        if s.strata then f:SetFrameStrata(s.strata) end
        if s.level then f:SetFrameLevel(s.level) end
        for _,p in ipairs(s.points)do f:SetPoint(unpack(p)) end
    end
    if self.host then self.host:Hide() end
end
