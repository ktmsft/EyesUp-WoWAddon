local addonName, NS = ...

-- =============================================================================
-- Options.lua
-- The knobs. Escape → Options → AddOns → Eyes Up.
--
-- We register a *canvas* category, which is Blizzard's way of saying "here's an
-- empty rectangle, you're on your own." Everything you see in it -- every
-- checkbox, slider, swatch and scrollbar -- is hand-built below. That's more code
-- than using the Settings widget API, but it means the page looks like the addon
-- and not like a form.
--
-- Three columns: what to show, what it looks like, and the list of every specific
-- thing you've ever found (so you can tell it to stop mentioning that one weed).
--
-- The panel has no backdrop, no close button, no drag handling and no frame
-- strata, and that is not an oversight -- the Settings container supplies all of
-- that and sizes us to its canvas. Add any of it back and you'll get a window
-- inside a window.
-- =============================================================================

local Options = {}
NS.Options = Options

local panel

-- Controls that only mean something in one mode. Refresh greys out the ones the
-- current mode ignores, so nobody drags "Radar size" in cue mode and wonders why
-- the world isn't changing.
-- `cueOnly` no longer means "hidden in radar mode" -- the radar isn't on this page
-- any more. It survives because the column layout reads it to work out which
-- controls are sliders and need SLIDER_LEAD headroom above them.
local cueOnly = {}

-- ---- small parts, made by hand ----------------------------------------------

local function setDimmed(control, enabled)
    if control.SetEnabled then control:SetEnabled(enabled) end
    if control.label then
        if enabled then control.label:SetTextColor(1, 1, 1)
        else control.label:SetTextColor(0.5, 0.5, 0.5) end
    end
end

local function makeCheck(parent, label, getter, setter)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetSize(24, 24)
    local fs = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetPoint("LEFT", cb, "RIGHT", 2, 0)
    fs:SetText(label)
    cb.label = fs
    cb:SetScript("OnClick", function(self)
        setter(self:GetChecked() and true or false)
        Options.SyncLayout()
    end)
    cb.Refresh = function() cb:SetChecked(getter()) end
    return cb
end

-- A radio button. Blizzard's radio template has no idea it's part of a group --
-- it's just a checkbox that looks round. So "pick exactly one" is simply: write
-- the value, then let Refresh repaint every button in the group from the single
-- source of truth in the DB. No bookkeeping, nothing to get out of sync.
local function makeRadio(parent, label, value, getter, setter)
    local rb = CreateFrame("CheckButton", nil, parent, "UIRadioButtonTemplate")
    rb:SetSize(20, 20)
    local fs = rb:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetPoint("LEFT", rb, "RIGHT", 4, 0)
    fs:SetText(label)
    rb.label = fs
    rb:SetScript("OnClick", function()
        setter(value)
        Options.SyncLayout()
        Options.Refresh()       -- repaint the siblings, re-grey by mode
    end)
    rb.Refresh = function() rb:SetChecked(getter() == value) end
    return rb
end

