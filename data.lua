  
local collision_mask_util = require("__core__/lualib/collision-mask-util")

local max_w = settings.startup["wide-splitters-max-width"].value
local style = settings.startup["wide-splitters-art-style"].value

local DIRS = { "north", "east", "south", "west" }

local TIER_COLORS = {
  ["splitter"]         = { 0.92, 0.76, 0.12 },
  ["fast-splitter"]    = { 0.85, 0.20, 0.15 },
  ["express-splitter"] = { 0.20, 0.50, 0.90 },
  ["turbo-splitter"]   = { 0.40, 0.78, 0.30 },
}

local function color_for(name)
  local c = TIER_COLORS[name] or { 0.7, 0.7, 0.7 }
  return { r = c[1], g = c[2], b = c[3], a = 1 }
end

local EMPTY = { filename = "__core__/graphics/empty.png", priority = "extra-high", width = 1, height = 1 }
local function empty4()
  return { north = table.deepcopy(EMPTY), east = table.deepcopy(EMPTY),
           south = table.deepcopy(EMPTY), west = table.deepcopy(EMPTY) }
end

-- Find the transport belt matching a splitter's tier.
local function find_belt(splitter)
  local prefix = splitter.name:match("^(.*)splitter$")
  if prefix then
    local b = data.raw["transport-belt"][prefix .. "transport-belt"]
    if b then return b end
  end
  for _, b in pairs(data.raw["transport-belt"]) do
    if math.abs(b.speed - splitter.speed) < 1e-9 then return b end
  end
end

local hidden_done = {}
local function hidden_belt_for(belt)
  local hn = "ws-belt-" .. belt.name
  if not hidden_done[hn] then
    local hb = table.deepcopy(belt)
    hb.name = hn
    hb.minable = nil
    hb.next_upgrade = nil
    hb.fast_replaceable_group = nil
    hb.related_underground_belt = nil
    hb.placeable_by = nil
    hb.flags = { "player-creation", "not-on-map", "not-blueprintable",
                 "not-deconstructable", "not-upgradable", "not-repairable" }
    hb.hidden = true
    hb.hidden_in_factoriopedia = true
    hb.selectable_in_game = false
    data:extend({ hb })
    hidden_done[hn] = true
  end
  return hn
end

-- Icon = base icon layers + the width drawn as digit layers in the centre.
local DIGIT_SCALE = { 0.50, 0.38, 0.26 }
local function numbered_icons(item, w)
  local layers
  if item.icons then
    layers = table.deepcopy(item.icons)
    for _, l in ipairs(layers) do l.icon_size = l.icon_size or item.icon_size or 64 end
  else
    layers = { { icon = item.icon, icon_size = item.icon_size or 64 } }
  end
  local s = tostring(w)
  local n = #s
  local scale = DIGIT_SCALE[n] or 0.2
  local spacing = 36 * scale
  for i = 1, n do
    layers[#layers + 1] = {
      icon = "__wide-splitters__/graphics/digits/d" .. s:sub(i, i) .. ".png",
      icon_size = 64,
      scale = scale,
      shift = { (i - (n + 1) / 2) * spacing, 0 },
    }
  end
  return layers
end

local function set_icons(proto, item, w)
  proto.icons = numbered_icons(item, w)
  proto.icon = nil
  proto.icon_size = nil
end

-- Animation prototype that points at one vanilla splitter sprite sheet.
-- The shift is NOT baked in; control.lua applies it unscaled at draw time.
local function make_anim(proto_name, sp)
  if type(sp) ~= "table" or not sp.filename then return nil end
  if sp.filename:find("empty.png", 1, true) then return nil end
  data:extend({ {
    type = "animation",
    name = proto_name,
    filename = sp.filename,
    priority = sp.priority or "extra-high",
    width = sp.width,
    height = sp.height,
    x = sp.x,
    y = sp.y,
    frame_count = sp.frame_count or 1,
    line_length = sp.line_length or 0,
    scale = sp.scale or 1,
    shift = { 0, 0 },
    animation_speed = 1,
  } })
  local sh = sp.shift or { 0, 0 }
  return { name = proto_name, shift = { x = sh[1] or sh.x or 0, y = sh[2] or sh.y or 0 } }
end

local MAX_COPIES = 24

local function sprite_from_sheet(sp, dx, dy)
  if type(sp) ~= "table" or not sp.filename then return nil end
  if sp.filename:find("empty.png", 1, true) then return nil end
  local sh = sp.shift or { 0, 0 }
  return {
    filename = sp.filename,
    priority = sp.priority or "extra-high",
    x = sp.x or 0,            -- first frame of the sheet
    y = sp.y or 0,
    width = sp.width,
    height = sp.height,
    scale = sp.scale or 1,
    shift = { (sh[1] or sh.x or 0) + dx, (sh[2] or sh.y or 0) + dy },
  }
end

