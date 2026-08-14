-- Eyes Up - Copyright (c) 2026 KTM (abitofmoss). All Rights Reserved.
-- No redistribution or reuse of this code or assets without permission. See LICENSE.
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

-- ---------------------------------------------------------------------------
-- Keybindings (see Bindings.xml).
--
-- The binding system calls these by GLOBAL name, so they must be real globals, and
-- the labels the Keybindings UI shows come from the BINDING_NAME_* globals. The
-- SECTION they sit under ("Eyes Up Add On") is the `category` in Bindings.xml.
-- This is the one place we deliberately write to _G.
--
-- Why a keybind at all: hubs and renown quest camps are full of service and quest
-- POIs that are engine-drawn and CANNOT be hidden by any addon (see the note in
-- Hud.lua). "Step aside in cities" folds the HUD in real towns, but these camps
-- aren't rest areas -- so the honest answer is a key you can flick to drop the
-- whole HUD for a moment and bring it back when you leave.
-- ---------------------------------------------------------------------------
_G.BINDING_NAME_EYESUP_TOGGLE_HUD = "Toggle the heads-up display"
_G.BINDING_NAME_EYESUP_TOGGLE_CUE = "Toggle the addon (eyes up / closed)"

function _G.EyesUpToggleHUD()
    if NS.Hud then NS.Hud.Toggle() end
end

function _G.EyesUpToggleEnabled()
    if not NS.db then return end
    NS.db.enabled = not NS.db.enabled
    NS.Print(NS.db.enabled and "eyes up." or "eyes closed.")
end

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

-- ---------------------------------------------------------------------------
-- Per-character vs. shared-across-all-characters settings.
--
-- Two saved files exist (see the .toc): EyesUpDB is per-character, EyesUpAccountDB
-- is shared. NS.db points at whichever one EyesUpDB.useAccount selects, chosen at
-- load. Flipping it here copies your CURRENT settings into the OTHER file first --
-- so nothing is lost or reset -- flags the choice, and asks for a /reload, which
-- is the clean way to re-point NS.db and Data.nodes without hunting down every
-- live reference to them.
-- ---------------------------------------------------------------------------
local function deepCopy(src, dst)
    for k, v in pairs(src) do
        if type(v) == "table" then
            local t = type(dst[k]) == "table" and dst[k] or {}
            wipe(t)
            deepCopy(v, t)
            dst[k] = t
        else
            dst[k] = v
        end
    end
end

function NS.SettingsAreShared()
    return EyesUpDB and EyesUpDB.useAccount == true
end

-- ---------------------------------------------------------------------------
-- RELOADING IS PROTECTED -- AND THIS DOES MORE THAN RELOAD.
--
-- C_UI.Reload is a protected call. Ask for it in combat and the client refuses:
--
--     ADDON_ACTION_BLOCKED: tried to call the protected function 'Reload()'
--
-- On its own that would be survivable noise. It isn't on its own, because by the
-- time we ask, we have ALREADY copied every setting into the other file and flipped
-- EyesUpDB.useAccount. So a blocked reload doesn't CANCEL the change, it STRANDS it:
-- the saved flag says "shared", NS.db still points at the per-character table, and
-- every setting you touch between there and your next login is written to the file
-- the addon has already decided to stop reading. Nothing errors, nothing looks
-- wrong, and an evening's settings quietly go nowhere.
--
-- So the whole operation waits, not just the reload. In combat we do NOTHING and
-- queue it -- one thing that either happened or didn't, never half of one. And the
-- one-second timer re-checks on its way out, because a fight can start inside that
-- second and that path would be blocked with the copy already made.
-- ---------------------------------------------------------------------------
local pendingShare = nil        -- a share flip waiting for the fight to end
local reloadWatch = CreateFrame("Frame")
reloadWatch:RegisterEvent("PLAYER_REGEN_ENABLED")

-- Wrap the reload in a real function: passing `C_UI and C_UI.Reload or ReloadUI`
-- directly hands C_Timer.After a nil when neither name resolves on the running
-- client ("bad argument #2 to C_Timer.After"). A closure is always a function, and
-- it calls whichever reload API actually exists.
local function reloadNow()
    if InCombatLockdown and InCombatLockdown() then
        reloadWatch.wantReload = true
        NS.Print("|cffffcc00...a fight started. Holding the reload until it's over.|r")
        return
    end
    if C_UI and C_UI.Reload then C_UI.Reload()
    elseif ReloadUI then ReloadUI() end
end

reloadWatch:SetScript("OnEvent", function(self)
    if pendingShare ~= nil then
        local want = pendingShare
        pendingShare = nil
        NS.SetSettingsShared(want)
        return
    end
    if self.wantReload then
        self.wantReload = false
        reloadNow()
    end
end)

