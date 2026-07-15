local addonName, NS = ...

-- =============================================================================
-- Probe.lua
--
-- A diagnostic. It ships, it does nothing, and it is not part of the addon --
-- nothing else reads it and nothing else depends on it. Delete this file and
-- Eyes Up works exactly as before.
--
-- WHY IT EXISTS
--
-- The addon's founding assumption, stated in every design note in this repo, is:
-- "the WoW API cannot tell you about live gathering nodes, therefore we keep a
-- database of where they've been." That is true of *enumeration* -- you cannot
-- ask for a list. But the engine will happily tell you about the single best
-- interactable near you, live, by name and by id: the soft-target system. And
-- an addon whose entire personality is "show me the ONE thing worth turning
-- for" is, suspiciously, the exact shape of an API that returns one object.
--
-- Before restructuring around that, we should find out whether it's true. Six
-- questions, none of which can be answered by reading code:
--
--   1. Does soft-target acquire herb/ore/lumber nodes at all -- and at what
--      range? (BetterFishing asks the client for 60 yards. Does it get them?)
--   2. Does it fire for nodes whose profession you DON'T have? If not,
--      "learn a node by walking past it" only works for your own professions.
--   3. Is SoftTargetInteractArc = 2 genuinely 360 degrees, or a wide cone?
--   4. Do other addons fight us for these CVars? (BetterFishing and Plater both
--      set them. On this machine. Right now.)
--   5. Does Midnight's "secret value" system hide the GUID or the name from us?
--   6. Does C_Navigation actually project a world point to a screen position --
--      i.e. is a true world-anchored HUD pin possible?
--
-- So: this file measures, and it does not conclude. It changes nothing unless
-- you explicitly ask it to, it puts back what it borrowed, and every number it
-- prints came from the client rather than from someone's memory of the client.
--
--   /eu probe            watch soft-target acquisitions and log them. START HERE --
--                        setting the CVars below does NOT start the watch.
--   /eu probe now        narrate the CURRENT soft target step by step. This is the
--                        one to reach for when the answer is "nothing happened".
--   /eu probe report     what we've learned so far
--   /eu probe yards      how big is this zone REALLY (spoiler: not 1000)
--   /eu probe cvars      what the soft-target CVars are set to, and who owns them
--   /eu probe cvars on   borrow them (360 degrees, 60 yards) -- restorable
--   /eu probe cvars off  give them back
--   /eu probe nav        can the engine project a world point to my screen?
-- =============================================================================

local Probe = {}
NS.Probe = Probe

local Data = NS.Data
local Scan = NS.Scan

local sqrt, atan2, deg, abs, floor = math.sqrt, math.atan2, math.deg, math.abs, math.floor
local PI2 = math.pi * 2

-- ---------------------------------------------------------------------------
-- Feature guards.
--
-- Every one of these is allowed to be missing. This file must never be the
-- reason someone's client throws an error at load -- it's a debugging tool, and
-- a debugging tool that breaks the thing it's debugging is a practical joke.
-- ---------------------------------------------------------------------------
local GetCVar          = C_CVar and C_CVar.GetCVar or _G.GetCVar
local SetCVar          = C_CVar and C_CVar.SetCVar or _G.SetCVar
local UnitIsGameObject = _G.UnitIsGameObject
local UnitPosition     = _G.UnitPosition
local GetNamePlateForUnit = _G.C_NamePlate and C_NamePlate.GetNamePlateForUnit

-- Midnight (12.0) can hand back values that an addon is not permitted to look
-- at. Reading one the ordinary way is an error, not a nil -- so everything that
-- touches a GUID or a unit name goes through here first. On an older client
-- Secret_CanAccess doesn't exist, and everything is readable.
local Secret_CanAccess = _G.Secret_CanAccess

local function canRead(v)
    if v == nil then return false end
    if Secret_CanAccess then return Secret_CanAccess(v) end
    return true
end

-- ---------------------------------------------------------------------------
-- What we've seen.
--
-- Deliberately NOT saved to disk. A probe run is a session, you read the report
-- at the end of it, and then you go and change the code. Persisting it would
-- just invite someone to build a feature on top of a diagnostic.
-- ---------------------------------------------------------------------------
local watching = false

local seen        = {}      -- objectID -> { name, hits, maxDist, maxAngle, gathered }
local seenCount   = 0
local acquisitions = 0
local secretHits  = 0       -- times the client refused to let us read something

-- Set once we learn the answer, so the report can state it rather than guess:
--   true  = UnitPosition("softinteract") returns coordinates for a GameObject,
--           which makes distance and bearing EXACT and this whole file easy
--   false = it doesn't, and we fall back to the walk-to estimate below
local unitPosWorks = nil

-- The object we're currently soft-targeting, and where the player was standing
-- when it was acquired. If UnitPosition doesn't work on game objects, this is
-- how we recover the acquisition distance: you eventually walk up to the node
-- and gather it, and the place you were standing when you gathered IS the node.
-- Distance from "where I first noticed it" to "where it turned out to be" is
-- the acquisition range, and the angle between them (against the facing we
-- recorded) is the arc.
local current = nil         -- { id, name, px, py, facing, t }

local function playerWorld()
    if not UnitPosition then return nil end
    -- NOTE the order. UnitPosition returns posY, posX, posZ, instanceID -- y
    -- FIRST. Getting this backwards gives you distances that are almost right,
    -- which is the worst kind of wrong.
    local y, x = UnitPosition("player")
    if not (x and y) then return nil end
    return x, y
end

local function objectWorld()
    if not UnitPosition then return nil end
    local ok, y, x = pcall(UnitPosition, "softinteract")
    if not (ok and x and y) then return nil end
    return x, y
end

-- Is there a soft-interact target, and what is it?
--
-- NOT UnitExists("softinteract"). That returns FALSE for a game object even while
-- UnitGUID, UnitName and UnitIsGameObject are all cheerfully answering about the
-- herb you're standing in front of -- a GameObject is not a "unit" in the sense
-- UnitExists means. Gating on it made this entire probe a no-op, silently, and
-- cost a farming lap to find. The GUID is the existence test.
local function softGUID()
    local guid = UnitGUID("softinteract")
    if guid == nil then return nil end
    return guid
end

-- The angle between "the way you were looking" and "where the thing turned out
-- to be", in degrees, 0 = dead ahead, 180 = directly behind you. This is the
-- answer to the arc question, and it's the reason we bother recording facing.
--
-- World coordinates: +x is north, +y is west, and GetPlayerFacing() is radians
-- counter-clockwise from north -- so atan2(dy, dx) is already in the same
-- convention and we can simply subtract. (This is NOT the same convention as
-- Data.Bearing, which works in map coords and is clockwise from north. Do not
-- copy this math into the renderers.)
local function offFacing(dx, dy, facing)
    if not facing then return nil end
    local a = atan2(dy, dx) - facing
    while a > math.pi do a = a - PI2 end
    while a < -math.pi do a = a + PI2 end
    return abs(deg(a))
end

-- GameObject-0-<server>-<instance>-<zone>-<objectID>-<spawn>
-- We want the objectID: it is numeric, it is stable, and -- unlike the item a
-- node drops -- it is the same on a German client.
local function objectIDFrom(guid)
    if guid == nil then return nil end          -- nothing there. Not the same as "hidden".
    if not canRead(guid) then
        secretHits = secretHits + 1
        return nil, true                        -- there, but 12.0 won't let us look
    end
    local unitType, id = guid:match("^(%a+)%-0%-%d*%-%d*%-%d*%-(%d*)")
    if unitType ~= "GameObject" or not id then return nil end
    return tonumber(id)
end

local function note(id, name)
    local rec = seen[id]
    if not rec then
        rec = { name = name, hits = 0, maxDist = 0, maxAngle = 0, gathered = false }
        seen[id] = rec
        seenCount = seenCount + 1
    end
    rec.hits = rec.hits + 1
    if name and name ~= "" then rec.name = name end
    return rec
