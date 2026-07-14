local addonName, NS = ...

-- =============================================================================
-- Core.lua
-- Last to load, first to blame.
--
-- This is the part that wakes everything up: loads your saved variables, listens
-- for the events that matter, teaches the game what /eu means, and then gets out
-- of the way. It assumes every other file already exists, which is why it's last
-- in the .toc and must stay there.
-- =============================================================================

local Data = NS.Data

-- There are two renderers now, and every setting that MOVES something -- lock,
-- position, size, color -- has to reach both of them. Fan out here, once, so no
-- call site has to remember. Forget this and "Lock position" mysteriously stops
-- applying to one of them.
local function applyLayouts()
    if NS.Overlay then NS.Overlay.ApplyLayout() end
    if NS.Cue then NS.Cue.ApplyLayout() end
    -- The detection slider isn't only a filter -- it's how far we ASK the engine
    -- to soft-target. Drag it and the reach really changes, rather than merely
    -- widening the circle we discard things against.
    if NS.Live then NS.Live.SyncRange() end
end
NS.ApplyLayouts = applyLayouts

-- Fill in anything the player's saved table is missing, recursively. This is the
-- entire update story: add a key to NS.defaults, and every existing character
-- quietly grows it on next login. It never removes and never renames.
local function applyDefaults(dst, src)
    for k, v in pairs(src) do
        if type(v) == "table" then
            if type(dst[k]) ~= "table" then dst[k] = {} end
            applyDefaults(dst[k], v)
        elseif dst[k] == nil then
            dst[k] = v
        end
    end
    return dst
end

local function spellName(spellID)
    if C_Spell and C_Spell.GetSpellInfo then
        local info = C_Spell.GetSpellInfo(spellID)
        return info and info.name
    end
    return (GetSpellInfo(spellID))
end

-- =============================================================================
-- Watching you gather
--
-- There is no "you gathered a node" event. There are two half-events, and
-- neither is enough on its own:
--
--   the CAST tells us what KIND of thing it was  (herb? ore? we know)
--   the LOOT tells us WHICH thing it was         (Mycobloom -- but from what?)
--
-- So we bridge them. A gather cast parks a `pending` note -- what, and where you
-- were standing -- and the loot that follows fills in the blank and commits it.
--
-- That item id is what earns a node a name and a face: it's why the cue can show
-- you an actual picture of the herb, and why the filter list says "Mycobloom"
-- instead of "some plant, id 12345".
-- =============================================================================

-- How long loot has to claim a cast, and how long until we give up. Fishing gets
-- its own, much longer answer to both -- see NS.PendingWindow.
local function pendingWindow(nodeType)
    return NS.PendingWindow[nodeType] or NS.PendingWindow.default
end
local function fallbackDelay(nodeType)
    return NS.PendingFallback[nodeType] or NS.PendingFallback.default
end

local pending           -- { type, mapID, x, y, t, seq } or nil
local pendingSeq = 0    -- lets the fallback timer know if it's been beaten to it
local lootHandled = false  -- one commit per loot, please

local LOOT_SLOT_ITEM_TYPE = LOOT_SLOT_ITEM or 1

