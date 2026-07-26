-- Eyes Up - Copyright (c) 2026 KTM (abitofmoss). All Rights Reserved.
-- No redistribution or reuse of this code or assets without permission. See LICENSE.
local addonName, NS = ...

-- =============================================================================
-- Vignettes.lua
-- The only things we can actually see.
--
-- Everywhere else in this addon we're working from memory. Not here. Treasures
-- and rares get surfaced by Blizzard as *vignettes* -- those little icons that
-- appear at the edge of your minimap -- and unlike herbs and ore, the client
-- will happily tell us about them: what they are, where they are, right now.
--
-- No database. No guessing. We ask every update and the world answers. These are
-- the only nodes the addon is ever genuinely CERTAIN about, which is why they're
-- the ones that draw at full opacity while everything else fades a little.
-- =============================================================================

local Vignettes = {}
NS.Vignettes = Vignettes

local Data = NS.Data
local issecretvalue = _G.issecretvalue   -- 12.0: instanced guids come back "secret"

-- Enum.VignetteType.* -> NodeType, resolved by NAME at load. The numeric values
-- shuffle between builds; the names don't.
local typeMap = {}   -- [enumValue] = NodeType
do
    if Enum and Enum.VignetteType then
        for enumName, nodeType in pairs(NS.VignetteTypeToNode) do
            local val = Enum.VignetteType[enumName]
            if val ~= nil then typeMap[val] = nodeType end
        end
    end
end

-- What is this thing -- or nil for "none of our business."
--
-- That nil is the most important thing in this file. We used to fall back to
-- TREASURE for anything we didn't recognize, which sounds harmless until you
-- learn that Enum.VignetteType.Normal is retail's junk drawer: rares, world
-- events, quest objectives, bonus objectives, someone's dropped profession bag.
-- All Normal. All, therefore, "treasure." The cue never shut up and the filter
-- list filled with rare mobs.
--
-- Now: the atlas name decides (VignetteLoot* is a chest, VignetteKill* is a rare
-- you must fight, VignetteEvent* is an event), the enum only gets a say when it
-- explicitly says Treasure, and anything else is politely ignored. Not drawn,
-- not remembered, not counted.
local function classify(info)
    local atlas = info.atlasName
    if atlas then
        atlas = atlas:lower()
        for _, rule in ipairs(NS.VignetteAtlasToNode) do
            if atlas:find(rule.match, 1, true) then return rule.node end
        end
    end
    return typeMap[info.type]
end

-- ---------------------------------------------------------------------------
-- The node cache, keyed by GUID
--
-- We used to build a brand-new node table for every vignette on every update.
-- Twenty a second, forever. Wasteful, yes -- but the real cost was that a node
-- was never the same table twice, and the cue needs to ask "is this a DIFFERENT
-- node than last tick?" to decide whether to tick the sound and re-resolve the
-- icon. With fresh tables every frame, that question has no cheap answer.
--
-- The GUID is the stable identity of a *particular* vignette while it's visible.
-- (vignetteID is not -- that identifies the KIND, so two chests of the same sort
-- share one.) So we cache by GUID and update the node in place. Now every node
-- in the addon, from either source, is the same Lua table from tick to tick, and
-- "is it different?" is a pointer comparison.
--
-- Pleasant side effect: rares that patrol now move, instead of teleporting.
-- ---------------------------------------------------------------------------
local nodeCache = {}   -- [guid] = node
local seen = {}        -- scratch set, reused every pass

local function getNode(guid, nodeType, id, name, x, y)
    local node = nodeCache[guid]
    if not node then
        node = { vignette = true }
        nodeCache[guid] = node
    end
    node.x, node.y = x, y
    node.type, node.id, node.name = nodeType, id, name
    return node
end

-- Forget the ones that have wandered off (or been looted).
local function prune()
    for guid in pairs(nodeCache) do
        if not seen[guid] then nodeCache[guid] = nil end
    end
