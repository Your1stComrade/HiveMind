local util = require("script/script_util")
local shared = require("shared")
local data =
{
  spawner_tick_check = {},
  ghost_tick_check = {},
  not_idle_units = {},
  destroy_factor = 0.002,
  enemy_attack_pollution_consumption_modifier = 1,
  can_spawn = false,
  pop_count = {},
  max_pop_count = {}
}

local unit_spawned_event

local get_destroy_factor = function()
  return data.destroy_factor
end

local get_enemy_attack_pollution_consumption_modifier = function()
  return data.enemy_attack_pollution_consumption_modifier
end

local get_max_pop_count = function(force_index)
  if not data.max_pop_count[force_index] then
    data.max_pop_count[force_index] = game.forces[force_index].technologies["popcap"].level * settings.global["hivemind-increase-per-level"].value + settings.global["hivemind-starting-popcap"].value
  end
  return data.max_pop_count[force_index]
end

local spawner_map
local get_spawner_map = function()
  if spawner_map then return spawner_map end
  spawner_map = {}
  for index, name in pairs(util.get_spawner_list()) do
    spawner_map[util.deployer_name(name)] = true
  end
  return spawner_map
end


--Max pollution each spawner can absorb is 10% of whatever the chunk has.
local pollution_percent_to_take = 0.1

local min_to_take = 1

local prototype_cache = {}

local get_prototype = function(name)
  local prototype = prototype_cache[name]
  if prototype then return prototype end
  prototype = game.entity_prototypes[name]
  prototype_cache[name] = prototype
  return prototype
end

function request_get_prototype(name)  -- call get_prototype from other scripts
  return get_prototype(name)
end

local required_pollution = util.required_pollution
local pollution_cost_multiplier = shared.pollution_cost_multiplier

local get_required_pollution = function(name, entity)
  if entity.type == "entity-ghost" then entity = game.entity_prototypes[name] end
  return required_pollution(name, entity) * pollution_cost_multiplier
end

local unit_list

local get_units = function()
  if unit_list then return unit_list end
  unit_list = {}
  for name, prototype in pairs (game.entity_prototypes) do
    if prototype.type == "unit" then
      table.insert(unit_list, name)
    end
  end
  return unit_list
end

local unit_sizes

local get_unit_sizes = function(name)
  if unit_sizes then return unit_sizes[name] end
  unit_sizes = {}
  for name, x in pairs(get_units()) do
    unit_sizes[x] = math.ceil(game.entity_prototypes[x].pollution_to_join_attack / settings.startup["hivemind-unit-size-devider"].value)
  end
  return unit_sizes[name]
end

local can_spawn_units = function(force_index, name)
  return data.pop_count[force_index] + get_unit_sizes(name) <= get_max_pop_count(force_index)
end

local update_force_popcap_labels = function(force, caption)
  for k, player in pairs (force.players) do
    local gui = player.gui.left
    local label = gui.unit_deployment_pop_cap_label
    if not label then
      label = gui.add{name = "unit_deployment_pop_cap_label", type = "label"}
    end
    label.caption = caption
    label.visible = (caption ~= "")
  end
end

local update_pop_cap = function()
  --local profiler = game.create_profiler()
  local list = get_units()
  local forces = game.forces
  local forces_to_update = {}
  data.pop_count = {}
  for name, force in pairs (forces) do
    local total = 0
    local get_entity_count = force.get_entity_count
    for k = 1, #list do
      total = total + get_entity_count(list[k]) * get_unit_sizes(list[k])
    end
    local index = force.index
    local current = data.pop_count[index]
    data.pop_count[index] = total
    local caption = total > 0 and {"popcap", total.."/"..get_max_pop_count(index)} or ""
    update_force_popcap_labels(force, caption)
  end

  --game.print({"", game.tick, profiler})
end

local direction_enum =
{
  [defines.direction.north] = {0, -2},
  [defines.direction.south] = {0, 2},
  [defines.direction.east] = {2, 0},
  [defines.direction.west] = {-2, 0}
}