-- Write down the parked note. id/name may be nil -- see the fallback below.
--
-- Everything goes through Data.AddNode: the dedupe, the backfill, the NoteKnown
-- that feeds the filter list. One write path, not three.
local function commitPending(id, name)
    local p = pending
    pending = nil
    if not p then return end

    -- WHO is this node?
    --
    -- The loot tells us what it DROPPED ("Copper Ore"). We want to know what it
    -- IS ("Copper Vein") -- the thing you see in the world, and the thing you'd
    -- want to filter on.
    --
    -- The species was resolved at CAST time (beginPending), because that's the
    -- only moment we can: you were soft-targeting the node, so the game told us
    -- its name, and Species.lua turns that name -- variant and all -- into one
    -- species. By loot time the node has despawned and the moment is gone.
    --
    -- ONLY A SPECIES ID EVER BECOMES A NODE'S IDENTITY. Never an item id. That is
    -- the rule that fixes the duplicate: the filter list used to hold both, and
    -- since a herb's item shares its node's name, "Tranquility Bloom" appeared
    -- twice with two independent checkboxes. If we can't name the species we
    -- record the node type-only -- which is a thing this addon has always been
    -- able to do -- rather than reaching for the item id and poisoning the list.
    local sID, sName = p.species, p.speciesName

    -- Fallback: GatherMate had a node at this exact spot, so we know what species
    -- stands here even if soft-targeting was off.
    if not sID then
        sID, sName = NS.Seed.IdentifyNear(p.mapID, p.x, p.y, p.type)
    end

    local node, added = Data.AddNode(p.mapID, p.x, p.y, p.type, sID, sName)

    -- The item, kept for its art. Never for its identity.
    if id then node.item = id end

    -- Now we know what this SPECIES looks like -- so every other one of them,
    -- including live soft-target nodes that have never been in your bags, can
    -- stop showing a generic leaf and show the real thing.
    if sID and id and NS.db.speciesItem then
        NS.db.speciesItem[p.type] = NS.db.speciesItem[p.type] or {}
        NS.db.speciesItem[p.type][sID] = id
    end

    -- And GatherMate's copy of this node steps aside for good -- ours is better,
    -- and two tables for one plant is a flickering icon and a resurrected husk.
    NS.Seed.Supersede(p.mapID, p.x, p.y, p.type)

    -- And immediately hush it. You JUST took this node; it is definitively not
    -- there anymore. Without this the cue would spin round and point proudly at
    -- the hole in the ground you're still standing over.
    --
    -- Unless it's a fishing pool -- which is still very much there, and which
    -- you're presumably standing next to, casting into. Hushing it would be a
    -- strange way to thank you for finding it.
    local persists = NS.PersistsAfterUse[p.type]
    if not persists then
        Data.MarkHarvested(node)
    end

    if NS.db and NS.db.debug then
        NS.Printf("%s %s at %.1f, %.1f%s%s",
            added and "learned" or "refined",
            NS.NodeTypeLabel[p.type] or p.type,
            p.x * 100, p.y * 100,
            id and (" -> " .. tostring(name or id)) or " (no item id)",
            persists and "" or (" (quiet for %d min)"):format(NS.db.respawnMinutes or 0))
    end
end

-- Did this loot come off a node, or off something you killed?
--
-- Node loot comes from a GameObject. Corpse loot comes from a Creature. Without
-- this check, killing a boar within a second and a half of picking a herb would
-- steal the herb's record and file the boar's meat as a plant.
local function lootIsFromObject()
    if not GetLootSourceInfo then return true end   -- can't tell; give it the benefit
    for i = 1, GetNumLootItems() do
        local guid = GetLootSourceInfo(i)
        if guid then
            local kind = strsplit("-", guid)
            if kind == "GameObject" then return true end
            if kind == "Creature" or kind == "Vehicle" or kind == "Player" then
                return false
            end
        end
    end
    return true
end

-- The itemID behind a loot slot: the instant (no-network) lookup first, then
-- reading it straight out of the link.
local function lootSlotItemID(slot)
    local link = GetLootSlotLink(slot)
    if not link then return nil end
    if C_Item and C_Item.GetItemInfoInstant then
        local itemID = C_Item.GetItemInfoInstant(link)
        if itemID then return itemID end
    end
    return tonumber(link:match("item:(%d+)"))
end

-- What the node actually gave you. Gathers can drop bonus bits and pieces, but
-- the node's own product is the first real item slot.
local function primaryLootItem()
    for i = 1, GetNumLootItems() do
        local isItem = true
        if GetLootSlotType then
            isItem = (GetLootSlotType(i) == LOOT_SLOT_ITEM_TYPE)
        end
        if isItem then
            local itemID = lootSlotItemID(i)
            if itemID then
                local _, lootName = GetLootSlotInfo(i)
                return itemID, lootName
            end
        end
    end
    return nil
end

local function onLoot()
    if not pending then return end
    if lootHandled then return end
    -- Too old to belong to this cast. Let the fallback timer sort it out.
    -- (A fishing cast gets a very long leash here: the fish takes its time.)
    if (GetTime() - pending.t) > pendingWindow(pending.type) then return end
    -- Something you killed. Leave the note alone; it's not for you.
    if not lootIsFromObject() then return end

    local itemID, itemName = primaryLootItem()
    if itemID then
        lootHandled = true
        commitPending(itemID, itemName)
    end
