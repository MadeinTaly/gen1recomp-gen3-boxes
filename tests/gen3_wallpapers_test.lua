-- Gen 3 boot: extra wallpapers, skins and pointers in the cart's own PC.
-- Run from the engine root: luajit mods/gen3_box/tests/gen3_wallpapers_test.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local T = require("tests.modkit")
local SaveData = require("src.core.SaveData")
local DIR = "mods/gen3_box"

local LAST_WALLPAPER = 118 -- PESTO, the last of the mod's eighteen

local function load(options)
  local real = SaveData.loadOptions
  SaveData.loadOptions = function(fs)
    local o = real(fs); o.mods = o.mods or {}; o.mods.gen3_box = true
    o.modOptions = { gen3_box = options or {} }
    return o
  end
  local run = T.sdk.loadMod(DIR, { generation = 3, data = T.sdk.gen3Data() })
  SaveData.loadOptions = real
  return run
end

local function press(key)
  require("src.ui.game3.box_storage_ui").handleInput({ wasPressed = function(_, k) return k == key end })
end

local run = load()
T.eq(run.mod and run.mod.state, "loaded", "gira su gen 3: " .. tostring(run.mod and run.mod.skipReason))
T.eq(#run.errors, 0, "carica senza errori (" .. tostring(run.errors[1]) .. ")")

local BoxStorageUI = require("src.ui.game3.box_storage_ui")
local Storage = require("src.core.game3.storage")

local session = { version = "emerald" }
local storage = Storage.ensure(session)
local box = storage.boxes[storage.currentBox or 1]
BoxStorageUI.open, BoxStorageUI._session, BoxStorageUI._presentation = true, session, nil

-- ------- wallpapers: a theme, then a wallpaper (the cart's themes first)
BoxStorageUI.mode = "pick_wallpaper"
press("up")   -- from SCENERY 1 (the box's own), wraps to the last theme: RETRO
press("a")    -- RETRO: VAPORWAVE, ARCADE, LIBRARY
press("a")
T.eq(box.wallpaper, 105, "UP dal primo tema arriva a RETRO, A sceglie VAPORWAVE")
T.eq(BoxStorageUI.mode, "browse", "e chiude il picker")

BoxStorageUI.mode = "pick_wallpaper"
press("down") -- opens on RETRO (the box's theme), wraps to SCENERY 1
press("a"); press("a")
T.eq(box.wallpaper, 1, "DOWN dall'ultimo tema torna a SCENERY 1, A sceglie FOREST")

BoxStorageUI.mode = "pick_wallpaper"
press("a")    -- into SCENERY 1
press("b")    -- back to the themes, not out of the picker
T.eq(BoxStorageUI.mode, "pick_wallpaper", "B dagli sfondi torna ai temi")
press("b")
T.eq(BoxStorageUI.mode, "browse", "B dai temi chiude")

BoxStorageUI.mode = "pick_wallpaper_group" -- Ruby/Sapphire's theme menu is taken over too
press("b")
T.eq(BoxStorageUI.mode, "browse", "B chiude anche dal menu a gruppi di R/S")
T.eq(box.wallpaper, 1, "e non cambia lo sfondo")

-- ------- box menu: the cart's rows plus SKIN and POINTER before CANCEL
-- SWITCH BOX, WALLPAPER, ALL BOXES, WHAT'S NEW, SKIN, POINTER, CANCEL
BoxStorageUI.mode = "box_menu"
press("down"); press("down"); press("down"); press("down") -- SKIN
press("a")
press("down")                -- ORIGINAL -> MINIMAL, previewed live
press("b")                   -- back to the menu, preview undone
T.eq(BoxStorageUI.mode, "box_menu", "B dalla lista skin torna al menu del box")
press("up"); press("up"); press("up"); press("up") -- back to SWITCH BOX (cursor was left on SKIN)
press("a")                   -- the cart's own row: the cart runs it
T.eq(BoxStorageUI.mode, "pick_box", "SWITCH BOX e' eseguito dal gioco (pick_box)")

-- ------- WHAT'S NEW, Gen 3's own: from the box menu, B closes it
BoxStorageUI.mode = "box_menu"
press("down"); press("down"); press("down") -- WHAT'S NEW
press("a")
T.eq(BoxStorageUI.mode, "browse", "WHAT'S NEW dal menu del box chiude il menu")
press("right"); press("left")   -- turns pages, consumed by the popup
press("b")
T.eq(BoxStorageUI.mode, "browse", "B chiude WHAT'S NEW e torna al box")

-- ------- ALL BOXES: a Pokemon carried from box 1 to box 2
BoxStorageUI.mode = "browse"
local boxes = storage.boxes
local mon = { tag = "moved" }
boxes[1].mons[1], boxes[2].mons[1] = mon, nil
storage.currentBox = 1
press("select")              -- opens the view on box 1, slot 1
press("a")                   -- picks it up
T.eq(boxes[1].mons[1], nil, "A nella vista prende il Pokemon dallo slot")
for _ = 1, 6 do press("right") end -- off the right edge of box 1: the next box in the grid
press("a")                   -- puts it down
local landed
for b, bx in ipairs(boxes) do for s = 1, 30 do if bx.mons[s] == mon then landed = b end end end
T.check(landed ~= nil and landed ~= 1, "e lo posa in un altro box (" .. tostring(landed) .. ")")
press("a")                   -- picks it up again
press("b")                   -- leaves with it in hand: it goes back
local back
for b, bx in ipairs(boxes) do for s = 1, 30 do if bx.mons[s] == mon then back = b end end end
T.eq(back, landed, "uscendo con un Pokemon in mano torna al suo posto")
T.eq(storage.currentBox, landed, "lo schermo del gioco riapre sul box del cursore")
press("a")                   -- the view is closed: this is the cart's A again
T.check(BoxStorageUI.mode ~= nil, "dopo B l'input torna al gioco")

run.release()

-- ------- EXTRA WALLPAPERS off: the picker is the cart's sixteen
run = load({ gen3_wallpapers = false, gen3_card = false })
T.eq(#run.errors, 0, "carica anche con gli sfondi extra spenti")
BoxStorageUI = require("src.ui.game3.box_storage_ui")
BoxStorageUI.open, BoxStorageUI._session, BoxStorageUI._presentation = true, session, nil
box.wallpaper = 1
BoxStorageUI.mode = "pick_wallpaper"
press("up"); press("a"); press("a")
T.check(box.wallpaper < 101, "con l'opzione spenta UP dal primo resta tra quelli del gioco (" .. box.wallpaper .. ")")

-- PKMN DATA CARD off: the view still opens and works without the card
BoxStorageUI.mode = "browse"
press("select")
press("b")
T.eq(BoxStorageUI.mode, "browse", "ALL BOXES apre e chiude anche senza la carta")
run.release()

-- ------- the Gen 1/2 options on Gen 3
local Runtime = require("src.mods.Runtime")
local function startItems()
  local noop = function() end
  local items = { { id = "pokemon", label = "POKEMON", onSelect = noop },
                  { id = "exit", label = "EXIT", onSelect = noop } }
  return Runtime.call("ui.start_menu.items", function(_, it) return it end, { session = session }, items)
end

-- defaults: OPEN FROM START+PC puts BOXES after POKEMON
run = load()
local items = startItems()
T.eq(items[2] and items[2].label, "BOXES", "OPEN FROM START+PC: BOXES nel menu START dopo POKEMON")
run.release()

-- OPEN FROM PC, BOX HEALS on, FULL SCREEN off
run = load({ access = "pc", heal = true, fullscreen = false })
items = startItems()
T.eq(#items, 2, "OPEN FROM PC: nessuna voce BOXES nel menu START")
BoxStorageUI = require("src.ui.game3.box_storage_ui")
BoxStorageUI.open, BoxStorageUI._session, BoxStorageUI._presentation = true, session, nil
local hurt = { hp = 1, maxHp = 20, status = 8, moves = {} }
storage.boxes[3].mons[4] = hurt
pcall(BoxStorageUI.close)
T.eq(hurt.hp, 20, "BOX HEALS: chiudere il PC rimette gli HP al massimo")
T.eq(hurt.status, nil, "BOX HEALS: e toglie lo stato")
BoxStorageUI.open, BoxStorageUI._session, BoxStorageUI.mode = true, session, "browse"
local kept = { tag = "kept" }
storage.boxes[1].mons[1] = kept
press("select"); press("a")
T.eq(storage.boxes[1].mons[1], kept, "FULL SCREEN spento: SELECT non apre ALL BOXES (A non prende il Pokemon)")
run.release()

T.finish("gen3_wallpapers")