-- Lateral centres of the splitter copies that together cover a w-wide footprint.
local function copy_offsets(w)
  local k = math.min(math.ceil(w / 2), MAX_COPIES)
  if k <= 1 then return { 0 } end
  local span = w - 2
  local offs = {}
  for i = 0, k - 1 do offs[#offs + 1] = -span / 2 + span * i / (k - 1) end
  return offs
end

local function tiled_sprites(splitter, w)
  if not splitter.structure then return nil end
  local offs = copy_offsets(w)
  local result = {}
  for _, d in ipairs(DIRS) do
    local across_x = (d == "north" or d == "south")
    local layers = {}
    for _, o in ipairs(offs) do
      local dx, dy = 0, 0
      if across_x then dx = o else dy = o end
      local st = sprite_from_sheet(splitter.structure[d], dx, dy)
      if st then layers[#layers + 1] = st end
    end
    if #layers == 0 then return nil end
    if splitter.structure_patch then
      for _, o in ipairs(offs) do
        local dx, dy = 0, 0
        if across_x then dx = o else dy = o end
        local pt = sprite_from_sheet(splitter.structure_patch[d], dx, dy)
        if pt then layers[#layers + 1] = pt end
      end
    end
    result[d] = { layers = layers }
  end
  return result
end

-- Collect source splitters first (we add prototypes while looping afterwards).
local sources = {}
for name, s in pairs(data.raw["splitter"]) do
  if not s.hidden and data.raw.recipe[name] and data.raw.item[name] then
    sources[#sources + 1] = s
  end
end
table.sort(sources, function(a, b) return a.name < b.name end)

local carriers = {}

for _, s in ipairs(sources) do
  local belt = find_belt(s)
  if belt then
    local item = data.raw.item[s.name]
    local hb = hidden_belt_for(belt)

    -- Stretchable art from the vanilla splitter (nil if the sprites are exotic).
    local anim = { structure = {}, patch = {} }
    local any = false
    for _, d in ipairs(style == "stretched" and DIRS or {}) do
      local a = make_anim("ws-structure-" .. s.name .. "-" .. d, s.structure and s.structure[d])
      if a then anim.structure[d] = a; any = true end
      local p = make_anim("ws-patch-" .. s.name .. "-" .. d, s.structure_patch and s.structure_patch[d])
      if p then anim.patch[d] = p end
    end
    if not any then anim = nil end

    -- Technologies that unlock the base splitter also unlock our variants.
    local techs = {}
    for _, tech in pairs(data.raw.technology) do
      for _, eff in ipairs(tech.effects or {}) do
        if eff.type == "unlock-recipe" and eff.recipe == s.name then
          techs[#techs + 1] = tech
          break
        end
      end
    end

    for w = 3, max_w do
      local name = "ws-" .. s.name .. "-" .. w
      local lname = { "wide-splitters.name", s.localised_name or { "entity-name." .. s.name }, tostring(w) }
      local ldesc = { "wide-splitters.description", tostring(w) }

      -- Carrier entity
      local e = table.deepcopy(data.raw["constant-combinator"]["constant-combinator"])
      e.name = name
      e.localised_name = lname
      e.localised_description = ldesc
      set_icons(e, item, w)
      e.minable = { mining_time = 0.1, result = name }
      e.fast_replaceable_group = nil
      e.next_upgrade = nil
      e.max_health = s.max_health or e.max_health
      e.collision_box = { { -w / 2 + 0.1, -0.4 }, { w / 2 - 0.1, 0.4 } }
      e.selection_box = { { -w / 2, -0.5 }, { w / 2, 0.5 } }
      e.tile_width = w
      e.tile_height = 1
      local cm = table.deepcopy(collision_mask_util.get_mask(e))
      for layer in pairs(collision_mask_util.get_mask(belt).layers) do
        cm.layers[layer] = nil
      end
      e.collision_mask = cm
      local tiled = (style == "tiled") and tiled_sprites(s, w) or nil
      e.sprites = tiled or tiled_sprites(s, w)        -- empty => art is drawn at runtime
      e.activity_led_sprites = empty4()
      e.activity_led_light = { intensity = 0, size = 0, color = { r = 1, g = 1, b = 1 } }

      -- Item
      local it = {
        type = "item",
        name = name,
        localised_name = lname,
        localised_description = ldesc,
        subgroup = item.subgroup,
        order = (item.order or "z") .. "-" .. string.format("%03d", w),
        place_result = name,
        stack_size = item.stack_size or 50,
      }
      set_icons(it, item, w)

      -- Recipe
      local r = {
        type = "recipe",
        name = name,
        localised_name = lname,
        enabled = (#techs == 0),
        energy_required = 1,
        ingredients = { { type = "item", name = s.name, amount = w - 1 } },
        results = { { type = "item", name = name, amount = 1 } },
      }

      data:extend({ e, it, r })

      for _, tech in ipairs(techs) do
        table.insert(tech.effects, { type = "unlock-recipe", recipe = name })
      end

      carriers[name] = { width = w, belt = hb, item = name, color = color_for(s.name), anim = anim, static_art = (tiled ~= nil) }
    end
  end
end

data:extend({
  { type = "mod-data", name = "wide-splitters", data = { carriers = carriers } },
})
