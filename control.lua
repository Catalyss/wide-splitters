local CARRIERS = {}

do
  local md = prototypes.mod_data["wide-splitters"]
  if md then CARRIERS = md.data.carriers end
end

local DIR = defines.direction
local FORWARD = {
  [DIR.north] = { x = 0, y = -1 }, [DIR.east] = { x = 1, y = 0 },
  [DIR.south] = { x = 0, y = 1 },  [DIR.west] = { x = -1, y = 0 },
}

local function lateral(dir)
  if dir == DIR.north or dir == DIR.south then return { x = 1, y = 0 } end
  return { x = 0, y = 1 }
end

local COLOR_RAIL = { r = 0.22, g = 0.22, b = 0.22, a = 1 }
local COLOR_POST = { r = 0.40, g = 0.40, b = 0.40, a = 1 }
local on_tick -- forward declaration

local function sync_tick()
  if storage.splitters and next(storage.splitters) then
    script.on_event(defines.events.on_tick, on_tick)
  else
    script.on_event(defines.events.on_tick, nil)
  end
end

local function init_storage()
  storage.splitters = storage.splitters or {}
  storage.interval = settings.global["wide-splitters-balance-interval"].value
end

local DIRNAME = {
  [DIR.north] = "north", [DIR.east] = "east", [DIR.south] = "south", [DIR.west] = "west",
}

-- Draw one vanilla splitter sprite sheet, stretched along the belt-width axis.
local function draw_stretched(rec, carrier, a, layer)
    local pos, dir = carrier.position, carrier.direction
    local across_x =
        dir == DIR.north or dir == DIR.south
    local k = rec.width / 2
    local x_scale = across_x and k or 1
    local y_scale = across_x and 1 or k
    local shift_x = (a.shift.x or 0) * x_scale
    local shift_y = (a.shift.y or 0) * y_scale
    rec.render[#rec.render + 1] = rendering.draw_animation({
        animation = a.name,
        target = {
            x = pos.x + shift_x,
            y = pos.y + shift_y
        },
        surface = carrier.surface,
        x_scale = x_scale,
        y_scale = y_scale,
        animation_speed = 0.5,
        render_layer = layer,
    })
end

-- Fallback art (plain rectangles) for splitters whose sprites we can't reuse.
local function draw_rectangles(rec, carrier, info)
  local pos, dir, w = carrier.position, carrier.direction, rec.width
  local f, l = FORWARD[dir] or FORWARD[DIR.north], lateral(dir)
  local surface = carrier.surface
  local half = w / 2

  local function rect(lat0, lat1, dep0, dep1, color)
    local ax, ay = pos.x + l.x * lat0 + f.x * dep0, pos.y + l.y * lat0 + f.y * dep0
    local bx, by = pos.x + l.x * lat1 + f.x * dep1, pos.y + l.y * lat1 + f.y * dep1
    rec.render[#rec.render + 1] = rendering.draw_rectangle({
      color = color,
      filled = true,
      left_top = { math.min(ax, bx), math.min(ay, by) },
      right_bottom = { math.max(ax, bx), math.max(ay, by) },
      surface = surface,
    })
  end

  rect(-half, -half + 0.14, -0.5, 0.5, COLOR_RAIL)
  rect(half - 0.14, half, -0.5, 0.5, COLOR_RAIL)
  for k = 1, w - 1 do
    local c = -half + k
    rect(c - 0.04, c + 0.04, -0.32, 0.32, COLOR_POST)
  end
  rect(-half + 0.14, half - 0.14, -0.5, -0.42, COLOR_RAIL)
  rect(-half + 0.14, half - 0.14, 0.42, 0.5, info.color)
end

local function draw_art(rec, carrier, info)
  info.static_art = nil
  local d = DIRNAME[carrier.direction]
  local anim = info.anim
  local st = anim and anim.structure and anim.structure[d]
  if st then
    draw_stretched(rec, carrier, st, "object")
    local patch = anim.patch and anim.patch[d]
    if patch then draw_stretched(rec, carrier, patch, "higher-object-under") end
  else
    draw_rectangles(rec, carrier, info)
  end
end

-- Creates the hidden belts + art for rec. Returns true on success.
local function build_parts(rec, carrier, info)
  local surface, force, dir, pos = carrier.surface, carrier.force, carrier.direction, carrier.position
  local l, w = lateral(dir), info.width
  local belts = {}
  for i = 1, w do
    local off = i - (w + 1) / 2
    local b = surface.create_entity({
      name = info.belt,
      position = { x = pos.x + l.x * off, y = pos.y + l.y * off },
      direction = dir,
      force = force,
      create_build_effect_smoke = false,
      raise_built = false,
    })
    if not b then
      for _, x in ipairs(belts) do x.destroy() end
      return false
    end
    b.destructible = false
    belts[i] = b
  end
  rec.belts = belts
  rec.surface, rec.position, rec.force = surface, pos, force
  draw_art(rec, carrier, info)
  return true
end

local function salvage(rec, player)
  for _, b in ipairs(rec.belts or {}) do
    if b.valid then
      for lane = 1, 2 do
        local line = b.get_transport_line(lane)
        for _, c in pairs(line.get_contents()) do
          local inserted = 0
          if player and player.valid then inserted = player.insert(c) end
          if inserted < c.count and rec.surface and rec.surface.valid then
            rec.surface.spill_item_stack({
              position = rec.position,
              stack = { name = c.name, count = c.count - inserted, quality = c.quality },
              enable_looted = true,
              allow_belts = false,
            })
          end
        end
        line.clear()
      end
    end
  end
