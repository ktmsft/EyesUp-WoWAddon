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

-- A dropdown: a button showing the current choice, opening a radio menu on click.
--
-- Built on MenuUtil (the modern menu system, stable since 11.0) rather than the
-- old UIDropDownMenu -- one call, a proper popup, and the button's text always
-- mirrors the selection. `options` is { {value=, label=}, ... }.
local function makeDropdown(parent, width, options, getter, setter)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(width or 190, 22)

    local function labelFor()
        local cur = getter()
        for _, o in ipairs(options) do if o.value == cur then return o.label end end
        return options[1] and options[1].label or "?"
    end

    b:SetText(labelFor())
    b.Refresh = function() b:SetText(labelFor()) end

    b:SetScript("OnClick", function()
        if not MenuUtil then return end
        MenuUtil.CreateContextMenu(b, function(_, root)
            for _, o in ipairs(options) do
                root:CreateRadio(o.label,
                    function() return getter() == o.value end,
                    function() setter(o.value); b:SetText(labelFor()) end)
            end
        end)
    end)

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

-- ---- the list of everything you can filter ----------------------------------
--
-- Grouped into TYPES -- Herbs, Mining, Lumber, Fishing, Treasure -- because that's
-- the axis you actually filter along ("stop telling me about fish"), and because a
-- node's type is the one thing about it that is always known and can never be
-- wrong. Fold the types you don't care about and the wall of names goes away.
--
-- Every species comes from NS.Species (Species.lua) -- the whole game, written
-- down -- so the list can never come up empty the way a "only what you've seen"
-- list can. Within a type, newest expansion first (s.expac), then alphabetical.

local headerPool, rowPool = {}, {}