-- A color swatch that opens the game's color picker.
--
-- The picker changed shape in 10.2: SetupColorPickerAndShow(info) replaced
-- reaching in and poking ColorPickerFrame.func / .cancelFunc / .previousValues
-- by hand. We support both, because someone is always on an older client.
--
-- The swatchFunc writes through on every movement of the wheel, which is what
-- makes the cue recolor LIVE while you're still dragging. Little thing. Feels
-- like magic.
local function makeColorSwatch(parent, nodeType)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(16, 16)

    local bg = b:CreateTexture(nil, "BACKGROUND")
    bg:SetColorTexture(0, 0, 0, 1)      -- a dark hairline, so pale colors still read
    bg:SetAllPoints(b)

    local swatch = b:CreateTexture(nil, "ARTWORK")
    swatch:SetPoint("TOPLEFT", b, "TOPLEFT", 1, -1)
    swatch:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -1, 1)

    local function paint()
        local c = NS.TypeColor(nodeType)
        swatch:SetColorTexture(c[1], c[2], c[3], 1)
    end

    b:SetScript("OnClick", function()
        local c = NS.TypeColor(nodeType)
        local pr, pg, pb = c[1], c[2], c[3]      -- remembered, in case they change their mind

        local function commit(r, g, bl)
            NS.db.typeColor[nodeType] = { r, g, bl }
            paint()
            Options.SyncLayout()                 -- repaint the cue and the radar
        end
        local function onChange() commit(ColorPickerFrame:GetColorRGB()) end
        local function onCancel() commit(pr, pg, pb) end

        if ColorPickerFrame.SetupColorPickerAndShow then      -- 10.2+
            ColorPickerFrame:SetupColorPickerAndShow({
                r = pr, g = pg, b = pb,
                hasOpacity = false,
                swatchFunc = onChange,
                cancelFunc = onCancel,
            })
        else                                                   -- the old way
            ColorPickerFrame.func       = onChange
            ColorPickerFrame.cancelFunc = onCancel
            ColorPickerFrame.hasOpacity = false
            ColorPickerFrame.previousValues = { r = pr, g = pg, b = pb }
            ColorPickerFrame:SetColorRGB(pr, pg, pb)
            ColorPickerFrame:Hide()      -- so OnShow fires even if it's already up
            ColorPickerFrame:Show()
        end
    end)

    b.Refresh = paint
    return b
end

-- Sliders are TALLER THAN THEY LOOK: the title sits above the frame's top edge
-- and the value below its bottom, both outside the frame's own rect. That's what
-- the isSlider flag is for: the column layouts add SLIDER_LEAD of headroom above
-- every slider. Without it the title lands on top of the control above it, which
-- is exactly what the page used to look like.
-- Priority, as a button you click through rather than a dropdown you open.
--
-- Three values, one click each, and the answer is readable without opening
-- anything -- which is the entire argument against a dropdown here. The label is
-- also the state, so there's nothing to keep in sync.
local PRIORITY_TEXT = {
    [1] = "|cff888888Low|r",
    [2] = "Normal",
    [3] = "|cffffd100High|r",
}

local function makePriority(parent, nodeType)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(52, 18)

    local function current()
        local p = NS.db.typePriority and NS.db.typePriority[nodeType]
        return NS.PriorityWeight[p] and p or NS.Priority.NORMAL
    end

    b.Refresh = function() b:SetText(PRIORITY_TEXT[current()]) end

    b:SetScript("OnClick", function()
        NS.db.typePriority[nodeType] = (current() % 3) + 1     -- Low → Normal → High → Low
        b.Refresh()
        Options.SyncLayout()
    end)

    b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(NS.NodeTypeLabel[nodeType] or nodeType)
        GameTooltip:AddLine("When two things are in range at once, this decides which one gets the icon.",
            1, 1, 1, true)
        GameTooltip:AddLine("|cffffd100High|r counts as half its real distance, |cff888888Low|r as double. It's a preference, not a filter -- to stop seeing a type entirely, untick it.",
            0.8, 0.8, 0.8, true)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", GameTooltip_Hide)

    return b
end

local function makeSlider(parent, label, minV, maxV, step, getter, setter, fmt)
    local s = CreateFrame("Slider", nil, parent, "OptionsSliderTemplate")
    s.isSlider = true
    s:SetMinMaxValues(minV, maxV)
    s:SetValueStep(step)
    s:SetObeyStepOnDrag(true)
    s:SetWidth(180)
    -- Hide the template's built-in labels and use our own: theirs move around
    -- between patches, ours don't.
    if s.Low then s.Low:SetText("") end
    if s.High then s.High:SetText("") end
    local title = s:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    title:SetPoint("BOTTOM", s, "TOP", 0, 2)
    local val = s:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    val:SetPoint("TOP", s, "BOTTOM", 0, 0)
    s.label = title
    local function paint(v) title:SetText(label); val:SetText((fmt or "%.2f"):format(v)) end
    s:SetScript("OnValueChanged", function(self, v)
        setter(v); paint(v); Options.SyncLayout()
    end)
    s.Refresh = function() local v = getter(); s:SetValue(v); paint(v) end
    return s
