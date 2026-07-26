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
-- The Minimap is a frame. Frames can be moved, resized, and masked. And the mask
-- -- which shapes the map through its alpha channel -- does NOT apply to the
-- blips, because the blips aren't part of the Lua render at all. Point a fully
-- transparent mask at the minimap and the terrain vanishes while every tracking
-- icon stays exactly where it was.
--
-- What's left is node markers hanging in space over the actual world, in the
-- middle of your screen, telling the absolute truth. Which is what "Eyes Up"
-- meant all along.
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
local reanchoring = false     -- guards the button SetPoint hook against its own corrections
local reloadNudged = false    -- the "reload to get your skin back" note is a once-per-session thing

-- Blizzard's round mask. There is no GetMaskTexture, so the only way to put the
-- shape back is to know its name.
local ROUND_MASK = "Interface\\CHARACTERFRAME\\TempPortraitAlphaMask"

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
local MINIMAP_SUITES = {
    { "ElvUI",              "ElvUI" },
    { "EllesmereUIMinimap", "EllesmereUI" },
    { "Tukui",         "Tukui" },
    { "NDui",          "NDui" },
    { "SpartanUI",     "SpartanUI" },
    { "LUI",           "LUI" },
    { "SexyMap",       "SexyMap" },
    { "Chinchilla",    "Chinchilla" },
    { "SimpleMinimap", "SimpleMinimap" },
    { "BasicMinimap",  "BasicMinimap" },
    { "SquareMinimap", "SquareMinimap" },
    { "Carbonite",     "Carbonite" },
}

-- Who else thinks the minimap is theirs? A display name, or nil for "nobody".
function Hud.MinimapOwner()
    local loaded = (C_AddOns and C_AddOns.IsAddOnLoaded) or _G.IsAddOnLoaded
    if loaded then
        for _, entry in ipairs(MINIMAP_SUITES) do
            local ok, is = pcall(loaded, entry[1])
            if ok and is then return entry[2] end
        end
    end

    -- The nameless check. Careful about WHEN this is asked: while the HUD is up the
    -- minimap is parented to UIParent by us, so this would happily report ourselves.
    -- Both callers ask while it's down.
    if not active and Minimap and MinimapCluster and Minimap.GetParent then
        local p = Minimap:GetParent()
        if p and p ~= MinimapCluster and p ~= _G.MinimapBackdrop then
            -- A named holder is worth repeating back ("ElvUI_MinimapHolder" tells the
            -- player exactly who). UIParent is not: it's where every suite that can't
            -- be bothered to build a holder drops it -- EllesmereUI among them -- and
            -- "UIParent is running your minimap" tells nobody anything.
            local n = p.GetName and p:GetName()
            if n and n ~= "UIParent" then return n end
            return "another addon"
        end
    end
end

-- ---------------------------------------------------------------------------
-- The one-time question, answered on the player's behalf.
--
-- Runs once per character. The stamp is deliberately NOT a key in NS.defaults --
-- see the identityVersion note in Core.lua for why that matters: a default would
-- hand every existing install the "already asked" mark, and this would never fire
-- for the very people it exists for.
--
-- Stamped before any of the early-outs, so this asks once and then never again --
-- whichever way it goes. Someone who wants the HUD on top of their suite turns it
-- on and is left alone forever after.
-- ---------------------------------------------------------------------------
function Hud.CheckMinimapCompat()
    local db = NS.db
    if not db or db.hudCompatChecked then return end
    db.hudCompatChecked = true

    if not (db.hudRespectOtherAddons and db.hudEnabled) then return end

    local owner = Hud.MinimapOwner()
    if not owner then return end

    db.hudEnabled = false
    NS.Printf("|cffffcc00%s is running your minimap, so Eyes Up left it where it is.|r", owner)
    NS.Print("  The HUD works by MOVING your minimap to the middle of the screen -- there's")
    NS.Print("  only one of them, so it can't be in both places at once.")
    NS.Print("  |cffffff00/eu hud on|r to use it anyway. Everything else is already running.")
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
-- The offsets can't be reused as-is -- LibDBIcon computed them for a 400px map, so
-- they'd fling the buttons half a screen away from a 140px tray. What we keep is
-- the ANGLE (which is what the player actually chose when they dragged it) and we
-- recompute the radius for the tray. They land back around the corner exactly where
-- they were.
-- ---------------------------------------------------------------------------
local atan2, cos, sin, rad = math.atan2, math.cos, math.sin, math.rad

-- Blizzard's own minimap buttons ride along too, and they're NOT direct children
-- of Minimap -- the expansion "gem" is under MinimapBackdrop, the queue eye and the
-- garrison button float around the cluster. Name them so the patrol can find them
-- wherever they're parented.
local BLIZZ_BUTTONS = {
    "ExpansionLandingPageMinimapButton",   -- the purple expansion gem
    "GarrisonLandingPageMinimapButton",
    "QueueStatusButton",
    "MiniMapMailFrame",                    -- the "you have mail" flag
}

