-- Eyes Up - Copyright (c) 2026 KTM (abitofmoss). All Rights Reserved.
-- No redistribution or reuse of this code or assets without permission. See LICENSE.
local addonName, NS = ...

-- =============================================================================
-- Corner.lua
-- Giving back what the HUD took.
--
-- Hud.lua moves your minimap to the middle of the screen and masks the terrain
-- away, leaving the tracking blips. That's the good half. The half it TOOK is
-- everything you'd ever actually glance at a corner map for: where you are, which
-- way the road goes, where the quest is, where your party is, what you haven't
-- explored.
--
-- There is only one Minimap object, so we can't have both. But we don't need the
-- minimap for that -- we need A map, and Blizzard already ships a small one.
--
-- THE BATTLEFIELD MAP
--
-- BattlefieldMapFrame is a MapCanvas: the same machinery WorldMapFrame is built
-- from, in a small movable window, with the data providers already wired up --
-- terrain, fog of war, quest pins, area POIs, party members, vignettes. It works
-- in any zone, not just battlegrounds. And it's maintained by the people who would
-- otherwise break it.
--
-- So we don't build a map. We borrow that one, park it in the hole where the
-- minimap used to be, and lock it onto the player.
--
-- Hand-rolling a MapCanvas is entirely possible -- every mixin and provider is
-- there, and UnitPositionFrame and FogOfWarFrame both instantiate -- but it's a few
-- hundred lines of scaffolding (MapCanvasMixin:OnLoad wants a ScrollContainer that
-- only exists in XML) and every line of it is a hostage to the next patch. This is
-- thirty, and it doesn't rot.
--
-- WHAT IT CANNOT DO, AND WHY THAT'S FINE
--
-- A MapCanvas cannot draw gathering blips. Those are minimap-only, engine-drawn,
-- and unreachable -- that limitation is the reason this entire addon exists. So the
-- two halves don't overlap, they complement:
--
--     the HUD    -- Blizzard's tracking blips, at your eye.   WHAT'S GATHERABLE.
--     the corner -- a real map, where the minimap was.        WHERE YOU ARE.
-- =============================================================================

local Corner = {}
NS.Corner = Corner

local frame                     -- BattlefieldMapFrame, once we've woken it up
local active = false
local saved = nil
local lastMapID = nil
local follower
local marker                    -- "you are here" -- see below, we draw it ourselves
local MARKER_SIZE = 16
local providersKilled = false   -- have we neutralised its (tainting) data providers
local origAddDataProvider       -- saved so nothing can re-add a pin behind our back

-- The corner map's frame (see the art section, far below) reaches back up here for
-- its declarations, because a name in Lua is resolved where it is WRITTEN, not
-- where it runs: ApplyShape and shapeSweep both sit above that section, so without
-- these lines their references would compile to nil globals and only misbehave once
-- somebody squared the corner off. Assigned without `local` at their real
-- definitions. This bit us twice in one sitting -- it is not a hypothetical.
local borderTex, borderHolder
local ensureBorder