end

-- Park a note at wherever you're standing right now.
--
-- Now, at cast time -- NOT at loot time. By the time the loot window opens you've
-- usually drifted a few yards, and a database full of nodes that are all slightly
-- northwest of where they really are is worse than useless.
local function beginPending(nodeType)
    -- Whatever you're soft-targeting at the instant you start the cast IS the
    -- thing you're gathering, and the spell just told us what kind it is. Both of
    -- the things we do with that have to happen HERE, at cast time -- by the time
    -- the loot arrives the node has despawned and the game has forgotten it:
    --
    --   1. LEARN it, if Species.lua has never heard of this name.
    --   2. RESOLVE the species, so the node we're about to write down is a
    --      "Copper Vein" and not a "Copper Ore".
    NS.Live.Learn(nodeType)
    local sType, sID, sName = NS.Live.CurrentSpecies()

    if not (NS.db and NS.db.recordGathers) then return end
    local mapID, x, y = Data.GetPlayerPosition()
    if not mapID then return end

    -- An old note still sitting here means its loot never came. Write it down
    -- type-only rather than dropping it on the floor as we overwrite it.
    if pending then commitPending(nil, nil) end

    -- A new cast means a new loot session. Resetting here (as well as on
    -- LOOT_CLOSED) means a missing LOOT_CLOSED can't wedge this flag and starve
    -- every future gather of its item id.
    lootHandled = false

    pendingSeq = pendingSeq + 1
    local seq = pendingSeq
    pending = {
        type = nodeType, mapID = mapID, x = x, y = y, t = GetTime(), seq = seq,
        -- Only trust the soft-target's species if it agrees with the spell about
        -- what KIND of thing this is. Cast Mining while standing next to a herb
        -- and we'd otherwise file the ore under the herb's name.
        species     = (sType == nodeType) and sID or nil,
        speciesName = (sType == nodeType) and sName or nil,
    }

    -- The fallback, and it's deliberate: if no loot ever resolves -- an
    -- interrupted cast, an empty node, a client that never opens a loot window --
    -- we still write the node down, just without an id. Losing a node you
    -- actually gathered is a worse outcome than storing one you can't filter by
    -- species.
    C_Timer.After(fallbackDelay(nodeType), function()
        if pending and pending.seq == seq then
            commitPending(nil, nil)
        end
    end)
end

-- ---------------------------------------------------------------------------
-- Waking up
-- ---------------------------------------------------------------------------
local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
ev:RegisterEvent("LOOT_READY")
ev:RegisterEvent("LOOT_OPENED")
ev:RegisterEvent("LOOT_CLOSED")

-- Zone changes, so the seed index for the new map is built the moment you arrive
-- rather than during the first scan tick after it. There is no "import" step and
-- nothing for the player to run: flying into a zone is the trigger.
ev:RegisterEvent("ZONE_CHANGED_NEW_AREA")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")

-- Soft targeting is somebody's game setting and we borrow it. Give it back.
ev:RegisterEvent("PLAYER_LOGOUT")

