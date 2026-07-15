local addonName, NS = ...

-- =============================================================================
-- Constants.lua
--
--   "Keep your eyes up, friend. The road tells you more than the map does."
--
-- Every number, color, and magic string the addon believes in, gathered in one
-- place so you can argue with them. Loaded first, so everything after this can
-- reach into NS.* without checking whether it's there yet.
--
-- If you're here to tweak something, you probably want NS.defaults at the
-- bottom -- that's the schema for everything the addon remembers about you.
-- =============================================================================

NS.name  = addonName
NS.title = "Eyes Up"

-- Our voice in the chat frame. One place, so the addon always sounds like
-- itself and never like a stray print() someone forgot to delete.
local TAG = "|cff66ccffEyes Up|r "

function NS.Print(msg)
    print(TAG .. msg)
end

function NS.Printf(fmt, ...)
    print(TAG .. fmt:format(...))
end

-- -----------------------------------------------------------------------------
-- The four things worth stopping for.
--
-- These string keys are written directly into your saved variables (typeEnabled,
-- nodeFilter, knownNodes, typeColor all key off them). Rename one and you
-- silently orphan every filter that player ever set. So: don't. Add, never
-- rename.
-- -----------------------------------------------------------------------------
NS.NodeType = {
    HERB     = "HERB",
    MINE     = "MINE",
    LUMBER   = "LUMBER",
    FISHING  = "FISHING",
    TREASURE = "TREASURE",
}

-- The order they appear in the options, and what we call them out loud.
NS.NodeTypeOrder = { "HERB", "MINE", "LUMBER", "FISHING", "TREASURE" }
NS.NodeTypeLabel = {
    HERB     = "Herbalism",
    MINE     = "Mining",
    LUMBER   = "Lumber",
    FISHING  = "Fishing",
    TREASURE = "Treasure",
}

-- The colors we ship with -- the *factory* palette, not the live one.
--
-- The player owns their colors: NS.defaults.typeColor is seeded from this, and
-- the color pickers in the options edit that copy. So this table is a fallback
-- and a "Reset colors" button, nothing more. Read live colors with
-- NS.TypeColor(); reach into this one directly and you'll cheerfully ignore
-- every choice the player made.
NS.NodeTypeColor = {
    HERB     = { 0.30, 0.85, 0.35 },  -- green things that grow
    MINE     = { 0.95, 0.70, 0.25 },  -- ore-vein amber
    LUMBER   = { 0.65, 0.45, 0.25 },  -- honest brown
    FISHING  = { 0.35, 0.70, 0.95 },  -- water, obviously
    TREASURE = { 0.85, 0.75, 0.95 },  -- suspiciously enchanted lavender
}

local WHITE = { 1, 1, 1 }

-- The live color for a node type: the player's, falling back to ours.
-- Called for every blip on every tick, so it hands back the stored table rather
-- than building a new one. Treat what you get as read-only.
function NS.TypeColor(nodeType)
    local db = NS.db
    local c = db and db.typeColor and db.typeColor[nodeType]
    return c or NS.NodeTypeColor[nodeType] or WHITE
end

-- -----------------------------------------------------------------------------
-- Priority: which of two nodes wins when both are in range.
--
-- The cue shows ONE thing (usually), and until now that thing was simply the
-- nearest -- so a mining hub you don't care about would happily elbow out the
-- herb you're actually farming, purely by standing five yards closer.
--
-- Priority is a thumb on the scale, not a filter. It doesn't change what's
-- *found*; it changes what gets the icon when several things are found at once.
-- The weight is a MULTIPLIER ON DISTANCE for ranking only: a HIGH node scores at
-- half its real distance ("it feels twice as close"), a LOW node at double. So
-- Scan ranks by dist * weight and, all else equal, distance still decides --
-- which is the point. This is preference, not tunnel vision. Turning a type OFF
-- is what typeEnabled is for.
--
-- Real distance is still real distance: the focus lock, the close-range pulse and
-- everything a renderer draws read e.dist, never the weighted rank. A LOW-priority
-- herb at your feet is still at your feet.
-- -----------------------------------------------------------------------------
NS.Priority = { LOW = 1, NORMAL = 2, HIGH = 3 }

