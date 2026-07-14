local addonName, NS = ...

-- =============================================================================
-- Cue.lua
-- The thing on your screen. The reason the addon has this name.
--
-- You are flying. You are looking at the world -- at the ridgeline, at the
-- treeline, at the thing that might be a cave. You are NOT looking at your
-- minimap, because looking at your minimap is how you fly a thousand yards past
-- a herb you wanted and never know it.
--
-- So: a small icon, near the middle of the screen, where your eyes already are.
-- It fades in when there's something you'd want. An arrow says which way. It
-- gets bigger as you close. When you're right on top of it, the arrow gives up
-- (it would only spin) and the icon pulses instead: it's here, look down.
--
-- And when there's nothing? It vanishes. Completely. A cue that lingers is just
-- a lie about a herb you already flew past.
--
-- It shows exactly ONE node -- the nearest thing you actually want, whatever kind
-- it is. Scan picks it. "Want" means it survived your filters, which Data
-- enforced at the source, which means this file is structurally incapable of
-- lighting up for something you told it to ignore. That's not carefulness on my
-- part. That's the architecture.
--
-- Like the radar, this is only a renderer. No timers, no distance math. Scan
-- hands it an answer and it paints.
-- =============================================================================

local Cue = {}
NS.Cue = Cue

local Data = NS.Data

local frame
local slots = {}          -- one per icon we might draw; see makeSlot
local currentAlpha = 0    -- what we're currently faded to
local shown = false       -- mirrors visibility
local pulseT = 0          -- ticks upward while you're standing on something

-- Item-art lookups are cached, and each slot remembers which node it's currently
-- wearing -- so we only repaint when the cue actually re-targets, rather than
-- twenty times a second for the same herb.
local iconCache = {}      -- [itemID] = fileID (hits only)

-- Who we last said "hey" about. Because Vignettes caches its nodes by GUID,
-- every node in the addon is a stable table -- so "is this a different node?" is
-- a pointer comparison, and nothing needs to be allocated to ask it.
local soundNode, lastSoundTime = nil, 0

-- The dials for "how much does this thing move around." Deliberately restrained.
-- It's a cue, not a boss warning.
local PROXIMITY_GROWTH = 0.25   -- up to +25% bigger as you close in
local PULSE_DEPTH      = 0.12   -- +/-12% while pulsing
local PULSE_SPEED      = 5.0    -- radians/sec -- a heartbeat, not a strobe
local ARROW_GAP_NEAR   = 6      -- px from icon to arrow, up close
local ARROW_GAP_FAR    = 20     -- ...and out at the edge of range
local MAX_SLOTS        = 3      -- the most icons we'll ever show at once

-- Where the runners-up sit, relative to the main icon: out to the sides, at a
-- distance that scales with how big the main icon is. The nearest node keeps the
-- middle -- it's the one you're meant to look at -- and the others flank it,
-- smaller, close enough to notice and far enough not to argue.
local SIDE_GAP = 0.85           -- as a multiple of the main icon's size

-- Walk `value` toward `target`, no faster than `maxStep`. (Same tween the radar
-- uses; both obey fadeSpeed.)
local function approach(value, target, maxStep)
    if value < target then return math.min(value + maxStep, target) end
    if value > target then return math.max(value - maxStep, target) end
    return value
end

-- ---------------------------------------------------------------------------
-- What does it look like?
--
-- Ideally: like the thing itself. If we know what item this node drops, we draw
-- that item's actual art, and a Mycobloom on your screen looks like a Mycobloom.
-- That's the whole delight of it.
--
-- When we can't, we fall back to a generic glyph tinted with the node's color.
-- "Can't" happens more than you'd think:
--   * a gather whose loot we never resolved is stored type-only (id = nil)
--   * a vignette's id is a vignetteID, NOT an itemID -- hand that number to
--     GetItemIconByID and you'll draw whatever unrelated item happens to own it.
--     Hence the explicit node.vignette check. It is load-bearing.
-- ---------------------------------------------------------------------------
local function itemIcon(itemID)
    local cached = iconCache[itemID]
    if cached then return cached end

    local icon
    if C_Item and C_Item.GetItemIconByID then
        icon = C_Item.GetItemIconByID(itemID)
    end
    if not icon and C_Item and C_Item.GetItemInfo then
        icon = select(10, C_Item.GetItemInfo(itemID))   -- 10th return is the icon
    end

    -- Only cache hits. A miss usually just means the client hasn't heard of the
    -- item yet; leaving it uncached lets us try again next time the cue changes
    -- targets, by which point it's normally arrived.
    if icon then iconCache[itemID] = icon end
    return icon