local deploy_unit = function(source, prototype)
  if not (source and source.valid) then return end
  local direction = source.direction
  local offset = direction_enum[direction]
  local name = prototype.name
  local deploy_bounding_box = prototype.collision_box
  local bounding_box = source.bounding_box
  local position = {source.position.x + offset[1], source.position.y + offset[2]}
  local surface = source.surface
  local force = source.force
  local find_non_colliding_position = surface.find_non_colliding_position
  local create_entity = surface.create_entity
  local on_flow = force.item_production_statistics.on_flow
  local deploy_position = find_non_colliding_position(name, position, 0, 1)
  local blood = {name = "blood-explosion-big", position = deploy_position}
  local create_param = {name = name, position = deploy_position, force = force, direction = direction, raise_built = true}
  create_entity(blood)
  local unit = create_entity(create_param)
  if unit and unit.valid then
    on_flow(name, 1)
    local index = force.index
    data.pop_count[index] = data.pop_count[index] + get_unit_sizes(name)
    script.raise_event(unit_spawned_event, {entity = unit, spawner = source})
    local caption = data.pop_count[index] > 0 and {"popcap", data.pop_count[index].."/"..get_max_pop_count(index)} or ""
    update_force_popcap_labels(force, caption)
  end
end


local min = math.min

local progress_color = {r = 0.8, g = 0.8}
local spawning_color = {r = 0, g = 1, b = 0, a = 0.5}

-- 1 pollution = 1 energy of crafting

local check_spawner = function(spawner_data)
  local entity = spawner_data.entity
  if not (entity and entity.valid) then return true end
  --entity.surface.create_entity{name = "flying-text", position = entity.position, text = game.tick % 60}

  entity.health = entity.health + 1

  local recipe = entity.get_recipe()
  if not recipe then
    if spawner_data.progress and rendering.is_valid(spawner_data.progress) then
      rendering.destroy(spawner_data.progress)
      spawner_data.progress = nil
    end
    return
  end

  local force = entity.force
  local force_index = force.index
  local recipe_name = recipe.name

  local can_spawn = can_spawn_units(force_index, recipe_name)
  entity.active = can_spawn
  if can_spawn == true then
    local item_count = entity.get_item_count(recipe_name)
    if item_count > 0 then
      deploy_unit(entity, get_prototype(recipe_name))
      entity.remove_item{name = recipe_name, count = 1}
    end
  end

  local surface = entity.surface
  local position = entity.position

  local progress = entity.crafting_progress

  if progress < 1 then

    local pollution = surface.get_pollution(position)
    local pollution_to_take = pollution * pollution_percent_to_take
    if pollution_to_take < min_to_take then
      pollution_to_take = min(min_to_take, pollution)
    end

    local energy = recipe.energy
    local current_energy = energy * progress

    pollution_to_take = min(pollution_to_take, energy - current_energy)

    current_energy = current_energy + pollution_to_take

    progress = current_energy / energy

    entity.crafting_progress = progress

    surface.pollute(position, -pollution_to_take)
    game.pollution_statistics.on_flow(entity.name, -pollution_to_take)
    force.item_production_statistics.on_flow(shared.pollution_proxy, -pollution_to_take)
  end


  local progress_bar = spawner_data.progress
  if type(progress_bar) == "table" then
    if progress_bar.valid then
      progress_bar.destroy()
    end
    --Old time it was a flying text... can remove in a while
    progress_bar = nil
    spawner_data.progress = nil
  end

  if progress_bar and rendering.is_valid(progress_bar) then
    rendering.set_text(progress_bar, math.floor(progress * 100) .. "%")
  else
    progress_bar = rendering.draw_text
    {
      text = math.floor(progress * 100) .. "%",
      surface = surface,
      target = entity,
      --target_offset = {0, 1},
      color = progress_color,
      alignment = "center",
      forces = {force},
      scale = 3,
      only_in_alt_mode = true
    }
    spawner_data.progress = progress_bar
  end


end

local teleport_unit_away = util.teleport_unit_away

local try_to_revive_entity = function(entity)
  if not (entity and entity.valid) then return true end
  local force = entity.force
  local name = entity.ghost_name
  local revived = entity.revive({raise_revive = true})
  if revived then
    force.entity_build_count_statistics.on_flow(name, 1)
    return true
  end
  local prototype = get_prototype(entity.ghost_name)
  local box = prototype.collision_box
  local origin = entity.position
  local area = {{box.left_top.x + origin.x, box.left_top.y + origin.y},{box.right_bottom.x + origin.x, box.right_bottom.y + origin.y}}
  local units = {}
  for k, unit in pairs (entity.surface.find_entities_filtered{area = area, force = force, type = "unit"}) do
    teleport_unit_away(unit, area)
  end
  local revived = entity.revive({raise_revive = true})
  if revived then
    force.entity_build_count_statistics.on_flow(name, 1)
    return true
  end
end

local is_idle = function(unit_number)
  return not (data.not_idle_units[unit_number]) --and remote.call("unit_control", "is_unit_idle", unit.unit_number)
