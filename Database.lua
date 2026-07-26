local addonName, NS = ...

-- =============================================================================
-- Database.lua
-- The memory, and the math.
--
-- Here's the reality this whole addon is built around: WoW will not tell you
-- where the herbs are. There is no API for it. There never has been. The world
-- is full of ore veins and the client cheerfully declines to enumerate a single
-- one of them.
--
-- So we do what a gatherer does. We remember. Every node you pick gets written
-- down -- what it was, where you were standing -- and from then on, when you
-- come back this way, we can tell you "there was one about forty yards that
-- way." Not "there is one." There WAS one. The difference is the entire honest
-- soul of this file, and it's why IsAvailable() and IsConfirmed() exist below.
--
-- The rest is arithmetic: how far, and which way.
-- =============================================================================

local Data = {}
NS.Data = Data

-- Everything we know: nodes[mapID] = { {x=, y=, type=, id=, name=, harvested=}, ... }
-- Core.lua swaps this for the saved-variables table at login, so these tables
-- ARE the saved data -- mutate them and it persists.
Data.nodes = {}

-- ---------------------------------------------------------------------------
-- Where am I, how far is that, and which way
-- ---------------------------------------------------------------------------

-- The player's spot on their current map. Returns mapID, x, y (0..1), or nil
-- when the world isn't ready to say (loading screens, taxi rides, the void).
function Data.GetPlayerPosition()
    local mapID = C_Map.GetBestMapForUnit("player")
    if not mapID then return nil end
    local pos = C_Map.GetPlayerMapPosition(mapID, "player")
    if not pos then return nil end
    local x, y = pos:GetXY()
    if not x or not y then return nil end
    return mapID, x, y
end

-- ---------------------------------------------------------------------------
-- How big is this zone, actually?
--
-- Map coordinates are 0..1 across the zone, so a "distance" in them is
-- meaningless until you know what the zone measures in yards. This addon used to
-- guess -- one constant, 1000 yards, applied to both axes, with a whole parallel
-- set of saved settings (detectionNorm, closeNorm, focusNorm) to paper over how
-- wrong the guess was.
--
-- It didn't need to guess. C_Map.GetMapWorldSize has been able to answer this
-- exactly, for free, for years, and it returns the two axes SEPARATELY -- which
-- matters more than the scale does. Zul'Aman is 8950 x 5967 yards: half again as
-- wide as it is tall. Scale both axes by one number and you don't merely get the
-- distances wrong, you get them wrong ANISOTROPICALLY -- a yard east counts for
-- less than a yard north, the detection radius becomes an ellipse, and the
-- bearing (an atan2 of the two) comes out skewed by up to eleven degrees. The
-- arrow pointed slightly beside the herb, in every non-square zone, forever.
--
-- Nothing here needs world coordinates or a library. Scale each axis by its own
-- real size and both the distance and the angle fall out correct.
--
-- The first return is the map's X span, the second its Y. Cached per map: it
-- never changes, and this is the hot path.
-- ---------------------------------------------------------------------------
local sizeCache = {}

-- The last resort, and it should never fire: a map the client won't size for us.
-- Better a wrong number than a dead addon -- but if you ever see distances
-- misbehave, check whether you've landed here.
local FALLBACK = NS.FALLBACK_ZONE_YARDS

function Data.MapSize(mapID)
    local s = sizeCache[mapID]
    if s then return s[1], s[2] end

    local w, h
    if C_Map.GetMapWorldSize then
        w, h = C_Map.GetMapWorldSize(mapID)
    end
    if not (w and h) or w <= 0 or h <= 0 then
        w, h = FALLBACK, FALLBACK
    end

    sizeCache[mapID] = { w, h }
    return w, h
end

-- Distance in yards between two points on a map. True yards, both axes, no
-- library, no approximation.
function Data.DistanceYards(mapID, x1, y1, x2, y2)
    local w, h = Data.MapSize(mapID)
    local dx = (x2 - x1) * w
    local dy = (y2 - y1) * h
    return math.sqrt(dx * dx + dy * dy)
end