ev:SetScript("OnEvent", function(_, event, ...)
    if event == "ADDON_LOADED" then
        local loaded = ...
        if loaded ~= addonName then return end

        EyesUpDB = EyesUpDB or {}

        -- This addon used to be called NodeSight. If a player brought their old
        -- saved-variables file across (see the README), adopt it whole rather
        -- than making them re-gather half a continent. Runs once: after this,
        -- EyesUpDB has content and we never look back.
        if not next(EyesUpDB) and type(_G.NodeSightDB) == "table" then
            EyesUpDB = _G.NodeSightDB
            NS.migrated = true
        end

        applyDefaults(EyesUpDB, NS.defaults)
        EyesUpDB.nodes = EyesUpDB.nodes or {}
        NS.db = EyesUpDB
        Data.nodes = EyesUpDB.nodes        -- these tables ARE the saved data now

        -- ---------------------------------------------------------------------
        -- One-time: the filter list changed what it identifies things BY.
        --
        -- It used to key on the item a node dropped, so mining was listed as
        -- "Copper Ore". It now keys on the species, so mining is listed as
        -- "Copper Vein" -- the thing you actually see in the world. Leave the old
        -- entries in place and every rock is in the list TWICE, under two names,
        -- with two independent checkboxes and no clue which one does anything.
        --
        -- So the discovered-node list gets emptied exactly once. It costs nothing:
        -- it refills the moment you fly into a zone (from GatherMate) or gather
        -- something. The per-node filters go with it -- and they have to, because
        -- they were keyed on ids that no longer identify anything.
        --
        -- Deliberately NOT a key in NS.defaults: applyDefaults backfills missing
        -- keys, so putting it there would hand every existing character the
        -- "already migrated" stamp and this would never run.
        -- ---------------------------------------------------------------------
        if EyesUpDB.identityVersion ~= 3 then
            local had = false
            for _, t in ipairs(NS.NodeTypeOrder) do
                if next(EyesUpDB.knownNodes[t] or {}) then had = true end
                wipe(EyesUpDB.knownNodes[t])
                wipe(EyesUpDB.nodeFilter[t])
            end
            EyesUpDB.identityVersion = 3
            NS.pruned = had
        end

    elseif event == "PLAYER_LOGOUT" then
        NS.Live.Restore()                  -- put their CVars back

    elseif event == "PLAYER_LOGIN" then
        NS.Overlay.Create()
        NS.Cue.Create()
        applyLayouts()
        NS.Live.Enable()                   -- soft targeting on, or nothing is ever confirmed
        NS.Scan.Start()                    -- the heartbeat; needs both renderers built
        NS.Options.Init()                  -- get listed in Settings before anyone looks

        NS.Print("eyes up. |cffffff00/eu|r for options, |cffffff00/eu demo|r to see it work.")
        if NS.migrated then
            NS.Print("|cff88ff88Found your old NodeSight data and brought it along.|r")
        end
        if NS.pruned then
            NS.Print("|cff88ff88Nodes are now listed by species (\"Copper Vein\"), not by what they")
            NS.Print("drop (\"Copper Ore\"), so the old list was cleared. It refills as you fly.|r")
        end
        if NS.Seed.IsAvailable() then
            NS.Print("|cff88ff88GatherMate2_Data found — the cue works in zones you've never farmed.|r")
        end

    elseif event == "ZONE_CHANGED_NEW_AREA" or event == "PLAYER_ENTERING_WORLD" then
        -- The map isn't always ready the instant the event fires, so ask on the
        -- next frame rather than getting a nil mapID and quietly indexing nothing.
        C_Timer.After(0, function()
            NS.Seed.Prepare(C_Map.GetBestMapForUnit("player"))
        end)

    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        local unit, _, spellID = ...
        if unit ~= "player" then return end
        local name = spellName(spellID)
        local nodeType = name and NS.GatherSpellNames[name]
        if nodeType then
            beginPending(nodeType)         -- the loot that follows will finish this
        end

    elseif event == "LOOT_READY" or event == "LOOT_OPENED" then
        -- Both of these fire for a gather (READY first; OPENED only if a window
        -- actually appears, which autoloot skips). lootHandled makes the pair
        -- idempotent so we don't record the same node twice.
        onLoot()

    elseif event == "LOOT_CLOSED" then
        lootHandled = false
    end
end)

-- ---------------------------------------------------------------------------
-- Toys, for testing without walking to Elwynn
-- ---------------------------------------------------------------------------

local function markHere(nodeType)
    local mapID, x, y = Data.GetPlayerPosition()
    if not mapID then NS.Print("I don't know where you are."); return end
    Data.AddNode(mapID, x, y, nodeType, nil, "Manual mark")
    NS.Printf("marked a %s node right here.", NS.NodeTypeLabel[nodeType] or nodeType)
end

