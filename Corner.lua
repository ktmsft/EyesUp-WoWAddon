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
local stripped = false          -- have we removed its (tainting) data providers yet

-- It's a LoadOnDemand Blizzard addon, so it doesn't exist until somebody asks.
local function acquire()
    if _G.BattlefieldMapFrame then return _G.BattlefieldMapFrame end
    local load = C_AddOns and C_AddOns.LoadAddOn or _G.LoadAddOn
    if load then pcall(load, "Blizzard_BattlefieldMap") end
    return _G.BattlefieldMapFrame
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
-- This is the whole thing that was missing: the probe panned to the player ONCE,
-- so it showed you where you'd been standing when you ran it and then sat there
-- while you walked away.
--
-- A map that doesn't follow you is a screenshot.
--
-- Two jobs, and they're different: pan to the player's position every tick, and
-- re-point the canvas at a whole new map when you cross a zone boundary. Miss the
-- second and you get a beautifully centred view of the zone you just left.
-- ---------------------------------------------------------------------------
local function follow()
    if not (active and frame) then return end

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
-- On
-- ---------------------------------------------------------------------------
function Corner.Enable()
    if active then return end
    frame = acquire()
    if not frame then return end

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

    -- STRIP THE PINS, or they'll taint us. This is the important line.
    --
    -- The Battlefield Map is a secure Blizzard frame. The moment we reparent and
    -- drive it from addon code it's tainted -- and its AreaPOI / quest / vignette
    -- pins call the PROTECTED SetPropagateMouseClicks when they're acquired. With
    -- our taint on the stack, the game blocks that call and spits ADDON_ACTION_
    -- BLOCKED errors every time a mailbox or quest marker comes into view.
    --
    -- We don't want those pins anyway -- the whole point of this map is terrain and
    -- roads. So remove every data provider. No pins acquired, no protected call, no
    -- taint. The map's own tile system draws the terrain regardless (it isn't a data
    -- provider), and our follow loop keeps it centred on you, so "you are here" is
    -- simply the middle of the frame -- no player pin required.
    --
    -- Side effect: this leaves the Battlefield Map itself bare until a /reload, but
    -- almost nobody uses it directly, and a reload restores it fully.
    if not stripped and frame.RemoveAllDataProviders then
        pcall(frame.RemoveAllDataProviders, frame)
        stripped = true
    end

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
    lastMapID = nil
    active = true

    follow()

    if not follower then
        follower = CreateFrame("Frame")
        -- EVERY frame, not throttled. At 10/sec the player visibly drifted toward
        -- the edge between updates while flying, then snapped back. The pan is a
        -- cheap call, so just keep it pinned.
        follower:SetScript("OnUpdate", function()
            if active then follow() end
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

    if follower then follower:Hide() end

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
    end
    frame:SetAlpha(NS.db.cornerAlpha or 1)
    follow()
end
