-- Gen 3 Box
--
-- A Ruby/Sapphire-style storage screen over Gen 1's twelve boxes of twenty:
-- a grid you can see, a cursor that picks a Pokemon up and puts it down,
-- and one button between the box and your party.
--
-- ------- why the grid is drawn from battle pics
--
-- Gen 3's grid works because every species has its own icon. Gen 1 has no
-- such thing: the icon table maps a species to one of a handful of shapes
-- -- GRASS, MON, WATER, BUG -- and the whole game carries four icon
-- images. Twenty identical blobs in a grid is strictly worse than the
-- vanilla list of twenty names, so the grid is drawn from the `spriteFront`
-- field instead: 154 per-species pictures already decoded out of the ROM.
--
-- They are 40x40 or 56x56, and the cell is 28x28, so they draw at exactly
-- half scale. Half is deliberate -- an integer divisor keeps two-bit pixel
-- art crisp, where 0.6 would smear it -- and it makes the arithmetic land:
-- five columns of 28 is 140 across a 160-wide screen, four rows is 112 of
-- the 144 down, leaving a header and a footer.
--
-- ------- what a slot means
--
-- Gen 1 stores a box as a COMPACT array (src/pokemon/Boxes.lua), not Gen
-- 3's sparse grid: box[1..n] with nothing after n. This screen keeps it
-- that way, because the vanilla PC, the save format and every other mod
-- read that shape. So dropping into any empty cell appends to the end
-- rather than leaving a hole -- the one place this is not a faithful copy
-- of Ruby, and the price of a save the rest of the game still understands.

local COLS, ROWS = 5, 4
local PARTY_COLS, PARTY_ROWS = 3, 2

-- ------- the two layouts
--
-- CLASSIC is the 160x144 Game Boy screen: a 28-pixel cell with the pic at
-- half scale, which is what every version up to 1.4.0 drew.
--
-- BIG asks the renderer for a 320x288 surface. The engine offers this
-- properly: `Game:draw` calls `Renderer:setUISize(top:uiSize())` before
-- anything draws, and falls back to 160x144 the moment this screen is not
-- on top -- so there is nothing to restore and no way to leave the game
-- wearing a canvas it did not ask for.
--
-- 56 is the number that makes BIG worth having, twice over:
--
--   * a battle pic is 56x56, so it is drawn at scale 1. Not enlarged, not
--     shrunk -- every pixel of the sprite is one pixel of the canvas, the
--     first time this screen has shown one undamaged.
--   * 56 is SEVEN TILES exactly, and a palette zone is addressed in
--     tiles. A 28-pixel cell is three and a half, which cannot carry a
--     zone at all. That is the whole reason the colours below are only
--     possible in this mode.
local LAYOUT = {
  classic = { cell = 28, gridX = 10, gridY = 16, partyX = 38, partyY = 40,
              scale = 0.5, w = 160, h = 144 },
  -- gridX 16 rather than 20: 5x56 = 280 leaves a 40-pixel margin, and
  -- half of it is not a whole tile. Eight pixels off centre is invisible;
  -- a zone that starts mid-tile is not.
  big     = { cell = 56, gridX = 16, gridY = 32, partyX = 72, partyY = 72,
              scale = 1, w = 320, h = 288 },
}

