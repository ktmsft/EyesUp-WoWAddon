-- Eyes Up - Copyright (c) 2026 KTM (abitofmoss). All Rights Reserved.
-- No redistribution or reuse of this code or assets without permission. See LICENSE.
local addonName, NS = ...

-- =============================================================================
-- Live.lua
-- The only thing in this addon that can say YES.
--
-- Every other source is a memory. Your database remembers where a herb WAS.
-- GatherMate remembers where a herb HAS BEEN, thousands of times over. Neither
-- of them knows -- neither of them CAN know -- whether one is standing there
-- right now, and the client will not tell us. That's the founding limitation, and
-- three days of probing the API have only confirmed it: the minimap's tracking
-- blips are drawn by the engine and cannot be read, and no query exists.
--
-- With one exception. The soft-interact target.
--
-- Ask the client what your Interact key would grab, and it will tell you: a unit
-- token, "softinteract", which resolves to a real GameObject with a real name and
-- a real id. Not a memory. Not a guess. A herb that is actually there, right now,
-- and that you could actually pick.
--
-- WHAT IT COSTS
--
-- It reaches about fifteen to twenty-five yards. That's it. We asked for sixty
-- (SoftTargetInteractRange) and the engine ignored us, because a game object's
-- own interact distance governs -- measured repeatedly at 12.8, 13.1, 13.7, 13.9
-- yards, with some seed-matched readings out to ~25.
--
-- And it hands back exactly ONE object: the best candidate. A chair standing
-- nearer than a herb will mask the herb. There's no enumerating, no second place.
--
-- So this source is short-sighted and easily distracted, and it is the only
-- honest one we have. Everything it reports is true.
--
-- WHERE IS IT?
--
-- UnitPosition returns nil for a game object -- the engine names the thing but
-- won't place it. So we ask GatherMate: soft-target says "Tranquility Bloom", and
-- GatherMate knows where every Tranquility Bloom in the zone is. Nearest match
-- wins, and now we have a bearing and a distance for something we KNOW is there.
--
--     Soft-target says it is REAL.  GatherMate says WHERE.
--
-- Neither could do this alone, which is the whole reason both exist here.
--
-- If we can't place it (no GatherMate, or a species it's never heard of) we still
-- report the node -- we just report it as being right on top of you, which drops
-- the arrow and pulses instead. That's not a fudge, it's the honest rendering of
-- "it's here somewhere and I can't point".
-- =============================================================================

local Live = {}
NS.Live = Live

local Data = NS.Data
local Seed = NS.Seed

-- ---------------------------------------------------------------------------
-- The CVars, which are the price of admission.
--
-- Soft targeting must be ON (SoftTargetInteract 2 or 3) or "softinteract" never
-- resolves and this entire source is dead. Most players have it off.
--
-- So we turn it on -- and we are honest that this is somebody's game settings we
-- are touching. Arc 2 means the soft target can be BEHIND you, which is the whole
-- point (the thing you rode past without seeing is exactly the thing worth
-- mentioning). Range follows the detection slider -- see the long note on Enable
-- for why we ask for the full reach instead of assuming a cap.
--
-- We snapshot what was there before and put it back on logout. `db.manageSoftTarget`
-- turns the whole business off for anyone who'd rather set it themselves.
-- ---------------------------------------------------------------------------
local GetCVar = C_CVar and C_CVar.GetCVar or _G.GetCVar
local SetCVar = C_CVar and C_CVar.SetCVar or _G.SetCVar

local CVARS = { "SoftTargetInteract", "SoftTargetInteractArc", "SoftTargetInteractRange" }

local saved, held = {}, false

-- These three are PROTECTED CVars: they steer what your Interact key grabs, so the
-- client refuses to let an addon write them while you're in combat and shouts
-- ADDON_ACTION_BLOCKED instead. Reading is fine; only writing is barred.
--
-- Every write in this file goes through here, and every one of them is something we
-- can simply do later -- so in combat we drop the write, remember that we owe one,
-- and settle up the moment the fight ends. Nothing is lost; it just arrives late.
local deferred = false

local function writeCVar(name, value)
    if not SetCVar then return false end
    if InCombatLockdown and InCombatLockdown() then
        deferred = true
        return false
    end
    SetCVar(name, value)
    return true
end