-- Which way is it? A compass bearing in radians, clockwise from north.
--
-- Two lines worth reading twice:
--
--   * Map y grows SOUTHWARD, so "north" is y1 - y2, not the other way round.
--     Get this backwards and the arrow points confidently into the sea.
--   * The axes are scaled to YARDS before the atan2, which is why this needs a
--     mapID that it never used to need. An angle between two normalized deltas
--     is not an angle in the world unless the zone happens to be square, and
--     they mostly aren't.
--
-- The convention is unchanged -- radians, clockwise from north -- so the renderers'
-- `relative = bearing + facing` still cancels the way it always did.
function Data.Bearing(mapID, x1, y1, x2, y2)
    local w, h = Data.MapSize(mapID)
    local east  = (x2 - x1) * w      -- +x = east
    local north = (y1 - y2) * h      -- map y grows south, so north = -dy
    return math.atan2(east, north)
end

-- ---------------------------------------------------------------------------
-- Writing things down
-- ---------------------------------------------------------------------------

function Data.GetZone(mapID)
    local z = Data.nodes[mapID]
    if not z then z = {}; Data.nodes[mapID] = z end
    return z
end

-- "I have seen one of these before." Feeds the per-node filter list, which is
-- how you get to say "all herbs except that one weed I keep accidentally
-- picking."
function Data.NoteKnown(nodeType, id, name)
    local db = NS.db
    if not db then return end
    db.knownNodes[nodeType] = db.knownNodes[nodeType] or {}
    if name and (not db.knownNodes[nodeType][id]) then
        db.knownNodes[nodeType][id] = name
    end
end

