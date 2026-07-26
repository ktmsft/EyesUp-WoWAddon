-- Eyes Up - Copyright (c) 2026 KTM (abitofmoss). All Rights Reserved.
-- No redistribution or reuse of this code or assets without permission. See LICENSE.
local addonName, NS = ...

-- =============================================================================
-- Scan.lua
-- The engine room. Everything that isn't paint.
--
-- Once per tick: where are you, which way are you looking, what's near you, and
-- which of it matters most. That's it. That's the whole job. Then it hands the
-- answer to whoever's drawing today and goes back to sleep for 50 milliseconds.
--
-- This used to live inside the radar's update function, which meant the radar
-- WAS the addon -- the thing that found nodes and the thing that drew them were
-- the same function, and you couldn't have one without the other. Adding the cue
-- meant either copying all of it or pulling it out. This file is the pulling-out.
--
-- It loads AFTER both renderers, which looks backwards until you see why: it's
-- the only module that needs THEM, and they need nothing from it. So everyone
-- gets to bind their dependencies at file scope like civilized code, and nobody
-- has to do a lazy NS.Whatever lookup that a future reader will "tidy up" into a
-- nil upvalue.
--
-- WHAT COUNTS AS A NODE: whatever Data.ForEachNearby and Vignettes.ForEachOnMap
-- hand us -- and both of those apply the player's filters at the source. So by
-- the time anything reaches this file it's already something the player asked
-- for. There is exactly one place that can get filtering wrong, and it isn't
-- here, and it isn't in either renderer.
-- =============================================================================

local Scan = {}
NS.Scan = Scan

local Data      = NS.Data
local Seed      = NS.Seed
local Live      = NS.Live
local Vignettes = NS.Vignettes
local Overlay   = NS.Overlay
local Cue       = NS.Cue

local THROTTLE = 0.05     -- 20 scans a second is plenty

-- ---------------------------------------------------------------------------
-- The answer.
--
-- One table, REUSED every tick, entries and all. This runs twenty times a second
-- for as long as you're logged in, so it allocates nothing once it's warmed up.
-- The price of that is a contract, and it is not negotiable:
--
--   * Entries are only valid during the Render call they're handed to. Read
--     them. Do not keep one. Do not modify one.
--   * Loop `for i = 1, result.count`. NOT ipairs. NOT #list. The tail of the
--     pool is full of last tick's ghosts, and they look exactly like real nodes.
--   * In "both" mode, two renderers read this same table in the same tick.
--
-- `valid` and `facing` are separate flags on purpose, and the distinction is
-- subtle enough to be worth a paragraph. `valid` means we know where you ARE, so
-- distances mean something. `facing` means we know which way you're LOOKING, so
-- bearings mean something. Open the world map and GetPlayerFacing() goes nil --
-- your bearings die, your distances don't. Collapse these into one flag and the
-- cue blinks out every time you check your map, which is maddening, which is why
-- there are two.
-- ---------------------------------------------------------------------------
Scan.result = {
    valid      = false,
    facing     = nil,
    mapID      = nil,
    px         = nil,
    py         = nil,
    range      = 0,     -- how far we're looking, in whatever yards are in play
    closeRange = 0,     -- "you're standing on it" (see CloseRange)
    count      = 0,     -- how many entries in `list` are real
    list       = {},    -- the pool: { node =, dist =, bearing = }
    nearest    = nil,   -- the one that matters, or nil

    -- The shortlist: the nearest few, in order, already trimmed to how many the
    -- player asked for (cueCount) and already collapsed to ONE if the focus lock
    -- has fired. `top[1]` is always the same entry as `nearest`.
    --
    -- Renderers draw from this. It holds pointers into `list`, so the same
    -- don't-keep-it, don't-touch-it contract applies, and `topCount` -- not #top --
    -- says how many are real.
    top        = {},
    topCount   = 0,
    focused    = false, -- true = something is close enough that it's the only thing
                        -- worth mentioning, and we dropped the rest
}

-- Who we're currently locked onto. Remembered across ticks, for the reason
-- immediately below.
local stickyNode

-- Two nodes a yard apart will otherwise swap the title of "nearest" back and
-- forth every single tick -- strobing the cue's icon, machine-gunning the sound,
-- and generally behaving like a haunted compass. So a challenger has to be
-- MEANINGFULLY closer, not just closer.
local STICKY_MARGIN = 0.9