function Live.Enable()
    if held or not SetCVar then return end
    if not (NS.db and NS.db.manageSoftTarget) then return end
    -- Snapshot first (reads are never blocked), but don't claim to be holding
    -- their settings until we've actually managed to change one.
    for _, c in ipairs(CVARS) do saved[c] = GetCVar(c) end
    if InCombatLockdown and InCombatLockdown() then deferred = true return end

    writeCVar("SoftTargetInteract", 3)    -- always on, not just for gamepads
    writeCVar("SoftTargetInteractArc", 2) -- any direction: the node you rode PAST
                                          -- is exactly the one worth mentioning

    -- ASK FOR THE FULL DETECTION RADIUS, and let the engine give what it will.
    --
    -- We measured game objects acquiring at 12-25 yards with this set to 60, and I
    -- concluded from that the CVar was doing nothing and stopped setting it. That
    -- was the wrong call twice over. First: if the engine ever WILL reach further
    -- -- for a node in the open with nothing competing, in a patch, on a different
    -- object -- then not asking guarantees we never find out. Second: the readings
    -- we have (12.8, 13.1, 13.7, 13.9, and seed-matched hits at 15.5 and 25) are
    -- not a flat line, which is not what a hard cap looks like.
    --
    -- So ask for everything, take whatever comes, and let the measurement tell us
    -- what the ceiling is instead of us imposing one. Costs nothing to ask.
    local want = (NS.db.detectionYards or 60)
    if want < 10 then want = 10 elseif want > 100 then want = 100 end
    writeCVar("SoftTargetInteractRange", want)

    held = true
end

-- The CVar follows the detection slider, so moving it actually reaches further
-- rather than just widening the circle we filter against.
function Live.SyncRange()
    if not (held and SetCVar and NS.db) then return end
    local want = NS.db.detectionYards or 60
    if want < 10 then want = 10 elseif want > 100 then want = 100 end
    writeCVar("SoftTargetInteractRange", want)
end

function Live.Restore()
    if not (held and SetCVar) then return end
    for _, c in ipairs(CVARS) do
        if saved[c] ~= nil then writeCVar(c, saved[c]) end
    end
    held = false
end

-- Settling up. Anything we couldn't write mid-fight gets written now -- and if we
-- never got to Enable at all (logged in straight into combat, which is what a
-- battleground start looks like), do the whole thing now.
local watcher = CreateFrame("Frame")
watcher:RegisterEvent("PLAYER_REGEN_ENABLED")
watcher:SetScript("OnEvent", function()
    if not deferred then return end
    deferred = false
    if held then Live.SyncRange() else Live.Enable() end
end)

-- Is soft targeting actually on, whoever turned it on? If this is false, mode
-- "confirmed" has nothing to work with and the cue will never fire -- which is a
-- thing worth being able to say out loud rather than leaving someone to wonder.
function Live.IsReady()
    local v = GetCVar and tonumber(GetCVar("SoftTargetInteract") or 0) or 0
    return v >= 2
end

-- ---------------------------------------------------------------------------
-- Is that a node, or a chair?
--
-- Soft-target offers EVERY interactable: herbs, ore, chests, doors, stools,
-- your own fishing bobber. Take them all and knownNodes fills up with furniture
-- -- which is precisely the mistake Vignettes.classify used to make, and the
-- reason the rule everywhere in here is blunt: an unrecognized thing is NOT A NODE.
--
-- Same rule here, and the same default: unknown means ignore.
--
-- The classifier is GatherMate's own species list, which we already have loaded.
-- It knows "Tranquility Bloom" is a herb and has a number for it. It has never
-- heard of "Stool". That single lookup gives us the type AND an identity that
-- matches what the seed and the database already use, for free.
-- ---------------------------------------------------------------------------
-- One table lookup, and it's ours.
--
-- This used to interrogate GatherMate's species list, which meant an addon that
-- couldn't tell a herb from a stool unless you'd installed a second addon. It's
-- a flat generated table now (Species.lua) -- every gathering node in the game,
-- every name it can wear -- so the classifier depends on nothing, works on a
-- clean install, and knows "Lightfused Tranquility Bloom" is a Tranquility Bloom.
local function classify(name)
    if not name then return nil end

    local s = NS.SpeciesByName[name]
    if s then return s.type, s.id end

    -- Learned the hard way: you cast Mining at it, so it's a mine, whatever the
    -- table says. Covers anything a patch adds before Species.lua is regenerated.
    local learned = NS.db and NS.db.objectType and NS.db.objectType[name]
    if learned then return learned, nil end

    return nil                    -- a stool. Not a node. Default to ignoring.
end

Live.Classify = classify

-- Called from Core when you gather: whatever you were soft-targeting at the
-- moment of the cast IS the thing you just gathered, and the spell says what kind
-- it was. That's how a species the table doesn't know yet gets classified.
function Live.Learn(nodeType)
    local name = Live.CurrentName()
    if not (name and nodeType and NS.db) then return end
    if classify(name) then return end          -- already known; nothing to learn

    NS.db.objectType = NS.db.objectType or {}
    NS.db.objectType[name] = nodeType
end

-- What species is the thing you're soft-targeting right now? (type, id, name)
-- Core asks this at cast time -- that's the moment we KNOW which node you're
-- gathering, and it's what stops item ids ever entering the filter list again.
function Live.CurrentSpecies()
    local name = Live.CurrentName()
    if not name then return nil end
    local nodeType, id = classify(name)
    if not (nodeType and id) then return nil end
    local s = NS.Species[nodeType] and NS.Species[nodeType][id]
    return nodeType, id, s and s.name or name
end

