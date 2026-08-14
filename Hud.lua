-- Eyes Up - Copyright (c) 2026 KTM (abitofmoss). All Rights Reserved.
-- No redistribution or reuse of this code or assets without permission. See LICENSE.
local addonName, NS = ...

-- =============================================================================
-- Hud.lua
-- The thing this addon was always trying to be.
--
-- THE WHOLE STORY, BECAUSE IT'S SHORT AND IT MATTERS
--
-- Eyes Up spent its life working around one limitation: an addon cannot read the
-- minimap's tracking blips. The engine draws them; Lua is told nothing. Every
-- method on the Minimap widget was checked. There is no way to ask where the
-- herbs are.
--
-- So the addon guessed. It remembered where you'd gathered. It read GatherMate's
-- dump of where nodes had been seen. It leaned on the soft-target, which tells
-- the truth but only reaches fifteen yards. All of it was scaffolding built
-- around a wall.
--
-- The wall was in the wrong place.
--
-- We were trying to READ the blips so we could REDRAW them somewhere useful. But
-- the blips are already perfect: live, complete, accurate to the yard, and drawn
-- by the engine at the full range of your tracking. They have exactly one problem.
-- They're in the corner of your screen.
--
-- So don't read them. MOVE THEM.
--
-- The Minimap is a frame. Frames can be moved, resized, masked and faded. Move it
-- to the middle of the screen, then take the terrain away and leave the blips.
--
-- TWO DIALS, AND WHICH ONE DOES WHICH IS NOT OBVIOUS
--
--   the MASK   -- shapes what draws, through its alpha channel. It is a GATE, and
--                 it gates the blips too: where the mask is transparent, there are
--                 no blips either. So the mask must be OPAQUE across the whole area
--                 we want to see -- a plain round disc.
--   frame ALPHA -- Minimap:SetAlpha, a separate path, and the useful one: it fades
--                 the terrain and does NOT reach the blips. Turn it down to a
--                 hundredth and the map is simply gone while every tracking icon
--                 stays at full strength.
--
-- So: opaque mask, low alpha. What's left is node markers hanging in space over the
-- actual world, in the middle of your screen, telling the absolute truth. Which is
-- what "Eyes Up" meant all along.
--
-- IT USED TO BE THE OTHER WAY ROUND, AND THAT IS WHY THE SETTINGS LOOK ODD
--
-- Through 12.0.7 the mask did not touch the blips at all. A fully transparent mask
-- (MASK_CLEAR, alpha 0) deleted the terrain and left every icon, and hudAlpha was
-- just the HUD's overall opacity. 12.1 gave the mask a blip gate and the trick
-- died: alpha 0 erased the blips, alpha 1 erased them, alpha 64 erased them, and
-- the HUD came up empty with no error anywhere. It's a threshold, not a fade.
--
-- Frame alpha was the way out, and it behaves the same on both clients -- so there
-- is ONE code path here, not a version branch. The old masks are still selectable
-- from /eu hud mask for diagnosis; they are simply no longer how this works.
-- See BACKLOG.md for the measurements.
--
-- WHAT THIS COSTS
--
-- There is only ONE Minimap object in the game -- CreateFrame("Minimap") fails,
-- we tried. So this doesn't add a HUD, it MOVES your minimap. Turn it on and the
-- little map in your corner is gone: no terrain, no roads, no zone map. You get
-- the blips instead, where you're looking.
--
-- That's a real trade. It's on by default anyway, because it is also, quite
-- precisely, the trade this addon exists to offer -- and nobody discovers that by
-- reading an options panel.
--
-- With one exception, and it was a bug report that found it: if a UI suite is
-- already running the minimap, taking it is not a trade the player agreed to. See
-- Hud.MinimapOwner below.
-- =============================================================================

local Hud = {}
NS.Hud = Hud

-- What we borrowed, so we can give it back. The player's minimap is theirs.
local saved = nil
local hidden = {}      -- Lua regions/children we hid, so we only re-show those
local active = false

-- Forward declarations. Enable() and Disable() sit near the top of this file but
-- lean on helpers defined further down (the button patrol, the CVar restorers). A
-- `local function` isn't in scope above its own definition, so without these the
-- calls would resolve to nil globals and blow up mid-transition -- which they did,
-- and worse, Disable died before restoring the minimap, so the HUD couldn't come
-- back. Declared here, assigned (without `local`) at their real definitions below.
local startPatrol, restoreRotation, restoreRing, patrol
local applyTracking, restoreTracking
local placeMinimap, layoutMover, hideMover
local reanchoring = false     -- guards the button SetPoint hook against its own corrections
local reloadNudged = false    -- the "reload to get your skin back" note is a once-per-session thing

-- Blizzard's round mask. There is no GetMaskTexture, so the only way to put the
-- shape back is to know its name.
local ROUND_MASK = "Interface\\CHARACTERFRAME\\TempPortraitAlphaMask"

-- ---------------------------------------------------------------------------
-- NOT DURING A FIGHT.
--
-- Everything this file does is surgery on frames that are Blizzard's: reparenting
-- the Minimap, hiding the cluster, writing rotateMinimap. In combat the client
-- refuses some of that outright -- protected frames can't be restructured, secure
-- CVars can't be written -- and the answer is ADDON_ACTION_BLOCKED in your face.
--
-- Live.lua learned this the hard way with SoftTargetInteractRange. Same rule here,
-- and the same shape of answer: in combat we do nothing and remember that we owe
-- the player a pass, then run it when the fight ends.
--
-- This is barely a compromise. Rearranging somebody's minimap while they're being
-- hit is not a thing anyone wanted; a few seconds' wait is the better behaviour
-- even where the client would have allowed it.
-- ---------------------------------------------------------------------------
local combatPending = false

local function notNow()
    if InCombatLockdown and InCombatLockdown() then
        combatPending = true
        return true
    end
    return false
end

function Hud.IsActive()
    return active
end

-- ---------------------------------------------------------------------------
-- SOMEBODY ELSE'S MINIMAP.
--
-- This addon does not add a HUD. It MOVES the one Minimap object the game has. If
-- you run a UI suite -- ElvUI, EllesmereUI, SexyMap -- that object is the one it
-- skinned, sized and parented into its own layout. Take it away and, from where the
-- player is sitting, Eyes Up broke their UI. A CurseForge report said exactly that,
-- and they were right to report it.
--
-- We can't share it. There is one Minimap and CreateFrame("Minimap") fails. So the
-- only decent thing left is to ASK FIRST: if something else is clearly running the
-- minimap, don't take it unasked -- stand down, say why, and leave the HUD one
-- command away.
--
-- Two signals, because a name list ages badly on its own:
--
--   1. A known suite is loaded. Fast, exact, covers the common cases.
--   2. The Minimap is no longer parented to MinimapCluster. Blizzard puts it there;
--      anything that re-homes it into its own holder has plainly claimed it. This
--      one needs no name, so it catches the suites the list has never heard of --
--      which, on a long enough timeline, is most of them.
--
-- NAME THE MODULE, NOT THE SUITE. EllesmereUI taught this one: "EllesmereUI" is a
-- shared framework that every module in the suite depends on, so somebody running
-- only its action bars and chat has it loaded and wants nothing to do with the
-- minimap. Checking that name would stand us down for nothing. "EllesmereUIMinimap"
-- is the part that actually claims the map. Left column is the folder we test, right
-- column is the name we say out loud.
--
-- Ordered, not a hash: with two suites loaded we want the same answer every time.
-- ---------------------------------------------------------------------------
-- Each entry is { name we say out loud, { every folder that means this suite } }.
-- Folder names in the wild are not what you would guess -- "simpleMinimap" is
-- lowercase, "Square_Minimap" carries an underscore, Carbonite ships its maps in a
-- dotted folder -- and asking IsAddOnLoaded for a string that is one character off
-- returns false with no complaint. A silently wrong entry is worse than no entry,
-- because it looks like coverage. So: match case-insensitively, and list every
-- plausible folder rather than betting on one.
--
-- Verified against each project's own packaging in July 2026. EllesmereUI was
-- verified against a live install -- it's the one that proved the whole exercise
-- necessary, since the obvious guess ("EllesmereUI") is a framework every module in
-- the suite depends on and would have stood us down for people running only its
-- chat and action bars.
local MINIMAP_SUITES = {
    { "ElvUI",          { "ElvUI" } },
    { "EllesmereUI",    { "EllesmereUIMinimap" } },
    { "Tukui",          { "Tukui" } },
    { "NDui",           { "NDui" } },
    { "SpartanUI",      { "SpartanUI" } },
    { "SexyMap",        { "SexyMap" } },
    { "BasicMinimap",   { "BasicMinimap" } },
    { "Chinchilla",     { "Chinchilla" } },
    { "simpleMinimap",  { "simpleMinimap" } },
    { "Square Minimap", { "Square_Minimap", "SquareMinimap" } },
    { "Carbonite",      { "Carbonite", "Carbonite.Maps" } },
    { "LUI",            { "LUI" } },
}

-- Every loaded addon's folder name, lowercased, as a set. Enumerating beats asking
-- about names one at a time: it costs one pass, and it's what makes the matching
-- case-insensitive instead of hoping we typed the capitals the way the author did.
local function loadedAddonSet()
    local A = _G.C_AddOns or _G
    local count = A.GetNumAddOns or _G.GetNumAddOns
    local info  = A.GetAddOnInfo or _G.GetAddOnInfo
    local isOn  = A.IsAddOnLoaded or _G.IsAddOnLoaded
    if not (count and info and isOn) then return nil end

    local set, n = {}, 0
    local ok, total = pcall(count)
    if not ok or not total then return nil end

    for i = 1, total do
        local okName, name = pcall(info, i)
        if okName and name then
            local okLoaded, loaded = pcall(isOn, i)
            if okLoaded and loaded then
                set[name:lower()] = true
                n = n + 1
            end
        end
    end
    return n > 0 and set or nil
end