-- Remember a node. If we already know one of the same kind within dedupeYards,
-- this is that node again (you wandered a bit while casting), so we nudge the
-- stored coords toward the new sighting rather than filling the map with
-- near-identical duplicates.
--
-- Returns `node, isNew` -- the table either way, so the caller can do something
-- to the thing it just recorded (Core stamps it as harvested) without having to
-- go looking for it again.
function Data.AddNode(mapID, x, y, nodeType, id, name)
    local zone = Data.GetZone(mapID)
    local dedupe = (NS.db and NS.db.dedupeYards) or 15
    for _, n in ipairs(zone) do
        if n.type == nodeType then
            local d = Data.DistanceYards(mapID, n.x, n.y, x, y)
            if d and d <= dedupe then
                -- Same node, seen again. Average the position (each sighting
                -- makes it a little truer) and backfill anything we learned this
                -- time that we didn't know last time.
                n.x = (n.x + x) * 0.5
                n.y = (n.y + y) * 0.5
                if id and not n.id then n.id = id end
                if name and not n.name then n.name = name end
                if id then Data.NoteKnown(nodeType, id, name) end
                return n, false
            end
        end
    end
    local node = { x = x, y = y, type = nodeType, id = id, name = name }
    zone[#zone + 1] = node
    if id then Data.NoteKnown(nodeType, id, name) end
    return node, true
end

-- ---------------------------------------------------------------------------
-- Is it still there? (An honest accounting)
-- ---------------------------------------------------------------------------

-- The one thing we know for certain about a node: if you just picked it, it's
-- gone. Stamp it, and stop pointing at it.
--
-- Without this, you'd pluck a herb, turn around, and the cue would swing back
-- and point triumphantly at the empty ground you were standing on. Which is
-- funny exactly once.
--
-- The stamp is time() -- SERVER time, the wall clock. Not GetTime(), which
-- counts seconds since the client launched and would therefore reset on every
-- /reload, resurrecting the entire afternoon's harvest.
function Data.MarkHarvested(node)
    if node then node.harvested = time() end
end

function Data.IsAvailable(node)
    local db = NS.db
    if not (db and node.harvested) then return true end
    local minutes = db.respawnMinutes or 0
    if minutes <= 0 then return true end          -- the player turned this off
    return (time() - node.harvested) >= (minutes * 60)
end

-- Do we actually KNOW this is there, or are we going on memory?
--
-- Vignettes we can see -- the game is telling us about them right now. Anything
-- from the database is a story about the past. The renderers draw the stories
-- more faintly than the facts, which is the least we can do.
function Data.IsConfirmed(node)
    -- Two ways to actually KNOW, and they're the only two that exist.
    --
    --   vignette -- the engine is drawing it on the minimap, so it's there.
    --   live     -- the soft-interact target: the client just told us this is a
    --               real object you could reach out and gather. See Live.lua.
    --
    -- Everything else in this addon is memory: your gathers, GatherMate's dump.
    -- They are guesses, and they draw at unconfirmedAlpha because that is what an
    -- honest guess looks like.
    return node.vignette == true or node.live == true
end

-- ---------------------------------------------------------------------------
-- Recording, importing
-- ---------------------------------------------------------------------------

-- Record a gather at wherever the player is standing RIGHT NOW.
--
-- Core.lua deliberately doesn't use this: it parks the position at cast time and
-- commits it when the loot resolves, because by the time you've looted you've
-- usually drifted a few yards off the node. Still exported, because it's a
-- perfectly good helper -- just don't call it from a loot handler and then
-- wonder why your nodes are all slightly to the left.
function Data.RecordGatherAt(nodeType, id, name)
    if not (NS.db and NS.db.recordGathers) then return end
    local mapID, x, y = Data.GetPlayerPosition()
    if not mapID then return end
    local node, added = Data.AddNode(mapID, x, y, nodeType, id, name)
    Data.MarkHarvested(node)          -- you took it; it isn't there anymore
    if added and NS.db and NS.db.debug then
        NS.Printf("recorded %s at %.1f, %.1f",
            NS.NodeTypeLabel[nodeType] or nodeType, x * 100, y * 100)
    end
end

-- Pour someone else's map into ours. Shape:
--   seed[mapID] = { {x=, y=, type=, id=, name=}, ... }
-- Returns how many were genuinely new.
function Data.ImportSeed(seed)
    local count = 0
    for mapID, list in pairs(seed) do
        for _, n in ipairs(list) do
            local _, added = Data.AddNode(mapID, n.x, n.y, n.type, n.id, n.name)
            if added then count = count + 1 end
        end
    end
    return count
end

-- ---------------------------------------------------------------------------
-- Asking questions of it
-- ---------------------------------------------------------------------------

-- Does the player want to hear about this one? Type filter first, then the
-- per-node filter for people with opinions about specific herbs.
function Data.IsVisible(nodeType, id)
    local db = NS.db
    if not db then return true end
    if not db.typeEnabled[nodeType] then return false end
    if id ~= nil then
        local f = db.nodeFilter[nodeType]
        if f and f[id] == false then return false end
    end
    return true
end

-- Where is the nearest node we know of called this?
--
-- The soft-interact target tells us a "Tranquility Bloom" is really there, and
-- then flatly refuses to say where -- UnitPosition returns nil for a game object.
-- So somebody has to place it, and the obvious somebody is us: we have been
-- writing down where we picked things for as long as this addon has existed.
--
-- GatherMate can do this too, and can do it in a zone you've never farmed, which
-- is why Live asks it first. But it must not be the ONLY way -- an addon that
-- can't point at a herb unless you installed a second addon is an addon with a
-- dependency, whatever the .toc says.
function Data.LocateByName(mapID, px, py, name, maxYards)
    if not name then return nil end
    local zone = Data.nodes[mapID]
    if not zone then return nil end

    maxYards = maxYards or 60
    local best, bestDist
    for _, n in ipairs(zone) do
        if n.name == name then
            local d = Data.DistanceYards(mapID, px, py, n.x, n.y)
            if d and d <= maxYards and (not bestDist or d < bestDist) then
                best, bestDist = n, d
            end
        end
    end

    if not best then return nil end
    return best, bestDist, Data.Bearing(mapID, px, py, best.x, best.y)
end

-- Walk everything we know on this map, handing each one to fn as
--   fn(node, distanceYards, bearingRadians)
--
-- Note what gets applied HERE, at the source: the filters AND availability. A
-- node the player filtered out, or one they just picked, never leaves this
-- function. That's why no renderer downstream has to remember to check -- they
-- structurally cannot see a node the player didn't ask for. Keep it that way.
function Data.ForEachNearby(mapID, px, py, fn)
    local zone = Data.nodes[mapID]
    if not zone then return end
    for _, n in ipairs(zone) do
        if Data.IsVisible(n.type, n.id) and Data.IsAvailable(n) then
            local dist = Data.DistanceYards(mapID, px, py, n.x, n.y)
            local bearing = Data.Bearing(mapID, px, py, n.x, n.y)
            fn(n, dist, bearing)
        end
    end
end