end

-- Dress one slot for one node. Memoized on the node, so it runs when that slot
-- re-targets and not on every frame. (ApplyLayout clears every slot's memo when a
-- color or style setting changes -- that's what makes dragging a color picker
-- repaint the cue live, instead of "next time you happen to fly past a herb".)
local function applyIcon(slot, node)
    if node == slot.node then return end
    slot.node = node

    local db = NS.db
    local c = NS.TypeColor(node.type)

    -- Which face are we wearing today?
    --
    -- "custom" means the player supplied their own generic art and would rather
    -- see "a herb" than "a Mycobloom" -- so we don't even look the item up.
    -- "item" means show the real thing when we can, and fall back to a glyph when
    -- we can't (a node we've never gathered, or a vignette, whose id is a
    -- vignetteID and NOT an itemID -- feed that number to GetItemIconByID and
    -- you'll draw a picture of some unrelated item that happens to own it).
    -- WHICH NUMBER IS AN ITEM ID?
    --
    -- Only `node.item`. `node.id` is the node's IDENTITY, and depending on where
    -- the node came from that's an itemID (a gather, before GatherMate existed
    -- here), a vignetteID, or a GatherMate species id -- and feeding either of the
    -- last two to GetItemIconByID draws a confident picture of some unrelated item
    -- that happens to own that number.
    --
    -- So: use node.item. Fall back to node.id ONLY for the legacy case where it
    -- genuinely is the item (a gather we recorded before, with no seed data and no
    -- vignette). Everything else gets the generic glyph, which is the honest
    -- answer -- we haven't picked one of these yet, so we've never seen its art.
    local itemID = node.item

    -- We may never have picked THIS herb, but if we've ever picked one of its
    -- species we know what it looks like. That's what speciesItem is for, and it's
    -- what lets a live soft-target node -- which knows what it is but has never
    -- been in your bags -- show real art instead of a generic leaf.
    if not itemID and node.id then
        local byType = db.speciesItem and db.speciesItem[node.type]
        itemID = byType and byType[node.id]
    end

    -- Legacy: nodes recorded before species ids existed, whose `id` genuinely IS
    -- the item they dropped.
    if not itemID and not node.vignette and not node.seeded and not node.live then
        itemID = node.id
    end

    -- ONE SWITCH, TWO ANSWERS. That's the whole of it.
    --
    --   "custom" -- your art, from textures/. One icon per type, every time. A herb
    --               is a herb. Nothing to learn, nothing that changes as you play.
    --   "item"   -- the game's own art: the actual Mycobloom, once we know what
    --               this species drops. Until then, Blizzard's generic glyph for
    --               the type, tinted by its color.
    --
    -- There used to be a THIRD thing here -- standInGlyphs -- which quietly used
    -- your art as the fallback inside "item" mode. It was a sensible behavior and a
    -- terrible setting: two checkboxes that both said "use my icons" and meant
    -- different things, and no way to tell from the page which one was in charge.
    -- Gone. If you want your art, ask for your art.
    local icon, isRealArt
    if (db.iconStyle or "item") == "custom" then
        icon = NS.CustomGlyph[node.type]
    elseif itemID then
        icon = itemIcon(itemID)
        isRealArt = icon ~= nil
    end

    if not icon then
        icon = NS.NodeTypeGlyph[node.type] or NS.FallbackGlyph
    end

    slot.icon:SetTexture(icon)
    if isRealArt then
        slot.icon:SetVertexColor(1, 1, 1)            -- real art. Don't paint on it.
    else
        slot.icon:SetVertexColor(c[1], c[2], c[3])   -- a glyph carries its type in its color
    end

    -- The border is the only thing left that can tell you what KIND of node this
    -- is once we're showing real item art. You can't tint a herb's icon green
    -- without wrecking the picture -- but you can frame it in green.
    local bc = NS.CueBorderColor
    if db.cueBorderTypeColor then
        slot.border:SetColorTexture(c[1], c[2], c[3], bc[4])
    else
        slot.border:SetColorTexture(bc[1], bc[2], bc[3], bc[4])
    end