-- Who else thinks the minimap is theirs? A display name, or nil for "nobody".
function Hud.MinimapOwner()
    local loaded = loadedAddonSet()
    if loaded then
        -- Our order, not the game's install order, so two suites at once give the
        -- same answer every time.
        for _, entry in ipairs(MINIMAP_SUITES) do
            for _, folder in ipairs(entry[2]) do
                if loaded[folder:lower()] then return entry[1] end
            end
        end
    end

    -- THE NAMELESS CHECK -- and it has to walk the ANCESTORS, not test the parent.
    --
    -- The first cut of this compared Minimap:GetParent() against MinimapCluster and
    -- MinimapBackdrop and treated anything else as a claim. That was a bet that
    -- Blizzard's own frame hierarchy would never change shape, and in 12.0 it did:
    -- the Minimap now hangs off an ANONYMOUS container inside the cluster. The
    -- comparison failed, GetName() on the container came back nil, and the check fell
    -- through to "another addon" -- on a stock UI, with no minimap addon installed at
    -- all. It switched the HUD off on people who had asked for it and put a dialog up
    -- blaming an addon that did not exist.
    --
    -- So ask the question that actually matters. The cluster is where Blizzard keeps
    -- its minimap. If the map is still SOMEWHERE underneath it -- however many
    -- containers deep, whatever they're called -- nobody has taken it. Only a map
    -- lifted clean out of the cluster has been claimed. That answer survives Blizzard
    -- rearranging the inside of their own cluster, which is the failure this had.
    --
    -- Gone with it: the two checks that read the CLUSTER's own state (hidden, or
    -- faded below full alpha) and called either one a claim. Reparenting isn't the
    -- only way to take a minimap and those caught the rest -- but they also caught the
    -- player's own Edit Mode choices and every addon that tidies the corner without
    -- touching the map. Standing the headline feature down needs better evidence than
    -- a faded frame, and the suites that restyle in place are on the name list above.
    --
    -- Careful about WHEN this is asked: while the HUD is up the minimap is parented to
    -- UIParent by us, so it would happily report ourselves. Both callers ask while
    -- it's down.
    if not active and Minimap and MinimapCluster and Minimap.GetParent then
        -- The depth cap is paranoia about a parent loop, not about the hierarchy --
        -- Blizzard's is two or three deep.
        local holder, p, depth = nil, Minimap:GetParent(), 0

        while p and depth < 12 do
            if p == MinimapCluster then return nil end   -- still Blizzard's; nobody took it

            -- Note the first named frame on the way up, but keep climbing -- the name
            -- is only worth anything if we come out the top WITHOUT meeting the
            -- cluster. A real holder tells the player exactly who ("ElvUI_MinimapHolder").
            -- UIParent doesn't: it's where every suite that can't be bothered to build
            -- a holder drops it -- EllesmereUI among them -- and "UIParent is running
            -- your minimap" tells nobody anything.
            if not holder then
                local n = p.GetName and p:GetName()
                if n and n ~= "UIParent" then holder = n end
            end

            p = p.GetParent and p:GetParent() or nil
            depth = depth + 1
        end

        -- Out the top without passing through the cluster: the map has been moved.
        return holder or "another addon"
    end
end

-- ---------------------------------------------------------------------------
-- SAY IT WHERE IT CAN'T BE MISSED.
--
-- A chat line is the wrong shape for this. We have just switched off the feature
-- people install this addon FOR, and chat scrolls away behind loot spam and combat
-- text before anybody reads it. EllesmereUI puts a real dialog up when it finds
-- Plater running against its own nameplates, and that's the right instinct: if an
-- addon has made a decision on the player's behalf, it should say so somewhere they
-- have to look, and let them undo it in one click rather than go hunting for a
-- slash command.
--
-- Ours differs from theirs in one way, deliberately. No "don't show again" button:
-- CheckMinimapCompat stamps itself and asks once per character no matter which way
-- this goes, so offering to suppress a thing that was never going to repeat would
-- be a lie about what the alternative was. The second button does something useful
-- instead -- it turns the HUD on.
--
-- NEVER ASSIGN StaticPopupDialogs ITSELF -- not even `= StaticPopupDialogs or {}`.
--
-- Setting our own KEY in the table is the safe half, and always was. Writing the
-- GLOBAL is what breaks things: assigning a Blizzard global from addon code stamps
-- that global with our taint for the rest of the session, and every piece of
-- Blizzard code that reads it afterwards inherits the stamp. Popups are read from
-- all over the UI, the Escape / game-menu path included, and a tainted execution
-- there is refused the protected calls it needs -- ClearTarget when you press
-- Escape with a target, Quit when you click "Exit Game".
--
-- What the player sees is an Escape key that throws ADDON_ACTION_FORBIDDEN and a
-- game they cannot log out of, and there is no way to guess from either symptom
-- that a minimap addon caused it. Blizzard's UI builds this table long before any
-- addon loads, so the `or {}` was never protecting against anything anyway.
-- ---------------------------------------------------------------------------
StaticPopupDialogs["EYESUP_MINIMAP_TAKEN"] = {
    text = "|cff66ff66Eyes Up|r\n\n"
        .. "%s is running your minimap, so the blip HUD has been left off.\n\n"
        .. "The HUD works by MOVING your minimap to the middle of the screen -- "
        .. "there's only one of them, so it can't be in both places at once.\n\n"
        .. "Everything else in Eyes Up is already running.",
    button1 = _G.OKAY or "Okay",
    button2 = "Use the HUD anyway",
    -- Two-button StaticPopups map button1 to OnAccept and button2 to OnCancel.
    -- "Cancel" here means "no, take the minimap", which reads backwards in the
    -- source and exactly right on screen.
    OnCancel = function()
        if NS.Hud then NS.Hud.SetEnabled(true) end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,      -- keeps us off Blizzard's own dialog slots, and out of their taint
}

-- ---------------------------------------------------------------------------
-- The question, asked at every login and answered on the player's behalf.
--
-- WE REMEMBER WHO, NOT WHETHER. The first cut of this stored a boolean -- "already
-- asked" -- and that has one failure that gets worse the longer somebody uses the
-- addon: answer it once for EllesmereUI, uninstall EllesmereUI a year later, install
-- SexyMap, and Eyes Up quietly takes the new minimap without a word, because it
-- remembers being asked A question rather than THAT question.
--
-- So the stamp is the owner's name. Same suite as last time, stay quiet forever.
-- Different suite -- or a suite where there wasn't one before -- and it's a new
-- question, so ask it. Nobody gets nagged about a decision they've already made, and
-- nobody gets silently overridden because their setup changed.
--
-- Deliberately NOT a key in NS.defaults -- see the identityVersion note in Core.lua:
-- a default would hand every install the "already asked" mark, and this would never
-- fire for the very people it exists for.
--
-- Note the order of the guards. We stamp only when we ACTUALLY ask, which means the
-- HUD-is-off case falls through without recording anything: there's nothing to stand
-- down, so there's no decision to remember, and if they turn the HUD on later we
-- still owe them the question.
-- ---------------------------------------------------------------------------
function Hud.CheckMinimapCompat()
    local db = NS.db
    if not (db and db.hudRespectOtherAddons) then return end

    local owner = Hud.MinimapOwner()
    if not owner then return end            -- nobody else wants it; nothing to ask
    if db.hudCompatAsked == owner then return end   -- asked, answered, settled
    if not db.hudEnabled then return end    -- already off; ask if it ever comes on

    db.hudCompatAsked = owner
    db.hudEnabled = false

    -- Take it down NOW, don't just record the wish. At login this was harmless --
    -- Core calls Refresh a line later anyway -- but the moment anything else calls
    -- this mid-session (a compat reset, say) the flag alone would leave a HUD up
    -- that the database says is off. Refresh is idempotent, so the login path is
    -- unchanged.
    Hud.Refresh()

    -- The dialog is the part people will actually read. The chat line is the record
    -- underneath it, for whoever clicks Okay on reflex and wonders an hour later
    -- where the HUD went.
    NS.Printf("|cffffcc00%s is running your minimap, so the blip HUD stayed off.|r "
        .. "|cffffff00/eu on|r to use it anyway.", owner)

    if _G.StaticPopup_Show then
        _G.StaticPopup_Show("EYESUP_MINIMAP_TAKEN", owner)
    end
end

-- ---------------------------------------------------------------------------
-- THE CORNER STAYS. Only the map leaves.
--
-- The first cut of this hid the whole MinimapCluster, which threw out the border,
-- the tracking button, the mail icon, the clock and every addon's little minimap
-- button along with it. Those are all useful and none of them belong on a HUD --
-- they belong exactly where they were.
--
-- So the cluster stays in the corner. We take the MAP out of it and leave a dark
-- disc in the hole, so the ring doesn't look broken.
--
-- The addon buttons are the fiddly part: LibDBIcon anchors them to the Minimap
-- itself ("CENTER", Minimap, "CENTER", x, y), so when the map flies to the middle
-- of the screen they cheerfully follow it and orbit your HUD. They have to be
-- re-parented AND re-anchored to something that stays behind. That's what the tray
-- is: a frame sitting exactly where the minimap used to be, so the buttons keep
-- their positions and go on working.
-- ---------------------------------------------------------------------------
local tray
local moved = {}       -- { obj, parent, point } for everything we relocated

local function ensureTray()
    if tray then return tray end

    -- PARENTED TO UIParent, NOT THE CLUSTER -- and that's not a style choice.
    --
    -- Alpha is inherited. EllesmereUI doesn't HIDE MinimapCluster when it takes the
    -- minimap over, it sets the cluster's alpha to 0 and leaves it shown. Hang the
    -- tray off that and the tray, its disc, and every addon button we carefully
    -- parked on it are all invisible -- so the corner we went to this trouble to
    -- preserve just looks empty, which is the exact complaint this release is about.
    --
    -- Anchoring is unaffected: we still SetPoint against whatever the minimap was
    -- anchored to (see stripArt), and anchoring to a transparent frame resolves
    -- perfectly well. Only PARENTING inherits the alpha.
    tray = CreateFrame("Frame", "EyesUpMinimapTray", UIParent)
    tray:SetFrameStrata("LOW")
    tray:SetAlpha(1)

    -- A dark disc where the map used to be. Without it the corner is a ring around
    -- a hole, which reads as a bug rather than a choice.
    local disc = tray:CreateTexture(nil, "BACKGROUND")
    disc:SetAllPoints(tray)
    disc:SetColorTexture(0, 0, 0, 0.55)
    disc:SetMask(NS.CustomGlyphDir .. "MASK_ROUND")
    tray.disc = disc

    return tray
end

