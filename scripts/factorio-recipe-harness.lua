local data_root = arg[1] or "wube-factorio-data"
local requested_mods = arg[2] or "base,elevated-rails,quality,space-age"

local function path_join(...)
  local parts = {...}
  return table.concat(parts, "/"):gsub("/+", "/")
end

local function file_exists(path)
  local file = io.open(path, "rb")
  if file then
    file:close()
    return true
  end
  return false
end

local function read_file(path)
  local file = assert(io.open(path, "rb"))
  local contents = file:read("*a")
  file:close()
  return contents
end

local raw_pairs = pairs

function _G.pairs(value)
  local metatable = getmetatable(value)
  if metatable and metatable.__pairs then
    return metatable.__pairs(value)
  end

  local keys = {}
  for key in raw_pairs(value) do
    keys[#keys + 1] = key
  end

  local index = 0
  return function()
    index = index + 1
    local key = keys[index]
    if key ~= nil then
      return key, value[key]
    end
  end
end

local function table_size(value)
  local count = 0
  for _ in pairs(value) do
    count = count + 1
  end
  return count
end

_G.table_size = table_size
_G.log = function(message)
  io.stderr:write(tostring(message), "\n")
end
_G.serpent = {
  block = function(value)
    return tostring(value)
  end,
}

if not math.atan2 then
  math.atan2 = function(y, x)
    return math.atan(y, x)
  end
end

if not math.pow then
  math.pow = function(x, y)
    return x ^ y
  end
end

local next_enum_value = 1000
local function enum_table(values)
  local enum = values or {}
  return setmetatable(enum, {
    __index = function(table_, key)
      next_enum_value = next_enum_value + 1
      rawset(table_, key, next_enum_value)
      return next_enum_value
    end,
  })
end

local item_prototype_types = {
  ["ammo"] = true,
  ["armor"] = true,
  ["blueprint"] = true,
  ["blueprint-book"] = true,
  ["capsule"] = true,
  ["copy-paste-tool"] = true,
  ["deconstruction-item"] = true,
  ["gun"] = true,
  ["item"] = true,
  ["item-with-entity-data"] = true,
  ["item-with-inventory"] = true,
  ["item-with-label"] = true,
  ["item-with-tags"] = true,
  ["module"] = true,
  ["rail-planner"] = true,
  ["repair-tool"] = true,
  ["selection-tool"] = true,
  ["space-platform-starter-pack"] = true,
  ["spidertron-remote"] = true,
  ["tool"] = true,
  ["upgrade-item"] = true,
}

local equipment_prototype_types = {
  ["active-defense-equipment"] = true,
  ["battery-equipment"] = true,
  ["belt-immunity-equipment"] = true,
  ["energy-shield-equipment"] = true,
  ["generator-equipment"] = true,
  ["inventory-bonus-equipment"] = true,
  ["movement-bonus-equipment"] = true,
  ["night-vision-equipment"] = true,
  ["roboport-equipment"] = true,
  ["solar-panel-equipment"] = true,
}

local function prototype_type_set(filter)
  return setmetatable({}, {
    __pairs = function()
      local key = nil
      return function()
        repeat
          key = next(data and data.raw or {}, key)
          if key == nil then return nil end
        until filter(key)
        return key, true
      end
    end,
  })
end

_G.defines = {
  default_icon_size = 64,
  direction = enum_table({
    north = 0,
    northnortheast = 1,
    northeast = 2,
    eastnortheast = 3,
    east = 4,
    eastsoutheast = 5,
    southeast = 6,
    southsoutheast = 7,
    south = 8,
    southsouthwest = 9,
    southwest = 10,
    westsouthwest = 11,
    west = 12,
    westnorthwest = 13,
    northwest = 14,
    northnorthwest = 15,
  }),
  prototypes = {
    item = prototype_type_set(function(type_name)
      return item_prototype_types[type_name] == true
    end),
    entity = prototype_type_set(function(type_name)
      return item_prototype_types[type_name] ~= true
        and equipment_prototype_types[type_name] ~= true
        and type_name ~= "fluid"
        and type_name ~= "recipe"
        and type_name ~= "technology"
        and type_name ~= "tile"
        and type_name ~= "quality"
    end),
    equipment = prototype_type_set(function(type_name)
      return equipment_prototype_types[type_name] == true
    end),
  },
  inventory = enum_table(),
  build_mode = enum_table(),
  build_check_type = enum_table(),
  chunk_generated_status = enum_table(),
  command = enum_table(),
  controllers = enum_table(),
  events = enum_table(),
  input_method = enum_table(),
  logistic_member_index = enum_table(),
  shooting = enum_table(),
  wire_connector_id = enum_table(),
}

_G.feature_flags = setmetatable({}, {
  __index = function(table_, key)
    rawset(table_, key, true)
    return true
  end,
})

_G.data = {
  raw = {},
  is_demo = false,
}

local prototype_sources = {}
local current_mod_stack = {}

function data.extend(self, otherdata)
  if self ~= data and otherdata == nil then
    otherdata = self
  end

  if type(otherdata) ~= "table" then
    error("data:extend expected an array of prototypes")
  end

  for _, prototype in ipairs(otherdata) do
    if type(prototype) ~= "table" then
      error("data:extend expected prototype tables")
    end
    if not prototype.type then
      error("Missing prototype type")
    end
    if not prototype.name then
      error("Missing prototype name for type " .. tostring(prototype.type))
    end

    local prototypes = data.raw[prototype.type]
    if not prototypes then
      prototypes = {}
      data.raw[prototype.type] = prototypes
    end

    prototypes[prototype.name] = prototype
    prototype_sources[prototype.type .. "|" .. prototype.name] = current_mod_stack[#current_mod_stack]
  end
end

local mods_to_load = {}
for mod in requested_mods:gmatch("[^,]+") do
  local trimmed_mod = mod:match("^%s*(.-)%s*$")
  if trimmed_mod ~= "" then
    mods_to_load[#mods_to_load + 1] = trimmed_mod
  end
end

local mod_roots = { core = path_join(data_root, "core") }
local mods = {}

local function parse_mod_version(mod)
  local info_path = path_join(data_root, mod, "info.json")
  if not file_exists(info_path) then return "" end
  local version = read_file(info_path):match('"version"%s*:%s*"([^"]+)"')
  return version or ""
end

for _, mod in ipairs(mods_to_load) do
  mod_roots[mod] = path_join(data_root, mod)
  mods[mod] = parse_mod_version(mod)
end
_G.mods = mods

local loaded_modules = {}
local virtual_modules = {}

local function virtual_graphics_module()
  return {
    width = 1,
    height = 1,
    shift = {0, 0},
    line_length = 1,
    frames = 1,
  }
end

local function virtual_named_table_module()
  return setmetatable({}, {
    __index = function(table_, key)
      local value = {}
      rawset(table_, key, value)
      return value
    end,
  })
end

local function virtual_sound_module(module, normalized)
  return function()
    local name = normalized:match("([^/]+)$") or module
    return {
      type = "ambient-sound",
      name = name,
      sound = {filename = module .. ".ogg"},
    }
  end
end

local function normalize_module_path(module)
  return (module:gsub("%.", "/"))
end

local function resolve_module(module)
  local explicit_mod, explicit_path = module:match("^__([%w%-]+)__[%.%/]?(.*)$")

  if explicit_mod then
    local root = mod_roots[explicit_mod]
    if not root then
      root = path_join(data_root, explicit_mod)
      mod_roots[explicit_mod] = root
    end

    local normalized = normalize_module_path(explicit_path)
    local candidates = {
      path_join(root, normalized .. ".lua"),
      path_join(root, "lualib", normalized .. ".lua"),
    }

    for _, candidate in ipairs(candidates) do
      if file_exists(candidate) then
        return candidate, explicit_mod
      end
    end

    if normalized:match("^graphics/") then
      local virtual_path = "__virtual__/" .. module
      virtual_modules[virtual_path] = virtual_graphics_module
      return virtual_path, explicit_mod
    end

    if normalized:match("^menu%-simulations/") then
      local virtual_path = "__virtual__/" .. module
      virtual_modules[virtual_path] = virtual_named_table_module
      return virtual_path, explicit_mod
    end

    if normalized:match("^sound/") then
      local virtual_path = "__virtual__/" .. module
      virtual_modules[virtual_path] = virtual_sound_module(module, normalized)
      return virtual_path, explicit_mod
    end
  else
    local current_mod = current_mod_stack[#current_mod_stack] or "core"
    local normalized = normalize_module_path(module)
    local candidates = {
      { path_join(mod_roots[current_mod] or path_join(data_root, current_mod), normalized .. ".lua"), current_mod },
      { path_join(mod_roots[current_mod] or path_join(data_root, current_mod), "lualib", normalized .. ".lua"), current_mod },
      { path_join(mod_roots.core, "lualib", normalized .. ".lua"), "core" },
      { path_join(mod_roots.core, normalized .. ".lua"), "core" },
    }

    for _, candidate in ipairs(candidates) do
      if file_exists(candidate[1]) then
        return candidate[1], candidate[2]
      end
    end

    if normalized:match("^graphics/") then
      local virtual_path = "__virtual__/" .. current_mod .. "/" .. module
      virtual_modules[virtual_path] = virtual_graphics_module
      return virtual_path, current_mod
    end

    if normalized:match("^menu%-simulations/") then
      local virtual_path = "__virtual__/" .. current_mod .. "/" .. module
      virtual_modules[virtual_path] = virtual_named_table_module
      return virtual_path, current_mod
    end

    if normalized:match("^sound/") then
      local virtual_path = "__virtual__/" .. current_mod .. "/" .. module
      virtual_modules[virtual_path] = virtual_sound_module(module, normalized)
      return virtual_path, current_mod
    end
  end

  error("Unable to resolve Lua module: " .. module)
end

local function execute_lua_file(path, mod)
  local chunk, load_error = loadfile(path, "bt", _G)
  if not chunk then
    error(load_error)
  end

  current_mod_stack[#current_mod_stack + 1] = mod
  local ok, result = pcall(chunk)
  current_mod_stack[#current_mod_stack] = nil

  if not ok then
    error(path .. ": " .. tostring(result))
  end

  return result
end

function require(module)
  local path, mod = resolve_module(module)

  if loaded_modules[path] ~= nil then
    return loaded_modules[path]
  end

  if virtual_modules[path] then
    local result = virtual_modules[path]()
    loaded_modules[path] = result
    return result
  end

  loaded_modules[path] = true
  local result = execute_lua_file(path, mod)
  if result ~= nil then
    loaded_modules[path] = result
    return result
  end
  return true
end

local function run_stage(mod, stage_file)
  local path = path_join(data_root, mod, stage_file)
  if file_exists(path) then
    execute_lua_file(path, mod)
  end
end

run_stage("core", "data.lua")
for _, mod in ipairs(mods_to_load) do
  run_stage(mod, "data.lua")
end
for _, mod in ipairs(mods_to_load) do
  run_stage(mod, "data-updates.lua")
end
for _, mod in ipairs(mods_to_load) do
  run_stage(mod, "data-final-fixes.lua")
end

local function sorted_keys(object)
  local keys = {}
  for key in pairs(object or {}) do
    keys[#keys + 1] = key
  end
  table.sort(keys, function(a, b)
    return tostring(a) < tostring(b)
  end)
  return keys
end

local function camel_fields(input, output, fields)
  for _, field in ipairs(fields) do
    local source_key = field[1]
    local target_key = field[2]
    if input[source_key] ~= nil then
      output[target_key] = input[source_key]
    end
  end
end

local function url_encode_path_segment(value)
  return tostring(value):gsub("([^%w%-%._~])", function(char)
    return string.format("%%%02X", string.byte(char))
  end)
end

local function url_encode_wiki_page_title(value)
  local encoded_parts = {}
  for part in tostring(value):gmatch("[^/]+") do
    encoded_parts[#encoded_parts + 1] = url_encode_path_segment(part)
  end
  return table.concat(encoded_parts, "/")
end

local function wiki_title_from_name(name)
  local words = {}
  for word in tostring(name):gmatch("[^-]+") do
    local lower = word:lower()
    if lower:match("^mk%d+$") then
      words[#words + 1] = lower:upper()
    elseif #words == 0 then
      words[#words + 1] = lower:gsub("^%l", string.upper)
    else
      words[#words + 1] = lower
    end
  end
  return table.concat(words, "_")
end

local function wiki_title_from_icon_path(icon_path)
  if type(icon_path) ~= "string" then return nil end
  local filename = icon_path:match("([^/]+)%.png$")
  if not filename then return nil end
  return wiki_title_from_name(filename)
end

local function is_useful_composite_icon_path(icon_path)
  if type(icon_path) ~= "string" then return false end
  local filename = icon_path:match("([^/]+)%.png$")
  if not filename then return false end

  local ignored = {
    ["barrel-empty"] = true,
    ["barrel-empty-side-mask"] = true,
    ["barrel-empty-top-mask"] = true,
    ["barrel-fill"] = true,
    ["barrel-fill-side-mask"] = true,
    ["barrel-fill-top-mask"] = true,
    ["barrel-hoop-top-mask"] = true,
    ["barrel-side-mask"] = true,
    ["recycling"] = true,
    ["recycling-top"] = true,
  }

  return not ignored[filename] and not filename:match("mask$")
end

local function wiki_title_from_composite_icons(icons)
  if type(icons) ~= "table" then return nil end

  for _, icon in ipairs(icons) do
    if type(icon) == "table" and is_useful_composite_icon_path(icon.icon) then
      return wiki_title_from_icon_path(icon.icon)
    end
  end

  return nil
end

local wiki_url_overrides = {
  ["Battery_equipment"] = {page = "Personal_battery", icon = "Personal_battery"},
  ["Battery_MK2_equipment"] = {page = "Personal_battery_MK2", icon = "Personal_battery_MK2"},
  ["Battery_MK3_equipment"] = {page = "Personal_battery_MK3", icon = "Personal_battery_MK3"},
  ["Bottomless_chest"] = false,
  ["Capture_bot"] = {page = "Capture_bot_rocket", icon = "Capture_bot_rocket"},
  ["Capture_robot_rocket"] = {page = "Capture_bot_rocket", icon = "Capture_bot_rocket"},
  ["Coin"] = false,
  ["Copper_ore_melting"] = {page = "Molten_copper", icon = "Molten_copper"},
  ["Crude_oil_resource"] = {page = "Crude_oil", icon = "Crude_oil"},
  ["Discharge_defense_equipment"] = {page = "Discharge_defense", icon = "Discharge_defense"},
  ["Electric_energy_interface"] = {page = false, icon = "Electric_energy_interface"},
  ["Empty_barrel"] = {page = "Barrel", icon = "Barrel"},
  ["Empty_module_slot"] = false,
  ["Energy_shield_equipment"] = {page = "Energy_shield", icon = "Energy_shield"},
  ["Energy_shield_MK2_equipment"] = {page = "Energy_shield_MK2", icon = "Energy_shield_MK2"},
  ["Exoskeleton_equipment"] = {page = "Exoskeleton", icon = "Exoskeleton"},
  ["Express_loader"] = false,
  ["Fast_loader"] = false,
  ["Fish"] = {page = "Raw_fish", icon = "Raw_fish"},
  ["Fission_reactor_equipment"] = {page = "Portable_fission_reactor", icon = "Portable_fission_reactor"},
  ["Fluoroketone_cold"] = {page = "Fluoroketone_(cold)", icon = "Fluoroketone_(cold)"},
  ["Fluoroketone_cold_barrel"] = {page = "Barrel", icon = "Fluoroketone_(cold)_barrel"},
  ["Fluoroketone_cooling"] = {page = "Fluoroketone_(cold)", icon = "Fluoroketone_(cold)"},
  ["Fluoroketone_hot"] = {page = "Fluoroketone_(hot)", icon = "Fluoroketone_(hot)"},
  ["Fluoroketone_hot_barrel"] = {page = "Barrel", icon = "Fluoroketone_(hot)_barrel"},
  ["Fluorine_vent"] = {page = "Fluorine", icon = "Fluorine"},
  ["Fusion_reactor_equipment"] = {page = "Portable_fusion_reactor", icon = "Portable_fusion_reactor"},
  ["Heat_boiler"] = {page = "Heat_exchanger", icon = "Heat_exchanger"},
  ["Heat_interface"] = {page = "Map_editor#Editor_entities", icon = "Heat_interface"},
  ["Infinity_cargo_wagon"] = false,
  ["Infinity_chest"] = {page = "Map_editor#Editor_entities", icon = "Infinity_chest"},
  ["Infinity_pipe"] = {page = "Map_editor#Editor_entities", icon = "Infinity_pipe"},
  ["Iron_ore_melting"] = {page = "Molten_iron", icon = "Molten_iron"},
  ["Lane_splitter"] = {page = false, icon = "Lane_splitter"},
  ["Linked_chest_icon"] = {page = false, icon = "Linked_chest"},
  ["Loader"] = {page = "Prototype/Loader1x2", icon = "Loader"},
  ["Long_handed_inserter"] = {page = "Long-handed_inserter", icon = "Long-handed_inserter"},
  ["Night_vision_equipment"] = {page = "Nightvision", icon = "Nightvision"},
  ["One_way_valve_east"] = false,
  ["Overflow_valve_east"] = false,
  ["Pentapod_egg_3"] = {page = "Pentapod_egg", icon = "Pentapod_egg"},
  ["Personal_laser_defense_equipment"] = {page = "Personal_laser_defense", icon = "Personal_laser_defense"},
  ["Personal_roboport_equipment"] = {page = "Personal_roboport", icon = "Personal_roboport"},
  ["Personal_roboport_MK2_equipment"] = {page = "Personal_roboport_MK2", icon = "Personal_roboport_MK2"},
  ["Piercing_shotgun_shell"] = {page = "Piercing_shotgun_shells", icon = "Piercing_shotgun_shells"},
  ["Proxy_container"] = false,
  ["Rail"] = {page = "Rail", icon = "Straight_rail"},
  ["Science"] = false,
  ["Shotgun_shell"] = {page = "Shotgun_shells", icon = "Shotgun_shells"},
  ["Small_lamp"] = {page = "Lamp", icon = "Lamp"},
  ["Solar_panel_equipment"] = {page = "Portable_solar_panel", icon = "Portable_solar_panel"},
  ["Space_platform_starter_pack"] = {page = "Space_platform_starter_pack", icon = "Space_platform_hub"},
  ["Stone_wall"] = {page = "Wall", icon = "Wall"},
  ["Sulfuric_acid_geyser"] = {page = "Sulfuric_acid", icon = "Sulfuric_acid"},
  ["Teslagun"] = {page = "Tesla_gun", icon = "Tesla_gun"},
  ["Top_up_valve_east"] = false,
  ["Turbo_loader"] = false,
  ["Unknown"] = false,
  ["Uranium_235"] = {page = "Uranium-235", icon = "Uranium-235"},
  ["Uranium_238"] = {page = "Uranium-238", icon = "Uranium-238"},
}

local function wiki_page_url_from_title(title)
  local page_title, fragment = tostring(title):match("^([^#]+)#(.+)$")
  if page_title then
    return "https://wiki.factorio.com/" .. url_encode_wiki_page_title(page_title) .. "#" .. fragment
  end
  return "https://wiki.factorio.com/" .. url_encode_wiki_page_title(title)
end

local function wiki_icon_url_from_title(title)
  return "https://wiki.factorio.com/images/" .. url_encode_path_segment(title) .. ".png"
end

local function wiki_urls_from_title(title)
  if not title or title == "" then return nil, nil end
  local override = wiki_url_overrides[title]
  if override == false then return nil, nil end

  local page_title = title
  local icon_title = title
  if override then
    page_title = override.page
    icon_title = override.icon
  end
  local page_url = page_title and wiki_page_url_from_title(page_title) or nil
  local icon_url = icon_title and wiki_icon_url_from_title(icon_title) or nil
  return page_url, icon_url
end

local function find_named_prototype(product_type, name)
  if product_type == "fluid" then
    return data.raw.fluid and data.raw.fluid[name] or nil
  end

  for type_name in pairs(defines.prototypes.item) do
    local prototypes = data.raw[type_name]
    if prototypes and prototypes[name] then
      return prototypes[name]
    end
  end

  return nil
end

local function add_wiki_urls(target, title)
  local page_url, icon_url = wiki_urls_from_title(title)
  if page_url then target.wikiPageUrl = page_url end
  if icon_url then target.wikiIconUrl = icon_url end
end

local function add_product_wiki_urls(target, product_type, name)
  local prototype = find_named_prototype(product_type, name)
  local title = prototype and wiki_title_from_icon_path(prototype.icon) or nil
  add_wiki_urls(target, title or wiki_title_from_name(name))
end

local resource_products_by_key = {}

local function copy_array(value)
  local output = {}
  if type(value) ~= "table" then return output end

  for _, item in ipairs(value) do
    output[#output + 1] = item
  end

  return output
end

local function add_resource_availability(target, product_type, name)
  local resource_product = resource_products_by_key[product_type .. ":" .. name]
  if not resource_product then return end

  if #resource_product.planets > 0 then
    target.resourcePlanets = copy_array(resource_product.planets)
  end
  if #resource_product.resources > 0 then
    target.sourceResources = copy_array(resource_product.resources)
  end
end

local function normalize_stack(stack, default_type)
  if type(stack) ~= "table" then return nil end

  local name = stack.name or stack[1]
  if not name then return nil end

  local normalized = {
    type = stack.type or default_type or "item",
    name = name,
  }

  add_product_wiki_urls(normalized, normalized.type, normalized.name)
  add_resource_availability(normalized, normalized.type, normalized.name)

  if stack.amount ~= nil then normalized.amount = stack.amount end
  if stack[2] ~= nil and normalized.amount == nil then normalized.amount = stack[2] end
  if stack.amount_min ~= nil then normalized.amountMin = stack.amount_min end
  if stack.amount_max ~= nil then normalized.amountMax = stack.amount_max end

  camel_fields(stack, normalized, {
    {"probability", "probability"},
    {"extra_count_fraction", "extraCountFraction"},
    {"catalyst_amount", "catalystAmount"},
    {"ignored_by_stats", "ignoredByStats"},
    {"ignored_by_productivity", "ignoredByProductivity"},
    {"fluidbox_index", "fluidboxIndex"},
    {"temperature", "temperature"},
    {"minimum_temperature", "minimumTemperature"},
    {"maximum_temperature", "maximumTemperature"},
  })

  if normalized.amount == nil and normalized.amountMin == nil and normalized.amountMax == nil then
    normalized.amount = 1
  end

  return normalized
end

local function add_unique(array, seen, value)
  if value == nil or seen[value] then return end
  seen[value] = true
  array[#array + 1] = value
end

local function collect_resource_planets()
  local planets_by_resource = {}

  for _, planet_name in ipairs(sorted_keys(data.raw.planet or {})) do
    local planet = data.raw.planet[planet_name]
    local map_gen_settings = planet and planet.map_gen_settings
    local autoplace_settings = map_gen_settings and map_gen_settings.autoplace_settings
    local entity_autoplace = autoplace_settings and autoplace_settings["entity"]
    local entity_settings = entity_autoplace and entity_autoplace.settings

    for _, entity_name in ipairs(sorted_keys(entity_settings or {})) do
      if data.raw.resource and data.raw.resource[entity_name] then
        local planets = planets_by_resource[entity_name]
        if not planets then
          planets = {}
          planets_by_resource[entity_name] = planets
        end
        planets[#planets + 1] = planet_name
      end
    end
  end

  return planets_by_resource
end

local normalize_stack_list

local function normalize_resource_products(resource)
  local minable = resource.minable
  if type(minable) ~= "table" then return {} end

  if minable.results then
    return normalize_stack_list(minable.results, "item")
  end

  if minable.result then
    local product = {
      type = "item",
      name = minable.result,
      amount = minable.count or minable.amount or 1,
    }
    add_product_wiki_urls(product, product.type, product.name)
    return {product}
  end

  return {}
end

local function build_resources_by_product(resources)
  local by_product = {}
  local seen_by_product = {}

  for _, resource_name in ipairs(sorted_keys(resources)) do
    local resource = resources[resource_name]

    for _, product in ipairs(resource.products) do
      local key = product.type .. ":" .. product.name
      local product_entry = by_product[key]
      if not product_entry then
        product_entry = {
          type = product.type,
          name = product.name,
          resources = {},
          planets = {},
        }
        add_product_wiki_urls(product_entry, product.type, product.name)
        by_product[key] = product_entry
        seen_by_product[key] = {
          resources = {},
          planets = {},
        }
      end

      local seen = seen_by_product[key]
      add_unique(product_entry.resources, seen.resources, resource.name)
      for _, planet_name in ipairs(resource.planets) do
        add_unique(product_entry.planets, seen.planets, planet_name)
      end
    end
  end

  for _, key in ipairs(sorted_keys(by_product)) do
    table.sort(by_product[key].resources)
    table.sort(by_product[key].planets)
  end

  return by_product
end

local function build_resources()
  local planets_by_resource = collect_resource_planets()
  local resources = {}

  for _, name in ipairs(sorted_keys(data.raw.resource or {})) do
    local resource = data.raw.resource[name]
    local normalized = {
      name = resource.name,
      planets = planets_by_resource[name] or {},
      products = normalize_resource_products(resource),
    }

    local source_mod = prototype_sources["resource|" .. resource.name]
    if source_mod then normalized.sourceMod = source_mod end

    add_wiki_urls(normalized, wiki_title_from_icon_path(resource.icon) or wiki_title_from_name(resource.name))

    camel_fields(resource, normalized, {
      {"category", "category"},
      {"subgroup", "subgroup"},
      {"order", "order"},
      {"icon", "icon"},
      {"infinite", "infinite"},
      {"minimum", "minimum"},
      {"normal", "normal"},
      {"map_color", "mapColor"},
    })

    resources[name] = normalized
  end

  return resources, build_resources_by_product(resources)
end

function normalize_stack_list(stacks, default_type)
  local normalized = {}
  if type(stacks) ~= "table" then return normalized end

  for _, stack in ipairs(stacks) do
    local normalized_stack = normalize_stack(stack, default_type)
    if normalized_stack then
      normalized[#normalized + 1] = normalized_stack
    end
  end

  return normalized
end

local function normalize_results(recipe)
  if recipe.results then
    return normalize_stack_list(recipe.results, "item")
  end

  if recipe.result then
    return {
      {
        type = "item",
        name = recipe.result,
        amount = recipe.result_count or 1,
      },
    }
  end

  return {}
end

local function normalize_recipe(recipe)
  local normalized = {
    name = recipe.name,
    category = recipe.category or "crafting",
    enabled = recipe.enabled ~= false,
    energyRequired = recipe.energy_required or 0.5,
    ingredients = normalize_stack_list(recipe.ingredients, "item"),
    results = normalize_results(recipe),
  }

  local source_mod = prototype_sources["recipe|" .. recipe.name]
  if source_mod then normalized.sourceMod = source_mod end

  local recipe_wiki_title = nil
  if not recipe.parameter then
    recipe_wiki_title = wiki_title_from_icon_path(recipe.icon) or wiki_title_from_composite_icons(recipe.icons)
  end
  if not recipe_wiki_title and not recipe.parameter and #normalized.results == 1 then
    recipe_wiki_title = wiki_title_from_name(normalized.results[1].name)
  end
  add_wiki_urls(normalized, recipe_wiki_title)

  camel_fields(recipe, normalized, {
    {"subgroup", "subgroup"},
    {"order", "order"},
    {"main_product", "mainProduct"},
    {"icon", "icon"},
    {"icons", "icons"},
    {"localised_name", "localisedName"},
    {"hidden", "hidden"},
    {"hide_from_player_crafting", "hideFromPlayerCrafting"},
    {"hide_from_signal_gui", "hideFromSignalGui"},
    {"allow_productivity", "allowProductivity"},
    {"allow_quality", "allowQuality"},
    {"allow_decomposition", "allowDecomposition"},
    {"unlock_results", "unlockResults"},
    {"surface_conditions", "surfaceConditions"},
    {"parameter", "parameter"},
  })

  return normalized
end

local resources, resources_by_product = build_resources()
resource_products_by_key = resources_by_product

local recipes = {}
local recipes_by_product = {}

for _, name in ipairs(sorted_keys(data.raw.recipe or {})) do
  local recipe = normalize_recipe(data.raw.recipe[name])
  recipes[name] = recipe

  for _, product in ipairs(recipe.results) do
    local key = product.type .. ":" .. product.name
    if not recipes_by_product[key] then
      recipes_by_product[key] = {
        type = product.type,
        name = product.name,
        recipes = {},
      }
      add_product_wiki_urls(recipes_by_product[key], product.type, product.name)
      add_resource_availability(recipes_by_product[key], product.type, product.name)
    end
    recipes_by_product[key].recipes[#recipes_by_product[key].recipes + 1] = name
  end
end

for _, key in ipairs(sorted_keys(recipes_by_product)) do
  table.sort(recipes_by_product[key].recipes)
end

local function encode_json(value)
  local value_type = type(value)

  if value == nil then return "null" end
  if value_type == "boolean" then return value and "true" or "false" end
  if value_type == "number" then return tostring(value) end
  if value_type == "string" then
    return '"' .. value
      :gsub("\\", "\\\\")
      :gsub('"', '\\"')
      :gsub("\b", "\\b")
      :gsub("\f", "\\f")
      :gsub("\n", "\\n")
      :gsub("\r", "\\r")
      :gsub("\t", "\\t") .. '"'
  end
  if value_type ~= "table" then return "null" end

  local max_index = 0
  local count = 0
  local array = true
  for key in pairs(value) do
    count = count + 1
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
      array = false
      break
    end
    if key > max_index then max_index = key end
  end
  if array and max_index ~= count then array = false end

  local parts = {}
  if array then
    for index = 1, max_index do
      parts[#parts + 1] = encode_json(value[index])
    end
    return "[" .. table.concat(parts, ",") .. "]"
  end

  for _, key in ipairs(sorted_keys(value)) do
    local nested_value = value[key]
    if type(nested_value) ~= "function" then
      parts[#parts + 1] = encode_json(tostring(key)) .. ":" .. encode_json(nested_value)
    end
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

local factorio_version = "unknown"
if mods.base and mods.base ~= "" then
  factorio_version = mods.base
end

local output = {
  factorioVersion = factorio_version,
  mods = mods,
  recipeCount = table_size(recipes),
  craftableCount = table_size(recipes_by_product),
  resourceCount = table_size(resources),
  recipes = recipes,
  recipesByProduct = recipes_by_product,
  resources = resources,
  resourcesByProduct = resources_by_product,
}

io.write(encode_json(output))