function NS.SetSettingsShared(shared)
    shared = shared and true or false
    if NS.SettingsAreShared() == shared then return end

    -- Nothing at all in combat -- see above. Not the copy, not the flag, not the
    -- reload. Queued whole, applied whole.
    if InCombatLockdown and InCombatLockdown() then
        pendingShare = shared
        NS.Print("|cffffcc00not mid-fight|r -- switching your settings over needs a reload.")
        NS.Print("  I'll do the whole thing the moment the fight ends. Nothing has changed yet.")
        -- Put the tick back where it was, so the page never claims a state we
        -- haven't reached. The line above is what explains it.
        if NS.Options then NS.Options.Refresh() end
        return
    end

    local target = shared and EyesUpAccountDB or EyesUpDB
    deepCopy(NS.db, target)          -- carry everything (settings AND gathered data) across
    EyesUpDB.useAccount = shared     -- set AFTER the copy, so the copy can't stamp the wrong value

    NS.Printf("settings are now |cffffff00%s|r. Reloading to apply...",
        shared and "shared across all your characters" or "per-character")
    C_Timer.After(1, reloadNow)
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

        -- Dev vs live saved variables. A DEV build carries "[DEV]" in its Title (see the
        -- gitignored dev loader) and declares its own EyesUpDev* files, so dev experiments
        -- never touch a live profile and both copies can sit installed side by side. Mirror
        -- the dev files into the working globals here, and write them back below; every
        -- other reference stays exactly as it was.
        local isDev = C_AddOns and C_AddOns.GetAddOnMetadata
            and ((C_AddOns.GetAddOnMetadata(addonName, "Title") or ""):find("%[DEV%]") ~= nil)
        if isDev then
            EyesUpDB        = EyesUpDevDB
            EyesUpAccountDB = EyesUpDevAccountDB
        end

        EyesUpDB       = EyesUpDB or {}         -- per-character file
        EyesUpAccountDB = EyesUpAccountDB or {}  -- shared-across-all-characters file

        -- This addon used to be called NodeSight. If a player brought their old
        -- saved-variables file across (see the README), adopt it whole rather
        -- than making them re-gather half a continent. Runs once, into the
        -- per-character store (that's where the old file landed).
        if not next(EyesUpDB) and type(_G.NodeSightDB) == "table" then
            EyesUpDB = _G.NodeSightDB
            NS.migrated = true
        end

        -- Persist to the dev files (declared by the dev loader) so an isolated dev profile
        -- saves on logout. Same table refs, so every later write is captured.
        if isDev then
            EyesUpDevDB        = EyesUpDB
            EyesUpDevAccountDB = EyesUpAccountDB
        end

        -- WHICH store are we using?
        --
        -- The choice lives on the per-character file (EyesUpDB.useAccount), because
        -- that file always exists and each character decides for itself. Default is
        -- per-character -- exactly what every existing install already had, so no
        -- one's settings move without them asking. Flip it in the options and we
        -- copy your settings across and /reload onto the other store.
        local db = EyesUpDB.useAccount and EyesUpAccountDB or EyesUpDB

        applyDefaults(db, NS.defaults)
        db.nodes = db.nodes or {}
        NS.db = db
        Data.nodes = db.nodes              -- these tables ARE the saved data now

        -- Stamp which build last wrote this file. "It started after an update" is a
        -- guess until you can see what the file was written by, and saved variables
        -- outlive the install that made them.
        NS.BUILD = ((C_AddOns and C_AddOns.GetAddOnMetadata
            and C_AddOns.GetAddOnMetadata(addonName, "Version")) or "?") .. "+f0a4d7e21c6b"
        db.build = NS.BUILD

        -- ---------------------------------------------------------------------
        -- One-time: undo a compat verdict that was never true.
        --
        -- Up to 1.2.1 the minimap-owner check compared Minimap:GetParent() against
        -- MinimapCluster directly. 12.0 put an anonymous container in between, so on
        -- a stock UI with nothing installed the check answered "another addon",
        -- switched the HUD off, and stamped the verdict so it would never ask again.
        -- Everyone it caught is sitting on a feature they asked for, turned off on
        -- their behalf, with a stamp saying not to mention it.
        --
        -- The stamp is the tell. A nameless "another addon" is what the broken check
        -- produced, so clear it and give the HUD back. This can't overreach: the
        -- stamp is only ever written in the same breath as hudEnabled = false, so
        -- anybody carrying one had the HUD on when it fired. And the fixed check runs
        -- half a second into login anyway -- if a suite really is in the way it will
        -- stand down again, properly, and ask.
        --
        -- Deliberately NOT a key in NS.defaults -- same reasoning as identityVersion
        -- below: a default would hand every install the "already handled" mark.
        -- ---------------------------------------------------------------------
        if not db.compatVerdictRepaired then
            db.compatVerdictRepaired = true
            if db.hudCompatAsked == "another addon" then
                db.hudCompatAsked = nil
                db.hudEnabled     = true
                NS.compatRestored = true
            end
        end

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
        if db.identityVersion ~= 3 then
            local had = false
            for _, t in ipairs(NS.NodeTypeOrder) do
                if next(db.knownNodes[t] or {}) then had = true end
                wipe(db.knownNodes[t])
                wipe(db.nodeFilter[t])
            end
            db.identityVersion = 3
            NS.pruned = had
        end

        -- ---------------------------------------------------------------------
        -- One-time: the mask stopped being the thing that hides the terrain.
        --
        -- Every install before this one has hudMask = "clear" and hudAlpha = 1.0
        -- saved, because that WAS the addon: a fully transparent mask deleted the
        -- map and left the blips. 12.1 gave the mask a blip gate, so a transparent
        -- mask now deletes the blips too and the HUD comes up empty -- no error, no
        -- clue, just nothing. The job moved to frame alpha. See the top of Hud.lua.
        --
        -- Changing NS.defaults alone reaches nobody: applyDefaults only fills keys
        -- that are MISSING, and every existing character already has both of these.
        -- So they get rewritten here, once.
        --
        -- Only the transparent masks are touched. Somebody who deliberately chose
        -- "round" or "vignette" gets left alone, and hudAlpha is only ever lowered
        -- -- if they'd already turned the HUD down further than we would, that was a
        -- choice and it still works.
        --
        -- Deliberately NOT a key in NS.defaults -- same trap as identityVersion
        -- above: a default would stamp every install as already-migrated and this
        -- would never run for the people it exists for.
        -- ---------------------------------------------------------------------
        if not db.maskGatesBlipsMigrated then
            db.maskGatesBlipsMigrated = true
            local m = db.hudMask
            if m == nil or m == "clear" or m == "ghost" or m == "dim" then
                db.hudMask = "round"
                if (db.hudAlpha or 1) > 0.01 then db.hudAlpha = 0.01 end
            end
        end

        -- Backfill speciesItem from every node we've ever recorded.
        --
        -- The cue's icon in "item" mode wants the thing a node DROPS (the ore, not
        -- a pickaxe). It gets that from db.speciesItem[type][speciesID]. But the
        -- cue mostly shows LIVE soft-target nodes now, which never carry an item --
        -- so unless speciesItem already knew that species, you got the generic
        -- glyph. Every node in your database that resolved both its species and its
        -- drop already holds the answer; sweep them in once at login so a herb you
        -- picked last week teaches its icon to the live blip today.
        db.speciesItem = db.speciesItem or {}
        for _, zone in pairs(db.nodes or {}) do
            for _, n in ipairs(zone) do
                if n.id and n.item and n.type then
                    local byType = db.speciesItem[n.type]
                    if byType and byType[n.id] == nil then byType[n.id] = n.item end
                end
            end
        end

    elseif event == "PLAYER_LOGOUT" then
        NS.Live.Restore()                  -- put their CVars back

    elseif event == "PLAYER_LOGIN" then
        NS.Overlay.Create()
        NS.Cue.Create()
        applyLayouts()
        NS.Live.Enable()                   -- soft targeting on, or nothing is ever confirmed

        -- The minimap isn't ours until Blizzard has finished arranging it, and it
        -- arranges it during PLAYER_LOGIN. Take it a moment later. Refresh (not
        -- Enable) so a login inside a city correctly stays stood-down.
        --
        -- CheckMinimapCompat goes inside the same delay, and that's load-bearing:
        -- a UI suite claims the minimap from its OWN login handler, which may run
        -- after ours. Ask at PLAYER_LOGIN proper and we'd be looking at Blizzard's
        -- untouched minimap and conclude nobody else wants it. The timer is
        -- unconditional now -- the check has to run even when the HUD is already
        -- off, so it stamps itself and stops asking.
        C_Timer.After(0.5, function()
            NS.Hud.CheckMinimapCompat()
            if NS.db.hudEnabled then NS.Hud.Refresh() end
        end)

        NS.Scan.Start()                    -- the heartbeat; needs both renderers built
        NS.Options.Init()                  -- get listed in Settings before anyone looks

        NS.Print("eyes up. |cffffff00/eu|r for options.")
        if NS.migrated then
            NS.Print("|cff88ff88Found your old NodeSight data and brought it along.|r")
        end
        if NS.pruned then
            NS.Print("|cff88ff88Nodes are now listed by species (\"Copper Vein\"), not by what they")
            NS.Print("drop (\"Copper Ore\"), so the old list was cleared. It refills as you fly.|r")
        end
        if NS.compatRestored then
            -- One call, not three. Chat stamps the "Eyes Up" tag on every message it
            -- is handed, so a message broken across three of them wears the tag three
            -- times and wraps badly. Hand it the whole thing and let chat wrap it.
            NS.Print("|cff88ff88The blip HUD is back on -- it had been switched off by a "
                .. "compatibility check that misread this game version and thought another "
                .. "addon was running your minimap. Nothing was.|r "
                .. "|cffffff00/eu off|r if you'd rather it stayed off.")
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
-- ---------------------------------------------------------------------------
-- THE WORD "HUD" IS NOISE NOW.
--
-- This addon is the HUD. Everything anyone types at it is about the circle in the
-- middle of the screen or the blips in it, and making them all say "hud" first was
-- a prefix that only ever earned its keep back when the cue was the main event.
--
-- So: any of these as the first word is quietly rewritten into the `hud` handler.
-- `/eu size 400` and `/eu hud size 400` are one command with two spellings, and the
-- long form still works -- nothing anyone has in a macro breaks.
--
-- What's NOT in here is the cue's half. Those commands still exist (the options
-- page doesn't cover all of them) but they're off the front page: `/eu more`.
local HUD_WORDS = {
    on = true, off = true, size = true, move = true, unlock = true, lock = true,
    centre = true, center = true, pos = true, status = true,
    blips = true, blipsize = true,
    rotate = true, ring = true, alpha = true, mask = true, sweep = true,
    track = true, map = true, mapalpha = true, zoom = true, shape = true,
    border = true, mapsize = true, city = true, combat = true,
    corner = true, compat = true,
}

SlashCmdList.EYESUP = function(msg)
    msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    local cmd, arg = msg:match("^(%S*)%s*(.-)$")

    if HUD_WORDS[cmd] then
        arg = (arg ~= "") and (cmd .. " " .. arg) or cmd
        cmd = "hud"
    elseif cmd:match("^%d+$") then
        arg, cmd = cmd, "hud"          -- /eu 400 -- the size, the way it always was
    end

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

    -- ---- the cue, in one place --------------------------------------------
    -- `lock` and `unlock` used to be the cue's, at the top level. The HUD has them
    -- now (it's what people actually want to move), so everything the cue does that
    -- the options page doesn't cover lives here instead of scattered across the
    -- front page. Bare `/eu cue` answers the only question anyone asks it.
    elseif cmd == "cue" or cmd == "reset" then
        if cmd == "reset" or arg == "reset" then
            NS.db.posX, NS.db.posY = 0, 0
            NS.db.cuePosX = NS.defaults.cuePosX
            NS.db.cuePosY = NS.defaults.cuePosY
            applyLayouts(); NS.Print("cue back in the middle.")

        elseif arg == "lock" or arg == "unlock" then
            NS.db.locked = (arg == "lock")
            applyLayouts()
            NS.Print(NS.db.locked and "cue locked down."
                or "cue unlocked — drag it (or the radar) wherever suits you.")
            NS.Print("  |cff888888The HUD moves separately:|r |cffffff00/eu move|r")

        else
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
            NS.Print("  |cffffff00/eu cue lock|unlock|reset|r  |cff888888-- the rest is on the options page|r")
        end

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

    elseif cmd == "hud" then
        -- The real thing. Your minimap's tracking blips, in the middle of your
        -- screen, with the map itself masked away.
        if arg == "off" then
            NS.Hud.SetEnabled(false)
            NS.Print("minimap put back in its corner.")
        elseif arg == "on" or arg == "" then
            NS.Hud.SetEnabled(true)
            local r = NS.Hud.RangeYards()
            NS.Print("|cff66ff66eyes up.|r Your tracking blips are now in front of you.")
            NS.Printf("  seeing |cff66ff66%s yards|r in every direction -- the game's own markers,",
                r and math.floor(r) or "?")
            NS.Print("  live and exact. Nothing here is a guess.")
            NS.Print("  |cffffcc00Your corner minimap is gone while this is on.|r |cffffff00/eu off|r brings it back.")
            if NS.db.hudHideInCity then
                NS.Print("  (It steps aside in cities -- town's not for gathering. |cffffff00/eu city off|r to keep it.)")
            end
            NS.Print("  Needs Find Herbs / Find Minerals ticked -- these ARE those blips.")
        elseif arg:match("^%d+$") or arg:match("^size") then
            -- "/eu 400" and "/eu size 400" are the same thing.
            local v = tonumber(arg:match("^(%d+)$") or arg:match("^size%s+(%d+)$"))
            if v then
                NS.db.hudSize = math.max(100, math.min(800, v))
                NS.Hud.ApplyLook()
                NS.Printf("hud size: %d px", NS.db.hudSize)
            else
                NS.Printf("usage: |cffffff00/eu size 100-800|r  (currently %d)", NS.db.hudSize or 400)
            end

        elseif arg == "unlock" or arg == "move" then
            -- Off its peg. SetLocked does the talking when it can't (HUD down, or
            -- mid-fight), so there's nothing to say here on success that the green
            -- circle now on screen doesn't say better.
            if NS.Hud.SetLocked(false) then
                NS.Print("|cff66ff66unlocked.|r Drag the circle wherever suits you, then")
                NS.Print("  right-click it (or |cffffff00/eu lock|r) to lock it there.")
                NS.Print("  |cff888888Alt while dragging turns off the snap to centre.|r")
            end

        elseif arg == "lock" or arg == "pin" then
            NS.Hud.SetLocked(true)
            NS.Printf("|cff66ff66locked|r at %d, %d.", NS.db.hudX or 0, NS.db.hudY or 0)

        elseif arg == "center" or arg == "centre" or arg == "reset" then
            -- Only ever the HUD. hudX/hudY are read by placeMinimap, which only
            -- runs while the HUD is up; with it down this just tidies the stored
            -- position for next time and leaves the corner minimap alone.
            NS.Hud.ResetPosition()
            if NS.Options then NS.Options.Refresh() end
            NS.Print(NS.Hud.IsActive()
                and "hud snapped back to the middle of the screen."
                or  "hud position reset to centre -- it'll be there when the HUD next comes up.")

        elseif arg:match("^pos") then
            local x, y = arg:match("^pos%s+(-?%d+)%s+(-?%d+)$")
            if x then
                NS.Hud.SetPosition(tonumber(x), tonumber(y))
                NS.Printf("hud at %d, %d (from screen centre).", NS.db.hudX, NS.db.hudY)
            else
                NS.Print("usage: |cffffff00/eu pos <x> <y>|r  -- pixels from screen centre")
                NS.Printf("  currently %d, %d. |cffffff00/eu move|r to drag it instead.",
                    NS.db.hudX or 0, NS.db.hudY or 0)
            end

        elseif arg:match("^mapalpha") or arg:match("^map%s+alpha") then
            -- The CORNER map's opacity. Deliberately not "alpha", which is the HUD's
            -- and would be a miserable pair of commands to tell apart in a hurry.
            local v = tonumber(arg:match("^mapalpha%s+([%d%.]+)$")
                            or arg:match("^map%s+alpha%s+([%d%.]+)$"))
            if v then
                if v > 1 then v = v / 100 end          -- accept "60" as 60%
                NS.db.cornerAlpha = math.max(0.1, math.min(1, v))
                if NS.Corner then NS.Corner.ApplyLook() end
                if NS.Options then NS.Options.Refresh() end
                NS.Printf("corner map opacity: |cff66ff66%d%%|r", NS.db.cornerAlpha * 100)
                NS.Print("  |cff888888Your position arrow stays at full strength.|r")
            else
                NS.Print("usage: |cffffff00/eu mapalpha 10-100|r  (or 0.1-1)")
                NS.Printf("  currently %d%%. Floored at 10%% -- for none at all, "
                    .. "|cffffff00/eu map off|r.", (NS.db.cornerAlpha or 1) * 100)
            end

        elseif arg == "blips" then
            -- Bare: what this client will and won't let us do to them, measured live.
            NS.Hud.BlipReport()

        elseif arg:match("^blips%s") or arg:match("^blipsize") then
            -- With a number: the one blip dial that works. Same word either way --
            -- two commands one letter apart was never going to be remembered.
            local v = tonumber(arg:match("^blips%s+([%d%.]+)$")
                            or arg:match("^blipsize%s+([%d%.]+)$"))
            if v then
                v = NS.Hud.SetBlipScale(v)
                if NS.Options then NS.Options.Refresh() end
                NS.Printf("blip size: |cff66ff66%.2fx|r -- the circle and the range are unchanged, "
                    .. "only the dots.", v)
            else
                NS.Print("usage: |cffffff00/eu blips 0.5-3|r  (1 = Blizzard's)")
                NS.Print("  The blips are engine-drawn and can't be repainted, but scaling the")
                NS.Print("  map scales the artwork -- so we scale up and shrink to match.")
                NS.Print("  |cffffff00/eu blips|r on its own says what else this client allows.")
            end

        elseif arg == "rotate" or arg == "rotate on" or arg == "rotate off" then
            if arg ~= "rotate" then NS.db.hudRotate = (arg == "rotate on") end
            NS.Hud.ApplyLook()
            NS.Printf("rotate: %s", NS.db.hudRotate
                and "|cff66ff66on|r — up is the way you're facing"
                or  "off — up is north, and you have to do the maths")

        elseif arg == "corner on" or arg == "corner off" then
            NS.db.hudKeepCorner = (arg == "corner on")
            if NS.Hud.IsActive() then NS.Hud.Disable(); NS.Hud.Enable() end
            NS.Printf("corner: %s", NS.db.hudKeepCorner
                and "kept (border, tracking, mail, clock, addon buttons)"
                or  "hidden entirely")

        elseif arg == "track" then
            -- "Find Herbs is ticked and there are still no blips." This is the
            -- answer, and it's the only place you can see it: the HUD shows the
            -- game's own tracking, so if the game isn't tracking herbs there is
            -- nothing to show and nothing to go wrong. Prints, per type, what the
            -- client said and what we decided to do about it.
            local list = NS.Hud.ListTracking()
            NS.Printf("tracking: %d type(s), managed: %s", #list,
                NS.db.hudManageTracking and "|cff66ff66yes|r" or "no")
            if #list == 0 then
                NS.Print("  |cffff6666the client offered no tracking types at all.|r")
            end
            for _, t in ipairs(list) do
                if not t.readable then
                    -- The failure this whole dump exists for: C_Minimap.GetTrackingInfo
                    -- changed shape and we can no longer tell a herb from a mailbox.
                    NS.Printf("  |cffff6666%2d unreadable|r -- GetTrackingInfo said nothing", t.index)
                else
                    NS.Printf("  %2d %s%s|r  %s  want %s",
                        t.index,
                        t.active and "|cff66ff66" or "|cff888888",
                        t.name,
                        t.cat and ("|cffffcc00[" .. t.cat .. "]|r") or "[-]",
                        NS.Hud.TrackWanted(t.key, t.cat) and "on" or "off")
                end
            end

        elseif arg == "track on" or arg == "track off" then
            NS.db.hudManageTracking = (arg == "track on")
            if NS.Hud.IsActive() then NS.Hud.Disable(); NS.Hud.Enable() end
            NS.Printf("gathering-only tracking: %s", NS.db.hudManageTracking
                and "|cff66ff66on|r — only herbs/ore/timber/fish while the HUD is up"
                or  "off — the HUD shows whatever you're tracking")

        elseif arg == "sweep on" or arg == "sweep off" then
            -- Half of "why are there no blips?" -- see Hud.SetSweep. Off puts the
            -- ring, the border and the POI art back on the HUD; if the BLIPS come
            -- back with them, the sweep was eating them.
            NS.Hud.SetSweep(arg == "sweep on")
            NS.Printf("texture sweep: %s", NS.db.hudSweep
                and "|cff66ff66on|r — the map's own art is hidden"
                or  "|cffffcc00off|r — ring, border and POI art are back (diagnostic)")

        elseif arg:match("^mask") then
            -- The other half. "round" is Blizzard's own mask: if blips draw under
            -- that and not under "clear", the mask is clipping the blip layer.
            local v = arg:match("^mask%s+(%S+)$")
            if v == "clear" or v == "vignette" or v == "dim" or v == "ghost" or v == "round" then
                NS.db.hudMask = v
                NS.Hud.ApplyLook()
                if NS.Options then NS.Options.Refresh() end
                NS.Printf("mask: |cff66ff66%s|r%s", v,
                    v == "round" and " — Blizzard's own. The map is back; this is the control case."
                    or (v == "clear" and " — no map at all, blips only" or ""))
            else
                NS.Print("usage: |cffffff00/eu mask clear|ghost|dim|vignette|round|r")
                NS.Print("  |cffffff00clear|r is the point of the addon (alpha 0). |cffffff00ghost|r is alpha 1 --")
                NS.Print("  terrain you can't see, over a mask that isn't zero. |cffffff00round|r is")
                NS.Print("  Blizzard's, and it's how you tell a masking problem from anything else.")
            end

        elseif arg:match("^alpha") then
            -- The other way out, if the mask is a threshold. Frame alpha is a
            -- different mechanism from mask alpha -- so the question is whether it
            -- reaches the blips. If the map fades and the BLIPS STAY BRIGHT, we get
            -- the HUD back: Blizzard's round mask, turned down.
            local v = tonumber(arg:match("^alpha%s+([%d%.]+)$"))
            if v then
                if v > 1 then v = v / 100 end          -- accept "10" as 10%
                NS.db.hudAlpha = math.max(0, math.min(1, v))
                NS.Hud.ApplyLook()
                if NS.Options then NS.Options.Refresh() end
                NS.Printf("hud alpha: |cff66ff66%.2f|r", NS.db.hudAlpha)
                NS.Print("  Did the map fade but the blips stay bright? Then frame alpha")
                NS.Print("  doesn't reach them, and that's the way out.")
            else
                NS.Print("usage: |cffffff00/eu alpha 0-1|r  (or 0-100)")
            end

        elseif arg:match("^ring") then
            -- The compass ring: gone, or faded to whatever you can live with.
            local v = arg:match("^ring%s+(%S+)$")
            if v == "off" then
                NS.db.hudRingAlpha = 0
            elseif v == "on" then
                NS.db.hudRingAlpha = 0.25
            elseif tonumber(v) then
                local n = tonumber(v)
                if n > 1 then n = n / 100 end          -- accept "25" as 25%
                NS.db.hudRingAlpha = math.max(0, math.min(1, n))
            else
                NS.Print("usage: |cffffff00/eu ring off|on|<0-100>|r")
                NS.Print("  It's not just decoration -- the ring IS the edge of your range.")
                NS.Print("  A blip on the rim is 100 yards away. Try |cffffff00/eu ring 20|r.")
                return
            end
            NS.Hud.ApplyLook()
            NS.Printf("compass ring: %s",
                NS.db.hudRingAlpha <= 0 and "|cff888888hidden|r"
                or ("|cff66ff66%d%%|r"):format(NS.db.hudRingAlpha * 100))

        elseif arg == "combat on" or arg == "combat off" then
            NS.db.hudHideInCombat = (arg == "combat on")
            if NS.Hud.SetCombatHidden then
                NS.Hud.SetCombatHidden(NS.db.hudHideInCombat
                    and InCombatLockdown and InCombatLockdown() and true or false)
            end
            if NS.Options then NS.Options.Refresh() end
            NS.Printf("hud in combat: %s", NS.db.hudHideInCombat
                and "|cff66ff66steps aside|r — back when the fight ends (the corner map stays)"
                or  "stays up")

        elseif arg == "city on" or arg == "city off" then
            NS.db.hudHideInCity = (arg == "city on")
            NS.Hud.Refresh()
            NS.Printf("hud in cities: %s", NS.db.hudHideInCity
                and "|cff66ff66steps aside|r (town's not for gathering)"
                or  "stays up (POI clutter and all)")

        elseif arg == "map on" or arg == "map off" then
            NS.db.cornerMap = (arg == "map on")
            if NS.Hud.IsActive() then
                if NS.db.cornerMap then NS.Corner.Enable() else NS.Corner.Disable() end
            end
            NS.Printf("corner map: %s", NS.db.cornerMap
                and "|cff66ff66on|r — roads, quests, party, fog, where the minimap was"
                or  "off — just the dark disc and your buttons")

        elseif arg:match("^mapsize") then
            -- How much of the corner the MAP fills, with the frame drawn round it.
            local v = tonumber(arg:match("^mapsize%s+([%d%.]+)$"))
            if v then
                if v > 1 then v = v / 100 end          -- accept "90" as 90%
                NS.db.cornerMapScale = math.max(0.6, math.min(1, v))
                if NS.Corner then NS.Corner.ApplyShape(); NS.Corner.ApplyLook() end
                if NS.Options then NS.Options.Refresh() end
                NS.Printf("corner map size: |cff66ff66%d%%|r of the corner", NS.db.cornerMapScale * 100)
            else
                NS.Print("usage: |cffffff00/eu mapsize 60-100|r  (or 0.6-1)")
                NS.Printf("  currently %d%%. Pairs with |cffffff00/eu border|r: 100%% and a border of")
                NS.Print("  1.09 is Blizzard's own fit, where the ring lands exactly on the rim.")
            end

        elseif arg == "border auto" then
            -- Back to the size the art itself implies, whatever that turns out to be
            -- on this client -- rather than a number somebody typed once.
            NS.db.cornerBorderScale = nil
            if NS.Corner then NS.Corner.ApplyShape() end
            NS.Print("corner frame back to the size its art implies. |cffffff00/eu art|r says what that is.")

        elseif arg == "border on" or arg == "border off" then
            NS.db.cornerBorder = (arg == "border on")
            if NS.Corner then NS.Corner.ApplyShape() end
            if NS.Options then NS.Options.Refresh() end
            NS.Printf("corner frame: %s", NS.db.cornerBorder
                and "|cff66ff66on|r — if this client has real art for it (|cffffff00/eu art|r)"
                or  "off")

        elseif arg:match("^border") then
            local v = tonumber(arg:match("^border%s+([%d%.]+)$"))
            if v then
                NS.db.cornerBorderScale = math.max(1, math.min(2, v))
                if NS.Corner then NS.Corner.ApplyShape() end
                NS.Printf("corner frame size: |cff66ff66%.2fx|r the map", NS.db.cornerBorderScale)
            else
                NS.Print("usage: |cffffff00/eu border on|off|r  or  |cffffff00/eu border 1.0-2.0|r (how far it overhangs)")
            end

        elseif arg == "shape round" or arg == "shape square" then
            NS.db.cornerShape = (arg == "shape round") and "circle" or "square"
            if NS.Corner then NS.Corner.ApplyShape() end
            if NS.Options then NS.Options.Refresh() end
            NS.Printf("corner map shape: %s", NS.db.cornerShape == "circle"
                and "|cff66ff66round|r — same disc the tray is cut to"
                or  "square — Blizzard's own edges")

        elseif arg:match("^zoom") then
            local v = tonumber(arg:match("^zoom%s+([%d%.]+)$"))
            if v then
                NS.db.cornerZoom = math.max(0.2, math.min(1.0, v))
                NS.Corner.ApplyLook()
                NS.Printf("corner map zoom: %.2f (1.0 = as close as it goes)", NS.db.cornerZoom)
            else
                NS.Print("usage: |cffffff00/eu zoom 0.2-1.0|r  (1.0 = tightest)")
            end

        elseif arg == "compat on" or arg == "compat off" then
            NS.db.hudRespectOtherAddons = (arg == "compat on")
            -- Switching it back ON re-arms the question. Anyone who turns this on
            -- is asking to be warned, and "on, but I already asked you once while
            -- it was off, so never again" is not what those words mean.
            if NS.db.hudRespectOtherAddons then NS.db.hudCompatAsked = nil end
            NS.Printf("stand aside for minimap addons: %s", NS.db.hudRespectOtherAddons
                and "|cff66ff66on|r — the HUD won't claim a minimap another addon is running"
                or  "off — the HUD takes the minimap whatever else is installed")

        elseif arg == "compat reset" then
            -- Re-ask, now. Both conditions have to be put back, not just the stamp:
            -- the check only fires while the HUD is ON, and standing down turned it
            -- off. Clearing the stamp alone looks like the feature is broken.
            NS.db.hudCompatAsked = nil
            NS.db.hudEnabled = true
            NS.Hud.CheckMinimapCompat()
            if NS.db.hudCompatAsked and not NS.db.hudEnabled then
                NS.Print("compat check re-armed and it fired -- see the dialog.")
            else
                local owner = NS.Hud.MinimapOwner()
                NS.Printf("compat check re-armed. Nothing else claims the minimap%s, "
                    .. "so the HUD stays on.", owner and (" except " .. owner) or "")
            end

        elseif arg == "status" then
            NS.Hud.Report()
            NS.Printf("corner map: %s", NS.Corner.IsActive()
                and "|cff66ff66on|r" or (NS.Corner.IsAvailable() and "off" or "|cffff6666unavailable|r"))
            -- The two alphas that multiply. This is the line that would have named
            -- "the corner map came up as a ghost" in one look instead of a session.
            if NS.Corner.AlphaReport then
                NS.Printf("corner alpha: %s", NS.Corner.AlphaReport())
            end
            local owner = NS.Hud.MinimapOwner()
            if owner then
                NS.Printf("minimap also managed by: |cffffcc00%s|r", owner)
            end

        else
            -- The eight everyday ones are in the main help; these are the rest,
            -- grouped by what you'd be trying to do. Every one of them also works
            -- without the "hud" -- /eu ring 20 and /eu hud ring 20 are the same.
            NS.Print("|cff66ff66the HUD, in full.|r The everyday ones: |cffffff00/eu|r")
            print("  |cff888888look:|r    rotate on/off | ring off/<0-100> | alpha <0-1>")
            print("  |cff888888blips:|r   blips <0.5-3>  |cff888888(size is the only one the client allows)|r")
            print("  |cff888888place:|r   move | lock | centre | pos <x> <y> | size <px>")
            print("  |cff888888corner:|r  map on/off | mapalpha <10-100> | zoom <n> | shape round/square")
        print("           border on/off | border <1.0-2.0> | border auto | mapsize <60-100>")
        print("           |cffffff00/eu art|r -- what border art this client actually has")
            print("  |cff888888aside:|r   combat on/off | city on/off | corner on/off | compat on/off")
            print("  |cff888888broken?:|r status | track | track on/off | sweep on/off |")
            print("            mask clear/ghost/dim/vignette/round")
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

    elseif cmd == "debug" then
        NS.db.debug = not NS.db.debug
        NS.Print("debug " .. (NS.db.debug and "on" or "off"))

    -- ---- everything that isn't the HUD -------------------------------------
    -- One door, so the front page can stay eight lines. Nothing here was removed;
    -- it just stopped being the first thing you see when you ask for help.
    elseif cmd == "art" then
        -- Replaces "which texture should the corner map wear?" with a look at what
        -- this client actually has. See the note above Corner.ArtReport.
        if NS.Corner and NS.Corner.ArtReport then NS.Corner.ArtReport() end

    elseif cmd == "more" then
        NS.Print("|cff66ff66the rest.|r Most of this is on the options page (|cffffff00/eu|r).")
        print("  |cffffff00/eu toggle|r          the whole addon, on or off")
        print("  |cffffff00/eu cue|r             the cue: why isn't it firing? (+ lock|unlock|reset)")
        print("  |cffffff00/eu guesses|r <on|off> also point at nodes that might not be there")
        print("  |cffffff00/eu seed|r <on|off>   use GatherMate2_Data's node map, if installed")
        print("  |cffffff00/eu softtarget|r <on|off>  the setting the cue needs to confirm a node")
        print("  |cffffff00/eu near|r            what the cue can see right now, and why")
        print("  |cffffff00/eu vignettes|r       what the game is showing us, and what we make of it")
        print("  |cffffff00/eu mode|r <m>        cue | radar | both")
        print("  |cffffff00/eu priority|r <type> low/normal/high")
        print("  |cffffff00/eu mark|r <type>     drop a test node here")
        print("  |cffffff00/eu clear|r           forget this map")
        print("  |cffffff00/eu clearknown|r      reset the discovered-node list")
        print("  |cffffff00/eu debug|r           narrate everything")
        NS.Print("|cff888888When the HUD looks wrong:|r |cffffff00/eu mask|r, |cffffff00/eu sweep|r, "
            .. "|cffffff00/eu track|r, |cffffff00/eu alpha|r |cff888888-- see /eu status first.|r")

    else
        -- EIGHT LINES. This addon is the HUD, so this is the HUD -- and the word
        -- "hud" isn't in any of them, because every one of them is about it.
        NS.Print("|cff66ff66Eyes Up.|r Your minimap's blips, in the middle of your screen.")
        print("  |cffffff00/eu|r              open the options")
        print("  |cffffff00/eu on|r / |cffffff00off|r      the HUD")
        print("  |cffffff00/eu size|r <px>     how big the circle is")
        print("  |cffffff00/eu move|r          unlock and drag it; right-click to lock")
        print("  |cffffff00/eu lock|r          lock it where it is")
        print("  |cffffff00/eu centre|r        put it back in the middle")
        print("  |cffffff00/eu blips|r <0.5-3> how big the blips are (bare: what else is possible)")
        print("  |cffffff00/eu status|r        what's on, and why there might be no blips")
        NS.Print("|cff888888everything else -- the cue, filters, diagnostics:|r |cffffff00/eu more|r")
    end
end
