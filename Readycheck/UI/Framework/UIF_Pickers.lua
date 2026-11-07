local pairs, ipairs, type, tostring, tonumber = pairs, ipairs, type, tostring, tonumber
local math_floor, math_max, math_min, math_abs = math.floor, math.max, math.min, math.abs
local string_format = string.format
local CreateFrame = CreateFrame
local C_Timer = C_Timer

------------------------------------------------------------------------
-- Readycheck - UI Framework Pickers
-- The controls for the four styling settings every feature shares, each
-- built from the framework's own widgets and each raising the settings
-- change signal after its `set`:
--   RC.UI:OpenColorPicker(o)              the game's colour wheel, live
--   RC.UI:CreateColorPicker(parent, opts) a colour row bound to get/set
--   RC.UI:CreateFontPicker(parent, opts)  face, size, outline, shadow
--   RC.UI:CreateTexturePicker(parent, opts)  a statusbar texture
--   RC.UI:CreateAnimationPicker(parent, opts) a Motion spec + live demo
--   RC.UI:SetWidgetEnabled(widget, on)    dim a control and stop clicks
--   RC.UI:ColorOf(c, fallback) -> r, g, b, a
-- Sound already has RC.UI:CreateSoundPicker (UIF_Widgets).
--
-- Every picker returns a holder frame with a real height (anchor it by
-- TOPLEFT and advance your y by holder:GetHeight() + a gap) and
-- holder:Refresh() to re-read get() after something else changed the
-- value. `set` always receives a NEW table (font/animation specs), never
-- the one `get` returned, so a defaults table can never be written
-- through.
------------------------------------------------------------------------