end

-- ---------------------------------------------------------------------------
-- The little "hey" (off unless you ask)
--
-- Edge-triggered: it fires once when a DIFFERENT node becomes the nearest one,
-- including the first one to show up. It is not a metronome. It does not follow
-- you around going ping. It mentions the thing, once, and then it's quiet.
-- ---------------------------------------------------------------------------
local function tickSound(node)
    local db = NS.db
    if not db.soundEnabled then
        soundNode = node        -- keep it in sync anyway, so switching the sound
        return                  -- on doesn't immediately ping for the node you're
    end                         -- already standing next to
    if node == soundNode then return end

    -- A guess never gets to make a noise.
    --
    -- The sound says "there is something here" out loud, and for a remembered node
    -- -- yours or GatherMate's -- that is a claim we cannot support: most of those
    -- points are empty ground. Being wrong quietly, in the corner of your eye, at
    -- unconfirmedAlpha, is a small thing. Being wrong with a chime is a liar.
    if not Data.IsConfirmed(node) then
        soundNode = node
        return
    end

    local now = GetTime()
    -- The cooldown is a floor, not a nicety. Scan's hysteresis already stops two
    -- near-identical nodes trading places every tick, but this is the backstop
    -- that guarantees you never get machine-gunned.
    if (now - lastSoundTime) < (db.soundCooldown or 5) then return end

    soundNode = node
    lastSoundTime = now
    if NS.CueSoundKit then PlaySound(NS.CueSoundKit) end
end

-- ---------------------------------------------------------------------------
-- Building it
-- ---------------------------------------------------------------------------
-- One icon's worth of art: a border, the icon, and an arrow. Three of these get
-- built up front (they're cheap, and building frames mid-combat is how you get
-- stutter) and we simply show fewer of them when the player wants fewer.
local function makeSlot()
    local s = {}

    -- The border is a lie, and a good one: it's a plain solid rectangle sitting
    -- BEHIND the icon, drawn a few pixels bigger on every side. The icon is
    -- opaque, so the only part of the rectangle you ever see is the margin --
    -- which reads exactly like a border. One texture instead of four, no corner
    -- seams to fight, and it grows with the icon for free.
    s.border = frame:CreateTexture(nil, "BACKGROUND")
    s.border:Hide()

    s.icon = frame:CreateTexture(nil, "ARTWORK")
    -- (The crop is applied in ApplyLayout -- it's a setting, not a fact about the
    -- node. And note this texture is never rotated: SetRotation is implemented
    -- with texcoords and would fight the crop. That's exactly why the arrow gets
    -- its own texture instead of sharing this one.)
    s.icon:Hide()

    s.arrow = frame:CreateTexture(nil, "OVERLAY")
    s.arrow:SetTexture(NS.ArrowTexture)
    s.arrow:Hide()

    return s
end

local function hideSlot(s)
    s.border:Hide()
    s.icon:Hide()
    s.arrow:Hide()
    s.node = nil
end

function Cue.Create()
    if frame then return end
    frame = CreateFrame("Frame", "EyesUpCue", UIParent)
    frame:SetFrameStrata("MEDIUM")

    for i = 1, MAX_SLOTS do
        slots[i] = makeSlot()
    end

    -- Draggable when unlocked, remembered in the cue's OWN position keys so it
    -- never fights the radar over where "your spot" is.
    frame:SetMovable(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(self)
        if not NS.db.locked then self:StartMoving() end
    end)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local cx, cy = UIParent:GetCenter()
        local sx, sy = self:GetCenter()
        NS.db.cuePosX = math.floor(sx - cx + 0.5)
        NS.db.cuePosY = math.floor(sy - cy + 0.5)
    end)

    frame:Hide()
    Cue.ApplyLayout()