end

-- Every widget writes straight through to NS.db the moment you touch it, so all
-- any of them needs afterwards is for the frames to notice. There are TWO
-- renderers now: fan out to both, or "Lock position" quietly stops applying to
-- the cue and you spend an evening wondering why.
function Options.SyncLayout()
    if NS.ApplyLayouts then NS.ApplyLayouts() end
end
Options.SyncOverlay = Options.SyncLayout   -- the old name, kept for old callers

-- ---- the list of everything you've found ------------------------------------
--
-- Sorted into expansions, because after a few hundred hours the flat list is a
-- wall of herb names and finding the one you want to mute means reading all of
-- them. Fold the expansions you're not playing in and the problem goes away.
--
-- WHERE THE EXPANSION COMES FROM: a table. NS.Species, in Species.lua.
--
-- It used to come from the 15th return of C_Item.GetItemInfo, which worked only
-- because a node's id was then the id of the item it dropped. Once identity moved
-- to the SPECIES (Peacebloom is 401, Copper Vein is 201), that call started
-- handing back some unrelated Classic item that happened to own the number 401 --
-- and its expansion -- so every herb was filed under a random one.
--
-- The set of herbs in the game is finite and changes once a year. It doesn't need
-- deriving at runtime, and deriving it is what broke it. So it's written down, and
-- an expansion lookup is now a table read that cannot be wrong and cannot be nil-
-- until-cached.

local headerPool, rowPool = {}, {}

local OTHER = "OTHER"     -- a species the table doesn't know (yet)

local function expansionName(key)
    if key == OTHER then return "Other" end
    return _G["EXPANSION_NAME" .. key] or ("Expansion " .. tostring(key))
end

local function getHeader(content, i)
    local h = headerPool[i]
    if not h then
        h = CreateFrame("Button", nil, content)
        h:SetSize(150, 18)
        h.text = h:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        h.text:SetPoint("LEFT", 2, 0)
        h:SetHighlightFontObject("GameFontHighlightSmall")
        headerPool[i] = h
    end
    return h
end

local function getRow(content, i)
    local r = rowPool[i]
    if not r then
        r = CreateFrame("Frame", nil, content)
        r:SetSize(150, 20)
        r.cb = CreateFrame("CheckButton", nil, r, "UICheckButtonTemplate")
        r.cb:SetSize(20, 20)
        r.cb:SetPoint("LEFT", 10, 0)
        -- A little colored square, so you can tell a herb from an ore at a glance
        -- without reading a word.
        r.dot = r:CreateTexture(nil, "ARTWORK")
        r.dot:SetSize(6, 6)
        r.dot:SetPoint("LEFT", r.cb, "RIGHT", 2, 0)
        r.text = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        r.text:SetPoint("LEFT", r.dot, "RIGHT", 4, 0)
        rowPool[i] = r
    end
    return r
end