-- Scatter imaginary nodes around you, so you can watch the cue work without
-- flying to a zone and hoping.
local function demoScatter()
    local mapID, x, y = Data.GetPlayerPosition()
    if not mapID then NS.Print("I don't know where you are."); return end
    local types = NS.NodeTypeOrder
    for i = 1, 8 do
        local ang = (i / 8) * math.pi * 2
        local r = 0.02 + (i % 3) * 0.015
        local t = types[(i % #types) + 1]
        Data.AddNode(mapID, x + math.cos(ang) * r, y + math.sin(ang) * r,
            t, 1000 + i, "Demo " .. NS.NodeTypeLabel[t] .. " " .. i)
    end
    -- Imaginary nodes are, by definition, not really there -- so with the default
    -- confirmed-only cue they'd be filtered out and the demo would show nothing at
    -- all. Turn guesses on for the duration, and say so, rather than leaving
    -- someone to conclude the addon is broken.
    if not NS.db.showGuesses then
        NS.db.showGuesses = true
        if NS.Options then NS.Options.Refresh() end
        NS.Print("(turned |cffffcc00guesses on|r — fake nodes aren't really there, so the")
        NS.Print(" confirmed-only cue would ignore them. |cffffff00/eu guesses off|r when you're done.)")
    end

    NS.Print("scattered some imaginary nodes around you. Spin in a circle.")
end

-- ---------------------------------------------------------------------------
-- /eu
-- ---------------------------------------------------------------------------
SLASH_EYESUP1 = "/eyesup"
SLASH_EYESUP2 = "/eu"
SLASH_EYESUP3 = "/ns"          -- muscle memory from the NodeSight days

-- What you're allowed to call a node type at the prompt. Shared by `mark` and
-- `priority`, because typing "fish" should mean the same thing to both.
local TYPE_ARG = {
    herb = NS.NodeType.HERB,        mine     = NS.NodeType.MINE,
    lumber = NS.NodeType.LUMBER,    fish     = NS.NodeType.FISHING,
    fishing = NS.NodeType.FISHING,  treasure = NS.NodeType.TREASURE,
}

local PRIORITY_ARG = {
    low = NS.Priority.LOW, normal = NS.Priority.NORMAL, high = NS.Priority.HIGH,
}
SlashCmdList.EYESUP = function(msg)
    msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    local cmd, arg = msg:match("^(%S*)%s*(.-)$")

    if cmd == "" or cmd == "config" or cmd == "options" then
        NS.Options.Open()

    elseif cmd == "toggle" then
        -- `enabled` is the whole addon, not just one renderer. The heartbeat
        -- keeps beating either way -- which is precisely what lets this come back
        -- on without a /reload.
        NS.db.enabled = not NS.db.enabled
        NS.Print(NS.db.enabled and "eyes up." or "eyes closed.")

    elseif cmd == "mode" then
        if arg == "cue" or arg == "radar" or arg == "both" then
            NS.db.mode = arg
            applyLayouts()
            NS.Print("mode: " .. arg)
        else
            NS.Printf("usage: /eu mode cue|radar|both   (currently: %s)",
                tostring(NS.db.mode or "cue"))
        end

    elseif cmd == "lock" then
        NS.db.locked = true; applyLayouts(); NS.Print("locked down.")

    elseif cmd == "unlock" then
        NS.db.locked = false; applyLayouts()
        NS.Print("unlocked — drag the cue (or the radar) wherever suits you.")

    elseif cmd == "reset" then
        NS.db.posX, NS.db.posY = 0, 0
        NS.db.cuePosX = NS.defaults.cuePosX
        NS.db.cuePosY = NS.defaults.cuePosY
        applyLayouts(); NS.Print("back to the middle.")

    elseif cmd == "mark" then
        local t = TYPE_ARG[arg]
        if t then markHere(t)
        else NS.Print("usage: /eu mark herb|mine|lumber|fish|treasure") end

    elseif cmd == "priority" then
        -- Which type wins when two things are in range at once. Not a filter --
        -- see NS.Priority. With no argument, just say where things stand.
        local what, level = arg:match("^(%S*)%s*(%S*)$")
        local t, p = TYPE_ARG[what or ""], PRIORITY_ARG[level or ""]
        if t and p then
            NS.db.typePriority[t] = p
            if NS.Options then NS.Options.Refresh() end
            NS.Printf("%s: %s priority.", NS.NodeTypeLabel[t], NS.PriorityLabel[p])
        elseif what == "" then
            NS.Print("what you care about most:")
            for _, nt in ipairs(NS.NodeTypeOrder) do
                local lvl = NS.db.typePriority[nt] or NS.Priority.NORMAL
                print(("  %-10s %s"):format(NS.NodeTypeLabel[nt], NS.PriorityLabel[lvl] or "?"))
            end
        else
            NS.Print("usage: /eu priority herb/mine/lumber/fish/treasure low/normal/high")
        end

    elseif cmd == "demo" then
        demoScatter()

    elseif cmd == "clear" then
        local mapID = C_Map.GetBestMapForUnit("player")
        if mapID and Data.nodes[mapID] then wipe(Data.nodes[mapID]) end
        NS.Print("forgot everything about this map.")

    elseif cmd == "vignettes" then
        NS.Vignettes.Dump()

    elseif cmd == "clearknown" then
        -- The old classifier filed every rare, event and quest marker under
        -- TREASURE, so long-time players have a filter list full of nonsense.
        -- Wiping it is safe: it fills back in from what you actually see, and
        -- these days only real chests get in.
        for _, t in ipairs(NS.NodeTypeOrder) do
            wipe(NS.db.knownNodes[t])
            wipe(NS.db.nodeFilter[t])
        end
        if NS.Options then NS.Options.Refresh() end
        NS.Print("cleared the discovered-node list and its filters. Fresh eyes.")

    elseif cmd == "seed" then
        -- Somebody else's map. On, off, or "is this actually doing anything".
        if arg == "on" or arg == "off" then
            NS.db.seedEnabled = (arg == "on")
            if NS.Options then NS.Options.Refresh() end
        end

        if not NS.Seed.IsAvailable() then
            NS.Print("GatherMate2_Data isn't installed, so there's no map to borrow.")
            NS.Print("Without it the cue only knows what you've shown it.")
        else
            NS.Printf("seed: %s", NS.db.seedEnabled and "|cff66ff66on|r" or "|cffff6666off|r")

            local mapID, px, py = Data.GetPlayerPosition()
            if not mapID then
                NS.Print("...but I can't tell where you are right now.")
            else
                local onMap = NS.Seed.CountOnMap(mapID) or 0
                local inRange = NS.Seed.CountInRange(mapID, px, py)
                local info = C_Map.GetMapInfo(mapID)

                NS.Printf("  %s: |cffffff00%d|r nodes known here", info and info.name or "?", onMap)
                NS.Printf("  within your %d yard detection radius, right now: |cff66ff66%d|r",
                    NS.db.detectionYards or 60, inRange)

                -- The whole point of printing this: a quiet cue is USUALLY an empty
                -- field, not a broken addon. Sixty yards is a small circle.
                if onMap > 0 and inRange == 0 then
                    NS.Print("  |cff888888(nothing in range -- that's the cue working, not failing.")
                    NS.Print("   walk somewhere greener and run this again.)|r")
                elseif onMap == 0 then
                    NS.Print("  |cffffcc00GatherMate has no data for this map.|r")
                end
            end
        end

    elseif cmd == "guesses" then
        -- The one setting that decides what this addon IS.
        if arg == "on" or arg == "off" then
            NS.db.showGuesses = (arg == "on")
            if NS.Options then NS.Options.Refresh() end
        end
        if NS.db.showGuesses then
            NS.Printf("guesses |cffffcc00on|r — the cue also points at remembered nodes, out to %d yards.",
                NS.db.detectionYards or 60)
            NS.Print("Most of those aren't there. They draw faint and never make a sound.")
        else
            NS.Print("guesses |cff66ff66off|r — the cue only fires for nodes that are really there.")
            NS.Print("Shorter reach (~15-25 yards), but it never lies. |cffffff00/eu guesses on|r for the rest.")
        end

    elseif cmd == "status" then
        -- "Why is nothing happening?" -- answered in four lines.
        NS.Printf("mode: %s", NS.db.showGuesses
            and "|cffffcc00confirmed + guesses|r" or "|cff66ff66confirmed only|r (default)")
        NS.Printf("soft targeting: %s", NS.Live.IsReady()
            and "|cff66ff66on|r — live nodes can be seen"
            or "|cffff6666OFF — the cue can never fire.|r Set |cffffff00/eu softtarget on|r")
        NS.Printf("GatherMate2_Data: %s (optional)", NS.Seed.IsAvailable()
            and "|cff66ff66found|r — live nodes can be pointed at anywhere"
            or "|cffffcc00absent|r — live nodes get an arrow once you've gathered that species once")
        local mapID = C_Map.GetBestMapForUnit("player")
        NS.Printf("this zone: %s known node positions",
            mapID and tostring(NS.Seed.CountOnMap(mapID) or 0) or "?")

    elseif cmd == "softtarget" then
        if arg == "off" then
            NS.db.manageSoftTarget = false
            NS.Live.Restore()
            NS.Print("hands off your soft-target CVars. Note: the cue can't confirm anything now.")
        else
            NS.db.manageSoftTarget = true
            NS.Live.Enable()
            NS.Print("soft targeting on (360°). Your setting is restored at logout.")
        end

    elseif cmd == "near" then
        -- What, exactly, does the addon think is around you right now?
        --
        -- This exists to separate two very different failures that look identical
        -- from the cockpit: "there's a herb 20 yards north" when there ISN'T one
        -- there (a ghost -- the node has been there, isn't now, and the client
        -- won't tell us), versus "there's a herb 20 yards north" when the herb is
        -- actually four hundred yards away behind a hill (a coordinate bug, and
        -- mine to fix). Walk to what it names. If it's empty ground but the RIGHT
        -- ground, it's a ghost. If it's nowhere near, I've broken the maths.
        local mapID, px, py = Data.GetPlayerPosition()
        if not mapID then
            NS.Print("can't tell where you are.")
        else
            local COMPASS = { "N", "NE", "E", "SE", "S", "SW", "W", "NW" }
            local function say(node, dist, bearing)
                local deg = math.deg(bearing or 0) % 360
                local dir = COMPASS[math.floor((deg + 22.5) / 45) % 8 + 1]
                print(("  |cffffff00%-24s|r %-9s %5.0fy %-3s  %s"):format(
                    node.name or "(unnamed)",
                    NS.NodeTypeLabel[node.type] or node.type,
                    dist or -1, dir,
                    node.seeded and "|cff888888gathermate|r"
                        or node.vignette and "|cff66ff66vignette (really there)|r"
                        or "|cff66ccffyours|r"))
            end

            NS.Printf("within %d yards, this is everything the cue can see:", NS.db.detectionYards or 60)
            Data.ForEachNearby(mapID, px, py, say)
            NS.Seed.ForEachNearby(mapID, px, py, say)
            NS.Vignettes.ForEachOnMap(mapID, px, py, say)
            NS.Print("|cff888888gathermate = a node has BEEN here. Not that one is here now.|r")
        end

    elseif cmd == "probe" then
        -- Diagnostics. See Probe.lua -- it measures what the client will actually
        -- tell us about live nodes, which is more than this addon currently asks.
        NS.Probe.Command(arg)

    elseif cmd == "debug" then
        NS.db.debug = not NS.db.debug
        NS.Print("debug " .. (NS.db.debug and "on" or "off"))

    else
        NS.Print("what I can do:")
        print("  |cffffff00/eu|r                 open the options")
        print("  |cffffff00/eu toggle|r          eyes up / eyes closed")
        print("  |cffffff00/eu mode|r <m>        cue | radar | both")
        print("  |cffffff00/eu lock|r/|cffffff00unlock|r    move things around")
        print("  |cffffff00/eu reset|r           put them back")
        print("  |cffffff00/eu priority|r <type> low/normal/high")
        print("  |cffffff00/eu mark|r <type>     drop a test node here")
        print("  |cffffff00/eu demo|r            scatter imaginary nodes around you")
        print("  |cffffff00/eu clear|r           forget this map")
        print("  |cffffff00/eu vignettes|r       what can I see, and what do I think it is")
        print("  |cffffff00/eu guesses|r <on|off> also point at nodes that might not be there")
        print("  |cffffff00/eu status|r          why isn't it firing?")
        print("  |cffffff00/eu near|r            list everything the cue can currently see, and why")
        print("  |cffffff00/eu seed|r <on|off>   use GatherMate2_Data's node map, if installed")
        print("  |cffffff00/eu clearknown|r      reset the discovered-node list")
        print("  |cffffff00/eu probe|r           what will the client REALLY tell us? (diagnostic)")
        print("  |cffffff00/eu debug|r           narrate everything")
    end
end
