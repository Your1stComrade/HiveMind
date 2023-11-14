local util = require("script/script_util")

local shared = require("shared")
local unit_deployment = require("script/unit_deployment")

local on_marked_for_upgrade = function(event)
  local entity = event.entity
  local target = event.target

  local can_upgrade = false

  if get_needs_technology(ghost_name) then
    if entity.force.technologies[get_needs_technology(ghost_name)].researched then
      game.print("has tech")
      can_upgrade = true
    end
  else
    game.print("no tech required")
    can_upgrade = true
  end

  if can_upgrade then
    local stored_pollution = shared.required_pollution[entity.name]
  
    local required_pollution = shared.required_pollution[target.name]

    local difference = required_pollution - stored_pollution

    if difference <= 0 then
      entity.surface.create_entity{
        name = target.name, 
        position = entity.position, 
        direction = event.direction,
        force = entity.force
      }
      entity.destroy()
    else
      local ent = entity.surface.create_entity{
        name = "entity-ghost", 
        inner_name = target.name,
        position = entity.position, 
        direction = event.direction,
        force = entity.force
      }

      register_ghost_built(ent, event.player_index, stored_pollution)

      entity.destroy()
    end
  end
end

local events =
{
  [defines.events.on_marked_for_upgrade] = on_marked_for_upgrade,
}

local lib = {}

lib.get_events = function() return events end

return lib