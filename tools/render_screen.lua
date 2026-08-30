-- Draws the WHOLE box screen to a file, without a ROM and without a window.
--
-- render_wallpapers.lua draws one scene at one size, which is the right tool
-- for judging a pattern and the wrong one for judging a LAYOUT. Every fault
-- reported against FULL SCREEN has been about the layout: panels in a corner,
-- a scene filling 144 rows of a 244-row panel and leaving white under it, a
-- grid setting that stopped meaning anything. None of those are visible in a
-- wallpaper render, and all of them are obvious in a screen render.
--
--   cd <engine>
--   FULL=1 GRID=big WINW=1080 WINH=2160 OUT=/tmp/boxs \
--     PAPER_RAW=/tmp/raw POKEPORT_DATA_DIR=tests/fixture_data \
--     luajit mods/gen3_box/tools/render_screen.lua
--
-- Writes screen.rgb at the canvas size it chose and prints that size, so
-- tools/rgb_to_png.py (in gen3_dex) or any headerless-RGB viewer can show it.
-- PAPER_RAW is the layer dump from `check_wallpaper.py --raw`; without it the
-- painted wallpapers render as nothing and only the drawn ones show.

package.path = "./?.lua;./?/init.lua;" .. package.path
if not _G.love then _G.love = require("tests.love_stub") end

local OUT = os.getenv("OUT") or "/tmp/boxs"
local W, H = 160, 144 -- replaced once the screen has told us its surface

local buf, cur = {}, { 1, 1, 1, 1 }

local function clear()
  for i = 1, W * H * 3 do buf[i] = 255 end
end

-- ------- canvases, because the CLIPPING is the thing being looked at
--
-- Every wallpaper is painted into a canvas exactly the size of its panel and
-- blitted at the origin, which is how the mod clips a scene to a box without
-- guessing which space a scissor lives in. A stub that ignored canvases would
-- draw each panel's scene straight onto the screen, unclipped, and show a
-- layout the game never draws -- the one bug this file exists to catch.
--
-- So: a canvas is an RGBA buffer, setCanvas redirects the writes into it, and
-- drawing one composites it. Same code path as the real thing.
local target = nil -- nil = the screen

local function blend(x, y, r, g, b, a)
  x, y = math.floor(x), math.floor(y)
  a = math.max(0, math.min(1, a or 1))
  if target then
    if x < 0 or y < 0 or x >= target._w or y >= target._h then return end
    local B = target._buf
    local i = (y * target._w + x) * 4 + 1
    local oa = B[i + 3] or 0
    local na = a + oa * (1 - a)
    if na <= 0 then
      B[i], B[i + 1], B[i + 2], B[i + 3] = 0, 0, 0, 0
      return
    end
    B[i] = (r * a + (B[i] or 0) * oa * (1 - a)) / na
    B[i + 1] = (g * a + (B[i + 1] or 0) * oa * (1 - a)) / na
    B[i + 2] = (b * a + (B[i + 2] or 0) * oa * (1 - a)) / na
    B[i + 3] = na
    return
  end
  if x < 0 or y < 0 or x >= W or y >= H then return end
  local i = (y * W + x) * 3 + 1
  local function mix(old, new)
    return math.max(0, math.min(255, math.floor(old * (1 - a) + new * 255 * a)))
  end
  buf[i], buf[i + 1], buf[i + 2] = mix(buf[i], r), mix(buf[i + 1], g), mix(buf[i + 2], b)
end

local function px(x, y) blend(x, y, cur[1], cur[2], cur[3], cur[4]) end

-- a real transform stack: the scenes are drawn scaled and translated into
-- their panels, and a no-op translate would draw the bug this exists to find
local sc, ox, oy = 1, 0, 0
local stack = {}