end


local distance = util.distance

local get_sacrifice_radius = function()
  return 24
end

local needs_technology
local get_needs_technology = function(name)
  if needs_technology then return needs_technology[name] end
  needs_technology = {}
  for _, tech in pairs(game.technology_prototypes) do
    for _, effect in pairs(tech.effects) do
      if effect.type == "unlock-recipe" then
        needs_technology[effect.recipe] = tech.name
      end
    end
  end
  return needs_technology[name]
end

function request_needs_technology(name)  -- call get_needs_technology from other scripts
  return get_needs_technology(name)
end

local needs_blight = shared.needs_blight
local blight_name = shared.blight

local check_ghost = function(ghost_data)
  local entity = ghost_data.entity
  if not (entity and entity.valid) then return true end
  local surface = entity.surface
  --entity.surface.create_entity{name = "flying-text", position = entity.position, text = ghost_data.required_pollution}
  local ghost_name = entity.ghost_name

  if ghost_data.required_pollution > 0 then
    for k, unit in pairs (surface.find_units{area = entity.bounding_box, force = entity.force, condition = "same"}) do
      if unit.valid then
        local prototype = get_prototype(unit.name)
        local pollution = prototype.pollution_to_join_attack * pollution_cost_multiplier
        if unit.destroy({raise_destroy = true}) then
          ghost_data.required_pollution = ghost_data.required_pollution - pollution
          if ghost_data.required_pollution <= 0 then break end
        end
      end
    end
  end

  if ghost_data.required_pollution <= 0 then
    return try_to_revive_entity(entity)
  end

  local origin = entity.position
  local r = get_sacrifice_radius()
  local command =
  {
    type = defines.command.go_to_location,
    destination_entity = entity,
    distraction = defines.distraction.none,
    radius = 0.2
  }

  local needed_pollution = ghost_data.required_pollution
  for k, unit in pairs (surface.find_entities_filtered{position = origin, radius = r, force = entity.force, type = "unit"}) do
    if unit.valid then
      local unit_number = unit.unit_number
      if is_idle(unit_number) then
        --entity.surface.create_entity{name = "flying-text", position = unit.position, text = "IDLE"}
        unit.set_command(command)
        local pollution = unit.prototype.pollution_to_join_attack * pollution_cost_multiplier
        needed_pollution = needed_pollution - pollution
        data.not_idle_units[unit_number] = {tick = game.tick, ghost_data = ghost_data}
        if needed_pollution <= 0 then break end
      end
    end
  end

  local progress = ghost_data.progress
  if type(progress) == "table" then
    if progress.valid then
      progress.destroy()
    end
    --Old time it was a flying text... can remove in a while
    progress = nil
    ghost_data.progress = nil
  end

  if progress and rendering.is_valid(progress) then
    rendering.set_text(progress, math.floor((1 - (ghost_data.required_pollution / get_required_pollution(ghost_name, get_prototype(ghost_name)))) * 100) .. "%")
  else
    progress = rendering.draw_text
    {
      text = math.floor((1 - (ghost_data.required_pollution / get_required_pollution(ghost_name, get_prototype(ghost_name)))) * 100) .. "%",
      surface = surface,
      target = entity,
      --target_offset = {0, 1},
      color = spawning_color,
      alignment = "center",
      forces = {entity.force},
      scale = 3,
      only_in_alt_mode = true
    }
    ghost_data.progress = progress
  end


  local radius = ghost_data.radius
  if not (radius and rendering.is_valid(radius)) then
    radius = rendering.draw_circle
    {
      color = {r = 0.6, g = 0.6},
      width = 1,
      target = entity,
      surface = entity.surface,
      forces = {entity.force},
      draw_on_ground = true,
      filled = false,
      radius = r,
      only_in_alt_mode = true
    }
    ghost_data.radius = radius
  end

end

local make_proxy = function(entity)
  error("Not used")
  local radar_prototype = get_prototype(entity.name.."-radar")
  if not radar_prototype then return end
  --game.print("Made proxy for ".. entity.name)
  local radar_proxy = entity.surface.create_entity
  {
    name = radar_prototype.name,
    position = entity.position,
    force = entity.force
  } or error("Couldn't build radar proxy for some reason...")
  entity.destructible = false
  data.proxies[radar_proxy.unit_number] = entity
end

-- So, 59, so that its not exactly 60. Which means over a minute or so, each spawner will 'go first' at the pollution.
local spawners_update_interval = 59

