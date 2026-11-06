local pairs, ipairs, type, tostring, tonumber = pairs, ipairs, type, tostring, tonumber
local math_floor, math_max, math_min = math.floor, math.max, math.min
local CreateFrame = CreateFrame

------------------------------------------------------------------------
-- Readycheck - UI Framework: the customization pickers
-- One compact control per family of the customization standard
-- (UIF_Custom), built from the framework's own widgets. Each raises
-- RC.UI:NotifySettingChanged after its set (sliders live while dragged),
-- each set receives a NEW table (or nil = back to the feature's default).
-- Every picker returns a holder with a real height (anchor it by TOPLEFT,
-- x = 14 in a card, and advance by holder:GetHeight() + a gap) and
-- holder:Refresh() to re-read get().
--
--   RC.UI:CreateAnchorPicker(parent, opts)        point grid, "of the target"
--                                                 grid, anchor to, X / Y, align, Reset
--   RC.UI:CreateFramePositionPicker(parent, opts) the anchor picker + layer,
--                                                 level, scale, keep on screen
--   RC.UI:CreateLayoutPicker(parent, opts)        grow, wrap, per line, gaps,
--                                                 padding, item size, order, reverse, most
--   RC.UI:CreateVisibilityPicker(parent, opts)    show when, opacity (+ combat),
--                                                 mouseover fade
--   RC.UI:CreateChromePicker(parent, opts)        background, border, shadow, glow
--   RC.UI:CreateStateEditor(parent, opts)         a state dropdown + its overrides
--   RC.UI:CreateTextFormatPicker(parent, opts)    numbers, times, names, template
--   RC.UI:CreateSoundSpecPicker(parent, opts)     sound, channel, throttle
--   RC.UI:CreateTextElement(parent, opts)         one text: font + colour(s) +
--                                                 format + position, one group
--   RC.UI:CreateFrameElement(parent, opts)        one part: position + size (+ look)
-- Common opts: label, width, get, set, defaults (a table or a function:
-- what nil means - today's look), fields (a set of field names to offer).
------------------------------------------------------------------------

local RC = _G.Readycheck
if not (RC and RC.UI and RC.Custom) then return end
RC._uif = RC._uif or {}
local _uif = RC._uif
local BASE, FLAT, CreateProfessionalFontString = _uif.BASE, _uif.FLAT, _uif.CreateProfessionalFontString
local GetTextNormal, GetTextGray, GetAccentGold, GetElementBG = _uif.GetTextNormal, _uif.GetTextGray, _uif.GetAccentGold, _uif.GetElementBG
local GetButtonNormalBG, GetButtonHoverBG, GetButtonConfiguredBG = _uif.GetButtonNormalBG, _uif.GetButtonHoverBG, _uif.GetButtonConfiguredBG
local GetBorderNormal, GetBorderSelected = _uif.GetBorderNormal, _uif.GetBorderSelected
local NotifySettingChanged = _uif.NotifySettingChanged

local Custom = RC.Custom
local EMPTY = Custom.EMPTY
local Copy, Clean = Custom.Copy, Custom.Clean

local function Def(opts)
    local d = opts.defaults
    if type(d) == "function" then d = d() end
    return type(d) == "table" and d or EMPTY
end
local function Cur(opts)
    local t = opts.get and opts.get()
    return type(t) == "table" and t or nil
end
local function Want(opts, field) return not opts.fields or opts.fields[field] and true or false end
local function Label(parent, text, gray)
    local fs = CreateProfessionalFontString(parent, "OVERLAY", BASE.FONT_SIZE_SMALL, "OUTLINE")
    fs:SetJustifyH("LEFT")
    fs:SetText(text or "")
    local c = gray and GetTextGray() or GetTextNormal()
    fs:SetTextColor(c.r, c.g, c.b, 1)
    return fs
end
local function Tip(frame, title, body)
    frame:HookScript("OnEnter", function(b)
        GameTooltip:SetOwner(b, "ANCHOR_RIGHT")
        local gold, norm = RC:GetColor("text", "gold"), RC:GetColor("text", "normal")
        GameTooltip:SetText(title or "", gold.r, gold.g, gold.b)
        if body then GameTooltip:AddLine(body, norm.r, norm.g, norm.b, true) end
        GameTooltip:Show()
    end)
    frame:HookScript("OnLeave", function() GameTooltip:Hide() end)
end
local function PX(v) return math_floor(v + 0.5) .. RCL[" px"] end
local function PCT(v) return math_floor(v + 0.5) .. "%" end
local function SEC100(v) return string.format("%.2fs", v / 100) end
local function Pct() return { toStore = function(v) return v / 100 end, fromStore = function(v) return math_floor(v * 100 + 0.5) end } end
local function Hund() return { toStore = function(v) return v / 100 end, fromStore = function(v) return math_floor(v * 100 + 0.5) end } end

-- A slider's label longer than the room left of its value wraps onto more
-- lines and the slider grows taller (the track stays at the bottom), so
-- nothing is cut short. w is the slider's width; returns its height.
local function WrapSliderLabel(s, w)
    local lab = s.label
    if not lab then return 30 end
    local valueW = math_min(60, math_max(28, math_floor(w * 0.4)))
    local room = math_max(40, math_floor(w - valueW - 4))
    if (lab:GetStringWidth() or 0) <= room + 0.5 then return 30 end
    local one = math_floor((lab:GetStringHeight() or 10) + 0.5)
    lab:ClearAllPoints()
    lab:SetPoint("TOPLEFT", s.parentFrame, "TOPLEFT", 0, 0)
    lab:SetWidth(room)
    lab:SetWordWrap(true)
    local extra = math_max(0, math_floor((lab:GetStringHeight() or one) + 0.999) - one)
    s:SetHeight(30 + extra)
    return 30 + extra
end

-- ============================================================
-- FORM: a two-column flow of bound controls
-- ============================================================
-- bind = { cur = fn() -> table, put = fn(field, value, quiet), def = fn(field) }
local function Form(host, W, bind)
    local f = { W = W, y = 0, n = 0, rowH = 0, sync = {}, two = W >= 300 }
    f.colW = f.two and math_floor((W - 16) / 2) or W
    function f:EndRow()
        if self.n % 2 == 1 then
            self.y = self.y - self.rowH - 8
            self.n = self.n + 1
        end
    end
    function f:Cell(w, h, full)
        if full or not self.two then
            self:EndRow()
            w:SetPoint("TOPLEFT", host, "TOPLEFT", 0, self.y)
            self.y = self.y - h - 8
            return
        end
        if self.n % 2 == 0 then
            w:SetPoint("TOPLEFT", host, "TOPLEFT", 0, self.y)
            self.rowH = h
        else
            w:SetPoint("TOPLEFT", host, "TOPLEFT", self.colW + 16, self.y)
            self.rowH = math_max(self.rowH, h)
            self.y = self.y - self.rowH - 8
        end
        self.n = self.n + 1
    end
    function f:Height() self:EndRow() return -self.y end
    function f:Sync()
        self.syncing = true
        for _, fn in ipairs(self.sync) do
            local ok, err = pcall(fn)
            if not ok then RC:DebugPrint("Custom picker sync failed: " .. tostring(err), "ui") end
        end
        self.syncing = false
    end
    local function Eff(field, fb)
        local v = bind.cur()[field]
        if v == nil then v = bind.def(field) end
        if v == nil then v = fb end
        return v
    end
    f.Eff = Eff
    -- o: { toStore = fn(v), fromStore = fn(v), full = bool }
    function f:Slider(field, label, lo, hi, step, fmt, fb, o)
        o = o or EMPTY
        step = step or 1
        local w = (o.full or not self.two) and self.W or self.colW
        local holder = CreateFrame("Frame", nil, host)
        holder:SetSize(w, 30)
        local function Shown()
            local v = tonumber(Eff(field, fb)) or lo
            if o.fromStore then v = o.fromStore(v) end
            return v
        end
        local s = RC.UI:CreateSlider(holder, lo, hi, Shown(), step)
        s:SetPoint("TOPLEFT", holder, "TOPLEFT", 0, 0)
        s:SetWidth(w - 20)
        s:SetLabel(label)
        s.rpkLabel = label
        local sh = WrapSliderLabel(s, w - 20)
        holder:SetHeight(sh)
        s.Text:SetText(fmt and fmt(Shown()) or tostring(Shown()))
        s:SetScript("OnValueChanged", function(self, v)
            v = math_floor(v / step + 0.5) * step
            self.Text:SetText(fmt and fmt(v) or tostring(v))
            if f.syncing then return end
            if o.toStore then v = o.toStore(v) end
            bind.put(field, v, true)
        end)
        local x = RC.UI:CreateXCloseButton(holder, 14, function()
            bind.put(field, nil)
        end)
        x:SetPoint("BOTTOMRIGHT", holder, "BOTTOMRIGHT", 0, 3)
        Tip(x, RCL["Reset"], RCL["Back to the default"])
        self.sync[#self.sync + 1] = function()
            local v = Shown()
            local mn, mx = s:GetMinMaxValues()
            if v < mn or v > mx then s:SetMinMaxValues(math_min(lo, v), math_max(hi, v)) end
            s:SetValue(v)
            s.Text:SetText(fmt and fmt(v) or tostring(v))
            if bind.cur()[field] ~= nil then x:Show() else x:Hide() end
        end
        holder.control, holder.reset = s, x
        self:Cell(holder, sh, o.full)
        return holder
    end
    -- items: list (or fn) of { text, value }; "Default" (nil) comes first
    function f:Drop(field, label, items, o)
        o = o or EMPTY
        local w = (o.full or not self.two) and self.W or self.colW
        local function Raw() return type(items) == "function" and items() or items end
        local function List()
            local out = {}
            if not o.noDefault then out[1] = { text = o.defaultText or RCL["Default"], value = "__d" } end
            for _, it in ipairs(Raw()) do out[#out + 1] = it end
            return out
        end
        local function TextOf(v)
            for _, it in ipairs(Raw()) do if it.value == v then return it.text end end
            return v ~= nil and tostring(v) or nil
        end
        local function Selected()
            local v = bind.cur()[field]
            if v == nil and not o.noDefault then
                local d = bind.def(field)
                local t = d ~= nil and TextOf(d)
                local base = o.defaultText or RCL["Default"]
                return "__d", (t and (base .. " (" .. t .. ")") or base)
            end
            if v == nil then v = bind.def(field) end
            return v, TextOf(v) or ""
        end
        local holder = CreateFrame("Frame", nil, host)
        holder:SetSize(w, 14 + (BASE.DROPDOWN_HEIGHT or 24))
        local lab = Label(holder, label, true)
        lab:SetPoint("TOPLEFT", holder, "TOPLEFT", 0, 0)
        local dd = RC.UI:CreateScrollableDropdown(holder, w, "", 10)
        dd:SetPoint("TOPLEFT", holder, "TOPLEFT", 0, -14)
        dd:SetItems(List(), function(v)
            bind.put(field, v ~= "__d" and v or nil, true)
        end)
        self.sync[#self.sync + 1] = function()
            local v, t = Selected()
            dd:SetSelectedValue(v, t)
        end
        holder.control, holder.label = dd, lab
        self:Cell(holder, holder:GetHeight(), o.full)
        return holder
    end
    function f:Check(field, label, fb)
        local wrap = CreateFrame("Frame", nil, host)
        wrap:SetSize(self.colW, 30)
        local cb = RC.UI:CreateCheckbox(wrap, label, Eff(field, fb) and true or false)
        cb.parentFrame:SetPoint("LEFT", wrap, "LEFT", 0, -4)
        -- a label longer than its column wraps under itself, the box level
        -- with its first line, and the row grows
        local size = BASE.CHECKBOX_SIZE or 16
        local room = math_floor(self.colW - size - 7)
        local h = 30
        if room >= 30 and (cb.Text:GetStringWidth() or 0) > room + 0.5 then
            cb.Text:ClearAllPoints()
            cb.Text:SetPoint("TOPLEFT", cb, "TOPRIGHT", 7, 1)
            cb.Text:SetWidth(room)
            cb.Text:SetJustifyH("LEFT")
            cb.Text:SetWordWrap(true)
            cb:ClearAllPoints()
            cb:SetPoint("TOPLEFT", cb.parentFrame, "TOPLEFT", 0, 0)
            local th = math_max(size, math_floor((cb.Text:GetStringHeight() or size) + 0.999))
            cb.parentFrame:SetSize(size + 7 + room, th)
            cb:SetHitRectInsets(0, -(7 + room), 0, 0)
            h = th + 30 - size
            wrap:SetHeight(h)
        end
        cb:SetScript("OnClick", function(self)
            if f.syncing then return end
            bind.put(field, self:GetChecked() and true or false, true)
        end)
        self.sync[#self.sync + 1] = function() cb:SetChecked(Eff(field, fb) and true or false) end
        wrap.control = cb
        self:Cell(wrap, h)
        return wrap
    end
    function f:Color(field, label, fb)
        local wrap = CreateFrame("Frame", nil, host)
        wrap:SetSize(self.colW, 24)
        local function DefColor()
            local d = bind.def(field)
            if d == nil then d = fb end
            return type(d) == "table" and d or { r = 1, g = 1, b = 1, a = 1 }
        end
        local co = { label = label, alpha = true, width = self.colW,
            get = function() return bind.cur()[field] end,
            set = function(r, g, b, a) bind.put(field, { r = r, g = g, b = b, a = a or 1 }, true) end,
            default = DefColor(),
            reset = function() bind.put(field, nil, true) end,
            isChanged = function() return bind.cur()[field] ~= nil end }
        local cp = RC.UI:CreateColorPicker(wrap, co)
        cp:SetPoint("TOPLEFT", wrap, "TOPLEFT", 0, 0)
        self.sync[#self.sync + 1] = function() co.default = DefColor() cp:Refresh() end
        wrap.control = cp
        self:Cell(wrap, 24)
        return wrap
    end
    function f:Texture(field, label)
        local tp = RC.UI:CreateTexturePicker(host, { label = label, width = self.colW,
            get = function() return bind.cur()[field] end,
            set = function(v) bind.put(field, v, true) end })
        self.sync[#self.sync + 1] = function() if tp.Refresh then tp:Refresh() end end
        self:Cell(tp, tp:GetHeight())
        return tp
    end
    function f:Edit(field, label, hint, o)
        o = o or EMPTY
        local w = (o.full or not self.two) and self.W or self.colW
        local holder = CreateFrame("Frame", nil, host)
        holder:SetSize(w, 14 + (BASE.EDITBOX_HEIGHT or 22))
        local lab = Label(holder, label, true)
        lab:SetPoint("TOPLEFT", holder, "TOPLEFT", 0, 0)
        local c = RC.UI:CreateStyledEditBox(holder, { width = w, height = BASE.EDITBOX_HEIGHT or 22 })
        c:SetPoint("TOPLEFT", holder, "TOPLEFT", 0, -14)
        local eb = c.editBox
        eb:SetText(bind.cur()[field] or "")
        eb:SetScript("OnEnterPressed", function(self)
            self:ClearFocus()
            if f.syncing then return end
            local t = self:GetText()
            bind.put(field, (t and t ~= "") and t or nil, true)
        end)
        if hint then Tip(eb, label, hint) end
        self.sync[#self.sync + 1] = function()
            if not (eb.HasFocus and eb:HasFocus()) then eb:SetText(bind.cur()[field] or "") end
        end
        holder.control, holder.editBox = c, eb
        self:Cell(holder, holder:GetHeight(), o.full)
        return holder
    end
    return f
end
RC.UI.CustomForm = Form

-- a spec-editing holder: get/set over one spec, a Form bound to it
local function SpecHost(parent, opts, want)
    local W = opts.width or want or 420
    local host = CreateFrame("Frame", nil, parent)
    local form
    local bind = {
        cur = function() return Cur(opts) or EMPTY end,
        def = function(field) return Def(opts)[field] end,
        put = function(field, value, quiet)
            local new = Copy(Cur(opts) or {})
            new[field] = value
            if opts.set then opts.set(Clean(new)) end
            if form then form:Sync() end
            if host.OnPut then host.OnPut() end
            if not quiet then NotifySettingChanged("custom") end
        end,
    }
    local top = 0
    if opts.label then
        host.label = Label(host, opts.label)
        host.label:SetPoint("TOPLEFT", host, "TOPLEFT", 0, 0)
        top = 18
    end
    local body = CreateFrame("Frame", nil, host)
    body:SetPoint("TOPLEFT", host, "TOPLEFT", 0, -top)
    body:SetSize(W, 10)
    form = Form(body, W, bind)
    host.form, host.bind, host.body, host.top, host.W = form, bind, body, top, W
    function host:Finish()
        local h = form:Height()
        body:SetHeight(math_max(1, h))
        self:SetSize(W, top + h)
        form:Sync()
        return self
    end
    function host:Refresh() form:Sync() end
    function host:Repaint()
        if self.label then local c = GetTextNormal() self.label:SetTextColor(c.r, c.g, c.b, 1) end
    end
    return host
end
RC.UI.CustomSpecHost = SpecHost

-- ============================================================
-- POINT GRID
-- ============================================================
local POINT_LABEL = {
    TOPLEFT = RCL["Top left"], TOP = RCL["Top"], TOPRIGHT = RCL["Top right"],
    LEFT = RCL["Left"], CENTER = RCL["Center"], RIGHT = RCL["Right"],
    BOTTOMLEFT = RCL["Bottom left"], BOTTOM = RCL["Bottom"], BOTTOMRIGHT = RCL["Bottom right"],
}
RC.ANCHOR_POINT_LABELS = POINT_LABEL

local function Grid(parent, title, onPick)
    local DOT, GAP, PAD = 12, 5, 4
    local side = PAD * 2 + DOT * 3 + GAP * 2
    local g = CreateFrame("Frame", nil, parent)
    local lab = Label(g, title, true)
    lab:SetPoint("TOPLEFT", g, "TOPLEFT", 0, 0)
    local box = CreateFrame("Frame", nil, g)
    box:SetSize(side, side)
    box:SetPoint("TOPLEFT", g, "TOPLEFT", 0, -14)
    local bg = box:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetTexture(FLAT)
    local eb = GetElementBG()
    bg:SetVertexColor(eb.r, eb.g, eb.b, 1)
    box.border = RC.UI:CreateSimpleBorder(box, 1)
    g:SetSize(math_max(side, (lab:GetStringWidth() or 0) + 2), side + 14)
    g.dots = {}
    local function PaintDot(b)
        local on = b.point == g.sel
        local fill = on and GetButtonConfiguredBG() or (b.hot and GetButtonHoverBG()) or GetButtonNormalBG()
        b.fill:SetVertexColor(fill.r, fill.g, fill.b, 1)
        local k = on and GetBorderSelected() or (b.hot and GetAccentGold()) or GetBorderNormal()
        RC.UI:UpdateBorderColor(b.border, k, 1)
    end
    for i, p in ipairs(RC.ANCHOR_POINTS) do
        local b = CreateFrame("Button", nil, box)
        b:SetSize(DOT, DOT)
        local col, row = (i - 1) % 3, math_floor((i - 1) / 3)
        b:SetPoint("TOPLEFT", box, "TOPLEFT", PAD + col * (DOT + GAP), -PAD - row * (DOT + GAP))
        b.fill = b:CreateTexture(nil, "BACKGROUND")
        b.fill:SetAllPoints()
        b.fill:SetTexture(FLAT)
        b.border = RC.UI:CreateSimpleBorder(b, 1)
        b.point = p
        b:SetScript("OnEnter", function(self) self.hot = true PaintDot(self) end)
        b:SetScript("OnLeave", function(self) self.hot = nil PaintDot(self) end)
        Tip(b, POINT_LABEL[p])
        b:SetScript("OnClick", function() onPick(p) end)
        g.dots[p] = b
    end
    function g:Select(p)
        self.sel = p
        for _, b in pairs(self.dots) do PaintDot(b) end
    end
    function g:Repaint()
        local c = GetTextGray()
        lab:SetTextColor(c.r, c.g, c.b, 1)
        local e = GetElementBG()
        bg:SetVertexColor(e.r, e.g, e.b, 1)
        self:Select(self.sel)
    end
    g.label = lab
    return g
end
RC.UI.CreateAnchorGrid = function(_, parent, title, onPick) return Grid(parent, title, onPick) end

-- ============================================================
-- ANCHOR
-- ============================================================
local ANCHOR_FIELDS = { "point", "relPoint", "x", "y", "to", "justify", "point2", "relPoint2", "x2", "y2", "to2", "fill" }
--   opts.targets   { { value = "<key>", text = "Count text" }, ... } (or a fn):
--                  adds an "Anchor to" dropdown, first row = the default
--   opts.defaultTargetLabel, opts.text (FontString: Text align),
--   opts.relPoint = false hides the "Of the target" grid,
--   opts.min / max / step (-100 / 100 / 1), opts.defaults (the built-in anchor)
function RC.UI:CreateAnchorPicker(parent, opts)
    opts = opts or {}
    local host = SpecHost(parent, setmetatable({ label = opts.label or "" }, { __index = opts }), opts.width or 420)
    local W, form, bind, body = host.W, host.form, host.bind, host.body
    local function Resolved() return RC.UI:ResolveAnchor(Cur(opts), Def(opts)) end
    local function AnchorSet()
        local c = Cur(opts)
        if not c then return false end
        for _, k in ipairs(ANCHOR_FIELDS) do if c[k] ~= nil then return true end end
        return false
    end
    local reset = RC.UI:CreateStyledButton(host, RCL["Reset"], 60, 18)
    reset:SetPoint("TOPRIGHT", host, "TOPRIGHT", 0, 2)
    reset:SetScript("OnClick", function()
        local new = Copy(Cur(opts) or {})
        for _, k in ipairs(ANCHOR_FIELDS) do new[k] = nil end
        if opts.set then opts.set(Clean(new)) end
        form:Sync()
        if host.OnPut then host.OnPut() end
        NotifySettingChanged("anchor")
    end)
    host.resetButton = reset

    local function PickPoint(field, p)
        local d = Def(opts)
        local new = Copy(Cur(opts) or {})
        if field == "point" then
            local dp = Custom.VALID_POINT[d.point] and d.point or "CENTER"
            new.point = (p ~= dp) and p or nil
        else
            new.relPoint = nil
            local _, rp = RC.UI:ResolveAnchor(new, d)
            new.relPoint = (p ~= rp) and p or nil
        end
        if opts.set then opts.set(Clean(new)) end
        form:Sync()
        if host.OnPut then host.OnPut() end
        NotifySettingChanged("anchor")
    end
    local row = CreateFrame("Frame", nil, body)
    local g1 = Grid(row, RCL["Point"], function(p) PickPoint("point", p) end)
    g1:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
    local x0 = g1:GetWidth() + 16
    local g2
    if opts.relPoint ~= false then
        g2 = Grid(row, RCL["Of the target"], function(p) PickPoint("relPoint", p) end)
        g2:SetPoint("TOPLEFT", row, "TOPLEFT", x0, 0)
        x0 = x0 + g2:GetWidth() + 16
    end
    local rowH = g1:GetHeight()
    row:SetSize(W, rowH)
    if opts.targets then
        local targets = opts.targets
        local inRow = (W - x0) >= 150
        local dw = inRow and math_min(220, W - x0) or math_min(W, 260)
        local function Items()
            local l = type(targets) == "function" and targets() or targets
            local out = { { text = opts.defaultTargetLabel or RCL["Default"], value = "__d" } }
            for _, t in ipairs(l) do out[#out + 1] = t end
            return out
        end
        local holder = CreateFrame("Frame", nil, row)
        holder:SetSize(dw, 14 + (BASE.DROPDOWN_HEIGHT or 24))
        local lab = Label(holder, RCL["Anchor to"], true)
        lab:SetPoint("TOPLEFT", holder, "TOPLEFT", 0, 0)
        local dd = RC.UI:CreateScrollableDropdown(holder, dw, "", 10)
        dd:SetPoint("TOPLEFT", holder, "TOPLEFT", 0, -14)
        dd:SetItems(Items(), function(v) bind.put("to", v ~= "__d" and v or nil, true) end)
        if inRow then
            holder:SetPoint("TOPLEFT", row, "TOPLEFT", x0, 0)
        else
            holder:SetPoint("TOPLEFT", row, "TOPLEFT", 0, -(rowH + 8))
            rowH = rowH + 8 + holder:GetHeight()
            row:SetHeight(rowH)
        end
        form.sync[#form.sync + 1] = function()
            local v = (Cur(opts) or EMPTY).to
            local text = opts.defaultTargetLabel or RCL["Default"]
            for _, it in ipairs(Items()) do if it.value == v then text = it.text end end
            dd:SetSelectedValue(v or "__d", text)
        end
        host.target = dd
    end
    row:SetPoint("TOPLEFT", body, "TOPLEFT", 0, 0)
    form.y = -(rowH + 8)
    bind.def = function(field)
        local _, _, x, y = Resolved()
        if field == "x" then return x elseif field == "y" then return y end
        return Def(opts)[field]
    end
    local lo, hi, st = opts.min or -100, opts.max or 100, opts.step or 1
    host.x = form:Slider("x", RCL["X offset"], lo, hi, st, PX, 0)
    host.y = form:Slider("y", RCL["Y offset"], lo, hi, st, PX, 0)
    if opts.text then
        -- one of three (or the default): a dropdown, like every value picker
        local holder = CreateFrame("Frame", nil, body)
        local sw = math_min(W, 260)
        holder:SetSize(sw, 22)
        local jc = RC.UI:CreateSegmentedControl(holder, {
            x = 0, y = 0, width = sw, height = 22, label = RCL["Text align"],
            items = {
                { key = "__d", label = RCL["Default"], tooltip = RCL["Follows the point it is anchored by."] },
                { key = "LEFT", label = RCL["Left"] }, { key = "CENTER", label = RCL["Center"] }, { key = "RIGHT", label = RCL["Right"] },
            },
            selected = (Cur(opts) or EMPTY).justify or "__d",
            onSelect = function(k)
                if form.syncing then return end
                bind.put("justify", (k ~= "__d") and k or nil, true)
            end,
        })
        holder.control = jc
        holder.buttons = jc.byKey
        form:Cell(holder, holder:GetHeight(), true)
        form.sync[#form.sync + 1] = function()
            jc:SetValue((Cur(opts) or EMPTY).justify or "__d", true)
        end
        host.justify = holder
    end
    form.sync[#form.sync + 1] = function()
        local p, rp = Resolved()
        g1:Select(p)
        if g2 then g2:Select(rp) end
        RC.UI:SetWidgetEnabled(reset, AnchorSet())
    end
    host.point, host.relPoint = g1, g2
    return host:Finish()
end

-- ============================================================
-- FRAME POSITION
-- ============================================================
function RC.UI:CreateFramePositionPicker(parent, opts)
    opts = opts or {}
    local W = opts.width or 420
    local host = CreateFrame("Frame", nil, parent)
    -- opts.noAnchor: a frame the mover (RC.Position) places - only its
    -- layer, level, scale and clamp here
    local a
    if not opts.noAnchor then
        a = self:CreateAnchorPicker(host, { label = opts.label, width = W, get = opts.get, set = opts.set,
            defaults = opts.defaults, targets = opts.targets, defaultTargetLabel = opts.defaultTargetLabel or RCL["The screen"],
            min = opts.min or -1200, max = opts.max or 1200 })
        a:SetPoint("TOPLEFT", host, "TOPLEFT", 0, 0)
    end
    local rest = SpecHost(host, { width = W, get = opts.get, set = opts.set, defaults = opts.defaults,
        label = a and nil or opts.label })
    if a then rest:SetPoint("TOPLEFT", a, "BOTTOMLEFT", 0, -8) else rest:SetPoint("TOPLEFT", host, "TOPLEFT", 0, 0) end
    local f = rest.form
    if Want(opts, "strata") then
        local items = {}
        for _, s in ipairs(RC.STRATAS) do items[#items + 1] = { text = s:sub(1, 1) .. s:sub(2):lower(), value = s } end
        f:Drop("strata", RCL["Layer"], items)
    end
    if Want(opts, "level") then f:Slider("level", RCL["Level (above / below)"], -20, 20, 1, function(v) return (v > 0 and "+" or "") .. v end, 0) end
    if Want(opts, "scale") then f:Slider("scale", RCL["Scale"], 50, 200, 5, PCT, 1, Pct()) end
    if Want(opts, "clamp") then f:Check("clamp", RCL["Keep it on the screen"], false) end
    rest:Finish()
    if a then
        rest.OnPut = function() a:Refresh() end
        a.OnPut = function() rest:Refresh() end
        host:SetSize(W, a:GetHeight() + 8 + rest:GetHeight())
    else
        host:SetSize(W, rest:GetHeight())
    end
    host.anchor, host.rest = a, rest
    function host:Refresh() if a then a:Refresh() end rest:Refresh() end
    return host
end

-- ============================================================
-- LAYOUT
-- ============================================================
local GROW_LABEL = { RIGHT = RCL["Right"], LEFT = RCL["Left"], DOWN = RCL["Down"], UP = RCL["Up"], CENTER = RCL["From the middle"] }
function RC.UI:CreateLayoutPicker(parent, opts)
    opts = opts or {}
    local host = SpecHost(parent, opts, 420)
    local f = host.form
    local function Items(list)
        local out = {}
        for _, id in ipairs(list) do out[#out + 1] = { text = GROW_LABEL[id] or id, value = id } end
        return out
    end
    if Want(opts, "grow") then f:Drop("grow", RCL["Grows"], Items(opts.grows or RC.LAYOUT_GROWS)) end
    if Want(opts, "wrap") then f:Drop("wrap", RCL["New lines go"], Items({ "DOWN", "UP", "RIGHT", "LEFT" })) end
    if Want(opts, "perLine") then f:Slider("perLine", RCL["Per line (0 = one line)"], 0, 20, 1, nil, 0) end
    if Want(opts, "max") then f:Slider("max", RCL["Most shown"], 1, opts.maxItems or 40, 1, nil, opts.maxItems or 40) end
    if Want(opts, "spacingX") then f:Slider("spacingX", RCL["Gap across"], -10, 40, 1, PX, 0) end
    if Want(opts, "spacingY") then f:Slider("spacingY", RCL["Gap down"], -10, 40, 1, PX, 0) end
    if Want(opts, "padding") then f:Slider("padding", RCL["Padding"], 0, 30, 1, PX, 0) end
    if Want(opts, "itemW") then f:Slider("itemW", RCL["Item width"], 8, opts.sizeMax or 128, 1, PX, 20) end
    if Want(opts, "itemH") then f:Slider("itemH", RCL["Item height"], opts.itemHMin or 8, opts.sizeMax or 128, 1, PX, 20) end
    if opts.sorts and Want(opts, "sort") then f:Drop("sort", RCL["Order by"], opts.sorts) end
    if Want(opts, "reverse") then f:Check("reverse", RCL["Reverse the order"], false) end
    return host:Finish()
end

-- ============================================================
-- VISIBILITY
-- ============================================================
local SHOW_LABEL = { always = RCL["Always"], combat = RCL["In combat"], nocombat = RCL["Out of combat"],
    group = RCL["In a group"], raid = RCL["In a raid group"], instance = RCL["In a dungeon or raid"],
    target = RCL["With a target"], resting = RCL["While resting"], mouseover = RCL["On mouseover"], never = RCL["Never"] }
RC.VIS_SHOW_LABELS = SHOW_LABEL
function RC.UI:CreateVisibilityPicker(parent, opts)
    opts = opts or {}
    local host = SpecHost(parent, opts, 420)
    local f = host.form
    if Want(opts, "show") then
        local items = {}
        for _, id in ipairs(opts.shows or RC.VIS_SHOW) do items[#items + 1] = { text = SHOW_LABEL[id] or id, value = id } end
        f:Drop("show", RCL["Show"], items)
    end
    if Want(opts, "alpha") then f:Slider("alpha", RCL["Opacity"], 0, 100, 5, PCT, 1, Pct()) end
    if Want(opts, "combatAlpha") then f:Slider("combatAlpha", RCL["Opacity in combat"], 0, 100, 5, PCT, 1, Pct()) end
    if Want(opts, "mouseover") then f:Check("mouseover", RCL["Brighten on mouseover"], false) end
    if Want(opts, "hoverAlpha") then f:Slider("hoverAlpha", RCL["Opacity on mouseover"], 0, 100, 5, PCT, 1, Pct()) end
    if Want(opts, "fadeIn") then f:Slider("fadeIn", RCL["Fade in"], 0, 200, 5, SEC100, 0.2, Hund()) end
    if Want(opts, "fadeOut") then f:Slider("fadeOut", RCL["Fade out"], 0, 200, 5, SEC100, 0.3, Hund()) end
    return host:Finish()
end

-- ============================================================
-- CHROME
-- ============================================================
function RC.UI:CreateChromePicker(parent, opts)
    opts = opts or {}
    local host = SpecHost(parent, opts, 420)
    local f = host.form
    if Want(opts, "bgTexture") then f:Texture("bgTexture", RCL["Background texture"]) end
    if Want(opts, "bgColor") then f:Color("bgColor", RCL["Background colour"]) end
    if Want(opts, "bgInset") then f:Slider("bgInset", RCL["Background inset"], 0, 10, 1, PX, 0) end
    if Want(opts, "borderSize") then f:Slider("borderSize", RCL["Border size"], 0, 6, 1, PX, 1) end
    if Want(opts, "borderColor") then f:Color("borderColor", RCL["Border colour"]) end
    if Want(opts, "shadowSize") then f:Slider("shadowSize", RCL["Shadow"], 0, 12, 1, PX, 0) end
    if Want(opts, "shadowColor") then f:Color("shadowColor", RCL["Shadow colour"], { r = 0, g = 0, b = 0, a = 0.6 }) end
    if Want(opts, "glowSize") then f:Slider("glowSize", RCL["Glow"], 0, 12, 1, PX, 0) end
    if Want(opts, "glowColor") then f:Color("glowColor", RCL["Glow colour"], { r = 1, g = 0.82, b = 0, a = 0.8 }) end
    return host:Finish()
end

-- ============================================================
-- PER-STATE STYLES
-- ============================================================
--   opts.states { { id, label } }, get / set the WHOLE states table,
--   opts.defaults { [id] = { ... } } (or a fn), opts.fields (set of
--   color desat alpha border glow textColor anim), opts.remember (a table)
function RC.UI:CreateStateEditor(parent, opts)
    opts = opts or {}
    local W = opts.width or 420
    local host = CreateFrame("Frame", nil, parent)
    local states = opts.states or {}
    local mem = opts.remember or {}
    local sel = mem.state
    local okSel = false
    for _, s in ipairs(states) do if s.id == sel then okSel = true end end
    if not okSel then sel = states[1] and states[1].id end
    local top = 0
    if opts.label then
        host.label = Label(host, opts.label)
        host.label:SetPoint("TOPLEFT", host, "TOPLEFT", 0, 0)
        top = 18
    end
    local function All() local t = opts.get and opts.get() return type(t) == "table" and t or nil end
    local function LabelOf(id) for _, s in ipairs(states) do if s.id == id then return s.label or s.id end end return "" end
    local sub
    local holder = CreateFrame("Frame", nil, host)
    local dw = math_min(W, 220)
    holder:SetSize(dw, 14 + (BASE.DROPDOWN_HEIGHT or 24))
    holder:SetPoint("TOPLEFT", host, "TOPLEFT", 0, -top)
    local lab = Label(holder, RCL["State"], true)
    lab:SetPoint("TOPLEFT", holder, "TOPLEFT", 0, 0)
    local dd = RC.UI:CreateScrollableDropdown(holder, dw, LabelOf(sel), 10)
    dd:SetPoint("TOPLEFT", holder, "TOPLEFT", 0, -14)
    local items = {}
    for _, s in ipairs(states) do items[#items + 1] = { text = s.label or s.id, value = s.id } end
    dd:SetItems(items, function(v) sel = v mem.state = v if sub then sub:Refresh() end end)
    dd:SetSelectedValue(sel, LabelOf(sel))
    sub = SpecHost(host, { width = W,
        get = function() local a = All() return a and a[sel] end,
        set = function(spec)
            local a = Copy(All() or {})
            a[sel] = spec
            if opts.set then opts.set(Clean(a)) end
        end,
        defaults = function()
            local d = opts.defaults
            if type(d) == "function" then d = d() end
            return type(d) == "table" and d[sel] or EMPTY
        end })
    sub:SetPoint("TOPLEFT", holder, "BOTTOMLEFT", 0, -8)
    local f = sub.form
    local want = opts.fields
    local function W_(k) return not want or want[k] end
    if W_("color") then f:Color("color", RCL["Colour"]) end
    if W_("textColor") then f:Color("textColor", RCL["Text colour"]) end
    if W_("border") then f:Color("border", RCL["Border colour"]) end
    if W_("glow") then f:Color("glow", RCL["Glow colour"]) end
    if W_("desat") then f:Drop("desat", RCL["Grey it out"], { { text = RCL["Yes"], value = true }, { text = RCL["No"], value = false } }) end
    if W_("alpha") then f:Slider("alpha", RCL["Opacity"], 0, 100, 5, PCT, 1, Pct()) end
    if W_("anim") then
        f:EndRow()
        local ap = RC.UI:CreateAnimationPicker(sub.body, { label = RCL["When it starts"], width = W, how = "update",
            get = function() return sub.bind.cur().anim end,
            set = function(spec) sub.bind.put("anim", spec, true) end })
        f:Cell(ap, ap:GetHeight(), true)
        f.sync[#f.sync + 1] = function() ap:Refresh() end
    end
    sub:Finish()
    host:SetSize(W, top + holder:GetHeight() + 8 + sub:GetHeight())
    function host:Refresh() dd:SetSelectedValue(sel, LabelOf(sel)) sub:Refresh() end
    host.state, host.editor = dd, sub
    host.Selected = function() return sel end
    return host
end

-- ============================================================
-- TEXT FORMAT
-- ============================================================
--   opts.kinds  set of number, percent, time, name
--   opts.tokens { { token = "cur", label = "Current" } } adds a template box
--   opts.sample fn(spec) -> the line as it would read
function RC.UI:CreateTextFormatPicker(parent, opts)
    opts = opts or {}
    local host = SpecHost(parent, opts, 420)
    local f = host.form
    local k = opts.kinds or { number = true }
    if k.number then
        f:Drop("abbrev", RCL["Big numbers"], { { text = RCL["Short (12.3k)"], value = "short" },
            { text = RCL["Commas (12,345)"], value = "comma" }, { text = RCL["In full (12345)"], value = "full" } })
    end
    if k.number or k.percent then f:Slider("decimals", RCL["Decimals"], 0, 3, 1, nil, 1) end
    if k.time then
        f:Drop("time", RCL["Times"], { { text = "1:05", value = "mmss" }, { text = RCL["1:05 / 45s"], value = "clock" }, { text = RCL["1m / 45s"], value = "short" },
            { text = RCL["65s"], value = "seconds" } })
        f:Slider("timeDecimalsUnder", RCL["Tenths below (0 = never)"], 0, 10, 1,
            function(v) return v == 0 and RCL["never"] or (v .. "s") end, 0)
    end
    if k.name then
        f:Slider("maxLen", RCL["Longest (0 = no limit)"], 0, 30, 1,
            function(v) return v == 0 and RCL["no limit"] or (v .. RCL[" letters"]) end, 0)
        f:Edit("mark", RCL["Cut mark"], RCL["What ends a shortened name."])
    end
    f:Drop("case", RCL["Letters"], { { text = RCL["As they are"], value = "none" }, { text = RCL["UPPER CASE"], value = "upper" },
        { text = RCL["lower case"], value = "lower" } })
    f:Edit("prefix", RCL["Before it"])
    f:Edit("suffix", RCL["After it"])
    if opts.tokens then
        local names = {}
        for _, t in ipairs(opts.tokens) do names[#names + 1] = "[" .. t.token .. "] " .. (t.label or t.token) end
        f:Edit("template", RCL["Template"], RCL["Words and these, in any order: "] .. table.concat(names, ", "), { full = true })
    end
    if opts.sample then
        f:EndRow()
        local wrap = CreateFrame("Frame", nil, host.body)
        wrap:SetSize(host.W, 16)
        local fs = Label(wrap, "")
        fs:SetPoint("LEFT", wrap, "LEFT", 0, 0)
        f:Cell(wrap, 16, true)
        f.sync[#f.sync + 1] = function()
            local ok, s = pcall(opts.sample, Cur(opts) or EMPTY)
            fs:SetText(ok and (RCL["Reads: "] .. tostring(s)) or "")
        end
        host.sampleText = fs
    end
    return host:Finish()
end

-- ============================================================
-- SOUND (per event)
-- ============================================================
--   opts.defaults.sound  what nil plays (the feature's own sound key)
function RC.UI:CreateSoundSpecPicker(parent, opts)
    opts = opts or {}
    local host = SpecHost(parent, opts, 420)
    local f = host.form
    local wrap = CreateFrame("Frame", nil, host.body)
    wrap:SetSize(f.colW, 14 + (BASE.DROPDOWN_HEIGHT or 24))
    local lab = Label(wrap, RCL["Sound"], true)
    lab:SetPoint("TOPLEFT", wrap, "TOPLEFT", 0, 0)
    local function Key() return host.bind.cur().sound or Def(opts).sound end
    local sp = RC.UI:CreateSoundPicker(wrap, { width = math_max(100, f.colW - 90), selected = Key(),
        onPick = function(key) host.bind.put("sound", key, true) end })
    sp:SetPoint("TOPLEFT", wrap, "TOPLEFT", 0, -14)
    f:Cell(wrap, wrap:GetHeight())
    f.sync[#f.sync + 1] = function()
        local k = Key()
        sp.selected = k
        if k then sp.dropdown:SetSelectedValue(k, k) end
    end
    local ch = {}
    for _, c in ipairs(RC.SOUND_CHANNELS) do ch[#ch + 1] = { text = c, value = c } end
    f:Drop("channel", RCL["Channel"], ch)
    f:Slider("throttle", RCL["Not again within"], 0, 30, 1, function(v) return v == 0 and RCL["no limit"] or (v .. "s") end, 0)
    host.sound = sp
    return host:Finish()
end

-- ============================================================
-- THE POOL (shared by every picker above and the bundles below)
-- ============================================================
-- The client never frees a frame, and a settings page is built again on
-- every tab switch, toggle and resize. A picker built for a page goes
-- back to the pool when the page is cleared (RC:ClearSidebarContent) and
-- the next build that asks for one of the same shape gets it back:
-- reparented, re-bound and refreshed, no new frames. The shape is the
-- picker's name plus every plain value in its opts (labels, widths,
-- fields, defaults tables, the targets list) and the global font; the
-- functions in opts (get / set / defaults / sample...) are bound through
-- small forwarders that always call the latest build's functions, so a
-- reused picker reads and writes exactly what the new build asked for.
local Pool = { free = {}, out = setmetatable({}, { __mode = "k" }), depth = 0, colorEpoch = 0,
    stats = { built = 0, reused = 0, released = 0 } }
RC.UI.CustomPool = Pool
local POOL_NOCOPY = { remember = true }        -- tables kept by identity (the page owns them)
local POOL_EVAL = { targets = true, items = true }   -- functions whose result shapes the picker
local function IsObj(v) return type(v) == "table" and type(v.GetObjectType) == "function" end
local function SigOf(v, depth, buf, key)
    local t = type(v)
    if t == "function" then
        if key and POOL_EVAL[key] then
            local ok, r = pcall(v)
            if ok then return SigOf(r, depth, buf) end
        end
        buf[#buf + 1] = "f"
    elseif t == "table" then
        if IsObj(v) or (key and POOL_NOCOPY[key]) or depth > 4 then buf[#buf + 1] = "@" .. tostring(v) return end
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = k end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        buf[#buf + 1] = "{"
        for _, k in ipairs(keys) do
            buf[#buf + 1] = tostring(k) .. "="
            SigOf(v[k], depth + 1, buf, k)
            buf[#buf + 1] = ";"
        end
        buf[#buf + 1] = "}"
    else
        buf[#buf + 1] = t:sub(1, 1) .. tostring(v)
    end
end
local function Forwarder(live, path)
    local n = #path
    return function(...)
        local v = live.cur
        for i = 1, n do
            if type(v) ~= "table" then return nil end
            v = v[path[i]]
        end
        if type(v) == "function" then return v(...) end
        return nil
    end
end
local function ShadowOf(v, live, path, key)
    local t = type(v)
    if t == "function" then return Forwarder(live, path) end
    if t ~= "table" or IsObj(v) or (key and POOL_NOCOPY[key]) or #path > 5 then return v end
    local o = {}
    for k, x in pairs(v) do
        local p = {}
        for i = 1, #path do p[i] = path[i] end
        p[#p + 1] = k
        o[k] = ShadowOf(x, live, p, k)
    end
    return o
end
local function FontEpoch()
    local fs = RC.db and RC.db.fontSettings
    return tostring(fs and fs.selectedFont) .. "/" .. tostring(fs and fs.fontSize) .. "/"
        .. tostring(RC.fontSystem and RC.fontSystem.currentFont) .. "/" .. Pool.colorEpoch
end
-- a theme colour change repaints what is on screen; what waits in the
-- pool is simply dropped (built again in the new colours when asked for)
local function WatchColors()
    local cur = RC.RefreshUIColors
    if type(cur) == "function" and cur ~= Pool._wrappedRUC then
        local raw = cur
        Pool._wrappedRUC = function(...)
            Pool.colorEpoch = Pool.colorEpoch + 1
            Pool.free = {}
            return raw(...)
        end
        RC.RefreshUIColors = Pool._wrappedRUC
    end
end
local function ResetForReuse(b)
    b._rcDepBy, b._rcDepOff, b._rcDepBindings, b._rcDepIndented = nil, nil, nil, nil
    if b._rcBlocker or b._rcDisabled then RC.UI:SetWidgetEnabled(b, true) end
    b:SetAlpha(1)
end
function Pool.Acquire(name, raw, selfUI, parent, opts)
    if Pool.depth > 0 or Pool.off or type(opts) ~= "table" or not parent then
        return raw(selfUI, parent, opts)
    end
    WatchColors()
    local buf = { name, "|", FontEpoch(), "|" }
    SigOf(opts, 0, buf)
    local sig = table.concat(buf)
    local list = Pool.free[sig]
    local b = list and list[#list]
    if b then
        list[#list] = nil
        b._rcPoolLive.cur = opts
        b:SetParent(parent)
        b:ClearAllPoints()
        b:Show()
        ResetForReuse(b)
        Pool.out[b] = true
        Pool.depth = Pool.depth + 1
        local ok, err = pcall(function()
            if b._rcOnAcquire then b._rcOnAcquire(b) end
            if b.Refresh then b:Refresh() end
        end)
        Pool.depth = Pool.depth - 1
        if not ok then RC:DebugPrint("Custom pool refresh failed: " .. tostring(err), "ui") end
        Pool.stats.reused = Pool.stats.reused + 1
        return b
    end
    local live = { cur = opts }
    local shadow = ShadowOf(opts, live, {})
    Pool.depth = Pool.depth + 1
    local ok, res = pcall(raw, selfUI, parent, shadow)
    Pool.depth = Pool.depth - 1
    if not ok then error(res, 0) end
    if type(res) == "table" and res.SetParent then
        res._rcPoolSig, res._rcPoolLive = sig, live
        Pool.out[res] = true
        Pool.stats.built = Pool.stats.built + 1
    end
    return res
end
local function Under(f, root)
    local p, d = f:GetParent(), 0
    while p and d < 40 do
        if p == root then return true end
        p = p:GetParent()
        d = d + 1
    end
    return false
end
-- RC.UI:ReleaseCustomBlocks(root): every pooled picker under root goes
-- back to the pool (the page clear calls it before the page is thrown away)
function RC.UI:ReleaseCustomBlocks(root)
    if not root then return 0 end
    if not Pool.holder then
        Pool.holder = CreateFrame("Frame", nil, UIParent)
        Pool.holder:Hide()
    end
    local n, back = 0, {}
    for b in pairs(Pool.out) do
        if Under(b, root) then back[#back + 1] = b end
    end
    for _, b in ipairs(back) do
        Pool.out[b] = nil
        b:Hide()
        b:ClearAllPoints()
        b:SetParent(Pool.holder)
        local sig = b._rcPoolSig
        -- (a block built before a font / colour change is not handed out again)
        if sig and sig:find("|" .. FontEpoch() .. "|", 1, true) then
            local list = Pool.free[sig]
            if not list then list = {} Pool.free[sig] = list end
            list[#list + 1] = b
        end
        n = n + 1
    end
    Pool.stats.released = Pool.stats.released + n
    return n
end
function RC.UI:FlushCustomPool() Pool.free = {} end

-- RC.UI:DiscardTree(frame): a settings page piece thrown away for good
-- (the page clear and the search's unseen builds call it). It is marked
-- (its font strings leave the font refresh list: RC:PruneTrackedFonts),
-- and a dropdown in it takes its list along: the list hangs on UIParent
-- so it can draw over the window, and would otherwise stay one of
-- UIParent's children for the rest of the session, one per dropdown per
-- rebuild.
local function Detach(f, d)
    if d > 30 then return end
    local m = rawget(f, "menu")
    if type(m) == "table" and rawget(m, "_rcOwner") == f and m:GetParent() == UIParent then
        m:Hide()
        m:SetParent(f)
    end
    for _, c in ipairs({ f:GetChildren() }) do Detach(c, d + 1) end
end
function RC.UI:DiscardTree(f)
    if not f then return end
    f._rcDiscarded = true
    Detach(f, 0)
end

-- ============================================================
-- FOLDS: the customization sections, shut until opened
-- ============================================================
-- A text's format and position, a part's place and size, and the frame
-- layer / fade / edge cards sit behind a one-line header (closed at
-- first). What is inside is built the first time it is opened; the page
-- is then built again around it (scroll kept). Opened sections stay open
-- for the session, per page. Search builds them all (unseen) and opens
-- the one a result lands in; a click on a preview sample opens its text's.
local FOLD_H = 20
local Folds = { open = {}, openAll = false }
RC.UI.CustomFolds = Folds
local function FoldPage()
    local S = RC.SidebarSearch
    if S and S.inDryRun then return tostring(S.dryItem or "") end
    local st = RC.SidebarState
    local item = st and (st.buildingItem or st.currentMenuItem)
    return tostring((item and item.id) or (st and st.selectedItem) or "")
end
local function FoldIsOpen(k)
    if Folds.openAll then return true end
    local S = RC.SidebarSearch
    if S and S.inDryRun then return true end
    return Folds.open[k] and true or false
end
function RC.UI:IsCustomFoldOpen(k) return FoldIsOpen(k) end
-- on = open / shut; rebuild = build the page on screen again around it
function RC.UI:SetCustomFoldOpen(k, on, rebuild, fold)
    if not k then return end
    Folds.open[k] = on and true or nil
    if not rebuild then return end
    local win = RC.sidebarConfigFrame
    local live = win and win.compatFrame and win.compatFrame.scrollChild
    if fold and live and Under(fold, live) and win:IsShown() and RC.RelayoutSidebarPage
        and not (RC.SidebarSearch and RC.SidebarSearch.searchMode) then
        RC:RelayoutSidebarPage(win)
    elseif fold and fold.Sync then
        -- not on the settings page (a test host, a dialog): open in place
        fold:Sync()
        if fold.onResize then fold.onResize() end
    end
end

local function PaintFold(fold)
    local hdr = fold.header
    local fill = hdr.hot and GetButtonHoverBG() or GetButtonNormalBG()
    hdr.bg:SetVertexColor(fill.r, fill.g, fill.b, 1)
    RC.UI:UpdateBorderColor(hdr.border, hdr.hot and GetAccentGold() or GetBorderNormal(), 1)
    local c = hdr.hot and GetAccentGold() or GetTextNormal()
    fold.titleFS:SetTextColor(c.r, c.g, c.b, 1)
    local a = GetAccentGold()
    fold.arrow:SetVertexColor(a.r, a.g, a.b, 1)
    local g = GetTextGray()
    fold.stateFS:SetTextColor(a.r, a.g, a.b, 1)
    if not fold.changed then fold.stateFS:SetTextColor(g.r, g.g, g.b, 1) end
end
-- buildBody(body) -> a frame with a real height, built once (first open);
-- isChanged() -> true while something in it is set (the header says so);
-- keyPart names the section on its page.
local function FoldUI(parent, W, label, buildBody, isChanged, keyPart)
    local fold = CreateFrame("Frame", nil, parent)
    fold:SetSize(W, FOLD_H)
    local hdr = CreateFrame("Button", nil, fold)
    hdr:SetPoint("TOPLEFT", fold, "TOPLEFT", 0, 0)
    hdr:SetSize(W, FOLD_H)
    hdr.bg = hdr:CreateTexture(nil, "BACKGROUND")
    hdr.bg:SetAllPoints()
    hdr.bg:SetTexture(FLAT)
    hdr.border = RC.UI:CreateSimpleBorder(hdr, 1)
    local arrow = hdr:CreateTexture(nil, "ARTWORK")
    arrow:SetSize(9, 9)
    arrow:SetPoint("LEFT", hdr, "LEFT", 7, 0)
    arrow:SetTexture("Interface\\AddOns\\Readycheck\\Media\\arrow")
    local stateFS = CreateProfessionalFontString(hdr, "OVERLAY", BASE.FONT_SIZE_SMALL, "OUTLINE")
    stateFS:SetPoint("RIGHT", hdr, "RIGHT", -7, 0)
    stateFS:SetJustifyH("RIGHT")
    local title = CreateProfessionalFontString(hdr, "OVERLAY", BASE.FONT_SIZE_SMALL, "OUTLINE")
    title:SetPoint("LEFT", arrow, "RIGHT", 6, 0)
    title:SetJustifyH("LEFT")
    title:SetWordWrap(false)
    title:SetText(label or "")
    hdr.text = title
    fold.header, fold.arrow, fold.titleFS, fold.stateFS = hdr, arrow, title, stateFS
    local body = CreateFrame("Frame", nil, fold)
    body:SetPoint("TOPLEFT", fold, "TOPLEFT", 0, -(FOLD_H + 8))
    body:SetSize(W, 1)
    body:Hide()
    fold.body = body
    hdr:SetScript("OnEnter", function(b) b.hot = true PaintFold(fold) end)
    hdr:SetScript("OnLeave", function(b) b.hot = nil PaintFold(fold) end)
    hdr:SetScript("OnClick", function()
        RC.UI:SetCustomFoldOpen(fold.openKey, not fold.isOpen, true, fold)
    end)
    local truncDone = false
    function fold:Sync()
        self.openKey = FoldPage() .. "|" .. tostring(keyPart)
        body._rcFoldKey = self.openKey
        local open = FoldIsOpen(self.openKey)
        if open and not self.inner then
            Pool.depth = Pool.depth + 1
            local ok, inner = pcall(buildBody, body)
            Pool.depth = Pool.depth - 1
            if ok and inner then
                inner:ClearAllPoints()
                inner:SetPoint("TOPLEFT", body, "TOPLEFT", 0, 0)
                self.inner = inner
            elseif not ok then
                RC:DebugPrint("Custom section failed to build: " .. tostring(inner), "ui")
            end
        end
        open = open and self.inner ~= nil
        self.isOpen = open
        if open then
            local h = math_max(1, self.inner:GetHeight() or 1)
            body:SetHeight(h)
            body:Show()
            self:SetHeight(FOLD_H + 8 + h)
        else
            body:Hide()
            self:SetHeight(FOLD_H)
        end
        RC.UI:SetDropdownArrowOpen(arrow, open)
        local ch = false
        if isChanged then
            local okC, v = pcall(isChanged)
            ch = okC and v and true or false
        end
        self.changed = ch
        stateFS:SetText(ch and RCL["Changed"] or "")
        local room = W - 7 - 9 - 6 - 8 - (ch and math_floor((stateFS:GetStringWidth() or 0) + 0.5) + 8 or 0)
        title:SetWidth(math_max(20, room))
        if not truncDone and RC.UI.TruncTip then
            truncDone = true
            RC.UI:TruncTip(title, hdr)
        end
        PaintFold(self)
    end
    function fold:Repaint() PaintFold(self) end
    fold:Sync()
    return fold
end
RC.UI.CustomFoldUI = FoldUI

-- ============================================================
-- BUNDLES for feature pages
-- ============================================================
local function Flash(g)
    if not g.flashTex then
        local t = g:CreateTexture(nil, "BACKGROUND")
        t:SetTexture(FLAT)
        t:SetPoint("TOPLEFT", g, "TOPLEFT", -6, 4)
        t:SetPoint("BOTTOMRIGHT", g, "BOTTOMRIGHT", 6, -4)
        g.flashTex = t
    end
    local a = GetAccentGold()
    g.flashTex:SetVertexColor(a.r, a.g, a.b, 0.15)
    g.flashTex:Show()
    C_Timer.After(0.8, function() if g.flashTex then g.flashTex:Hide() end end)
end

local function Group(parent, o)
    local W = o.width or 440
    local g = CreateFrame("Frame", nil, parent)
    local y = 0
    if o.label then
        g.title = CreateProfessionalFontString(g, "OVERLAY", BASE.FONT_SIZE_NORMAL, "OUTLINE")
        g.title:SetPoint("TOPLEFT", g, "TOPLEFT", 0, 0)
        g.title:SetText(o.label)
        local c = GetTextNormal()
        g.title:SetTextColor(c.r, c.g, c.b, 1)
        g._rcSearchTitle = true   -- search lists the group's label
        y = -20
    end
    g.flash = Flash
    if o.key and RC.CustomPick then RC.CustomPick.RegisterGroup(o.key, g) end
    g._zFlash = Flash
    local parts = {}
    local fold, foldY
    local function Add(w, gap)
        w:SetPoint("TOPLEFT", g, "TOPLEFT", 0, y)
        y = y - w:GetHeight() - (gap or 10)
        parts[#parts + 1] = w
    end
    -- the fold goes last: its height changes when it opens
    local function AddFold(f)
        f:SetPoint("TOPLEFT", g, "TOPLEFT", 0, y)
        fold, foldY = f, y
        g.fold = f
        f.onResize = function() g:Relayout() end
    end
    function g:Relayout()
        local bottom = y
        if fold then bottom = foldY - fold:GetHeight() - 10 end
        self:SetSize(W, math_max(1, -bottom - 4))
    end
    local function Done()
        g:Relayout()
        return g
    end
    -- refreshed on reuse (the pool) and by the page
    function g:Refresh()
        for _, w in ipairs(parts) do if w.Refresh then w:Refresh() end end
        if fold and fold.inner and fold.inner.Refresh then fold.inner:Refresh() end
    end
    -- reused: re-register for preview picks, open / shut as this page wants
    g._rcOnAcquire = function()
        if o.key and RC.CustomPick then RC.CustomPick.RegisterGroup(o.key, g) end
        if fold then fold:Sync() end
        g:Relayout()
    end
    return g, W, Add, Done, AddFold
end

-- one box holding several pickers stacked (a fold's inside)
local function Stack(parent, W, list)
    local box = CreateFrame("Frame", nil, parent)
    local y, bottom = 0, 0
    local kids = {}
    for _, make in ipairs(list) do
        local w = make(box)
        if w then
            w:SetPoint("TOPLEFT", box, "TOPLEFT", 0, y)
            bottom = y - w:GetHeight()
            y = bottom - 10
            kids[#kids + 1] = w
        end
    end
    box:SetSize(W, math_max(1, -bottom))
    function box:Refresh() for _, w in ipairs(kids) do if w.Refresh then w:Refresh() end end end
    return box
end
local function SpecSet(get)
    if not get then return false end
    local ok, t = pcall(get)
    return ok and type(t) == "table" and next(t) ~= nil
end

-- RC.UI:CreateTextElement(card, {
--     label, key, width,
--     font = { get, set, defaults, sample, minSize, maxSize, label },   -- or fontGet / fontSet / fontDefaults
--     colors = { { label, get, set, default, reset, isChanged, alpha } }, -- or colorGet / colorSet / colorDefault
--     formatGet, formatSet, formatDefaults, formatKinds, formatTokens, formatSample,
--     anchorGet, anchorSet, anchorDefaults, targets, defaultTargetLabel, anchorMin, anchorMax })
-- Parts without a get are left out. Place the returned group by TOPLEFT
-- (x = 14 in a card) and advance by group:GetHeight() + a gap. The font and
-- colours show at once; the format and the position sit in one section
-- that opens on a click (group.fold; group.format / group.anchor once open).
function RC.UI:CreateTextElement(parent, o)
    o = o or {}
    local g, W, Add, Done, AddFold = Group(parent, o)
    local font = o.font
    if not font and o.fontGet then
        font = { get = o.fontGet, set = o.fontSet, defaults = o.fontDefaults, sample = o.sample,
            minSize = o.minSize, maxSize = o.maxSize }
    end
    if font then
        g.font = self:CreateFontPicker(g, { label = font.label or RCL["Font"], width = W, get = font.get, set = font.set,
            defaults = font.defaults, sample = font.sample, minSize = font.minSize, maxSize = font.maxSize })
        Add(g.font)
    end
    local colors = o.colors
    if not colors and o.colorGet then
        colors = { { label = o.colorLabel or RCL["Colour"], get = o.colorGet, set = o.colorSet, default = o.colorDefault,
            reset = o.colorReset, isChanged = o.colorIsChanged, alpha = o.colorAlpha } }
    end
    if colors then
        g.colors = {}
        for _, c in ipairs(colors) do
            local cp = self:CreateColorPicker(g, { label = c.label, alpha = c.alpha, width = W, get = c.get, set = c.set,
                default = c.default, reset = c.reset, isChanged = c.isChanged })
            Add(cp, 4)
            g.colors[#g.colors + 1] = cp
        end
        g.color = g.colors[1]
    end
    if o.formatGet or o.anchorGet then
        local label = (o.formatGet and o.anchorGet) and RCL["Format and position"]
            or (o.anchorGet and RCL["Position"] or RCL["Format"])
        local f = FoldUI(g, W, label, function(body)
            return Stack(body, W, {
                function(box)
                    if not o.formatGet then return nil end
                    g.format = RC.UI:CreateTextFormatPicker(box, { label = RCL["Format"], width = W, get = o.formatGet, set = o.formatSet,
                        defaults = o.formatDefaults, kinds = o.formatKinds, tokens = o.formatTokens, sample = o.formatSample })
                    return g.format
                end,
                function(box)
                    if not o.anchorGet then return nil end
                    g.anchor = RC.UI:CreateAnchorPicker(box, { label = RCL["Position"], width = W, get = o.anchorGet, set = o.anchorSet,
                        defaults = o.anchorDefaults, targets = o.targets, defaultTargetLabel = o.defaultTargetLabel,
                        text = true, min = o.anchorMin, max = o.anchorMax })
                    return g.anchor
                end,
            })
        end, function() return SpecSet(o.formatGet) or SpecSet(o.anchorGet) end,
            "text|" .. tostring(o.key or "") .. "|" .. tostring(o.label or ""))
        AddFold(f)
    end
    return Done()
end

-- RC.UI:CreateFrameElement(card, {
--     label, key, width,
--     anchorGet, anchorSet, anchorDefaults, targets, defaultTargetLabel, anchorMin, anchorMax,
--     sizeGet, sizeSet, sizeMin, sizeMax, sizeLabel,      -- one "Size"
--     widthGet, widthSet, heightGet, heightSet,            -- or width + height
--     chromeGet, chromeSet, chromeDefaults, chromeFields }) -- optional look
-- Everything sits in one section under the label that opens on a click.
function RC.UI:CreateFrameElement(parent, o)
    o = o or {}
    local g, W, Add, Done, AddFold = Group(parent, o)
    local lo, hi = o.sizeMin or 4, o.sizeMax or 128
    local function Sl(box, label, get, set)
        local holder = CreateFrame("Frame", nil, box)
        holder:SetSize(math_min(W, 280), 30)
        local s = RC.UI:CreateSlider(holder, lo, hi, tonumber(get()) or lo, 1)
        s:SetPoint("TOPLEFT", holder, "TOPLEFT", 0, 0)
        s:SetWidth(math_min(W, 280))
        s:SetLabel(label)
        s.rpkLabel = label
        holder:SetHeight(WrapSliderLabel(s, math_min(W, 280)))
        s.Text:SetText(PX(tonumber(get()) or lo))
        local syncing = false
        s:SetScript("OnValueChanged", function(sl, v)
            v = math_floor(v + 0.5)
            sl.Text:SetText(PX(v))
            if syncing then return end
            set(v)
        end)
        holder.control = s
        function holder:Refresh()
            local v = tonumber(get()) or lo
            syncing = true
            s:SetValue(v)
            s.Text:SetText(PX(v))
            syncing = false
        end
        return holder, s
    end
    local f = FoldUI(g, W, RCL["Position and size"], function(body)
        return Stack(body, W, {
            function(box)
                if not o.anchorGet then return nil end
                g.anchor = RC.UI:CreateAnchorPicker(box, { label = RCL["Position"], width = W, get = o.anchorGet, set = o.anchorSet,
                    defaults = o.anchorDefaults, targets = o.targets, defaultTargetLabel = o.defaultTargetLabel,
                    min = o.anchorMin, max = o.anchorMax })
                return g.anchor
            end,
            function(box)
                if not o.sizeGet then return nil end
                local h, s = Sl(box, o.sizeLabel or RCL["Size"], o.sizeGet, o.sizeSet)
                g.sizeSlider = s
                return h
            end,
            function(box)
                if not o.widthGet then return nil end
                local h, s = Sl(box, RCL["Width"], o.widthGet, o.widthSet)
                g.widthSlider = s
                return h
            end,
            function(box)
                if not o.heightGet then return nil end
                local h, s = Sl(box, RCL["Height"], o.heightGet, o.heightSet)
                g.heightSlider = s
                return h
            end,
            function(box)
                if not o.chromeGet then return nil end
                g.chrome = RC.UI:CreateChromePicker(box, { label = RCL["Look"], width = W, get = o.chromeGet, set = o.chromeSet,
                    defaults = o.chromeDefaults, fields = o.chromeFields })
                return g.chrome
            end,
        })
    end, function() return SpecSet(o.anchorGet) or SpecSet(o.chromeGet) end,
        "part|" .. tostring(o.key or "") .. "|" .. tostring(o.label or ""))
    AddFold(f)
    return Done()
end

-- ============================================================
-- A TEXT PLACED OVER TODAY'S POINT (Readycheck only)
-- ============================================================
-- For a feature whose text is laid out by its own code: after its own
-- SetPoint, one call with the same values. No spec = nothing happens (the
-- text stays exactly where the feature put it); a spec moves it from
-- there (relPoint / x / y / to as section 9.2). def is the element's own
-- reusable table (allocation-free).
--   RC.UI:AnchorOver(fs, spec, def, point, to, relPoint, x, y, resolveTo)
function RC.UI:AnchorOver(region, spec, def, point, to, relPoint, x, y, resolveTo)
    if type(spec) ~= "table" or not region then return false end
    def.point, def.to, def.relPoint, def.x, def.y = point, to, relPoint or point, x or 0, y or 0
    return self:ApplyAnchor(region, spec, def, resolveTo)
end

-- A click on a preview sample picks the tagged text (RC.UI:TagElement)
-- under the pointer, else the sample's own tag:
--   RC.UI:PickOnClick(sampleFrame, previewKey)
-- (looked up on the click only; set once per sample frame)
local function TaggedUnder(f, depth)
    if not f or depth > 6 then return nil end
    for _, r in ipairs({ f:GetRegions() }) do
        if r._zElement and r:IsShown() and r.IsMouseOver and r:IsMouseOver() then return r._zElement end
    end
    for _, k in ipairs({ f:GetChildren() }) do
        if k:IsShown() then
            local hit = TaggedUnder(k, depth + 1)
            if hit then return hit end
        end
    end
    return nil
end
RC.UI.TaggedUnder = TaggedUnder
function RC.UI:PickOnClick(frame, previewKey)
    if not frame then return end
    frame._rcPickKey = previewKey
    if frame._rcPickOn then return end
    frame._rcPickOn = true
    frame:EnableMouse(true)
    frame:SetScript("OnMouseUp", function(f, button)
        if button and button ~= "LeftButton" then return end
        local key = TaggedUnder(f, 0) or (RC.CustomPick and RC.CustomPick.ElementAt(f))
        if key and RC.CustomPick then RC.CustomPick.Pick(f._rcPickKey, key) end
    end)
end

-- ============================================================
-- A FEATURE'S ON-SCREEN FRAME (Readycheck only)
-- ============================================================
-- One call from the feature's own style / apply function:
--   RC:ApplyFrameCustom(frame, root, opts)
--     root      the feature's registered settings table (or a fn returning it)
--     root.framePos    { strata, level, scale, clamp } - the mover keeps the spot
--     root.visibility  the standard's visibility (control "alpha": never
--                      Show / Hide, so it composes with the feature's own
--                      show rules and animations)
--     root.chrome      background / border / shadow / glow (own pieces
--                      appear only once a value is set)
--     opts.scale = false   the feature has its own scale setting (left alone)
--     opts.chrome = false  the feature dresses its own pieces (no chrome)
--     opts.parts           the feature's own bg / border for ApplyChrome
-- Nothing set = the frame exactly as the feature leaves it.
local function RootOf(root)
    if type(root) == "function" then return root() end
    return root
end
function RC:ApplyFrameCustom(frame, root, opts)
    if not frame then return end
    opts = opts or EMPTY
    local t = RootOf(root)
    if type(t) ~= "table" then return end
    -- what "unset" puts back: the frame as the feature made it
    local d = frame._rcFrameDef
    if not d then
        d = { strata = frame.GetFrameStrata and frame:GetFrameStrata() or nil,
              clamp = frame.IsClampedToScreen and (frame:IsClampedToScreen() and true or false) or nil }
        frame._rcFrameDef = d
    end
    local fp = type(t.framePos) == "table" and t.framePos or nil
    if fp and opts.scale == false and fp.scale ~= nil then
        fp = Copy(fp)
        fp.scale = nil
    end
    -- (a settings preview sample takes the look only: never a layer that
    -- could draw over the settings window)
    if not opts.sample and (fp or frame._rcFPSet) then
        if not frame._rcFPSet then d.scale = (opts.scale ~= false) and frame:GetScale() or nil end
        local ok = RC.UI:ApplyFramePosition(frame, fp or EMPTY, d)
        if ok then
            if not (fp and fp.level) and frame._zcBaseLevel then frame:SetFrameLevel(frame._zcBaseLevel) end
            frame._rcFPSet = fp ~= nil
        end
    end
    if opts.chrome ~= false then
        local ch = type(t.chrome) == "table" and t.chrome or nil
        if ch then
            RC.UI:ApplyChrome(frame, ch, nil, opts.parts)
            frame._rcChromeSet = true
        elseif frame._rcChromeSet then
            -- cleared: the pieces the standard made go, the feature repaints its own
            RC.UI:ApplyChrome(frame, { shadowSize = 0, glowSize = 0 }, nil, opts.parts)
            if frame._zcBg and frame._zcBg._zui_own then frame._zcBg:Hide() end
            if frame._zcBorder then for _, tx in pairs(frame._zcBorder) do if tx._zui_own then tx:Hide() end end end
            frame._rcChromeSet = nil
        end
    end
    if RC.Visibility and not opts.sample then
        if not frame._rcVisBound then
            frame._rcVisBound = true
            RC.Visibility.Register(frame, function()
                local r = RootOf(root)
                return type(r) == "table" and r.visibility or nil
            end, { control = "alpha", hoverFrame = opts.hoverFrame })
        else
            RC.Visibility.Refresh(frame)
        end
    end
end

-- The three cards a page adds for its frame, each in its own tab:
--   RC.UI:FrameLayerCard(parent, yPos, root, apply, opts)    Position
--   RC.UI:FrameVisibilityCard(parent, yPos, root, apply, opts) Behavior
--   RC.UI:FrameChromeCard(parent, yPos, root, apply, opts)    Look
-- root: the settings table (or fn); apply(): save + restyle the live frame.
-- Each returns the next yPos. opts.title, opts.scale = false, opts.fields.
local function CardW(card)
    local w = card and card.GetWidth and card:GetWidth()
    if type(w) == "number" and w > 240 then return math_min(460, w - 28) end
    return 420
end
-- ensure(): makes the root table when it does not exist yet (only when
-- something is set; just looking never writes a profile)
local function FamilyAccess(root, family, apply, ensure)
    local get, set = RC.UI:CustomAccess(function() return RootOf(root) end, family, nil, function()
        if RC.SaveConfigurationToProfile then RC:SaveConfigurationToProfile() end
        if apply then apply() end
    end)
    if ensure then
        local rawSet = set
        set = function(spec)
            if spec ~= nil and type(RootOf(root)) ~= "table" then ensure() end
            return rawSet(spec)
        end
    end
    return get, set
end
local function FinishCard(card, holder, y, yPos, note)
    y = y - holder:GetHeight() - 8
    if note then y = RC.UI:CreateHelpLine(card, 14, y, note) end
    card:SetContentHeight(math.abs(y) + 4)
    return yPos - card:GetHeight() - 15
end
-- RC.UI:CreateCustomFold(parent, { label, width, key, ctor = "CreateVisibilityPicker",
--     args = { ...that picker's opts }, changed = fn }) -> a section that builds
-- RC.UI[ctor](body, args) the first time it is opened (pooled like a picker)
function RC.UI:CreateCustomFold(parent, o)
    o = o or {}
    local W = o.width or 420
    local f = FoldUI(parent, W, o.label or RCL["Options"], function(body)
        local ctor = RC.UI[o.ctor]
        if type(ctor) ~= "function" then return nil end
        return ctor(RC.UI, body, o.args or {})
    end, o.changed, "card|" .. tostring(o.key or o.label or ""))
    function f:Refresh() if self.inner and self.inner.Refresh then self.inner:Refresh() end end
    f._rcOnAcquire = function(self) self:Sync() end
    return f
end
local function FoldLabel(fields, names)
    local out = {}
    for _, n in ipairs(names) do if not fields or fields[n[1]] then out[#out + 1] = n[2] end end
    return table.concat(out, ", ")
end
function RC.UI:FrameLayerCard(parent, yPos, root, apply, opts)
    opts = opts or EMPTY
    local card = RC:CreateSettingsCard(parent, yPos, opts.title or RCL["Frame layer and scale"])
    local g, s = FamilyAccess(root, "framePos", apply, opts.ensure)
    local f = { strata = true, level = true, clamp = true, scale = opts.scale ~= false }
    local W = CardW(card)
    local h = self:CreateCustomFold(card, { width = W, key = "framePos|" .. tostring(opts.title or ""),
        label = (opts.scale ~= false) and RCL["Layer, level, scale, keep on screen"] or RCL["Layer, level, keep on screen"],
        changed = function() return SpecSet(g) end, ctor = "CreateFramePositionPicker",
        args = { width = W, get = g, set = s, noAnchor = true, fields = f, defaults = opts.defaults } })
    h:SetPoint("TOPLEFT", card, "TOPLEFT", 14, -32)
    return FinishCard(card, h, -32, yPos, opts.note or RCL["Layer and level decide what it draws over; the mover keeps where it sits."])
end
function RC.UI:FrameVisibilityCard(parent, yPos, root, apply, opts)
    opts = opts or EMPTY
    local card = RC:CreateSettingsCard(parent, yPos, opts.title or RCL["Fade and opacity"])
    local g, s = FamilyAccess(root, "visibility", apply, opts.ensure)
    local W = CardW(card)
    local h = self:CreateCustomFold(card, { width = W, key = "visibility|" .. tostring(opts.title or ""),
        label = RCL["When it shows, opacity, mouseover, fades"],
        changed = function() return SpecSet(g) end, ctor = "CreateVisibilityPicker",
        args = { width = W, get = g, set = s,
            fields = opts.fields or { show = true, alpha = true, combatAlpha = true, mouseover = true, hoverAlpha = true, fadeIn = true, fadeOut = true } } })
    h:SetPoint("TOPLEFT", card, "TOPLEFT", 14, -32)
    return FinishCard(card, h, -32, yPos, opts.note or RCL["On top of its own show rules above: a rule that is not met fades it out."])
end
function RC.UI:FrameChromeCard(parent, yPos, root, apply, opts)
    opts = opts or EMPTY
    local card = RC:CreateSettingsCard(parent, yPos, opts.title or RCL["Frame edge and shadow"])
    local g, s = FamilyAccess(root, "chrome", apply, opts.ensure)
    local W = CardW(card)
    local fields = opts.fields or { bgColor = true, borderSize = true, borderColor = true, shadowSize = true, shadowColor = true, glowSize = true, glowColor = true }
    local h = self:CreateCustomFold(card, { width = W, key = "chrome|" .. tostring(opts.title or ""),
        label = FoldLabel(fields, { { "bgColor", RCL["Background"] }, { "borderSize", RCL["Border"] },
            { "shadowSize", RCL["Shadow"] }, { "glowSize", RCL["Glow"] } }),
        changed = function() return SpecSet(g) end, ctor = "CreateChromePicker",
        args = { width = W, get = g, set = s, defaults = opts.defaults, fields = fields } })
    h:SetPoint("TOPLEFT", card, "TOPLEFT", 14, -32)
    return FinishCard(card, h, -32, yPos, opts.note or RCL["Unset, the frame keeps its own look."])
end

-- A page whose tabs follow the standard order adds the frame's cards in
-- one line after its tab content:
--   yPos = RC.UI:FrameCardsForTab(tab, parent, yPos, root, apply, opts)
-- behavior -> fade, look -> edge, position -> layer (opts.scale = false for
-- a frame with its own scale, opts.chromeFields to limit the edge card,
-- opts.prefix = "Tracker " to name them for one of several frames).
function RC.UI:FrameCardsForTab(tab, parent, yPos, root, apply, opts)
    opts = opts or EMPTY
    local pre = opts.prefix
    if tab == "behavior" then
        return self:FrameVisibilityCard(parent, yPos, root, apply, { title = pre and (pre .. RCL["fade and opacity"]) or nil,
            ensure = opts.ensure, note = opts.visibilityNote })
    elseif tab == "look" then
        return self:FrameChromeCard(parent, yPos, root, apply, { title = pre and (pre .. RCL["edge and shadow"]) or nil,
            fields = opts.chromeFields, ensure = opts.ensure })
    elseif tab == "position" then
        return self:FrameLayerCard(parent, yPos, root, apply, { title = pre and (pre .. RCL["layer"]) or nil, scale = opts.scale,
            ensure = opts.ensure })
    end
    return yPos
end

-- ============================================================
-- POOLED CONSTRUCTORS
-- ============================================================
-- (called inside another pooled build, a picker is built plainly as part
-- of it; see THE POOL above)
for _, name in ipairs({ "CreateAnchorPicker", "CreateFramePositionPicker", "CreateLayoutPicker",
    "CreateVisibilityPicker", "CreateChromePicker", "CreateStateEditor", "CreateTextFormatPicker",
    "CreateSoundSpecPicker", "CreateTextElement", "CreateFrameElement", "CreateCustomFold",
    "CreateFontPicker", "CreateAnimationPicker" }) do
    local raw = RC.UI[name]
    if type(raw) == "function" then
        RC.UI[name] = function(selfUI, parent, opts) return Pool.Acquire(name, raw, selfUI, parent, opts) end
    end
end

-- a click on a preview sample opens the section its text sits in
if RC.CustomPick and not RC.CustomPick._rcFoldWrapped then
    local rawPick = RC.CustomPick.Pick
    RC.CustomPick._rcFoldWrapped = true
    RC.CustomPick.Pick = function(previewKey, elementKey)
        local g = elementKey and RC.CustomPick.groups[elementKey]
        local f = g and g.fold
        local opened = false
        if f and f.openKey and not f.isOpen then
            Folds.open[f.openKey] = true
            opened = true
        end
        local hasHandler = previewKey and RC.CustomPick.handlers[previewKey]
        if opened and not hasHandler then RC.UI:SetCustomFoldOpen(f.openKey, true, true, f) end
        return rawPick(previewKey, elementKey)
    end
end