-- Draws into `list`, the third column's frame, and grows it to fit. The column
-- has no scrollbar of its own any more -- the whole page scrolls, so the list is
-- just a tall thing on a tall page. That's one scrollbar instead of two nested
-- ones fighting over the mouse wheel.
local function rebuildNodeList(list)
    if not list then return end
    local db = NS.db
    if not db then return end

    for _, h in ipairs(headerPool) do h:Hide() end
    for _, r in ipairs(rowPool) do r:Hide() end

    -- EVERY species in the game, bucketed by expansion.
    --
    -- It used to list only what you'd "discovered", and that made the list a
    -- hostage to whatever data happened to be loaded that session -- wipe your
    -- saved variables, or play without the seed data, and the list came up EMPTY,
    -- with nothing to filter and no way to filter it. A filter list that can be
    -- empty is a filter list that doesn't work.
    --
    -- Species.lua knows every herb, vein and log in the game. So the list does
    -- too. All of them, always, whether you've seen one or not -- fold the
    -- expansions you aren't playing and the length stops mattering.
    local groups, keys = {}, {}
    for _, nType in ipairs(NS.NodeTypeOrder) do
        for id, s in pairs(NS.Species[nType] or {}) do
            local key = s.expac or OTHER
            local g = groups[key]
            if not g then
                g = {}
                groups[key] = g
                keys[#keys + 1] = key
            end
            g[#g + 1] = { type = nType, id = id, name = s.name }
        end
    end

    -- Newest expansion first -- it's the one you're playing. "Other" always last.
    table.sort(keys, function(a, b)
        if a == OTHER then return false end
        if b == OTHER then return true end
        return a > b
    end)

    local newest = keys[1]

    local hIdx, rIdx, y = 0, 0, -4

    for _, key in ipairs(keys) do
        local entries = groups[key]
        table.sort(entries, function(a, b) return (a.name or "") < (b.name or "") end)

        -- Everything folds shut by default EXCEPT the expansion you're playing.
        -- Four hundred rows unrolled is not a filter list, it's a phone book.
        local collapsed = db.filterCollapsed[key]
        if collapsed == nil then collapsed = (key ~= newest) end

        hIdx = hIdx + 1
        local h = getHeader(list, hIdx)
        h:ClearAllPoints()
        h:SetPoint("TOPLEFT", list, "TOPLEFT", 0, y)
        h.text:SetText(("%s %s |cff888888(%d)|r"):format(
            collapsed and "|cffffd100+|r" or "|cffffd100-|r",
            expansionName(key), #entries))
        h:SetScript("OnClick", function()
            db.filterCollapsed[key] = not collapsed
            rebuildNodeList(list)      -- redraw in place; cheap, and it feels instant
        end)
        h:Show()
        y = y - 18

        if not collapsed then
            for _, e in ipairs(entries) do
                rIdx = rIdx + 1
                local row = getRow(list, rIdx)
                row:ClearAllPoints()
                row:SetPoint("TOPLEFT", list, "TOPLEFT", 0, y)
                row.text:SetText(e.name or ("id " .. tostring(e.id)))

                local c = NS.TypeColor(e.type)
                row.dot:SetColorTexture(c[1], c[2], c[3], 1)

                -- Checked = "tell me about these". Unchecked = "I know. I don't care."
                local filtered = db.nodeFilter[e.type][e.id] == false
                row.cb:SetChecked(not filtered)
                row.cb:SetScript("OnClick", function(self)
                    if self:GetChecked() then
                        db.nodeFilter[e.type][e.id] = nil
                    else
                        db.nodeFilter[e.type][e.id] = false
                    end
                end)
                row:Show()
                y = y - 20
            end
        end
    end

    -- The list is the tallest thing on the page as often as not, so the page's
    -- scroll range has to grow with it -- including when you fold an expansion
    -- and it suddenly shrinks under the scroll offset you were sitting at.
    list:SetHeight(math.max(1, -y + 8))
    if Options.UpdateHeight then Options.UpdateHeight() end
end

-- ---- the page ---------------------------------------------------------------

local CONTENT_W  = 660    -- the width the three columns were drawn for
local SLIDER_LEAD = 14    -- headroom for a slider's title, which sits above its frame

local function buildPanel()
    if panel then return panel end

    panel = CreateFrame("Frame", "EyesUpOptionsPanel", UIParent)
    panel:SetSize(CONTENT_W, 460)   -- a placeholder; Settings stretches us to its canvas
    panel:Hide()
    panel.name = addonName    -- a legacy field some containers still read

    -- ---- the page scrolls ---------------------------------------------------
    --
    -- Settings hands us a canvas of ITS choosing, not ours, and the middle column
    -- is taller than that canvas on most resolutions. Laid out flat, the bottom
    -- sliders simply fell off the end of the page with no way to reach them. So
    -- everything below lives on a scroll child of a fixed height we compute, and
    -- the canvas becomes a window onto it.
    --
    -- The scrollbar is hand-built for the same reason everything else here is:
    -- it's a plain Slider with a colored thumb, which is a dozen lines and can't
    -- be broken by a patch rearranging a template.
    local scroll = CreateFrame("ScrollFrame", nil, panel)
    scroll:SetPoint("TOPLEFT", 0, 0)
    scroll:SetPoint("BOTTOMRIGHT", -16, 0)

    local bar = CreateFrame("Slider", nil, panel)
    bar:SetOrientation("VERTICAL")
    bar:SetWidth(8)
    bar:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -4, -8)
    bar:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -4, 8)
    bar:SetMinMaxValues(0, 0)
    bar:SetValueStep(1)
    bar:SetObeyStepOnDrag(true)
    bar:SetValue(0)

    local track = bar:CreateTexture(nil, "BACKGROUND")
    track:SetAllPoints(bar)
    track:SetColorTexture(1, 1, 1, 0.05)

    bar:SetThumbTexture("Interface\\Buttons\\WHITE8X8")
    local thumb = bar:GetThumbTexture()
    thumb:SetSize(8, 40)
    thumb:SetColorTexture(0.6, 0.6, 0.6, 0.7)

    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(CONTENT_W, 460)
    scroll:SetScrollChild(content)

    bar:SetScript("OnValueChanged", function(_, v) scroll:SetVerticalScroll(v) end)

    -- Wheel over anything on the page scrolls the page. The Slider clamps the
    -- value for us, so there's no range check to get wrong here.
    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", function(_, delta)
        bar:SetValue(bar:GetValue() - delta * 40)
    end)

    -- Called whenever the canvas resizes or the filter list grows or shrinks.
    -- Scroll offset is re-clamped by SetValue, so folding an expansion while
    -- scrolled to the bottom lands you at the new bottom rather than in blank space.
    function Options.UpdateScroll()
        local range = math.max(0, content:GetHeight() - scroll:GetHeight())
        bar:SetMinMaxValues(0, range)
        bar:SetShown(range > 0)
        bar:SetValue(math.min(bar:GetValue(), range))
        scroll:SetVerticalScroll(bar:GetValue())
    end
    scroll:SetScript("OnSizeChanged", function() Options.UpdateScroll() end)

    local title = content:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("Eyes Up")

    local subtitle = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -4)
    subtitle:SetText("Watch the world, not the minimap.  |cff888888/eu demo|r to see it work.")

    local controls = {}

    -- ---- column 1: what to show ---------------------------------------------
    local L = CreateFrame("Frame", nil, content)
    L:SetPoint("TOPLEFT", 16, -60)
    L:SetWidth(220)

    local y = 0
    local function place(c, h, group)
        if c.isSlider then y = y - SLIDER_LEAD end
        c:SetPoint("TOPLEFT", L, "TOPLEFT", 0, y)
        y = y - (h or 26)
        controls[#controls + 1] = c
        if group then group[#group + 1] = c end
    end

    local displayLabel = L:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    displayLabel:SetPoint("TOPLEFT", L, "TOPLEFT", 0, y)
    displayLabel:SetText("Display")
    y = y - 20

    -- ---------------------------------------------------------------------
    -- The one setting that decides what this addon IS.
    --
    -- This used to be the cue/radar/both switch. The radar is gone from here --
    -- it was a choice between two ways of DRAWING, which nobody needed to make,
    -- while the choice that actually matters wasn't on the page at all.
    --
    -- That choice is whether the addon is allowed to tell you about things it
    -- isn't sure are there. Off, and every cue is real. On, and you get much more
    -- warning, most of which is wrong. There is no third answer -- that's the
    -- shape of the game's API, not a design we picked. See Live.lua.
    --
    -- (The radar still exists: /eu mode radar. It just isn't a decision worth
    -- putting in front of someone.)
    -- ---------------------------------------------------------------------
    place(makeCheck(L, "Show guesses",
        function() return NS.db.showGuesses end,
        function(v) NS.db.showGuesses = v end))

    local gnote = L:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    gnote:SetPoint("TOPLEFT", L, "TOPLEFT", 6, y)
    gnote:SetWidth(210)
    gnote:SetJustifyH("LEFT")
    gnote:SetText("Off: only nodes that are really there. Never wrong, "
                .. "but only reaches ~15-25 yd.\n"
                .. "On: also points at places a node has BEEN, out to your full "
                .. "range. Most of those won't be there. They draw faint and "
                .. "never make a sound.")
    y = y - 62

    y = y - 4
    place(makeCheck(L, "Enabled",
        function() return NS.db.enabled end,
        function(v) NS.db.enabled = v end))
    place(makeCheck(L, "Lock position (uncheck to drag)",
        function() return NS.db.locked end,
        function(v) NS.db.locked = v end))
    place(makeCheck(L, "Remember nodes as I gather",
        function() return NS.db.recordGathers end,
        function(v) NS.db.recordGathers = v end))

    y = y - 6
    place(makeCheck(L, "Direction arrow",
        function() return NS.db.cueShowArrow end,
        function(v) NS.db.cueShowArrow = v end), 26, cueOnly)
    place(makeCheck(L, "Square icon",
        function() return NS.db.cueSquareIcon end,
        function(v) NS.db.cueSquareIcon = v end), 26, cueOnly)
    place(makeCheck(L, "Color border by node type",
        function() return NS.db.cueBorderTypeColor end,
        function(v) NS.db.cueBorderTypeColor = v end), 26, cueOnly)
    -- Real item art, or your own generic pack. See NS.CustomGlyph for where the
    -- files go -- and note WoW gives us no way to check they're actually there,
    -- so if you turn this on and get blank squares, that's the missing file
    -- talking.
    place(makeCheck(L, "Use my own icons (Textures/)",
        function() return (NS.db.iconStyle or "item") == "custom" end,
        function(v) NS.db.iconStyle = v and "custom" or "item" end), 26, cueOnly)

    y = y - 6
    local soundLabel = L:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    soundLabel:SetPoint("TOPLEFT", L, "TOPLEFT", 0, y)
    soundLabel:SetText("Sound")
    y = y - 20

    place(makeCheck(L, "Tick when something new turns up",
        function() return NS.db.soundEnabled end,
        function(v) NS.db.soundEnabled = v end))
    place(makeSlider(L, "Tick cooldown (sec)", 1, 30, 1,
        function() return NS.db.soundCooldown end,
        function(v) NS.db.soundCooldown = v end, "%.0f"), 44)

    -- ---- column 2: what it looks like ---------------------------------------
    local M = CreateFrame("Frame", nil, content)
    M:SetPoint("TOPLEFT", 250, -60)
    M:SetWidth(200)

    local my = 0
    local function placeM(c, h, group)
        if c.isSlider then my = my - SLIDER_LEAD end
        c:SetPoint("TOPLEFT", M, "TOPLEFT", 0, my)
        my = my - (h or 26)
        controls[#controls + 1] = c
        if group then group[#group + 1] = c end
    end

    local typesLabel = M:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    typesLabel:SetPoint("TOPLEFT", M, "TOPLEFT", 0, my)
    typesLabel:SetText("Node types")
    my = my - 16

    local typesHint = M:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    typesHint:SetPoint("TOPLEFT", M, "TOPLEFT", 0, my)
    typesHint:SetText("show / color / priority")
    my = my - 18

    -- On/off, a color, and how much you care.
    --
    -- The color isn't decoration: it's the radar's blip, the cue's fallback glyph,
    -- and the cue's border, all at once. The priority isn't a filter: it's the
    -- thumb on the scale when two things are in range and only one can have the
    -- icon (see NS.Priority).
    for _, nType in ipairs(NS.NodeTypeOrder) do
        local rowY = my
        placeM(makeCheck(M, NS.NodeTypeLabel[nType],
            function() return NS.db.typeEnabled[nType] end,
            function(v) NS.db.typeEnabled[nType] = v end))

        local sw = makeColorSwatch(M, nType)
        sw:SetPoint("TOPLEFT", M, "TOPLEFT", 122, rowY - 4)
        controls[#controls + 1] = sw

        local pr = makePriority(M, nType)
        pr:SetPoint("TOPLEFT", M, "TOPLEFT", 144, rowY - 4)
        controls[#controls + 1] = pr
    end

    my = my - 6
    local resetColors = CreateFrame("Button", nil, M, "UIPanelButtonTemplate")
    resetColors:SetSize(120, 20)
    resetColors:SetPoint("TOPLEFT", M, "TOPLEFT", 0, my)
    resetColors:SetText("Reset colors")
    resetColors:SetScript("OnClick", function()
        for t, c in pairs(NS.NodeTypeColor) do
            NS.db.typeColor[t] = { c[1], c[2], c[3] }
        end
        Options.SyncLayout()
        Options.Refresh()
    end)
    my = my - 34

    -- One is the default and the point of the addon. Two or three is for farming
    -- loops, when a bit of peripheral awareness earns its keep. Note the focus
    -- lock overrides this: get close to something and it's the only thing shown,
    -- whatever number you picked.
    placeM(makeSlider(M, "Icons at once", 1, 3, 1,
        function() return NS.db.cueCount end,
        function(v) NS.db.cueCount = v end, "%.0f"), 44, cueOnly)
    placeM(makeSlider(M, "Cue size (px)", 20, 80, 2,
        function() return NS.db.cueSize end,
        function(v) NS.db.cueSize = v end, "%.0f"), 44, cueOnly)
    placeM(makeSlider(M, "Border thickness", 0, 6, 1,
        function() return NS.db.cueBorderSize end,
        function(v) NS.db.cueBorderSize = v end, "%.0fpx"), 44, cueOnly)
    placeM(makeSlider(M, "Active opacity", 0, 1, 0.01,
        function() return NS.db.activeAlpha end,
        function(v) NS.db.activeAlpha = v end), 44)
    -- One pair of sliders, in yards, always. There used to be two pairs and a fork
    -- on NS.HasHBD -- a "zone %" slider for players without HereBeDragons, because
    -- the addon didn't know how big a zone was. It does now (Data.MapSize), so a
    -- yard is a yard for everyone and the fork is gone.
    placeM(makeSlider(M, "Detection (yards)", 20, 200, 5,
        function() return NS.db.detectionYards end,
        function(v) NS.db.detectionYards = v end, "%.0f"), 44)
    placeM(makeSlider(M, "Focus lock (yards)", 0, 60, 5,
        function() return NS.db.focusYards end,
        function(v) NS.db.focusYards = v end, "%.0f"), 44, cueOnly)

    -- How long a node you picked stays quiet, and how faint the nodes we're only
    -- guessing about are drawn. NS.defaults explains why both of these exist.
    placeM(makeSlider(M, "Hush gathered for (min)", 0, 30, 1,
        function() return NS.db.respawnMinutes end,
        function(v) NS.db.respawnMinutes = v end, "%.0f"), 44)
    placeM(makeSlider(M, "Unconfirmed opacity", 0.2, 1, 0.05,
        function() return NS.db.unconfirmedAlpha end,
        function(v) NS.db.unconfirmedAlpha = v end), 44)

    Options.controls = controls

    -- The columns are the only things that know how tall they ended up, so they
    -- say so here rather than us guessing a page height and getting it wrong the
    -- next time a slider is added.
    L:SetHeight(math.max(1, -y))
    M:SetHeight(math.max(1, -my))

    local hint = content:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("TOPLEFT", L, "BOTTOMLEFT", 0, -12)
    hint:SetText("Distances are true yards. For scale, your minimap shows about 100.")

    -- ---- column 3: the things you've found ----------------------------------
    local Rlabel = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    Rlabel:SetPoint("TOPLEFT", 470, -62)
    Rlabel:SetText("Node filters")

    local list = CreateFrame("Frame", nil, content)
    list:SetPoint("TOPLEFT", 470, -80)
    list:SetSize(170, 1)      -- rebuildNodeList grows it
    Options.list = list

    -- The page is as tall as its tallest column. The list moves, so this is
    -- recomputed on every rebuild rather than measured once.
    local staticH = math.max(60 + (-y) + 34, 60 + (-my))
    function Options.UpdateHeight()
        local h = math.max(staticH, 80 + list:GetHeight())
        content:SetHeight(h + 20)
        Options.UpdateScroll()
    end

    -- Repaint whenever Settings shows us. We write every setting through the
    -- moment it's touched, so commit and default have nothing left to do.
    panel:SetScript("OnShow", function() Options.Refresh() end)
    panel.OnRefresh = function() Options.Refresh() end
    panel.OnCommit  = function() end
    panel.OnDefault = function() end

    return panel
end

-- ---- getting listed in the Settings menu ------------------------------------

-- Called once from Core at PLAYER_LOGIN -- not lazily -- so the page is in the
-- list before anyone goes looking for it.
function Options.Init()
    if NS.settingsCategory then return end

    local p = buildPanel()

    if not (Settings and Settings.RegisterCanvasLayoutCategory
            and Settings.RegisterAddOnCategory) then
        -- No Settings API? Then we simply have no options page. We do not
        -- explode at load. Every Settings.* call in this file is guarded for
        -- exactly this reason.
        Options.unavailable = true
        return
    end

    local category = Settings.RegisterCanvasLayoutCategory(p, "Eyes Up")
    Settings.RegisterAddOnCategory(category)

    NS.settingsCategory   = category
    -- 12.0 stopped letting us set category.ID ourselves, so read it back.
    NS.settingsCategoryID = (category.GetID and category:GetID()) or category.ID
end

-- Open Escape → Options → AddOns → Eyes Up.
function Options.Open()
    if Options.unavailable or not NS.settingsCategoryID then
        NS.Print("this client has no Settings API, so there's no options page. Sorry.")
        return
    end
    if InCombatLockdown() then
        NS.Print("not in combat. Options can wait; that thing hitting you can't.")
        return
    end
    if C_SettingsUtil and C_SettingsUtil.OpenSettingsPanel then
        C_SettingsUtil.OpenSettingsPanel(NS.settingsCategoryID)   -- 12.0+
    elseif Settings and Settings.OpenToCategory then
        Settings.OpenToCategory(NS.settingsCategoryID)            -- 10.0–11.x
    end
end

-- Settings owns show/hide, so there's no window of ours to toggle. Kept as an
-- alias so old habits keep working.
Options.Toggle = Options.Open

function Options.Refresh()
    if not panel or not NS.db then return end
    for _, c in ipairs(Options.controls or {}) do
        if c.Refresh then c.Refresh() end
    end

    -- There used to be mode-based greying here -- radar controls dimmed in cue
    -- mode and vice versa. The radar isn't on this page any more, so every control
    -- that remains applies to the only thing we draw, and nothing needs dimming.
    -- (The `cueOnly` group is kept so the sliders still get their SLIDER_LEAD
    -- headroom from the layout code; it just no longer means "sometimes off".)

    rebuildNodeList(Options.list)
end