NS.PriorityOrder = { 1, 2, 3 }
NS.PriorityLabel = { [1] = "Low", [2] = "Normal", [3] = "High" }
NS.PriorityWeight = { [1] = 2.0, [2] = 1.0, [3] = 0.5 }

-- The ranking weight for a node type. Hot path (every node, every tick), so it's
-- a couple of table lookups and no allocation. Unknown or unset = Normal = 1.0,
-- which makes the whole feature a no-op for anyone who never touches it.
function NS.TypeWeight(nodeType)
    local db = NS.db
    local p = db and db.typePriority and db.typePriority[nodeType]
    return NS.PriorityWeight[p] or 1.0
end

-- Stand-in art for when we don't know what the node actually drops.
--
-- The cue would much rather show you the real item -- a Mycobloom looks like a
-- Mycobloom -- but it can't always. A gather whose loot never resolved is stored
-- type-only, and a vignette's id is a vignetteID, not an itemID. In those cases
-- we fall back to one of these and tint it with the node's color, so at minimum
-- you know what *kind* of thing is out there.
NS.NodeTypeGlyph = {
    HERB     = "Interface\\ICONS\\Trade_Herbalism",
    MINE     = "Interface\\ICONS\\Trade_Mining",
    LUMBER   = "Interface\\ICONS\\INV_Misc_Branch_01",
    FISHING  = "Interface\\ICONS\\Trade_Fishing",
    TREASURE = "Interface\\ICONS\\INV_Box_01",
}
NS.FallbackGlyph = "Interface\\ICONS\\INV_Misc_QuestionMark"

-- -----------------------------------------------------------------------------
-- Your art.
--
-- Tick "Use my icons instead of the game's" (db.iconStyle = "custom") and the cue
-- draws these, always: one clean icon per node type, the same every time. Some
-- people want to see the actual Mycobloom. Some people want to see "a herb" and
-- get on with their day. Both are reasonable, which is why it's a switch -- and
-- why it's the ONLY icon switch.
--
-- The files live in textures/. Note there's no extension in the paths below --
-- that isn't an oversight, WoW resolves .tga and .blp either way.
--
-- THE FOLDER NAME MUST MATCH THE DISK, CASE AND ALL, even though Windows doesn't
-- care. Say "Textures" here while the folder is "textures" and it works on your
-- machine and renders blank squares for anyone who unzips it somewhere
-- case-sensitive. It's lowercase on both sides. Keep it that way.
--
-- TWO MORE THINGS THAT WILL COST YOU AN EVENING:
--
--   1. Textures MUST have power-of-two dimensions (256x256, 128x128...). WoW's
--      loader simply refuses anything else -- no error, no warning, just a blank
--      square where your icon should be. FISHING.tga arrived as 1024x989 and was
--      exactly this: invisible, and silent about it. Everything in textures/ is
--      256x256 now; textures/original/ keeps the full-size art.
--
--   2. WoW gives Lua NO WAY to ask whether a texture file exists, or whether it
--      loaded. So the addon cannot check, cannot warn, and cannot fall back. A
--      blank icon always means: missing file, wrong name, wrong case, or not a
--      power of two. There is no third possibility, and no code you can write
--      here will detect it -- go and look at the file.
--
-- A nil entry below is safe and different: it means "no art for this type", and
-- the cue quietly uses the built-in Blizzard glyph instead.
-- -----------------------------------------------------------------------------
NS.CustomGlyphDir = "Interface\\AddOns\\EyesUp\\textures\\"
NS.CustomGlyph = {
    HERB     = NS.CustomGlyphDir .. "HERBING",
    MINE     = NS.CustomGlyphDir .. "MINING",
    LUMBER   = NS.CustomGlyphDir .. "LUMBER",
    TREASURE = NS.CustomGlyphDir .. "TREASURE",
    FISHING  = NS.CustomGlyphDir .. "FISHING",
}

-- The arrow. Points north at rotation 0, which is the assumption baked into all
-- the bearing math. If you swap the art, keep it SQUARE: SetRotation works in
-- texture space, so a rectangular texture shears itself when it turns.
NS.ArrowTexture = "Interface\\Minimap\\MinimapArrow"

