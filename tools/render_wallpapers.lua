-- Renders the drawn wallpapers to files, without a ROM and without a screen.
--
-- A pattern that lives only as code cannot be judged by reading it, and for
-- three releases nobody had looked at these: the forest was a field of green
-- dots, the snow was invisible on white, the cave was a beige wall with teeth
-- at the edges. This is what makes them visible.
--
-- It does not reimplement anything. It stubs love.graphics with a tiny
-- rasteriser, asks the real screen for its real drawWallpaper, and writes the
-- frames out as raw RGB -- so what comes out is what the game draws. It found
-- a bug the first time it ran: NIGHT was passing a NEGATIVE alpha to
-- setColor, which LOVE tolerates in silence and this does not.
--
--   cd <engine>
--   PAPER_OUT=/tmp/papers PAPER_FRAMES=16 PAPER_STEP=14 \
--     POKEPORT_DATA_DIR=tests/fixture_data \
--     luajit mods/gen3_box/tools/render_wallpapers.lua
--
-- PAPER_FRAMES > 1 writes <ID>_00.rgb ... for an animation; 1 writes <ID>.rgb.
-- Convert with any tool that reads headerless RGB at 160x144.

package.path = "./?.lua;./?/init.lua;" .. package.path
if not _G.love then _G.love = require("tests.love_stub") end

-- CLASSIC by default; PAPER_W/PAPER_H render the same call at BIG's 320x288,
-- which is the only way to see what the other grid size does to a pattern.
local W = tonumber(os.getenv("PAPER_W") or "160")
local H = tonumber(os.getenv("PAPER_H") or "144")
local OUT = os.getenv("PAPER_OUT") or "/tmp/papers"

local buf, cur = {}, { 1, 1, 1, 1 }

local function clear()
  for i = 1, W * H * 3 do buf[i] = 255 end
end

local function blend(x, y, r, g, b, a)
  x, y = math.floor(x), math.floor(y)
  if x < 0 or y < 0 or x >= W or y >= H then return end
  a = math.max(0, math.min(1, a or 1))
  local i = (y * W + x) * 3 + 1
  local function mix(old, new)
    return math.max(0, math.min(255, math.floor(old * (1 - a) + new * 255 * a)))
  end
  buf[i], buf[i + 1], buf[i + 2] = mix(buf[i], r), mix(buf[i + 1], g), mix(buf[i + 2], b)
end

local function px(x, y) blend(x, y, cur[1], cur[2], cur[3], cur[4]) end

-- A real transform stack, because BIG is the CLASSIC scene at scale two and
-- a no-op scale() would render the exact bug it is meant to prove fixed: the
-- scene sitting in a 160x144 corner of a 320x288 canvas.
local sc, stack = 1, {}

