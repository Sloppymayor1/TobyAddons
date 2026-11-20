local _, FRNS_ = ...; local NS = FRNS_.Gathering
local trial=NS.CursorSweepTrial
-- Geometry ported from preserved regular FDG 1.1.2. Only probe transport is asynchronous.
local function pixel(c)return 2*c.radius/(c.width*c.scale)end
local function copyContext(c)
    local result={};for k,v in pairs(c)do result[k]=v end;return result
end
local VIEW_TOLERANCE={w=.001,h=.001,width=.01,height=.01,scale=.00001,radius=.001,iconScale=.00001}
local function changedView(c,old)
    if not c then return 'unreadable map context' end
    for _,field in ipairs({'map','w','h','width','height','scale','radius','iconScale'})do
        local a,b=c[field],old[field]
        local tolerance=VIEW_TOLERANCE[field]
        local changed
        if tolerance and type(a)=='number' and type(b)=='number' then changed=math.abs(a-b)>tolerance
        else changed=a~=b end
        if changed then return field..' '..tostring(b)..' -> '..tostring(a) end
    end
end
local function relative(c,origin,spot)
    local e,n=(spot.x-origin.x)*c.w,-(spot.y-origin.y)*c.h
    return (e*c.cos+n*c.sin)/pixel(c),(-e*c.sin+n*c.cos)/pixel(c)
end
local function offset(c,origin,x,y)
    return {x=origin.x+(x*c.cos-y*c.sin)*pixel(c)/c.w,
        y=origin.y-(y*c.cos+x*c.sin)*pixel(c)/c.h}
end
local function distance(a,b,c)return ((a.x-b.x)*c.w)^2+((a.y-b.y)*c.h)^2 end
local function present(node)
    for _,v in ipairs(NS.GatheringNodeCache or {})do if v==node then return true end end