end

-- ---------------------------------------------------------------------------
-- Looking at whatever we're currently soft-targeting.
--
-- The first cut of this trusted PLAYER_SOFT_INTERACT_CHANGED and silently
-- ignored anything that wasn't a GameObject. Which meant a run that logged
-- NOTHING could mean any of four completely different things -- the event never
-- fired, the token never resolved, it resolved to creatures only, or the GUID
-- didn't parse -- and there was no way to tell them apart. A diagnostic whose
-- null result is ambiguous is not a diagnostic.
--
-- So now: we POLL (the event is a bonus, not a dependency), and we report every
-- soft target we ever see, node or not. A creature in the log is a real finding:
-- it proves the system is live and that gathering nodes specifically aren't
-- being offered. Silence now means silence, and means something.
-- ---------------------------------------------------------------------------
-- ---------------------------------------------------------------------------
-- What does the CURSOR say it is?
--
-- The classifier currently leans on GatherMate's species list to decide whether
-- "Tranquility Bloom" is a herb and "Stool" is furniture. That's a dependency,
-- and we don't want one.
--
-- But the game already knows. Hover a vein and you get a pickaxe; hover a herb and
-- you get something else; hover a chest and you get a hand. SetUnitCursorTexture
-- hands that art to an addon (it's how Plumber draws its interact icon), and if we
-- can read the ATLAS NAME back off it, the client is telling us -- natively, in
-- every locale, with no addon installed -- what kind of thing this is.
--
-- This prints the atlas so we can find out whether it discriminates. If it does,
-- the GatherMate dependency dies.
-- ---------------------------------------------------------------------------
local cursorTex

local function cursorAtlas()
    if not _G.SetUnitCursorTexture then return nil end
    if not cursorTex then
        cursorTex = UIParent:CreateTexture(nil, "ARTWORK")
        cursorTex:Hide()
    end
    local ok, has = pcall(SetUnitCursorTexture, cursorTex, "softinteract")
    if not (ok and has) then return nil end
    return cursorTex:GetAtlas() or cursorTex:GetTexture()
end

-- ---------------------------------------------------------------------------
-- The other reticle.
--
-- Soft-target is capped by a game object's interact distance -- about fifteen to
-- twenty-five yards -- and there is nothing we can do about that.
--
-- But "softinteract" is not the only unit token that can resolve to a GameObject.
-- There is also "mouseover". And when you fly with the right button held, the
-- centre of your screen IS the mouse: the client raycasts the world under it every
-- frame, for free, and it is pointed at precisely the thing you are looking at.
--
-- If UnitIsGameObject("mouseover") resolves for a herb you are merely LOOKING at,
-- rather than standing on, then the game will tell us what's out there at whatever
-- range hover-tooltips reach -- which is a great deal further than you can reach
-- with your hand, and which is not a prediction, not a database, and not a ghost.
-- It's the thing itself, and the player aimed at it.
--
-- I don't know whether it works. Nobody's list of addon APIs would tell me. So we
-- log it: every game object that passes under the reticle, and how far away it was
-- (measured against the seed data, same ruler as everything else).
-- ---------------------------------------------------------------------------
local mouseSeen, mouseCount = {}, 0
local mouseMax = 0
local lastMouseGUID = nil

local function checkMouseover()
    local guid = UnitGUID("mouseover")
    if not canRead(guid) then return end
    if guid == lastMouseGUID then return end
    lastMouseGUID = guid

    local id = objectIDFrom(guid)
    if not id then return end                       -- a creature, or a player

    local name = UnitName("mouseover")
    if not canRead(name) then return end

    -- How far is the thing we're LOOKING at? Same trick as soft-target: the engine
    -- names it but won't place it, so ask the seed data where that species stands.
    local dist
    local mapID, px, py = Data.GetPlayerPosition()
    if mapID and NS.Seed then
        local _, d = NS.Seed.LocateByName(mapID, px, py, name, 300)
        dist = d
    end

    if not mouseSeen[id] then
        mouseSeen[id] = name
        mouseCount = mouseCount + 1
    end
    if dist and dist > mouseMax then mouseMax = dist end

    NS.Printf("|cffff99ff[mouseover]|r %s  id=%d%s", name, id,
        dist and ("  |cff66ff66%.1f yd|r"):format(dist) or "  (can't place it)")
end

local lastGUID = nil

-- Where we were standing the FIRST time we ever saw each object this session,
-- keyed by GUID.
--
-- It has to be the first time, and it has to be per-object. Walking up to a node
-- the soft target flickers -- this herb, that one, back to the first -- and if
-- each re-acquisition overwrote the sighting position with wherever you'd got to
-- by then, the measured range would collapse toward zero. Which is precisely the
-- number we're trying to establish, so it would have looked like an answer.
local firstSeen = {}

local function inspect(loud)
    local guid = softGUID()
    if not guid then
        if loud then NS.Print("nothing soft-targeted right now. Face a node and stand closer.") end
        -- NOTE: `current` deliberately survives. The node despawns the instant you
        -- gather it, so if we cleared this here, the gather that resolves the
        -- measurement would arrive to find nothing to measure against.
        lastGUID = nil
        return
    end

    if not loud and guid == lastGUID then return end   -- same thing as last poll
    lastGUID = guid

    local isObject = UnitIsGameObject and UnitIsGameObject("softinteract")
    local id, wasSecret = objectIDFrom(guid)

    local rawName = UnitName("softinteract")
    local name = canRead(rawName) and rawName or nil
    if rawName and not name then
        secretHits = secretHits + 1
        name = "|cffff6666<secret>|r"
    end

    if wasSecret then
        NS.Print("|cffff6666soft-target GUID came back SECRET|r -- 12.0 is hiding it from us.")
        return
    end

    -- Not a game object. Say so anyway -- this is the single most useful line in
    -- the whole file when nothing else is showing up.
    if not id then
        NS.Printf("|cff888888soft-target: %s -- not a game object|r (%s)",
            name or "?", tostring(guid):match("^(%a+)") or "?")
        return
    end

    acquisitions = acquisitions + 1
    local rec = note(id, name)

    local px, py = playerWorld()
    local facing = GetPlayerFacing()

    -- The good path: the engine tells us where the OBJECT is, so distance and
    -- bearing are exact and immediate. Test it once, remember the answer.
    local ox, oy = objectWorld()
    if unitPosWorks == nil then
        unitPosWorks = (ox ~= nil)
        NS.Printf("UnitPosition(\"softinteract\") %s for game objects.",
            unitPosWorks and "|cff66ff66WORKS|r -- exact ranges from here on"
                          or "|cffffcc00returns nil|r -- falling back to walk-to estimates")
    end

    local dist, angle
    if ox and px then
        local dx, dy = ox - px, oy - py
        dist  = sqrt(dx * dx + dy * dy)
        angle = offFacing(dx, dy, facing)
    end

    -- The engine wouldn't tell us where the object is. But GatherMate knows where
    -- every node of THIS SPECIES is, and soft-target just told us the species. So
    -- ask the seed data, and get an exact range the moment it acquires -- no
    -- walking to it, no gathering it, no estimating.
    --
    -- This is the measurement the design hangs on. See Seed.LocateByName.
    if not dist and name and NS.Seed then
        local mapID, px2, py2 = Data.GetPlayerPosition()
        if mapID then
            local _, d, bearing = NS.Seed.LocateByName(mapID, px2, py2, name, 250)
            if d then
                dist = d
                -- Bearing is a compass angle clockwise from north; GetPlayerFacing
                -- is counter-clockwise from north. They cancel -- hence PLUS, not
                -- minus. (Same identity both renderers rely on; see CLAUDE.md.)
                if facing and bearing then
                    local rel = bearing + facing
                    while rel > math.pi do rel = rel - PI2 end
                    while rel < -math.pi do rel = rel + PI2 end
                    angle = abs(deg(rel))
                end
            end
        end
    end

    if dist then
        if dist > rec.maxDist then rec.maxDist = dist end
        if angle and angle > rec.maxAngle then rec.maxAngle = angle end
    end

    -- Park where we were standing the first time this object appeared -- and only
    -- the first time. Re-acquiring it as you close in must not move the goalpost.
    local seenAt = firstSeen[guid]
    if not seenAt then
        seenAt = { id = id, name = name, px = px, py = py, facing = facing, t = GetTime() }
        firstSeen[guid] = seenAt
    end
    current = seenAt

    local nameplate = GetNamePlateForUnit and GetNamePlateForUnit("softinteract")

    NS.Printf("|cff66ccff%s|r  id=%d%s%s%s%s",
        name or "?", id,
        isObject and "  gameobject" or "  |cffffcc00not flagged as a game object|r",
        dist  and ("  |cff66ff66%.1f yd|r"):format(dist) or "",
        angle and ("  %.0f° off-facing"):format(angle) or "",
        nameplate and "  |cff66ff66has nameplate|r" or "")

    -- The thing that could kill the GatherMate dependency. If a herb and a vein
    -- and a chest print DIFFERENT atlases here, the game is classifying them for
    -- us and we never have to ask an addon.
    local atlas = cursorAtlas()
    NS.Printf("    cursor: %s", atlas and ("|cffffff00" .. tostring(atlas) .. "|r")
                                        or "|cff888888(none)|r")
end

-- The one-shot. Stand next to a node, look at it, run `/eu probe now`, and this
-- narrates every single step so we can see exactly where the chain breaks.
local function inspectNow()
    NS.Print("---- what am I soft-targeting, right now ----")

    local iv = GetCVar and GetCVar("SoftTargetInteract")
    NS.Printf("  SoftTargetInteract = %s %s", tostring(iv),
        (iv == "2" or iv == "3") and "|cff66ff66(ok)|r"
            or "|cffff6666(must be 2 or 3 -- run /eu probe cvars on)|r")

    -- Printed only as a curiosity, and labelled as a liar. It says false for a
    -- game object even when everything below it answers perfectly. Do not gate on
    -- it. (This addon did, and measured nothing for an entire farming lap.)
    NS.Printf("  UnitExists               = %s |cff888888<- always false for objects; ignore it|r",
        (UnitExists and UnitExists("softinteract")) and "true" or "false")
    NS.Printf("  UnitIsGameObject         = %s",
        UnitIsGameObject and tostring(UnitIsGameObject("softinteract")) or "|cffffcc00no such API|r")

    local guid = softGUID()
    NS.Printf("  UnitGUID                 = %s |cff888888<- THIS is the existence test|r",
        canRead(guid) and tostring(guid) or "|cffff6666<secret or nil>|r")
    NS.Printf("  UnitName                 = %s", tostring(canRead(UnitName("softinteract")) and UnitName("softinteract")))
    NS.Printf("  parsed objectID          = %s", tostring(objectIDFrom(guid)))
    NS.Printf("  cursor atlas             = %s |cff888888<- if herb/vein/chest differ here,|r",
        tostring(cursorAtlas()))
    NS.Print("                                        |cff888888the GatherMate dependency dies|r")

    inspect(true)
end

-- You are now standing on the thing. If we couldn't ask the engine where the
-- object was, this is the next best answer: the node is wherever you were when
-- you successfully gathered it.
local function onGatherCast(spellID)
    if not (watching and current) then return end
    if unitPosWorks then return end          -- we already had the exact number

    local info = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(spellID)
    local sname = info and info.name
    if not (sname and NS.GatherSpellNames[sname]) then return end

    local px, py = playerWorld()
    if not (px and current.px) then return end

    local dx, dy = px - current.px, py - current.py
    local dist = sqrt(dx * dx + dy * dy)
    local angle = offFacing(dx, dy, current.facing)

    local rec = seen[current.id]
    if rec then
        rec.gathered = true
        if dist > rec.maxDist then rec.maxDist = dist end
        if angle and angle > rec.maxAngle then rec.maxAngle = angle end
    end

    NS.Printf("  ...walked |cff66ff66%.1f yd|r to %s (acquired %.0f° off-facing)",
        dist, current.name or "it", angle or 0)
    current = nil
end

-- ---------------------------------------------------------------------------
-- The CVars.
--
-- These are the player's, not ours. Soft-target at 360 degrees and 60 yards
-- changes what the Interact key does -- press it and you may well interact with
-- something across the field. That is an intrusion, so it is opt-in, it is
-- announced, and it is put back.
--
-- The snapshot is taken at load, BEFORE we touch anything, and hooksecurefunc
-- keeps it honest: if another addon (BetterFishing and Plater both want these)
-- changes one behind our back, we record their value as the new "original"
-- rather than cheerfully restoring a stale one over the top of it.
-- ---------------------------------------------------------------------------
local CVAR_LIST = {
    "SoftTargetInteract",       -- 0 off .. 3 always
    "SoftTargetInteractArc",    -- 0 ahead .. 2 (allegedly) any direction
    "SoftTargetInteractRange",  -- yards
    "SoftTargetIconGameObject", -- draw the little interact icon on the object
}

local WANT = {
    SoftTargetInteract      = "3",
    SoftTargetInteractArc   = "2",
    SoftTargetInteractRange = "60",
}

local original = {}
local held     = false      -- are OUR values currently installed?
local stolen   = {}         -- cvar -> true, if someone changed it while we held it

do
    for _, c in ipairs(CVAR_LIST) do original[c] = GetCVar and GetCVar(c) end
end

if C_CVar and hooksecurefunc then
    hooksecurefunc(C_CVar, "SetCVar", function(cvar, value)
        if not cvar then return end
        for _, c in ipairs(CVAR_LIST) do
            if cvar:lower() == c:lower() then
                if held and WANT[c] and tostring(value) ~= WANT[c] then
                    -- Somebody else is driving. Question 4, answered live.
                    -- (Only the CVars we actually asked for count as contested --
                    -- WANT has no opinion about SoftTargetIconGameObject, so an
                    -- addon setting that one isn't fighting us.)
                    stolen[c] = true
                    NS.Printf("|cffff6666another addon just set %s = %s|r (we wanted %s)",
                        c, tostring(value), WANT[c])
                elseif not held then
                    original[c] = tostring(value)
                end
                return
            end
        end
    end)
end

local function cvarsReport()
    NS.Print("soft-target CVars:")
    for _, c in ipairs(CVAR_LIST) do
        local v = GetCVar and GetCVar(c)
        print(("  |cffffff00%-26s|r %s%s"):format(c, tostring(v),
            stolen[c] and "  |cffff6666(someone else changed this)|r" or ""))
    end
    print(held and "  |cff66ff66we are currently holding these|r"
                or "  (untouched -- these are yours)")
end

local function cvarsOn()
    if not SetCVar then return NS.Print("no CVar API on this client.") end
    if held then return NS.Print("already holding them.") end
    if InCombatLockdown and InCombatLockdown() then
        return NS.Print("not in combat. Try again when things calm down.")
    end
    for _, c in ipairs(CVAR_LIST) do original[c] = GetCVar(c) end
    held = true
    wipe(stolen)
    for c, v in pairs(WANT) do SetCVar(c, v) end
    NS.Print("borrowed the soft-target CVars: |cffffff00360°, 60 yards, always on|r.")
    NS.Print("your Interact key now reaches a lot further. |cffffff00/eu probe cvars off|r puts it back.")

    -- Setting the CVars is not the same as switching the probe on, and assuming
    -- otherwise cost a whole farming lap.
    if not watching then
        NS.Print("|cffff6666...but the probe itself isn't running.|r Run |cffffff00/eu probe|r or nothing is being recorded.")
    end
end

local function cvarsOff()
    if not SetCVar then return end
    if not held then return NS.Print("we weren't holding them.") end
    held = false
    for _, c in ipairs(CVAR_LIST) do
        if original[c] ~= nil then SetCVar(c, original[c]) end
    end
    NS.Print("gave the soft-target CVars back.")
end

-- ---------------------------------------------------------------------------
-- How big is this zone, really?
--
-- This is the question that started all this. The addon used to assume every
-- zone was 1000 yards across, both axes; Zul'Aman is 8950 x 5967. Now it asks
-- (Data.MapSize), so this report is no longer an indictment -- it's a check that
-- the client is answering, and a sanity read on the numbers the addon is using.
-- ---------------------------------------------------------------------------
local function yardsReport()
    local mapID = C_Map.GetBestMapForUnit("player")
    if not mapID then return NS.Print("no map. Are you in a cinematic?") end

    local info = C_Map.GetMapInfo(mapID)
    NS.Printf("zone: %s (map %d)", info and info.name or "?", mapID)

    -- Straight from the source the addon now uses, so this doubles as a check
    -- that Data.MapSize is getting a real answer here rather than the fallback.
    local w, h = Data.MapSize(mapID)
    NS.Printf("  true size:   |cff66ff66%.0f x %.0f yards|r  (aspect %.2f:1)",
        w, h, math.max(w, h) / math.min(w, h))
    if w == NS.FALLBACK_ZONE_YARDS and h == NS.FALLBACK_ZONE_YARDS then
        NS.Print("  |cffff6666...that's the FALLBACK|r -- the client wouldn't size this map.")
    end

    local det = NS.db and NS.db.detectionYards or 60
    NS.Printf("  detection:   |cff66ff66%d yards|r, and it now genuinely means %d yards", det, det)

    local px, py = playerWorld()
    NS.Printf("  UnitPosition(player): %s",
        px and ("|cff66ff66%.1f, %.1f|r (world yards, free, no library)"):format(px, py)
            or "|cffff6666nil|r -- restricted here (instance?)")

    if C_Minimap and C_Minimap.GetViewRadius then
        local r = C_Minimap.GetViewRadius()
        NS.Printf("  minimap view radius: |cff66ff66%s yards|r at the current zoom", tostring(r and floor(r) or "?"))
    end
end

-- ---------------------------------------------------------------------------
-- Can the engine put a world point on my screen?
--
-- This is the HUD question, and it's the one with teeth. C_Navigation.GetFrame()
-- is supposed to return a frame that the ENGINE repositions every frame at the
-- projected screen position of whatever you're super-tracking. If that's true,
-- an icon can sit on the actual herb instead of near the middle of the screen
-- pointing at it.
--
-- To test it we have to super-track something, which means borrowing the
-- player's waypoint. So we take it, watch it for ten seconds, and give it back.
-- ---------------------------------------------------------------------------
local navFrame, navTicker
local savedWaypoint, savedTracking

local function navRestore()
    if navTicker then navTicker:Cancel(); navTicker = nil end
    C_Map.ClearUserWaypoint()
    if savedWaypoint then
        C_Map.SetUserWaypoint(savedWaypoint)
        if savedTracking then C_SuperTrack.SetSuperTrackedUserWaypoint(true) end
    end
    savedWaypoint, savedTracking = nil, nil
    NS.Print("nav test done; your waypoint is back where it was.")
end

local function navTest()
    if not C_Navigation then return NS.Print("no C_Navigation on this client. No world HUD.") end

    local r = Scan and Scan.result
    local target = r and r.valid and r.nearest
    if not target then
        return NS.Print("nothing in range to aim at. Stand near a known node (or /eu demo first).")
    end

    local mapID = r.mapID
    if C_Map.CanSetUserWaypointOnMap and not C_Map.CanSetUserWaypointOnMap(mapID) then
        return NS.Print("this map doesn't allow user waypoints, so we can't test the nav frame here.")
    end

    -- Borrow.
    savedWaypoint = C_Map.GetUserWaypoint()
    savedTracking = C_SuperTrack.IsSuperTrackingUserWaypoint and C_SuperTrack.IsSuperTrackingUserWaypoint()

    local node = target.node
    C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(mapID, node.x, node.y))
    C_SuperTrack.SetSuperTrackedUserWaypoint(true)

    NS.Printf("super-tracking the nearest %s (%s). Watching the nav frame for 10s --",
        NS.NodeTypeLabel[node.type] or node.type, node.name or "unnamed")
    NS.Print("turn around, walk away, put a hill between you and it.")

    local elapsed = 0
    navTicker = C_Timer.NewTicker(1, function()
        elapsed = elapsed + 1

        navFrame = C_Navigation.GetFrame and C_Navigation.GetFrame()
        local hasPos = C_Navigation.HasValidScreenPosition and C_Navigation.HasValidScreenPosition()
        local clamped = C_Navigation.WasClampedToScreen and C_Navigation.WasClampedToScreen()
        local state = C_Navigation.GetTargetState and C_Navigation.GetTargetState()
        local dist  = C_Navigation.GetDistance and C_Navigation.GetDistance()

        local sx, sy
        if navFrame and navFrame.GetCenter then sx, sy = navFrame:GetCenter() end

        NS.Printf("  frame=%s  screen=%s  onscreen=%s  clamped=%s  state=%s  dist=%s",
            navFrame and "|cff66ff66yes|r" or "|cffff6666nil|r",
            sx and ("%.0f,%.0f"):format(sx, sy) or "-",
            hasPos and "|cff66ff66yes|r" or "no",
            clamped and "|cffffcc00yes (behind you)|r" or "no",
            tostring(state),
            dist and ("|cff66ff66%.0f yd|r"):format(dist) or "-")

        if elapsed >= 10 then navRestore() end
    end, 10)
end

-- ---------------------------------------------------------------------------
-- The long shot.
--
-- Soft-target caps at ~14 yards and hands back exactly ONE object with no
-- position. Nameplates are the opposite on both counts: the engine creates a
-- frame per unit, positions it in SCREEN SPACE over the thing itself, and game
-- objects can have them (Plater and Plumber both style them).
--
-- If the client spawns a nameplate for every nearby interactable, then
-- C_NamePlate.GetNamePlates() is a live, positioned, multi-node source -- which is
-- everything soft-target isn't, and it would make a real world-anchored HUD
-- possible for herbs.
--
-- I doubt it. I think retail only ever plates the single soft-interact target.
-- But it costs fifteen lines to find out and the payoff would be the whole addon,
-- so: stand in a patch with several nodes around you and run this.
-- ---------------------------------------------------------------------------
local function platesTest()
    if not (C_NamePlate and C_NamePlate.GetNamePlates) then
        return NS.Print("no C_NamePlate on this client.")
    end

    NS.Print("---- nameplates right now ----")
    NS.Printf("  nameplateShowAll=%s  SoftTargetNameplateInteract=%s  maxDistance=%s",
        tostring(GetCVar and GetCVar("nameplateShowAll")),
        tostring(GetCVar and GetCVar("SoftTargetNameplateInteract")),
        tostring(GetCVar and GetCVar("nameplateMaxDistance")))

    -- These are the settings that would let the engine plate more than one object,
    -- if it is ever willing to. Turn them all the way up before concluding it
    -- isn't -- the same mistake I made with SoftTargetInteractRange.
    if not (GetCVar and GetCVar("SoftTargetNameplateInteract") == "1") then
        NS.Print("  |cffffcc00try first:|r /console SoftTargetNameplateInteract 1")
        NS.Print("  |cffffcc00then:|r      /console nameplateShowAll 1")
    end

    local plates = C_NamePlate.GetNamePlates() or {}
    local objects = 0

    for _, plate in ipairs(plates) do
        local unit = plate.namePlateUnitToken
        if unit then
            local isObj = UnitIsGameObject and UnitIsGameObject(unit)
            local nm = UnitName(unit)
            if not canRead(nm) then nm = "<secret>" end

            if isObj then
                objects = objects + 1
                -- A world-anchored screen position, handed to us by the engine.
                local x, y = plate:GetCenter()
                NS.Printf("  |cff66ff66OBJECT|r %-24s screen %s",
                    tostring(nm), x and ("%.0f,%.0f"):format(x, y) or "?")
            else
                NS.Printf("  |cff888888unit  |r %s", tostring(nm))
            end
        end
    end

    NS.Printf("%d nameplates, |cffffff00%d|r of them game objects.", #plates, objects)
    if objects > 1 then
        NS.Print("|cff66ff66MORE THAN ONE OBJECT PLATED.|r That's a live, positioned, multi-node")
        NS.Print("source. Tell Claude immediately -- it changes the whole design.")
    elseif objects == 1 then
        NS.Print("|cffffcc00Only one|r -- that'll be the soft-target. No better than what we have.")
    else
        NS.Print("|cffffcc00No objects plated.|r Try /console SoftTargetNameplateInteract 1")
        NS.Print("and stand next to a node, then run this again.")
    end
end

-- ---------------------------------------------------------------------------
-- THE MINIMAP, RECONSIDERED.
--
-- Everything in this addon exists because an addon cannot READ the minimap's
-- tracking blips. That's still true -- the Minimap widget has thirty-odd methods
-- and not one of them returns a blip position. The engine draws them and tells
-- Lua nothing.
--
-- But we may have been asking the wrong question. We don't need to READ the
-- blips. The player's tracking is already on -- Find Herbs, Find Minerals, Find
-- Lumber, Find Fish -- and the engine is already drawing perfect, live, truthful
-- markers for every node around them. They're just in the corner of the screen,
-- which is the entire problem this addon was written to solve.
--
-- So: don't duplicate the data. MOVE THE DISPLAY.
--
-- Three things to find out, and all three are cheap:
--
--   1. Can a SECOND Minimap exist? The wiki says "in the stock UI there is only
--      one unique Minimap object" -- which is a careful sentence that does not
--      say CreateFrame("Minimap") fails. If it works and it renders blips, we get
--      a heads-up minimap AND you keep the one in your corner. That's the prize.
--
--   2. Does SetMaskTexture hide the TERRAIN but keep the BLIPS? The mask shapes
--      the minimap through its alpha channel. If the blips are drawn on top of
--      the mask rather than clipped by it, a transparent mask gives us floating
--      node markers over the world with no map behind them. That IS the HUD.
--
--   3. Does SetBlipTexture still work in 12.0? It's how Blipstick and
--      DerangementMinimapBlips make tracking dots bigger and easier to read. One
--      source says Midnight removed it. The wiki still lists it. Only the client
--      knows.
-- ---------------------------------------------------------------------------
local secondMap

local function minimapTest()
    NS.Print("---- what will the minimap let us do? ----")

    if not Minimap then return NS.Print("no Minimap object?!") end

    local w, h = Minimap:GetSize()
    NS.Printf("  the real one: %.0fx%.0f  zoom %s/%s  view radius %s yd",
        w, h, tostring(Minimap:GetZoom()),
        Minimap.GetZoomLevels and tostring(Minimap:GetZoomLevels()) or "?",
        C_Minimap and C_Minimap.GetViewRadius and tostring(floor(C_Minimap.GetViewRadius() or 0)) or "?")

    -- 1. A SECOND MINIMAP.
    if not secondMap then
        local ok, frame = pcall(CreateFrame, "Minimap", "EyesUpHUDMinimap", UIParent)
        if ok and frame then
            secondMap = frame
            frame:SetSize(200, 200)
            frame:SetPoint("CENTER", UIParent, "CENTER", 0, 120)
            frame:SetFrameStrata("BACKGROUND")
            frame:SetAlpha(0.85)
            if frame.SetZoom then pcall(frame.SetZoom, frame, 0) end
            frame:Show()
            NS.Print("  |cff66ff66CreateFrame(\"Minimap\") SUCCEEDED.|r A second one exists.")
            NS.Print("  |cff66ff66Look just above the middle of your screen.|r")
            NS.Print("  Does it draw the world? Does it draw NODE BLIPS? That's the whole question.")
            NS.Print("  |cffffff00/eu probe minimap off|r to remove it.")
        else
            NS.Print("  |cffff6666CreateFrame(\"Minimap\") failed.|r Only one minimap can exist.")
            NS.Print("  So a HUD means MOVING the real one -- try |cffffff00/eu probe hud|r.")
        end
    else
        NS.Print("  second minimap already up. |cffffff00/eu probe minimap off|r to remove.")
    end

    -- 2 and 3: what the widget will still let us do to it.
    NS.Printf("  SetMaskTexture  : %s", Minimap.SetMaskTexture and "|cff66ff66present|r" or "|cffff6666gone|r")
    NS.Printf("  SetBlipTexture  : %s", Minimap.SetBlipTexture
        and "|cff66ff66present|r -- blips can be restyled/enlarged"
        or  "|cffff6666REMOVED in 12.0|r -- blips are Blizzard's, as-is")
    NS.Printf("  UpdateBlips     : %s", Minimap.UpdateBlips and "|cff66ff66present|r" or "gone")
end

local function minimapOff()
    if secondMap then
        secondMap:Hide()
        secondMap:SetParent(nil)
        secondMap = nil
        NS.Print("second minimap removed.")
    else
        NS.Print("no second minimap up.")
    end
end

-- ---------------------------------------------------------------------------
-- Plan B: if only one Minimap can exist, bring THAT one to the middle.
--
-- Invasive -- it is literally your minimap, and it will leave its corner. But it
-- is also the entire idea, tested in ten seconds: real blips, real positions,
-- drawn by the engine, floating where you're already looking.
--
-- Everything is saved and put back. A /reload also fixes it, because Blizzard
-- re-anchors the cluster on load.
-- ---------------------------------------------------------------------------
local hudSaved, hudOn = nil, false

local function hudTest()
    if hudOn then
        if hudSaved then
            Minimap:SetParent(hudSaved.parent)
            Minimap:ClearAllPoints()
            Minimap:SetPoint(unpack(hudSaved.point))
            Minimap:SetSize(hudSaved.w, hudSaved.h)
            Minimap:SetAlpha(hudSaved.alpha)
            Minimap:SetFrameStrata(hudSaved.strata)
            if Minimap.SetMaskTexture and hudSaved.mask then
                pcall(Minimap.SetMaskTexture, Minimap, hudSaved.mask)
            end
        end
        hudOn = false
        NS.Print("minimap put back. (/reload if it looks odd.)")
        return
    end

    hudSaved = {
        parent = Minimap:GetParent(),
        point  = { Minimap:GetPoint(1) },
        w = select(1, Minimap:GetSize()),
        h = select(2, Minimap:GetSize()),
        alpha  = Minimap:GetAlpha(),
        strata = Minimap:GetFrameStrata(),
        -- There's no GetMaskTexture, so remember Blizzard's round one by name.
        mask   = "Interface\\CHARACTERFRAME\\TempPortraitAlphaMask",
    }

    Minimap:SetParent(UIParent)
    Minimap:ClearAllPoints()
    Minimap:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    Minimap:SetSize(400, 400)
    Minimap:SetAlpha(0.30)
    Minimap:SetFrameStrata("BACKGROUND")
    hudOn = true

    NS.Print("your minimap is now |cff66ff66in the middle of your screen|r, big and faint.")
    NS.Print("Now try |cffffff00/eu probe mask clear|r -- that's the question that matters.")
    NS.Print("|cffffff00/eu probe hud|r again to put it back.")
end

-- ---------------------------------------------------------------------------
-- THE QUESTION THAT DECIDES HOW GOOD THIS CAN BE.
--
-- SetMaskTexture shapes the minimap through the mask's ALPHA channel. What we
-- don't know is whether the tracking blips are subject to that mask or drawn on
-- top of it.
--
--   * If they're MASKED, a clear mask erases everything and the best we can ever
--     do is a faint minimap floating in the middle of your screen. Which is still
--     a real feature, and still made of true data -- just not beautiful.
--
--   * If they're UNMASKED, a clear mask leaves us with NOTHING BUT THE BLIPS:
--     live, engine-drawn node markers hanging over the actual world, at full
--     tracking range, with no map behind them. That is precisely the heads-up
--     display this addon has spent its whole life trying to fake out of a
--     database, and it would be handed to us for free by the game.
--
-- One command tells us which.
-- ---------------------------------------------------------------------------
local MASKS = {
    clear    = NS.CustomGlyphDir .. "MASK_CLEAR",     -- alpha 0 everywhere
    dim      = NS.CustomGlyphDir .. "MASK_DIM",       -- alpha 64 everywhere
    vignette = NS.CustomGlyphDir .. "MASK_VIGNETTE",  -- soft, fades out at the edge
    round    = "Interface\\CHARACTERFRAME\\TempPortraitAlphaMask",  -- Blizzard's
}

local function maskTest(which)
    if not Minimap.SetMaskTexture then
        return NS.Print("|cffff6666SetMaskTexture is gone in this client.|r Nothing to try.")
    end

    local tex = MASKS[which]
    if not tex then
        NS.Print("usage: |cffffff00/eu probe mask clear|dim|vignette|round|r")
        NS.Print("  |cffffff00clear|r -- fully transparent. If BLIPS SURVIVE THIS, we've won:")
        NS.Print("           node markers floating over the world, no map behind them.")
        NS.Print("  |cffffff00dim|r/|cffffff00vignette|r -- softer versions, in case clear kills everything.")
        NS.Print("  |cffffff00round|r -- Blizzard's, to put it back.")
        return
    end

    local ok = pcall(Minimap.SetMaskTexture, Minimap, tex)
    if not ok then return NS.Print("SetMaskTexture threw. Odd.") end
    if Minimap.UpdateBlips then pcall(Minimap.UpdateBlips, Minimap) end

    NS.Printf("mask: |cffffff00%s|r", which)
    if which == "clear" then
        NS.Print("|cff66ff66Look at the middle of your screen.|r")
        NS.Print("  Blips still there, terrain gone?  -> we have a real HUD. Tell Claude.")
        NS.Print("  Everything gone?                  -> blips are masked; the faint map is our ceiling.")
    end
end

-- ---------------------------------------------------------------------------
-- CAN WE BUILD A REAL MAP FOR THE CORNER?
--
-- Moving the minimap to the middle of the screen costs you the minimap. The blips
-- were the valuable part and we've kept them -- but the terrain, the roads, the
-- quest pins, the party dots and the fog all went with it, and those are the
-- reasons you'd ever glance at a corner map in the first place.
--
-- The idea: build a replacement out of the WORLD MAP's machinery. MapCanvasMixin
-- is the framework WorldMapFrame is made of, and its data providers do all the pin
-- work already -- quests, area POIs, group members, vignettes, fog of war. Blizzard
-- ships a small one: the Battlefield Map is a MapCanvas in a movable window. So the
-- pattern is proven; the question is whether an addon can instantiate it.
--
-- What it CANNOT do, and this is the whole reason it's a companion and not a
-- replacement: a MapCanvas cannot draw gathering blips. Those are minimap-only,
-- engine-drawn, and unreachable -- which is the entire premise of this addon. So
-- the split would be:
--
--     the HUD   -- Blizzard's tracking blips, at your eye. What's gatherable.
--     the corner -- a MapCanvas. Where you ARE. Roads, quests, party, fog.
--
-- That's a real division of labour, not a workaround.
--
-- Before writing several hundred lines of it, find out what actually exists on
-- this client. UnitPositionFrame and FogOfWarFrame are undocumented widget types
-- that show up in the Widget API list -- if CreateFrame will make one, they're how
-- the party dots and the fog get drawn, and half the work is already done.
-- ---------------------------------------------------------------------------
local function canvasTest()
    NS.Print("---- can we build a map canvas? ----")

    local function has(name) return _G[name] ~= nil end

    NS.Printf("  MapCanvasMixin             %s", has("MapCanvasMixin") and "|cff66ff66yes|r" or "|cffff6666no|r")
    NS.Printf("  MapCanvasDataProviderMixin %s", has("MapCanvasDataProviderMixin") and "|cff66ff66yes|r" or "|cffff6666no|r")
    NS.Printf("  MapCanvasPinMixin          %s", has("MapCanvasPinMixin") and "|cff66ff66yes|r" or "|cffff6666no|r")

    NS.Print("  data providers (these do the pin work for us):")
    for _, p in ipairs({
        "QuestDataProviderMixin", "AreaPOIDataProviderMixin",
        "GroupMembersDataProviderMixin", "VignetteDataProviderMixin",
        "MapExplorationDataProviderMixin", "MapHighlightDataProviderMixin",
        "WorldQuestDataProviderMixin", "StorylineQuestDataProviderMixin",
    }) do
        NS.Printf("    %-32s %s", p, has(p) and "|cff66ff66yes|r" or "|cff888888no|r")
    end

    -- The two undocumented widget types. If these instantiate, the party dots and
    -- the fog of war are solved problems and we're mostly gluing.
    NS.Print("  undocumented widget types:")
    for _, t in ipairs({ "UnitPositionFrame", "FogOfWarFrame" }) do
        local ok, f = pcall(CreateFrame, t, nil, UIParent)
        if ok and f then
            NS.Printf("    %-20s |cff66ff66CREATED|r (objectType=%s)", t,
                f.GetObjectType and f:GetObjectType() or "?")
            f:Hide()
        else
            NS.Printf("    %-20s |cffff6666cannot create|r", t)
        end
    end

    -- The real question: will a canvas instantiate at all?
    local ok, err = pcall(function()
        local f = CreateFrame("Frame", "EyesUpCanvasTest", UIParent)
        Mixin(f, MapCanvasMixin)
        f:OnLoad()
        f:SetSize(200, 200)
        f:SetPoint("CENTER")
        local mapID = C_Map.GetBestMapForUnit("player")
        f:SetMapID(mapID)
        f:Hide()
        return true
    end)

    NS.Printf("  instantiating a MapCanvas: %s", ok and "|cff66ff66WORKED|r"
        or ("|cffff6666failed|r -- " .. tostring(err):sub(1, 70)))

    if ok then
        NS.Print("|cff66ff66The corner map is buildable.|r Blizzard's providers draw the pins;")
        NS.Print("we'd anchor it to the tray, lock it to the player and shrink it.")
    else
        NS.Print("|cffffcc00Canvas won't instantiate bare.|r It likely needs the XML template")
        NS.Print("(MapCanvasScrollFrameTemplate) rather than a raw Mixin. Still doable, more work.")
    end
end

-- ---------------------------------------------------------------------------
-- ...OR JUST USE THE ONE BLIZZARD ALREADY BUILT.
--
-- The canvas test says every piece exists and only the scaffolding is missing --
-- MapCanvasMixin:OnLoad wants a ScrollContainer that comes from XML. We could
-- build that: an XML file, the shared pin templates, a pan-and-zoom loop to keep it
-- on the player. Two or three hundred lines, and every one of them a hostage to the
-- next patch.
--
-- But Blizzard ships a MapCanvas in a small movable window ALREADY. It's the
-- Battlefield Map -- the zone map overlay you can toggle on in any zone, not just
-- battlegrounds. It has the providers wired up, the pins working, the fog, the
-- party dots, and it's maintained by the people who break it.
--
-- So before writing our own: can we simply borrow theirs, park it in the tray where
-- the minimap used to be, and shrink it? That's thirty lines instead of three
-- hundred, and it doesn't rot.
--
-- This finds out.
-- ---------------------------------------------------------------------------
local function bfMapTest()
    NS.Print("---- can we borrow Blizzard's Battlefield Map? ----")

    local load = C_AddOns and C_AddOns.LoadAddOn or _G.LoadAddOn
    if load then pcall(load, "Blizzard_BattlefieldMap") end

    local f = _G.BattlefieldMapFrame
    if not f then
        NS.Print("  |cffff6666BattlefieldMapFrame doesn't exist.|r")
        NS.Print("  So it's the hand-built canvas or nothing. Tell Claude.")
        return
    end

    NS.Print("  |cff66ff66BattlefieldMapFrame exists|r -- it's a MapCanvas, already wired up.")
    NS.Printf("    SetMapID          %s", f.SetMapID and "|cff66ff66yes|r" or "no")
    NS.Printf("    ScrollContainer   %s", f.ScrollContainer and "|cff66ff66yes|r" or "no")
    NS.Printf("    dataProviders     %s", f.dataProviders and "|cff66ff66yes|r" or "no")
    NS.Printf("    can pan/zoom      %s",
        (f.ScrollContainer and f.ScrollContainer.InstantPanAndZoom) and "|cff66ff66yes|r" or "no")

    -- Park it where the minimap was and lock it to the player, just to see it.
    local tray = _G.EyesUpMinimapTray
    f:SetParent(tray or UIParent)
    f:ClearAllPoints()
    if tray then
        f:SetPoint("CENTER", tray, "CENTER", 0, 0)
        f:SetSize(tray:GetWidth(), tray:GetHeight())
    else
        f:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -20, -20)
        f:SetSize(180, 180)
    end
    f:SetAlpha(0.9)
    f:Show()

    local mapID = C_Map.GetBestMapForUnit("player")
    if mapID and f.SetMapID then pcall(f.SetMapID, f, mapID) end

    -- Lock it to you: pan to the player, zoomed in, so it reads like a minimap
    -- rather than a zone map.
    local sc = f.ScrollContainer
    if sc and sc.InstantPanAndZoom then
        local pos = C_Map.GetPlayerMapPosition(mapID, "player")
        if pos then
            local x, y = pos:GetXY()
            pcall(sc.InstantPanAndZoom, sc, sc.maxScale or 3, x, y)
        end
    end

    NS.Print("  |cff66ff66Parked it in the corner.|r Does it show the zone, centred on you?")
    NS.Print("  If yes, the corner map is basically free. |cffffff00/eu probe bfmap off|r to undo.")
end

local function bfMapOff()
    local f = _G.BattlefieldMapFrame
    if f then f:Hide() end
    NS.Print("battlefield map hidden. (/reload to fully reset it.)")
end

-- ---------------------------------------------------------------------------
-- WHAT IS ACTUALLY ON THE MINIMAP?
--
-- Move the minimap to the middle of the screen and everything it draws comes with
-- it. The tracking blips are what we wanted. But a city adds mailboxes, inns, quest
-- givers, vendors, dungeon portals -- and a stray addon button or two that refused
-- to be parked. Some of those are Lua frames we can hide or move; some are engine-
-- drawn and untouchable. Guessing which is which is how you ship a setting that
-- does nothing.
--
-- So: dump it. Every child of the Minimap, with its type, its name, and whether
-- it's sitting near the center (i.e. on top of your character) right now. That
-- tells us exactly what the clutter IS and what we're allowed to do about it.
-- ---------------------------------------------------------------------------
local function describe(obj)
    local name = (obj.GetName and obj:GetName()) or "(anon)"
    local kind = obj.GetObjectType and obj:GetObjectType() or "?"
    local tex = ""
    if obj.GetTextureFilePath then
        local ok, p = pcall(obj.GetTextureFilePath, obj); if ok and p then tex = "  tex=" .. tostring(p) end
    elseif obj.GetAtlas then
        local ok, a = pcall(obj.GetAtlas, obj); if ok and a then tex = "  atlas=" .. tostring(a) end
    end
    return kind, name, tex
end

local function dumpInto(parent, label, depth)
    if not parent then return end
    local kids  = parent.GetChildren and { parent:GetChildren() } or {}
    local regs  = parent.GetRegions  and { parent:GetRegions()  } or {}
    if #kids == 0 and #regs == 0 then return end

    NS.Printf("|cffffd100%s|r  (%d frames, %d regions)", label, #kids, #regs)

    for _, c in ipairs(kids) do
        if c:IsShown() then
            local kind, name, tex = describe(c)
            NS.Printf("  %s  %s%s", kind, name, tex)
            -- One level deeper for containers -- that's where pins hide.
            if depth > 0 and #({ c:GetChildren() }) > 0 then
                for _, gc in ipairs({ c:GetChildren() }) do
                    if gc:IsShown() then
                        local k2, n2, t2 = describe(gc)
                        NS.Printf("      %s  %s%s", k2, n2, t2)
                    end
                end
            end
        end
    end
    for _, r in ipairs(regs) do
        if r.IsShown and r:IsShown() then
            local kind, name, tex = describe(r)
            NS.Printf("  |cff888888%s  %s%s|r", kind, name, tex)
        end
    end
end

local function minimapDump()
    NS.Print("---- what's really on the minimap ----")
    dumpInto(Minimap, "Minimap", 1)
    dumpInto(_G.MinimapBackdrop, "MinimapBackdrop", 1)
    dumpInto(_G.MinimapCluster, "MinimapCluster", 0)
    NS.Print("|cff888888Look for the mailbox/inn/quest icons above -- their atlas/name is")
    NS.Print("what we'd hide. The herb/ore blips are engine-drawn and appear in NONE|r")
    NS.Print("|cff888888of these lists, so hiding pins can never touch them.|r")
end

-- ---------------------------------------------------------------------------
-- IS SetPlayerTexture THE LEVER AT ALL?
--
-- The arrow isn't a Lua region -- the Minimap has none, and a recursive hunt found
-- nothing. So the only possible control is Minimap:SetPlayerTexture, and it either
-- works and our transparent file is bad, or it doesn't work and the arrow is
-- untouchable like the blips.
--
-- One way to know: set it to a SOLID, unmistakable texture. If the arrow turns into
-- a white square, SetPlayerTexture is the lever and the transparent file was the
-- problem. If nothing changes, the arrow is beyond us.
-- ---------------------------------------------------------------------------
local function arrowTest(which)
    if not Minimap.SetPlayerTexture then
        return NS.Print("|cffff6666no SetPlayerTexture on this client|r -- arrow is untouchable.")
    end

    if which == "solid" then
        local ok, err = pcall(Minimap.SetPlayerTexture, Minimap, "Interface\\Buttons\\WHITE8X8")
        NS.Printf("set player texture -> WHITE8X8: %s", ok and "|cff66ff66no error|r"
            or ("|cffff6666" .. tostring(err):sub(1, 60) .. "|r"))
        NS.Print("Did the center arrow become a |cffffffffwhite square|r?")
        NS.Print("  YES -> SetPlayerTexture works; our transparent file was the problem.")
        NS.Print("  NO  -> the arrow is engine-drawn and can't be hidden. Full stop.")
    elseif which == "clear" then
        -- A guaranteed-transparent stock texture, not our own file.
        local ok = pcall(Minimap.SetPlayerTexture, Minimap, 1058089) -- a known blank
        if not ok then pcall(Minimap.SetPlayerTexture, Minimap, "Interface\\Common\\Spacer") end
        NS.Print("set player texture -> a blank. Arrow gone?")
    else
        pcall(Minimap.SetPlayerTexture, Minimap, "Interface\\Minimap\\MinimapArrow")
        NS.Print("player texture restored to the normal arrow.")
    end
end

-- ---------------------------------------------------------------------------
-- The report
-- ---------------------------------------------------------------------------
local function report()
    NS.Print("---- probe report ----")

    -- FIRST, always: was anything even listening? A report of zero from a probe
    -- that was switched off is not a result, and last time it looked exactly like
    -- one. `/eu probe cvars on` does NOT start the watch -- that caught me out,
    -- so now it says so out loud rather than quietly measuring nothing.
    NS.Printf("watching: %s      soft-target CVars: %s",
        watching and "|cff66ff66yes|r" or "|cffff6666NO -- run /eu probe to start it|r",
        held and "|cff66ff66borrowed (360°, 60yd)|r" or "|cffffcc00yours, untouched|r")

    NS.Printf("acquisitions: %d   distinct objects: %d   secret values hit: %s",
        acquisitions, seenCount,
        secretHits > 0 and ("|cffff6666" .. secretHits .. "|r") or "0")

    if unitPosWorks == nil then
        NS.Print("UnitPosition on game objects: |cffffcc00untested|r (nothing acquired yet)")
    else
        NS.Printf("UnitPosition on game objects: %s",
            unitPosWorks and "|cff66ff66works -- exact ranges|r"
                          or "|cffffcc00nil -- distances below are walk-to estimates|r")
    end

    if seenCount == 0 then
        NS.Print("nothing seen yet.")
        if not watching then
            NS.Print("|cffff6666...because the probe wasn't running.|r Run |cffffff00/eu probe|r first.")
        else
            NS.Print("The probe WAS running, so this is a real null. Next step: stand right next")
            NS.Print("to a node, look straight at it, and run |cffffff00/eu probe now|r -- that narrates")
            NS.Print("every step and shows exactly where the chain breaks.")
        end
        return
    end

    -- The engine won't give us a game object's position (UnitPosition is nil for
    -- them), so range and arc come from the walk-to: where you were standing when
    -- it first appeared, versus where you stood to gather it. Which means a node
    -- you never gathered has no numbers -- it's in the list, at 0.0y, as evidence
    -- that it was SEEN. Don't read those zeroes as "acquired at zero yards".
    if not unitPosWorks then
        NS.Print("|cff888888ranges are measured against GatherMate's position for that species,|r")
        NS.Print("|cff888888or (failing that) how far you walked to gather it.|r")
    end

    local bestDist, bestAngle = 0, 0
    print(("  |cffffff00%-28s %8s %10s %8s %s|r"):format("object", "id", "max range", "max arc", "seen"))
    for id, rec in pairs(seen) do
        if rec.maxDist  > bestDist  then bestDist  = rec.maxDist  end
        if rec.maxAngle > bestAngle then bestAngle = rec.maxAngle end
        print(("  %-28s %8d %9.1fy %7.0f° %5dx%s"):format(
            (rec.name or "?"):sub(1, 28), id, rec.maxDist, rec.maxAngle, rec.hits,
            rec.gathered and "  gathered" or ""))
    end

    -- The headline, if it worked: can we see further by LOOKING than by reaching?
    NS.Printf("mouseover: |cffff99ff%d|r objects seen, furthest |cffff99ff%.1f yards|r",
        mouseCount, mouseMax)
    if mouseMax > 30 then
        NS.Print("|cff66ff66MOUSEOVER BEATS SOFT-TARGET.|r The reticle sees further than your")
        NS.Print("hand reaches. That's a live source at real range -- tell Claude.")
    elseif mouseCount == 0 then
        NS.Print("|cff888888(no game objects under the reticle -- hold right-mouse and look at one)|r")
    end

    NS.Printf("furthest acquisition: |cff66ff66%.1f yards|r", bestDist)
    NS.Printf("widest arc: |cff66ff66%.0f°|r off your facing %s", bestAngle,
        bestAngle > 100 and "(so it really is looking behind you)" or "(keep testing -- turn your back on one)")
end

-- ---------------------------------------------------------------------------
-- Wiring
-- ---------------------------------------------------------------------------
local ev = CreateFrame("Frame")
ev:SetScript("OnEvent", function(_, event, ...)
    if event == "PLAYER_SOFT_INTERACT_CHANGED" then
        if watching then inspect(false) end
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        local unit, _, spellID = ...
        if unit == "player" then onGatherCast(spellID) end
    elseif event == "PLAYER_LOGOUT" then
        -- Never leave someone's Interact key reaching sixty yards because they
        -- forgot to turn the probe off.
        if held then cvarsOff() end
    end
end)
ev:RegisterEvent("PLAYER_LOGOUT")

-- The poll. Five times a second, which is nothing, and it means the whole probe
-- no longer rests on PLAYER_SOFT_INTERACT_CHANGED being the event we think it is
-- and firing when we think it does. If the token ever resolves, we WILL see it.
local poller
local since = 0

local function watch(on)
    watching = on
    if on then
        ev:RegisterEvent("PLAYER_SOFT_INTERACT_CHANGED")
        ev:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")

        if not poller then
            poller = CreateFrame("Frame")
            poller:SetScript("OnUpdate", function(_, elapsed)
                if not watching then return end
                since = since + elapsed
                if since < 0.2 then return end
                since = 0
                inspect(false)
                checkMouseover()     -- the other reticle. See above.
            end)
        end
        poller:Show()

        NS.Print("probe |cff66ff66on|r (polling, so it doesn't matter if the event misbehaves).")
        cvarsReport()
        if not held then
            NS.Print("these are your own settings -- baseline first. When you've seen what they")
            NS.Print("give you, |cffffff00/eu probe cvars on|r and compare.")
        end
        NS.Print("Stuck? Stand next to a node, look at it, |cffffff00/eu probe now|r.")
    else
        ev:UnregisterEvent("PLAYER_SOFT_INTERACT_CHANGED")
        ev:UnregisterEvent("UNIT_SPELLCAST_SUCCEEDED")
        if poller then poller:Hide() end
        current, lastGUID = nil, nil
        NS.Print("probe off.")
    end
end

function Probe.Command(arg)
    local sub, rest = (arg or ""):match("^(%S*)%s*(.-)$")

    if sub == "" then
        watch(not watching)
    elseif sub == "now" then
        inspectNow()
    elseif sub == "report" then
        report()
    elseif sub == "yards" then
        yardsReport()
    elseif sub == "dump" then
        minimapDump()
    elseif sub == "arrow" then
        arrowTest(rest ~= "" and rest or "solid")
    elseif sub == "canvas" then
        canvasTest()
    elseif sub == "bfmap" then
        if rest == "off" then bfMapOff() else bfMapTest() end
    elseif sub == "minimap" then
        if rest == "off" then minimapOff() else minimapTest() end
    elseif sub == "hud" then
        hudTest()
    elseif sub == "mask" then
        maskTest(rest ~= "" and rest or nil)
    elseif sub == "plates" then
        platesTest()
    elseif sub == "nav" then
        navTest()
    elseif sub == "cvars" then
        if rest == "on" then cvarsOn()
        elseif rest == "off" then cvarsOff()
        else cvarsReport() end
    elseif sub == "reset" then
        wipe(seen); wipe(firstSeen); wipe(mouseSeen)
        seenCount, acquisitions, secretHits = 0, 0, 0
        mouseCount, mouseMax, lastMouseGUID = 0, 0, nil
        unitPosWorks, current, lastGUID = nil, nil, nil
        NS.Print("probe data cleared.")
    else
        NS.Print("probe:")
        print("  |cffffff00/eu probe|r             watch soft-target acquisitions (start here)")
        print("  |cffffff00/eu probe now|r         narrate the CURRENT soft target, step by step")
        print("  |cffffff00/eu probe report|r      what we've learned")
        print("  |cffffff00/eu probe yards|r       how big is this zone really")
        print("  |cffffff00/eu probe cvars|r       [on|off] borrow 360°/60yd soft-target")
        print("  |cffffff00/eu probe minimap|r     can a SECOND minimap exist? (the big one)")
        print("  |cffffff00/eu probe hud|r         put your REAL minimap in the middle of the screen")
        print("  |cffffff00/eu probe mask|r <m>    clear|dim|vignette|round -- can we drop the terrain?")
        print("  |cffffff00/eu probe nav|r         can the engine project a world point?")
        print("  |cffffff00/eu probe reset|r       forget what we've seen")
    end
end
