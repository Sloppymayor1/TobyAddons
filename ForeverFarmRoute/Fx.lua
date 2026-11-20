-- Small particle system shared by the route bursts, grind sparks and the
-- mining celebration. Particles are textures recycled per parent frame.
local _, NS = ...

local MEDIA = "Interface\\AddOns\\ForeverFarmRoute\\Media\\"
local sin, random = math.sin, math.random

local FX = {}
NS.FX = FX

local live = {}
local spare = {}

local runner = CreateFrame("Frame")
runner:Hide()

local function Recycle(p)
    p.t:Hide()
    local s = spare[p.parent]
    if not s then
        s = {}
        spare[p.parent] = s
    end
    s[#s + 1] = p.t
end

-- p: { life, size, vx, vy, gravity, drag, grow, alpha, fadePow,
--      r, g, b, r2, g2, b2, tex, blend, sway, swayAmp, layer, sub }
function FX.Spawn(parent, x, y, p)
    local s = spare[parent]
    local t = s and s[#s]
    if t then
        s[#s] = nil
    else
        t = parent:CreateTexture(nil, p.layer or "OVERLAY", nil, p.sub or 7)
    end
    t:SetDrawLayer(p.layer or "OVERLAY", p.sub or 7)
    t:SetTexture(p.tex or (MEDIA .. "Glow"))
    t:SetBlendMode(p.blend or "ADD")
    p.t, p.parent, p.x, p.y, p.age = t, parent, x, y, 0
    p.vx, p.vy = p.vx or 0, p.vy or 0
    p.phase = random() * 6.28
    live[#live + 1] = p
    t:Show()
    runner:Show()
end

function FX.Clear(parent)
    for i = #live, 1, -1 do
        local p = live[i]
        if not parent or p.parent == parent then
            Recycle(p)
            live[i] = live[#live]
            live[#live] = nil
        end
    end
end

runner:SetScript("OnUpdate", function(self, dt)
    if dt > 0.1 then dt = 0.1 end
    local i = 1
    while i <= #live do
        local p = live[i]
        p.age = p.age + dt
        if p.age >= p.life then
            Recycle(p)
            live[i] = live[#live]
            live[#live] = nil
        else
            local drag = p.drag or 0
            if drag > 0 then
                local k = 1 - drag * dt
                if k < 0 then k = 0 end
                p.vx, p.vy = p.vx * k, p.vy * k
            end
            p.vy = p.vy + (p.gravity or 0) * dt
            p.x = p.x + p.vx * dt
            p.y = p.y + p.vy * dt
            local x = p.x
            if p.sway then x = x + sin(p.age * p.sway + p.phase) * (p.swayAmp or 4) end
            local f = p.age / p.life
            local size = p.size * (1 + (p.grow or 0) * f)
            local t = p.t
            t:SetSize(size, size)
            t:SetPoint("CENTER", p.parent, "CENTER", x, p.y)
            local r, g, b = p.r or 1, p.g or 1, p.b or 1
            if p.r2 then
                r = r + (p.r2 - r) * f
                g = g + (p.g2 - g) * f
                b = b + (p.b2 - b) * f
            end
            t:SetVertexColor(r, g, b, (p.alpha or 1) * (1 - f) ^ (p.fadePow or 1))
            i = i + 1
        end
    end
    if #live == 0 then self:Hide() end
end)

-- Mild celebratory pop: a ring and a puff of quick-fading sparks.
function FX.Burst(parent, x, y, r, g, b)
    FX.Spawn(parent, x, y, {
        tex = MEDIA .. "Ring", life = 0.45, size = 12, grow = 4, alpha = 0.9, fadePow = 1.5,
        r = r, g = g, b = b,
    })
    for _ = 1, 16 do
        local a = random() * 6.283
        local v = 45 + random() * 70
        local white = random() < 0.35
        FX.Spawn(parent, x, y, {
            life = 0.35 + random() * 0.35, size = 5 + random() * 5, grow = -0.6,
            vx = math.cos(a) * v, vy = sin(a) * v, drag = 3.5, fadePow = 1.4,
            r = white and 1 or r, g = white and 1 or g, b = white and 1 or b,
        })
    end
end

-- Grind sparks: hot, short-lived, thrown back opposite your movement.
function FX.Sparks(parent, x, y, dirX, dirY, n)
    for _ = 1, n do
        local spread = (random() - 0.5) * 1.6
        local c, s = math.cos(spread), sin(spread)
        local bx, by = -dirX * c + dirY * s, -dirX * s - dirY * c
        local v = 70 + random() * 110
        FX.Spawn(parent, x, y, {
            life = 0.18 + random() * 0.25, size = 3 + random() * 3.5, grow = -0.5,
            vx = bx * v + (random() - 0.5) * 30, vy = by * v + 40 + random() * 50,
            gravity = -420, drag = 1.5, fadePow = 1.2,
            r = 1, g = 0.95, b = 0.6, r2 = 1, g2 = 0.45, b2 = 0.05,
        })
    end
end