local G = {}
function G.push() stack[#stack + 1] = sc end
function G.pop() sc = table.remove(stack) or 1 end
function G.scale(s) sc = sc * (s or 1) end
function G.setColor(r, g, b, a) cur = { r or 1, g or 1, b or 1, a or 1 } end
function G.getDimensions() return W, H end

function G.rectangle(mode, x, y, w, h)
  x, y, w, h = x * sc, y * sc, w * sc, h * sc
  if mode == "fill" then
    for yy = y, y + h - 1 do for xx = x, x + w - 1 do px(xx, yy) end end
  else
    for xx = x, x + w - 1 do px(xx, y); px(xx, y + h - 1) end
    for yy = y, y + h - 1 do px(x, yy); px(x + w - 1, yy) end
  end
end

function G.circle(mode, cx, cy, r)
  cx, cy, r = cx * sc, cy * sc, r * sc
  local r2 = r * r
  if mode == "fill" then
    for yy = math.floor(cy - r), math.ceil(cy + r) do
      for xx = math.floor(cx - r), math.ceil(cx + r) do
        local dx, dy = xx - cx, yy - cy
        if dx * dx + dy * dy <= r2 then px(xx, yy) end
      end
    end
  else
    for a = 0, 360, 4 do
      local rad = a * math.pi / 180
      px(cx + r * math.cos(rad), cy + r * math.sin(rad))
    end
  end
end

function G.line(x1, y1, x2, y2)
  x1, y1, x2, y2 = x1 * sc, y1 * sc, x2 * sc, y2 * sc
  local steps = math.max(math.abs(x2 - x1), math.abs(y2 - y1), 1)
  for i = 0, steps do
    px(x1 + (x2 - x1) * i / steps, y1 + (y2 - y1) * i / steps)
  end
end

function G.polygon(mode, ...)
  local p = { ... }
  for i = 1, #p do p[i] = p[i] * sc end
  local minY, maxY = math.huge, -math.huge
  for i = 2, #p, 2 do
    minY = math.min(minY, p[i]); maxY = math.max(maxY, p[i])
  end
  for yy = math.floor(minY), math.ceil(maxY) do
    local xs, n = {}, #p / 2
    for i = 1, n do
      local x1, y1 = p[(i - 1) * 2 + 1], p[(i - 1) * 2 + 2]
      local j = (i % n) + 1
      local x2, y2 = p[(j - 1) * 2 + 1], p[(j - 1) * 2 + 2]
      if (y1 <= yy and y2 > yy) or (y2 <= yy and y1 > yy) then
        xs[#xs + 1] = x1 + (yy - y1) / (y2 - y1) * (x2 - x1)
      end
    end
    table.sort(xs)
    for k = 1, #xs - 1, 2 do
      for xx = math.floor(xs[k]), math.ceil(xs[k + 1]) do px(xx, yy) end
    end
  end
end

-- anything else the screen reaches for is a no-op: this draws wallpapers,
-- not text or sprites
love.graphics = setmetatable(G, { __index = function() return function() end end })

local T = require("tests.modkit")
local Data = require("src.core.Data")
Data:load()
local DIR = os.getenv("GEN3_BOX_DIR") or "mods/gen3_box"
local run = T.sdk.loadMod(DIR, { data = Data })
assert(#run.errors == 0, tostring(run.errors[1]))

local store = run.loader.modOptions.gen3_box or {}
run.loader.modOptions.gen3_box = store
store.grid = "classic"

local boxes = {}
for i = 1, 12 do boxes[i] = {} end
local screen = Data.screens.Gen3Box.new({
  data = Data,
  save = { boxes = boxes, currentBox = 1, party = {} },
  stack = { push = function() end, pop = function() end, top = function() end },
  input = { wasPressed = function() return false end },
})

local function writeRaw(name)
  local f = assert(io.open(OUT .. "/" .. name .. ".rgb", "wb"))
  local bytes = {}
  for i = 1, W * H * 3 do bytes[i] = string.char(buf[i]) end
  f:write(table.concat(bytes))
  f:close()
end

local FRAMES = tonumber(os.getenv("PAPER_FRAMES") or "1")
local STEP = tonumber(os.getenv("PAPER_STEP") or "12")

-- PAPER_ART renders every artist of every scene rather than only the drawn
-- one: an image style is cropped, scaled and tiled by drawArt, and none of
-- that is visible from the file on disk.
local ART = os.getenv("PAPER_ART")
local ONLY = os.getenv("PAPER_ONLY")
local art = run.loader.exports.gen3_box.wallpaperArt or {}

for _, w in ipairs(run.loader.exports.gen3_box.wallpapers) do
  if w.palette and (not ONLY or ONLY == w.id) then
    local styles = (ART and art[w.id]) or { false }
    for si, style in ipairs(styles) do
      local tag = w.id
      if ART then tag = w.id .. "_" .. (style.by or si):gsub("%W", "") end
      for f = 0, FRAMES - 1 do
        screen.paperTick = f * STEP
        clear()
        screen.drawWallpaper(w, W, H, style or nil)
        writeRaw(FRAMES > 1 and (tag .. "_" .. string.format("%02d", f)) or tag)
      end
      print("rendered: " .. tag .. " (" .. FRAMES .. " frame, " .. W .. "x" .. H .. ")")
    end
  end
end