-- ---------------------------------------------------------------------------
-- Reading the soft target
--
-- NOT UnitExists("softinteract"). That returns FALSE for a game object even while
-- UnitGUID, UnitName and UnitIsGameObject all answer perfectly about the herb in
-- front of you -- a GameObject is not a "unit" in the sense UnitExists means.
-- Gating on it silently makes this whole file a no-op, which cost a farming lap
-- to discover once already. The GUID is the existence test.
-- ---------------------------------------------------------------------------
-- Is this value safe to USE -- as a table key, in a comparison, printed?
--
-- 12.0 hides object identities in instanced content (delves, dungeons) behind
-- "secret" values. The subtlety that bit us: Secret_CanAccess only says whether
-- you may READ a value; a value can be readable and STILL be a secret type that
-- errors the instant you index a table with it or compare it. issecretvalue is
-- the real test. If it's a secret, we treat it as unusable -- Live simply reports
-- nothing in a delve, which is correct: there's nothing to gather in there.
local issecretvalue = _G.issecretvalue

local function canRead(v)
    if v == nil then return false end
    if issecretvalue and issecretvalue(v) then return false end
    return true
end

function Live.CurrentName()
    local guid = UnitGUID("softinteract")
    if not canRead(guid) then return nil end
    local name = UnitName("softinteract")
    if not canRead(name) then return nil end
    return name, guid
end

-- ---------------------------------------------------------------------------
-- Stable tables, by GUID.
--
-- The cue asks "did the nearest node CHANGE?" to decide whether to ping and
-- whether to re-resolve the icon, and that question is only cheap if a node is
-- the same Lua table tick after tick. That's node identity, and every source in
-- this addon owes it: the table IS the key, so the check stays a pointer compare.
--
-- The GUID is the stable per-instance identity of a game object in front of you --
-- unlike the object id, which two herbs of the same species share.
-- ---------------------------------------------------------------------------
local cache = {}
local cacheGUID = nil

local function nodeFor(guid, nodeType, id, name)
    if cacheGUID ~= guid then
        cache = {}
        cacheGUID = guid
    end
    local n = cache[guid]
    if not n then
        n = { type = nodeType, id = id, name = name, live = true }
        cache[guid] = n
    end
    n.type, n.id, n.name = nodeType, id, name
    return n
end

-- ---------------------------------------------------------------------------
-- The contract
--
--   fn(node, distanceYards, bearingRadians)
--
-- Same signature as every other source, so Scan hands us the same `consider` and
-- never has to know which of us is which. At most ONE node, ever -- that's not a
-- limitation of this code, it's what the API gives.
-- ---------------------------------------------------------------------------
function Live.ForEachNearby(mapID, px, py, fn)
    local worldName, guid = Live.CurrentName()
    if not worldName then return end

    local nodeType, id = classify(worldName)
    if not nodeType then return end                       -- a chair. Not our business.
    if not Data.IsVisible(nodeType, id) then return end   -- filters, at the source

    -- The world calls it "Lightfused Tranquility Bloom". Everything else in this
    -- addon -- the database, the seed data, the filter list -- calls it
    -- "Tranquility Bloom", because they are the same plant. Collapse to the base
    -- name HERE, or the position lookup below searches for a name nothing was ever
    -- stored under and the cue can never point at anything.
    local s = id and NS.Species[nodeType] and NS.Species[nodeType][id]
    local name = (s and s.name) or worldName

    local node = nodeFor(guid, nodeType, id, name)

    -- Where is it? The engine won't say, so somebody has to place it.
    --
    -- Ask our OWN database first -- it's ours, it's always there, and if you've
    -- picked one of these before we know exactly where they stand. Then ask
    -- GatherMate, which can place a species in a zone you've never farmed but
    -- which the player may not have installed and must never be REQUIRED to.
    --
    -- Whichever answers, we end up with a real distance and a real bearing for
    -- something we KNOW is standing there. That's the best answer this addon is
    -- capable of giving, and it doesn't depend on anything.
    -- Search as far as the player's detection radius, not some number I typed in.
    -- If soft-target ever hands us something at fifty yards, we must be able to
    -- place it -- capping the ruler shorter than the thing being measured would
    -- silently throw away exactly the readings we care most about.
    local reach = (NS.db and NS.db.detectionYards) or 60

    local dist, bearing
    local found, d, b = Data.LocateByName(mapID, px, py, name, reach)
    if not found and Seed then
        found, d, b = Seed.LocateByName(mapID, px, py, name, reach)
    end
    if found then
        dist, bearing = d, b
        node.x, node.y = found.x, found.y
    end

    if not dist then
        -- Couldn't place it. Rather than drop a node we KNOW is real, report it as
        -- being right on top of you: inside closeRange the cue drops the arrow and
        -- pulses, which is exactly the right picture for "it's here, I can't point".
        dist = ((NS.db and NS.db.closeYards) or 10) * 0.5
        bearing = 0
    end

    fn(node, dist, bearing)
end
