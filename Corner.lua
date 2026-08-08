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
    -- Above the map, which is a child of the same tray. The buttons orbit the rim
    -- and this is sixteen pixels dead centre, so nothing of yours gets covered.
    if frame then marker:SetFrameLevel(frame:GetFrameLevel() + 4) end
    marker:SetAlpha(NS.db.cornerAlpha or 1)
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
    -- The tray, not the map: same rect (Enable sizes the map to it), but the tray is
    -- ours and outlives the map being handed back.
    shapeMask:SetAllPoints(tray)
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
    if not ensureShapeMask() then return end     -- square, or no mask support
    shapeWalk(canvasRoot(), 0)
end

-- Called when the setting changes: drop what we did and do it again from scratch,
-- because going circle -> square has to actively REMOVE masks, not merely stop
-- adding them.
function Corner.ApplyShape()
    clearShape()
    if active then shapeSweep() end
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
    frame:SetSize(tray:GetWidth(), tray:GetHeight())
    frame:SetAlpha(NS.db.cornerAlpha or 1)

    -- It must not eat clicks: the addon buttons live on this tray, on top of it,
    -- and a map that swallows the mouse would make every one of them dead.
    frame:SetMovable(false)
    frame:EnableMouse(false)

    -- Its window furniture -- title bar, close button, the tabs -- is for a
    -- floating window. This isn't one.
    if frame.BorderFrame then frame.BorderFrame:Hide() end
    if frame.Tab then frame.Tab:Hide() end

    frame:Show()
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
end

function Corner.ApplyLook()
    if not (active and frame) then return end
    local tray = _G.EyesUpMinimapTray
    if tray then
        frame:SetSize(tray:GetWidth(), tray:GetHeight())
        ensureMarker(tray)          -- the tray may have resized under it
    end
    frame:SetAlpha(NS.db.cornerAlpha or 1)
    follow()
    -- The tray may have resized under us, which moves the mask's rect -- so re-anchor
    -- it and pick up anything the resize rebuilt.
    shapeSweep()
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