end

function Cue.ApplyLayout()
    if not frame then return end
    local db = NS.db

    -- Square it off: crop the beveled frame that item art bakes into its own
    -- outer edge. Skip this and you get the stock rounded bevel with our border
    -- sitting outside it, like a picture frame around a picture frame.
    local crop = db.cueSquareIcon and NS.IconCrop or 0

    for i = 1, MAX_SLOTS do
        local s = slots[i]
        s.icon:SetTexCoord(crop, 1 - crop, crop, 1 - crop)
        -- Icon and border art are memoized per node (see applyIcon), so a palette
        -- edit -- or switching to your own textures -- wouldn't show up until that
        -- slot happened to re-target. Drop the memo and the next frame repaints.
        -- This one line is why the color picker updates live while you're still
        -- dragging the wheel.
        s.node = nil
    end

    -- Big enough for the main icon at full growth, its border, the arrow orbiting
    -- outside all that, and a smaller icon out to either side. This frame is the
    -- anchor and the drag target -- it isn't the art.
    local main = db.cueSize * (1 + PROXIMITY_GROWTH) + (db.cueBorderSize or 0) * 2
    local wide = main + (ARROW_GAP_FAR + main * SIDE_GAP) * 2
    frame:SetSize(wide, main + ARROW_GAP_FAR * 2)
    frame:ClearAllPoints()
    frame:SetPoint("CENTER", UIParent, "CENTER", db.cuePosX, db.cuePosY)
    -- Only take the mouse when unlocked. A mouse-enabled frame parked at screen
    -- center would otherwise quietly eat your mouselook and your click-to-move,
    -- and you would rightly hate us for it.
    frame:EnableMouse(not db.locked)
end

-- Scan calls this when the player didn't ask for a cue (or turned the addon
-- off). Reset the tween so we fade in from nothing next time instead of popping
-- back at a stale opacity.
function Cue.Hide()
    if not frame or not shown then return end
    frame:Hide()
    shown = false
    currentAlpha = 0
    for i = 1, MAX_SLOTS do hideSlot(slots[i]) end
    soundNode = nil
end

-- ---------------------------------------------------------------------------
-- Draw one scan
--
-- `result` is Scan.result -- REUSED every tick. Read it; never hold onto an entry
-- from it (the contract is spelled out in Scan.lua). `elapsed` is accumulated
-- time, which is what makes the fade framerate-independent.
-- ---------------------------------------------------------------------------
-- Draw one node into one slot.
--
-- `main` is the slot in the middle: the nearest thing, drawn full size, allowed
-- to pulse. The others are runners-up -- smaller, off to the side, present but
-- not shouting.
local function renderSlot(s, entry, result, elapsed, main, offsetX)
    local db = NS.db
    local node, dist = entry.node, entry.dist

    applyIcon(s, node)

    -- Distance you feel instead of read. No numbers, ever -- you're flying, you
    -- don't want arithmetic, you want to know if it's worth turning.
    local frac = dist / result.range
    if frac < 0 then frac = 0 elseif frac > 1 then frac = 1 end
    local scale = 1 + PROXIMITY_GROWTH * (1 - frac)

    -- You're on top of it. At this range the bearing swings wildly with every
    -- step you take, and an arrow that spins in circles is worse than no arrow at
    -- all. So: drop it, and pulse. "It's right here" is the only thing left worth
    -- saying, so say only that.
    local close = dist <= result.closeRange

    if close and main then
        pulseT = pulseT + elapsed
        scale = scale * (1 + PULSE_DEPTH * math.sin(pulseT * PULSE_SPEED))
    end

    local size = db.cueSize * scale
    if not main then size = size * (db.cueSecondaryScale or 0.62) end

    s.icon:SetSize(size, size)
    s.icon:ClearAllPoints()
    s.icon:SetPoint("CENTER", frame, "CENTER", offsetX, 0)
    s.icon:Show()

    -- The border grows with the icon rather than being a fixed ring, so it stays
    -- the thickness you asked for while the icon swells and pulses.
    local border = db.cueBorderSize or 0
    if border > 0 then
        s.border:SetSize(size + border * 2, size + border * 2)
        s.border:ClearAllPoints()
        s.border:SetPoint("CENTER", frame, "CENTER", offsetX, 0)
        s.border:Show()
    else
        s.border:Hide()
    end

    -- The arrow orbits outside the BORDER, not the icon -- otherwise a thick
    -- border simply swallows it.
    local outer = size * 0.5 + border

    if close or not db.cueShowArrow or not result.facing then
        s.arrow:Hide()
    else
        -- Same convention as the radar: our Bearing() is clockwise-from-north and
        -- GetPlayerFacing() is counter-clockwise-from-north, so the two cancel
        -- out. It's `+ facing`, however much you want it to be minus.
        local relative = entry.bearing + result.facing
        -- The arrow also draws in toward the icon as you approach, so the whole
        -- little cluster tightens up. Another way of saying "closer" without
        -- saying a number.
        local gap = ARROW_GAP_NEAR + (ARROW_GAP_FAR - ARROW_GAP_NEAR) * frac
        local r = outer + gap
        s.arrow:SetSize(size * 0.5, size * 0.5)     -- square; see NS.ArrowTexture
        s.arrow:SetRotation(-relative)              -- the art points north at 0
        s.arrow:ClearAllPoints()
        s.arrow:SetPoint("CENTER", frame, "CENTER",
            offsetX + math.sin(relative) * r,       -- +x = right
            math.cos(relative) * r)                 -- +y = up = straight ahead
        s.arrow:Show()
    end
