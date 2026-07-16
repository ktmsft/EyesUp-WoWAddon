local addonName, NS = ...

-- =============================================================================
-- Seed.lua
-- A third node source: somebody else's map, if they left one lying around.
--
-- THE PROBLEM THIS SOLVES
--
-- Eyes Up knew nothing about a zone until you had farmed it. Fly into a fresh
-- Midnight zone and the cue was silent -- not because there was nothing there,
-- but because we hadn't been there. The addon that tells you what's nearby told
-- you nothing, on the exact day you most needed it.
--
-- The data exists. GatherMate2_Data is a Wowhead dump of node positions, kept up
-- to date and already Midnight-ready (3,421 nodes in Zul'Aman alone). If the
-- player has it installed, we read it and the cue works from the first minute.
--
-- WE ARE NOT BECOMING GATHERMATE. GatherMate paints every node in the zone onto
-- your map and your minimap -- a treasure map, which is precisely what this addon
-- exists not to be. We use the same fuel to answer a much smaller question: is
-- there one thing, within sixty yards, that you'd regret flying past. Same data,
-- opposite product. The restraint lives in the detection radius and the focus
-- lock -- never in being ignorant of where the herbs are.
--
-- WE BUNDLE NOTHING. GatherMate2 is GPL; we ship none of its code and none of its
-- data. We read the global tables it defines IF they are already on the player's
-- disk, which is the same courtesy this addon used to extend to HereBeDragons.
-- Nothing here is required, and nothing here is redistributed.
--
-- IDENTITY: THE NODE, NOT THE ITEM
--
-- This is the part worth reading twice, because it changed how the filter list
-- works.
--
-- The addon used to identify a node by THE ITEM IT DROPPED -- you gathered a
-- herb, the loot said "Mycobloom", and that item's id became the node's identity.
-- Which meant a species didn't exist, as far as the filter list was concerned,
-- until you had personally picked one. It also meant mining showed up under the
-- name of its ore ("Copper Ore") rather than the thing you actually see in the
-- world ("Copper Vein"), which are not the same word and never were.
--
-- A node is now identified the way the world identifies it: by SPECIES. Every
-- one of them, its name, and its expansion is written down in Species.lua -- so
-- the filter list fills in with every species in the zone you just flew into,
-- before you gather anything, and it needs no addon installed to do it.
--
-- The seed data is keyed on those same species numbers, which is the only reason
-- this file can read it at all. But the NAMES, the TYPES and the EXPANSIONS are
-- ours. The one thing we want from GatherMate is coordinates.
--
-- The item is demoted to what it always really was: ART. It is stored as
-- `node.item` and used for one thing, drawing the icon, once you've picked one.
--
--     GatherMate says WHERE it is.
--     Your own gathers say WHAT IT LOOKS LIKE, and refine where.
--
-- ONE TABLE PER NODE, ALWAYS
--
-- The trap here is duplicates. GatherMate has a herb at X; you pick it, and your
-- own database records a herb at X too. Now two node tables describe one plant --
-- the cue picks whichever is momentarily nearest and its icon flickers between
-- real item art and a generic glyph, and hushing one leaves the other cheerfully
-- pointing at the hole you're standing over.
--
-- So a seeded node steps aside the moment we have our own record of it:
-- `Seed.Supersede` on gather, and a prune at index time for the ones you recorded
-- in an earlier session. Exactly one table describes any given plant.
-- =============================================================================

local Seed = {}
NS.Seed = Seed

local Data = NS.Data

local floor, min, ceil = math.floor, math.min, math.ceil

-- GatherMate's globals, our node type, and GatherMate's own name for the
-- profession (which is the key into its name lookup -- "Herb Gathering", not
-- "Herb", and "Logging", not "Timber").
--
-- The TYPE comes from WHICH TABLE a node was in, so we never have to interpret a
-- GatherMate node id to know what it is.
--
-- (The file is TimberData.lua but the global it defines is
-- GatherMateData2LoggingDB. Guess wrong and you silently get no lumber at all,
-- with no error to tell you why.)
local SOURCES = {
    { global = "GatherMateData2HerbDB",     type = NS.NodeType.HERB,     prof = "Herb Gathering" },
    { global = "GatherMateData2MineDB",     type = NS.NodeType.MINE,     prof = "Mining" },
    { global = "GatherMateData2LoggingDB",  type = NS.NodeType.LUMBER,   prof = "Logging" },
    { global = "GatherMateData2FishDB",     type = NS.NodeType.FISHING,  prof = "Fishing" },
    { global = "GatherMateData2TreasureDB", type = NS.NodeType.TREASURE, prof = "Treasure" },
}

-- ---------------------------------------------------------------------------
-- Getting at it
--
-- GatherMate2_Data is LoadOnDemand, so its globals don't exist until somebody
-- asks. Usually GatherMate2 will already have done so; if not, we ask, once.
--
-- Tri-state and cached: nil = haven't tried, false = not there, true = we have
-- it. Once only, because the answer can't change mid-session and a failed
-- LoadAddOn on every tick is a fine way to ruin someone's framerate.
-- ---------------------------------------------------------------------------
local available = nil

local function ensure()
    if available ~= nil then return available end

    if not _G.GatherMateData2HerbDB then
        local load = C_AddOns and C_AddOns.LoadAddOn or _G.LoadAddOn
        if load then pcall(load, "GatherMate2_Data") end
    end

    available = _G.GatherMateData2HerbDB ~= nil
    return available
end

function Seed.IsAvailable()
    return ensure()
end

-- The species name for a node id.
--
-- This used to ask the GatherMate2 addon. It doesn't need to: the seed data is
-- keyed on species numbers, and we have our own table of every species in the
-- game (Species.lua). So the only thing we now want from GatherMate is the
-- POSITIONS -- names, types and expansions are ours.
local function speciesName(nodeType, nodeID)
    local s = NS.Species[nodeType] and NS.Species[nodeType][nodeID]
    return s and s.name or nil
end

-- ---------------------------------------------------------------------------
-- The coordinate packing
--
-- GatherMate stores a point as one 10-digit number, XXXXYYYY00 -- each half the
-- coordinate as a percentage to two decimals. So 0.3560, 0.3430 is 3560343000.
-- Unpack to the normalized 0..1 map coords every other node in this addon speaks.
-- ---------------------------------------------------------------------------
local function unpackCoord(c)
    local x = floor(c / 1000000)
    local y = floor((c % 1000000) / 100)
    return x / 10000, y / 10000
end

-- ---------------------------------------------------------------------------
-- The index, and why there is one
--
-- The dumps are big -- two megabytes of herbs -- and a busy zone holds thousands
-- of nodes (3,421 in Zul'Aman). Scan runs twenty times a second, forever, so
-- walking the whole zone list per tick -- which is what Data.ForEachNearby does,
-- and gets away with, because YOUR database holds dozens -- would be an actual
-- framerate cost.
--
-- So we bucket the zone into a coarse grid, once, the first time we scan in it,
-- and visit only the cells that could hold something within detection range. A
-- cell is 0.02 of the map, comfortably wider than sixty yards in any real zone,
-- so a tick looks at nine cells and about a dozen nodes.
--
-- Node tables built here are STABLE and never rebuilt, which is the contract
-- every source owes (CLAUDE.md, "Node identity"): the table IS the identity key,
-- so Scan's stickiness and the cue's don't-re-resolve-the-icon check stay pointer
-- compares.
-- ---------------------------------------------------------------------------
local CELL = 0.02
local grids = {}          -- grids[mapID] = { [cellKey] = { node, ... } }

local function cellKey(cx, cy)
    return cx * 128 + cy
end

-- Do we already have our OWN record of this node? If so the seeded copy must not
-- exist -- ours is better (it knows what the thing drops) and two tables for one
-- plant is the duplicate bug in the header.
--
-- Bucketed on the same grid as everything else, because the naive version -- ask
-- this of all 3,421 seeded nodes, and have each one walk your whole zone list --
-- is thousands times hundreds of distance calculations in a single frame, on the
-- loading screen, which you would feel.
local function indexPlayerNodes(mapID)
    local zone = Data.nodes[mapID]
    if not zone or #zone == 0 then return nil end     -- never farmed here: nothing to prune

    local cells = {}
    for _, n in ipairs(zone) do
        local k = cellKey(floor(n.x / CELL), floor(n.y / CELL))
        local bucket = cells[k]
        if not bucket then
            bucket = {}
            cells[k] = bucket
        end
        bucket[#bucket + 1] = n
    end
    return cells
end

local function playerAlreadyHas(pcells, mapID, x, y, nodeType, dedupe)
    if not pcells then return false end
    local cx0, cy0 = floor(x / CELL), floor(y / CELL)
    for cx = cx0 - 1, cx0 + 1 do
        for cy = cy0 - 1, cy0 + 1 do
            local bucket = pcells[cellKey(cx, cy)]
            if bucket then
                for i = 1, #bucket do
                    local n = bucket[i]
                    if n.type == nodeType then
                        local d = Data.DistanceYards(mapID, x, y, n.x, n.y)
                        if d and d <= dedupe then return true end
                    end
                end
            end
        end
    end
    return false
end

local function build(mapID)
    local cells = {}
    local total, pruned = 0, 0
    local dedupe = (NS.db and NS.db.dedupeYards) or 15
    local pcells = indexPlayerNodes(mapID)

    for _, src in ipairs(SOURCES) do
        local db = _G[src.global]
        local zone = db and db[mapID]
        if zone then
            for coord, nodeID in pairs(zone) do
                local x, y = unpackCoord(coord)

                if playerAlreadyHas(pcells, mapID, x, y, src.type, dedupe) then
                    pruned = pruned + 1
                else
                    local name = speciesName(src.type, nodeID)

                    -- The species goes into the filter list whether or not you've
                    -- ever gathered one. This is the whole point: fly into a zone
                    -- and its herbs are immediately things you can say no to.
                    Data.NoteKnown(src.type, nodeID, name)

                    local node = {
                        x = x, y = y,
                        type = src.type,
                        id   = nodeID,     -- GatherMate's node id. NOT an item id.
                        name = name,
                        seeded = true,     -- ...which is how Cue knows not to feed
                                           -- `id` to GetItemIconByID and draw a
                                           -- picture of some unrelated item.
                    }

                    local k = cellKey(floor(x / CELL), floor(y / CELL))
                    local bucket = cells[k]
                    if not bucket then
                        bucket = {}
                        cells[k] = bucket
                    end
                    bucket[#bucket + 1] = node
                    total = total + 1
                end
            end
        end
    end

    grids[mapID] = cells
    if NS.db and NS.db.debug then
        NS.Printf("seed: indexed %d nodes on map %d (%d already ours)", total, mapID, pruned)
    end
    return cells
end

-- Nothing to import, and nothing for the player to remember to do: the index for
-- a zone is built the first time we scan in it and then reused. This exists so
-- Core can warm it on PLAYER_ENTERING_WORLD / zone change and take the (small)
-- build cost off the first scan tick rather than mid-flight.
function Seed.Prepare(mapID)
    if not (NS.db and NS.db.seedEnabled) then return end
    if not ensure() then return end
    if not mapID or grids[mapID] then return end
    build(mapID)
end

-- Throw away the index for a map so it rebuilds -- used after the player's own
-- database changes enough that the prune above would come out differently.
function Seed.Invalidate(mapID)
    if mapID then grids[mapID] = nil else wipe(grids) end
end

-- ---------------------------------------------------------------------------
-- The contract
--
--   fn(node, distanceYards, bearingRadians)
--
-- Identical to Data.ForEachNearby and Vignettes.ForEachOnMap, and for the same
-- reason: Scan hands one `consider` to all three and never has to know which is
-- which. Filters are applied HERE, at the source, so a filtered-out node
-- structurally cannot reach a renderer.
-- ---------------------------------------------------------------------------
local function eachInRange(mapID, px, py, fn)
    local db = NS.db
    local cells = grids[mapID] or build(mapID)

    -- How far out do we look? Detection range is yards; the grid is map
    -- fractions. Convert on the SMALLER axis, which makes the ring count
    -- conservative -- an extra empty bucket is free, a missed node isn't.
    local w, h = Data.MapSize(mapID)
    local rangeNorm = (db.detectionYards or 60) / min(w, h)
    local rings = ceil(rangeNorm / CELL)

    local cx0, cy0 = floor(px / CELL), floor(py / CELL)

    for cx = cx0 - rings, cx0 + rings do
        for cy = cy0 - rings, cy0 + rings do
            local bucket = cells[cellKey(cx, cy)]
            if bucket then
                for i = 1, #bucket do
                    local n = bucket[i]
                    if not n.superseded
                       and Data.IsVisible(n.type, n.id)
                       and Data.IsAvailable(n) then
                        fn(n,
                           Data.DistanceYards(mapID, px, py, n.x, n.y),
                           Data.Bearing(mapID, px, py, n.x, n.y))
                    end
                end
            end
        end
    end
end

function Seed.ForEachNearby(mapID, px, py, fn)
    if not (NS.db and NS.db.seedEnabled) then return end
    if not ensure() then return end
    eachInRange(mapID, px, py, fn)
end

-- ---------------------------------------------------------------------------
-- "That one's mine now."
--
-- You gathered a node GatherMate also knew about. From here on OUR record is the
-- better one -- it knows what the thing drops, so it can show real art -- and the
-- seeded copy must get out of the way, permanently, or we're back to two tables
-- for one plant: an icon that flickers as you step between them, and a husk that
-- keeps pointing at the hole you're standing over after the other has been hushed.
--
-- Returns the seeded node's species id and name if it found one, so the caller
-- can adopt them -- which is how a gathered node gets to be a "Copper Vein"
-- instead of a "Copper Ore".
-- ---------------------------------------------------------------------------
local function nearestSeeded(mapID, x, y, nodeType)
    local cells = grids[mapID]
    if not cells then return nil end

    local dedupe = (NS.db and NS.db.dedupeYards) or 15
    local best, bestDist
    local cx0, cy0 = floor(x / CELL), floor(y / CELL)

    for cx = cx0 - 1, cx0 + 1 do
        for cy = cy0 - 1, cy0 + 1 do
            local bucket = cells[cellKey(cx, cy)]
            if bucket then
                for i = 1, #bucket do
                    local n = bucket[i]
                    if n.type == nodeType and not n.superseded then
                        local d = Data.DistanceYards(mapID, x, y, n.x, n.y)
                        if d and d <= dedupe and (not bestDist or d < bestDist) then
                            best, bestDist = n, d
                        end
                    end
                end
            end
        end
    end
    return best
end

-- What species is the node at this spot, according to GatherMate? (id, name)
function Seed.IdentifyNear(mapID, x, y, nodeType)
    if not (NS.db and NS.db.seedEnabled and ensure()) then return nil end
    local n = nearestSeeded(mapID, x, y, nodeType)
    if not n then return nil end
    return n.id, n.name
end

-- Stand down: we have our own record of this one now.
function Seed.Supersede(mapID, x, y, nodeType)
    if not (NS.db and NS.db.seedEnabled and ensure()) then return end
    local n = nearestSeeded(mapID, x, y, nodeType)
    if n then n.superseded = true end
end

-- ---------------------------------------------------------------------------
-- Putting a soft-target name on the map.
--
-- Soft-target tells us WHAT is near ("Tranquility Bloom") but flatly refuses to
-- say where -- UnitPosition returns nil for a game object. GatherMate knows where
-- every Tranquility Bloom in the zone is. Put the two together and the live cue
-- can point an arrow at the thing soft-target just found, the instant it happens,
-- with no walking and no gathering. This is how Live.lua turns a name into a
-- direction.
--
-- Searches a little WIDER than detection range on purpose: soft-target can acquire
-- something a hair past our radius, and we'd rather find its position and let the
-- distance filter decide than miss it for being one yard long.
-- ---------------------------------------------------------------------------
function Seed.LocateByName(mapID, px, py, name, maxYards)
    if not (name and ensure()) then return nil end
    local cells = grids[mapID]
    if not cells then return nil end

    maxYards = maxYards or 200
    local w, h = Data.MapSize(mapID)
    local rings = ceil((maxYards / min(w, h)) / CELL)

    local best, bestDist
    local cx0, cy0 = floor(px / CELL), floor(py / CELL)

    for cx = cx0 - rings, cx0 + rings do
        for cy = cy0 - rings, cy0 + rings do
            local bucket = cells[cellKey(cx, cy)]
            if bucket then
                for i = 1, #bucket do
                    local n = bucket[i]
                    if n.name == name then
                        local d = Data.DistanceYards(mapID, px, py, n.x, n.y)
                        if d and d <= maxYards and (not bestDist or d < bestDist) then
                            best, bestDist = n, d
                        end
                    end
                end
            end
        end
    end

    if not best then return nil end
    return best, bestDist, Data.Bearing(mapID, px, py, best.x, best.y)
end

-- ---------------------------------------------------------------------------
-- Diagnostics, for /eu seed
-- ---------------------------------------------------------------------------
function Seed.CountOnMap(mapID)
    if not ensure() then return nil end
    local n = 0
    for _, src in ipairs(SOURCES) do
        local db = _G[src.global]
        local zone = db and db[mapID]
        if zone then
            for _ in pairs(zone) do n = n + 1 end
        end
    end
    return n
end

-- How many seeded nodes are within detection range RIGHT NOW -- i.e. how many the
-- cue could actually be reacting to. This is the number to look at when the cue
-- seems quiet and you want to know whether that's a bug or simply an empty field.
function Seed.CountInRange(mapID, px, py)
    if not (ensure() and NS.db and NS.db.seedEnabled) then return 0 end
    local range = NS.db.detectionYards or 60
    local n = 0
    eachInRange(mapID, px, py, function(_, dist)
        if dist and dist <= range then n = n + 1 end
    end)
    return n
end