local spawner_built = function(entity)
  local spawner_data = {entity = entity, proxy = radar_proxy}
  local update_tick = entity.unit_number % spawners_update_interval
  data.spawner_tick_check[update_tick] = data.spawner_tick_check[update_tick] or {}
  data.spawner_tick_check[update_tick][entity.unit_number] = spawner_data
end

local ghost_update_interval = 60

spawner_ghost_built = function(entity, player_index, override_pollution)
  local ghost_name = entity.ghost_name

  if get_needs_technology(ghost_name) then
    if not entity.force.technologies[get_needs_technology(ghost_name)].researched then
      if player_index then
        local player = game.get_player(player_index)
        player.create_local_flying_text
        {
          text={"entity-not-unlocked", get_prototype(ghost_name).localised_name},
          position=entity.position,
          color=nil,
          time_to_live=nil,
          speed=nil
        }
      end
      entity.destroy()
      return
    end
  end

  if util.needs_blight(ghost_name) and entity.surface.get_tile(entity.position).name ~= blight_name then
    if player_index then
      local player = game.get_player(player_index)
      player.create_local_flying_text
      {
        text={"must-be-placed-on-blight", get_prototype(ghost_name).localised_name},
        position=entity.position,
        color=nil,
        time_to_live=nil,
        speed=nil
      }
    end
    entity.destroy()
    return
  end

  local pollution = override_pollution or get_required_pollution(ghost_name, get_prototype(ghost_name))
  local ghost_data = {entity = entity, required_pollution = pollution}
  local update_tick = entity.unit_number % ghost_update_interval
  data.ghost_tick_check[update_tick] = data.ghost_tick_check[update_tick] or {}
  data.ghost_tick_check[update_tick][entity.unit_number] = ghost_data
  check_ghost(ghost_data)
end

function register_ghost_built(entity, player_index, override_pollution) -- call spawner_ghost_built from other scripts
  spawner_ghost_built(entity, player_index, override_pollution)
end

local on_built_entity = function(event)
  local entity = event.created_entity or event.entity
  if not (entity and entity.valid) then return end

  --make_proxy(entity)

  if (get_spawner_map()[entity.name]) then
    return spawner_built(entity)
  end

  --if not util.is_hivemind_force(entity.force) then return end

  if entity.type == "entity-ghost" then
    local ghost_name = entity.ghost_name
    if util.get_hivemind_entity_list()[ghost_name] then
      return spawner_ghost_built(entity, event.player_index)
    end
  end

end

local check_spawners_on_tick = function(tick)

  local mod = tick % spawners_update_interval
  local entities = data.spawner_tick_check[mod]
  if not entities then return end

  for unit_number, spawner_data in pairs (entities) do
    --count = count + 1
    if check_spawner(spawner_data) then
      entities[unit_number] = nil
    end
  end
end

local check_ghosts_on_tick = function(tick)

  local mod = tick % ghost_update_interval
  local entities = data.ghost_tick_check[mod]
  if not entities then return end

  for unit_number, ghost_data in pairs (entities) do
    if check_ghost(ghost_data) then
      entities[unit_number] = nil
    end
  end
end

local expiry_time = 180
local check_not_idle_units = function(tick)
  if tick % expiry_time ~= 0 then return end
  local expiry_tick = tick - expiry_time
  local max = sanity_max
  for unit_number, unit_data in pairs (data.not_idle_units) do
    if unit_data.tick <= expiry_tick then
      data.not_idle_units[unit_number] = nil
    end
  end
end

local check_update_map_settings = function(tick)
  if tick and tick % 600 ~= 0 then return end
  data.destroy_factor = game.map_settings.enemy_evolution.destroy_factor
  data.enemy_attack_pollution_consumption_modifier = game.map_settings.pollution.enemy_attack_pollution_consumption_modifier
end

local check_update_pop_cap = function(tick)
  if tick and tick % 60 ~= 0 then return end
  update_pop_cap()
end


local on_tick = function(event)
  check_spawners_on_tick(event.tick)
  check_ghosts_on_tick(event.tick)
  check_not_idle_units(event.tick)
  check_update_map_settings(event.tick)
  check_update_pop_cap(event.tick)
end

local on_ai_command_completed = function(event)
  local command_data = data.not_idle_units[event.unit_number]
  if command_data then
    return check_ghost(command_data.ghost_data)
  end
end