-- ---------------------------------------------------------------------------
-- How far is far?
--
-- Sixty yards means sixty yards. That sentence used to be a lie.
--
-- There were two of every threshold here -- detectionYards AND detectionNorm,
-- closeYards AND closeNorm -- because without HereBeDragons the addon didn't
-- know how big a zone was and scaled map coordinates against a guess (1000
-- yards). The guess was off by a factor of NINE in Zul'Aman, so a default
-- install's "60 yard" detection radius was really ~450 yards, the focus lock
-- fired at a hundred and fifty, and the addon quietly became the treasure map
-- it was written not to be.
--
-- Data.MapSize asks the client instead. There is one regime now, it is yards,
-- and these three functions are the trivial readers they should always have
-- been. Add a threshold: add ONE key.
-- ---------------------------------------------------------------------------
function Scan.DetectionRange()
    return NS.db.detectionYards
end

function Scan.CloseRange()
    return NS.db.closeYards
end

-- Inside this, one thing matters and the others don't. See the focus lock below.
function Scan.FocusRange()
    return NS.db.focusYards or 20
end

-- ---------------------------------------------------------------------------
-- The pass itself
-- ---------------------------------------------------------------------------

-- Hoisted up here with its state in module locals, because this function gets
-- handed to two iterators every tick -- and a closure built inside Update() would
-- be one more allocation per tick, forever, for no reason at all.
local scanRange, bestRank, bestEntry, stickyEntry

local function consider(node, dist, bearing)
    -- Data.DistanceYards always answers now, but the nil guard stays: it costs
    -- nothing, and a source that hands us a node it can't place is a bug we'd
    -- rather ignore than crash on, twenty times a second, mid-flight.
    if not dist or dist > scanRange then return end

    local r = Scan.result
    local i = r.count + 1
    r.count = i

    local e = r.list[i]
    if not e then
        e = {}
        r.list[i] = e
    end
    e.node, e.dist, e.bearing = node, dist, bearing

    -- TWO distances, and the difference matters. `dist` is how far the thing
    -- actually is -- it's what renderers draw with and what the focus lock reads.
    -- `rank` is that distance bent by the player's priority for its type, and it
    -- is used for ONE thing: deciding who wins. Whether something is IN range is
    -- still judged on the real distance above, so raising a type's priority never
    -- conjures nodes out past the detection radius; it only decides which of the
    -- things already in front of you gets the icon.
    e.rank = dist * NS.TypeWeight(node.type)

    if not bestRank or e.rank < bestRank then
        bestRank, bestEntry = e.rank, e
    end
    if node == stickyNode then
        stickyEntry = e
    end
end

-- ---------------------------------------------------------------------------
-- The shortlist, and the focus lock.
--
-- The player asked for up to `cueCount` icons (1 to 3). We give them the nearest
-- that many -- EXCEPT when something is close enough to trip the focus lock, at
-- which point it becomes the only thing we mention, no matter what they asked
-- for.
--
-- That exception is the whole personality of this addon. If there's a herb
-- fifteen yards away, "there is a herb fifteen yards away" is the entire message.
-- Adding "...and two more somewhere out there" doesn't enrich it, it dilutes it.
-- Go and get the herb.
--
-- Selection is a partial sort -- we pick the smallest, then the next, at most
-- three times. O(3n) with n = the handful of nodes in range, no allocation, no
-- table.sort, nothing to garbage-collect. Runs twenty times a second forever, so
-- that matters more than the elegance does.
-- ---------------------------------------------------------------------------
local MAX_ICONS = 3

local function buildShortlist(r, bestEntry)
    r.topCount = 0
    r.focused  = false

    if not bestEntry then return end

    -- The winner is already decided (priority applied, hysteresis applied), so it
    -- goes in first and unconditionally. Everything below fills in behind it.
    r.top[1] = bestEntry
    r.topCount = 1

    -- Focus lock: it's right there. Say that and only that.
    --
    -- On `dist`, NOT `rank`. A node at your feet is at your feet no matter how
    -- you feel about its type -- weighting this would mean a LOW-priority herb
    -- you're standing on fails to trip the lock and keeps two other icons on
    -- screen, which is nonsense.
    if bestEntry.dist <= Scan.FocusRange() then
        r.focused = true
        return
    end

    local db = NS.db
    local want = db.cueCount or 1
    if want < 1 then want = 1 elseif want > MAX_ICONS then want = MAX_ICONS end
    if want == 1 then return end

    -- Fill the remaining slots with the next-best, skipping anything already on
    -- the list. Ranked, like the winner was -- so the runners-up are the ones the
    -- player would care about next, not merely the ones standing nearest.
    for _ = 2, want do
        local pick, pickRank
        for i = 1, r.count do
            local e = r.list[i]
            local taken = false
            for j = 1, r.topCount do
                if r.top[j] == e then taken = true; break end
            end
            if not taken and (not pickRank or e.rank < pickRank) then
                pick, pickRank = e, e.rank
            end
        end
        if not pick then break end
        r.topCount = r.topCount + 1
        r.top[r.topCount] = pick
    end
end

