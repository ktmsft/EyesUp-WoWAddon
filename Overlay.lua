-- Eyes Up - Copyright (c) 2026 KTM (abitofmoss). All Rights Reserved.
-- No redistribution or reuse of this code or assets without permission. See LICENSE.
local addonName, NS = ...

-- =============================================================================
-- Overlay.lua
-- The radar. The old way.
--
-- A dim disc near the middle of the screen with a blip for every node in range,
-- rotated so that "up" is wherever you're facing. It works, it's rather pretty,
-- and it was the whole addon once.
--
-- It's also the thing we're trying to grow out of. A radar asks you to LOOK at
-- it -- to flick your eyes down, parse a constellation of dots, and translate
-- that back into the world. Which is precisely the habit the cue exists to
-- break. So the radar is opt-in now: NS.db.mode has to name it.
--
-- Mechanically, it's been demoted too. It used to own the update loop, the
-- position lookup and the proximity scan -- it WAS the engine. Now Scan.lua does
-- all that and hands us the answer; we just draw. No timers, no distance math,
-- nothing but paint.
-- =============================================================================

local Overlay = {}
NS.Overlay = Overlay

local Data = NS.Data

local frame, disc, ring, playerDot, pointer
local blips = {}          -- texture pool
local currentAlpha = 0    -- what we're currently faded to
local shown = false       -- mirrors visibility, so we don't re-Hide 20x a second

-- Walk `value` toward `target`, but no further than `maxStep` this tick.
local function approach(value, target, maxStep)
    if value < target then return math.min(value + maxStep, target) end
    if value > target then return math.max(value - maxStep, target) end
    return value
end

-- ---------------------------------------------------------------------------
-- The blip pool
--
-- Textures are expensive to make and cheap to reuse, and this runs forever. So
-- we keep them and hand them out.
-- ---------------------------------------------------------------------------
local blipInUse = 0

local function acquireBlip()
    blipInUse = blipInUse + 1
    local b = blips[blipInUse]
    if not b then
        b = frame:CreateTexture(nil, "OVERLAY")
        b:SetTexture("Interface\\COMMON\\Indicator-Gray")
        b:SetSize(10, 10)
        blips[blipInUse] = b
    end
    b:Show()
    return b
end

-- Put away the blips this pass didn't need.
--
-- This MUST run at the end of a pass. It used to run at the start, where
-- blipInUse is still 0 -- so it dutifully hid every blip in the pool, and then
-- acquireBlip immediately showed them all again. Every tick. Forever. It was
-- doing an enormous amount of work to achieve nothing at all.
local function releaseUnusedBlips()
    for i = blipInUse + 1, #blips do
        blips[i]:Hide()
    end
    blipInUse = 0
end

-- ---------------------------------------------------------------------------
-- Building the thing
-- ---------------------------------------------------------------------------
function Overlay.Create()
    if frame then return end
    frame = CreateFrame("Frame", "EyesUpRadar", UIParent)
    frame:SetFrameStrata("MEDIUM")

    disc = frame:CreateTexture(nil, "BACKGROUND")
    disc:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    disc:SetAllPoints(frame)
    disc:SetAlpha(0.55)

    ring = frame:CreateTexture(nil, "BORDER")
    ring:SetTexture("Interface\\COMMON\\RingBorder")
    ring:SetPoint("CENTER")

    playerDot = frame:CreateTexture(nil, "ARTWORK")
    playerDot:SetTexture("Interface\\COMMON\\Indicator-Gray")
    playerDot:SetVertexColor(1, 1, 1)
    playerDot:SetSize(8, 8)
    playerDot:SetPoint("CENTER")   -- you are here, always, reassuringly

    pointer = frame:CreateTexture(nil, "OVERLAY")
    pointer:SetTexture(NS.ArrowTexture)
    pointer:SetSize(20, 20)
    pointer:SetPoint("CENTER")
    pointer:Hide()

    -- Draggable, but only when the player says so.
    frame:SetMovable(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(self)
        if not NS.db.locked then self:StartMoving() end
    end)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        -- Stored as an offset from screen center, so it survives resolution
        -- changes with its dignity intact.
        local cx, cy = UIParent:GetCenter()
        local sx, sy = self:GetCenter()
        NS.db.posX = math.floor(sx - cx + 0.5)
        NS.db.posY = math.floor(sy - cy + 0.5)
    end)

    frame:Hide()
    Overlay.ApplyLayout()