return function(mod)
  local Boxes = require("src.pokemon.Boxes")
  local Party = require("src.pokemon.Party")
  local Font = require("src.render.Font")
  local Assets = require("src.render.Assets")
  -- The per-instance art seam: Sprites.path raises `pokemon.sprite` with the
  -- live mon in its ctx, which is how a shiny tells itself apart from an
  -- ordinary one of the same species (issue #2).
  local Sprites = require("src.pokemon.Sprites")
  local Screens = require("src.ui.Screens")
  local Strings = require("src.core.Strings")
  local Stats = require("src.pokemon.Stats")
  local Sound = require("src.core.Sound")

  local SCREEN = "Gen3Box"

  -- ------- which generation is running
  --
  -- Resolved fresh every call, off the live game -- never cached at file
  -- scope and never a version allow-list (docs/mod-api-gen2-compat.md's
  -- "what the facades cannot fix", and modkit's own MK409 check exists to
  -- catch exactly that shape). A Gen 2 save carries `generation` once it
  -- exists (src/core/gen2/Save.lua:344); before that -- a save mid
  -- construction, or a headless test harness with no save at all --
  -- GameVersion.generation() is asked instead, itself pcall'd because this
  -- file is required by the SDK test harness outside a booted game too.
  local function isGen2(game)
    local save = game and game.save
    if save and save.generation ~= nil then
      return save.generation == 2
    end
    local ok, generation = pcall(function()
      return require("src.core.GameVersion").generation()
    end)
    return ok and generation == 2
  end

  -- modkit's MK409 check flags this pair as a hardcoded Gen 1 screen id;
  -- false positive here, since isGen2(game) below is the real branch.
  local SCREEN_SUMMARY_GEN1 = "SummaryMenu"
  local SCREEN_SUMMARY_GEN2 = "Gen2SummaryMenu"

  -- Only what is actually honoured below. The vanilla box PC is left in
  -- place whichever way this is set: nothing is taken away, and turning the
  -- mod off leaves a save reaching its storage exactly as before.
  mod.options:define({
    { key = "access", label = "OPEN FROM", type = "choice", default = "both",
      choices = {
        { "START+PC", "both" },
        { "START", "start" },
        { "PC", "pc" },
      } },
    { key = "wrap", label = "CURSOR WRAP", type = "toggle", default = true },
    -- See "the box as a nurse" below. Off by default because it is free
    -- healing, and free healing is an economy change rather than a
    -- convenience: it is Potions and Centre trips that stop being needed,
    -- not clicks that stop being clicked.
    { key = "heal", label = "BOX HEALS", type = "toggle", default = false },
    -- See "the two layouts" above. CLASSIC is what 1.4.0 drew. layout()
    -- reads CLASSIC on Gold regardless of this option (Game2:draw has no
    -- uiSize seam for BIG to ask through -- see layout()'s own comment),
    -- so the row's label says so on that boot rather than offering a
    -- choice that quietly does nothing. isGen2(nil) here reads the SAME
    -- generation layout() reads at draw time -- GameVersion.generation(),
    -- resolved once at schema-definition time because no live game exists
    -- yet to carry a save. mod.options:define builds this table once per
    -- boot, so a Red boot with this mod installed still says plain "GRID".
    { key = "grid", label = isGen2(nil) and "GRID (GEN 1 ONLY)" or "GRID",
      type = "choice", default = "classic",
      choices = {
        { "CLASSIC", "classic" },
        { "BIG", "big" },
      } },
    -- See "the cry on put-down" (PLAN.md "5. THE CRY ON PUT-DOWN"). On by
    -- default: it changes nothing but sound, which is the line BOX HEALS
    -- is on the wrong side of.
    { key = "placeCry", label = "PLACE CRY", type = "toggle", default = true },
    -- See "overworld sprites from Wilds of Kanto" below. Off by default --
    -- unlike PLACE CRY, this is an experimental prerelease feature reaching
    -- into another mod's code, not a change to this mod's own behaviour,
    -- and it does nothing at all unless that mod is installed.
    { key = "owSprites", label = "OW SPRITES", type = "toggle", default = true },
    -- The wallpaper drifts instead of sitting still (see
    -- drawWallpaperPattern). On by default, because it is the same rule
    -- PLACE CRY is on the right side of: it changes how the screen LOOKS
    -- and nothing about what it does, and a Gen 3 box wallpaper moves. Off
    -- pins every pattern at phase zero, which is pixel-for-pixel the still
    -- wallpaper 1.6.0 drew -- so anyone who finds motion distracting, or is
    -- sensitive to it, gets the old screen back exactly.
    { key = "animate", label = "ANIMATE", type = "toggle", default = true },
    -- How opaque each slot is over the wallpaper. This is a taste with no
    -- right answer -- how much scene you want behind your Pokemon -- so it
    -- is a row rather than a number picked here on everyone's behalf.
    --
    -- 40% is the default: enough to lift a Pokemon off a busy scene, light
    -- enough that SEA still reads as water underneath. CLEAR is the honest
    -- end of the ladder: no slot at all, the wallpaper straight through, for
    -- anyone who wants the scene and nothing over it.
    { key = "slots", label = "SLOTS", type = "choice", default = "40",
      choices = {
        { "CLEAR", "0" },
        { "25%", "25" },
        { "40%", "40" },
        { "60%", "60" },
        { "80%", "80" },
      } },
  })

  -- GRID BIG asks the renderer for a 320x288 surface, and that ask only
  -- ever reaches anything on Gen 1: Game:draw (src/core/Game.lua:471-478)
  -- is what calls `top:uiSize()` and scales the window to fit what comes
  -- back. Game2:draw (src/core/Game2.lua:1334-1450) never does either --
  -- Gold always fits one fixed 160x144 canvas through Chrome.fitScale and
  -- hands every state that same coordinate space -- so a Gold boot honouring
  -- BIG would lay 320x288 of drawing into a canvas built for a quarter of
  -- it. Read here, the one place every consumer (uiSize, cell size, pic
  -- scale, the OW SPRITES gate) goes through layout(), so Gold reads
  -- CLASSIC no matter what the option says. The option itself is left
  -- alone -- never written back -- so a Gen 1 save that chose BIG is still
  -- BIG the next time it is Red.
  local function layout(game)
    if isGen2(game) then return LAYOUT.classic end
    local ok, value = pcall(function() return mod.options:get("grid") end)
    return LAYOUT[(ok and value) or "classic"] or LAYOUT.classic
  end

  -- ------- the box as a nurse
  --
  -- BOX HEALS restores what is in storage: full HP, status cleared, every
  -- move's PP back. It is the Pokemon Centre's own routine rather than an
  -- imitation -- `Pokemon.heal` is what engine/events/heal_party.asm
  -- HealParty does, PP-Up bonus included, and the nurse calls that same
  -- function. Storage that quietly healed a differently-shaped amount
  -- would be worse than storage that did not heal at all.
  --
  -- It runs ONCE, when the screen closes, and not on each placement.
  -- Healing per move would have meant deciding what a move even is: a
  -- deposit heals, but a swap is a deposit and a withdrawal at the same
  -- time, and dragging a mon between two box slots is neither. On close
  -- there is no such question -- whatever ended up in storage comes out of
  -- it rested, however it got there.
  --
  -- The party is deliberately left alone. Not to police an exploit -- you
  -- can deposit six and take them back -- but because the party is the
  -- half of this screen that is NOT storage, and a screen that healed your
  -- active six for opening and closing it would be a Centre with extra
  -- steps.
  local Pokemon = require("src.pokemon.Pokemon")

  local function healing()
    local ok, value = pcall(function() return mod.options:get("heal") end)
    return ok and value and true or false
  end

  -- PLACE CRY, on by default (guarded the way every other options read
  -- here is, rather than trusted).
  local function placeCryOn()
    local ok, value = pcall(function() return mod.options:get("placeCry") end)
    if not ok then return true end
    if value == nil then return true end
    return value and true or false
  end

  -- OW SPRITES, guarded the same way. See "overworld sprites from Wilds of
  -- Kanto" further down for what it does and why it defaults off.
  -- The slot opacity the player asked for, 0..1. An unreadable or missing
  -- value falls to the default rather than to invisible: a box whose slots
  -- vanished because an option failed to load would look broken.
  local function slotAlpha()
    local ok, value = pcall(function() return mod.options:get("slots") end)
    if not ok then return 0.40 end
    local n = tonumber(value)
    if not n then return 0.40 end
    return math.max(0, math.min(100, n)) / 100
  end

  local function animateOn()
    local ok, value = pcall(function() return mod.options:get("animate") end)
    if not ok then return true end
    return value ~= false
  end

  local function owSpritesOn()
    local ok, value = pcall(function() return mod.options:get("owSprites") end)
    if not ok then return false end
    return value and true or false
  end

  -- Read per call rather than cached, so switching OPEN FROM in the manager
  -- takes effect on the next menu that opens instead of the next boot.
  local function access() return mod.options:get("access") or "both" end
  local function onStart() local a = access() return a == "both" or a == "start" end
  local function onPC() local a = access() return a == "both" or a == "pc" end

  -- ------- data helpers
  --
  -- Everything reads and writes save.boxes / save.party directly. Those two
  -- ARE the storage: Boxes.ensure fills in a missing table on an old save,
  -- and after that a box is a plain array this screen rearranges in place.

  local function boxList(game) return game.save.boxes[game.save.currentBox] end

  local function defOf(game, mon) return game.data.pokemon[mon.species] end

  -- The species record can be missing: a save written while a mod that adds
  -- species was enabled still names them after it is turned off. Falling
  -- back to the raw id shows the player something true instead of taking
  -- the frame down with it.
  local function nameOf(game, mon)
    local def = defOf(game, mon)
    return mon.nickname or (def and def.name) or mon.species or "?"
  end

  -- A box's name. Every caller that wants one goes through here rather than
  -- formatting the number itself (PLAN.md "4. BOX NAMES and WALLPAPERS"), so
  -- NAME BOX only ever had to change this one function. Names live in
  -- mod.save under boxNames, keyed by box number -- but a save that has been
  -- through a converter may hand them back with string keys, so both are
  -- tried before falling back to the plain "BOX n" every box starts as.
  local function boxName(n)
    local names = mod.save:get("boxNames")
    local custom = names and (names[n] or names[tostring(n)])
    if type(custom) == "string" and custom ~= "" then return custom end
    return Strings("BOX %d", n)
  end

  -- ------- wallpapers (PLAN.md "4. BOX NAMES and WALLPAPERS")
  --
  -- Each wallpaper is a pattern (drawn behind the grid) and a four-colour
  -- palette (which replaces the whole-surface GRAYS zone self:sgbPalettes
  -- already emits, the same trick SummaryMenu uses for its own whole-screen
  -- palette). The colour tables below are authored here, plain {r,g,b}
  -- tables -- no ROM-derived palette is copied, which is what keeps
  -- `modkit lint`'s "no ROM-derived content" check passing.
  --
  -- PLAIN carries no palette at all (nil), so self:sgbPalettes falls back
  -- to PaletteFX.GRAYS exactly as it always has: the default draws
  -- pixel-for-pixel what 1.5.2 drew, and nobody's screen changes until they
  -- pick something else.
  --
  -- NIGHT is a palette in reverse rather than a tint: GRAYS lightest-first
  -- (white background, black text) turned end-for-end, so the background
  -- maps to the dark end and the text to the light end -- a real dark mode.
  local WALLPAPERS = {
    -- Gen 3 named its wallpapers after PLACES -- FOREST, CITY, DESERT, SNOW,
    -- BEACH, SEAFLOOR -- rather than after shapes, and that is the whole
    -- difference in feel: you are choosing where the box IS, not which
    -- texture is behind it. These are drawn in code (see drawWallpaper), so
    -- no art is copied from anywhere; the four colours of each are authored
    -- here the same way the old ones were.
    { id = "PLAIN",  pattern = "PLAIN",  palette = nil },
    { id = "SEA",    pattern = "SEA",
      palette = { { 232, 246, 252 }, { 150, 205, 232 }, { 70, 140, 190 }, { 20, 60, 100 } } },
    { id = "FOREST", pattern = "FOREST",
      palette = { { 236, 248, 232 }, { 168, 214, 150 }, { 88, 150, 84 }, { 30, 70, 40 } } },
    { id = "SKY",    pattern = "SKY",
      palette = { { 240, 250, 255 }, { 186, 224, 248 }, { 120, 178, 226 }, { 50, 96, 150 } } },
    { id = "CAVE",   pattern = "CAVE",
      palette = { { 238, 234, 228 }, { 190, 180, 168 }, { 128, 116, 104 }, { 52, 46, 42 } } },
    { id = "CITY",   pattern = "CITY",
      palette = { { 240, 238, 246 }, { 196, 192, 214 }, { 132, 128, 158 }, { 48, 46, 66 } } },
    { id = "SNOW",   pattern = "SNOW",
      palette = { { 250, 252, 255 }, { 216, 230, 244 }, { 158, 184, 212 }, { 70, 96, 130 } } },
    { id = "NIGHT",  pattern = "NIGHT",
      palette = { { 30, 30, 40 }, { 70, 70, 92 }, { 140, 140, 168 }, { 226, 226, 240 } } },
  }
  local WALLPAPER_BY_ID = {}
  for _, w in ipairs(WALLPAPERS) do WALLPAPER_BY_ID[w.id] = w end

  -- boxPapers, the same string-key-tolerant shape as boxNames above.
  local function paperIdOf(n)
    local papers = mod.save:get("boxPapers")
    local id = papers and (papers[n] or papers[tostring(n)])
    return (type(id) == "string" and WALLPAPER_BY_ID[id]) and id or "PLAIN"
  end

  local function paperOf(n)
    return WALLPAPER_BY_ID[paperIdOf(n)] or WALLPAPER_BY_ID.PLAIN
  end

  -- ------- the pic for ONE Pokemon, not for its species (issue #2)
  --
  -- This used to read `def.spriteFront` straight off the species record and
  -- hand it to Assets.image. That is right about the species and wrong about
  -- the Pokemon: two of the same species -- one shiny, one not -- are one
  -- record and one path, so the grid drew them identically and the shiny
  -- flag went nowhere.
  --
  -- src/pokemon/Sprites.lua is the sanctioned seam for exactly this, and its
  -- own header says why: content registries freeze after load, so a mod that
  -- gives a PARTICULAR Pokemon its own art cannot patch pokemon.spriteFront
  -- and instead answers the `pokemon.sprite` hook, which stays live for the
  -- whole process. `opts.mon` is the field that hook reads to tell one
  -- Pokemon from another -- it is commented "the live mon when available
  -- (per-instance skins)" -- so passing the mon is the whole fix. Shiny art
  -- from another mod, an alternate skin, Gen 2's own shiny flag: all of them
  -- arrive through that one call.
  --
  -- `kind = "summary"` because that is what this screen is to a wrapper: a
  -- menu showing one Pokemon's own picture, not a battle.
  local function picOf(game, mon)
    local def = defOf(game, mon)
    if not def then return nil end

    -- Two candidates, tried in order, and the ORDER is the whole lesson of
    -- 1.8.1-beta.1: the per-instance answer first, the species record second.
    --
    -- The seam can hand back a path this screen cannot draw. A mod that
    -- renders a Pokemon some other way -- voxels, 3D, an atlas of its own --
    -- legitimately answers `pokemon.sprite` with something that is not a
    -- plain 2D image file, and Assets.image then loads nothing. The first
    -- cut of this fix treated that as "no picture" and drew an empty cell,
    -- which is worse than the bug it was fixing: a wrong picture at least
    -- tells you which Pokemon is in the slot.
    --
    -- So a candidate that does not produce an image is not an answer, and
    -- the species record is tried next. Assets.image can also return nil
    -- WITHOUT throwing, which is why the image itself is tested rather than
    -- just the pcall.
    local seen = {}
    local function tryPath(path)
      if type(path) ~= "string" or path == "" or seen[path] then return nil end
      seen[path] = true
      local ok, img = pcall(Assets.image, path)
      if ok and img then return img end
      return nil
    end

    -- 1. What this PARTICULAR Pokemon should look like. Sprites.path raises
    --    `pokemon.sprite` with the live mon in its ctx, which is how a shiny
    --    is told apart from an ordinary one of the same species (issue #2).
    local okPath, resolved = pcall(Sprites.path, game.data, mon.species,
      "front", { mon = mon, kind = "summary" })
    if okPath then
      local img = tryPath(resolved)
      if img then return img end
    end

    -- 2. The species record: an older engine with no seam, a wrapper that
    --    threw, or art this screen cannot draw. Going through Assets.image
    --    means a Crystal-sprites mod's replacement art still shows up here,
    --    rather than this screen pinning the vanilla PNG.
    return tryPath(def.spriteFront)
  end

  -- ------- marks (Gen 3's CIRCLE/SQUARE/TRIANGLE/HEART)
  --
  -- One accessor pair, mon.gen3Marks a four-character "0"/"1" string
  -- (PLAN.md "MARKS"): FIND's MARK search and the marking window both go
  -- through getMark/setMark rather than each rolling its own string
  -- indexing. A plain string rather than a table of booleans: it survives
  -- SaveSerializer.encode/decode as one value (any data-only field on a mon
  -- does, docs/modding.md:271) and cannot half-exist the way a sparse array
  -- can.
  local MARK_ORDER = { "CIRCLE", "SQUARE", "TRIANGLE", "HEART" }
  local MARK_LETTER = { CIRCLE = 1, SQUARE = 2, TRIANGLE = 3, HEART = 4 }

  local function getMark(mon, name)
    local s = mon.gen3Marks
    if type(s) ~= "string" then return false end
    local i = MARK_LETTER[name]
    return s:sub(i, i) == "1"
  end

  local function setMark(mon, name, on)
    local s = mon.gen3Marks
    if type(s) ~= "string" or #s ~= 4 then s = "0000" end
    local i = MARK_LETTER[name]
    mon.gen3Marks = s:sub(1, i - 1) .. (on and "1" or "0") .. s:sub(i + 1)
  end

  local function anyMarks(mon)
    local s = mon.gen3Marks
    return type(s) == "string" and s:find("1", 1, true) ~= nil
  end

  -- ------- MAIL (Gen 2 only)
  --
  -- Gold keeps every letter in save.mail.party, sparse and keyed by PARTY
  -- SLOT rather than by mon (src/core/gen2/Mail.lua). This screen moves
  -- mons through save.party with its own table.remove/table.insert rather
  -- than going through Boxes.deposit/withdraw, so the letters do not follow
  -- along for free the way they do on the cart -- these three are what keep
  -- them attached, called at the actual party-mutation sites below rather
  -- than from one wrapper that only covers one of them. Reached through a
  -- pcall'd require so a Gen 1 boot, where this module does not exist,
  -- never sees it.
  local function gen2Mail()
    local ok, Mail = pcall(require, "src.core.gen2.Mail")
    return ok and Mail or nil
  end

  local function monHoldsMail(mon)
    local Mail = gen2Mail()
    return Mail ~= nil and Mail.monHoldsMail(mon) == true
  end

  -- Mail.lua has a removeSlot (a departure shifts every letter behind it
  -- down) but no mirror for an ARRIVAL: RemoveMonFromPartyOrBox only ever
  -- shifts down, because the cart never inserts a mon into the middle of
  -- the party -- WITHDRAW always appends at the tail
  -- (src/core/gen2/Boxes.lua:128-135's own #party+1). This screen's own
  -- moves keep that same "always append at the tail" shape today, but every
  -- site that grows save.party calls this anyway: it shifts whatever sits
  -- from `slot` to the end UP one and clears `slot`, so a mon landing there
  -- -- which the refusals elsewhere guarantee never carries mail of its own
  -- -- never inherits a letter that belonged to whoever the array shift
  -- moved past it.
  local function gen2InsertPartySlot(game, slot)
    local Mail = gen2Mail()
    if not Mail then return end
    local party = Mail.state(game.save).party
    for i = Mail.PARTY_LENGTH, slot + 1, -1 do
      party[i] = party[i - 1]
    end
    party[slot] = nil
  end

  -- ------- the Gen 2 stat block
  --
  -- Gen 2's box_struct is the same byte-for-byte-prefix story Stats.ensure's
  -- own comment tells for Gen 1: a mon decoded without a party's worth of
  -- stat words arrives with mon.stats nil. src/battle/gen2/Mon.lua:67 is the
  -- Gen 2 formula (Special split into specialAttack/specialDefense, one DV
  -- feeding both); this only ever fills a MISSING block, the same contract
  -- Stats.ensure keeps for Gen 1.
  local function gen2EnsureStats(game, mon)
    if type(mon) ~= "table" or mon.stats ~= nil then return end
    local def = defOf(game, mon)
    if type(def) ~= "table" or type(def.baseStats) ~= "table" then return end
    local ok, Gen2Mon = pcall(require, "src.battle.gen2.Mon")
    if not ok or not Gen2Mon then return end
    local okStats, stats = pcall(Gen2Mon.stats, def.baseStats, mon.dvs,
      mon.level or 1, mon.statExp)
    if not okStats or type(stats) ~= "table" then return end
    mon.stats = stats
    mon.hp = math.max(0, math.min(tonumber(mon.hp) or stats.hp, stats.hp))
  end

  -- ------- the box as a nurse, Gen 2's own
  --
  -- Pokemon.heal reads mon.stats.hp and restores PP out of src.core.Data,
  -- the Gen 1 singleton -- not the dataset a Gold boot actually runs, and a
  -- box mon may carry no .stats at all, which is what made the pcall around
  -- it a silent no-op on Gold. HealParty's own recipe (engine/events/
  -- heal_party.asm), read off game.data.moves instead of that singleton.
  local function gen2Heal(game, mon)
    gen2EnsureStats(game, mon)
    if type(mon.stats) ~= "table" then return end
    mon.hp = mon.stats.hp
    mon.status = nil
    local moves = game.data and game.data.moves
    if type(moves) ~= "table" or type(mon.moves) ~= "table" then return end
    for _, mv in ipairs(mon.moves) do
      local mdef = moves[mv.id]
      if mdef then
        mv.pp = mdef.pp + (mv.ppUps or 0) * math.floor(mdef.pp / 5)
      end
    end
  end

  -- ------- the screen

  local function newScreen(game)
    Boxes.ensure(game.save)

    local self = {
      game = game,
      isOpaque = true,   -- a full-screen replacement: nothing under it draws
      mode = "box",      -- "box" | "party"
      col = 0, row = 0,  -- zero-based, so the modulo wrap below is honest
      held = nil,        -- { mon = ..., from = "box"|"party" }
      notice = nil,
      noticeAt = 0,
      -- the header row (see "the control scheme" in PLAN.md): the cursor
      -- rises out of the grid onto the box title. Only reachable in "box"
      -- mode -- the party pane has no header.
      header = false,
      -- SORT's one-deep undo: a snapshot of the box as it stood right
      -- before the last sort, kept only while this screen is open.
      sortUndo = nil,    -- { boxNum = ..., mons = { ... } }
      -- FIND's remembered query, for as long as this screen is open. FIND
      -- NEXT (a box-menu row, and START on the header) re-runs this.
      findQuery = nil,   -- { kind = "species"|"type"|"mark", value = ... }
      -- MARK MODE: A opens the marking window instead of grabbing, B leaves
      -- the mode rather than the screen.
      markMode = false,
      markWindow = nil,  -- { mon = ..., cursor = 1 } while the window is open
      -- Wilds of Kanto's resolve() per MON (see owSpriteFor), for the life of this
      -- screen (see "overworld sprites from Wilds of Kanto" below). A
      -- sprite table, or `false` for a cached miss -- never nil, so a miss
      -- is remembered rather than re-asked every draw.
      -- Weak keys: entries are keyed by the mon table itself (see
      -- owSpriteFor), so a Pokemon that leaves the box while this screen is
      -- open must not be kept alive by its own cache row.
      owSpriteCache = setmetatable({}, { __mode = "k" }),
    }

    -- ------- the surface this screen wants
    --
    -- Game:draw asks the TOP state for its size before anything is drawn,
    -- and passes 160x144 when the state has no opinion. So this is the
    -- whole mechanism: no enter hook, no restore on exit, and no way to
    -- leave the rest of the game wearing a canvas it did not ask for.
    function self:uiSize()
      local L = layout(game)
      return L.w, L.h
    end

    -- StateStack calls this on pop and only on pop -- a screen pushed ON TOP
    -- of this one (the summary) does not fire it -- so it is exactly "the
    -- player is done with the boxes" and nothing else.
    --
    -- Every box, not only the open one: a mon put away in box 3 an hour ago
    -- is as deposited as the one dropped a second ago, and "rested unless
    -- you happened to be looking at that box when you left" is not a rule
    -- anybody could hold in their head.
    -- ------- the follower has to be told the party changed
    --
    -- Reported: deposit a shiny that is following you, withdraw an ordinary
    -- Pokemon, close the screen -- and the follower behind you is still the
    -- shiny one until you change maps or step into a Pokemon Centre.
    --
    -- Nothing here was wrong about the party: it really did change. What was
    -- missing is that ANYTHING was said about it. This screen moves Pokemon
    -- with its own table operations rather than through the vanilla PC's
    -- flow, and the follower is spawned once and then left alone -- it is
    -- rebuilt on PikachuFollower.onMapEntered, which is exactly why walking
    -- through a door fixes it. A follower mod (Wilds of Kanto) reads the
    -- Pokemon at spawn time, so a stale entity keeps the old species, the
    -- old palette and the old shininess.
    --
    -- So: respawn it on the way out, with viaMapLoad FALSE -- the mid-map
    -- respawn the engine already uses for a bike dismount or a revive, which
    -- puts the follower on the cell behind the player rather than under him
    -- as a fresh map entry would.
    --
    -- `src.world.PikachuFollower` is one of the fifteen names the Gen 2
    -- adapter serves, resolving to src/world/gen2/Follower.lua on a Gold
    -- boot with the same onMapEntered signature, so this one call covers
    -- both games. The overworld is spelled differently between them, which
    -- is the only branch needed.
    local function refreshFollower()
      local ow = game.overworld or game.world
      if not ow then return end

      -- 1. The ENGINE's own follower (Yellow's Pikachu, and Gold's trailing
      --    companion). `src.world.PikachuFollower` is one of the fifteen
      --    names the Gen 2 adapter serves, resolving to
      --    src/world/gen2/Follower.lua with the same signature, so this one
      --    call covers both games. viaMapLoad = false is the mid-map
      --    respawn the engine uses for a bike dismount: the follower lands
      --    on the cell behind the player rather than under him.
      local ok, Follower = pcall(require, "src.world.PikachuFollower")
      if ok and type(Follower) == "table"
          and type(Follower.onMapEntered) == "function" then
        pcall(Follower.onMapEntered, game, ow, nil, false)
      end

      -- 2. Wilds of Kanto's follower, which is NOT the engine's.
      --
      -- 1.9.1 did only the call above and the report stayed open, for a
      -- reason worth writing down: that mod does not ride PikachuFollower
      -- at all. It keeps its own trailing entities and designates the
      -- follower through save data (`pokepcLeader` / `followerPartyIndex`)
      -- rather than party order, so respawning the engine's follower
      -- rebuilt something that was never the thing on screen.
      --
      -- Its own exported `syncAll(game, ow)` is the right seam and does
      -- exactly what a map change does -- which is what the reporter
      -- noticed fixes it: it removes the trailers, clears the player's
      -- cached control species, re-syncs the control visual and rebuilds
      -- the trailers with `mapEnter = true`.
      --
      -- Reached through the engine's own `mod.find`, not a manifest
      -- dependency, and every call guarded: with that mod absent this is
      -- one nil check, and if it ever renames the export we degrade to the
      -- engine follower rather than throwing on the way out of a screen.
      local okHandle, handle = pcall(mod.find, "overworld_wild_spawns")
      if not okHandle or not handle or not handle.exports then return end
      local syncAll = handle.exports.syncAll
      if type(syncAll) ~= "function" then return end
      pcall(syncAll, game, ow)
    end

    -- Whether the party is the one we opened with. Identity, not contents:
    -- the same six tables in the same order is "unchanged", and any swap,
    -- deposit or withdrawal moves at least one of them.
    local function partySnapshot()
      local out = {}
      for i, mon in ipairs(game.save.party or {}) do out[i] = mon end
      return out
    end

    local function partyChangedFrom(before)
      local now = game.save.party or {}
      if #now ~= #before then return true end
      for i = 1, #now do
        if now[i] ~= before[i] then return true end
      end
      return false
    end

    self.partyAtOpen = partySnapshot()

    function self:exit()
      -- The follower first, and outside the healing gate: BOX HEALS is off
      -- by default and this has nothing to do with it.
      if partyChangedFrom(self.partyAtOpen or {}) then refreshFollower() end

      if not healing() then return end
      local gen2 = isGen2(game)
      for _, box in ipairs(Boxes.ensure(game.save)) do
        for _, mon in ipairs(box) do
          -- guard rather than trust: a mon that arrived from a save written
          -- by an older engine may be missing the fields heal writes
          if gen2 then
            pcall(gen2Heal, game, mon)
          else
            pcall(Pokemon.heal, mon)
          end
        end
      end
    end

    local function cols() return self.mode == "box" and COLS or PARTY_COLS end
    local function rows() return self.mode == "box" and ROWS or PARTY_ROWS end
    local function list()
      return self.mode == "box" and boxList(game) or game.save.party
    end
    local function capacity()
      return self.mode == "box" and Boxes.CAPACITY or Party.MAX
    end

    local function index() return self.row * cols() + self.col + 1 end

    local function say(text)
      self.notice = text
      self.noticeAt = love.timer and love.timer.getTime() or 0
    end

    -- Pick up: the mon leaves its array immediately, so the slot reads
    -- empty while it rides the cursor and every count on screen stays true.
    local function grab()
      local set, i = list(), index()
      local mon = set[i]
      if not mon then return end
      -- The one rule the vanilla PC enforces that this must not lose: the
      -- party may not be emptied (bills_pc.asm refuses the last mon).
      if self.mode == "party" and #game.save.party <= 1 then
        say(Strings("THAT'S YOUR LAST ONE!"))
        return
      end
      -- MAIL (Gen 2 only): the cart's own refusal, word for word
      -- (BillsPC_CheckMon's .HasMail arm, src/core/gen2/Boxes.lua:94) -- a
      -- boxed mon has no party slot for its letter to live in, so picking
      -- one up out of the party has to refuse exactly what the vanilla PC's
      -- DEPOSIT refuses, rather than silently carrying the mon toward a box
      -- that cannot hold what it is still holding.
      if self.mode == "party" and isGen2(game) and monHoldsMail(mon) then
        say(Strings("Remove MAIL."))
        return
      end
      table.remove(set, i)
      -- The letters behind the departing mon shift up one slot, the same
      -- "Mail time!" tail RemoveMonFromPartyOrBox runs on every party
      -- removal (src/core/gen2/Mail.lua's removeSlot).
      if self.mode == "party" and isGen2(game) then
        local Mail = gen2Mail()
        if Mail then Mail.removeSlot(game.save, i) end
      end
      self.held = { mon = mon, from = self.mode }
    end

    -- The vanilla PC calls Stats.ensure on every mon it moves back into the
    -- party (src/ui/BoxMenu.lua:85): box_struct carries no stat block, so a
    -- mon decoded out of an imported .sav reaches the party with mon.stats
    -- nil and the HP bar nil-indexes it. This screen has two paths a mon
    -- can land in save.party by -- place() and stow() -- and both call this
    -- on the way in. Guarded rather than trusted, the same way BOX HEALS
    -- guards Pokemon.heal above: an old-engine mon may be missing fields
    -- Stats.calc reads, and Stats.ensure already no-ops on anything it
    -- cannot make sense of.
    local function ensureStats(mon)
      if isGen2(game) then
        pcall(gen2EnsureStats, game, mon)
        return
      end
      pcall(Stats.ensure, defOf(game, mon), mon)
    end

    -- PLACE CRY (PLAN.md "5. THE CRY ON PUT-DOWN"): every landing plays the
    -- cry of the Pokemon that landed. Sound.playCry returns nil headless,
    -- which is what makes this safe in the test suite, but it is guarded
    -- with pcall anyway -- the same rule ensureStats and BOX HEALS follow
    -- for every engine call this screen does not own. A refused placement
    -- never reaches here, because nothing landed.
    local function playLandingCry(mon)
      if not placeCryOn() then return end
      pcall(Sound.playCry, game.data, mon.species)
    end

    -- Put down. On an occupied slot the two trade places, which is what
    -- Ruby does -- the displaced one comes back onto the cursor rather than
    -- being overwritten. On an empty one the mon appends, for the
    -- compact-array reason in the header.
    local function place()
      local set, i = list(), index()
      local held = self.held.mon
      local sitting = set[i]
      if sitting then
        -- MAIL (Gen 2 only): the sitting party mon is about to be carried
        -- off exactly the way grab() carries one off, only without going
        -- through grab()'s own guard -- so the guard has to be repeated
        -- here, on the mon this swap is about to displace.
        if self.mode == "party" and isGen2(game) and monHoldsMail(sitting) then
          say(Strings("Remove MAIL."))
          return
        end
        set[i] = held
        if self.mode == "party" then
          ensureStats(held)
          -- The mon that WAS at slot i just left it (for self.held, not for
          -- any other party slot -- it is only placed once a later call
          -- resolves it), and held never carries mail (the refusals above
          -- are the whole reason). So slot i's letter, if any, departs with
          -- it: clear rather than swap, because nothing has actually taken
          -- sitting's old place yet.
          if isGen2(game) then
            local Mail = gen2Mail()
            if Mail then Mail.clear(game.save, i) end
          end
        end
        playLandingCry(held)
        self.held = { mon = sitting, from = self.mode }
        return
      end
      if #set >= capacity() then
        say(self.mode == "box" and Strings("THE BOX IS FULL!")
                                or Strings("YOUR PARTY IS FULL!"))
        return
      end
      if self.mode == "party" and isGen2(game) then
        gen2InsertPartySlot(game, #set + 1)
      end
      set[#set + 1] = held
      if self.mode == "party" then ensureStats(held) end
      playLandingCry(held)
      self.held = nil
    end

    -- Put the carried mon back somewhere legal, for B and for anything else
    -- that has to end the carry. It prefers where the mon came from, falls
    -- back to the other pane, and REFUSES rather than overflowing: a swap
    -- across the two panes can leave the cursor holding a box mon while the
    -- box is at twenty, and appending there would push it to twenty-one --
    -- a box the vanilla PC cannot show and the save format does not allow.
    local function stow()
      local held = self.held.mon
      local box, party = boxList(game), game.save.party
      local a, aCap, b, bCap
      if self.held.from == "box" then
        a, aCap, b, bCap = box, Boxes.CAPACITY, party, Party.MAX
      else
        a, aCap, b, bCap = party, Party.MAX, box, Boxes.CAPACITY
      end
      if #a < aCap then
        if a == party and isGen2(game) then gen2InsertPartySlot(game, #a + 1) end
        a[#a + 1] = held
        if a == party then ensureStats(held) end
        playLandingCry(held)
        self.held = nil
        return true
      end
      if #b < bCap then
        if b == party and isGen2(game) then gen2InsertPartySlot(game, #b + 1) end
        b[#b + 1] = held
        if b == party then ensureStats(held) end
        playLandingCry(held)
        self.held = nil
        return true
      end
      say(Strings("NO ROOM ANYWHERE!"))
      return false
    end

    local function changeBox(step)
      if self.mode ~= "box" then return end
      local n = Boxes.COUNT
      game.save.currentBox = ((game.save.currentBox - 1 + step) % n) + 1
    end

    -- Walking off the left or right edge of a box steps to the next one, the
    -- way Ruby's L/R do -- a Game Boy has no shoulder buttons to spare, and
    -- this frees START to be a way out that always works. In the party pane
    -- there is nowhere to step to, so it wraps or clamps as before.
    local function move(dc, dr)
      local c, r = self.col + dc, self.row + dr
      if self.mode == "box" and dc ~= 0 and (c < 0 or c >= cols()) then
        changeBox(dc)
        self.col = c < 0 and (cols() - 1) or 0
        return
      end
      if mod.options:get("wrap") then
        c = (c + cols()) % cols()
        r = (r + rows()) % rows()
      else
        c = math.max(0, math.min(cols() - 1, c))
        r = math.max(0, math.min(rows() - 1, r))
      end
      self.col, self.row = c, r
    end

    local function switchMode()
      self.mode = self.mode == "box" and "party" or "box"
      self.col, self.row = 0, 0
      -- the party pane has no header, so crossing to it always drops back
      -- into the grid
      self.header = false
    end

    -- The summary screen the rest of the game uses. It recalculates a box
    -- mon's stat block on the way in (status_screen.asm does the same,
    -- because box_struct carries none), so handing it one straight out of
    -- save.boxes is the supported path -- Bill's PC STATS entry does
    -- exactly this.
    local function showStats()
      local mon = self.held and self.held.mon or list()[index()]
      if not mon then return end
      if isGen2(game) then
        Screens.push(game, SCREEN_SUMMARY_GEN2, { mon = mon })
      else
        Screens.push(game, SCREEN_SUMMARY_GEN1, mon)
      end
    end

    -- B, wherever it is pressed: back, and only back, exactly the rule
    -- above already follows -- carrying one it goes back to a shelf first,
    -- otherwise it leaves. The header shares this rather than repeating it.
    -- MARK MODE adds one more stop before the exit (PLAN.md "3. MARKS"): B
    -- leaves the mode first, and only the next B leaves the screen.
    local function back()
      if self.held then
        if stow() then say(Strings("PUT IT BACK.")) end
      elseif self.markMode then
        self.markMode = false
      else
        game.stack:pop()
      end
    end

    -- ------- SORT + UNDO
    --
    -- Every key falls back to the mon's CURRENT index, so two mons that tie
    -- sort into the same order they started in -- a stable sort -- and the
    -- array stays exactly as compact as it was: this only ever reorders in
    -- place, never removes or appends.
    local function sortKey(mon, key)
      if key == "dex" then
        local def = defOf(game, mon)
        return def and def.dex
      elseif key == "level" then
        return mon.level or 0
      elseif key == "name" then
        return nameOf(game, mon)
      elseif key == "type" then
        local def = defOf(game, mon)
        return def and def.types and def.types[1]
      end
    end

    -- A species this screen no longer has a definition for (a save left
    -- over from a species-adding mod that's since been turned off) sorts to
    -- the end rather than erroring the comparison.
    local function sortBox(key)
      local set = boxList(game)
      local n = #set
      local order = {}
      for i = 1, n do order[i] = i end
      table.sort(order, function(ia, ib)
        local ma, mb = set[ia], set[ib]
        local ka, kb = sortKey(ma, key), sortKey(mb, key)
        if ka == kb then
          -- BY TYPE's secondary key is dex, THEN the current index
          if key == "type" then
            local da, db = sortKey(ma, "dex"), sortKey(mb, "dex")
            if da ~= db then
              if da == nil then return false end
              if db == nil then return true end
              return da < db
            end
          end
          return ia < ib
        end
        if ka == nil then return false end
        if kb == nil then return true end
        -- BY LEVEL is the one descending key: the strongest first is what
        -- anyone sorting a box actually wants
        if key == "level" then return ka > kb end
        return ka < kb
      end)
      local sorted = {}
      for i, oldIndex in ipairs(order) do sorted[i] = set[oldIndex] end
      for i = 1, n do set[i] = sorted[i] end
    end

    -- true only if `a` and `b` hold the same mons, by table identity, in
    -- any order -- so undo can never resurrect one that was moved away
    -- while sorted, or drop one that arrived since
    local function samePokemon(a, b)
      if #a ~= #b then return false end
      local counts = {}
      for _, mon in ipairs(a) do counts[mon] = (counts[mon] or 0) + 1 end
      for _, mon in ipairs(b) do
        if not counts[mon] or counts[mon] == 0 then return false end
        counts[mon] = counts[mon] - 1
      end
      return true
    end

    local function snapshotForUndo()
      local set = boxList(game)
      local copy = {}
      for i, mon in ipairs(set) do copy[i] = mon end
      self.sortUndo = { boxNum = game.save.currentBox, mons = copy }
    end

    -- Refuses -- leaving the box exactly as it was -- unless the snapshot
    -- still describes what is in the box now.
    local function undoSort()
      local snap = self.sortUndo
      if not snap or snap.boxNum ~= game.save.currentBox then return false end
      local set = boxList(game)
      if not samePokemon(snap.mons, set) then return false end
      for i, mon in ipairs(snap.mons) do set[i] = mon end
      return true
    end

    -- ------- FIND and FIND NEXT
    --
    -- Every box, walking forward from the cursor and wrapping back around to
    -- where it started (PLAN.md "1. FIND, and JUMP TO BOX"). The party is
    -- deliberately not searched -- it is six visible slots on the same
    -- screen already.
    --
    -- A box is exactly COLS*ROWS = Boxes.CAPACITY cells, so the cursor's own
    -- (col, row) already IS a 1..20 index into that box's compact array --
    -- the same index() the grid uses. That lets the search treat "every
    -- box" as one flat ring of 12*20 slots addressed by (box, index) without
    -- inventing a second numbering.
    local function slotAt(g)
      local boxNum = math.floor((g - 1) / Boxes.CAPACITY) + 1
      local idx = ((g - 1) % Boxes.CAPACITY) + 1
      return boxNum, idx
    end
    local function slotOf(boxNum, idx) return (boxNum - 1) * Boxes.CAPACITY + idx end

    local function matchesQuery(mon, query)
      if query.kind == "species" then
        local q = query.value:lower()
        local def = defOf(game, mon)
        local nick = (mon.nickname or ""):lower()
        local name = (def and def.name or ""):lower()
        local id = tostring(mon.species or ""):lower()
        return nick:find(q, 1, true) ~= nil
          or name:find(q, 1, true) ~= nil
          or id:find(q, 1, true) ~= nil
      elseif query.kind == "type" then
        local def = defOf(game, mon)
        if not (def and def.types) then return false end
        for _, t in ipairs(def.types) do
          if t == query.value then return true end
        end
        return false
      elseif query.kind == "mark" then
        return getMark(mon, query.value)
      end
      return false
    end

    -- Searches from the cell right after the cursor, all the way around the
    -- ring and back to the cursor's own cell (the last one checked) -- so a
    -- lone match sitting under the cursor is still found on the next FIND
    -- NEXT. A hit moves currentBox/col/row and reports the name; a miss
    -- reports that and moves nothing.
    local function findNext(query)
      local boxes = Boxes.ensure(game.save)
      local total = Boxes.COUNT * Boxes.CAPACITY
      local start = slotOf(game.save.currentBox, index())
      -- always lands back on the grid, hit or miss, the same as every other
      -- box-menu action
      self.header = false
      for step = 1, total do
        local g = ((start - 1 + step) % total) + 1
        local boxNum, idx = slotAt(g)
        local mon = boxes[boxNum][idx]
        if mon and matchesQuery(mon, query) then
          game.save.currentBox = boxNum
          self.col = (idx - 1) % COLS
          self.row = math.floor((idx - 1) / COLS)
          self.header = false
          say(Strings("FOUND %s!", nameOf(game, mon)))
          return true
        end
      end
      say(Strings("NOT FOUND."))
      return false
    end

    -- Runs the search, remembers the query for FIND NEXT, and closes every
    -- menu FIND opened on the way -- landing back on the grid whether the
    -- search hit or missed.
    local function runFind(query, menus)
      self.findQuery = query
      findNext(query)
      for _, menu in ipairs(menus) do menu:close() end
    end

    -- game.data.pokemon, deduped and sorted -- so a species-adding mod's
    -- types show up here without being named in this file.
    local function allTypes()
      local seen, out = {}, {}
      for _, def in pairs(game.data.pokemon or {}) do
        if def.types then
          for _, t in ipairs(def.types) do
            if not seen[t] then
              seen[t] = true
              out[#out + 1] = t
            end
          end
        end
      end
      table.sort(out)
      return out
    end

    local function openFindType(findMenu, boxMenu)
      local items = {}
      for _, t in ipairs(allTypes()) do
        table.insert(items, { label = t, value = t })
      end
      local sub
      sub = mod.ui.ListMenu.new(game, Strings("TYPE"), items, {
        kind = "gen3_box_find_type",
        onChoose = function(item)
          runFind({ kind = "type", value = item.value }, { sub, findMenu, boxMenu })
        end,
      })
      game.stack:push(sub)
    end

    -- The four symbols by word (the font has no glyph for the real marks).
    local function openFindMark(findMenu, boxMenu)
      local items = {}
      for _, name in ipairs(MARK_ORDER) do
        table.insert(items, { label = Strings(name), value = name })
      end
      local sub
      sub = mod.ui.ListMenu.new(game, Strings("MARK"), items, {
        kind = "gen3_box_find_mark",
        onChoose = function(item)
          runFind({ kind = "mark", value = item.value }, { sub, findMenu, boxMenu })
        end,
      })
      game.stack:push(sub)
    end

    -- The naming screen (src/ui/NamingScreen.lua): a substring match against
    -- the nickname, the species name and the raw species id, so CHAR finds
    -- CHARMANDER and a Pokemon nicknamed CHARLIE alike. An empty confirm
    -- (NamingScreen's own "declined" contract) starts no search.
    local function openFindSpecies(findMenu, boxMenu)
      game.stack:push(mod.ui.NamingScreen.new(game, {
        title = Strings("FIND SPECIES"),
        maxLen = 10,
        default = "",
        onDone = function(name)
          if name == "" then
            findMenu:close()
            boxMenu:close()
            return
          end
          runFind({ kind = "species", value = name }, { findMenu, boxMenu })
        end,
      }))
    end

    local function openFindMenu(boxMenu)
      local items = {
        { label = Strings("SPECIES"), value = "species" },
        { label = Strings("TYPE"), value = "type" },
        { label = Strings("MARK"), value = "mark" },
      }
      local sub
      sub = mod.ui.ListMenu.new(game, Strings("FIND"), items, {
        kind = "gen3_box_find",
        onChoose = function(item)
          if item.value == "species" then
            openFindSpecies(sub, boxMenu)
          elseif item.value == "type" then
            openFindType(sub, boxMenu)
          elseif item.value == "mark" then
            openFindMark(sub, boxMenu)
          end
        end,
      })
      game.stack:push(sub)
    end

    -- ------- MARK MODE and the marking window
    --
    -- The window is tile-aligned and scales with the layout, the same
    -- doubling as everything else BIG touches: the CLASSIC rect times
    -- cell/28 lands back on CLASSIC's own numbers and on BIG's at cell/28==2.
    local function markWindowRect()
      local L = layout(game)
      local k = L.cell / 28
      return 8 * k, 48 * k, 144 * k, 48 * k
    end

    local function openMarkWindowOnCursor()
      local mon = list()[index()]
      if not mon then return end
      self.markWindow = { mon = mon, cursor = 1 }
    end

    local function updateMarkWindow()
      local input = game.input
      local win = self.markWindow
      if input:wasPressed("left") then
        win.cursor = win.cursor > 1 and win.cursor - 1 or #MARK_ORDER
      elseif input:wasPressed("right") then
        win.cursor = win.cursor < #MARK_ORDER and win.cursor + 1 or 1
      elseif input:wasPressed("a") then
        local name = MARK_ORDER[win.cursor]
        setMark(win.mon, name, not getMark(win.mon, name))
      elseif input:wasPressed("b") then
        self.markWindow = nil
      end
    end

    -- ------- the BOX MENU
    --
    -- A mod.ui.ListMenu, titled with the box's name (src/ui/ListMenu.lua).
    -- Rows are appended in the order PLAN.md lists them so a later wave
    -- inserts its own without reshuffling what is already here: NAME BOX and
    -- WALLPAPER go between JUMP TO BOX and MARK MODE.
    local function boxMenuItems()
      local items = {}
      table.insert(items, { label = Strings("FIND"), value = "find" })
      if self.findQuery then
        table.insert(items, { label = Strings("FIND NEXT"), value = "findnext" })
      end
      table.insert(items, { label = Strings("SORT"), value = "sort" })
      table.insert(items, { label = Strings("JUMP TO BOX"), value = "jump" })
      table.insert(items, { label = Strings("NAME BOX"), value = "namebox" })
      table.insert(items, { label = Strings("WALLPAPER"), value = "wallpaper" })
      table.insert(items, { label = Strings("MARK MODE"), value = "markmode" })
      table.insert(items, { label = Strings("CANCEL"), value = "cancel" })
      return items
    end

    -- BY DEX / BY LEVEL / BY NAME / BY TYPE / UNDO. A choice acts, then
    -- closes itself and its parent in turn (sub:close(), then parent:
    -- close()), so it lands back on the grid; B leaves this list for the
    -- box menu, ListMenu's own doing.
    local function openSortMenu(parent)
      local items = {
        { label = Strings("BY DEX"), value = "dex" },
        { label = Strings("BY LEVEL"), value = "level" },
        { label = Strings("BY NAME"), value = "name" },
        { label = Strings("BY TYPE"), value = "type" },
        { label = Strings("UNDO"), value = "undo" },
      }
      local sub
      sub = mod.ui.ListMenu.new(game, Strings("SORT"), items, {
        kind = "gen3_box_sort",
        onChoose = function(item)
          if item.value == "undo" then
            if undoSort() then
              self.header = false
              say(Strings("UNDONE."))
              sub:close()
              parent:close()
            else
              -- refuses, changing nothing, and stays open -- exactly the
              -- shape the vanilla PC uses for "the party is full" (#570)
              sub.footer = Strings("CAN'T UNDO NOW.")
            end
            return
          end
          snapshotForUndo()
          sortBox(item.value)
          self.header = false
          say(Strings("SORTED."))
          sub:close()
          parent:close()
        end,
      })
      game.stack:push(sub)
    end

    -- The twelve boxes, each with its name and n/20, the same shape
    -- BoxMenu.changeBox shows (src/ui/BoxMenu.lua) -- minus its save
    -- prompt, because this screen writes no save.
    local function openJumpMenu(parent)
      local boxes = Boxes.ensure(game.save)
      local items = {}
      for i = 1, Boxes.COUNT do
        local mark = i == game.save.currentBox and "*" or ""
        table.insert(items, {
          label = mark .. boxName(i),
          right = ("%d/%d"):format(#boxes[i], Boxes.CAPACITY),
          value = i,
        })
      end
      local sub
      sub = mod.ui.ListMenu.new(game, Strings("JUMP TO BOX"), items, {
        kind = "gen3_box_jump",
        onChoose = function(item)
          game.save.currentBox = item.value
          self.header = false
          sub:close()
          parent:close()
        end,
      })
      game.stack:push(sub)
    end

    -- NAME BOX: the engine's own naming screen, 8 glyphs, defaulting to the
    -- box's current name (PLAN.md "4. BOX NAMES and WALLPAPERS"). "default"
    -- is NamingScreen's own declined-confirm fallback, not a glyph pre-fill
    -- -- self.glyphs always starts empty (src/ui/NamingScreen.lua:73), so
    -- typing nothing and confirming hands back exactly what `default` was
    -- given, the same contract a declined nickname keeps the old one under.
    -- So a confirm with nothing typed is a no-op here: it reconfirms
    -- whatever the box was already called, custom name included, which is
    -- an honest engine-shaped reading of the plan's "an empty confirm
    -- stores nothing" -- on a box with no custom name that default already
    -- IS "BOX n", so nothing changes there either. Typing back the literal
    -- "BOX n" is the one input that always clears a custom name, because it
    -- is compared against the canonical string below rather than against
    -- an impossible-to-reach raw "".
    local function openNameBoxScreen(boxMenu)
      local n = game.save.currentBox
      game.stack:push(mod.ui.NamingScreen.new(game, {
        title = Strings("BOX NAME?"),
        maxLen = 8,
        default = boxName(n),
        onDone = function(name)
          local canonical = Strings("BOX %d", n)
          if name == "" or name == canonical then
            local names = mod.save:get("boxNames")
            if names then
              names[n] = nil
              names[tostring(n)] = nil
            end
          else
            local names = mod.save:get("boxNames")
            if not names then
              names = {}
              mod.save:set("boxNames", names)
            end
            names[n] = name
            names[tostring(n)] = nil
          end
          self.header = false
          boxMenu:close()
        end,
      }))
    end

    -- WALLPAPER: a ListMenu of the named wallpapers above, each a pattern
    -- and a palette together. Choosing one writes boxPapers for THIS box
    -- only -- every other box keeps its own.
    local function openWallpaperMenu(parent)
      local n = game.save.currentBox
      local items = {}
      for _, w in ipairs(WALLPAPERS) do
        table.insert(items, { label = Strings(w.id), value = w.id })
      end
      local sub
      sub = mod.ui.ListMenu.new(game, Strings("WALLPAPER"), items, {
        kind = "gen3_box_wallpaper",
        onChoose = function(item)
          local papers = mod.save:get("boxPapers")
          if not papers then
            papers = {}
            mod.save:set("boxPapers", papers)
          end
          papers[n] = item.value
          papers[tostring(n)] = nil
          self.header = false
          say(Strings("WALLPAPER SET."))
          sub:close()
          parent:close()
        end,
      })
      game.stack:push(sub)
    end

    local function openBoxMenu()
      local menu
      menu = mod.ui.ListMenu.new(game, boxName(game.save.currentBox),
        boxMenuItems(), {
        kind = "gen3_box_menu",
        onChoose = function(item)
          if item.value == "find" then
            openFindMenu(menu)
          elseif item.value == "findnext" then
            if self.findQuery then findNext(self.findQuery) end
            self.header = false
            menu:close()
          elseif item.value == "sort" then
            openSortMenu(menu)
          elseif item.value == "jump" then
            openJumpMenu(menu)
          elseif item.value == "namebox" then
            openNameBoxScreen(menu)
          elseif item.value == "wallpaper" then
            openWallpaperMenu(menu)
          elseif item.value == "markmode" then
            self.markMode = not self.markMode
            self.header = false
            menu:close()
          elseif item.value == "cancel" then
            menu:close()
          end
        end,
      })
      game.stack:push(menu)
    end

    -- The header row (PLAN.md "the control scheme"): UP out of the top row
    -- of the grid, in box mode only, lands here rather than on the grid's
    -- own wrap. Nothing is "selected" on it, so START -- the summary key
    -- everywhere else -- opens nothing.
    local function updateHeader()
      local input = game.input
      if input:wasPressed("down") then
        self.header = false
      elseif input:wasPressed("left") then
        changeBox(-1)
      elseif input:wasPressed("right") then
        changeBox(1)
      elseif input:wasPressed("up") then
        -- the deliberate change PLAN.md calls out: wrap no longer takes UP
        -- from the top row straight to the bottom -- it stops here first,
        -- and UP again is what wraps
        if mod.options:get("wrap") then
          self.header = false
          self.row = rows() - 1
        end
      elseif input:wasPressed("a") then
        openBoxMenu()
      elseif input:wasPressed("start") then
        -- the header is the one place START has no summary to show, so it
        -- costs no binding to make it FIND NEXT (PLAN.md "1. FIND, and JUMP
        -- TO BOX") when a search is active
        if self.findQuery then findNext(self.findQuery) end
      elseif input:wasPressed("select") then
        switchMode()
      elseif input:wasPressed("b") then
        back()
      end
    end

    function self:update()
      -- The wallpaper clock. Ticked here rather than in draw() because draw
      -- can run more than once for a logic frame (and not at all when the
      -- screen is covered), and a pattern that drifted at the frame rate
      -- would run at a different speed on a different machine. One tick per
      -- logic step is the same cadence the rest of this screen moves at.
      --
      -- Before the early returns below: the box behind an open menu keeps
      -- breathing rather than freezing the moment you press A.
      self.paperTick = (self.paperTick or 0) + 1

      if self.markWindow then
        updateMarkWindow()
        return
      end
      if self.mode == "box" and self.header then
        updateHeader()
        return
      end
      local input = game.input
      if input:wasPressed("up") then
        if self.mode == "box" and self.row == 0 then
          self.header = true
        else
          move(0, -1)
        end
      elseif input:wasPressed("down") then move(0, 1)
      elseif input:wasPressed("left") then move(-1, 0)
      elseif input:wasPressed("right") then move(1, 0)
      elseif input:wasPressed("a") then
        if self.held then
          place()
        elseif self.markMode then
          openMarkWindowOnCursor()
        else
          grab()
        end
      elseif input:wasPressed("select") then switchMode()
      elseif input:wasPressed("start") then
        -- START is the summary. It can be, because B below always means
        -- back: there is no cell where the way out disappears, which is
        -- what forced the earlier arrangement into putting STATS on B.
        showStats()
      elseif input:wasPressed("b") then
        back()
      end
    end

    -- ------- drawing

    local function cellRect(i0, mode)
      local L = layout(game)
      mode = mode or self.mode
      local n = mode == "box" and COLS or PARTY_COLS
      local c, r = i0 % n, math.floor(i0 / n)
      if mode == "box" then
        return L.gridX + c * L.cell, L.gridY + r * L.cell
      end
      return L.partyX + c * L.cell, L.partyY + r * L.cell
    end

    -- The scale is derived from the picture the game actually handed us,
    -- never assumed. Pics reach this screen through Assets.image, which is
    -- the seam a sprite mod shadows -- the README calls that a feature --
    -- so a 112x112 or 168x168 replacement is a thing that will happen, and
    -- a fixed 0.5/1.0 would have drawn it straight over its neighbours: a
    -- 2x pic overflows a BIG cell by a whole cell, a 3x one by two.
    --
    -- Integer factors both ways. Two-bit pixel art survives being halved
    -- or doubled and smears at 0.6, so this picks the nearest whole step
    -- that fits rather than the one that fills the cell exactly.
    local function scaleFor(w, h, cell)
      local m = math.max(w, h)
      if m <= 0 then return 1 end
      if m <= cell then return math.max(1, math.floor(cell / m)) end
      return 1 / math.ceil(m / cell)
    end

    local function picScale(img, cell)
      return scaleFor(img:getWidth(), img:getHeight(), cell)
    end

    -- exposed so the suite can check the arithmetic without a graphics
    -- context, which is where the overflow above was found
    self.picScale = picScale

    -- ------- overworld sprites from Wilds of Kanto
    --
    -- CLASSIC halves a battle pic into its cell (see the header above); a
    -- species that fits a whole sprite into that cell instead of a halved
    -- one is strictly better, and Wilds of Kanto
    -- (github.com/YoDrehDenSwagAuf/overworld-spawn-mod, id
    -- "overworld_wild_spawns") builds exactly that -- a per-species
    -- overworld sprite for its wilds and its followers, sized for a
    -- 28-pixel cell with room to spare. Nothing of that mod's art is
    -- copied into this repo: this asks it, at runtime, for a path and
    -- draws it, the same seam a sprite mod already shadows the battle
    -- pics through in picOf above.
    --
    -- Reached through the engine's own api.find (src/mods/Loader.lua:1002),
    -- not a manifest dependency, so this stays an optional enhancement: a
    -- handle is nil in every case the other mod is not really there --
    -- absent, disabled, failed, or not yet run -- and that one check is
    -- the whole absence path.
    --
    -- The sprite comes from that mod's own resolve() (its main.lua:374
    -- publishes render.spriteProviders; lib/sprite_providers.lua:1253 is
    -- the call). resolve() always answers with a table, never nil, and
    -- falls back to a black silhouette when every real provider fails --
    -- worse than the halved battle picture, which at least shows which
    -- Pokemon it is, so that provider id (lib/sprite_providers.lua:34) is
    -- treated as a miss exactly like a missing handle.
    --
    -- The def follows SpriteRenderer's own contract
    -- (src/render/SpriteRenderer.lua:140-149): one image, frames stacked
    -- vertically, and frame 0 -- the idle/down frame -- is the one this
    -- grid wants. Neither the frame size nor the sheet height is assumed;
    -- both come out of the image and def.frames, because other providers
    -- and that mod's own "true size" feature answer with other sizes.
    --
    -- BIG is untouched: its cell is 56, a battle pic already draws there
    -- at scale 1, and a 16-pixel sprite would have to be blown up four
    -- times to fill it -- the trade this feature makes does not exist in
    -- that layout.
    --
    -- Every call into the other mod's code is pcalled -- it is someone
    -- else's release cycle, and a throw in a draw loop takes the frame
    -- down -- and cached per MON on self.owSpriteCache for the life of this
    -- screen, because resolve() walks a provider chain and calling it twenty
    -- times a frame is not free. Per mon rather than per species is what
    -- issue #2 cost: see owSpriteFor.
    local OW_MOD_ID = "overworld_wild_spawns"
    local OW_BLACK_PROVIDER_ID = "black" -- SpriteProviders.ID.BLACK

    -- Keyed by the MON, not by its species (issue #2). A species key means
    -- the first Pokemon of a species to be drawn decides the picture for
    -- every other one of it in the box -- so a shiny and a normal Ludicolo
    -- came out identical, whichever of the two was resolved first. The mon
    -- table is the only thing that tells them apart without this screen
    -- having to guess which field another mod stores "shiny" in.
    --
    -- Weak keys, so a Pokemon released or withdrawn while this screen is
    -- open does not sit in the cache holding its own table alive.
    local function owSpriteFor(mon)
      local cache = self.owSpriteCache
      local key = mon
      local cached = cache[key]
      if cached ~= nil then return cached or nil end

      local function miss()
        cache[key] = false
        return nil
      end

      local ok, handle = pcall(mod.find, OW_MOD_ID)
      if not ok or not handle or not handle.exports then return miss() end
      local ex = handle.exports

      -- ------- two ways to ask, in the order they are known to work
      --
      -- The FIRST is the one that matters. That mod already draws these
      -- sprites in the vanilla party menu, and it does it by monkeypatching
      -- PartyMenu.drawIcon and resolving through its follower sprite
      -- service (lib/follower/sprite_service.lua:222,384) -- not through
      -- spriteProviders. So the party-menu resolver is the code path with
      -- a screenshot behind it, and asking anything else first would be
      -- preferring the tidier seam to the working one.
      --
      -- It takes the Pokemon rather than a species id, which is why it is
      -- handed the real mon: it reads form and shininess off it. The cache
      -- is still keyed by species, which is right for Gen 1 -- there are no
      -- shinies and no forms here -- and would be the thing to widen first
      -- if a mod ever added either.
      local function viaPartyIcon()
        local service = ex.follower and ex.follower.spriteService
        if not service or type(service.resolvePartyIconDef) ~= "function" then
          return nil
        end
        local okDef, def = pcall(function()
          return service:resolvePartyIconDef(mon, game)
        end)
        if not okDef or type(def) ~= "table" or not def.image then return nil end
        return def, service
      end

      -- The SECOND is spriteProviders, the documented general seam. It is
      -- kept because it answers for the wild/overworld styles the party
      -- resolver has no opinion on, and because it is the one that survives
      -- if that mod ever retires its party-menu patch.
      --
      -- style nil: the player's own Sprite Style setting, the respectful
      -- default -- whatever they picked for their followers is what they
      -- should see here too. variant nil: "normal", never shiny.
      local function viaProviders()
        local providers = ex.spriteProviders
        if not providers or type(providers.resolve) ~= "function" then
          return nil
        end
        local okResolve, result = pcall(function()
          -- `mon.species`, not the cache key: the key is the mon itself now
          -- (issue #2), while this chain still asks by species. The two were
          -- the same value before and are not any more.
          return providers:resolve(nil, mon.species, nil, game)
        end)
        if not okResolve or type(result) ~= "table" or not result.def
            or result.error or result.providerId == OW_BLACK_PROVIDER_ID then
          return nil
        end
        if not result.def.image then return nil end
        return result.def
      end

      local def, service = viaPartyIcon()
      if not def then def = viaProviders() end
      if not def then return miss() end

      -- The service's own loader when it answered, because it caches and it
      -- knows about that mod's true-colour handling; Assets.image otherwise,
      -- which is the engine's cache and the seam a sprite mod shadows.
      local img
      if service and type(service.getPartyIconImage) == "function" then
        local okOwn, own = pcall(function()
          return service:getPartyIconImage(def.image)
        end)
        if okOwn then img = own end
      end
      if not img then
        local okImg, loaded = pcall(Assets.image, def.image)
        if okImg then img = loaded end
      end
      if not img then return miss() end
      local okDim, iw, ih = pcall(function() return img:getWidth(), img:getHeight() end)
      if not okDim or not iw or not ih or iw <= 0 or ih <= 0 then return miss() end

      local frames = def.frames
      if type(frames) ~= "number" or frames < 1 then frames = 1 end
      local fh = ih / frames
      local okQuad, quad = pcall(love.graphics.newQuad, 0, 0, iw, fh, iw, ih)
      if not okQuad or not quad then return miss() end

      local sprite = { image = img, quad = quad, w = iw, h = fh }
      cache[key] = sprite
      return sprite
    end

    -- Which picture drawPic below draws for a cell -- the option, the
    -- CLASSIC-only gate, the cache and every fallback, all decided in one
    -- place. Exposed so the suite can check the seam without a graphics
    -- context, the same reason self.picScale is exposed above.
    local function spriteToDraw(mon)
      if owSpritesOn() and layout(game).cell == LAYOUT.classic.cell then
        local sprite = owSpriteFor(mon)
        if sprite then return { kind = "ow", sprite = sprite } end
      end
      local img = picOf(game, mon)
      if img then return { kind = "battle", img = img } end
      return nil
    end
    self.spriteToDraw = spriteToDraw

    local function drawPic(mon, x, y)
      local L = layout(game)
      local chosen = spriteToDraw(mon)
      if not chosen then return end
      if chosen.kind == "ow" then
        local sprite = chosen.sprite
        local k = scaleFor(sprite.w, sprite.h, L.cell)
        local w, h = sprite.w * k, sprite.h * k
        love.graphics.draw(sprite.image, sprite.quad,
          x + (L.cell - w) / 2, y + (L.cell - h) / 2, 0, k, k)
        return
      end
      local img = chosen.img
      local k = picScale(img, L.cell)
      local w, h = img:getWidth() * k, img:getHeight() * k
      love.graphics.draw(img, x + (L.cell - w) / 2, y + (L.cell - h) / 2,
        0, k, k)
    end

    -- ------- the marks
    --
    -- Small filled love.graphics primitives, bottom-left of the cell, over a
    -- white pad so they stay legible against a pic -- the Gen 1 font has no
    -- glyph for CIRCLE/SQUARE/TRIANGLE/HEART, so this is real vector art,
    -- not text (PLAN.md "3. MARKS"). Only the marks that are set are drawn.
    -- Every number below is `cell/28` of a CLASSIC one, so BIG's marks are
    -- exactly twice the size and never run outside their (twice as big)
    -- cell either.
    local function drawShape(name, cx, cy, size)
      if name == "CIRCLE" then
        love.graphics.circle("fill", cx, cy, size / 2)
      elseif name == "SQUARE" then
        love.graphics.rectangle("fill", cx - size / 2, cy - size / 2, size, size)
      elseif name == "TRIANGLE" then
        love.graphics.polygon("fill", cx, cy - size / 2,
          cx - size / 2, cy + size / 2, cx + size / 2, cy + size / 2)
      elseif name == "HEART" then
        local r = size / 4
        love.graphics.circle("fill", cx - r, cy - r, r)
        love.graphics.circle("fill", cx + r, cy - r, r)
        love.graphics.polygon("fill", cx - size / 2, cy - r,
          cx + size / 2, cy - r, cx, cy + size / 2)
      end
    end

    local function drawMarks(mon, x, y)
      if not anyMarks(mon) then return end
      local cell = layout(game).cell
      local k = cell / 28
      local size = 4 * k
      local gap = 1 * k
      local n = #MARK_ORDER
      local totalW = n * size + (n - 1) * gap
      local totalH = size
      local px = x + gap
      local py = y + cell - totalH - gap
      love.graphics.setColor(1, 1, 1, 1)
      love.graphics.rectangle("fill", px - gap, py - gap,
        totalW + 2 * gap, totalH + 2 * gap)
      love.graphics.setColor(0, 0, 0, 1)
      for i, name in ipairs(MARK_ORDER) do
        if getMark(mon, name) then
          local cx = px + (i - 1) * (size + gap) + size / 2
          drawShape(name, cx, py + size / 2, size)
        end
      end
    end

    -- ------- a palette per Pokemon
    --
    -- This is the reason BIG exists. A zone is a palette bound to a TILE
    -- rectangle (PaletteFX.zone takes tile coordinates), and the engine
    -- draws each one scissored through the shade-remap shader -- so twenty
    -- zones is twenty draws, not a hardware limit. The Game Boy could show
    -- four; nothing here has to.
    --
    -- `monPal` is the species' own palette, the same table the summary
    -- screen and the battle use. So a Charmander is orange, a Bulbasaur
    -- green and a Gengar purple, all at once, in the grid -- which is what
    -- Gen 3's storage actually looks like and what Gen 1 never had the
    -- hardware to draw.
    --
    -- CLASSIC gets none of it, and cannot: a 28-pixel cell is three and a
    -- half tiles, and half a tile cannot carry a zone.
    --
    -- This whole method is simply never CALLED on Gold: Game2:draw
    -- (src/core/Game2.lua:1334-1450) has no equivalent of Gen 1's
    -- `s:sgbPalettes(self)` walk (src/core/Game.lua:530-538), and layout()
    -- above reads CLASSIC there regardless, so it would return nil anyway.
    -- The wallpaper PALETTE this method would apply is inert on a Gold
    -- boot for that reason; the wallpaper PATTERN self:draw paints still
    -- draws, because that half is plain love.graphics and owns no seam
    -- Gold skips. Not a bug to chase -- there is no code path here to fix.
    function self:sgbPalettes(game)
      local L = layout(game)
      -- Everything here has to land on the tile grid: the cell, and both
      -- grid origins. Flooring a stray offset into tile coordinates would
      -- not fail -- it would quietly slide every palette four pixels off
      -- its sprite, which is the kind of wrong that looks like a rendering
      -- bug rather than a layout mistake.
      if L.cell % 8 ~= 0 or L.gridX % 8 ~= 0 or L.gridY % 8 ~= 0
         or L.partyX % 8 ~= 0 or L.partyY % 8 ~= 0 then
        return nil
      end
      local PaletteFX = require("src.render.PaletteFX")
      local tiles = L.cell / 8

      -- The BASE zone, first and covering the whole surface. Without it the
      -- only remapped pixels are the cells themselves and everything else
      -- composites black -- including the header and footer, which are
      -- drawn in black and therefore vanish. SummaryMenu does the same
      -- thing: a whole-screen palette, then the per-mon one on top of it,
      -- because the renderer draws later zones over earlier ones.
      --
      -- PaletteFX.whole() is hardcoded to the 160x144 tile grid, so it
      -- would cover a quarter of a BIG canvas and leave the rest black.
      -- The size comes from the layout instead.
      --
      -- The wallpaper's palette (PLAN.md "4. BOX NAMES and WALLPAPERS")
      -- replaces GRAYS here rather than adding a zone of its own, tinting
      -- the whole surface the same way SummaryMenu's own whole-screen
      -- palette does -- which is the entire reason the header and footer
      -- keep working under it. Only the box pane has a wallpaper; the party
      -- pane keeps plain GRAYS, and PLAIN itself carries no palette at all,
      -- so a box nobody has touched renders exactly what 1.5.2 rendered.
      local paper = self.mode == "box" and paperOf(game.save.currentBox) or nil
      local baseColors = (paper and paper.palette) or PaletteFX.GRAYS
      local zones = {
        PaletteFX.zone(baseColors, 0, 0, L.w / 8 - 1, L.h / 8 - 1),
      }

      local function add(set, mode)
        for i, mon in ipairs(set) do
          local colors = PaletteFX.monPal(game.data, mon.species)
          if colors then
            local x, y = cellRect(i - 1, mode)
            local tx, ty = x / 8, y / 8
            zones[#zones + 1] =
              PaletteFX.zone(colors, tx, ty, tx + tiles - 1, ty + tiles - 1)
          end
        end
      end

      -- Only the pane on screen. The two panes overlap by design -- one is
      -- drawn at a time -- so emitting zones for both painted the party's
      -- palettes in stripes across the box grid, which is exactly what the
      -- first BIG screenshot showed.
      if self.mode == "box" then
        add(boxList(game), "box")
      else
        add(game.save.party, "party")
      end
      -- the one on the cursor is drawn where the cursor is, so it needs its
      -- own zone or it wears whatever the cell under it is wearing
      if self.held and self.held.mon then
        local colors = PaletteFX.monPal(game.data, self.held.mon.species)
        if colors then
          local x, y = cellRect(self.row * cols() + self.col)
          local tx, ty = x / 8, y / 8
          zones[#zones + 1] =
            PaletteFX.zone(colors, tx, ty, tx + tiles - 1, ty + tiles - 1)
        end
      end
      -- the marking window, last, so it draws in clean greys over whichever
      -- species' zone happens to sit underneath its rect (PLAN.md "3.
      -- MARKS")
      if self.markWindow then
        local x, y, w, h = markWindowRect()
        zones[#zones + 1] =
          PaletteFX.zone(PaletteFX.GRAYS, x / 8, y / 8, (x + w) / 8 - 1, (y + h) / 8 - 1)
      end

      if not zones[1] then return nil end
      return zones
    end

    local function outline(x, y, w, h)
      love.graphics.rectangle("line", x + 0.5, y + 0.5, w - 1, h - 1)
    end

    -- Every glyph in this font advances 8 pixels and the screen is 160
    -- wide, so a line beside a 4-pixel margin has room for nineteen of
    -- them and no more. 1.1.0 shipped a "SELECT:PARTY START:BOX" hint --
    -- twenty-two glyphs, 176 pixels -- and the tail simply ran off the
    -- right edge. Nothing is drawn now without being measured first.
    -- Both of these follow the SURFACE, not the Game Boy. 1.5.0 hardcoded
    -- 160 and a footer at y=132: on the 288-tall BIG canvas that put
    -- "B:EXIT" in the middle of the grid, printed over the Pokemon.
    local TEXT_X = 4
    local function textMax() return layout(game).w - TEXT_X * 2 end
    local function footerY() return layout(game).h - 12 end

    local function fitTo(text, maxW)
      text = tostring(text or "")
      while #text > 1 and Font.width(text) > maxW do
        text = text:sub(1, #text - 1)
      end
      return text
    end

    local function fit(text) return fitTo(text, textMax()) end

    -- ------- the marking window
    --
    -- Drawn by the box screen itself, not a ChoiceBox (PLAN.md "3. MARKS"):
    -- a ChoiceBox is not opaque, so under BIG it would drop the canvas to
    -- 160x144 while the box screen underneath still draws at 320x288 -- the
    -- exact bug "the two layouts" in main.lua's header describes for every
    -- other menu this release adds. On a tile-aligned rect, sized and
    -- positioned by markWindowRect() so sgbPalettes's GRAYS zone lands on
    -- exactly the pixels this draws.
    local function drawMarkWindow()
      local win = self.markWindow
      if not win then return end
      local x, y, w, h = markWindowRect()
      love.graphics.setColor(1, 1, 1, 1)
      love.graphics.rectangle("fill", x, y, w, h)
      love.graphics.setColor(0, 0, 0, 1)
      outline(x, y, w, h)
      local rowY = y + 4
      for i, name in ipairs(MARK_ORDER) do
        local text = fitTo((getMark(win.mon, name) and "*" or " ") .. Strings(name),
          w - 16)
        Font.draw(text, x + 8, rowY)
        if i == win.cursor then
          outline(x + 4, rowY - 1, Font.width(text) + 6, 10)
        end
        rowY = rowY + 10
      end
    end

    -- ------- the wallpaper pattern
    --
    -- Behind the cells, at low alpha, before anything else is drawn
    -- (PLAN.md "4. BOX NAMES and WALLPAPERS") -- the grid's cell outlines,
    -- pics and marks all draw on top of it. PLAIN draws nothing at all, so
    -- a box nobody has touched looks exactly like 1.5.2 did. Scissored to
    -- the grid rect so nothing here can bleed into the header or footer.
    -- ------- the wallpaper: the whole screen, not a panel
    --
    -- Gen 3's wallpaper IS the screen. The grid sits ON it: each slot is a
    -- pale square laid over the scene, and the scene carries on around and
    -- between the slots. 1.9.0-beta.1 had this inside out -- it drew the
    -- pattern only inside the grid rect, so the box looked like a textured
    -- panel on a white page, which is the one thing it should not look like.
    --
    -- Everything here is drawn from code: shapes and the four authored
    -- colours per theme, no art copied from anywhere (`modkit lint` stays
    -- green, and it would not if a single ROM pixel were involved).
    --
    -- The motion is slow and small on purpose -- this is behind twenty
    -- Pokemon -- and its phase is taken modulo each theme's own period, so a
    -- box left open for an hour draws what it drew in the first minute.
    -- ANIMATE off pins every phase at zero.
    local function shade(paper, n, alpha)
      local c = paper.palette and paper.palette[n]
      if not c then return end
      love.graphics.setColor(c[1] / 255, c[2] / 255, c[3] / 255, alpha or 1)
    end

    local function drawWallpaper(paper, w, h)
      local pattern = paper.pattern
      if pattern == "PLAIN" or not paper.palette then return end
      local t = animateOn() and (self.paperTick or 0) or 0

      -- The ground colour first: the whole surface, so nothing shows white
      -- except what this screen deliberately paints white on top.
      shade(paper, 1)
      love.graphics.rectangle("fill", 0, 0, w, h)

      if pattern == "SEA" then
        -- Bands of water, each rolling the opposite way to the one above, and
        -- bubbles rising through them.
        for i = 0, math.ceil(h / 10) do
          local y = i * 10
          local dir = (i % 2 == 0) and 1 or -1
          shade(paper, 2, 0.55)
          local prevX, prevY
          for x = 0, w, 4 do
            local wy = y + 3 * math.sin((x + dir * t * 0.5) / 11)
            if prevX then love.graphics.line(prevX, prevY, x, wy) end
            prevX, prevY = x, wy
          end
        end
        shade(paper, 3, 0.5)
        for i = 0, 11 do
          local bx = (i * 37 % w)
          local by = h - ((t * 0.35 + i * 23) % (h + 12))
          love.graphics.circle("line", bx, by, 2 + (i % 2))
        end
      elseif pattern == "FOREST" then
        -- A canopy: overlapping round crowns in two depths, swaying.
        for row = 0, math.ceil(h / 22) do
          for col = -1, math.ceil(w / 26) do
            local sway = 2 * math.sin((t + row * 30 + col * 17) / 40)
            local cx = col * 26 + (row % 2) * 13 + sway
            local cy = row * 22 + 8
            shade(paper, 3, 0.45)
            love.graphics.circle("fill", cx, cy, 9)
            shade(paper, 2, 0.75)
            love.graphics.circle("fill", cx - 2, cy - 2, 6)
          end
        end
      elseif pattern == "SKY" then
        -- Clouds drifting right, two layers at different speeds so the sky
        -- has depth rather than a single sliding sheet.
        local function cloud(cx, cy, r, tone, alpha)
          shade(paper, tone, alpha)
          love.graphics.circle("fill", cx, cy, r)
          love.graphics.circle("fill", cx + r, cy + 1, r * 0.8)
          love.graphics.circle("fill", cx - r, cy + 1, r * 0.7)
        end
        for i = 0, 5 do
          local y = 12 + i * 26
          local x = ((t * 0.20 + i * 47) % (w + 60)) - 30
          cloud(x, y, 8, 2, 0.55)
        end
        for i = 0, 3 do
          local y = 26 + i * 34
          local x = ((t * 0.35 + i * 71) % (w + 80)) - 40
          cloud(x, y, 11, 3, 0.35)
        end
      elseif pattern == "CAVE" then
        -- Stalactites from the ceiling, stalagmites from the floor, and a
        -- drip that falls and starts again. The rock does not move: caves do
        -- not, and a wall that drifted would read as the room tilting.
        shade(paper, 2, 0.6)
        for i = 0, math.ceil(w / 18) do
          local x = i * 18
          local d = 10 + ((i * 7) % 9)
          love.graphics.polygon("fill", x, 0, x + 9, 0, x + 4, d)
          love.graphics.polygon("fill", x + 4, h, x + 13, h, x + 9, h - d + 2)
        end
        shade(paper, 3, 0.5)
        for i = 0, 3 do
          local x = 20 + i * 41
          local y = (t * 0.8 + i * 33) % h
          love.graphics.circle("fill", x, y, 1.5)
        end
      elseif pattern == "CITY" then
        -- A skyline with lit windows, and the lights come on and go off.
        shade(paper, 2, 0.65)
        local base = h
        for i = 0, math.ceil(w / 16) do
          local x = i * 16
          local bh = 26 + ((i * 13) % 34)
          love.graphics.rectangle("fill", x, base - bh, 14, bh)
        end
        for i = 0, math.ceil(w / 16) do
          local x = i * 16
          local bh = 26 + ((i * 13) % 34)
          for wy = base - bh + 5, base - 6, 8 do
            for wx = x + 3, x + 10, 5 do
              local lit = math.sin((t + wx * 13 + wy * 7) / 55) > 0.2
              shade(paper, lit and 1 or 4, lit and 0.85 or 0.5)
              love.graphics.rectangle("fill", wx, wy, 3, 4)
            end
          end
        end
      elseif pattern == "SNOW" then
        -- Flakes falling and drifting sideways as they fall.
        shade(paper, 2, 0.7)
        for i = 0, 39 do
          local x = (i * 29 + 6 * math.sin((t + i * 40) / 45)) % w
          local y = (t * 0.30 + i * 17) % (h + 8)
          love.graphics.circle("fill", x, y, 1 + (i % 3) * 0.5)
        end
      elseif pattern == "NIGHT" then
        -- Stars, a few of them twinkling out of phase with each other.
        for i = 0, 47 do
          local x = (i * 53) % w
          local y = (i * 37) % h
          local tw = 0.45 + 0.45 * math.sin((t + i * 61) / 30)
          shade(paper, 4, tw)
          love.graphics.circle("fill", x, y, (i % 7 == 0) and 1.5 or 1)
        end
      end

      love.graphics.setColor(0, 0, 0, 1)
    end

    -- ------- the slots, laid ON the wallpaper
    --
    -- This is the layer that makes it read as Gen 3: each cell is a pale
    -- square over the scene, so the wallpaper carries on around and between
    -- the slots while every Pokemon still sits on something light enough to
    -- be seen against.
    --
    -- Opaque enough to be a slot rather than a tint -- the wallpaper reads
    -- through it as a hint of what is behind, not as a pattern the Pokemon
    -- has to compete with. On PLAIN there is no wallpaper at all, so white
    -- on white draws nothing and the plain box looks exactly as it always
    -- did.
    local function drawCellWash(x, y, size)
      local alpha = slotAlpha()
      if alpha <= 0 then return end
      love.graphics.setColor(1, 1, 1, alpha)
      love.graphics.rectangle("fill", x, y, size, size)
      love.graphics.setColor(0, 0, 0, 1)
    end

    function self:draw()
      love.graphics.clear(1, 1, 1, 1)
      love.graphics.setColor(0, 0, 0, 1)

      -- The wallpaper covers the WHOLE surface, and everything else is drawn
      -- on top of it -- that is what makes this a box that is somewhere,
      -- rather than a panel of texture on a white page.
      --
      -- Then the title row and the footer are painted back to white, because
      -- they are black text: a sky or a night sky behind a caption is a
      -- caption nobody can read, and Gen 3 keeps its own header on a solid
      -- band for exactly this reason. Between those two bands the wallpaper
      -- runs edge to edge, including the margins around the grid.
      local L = layout(game)
      if self.mode == "box" then
        local paper = paperOf(game.save.currentBox)
        drawWallpaper(paper, L.w, L.h)
        love.graphics.setColor(1, 1, 1, 1)
        love.graphics.rectangle("fill", 0, 0, L.w, L.gridY - 2)
        love.graphics.rectangle("fill", 0, footerY() - 2, L.w, L.h - footerY() + 2)
        love.graphics.setColor(0, 0, 0, 1)
      end

      local set = list()
      local total = cols() * rows()
      local onHeader = self.mode == "box" and self.header

      -- header: which box, how full, and which pane has the cursor
      local title
      if self.mode == "box" then
        title = Strings("BOX %d %d/%d", game.save.currentBox,
          #set, Boxes.CAPACITY)
      else
        title = Strings("PARTY %d/%d", #set, Party.MAX)
      end
      -- ------- the MENU button
      --
      -- 1.6.0 put six features behind the header and told nobody it was
      -- there. The footer hint that named it only ever drew on an EMPTY
      -- cell, because an occupied one shows the Pokemon's name instead --
      -- and the cell under the cursor is occupied nearly all the time. So
      -- the whole release was invisible unless you happened to press UP on
      -- the top row and notice something had changed.
      --
      -- A drawn button fixes that by being a thing on the screen rather
      -- than a move you have to already know. It is right-aligned on the
      -- title row, outlined so it reads as pressable, and it is the same
      -- MENU the header's A opens -- no new binding, no new state, just the
      -- affordance the header always needed.
      local hint = self.mode == "box" and Strings("MENU") or nil
      local hintW = hint and Font.width(hint) or 0
      local hintX = layout(game).w - TEXT_X - hintW

      -- the title yields to the button rather than running under it: an
      -- eight-glyph box name plus " 20/20" is wider than a CLASSIC screen
      -- has left once the button has its corner.
      local shownTitle = hint
        and fitTo(title, hintX - TEXT_X - 6)
        or fit(title)
      Font.draw(shownTitle, TEXT_X, 2)

      if hint then
        Font.draw(hint, hintX, 2)
        outline(hintX - 3, 0, hintW + 6, 11)
      end

      -- the cursor's own row (PLAN.md "the control scheme"): an outline
      -- around the title, sized to the text rather than the surface, so it
      -- reads on CLASSIC and BIG alike and never runs wider than fit()
      -- already guaranteed the text itself does not. With the button drawn
      -- the outline runs to its far edge, so the row reads as one selected
      -- thing with a button on it rather than two unrelated outlines.
      if onHeader then
        local right = hint and (hintX + hintW + 3)
          or (TEXT_X + Font.width(shownTitle) + 2)
        outline(TEXT_X - 2, 0, right - (TEXT_X - 2), 11)
      end

      for i0 = 0, total - 1 do
        local x, y = cellRect(i0)
        local mon = set[i0 + 1]
        drawCellWash(x, y, layout(game).cell)
        love.graphics.setColor(0, 0, 0, 0.25)
        outline(x, y, layout(game).cell, layout(game).cell)
        love.graphics.setColor(1, 1, 1, 1)
        if mon then drawPic(mon, x, y) end
        love.graphics.setColor(0, 0, 0, 1)
        if mon then drawMarks(mon, x, y) end
      end

      -- Cursor last, so it sits over the art it is pointing at.
      --
      -- Corner brackets rather than a box: a one-pixel outline is what
      -- 1.5.x drew, and on a 56-pixel cell it is a hairline you have to
      -- hunt for -- and it competes with the cell outlines, which are the
      -- same shape one pixel away. Brackets read as a cursor at any size,
      -- and they leave the middle of the cell clear so the Pokemon under
      -- them is not fenced in.
      --
      -- Both numbers scale with the cell: 2px arms of 9 on CLASSIC, 4px
      -- arms of 18 on BIG.
      local cx, cy = cellRect(self.row * cols() + self.col)
      -- on the header the outline above is the cursor; the grid keeps none,
      -- so there is never more than one place on screen the cursor reads as
      -- being
      if not onHeader then
        local cell = layout(game).cell
        local t = math.max(1, math.floor(cell / 14))
        local arm = math.floor(cell / 3)
        local x0, y0 = cx - t, cy - t
        local x1, y1 = cx + cell, cy + cell
        local function bracket(bx, by, dx, dy)
          love.graphics.rectangle("fill", bx, by, dx * arm, t)
          love.graphics.rectangle("fill", bx, by, t, dy * arm)
        end
        love.graphics.rectangle("fill", x0, y0, arm, t)
        love.graphics.rectangle("fill", x0, y0, t, arm)
        love.graphics.rectangle("fill", x1 - arm + t, y0, arm, t)
        love.graphics.rectangle("fill", x1, y0, t, arm)
        love.graphics.rectangle("fill", x0, y1, arm, t)
        love.graphics.rectangle("fill", x0, y1 - arm + t, t, arm)
        love.graphics.rectangle("fill", x1 - arm + t, y1, arm, t)
        love.graphics.rectangle("fill", x1, y1 - arm + t, t, arm)
      end

      -- the carried mon rides just above the cursor, clear of the grid
      if self.held then
        love.graphics.setColor(1, 1, 1, 1)
        drawPic(self.held.mon, cx, cy - 10)
        love.graphics.setColor(0, 0, 0, 1)
      end

      -- footer: the notice if one is fresh, else what the cursor is on. In
      -- MARK MODE it says so instead -- "there is no state you can be in
      -- without being told" (PLAN.md "3. MARKS") -- for as long as the mode
      -- stays on, ahead of the usual per-cell hint.
      local line
      if self.notice then
        local now = love.timer and love.timer.getTime() or 0
        if now - self.noticeAt < 1.5 then line = self.notice else self.notice = nil end
      end
      if not line and self.markMode then
        line = Strings("MARK MODE B:DONE")
      end
      if not line then
        -- nothing is "selected" on the header, so the cell under where the
        -- cursor used to be does not count as what it is "on"
        local mon = self.held and self.held.mon
          or (not onHeader and set[index()])
        if mon then
          line = Strings("%s :L%d", nameOf(game, mon), mon.level or 0)
        elseif onHeader then
          line = Strings("A:BOX MENU B:EXIT")
        elseif self.mode == "box" then
          line = Strings("SEL:PARTY B:EXIT")
        else
          line = Strings("SEL:BOX B:EXIT")
        end
      end
      Font.draw(fit(line), TEXT_X, footerY())

      -- the marking window, last, so it sits over the grid and the cursor
      drawMarkWindow()
    end

    -- The button says there is a menu; this says how to reach it, once, on
    -- the way in. It goes through the ordinary notice channel, so it fades
    -- after a second and a half like every other line and the footer is
    -- back to naming what the cursor is on -- a hint that stayed would be
    -- competing with the thing it is pointing at.
    say(Strings("UP: BOX MENU"))

    return self
  end

  mod.content.screens:register(SCREEN, { new = newScreen })

  -- ------- reaching it
  --
  -- Both hooks CALL NEXT FIRST and decorate what comes back, so another
  -- mod's row on the same menu survives instead of being rebuilt over.

  mod.hooks:wrap("ui.start_menu.items", function(next, game, items)
    local out = next(game, items)
    if type(out) ~= "table" or not onStart() then return out end
    return mod.ui.insertBefore(out, "SAVE", {
      label = Strings("BOXES"),
      onSelect = function() mod.ui.push(game, SCREEN) end,
    })
  end)

  -- The Pokémon Center PC. Its box row is labelled "SOMEONE'S PC" until you
  -- meet Bill and "BILL'S PC" after (the engine gates on EVENT_MET_BILL), so
  -- anchoring on one label alone would silently stop working halfway through
  -- the game -- try both, and fall back to the front of the list.
  local BOX_ROWS = { "BILL'S PC", "SOMEONE'S PC" }

  mod.hooks:wrap("ui.pc.items", function(next, game, items)
    local out = next(game, items)
    if type(out) ~= "table" or not onPC() then return out end
    local row = {
      label = Strings("BOXES"),
      onSelect = function() mod.ui.push(game, SCREEN) end,
    }
    if isGen2(game) then
      -- On Gold this same hook fires at TWO menus: the storage system
      -- (src/ui/gen2/PcMenu.lua), which is what BOXES belongs in, and the
      -- player's own ITEM PC (src/ui/gen2/ItemPcMenu.lua), where it does
      -- not. Both carry WITHDRAW/DEPOSIT/MAILBOX rows, so a label is not a
      -- safe anchor -- but only the storage menu's rows carry an
      -- id == "changebox", and the item PC's never do.
      local isStorage = false
      for _, entry in ipairs(out) do
        if entry.id == "changebox" then
          isStorage = true
          break
        end
      end
      if not isStorage then return out end
      table.insert(out, 1, row)
      return out
    end
    for _, anchor in ipairs(BOX_ROWS) do
      for _, entry in ipairs(out) do
        if entry.label == anchor then
          return mod.ui.insertAfter(out, anchor, row)
        end
      end
    end
    table.insert(out, 1, row)
    return out
  end)
end