local RC = _G.Readycheck
if not RC then return end
RC._uif = RC._uif or {}
local _uif = RC._uif
local BASE, FLAT, CreateProfessionalFontString = _uif.BASE, _uif.FLAT, _uif.CreateProfessionalFontString
local GetTextNormal, GetTextGray, GetAccentGold, GetElementBG = _uif.GetTextNormal, _uif.GetTextGray, _uif.GetAccentGold, _uif.GetElementBG
local NotifySettingChanged, CopyValue = _uif.NotifySettingChanged, _uif.CopyValue

    local LABEL_H = 18

    -- r, g, b, a from {r=,g=,b=,a=}, {1, 0.5, 0, 1} or nil (the fallback).
    function RC.UI:ColorOf(c, fallback)
        if type(c) ~= "table" then c = fallback end
        if type(c) ~= "table" then return 1, 1, 1, 1 end
        local r = c.r or c[1] or 1
        local g = c.g or c[2] or 1
        local b = c.b or c[3] or 1
        local a = c.a or c[4] or 1
        return r, g, b, a
    end

    local function Label(parent, text)
        local fs = CreateProfessionalFontString(parent, "OVERLAY", BASE.FONT_SIZE_SMALL, "OUTLINE")
        fs:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
        fs:SetJustifyH("LEFT")
        fs:SetText(text or "")
        local c = GetTextNormal()
        fs:SetTextColor(c.r, c.g, c.b, 1)
        return fs
    end

    -- The theme refresh (RC:RefreshUIColors walks the page for :Repaint)
    -- recolours a picker's own pieces; its inner widgets repaint themselves.
    local function PaintLabel(holder)
        local c = GetTextNormal()
        holder.label:SetTextColor(c.r, c.g, c.b, 1)
    end

    ------------------------------------------------------------------
    -- Enabled / dimmed
    ------------------------------------------------------------------
    -- Dims a control and lays a mouse-eating cover over it. Works on any
    -- framework widget (sliders and checkboxes are handled through their
    -- container) and on a picker holder.
    function RC.UI:SetWidgetEnabled(widget, on)
        if not widget then return end
        local w = widget.parentFrame or widget
        w:SetAlpha(on and 1 or 0.4)
        if not w._rcBlocker then
            local b = CreateFrame("Frame", nil, w)
            -- a checkbox is placed by its button, not its container: cover
            -- the box and its label
            if widget.Text and widget.GetChecked then
                b:SetPoint("TOPLEFT", widget, "TOPLEFT", -2, 2)
                b:SetPoint("BOTTOMRIGHT", widget.Text, "BOTTOMRIGHT", 2, -2)
            else
                b:SetAllPoints(w)
            end
            b:SetFrameLevel((w:GetFrameLevel() or 1) + 20)
            b:EnableMouse(true)
            w._rcBlocker = b
        end
        if on then w._rcBlocker:Hide() else w._rcBlocker:Show() end
        w._rcDisabled = not on
    end

    ------------------------------------------------------------------
    -- Dependent options: indented under their switch, greyed and
    -- unclickable while it is off
    ------------------------------------------------------------------
    -- RC.UI:BindDependents(parent, children, opts) -> binding
    --   parent    a checkbox, or a function returning on/off
    --   children  what only matters while the parent is on: checkboxes
    --             (or their holders), sliders (or their frames), dropdowns,
    --             pickers, buttons, help lines and labels (font strings)
    --   opts.indent  px each child moves right (default 16; 0 = stays);
    --                a child anchored to another child moves with it, and
    --                a nested binding indents again (grandchildren sit a
    --                step further in: bind the inner switch first)
    --   opts.invert  the children matter while the parent is OFF
    --   opts.when    an extra condition (both must hold)
    -- A child is dimmed (label and control), takes no clicks and no wheel,
    -- and comes back the moment the parent is ticked again: the binding
    -- follows the parent's clicks and every SetChecked on it. Values are
    -- never touched. A child bound to several parents is on only while all
    -- of them are; a switch that is itself a dependent passes its state on,
    -- so a grandchild greys with its grandparent. binding:Refresh() re-reads
    -- a function parent.
    --
    -- RC.UI:MarkCard(card) / RC.UI:CardSince(card, mark): everything a card
    -- gained after the mark (its child frames and its own font strings), so
    -- a page marks right after its switch and binds what it built under it:
    --   local mark = RC.UI:MarkCard(card)
    --   ... the options under the switch ...
    --   RC.UI:BindDependents(enableBox, RC.UI:CardSince(card, mark))
    local DEP_INDENT, DEP_DIM = 16, 0.4

    function RC.UI:MarkCard(card)
        local m = { kids = {}, regs = {} }
        if not card then return m end
        for _, k in ipairs({ card:GetChildren() }) do m.kids[k] = true end
        for _, r in ipairs({ card:GetRegions() }) do m.regs[r] = true end
        return m
    end

    function RC.UI:CardSince(card, mark)
        local out = {}
        if not (card and mark) then return out end
        for _, k in ipairs({ card:GetChildren() }) do
            if not mark.kids[k] and not k._rcLockCover then out[#out + 1] = k end
        end
        for _, r in ipairs({ card:GetRegions() }) do
            if not mark.regs[r] and r.GetObjectType and r:GetObjectType() == "FontString" then out[#out + 1] = r end
        end
        return out
    end

    -- the control a holder stands for (a checkbox's bare holder, a
    -- slider's frame), and the frame that carries its anchors
    local function DepControl(x)
        if type(x) ~= "table" then return nil end
        return x.checkbox or x.slider or x
    end
    local function DepAnchorFrame(x)
        if type(x) ~= "table" then return nil end
        if x.checkbox then return x.checkbox end   -- the holder has no anchors
        return x
    end
    local function IsFontString(x)
        return x.GetObjectType and x:GetObjectType() == "FontString"
    end

    local function DepPaint(w)
        local on = true
        for _, v in pairs(w._rcDepBy or {}) do
            if not v then on = false break end
        end
        local was = w._rcDepOff and true or false
        if IsFontString(w) then
            w:SetAlpha(on and 1 or DEP_DIM)
        else
            RC.UI:SetWidgetEnabled(w, on)
            local holder = w.parentFrame
            if holder then holder:SetAlpha(on and 1 or DEP_DIM) end
            if w.GetChecked and w.Enable and w.Disable then
                if on then w:Enable() else w:Disable() end
            end
            if w.Repaint then pcall(w.Repaint, w) end
        end
        w._rcDepOff = not on
        -- a switch that is itself a dependent passes its state on
        if was ~= w._rcDepOff and w._rcDepBindings then
            for _, b in ipairs(w._rcDepBindings) do b:Refresh() end
        end
    end

    -- move a child right: only its own left-side anchors to something
    -- outside the binding (the card, the switch); one anchored to another
    -- child rides along with it
    local function DepIndent(f, px, members)
        if not f or px == 0 then return end
        local n = f.GetNumPoints and f:GetNumPoints() or 0
        if n == 0 then return end
        local pts, moved = {}, false
        for i = 1, n do
            local p, rel, rp, x, y = f:GetPoint(i)
            pts[i] = { p, rel, rp, x or 0, y or 0 }
            if p and p:find("LEFT") and not (rel and members[rel]) then
                pts[i][4] = (x or 0) + px
                moved = true
            end
        end
        if not moved then return end
        f:ClearAllPoints()
        for _, q in ipairs(pts) do
            if q[2] then f:SetPoint(q[1], q[2], q[3], q[4], q[5]) else f:SetPoint(q[1], q[4], q[5]) end
        end
        f._rcDepIndented = true
        -- a one-line help note is cut again to the width it has left
        if f.Refit then
            local w = f.GetWidth and f:GetWidth() or 0
            if w > px then f:Refit(w - px) end
        end

    end

    function RC.UI:BindDependents(parent, children, opts)
        opts = opts or {}
        local b = { parent = parent, children = {}, invert = opts.invert, when = opts.when }
        if not parent or type(children) ~= "table" then return b end
        local members = {}
        local pHolder = type(parent) == "table" and parent.parentFrame or nil
        for _, x in ipairs(children) do
            if type(x) == "table" and x ~= parent and (pHolder == nil or x ~= pHolder) then

                local w = DepControl(x)
                if w then
                    b.children[#b.children + 1] = w
                    members[x] = true
                    members[w] = true
                    if w.parentFrame then members[w.parentFrame] = true end
                end
            end
        end
        local px = opts.indent
        if px == nil then px = DEP_INDENT end
        for _, x in ipairs(children) do
            if members[x] then
                local f = DepAnchorFrame(x)
                -- a slider is placed by its frame (its own points sit on it)
                if f and f.parentFrame and f.parentFrame.slider == f then f = f.parentFrame end
                DepIndent(f, px, members)
            end
        end

        function b:IsOn()
            local p = self.parent
            local on
            if type(p) == "function" then
                on = p() and true or false
            else
                on = (p.GetChecked and p:GetChecked()) and true or false
                if p._rcDepOff then on = false end
            end
            if self.invert then on = not on end
            if on and self.when then on = self.when() and true or false end
            return on
        end
        function b:Refresh()
            local on = self:IsOn()
            for _, w in ipairs(self.children) do
                w._rcDepBy = w._rcDepBy or {}
                w._rcDepBy[self] = on
                DepPaint(w)
            end
            return on
        end

        if type(parent) == "table" then
            parent._rcDepBindings = parent._rcDepBindings or {}
            parent._rcDepBindings[#parent._rcDepBindings + 1] = b
            if not parent._rcDepHooked then
                parent._rcDepHooked = true
                local function RefreshAll(self)
                    for _, bb in ipairs(self._rcDepBindings or {}) do bb:Refresh() end
                end
                if parent.HookScript then parent:HookScript("PostClick", RefreshAll) end
                local rawSet = parent.SetChecked
                if rawSet then
                    parent.SetChecked = function(self, v, ...)
                        rawSet(self, v, ...)
                        RefreshAll(self)
                    end
                end
            end
        end
        b:Refresh()
        return b
    end

    ------------------------------------------------------------------
    -- The game's colour wheel
    ------------------------------------------------------------------
    -- RC.UI:OpenColorPicker({ r, g, b, a, alpha = true,
    --     onChange = fn(r, g, b, a),   every move while dragging
    --     onCancel = fn(r, g, b, a) }) the values it opened with
    -- Two client generations: the modern dialog takes an options table
    -- and reports alpha; the older one wants fields set before Show and
    -- keeps OPACITY (1 - alpha) on its own slider. Cancel hands back the
    -- values captured here, whatever shape previousValues has.
    function RC.UI:OpenColorPicker(o)
        local CPF = ColorPickerFrame
        if not CPF or type(o) ~= "table" then return false end
        local r0, g0, b0, a0 = o.r or 1, o.g or 1, o.b or 1, o.a or 1
        local withAlpha = o.alpha and true or false
        -- The appearance bridges hook the OK button by pickerType; claim
        -- the dialog so a stale bridge never writes our colour.
        RC.colorPickerInfo = { pickerType = "framework" }
        local function Alpha()
            if not withAlpha then return a0 end
            if CPF.GetColorAlpha then
                local ok, a = pcall(CPF.GetColorAlpha, CPF)
                if ok and type(a) == "number" then return a end
            end
            if OpacitySliderFrame and OpacitySliderFrame.GetValue then
                return 1 - (OpacitySliderFrame:GetValue() or 0)
            end
            return a0
        end
        local function Changed()
            local r, g, b = CPF:GetColorRGB()
            if o.onChange then o.onChange(r, g, b, Alpha()) end
        end
        local function Cancel()
            if o.onCancel then o.onCancel(r0, g0, b0, a0) end
        end
        if CPF.SetupColorPickerAndShow then
            CPF:SetupColorPickerAndShow({
                r = r0, g = g0, b = b0, hasOpacity = withAlpha, opacity = a0,
                swatchFunc = Changed, opacityFunc = Changed, cancelFunc = Cancel,
            })
        else
            -- Hidden first: the old dialog wires itself up in OnShow.
            CPF:Hide()
            CPF.func = Changed
            CPF.swatchFunc = Changed
            CPF.opacityFunc = Changed
            CPF.cancelFunc = Cancel
            CPF.hasOpacity = withAlpha
            CPF.opacity = 1 - a0
            CPF.previousValues = { r = r0, g = g0, b = b0, opacity = 1 - a0 }
            CPF:SetColorRGB(r0, g0, b0)
            CPF:Show()
        end
        return true
    end

    ------------------------------------------------------------------
    -- Colour
    ------------------------------------------------------------------
    -- RC.UI:CreateColorPicker(parent, {
    --     label = "Text colour", alpha = true, width = 300,
    --     get = fn() -> {r,g,b,a} | r, g, b, a,     (nil -> opts.default)
    --     set = fn(r, g, b, a),                     a is nil unless alpha
    --     default = {r,g,b,a},     the Reset link shows while it differs
    --     reset = fn(),            optional; Reset calls it instead of set(default)
    --     isChanged = fn() -> bool optional; overrides the default compare
    --     tooltip = "..." })
    -- One framework colour row (swatch, label, #hex, gold dot, Reset).
    -- Live while the wheel is dragged; Cancel puts back what it opened with.
    local function ToHex(r, g, b)
        local function q(v) return math_max(0, math_min(255, math_floor((v or 0) * 255 + 0.5))) end
        return string_format("%02X%02X%02X", q(r), q(g), q(b))
    end

    function RC.UI:CreateColorPicker(parent, opts)
        opts = opts or {}
        local holder = CreateFrame("Frame", nil, parent)
        holder:SetSize(opts.width or 300, 24)
        local row = self:CreateColorRow(holder)
        row:SetPoint("TOPLEFT", holder, "TOPLEFT", 0, 0)
        row:SetPoint("TOPRIGHT", holder, "TOPRIGHT", 0, 0)
        holder.row = row

        local function Read()
            local a, b, c, d = nil, nil, nil, nil
            if opts.get then a, b, c, d = opts.get() end
            if type(a) == "number" then return a, b or 1, c or 1, d or 1 end
            return RC.UI:ColorOf(a, opts.default)
        end
        local function Changed(r, g, b, a)
            if opts.isChanged then return opts.isChanged() and true or false end
            local d = opts.default
            if type(d) ~= "table" then return false end
            local dr, dg, db, da = RC.UI:ColorOf(d)
            local function q(v) return math_floor((v or 0) * 255 + 0.5) end
            return q(r) ~= q(dr) or q(g) ~= q(dg) or q(b) ~= q(db)
                or (opts.alpha and math_floor(a * 100 + 0.5) ~= math_floor(da * 100 + 0.5)) or false
        end
        local function Write(r, g, b, a)
            if opts.set then opts.set(r, g, b, opts.alpha and a or nil) end
            holder:Refresh()
            NotifySettingChanged("color")
        end

        function holder:Refresh()
            local r, g, b, a = Read()
            row.currentColor = { r = r, g = g, b = b, a = a }
            row:SetData(opts.label or "", "#" .. ToHex(r, g, b), row.currentColor, Changed(r, g, b, a))
        end

        row.onClick = function()
            local r, g, b, a = Read()
            -- an unset colour (shown as its default) goes back to unset on
            -- Cancel, not to a copy of the default
            local wasSet = Changed(r, g, b, a)
            RC.UI:OpenColorPicker({ r = r, g = g, b = b, a = a, alpha = opts.alpha,
                onChange = Write,
                onCancel = function(r0, g0, b0, a0)
                    if not wasSet and opts.reset then
                        opts.reset()
                        holder:Refresh()
                        NotifySettingChanged("color")
                    else
                        Write(r0, g0, b0, a0)
                    end
                end })
        end
        row.onReset = function()
            if opts.reset then
                opts.reset()
            elseif opts.default and opts.set then
                local r, g, b, a = RC.UI:ColorOf(opts.default)
                opts.set(r, g, b, opts.alpha and a or nil)
            end
            holder:Refresh()
            NotifySettingChanged("color")
        end
        row.tooltipFn = function(_, tt)
            local tn, gold = GetTextNormal(), GetAccentGold()
            tt:AddLine(opts.label or "", tn.r, tn.g, tn.b)
            if opts.tooltip then
                local gr = GetTextGray()
                tt:AddLine(opts.tooltip, gr.r, gr.g, gr.b, true)
            end
            tt:AddLine(RCL["Click to edit"], gold.r, gold.g, gold.b)
        end
        function holder:Repaint() row:Repaint() end

        holder:Refresh()
        return holder
    end

    ------------------------------------------------------------------
    -- Font
    ------------------------------------------------------------------
    -- RC.UI:CreateFontPicker(parent, {
    --     label = "Icon text", width = 420,
    --     get = fn() -> font spec | nil,  set = fn(spec),
    --     defaults = { size = 12, outline = "OUTLINE", shadow = true },
    --     minSize = 6, maxSize = 32, sample = "USE  REMOVE" })
    -- Outline, size, shadow, and a sample line drawn with exactly what the
    -- feature will draw (RC:ApplyFontSpec). The face is Readycheck's one
    -- font (Appearance > Fonts): the face box is shown disabled with a
    -- note, and a face an older save picked stays in the spec, ignored.
    local function OutlineLabel(id)
        for _, o in ipairs(RC.FONT_OUTLINES or {}) do
            if o.id == id then return o.label end
        end
        return RCL["Outline"]
    end

    function RC.UI:CreateFontPicker(parent, opts)
        opts = opts or {}
        local W = opts.width or 420
        local defaults = opts.defaults or {}
        local holder = CreateFrame("Frame", nil, parent)
        holder:SetSize(W, LABEL_H + 32 + 40 + 24)
        holder.label = Label(holder, opts.label)

        local function Spec()
            local s = opts.get and opts.get()
            return type(s) == "table" and s or {}
        end
        local function Put(field, value)
            local s = CopyValue(Spec())
            s[field] = value
            if opts.set then opts.set(s) end
            holder:Refresh()
            NotifySettingChanged("picker")
        end

        local faceW = math_floor(math_min(220, W * 0.52))
        local face = self:CreateScrollableDropdown(holder, faceW, RC.ONE_FONT_NOTE, 10)
        face:SetPoint("TOPLEFT", holder, "TOPLEFT", 0, -LABEL_H)
        local outline = self:CreateScrollableDropdown(holder, 140, OutlineLabel("OUTLINE"), 5)
        outline:SetPoint("LEFT", face, "RIGHT", 8, 0)

        -- one font: the face box is a disabled note, not a choice
        face:SetItems({ { text = RC.ONE_FONT_NOTE, value = "" } }, function() end)
        face:EnableMouse(false)
        face:SetAlpha(0.5)
        if face.arrow then face.arrow:Hide() end
        face.tooltipText = RC.ONE_FONT_NOTE
        local olItems = {}
        for _, o in ipairs(RC.FONT_OUTLINES or {}) do olItems[#olItems + 1] = { text = o.label, value = o.id } end
        outline:SetItems(olItems, function(v) Put("outline", v) end)

        local minS, maxS = opts.minSize or 6, opts.maxSize or 32
        local size = self:CreateSlider(holder, minS, maxS, defaults.size or 12, 1)
        size:SetPoint("TOPLEFT", holder, "TOPLEFT", 0, -(LABEL_H + 32))
        size:SetWidth(faceW)
        size:SetLabel(RCL["Size"])
        size:SetScript("OnValueChanged", function(s, v)
            v = math_floor(v + 0.5)
            s.Text:SetText(v .. RCL[" pt"])
            if holder.syncing then return end
            Put("size", v)
        end)

        local shadow = self:CreateCheckbox(holder, RCL["Shadow"], defaults.shadow)
        shadow:SetPoint("LEFT", size.parentFrame, "RIGHT", 12, -4)
        shadow:SetScript("OnClick", function(cb) Put("shadow", cb:GetChecked() and true or false) end)

        local sample = holder:CreateFontString(nil, "OVERLAY")
        sample:SetPoint("TOPLEFT", holder, "TOPLEFT", 0, -(LABEL_H + 32 + 40))
        sample:SetPoint("RIGHT", holder, "RIGHT", 0, 0)
        sample:SetJustifyH("LEFT")
        sample:SetWordWrap(false)
        holder.sample = sample

        holder.face, holder.outline, holder.size, holder.shadow = face, outline, size, shadow

        function holder:Refresh()
            local s = Spec()
            self.syncing = true
            face:SetSelectedValue("", RC.ONE_FONT_NOTE)
            local ol = s.outline
            if ol == nil then ol = defaults.outline or "OUTLINE" end
            outline:SetSelectedValue(ol, OutlineLabel(ol))
            local _, sz, _, sh = RC:ResolveFontSpec(s, defaults)
            size:SetValue(sz)
            size.Text:SetText(math_floor(sz + 0.5) .. RCL[" pt"])
            shadow:SetChecked(sh)
            self.syncing = false
            RC:ApplyFontSpec(sample, s, defaults)
            sample:SetText(opts.sample or RCL["The quick brown fox - 123"])
            local c = GetTextNormal()
            sample:SetTextColor(c.r, c.g, c.b, 1)
        end
        function holder:Repaint()
            PaintLabel(self)
            local c = GetTextNormal()
            sample:SetTextColor(c.r, c.g, c.b, 1)
        end

        holder:Refresh()
        return holder
    end

    ------------------------------------------------------------------
    -- Texture
    ------------------------------------------------------------------
    -- RC.UI:CreateTexturePicker(parent, {
    --     label = "Bar texture", width = 260,
    --     get = fn() -> name | nil,  set = fn(name | nil),   nil = global
    --     color = fn() -> r, g, b })   tint of the samples (default accent)
    function RC.UI:CreateTexturePicker(parent, opts)
        opts = opts or {}
        local W = opts.width or 260
        local holder = CreateFrame("Frame", nil, parent)
        holder:SetSize(W, LABEL_H + 26 + 16)
        holder.label = Label(holder, opts.label)

        local dd = self:CreateScrollableDropdown(holder, W, RCL["Readycheck texture"], 10)
        dd:SetPoint("TOPLEFT", holder, "TOPLEFT", 0, -LABEL_H)
        holder.dropdown = dd

        -- the sample: the texture as a 70% full bar on the element fill
        local sampleBox = CreateFrame("Frame", nil, holder)
        sampleBox:SetPoint("TOPLEFT", holder, "TOPLEFT", 0, -(LABEL_H + 28))
        sampleBox:SetSize(W, 12)
        local track = sampleBox:CreateTexture(nil, "BACKGROUND")
        track:SetAllPoints()
        track:SetTexture(FLAT)
        local bar = sampleBox:CreateTexture(nil, "ARTWORK")
        bar:SetPoint("TOPLEFT", sampleBox, "TOPLEFT", 0, 0)
        bar:SetPoint("BOTTOMLEFT", sampleBox, "BOTTOMLEFT", 0, 0)
        bar:SetWidth(math_floor(W * 0.7))
        sampleBox.border = self:CreateSimpleBorder(sampleBox)
        holder.track, holder.bar = track, bar

        local function Tint()
            if opts.color then return opts.color() end
            local a = GetAccentGold()
            return a.r, a.g, a.b
        end
        local function Name()
            local n = opts.get and opts.get()
            if n == "" then n = nil end
            return n
        end
        local function Items()
            local r, g, b = Tint()
            local tint = { r = r, g = g, b = b, a = 1 }
            local items = { { text = RCL["Readycheck texture"], value = "", icon = RC:ResolveTexture(nil),
                iconNoCrop = true, iconColor = tint } }
            for _, name in ipairs(RC.GetAvailableTextures and RC:GetAvailableTextures() or {}) do
                items[#items + 1] = { text = name, value = name, icon = RC:ResolveTexture(name),
                    iconNoCrop = true, iconColor = tint }
            end
            return items
        end

        function holder:Refresh()
            local n = Name()
            dd:SetItems(Items(), function(v)
                if opts.set then opts.set((v ~= "" and v) or nil) end
                holder:Refresh()
                NotifySettingChanged("picker")
            end)
            if n then dd:SetSelectedValue(n, n) else dd:SetSelectedValue("", RCL["Readycheck texture"]) end
            local e = GetElementBG()
            track:SetVertexColor(e.r, e.g, e.b, 1)
            bar:SetTexture(RC:ResolveTexture(n))
            local r, g, b = Tint()
            bar:SetVertexColor(r, g, b, 1)
        end
        function holder:Repaint()
            PaintLabel(self)
            local e = GetElementBG()
            track:SetVertexColor(e.r, e.g, e.b, 1)
            local r, g, b = Tint()
            bar:SetVertexColor(r, g, b, 1)
        end

        holder:Refresh()
        return holder
    end

    ------------------------------------------------------------------
    -- Animation
    ------------------------------------------------------------------
    -- RC.UI:CreateAnimationPicker(parent, {
    --     label = "When it appears", width = 420,
    --     get = fn() -> spec | nil,  set = fn(spec),
    --     defaults = { style = "fade", duration = 0.3, ... },  what nil means
    --     styles = { "none", "fade", "pop" },   optional subset, in order
    --     how = "in" | "out" | "update",        what the demo plays
    --     maxDuration = 2 })
    -- Style, easing, length, delay, direction + distance (slide, bounce),
    -- repeat (pulse, flash), with a demo square that replays the spec
    -- while the picker is on screen. Controls that do nothing for the
    -- chosen style are dimmed.
    local function StyleItems(subset)
        local M = RC.Motion
        local out, want = {}, nil
        if subset then
            want = {}
            for _, id in ipairs(subset) do want[id] = true end
        end
        for _, s in ipairs(M.STYLES) do
            if not want or want[s.id] then out[#out + 1] = { text = s.label, value = s.id } end
        end
        return out
    end
    local function LabelOf(list, id)
        for _, x in ipairs(list) do if x.id == id then return x.label end end
        return tostring(id)
    end

    function RC.UI:CreateAnimationPicker(parent, opts)
        opts = opts or {}
        local M = RC.Motion
        local W = opts.width or 420
        local how = opts.how or "in"
        local maxD = math_floor((opts.maxDuration or 2) * 100 + 0.5)
        local holder = CreateFrame("Frame", nil, parent)
        holder:SetSize(W, LABEL_H + 30 + 38 + 36 + 22)
        holder.label = Label(holder, opts.label)

        local function Spec() return M.Normalize(opts.get and opts.get(), opts.defaults) end
        local function Put(field, value)
            local s = Spec()
            s[field] = value
            if opts.set then opts.set(s) end
            holder:Refresh()
            NotifySettingChanged("picker")
        end

        local DEMO = 54
        local colW = math_floor((W - DEMO - 16) / 2)

        local style = self:CreateScrollableDropdown(holder, colW, RCL["Fade"], 7)
        style:SetPoint("TOPLEFT", holder, "TOPLEFT", 0, -LABEL_H)
        style:SetItems(StyleItems(opts.styles), function(v) Put("style", v) end)
        style:SetSearchEnabled(false)
        local easing = self:CreateScrollableDropdown(holder, colW, RCL["Smooth"], 7)
        easing:SetPoint("LEFT", style, "RIGHT", 8, 0)
        local ezItems = {}
        for _, e in ipairs(M.EASINGS) do ezItems[#ezItems + 1] = { text = e.label, value = e.id } end
        easing:SetItems(ezItems, function(v) Put("easing", v) end)
        easing:SetSearchEnabled(false)

        local y2 = -(LABEL_H + 30)
        local length = self:CreateSlider(holder, 5, maxD, 30, 5)
        length:SetPoint("TOPLEFT", holder, "TOPLEFT", 0, y2)
        length:SetWidth(colW)
        length:SetLabel(RCL["Length"])
        length:SetScript("OnValueChanged", function(s, v)
            v = math_floor(v + 0.5)
            s.Text:SetText(string_format("%.2fs", v / 100))
            if holder.syncing then return end
            Put("duration", v / 100)
        end)
        local delay = self:CreateSlider(holder, 0, 100, 0, 5)
        delay:SetPoint("TOPLEFT", holder, "TOPLEFT", colW + 8, y2)
        delay:SetWidth(colW)
        delay:SetLabel(RCL["Delay"])
        delay:SetScript("OnValueChanged", function(s, v)
            v = math_floor(v + 0.5)
            s.Text:SetText(string_format("%.2fs", v / 100))
            if holder.syncing then return end
            Put("delay", v / 100)
        end)

        local y3 = y2 - 38
        local dirItems = {}
        for _, d in ipairs(M.DIRS) do dirItems[#dirItems + 1] = { key = d.id, label = d.label } end
        local dir = self:CreateSegmentedControl(holder, {
            items = dirItems, width = colW, height = 20, x = 0, y = y3 - 8, fontSize = 10,
            label = RCL["Direction"],
            selected = "up",
            onSelect = function(k) if not holder.syncing then Put("dir", k) end end,
        })
        local distance = self:CreateSlider(holder, 0, 80, 20, 2)
        distance:SetPoint("TOPLEFT", holder, "TOPLEFT", colW + 8, y3)
        distance:SetWidth(colW)
        distance:SetLabel(RCL["Distance"])
        distance:SetScript("OnValueChanged", function(s, v)
            v = math_floor(v + 0.5)
            s.Text:SetText(v .. RCL[" px"])
            if holder.syncing then return end
            Put("distance", v)
        end)

        local loop = self:CreateCheckbox(holder, RCL["Repeat until it goes"], false)
        loop:SetPoint("TOPLEFT", holder, "TOPLEFT", 0, y3 - 36)
        loop:SetScript("OnClick", function(cb) Put("loop", cb:GetChecked() and true or false) end)

        -- The demo: a gold square in its own box, replaying the spec on a
        -- C_Timer chain that ends the moment the picker leaves the screen.
        local box = CreateFrame("Frame", nil, holder)
        box:SetSize(DEMO, DEMO)
        box:SetPoint("TOPRIGHT", holder, "TOPRIGHT", 0, -LABEL_H)
        box.bg = box:CreateTexture(nil, "BACKGROUND")
        box.bg:SetAllPoints()
        box.bg:SetTexture(FLAT)
        box.border = self:CreateSimpleBorder(box)
        if box.SetClipsChildren then box:SetClipsChildren(true) end
        local square = CreateFrame("Frame", nil, box)
        square:SetSize(20, 20)
        square:SetPoint("CENTER", box, "CENTER", 0, 0)
        square.tex = square:CreateTexture(nil, "ARTWORK")
        square.tex:SetAllPoints()
        square.tex:SetTexture(FLAT)
        self:CreateSimpleBorder(square)
        holder.demo, holder.square = box, square

        local token = 0
        local function Cycle(t)
            if t ~= token or not box:IsVisible() then return end
            local s = Spec()
            M.Stop(square)
            square:Show()
            if how == "out" then
                M.Hide(square, s)
            elseif how == "update" then
                M.Play(square, s, "update")
            else
                square:Hide()
                M.Show(square, s)
            end
            local span = M.Duration(s.duration) + M.Duration(s.delay) + 0.9
            C_Timer.After(span, function()
                if t ~= token or not box:IsVisible() then return end
                if how == "out" then
                    M.Stop(square)
                    square:Show()
                end
                C_Timer.After(0.35, function() Cycle(t) end)
            end)
        end
        local function Restart()
            token = token + 1
            M.Stop(square)
            square:Show()
            if box:IsVisible() then Cycle(token) end
        end
        box:SetScript("OnShow", Restart)
        box:SetScript("OnHide", function()
            token = token + 1
            M.Stop(square)
        end)
        holder.Replay = Restart

        holder.style, holder.easing, holder.length, holder.delay = style, easing, length, delay
        holder.dir, holder.distance, holder.loop = dir, distance, loop

        function holder:Refresh()
            local s = Spec()
            self.syncing = true
            style:SetSelectedValue(s.style, LabelOf(M.STYLES, s.style))
            easing:SetSelectedValue(s.easing, LabelOf(M.EASINGS, s.easing))
            length:SetValue(math_floor(s.duration * 100 + 0.5))
            length.Text:SetText(string_format("%.2fs", s.duration))
            delay:SetValue(math_floor(s.delay * 100 + 0.5))
            delay.Text:SetText(string_format("%.2fs", s.delay))
            dir:SetValue(s.dir, true)
            distance:SetValue(s.distance)
            distance.Text:SetText(math_floor(s.distance + 0.5) .. RCL[" px"])
            loop:SetChecked(s.loop)
            self.syncing = false

            local on = s.style ~= "none"
            RC.UI:SetWidgetEnabled(easing, on and not (s.style == "bounce" or s.style == "flash" or s.style == "pulse"))
            RC.UI:SetWidgetEnabled(length, on)
            RC.UI:SetWidgetEnabled(delay, on)
            RC.UI:SetWidgetEnabled(dir, on and M.MOVES[s.style] and true or false)
            RC.UI:SetWidgetEnabled(distance, on and M.MOVES[s.style] and true or false)
            RC.UI:SetWidgetEnabled(loop, on and M.LOOPS[s.style] and how ~= "out" and true or false)

            self:Repaint()
            Restart()
        end
        function holder:Repaint()
            PaintLabel(self)
            local e = GetElementBG()
            box.bg:SetVertexColor(e.r, e.g, e.b, 1)
            local a = GetAccentGold()
            square.tex:SetVertexColor(a.r, a.g, a.b, 1)
        end

        holder:Refresh()
        return holder
    end
