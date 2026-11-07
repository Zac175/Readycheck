-- Prints one version's notes from Readycheck_Extras/Changelog.lua as Markdown.
-- Used by the release workflow: lua5.1 .github/tools/changelog_md.lua <version>
local want = arg[1]
local noop = function() end
local stub = setmetatable({}, { __index = function() return noop end, __call = noop })
_G.C_Timer = { After = noop, NewTicker = function() return stub end }
_G.CreateFrame = function() return stub end
_G.UIParent = stub
_G.RCL = setmetatable({}, { __index = function(_, k) return k end })
_G.Readycheck = { db = {}, UI = { TEXT = {} } }
local ok, err = pcall(dofile, "Readycheck_Extras/Changelog.lua")
local CL = _G.Readycheck.Changelog
if not (CL and CL.versions) then
  io.stderr:write("could not read the changelog: " .. tostring(err) .. "\n"); os.exit(1)
end
local labels = { added = "Added", changed = "Changed", fixed = "Fixed", removed = "Removed" }
for _, v in ipairs(CL.versions) do
  if v.version == want then
    local out = { "## Readycheck " .. v.version .. (v.title and (" - " .. v.title) or ""), "" }
    for _, s in ipairs(v.sections or {}) do
      out[#out + 1] = "### " .. (labels[s.type] or s.type)
      for _, item in ipairs(s.items or {}) do out[#out + 1] = "- " .. item end
      out[#out + 1] = ""
    end
    io.write(table.concat(out, "\n"))
    os.exit(0)
  end
end
io.write("## Readycheck " .. tostring(want) .. "\n")
