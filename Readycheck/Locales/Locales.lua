------------------------------------------------------------------------
-- Readycheck - Localization Core
-- Defines RCL, the global locale table used everywhere as RCL["English string"].
-- Keys are always the English source strings; the metatable below returns the
-- key itself when no entry exists, so a missing translation falls back to
-- English instead of erroring. Loads right after Libs, before everything else.
-- Each language file (deDE.lua etc.) early-returns unless it matches
-- GetLocale(), then fills RCL with that language's translations, which is how
-- the single active table gets selected.
------------------------------------------------------------------------
RCL = setmetatable({}, { __index = function(_, k) return k end })

Readycheck = Readycheck or {}
Readycheck.L = RCL

-- Locale identity, exposed for the odd file that wants to branch (the
-- font system uses this to avoid Latin-only fonts on ru/ko/zh clients).
Readycheck.LOCALE = GetLocale and GetLocale() or "enUS"