-- ---------------------------------------------------------------------------
-- Herding the addon buttons. This has to be re-asserted, not done once.
--
-- LibDBIcon anchors every minimap button like this (LibDBIcon-1.0.lua:173):
--
--     button:SetPoint("CENTER", Minimap, "CENTER", x, y)
--
-- Hardcoded to Minimap, with the orbit radius computed from Minimap:GetWidth()/2.
-- So the instant ANY addon refreshes its button -- a config change, a new addon
-- loading, a drag, LibDBIcon's own periodic tidy -- it re-anchors itself to the
-- 400-pixel minimap now sitting at the centre of your screen, and cheerfully
-- orbits your character. A single reparent at startup cannot survive that, and it
-- doesn't catch buttons registered later either.
--
-- So we sweep, repeatedly, while the HUD is up. It's a handful of buttons a couple
-- of times a second: nothing.
--
-- WE KEEP THE ANCHOR, NOT AN ANGLE. This used to store only the angle a button sat
-- at and rebuild every position from it -- on the tray AND on the way back out. That
-- is right for exactly one kind of button (a LibDBIcon icon orbiting the ring) and
-- wrong for every other kind, because an angle cannot describe "TOPRIGHT of the
-- cluster, minus eight pixels". Anything that wasn't orbiting got flung onto the
-- ring and left there, so turning the HUD off handed back a corner full of icons
-- the player never arranged.
--
-- So we snapshot every anchor verbatim and put it back verbatim. The tray is the
-- same size and in the same place as the minimap was, so while the HUD is up we can
-- simply replay those anchors with the tray standing in for the Minimap and every
-- button lands on the pixel it was already on.
--
-- The angle survives for LibDBIcon only, and only while parked -- see adopt().
-- ---------------------------------------------------------------------------
local atan2, cos, sin, rad = math.atan2, math.cos, math.sin, math.rad

-- Blizzard's own minimap buttons ride along too, and they're NOT direct children
-- of Minimap -- the expansion "gem" is under MinimapBackdrop, the queue eye and the
-- garrison button float around the cluster. Name them so the patrol can find them
-- wherever they're parented.
--
-- Naming a button here only means "go and look at it". followsMinimap() has the
-- final say, and for the queue eye the answer is usually no.
local BLIZZ_BUTTONS = {
    "ExpansionLandingPageMinimapButton",   -- the purple expansion gem
    "GarrisonLandingPageMinimapButton",
    "QueueStatusButton",
    "MiniMapMailFrame",                    -- the "you have mail" flag
}

-- Is this frame the Minimap, or something living inside it?
local function underMinimap(f)
    local depth = 0
    while f and depth < 12 do
        if f == Minimap then return true end
        f = f.GetParent and f:GetParent() or nil
        depth = depth + 1
    end
    return false
end

-- ---------------------------------------------------------------------------
-- DOES THIS BUTTON ACTUALLY TRAVEL WITH THE MAP?
--
-- The bug that prompted this: the Dungeon Finder eye. BLIZZ_BUTTONS named it, so we
-- parked it on the tray unconditionally -- but QueueStatusButton is placed by Edit
-- Mode and can live anywhere on screen. It was never anchored to the Minimap, so it
-- was never going to follow the HUD anywhere. All we did was take a button the
-- player had deliberately positioned and stick it on the minimap ring.
--
-- Only two things move when the Minimap moves: its children, and anything anchored
-- to it. Everything else we leave alone -- there is nothing to rescue it from.
--
-- Edit Mode frames are out regardless. Those own their own position, the player set
-- it in a UI built for the purpose, and Edit Mode re-applies its layout on its own
-- schedule -- so moving one is both rude and a fight we'd lose.
-- ---------------------------------------------------------------------------
local function followsMinimap(btn)
    -- Parentage first, and it beats everything below it. A child of the Minimap is
    -- carried to the middle of the screen whether Edit Mode has opinions or not, so
    -- refusing to park it wouldn't leave it alone -- it would just abandon it out
    -- there, invisible, with its textures swept up by hideLuaTextures.
    if underMinimap(btn:GetParent()) then return true end

    if btn.IsInDefaultPosition then return false end     -- an Edit Mode system; not ours

    for i = 1, (btn.GetNumPoints and btn:GetNumPoints() or 0) do
        local _, rel = btn:GetPoint(i)
        if underMinimap(rel) then return true end
    end
    return false
end

-- Every anchor a button is wearing, so we can put it back exactly as we found it.
local function capturePoints(btn)
    local pts = {}
    for i = 1, (btn.GetNumPoints and btn:GetNumPoints() or 0) do
        local p, rel, rp, x, y = btn:GetPoint(i)
        pts[#pts + 1] = { p, rel, rp, x or 0, y or 0 }
    end
    return pts
end

-- Replay a captured anchor list. With `swapTo`, anything anchored to the Minimap is
-- anchored to that instead -- which is how a button keeps its exact position in the
-- corner while the map it was pinned to is off in the middle of the screen.
--
-- underMinimap, not `== Minimap`: a button anchored to something INSIDE the map
-- (MinimapBackdrop, in the client versions that put it there) has been carried off
-- to the screen centre just the same. The tray is the same size and place, so
-- standing it in for a child frame is a close approximation rather than an exact
-- one -- and an approximation in the corner beats an exact answer in the middle of
-- your screen.
local function replay(btn, pts, swapTo)
    btn:ClearAllPoints()
    for _, pt in ipairs(pts) do
        local rel = pt[2]
        if swapTo and underMinimap(rel) then rel = swapTo end
        btn:SetPoint(pt[1], rel or btn:GetParent() or UIParent, pt[3], pt[4], pt[5])
    end
end

-- Put a parked button where it belongs on the tray.
local function reanchor(btn)
    local m = moved[btn]
    if not (m and tray) then return end
    reanchoring = true                     -- so our own SetPoint doesn't re-trigger the hook
    if m.angle then
        local r = (tray:GetWidth() / 2) + 10
        btn:ClearAllPoints()
        btn:SetPoint("CENTER", tray, "CENTER", cos(m.angle) * r, sin(m.angle) * r)
    else
        replay(btn, m.points, tray)
    end
    reanchoring = false
end

-- Adopt a button: remember where it came from, move it to the tray, and -- the key
-- part -- HOOK its SetPoint.
--
-- LibDBIcon re-anchors its buttons to Minimap on every interaction (OnEnter,
-- OnClick, OnDragStop all call button:SetPoint("CENTER", Minimap, ...)). With the
-- Minimap sitting at screen center, that flings the button to the middle of your
-- screen the instant you touch it. A periodic patrol can't win that race -- it only
-- corrects a fraction of a second later, so you see the snap.
--
-- So we catch it at the source: the moment anything re-points the button, our hook
-- fires (same frame) and puts it back on the tray. The reanchoring flag stops our
-- own correction from re-entering the hook.
local function adopt(btn)
    if not (btn and btn.SetParent and btn:IsShown()) then return end

    -- Nothing to rescue it from? Then leave it exactly where it is. Once we HAVE
    -- adopted it the test can't answer any more (it's on the tray now), so a button
    -- we already own stays owned until the HUD comes down.
    if not (moved[btn] or followsMinimap(btn)) then return end

    if not moved[btn] then
        local p, rel, rp, x, y = btn:GetPoint(1)
        moved[btn] = {
            parent = btn:GetParent(),
            strata = btn:GetFrameStrata(),
            points = capturePoints(btn),

            -- LibDBIcon's orbit, and nothing else: CENTER on the Minimap's CENTER
            -- with an offset. It gets the angle treatment because its offsets are
            -- not stable -- LibDBIcon recomputes the radius from Minimap:GetWidth()
            -- every time it touches the button, so with the HUD up they're sized for
            -- a 400px map and replaying them would fling the icon half a screen off
            -- the tray. The angle is the part the player actually chose; we keep
            -- that and recompute the radius for the tray.
            --
            -- Note this is only used while parked. Coming back out we replay the
            -- captured anchors like everything else, because by then the real
            -- offsets are correct again.
            angle = (p == "CENTER" and rp == "CENTER" and rel == Minimap
                     and x and y and (x ~= 0 or y ~= 0)) and atan2(y, x) or nil,
        }

        -- A Minimap child with no anchors at all has nothing to replay, so give it
        -- the orbit treatment rather than dropping it on the tray's centre.
        if #moved[btn].points == 0 and not moved[btn].angle then
            moved[btn].angle = rad(225)
        end
    end

    btn:SetParent(tray)
    btn:SetFrameStrata("MEDIUM")           -- the HUD is at BACKGROUND; these mustn't be
    reanchor(btn)

    if not btn.__eyesupHooked then
        btn.__eyesupHooked = true
        hooksecurefunc(btn, "SetPoint", function(self)
            -- Only fight for it while the HUD is up and we still own this button;
            -- otherwise let LibDBIcon place it normally.
            if active and not reanchoring and moved[self] then
                local m = moved[self]
                -- If that was the player dragging a LibDBIcon button, take the new
                -- angle with us -- otherwise a drag while the HUD is up silently
                -- does nothing. The radius still gets thrown away; it's sized for
                -- the 400px map.
                if m.angle then
                    local p, rel, rp, x, y = self:GetPoint(1)
                    if p == "CENTER" and rp == "CENTER" and rel == Minimap
                       and x and y and (x ~= 0 or y ~= 0) then
                        m.angle = atan2(y, x)
                    end
                end
                reanchor(self)
            end
        end)
    end
end

function Hud.ParkButtons()
    if not (active and tray and NS.db and NS.db.hudKeepCorner ~= false) then return end

    -- Addon buttons: LibDBIcon parents them straight to Minimap.
    for _, child in ipairs({ Minimap:GetChildren() }) do
        if child:GetObjectType() == "Button" then adopt(child) end
    end

    -- ...and any Blizzard button hiding a level down, by name.
    for _, name in ipairs(BLIZZ_BUTTONS) do
        adopt(_G[name])
    end
end

-- The blobs: the checkered fill WoW paints over quest / task / archaeology areas.
-- They're not plain regions -- the engine draws them -- but the Minimap widget has
-- dedicated setters, so a zero alpha erases them. That mesh arc bleeding across the
-- HUD is one of these.
--
-- No getters exist, so we can't snapshot the originals; on the way out we set them
-- back to Blizzard's defaults (1 outside/ring, and inside stays subtle). A /reload
-- restores the exact values, but you'll rarely notice.
local BLOB_KINDS  = { "Quest", "Task", "Arch" }
local BLOB_PARTS  = { "InsideAlpha", "OutsideAlpha", "RingAlpha" }

local function setBlobAlpha(a)
    for _, k in ipairs(BLOB_KINDS) do
        for _, part in ipairs(BLOB_PARTS) do
            local m = Minimap["Set" .. k .. "Blob" .. part]
            if m then pcall(m, Minimap, a) end
        end
    end