end

local function teardown(rec, player)
  salvage(rec, player)
  for _, b in ipairs(rec.belts or {}) do
    if b.valid then b.destroy() end
  end
  for _, r in ipairs(rec.render or {}) do
    if r.valid then r.destroy() end
  end
  rec.belts, rec.render = {}, {}
end

local function setup(carrier, info)
  local rec = { carrier = carrier, width = info.width, belts = {}, render = {} }
  if not build_parts(rec, carrier, info) then return false end
  storage.splitters[carrier.unit_number] = rec
  script.register_on_object_destroyed(carrier)
  sync_tick()
  return true
end

local function move_one(src, dst)
  local items = src.get_detailed_contents()
  local tries = 0
  for i = #items, 1, -1 do
    local it = items[i]
    if dst.can_insert_at(it.position) then
      local stack = it.stack
      local spec = { name = stack.name, count = stack.count, quality = stack.quality.name }
      if dst.insert_at(it.position, stack) then
        if src.remove_item(spec) > 0 then return true end
        dst.remove_item(spec) -- roll back if the source item could not be removed
        return false
      end
    end
    tries = tries + 1
    if tries >= 4 then break end
  end
  return false
end

local function balance(rec)
  local belts = rec.belts
  local w = #belts
  for lane = 1, 2 do
    local lines, counts = {}, {}
    for i = 1, w do
      local b = belts[i]
      if not b.valid then return end
      lines[i] = b.get_transport_line(lane)
      counts[i] = lines[i].get_item_count()
    end
    for _ = 1, w do
      local imax, imin = 1, 1
      for i = 2, w do
        if counts[i] > counts[imax] then imax = i end
        if counts[i] < counts[imin] then imin = i end
      end
      if counts[imax] - counts[imin] < 2 then break end
      if not move_one(lines[imax], lines[imin]) then break end
      counts[imax] = counts[imax] - 1
      counts[imin] = counts[imin] + 1
    end
  end
end

on_tick = function(event)
  local interval = storage.interval or 2
  local tick = event.tick
  for id, rec in pairs(storage.splitters) do
    if rec.carrier.valid and (tick + id) % interval == 0 then
      balance(rec)
    end
  end
end

local function refund(carrier, info, event)
  local pos, surface, quality = carrier.position, carrier.surface, carrier.quality.name
  local player = event.player_index and game.get_player(event.player_index)
  carrier.destroy()
  if player then
    player.create_local_flying_text({ text = "Not enough room for the hidden belts", position = pos })
    if player.insert({ name = info.item, count = 1, quality = quality }) > 0 then return end
  end
  surface.spill_item_stack({ position = pos, stack = { name = info.item, count = 1, quality = quality },
                             enable_looted = true, allow_belts = false })
end

local function on_built(event)
  local entity = event.entity
  if not (entity and entity.valid) then return end
  local info = CARRIERS[entity.name]
  if not info then return end
  if not setup(entity, info) then refund(entity, info, event) end
end

local function on_destroyed(event)
  if event.type ~= defines.target_type.entity then return end
  local rec = storage.splitters[event.useful_id]
  if not rec then return end
  teardown(rec, nil)
  storage.splitters[event.useful_id] = nil
  sync_tick()
end

local function on_pre_player_mined(event)
  local e = event.entity
  if not (e and e.valid and CARRIERS[e.name]) then return end
  local rec = storage.splitters[e.unit_number]
  if rec then salvage(rec, game.get_player(event.player_index)) end
end

local function on_pre_robot_mined(event)
  local e = event.entity
  if not (e and e.valid and CARRIERS[e.name]) then return end
  local rec = storage.splitters[e.unit_number]
  if rec then salvage(rec, nil) end
end

local function on_rotated(event)
  local e = event.entity
  if not (e and e.valid and CARRIERS[e.name]) then return end
  local rec = storage.splitters[e.unit_number]
  if not rec then return end
  teardown(rec, event.player_index and game.get_player(event.player_index) or nil)
  local info = CARRIERS[e.name]
  rec.carrier = e
  if not build_parts(rec, e, info) then
    e.direction = event.previous_direction
    build_parts(rec, e, info)
  end
end

local function on_gui_opened(event)
  local e = event.entity
  if e and e.valid and CARRIERS[e.name] then
    game.get_player(event.player_index).opened = nil
  end
end

local function on_setting_changed(event)
  if event.setting == "wide-splitters-balance-interval" then
    storage.interval = settings.global["wide-splitters-balance-interval"].value
  end
end

script.on_event(defines.events.on_built_entity, on_built)
script.on_event(defines.events.on_robot_built_entity, on_built)
script.on_event(defines.events.on_space_platform_built_entity, on_built)
script.on_event(defines.events.script_raised_built, on_built)
script.on_event(defines.events.script_raised_revive, on_built)
script.on_event(defines.events.on_object_destroyed, on_destroyed)
script.on_event(defines.events.on_pre_player_mined_item, on_pre_player_mined)
script.on_event(defines.events.on_robot_pre_mined, on_pre_robot_mined)
script.on_event(defines.events.on_player_rotated_entity, on_rotated)
script.on_event(defines.events.on_gui_opened, on_gui_opened)
script.on_event(defines.events.on_runtime_mod_setting_changed, on_setting_changed)

script.on_init(function() init_storage(); sync_tick() end)
script.on_configuration_changed(function() init_storage(); sync_tick() end)
script.on_load(function() sync_tick() end)
