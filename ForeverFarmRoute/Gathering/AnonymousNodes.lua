local _, FRNS_ = ...; local NS = FRNS_.Gathering
-- Reader/display adaptation only. All node ownership, confirmation, movement
-- matching, centering and validation remain in the original shared workflow.
local function public(v)return not(issecretvalue and issecretvalue(v))end
local function number(v)return public(v)and type(v)=='number'and v==v and math.abs(v)<math.huge end
local function read(fn,...)
    if type(fn)~='function'then return end
    local ok,result=pcall(fn,...)
    if ok and public(result)then return result end
end
local groupCache
function NS:IsAnonymousGroupMarker(ctx,px,py)
    if not ctx or not(number(px)and number(py))then return false end
    local raid=read(IsInRaid)==true
    local count=read(raid and GetNumGroupMembers or GetNumSubgroupMembers)
    if not number(count)then
        if raid or read(IsInGroup)==true then
            self.AnonymousGroupMaskStatus='group membership unreadable'
            return true,'group membership unavailable'
        end
        count=0
    end
    count=math.min(raid and 40 or 4,math.max(0,count))
    local now=read(GetTime);now=number(now)and now or 0
    if not groupCache or groupCache.map~=ctx.map or groupCache.raid~=raid or groupCache.count~=count or now<groupCache.at or now-groupCache.at>=.1 then
        groupCache={map=ctx.map,raid=raid,count=count,at=now,points={},unknown=0}
        for i=1,count do
            local unit=(raid and 'raid'or 'party')..i
            if read(UnitIsUnit,unit,'player')~=true then
                    local pos=read(C_Map and C_Map.GetPlayerMapPosition,ctx.map,unit)
                    local ok,x,y=pcall(function()return pos:GetXY()end)
                    if ok and number(x)and number(y)and x>=0 and x<=1 and y>=0 and y<=1 then
                        groupCache.points[#groupCache.points+1]={x=x,y=y}
                    else groupCache.unknown=groupCache.unknown+1 end
            end
        end
    end
    local radius=13 -- Trial margin after eight pixels admitted false group-marker icons.
    self.AnonymousGroupMaskStatus='members='..count..'; public positions='..#groupCache.points..'; unavailable='..groupCache.unknown..'; radius='..radius..'px'
    -- If a possibly visible member has no public location, do not guess that
    -- their secret tooltip is a resource. This is unknown, never empty.
    if groupCache.unknown>0 then return true,'group marker positions unavailable'end
    local sampleX,sampleY=(px-ctx.width/2)*ctx.scale,(py-ctx.height/2)*ctx.scale
    for _,point in ipairs(groupCache.points)do
        local east,north=(point.x-ctx.x)*ctx.w,(ctx.y-point.y)*ctx.h
        local x=(east*ctx.cos+north*ctx.sin)/ctx.radius*ctx.width*ctx.scale/2
        local y=(north*ctx.cos-east*ctx.sin)/ctx.radius*ctx.width*ctx.scale/2
        if(sampleX-x)^2+(sampleY-y)^2<=radius^2 then return true,'group marker area'end
    end
    return false
end
-- Temporary diagnostic trial requested by the author: leave quest exclusion
-- disabled across reloads while checking zero-hit scanning. Not a saved setting.
NS.AnonymousQuestMaskEnabled=true -- FarmRoute: unmatched sightings are drawn, so keep quest waypoints out
-- Native quest waypoints use the same secret minimap tooltip shape as nodes.
-- Project their public position, including the clamped edge arrow, rather than
-- trying to identify or inspect protected tooltip text.
function NS:IsAnonymousQuestMarker(ctx,px,py)
    if not ctx or not(number(px)and number(py))then return false end
    local quest=read(C_SuperTrack and C_SuperTrack.GetSuperTrackedQuestID)
    if not number(quest)or quest<=0 then return false end
    local fn=C_QuestLog and C_QuestLog.GetNextWaypointForMap
    if type(fn)~='function'then return true,'tracked quest position unavailable'end
    local ok,x,y=pcall(fn,quest,ctx.map)
    if not ok or not(number(x)and number(y))or x<0 or x>1 or y<0 or y>1 then
        -- No reliable bearing: withhold anonymous inference, never vote empty.
        return true,'tracked quest position unavailable'
    end
    local east,north=(x-ctx.x)*ctx.w,(ctx.y-y)*ctx.h
    local dx,dy=(east*ctx.cos+north*ctx.sin)/ctx.radius,(north*ctx.cos-east*ctx.sin)/ctx.radius
    local distance=math.sqrt(dx*dx+dy*dy)
    if distance>1 then dx,dy=dx/distance,dy/distance end
    local markerX,markerY=dx*ctx.width*ctx.scale/2,dy*ctx.height*ctx.scale/2
    local sampleX,sampleY=(px-ctx.width/2)*ctx.scale,(py-ctx.height/2)*ctx.scale
    if(sampleX-markerX)^2+(sampleY-markerY)^2<=20^2 then return true,'tracked quest marker area'end
    return false
end
local resources={
    herb={id=-2383,name='Unidentified herb',kind='herb',anonymous=true,icon='Interface\\Icons\\INV_Misc_QuestionMark'},
    ore={id=-2580,name='Unidentified ore',kind='ore',anonymous=true,icon='Interface\\Icons\\INV_Misc_QuestionMark'},
}
function NS:GetAnonymousGatheringResource(data,ctx,px,py)
    self.AnonymousReadExclusion=nil
    -- Physical minimap hover and experimental scanning share this reader.
    -- Hidden names must also produce generic observations outside a scan.
    if not public(data)or type(data)~='table'then return end
    local expected=Enum and Enum.TooltipDataType and Enum.TooltipDataType.MinimapMouseover or 21
    if not public(data.type)or data.type~=expected then return end
    local lines=data.lines
    if not public(lines)or type(lines)~='table'then return end
    local first=lines[1]
    if not public(first)or type(first)~='table'then return end
    local text=first.leftText
    if public(text)or type(text)~='string'then return end
    -- Check containers/types only. Never compare/convert/measure secret text.
    for i=1,32 do
        local line=lines[i]
        if not public(line)then return end
        if line~=nil then
            if type(line)~='table'then return end
            for _,key in ipairs({'leftText','rightText'})do
                local field=line[key]
                if public(field)then if field~=nil and type(field)~='string'then return end
                elseif type(field)~='string'then return end
            end
        end
    end
    if not public(lines[33])or lines[33]~=nil then return end
    local ok,spell=pcall(self.GetActiveGatheringTracking,self)
    if not ok or not public(spell)then return end
    local kind=spell==2383 and 'herb'or spell==2580 and 'ore'or nil
    if not kind or self.HasGatheringProfession and not self:HasGatheringProfession(kind)then return end
    local excluded,reason=self:IsAnonymousGroupMarker(ctx,px,py)
    if excluded then self.AnonymousReadExclusion=reason;return end
    -- Known !/? locations are shared with the quest renderer. Keep the broad
    -- tracked-waypoint diagnostic mask independent of these precise markers.
    if self.TerrainQuests and self.TerrainQuests.IsScanMarker then
        excluded,reason=self.TerrainQuests:IsScanMarker(ctx,px,py)
        if excluded then
            self.AnonymousQuestMaskStatus=reason;self.AnonymousReadExclusion=reason;return
        end
    end
    if self.AnonymousQuestMaskEnabled then
        excluded,reason=self:IsAnonymousQuestMarker(ctx,px,py)
        self.AnonymousQuestMaskStatus=reason or 'no quest marker overlap'
        if excluded then self.AnonymousReadExclusion=reason;return end
    else
        self.AnonymousQuestMaskStatus='disabled for diagnostic trial'
    end
    self.AnonymousReadExclusion=nil
    return resources[kind]
end
local anonymousTextures={herb='Interface\\AddOns\\ForeverFarmRoute\\Gathering\\Media\\TrackingHerb',
        ore='Interface\\AddOns\\ForeverFarmRoute\\Gathering\\Media\\TrackingOre'}
-- Presentation-only historical identity. Never change the live generic record.
local artworkIndexes={}
function NS:GetAnonymousNodeArtwork(node,scannerRange)
    if not node.anonymous then return nil,nil,'named observation' end
    if not number(node.uncertainty) or node.uncertainty<0 then return nil,nil,'unknown position uncertainty' end
    if not self.NewNodeLocationIndex or not self.GetGatheringNodeContext then return nil,nil,'location services unavailable' end
    local ctx=self:GetGatheringNodeContext()
    if not ctx or ctx.map~=node.map or not(number(ctx.w)and number(ctx.h))or ctx.w<=0 or ctx.h<=0 then return nil,nil,'current map geometry unavailable' end
    local imported=self.GetImportedNodeLocations and self:GetImportedNodeLocations(node.map)
    local sources={self.db and self.db.nodeLocations or {},self.BundledNodeLocations or {},imported or {},
        self.db and self.db.refinedNodeHints or {},self.BundledRefinedNodeHints or {}}
    -- Live provisional sightings carry an uncertainty region, not a finished
    -- centre. Consider all historical possibilities in that bounded region.
    -- Physical hover and explicit lookup use the scanner distance rules.
    local reach=math.max(15,node.uncertainty+12)
    local nearby,best={},nil
    for slot,source in ipairs(sources)do
        local rows=source.version==1 and source.maps and source.maps[node.map]
        if type(rows)=='table' then
            local index=artworkIndexes[slot]
            if not index or index.rows~=rows then index=self:NewNodeLocationIndex(rows);artworkIndexes[slot]=index end
            if not index:Build(128)then return nil,nil,'historical index building' end
            local q=index:Query(node.x,node.y,reach/ctx.w,reach/ctx.h)
            local done=false
            for _=1,256 do
                local row;row,done=index:Next(q)
                if row and row.kind==node.kind and not row.anonymous then
                    local d=((row.x-node.x)*ctx.w)^2+((row.y-node.y)*ctx.h)^2
                    if d<=reach^2+1e-8 then
                        nearby[#nearby+1]={row=row,d=d}
                        if number(row.uncertainty)and row.uncertainty>=0 and row.uncertainty<=12
                            and d<=(4+node.uncertainty+row.uncertainty)^2
                            and (not best or d<best.d)then best=nearby[#nearby] end
                    end
                end
                if done then break end
            end
            if not done then return nil,nil,'historical query budget reached' end
        end
    end
    if not best then return nil,nil,'no precise historical match in position region' end
    local candidate,second
    local types,seen={},{}
    local limit=4
    for _,hit in ipairs(nearby)do
        local row=hit.row
        local separation=((row.x-best.row.x)*ctx.w)^2+((row.y-best.row.y)*ctx.h)^2
        if separation<=12^2 then
            local entry=self:GetNodeResourceByID(row.id,row.kind)
            if not entry then return nil,nil,'nearby resource not in catalogue' end
            if not seen[entry.id] then
                seen[entry.id]=true;types[#types+1]=entry
                if #types>limit then return nil,nil,'more than '..limit..' historical types at closest spawn' end
            end
        elseif math.sqrt(hit.d)-math.sqrt(best.d)<=4 then
            -- Do not choose one of two similarly close, separate spawn points.
            return nil,nil,'separate historical spawns equally close'
        end
    end
    table.sort(types,function(a,b)return tostring(a.id)<tostring(b.id)end)
    candidate,second=types[1],types[2]
    return candidate,second,second and 'split closest historical spawn' or 'single closest historical spawn',best.row,types
end
function NS:RenderAnonymousNodeIcon(icon,node,size,alpha)
    local dot,rim=icon.anonymousImage,icon.anonymousBorder
    for _,part in ipairs({icon.anonymousThird,icon.anonymousFourth})do
        part:Hide()
        if part.RemoveMaskTexture and icon.artworkMask then part:RemoveMaskTexture(icon.artworkMask)end
    end
    if icon.splitMasked then
        if dot and dot.RemoveMaskTexture then dot:RemoveMaskTexture(icon.artworkMask)end
        if rim and rim.RemoveMaskTexture then rim:RemoveMaskTexture(icon.artworkMask)end
        icon.splitMasked=nil
    end
    if not node.anonymous then
        if icon.letter then icon.letter:Hide()end
        if dot then dot:Hide()end
        if rim then rim:Hide()end
        return
    end
    icon.image:Hide();icon.border:Hide();icon.elevation:Hide();icon.cave:Hide()
    if icon.letter then icon.letter:Hide()end
    if not dot or not rim then return end
    local known,second,reason,anchor,types=self:GetAnonymousNodeArtwork(node)
    node.anonymousArtworkStatus=reason
    if known then
        dot:Hide();rim:Hide()
        if types and #types>2 and icon.anonymousThird and icon.anonymousFourth then
            icon.anonymousStyle=nil
            local parts={dot,rim,icon.anonymousThird,icon.anonymousFourth}
            for i,entry in ipairs(types)do
                local part=parts[i]
                if part.AddMaskTexture and icon.artworkMask then part:AddMaskTexture(icon.artworkMask)end
                part:SetTexture(self:GetNodeResourceIcon(entry,node.kind))
                part:SetTexCoord(.08+.84*(i-1)/#types,.08+.84*i/#types,.08,.92)
                part:ClearAllPoints();part:SetPoint('LEFT',icon.image,'LEFT',(i-1)*size/#types,0)
                part:SetSize(size/#types,size);part:SetVertexColor(1,1,1);part:SetAlpha(alpha);part:Show()
            end
            icon.splitMasked=true
        elseif second then
            -- Crop each resource to its own half; preserve the shared ring anchor.
            icon.anonymousStyle=nil
            if icon.artworkMask and dot.AddMaskTexture and rim.AddMaskTexture then
                dot:AddMaskTexture(icon.artworkMask);rim:AddMaskTexture(icon.artworkMask)
                icon.splitMasked=true
            end
            for i,entry in ipairs({known,second})do
                local half=i==1 and dot or rim
                half:SetTexture(self:GetNodeResourceIcon(entry,node.kind))
                half:SetTexCoord(i==1 and .08 or .5,i==1 and .5 or .92,.08,.92)
                half:ClearAllPoints();half:SetPoint(i==1 and 'LEFT'or 'RIGHT',icon.image,i==1 and 'LEFT'or 'RIGHT',0,0)
                half:SetSize(size/2,size);half:SetVertexColor(1,1,1);half:SetAlpha(alpha);half:Show()
            end
        else
            icon.image:SetTexture(self:GetNodeResourceIcon(known,node.kind));icon.image:Show()
        end
        local difficulty=self.GetGatheringNodeDifficulty and self:GetGatheringNodeDifficulty(known)
        for _,entry in ipairs(types or (second and {second} or {}))do
            local other=self.GetGatheringNodeDifficulty and self:GetGatheringNodeDifficulty(entry)
            if other~=difficulty then difficulty=nil end
        end
        local color=self.GatheringDifficultyColors and self.GatheringDifficultyColors[difficulty]
        if color then icon.border:SetVertexColor(color[1],color[2],color[3]);icon.border:Show()end
        return
    end
    local texture=anonymousTextures[node.kind]
    if texture then
        if icon.anonymousStyle~=texture then
            dot:SetTexture(texture);dot:SetTexCoord(0,1,0,1)
            icon.anonymousStyle=texture
        end
        dot:ClearAllPoints();dot:SetPoint('CENTER',icon.image,'CENTER')
        dot:SetSize(size,size);dot:SetVertexColor(1,1,1);dot:SetAlpha(alpha);dot:Show();rim:Hide()
        return
    end
    -- A plain round yellow marker, with a small black rim like native blips.
    -- Only replacement anonymous dots change; native/client/other-addon pins
    -- and the existing named-node artwork keep their original sizes.
    local diameter=math.max(4,math.min(10,size*.6))
    if icon.anonymousStyle~='dot' then
        dot:SetTexture('Interface\\COMMON\\CommonMaskCircle')
        rim:SetTexture('Interface\\COMMON\\CommonMaskCircle')
        rim:ClearAllPoints();rim:SetPoint('CENTER',icon.image,'CENTER')
        dot:SetTexCoord(0,1,0,1)
        dot:ClearAllPoints();dot:SetPoint('CENTER',icon.image,'CENTER')
        icon.anonymousStyle='dot'
    end
    dot:SetSize(diameter,diameter);dot:SetVertexColor(1,.82,0);dot:SetAlpha(alpha);dot:Show()
    rim:SetSize(diameter+2,diameter+2);rim:SetVertexColor(0,0,0);rim:SetAlpha(alpha);rim:Show()
end