-- Put a button where it belongs on the tray, from the angle it was sitting at.
local function reanchor(btn)
    local m = moved[btn]
    if not (m and tray) then return end
    local r = (tray:GetWidth() / 2) + 10
    reanchoring = true                     -- so our own SetPoint doesn't re-trigger the hook
    btn:ClearAllPoints()
    btn:SetPoint("CENTER", tray, "CENTER", cos(m.angle) * r, sin(m.angle) * r)
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

    if not moved[btn] then
        local _, _, _, x, y = btn:GetPoint(1)
        moved[btn] = {
            parent = btn:GetParent(),
            angle  = (x and y and (x ~= 0 or y ~= 0)) and atan2(y, x) or rad(225),
        }
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
        hideLuaTextures(Minimap, 0)
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

    -- Hand the buttons back to the Minimap at the angle they were sitting at.
    -- LibDBIcon will re-place them properly the next time it touches them, and the
    -- minimap is back at its own size by now, so this is already right.
    for btn, m in pairs(moved) do
        if btn and btn.SetParent then
            btn:SetParent(m.parent or Minimap)
            btn:ClearAllPoints()
            local r = (Minimap:GetWidth() / 2) + 10
            btn:SetPoint("CENTER", Minimap, "CENTER", cos(m.angle) * r, sin(m.angle) * r)
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
    Minimap:ClearAllPoints()
    Minimap:SetPoint("CENTER", UIParent, "CENTER", db.hudX or 0, db.hudY or 0)
    Minimap:SetSize(db.hudSize or 400, db.hudSize or 400)
    Minimap:SetFrameStrata("BACKGROUND")     -- behind everything; it's scenery, not UI
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

    -- FIRST, before we touch anything: the button SetPoint hook keys off `active`,
    -- and restoreArt is about to re-point every button back to the Minimap. Leave
    -- `active` true and the hook fights the restore, dragging them back to the tray.
    active = false

    if patrol then patrol:Hide() end
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
        local cat = trackCategory(name, spellID)
        local want = Hud.TrackWanted(spellID or name, cat)
        if want ~= (activeState and true or false) then
            C_Minimap.SetTracking(i, want)
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
        local name, _, spellID = getTracking(i)
        out[#out + 1] = {
            name = name or ("Tracking " .. i),
            key  = spellID or name,
            cat  = trackCategory(name, spellID),
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
        local ok, n = pcall(hideLuaTextures, Minimap, 0)  -- POIs appear as you move
        if not ok then n = 0 end
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

function Hud.ApplyLook()
    if not active then return end
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
    local size = db.hudSize or 400
    Minimap:SetSize(size, size)
    Minimap:ClearAllPoints()
    Minimap:SetPoint("CENTER", UIParent, "CENTER", db.hudX or 0, db.hudY or 0)
    Minimap:SetAlpha(db.hudAlpha or 1)

    if Minimap.SetMaskTexture then
        local mask = (db.hudMask == "vignette")
            and (NS.CustomGlyphDir .. "MASK_VIGNETTE")
            or  (NS.CustomGlyphDir .. "MASK_CLEAR")
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
-- Can we restyle the blips?
--
-- Almost certainly not, and it's worth knowing WHY rather than trying and
-- shrugging. There are two blip atlases: Interface\Minimap\ObjectIcons.blp, which
-- you can overwrite and which the game ignores, and ObjectIconsAtlas.blp, which is
-- the one it actually uses and which you cannot. The only door was
-- Minimap:SetBlipTexture -- and Midnight appears to have removed it (the addon
-- "Keyboard's Minimap Icons" was retired for exactly this reason).
--
-- So the blips are Blizzard's, at Blizzard's size, in Blizzard's colours. We can
-- move them, rotate them, scale the whole map, and mask the world out from behind
-- them. We cannot repaint them. Say so plainly rather than shipping a setting that
-- silently does nothing.
-- ---------------------------------------------------------------------------
function Hud.CanSkinBlips()
    return Minimap.SetBlipTexture ~= nil
end

function Hud.Report()
    NS.Printf("hud: %s   size %d   rotate %s",
        active and "|cff66ff66on|r" or "off",
        NS.db.hudSize or 400,
        NS.db.hudRotate and "|cff66ff66on|r (up = the way you're facing)" or "off (up = north)")

    local r = Hud.RangeYards()
    NS.Printf("range: |cff66ff66%s yards|r, every direction, live and exact",
        r and math.floor(r) or "?")

    NS.Printf("blip skinning: %s", Hud.CanSkinBlips()
        and "|cff66ff66available|r (SetBlipTexture survived)"
        or  "|cffff6666not possible|r -- Blizzard removed SetBlipTexture in 12.0")
end