end

-- Everything else that's Lua and leaks: borders, rings, north tags, POI-pin art
-- sitting on child frames. The gathering blips are ENGINE-drawn -- they are not Lua
-- Texture regions and cannot be enumerated here -- so hiding every Lua texture we
-- can find can never touch them. That's what makes this safe to do bluntly.
--
-- We skip Buttons (parked separately) and the compass texture (applyRing owns it).
local function hideLuaTextures(frame, depth)
    if not frame or depth > 6 then return 0 end
    local compass = _G.MinimapCompassTexture
    local n = 0

    if frame.GetRegions then
        for _, r in ipairs({ frame:GetRegions() }) do
            if r ~= compass and r.GetObjectType and r:GetObjectType() == "Texture"
               and r.IsShown and r:IsShown() then
                r:Hide()
                -- Dedupe: the engine re-shows POI/landmark textures as you move, so
                -- the patrol re-hides them -- but we must only record each once, or
                -- `hidden` grows without bound over a session.
                if not r.__euHid then
                    r.__euHid = true
                    hidden[#hidden + 1] = r
                    -- Log the FIRST time we hide each, with its art, so we can see
                    -- exactly which POIs are Lua (caught here) and which aren't.
                    if NS.db and NS.db.debug then
                        local art = (r.GetAtlas and r:GetAtlas())
                                    or (r.GetTextureFilePath and select(1, pcall(r.GetTextureFilePath, r)))
                                    or (r.GetTexture and r:GetTexture())
                        NS.Printf("  hud hid: %s", tostring(art))
                    end
                end
                n = n + 1
            end
        end
    end
    if frame.GetChildren then
        for _, c in ipairs({ frame:GetChildren() }) do
            -- Descend into everything EXCEPT a button we've parked on the tray
            -- (those aren't under the Minimap any more anyway -- belt and braces).
            -- POI pins (mailbox, vendor) are often Buttons, so we must NOT skip
            -- buttons wholesale or their icons slip through.
            if not moved[c] then
                n = n + hideLuaTextures(c, depth + 1)
            end
        end
    end
    return n
end

local function stripArt()
    wipe(hidden)
    wipe(moved)

    local db = NS.db

    -- The quest/task blobs, gone.
    setBlobAlpha(0)

    if db and db.hudKeepCorner ~= false then
        -- Park the tray exactly where the map was, then move every button child
        -- (addon icons, zoom buttons) onto it so they stay in the corner.
        local t = ensureTray()
        t:ClearAllPoints()
        if saved and saved.point and saved.point[1] then
            t:SetPoint(unpack(saved.point))
        else
            t:SetPoint("CENTER", MinimapCluster or UIParent, "CENTER", 0, 0)
        end
        t:SetSize(saved and saved.w or 140, saved and saved.h or 140)
        t:Show()

        Hud.ParkButtons()

        -- AFTER the buttons are safely on the tray, sweep every remaining Lua
        -- texture off the Minimap -- ring, border, and any decoration bleeding
        -- through. Blips survive (they're engine-drawn); parked buttons survive
        -- (they're no longer Minimap descendants).
        --
        -- "Blips survive" is the load-bearing claim, and hudSweep is how you check
        -- it. See Hud.SetSweep.
        if db.hudSweep ~= false then hideLuaTextures(Minimap, 0) end
    else
        -- Corner off: take the buttons away entirely rather than let them orbit
        -- the HUD.
        for _, child in ipairs({ Minimap:GetChildren() }) do
            if child:IsShown() then
                child:Hide()
                hidden[#hidden + 1] = child
            end
        end
        if MinimapCluster and MinimapCluster:IsShown() then
            MinimapCluster:Hide()
            hidden[#hidden + 1] = MinimapCluster
        end
    end
end

local function restoreArt()
    -- Quest/task blobs back to Blizzard's defaults (best-effort; /reload is exact).
    setBlobAlpha(1)

    -- Hand the buttons back the way we found them: same parent, same strata, same
    -- anchors, to the pixel.
    --
    -- This used to re-place everything on a ring around the Minimap at the angle it
    -- had been sitting at, which is a fine description of a LibDBIcon icon and a
    -- terrible one for anything else. Buttons that had never been on the ring got
    -- put on it, and stayed there, so switching the HUD off in a city left the
    -- corner rearranged. The captured anchors say exactly where each one belongs, so
    -- use those and only fall back to the ring for a button that had none.
    for btn, m in pairs(moved) do
        if btn and btn.SetParent then
            btn:SetParent(m.parent or Minimap)
            if m.strata then btn:SetFrameStrata(m.strata) end
            if m.points and #m.points > 0 then
                replay(btn, m.points)
            else
                -- saved.w, NOT Minimap:GetWidth(). We run BEFORE Disable() puts the
                -- map back to its own size, so asking the map gives us 400 and a
                -- 210px orbit around a 140px minimap -- icons strewn well outside
                -- the ring. The old code read the live width here and that is a good
                -- part of what the corner looked like afterwards.
                local r = ((saved and saved.w or Minimap:GetWidth()) / 2) + 10
                local a = m.angle or rad(225)
                btn:ClearAllPoints()
                btn:SetPoint("CENTER", Minimap, "CENTER", cos(a) * r, sin(a) * r)
            end
        end
    end
    wipe(moved)

    if tray then tray:Hide() end

    for i = 1, #hidden do
        local o = hidden[i]
        if o then
            o.__euHid = nil
            if o.Show then o:Show() end
        end
    end
    wipe(hidden)
end

-- ---------------------------------------------------------------------------
-- On
-- ---------------------------------------------------------------------------
function Hud.Enable()
    if active or not Minimap then return end
    if notNow() then return end
    local db = NS.db
    if not db then return end

    -- Everything with a getter, taken before we touch any of it. Scale and mouse
    -- were missing here and it showed: we handed back a hard-coded scale of 1 and
    -- mouse-on, which is Blizzard's minimap, not necessarily theirs. If a suite had
    -- scaled it to 0.8 with the mouse off, turning the HUD off "fixed" their minimap
    -- into something they'd never set.
    saved = {
        parent = Minimap:GetParent(),
        point  = { Minimap:GetPoint(1) },
        w      = select(1, Minimap:GetSize()),
        h      = select(2, Minimap:GetSize()),
        alpha  = Minimap:GetAlpha(),
        strata = Minimap:GetFrameStrata(),
        zoom   = Minimap:GetZoom(),
        scale  = Minimap:GetScale(),
        level  = Minimap:GetFrameLevel(),
        mouse  = Minimap:IsMouseEnabled(),
    }

    -- UNLOCK BEFORE WE SET. A minimap addon can nail the strata and level down with
    -- SetFixedFrameStrata/SetFixedFrameLevel -- EllesmereUI does exactly that -- and
    -- once it's fixed, SetFrameStrata is silently ignored. No error, no warning: the
    -- HUD just comes up at whatever strata the suite chose, so a 400px minimap sits
    -- ON TOP of your action bars instead of behind them. Unlock first and the set
    -- below means what it says.
    --
    -- We don't re-lock on the way out. There's no getter to tell us it was locked in
    -- the first place, and the suite re-applies it on its next rebuild anyway -- which
    -- is what the /reload note in SetEnabled is for.
    if Minimap.SetFixedFrameStrata then pcall(Minimap.SetFixedFrameStrata, Minimap, false) end
    if Minimap.SetFixedFrameLevel then pcall(Minimap.SetFixedFrameLevel, Minimap, false) end

    Minimap:SetParent(UIParent)
    placeMinimap()
    Minimap:SetFrameStrata("BACKGROUND")     -- behind everything; it's scenery, not UI
    -- Room to slide a disc UNDER it. Frame levels can't go below zero, so if the
    -- minimap is sitting at the bottom of its strata there is nowhere to put the
    -- backdrop and it draws in front of the blips instead -- which looks exactly
    -- like the backdrop setting being broken. Snapshotted above, restored below.
    if (Minimap:GetFrameLevel() or 0) < 2 then Minimap:SetFrameLevel(2) end
    -- Mouse: off by default (a 400px zone that eats clicks in the middle of your
    -- screen is a nuisance while you're grabbing nodes), but the minimap's blip
    -- tooltips only work WITH the mouse on -- so it's a toggle. See ApplyLook.
    Minimap:EnableMouse(db.hudTooltips and true or false)

    -- BEFORE ApplyLook, not after. ApplyLook is also the live handler for the
    -- sliders, so it early-outs when the HUD isn't up -- which means calling it
    -- while `active` is still false does exactly nothing, and the mask never gets
    -- applied. You get Blizzard's round mask, the terrain stays, and the whole
    -- trick silently doesn't happen.
    active = true

    Hud.ApplyLook()
    stripArt()
    startPatrol()

    -- Give back what we just took: a real map, in the hole where the minimap was.
    -- It needs the tray, which stripArt() has only just built -- hence last.
    if NS.db.cornerMap and NS.Corner then
        NS.Corner.Enable()
    end
end

-- ---------------------------------------------------------------------------
-- Off -- and it has to be complete, because this is somebody's minimap.
-- ---------------------------------------------------------------------------
function Hud.Disable()
    if not active or not Minimap then return end
    -- Giving the minimap back is as much frame surgery as taking it was, so it
    -- waits too. The HUD stays up for the rest of the fight; nobody is gathering
    -- mid-pull anyway.
    if notNow() then return end

    -- Undo our own combat hide before anything else, while `active` is still true
    -- (SetCombatHidden won't re-show a HUD it thinks is down). Skip this and the
    -- minimap is handed back to the corner still hidden, which reads as the addon
    -- having eaten it.
    Hud.SetCombatHidden(false)

    -- FIRST, before we touch anything: the button SetPoint hook keys off `active`,
    -- and restoreArt is about to re-point every button back to the Minimap. Leave
    -- `active` true and the hook fights the restore, dragging them back to the tray.
    active = false

    if patrol then patrol:Hide() end
    -- Nothing of ours left on screen -- and PIN IT while we're here. Unlocked is a
    -- transient state, not a setting: the HUD folds away on its own in cities and
    -- dungeons, and coming back to "unlocked, but no handle anywhere" would leave
    -- the options page offering to pin something that isn't there.
    if NS.db then NS.db.hudLocked = true end
    pcall(hideMover)
    if NS.Corner then NS.Corner.Disable() end   -- before the tray goes away

    restoreArt()
    restoreRing()
    restoreRotation()
    restoreTracking()

    -- Their mouse setting, not a guess at it. Read it out before `saved` is dropped,
    -- and mind the Lua trap: `saved.mouse or true` is true when the stored value is
    -- false, which is the exact case this is here to preserve.
    local wantMouse = true

    if saved then
        if saved.mouse ~= nil then wantMouse = saved.mouse end
        Minimap:SetParent(saved.parent)
        Minimap:ClearAllPoints()
        if saved.point[1] then Minimap:SetPoint(unpack(saved.point)) end
        Minimap:SetSize(saved.w, saved.h)
        Minimap:SetAlpha(saved.alpha)
        Minimap:SetFrameStrata(saved.strata)
        if saved.level then Minimap:SetFrameLevel(saved.level) end
        if saved.scale then Minimap:SetScale(saved.scale) end
        if saved.zoom then Minimap:SetZoom(saved.zoom) end
    end

    -- The mask is the one thing we cannot hand back exactly. There is no
    -- GetMaskTexture (see ROUND_MASK at the top), so we can't snapshot the shape we
    -- replaced -- only put A shape back. Blizzard's round one, because a minimap
    -- still wearing our clear mask is an INVISIBLE minimap, which is a far worse
    -- failure than the wrong outline.
    --
    -- So if a suite gave it a square mask and a border, that's gone until the suite
    -- redraws it, and it won't until a reload. SetEnabled says so out loud rather
    -- than leaving someone staring at a round minimap in a square UI.
    if Minimap.SetMaskTexture then
        pcall(Minimap.SetMaskTexture, Minimap, ROUND_MASK)
    end
    Minimap:EnableMouse(wantMouse)

    saved = nil
    -- active was set false at the top, on purpose -- see the note there.
end

-- ---------------------------------------------------------------------------
-- Size, place, opacity, range -- applied live, so the sliders feel like sliders.
--
-- ZOOM IS RANGE. The minimap's zoom level decides how many yards it shows, and
-- C_Minimap.GetViewRadius will tell us exactly how many. Zoom 0 is the widest
-- view -- about a hundred yards -- which for a heads-up display is the whole
-- point: it sees five times further than the soft-target ever could, and unlike
-- the soft-target it sees EVERYTHING, not just the nearest one thing.
-- ---------------------------------------------------------------------------
-- ---------------------------------------------------------------------------
-- FACING. This is what turns a map into a heads-up display.
--
-- `rotateMinimap` is a real Blizzard CVar and it does exactly what we want for
-- free: the map -- and every blip on it -- turns with you, so UP IS THE WAY YOU
-- ARE FACING. A blip above centre is a herb in front of you. No bearing maths, no
-- arrow to read, no translation in your head. You just look.
--
-- Unrotated, a HUD is a compass rose you have to mentally rotate, which is exactly
-- the work this addon exists to save you. So it's on by default here.
--
-- It's the player's CVar, so we snapshot it and put it back.
-- ---------------------------------------------------------------------------
local GetCVar = C_CVar and C_CVar.GetCVar or _G.GetCVar
local SetCVar = C_CVar and C_CVar.SetCVar or _G.SetCVar

local savedRotate = nil

local function applyRotation()
    local db = NS.db
    if not SetCVar or not db then return end

    if db.hudRotate then
        if savedRotate == nil then savedRotate = GetCVar("rotateMinimap") end
        SetCVar("rotateMinimap", 1)
    elseif savedRotate ~= nil then
        SetCVar("rotateMinimap", savedRotate)
        savedRotate = nil
    end
end

function restoreRotation()
    if savedRotate ~= nil and SetCVar then
        SetCVar("rotateMinimap", savedRotate)
        savedRotate = nil
    end
end

-- ---------------------------------------------------------------------------
-- The compass ring.
--
-- Turn rotation on and Blizzard draws a ring with four gold chevrons around the
-- minimap, so you can still find north on a map that's spinning. Perfectly
-- sensible on a minimap. On a HUD it's a large metal circle drawn across the
-- middle of your screen.
--
-- It slips past stripArt() because it isn't hidden when we run -- the client shows
-- it in REACTION to us setting rotateMinimap, which lands a moment later. So it
-- gets handled on its own, and re-handled whenever the client touches the CVars.
--
-- It's an ordinary Texture, so it can be hidden, faded or tinted. Hidden by
-- default; hudRingAlpha turns it back up if you want the range circle as a frame
-- of reference. It IS a useful thing to see -- it's the edge of your 100 yards.
-- ---------------------------------------------------------------------------
local function compassTexture()
    return _G.MinimapCompassTexture or (Minimap and Minimap.compassTexture)
end

local function applyRing()
    local db = NS.db
    local c = compassTexture()
    if not (c and db) then return end

    local a = db.hudRingAlpha or 0
    if a <= 0 then
        c:Hide()
    else
        c:Show()
        c:SetAlpha(a)
        local col = db.hudRingColor
        if col and c.SetVertexColor then
            c:SetVertexColor(col[1] or 1, col[2] or 1, col[3] or 1)
        end
    end
end

-- ---------------------------------------------------------------------------
-- MINIMAP TRACKING: show the gathering, hush the rest.
--
-- The HUD shows every tracking blip the game is drawing -- and if you've got Track
-- Humanoids or Track Beasts or a dozen quest trackers on, all of that lands on your
-- screen too, not just the herbs and ore you care about. We can't filter the blip
-- layer, but we CAN decide what the game tracks in the first place.
--
-- C_Minimap's tracking is a filter list: each type has an index, a name, an active
-- flag, and a spellID. So while the HUD is up we turn ON the gathering types and
-- OFF the rest -- then put every one back exactly as we found it when the HUD comes
-- down. The player's tracking is theirs; we're only borrowing it.
--
-- Each type is looked up in db.hudTrackList (keyed by spellID, or name for the
-- non-spell ones). A type the player hasn't touched uses the DEFAULT, which is why
-- trackCategory exists: it tags the gathering types so they default ON and
-- everything else -- Mailbox, Auctioneer, Track Beasts, quests -- defaults OFF.
-- See Hud.TrackWanted. The options page shows a checkbox for every one of them.
-- ---------------------------------------------------------------------------
local TRACK_CATEGORIES = {
    { key = "herbs",    spell = 2383,  words = { "herb" } },
    { key = "minerals", spell = 2580,  words = { "mineral", "ore" } },
    { key = "lumber",   spell = 1256697, words = { "lumber", "timber", "logging" } },
    { key = "fish",     spell = 43308, words = { "fish" } },
    { key = "treasure", spell = 2481,  words = { "treasure" } },
}

-- Which category is this tracking type, or nil for "not gathering".
local function trackCategory(name, spellID)
    if spellID then
        for _, c in ipairs(TRACK_CATEGORIES) do
            if spellID == c.spell then return c.key end
        end
    end
    -- Guard the type: 12.0 hands GetTrackingInfo back as a TABLE; unpacking it as a
    -- tuple once put the whole table where `name` should be, and name:lower() on a
    -- table is a nil call -- the crash that spammed a thousand times.
    if type(name) == "string" then
        local n = name:lower()
        for _, c in ipairs(TRACK_CATEGORIES) do
            for _, w in ipairs(c.words) do
                if n:find(w) then return c.key end
            end
        end
    end
    return nil
end

-- GetTrackingInfo changed shape. Older clients return a tuple
-- (name, texture, active, category, nested, spellID); 12.0 returns a table with
-- named fields. Read both and hand back just what we use: name, active, spellID.
local function getTracking(i)
    local a, _, c, _, _, f = C_Minimap.GetTrackingInfo(i)
    if type(a) == "table" then
        return a.name, a.active, a.spellID
    end
    return a, c, f
end

local savedTracking = nil

function applyTracking()
    local db = NS.db
    if not (db and db.hudManageTracking and C_Minimap and C_Minimap.GetNumTrackingTypes) then
        return
    end

    local n = C_Minimap.GetNumTrackingTypes()
    if not n or n == 0 then return end

    -- Snapshot once, so a re-ApplyLook mid-session doesn't record our OWN changes
    -- as the "original" and lose the real state.
    if not savedTracking then
        savedTracking = {}
        for i = 1, n do
            local _, activeState = getTracking(i)
            savedTracking[i] = activeState and true or false
        end
    end

    for i = 1, n do
        local name, activeState, spellID = getTracking(i)

        -- A TYPE WE CANNOT NAME IS A TYPE WE CANNOT JUDGE.
        --
        -- getTracking has already had to change shape once (tuple in 11.x, table in
        -- 12.0) and it will again. When it stops reading, every entry comes back
        -- nil -- so trackCategory says "not gathering" for all of them, TrackWanted
        -- says off for all of them, and this loop cheerfully switches off the
        -- player's ENTIRE tracking. No error, no clue: the HUD comes up, the corner
        -- map swaps in, and there is simply nothing on it, forever.
        --
        -- So identification is a precondition, not an input. Can't read it, don't
        -- touch it. The cost of being wrong that way is some clutter on the HUD; the
        -- cost of being wrong the other way is the whole feature, silently.
        if name ~= nil or spellID ~= nil then
            local cat = trackCategory(name, spellID)
            local want = Hud.TrackWanted(spellID or name, cat)
            if want ~= (activeState and true or false) then
                C_Minimap.SetTracking(i, want)
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- The per-type tracking model, shared with the options page.
--
--   key    = spellID, or the name for the non-spell types (Mailbox, Auctioneer)
--   cat    = a gathering category (herbs/minerals/...) or nil for everything else
--
-- A key the player has never touched uses the DEFAULT: on for gathering, off for
-- the rest. So the HUD starts clean, and everything is one tick away.
-- ---------------------------------------------------------------------------
function Hud.TrackWanted(key, cat)
    local saved = NS.db and NS.db.hudTrackList and NS.db.hudTrackList[key]
    if saved ~= nil then return saved end
    return cat ~= nil          -- default: gathering shown, all else hidden
end

function Hud.SetTrackWanted(key, on)
    if not NS.db then return end
    NS.db.hudTrackList = NS.db.hudTrackList or {}
    NS.db.hudTrackList[key] = on and true or false
    if active then Hud.ApplyLook() end     -- enforce it right away
end

-- Every tracking type the client currently offers, in menu order, tagged with its
-- key and gathering category. The options page builds a checkbox per entry.
function Hud.ListTracking()
    local out = {}
    if not (C_Minimap and C_Minimap.GetNumTrackingTypes) then return out end
    local n = C_Minimap.GetNumTrackingTypes() or 0
    for i = 1, n do
        local name, activeState, spellID = getTracking(i)
        out[#out + 1] = {
            index  = i,
            name   = name or ("Tracking " .. i),
            key    = spellID or name,
            cat    = trackCategory(name, spellID),
            -- What the client says RIGHT NOW, and whether it said anything at all.
            -- `readable` false means getTracking came back empty for this entry --
            -- see the note in applyTracking for why that is the interesting case.
            active   = activeState and true or false,
            readable = (name ~= nil or spellID ~= nil),
        }
    end
    return out
end

function restoreTracking()
    if not (savedTracking and C_Minimap and C_Minimap.SetTracking) then
        savedTracking = nil
        return
    end
    for i, was in pairs(savedTracking) do
        local _, activeState = getTracking(i)
        if (activeState and true or false) ~= was then
            C_Minimap.SetTracking(i, was)
        end
    end
    savedTracking = nil
end

function restoreRing()
    local c = compassTexture()
    if not c then return end
    if c.SetVertexColor then c:SetVertexColor(1, 1, 1) end
    c:SetAlpha(1)
    c:Show()
end

-- ---------------------------------------------------------------------------
-- Standing our ground.
--
-- Blizzard re-shows its own furniture in response to its own events -- the compass
-- when rotation flips, the mask when the minimap re-zooms. We're a guest in this
-- frame, so rather than fight for ownership we just quietly put things back the way
-- we like them whenever the client stirs.
-- ---------------------------------------------------------------------------
local watcher = CreateFrame("Frame")
watcher:RegisterEvent("CVAR_UPDATE")
watcher:RegisterEvent("MINIMAP_UPDATE_ZOOM")
watcher:SetScript("OnEvent", function()
    if not active then return end
    -- Next frame: let Blizzard finish whatever it was doing first.
    C_Timer.After(0, function()
        if active then Hud.ApplyLook() end
    end)
end)

-- The button patrol. LibDBIcon re-anchors to Minimap whenever it feels like it,
-- and addons register their buttons whenever they finish loading, so this cannot
-- be a one-shot. Twice a second, over a handful of buttons -- it costs nothing and
-- it's the difference between the corner working and your icons orbiting your head.
local sincePatrol = 0
local lastHidCount = -1

function startPatrol()
    if patrol then patrol:Show() return end
    patrol = CreateFrame("Frame")
    patrol:SetScript("OnUpdate", function(_, elapsed)
        if not active then return end
        sincePatrol = sincePatrol + elapsed
        if sincePatrol < 0.5 then return end
        sincePatrol = 0
        -- pcall the lot: this runs 2x/sec forever, so a single bad API call must
        -- never turn into a thousand-line error storm (it did once already).
        pcall(Hud.ParkButtons)
        pcall(setBlobAlpha, 0)        -- quest blobs redraw as objectives change
        pcall(applyTracking)          -- keep tracking pinned to gathering-only
        local n = 0
        if NS.db.hudSweep ~= false then
            local ok, c = pcall(hideLuaTextures, Minimap, 0)  -- POIs appear as you move
            n = ok and c or 0
        end
        -- Only speak when the count CHANGES, so debug mode stays quiet at rest and
        -- you actually notice the moment a POI shows up and gets hidden.
        if NS.db.debug and n ~= lastHidCount then
            lastHidCount = n
            if n > 0 then NS.Printf("hud: hiding %d minimap texture(s)", n) end
        end
    end)
end

-- The player arrow at dead centre: we can't touch it, and it's worth writing down
-- why so nobody spends another evening trying.
--
-- It is engine-drawn -- the Minimap has zero Lua regions, and a recursive hunt
-- through its children found nothing arrow-shaped. The only ever handle was
-- Minimap:SetPlayerTexture, and 12.0 REMOVED it (the method is nil on this client).
-- So there is no API, of any kind, that can hide or restyle it. Same wall as the
-- gathering blips and the town POIs.
--
-- It's small, it sits on your character, and with rotation on it simply says "you
-- are here, facing up" -- which is harmless. So we leave it, and we don't ship a
-- setting that pretends to remove it.

-- ---------------------------------------------------------------------------
-- WHERE IT SITS, AND HOW BIG THE BLIPS ARE. One function, because they're the
-- same sum.
--
-- BLIP SIZE IS FRAME SCALE. The blips are drawn by the engine inside the Minimap,
-- at a size the engine picks -- resizing the frame with SetSize doesn't touch
-- them, which is why a 400px HUD has the same little dots a 140px minimap does,
-- spread five times further apart. SCALE is different: it's a transform on
-- everything the frame draws, artwork included. So scale up and shrink by the
-- same factor, and the circle stays the size you asked for, a blip on the rim is
-- still a hundred yards away, and the only thing that changed is how big the dots
-- are. That's the whole trick, and it's the one piece of blip styling the client
-- still allows.
--
-- The catch is that SetPoint offsets are measured in the anchored frame's own
-- scale, so a HUD at scale 2 would sit twice as far from centre as you asked.
-- hudX/hudY are screen pixels and stay screen pixels; the division is here.
function placeMinimap()
    local db = NS.db
    if not (db and Minimap) then return end

    local size  = db.hudSize or 400
    local scale = tonumber(db.hudBlipScale) or 1
    if scale < 0.5 then scale = 0.5 elseif scale > 3 then scale = 3 end

    Minimap:SetScale(scale)
    Minimap:SetSize(size / scale, size / scale)
    Minimap:ClearAllPoints()
    Minimap:SetPoint("CENTER", UIParent, "CENTER",
        (db.hudX or 0) / scale, (db.hudY or 0) / scale)
end

-- ---------------------------------------------------------------------------
-- TAKING IT OFF ITS PEG.
--
-- Centre is the right default and the wrong place for plenty of people: it's also
-- where your character stands, where the boss frames go, and where every other
-- addon puts its warnings. So the HUD unpins and drags.
--
-- WE DO NOT DRAG THE MINIMAP. StartMoving on a Blizzard frame is a state change on
-- somebody else's widget -- it rewrites their anchors to whatever the cursor did,
-- and we'd never get the original point back cleanly. Instead this is a frame of
-- OURS, the size and shape of the HUD, which drags normally; we read where it
-- ended up and re-place the minimap ourselves through the same placeMinimap() the
-- options sliders use. The minimap is only ever positioned by us, in one place.
--
-- It's mouse-enabled, so it only exists while you're moving it -- an invisible
-- 400px circle that eats mouselook in the middle of the screen is the single
-- worst thing this addon could ship. Right-click, /eu hud lock, or the fight
-- starting all put it away.
-- ---------------------------------------------------------------------------
local mover
local SNAP = 8      -- px from an axis where we call it centred (Alt to override)

function layoutMover()
    if not (mover and mover:IsShown()) then return end
    local db = NS.db
    local size = db.hudSize or 400
    mover:SetSize(size, size)
    if not mover.dragging then
        mover:ClearAllPoints()
        mover:SetPoint("CENTER", UIParent, "CENTER", db.hudX or 0, db.hudY or 0)
    end
    mover.readout:SetFormattedText("%d, %d", db.hudX or 0, db.hudY or 0)
end

function hideMover()
    if mover then mover:Hide() end
end

-- Where the mover ended up, in the same screen-pixel offsets hudX/hudY speak.
local function commitMover()
    local db = NS.db
    if not (db and mover) then return end

    local cx, cy = UIParent:GetCenter()
    local mx, my = mover:GetCenter()
    if not (cx and mx) then return end

    local x = math.floor(mx - cx + 0.5)
    local y = math.floor(my - cy + 0.5)

    -- Snap to the middle. Getting a HUD exactly centred on one axis by hand is
    -- fiddly and it's the position most people want, so within a few pixels we
    -- call it centred -- and say so in the readout, so it never looks like drift.
    if not IsAltKeyDown() then
        if math.abs(x) <= SNAP then x = 0 end
        if math.abs(y) <= SNAP then y = 0 end
    end

    db.hudX, db.hudY = x, y
    if active then
        placeMinimap()
    end
    layoutMover()
end

local function ensureMover()
    if mover then return mover end

    mover = CreateFrame("Frame", "EyesUpHudMover", UIParent)
    mover:SetFrameStrata("DIALOG")
    mover:SetClampedToScreen(true)
    mover:SetMovable(true)
    mover:EnableMouse(true)
    mover:RegisterForDrag("LeftButton")
    mover:Hide()

    -- The footprint, drawn as the disc the HUD actually is rather than the square
    -- the frame actually is -- so what you're dragging is what you'll get.
    local disc = mover:CreateTexture(nil, "BACKGROUND")
    disc:SetAllPoints(mover)
    disc:SetColorTexture(0.1, 0.6, 0.3, 0.18)
    disc:SetMask(NS.CustomGlyphDir .. "MASK_ROUND")

    -- Crosshair, so you can line the centre up on something.
    local vline = mover:CreateTexture(nil, "ARTWORK")
    vline:SetColorTexture(0.4, 1, 0.6, 0.5)
    vline:SetPoint("TOP", mover, "TOP", 0, 0)
    vline:SetPoint("BOTTOM", mover, "BOTTOM", 0, 0)
    vline:SetWidth(1)
    local hline = mover:CreateTexture(nil, "ARTWORK")
    hline:SetColorTexture(0.4, 1, 0.6, 0.5)
    hline:SetPoint("LEFT", mover, "LEFT", 0, 0)
    hline:SetPoint("RIGHT", mover, "RIGHT", 0, 0)
    hline:SetHeight(1)

    local title = mover:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("CENTER", mover, "CENTER", 0, 24)
    title:SetText("Eyes Up HUD |cffffcc00unlocked|r")

    local hint = mover:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hint:SetPoint("CENTER", mover, "CENTER", 0, 4)
    hint:SetText("drag me  |cff888888--|r  right-click to lock")

    mover.readout = mover:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    mover.readout:SetPoint("CENTER", mover, "CENTER", 0, -14)

    mover:SetScript("OnDragStart", function(self)
        self.dragging = true
        self:StartMoving()
    end)
    mover:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        self.dragging = false
        commitMover()
    end)
    -- Live, not on release. Dragging a green circle around and having the blips
    -- catch up afterwards tells you nothing about whether it's in the right place.
    mover:SetScript("OnUpdate", function(self)
        if self.dragging then commitMover() end
    end)
    mover:SetScript("OnMouseUp", function(self, button)
        if button == "RightButton" then Hud.SetLocked(true) end
    end)

    -- A fight starting pins it. Everything else in this file stands down in combat
    -- (see notNow), so an unlocked HUD would be a mouse trap you couldn't move.
    mover:RegisterEvent("PLAYER_REGEN_DISABLED")
    mover:SetScript("OnEvent", function()
        if NS.db and not NS.db.hudLocked then Hud.SetLocked(true) end
    end)

    return mover
end

function Hud.IsLocked()
    return not NS.db or NS.db.hudLocked ~= false
end

function Hud.SetLocked(on)
    local db = NS.db
    if not db then return end
    db.hudLocked = on and true or false

    if db.hudLocked then
        hideMover()
        return true
    end

    -- Unlocking is only meaningful with something to aim at -- and this only ever
    -- moves the HUD. With the HUD down, the Minimap is back in its corner where its
    -- owner (Blizzard, or whatever suite runs it) put it, and none of this touches
    -- that: hudX/hudY are applied by placeMinimap, which only ever runs while the
    -- HUD is up. So there is nothing here to unlock, and we say so rather than
    -- silently arming a handle over somebody's corner minimap.
    if not active then
        db.hudLocked = true
        NS.Print("the HUD isn't up -- |cffffff00/eu on|r first, then unlock it.")
        NS.Print("  |cff888888(This only ever moves the HUD. Your corner minimap is left alone.)|r")
        return false
    end
    if InCombatLockdown and InCombatLockdown() then
        db.hudLocked = true
        NS.Print("not in combat -- the HUD can't be moved mid-fight.")
        return false
    end

    ensureMover()
    mover:Show()
    layoutMover()
    return true
end

function Hud.ToggleLocked()
    return Hud.SetLocked(not Hud.IsLocked())
end

-- Exact placement, for anyone who'd rather type it than drag it -- and the way
-- back to the middle when a drag has gone somewhere silly.
function Hud.SetPosition(x, y)
    local db = NS.db
    if not db then return end
    db.hudX = math.floor(tonumber(x) or 0)
    db.hudY = math.floor(tonumber(y) or 0)
    if active then
        placeMinimap()
    end
    layoutMover()
end

function Hud.ResetPosition()
    Hud.SetPosition(0, 0)
end

function Hud.ApplyLook()
    if not active then return end
    -- Sizing and re-masking the Minimap is frame surgery, and applyRotation writes
    -- a CVar. Both wait for the fight to end -- including when the CVAR_UPDATE
    -- watcher fires mid-combat, which is the path nobody would think to test.
    if notNow() then return end
    local db = NS.db
    if not db then return end

    -- CORE -- must always run, whatever the extras below do.
    --
    -- The mask is what deletes the terrain; it's the entire point of the HUD. If an
    -- optional step (tracking, ring) throws and skips it, you're left staring at a
    -- giant map with orbiting buttons -- which is exactly what happened when the new
    -- tracking code raised an error mid-ApplyLook. So the core is unconditional and
    -- goes FIRST, and every nice-to-have after it is wrapped so a failure can never
    -- reach back and undo the mask.
    placeMinimap()
    Minimap:SetAlpha(db.hudAlpha or 1)

    -- THE MASK IS A GATE, NOT A FADE. See the top of this file.
    --
    -- "round" is the only one of these that belongs in normal use: an opaque disc,
    -- so every blip inside it draws. The terrain is dealt with by SetAlpha below,
    -- not here. The transparent ones are kept because they're how you diagnose the
    -- next time this changes -- and they are exactly what a broken HUD looks like,
    -- so don't hand them to anyone from the options page.
    if Minimap.SetMaskTexture then
        local m = db.hudMask or "round"
        local mask
        if m == "vignette" then
            mask = NS.CustomGlyphDir .. "MASK_VIGNETTE"
        elseif m == "dim" then
            mask = NS.CustomGlyphDir .. "MASK_DIM"
        elseif m == "ghost" then
            -- Alpha 1 out of 255, flat. Terrain you cannot see, over a mask that is
            -- nonetheless NOT zero -- which is the whole question 12.1 raised: is a
            -- blip GATED on the mask's alpha, or MULTIPLIED by it? If gated, this is
            -- the fix and it costs nothing. If multiplied, the blips come through at
            -- 1/255 and this looks identical to "clear".
            mask = NS.CustomGlyphDir .. "MASK_GHOST"
        elseif m == "round" then
            mask = ROUND_MASK
        else
            mask = NS.CustomGlyphDir .. "MASK_CLEAR"
        end
        pcall(Minimap.SetMaskTexture, Minimap, mask)
    end

    local zoom = db.hudZoom or 0
    local maxZoom = Minimap.GetZoomLevels and Minimap:GetZoomLevels() or 5
    if zoom > maxZoom then zoom = maxZoom elseif zoom < 0 then zoom = 0 end
    Minimap:SetZoom(zoom)

    -- Mouse on = blip tooltips work (but the HUD then eats clicks over its circle).
    Minimap:EnableMouse(db.hudTooltips and true or false)

    -- EXTRAS -- each on its own, so one failing can't take down the rest or the
    -- core. (The player arrow isn't here at all: it's engine-drawn and 12.0 removed
    -- SetPlayerTexture, so there is simply no way to touch it. See below.)
    pcall(applyRotation)
    pcall(applyRing)
    pcall(applyTracking)
    pcall(layoutMover)
end

-- ---------------------------------------------------------------------------
-- THE SWEEP, AND THE SWITCH THAT PROVES IT INNOCENT.
--
-- hideLuaTextures hides every Lua Texture under the Minimap, bluntly, on one
-- premise: the gathering blips are drawn by the ENGINE, so they are not Lua
-- Texture regions and cannot possibly be caught in the sweep. That premise is
-- true right up until a patch moves the blips into a Lua pin pool, at which point
-- the sweep quietly deletes the entire point of the addon twice a second and
-- looks exactly like "the mask broke."
--
-- So it gets an off switch. Turn the sweep off and the HUD gets its ring, its
-- border and its POI art back -- ugly, and diagnostic: if the blips come back
-- with them, the sweep was eating them and we need to learn what to skip.
--
-- Only offered on the keep-corner path. With the corner hidden, `hidden` also
-- holds frames we hid on purpose (the cluster, the map's children), and those are
-- not the sweep's to hand back.
-- ---------------------------------------------------------------------------
function Hud.SetSweep(on)
    if not NS.db then return end
    NS.db.hudSweep = on and true or false

    if not active then return end
    if on then
        pcall(hideLuaTextures, Minimap, 0)
        return
    end
    if NS.db.hudKeepCorner == false then return end

    for i = 1, #hidden do
        local o = hidden[i]
        if o then
            o.__euHid = nil
            if o.Show then o:Show() end
        end
    end
    wipe(hidden)
end

-- How far the HUD can actually see, in yards. Real number, straight from the
-- client -- worth printing, because it's the number that makes the case: the
-- database was guessing at sixty yards and the soft-target could only truly reach
-- fifteen. This just knows.
function Hud.RangeYards()
    if C_Minimap and C_Minimap.GetViewRadius then
        return C_Minimap.GetViewRadius()
    end
end

-- ---------------------------------------------------------------------------
-- Wanting it on, and it BEING on, are two different things.
--
-- The town POIs -- mailbox, inn, quest givers, vendors -- are engine-drawn, the
-- same untouchable layer as the gathering blips. We can't show the herbs without
-- showing all of it, and in a city "all of it" is a wall of clutter over your
-- character. But a city is exactly where you AREN'T gathering, so the answer isn't
-- to filter the clutter (we can't) -- it's to stand the HUD down while you're in
-- town and bring it back the moment you ride out.
--
-- IsResting() is true in inns and cities, which is precisely the line we want. So:
--
--     hudEnabled  -- what you asked for. A saved preference.
--     active      -- whether it's actually up right now. Suppressed while resting.
--
-- Everything user-facing sets the preference and then calls Refresh, which works
-- out whether the HUD should currently be showing and makes it so.
-- ---------------------------------------------------------------------------
function Hud.ShouldShow()
    local db = NS.db
    if not (db and db.hudEnabled) then return false end

    -- Cities and inns.
    if db.hudHideInCity and IsResting and IsResting() then return false end

    -- Battlegrounds and arenas: always, no toggle. There's nothing to gather in one,
    -- and in a PvP instance you want your real minimap back where your muscle memory
    -- expects it -- covering the actual map with a herb radar is the opposite of
    -- helpful when someone's stunning you. "pvp" is a battleground, "arena" is an
    -- arena; both come from the SECOND return of IsInInstance(), guarded by the first.
    if IsInInstance then
        local inInstance, itype = IsInInstance()
        if inInstance and (itype == "pvp" or itype == "arena") then return false end
    end

    -- Dungeons and raids ONLY. The FIRST return of IsInInstance() is the thing that
    -- matters: are you physically zoned INTO an instance? The "party"/"raid" string
    -- is the instance's content type (5-player vs raid), NOT your group -- being in
    -- a party or raid out in the open world returns (false, "none"), so this never
    -- fires from just grouping up. Delves and ritual sites are "scenario" and stay
    -- (prime gathering). Soft-target goes quiet inside any instance because 12.0
    -- makes it a secret value, but Live.lua handles that without erroring.
    if db.hudHideInDungeons and IsInInstance then
        local inInstance, itype = IsInInstance()
        if inInstance and (itype == "party" or itype == "raid") then return false end
    end

    return true
end

function Hud.Refresh()
    if Hud.ShouldShow() then
        if not active then Hud.Enable() end
    else
        if active then Hud.Disable() end
    end
end

-- The user-facing on/off: set the wish, then honor it.
function Hud.SetEnabled(on)
    local was = NS.db and NS.db.hudEnabled
    if NS.db then NS.db.hudEnabled = on and true or false end
    Hud.Refresh()

    -- The wish is recorded either way, but if we're in combat nothing visible
    -- happened -- and a keybind that silently does nothing reads as broken. Say so.
    if InCombatLockdown and InCombatLockdown() then
        NS.Print(on and "eyes up when this fight ends." or "minimap comes back when this fight ends.")
        return active
    end

    -- Turning it OFF is the moment somebody wants their own minimap back -- and what
    -- we can give them is Blizzard's round one, not their suite's. Say so HERE and
    -- not in Disable(), which also runs on every city and dungeon stand-down and
    -- would turn a useful note into a nag. Once a session is plenty.
    if was and not on and not reloadNudged then
        local owner = Hud.MinimapOwner()
        if owner then
            reloadNudged = true
            NS.Printf("|cffffcc00Your minimap is back.|r %s had styled it, and we can't repaint",
                owner)
            NS.Print("  that from here -- |cffffff00/reload|r restores its own look.")
        end
    end

    return active
end

function Hud.Toggle()
    return Hud.SetEnabled(not (NS.db and NS.db.hudEnabled))
end

-- Resting flips at city/inn boundaries; PLAYER_ENTERING_WORLD fires on every
-- instance transition. Both are cues to re-decide whether the HUD should show.
local restWatch = CreateFrame("Frame")
restWatch:RegisterEvent("PLAYER_UPDATE_RESTING")
restWatch:RegisterEvent("ZONE_CHANGED")
restWatch:RegisterEvent("ZONE_CHANGED_NEW_AREA")
restWatch:RegisterEvent("PLAYER_ENTERING_WORLD")
restWatch:SetScript("OnEvent", function()
    -- next frame: IsResting()/IsInInstance() can lag the event by a tick
    C_Timer.After(0, Hud.Refresh)
end)

-- ---------------------------------------------------------------------------
-- OUT OF THE WAY WHILE YOU'RE FIGHTING.
--
-- A hundred-yard circle of herb markers across the middle of the screen is exactly
-- what you don't want on a pull. "Step aside in cities" and "in dungeons" already
-- cover the places you're reliably not gathering; this covers the moment.
--
-- IT IS NOT Disable(). Everything in Disable is frame surgery -- reparenting,
-- resizing, re-masking -- and every bit of it stands down in combat (see notNow),
-- so a hide that went through Disable would land when the fight ENDED. Which is
-- the exact opposite of the feature.
--
-- SO IT IS Hide(), AND SETALPHA IS NOT AN OPTION. Fading the HUD out is the obvious
-- move and it does nothing: the blips ignore frame alpha. That's measured, and the
-- whole addon leans on it -- hudAlpha sits at 0.01 precisely so the map vanishes and
-- the blips don't. Turn that dial to zero in a fight and you'd have every blip at
-- full strength over the boss. Hide() is the only lever that takes them with it.
--
-- And Hide() is safe where Disable isn't, because visibility is not structure:
-- nothing is reparented, resized or re-masked, so there's no protected call to be
-- refused and nothing to defer. It reacts on the event, which is the point.
--
-- The corner map is deliberately left alone. That's a real map in the corner, and a
-- fight is when you'd actually want one.
-- ---------------------------------------------------------------------------
local combatHidden = false

function Hud.SetCombatHidden(on)
    if not Minimap then return end

    if on then
        if combatHidden or not active then return end
        combatHidden = true
        Minimap:Hide()
    else
        if not combatHidden then return end
        combatHidden = false
        -- Only put it back if the HUD still wants to be up. A zone change or a
        -- keybind during the fight may have decided otherwise, and Refresh below
        -- is what settles that -- this just undoes our own hide.
        if active then
            Minimap:Show()
        end
    end
end

function Hud.IsCombatHidden()
    return combatHidden
end

-- Settling up. Every path that gave up in combat -- a zone change, the keybind, a
-- checkbox, the CVar watcher -- collapses to the same two questions: should the HUD
-- be up, and does it look right. Ask both, once, and everything that was owed lands
-- together.
local combatWatch = CreateFrame("Frame")
combatWatch:RegisterEvent("PLAYER_REGEN_ENABLED")
combatWatch:RegisterEvent("PLAYER_REGEN_DISABLED")
combatWatch:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_REGEN_DISABLED" then
        if NS.db and NS.db.hudHideInCombat then Hud.SetCombatHidden(true) end
        return
    end

    -- Out of combat. Un-hide FIRST, then settle everything that was deferred --
    -- Refresh may well decide to take the HUD down, and it should be looking at a
    -- HUD that's actually up when it does.
    Hud.SetCombatHidden(false)

    if not combatPending then return end
    combatPending = false
    Hud.Refresh()
    if active then Hud.ApplyLook() end
end)

-- ---------------------------------------------------------------------------
-- CAN WE RESTYLE THE BLIPS? Settled, and worth writing down so nobody spends
-- another evening on it.
--
-- NO, not the artwork and not the colour. There are two blip atlases:
-- Interface\Minimap\ObjectIcons.blp, which you can overwrite and which the game
-- ignores, and ObjectIconsAtlas.blp, which is the one it draws from and which you
-- cannot. The only door was Minimap:SetBlipTexture, and 12.0.7 REMOVED IT -- which
-- is why "Keyboard's Minimap Icons" and every other blip-skin addon retired that
-- patch rather than fixing anything.
--
-- Nor is there a Lua object to reach for instead. The blips are engine-drawn: they
-- are not Texture regions under the Minimap (hideLuaTextures walks every one of
-- those and the blips survive it, which is the whole reason that sweep is safe),
-- and they don't take the frame's alpha either -- hudAlpha deletes the terrain and
-- leaves them at full strength on 12.0.7 and 12.1 both. Something that ignores the
-- frame's alpha is not going to take a vertex colour from it.
--
-- WHAT IS LEFT IS SIZE, and only size. Frame scale is a transform on everything the
-- frame draws, engine artwork included, so scaling up and shrinking by the same
-- factor gives bigger dots at the same circle and the same hundred yards. Confirmed
-- in-client. See placeMinimap.
--
-- TWO OTHER THINGS WERE TRIED AND ARE GONE, which is worth writing down so they
-- don't get re-invented. A disc of our own UNDER the map, to read pale blips
-- against; and a MOD (multiply) overlay OVER it, which is the only thing in the
-- client that changes what colour a blip comes out. Both worked in the sense that
-- they drew. Neither earned its place: the disc trades away the view through the
-- circle, which is most of the point of a heads-up display, and the tint colours the
-- world showing through by exactly as much as the blips, because a multiply cannot
-- tell them apart. A setting whose honest description is "and it ruins the thing you
-- turned the addon on for" is a setting not to have.
--
-- Per-TYPE colour -- herbs green, ore orange -- was never on the list and can't be:
-- it needs to know which blip is which, and nothing in the client will say. The
-- nearest thing the addon has is the tracking list, which decides which types get
-- drawn at all.
--
-- CanSkinBlips is kept as a live probe rather than a constant `false`, so if a
-- patch ever puts SetBlipTexture back, /eu hud blips says so instead of us
-- re-deriving all of the above.
-- ---------------------------------------------------------------------------
function Hud.CanSkinBlips()
    return Minimap.SetBlipTexture ~= nil
end

-- Count the Lua Texture regions under the Minimap. The number is the evidence for
-- "the blips are engine-drawn": you can see a dozen blips on screen and this will
-- report the map's own furniture and nothing else.
local function countLuaTextures(frame, depth)
    if not frame or depth > 3 then return 0 end
    local n = 0
    if frame.GetRegions then
        for _, r in ipairs({ frame:GetRegions() }) do
            if r and r.GetObjectType and r:GetObjectType() == "Texture" then n = n + 1 end
        end
    end
    if frame.GetChildren then
        for _, c in ipairs({ frame:GetChildren() }) do
            n = n + countLuaTextures(c, depth + 1)
        end
    end
    return n
end

-- /eu hud blips -- what this client will and won't let us do to them, measured
-- rather than remembered.
function Hud.BlipReport()
    NS.Print("|cff66ff66blips:|r what this client allows.")

    local doors = {
        { "SetBlipTexture",          "swap the whole blip atlas" },
        { "SetIconTexture",          "swap the POI icons" },
        { "SetPlayerTexture",        "replace the player arrow" },
        { "SetStaticPOIArrowTexture", "replace the edge-of-map arrows" },
    }
    for _, d in ipairs(doors) do
        NS.Printf("  %-24s %s  |cff888888%s|r", d[1],
            Minimap[d[1]] and "|cff66ff66present|r" or "|cffff6666gone|r", d[2])
    end

    local textures = countLuaTextures(Minimap, 0)
    NS.Printf("  Lua textures under the map: |cffffcc00%d|r -- none of them a blip; "
        .. "that's why the sweep is safe.", textures)

    NS.Printf("  blip size: |cff66ff66%.2fx|r", tonumber(NS.db and NS.db.hudBlipScale) or 1)

    if not Hud.CanSkinBlips() then
        NS.Print("  |cffffcc00Recolouring or reskinning the blips themselves isn't possible|r --")
        NS.Print("  12.0.7 removed SetBlipTexture and they're engine-drawn, so there's no")
        NS.Print("  Lua object to tint. Size is the whole of what's left:")
        NS.Print("  |cffffff00/eu blips 1.6|r")
    else
        NS.Print("  |cff66ff66SetBlipTexture is back on this client|r -- a real blip skin is possible")
        NS.Print("  again. Worth revisiting the note above Hud.CanSkinBlips.")
    end
end

-- The one blip dial there is.
function Hud.SetBlipScale(v)
    local db = NS.db
    if not db then return end
    v = tonumber(v) or 1
    if v < 0.5 then v = 0.5 elseif v > 3 then v = 3 end
    db.hudBlipScale = v
    if active then placeMinimap() end
    return v
end

function Hud.Report()
    NS.Printf("hud: %s   size %d   rotate %s",
        active and "|cff66ff66on|r" or "off",
        NS.db.hudSize or 400,
        NS.db.hudRotate and "|cff66ff66on|r (up = the way you're facing)" or "off (up = north)")

    -- The two things that can hide a blip without erroring. Both on the status line
    -- so "no blips" starts with an answer rather than a guess.
    NS.Printf("mask: %s   texture sweep: %s",
        NS.db.hudMask or "clear",
        NS.db.hudSweep ~= false and "on" or "|cffffcc00off|r")

    local r = Hud.RangeYards()
    NS.Printf("range: |cff66ff66%s yards|r, every direction, live and exact",
        r and math.floor(r) or "?")

    if combatHidden then
        NS.Print("|cffffcc00stood aside for the fight|r -- back when it ends.")
    end

    NS.Printf("position: %d, %d (%s)   blip size: %.2fx",
        NS.db.hudX or 0, NS.db.hudY or 0,
        Hud.IsLocked() and "pinned" or "|cffffcc00unlocked|r",
        tonumber(NS.db.hudBlipScale) or 1)

    NS.Printf("blip skinning: %s -- |cffffff00/eu blips|r for the detail",
        Hud.CanSkinBlips()
        and "|cff66ff66available|r (SetBlipTexture survived)"
        or  "|cffff6666not possible|r (SetBlipTexture went in 12.0.7)")
end