-- The cue's border color when it isn't wearing the node's own (r, g, b, a).
-- Near-black, so the icon keeps its edge against snow, sand, and the inside of
-- a very bright cave.
NS.CueBorderColor = { 0, 0, 0, 0.9 }

-- Item art has a beveled frame baked into its outer ~8%. Crop that off and the
-- icon becomes a clean square you can actually put a border around.
NS.IconCrop = 0.08

-- A last resort, and it should never fire.
--
-- This used to be NS.APPROX_ZONE_YARDS, and the addon leaned its whole weight on
-- it: every zone was assumed to be 1000 yards across, both axes. Zul'Aman is
-- 8950 x 5967. The client knew that all along (C_Map.GetMapWorldSize), we simply
-- never asked -- so a default install's "60 yard" detection radius was really
-- about 450 yards, and the direction arrow was skewed by up to 11 degrees
-- because the two axes were scaled as though the zone were square.
--
-- Data.MapSize asks now. This number survives only for a map the client refuses
-- to size, where a wrong distance still beats a dead addon. If you find yourself
-- here, something is unusual -- it isn't meant to be reachable.
NS.FALLBACK_ZONE_YARDS = 1000

-- The little "hey" sound. Off by default (see NS.defaults.soundEnabled).
-- Fall down the list instead of assuming: SOUNDKIT entries do get retired
-- between builds, and Cue.lua just stays quiet if we end up with nothing.
NS.CueSoundKit = SOUNDKIT and (
    SOUNDKIT.MAP_PING
    or SOUNDKIT.IG_MINIMAP_ZOOM_IN
    or SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON
) or nil

-- -----------------------------------------------------------------------------
-- Knowing a gather when we see one.
--
-- There's no "you gathered something" event. What there IS is a spell cast with
-- a name, so we match the cast name and infer the rest. Crude, effective, and
-- unfortunately English-only: these strings are localized by the client.
--
-- Playing on a non-English client? Add your locale's cast names here. Find them
-- with:  /run print(C_Spell.GetSpellInfo(<spellID>).name)  while the profession
-- ability is on your bars. The map is: a cast name -> a NodeType. That's all.
-- -----------------------------------------------------------------------------
NS.GatherSpellNames = {
    -- Herbalism's cast has gone by a few names across expansions. Take them all;
    -- an extra key costs nothing and a missing one costs you a node.
    ["Herb Gathering"] = NS.NodeType.HERB,
    ["Herbalism"]      = NS.NodeType.HERB,
    ["Herb Picking"]   = NS.NodeType.HERB,

    ["Mining"]         = NS.NodeType.MINE,

    -- Lumber comes off the Harvesting Hatchet, which surfaces as "Harvesting".
    -- Builds move; verify and extend as needed.
    ["Harvesting"]     = NS.NodeType.LUMBER,
    ["Chopping"]       = NS.NodeType.LUMBER,

    ["Fishing"]        = NS.NodeType.FISHING,
}

-- -----------------------------------------------------------------------------
-- How long we wait for the loot.
--
-- Every other gather is over in an instant: you swing the pick, the ore is in
-- your bag, and if the loot hasn't turned up within a second and a half then it
-- never will.
--
-- Fishing is not like that. You cast. The bobber sits there. A duck goes past.
-- Eventually -- ten, fifteen, twenty seconds later -- something bites. If we
-- applied the ordinary window to fishing, the loot would ALWAYS arrive too late
-- to be claimed, every fishing spot would be recorded without an item id, and no
-- fish would ever have a name. So fishing gets to wait.
-- -----------------------------------------------------------------------------
NS.PendingWindow = {          -- how long loot has to show up and claim the cast
    default = 1.5,
    FISHING = 45,
}
NS.PendingFallback = {        -- ...and how long until we give up and write it down anyway
    default = 2.0,
    FISHING = 50,
}

-- Nodes that DON'T disappear when you use them.
--
-- Pick a herb and it's gone -- that's why we hush it for a respawn window. But a
-- fishing pool is good for a couple of dozen casts; hushing it the moment you
-- catch your first fish would be exactly wrong, because you're standing there
-- fishing it and you'd like to keep knowing it's there.
NS.PersistsAfterUse = {
    FISHING = true,
}

