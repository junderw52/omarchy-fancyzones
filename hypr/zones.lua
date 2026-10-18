-- Zones: FancyZones-style window snapping for Omarchy.
--
-- Hold SUPER + SHIFT and drag a window with the left mouse button. The zones
-- for that monitor appear; release over one to snap the window into it.
-- SUPER + SHIFT + Z opens the zone editor on the focused monitor.
--
-- Settings live in ~/.config/omarchy/zones.json and are written by the
-- editor. They're re-read at the start of every drag, so edits apply
-- immediately. Load this file from ~/.config/hypr/hyprland.lua with:
--
--   dofile(os.getenv("HOME") .. "/.config/omarchy/plugins/fancyzones/hypr/zones.lua")

local home = os.getenv("HOME") or ""
local config_path = home .. "/.config/omarchy/zones.json"
local log_path = home .. "/.local/state/hypr-zones.log"

local defaults = {
  floatAll = false,
  gap = 8,
  debug = false,
  layouts = {
    default = {
      columns = {
        { width = 0.25, rows = { 1 } },
        { width = 0.5, rows = { 1 } },
        { width = 0.25, rows = { 1 } },
      },
    },
  },
}

-- Minimal JSON decoder; zones.json only holds objects, arrays, numbers,
-- strings and booleans.
local function decode_json(text)
  local pos = 1

  local function skip()
    pos = text:find("[^ \t\r\n]", pos) or #text + 1
  end

  local value

  local function str()
    local out = {}
    pos = pos + 1
    while true do
      local c = text:sub(pos, pos)
      if c == "" then
        error("unterminated string")
      elseif c == '"' then
        pos = pos + 1
        return table.concat(out)
      elseif c == "\\" then
        local e = text:sub(pos + 1, pos + 1)
        local map = { n = "\n", t = "\t", r = "\r", b = "\b", f = "\f" }
        if e == "u" then
          out[#out + 1] = "?"
          pos = pos + 6
        else
          out[#out + 1] = map[e] or e
          pos = pos + 2
        end
      else
        out[#out + 1] = c
        pos = pos + 1
      end
    end
  end

  function value()
    skip()
    local c = text:sub(pos, pos)
    if c == "{" then
      local obj = {}
      pos = pos + 1
      skip()
      if text:sub(pos, pos) == "}" then
        pos = pos + 1
        return obj
      end
      while true do
        skip()
        local key = str()
        skip()
        pos = pos + 1 -- :
        obj[key] = value()
        skip()
        local sep = text:sub(pos, pos)
        pos = pos + 1
        if sep == "}" then
          return obj
        elseif sep ~= "," then
          error("expected , or } at " .. pos)
        end
      end
    elseif c == "[" then
      local arr = {}
      pos = pos + 1
      skip()
      if text:sub(pos, pos) == "]" then
        pos = pos + 1
        return arr
      end
      while true do
        arr[#arr + 1] = value()
        skip()
        local sep = text:sub(pos, pos)
        pos = pos + 1
        if sep == "]" then
          return arr
        elseif sep ~= "," then
          error("expected , or ] at " .. pos)
        end
      end
    elseif c == '"' then
      return str()
    elseif text:sub(pos, pos + 3) == "true" then
      pos = pos + 4
      return true
    elseif text:sub(pos, pos + 4) == "false" then
      pos = pos + 5
      return false
    elseif text:sub(pos, pos + 3) == "null" then
      pos = pos + 4
      return nil
    else
      local num = text:match("^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
      if not num or num == "" then
        error("unexpected character at " .. pos)
      end
      pos = pos + #num
      return tonumber(num)
    end
  end

  return value()
end

local function load_config()
  local file = io.open(config_path, "r")
  if not file then
    return defaults
  end

  local text = file:read("a")
  file:close()

  local ok, parsed = pcall(decode_json, text)
  if not ok or type(parsed) ~= "table" then
    return defaults
  end

  return {
    floatAll = parsed.floatAll == true,
    gap = tonumber(parsed.gap) or defaults.gap,
    debug = parsed.debug == true,
    layouts = type(parsed.layouts) == "table" and parsed.layouts or defaults.layouts,
  }
end

local config = load_config()

local function log(message)
  if not config.debug then
    return
  end

  local file = io.open(log_path, "a")
  if file then
    file:write(os.date("%H:%M:%S "), message, "\n")
    file:close()
  end
end

local function shell_quote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

-- Usable area of a monitor in global logical coordinates (minus the bar).
local function usable_area(monitor)
  local reserved = monitor.reserved or {}
  local left, right = reserved.left or 0, reserved.right or 0
  local top, bottom = reserved.top or 0, reserved.bottom or 0

  return {
    x = monitor.x + left,
    y = monitor.y + top,
    w = monitor.width / monitor.scale - left - right,
    h = monitor.height / monitor.scale - top - bottom,
  }
end

-- Same math as zones() in ZoneModel.js.
local function zones_for(monitor)
  local layout = config.layouts[monitor.name] or config.layouts.default or defaults.layouts.default
  local columns = layout.columns or defaults.layouts.default.columns
  local area = usable_area(monitor)
  local gap = config.gap

  local inner_x, inner_y = area.x + gap, area.y + gap
  local inner_w, inner_h = area.w - gap, area.h - gap

  local zones = {}
  local fx = 0
  for _, column in ipairs(columns) do
    local fy = 0
    for _, height in ipairs(column.rows or { 1 }) do
      zones[#zones + 1] = {
        x = math.floor(inner_x + fx * inner_w),
        y = math.floor(inner_y + fy * inner_h),
        w = math.floor(column.width * inner_w - gap),
        h = math.floor(height * inner_h - gap),
      }
      fy = fy + height
    end
    fx = fx + column.width
  end

  return zones
end

local function zone_at(zones, point)
  for i, zone in ipairs(zones) do
    if point.x >= zone.x and point.x < zone.x + zone.w + config.gap and point.y >= zone.y and point.y < zone.y + zone.h + config.gap then
      return i
    end
  end

  return 0
end

local function overlay(method, ...)
  local args = { "omarchy-shell -q zones", method }
  for _, arg in ipairs({ ... }) do
    args[#args + 1] = shell_quote(arg)
  end

  hl.exec_cmd(table.concat(args, " "))
end

local function zones_json(monitor, zones)
  local items = {}
  for i, zone in ipairs(zones) do
    items[i] = string.format('{"x":%d,"y":%d,"w":%d,"h":%d}', zone.x - monitor.x, zone.y - monitor.y, zone.w, zone.h)
  end

  return string.format('{"monitor":"%s","zones":[%s]}', monitor.name, table.concat(items, ","))
end

-- Drag state while SUPER + SHIFT + drag is active.
local drag = nil
local poll_timer = nil

local function snap(window, zone)
  local selector = "address:" .. window.address
  local border = hl.get_config("general.border_size") or 0

  if not window.floating then
    hl.dispatch(hl.dsp.window.float({ action = "enable", window = selector }))
  end

  -- Resize first: resizing a floating window keeps its center, which would
  -- undo the move.
  hl.dispatch(hl.dsp.window.resize({ x = zone.w - 2 * border, y = zone.h - 2 * border, window = selector }))
  hl.dispatch(hl.dsp.window.move({ x = zone.x + border, y = zone.y + border, window = selector }))
end

local function finish()
  if not drag then
    return
  end

  local state = drag
  drag = nil
  poll_timer:set_enabled(false)
  overlay("hide")

  local window = hl.get_active_window()
  local zone = state.zones[state.zone]
  log(string.format("finish: zone %d, window %s", state.zone, window and window.class or "none"))

  if window and zone then
    snap(window, zone)
  end
end

local function poll()
  if not drag then
    poll_timer:set_enabled(false)
    return
  end

  -- Safety net in case the release never arrives.
  if os.time() - drag.started > 30 then
    log("timeout")
    finish()
    return
  end

  local cursor = hl.get_cursor_pos()
  local monitor = hl.get_monitor_at_cursor()
  if not cursor or not monitor then
    return
  end

  if monitor.name ~= drag.monitor then
    drag.monitor = monitor.name
    drag.zones = zones_for(monitor)
    drag.zone = -1
    overlay("show", zones_json(monitor, drag.zones))
  end

  local zone = zone_at(drag.zones, cursor)
  if zone ~= drag.zone then
    drag.zone = zone
    overlay("highlight", tostring(zone))
  end
end

local function begin()
  local monitor = hl.get_monitor_at_cursor()
  if not monitor then
    return
  end

  config = load_config()
  log("begin on " .. monitor.name)

  drag = {
    monitor = monitor.name,
    zones = zones_for(monitor),
    zone = -1,
    started = os.time(),
  }
  overlay("show", zones_json(monitor, drag.zones))
  poll_timer:set_enabled(true)
end

local function edit()
  local monitor = hl.get_active_monitor()
  if not monitor then
    return
  end

  local area = usable_area(monitor)
  local payload = string.format(
    '{"monitor":"%s","area":{"x":%d,"y":%d,"w":%d,"h":%d}}',
    monitor.name,
    area.x - monitor.x,
    area.y - monitor.y,
    area.w,
    area.h
  )
  hl.exec_cmd("omarchy-shell -q shell summon fancyzones " .. shell_quote(payload))
end

poll_timer = hl.timer(poll, { timeout = 30, type = "repeat" })
poll_timer:set_enabled(false)

local float_rule = hl.window_rule({ match = { class = ".*" }, float = true })
float_rule:set_enabled(config.floatAll)

-- Called by the editor after saving: `hyprctl eval 'Zones.reload()'`.
Zones = {
  reload = function()
    config = load_config()
    float_rule:set_enabled(config.floatAll)
  end,
  edit = edit,
}

-- The press handler is registered before the drag so both run on the same click.
hl.bind("SUPER + SHIFT + mouse:272", begin, { non_consuming = true })
o.bind("SUPER + SHIFT + mouse:272", "Drag window into a zone", hl.dsp.window.drag(), { mouse = true })
o.bind("SUPER + SHIFT + Z", "Edit window zones", edit)

-- Fires on every left-button release, whatever modifiers are still held, so
-- letting go of SHIFT before the mouse button still snaps.
hl.bind("mouse:272", finish, { release = true, ignore_mods = true, non_consuming = true, transparent = true })