local G = {}
function G.push() stack[#stack + 1] = { sc, ox, oy } end
function G.pop()
  local s = table.remove(stack)
  if s then sc, ox, oy = s[1], s[2], s[3] end
end
function G.origin() sc, ox, oy = 1, 0, 0 end
function G.scale(s) sc = sc * (s or 1) end
function G.translate(x, y) ox, oy = ox + (x or 0) * sc, oy + (y or 0) * sc end
function G.setColor(r, g, b, a) cur = { r or 1, g or 1, b or 1, a or 1 } end
local WINW = tonumber(os.getenv("WINW") or "1080")
local WINH = tonumber(os.getenv("WINH") or "2160")
function G.getDimensions() return WINW, WINH end
function G.clear(r, g, b, a)
  if target then
    local B, n = target._buf, target._w * target._h
    for i = 0, n - 1 do
      local o = i * 4 + 1
      B[o], B[o + 1], B[o + 2], B[o + 3] = r or 0, g or 0, b or 0, a or 1
    end
    return
  end
  local keep = cur
  cur = { r or 1, g or 1, b or 1, 1 }
  for y = 0, H - 1 do for x = 0, W - 1 do px(x, y) end end
  cur = keep
end

function G.newCanvas(w, h)
  local c = {
    _w = math.floor(w), _h = math.floor(h), _buf = {}, _canvas = true,
    getWidth = function(self) return self._w end,
    getHeight = function(self) return self._h end,
    setFilter = function() end,
  }
  for i = 1, c._w * c._h * 4 do c._buf[i] = 0 end
  return c
end

function G.setCanvas(c) target = c or nil end
function G.getCanvas() return target end

local function tx(x, y) return ox + x * sc, oy + y * sc end

function G.rectangle(mode, x, y, w, h)
  local x0, y0 = tx(x, y)
  w, h = w * sc, h * sc
  if mode == "fill" then
    for yy = y0, y0 + h - 1 do for xx = x0, x0 + w - 1 do px(xx, yy) end end
  else
    for xx = x0, x0 + w - 1 do px(xx, y0); px(xx, y0 + h - 1) end
    for yy = y0, y0 + h - 1 do px(x0, yy); px(x0 + w - 1, yy) end
  end
end

function G.circle(mode, cx, cy, r)
  local x0, y0 = tx(cx, cy)
  r = r * sc
  for yy = math.floor(y0 - r), math.ceil(y0 + r) do
    for xx = math.floor(x0 - r), math.ceil(x0 + r) do
      local dx, dy = xx - x0, yy - y0
      if dx * dx + dy * dy <= r * r then px(xx, yy) end
    end
  end
end

function G.line(x1, y1, x2, y2)
  local ax, ay = tx(x1, y1)
  local bx, by = tx(x2, y2)
  local steps = math.max(math.abs(bx - ax), math.abs(by - ay), 1)
  for i = 0, steps do
    px(ax + (bx - ax) * i / steps, ay + (by - ay) * i / steps)
  end
end

function G.polygon(mode, ...)
  local p = { ... }
  for i = 1, #p, 2 do p[i], p[i + 1] = tx(p[i], p[i + 1]) end
  local minY, maxY = math.huge, -math.huge
  for i = 2, #p, 2 do minY = math.min(minY, p[i]); maxY = math.max(maxY, p[i]) end
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

-- ------- an artist's layer, read from the raw dump (see render_wallpapers)
local RAW = os.getenv("PAPER_RAW")

local function u32(s, i)
  local a, b, c, d = s:byte(i, i + 3)
  return ((a * 256 + b) * 256 + c) * 256 + d
end

local imgCache = {}
function G.newImage(path)
  local name = tostring(path):match("([^/\\]+)%.png$")
  if imgCache[tostring(path)] ~= nil then return imgCache[tostring(path)] end
  local f = RAW and name and io.open(RAW .. "/" .. name .. ".rgba", "rb")
  if not f then
    local blank = setmetatable({},
      { __index = function() return function() return 0 end end })
    imgCache[tostring(path)] = blank
    return blank
  end
  local d = f:read("*a"); f:close()
  local img = {
    _w = u32(d, 1), _h = u32(d, 5), _d = d,
    getWidth = function(self) return self._w end,
    getHeight = function(self) return self._h end,
  }
  imgCache[tostring(path)] = img
  return img
end

-- one pixel of either kind: a loaded layer (packed bytes) or a canvas
-- (floats, already composited)
local function pixelOf(img, ix, iy)
  if img._d then
    local o = 8 + (iy * img._w + ix) * 4
    return img._d:byte(o + 1) / 255, img._d:byte(o + 2) / 255,
           img._d:byte(o + 3) / 255, img._d:byte(o + 4) / 255
  end
  local o = (iy * img._w + ix) * 4 + 1
  local B = img._buf
  return B[o] or 0, B[o + 1] or 0, B[o + 2] or 0, B[o + 3] or 0
end

function G.draw(img, x, y, _, sx, sy)
  if not (img and (img._d or img._buf)) then return end
  sx = sx or 1; sy = sy or sx
  local x0, y0 = tx(x or 0, y or 0)
  local step = sx * sc
  local limW = target and target._w or W
  local limH = target and target._h or H
  for iy = 0, img._h - 1 do
    local ry = y0 + iy * sy * sc
    if ry >= -step and ry < limH then
      for ix = 0, img._w - 1 do
        local rx = x0 + ix * step
        if rx >= -step and rx < limW then
          local r, g, b, a = pixelOf(img, ix, iy)
          if a > 0 then
            for py = 0, step - 1 do
              for pxx = 0, step - 1 do
                blend(rx + pxx, ry + py, r, g, b, a * (cur[4] or 1))
              end
            end
          end
        end
      end
    end
  end
end

love.graphics = setmetatable(G, { __index = function() return function() end end })

local T = require("tests.modkit")
local Data = require("src.core.Data")
Data:load()
local DIR = os.getenv("GEN3_BOX_DIR") or "mods/gen3_box"
local run = T.sdk.loadMod(DIR, { data = Data })
assert(#run.errors == 0, tostring(run.errors[1]))

local store = run.loader.modOptions.gen3_box or {}
run.loader.modOptions.gen3_box = store
store.grid = os.getenv("GRID") or "big"
store.fullscreen = os.getenv("FULL") == "1"
store.peek = os.getenv("PEEK") ~= "0"

-- MONS=n puts n Pokemon in every box, taken from the dataset in dex order.
-- An empty box shows the wallpaper and nothing else, which is half the
-- screen: the picture a cell draws is the other half, and whether it sits on
-- a white card over the scene is exactly the kind of thing only a render
-- answers.
local boxes = {}
local roster = {}
for id, def in pairs(Data.pokemon) do
  if def.dex then roster[#roster + 1] = id end
end
table.sort(roster, function(a, b) return Data.pokemon[a].dex < Data.pokemon[b].dex end)
local MONS = tonumber(os.getenv("MONS") or "0")
for i = 1, 12 do
  boxes[i] = {}
  for j = 1, math.min(MONS, 20) do
    local id = roster[((j - 1) % math.max(1, #roster)) + 1]
    if id then
      boxes[i][j] = { species = id, level = 5, hp = 20,
                      stats = { hp = 20 }, moves = {} }
    end
  end
end
local screen = Data.screens.Gen3Box.new({
  data = Data,
  save = { boxes = boxes, currentBox = 1, party = {} },
  stack = { push = function() end, pop = function() end, top = function() end },
  input = { wasPressed = function() return false end },
})

-- WALLS names one wallpaper per box -- `SKY:2,FOREST,PLAIN` -- so a render
-- can show several scenes at once the way the screen really does. They go
-- into the mod's SAVE, which is where a box's paper actually lives.
local walls = {}
for spec in (os.getenv("WALLS") or ""):gmatch("[^,]+") do
  local id, art = spec:match("^(%w+):(%d+)$")
  walls[#walls + 1] = { id = id or spec, art = tonumber(art) or 1 }
end
if #walls > 0 then
  run.loader.modSave = run.loader.modSave or {}
  local save = run.loader.modSave.gen3_box or {}
  run.loader.modSave.gen3_box = save
  local papers = {}
  for i = 1, 12 do papers[i] = walls[((i - 1) % #walls) + 1] end
  save.boxPapers = papers
end

-- NEWS=<n> apre il popup delle novita' su quella pagina: e' testo dentro un
-- riquadro, e se una riga sborda o una pagina e' piu' lunga del riquadro lo
-- si vede qui e da nessun'altra parte
local NEWS = tonumber(os.getenv("NEWS") or "0")
if NEWS > 0 then screen.news = { page = NEWS } else screen.news = nil end

local L = screen.layout()
W, H = L.w, L.h
if store.fullscreen then
  local Renderer = require("src.render.Renderer")
  Renderer.uiWidth, Renderer.uiHeight = W, H
end

clear()
local ok, err = pcall(function() screen:draw() end)
if not ok then print("FAILED: " .. tostring(err)) end

os.execute("mkdir -p " .. OUT)
local f = assert(io.open(OUT .. "/screen.rgb", "wb"))
local bytes = {}
for i = 1, W * H * 3 do bytes[i] = string.char(buf[i] or 255) end
f:write(table.concat(bytes))
f:close()
print(string.format("rendered %dx%d (cell %d, %dx%d panels) -> %s/screen.rgb",
  W, H, L.cell, L.acrossN or 1, L.downN or 1, OUT))