local redistribute_on_tick_checks = function()

  local new_spawner_tick_check = {}
  for k, array in pairs (data.spawner_tick_check) do
    for unit_number, data in pairs (array) do
      local mod = unit_number % spawners_update_interval
      new_spawner_tick_check[mod] = new_spawner_tick_check[mod] or {}
      new_spawner_tick_check[mod][unit_number] = data
    end
  end
  data.spawner_tick_check = new_spawner_tick_check

  local new_ghost_tick_check = {}
  for k, array in pairs (data.ghost_tick_check) do
    for unit_number, data in pairs (array) do
      local mod = unit_number % ghost_update_interval
      new_ghost_tick_check[mod] = new_ghost_tick_check[mod] or {}
      new_ghost_tick_check[mod][unit_number] = data
    end
  end
  data.ghost_tick_check = new_ghost_tick_check

end

local migrate_proxies = function()
  if not data.proxies then return end
  local types = {"assembling-machine", "lab", "mining-drill"}
  for k, surface in pairs (game.surfaces) do
    for k, entity in pairs (surface.find_entities_filtered{type = types, force = "hivemind"}) do
      entity.destructible = true
    end
  end
  data.proxies = nil
end

local on_research_finished = function(event)

  -- do the pop cap thingy
  if event.research.name:find("popcap") then
    data.max_pop_count[event.research.force.index] =  get_max_pop_count(event.research.force.index) + settings.global["hivemind-increase-per-level"].value
  -- data.max_pop_count = event.research.level * 10 + 20
  end

  for force in pairs(shared.needs_oponent_tech) do
    for tech in pairs(shared.needs_oponent_tech[force]) do
      local check_all_techs = 0
      for _, y in pairs(shared.needs_oponent_tech[force][tech]) do
        if game.forces[event.research.force.name].technologies[y].researched == true then
          check_all_techs = check_all_techs + 1
        end
      end
      if #shared.needs_oponent_tech[force][tech] == check_all_techs then
        game.forces[force].technologies[tech].enabled = true
        game.print({"stealing.stole",{"stealing."..force},{"stealing."..event.research.force.name}})
      end
    end
  end
end

local on_entity_died = function(event)
  local cause_force = event.force
  local entity = event.entity
  local force = entity.force
  if not cause_force then return end
  if force.get_friend(cause_force) or force == cause_force then return end
  if not get_spawner_map()[entity.name] then return end
  local recipe = entity.get_recipe()
  if not recipe then return end
  local spawn_count = 2 + math.ceil(get_max_pop_count(force.index) * 0.1 / get_unit_sizes(recipe.name))
  for x = 1, spawn_count, 1 do
    deploy_unit(entity, get_prototype(recipe.name))
  end
end

local events =
{
  [defines.events.on_built_entity] = on_built_entity,
  [defines.events.on_robot_built_entity] = on_built_entity,
  [defines.events.script_raised_revive] = on_built_entity,
  [defines.events.script_raised_built] = on_built_entity,
  [defines.events.on_tick] = on_tick,
  [defines.events.on_ai_command_completed] = on_ai_command_completed,

  [defines.events.on_entity_died] = on_entity_died,
  [defines.events.on_research_finished] = on_research_finished
}

commands.add_command("popcap", {"command.popcap-help"}, function(command)
  local player = game.get_player(command.player_index)
  if not player.admin then player.print({"command.admin-only",{"command.popcap-name"}}) return end
  if command.parameter == nil then player.print({"command.popcap-max", get_max_pop_count(player.force.index)}) return end
  if not tonumber(command.parameter) then player.print({"command.popcap-no-num"}) return end
  data.max_pop_count[player.force.index] = tonumber(command.parameter)
  player.print({"command.popcap-max", get_max_pop_count(player.force.index)})
end)

local setup_spawn_event = function()
  local control_events = remote.call("unit_control", "get_events")
  unit_spawned_event = control_events.on_unit_spawned
end

local unit_deployment = {}

unit_deployment.get_events = function() return events end

unit_deployment.on_init = function()
  global.unit_deployment = global.unit_deployment or data
  check_update_map_settings()
  check_update_pop_cap()
  setup_spawn_event()
end

unit_deployment.on_load = function()
  data = global.unit_deployment
  setup_spawn_event()
end

unit_deployment.on_configuration_changed = function()
  check_update_map_settings()
  if type(data.max_pop_count) ~= "table" then
    local time_store = data.max_pop_count
    data.max_pop_count = {}
    for _, force in pairs(game.forces) do
      if util.is_hivemind_force(force) then
        data.max_pop_count[force.index] = time_store
      end
    end
  end
  check_update_pop_cap()
  rendering.clear("Hive_Mind_MitchPlay")
  redistribute_on_tick_checks()
  migrate_proxies()
end

return unit_deployment