end
local function engine(node,ctx,seed)
    local group={}
    for k,v in pairs(node)do group[k]=v end
    if seed then group.x,group.y=seed.x,seed.y end
    group.centered=nil;group.centerTried=nil;group.pendingHits=nil;group.locationCandidate=nil
    group.samples=1
    local nodes={}
    for _,other in ipairs(NS.GatheringNodeCache or {})do
        if other~=node then
            local copy={};for k,v in pairs(other)do copy[k]=v end
            copy.centered=other.manualRefined or other.centered
            local footprint=other.manualPositiveFootprint
            copy.hitRadius=footprint and footprint.radius*ctx.iconScale*pixel(ctx) or nil
            nodes[#nodes+1]=copy
        end
    end
    local scan={found={group}}
    local PIXEL_STEP=12
    local playerMoving,lastMovement,TRACKING_SETTLE=false,-math.huge,1
    local axisCos,axisSin=ctx.cos,ctx.sin
    local currentContext=copyContext(ctx)
    local function probe()error('legacy discovery transport is disabled')end
local function profileProbe(profile, offset, ctx)
    local shift = offset / ctx.scale / (ctx.width / 2) * ctx.radius
    local cos, sin = math.cos(profile.angle), math.sin(profile.angle)
    local axisCos, axisSin = ctx.cos * cos - ctx.sin * sin, ctx.sin * cos + ctx.cos * sin
    local x, y = profile.x - shift * axisSin / ctx.w, profile.y - shift * axisCos / ctx.h
    return {group = profile.group, x = x, y = y, axis = 1, sign = -1,
        reach = 2, inside = 0, cos = ctx.cos, sin = ctx.sin, profile = profile, profileOffset = offset,
        probeCos = cos, probeSin = sin, axisCos = axisCos, axisSin = axisSin, moving = profile.moving}
end
local function circlePoint(profile, u, v, ctx)
    local cos, sin = math.cos(profile.angle), math.sin(profile.angle)
    local axisCos, axisSin = ctx.cos * cos - ctx.sin * sin, ctx.sin * cos + ctx.cos * sin
    local unit = ctx.radius / (ctx.width * ctx.scale / 2)
    return profile.originX + (u * axisCos - v * axisSin) * unit / ctx.w,
        profile.originY - (u * axisSin + v * axisCos) * unit / ctx.h
end
local function circleCandidates(profile, negative, ctx)
    local middle, positive = profile.middle, profile.positive
    if middle.half <= 0 or positive.half <= 0 or negative.half <= 0 then return end
    local cos, sin = math.cos(profile.angle), math.sin(profile.angle)
    local axisCos, axisSin = ctx.cos * cos - ctx.sin * sin, ctx.sin * cos + ctx.cos * sin
    local unit = (ctx.width * ctx.scale / 2) / ctx.radius
    local function along(section)
        return ((section.x - profile.originX) * ctx.w * axisCos
            + (profile.originY - section.y) * ctx.h * axisSin) * unit
    end
    local fits = {}
    for _, side in ipairs({-1, 1}) do
        -- Three nearby points on one outer edge describe its own circular
        -- lobe, even when the opposite edge belongs to a neighboring dot.
        local a = along(middle) + side * middle.half
        local b = along(positive) + side * positive.half - a
        local c = along(negative) + side * negative.half - a
        if math.abs(b + c) >= 0.7 then
            local u = (b*b + c*c + 32) / (2 * (b + c))
            local v = (b*b + 16 - 2*u*b) / 8
            local radius = math.sqrt(u*u + v*v)
            if radius >= 6 and radius <= 24 then
                local fit = {u = a + u, v = v, radius = radius, side = side}
                fit.x, fit.y = circlePoint(profile, fit.u, fit.v, ctx)
                fits[#fits + 1] = fit
            end
        end
    end
    table.sort(fits, function(a, b) return distance(a, profile.seed, ctx) < distance(b, profile.seed, ctx) end)
    return fits
end
local function circleCheck(profile, ctx)
    local fit = profile.circleFits[profile.circleIndex]
    while fit do
        local offset = profile.circleSide == 1 and 8 or -8
        local square = fit.radius^2 - (offset - fit.v)^2
        if square > 0 then
            local u = fit.u + fit.side * (math.sqrt(square) + (profile.circleOutside and 0.125 or -0.125))
            local x, y = circlePoint(profile, u, offset, ctx)
            return {group = profile.group, x = x, y = y, axis = 3, circleCheck = profile,
                cos = ctx.cos, sin = ctx.sin, moving = profile.moving}
        end
        if profile.circleSide == 1 then profile.circleSide = 2
        else profile.circleSide, profile.circleIndex = 1, profile.circleIndex + 1 end
        fit = profile.circleFits[profile.circleIndex]
    end
end
local function profileResult(profile, result, ctx, resume)
    -- Every cross-section is measured with live probes. Find a local widest
    -- section instead of accepting the midpoint of two connected hitboxes.
    if not resume then profile.reads = profile.reads + 1 end
    local function finish(best)
        return {group = profile.group, x = best.x, y = best.y, axis = 3,
            cos = ctx.cos, sin = ctx.sin, profileDone = true, profileRadius = best.half,
            halfWidth = best.half, halfHeight = best.half, moving = profile.moving}
    end
    local function walk()
        local offset = profile.best.offset + profile.direction * 4
        if math.abs(offset) >= profile.extent or profile.reads >= 20 then return nil end
        return profileProbe(profile, offset, ctx)
    end
    if profile.phase == 0 then
        if result.half == 0 then return nil end
        profile.middle, profile.phase = result, 1
        profile.x, profile.y = result.x, result.y
        return profileProbe(profile, 4, ctx)
    elseif profile.phase == 1 then
        profile.positive, profile.phase = result, 2
        return profileProbe(profile, -4, ctx)
    elseif profile.phase == 2 then
        if profile.circleAngle ~= profile.angle then
            profile.circleAngle = profile.angle
            profile.circleFits = circleCandidates(profile, result, ctx) or {}
            profile.circleIndex, profile.circleSide, profile.circleOutside = 1, 1, false
            profile.circleResult = result
            local check = circleCheck(profile, ctx)
            if check then return check end
        end
        local widest = math.max(profile.middle.half, profile.positive.half, result.half)
        if not profile.choice or widest < profile.choice.widest then
            profile.choice = {middle = profile.middle, positive = profile.positive, negative = result,
                widest = widest, angle = profile.angle}
        end
        profile.angleIndex = profile.angleIndex + 1
        local angle = profile.angles[profile.angleIndex]
        if angle then
            profile.angle, profile.phase = angle, 0
            profile.x, profile.y = profile.originX, profile.originY
            return profileProbe(profile, 0, ctx)
        end
        -- Compare neighboring sections too: a direction through both lobes
        -- can be narrow at the seed and much wider just a few pixels away.
        local choice = profile.choice
        profile.middle, profile.positive, result = choice.middle, choice.positive, choice.negative
        profile.x, profile.y, profile.angle = choice.middle.x, choice.middle.y, choice.angle
        local best = profile.middle
        if profile.positive.half > best.half then best = profile.positive end
        if result.half > best.half then best = result end
        if profile.positive.half > profile.middle.half and result.half > profile.middle.half then
            -- Both lobes can be wider than their shared midpoint. Refine the
            -- lobe belonging to the original positive hit, so repeated seeds
            -- from the second dot do not always converge on the first one.
            best = distance(profile.positive, profile.seed, ctx) < distance(result, profile.seed, ctx)
                and profile.positive or result
        end
        if best == profile.middle then return finish(best) end
        profile.previous, profile.best = profile.middle, best
        profile.direction, profile.phase = best.offset > 0 and 1 or -1, 3
        return walk()
    elseif profile.phase == 3 then
        if result.half > profile.best.half then
            profile.previous, profile.best = profile.best, result
            return walk()
        end
        -- Interpolate within the measured bracket, then measure that section
        -- and confirm its center separately before publishing or saving it.
        local left, middle, right = profile.previous.half^2, profile.best.half^2, result.half^2
        local curvature = left - 2 * middle + right
        if curvature >= -0.01 then return finish(profile.best) end
        local shift = profile.direction * 4 * (left - right) / (2 * curvature)
        shift = math.max(-4, math.min(4, shift))
        if math.abs(shift) < 0.125 then return finish(profile.best) end
        profile.phase = 4
        return profileProbe(profile, profile.best.offset + shift, ctx)
    end
    return finish(result.half >= profile.best.half and result or profile.best)
end
local rectangleSeed, rectangleGate
local function centerProfile(job, ctx, x, y)
    local angle = job.halfWidth < job.halfHeight and 0 or math.pi / 2
    local nearest
    local reach = 4 * PIXEL_STEP / (ctx.width * ctx.scale / 2) * ctx.radius
    for _, node in ipairs(nodes) do
        local separation = distance(node, job.group, ctx)
        if node.centered and node.map == ctx.map and node.id == job.group.id and node.hitRadius
            and separation > node.hitRadius^2 and separation < reach^2 and (not nearest or separation < nearest) then
            -- Expose the new lobe's far edge instead of cutting through the
            -- known node and repeatedly converging on its center.
            local east, north = (job.group.x - node.x) * ctx.w, (node.y - job.group.y) * ctx.h
            local sx, sy = east * ctx.cos + north * ctx.sin, north * ctx.cos - east * ctx.sin
            if sx == 0 then angle = sy >= 0 and math.pi / 2 or -math.pi / 2
            else
                angle = math.atan(sy / sx)
                if sx < 0 then angle = angle + math.pi end
            end
            nearest = separation
        end
    end
    local angles = {angle, math.pi / 4, -math.pi / 4}
    if math.min(job.halfWidth, job.halfHeight) >= 6 then
        -- The perpendicular cut exposes the far lobe when the first set of
        -- sections crosses the connection between two close dots.
        angles = {angle, angle + math.pi / 2, math.pi / 4, -math.pi / 4}
    end
    local profile = {group = job.group, x = x, y = y, originX = x, originY = y,
        seed = {x = job.group.x, y = job.group.y}, moving = job.moving,
        angle = angle, angles = angles, angleIndex = 1,
        extent = math.max(job.halfWidth, job.halfHeight) * 1.5, phase = 0, reads = 0}
    return rectangleGate({original = job, fallback = profileProbe(profile, 0, ctx)}, ctx, 1)
end
rectangleGate = function(gate, ctx, step)
    -- Test a shifted straight edge before spending a whole trace on a box.
    -- Circular hitboxes continue with their ordinary profile after four reads.
    local original = gate.original
    local normal = (original.y - original.group.y) * ctx.h * ctx.cos
        - (original.group.x - original.x) * ctx.w * ctx.sin
    local unit = ctx.radius / (ctx.width * ctx.scale / 2)
    -- The initial axis trace has up to 0.75 pixel edge brackets. Leave
    -- enough margin for that rounding; the subsequent box trace is finer.
    local x = original.halfWidth + (step % 2 == 0 and 1 or -1)
    local y = original.halfWidth * (step <= 2 and 0.6 or -0.6)
    return {group = original.group, axis = 3, rectangleGate = gate, rectangleStep = step,
        x = original.x - normal * ctx.sin / ctx.w + (x * ctx.cos - y * ctx.sin) * unit / ctx.w,
        y = original.y - normal * ctx.cos / ctx.h - (y * ctx.cos + x * ctx.sin) * unit / ctx.h,
        cos = ctx.cos, sin = ctx.sin, moving = gate.fallback.moving}
end
rectangleSeed = function(original, fallback, ctx, index)
    -- A count increase means another same-title hitbox joined this ray. Its
    -- first subsequent decrease exposes the original box's edge even though
    -- the neighboring tooltip remains present. Start in a single-title area.
    if index > 5 then return fallback end
    local x, y = original.group.x, original.group.y
    if index > 1 then
        local horizontal = index < 4
        local radius = horizontal and original.halfWidth or original.halfHeight
        local shift = math.max(0, radius - 2) * (index % 2 == 0 and -1 or 1)
            / (ctx.width * ctx.scale / 2) * ctx.radius
        x, y = original.x, original.y
        if horizontal then x, y = x + shift * ctx.cos / ctx.w, y - shift * ctx.sin / ctx.h
        else x, y = x - shift * ctx.sin / ctx.w, y - shift * ctx.cos / ctx.h end
    end
    return {group = original.group, x = x, y = y, axis = 1, sign = -1,
        reach = 2, inside = 0, cos = ctx.cos, sin = ctx.sin, moving = fallback.moving,
        rectangle = {original = original, fallback = fallback, index = index}}
end
local function nextRectangle(job, ctx)
    local box = job.rectangle
    return rectangleSeed(box.original, box.fallback, ctx, box.index + 1)
end
local function rectangleEdge(box, ctx, step)
    local pair = math.floor((step - 1) / 2)
    local edge, sample = math.floor(pair / 3), pair % 3 - 1
    local horizontal, sign = edge < 2, edge % 2 == 0 and -1 or 1
    local outside = step % 2 == 0
    local across = sample * 0.6
    local x = horizontal and sign * (box.halfWidth + (outside and 0.5 or -0.5)) or across * box.halfWidth
    local y = horizontal and across * box.halfHeight or sign * (box.halfHeight + (outside and 0.5 or -0.5))
    local unit = ctx.radius / (ctx.width * ctx.scale / 2)
    return {group = box.group, axis = 3, rectangleEdge = box, rectangleStep = step,
        x = box.x + (x * ctx.cos - y * ctx.sin) * unit / ctx.w,
        y = box.y - (y * ctx.cos + x * ctx.sin) * unit / ctx.h,
        cos = ctx.cos, sin = ctx.sin, moving = box.moving}
end
local function rejectFastLocation(group)
    local saved = group.fastLocation
    for _, node in ipairs(nodes) do
        if saved and node.fastLocation == saved then node.fastLocation = nil end
    end
    group.fastLocation = nil
    group.samples = group.samples + 1
    scan.nextPublish = 0
end
local function shapeCheck(job, ctx, step)
    local angle = math.pi / 4 + math.floor((step - 1) / 2) * math.pi / 2
    local radius = math.max(job.halfWidth, job.halfHeight) + (step % 2 == 1 and -0.75 or 0.75)
    local east, north = math.cos(angle) * radius, math.sin(angle) * radius
    local unit = ctx.radius / (ctx.width * ctx.scale / 2)
    return {group = job.group, axis = 3, shapeCheck = job, shapeStep = step,
        x = job.x + (east * ctx.cos - north * ctx.sin) * unit / ctx.w,
        y = job.y - (north * ctx.cos + east * ctx.sin) * unit / ctx.h,
        cos = ctx.cos, sin = ctx.sin, moving = job.moving}
end
-- Refine an observed hit, never an invented location. Measure opposite edges
-- of its tooltip hitbox and use their midpoint, horizontally then vertically.
-- Each call uses one probe and shares discovery's frame/time limits. The seed
-- stays in zone coordinates so player movement between frames is accounted for.
local function refineCenter(ctx)
    local job = scan.centerJob
    if job and job.group.fastLocation and (playerMoving or GetTime() - lastMovement < TRACKING_SETTLE) then
        job.group.centerTried, scan.centerJob = nil, nil
        return false
    end
    if not job then
        for _, group in ipairs(scan.found) do
            if group.centered and group.pendingHits then
                -- A coarse group may have seen more than one real dot. Check
                -- the retained hits again after measuring the first hitbox.
                while #group.pendingHits > 0 do
                    local hit = table.remove(group.pendingHits)
                    if distance(group, hit, ctx) >= group.hitRadius^2 then
                        job = {group = group, x = hit.x, y = hit.y, probeOnly = true, cos = ctx.cos, sin = ctx.sin}
                        break
                    end
                end
                if #group.pendingHits == 0 then group.pendingHits = nil end
                if job then scan.centerJob = job; break end
            end
            if group.locationCandidate and GetTime() >= (group.locationRetryAt or 0) then
                job = {group = group, x = group.locationCandidate.x, y = group.locationCandidate.y,
                    locationOnly = true, cos = ctx.cos, sin = ctx.sin}
                scan.centerJob = job
                break
            elseif not group.centerTried and not (group.fastLocation
                and (playerMoving or GetTime() - lastMovement < TRACKING_SETTLE)) then
                group.centerTried = true
                if group.recenterNode then group.recenterTriedAt = GetTime() end
                job = { group = group, x = group.x, y = group.y, axis = 1, sign = -1,
                    reach = 2, inside = 0, cos = ctx.cos, sin = ctx.sin }
                scan.centerJob = job
                break
            end
        end
    end
    if not job then return false end
    if playerMoving or GetTime() - lastMovement < TRACKING_SETTLE then job.moving = true end
    if job.profile and job.moving then job.profile.moving = true end
    if job.circleCheck and job.moving then job.circleCheck.moving = true end
    if job.shapeCheck and job.moving then job.shapeCheck.moving = true end
    if job.rectangle and job.moving then job.rectangle.fallback.moving = true end
    if job.rectangleGate and job.moving then job.rectangleGate.fallback.moving = true end
    if job.rectangleEdge and job.moving then
        job.rectangleEdge.moving, job.rectangleEdge.rectangle.fallback.moving = true, true
    end
    if job.cos ~= ctx.cos or job.sin ~= ctx.sin then
        -- Edges measured along different orientations cannot be combined.
        scan.deferReason='measurement orientation changed'
        scan.centerJob = nil
        return false
    end
    local east, north = (job.x - ctx.x) * ctx.w, (ctx.y - job.y) * ctx.h
    local x = ctx.width / 2 + (east * ctx.cos + north * ctx.sin) / ctx.radius * ctx.width / 2
    local y = ctx.height / 2 + (north * ctx.cos - east * ctx.sin) / ctx.radius * ctx.width / 2
    local offset = job.confirmed and job.sign * job.reach / ctx.scale or 0
    local probeCos, probeSin = job.probeCos or 1, job.probeSin or 0
    if job.axis == 1 then x, y = x + offset * probeCos, y + offset * probeSin
    else x, y = x - offset * probeSin, y + offset * probeCos end
    local dx, dy = x - ctx.width / 2, y - ctx.height / 2
    -- A clipped hitbox has no trustworthy midpoint. Leave the coarse estimate.
    if x < 1 or y < 1 or x > ctx.width - 1 or y > ctx.height - 1
        or dx^2 + dy^2 > (ctx.width / 2 - 1)^2 then
        scan.deferReason=string.format("probe clipped at %.1f,%.1f (%.1fpx view)",x*ctx.scale,y*ctx.scale,ctx.width*ctx.scale)
        scan.centerJob = nil
        return false
    end
    if job.probeOnly then
        probe(x, y, ctx)
        scan.centerJob = nil
        return true
    end
    local east = (x-ctx.width/2)/(ctx.width/2)*ctx.radius
    local north = (y-ctx.height/2)/(ctx.width/2)*ctx.radius
    local result=coroutine.yield({x=ctx.x+(east*ctx.cos-north*ctx.sin)/ctx.w,
        y=ctx.y-(north*ctx.cos+east*ctx.sin)/ctx.h,
        phase=job.profile and "profile" or job.axis==3 and "confirm" or "edges",axis=tostring(job.axis),
        requiresPositive=not job.confirmed,
        previewCentre=job.axis==3 and not job.profile and not job.profileDone and not job.shapeCheck
            and not job.rectangle and not job.rectangleGate and not job.rectangleEdge and not job.circleCheck
            and job.halfWidth and job.halfHeight and math.min(job.halfWidth,job.halfHeight)>=3
            and math.max(job.halfWidth,job.halfHeight)<=24 and math.abs(job.halfWidth-job.halfHeight)<=2})
    local matched,unknown,matchedCount=result.matched,result.unknown,result.count
    if job.locationOnly then
        if unknown then
            job.group.locationRetryAt = GetTime() + 1
        else
            local checks = job.group.locationChecks or {}
            local result = {x = job.x, y = job.y, matched = matched, single = matchedCount == 1, time = GetTime()}
            local replaced = false
            for i, checked in ipairs(checks) do
                if checked.x == job.x and checked.y == job.y then checks[i], replaced = result, true; break end
            end
            if not replaced then checks[#checks + 1] = result end
            job.group.locationChecks, job.group.locationCandidate = checks, nil
            job.group.samples = job.group.samples + 1
            scan.nextPublish = 0
        end
        scan.centerJob = nil
        return true
    end
    if job.rectangleGate then
        local gate = job.rectangleGate
        if unknown then scan.centerJob = nil
        elseif job.rectangleStep % 2 == 1 then
            gate.insideCount = matchedCount
            scan.centerJob = rectangleGate(gate, ctx, job.rectangleStep + 1)
        elseif gate.insideCount > matchedCount then
            scan.centerJob = rectangleSeed(gate.original, gate.fallback, ctx, 1)
        elseif job.rectangleStep < 4 then
            scan.centerJob = rectangleGate(gate, ctx, job.rectangleStep + 1)
        else scan.centerJob = gate.fallback end
        return true
    end
    if job.rectangleEdge then
        local box = job.rectangleEdge
        if unknown then scan.centerJob = nil
        elseif job.rectangleStep % 2 == 1 then
            box.edgeCount = matchedCount
            scan.centerJob = rectangleEdge(box, ctx, job.rectangleStep + 1)
        elseif box.edgeCount <= matchedCount then
            -- Every sampled straight edge must lose at least one resource
            -- title. A round lobe or a fabricated union midpoint fails here.
            scan.centerJob = box.rectangle.fallback
        elseif job.rectangleStep < 24 then
            scan.centerJob = rectangleEdge(box, ctx, job.rectangleStep + 1)
        else
            box.rectangleVerified, box.profileDone, box.rectangle = true, true, nil
            scan.centerJob = box -- one more fresh center read before publishing
        end
        return true
    end
    if job.rectangle and (unknown or not job.confirmed and matchedCount ~= 1) and job.axis ~= 3 then
        scan.centerJob = unknown and nil or nextRectangle(job, ctx)
        return true
    end
    if job.circleCheck then
        local profile = job.circleCheck
        if unknown then scan.centerJob = nil; return true end
        if matched and not profile.circleOutside then
            profile.circleOutside = true
        elseif not matched and profile.circleOutside then
            -- Check a fourth edge point independently: just inside must hit,
            -- just outside must miss. Then confirm the fitted center itself.
            local fit = profile.circleFits[profile.circleIndex]
            scan.centerJob = {group = job.group, x = fit.x, y = fit.y, axis = 3,
                cos = ctx.cos, sin = ctx.sin, profileDone = true, circleVerified = true,
                halfWidth = fit.radius, halfHeight = fit.radius, profileRadius = fit.radius, moving = profile.moving}
            return true
        else
            profile.circleOutside = false
            if profile.circleSide == 1 then profile.circleSide = 2
            else profile.circleSide, profile.circleIndex = 1, profile.circleIndex + 1 end
        end
        scan.centerJob = circleCheck(profile, ctx) or profileResult(profile, profile.circleResult, ctx, true)
        return true
    end
    if job.shapeCheck then
        local original = job.shapeCheck
        if unknown then scan.centerJob = nil
        elseif matched ~= (job.shapeStep % 2 == 1) then
            scan.centerJob = centerProfile(original, ctx, original.x, original.y)
        elseif job.shapeStep < 8 then
            scan.centerJob = shapeCheck(original, ctx, job.shapeStep + 1)
        else
            original.shapeChecked = true
            scan.centerJob = original
        end
        return true
    end
    if unknown or (not job.confirmed and not matched) then
        if not unknown and not matched and not job.confirmed and job.group.fastLocation and not job.profile then
            rejectFastLocation(job.group)
        end
        if job.profile and not unknown then
            scan.centerJob = profileResult(job.profile, {offset = job.profileOffset, half = 0, angle = job.profile.angle}, ctx)
        elseif not unknown and job.axis == 3 and not job.profileDone then
            -- Crossing two neighboring hitboxes can put the axis midpoint
            -- in empty space. Restart from the original observed hit.
            scan.centerJob = centerProfile(job, ctx, job.group.x, job.group.y)
        else
            scan.deferReason=job.profile and "profile cross-section not positive" or "seed/cross-section not positive"
            scan.centerJob = nil
        end
        return true
    end
    if job.axis == 3 then
        if job.rectangle then
            if math.abs(job.halfWidth - job.halfHeight) > 0.5
                and math.min(job.halfWidth, job.halfHeight) >= 2
                and math.min(job.halfWidth, job.halfHeight) <= 24
                and math.max(job.halfWidth, job.halfHeight) <= 48 then
                -- A narrow overlap can fall between the two-pixel ray steps,
                -- hiding its title-count increase. The outer union edges and
                -- shorter cut suggest two squares; neither is evidence until
                -- every edge independently loses a title and its center hits.
                local radius = math.min(job.halfWidth, job.halfHeight)
                local shift = math.abs(job.halfWidth - job.halfHeight)
                    / (ctx.width * ctx.scale / 2) * ctx.radius
                local horizontal = job.halfWidth > job.halfHeight
                local candidates = {}
                for _, sign in ipairs({-1, 1}) do
                    candidates[#candidates + 1] = {group = job.group, axis = 3,
                        x = job.x + sign * shift * (horizontal and ctx.cos or -ctx.sin) / ctx.w,
                        y = job.y - sign * shift * (horizontal and ctx.sin or ctx.cos) / ctx.h,
                        cos = ctx.cos, sin = ctx.sin, moving = job.moving,
                        halfWidth = radius, halfHeight = radius}
                end
                if distance(candidates[2], job.group, ctx) < distance(candidates[1], job.group, ctx) then
                    candidates[1], candidates[2] = candidates[2], candidates[1]
                end
                candidates[2].rectangle = {fallback = job.rectangle.fallback}
                candidates[1].rectangle = {fallback = candidates[2]}
                scan.centerJob = candidates[1]
            elseif math.abs(job.halfWidth - job.halfHeight) > 0.5
                or math.min(job.halfWidth, job.halfHeight) < 2 or math.max(job.halfWidth, job.halfHeight) > 24 then
                scan.centerJob = job.rectangle.fallback
            else
                scan.centerJob = rectangleEdge(job, ctx, 1)
            end
            return true
        end
        local saved = job.group.fastLocation
        local precision = 0.75 / (ctx.width * ctx.scale / 2) * ctx.radius
        if job.profileDone and saved and not job.trustedCenter and distance(job, saved, ctx) > precision^2 then
            -- Overlapping lobes can still suggest a middle point. A trusted
            -- historical center wins over that disagreement, but check it live
            -- again before completing the background job. This is reuse of
            -- existing provenance, never a new center measurement.
            scan.centerJob = {group = job.group, x = saved.x, y = saved.y, axis = 3,
                cos = ctx.cos, sin = ctx.sin, profileDone = true, trustedCenter = saved,
                halfWidth = job.halfWidth, halfHeight = job.halfHeight, profileRadius = job.profileRadius}
            return true
        end
        if job.profileDone and not job.rectangleVerified and matchedCount ~= 1 then
            scan.deferReason='profile centre not unique; count='..tostring(matchedCount)
            if job.trustedCenter then
                rejectFastLocation(job.group)
            end
            scan.centerJob = nil
            return true
        end
        -- Opposite-edge midpoints are only candidates. Confirm the final
        -- two-dimensional point itself before moving or saving the marker.
        local needsProfile = matchedCount > 1 or math.abs(job.halfWidth - job.halfHeight) > 2
            or job.halfWidth > job.halfHeight + 0.5
        local hitLimit = (math.min(job.halfWidth, job.halfHeight) + 2) / (ctx.width * ctx.scale / 2) * ctx.radius
        -- Coarse hits from a disconnected same-resource dot are discovery
        -- seeds. They do not make this independently checked center ambiguous.
        if not needsProfile then
            for _, node in ipairs(nodes) do
                if node ~= job.group and node.centered and node.id == job.group.id and node.map == ctx.map then
                    local separation = distance(node, job, ctx)
                    local precise = math.max(3, node.uncertainty + 2 / (ctx.width * ctx.scale / 2) * ctx.radius)
                    local observedRadius = node.hitRadius and math.max(0, node.hitRadius - node.uncertainty) or hitLimit
                    local candidateRadius = math.min(job.halfWidth, job.halfHeight)
                        / (ctx.width * ctx.scale / 2) * ctx.radius
                    if separation > precise^2 and separation < (observedRadius + candidateRadius)^2 then
                        needsProfile = true
                        break
                    end
                end
            end
        end
        if not job.profileDone and needsProfile then
            scan.centerJob = centerProfile(job, ctx, job.x, job.y)
            return true
        end
        if not job.profileDone and not job.shapeChecked and math.max(job.halfWidth, job.halfHeight) > 11 then
            -- A union of two overlapping hitboxes can look round in the two
            -- axis cuts. Its diagonal edges must agree before accepting it.
            scan.centerJob = shapeCheck(job, ctx, 1)
            return true
        end
        local group = job.group
        group.x, group.y, group.centered = job.x, job.y, true
        group.fastLocation = nil
        group.seedLocation = nil
        group.measuredCenter = not job.trustedCenter and {x = job.x, y = job.y} or nil
        group.trustedCenter = job.trustedCenter
        group.uncertainty = 2 / (ctx.width * ctx.scale / 2) * ctx.radius
        group.centerMoving = job.moving == true
        group.hitRadius = (job.profileRadius or math.max(job.halfWidth, job.halfHeight))
            / (ctx.width * ctx.scale / 2) * ctx.radius + group.uncertainty
        group.hitbox = nil
        if not job.trustedCenter and (job.circleVerified or job.rectangleVerified or not job.profileDone) then
            -- A reused saved center or an older profile's union width does
            -- not establish a safe interior to exclude from discovery.
            local interior = job.circleVerified and job.profileRadius or math.min(job.halfWidth, job.halfHeight)
            group.hitbox = {radius = interior / (ctx.width * ctx.scale / 2) * ctx.radius, width = ctx.width,
                scale = ctx.scale, viewRadius = ctx.radius, iconScale = ctx.iconScale}
        end
        group.samples = group.samples + 1
        scan.nextPublish = 0
        scan.centerJob = nil
        return true
    end
    if not job.confirmed then
        job.confirmed, job.boundaryCount, job.seedCount = true, matchedCount, matchedCount
        return true
    end
    local inside = matched
    if job.rectangle then
        inside = matchedCount >= job.boundaryCount
        if inside and not job.outside then job.boundaryCount = matchedCount end
    end
    if inside then job.inside = job.reach else job.outside = job.reach end
    if not job.outside then
        if job.reach >= 48 then
            scan.deferReason=string.format('no outer edge within 48px; axis=%s; count=%s; halfWidth=%s; halfHeight=%s',
                tostring(job.axis),tostring(matchedCount),tostring(job.halfWidth),tostring(job.halfHeight))
            scan.centerJob = nil; return true
        end
        -- Walk the connected hitbox in short steps. Exponential jumps can
        -- leap over an empty gap and mistake the next same-name dot for an edge.
        job.reach = math.min(48, job.reach + 2)
    elseif job.outside - job.inside > (job.profile and 0.0078125 or job.rectangle and 0.125 or 0.75) then
        job.reach = (job.inside + job.outside) / 2
    else
        -- Use confirmed edges to form a candidate, then verify it separately.
        local edge = job.inside
        if job.sign == -1 then
            job.negative, job.sign = edge, 1
            job.boundaryCount = job.seedCount
            job.inside, job.outside, job.reach = 0, nil, 2
        else
            local shift = (edge - job.negative) / 2 / ctx.scale / (ctx.width / 2) * ctx.radius
            if job.profile then
                local axisCos, axisSin = job.axisCos or ctx.cos, job.axisSin or ctx.sin
                if job.axis == 1 then
                    job.x, job.y = job.x + shift * axisCos / ctx.w, job.y - shift * axisSin / ctx.h
                else
                    job.x, job.y = job.x - shift * axisSin / ctx.w, job.y - shift * axisCos / ctx.h
                end
                scan.centerJob = profileResult(job.profile,
                    {offset = job.profileOffset, half = (edge + job.negative) / 2,
                        x = job.x, y = job.y, angle = job.profile.angle}, ctx)
            elseif job.axis == 1 then
                job.halfWidth = (edge + job.negative) / 2
                job.x, job.y = job.x + shift * ctx.cos / ctx.w, job.y - shift * ctx.sin / ctx.h
                job.axis, job.sign, job.confirmed = 2, -1, false
                job.inside, job.outside, job.reach = 0, nil, 2
            else
                job.x, job.y = job.x - shift * ctx.sin / ctx.w, job.y - shift * ctx.cos / ctx.h
                job.halfHeight = (edge + job.negative) / 2
                job.axis, job.confirmed = 3, false
            end
        end
    end
    return true
end
    local thread=coroutine.create(function()
        for _=1,4096 do
            if group.centered then return {done=true,group=group}end
            if not refineCenter(currentContext) then break end
        end
        return {done=true,reason=scan.deferReason or 'legacy centre produced no confirmed point'}
    end)
    return function(c,result)
        -- Preserve the old measured axes in world space. Only the transport
        -- rotates each requested point onto the native map's current view.
        currentContext=copyContext(c)
        currentContext.cos,currentContext.sin=axisCos,axisSin
        local ok,value=coroutine.resume(thread,result)
        if not ok then return {done=true,reason='legacy centre error: '..tostring(value)}end
        return value or {done=true,reason='legacy centre yielded no probe'}
    end
end
function trial:ReturnToDiscovery()
    if self.discoverySize then self.size=self.discoverySize end
    NS.CursorSweepReady=false
end
function trial:ParkUnreadableRefinement(job,now)
    self.refinementQueue=self.refinementQueue or {}
    local entry
    for _,candidate in ipairs(self.refinementQueue)do
        if candidate.node==job.node then entry=candidate;break end
    end
    if not entry then
        if #self.refinementQueue>=128 then self:AbortRefinement('unreadable refinement queue full');return end
        entry={node=job.node,seed=job.node.manualLastHit or job.nominal}
        self.refinementQueue[#self.refinementQueue+1]=entry
    end
    job.unknownWait=nil;job.answer=nil;job.textWait=nil
    job.publicationSince=nil;job.publicationCount=0;job.publicationLast=nil
    entry.work,entry.parkedAt,entry.after=job,now,(self.confirmedProbes or 0)+3
    job.node.cursorRefineRetry=now+2
    self.refinement=nil;self.refinementDiscovery=nil;self.refinementDiscoveryRemaining=nil
    self.refineSerial=nil;self.placed=nil;self.captureAt=nil;self.knownTarget=nil
    self:ReturnToDiscovery()
    self.refineStatus='unreadable occupancy; preserving '..tostring(job.reads)..' probes; discovering other nodes'
    if self.Trace then self:Trace('refinement parked',self.refineStatus..'; reason='..tostring(NS.AnonymousReadExclusion or 'unreadable native tooltip')) end
end
function trial:SuspendRefinement(reason,now)
    local job=self.refinement or self.refinePending
    if not job then return end
    if not self.refinePausedAt then self.refinePausedAt=now end
    self.refinePauseReason=reason
    job.answer=nil;job.textWait=nil;job.publicationSince=nil;job.publicationCount=0;job.publicationLast=nil
    self.refineStatus='paused: '..reason..'; preserving '..tostring(job.reads or 0)..' measured probes'
end
function trial:ResumeRefinement(now)
    if not self.refinePausedAt then return end
    local job=self.refinement or self.refinePending
    if job then
        job.start=job.start+(now-self.refinePausedAt)
        job.answer=nil;job.textWait=nil;job.publicationSince=nil;job.publicationCount=0;job.publicationLast=nil
        self.refineStatus='resuming centering; measured probes='..tostring(job.reads or 0)
    end
    self.refinePausedAt=nil;self.refinePauseReason=nil
    self.placed=nil;self.refineSerial=nil;self.captureAt=nil;self.nextDiscovery=nil
    NS.CursorSweepReady=false
end
function trial:AbortRefinement(reason)
    local previous=self.refinement or self.refinePending
    if previous then
        self.lastRefinementStop={at=GetTime(),reason=reason or 'unspecified',reads=previous.reads or 0,
            anonymous=previous.node.anonymous==true,kind=previous.node.kind}
    end
    self.refinePausedAt=nil;self.refinePauseReason=nil
    if self.refinePending then self.refinePending.node.cursorRefineRetry=GetTime()+5 end
    self.refinePending=nil;self.refinementDiscovery=nil
    if self.refinement then self.refinement.node.cursorRefineRetry=GetTime()+5 end
    self.refinement=nil;self.refineSerial=nil
    self:ReturnToDiscovery()
    self.refineStatus=reason or 'legacy centering waiting'
    if self.Trace and previous then self:Trace('refinement stopped',tostring(previous.node.name or previous.node.id)..'; '..tostring(reason)..'; probes='..tostring(previous.reads or 0)) end
    if previous then self.refineStatus=self.refineStatus..' ['..tostring(previous.node.name or previous.node.id)..'; '..tostring(previous.reads or 0)..' probes; '..tostring(previous.lastSample or 'no sample')..']' end
end
function trial:TrackRefinement(kind,now,parkOnly)
    self.pausedRefinements=self.pausedRefinements or {}
    local job=self.refinement or self.refinePending
    if job and (parkOnly or job.node.kind~=kind and not (NS.IsCursorSweepKindTracked and NS:IsCursorSweepKindTracked(job.node.kind))) then
        if self.refinePausedAt then job.start=job.start+now-self.refinePausedAt end
        job.answer=nil;job.textWait=nil;job.publicationSince=nil;job.publicationCount=0;job.publicationLast=nil
        if self.Trace then self:Trace('refinement parked',tostring(job.node.name or job.node.id)..'; kind='..tostring(job.node.kind)..'; probes='..tostring(job.reads or 0)) end
        self.pausedRefinements[job.node.kind]={refinement=self.refinement,pending=self.refinePending,size=self.size,at=now}
        self.refinement=nil;self.refinePending=nil;self.refinementDiscovery=nil
        self.refinePausedAt=nil;self.refinePauseReason=nil
        self.refineSerial=nil;self:ReturnToDiscovery()
        self.refineStatus='centering saved for '..tostring(job.node.kind)..'; discovering '..tostring(kind)
    end
    if not parkOnly and not self.validationBatchActive and not self.refinement and not self.refinePending then
        local resumeKind=kind
        if not self.pausedRefinements[resumeKind] and self.pausedRefinements.treasure
            and NS.IsCursorSweepKindTracked and NS:IsCursorSweepKindTracked('treasure') then resumeKind='treasure' end
        local saved=self.pausedRefinements[resumeKind]
        if saved then
            self.pausedRefinements[resumeKind]=nil
            local resume=saved.refinement or saved.pending
            if now-saved.at<=30 and present(resume.node) and not resume.node.manualRefined then
                self.refinement,self.refinePending=saved.refinement,saved.pending
                self.size=saved.size
                resume.start=resume.start+now-saved.at
                resume.answer=nil;resume.textWait=nil;resume.publicationSince=nil;resume.publicationCount=0;resume.publicationLast=nil
                self.refineSerial=nil;self.placed=nil;self.captureAt=nil;self.nextDiscovery=nil
                self.refinePausedAt=nil;self.refinePauseReason=nil
                NS.CursorSweepReady=false
                if self.Trace then self:Trace('refinement resumed',tostring(resume.node.name or resume.node.id)..string.format('; parked=%.1fs; probes=%d',now-saved.at,resume.reads or 0)) end
                self.resumedRefinements=(self.resumedRefinements or 0)+1
                self.refineStatus='resuming '..tostring(resumeKind)..' centering; measured probes='..tostring(resume.reads or 0)
            elseif self.Trace then
                local why=not present(resume.node) and 'observation no longer in cache'
                    or resume.node.manualRefined and 'already refined' or 'parked geometry exceeded30second limit'
                self:Trace('refinement discarded',tostring(resume.node.name or resume.node.id)..'; '..why..string.format('; parked=%.1fs; probes=%d',now-saved.at,resume.reads or 0))
            end
        end
    end
end
function trial:RefinementDiagnosticLines(now)
    local lines={}
    local function append(label,saved)
        local job=saved and (saved.refinement or saved.pending)
        if not job then return end
        local node=job.node
        lines[#lines+1]=string.format('%s %s:%s; present=%s; probes=%d; phase=%s; last count=%s; positive age=%.1fs; ttl=%ds; progress age=%.1fs%s',
            label,tostring(node.kind),tostring(node.name or node.id),tostring(present(node)==true),job.reads or 0,
            tostring(job.phase or 'reacquisition'),tostring(job.lastNativeCount),math.max(0,now-(node.seen or now)),
            (NS.GetGatheringObservationTTL and NS:GetGatheringObservationTTL(node) or node.observationTTL or 60),math.max(0,now-(job.lastProgressAt or job.start or now)),saved.at and string.format('; parked=%.1fs',now-saved.at) or '')
    end
    append('active',{refinement=self.refinement,pending=self.refinePending})
    for _,kind in ipairs({'herb','ore','treasure'})do append('saved',self.pausedRefinements and self.pausedRefinements[kind])end
    return lines
end
function trial:BeginLegacyRefinement(node,ctx,spot,now)
    local run=engine(node,ctx,spot)
    local point=run(ctx)
    if point.done then self:AbortRefinement(point.reason);node.cursorRefineRetry=now+5;return end
    self.refinement={node=node,run=run,nominal=point,start=now,serial=1,
        ctx=copyContext(ctx),maxDrift=0,reads=0,lastProgressAt=now,phase=point.phase,axis=point.axis}
    self.refineStatus='1.1.2 opposite-edge / profile centering'
end
function trial:BeginSavedHintRefinement(node,ctx,spot,hint,now)
    local radius=hint.radiusPixels*ctx.iconScale
    local directions={{1,0},{-1,0},{0,1},{0,-1}}
    local steps={}
    for _,d in ipairs(directions)do
        for _,inside in ipairs({true,false})do
            local reach=radius+(inside and -1 or 1)*ctx.iconScale
            local point=offset(ctx,hint,d[1]*reach,d[2]*reach)
            point.phase='saved centre boundary check';point.axis=inside and 'inside' or 'outside'
            steps[#steps+1]={point=point,inside=inside}
        end
    end
    local at=1
    local function run(c,result)
        local expected=steps[at].inside and 1 or 0
        if result.unknown or result.foreign or result.count~=expected then
            return {done=true,fallback=true,reason='saved centre boundary disagreed with fresh native reads'}
        end
        at=at+1
        if steps[at]then return steps[at].point end
        local p=pixel(c)
        return {done=true,group={x=hint.x,y=hint.y,uncertainty=math.max(hint.uncertainty,2*p),
            hitRadius=(radius+2*c.iconScale)*p,fromSavedHint=true,
            hitbox={radius=radius*p,width=c.width,scale=c.scale,viewRadius=c.radius,iconScale=c.iconScale}}}
    end
    node.cursorHintTried=true
    self.refinement={node=node,run=run,nominal=steps[1].point,start=now,serial=1,
        ctx=copyContext(ctx),maxDrift=0,reads=0,lastProgressAt=now,
        hintSeed={x=spot.x,y=spot.y},phase='saved centre boundary check',axis='inside'}
    self.refineStatus='checking saved measured centre before reuse'
    if self.Trace then self:Trace('saved hint',tostring(node.name or node.id)..'; checking eight inside/outside boundaries')end
end
-- Live discoveries render immediately. Queue costly geometry behind discovery;
-- queued coordinates are only actual positive hover samples, never history dots.
function trial:ConsiderRefinement(node,ctx,spot,now)
    if self.workflow and not self.workflow:Allows('refinement') then return end
    if not self.saved then return self:StartNodeRefinement(node,ctx,spot,now) end
    if node.manualRefined then return end
    self.refinementQueue=self.refinementQueue or {}
    for _,entry in ipairs(self.refinementQueue)do
        if entry.node==node then entry.seed={x=spot.x,y=spot.y};return end
    end
    if #self.refinementQueue>=128 then return end
    self.refinementQueue[#self.refinementQueue+1]={node=node,seed={x=spot.x,y=spot.y},after=(self.confirmedProbes or 0)+12}
end
-- Real observations retained through a HUD mode change also need geometry.
-- Only their actual last-positive samples can seed this queue; no history dots.
function trial:QueueRetainedObservations(now)
    local c=NS:GetGatheringNodeContext()
    if not c then return end
    for _,node in ipairs(NS.GatheringNodeCache or {})do
        local hit=node.manualLastHit
        if hit and node.manualProvisional and not node.manualRefined and node.map==c.map
            and node.seen and now-node.seen>=0 and now-node.seen<=(NS.GetGatheringObservationTTL and NS:GetGatheringObservationTTL(node) or node.observationTTL or 60)
            and NS.IsCursorSweepKindTracked and NS:IsCursorSweepKindTracked(node.kind) then
            self:ConsiderRefinement(node,c,hit,now)
        end
    end
end
-- Approach uses observed player travel, not camera facing or guessed paths.
function trial:UpdateRefinementApproach(c,now)
    local old=self.approachSample
    if not old or old.map~=c.map or now-old.at>.5 or old.w~=c.w or old.h~=c.h then
        self.approachSample={map=c.map,x=c.x,y=c.y,w=c.w,h=c.h,at=now};self.approachMotion=nil;return
    end
    if now-old.at<.1 then return end
    local dx,dy=(c.x-old.x)*c.w,(c.y-old.y)*c.h
    local length=math.sqrt(dx*dx+dy*dy)
    self.approachMotion=length>=.1 and length<=20 and {map=c.map,dx=dx,dy=dy,length=length,dt=now-old.at,at=now} or nil
    self.approachSample={map=c.map,x=c.x,y=c.y,w=c.w,h=c.h,at=now}
end
function trial:RefinementApproachScore(node,c,now)
    local motion=self.approachMotion
    if not motion or motion.map~=c.map or node.map~=c.map or now-motion.at>.3 then return end
    local x,y=(node.x-c.x)*c.w,(node.y-c.y)*c.h
    local d=x*x+y*y
    if d<1 or d>math.min(100,c.radius*.9)^2 then return end
    local dot=x*motion.dx+y*motion.dy
    if dot<=0 or dot<math.sqrt(d)*motion.length*.7072 then return end
    return d*motion.dt/dot -- estimated seconds until reaching the observation
end
function trial:PumpRefinementQueue(now)
    if self.refinePending or self.validationBatchActive or self.nodeValidation then return end
    local active=self.refinement
    if active and (not active.background or active.pendingPublication or self.size~=self.discoverySize) then return end
    local c=NS:GetGatheringNodeContext()
    if not c then return end
    self:UpdateRefinementApproach(c,now)
    local queue=self.refinementQueue or {}
    for i=#queue,1,-1 do
        local entry=queue[i];local node=entry.node
        if not present(node) or node.manualRefined or now-(node.seen or now)>(NS.GetGatheringObservationTTL and NS:GetGatheringObservationTTL(node) or node.observationTTL or 60) then table.remove(queue,i) end
    end
    local chosen,priority,bestApproach,bestTooHard
    for i,entry in ipairs(queue)do
        local node=entry.node
        local approach=self:RefinementApproachScore(node,c,now)
        -- A live observation on the player's approach gets its turn before
        -- the ordinary twelve-probe discovery allowance has elapsed.
        if node.map==c.map and NS.IsCursorSweepKindTracked and NS:IsCursorSweepKindTracked(node.kind)
            and (approach or (self.confirmedProbes or 0)>=entry.after) and now>=(node.cursorRefineRetry or 0) then
            local x,y=relative(c,c,entry.seed)
            if x*x+y*y<(self.discoverySize/2-4)^2 then
                local ambiguous=NS.IsCursorObservationAmbiguous and NS:IsCursorObservationAmbiguous(node,c,now)
                local tooHard=NS.GetGatheringNodeDifficulty and NS:GetGatheringNodeDifficulty(node)=='red' or false
                if not chosen or bestTooHard and not tooHard
                    or tooHard==bestTooHard and (approach and (not bestApproach or approach<bestApproach)
                        or not approach and not bestApproach and ambiguous and not priority) then
                    chosen,priority,bestApproach,bestTooHard=i,ambiguous,approach,tooHard
                end
            end
        end
    end
    if active then
        local score=self:RefinementApproachScore(active.node,c,now)
        local activeTooHard=NS.GetGatheringNodeDifficulty and NS:GetGatheringNodeDifficulty(active.node)=='red' or false
        if not chosen or not activeTooHard and bestTooHard
            or activeTooHard==bestTooHard and (not bestApproach or score and bestApproach>=score*.65)
            or now<(self.nextApproachPreempt or 0) then return end
        -- Preserve the coroutine and measured edges; never discard work just
        -- because another visible node is now being approached.
        local entry
        for _,candidate in ipairs(queue)do if candidate.node==active.node then entry=candidate;break end end
        if not entry then
            if #queue>=128 then return end
            entry={node=active.node,seed=active.node.manualLastHit or active.nominal,after=0};queue[#queue+1]=entry
        end
        active.answer=nil;active.textWait=nil;active.publicationSince=nil;active.publicationCount=0;active.publicationLast=nil
        entry.work,entry.parkedAt=active,now
        if self.Trace then self:Trace('refinement approach priority',tostring(active.node.name or active.node.id)..' parked for '..tostring(queue[chosen].node.name or queue[chosen].node.id)) end
        self.refinement=nil;self.refinementDiscovery=nil;self.refinementDiscoveryRemaining=nil
        self.refineSerial=nil;self.placed=nil;self.captureAt=nil;self.knownTarget=nil
        self.nextApproachPreempt=now+1
    end
    if chosen then
        local entry=table.remove(queue,chosen)
        if entry.work and now-entry.parkedAt<=30 and not changedView(c,entry.work.ctx) then
            local work=entry.work;work.start=work.start+now-entry.parkedAt
            work.answer=nil;work.textWait=nil;work.publicationSince=nil;work.publicationCount=0;work.publicationLast=nil
            self.refinement=work
        else self:StartNodeRefinement(entry.node,c,entry.seed,now) end
        if self.refinement then self.refinement.background=true;self.refinement.nextDiscoveryAt=0 end
        self.refineSerial=nil;self.placed=nil;self.captureAt=nil;self.nextDiscovery=nil;self.knownTarget=nil
        NS.CursorSweepReady=false
        self.refinementPriority=bestApproach and 'approaching '..tostring(entry.node.name or entry.node.id)
            or priority and 'ambiguous extra picture' or 'ordinary queue'
    end
end
function trial:StartNodeRefinement(node,ctx,spot,now)
    if self.workflow and not self.workflow:Allows('refinement') then return end
    if self.Trace then self:Trace('refinement request',tostring(node.name or node.id)..'; active job='..tostring(self.refinement~=nil or self.refinePending~=nil)..'; refined='..tostring(node.manualRefined==true)..'; retry wait='..string.format('%.1fs',math.max(0,(node.cursorRefineRetry or 0)-now))) end
    if self.validationBatchActive then return end
    if NS.IsCursorSweepKindTracked and not NS:IsCursorSweepKindTracked(node.kind) then return end
    if self.refinement or self.refinePending or node.manualRefined or now<(node.cursorRefineRetry or 0)then return end
    if not node.cursorHintTried and NS.FindRefinedNodeHint then
        local hint,why=NS:FindRefinedNodeHint(node,ctx,spot)
        if hint then self:BeginSavedHintRefinement(node,ctx,spot,hint,now);return end
        if why and self.Trace then self:Trace('saved hint deferred',tostring(node.name or node.id)..'; '..why)end
    end
    if self.saved and self.refinementSize and self.refinementSize~=self.discoverySize then
        -- A positive edge point on the small map can fall outside the smaller
        -- world hit area after enlargement. Reacquire the resource locally first.
        self.refinePending={node=node,seed={x=spot.x,y=spot.y},ctx=copyContext(ctx),start=now,
            radius=11*ctx.iconScale*pixel(ctx),index=1}
        self.size=self.refinementSize
        NS.CursorSweepReady=false
        self.refineStatus='enlarging capture map; reacquiring observed resource'
        return
    end
    self:BeginLegacyRefinement(node,ctx,spot,now)
end
function trial:PendingRefinementPoint(ctx,now)
    local pending=self.refinePending
    if not pending then return end
    if not ctx or not present(pending.node) or ctx.map~=pending.ctx.map or now-pending.start>45 then
        self:AbortRefinement('large-map reacquisition changed/expired');return
    end
    if math.abs(ctx.width*ctx.scale-self.refinementSize)>.5 then return end
    if not pending.points then
        pending.largeContext=copyContext(ctx)
        pending.points={{x=pending.seed.x,y=pending.seed.y}}
        local reach=math.min(48,pending.radius/pixel(ctx))
        for ring=4,math.ceil(reach/4)*4,4 do
            for direction=0,7 do
                local angle=direction*math.pi/4
                pending.points[#pending.points+1]=offset(ctx,pending.seed,ring*math.cos(angle),ring*math.sin(angle))
            end
        end
    elseif changedView(ctx,pending.largeContext) then self:AbortRefinement('large-map reacquisition reset: '..changedView(ctx,pending.largeContext));return end
    while pending.points[pending.index] do
        local target=pending.points[pending.index]
        local x,y=relative(ctx,ctx,target)
        if x*x+y*y<(self.size/2-1)^2 then
            pending.target=target;return {x,y},-pending.index
        end
        pending.index=pending.index+1
    end
    self:AbortRefinement('resource not reacquired on enlarged map')
end
function trial:PendingRefinementRead(ctx,spot,hits,reliable,now)
    local pending=self.refinePending
    if not pending.target or not pending.largeContext then return true end
    if not reliable or changedView(ctx,pending.largeContext) then self:AbortRefinement('unknown/changed enlarged-map sample');return true end
    local dx,dy=relative(ctx,pending.target,spot)
    if dx*dx+dy*dy>12^2 then return true end
    local hit=false
    for _,entry in ipairs(hits)do
        if entry.resource.id==pending.node.id and entry.resource.kind==pending.node.kind then hit=true end
    end
    local answer=pending.answer
    if not answer or answer.index~=pending.index or answer.hit~=hit or now-answer.at>.15 then
        pending.answer={index=pending.index,hit=hit,at=now};return true
    end
    if now-answer.at<.012 then return true end
    pending.answer=nil
    if hit then
        pending.node.seen=now
        self.refinePending=nil
        self:BeginLegacyRefinement(pending.node,ctx,spot,now)
    else
        pending.index=pending.index+1
        self.refineStatus='large-map local reacquisition; probe='..pending.index
        NS.CursorSweepReady=false
    end
    return true
end
function trial:RefinementPoint(now)
    if self.refinePending then return self:PendingRefinementPoint(NS:GetGatheringNodeContext(),now) end
    local j=self.refinement
    if not j then return end
    local ctx=NS:GetGatheringNodeContext()
    if not ctx or changedView(ctx,j.ctx) then self:AbortRefinement('legacy reset: '..changedView(ctx,j.ctx));return end
    if not present(j.node) then self:AbortRefinement('legacy target removed');return end
    if now-j.start>180 or j.reads>1000 then self:AbortRefinement('legacy centre budget exhausted');return end
    j.target=offset(ctx,j.nominal,-(j.biasX or 0),-(j.biasY or 0))
    local x,y=relative(ctx,ctx,j.target)
    if x*x+y*y>(self.size/2-1)^2 then self:AbortRefinement('legacy probe clipped by map edge');return end
    return {x,y},j.serial
end
local function publishConfirmedCentre(self,j,group,ctx,spot,now)
        local uncertainty=math.max(group.uncertainty or 0,pixel(ctx)*(2+j.maxDrift))
        if j.node.uncertainty and j.node.uncertainty<=uncertainty then self:AbortRefinement('existing position more precise');return end
        -- Preserve original history and trust: only the live picture is corrected.
        local node=j.node
        node.x,node.y,node.uncertainty=group.x,group.y,uncertainty
        node.seen=now
        node.manualLastHit={x=spot.x,y=spot.y,pixel=pixel(ctx),iconScale=ctx.iconScale}
        node.fastLocation,node.savedAnchor,node.locationRecord,node.locationSource=nil,nil,nil,nil
        node.centered,node.measuredCenter,node.importedAnchor=nil,nil,nil
        node.manualProvisional,node.manualRefined,node.cursorSweepObservation=true,true,true
        node.manualHoverFootprint=nil
        node.manualPositiveFootprint={x=group.x,y=group.y,radius=(group.hitRadius or uncertainty)/pixel(ctx)/ctx.iconScale}
        node.cursorSweepRefinementPixel=pixel(ctx)
        if self.LearnDiscoveryFootprint then self:LearnDiscoveryFootprint(group,ctx) end
        self.refined=(self.refined or 0)+1;NS:CursorSweepRefined(node,ctx)
        if group.fromSavedHint then self.savedHintsReused=(self.savedHintsReused or 0)+1 end
        if NS.SaveRefinedNodeHint and not group.fromSavedHint then
            local ok,why=pcall(NS.SaveRefinedNodeHint,NS,node,ctx,group)
            if not ok and self.Trace then self:Trace('saved hint failed',tostring(why))end
        end
        if self.Trace then self:Trace('refined',tostring(node.name or node.id)..'; probes='..tostring(j.reads)..'; uncertainty='..string.format('%.1fyd',uncertainty)) end
        self.refineStatus='refined with 1.1.2 edge/profile centering ('..j.reads..' probes)'
        self.refinement=nil;self.refineSerial=nil;self:ReturnToDiscovery()
end
function trial:RefinementRead(ctx,spot,hits,reliable,nonempty,now)
    local trackedJob=self.refinement or self.refinePending
    if trackedJob and NS.IsCursorSweepKindTracked and not NS:IsCursorSweepKindTracked(trackedJob.node.kind) then
        if self.TrackRefinement and NS.GetCursorSweepTrackingKind then self:TrackRefinement(NS:GetCursorSweepTrackingKind(),now)
        else self:AbortRefinement('target tracking changed; measurement discarded') end
        return true
    end
    if self.refinePausedAt then return true end
    if self.refinementDiscovery then return false end
    if self.refinePending then return self:PendingRefinementRead(ctx,spot,hits,reliable,now) end
    local j=self.refinement
    if not j then return false end
    if NS.IsCursorSweepKindTracked and not NS:IsCursorSweepKindTracked(j.node.kind) then
        if self.TrackRefinement and NS.GetCursorSweepTrackingKind then self:TrackRefinement(NS:GetCursorSweepTrackingKind(),now)
        else self:AbortRefinement('target tracking changed; measurement discarded') end
        return true
    end
    if not j.target then self:AbortRefinement('legacy unknown sample');return true end
    if not reliable then
        if j.node.anonymous then
            -- Secret/group/background tooltips can briefly replace occupancy
            -- after transport. Unknown is neither an edge nor an empty vote.
            local wait=j.unknownWait
            if not wait or wait.serial~=j.serial then
                wait={serial=j.serial,since=now};j.unknownWait=wait
            end
            j.answer=nil;j.publicationSince=nil;j.publicationCount=0;j.publicationLast=nil
            if now-wait.since<.25 then
                self.refineStatus='waiting for readable native occupancy; preserving '..tostring(j.reads or 0)..' probes'
                return true
            end
            self:ParkUnreadableRefinement(j,now);return true
        end
        self:AbortRefinement('legacy unknown sample');return true
    end
    j.unknownWait=nil
    if changedView(ctx,j.ctx) then self:AbortRefinement('legacy reset: '..changedView(ctx,j.ctx));return true end
    local dx,dy=relative(ctx,j.target,spot)
    if dx*dx+dy*dy>12^2 then self.refineStatus='legacy waiting for bounded cursor travel';return true end
    local ex,ey=relative(ctx,j.nominal,spot)
    if ex*ex+ey*ey>.75^2 then
        j.biasX,j.biasY=dx,dy;j.serial=j.serial+1;j.answer=nil
        j.publicationSince=nil;j.publicationCount=0;j.publicationLast=nil
        self.refineStatus='legacy compensating physical cursor offset';return true
    end
    j.maxDrift=math.max(j.maxDrift,math.sqrt(ex*ex+ey*ey))
    if NS.ObserveCursorSweepNodeHint then
        for _,hit in ipairs(hits)do
            if hit.resource.id==j.node.id and hit.resource.kind==j.node.kind then NS:ObserveCursorSweepNodeHint(j.node,hit)end
        end
    end
    if NS.GetManualNodeHoverStatus then
        local status=NS:GetManualNodeHoverStatus();j.lastSample=status and status.tooltipDetail
    end
    -- Other resource identities are discoveries even while this target is being measured.
    local foreign=false
    for _,hit in ipairs(hits)do
        if hit.resource.id~=j.node.id or hit.resource.kind~=j.node.kind then foreign=true end
    end
    local consume=not foreign or (self.discoverySize~=nil and self.refinementSize~=nil and self.refinementSize>self.discoverySize+.5)
    local count=0
    for _,hit in ipairs(hits)do if hit.resource.id==j.node.id and hit.resource.kind==j.node.kind then count=count+(hit.tooltipCount or 1) end end
    j.lastNativeCount=count
    if count>0 then j.node.seen=now end
    -- A player/quest label can temporarily replace the node at an interior
    -- probe. Hold this exact world point briefly instead of immediately
    -- throwing away measured edges. Never turn these reads into positive
    -- evidence, and retain ordinary target-to-background edge measurements.
    if count==0 and nonempty and not foreign and (j.nominal.requiresPositive or j.pendingPublication) then
        local blocked=j.textWait
        if not blocked or blocked.serial~=j.serial then
            blocked={serial=j.serial,since=now};j.textWait=blocked
            self.interiorReadRetries=(self.interiorReadRetries or 0)+1
        end
        if now-blocked.since<.12 then
            j.answer=nil;j.publicationSince=nil;j.publicationCount=0;j.publicationLast=nil
            self.refineStatus='retrying interior node read through public background text'
            return consume
        end
    else
        if count>0 and j.textWait then self.interiorReadRecoveries=(self.interiorReadRecoveries or 0)+1 end
        j.textWait=nil
    end
    if j.pendingPublication then
        if count~=1 then
            self:AbortRefinement('measured centre is not currently a unique positive resource');return true
        end
        if j.publicationLast and now-j.publicationLast>.15 then
            j.publicationSince=nil;j.publicationCount=0
        end
        j.publicationSince=j.publicationSince or now
        j.publicationLast=now;j.publicationCount=(j.publicationCount or 0)+1
        self.refineStatus='confirming live centre; '..j.publicationCount..' fresh reads'
        if j.publicationCount>=3 and now-j.publicationSince>=.25 then
            publishConfirmedCentre(self,j,j.pendingPublication,ctx,spot,now)
        end
        return true
    end
    local answer=j.answer
    if not answer or answer.serial~=j.serial or answer.count~=count or now-answer.at>.15 then
        j.answer={serial=j.serial,count=count,at=now};return consume
    end
    if now-answer.at<.012 then return consume end
    j.answer=nil;j.reads=j.reads+1;j.lastProgressAt=now
    if j.nominal.previewCentre and count==1 and not foreign and not j.previewed
        and not j.node.manualRefined and not j.node.fastLocation and not j.node.savedAnchor then
        local nearby=false
        for _,other in ipairs(NS.GatheringNodeCache or {})do
            if other~=j.node and other.map==j.node.map and other.kind==j.node.kind and other.id==j.node.id
                and now-(other.seen or now)<=(NS.GetGatheringObservationTTL and NS:GetGatheringObservationTTL(other) or other.observationTTL or 180)
                and distance(other,spot,ctx)<=(pixel(ctx)*ctx.iconScale*24)^2 then nearby=true;break end
        end
        if not nearby then
            -- Both axes were measured and this candidate itself just gave two
            -- matching live reads. Improve the approximate picture now; full
            -- shape/profile/final-publication checks still own precision.
            j.node.x,j.node.y=spot.x,spot.y
            j.node.manualLastHit={x=spot.x,y=spot.y,pixel=pixel(ctx),iconScale=ctx.iconScale}
            j.node.cursorCentrePreview=true;j.previewed=true
            if self.Trace then self:Trace('live centre preview',tostring(j.node.name or j.node.id)..'; two measured axes; full verification pending') end
        end
    end
    local result=j.run(ctx,{matched=count>0,unknown=false,count=count,foreign=foreign})
    if result.fallback then
        if self.Trace then self:Trace('saved hint fallback',tostring(j.node.name or j.node.id)..'; '..tostring(result.reason))end
        self:BeginLegacyRefinement(j.node,ctx,j.hintSeed,now)
        return consume
    end
    if result.done then
        local group=result.group
        if not group then self:AbortRefinement(result.reason);return consume end
        j.pendingPublication=group;j.publicationSince=nil;j.publicationCount=0;j.publicationLast=nil
        j.nominal={x=group.x,y=group.y,phase='live centre confirmation',axis='centre'}
        j.phase,j.axis='live centre confirmation','centre'
        j.serial=j.serial+1;j.answer=nil
        self.refineStatus='geometry measured; waiting for fresh exact-resource centre confirmation'

    else
        j.nominal=result;j.serial=j.serial+1;j.phase=result.phase;j.axis=result.axis
        self.refineStatus='1.1.2 centering; measured probes='..j.reads
    end
    return consume
end