end

-- Walk every visible vignette on this map, handing each to
--   fn(node, distanceYards, bearingRadians)
-- -- the exact same shape Data.ForEachNearby uses, which is what lets Scan treat
-- memory and sight as interchangeable. Filters are applied here, at the source,
-- same as there.
function Vignettes.ForEachOnMap(mapID, px, py, fn)
    if not C_VignetteInfo then return end
    local guids = C_VignetteInfo.GetVignettes()
    if not guids then return end

    wipe(seen)

    for _, guid in ipairs(guids) do
        -- In instanced content (delves, dungeons) 12.0 can hand back a SECRET guid,
        -- and using one as a table key (seen[guid], the node cache) errors. Skip it
        -- -- there's nothing to gather in an instance anyway.
        if issecretvalue and issecretvalue(guid) then
            -- nothing
        else
        local info = C_VignetteInfo.GetVignetteInfo(guid)
        -- onMinimap == false means the player can't see it either. We're here to
        -- notice things for you, not to conjure them.
        if info and info.onMinimap ~= false then
            seen[guid] = true
            local nodeType = classify(info)      -- nil = not our business
            local id = info.vignetteID
            if nodeType and Data.IsVisible(nodeType, id) then
                local pos = C_VignetteInfo.GetVignettePosition(guid, mapID)
                if pos then
                    local x, y = pos:GetXY()
                    if x and y then
                        -- The name can be secret even when the guid isn't, and it
                        -- flows into node.name -> the cue's item lookup and its text
                        -- label. A secret there errors, so drop it to nil (the
                        -- vignette still shows, just nameless).
                        local safeName = info.name
                        if issecretvalue and issecretvalue(safeName) then safeName = nil end
                        Data.NoteKnown(nodeType, id, safeName)
                        local node = getNode(guid, nodeType, id, safeName, x, y)
                        local dist = Data.DistanceYards(mapID, px, py, x, y)
                        local bearing = Data.Bearing(mapID, px, py, x, y)
                        fn(node, dist, bearing)
                    end
                end
            end
        end
        end   -- close the not-secret branch
    end

    prune()
end

-- `/eu vignettes` -- show your work.
--
-- Prints everything the game is currently showing you, its atlas name, and what
-- we decided it was. If something you want is being ignored, this is where you
-- find the atlas string to add to NS.VignetteAtlasToNode. If something you DON'T
-- want keeps showing up, this is where you find out why.
function Vignettes.Dump()
    if not C_VignetteInfo then
        NS.Print("this client has no vignette API. Odd.")
        return
    end
    local guids = C_VignetteInfo.GetVignettes() or {}
    NS.Printf("%d vignette(s) in sight:", #guids)
    for _, guid in ipairs(guids) do
        local info = C_VignetteInfo.GetVignetteInfo(guid)
        if info then
            local nodeType = classify(info)
            print(("  %s  |cff888888atlas=%s type=%s|r  -> %s"):format(
                tostring(info.name),
                tostring(info.atlasName),
                tostring(info.type),
                nodeType and (NS.NodeTypeLabel[nodeType] or nodeType)
                         or "|cffff5555ignored|r"))
        end
    end
end

-- The scan re-reads vignettes every update anyway, so this frame isn't load
-- bearing -- it's just here to say something in the debug log when the world
-- changes its mind about what's visible.
local ef = CreateFrame("Frame")
ef:RegisterEvent("VIGNETTES_UPDATED")
ef:RegisterEvent("VIGNETTE_MINIMAP_UPDATED")
ef:SetScript("OnEvent", function(_, event, ...)
    if not (NS.db and NS.db.debug) then return end
    if event == "VIGNETTES_UPDATED" and C_VignetteInfo then
        local guids = C_VignetteInfo.GetVignettes() or {}
        NS.Printf("vignettes in sight: %d", #guids)
    end
end)