end

-- Push the saved geometry onto the frame.
function Overlay.ApplyLayout()
    if not frame then return end
    local db = NS.db
    local size = db.radarSize
    frame:SetSize(size, size)
    frame:ClearAllPoints()
    frame:SetPoint("CENTER", UIParent, "CENTER", db.posX, db.posY)
    ring:SetSize(size * 1.08, size * 1.08)
    ring:SetShown(db.showRing)
    frame:EnableMouse(not db.locked)   -- only grab the mouse when unlocked
end

-- Scan calls this when the player didn't ask for a radar (or turned the addon
-- off). Resetting the tween means we fade back in from nothing next time, rather
-- than popping into existence at whatever opacity we left off at.
function Overlay.Hide()
    if not frame or not shown then return end
    frame:Hide()
    shown = false
    currentAlpha = 0
end

-- ---------------------------------------------------------------------------
-- Where on the disc does this go?
--
-- The angle convention, which is the one genuinely tricky bit of math in the
-- addon: our Bearing() is clockwise-from-north, and GetPlayerFacing() is
-- counter-clockwise-from-north. Those two cancel. Hence `bearing + facing`, and
-- not the subtraction your instincts are shouting for.
-- ---------------------------------------------------------------------------
local function screenOffset(bearing, facing, frac)
    local relative = bearing + facing
    local r = frac * (NS.db.radarSize * 0.5)
    local x =  math.sin(relative) * r    -- +x = right
    local y =  math.cos(relative) * r    -- +y = up = straight ahead
    return x, y, relative
end

-- ---------------------------------------------------------------------------
-- Draw one scan
--
-- `result` is Scan.result -- a table that is REUSED every single tick. Read it,
-- don't keep it, don't touch it (the full contract is in Scan.lua). `elapsed` is
-- the accumulated time since our last draw, which is what keeps the fade
-- honest at any framerate.
-- ---------------------------------------------------------------------------
function Overlay.Render(result, elapsed)
    if not frame then return end
    frame:Show()
    shown = true

    local db = NS.db
    local anyInRange = false

    -- No facing, no radar. Every blip's position is a bearing rotated by which
    -- way you're looking; without that we can't place a single one of them. (The
    -- cue is more forgiving -- it can still show you the icon and drop the
    -- arrow. We can't. It's blips or nothing.)
    if result.valid and result.facing then
        local facing, range = result.facing, result.range
        anyInRange = result.count > 0

        for i = 1, result.count do          -- 1..count, never ipairs: the tail of
            local e = result.list[i]        -- the pool is last tick's leftovers
            local ox, oy = screenOffset(e.bearing, facing, e.dist / range)
            local b = acquireBlip()
            local c = NS.TypeColor(e.node.type)     -- the player's palette, not ours
            b:SetVertexColor(c[1], c[2], c[3])
            -- A vignette we can see gets full strength. A node we merely
            -- remember gets a fainter dot, because we're guessing and we ought
            -- to look like we're guessing.
            b:SetAlpha(Data.IsConfirmed(e.node) and 1 or (db.unconfirmedAlpha or 1))
            b:ClearAllPoints()
            b:SetPoint("CENTER", frame, "CENTER", ox, oy)
        end

        -- And an arrow for the closest one.
        local nearest = result.nearest
        if db.showPointer and nearest then
            local _, _, relative = screenOffset(nearest.bearing, facing, 1)
            pointer:SetRotation(-relative)          -- the art points north at 0
            pointer:SetPoint("CENTER", frame, "CENTER",
                math.sin(relative) * (db.radarSize * 0.42),
                math.cos(relative) * (db.radarSize * 0.42))
            pointer:Show()
        else
            pointer:Hide()
        end
    else
        pointer:Hide()
    end

    releaseUnusedBlips()

    -- Brighten when there's something out there; sink back to a whisper when
    -- there isn't. The radar never disappears entirely -- a faint disc at rest is
    -- part of its charm, and unlike the cue it isn't claiming anything specific.
    local target = anyInRange and db.activeAlpha or db.baseAlpha
    currentAlpha = approach(currentAlpha, target, db.fadeSpeed * elapsed)
    frame:SetAlpha(currentAlpha)
end