-- Expansion index -> display name, for the second level of the filter tree.
local function expacName(e)
    if e == nil or e < 0 then return "Other" end
    if e == 0 then return "Classic" end
    return _G["EXPANSION_NAME" .. e] or ("Expansion " .. tostring(e))
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

    -- A TWO-LEVEL tree: TYPE (Herbs, Mining, ...) and inside each, EXPANSION.
    -- Both fold, so you can drill "Herbs > Midnight" and see just those, and
    -- filter along either axis. Everything comes from NS.Species (the whole game,
    -- written down), so the list can never come up empty.
    local hIdx, rIdx, y = 0, 0, -4

    -- A collapsible header at indent x with the fold caret already prepended.
    local function header(text, x, collapsed, onToggle)
        hIdx = hIdx + 1
        local h = getHeader(list, hIdx)
        h:ClearAllPoints()
        h:SetPoint("TOPLEFT", list, "TOPLEFT", x, y)
        h.text:SetText((collapsed and "|cffffd100+|r " or "|cffffd100-|r ") .. text)
        h:SetScript("OnClick", onToggle)
        h:Show()
        y = y - 18
    end

    for _, nType in ipairs(NS.NodeTypeOrder) do
        local species = NS.Species[nType]
        if species and next(species) then
            -- Bucket this type's species by expansion.
            local byExpac, expacs, total = {}, {}, 0
            for id, s in pairs(species) do
                local e = s.expac or -1
                local b = byExpac[e]
                if not b then b = {}; byExpac[e] = b; expacs[#expacs + 1] = e end
                b[#b + 1] = { id = id, name = s.name }
                total = total + 1
            end
            table.sort(expacs, function(a, b) return a > b end)   -- newest first

            local tKey = nType
            local tCollapsed = db.filterCollapsed[tKey]
            if tCollapsed == nil then tCollapsed = true end

            local c = NS.TypeColor(nType)
            header(("|cff%02x%02x%02x%s|r |cff888888(%d)|r"):format(
                math.floor(c[1] * 255), math.floor(c[2] * 255), math.floor(c[3] * 255),
                NS.NodeTypeLabel[nType] or nType, total),
                0, tCollapsed,
                function() db.filterCollapsed[tKey] = not tCollapsed; rebuildNodeList(list) end)

            if not tCollapsed then
                for _, e in ipairs(expacs) do
                    local entries = byExpac[e]
                    table.sort(entries, function(a, b) return (a.name or "") < (b.name or "") end)

                    local eKey = nType .. ":" .. e
                    local eCollapsed = db.filterCollapsed[eKey]
                    if eCollapsed == nil then eCollapsed = true end

                    header(("%s |cff888888(%d)|r"):format(expacName(e), #entries),
                        14, eCollapsed,
                        function() db.filterCollapsed[eKey] = not eCollapsed; rebuildNodeList(list) end)

                    if not eCollapsed then
                        for _, sp in ipairs(entries) do
                            rIdx = rIdx + 1
                            local row = getRow(list, rIdx)
                            row:ClearAllPoints()
                            row:SetPoint("TOPLEFT", list, "TOPLEFT", 26, y)
                            row.text:SetText(sp.name or ("id " .. tostring(sp.id)))
                            row.dot:SetColorTexture(c[1], c[2], c[3], 1)

                            -- Checked = "tell me". Unchecked = "I know, don't care."
                            row.cb:SetChecked(db.nodeFilter[nType][sp.id] ~= false)
                            row.cb:SetScript("OnClick", function(self)
                                db.nodeFilter[nType][sp.id] = self:GetChecked() and nil or false
                            end)
                            row:Show()
                            y = y - 20
                        end
                    end
                end
            end
        end
    end

    -- The list is the tallest thing on the page as often as not, so the page's
    -- scroll range has to grow with it -- including when you fold an expansion
    -- and it suddenly shrinks under the scroll offset you were sitting at.
    list:SetHeight(math.max(1, -y + 8))
    if Options.UpdateHeight then Options.UpdateHeight() end
end

-- ---- the HUD's "what to track" list -----------------------------------------
--
-- Every minimap tracking type the client offers, live (NS.Hud.ListTracking), as a
-- grid of checkboxes. Gathering up front; everything else -- mailbox, auctioneer,
-- quest markers, the lot -- folded behind an expander, because that list is long
-- and you rarely want any of it on a gathering HUD. Rebuilt on demand so the
-- expander can reflow, exactly like the node filter list.
local trackCBPool = {}

local function getTrackCB(parent, i)
    local cb = trackCBPool[i]
    if not cb then
        cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
        cb:SetSize(22, 22)
        cb.label = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        cb.label:SetPoint("LEFT", cb, "RIGHT", 2, 0)
        trackCBPool[i] = cb
    end
    return cb
end

function Options.rebuildTrackList()
    local container = Options.hudTrackList
    if not (container and NS.db and NS.Hud) then return end

    for _, cb in ipairs(trackCBPool) do cb:Hide() end

    local db = NS.db
    local gather, other = {}, {}
    for _, t in ipairs(NS.Hud.ListTracking()) do
        if t.cat then gather[#gather + 1] = t else other[#other + 1] = t end
    end

    local COLW, ROWH = 300, 24
    local idx, y, col = 0, 0, 0
    local function checkbox(t)
        idx = idx + 1
        local cb = getTrackCB(container, idx)
        cb:ClearAllPoints()
        cb:SetPoint("TOPLEFT", container, "TOPLEFT", col * COLW, y)
        cb.label:SetText(t.name)
        cb:SetChecked(NS.Hud.TrackWanted(t.key, t.cat) and true or false)
        cb:SetScript("OnClick", function(self)
            NS.Hud.SetTrackWanted(t.key, self:GetChecked())
        end)
        cb:Show()
        col = col + 1
        if col > 1 then col = 0; y = y - ROWH end
    end

    for _, t in ipairs(gather) do checkbox(t) end
    if col ~= 0 then col = 0; y = y - ROWH end        -- finish the row

    if #other > 0 then
        local ex = Options.hudExpander
        if not ex then
            ex = CreateFrame("Button", nil, container)
            ex:SetSize(300, 18)
            ex.text = ex:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            ex.text:SetPoint("LEFT", 2, 0)
            ex:SetHighlightFontObject("GameFontHighlightSmall")
            Options.hudExpander = ex
        end
        ex:SetParent(container)
        ex:ClearAllPoints()
        ex:SetPoint("TOPLEFT", container, "TOPLEFT", 0, y)
        local expanded = db.hudTrackExpanded
        ex.text:SetText((expanded and "|cffffd100-|r " or "|cffffd100+|r ")
            .. "|cff888888Everything else (" .. #other .. ")|r")
        ex:SetScript("OnClick", function()
            db.hudTrackExpanded = not db.hudTrackExpanded
            Options.rebuildTrackList()
        end)
        ex:Show()
        y = y - 22

        if expanded then
            for _, t in ipairs(other) do checkbox(t) end
            if col ~= 0 then col = 0; y = y - ROWH end
        end
    elseif Options.hudExpander then
        Options.hudExpander:Hide()
    end

    container:SetHeight(math.max(1, -y))
    if Options.hudContent then
        Options.hudContent:SetHeight((Options.hudTrackTop or 300) + math.max(1, -y) + 30)
        if Options.hudUpdateScroll then Options.hudUpdateScroll() end
    end
end

-- ---- the page ---------------------------------------------------------------

local CONTENT_W  = 660    -- the width the three columns were drawn for
local SLIDER_LEAD = 14    -- headroom for a slider's title, which sits above its frame

-- Every control across BOTH pages lives here, so Refresh can repaint them all in
-- one pass no matter which page they're on.
local controls = {}

-- ---------------------------------------------------------------------------
-- One scrollable page, built by hand.
--
-- Settings hands us a canvas of ITS choosing, and our columns are often taller
-- than it -- so each page is a scroll child of a height we compute, and the canvas
-- is a window onto it. The scrollbar is a plain Slider with a colored thumb: a
-- dozen lines that no patch can break by rearranging a template.
--
-- Returns the panel and its content frame. Each panel carries its own UpdateScroll.
-- ---------------------------------------------------------------------------
local function makeScrollPage(frameName, subtitleText)
    local p = CreateFrame("Frame", frameName, UIParent)
    p:SetSize(CONTENT_W, 460)   -- placeholder; Settings stretches us to its canvas
    p:Hide()
    p.name = frameName

    local scroll = CreateFrame("ScrollFrame", nil, p)
    scroll:SetPoint("TOPLEFT", 0, 0)
    scroll:SetPoint("BOTTOMRIGHT", -16, 0)

    local bar = CreateFrame("Slider", nil, p)
    bar:SetOrientation("VERTICAL")
    bar:SetWidth(8)
    bar:SetPoint("TOPRIGHT", p, "TOPRIGHT", -4, -8)
    bar:SetPoint("BOTTOMRIGHT", p, "BOTTOMRIGHT", -4, 8)
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
    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", function(_, delta)
        bar:SetValue(bar:GetValue() - delta * 40)
    end)

    function p.UpdateScroll()
        local range = math.max(0, content:GetHeight() - scroll:GetHeight())
        bar:SetMinMaxValues(0, range)
        bar:SetShown(range > 0)
        bar:SetValue(math.min(bar:GetValue(), range))
        scroll:SetVerticalScroll(bar:GetValue())
    end
    scroll:SetScript("OnSizeChanged", function() p.UpdateScroll() end)

    local title = content:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("Eyes Up")

    local subtitle = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -4)
    subtitle:SetText(subtitleText or "Watch the world, not the minimap.")

    p.content = content
    return p, content
end

-- ===========================================================================
-- PAGE 1: the heads-up display. The flagship, so it's the page you land on.
-- ===========================================================================
local function buildHudPage()
    local p, content = makeScrollPage("EyesUpOptionsHUD",
        "Your minimap's own tracking blips, moved to the middle of the screen.")

    -- Two columns: what the HUD DOES (left), and what it TRACKS plus its dials
    -- (right). Every knob lives here now -- nothing hides behind a slash command.

    -- ---- left column: behaviour, each with a line of why ----
    local L = CreateFrame("Frame", nil, content)
    L:SetPoint("TOPLEFT", 16, -60)
    L:SetWidth(300)

    local ly = 0
    local function placeL(c, h)
        if c.isSlider then ly = ly - SLIDER_LEAD end
        c:SetPoint("TOPLEFT", L, "TOPLEFT", 0, ly)
        ly = ly - (h or 26)
        controls[#controls + 1] = c
    end
    local function noteL(text, gap, indent)
        local fs = L:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        fs:SetPoint("TOPLEFT", L, "TOPLEFT", indent or 6, ly)
        fs:SetWidth(290 - (indent or 6))
        fs:SetJustifyH("LEFT")
        fs:SetText(text)
        ly = ly - (gap or 30)
    end

    placeL(makeCheck(L, "Blips in the middle of my screen",
        function() return NS.db.hudEnabled end,
        function(v) NS.Hud.SetEnabled(v) end))
    noteL("The game's own tracking blips, live and exact, where you're looking. "
        .. "Costs the corner minimap while it's up (a map goes there instead).", 44)

    placeL(makeCheck(L, "Rotate to my facing", function() return NS.db.hudRotate end,
        function(v) NS.db.hudRotate = v; NS.Hud.ApplyLook() end))
    noteL("Up becomes the way you're facing, so a blip above centre is straight "
        .. "ahead -- no compass to read in your head.", 34)

    placeL(makeCheck(L, "Step aside in cities", function() return NS.db.hudHideInCity end,
        function(v) NS.db.hudHideInCity = v; NS.Hud.Refresh() end))
    noteL("Cities and inns are full of mailboxes and quest markers the game won't "
        .. "let us hide -- and you're not gathering there anyway. So the HUD folds "
        .. "away while you're resting and comes back when you ride out.", 54)

    placeL(makeCheck(L, "Step aside in dungeons & raids",
        function() return NS.db.hudHideInDungeons end,
        function(v) NS.db.hudHideInDungeons = v; NS.Hud.Refresh() end))
    noteL("Folds away in dungeons and raids, so you're not chasing flowers mid-pull. "
        .. "Delves and ritual sites keep the HUD.", 34)

    placeL(makeCheck(L, "Map in the corner", function() return NS.db.cornerMap end,
        function(v)
            NS.db.cornerMap = v
            if NS.Hud.IsActive() then
                if v then NS.Corner.Enable() else NS.Corner.Disable() end
            end
        end))
    noteL("Puts a real map -- roads, your position -- where the minimap used to be, "
        .. "since the blips have taken its old spot.", 40)

    placeL(makeCheck(L, "Blip tooltips on hover",
        function() return NS.db.hudTooltips end,
        function(v) NS.db.hudTooltips = v; NS.Hud.ApplyLook() end))
    noteL("Hover a blip to read its name, like the old corner minimap. The catch: the "
        .. "HUD then hogs the mouse over its whole circle, so you can't click the "
        .. "world through it.", 44)

    placeL(makeCheck(L, "Share settings across all my characters",
        function() return NS.SettingsAreShared and NS.SettingsAreShared() end,
        function(v) if NS.SetSettingsShared then NS.SetSettingsShared(v) end end))
    noteL("On: all your characters share one set of settings and one pile of "
        .. "gathered nodes. Off: each keeps its own. Flipping this copies what "
        .. "you've got across first -- nothing's lost -- then reloads.", 48)

    -- ---- right column: what to track, and the dials ----
    local R = CreateFrame("Frame", nil, content)
    R:SetPoint("TOPLEFT", 336, -60)
    R:SetWidth(300)

    local ry = 0
    local function placeR(c, h, indent)
        if c.isSlider then ry = ry - SLIDER_LEAD end
        c:SetPoint("TOPLEFT", R, "TOPLEFT", indent or 0, ry)
        ry = ry - (h or 26)
        controls[#controls + 1] = c
    end
    local function noteR(text, gap)
        local fs = R:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        fs:SetPoint("TOPLEFT", R, "TOPLEFT", 6, ry)
        fs:SetWidth(284)
        fs:SetJustifyH("LEFT")
        fs:SetText(text)
        ry = ry - (gap or 30)
    end
    local function headerR(text)
        local fs = R:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        fs:SetPoint("TOPLEFT", R, "TOPLEFT", 0, ry)
        fs:SetText(text)
        ry = ry - 18
    end

    headerR("Size & feel")
    placeR(makeSlider(R, "HUD size (px)", 150, 600, 10,
        function() return NS.db.hudSize end,
        function(v) NS.db.hudSize = v; NS.Hud.ApplyLook() end, "%.0f"), 44)
    placeR(makeSlider(R, "Zoom (0 = widest, furthest)", 0, 6, 1,
        function() return NS.db.hudZoom end,
        function(v) NS.db.hudZoom = v; NS.Hud.ApplyLook() end, "%.0f"), 44)
    placeR(makeSlider(R, "Blip opacity", 0.2, 1, 0.05,
        function() return NS.db.hudAlpha end,
        function(v) NS.db.hudAlpha = v; NS.Hud.ApplyLook() end), 44)
    placeR(makeSlider(R, "Range ring opacity", 0, 1, 0.05,
        function() return NS.db.hudRingAlpha end,
        function(v) NS.db.hudRingAlpha = v; NS.Hud.ApplyLook() end), 44)
    placeR(makeSlider(R, "Corner map zoom", 0.2, 1, 0.05,
        function() return NS.db.cornerZoom end,
        function(v) NS.db.cornerZoom = v; if NS.Corner then NS.Corner.ApplyLook() end end), 44)

    placeR(makeCheck(R, "Soft edge (fade at the rim)",
        function() return NS.db.hudMask == "vignette" end,
        function(v) NS.db.hudMask = v and "vignette" or "clear"; NS.Hud.ApplyLook() end))

    L:SetHeight(math.max(1, -ly))
    R:SetHeight(math.max(1, -ry))
    local colBottom = 60 + math.max(-ly, -ry)   -- 60 = the columns' top offset

    -- ---- full width, below the columns: WHAT TO TRACK -----------------------
    -- The whole minimap tracking list, live. Master toggle, then a grid of every
    -- type; gathering shown, the rest folded. It's here at the bottom (not in a
    -- column) so the expander can grow the page without shoving anything sideways.
    local tTop = colBottom + 22

    local tHeader = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    tHeader:SetPoint("TOPLEFT", 16, -tTop)
    tHeader:SetText("What to track")

    local master = makeCheck(content, "Let Eyes Up choose what my minimap tracks",
        function() return NS.db.hudManageTracking end,
        function(v)
            NS.db.hudManageTracking = v
            if NS.Hud.IsActive() then NS.Hud.Disable(); NS.Hud.Enable() end
        end)
    master:SetPoint("TOPLEFT", 16, -(tTop + 20))
    controls[#controls + 1] = master

    local mnote = content:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    mnote:SetPoint("TOPLEFT", 22, -(tTop + 44))
    mnote:SetWidth(600)
    mnote:SetJustifyH("LEFT")
    mnote:SetText("While the HUD is up, these win over your minimap tracking -- ticked "
        .. "shows, unticked hides, even the mailboxes and quest markers. Everything but "
        .. "gathering starts off.")

    local trackList = CreateFrame("Frame", nil, content)
    trackList:SetPoint("TOPLEFT", 16, -(tTop + 68))
    trackList:SetSize(620, 1)      -- rebuildTrackList grows it

    Options.hudTrackList    = trackList
    Options.hudTrackTop     = tTop + 68
    Options.hudContent      = content
    Options.hudUpdateScroll = p.UpdateScroll

    Options.rebuildTrackList()

    -- Repaint this page's controls to current state whenever Settings shows it.
    p:SetScript("OnShow", function() Options.Refresh() end)
    p.OnRefresh = function() Options.Refresh() end
    p.OnCommit  = function() end
    p.OnDefault = function() end

    return p
end

-- ===========================================================================
-- PAGE 2: the cue, node types, and filters. A subcategory under the HUD page.
-- ===========================================================================
local function buildCuePage()
    local p, content = makeScrollPage("EyesUpOptionsCue",
        "The center-screen icon, node types, and the filter list.")

    -- What IS the cue, and why does it exist? A short paragraph, because someone
    -- landing here from the HUD page won't know.
    local intro = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    intro:SetPoint("TOPLEFT", 16, -54)
    intro:SetWidth(624)
    intro:SetJustifyH("LEFT")
    intro:SetText(
        "The |cffffd100cue|r is a small icon near the middle of your screen that "
        .. "fades in when a node you care about is within reach, with an arrow at "
        .. "it -- so you keep your eyes on the world, not the minimap. It's the "
        .. "original Eyes Up, and unlike the HUD it doesn't touch your minimap, so "
        .. "you can run either, or both. It reaches only as far as the game will "
        .. "confirm a node is really there (~15-25 yards) unless you turn on "
        .. "guesses.\n\n"
        .. "Below: what it's allowed to mention, how it looks, and -- in the filter "
        .. "list -- exactly which species should bother you.")

    -- ---- column 1: the cue and its sound ------------------------------------
    local L = CreateFrame("Frame", nil, content)
    L:SetPoint("TOPLEFT", 16, -128)
    L:SetWidth(220)

    local y = 0
    local function place(c, h)
        if c.isSlider then y = y - SLIDER_LEAD end
        c:SetPoint("TOPLEFT", L, "TOPLEFT", 0, y)
        y = y - (h or 26)
        controls[#controls + 1] = c
    end

    local displayLabel = L:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    displayLabel:SetPoint("TOPLEFT", L, "TOPLEFT", 0, y)
    displayLabel:SetText("The cue")
    y = y - 20

    -- The one setting that decides what the CUE is: may it point at things it
    -- isn't sure are there? Off, every cue is real (but reaches ~15-25yd). On, you
    -- get more warning, most of it wrong (drawn faint, never a sound). No third
    -- answer -- that's the shape of the API, not a choice. See Live.lua.
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
    place(makeCheck(L, "Show the node's name above the icon",
        function() return NS.db.cueShowName end,
        function(v) NS.db.cueShowName = v end), 26, cueOnly)
    place(makeCheck(L, "Square icon",
        function() return NS.db.cueSquareIcon end,
        function(v) NS.db.cueSquareIcon = v end), 26, cueOnly)
    place(makeCheck(L, "Color border by node type",
        function() return NS.db.cueBorderTypeColor end,
        function(v) NS.db.cueBorderTypeColor = v end), 26, cueOnly)
    -- Icon source: the dropped item, the profession symbol, or your own art. See
    -- Cue.applyIcon. ("My own art" reads from textures/ -- and WoW gives Lua no way
    -- to check a texture loaded, so a blank square there is always the file itself:
    -- missing, misnamed, wrong case, or not a power of two.)
    local iconLbl = L:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    iconLbl:SetPoint("TOPLEFT", L, "TOPLEFT", 0, y)
    iconLbl:SetText("Cue icon shows:")
    y = y - 18
    place(makeDropdown(L, 200, {
        { value = "item",       label = "The item it gives (ore, herb...)" },
        { value = "profession", label = "Profession symbol (pickaxe...)" },
        { value = "custom",     label = "My own art (textures/)" },
    },
        function() return NS.db.iconStyle or "item" end,
        function(v) NS.db.iconStyle = v; Options.SyncLayout() end), 30, cueOnly)

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
    M:SetPoint("TOPLEFT", 250, -128)
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
    placeM(makeSlider(M, "Arrow size", 0.3, 1.2, 0.05,
        function() return NS.db.cueArrowScale end,
        function(v) NS.db.cueArrowScale = v end), 44, cueOnly)
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
    Rlabel:SetPoint("TOPLEFT", 470, -130)
    Rlabel:SetText("Node filters")

    local list = CreateFrame("Frame", nil, content)
    list:SetPoint("TOPLEFT", 470, -148)
    list:SetSize(170, 1)      -- rebuildNodeList grows it
    Options.list = list

    -- The filter list lives on THIS page, so its scroll bookkeeping points here.
    -- The page is as tall as its tallest column; the list moves, so recompute on
    -- every rebuild rather than measuring once. (128 = where the columns start,
    -- below the title, subtitle and the intro paragraph.)
    local COL_TOP = 128
    local staticH = math.max(COL_TOP + (-y) + 34, COL_TOP + (-my))
    function Options.UpdateHeight()
        local h = math.max(staticH, COL_TOP + 20 + list:GetHeight())
        content:SetHeight(h + 20)
        p.UpdateScroll()
    end

    -- Repaint whenever Settings shows us. We write every setting through the
    -- moment it's touched, so commit and default have nothing left to do.
    p:SetScript("OnShow", function() Options.Refresh() end)
    p.OnRefresh = function() Options.Refresh() end
    p.OnCommit  = function() end
    p.OnDefault = function() end

    return p
end

-- ---- getting listed in the Settings menu ------------------------------------

-- Called once from Core at PLAYER_LOGIN -- not lazily -- so the page is in the
-- list before anyone goes looking for it.
function Options.Init()
    if NS.settingsCategory then return end

    -- Two pages. Build the cue page FIRST -- it owns Options.list and
    -- Options.UpdateHeight, which Refresh needs whichever page is showing.
    local cuePage = buildCuePage()
    local hudPage = buildHudPage()

    if not (Settings and Settings.RegisterCanvasLayoutCategory
            and Settings.RegisterAddOnCategory) then
        -- No Settings API? Then we simply have no options page. We do not
        -- explode at load. Every Settings.* call in this file is guarded for
        -- exactly this reason.
        Options.unavailable = true
        return
    end

    -- The HUD is the flagship, so it's the page you land on. The cue and its
    -- filters hang off it as a subcategory -- one click away, clearly labelled,
    -- and no longer jumbled together with the HUD settings on one confusing page.
    local category = Settings.RegisterCanvasLayoutCategory(hudPage, "Eyes Up")
    Settings.RegisterAddOnCategory(category)

    if Settings.RegisterCanvasLayoutSubcategory then
        Settings.RegisterCanvasLayoutSubcategory(category, cuePage, "Cue & filters")
    end

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
    if not NS.db then return end
    -- One shared list holds every control across both pages, so this repaints them
    -- all -- whichever page happens to be open.
    for _, c in ipairs(controls) do
        if c.Refresh then c.Refresh() end
    end
    rebuildNodeList(Options.list)
    if Options.rebuildTrackList then Options.rebuildTrackList() end
end