-- -----------------------------------------------------------------------------
-- What counts as treasure (and the long list of things that don't).
--
-- A cautionary tale. This used to map Enum.VignetteType.Normal -> TREASURE, and
-- fall back to TREASURE for anything it didn't recognize. Reasonable-sounding!
-- Except `Normal` is retail's catch-all: rare mobs, world events, quest markers,
-- bonus objectives, profession bags -- all Normal. So the cue treated the entire
-- minimap as buried treasure and shouted about it constantly.
--
-- The atlas name is the thing that actually discriminates (VignetteLoot* is a
-- chest, VignetteKill* is a rare, VignetteEvent* is an event), so we classify on
-- that, use the enum only when it says Treasure outright, and IGNORE anything we
-- don't recognize. An unknown vignette is not a node. That default matters more
-- than any rule below it.
-- -----------------------------------------------------------------------------
NS.VignetteTypeToNode = {
    -- Looked up by NAME at runtime, because the numeric enum values wander
    -- between builds and we'd rather not chase them.
    Treasure = NS.NodeType.TREASURE,
}

-- Substring match against a lowercased atlasName -> NodeType. First hit wins.
-- Want the addon to start noticing something? Run `/eu vignettes`, read the
-- atlas name it prints, and add a line here.
NS.VignetteAtlasToNode = {
    { match = "loot", node = NS.NodeType.TREASURE },   -- VignetteLoot, VignetteLootElite
}

-- =============================================================================
-- Everything the addon remembers about you.
--
-- This table IS the schema. Core.lua deep-copies it into EyesUpDB on first run
-- and backfills any key you're missing after an update -- which means adding a
-- setting is a one-line change *here* and nowhere else. Existing characters
-- migrate themselves.
-- =============================================================================
NS.defaults = {
    enabled          = true,

    -- Which face the addon wears.
    --
    -- The cue is the whole point: a small icon and an arrow, near the middle of
    -- the screen, where you're already looking. The radar came first and still
    -- works fine -- but it asks you to look AT it, which is the thing we're
    -- trying to stop doing. So it's opt-in now.
    mode             = "cue",   -- "cue" | "radar" | "both"

    -- The radar's shape and place.
    radarSize        = 200,     -- pixel diameter
    posX             = 0,       -- offset from screen center; 0,0 = dead center
    posY             = 0,
    locked           = true,    -- unlock to drag EITHER the cue or the radar

    -- The cue's shape and place. Its own position keys, so the two never fight
    -- over one -- in "both" mode they share the screen, and this default sits it
    -- comfortably above the radar disc (which is 100px from center) and above
    -- your character's head.
    cueSize          = 40,      -- icon size at the far edge of detection range
    cuePosX          = 0,
    cuePosY          = 150,
    cueShowArrow     = true,
    cueArrowScale    = 0.7,     -- arrow size as a fraction of the icon (was a hard 0.5)

    -- How many things it'll mention at once (1-3).
    --
    -- One is the honest default and the one this addon was designed around: the
    -- nearest thing worth turning for, and nothing else to think about. Two or
    -- three is for when you're farming a loop and want the peripheral awareness.
    -- More than three and you've reinvented the radar, which is already right
    -- there in the mode setting if that's what you want.
    cueCount         = 1,
    cueSecondaryScale = 0.62,   -- how much smaller the runners-up are drawn

    -- WHICH FACE THE CUE WEARS. One setting, two answers, and that's all there is.
    --
    --   "item"   -- the game's own art. A Mycobloom looks like a Mycobloom, once
    --              you've gathered one and we know what the species drops. Until
    --              then, the built-in glyph for its type, tinted by its color.
    --   "custom" -- your art, from textures/. One icon per type, every time. A herb
    --              is a herb. Nothing changes as you play.
    --
    -- There was briefly a second switch (standInGlyphs) that used your art as the
    -- fallback inside "item" mode. Two checkboxes that both read "use my icons" and
    -- meant different things is not a setting, it's a riddle. One switch now.
    --
    -- See NS.CustomGlyph above for where the files go -- and for why a blank icon
    -- is always a file problem and never a code problem.
    iconStyle        = "item",  -- "item" | "custom"

    -- Icon presentation.
    cueSquareIcon    = true,    -- crop the stock bevel; make it a clean square
    cueBorderSize    = 1,       -- border thickness in px; 0 = none

    -- Wear the node's color as a border.
    --
    -- Once the cue is showing real item art, the border is the ONLY thing left
    -- that can tell you what kind of node it is -- you can't tint a herb's icon
    -- green without ruining the picture, but you can frame it in green. Turn
    -- this off for a plain dark border and a quieter screen.
    cueBorderTypeColor = true,

    -- What the cue fades to when there's nothing worth mentioning: gone.
    -- Deliberately NOT baseAlpha. A cue resting at 12% opacity is just a ghost
    -- of the node you flew past two minutes ago, still insisting.
    cueIdleAlpha     = 0,

    -- Fading. The radar rests at baseAlpha; the cue rests at nothing.
    baseAlpha        = 0.12,    -- the radar's idle whisper
    activeAlpha      = 0.85,    -- "there's something here"
    fadeSpeed        = 4.0,     -- alpha per second, both directions

    -- -------------------------------------------------------------------------
    -- How far we look, and why it isn't very far.
    --
    -- This addon is not a treasure map. It is a tap on the shoulder. The question
    -- it answers is "is there something RIGHT THERE that I'd regret flying past" --
    -- not "where is every herb in Hallowfall". There are other addons for the
    -- second question and they're welcome to it.
    --
    -- So the range is deliberately short. Far enough that you have time to turn;
    -- close enough that turning is obviously worth it.
    --
    -- For scale: your minimap shows you about 100 yards. Sixty is INSIDE that --
    -- deliberately. Eyes Up is not trying to see further than the minimap. It's
    -- trying to save you the glance.
    -- -------------------------------------------------------------------------
    detectionYards   = 60,
    showRing         = true,    -- radar: draw the range ring
    showPointer      = true,    -- radar: aim an arrow at the nearest

    -- The focus lock.
    --
    -- When something is THIS close, it stops being one of several options and
    -- starts being the thing you should be looking at. So the cue drops everything
    -- else and shows only it -- however many icons you asked for.
    --
    -- The alternative is a screen that says "there's a herb at your feet, and also
    -- two other herbs somewhere", which is a strictly worse sentence.
    focusYards       = 20,

    -- "It's right here."
    --
    -- Inside this radius the bearing goes haywire -- you're standing on top of
    -- the thing, and a step in any direction swings the arrow wildly. An arrow
    -- that spins is worse than no arrow, so the cue drops it and pulses instead.
    closeYards       = 10,

    -- A quiet tick when something NEW turns up. Not a metronome, not a klaxon --
    -- it says "hey" once and then leaves you alone. Off until you ask for it.
    soundEnabled     = false,
    soundCooldown    = 5,       -- seconds; the floor between ticks

    -- What you care about, in the broad strokes.
    typeEnabled = {
        HERB = true, MINE = true, LUMBER = true, FISHING = true, TREASURE = true,
    },

    -- ...and which of it you care about MOST, when two things are in range at
    -- once and only one of them can have the icon. See NS.Priority above for what
    -- the numbers mean. Everything starts Normal, so out of the box this changes
    -- nothing at all -- it's only a preference once you express one.
    typePriority = {
        HERB = 2, MINE = 2, LUMBER = 2, FISHING = 2, TREASURE = 2,
    },

    -- Your palette. Seeded from NS.NodeTypeColor; edited via the color pickers.
    -- Drives the radar blips, the cue's fallback glyphs, and the cue's border.
    typeColor = {
        HERB     = { 0.30, 0.85, 0.35 },
        MINE     = { 0.95, 0.70, 0.25 },
        LUMBER   = { 0.65, 0.45, 0.25 },
        FISHING  = { 0.35, 0.70, 0.95 },
        TREASURE = { 0.85, 0.75, 0.95 },
    },

    -- What you care about, specifically. nodeFilter[type][id] = false means
    -- "yes, I know, I don't want it." Absent means shown. Fills in as you
    -- discover things.
    nodeFilter = { HERB = {}, MINE = {}, LUMBER = {}, FISHING = {}, TREASURE = {} },

    -- Which groups are folded shut in the filter list, keyed by NodeType. (It used
    -- to be keyed by expansion index; see Options.rebuildNodeList for why that
    -- stopped being possible. Any stale numeric keys left in here are harmless.)
    filterCollapsed = {},

    -- -------------------------------------------------------------------------
    -- The hard question: is the node actually THERE?
    --
    -- Our database knows where nodes have BEEN. It has no idea what's standing
    -- there right now, and WoW won't tell us -- you cannot enumerate live herb
    -- or ore nodes, full stop. Two things narrow the gap between what we know
    -- and what we imply:
    --
    --   1. A node you just gathered is *definitively* gone. We stamp it and stop
    --      cueing on it until it could plausibly have come back.
    --   2. Everything else in the database is a guess. Vignettes are the only
    --      nodes we can genuinely see, so the guesses draw dimmer instead of
    --      pretending to be certainties.
    --
    -- Honesty, rendered as opacity.
    -- -------------------------------------------------------------------------
    respawnMinutes   = 5,       -- hush a gathered node this long; 0 = never
    unconfirmedAlpha = 0.55,    -- how faint an unverified node draws; 1.0 = no distinction

    -- Learning as you go.
    recordGathers    = true,    -- remember nodes as you gather them
    dedupeYards      = 15,      -- two points this close are the same node, really

    -- -------------------------------------------------------------------------
    -- THE HEADS-UP DISPLAY.
    --
    -- Your minimap, moved to the middle of your screen with the terrain masked
    -- away -- leaving nothing but the tracking blips, hanging over the world where
    -- you're actually looking.
    --
    -- These are not our markers. They're the game's: live, complete, accurate to
    -- the yard, at the full range of your tracking (about 100 yards). Everything
    -- else in this addon is a workaround for not being able to read them. This
    -- doesn't read them. It just puts them where they belong.
    --
    -- It costs you the minimap in your corner -- there is only one Minimap object
    -- in the game and this IS it. That's a real trade, which is why it's off until
    -- you ask. Requires Find Herbs / Find Minerals etc. to be on, because these
    -- are literally those blips.
    -- -------------------------------------------------------------------------
    hudEnabled       = false,

    -- Stand the HUD down in cities and inns.
    --
    -- The town POIs -- mail, inns, quests, vendors -- are engine-drawn, the same
    -- layer as the gathering blips, so we can't hide them without hiding the herbs
    -- too. But you don't gather in town, so the HUD simply steps aside while you're
    -- resting and comes back when you ride out. On by default because a city minimap
    -- blown up over your character is nobody's idea of a heads-up display.
    hudHideInCity    = true,

    -- While the HUD is up, let Eyes Up decide what your minimap tracks -- so the
    -- blips on screen are the gathering you ticked below and nothing else (no Track
    -- Humanoids, no quest markers). Snapshotted and restored when the HUD comes
    -- down; we're borrowing your tracking, not resetting it. Turn this off to manage
    -- tracking yourself.
    hudManageTracking = true,

    -- ...and WHICH gathering to show, when the above is on. Each maps to a minimap
    -- tracking type (Find Herbs, Find Minerals, Find Fish, Find Treasure). You only
    -- see the ones your professions actually grant.
    hudTrack = { herbs = true, minerals = true, fish = true, treasure = true },

    hudSize          = 400,     -- pixels across
    hudX             = 0,       -- offset from screen center
    hudY             = 0,
    hudAlpha         = 1.0,     -- the BLIPS' opacity; the map behind them is gone
    hudZoom          = 0,       -- 0 = widest = furthest sight. Zoom IS range.
    hudMask          = "clear", -- "clear" (no map at all) | "vignette" (soft edge)

    -- UP IS THE WAY YOU'RE FACING. This is what makes it a HUD rather than a map.
    --
    -- Blizzard's `rotateMinimap` CVar turns the map -- and every blip on it -- with
    -- you, so a blip above center is a herb in front of you. No bearing to read, no
    -- rotating it in your head. Off, and it's a compass rose you have to translate,
    -- which is exactly the work this addon exists to save you.
    hudRotate        = true,

    -- Keep the border, the tracking button, the mail icon, the clock and your addon
    -- buttons where they've always been. Only the MAP moves. Off takes the whole
    -- corner away.
    hudKeepCorner    = true,

    -- (There's no player-arrow setting. 12.0 removed SetPlayerTexture and the arrow
    -- is engine-drawn, so no addon can hide it. See the note in Hud.ApplyLook.)

    -- A real map in the hole where the minimap used to be.
    --
    -- Moving the minimap to your eye costs you the minimap -- the roads, the quest
    -- pins, the party dots, the fog, everything you'd ever actually glance at a
    -- corner map FOR. So we borrow Blizzard's Battlefield Map (which is a MapCanvas
    -- with all of that already wired up), park it where the minimap was, and lock it
    -- to you. See Corner.lua.
    --
    -- It cannot show gathering blips -- nothing but the minimap can, which is the
    -- reason this addon exists. That's why the two halves complement rather than
    -- overlap: the HUD is what's gatherable, the corner is where you are.
    cornerMap        = true,
    cornerZoom       = 1.0,     -- multiplier on the canvas's max zoom
    cornerAlpha      = 1.0,

    -- The compass ring.
    --
    -- Blizzard draws it when the minimap rotates, so you can still find north. On a
    -- minimap that's sensible. On a HUD it's a large metal circle across the middle
    -- of your screen, so it's off.
    --
    -- But it isn't only decoration -- it's the EDGE OF YOUR RANGE, drawn exactly.
    -- A blip on the rim is a hundred yards away. Turn it up a little (0.15-0.3) and
    -- it stops being furniture and starts being information.
    hudRingAlpha     = 0,             -- 0 = gone. 1 = Blizzard's, at full strength.
    hudRingColor     = { 1, 1, 1 },   -- tint it; the art is greyscale so it takes color well

    -- -------------------------------------------------------------------------
    -- THE BIG ONE: do you want to be told about things that might not be there?
    --
    -- Off (the default) the cue only ever fires for a node we KNOW is standing in
    -- front of you -- the soft-interact target, or a vignette. Never a false
    -- alarm, in either direction: if the cue lights up, the thing is there. The
    -- price is reach. Soft targeting sees about fifteen to twenty-five yards, and
    -- no API in the game sees further; the minimap's tracking blips are drawn by
    -- the engine and cannot be read by an addon. So this is a nudge for the node
    -- you were about to ride past, not a radar.
    --
    -- On, the cue ALSO points at remembered nodes -- yours, and GatherMate's --
    -- out to detectionYards. You get much more warning, and most of it is wrong:
    -- GatherMate lists 3,421 places a node has been in Zul'Aman and only a
    -- fraction are up at any moment. The guesses draw faint and never make a
    -- sound, so at least they look like what they are.
    --
    -- There is no third option. This is the shape of the API, not a design we
    -- chose. See Live.lua.
    -- -------------------------------------------------------------------------
    showGuesses      = false,

    -- Soft targeting has to be ON for any of the above to work (the client only
    -- resolves "softinteract" when SoftTargetInteract is 2 or 3, and most people
    -- have it off). We turn it on at login and put your setting back at logout.
    -- Off if you'd rather manage your own CVars -- but then the cue will never
    -- fire, and /eu status will say so rather than leaving you guessing.
    manageSoftTarget = true,

    -- Use somebody else's map, if they left one lying around.
    --
    -- GatherMate2_Data, if installed, does two jobs. It's the source of the
    -- guesses above (when you turn them on) -- but far more importantly, it's how
    -- we know WHERE a live node is. The soft-interact target tells us a
    -- "Tranquility Bloom" is real and near; it flatly refuses to say where.
    -- GatherMate knows where every Tranquility Bloom in the zone is. That's the
    -- arrow. Without it the cue still fires on real nodes, it just can't point.
    seedEnabled      = true,

    -- What a species drops, so we can draw its actual icon.
    --   speciesItem[type][speciesID] = itemID
    -- Learned when you gather one. Before that, a node shows its generic glyph --
    -- which is honest: we know a Mycobloom is there, we've just never seen one.
    speciesItem = { HERB = {}, MINE = {}, LUMBER = {}, FISHING = {}, TREASURE = {} },

    -- Species the classifier learned from watching you gather, for things
    -- GatherMate has never heard of.  objectType[objectName] = NodeType
    objectType = {},

    -- Everything we've ever seen, so the filter list has something to list:
    --   knownNodes[type][id] = "Display Name"
    knownNodes = { HERB = {}, MINE = {}, LUMBER = {}, FISHING = {}, TREASURE = {} },
}