-- Look around. Returns the (reused) result table.
function Scan.Update()
    local r = Scan.result
    local db = NS.db
    r.count   = 0
    r.nearest = nil
    r.valid   = false
    r.facing  = nil

    local mapID, px, py = Data.GetPlayerPosition()
    if not (mapID and px and py) then
        stickyNode = nil
        return r
    end

    r.valid = true
    r.mapID, r.px, r.py = mapID, px, py
    r.facing     = GetPlayerFacing()          -- nil with the world map open
    r.range      = Scan.DetectionRange()
    r.closeRange = Scan.CloseRange()

    scanRange = r.range
    bestRank, bestEntry, stickyEntry = nil, nil, nil

    -- ---------------------------------------------------------------------
    -- Truth first, and by default truth ONLY.
    --
    -- These two sources are the only ones that KNOW. Live is the soft-interact
    -- target -- a real object, right there, that you could gather this second.
    -- Vignettes are drawn by the engine, so they exist by definition. Neither can
    -- ever tell you about something that isn't there.
    -- ---------------------------------------------------------------------
    Live.ForEachNearby(mapID, px, py, consider)       -- what is definitely there
    Vignettes.ForEachOnMap(mapID, px, py, consider)   -- what we can see

    -- ---------------------------------------------------------------------
    -- ...and the guesses, if you asked for them.
    --
    -- Both of these are memories of where a node HAS been. GatherMate has 3,421
    -- of them in Zul'Aman and only a fraction are standing at any moment, so with
    -- this on, most of what the cue points at will be empty ground. That is not a
    -- bug -- there is no API that would let it be otherwise -- which is why it's
    -- off by default and why what it draws is dimmed (Data.IsConfirmed) and never
    -- makes a sound. A guess should look like a guess.
    -- ---------------------------------------------------------------------
    if db.showGuesses then
        Data.ForEachNearby(mapID, px, py, consider)   -- what we remember
        Seed.ForEachNearby(mapID, px, py, consider)   -- what someone else remembered
    end

    -- Keep the node we already had unless the newcomer genuinely beats it. Both
    -- sources hand back stable tables (the database's live in your saved
    -- variables; Vignettes caches its own by GUID), so this identity check is a
    -- pointer comparison and costs nothing.
    --
    -- Compared on `rank`, the same scale the winner was chosen on. Mixing the two
    -- -- picking by rank but defending by distance -- would let a node lose the
    -- comparison and win the tie-break, and the cue would flicker between them.
    if stickyEntry and bestEntry and bestEntry ~= stickyEntry
       and bestEntry.rank >= stickyEntry.rank * STICKY_MARGIN then
        bestEntry = stickyEntry
    end

    r.nearest  = bestEntry
    stickyNode = bestEntry and bestEntry.node or nil

    buildShortlist(r, bestEntry)
    return r
end

-- ---------------------------------------------------------------------------
-- The heartbeat
--
-- A standalone frame that is never hidden and belongs to nobody. That sounds
-- fussy; it is not. A hidden frame does not run OnUpdate in WoW.
--
-- The loop used to live ON the radar's frame, and the radar hid its own frame
-- when you disabled the addon -- killing the very OnUpdate that would have
-- noticed you turning it back on. `/ns toggle` off, then on, and the radar simply
-- stayed dead until you /reload'd. It looked like a mystery. It was a snake
-- eating its own tail.
--
-- So the heartbeat lives out here where nothing can hide it, and "hidden" goes
-- back to being a decision about drawing rather than a decision about living.
-- Don't move it back onto a frame you also hide.
-- ---------------------------------------------------------------------------
local driver
local sinceUpdate = 0

local function hideAll()
    Overlay.Hide()
    Cue.Hide()
end

local function onUpdate(_, elapsed)
    sinceUpdate = sinceUpdate + elapsed
    if sinceUpdate < THROTTLE then return end
    local step = sinceUpdate      -- the ACCUMULATED time, not this frame's sliver:
    sinceUpdate = 0               -- the fades are per-second, and handing them a
                                  -- raw 60fps delta runs them about 3x too slow.

    local db = NS.db
    if not db then return end     -- we can tick before ADDON_LOADED. Be patient.

    if not db.enabled then
        hideAll()
        return                    -- note: hide the ART, never the heartbeat
    end

    -- Nil-safe on purpose: a saved-variables table from before `mode` existed
    -- must not resolve to "render nothing at all."
    local mode = db.mode or "cue"
    local result = Scan.Update()

    if mode == "radar" or mode == "both" then
        Overlay.Render(result, step)
    else
        Overlay.Hide()
    end

    if mode == "cue" or mode == "both" then
        Cue.Render(result, step)
    else
        Cue.Hide()
    end
end

-- Started from Core at PLAYER_LOGIN, once both renderers exist to be drawn into.
function Scan.Start()
    if driver then return end
    driver = CreateFrame("Frame")
    driver:SetScript("OnUpdate", onUpdate)
    driver:Show()
end