end

function Cue.Render(result, elapsed)
    if not frame then return end
    local db = NS.db

    -- Note what we do NOT require: a facing. Opening the world map nils
    -- GetPlayerFacing(), which makes the *direction* meaningless -- but not the
    -- distance. So the arrows go away and the icons stay. Blinking the entire cue
    -- out every time you glance at your map would be exactly the sort of
    -- twitchiness this addon exists to avoid.
    local n = result.valid and result.topCount or 0
    local nearest = n > 0 and result.top[1] or nil

    if nearest then
        frame:Show()
        shown = true

        tickSound(nearest.node)
        if nearest.dist > result.closeRange then pulseT = 0 end

        -- The main icon is centered; the runners-up flank it, out to the right and
        -- then the left. Scan has already trimmed this list -- if something tripped
        -- the focus lock, n is 1 and there's nothing to flank with.
        local step = db.cueSize * (1 + PROXIMITY_GROWTH) * SIDE_GAP
        for i = 1, n do
            local offsetX = 0
            if i == 2 then offsetX =  step
            elseif i == 3 then offsetX = -step end
            renderSlot(slots[i], result.top[i], result, elapsed, i == 1, offsetX)
        end
        for i = n + 1, MAX_SLOTS do hideSlot(slots[i]) end
    else
        soundNode = nil     -- so the next thing to turn up gets its "hey"
        pulseT = 0
        for i = 1, MAX_SLOTS do hideSlot(slots[i]) end
    end

    -- Fade out to nothing when there's nothing, and then actually leave -- a cue
    -- that lingers at 12% opacity is a ghost of a herb you already passed, still
    -- quietly insisting it's there.
    --
    -- And when there IS something: how loudly we say so depends on whether we
    -- actually know it's there. A vignette we can see right now gets full
    -- opacity. A node we merely remember gets unconfirmedAlpha, because we are
    -- guessing, and we should have the decency to look like we're guessing.
    local target = db.cueIdleAlpha
    if nearest then
        target = db.activeAlpha
        -- Keyed off the NEAREST node, the one we're really talking about. (The
        -- frame's alpha is shared by every slot, which is the honest simplification:
        -- if the thing at your feet is a certainty, the cue is confident.)
        if not Data.IsConfirmed(nearest.node) then
            target = target * (db.unconfirmedAlpha or 1)
        end
    end
    currentAlpha = approach(currentAlpha, target, db.fadeSpeed * elapsed)
    frame:SetAlpha(currentAlpha)

    if not nearest and currentAlpha <= 0.01 then
        frame:Hide()
        shown = false
    end
end