-- ---------------------------------------------------------------------------
-- "ABOVE THE MAP" MEANS ABOVE ITS TILES, NOT ABOVE ITS FRAME.
--
-- A MapCanvas is a tree: the frame holds a ScrollContainer, which holds a Child,
-- which is what the terrain is actually drawn on. Every layer sits above the one
-- before it -- so a frame at map level + 2 is above the CANVAS and comfortably
-- underneath everything the canvas draws.
--
-- Which looks exactly like the art failing to load, and isn't. The tell is that the
-- four compass points still show: they stick out past the rim, where there's no map
-- left to cover them. Everything inside the circle is behind the terrain.
--
-- So: find the deepest level anything under the map is using, and go above THAT.
-- Cheap -- the tree is four or five frames -- and it can't be out-argued by a
-- client that adds another layer.
--
-- STRATA FIRST, and it's the half that's easy to miss: frame level only orders
-- frames WITHIN a strata. The tray is LOW and the map keeps whatever strata
-- Blizzard gave its window, so ours has to join the map's strata before its level
-- means anything at all. (That also lifts it over the addon buttons on the tray --
-- they orbit at the rim, where this art is a thin ring and mostly transparent, so
-- there's nothing to cover.)
-- ---------------------------------------------------------------------------
local function deepestLevel(obj, depth)
    if not obj or depth > 5 or not obj.GetFrameLevel then return 0 end
    local lvl = obj:GetFrameLevel() or 0
    if obj.GetChildren then
        for _, c in ipairs({ obj:GetChildren() }) do
            local l = deepestLevel(c, depth + 1)
            if l > lvl then lvl = l end
        end
    end
    return lvl
end

local function raiseAboveMap(f, bump)
    if not (f and frame) then return end
    f:SetFrameStrata(frame:GetFrameStrata())
    f:SetFrameLevel(deepestLevel(frame, 0) + (bump or 2))
end

-- ---------------------------------------------------------------------------
-- HOW BIG THE MAP IS INSIDE THE TRAY.
--
-- It used to be exactly the tray, and that was right until something was drawn
-- around it. The border art has an inner edge, and where that edge lands depends on
-- how far the art is scaled: UI-HUD-Minimap-Frame at its native 1.09 puts its inner
-- edge exactly on the rim of a full-size map, which is the fit Blizzard drew. Push
-- the ring out to 1.15 and its inner edge moves out with it, leaving a moat.
--
-- So this is the other side of that dial. Two knobs rather than one derived from the
-- other, because "how much frame do I want" and "how much map do I want" are
-- genuinely different questions and the art doesn't settle them.
--
-- The MASK follows this, not the tray -- see ensureShapeMask. Miss that and the
-- circle is cut at the tray's radius while the map is drawn smaller, which doesn't
-- crop the map at all: you get a square map with a round hole's worth of nothing
-- around it.
-- ---------------------------------------------------------------------------
local function mapSize(tray)
    if not tray then return 0, 0 end
    local s = tonumber(NS.db and NS.db.cornerMapScale) or 1
    if s < 0.6 then s = 0.6 elseif s > 1 then s = 1 end
    return tray:GetWidth() * s, tray:GetHeight() * s
end

-- Borrowing and returning Blizzard's window is frame surgery, so it observes the
-- same rule Hud.lua does: nothing structural during a fight. See the long note
-- there. Deferred work is settled on PLAYER_REGEN_ENABLED at the foot of this file.
local combatPending = false

local function notNow()
    if InCombatLockdown and InCombatLockdown() then
        combatPending = true
        return true
    end
    return false
end

-- It's a LoadOnDemand Blizzard addon, so it doesn't exist until somebody asks.
local function acquire()
    if _G.BattlefieldMapFrame then return _G.BattlefieldMapFrame end
    local load = C_AddOns and C_AddOns.LoadAddOn or _G.LoadAddOn
    if load then pcall(load, "Blizzard_BattlefieldMap") end
    return _G.BattlefieldMapFrame
end

-- KILL THE PINS -- for good, not just once.
--
-- The Battlefield Map is a secure Blizzard frame. The moment we reparent and drive
-- it from addon code it's tainted -- and from then on EVERY pin it acquires calls a
-- protected function with our taint on the stack. Not one kind of pin: all of them,
-- because the first of the two calls is inside AcquirePin itself.
--
--   MapCanvasMixin:AcquirePin -> CheckMouseButtonPassthrough -> SetPassThroughButtons
--   SuperTrackablePinMixin:OnAcquired -> UpdateMousePropagation -> SetPropagateMouseClicks
--
-- Both get blocked, and you get ADDON_ACTION_BLOCKED every time a mailbox, a dungeon
-- entrance or a treasure vignette comes into view.
--
-- So: no pins. And removing the providers once wouldn't be enough on its own -- the
-- map re-registers on map/zone changes -- so we also replace AddDataProvider with a
-- no-op and nothing can attach again this session. RemoveDataProvider goes the same
-- way, or Blizzard's own code eventually calls RemoveAllData a second time on a
-- provider we already detached, and that one indexes an owning map that is now nil.
--
-- WHAT THIS REPLACES, AND WHY IT MATTERS: the previous version called
-- f:RemoveAllDataProviders(). MapCanvasMixin has no such method -- only
-- RemoveDataProvider, one at a time -- so the `if` guard was simply false, the
-- removal silently never ran, and all twenty-odd providers stayed live for the whole
-- session. Only the AddDataProvider no-op was doing anything, and it can't evict what
-- is already in the table. Hence the blocked calls this was written to prevent.
--
-- WHAT WE KEEP: the two providers that paint straight onto the canvas instead of
-- acquiring pins -- map exploration and fog of war. No AcquirePin, no protected call,
-- and they're the half of a corner map you actually read: where you've been and where
-- you haven't. Anything we can't positively identify is removed, because the safe
-- answer to "is this one a pin?" is yes.
--
-- Side effect: the real Battlefield Map stays bare until a /reload. Almost nobody
-- opens it directly, and a reload restores it fully.

-- The only handle we have on an anonymous data provider is where its methods came
-- from: CreateFromMixins copies them by reference, so a provider built out of
-- FogOfWarDataProviderMixin still holds that exact function, and nothing else does.
local function paintsInsteadOfPinning(dp)
    local refresh = dp.RefreshAllData
    if not refresh then return false end
    local exploration = _G.MapExplorationDataProviderMixin
    local fog = _G.FogOfWarDataProviderMixin
    return (exploration ~= nil and refresh == exploration.RefreshAllData)
        or (fog ~= nil and refresh == fog.RefreshAllData)
end

local function killProviders(f)
    if not f or providersKilled then return end

    -- List the doomed before removing any of them: RemoveDataProvider edits
    -- f.dataProviders, and that's the table we'd be walking.
    local remove = f.RemoveDataProvider
    if remove and f.dataProviders then
        local doomed = {}
        for dp in pairs(f.dataProviders) do
            if not paintsInsteadOfPinning(dp) then
                doomed[#doomed + 1] = dp
            end
        end
        for _, dp in ipairs(doomed) do
            -- Ask nicely first -- RemoveDataProvider releases the pins and unhooks
            -- the events. Then clear the entry ourselves regardless, because if that
            -- call errored halfway the provider is still in the dispatch table and
            -- still making pins, which is the exact thing we came here to stop.
            pcall(remove, f, dp)
            f.dataProviders[dp] = nil
        end
    end

    if not origAddDataProvider then
        origAddDataProvider = f.AddDataProvider
        f.AddDataProvider = function() end      -- pins may not enter
        f.RemoveDataProvider = function() end    -- and nobody may evict them twice
    end

    providersKilled = true
end

function Corner.IsAvailable()
    return acquire() ~= nil
end

function Corner.IsActive()
    return active
end

-- ---------------------------------------------------------------------------
-- Following you.
--
-- This is the whole thing: a map that pans to the player ONCE shows you where you
-- were standing when it opened, then sits there while you walk away.
--
-- A map that doesn't follow you is a screenshot.
--
-- Two jobs, and they're different: pan to the player's position every tick, and
-- re-point the canvas at a whole new map when you cross a zone boundary. Miss the
-- second and you get a beautifully centred view of the zone you just left.
-- ---------------------------------------------------------------------------
-- ---------------------------------------------------------------------------
-- You are here.
--
-- Stripping the data providers took Blizzard's player arrow with them: it comes from
-- the group-members provider, which acquires a pin like everything else, and a pin is
-- the one thing this canvas cannot have. That's a smaller loss than it sounds -- the
-- map is locked to you, so the middle of the frame IS you, every frame -- but a map
-- with nothing in the middle reads as a picture rather than a position. So we draw
-- the arrow back ourselves, which costs one texture.
--
-- Ours is honest about facing, which is the part worth having. The canvas is north-up
-- and never rotates, so the angle goes in exactly as the game reports it. Same art and
-- same convention as the cue: the art points north at rotation 0, GetPlayerFacing is
-- counter-clockwise from north, and SetRotation is counter-clockwise positive. No sign
-- flip here, unlike Cue.lua, because there's no clockwise bearing in the sum.
--
-- GetPlayerFacing goes nil while the world map is open. We hold the last angle instead
-- of snapping north, for the same reason Scan keeps `valid` and `facing` apart: not
-- knowing which way you're looking is not a reason to point somewhere wrong.
-- ---------------------------------------------------------------------------
local function ensureMarker(tray)
    if not marker then
        marker = CreateFrame("Frame", nil, tray)
        marker:SetSize(MARKER_SIZE, MARKER_SIZE)
        local tex = marker:CreateTexture(nil, "OVERLAY")
        tex:SetAllPoints(marker)
        tex:SetTexture(NS.ArrowTexture)
        marker.tex = tex
    end

    marker:SetParent(tray)
    marker:ClearAllPoints()
    marker:SetPoint("CENTER", tray, "CENTER", 0, 0)
    -- Above everything the map draws -- see raiseAboveMap. This was map level + 4,
    -- which is under the terrain, so the "you are here" arrow was quietly buried by
    -- the same bug the border had. The buttons orbit the rim and this is sixteen
    -- pixels dead centre, so nothing of yours gets covered.
    raiseAboveMap(marker, 4)
    -- FULL STRENGTH, whatever cornerAlpha says. It used to fade with the map, which
    -- is wrong the moment that dial does anything: the whole job of this corner is
    -- "where am I", and turning the map down to sit quietly behind your UI would
    -- take the answer down with it. The marker hangs off the TRAY, not the map, so
    -- it doesn't inherit the fade -- this is a choice, not an accident of parenting.
    marker:SetAlpha(1)
    marker:Show()
    return marker
end

local function follow()
    if not (active and frame) then return end

    -- Before the early-outs: which way you're looking doesn't depend on any of them.
    if marker then
        local facing = GetPlayerFacing and GetPlayerFacing()
        if facing then marker.tex:SetRotation(facing) end
    end

    local mapID = C_Map.GetBestMapForUnit("player")
    if not mapID then return end

    if mapID ~= lastMapID then
        pcall(frame.SetMapID, frame, mapID)
        lastMapID = mapID
    end

    local pos = C_Map.GetPlayerMapPosition(mapID, "player")
    if not pos then return end
    local x, y = pos:GetXY()
    if not (x and y) then return end

    local sc = frame.ScrollContainer
    if not sc then return end

    -- Zoom all the way in, then back off by the player's taste. A zone map at full
    -- extent isn't a minimap, it's a wall chart -- the whole point is to be close
    -- enough that the road under your feet is legible.
    local maxScale = (sc.GetScaleForMaxZoom and sc:GetScaleForMaxZoom())
                     or (sc.GetMaxZoomViewScale and sc:GetMaxZoomViewScale())
                     or sc.maxScale or 3
    local scale = maxScale * (NS.db.cornerZoom or 1.0)

    -- Drive BOTH the instant setters and the target setters. Different client
    -- versions honor different ones, and the canvas's own OnUpdate interpolates
    -- toward the *targets* -- so if we only snap once it can drift back. Setting the
    -- targets every tick is what actually pins it to you.
    pcall(function()
        if sc.SetPanTarget then sc:SetPanTarget(x, y) end
        if sc.SetZoomTarget then sc:SetZoomTarget(scale) end
        if sc.InstantPanAndZoom then sc:InstantPanAndZoom(scale, x, y) end
    end)
end

-- ---------------------------------------------------------------------------
-- SHAPING IT.
--
-- The hole this sits in is round -- Hud's tray paints a disc masked with MASK_ROUND
-- -- and a square map in a round hole reads as unfinished rather than deliberate.
--
-- Masking a MapCanvas is NOT the one-liner it is for the Minimap. SetMaskTexture is
-- a Texture method and BattlefieldMapFrame is a Frame, so there is nothing to call
-- it on. What works is the other half of the same system: one MaskTexture region,
-- added to every terrain texture on the canvas with Texture:AddMaskTexture.
--
-- Which means finding them, and then finding them AGAIN. The canvas builds its
-- detail tiles from a pool and re-lays them out on every pan and every zone change,
-- so a one-shot at Enable masks whatever existed at that instant and nothing after
-- -- you'd get a clean circle that grew square corners the moment you walked. Same
-- shape of problem as the button patrol in Hud.lua, and the same answer: sweep, on
-- the tick we are already running, and remember what we've done so it stays cheap.
--
-- WE WALK FOR TEXTURES rather than reaching for frame.detailLayerPool and
-- layer.textures. Those are Blizzard's internal names for Blizzard's internal
-- shapes, and this addon has been bitten once already by a hierarchy changing
-- underneath it (see the 12.0 note in Hud.MinimapOwner). A recursive walk needs no
-- names and survives them being renamed.
--
-- CLAMPTOBLACKADDITIVE is load-bearing. Tiles extend past the frame while the
-- canvas is panned; without clamping, everything beyond the mask's own rectangle is
-- left UNMASKED, and the map spills its corners out over the tray exactly where the
-- circle was supposed to end.
-- ---------------------------------------------------------------------------
local shapeMask
local maskedTex = {}            -- textures we've already masked; AddMaskTexture twice
                                -- on one texture is waste, and there's a hard cap on
                                -- how many masks a texture will take.
local sinceShape = 0

-- nil means "no shape" -- a square map, the way Blizzard draws it.
local function shapeArt()
    local shape = (NS.db and NS.db.cornerShape) or "circle"
    if shape == "square" then return nil end
    return NS.CustomGlyphDir .. "MASK_ROUND"
end

-- Where the terrain actually lives. GetCanvas is the sanctioned accessor; the
-- ScrollContainer.Child fallback is what it returns anyway, for a client where it
-- doesn't exist.
local function canvasRoot()
    if not frame then return nil end
    if frame.GetCanvas then
        local ok, c = pcall(frame.GetCanvas, frame)
        if ok and c then return c end
    end
    return frame.ScrollContainer and frame.ScrollContainer.Child or frame
end

local function clearShape()
    if shapeMask then
        for r in pairs(maskedTex) do
            if r.RemoveMaskTexture then pcall(r.RemoveMaskTexture, r, shapeMask) end
        end
    end
    wipe(maskedTex)
end

local function ensureShapeMask()
    local art = shapeArt()
    local tray = _G.EyesUpMinimapTray
    if not (art and tray) then return nil end

    if not shapeMask then
        if not tray.CreateMaskTexture then return nil end
        shapeMask = tray:CreateMaskTexture()
    end
    shapeMask:SetTexture(art, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    shapeMask:ClearAllPoints()
    -- Anchored to the tray (ours, and it outlives the map being handed back) but
    -- SIZED to the map. Those were the same rect until cornerMapScale existed, and
    -- SetAllPoints(tray) quietly became wrong the moment it did: a mask wider than
    -- the map crops nothing, so the map would come back square.
    shapeMask:SetSize(mapSize(tray))
    shapeMask:SetPoint("CENTER", tray, "CENTER", 0, 0)
    return shapeMask
end

local function shapeWalk(obj, depth)
    if not obj or depth > 6 then return end
    if obj.GetRegions then
        for _, r in ipairs({ obj:GetRegions() }) do
            if not maskedTex[r] and r.GetObjectType and r:GetObjectType() == "Texture"
               and r.AddMaskTexture then
                if pcall(r.AddMaskTexture, r, shapeMask) then maskedTex[r] = true end
            end
        end
    end
    if obj.GetChildren then
        for _, c in ipairs({ obj:GetChildren() }) do shapeWalk(c, depth + 1) end
    end
end

local function shapeSweep()
    if not (active and frame) then return end

    -- Re-assert on the slow sweep, not just once at Enable. The canvas rebuilds its
    -- tiles whenever it re-lays out -- new zone, new tile set -- and a rebuild can
    -- come back at a deeper level than the one we measured, which would sink the
    -- border and the arrow back under the terrain. Twice a second, and it's two
    -- setters over a tree of five frames, so it costs nothing to be certain.
    raiseAboveMap(borderHolder, 2)
    raiseAboveMap(marker, 4)

    if not ensureShapeMask() then return end     -- square, or no mask support
    shapeWalk(canvasRoot(), 0)
end

-- Called when the setting changes: drop what we did and do it again from scratch,
-- because going circle -> square has to actively REMOVE masks, not merely stop
-- adding them.
function Corner.ApplyShape()
    clearShape()
    if active then
        shapeSweep()
        -- A round border on a square map is worse than no border, so the frame
        -- follows the shape rather than being a setting you have to remember.
        ensureBorder(_G.EyesUpMinimapTray)
    end
end

-- ---------------------------------------------------------------------------
-- WHY THE MAP CAME UP AS A GHOST.
--
-- BattlefieldMapFrame carries a SECOND opacity, and it is not frame alpha. It's a
-- MapCanvas "global alpha", and Blizzard drives it from BattlefieldMapOptions --
-- whose `opacity` field is, despite the name, TRANSPARENCY:
--
--     function BattlefieldMapMixin:RefreshAlpha()
--         self:SetGlobalAlpha(1 - BattlefieldMapOptions.opacity)
--         self.BorderFrame:SetAlpha(1 - BattlefieldMapOptions.opacity)
--     end
--
-- Which is the right default for what that window IS: a translucent overlay you
-- keep up during a battleground and watch the fight through. It is exactly wrong
-- for what we're using it as -- an opaque map filling a hole in the UI. And the two
-- alphas MULTIPLY, so cornerAlpha at 1 still landed at whatever their slider said,
-- and the corner looked like a photocopy of a map with the world showing through.
--
-- WE DO NOT WRITE THEIR SAVED VARIABLE. BattlefieldMapOptions is the player's, and
-- their slider has to still mean what it says the next time they open that window
-- in a battleground. So we set the canvas's global alpha directly while we're
-- borrowing the frame, and hand it back by calling THEIR RefreshAlpha, which
-- reasserts THEIR value out of THEIR table. Nothing of theirs is stored, so there
-- is nothing of theirs to restore wrongly.
--
-- IT HAS TO BE RE-ASSERTED, NOT SET ONCE. RefreshAlpha runs again whenever that
-- opacity slider moves or the window is shown, and it would quietly drag our map
-- back down with it. Hence the hook -- hooksecurefunc, so Blizzard's own function
-- still runs first and we only add to it.
--
-- Everything here is behind a method check: SetGlobalAlpha is MapCanvasMixin's, and
-- a client that renames it should cost us the fix, not the corner map.
-- ---------------------------------------------------------------------------
local alphaHooked = false

local function setGlobalAlpha(a)
    if frame and frame.SetGlobalAlpha then
        pcall(frame.SetGlobalAlpha, frame, a)
    end
end

local function hookAlpha()
    if alphaHooked or not (frame and frame.RefreshAlpha) then return end
    alphaHooked = true
    hooksecurefunc(frame, "RefreshAlpha", function()
        if active then setGlobalAlpha(1) end
    end)
end

-- ===========================================================================
-- MAKING IT LOOK LIKE IT BELONGS
--
-- The corner map is a borrowed battleground window cut to a circle. It reads as a
-- hole with a map in it, because nothing frames it -- the minimap's own furniture
-- is drawn around the CLUSTER, and what we've put in the middle of it is not the
-- minimap any more.
--
-- WE DO NOT TYPE AN ART PATH. Two reasons, and the first is in Constants.lua: WoW
-- gives Lua no way to ask whether a texture file exists, so a wrong path is a
-- silently blank frame that no code here can detect or apply back from. And a
-- hardcoded name is a bet on the next patch besides.
--
-- So the art is DISCOVERED, and only ever something we've checked:
--
--   1. Whatever the live minimap is actually wearing. It's a texture on a frame we
--      can walk, so we read its atlas (or file) and its size straight off the UI.
--      Whatever this client -- or a UI suite -- put around the minimap is what goes
--      around the corner map, which is a better definition of "native" than any
--      name typed here could be.
--   2. A named atlas, but only one C_Texture.GetAtlasInfo confirms this client has.
--      That call returns nil for a name it's never heard of, which is exactly the
--      existence check plain files don't get -- so a wrong guess in the list below
--      costs nothing, it simply isn't picked.
--   3. One old, stable FILE, last, and flagged as the one thing here we cannot
--      check. A missing file draws nothing and says nothing, so this is the only
--      step that can fail silently -- which is why it's last and why /eu art
--      names it as unverified rather than letting it look like a success.
--
-- /eu art prints all of it -- what the minimap is wearing, and which of the
-- candidates this client actually has -- so pinning a better one is a look, not a
-- guessing game.
-- ===========================================================================
local borderArt                  -- { atlas=|file=, ratio= } once we've worked it out
local borderScanned = false

-- Names worth asking about. Not a list of things we believe are there -- a list of
-- things it is free to ASK about, because every one is verified before use.
--
-- The first entry is not a guess. It's what /eu art found on a 12.1 client: the
-- minimap's own ring is `UI-HUD-Minimap-Frame`, a region of the Minimap itself,
-- overhanging it by 1.09x. Four plausible-looking *-Border spellings were asked
-- about on that same client and every one came back unknown -- which is the whole
-- argument for verifying rather than typing a path and hoping.
--
-- The ratio is carried with the name because we can't measure it reliably at
-- runtime: by the time Corner runs, the HUD has already resized the Minimap, so
-- anything anchored to it measures against the wrong thing. 1.09 is what it reports
-- against an untouched map, and /eu border tunes it without a code change.
local BORDER_ATLASES = {
    { "UI-HUD-Minimap-Frame", 1.09 },   -- measured, 12.1
    { "UI-HUD-Minimap-Border", 1.09 },  -- kept in case a later patch renames it back
}

-- The last resort, and the only unverifiable thing in this file.
--
-- Interface\Minimap\MiniMap-TrackingBorder is an old, stable, round border, and it
-- has been in the client forever. But it is a FILE, not an atlas, so there is no
-- GetAtlasInfo to ask -- which is the exact hole described at the top of
-- Constants.lua: a missing file draws nothing and reports nothing, and no code here
-- can tell that apart from success.
--
-- Two consequences, both handled rather than hoped past. It goes LAST, so it only
-- runs on a client where nothing verifiable was found. And /eu art says out loud
-- that it's unverified, so "the corner came up unframed" has an answer waiting
-- instead of being a mystery.
--
-- It is also a border drawn for the small tracking BUTTON, not for a map, so its
-- overhang is a starting point rather than a measurement. /eu border tunes it.
local BORDER_FILE = { file = "Interface\\Minimap\\MiniMap-TrackingBorder", ratio = 1.4,
                      unverified = true }

local function verifiedAtlas(name)
    if not (C_Texture and C_Texture.GetAtlasInfo) then return nil end
    local ok, info = pcall(C_Texture.GetAtlasInfo, name)
    return (ok and info) and name or nil
end

-- The art on a Texture, whichever way it was set.
local function artOf(t)
    local a = t.GetAtlas and t:GetAtlas()
    if a then return a, nil end
    local f = t.GetTexture and t:GetTexture()
    if type(f) == "string" then return nil, f end
    return nil, nil
end

-- Walk the minimap's furniture looking for something ring-shaped. "Ring-shaped" is
-- judged by NAME (its art says border/ring/circle) and by SIZE (about as wide as the
-- map, give or take the overhang a border has by definition). Both, not either: the
-- cluster is full of textures that are one or the other.
local function scanForBorder(refSize)
    if not refSize or refSize <= 0 then return nil end

    local best
    local function look(f, depth)
        if not f or depth > 2 or not f.GetRegions then return end
        for _, r in ipairs({ f:GetRegions() }) do
            if r.GetObjectType and r:GetObjectType() == "Texture" then
                local atlas, file = artOf(r)
                -- "frame" is in here because of what /eu art found: the stock ring
                -- is called UI-HUD-Minimap-Frame, and a matcher looking only for
                -- "border" walked straight past the one texture it was written to
                -- find. The size window below is what keeps that word honest.
                local name = (atlas or file or ""):lower()
                if name:find("border") or name:find("ring") or name:find("circle")
                   or name:find("frame") then
                    local w = r:GetWidth() or 0
                    local ratio = w / refSize
                    -- A border is never much smaller than what it borders, and never
                    -- twice its size. Outside that it's a bar, a badge or a backdrop.
                    if ratio >= 0.9 and ratio <= 1.8 then
                        if not best or ratio < best.ratio then
                            best = { atlas = atlas, file = file, ratio = ratio }
                        end
                    end
                end
            end
        end
        if f.GetChildren then
            for _, c in ipairs({ f:GetChildren() }) do look(c, depth + 1) end
        end
    end

    look(_G.MinimapCluster, 0)
    look(_G.Minimap, 0)
    return best
end

-- Decided once per session, because the answer can't change without a reload and
-- the scan is a tree walk we'd otherwise be doing twice a second.
local function resolveBorderArt(refSize)
    if borderScanned then return borderArt end
    borderScanned = true

    borderArt = scanForBorder(refSize)
    if borderArt then return borderArt end

    for _, cand in ipairs(BORDER_ATLASES) do
        if verifiedAtlas(cand[1]) then
            borderArt = { atlas = cand[1], ratio = cand[2] }
            return borderArt
        end
    end

    borderArt = BORDER_FILE     -- unverifiable, and labelled as such. See above.
    return borderArt
end

function ensureBorder(tray)
    if not tray then return end

    local db = NS.db
    if not (db and db.cornerBorder) or (db.cornerShape or "circle") ~= "circle" then
        if borderHolder then borderHolder:Hide() end
        return
    end

    local art = resolveBorderArt(tray:GetWidth())
    if not art then
        if borderHolder then borderHolder:Hide() end
        return
    end

    -- IT NEEDS A FRAME OF ITS OWN, not a texture on the tray.
    --
    -- The map is a CHILD of the tray, so it draws above everything the tray draws
    -- itself -- a texture hung straight on the tray would be a border neatly hidden
    -- behind the thing it borders. Same trick the marker uses: our own frame, at a
    -- level above the map's. Two above, so the marker (+4) still wins over both.
    if not borderHolder then
        borderHolder = CreateFrame("Frame", nil, tray)
        borderTex = borderHolder:CreateTexture(nil, "OVERLAY")
        borderTex:SetAllPoints(borderHolder)
    end
    borderHolder:SetParent(tray)
    raiseAboveMap(borderHolder, 2)      -- 2, so the marker's 4 still wins over it

    if art.atlas then
        -- SetAtlas and nothing else. No SetTexCoord after it, ever: the atlas has
        -- already applied its own offset and scale, and adding coordinates on top
        -- applies them twice. That one cost a fortnight elsewhere.
        borderTex:SetAtlas(art.atlas, false)
    else
        borderTex:SetTexture(art.file)
    end

    local scale = tonumber(db.cornerBorderScale) or art.ratio or 1.18
    local size = tray:GetWidth() * scale
    borderHolder:ClearAllPoints()
    borderHolder:SetSize(size, size)
    borderHolder:SetPoint("CENTER", tray, "CENTER", 0, 0)
    borderHolder:SetAlpha(db.cornerAlpha or 1)
    borderHolder:Show()
end

-- What the frame is drawn at right now, so a slider can start its handle where the
-- frame actually is rather than at a number we picked. cornerBorderScale is nil
-- until somebody overrides it -- "whatever the art implies" -- and that isn't a
-- position on a slider, so this resolves it to one.
function Corner.BorderScale()
    local db = NS.db
    local override = db and tonumber(db.cornerBorderScale)
    if override then return override end
    return (borderArt and borderArt.ratio) or 1.09
end

-- /eu art -- what the minimap is wearing, and what this client has to offer.
-- Built for exactly one job: replacing "which texture should we use?" with a look.
function Corner.ArtReport()
    local tray = _G.EyesUpMinimapTray
    local ref = tray and tray:GetWidth() or (_G.Minimap and _G.Minimap:GetWidth()) or 0
    NS.Printf("|cff66ff66corner art.|r Sizes are relative to a %d px map.", ref)

    local n = 0
    local function dump(f, label, depth)
        if not f or depth > 2 or not f.GetRegions then return end
        for _, r in ipairs({ f:GetRegions() }) do
            if r.GetObjectType and r:GetObjectType() == "Texture" then
                local atlas, file = artOf(r)
                if atlas or file then
                    n = n + 1
                    NS.Printf("  %s%-8s %-4s %5.2fx  %s", ("  "):rep(depth), label,
                        r:IsShown() and "|cff66ff66on|r" or "|cff888888off|r",
                        ref > 0 and ((r:GetWidth() or 0) / ref) or 0,
                        atlas and ("|cffffcc00@" .. atlas .. "|r") or file)
                end
            end
        end
        if f.GetChildren then
            for _, c in ipairs({ f:GetChildren() }) do dump(c, label, depth + 1) end
        end
    end
    dump(_G.MinimapCluster, "cluster", 0)
    dump(_G.Minimap, "minimap", 0)
    if n == 0 then NS.Print("  |cffffcc00nothing -- the minimap's art is all engine-drawn here.|r") end

    NS.Print("candidate atlases:")
    for _, cand in ipairs(BORDER_ATLASES) do
        NS.Printf("  %-28s %s", cand[1],
            verifiedAtlas(cand[1]) and "|cff66ff66this client has it|r" or "|cff888888unknown|r")
    end
    NS.Printf("  %-28s |cffffcc00can't be checked|r (a file, not an atlas)", BORDER_FILE.file)

    borderScanned = false                      -- so this re-decides after a look
    local art = resolveBorderArt(ref)
    if not art then
        NS.Print("using: |cffffcc00nothing|r -- the corner stays unframed.")
    else
        NS.Printf("using: |cff66ff66%s|r at %.2fx%s",
            art.atlas and ("@" .. art.atlas) or art.file, art.ratio,
            art.unverified
                and "  |cffffcc00-- unverified. If the corner looks unframed, this file isn't there.|r"
                or "")
    end
end

-- ---------------------------------------------------------------------------
-- On
-- ---------------------------------------------------------------------------
function Corner.Enable()
    if active then return end
    -- Reparenting and showing one of Blizzard's windows is the kind of thing the
    -- client stops mid-combat. Same deal as the HUD: wait, then do it. The corner
    -- map is only reachable while the HUD is up, and that waits too.
    if notNow() then return end
    frame = acquire()
    if not frame then return end

    -- Do this FIRST, before we reparent and before any pin can be acquired.
    killProviders(frame)

    local tray = _G.EyesUpMinimapTray
    if not tray then return end          -- the HUD owns the tray; no HUD, no corner

    saved = {
        parent  = frame:GetParent(),
        point   = { frame:GetPoint(1) },
        w       = select(1, frame:GetSize()),
        h       = select(2, frame:GetSize()),
        alpha   = frame:GetAlpha(),
        shown   = frame:IsShown(),
        movable = frame:IsMovable(),
        mouse   = frame:IsMouseEnabled(),
    }

    -- THE DISC HAS NOTHING LEFT TO DO. Hud's tray paints a black 55% disc so the
    -- corner reads as a deliberate dark circle rather than a ring around a hole.
    -- There is a real map in that hole now, and the disc sits directly behind it at
    -- exactly the same size -- so all it can do is tint the map darker, which is
    -- precisely what it looked like. Off while we're here, back when we leave.
    if tray.disc then tray.disc:Hide() end

    frame:SetParent(tray)
    frame:ClearAllPoints()
    frame:SetPoint("CENTER", tray, "CENTER", 0, 0)
    frame:SetSize(mapSize(tray))
    frame:SetAlpha(NS.db.cornerAlpha or 1)

    -- Blizzard's own transparency, stood down while we own the frame -- see the
    -- long note above. cornerAlpha is the only dial on this map from here.
    hookAlpha()
    setGlobalAlpha(1)

    -- It must not eat clicks: the addon buttons live on this tray, on top of it,
    -- and a map that swallows the mouse would make every one of them dead.
    frame:SetMovable(false)
    frame:EnableMouse(false)

    -- Its window furniture -- title bar, close button, the tabs -- is for a
    -- floating window. This isn't one.
    if frame.BorderFrame then frame.BorderFrame:Hide() end
    if frame.Tab then frame.Tab:Hide() end

    frame:Show()
    ensureBorder(tray)
    ensureMarker(tray)
    lastMapID = nil
    active = true

    follow()
    shapeSweep()

    if not follower then
        follower = CreateFrame("Frame")
        -- The PAN is every frame, not throttled. At 10/sec the player visibly
        -- drifted toward the edge between updates while flying, then snapped back.
        -- It's a couple of setter calls, so just keep it pinned.
        --
        -- The SHAPE sweep is not: it's a tree walk, and new tiles only appear when
        -- the canvas re-lays out. Twice a second is well inside that, and everything
        -- it has already masked is skipped on sight.
        follower:SetScript("OnUpdate", function(_, elapsed)
            if not active then return end
            follow()
            sinceShape = sinceShape + elapsed
            if sinceShape >= 0.5 then
                sinceShape = 0
                shapeSweep()
            end
        end)
    end
    follower:Show()
end

-- ---------------------------------------------------------------------------
-- Off -- it's Blizzard's window and we borrowed it.
-- ---------------------------------------------------------------------------
function Corner.Disable()
    if not active or not frame then
        active = false
        return
    end
    -- Handing the window back is surgery too. Leaving it parked for the rest of a
    -- fight is harmless; erroring while somebody is being hit is not.
    if notNow() then return end

    if follower then follower:Hide() end
    if marker then marker:Hide() end
    if borderHolder then borderHolder:Hide() end

    -- Take the masks off BEFORE we hand the window back. It's Blizzard's, and a
    -- Battlefield Map that opens as a circle for the rest of the session because we
    -- borrowed it once is exactly the kind of mess this file's Disable exists to
    -- avoid. The tiles are pooled and reused, so this matters even if nobody ever
    -- opens that window.
    clearShape()

    -- Give the hole its filler back -- we're about to take the map out of it.
    local tray = _G.EyesUpMinimapTray
    if tray and tray.disc then tray.disc:Show() end

    if frame.BorderFrame then frame.BorderFrame:Show() end
    if frame.Tab then frame.Tab:Show() end

    if saved then
        frame:SetParent(saved.parent)
        frame:ClearAllPoints()
        if saved.point[1] then frame:SetPoint(unpack(saved.point)) end
        frame:SetSize(saved.w, saved.h)
        frame:SetAlpha(saved.alpha)
        frame:SetMovable(saved.movable)
        frame:EnableMouse(saved.mouse)
        frame:SetShown(saved.shown)
    end

    saved = nil
    lastMapID = nil
    active = false

    -- Their transparency back, from their own table -- and AFTER active goes false,
    -- or the hook above would immediately undo it. We never stored a value of
    -- theirs, so this can't hand back a stale one.
    if frame.RefreshAlpha then pcall(frame.RefreshAlpha, frame) end
end

function Corner.ApplyLook()
    if not (active and frame) then return end
    local tray = _G.EyesUpMinimapTray
    if tray then
        frame:SetSize(mapSize(tray))
        ensureBorder(tray)          -- the tray may have resized under it
        ensureMarker(tray)
    end
    frame:SetAlpha(NS.db.cornerAlpha or 1)
    setGlobalAlpha(1)
    follow()
    -- The tray may have resized under us, which moves the mask's rect -- so re-anchor
    -- it and pick up anything the resize rebuilt.
    shapeSweep()
end

-- What the two alphas are actually doing, for the next time the corner comes up
-- faint. The multiply is the thing to see: a frame alpha of 1 and a global alpha
-- of 0.3 is a map at 30%, and nothing in the options page would have told you.
function Corner.AlphaReport()
    if not frame then return "no map borrowed yet" end

    local fa = frame:GetAlpha() or 1

    -- GetGlobalAlpha is not guaranteed the way its setter is -- MapCanvasMixin keeps
    -- the value in a field and hasn't always offered a reader. Fall back to the
    -- field rather than reporting "?" when the number is sitting right there.
    local g
    if frame.GetGlobalAlpha then
        local ok, v = pcall(frame.GetGlobalAlpha, frame)
        if ok then g = v end
    end
    if g == nil then g = frame.globalAlpha end

    local opts = _G.BattlefieldMapOptions
    return ("frame %.2f x global %s = %s  (Blizzard's own slider: %s transparent)"):format(
        fa,
        g and ("%.2f"):format(g) or "?",
        g and ("|cff66ff66%.2f|r"):format(fa * g) or "?",
        (opts and opts.opacity) and ("%d%%"):format(opts.opacity * 100) or "?")
end

-- Settling up: whatever we ducked in combat, decide it again now. Hud.lua's own
-- flush usually gets here first (it loads earlier, so its handler runs first, and
-- enabling the HUD enables us) -- both Enable and Disable early-out when there's
-- nothing to do, so arriving second is a no-op rather than a fight.
local combatWatch = CreateFrame("Frame")
combatWatch:RegisterEvent("PLAYER_REGEN_ENABLED")
combatWatch:SetScript("OnEvent", function()
    if not combatPending then return end
    combatPending = false
    if NS.db and NS.db.cornerMap and NS.Hud and NS.Hud.IsActive() then
        Corner.Enable()
    else
        Corner.Disable()
    end
end)
