local CONFIG_FILE = "minimap.cfg"
local SERVER = "http://your-host.example.com:5055"
local PLAYER_NAME = "YourPlayerName"
local NAV_PERIPHERAL = nil
local NAV_METHOD = nil
local FRAME_INTERVAL = 1.0
local NAV_INTERVAL = 0.1
local SIDECAR_INTERVAL = 2.5

local SUB_W, SUB_H = 2, 3

-- Rasterized needle config: thin line drawn from the center cell out in the
-- compass-heading direction. Length is in sub-pixels; area is the cell
-- bounding box that gets re-blitted each tick (so old needle positions are
-- restored from cache instead of leaving a trail).
-- Load config (auto-created on first run with defaults).
if not fs.exists(CONFIG_FILE) then
  local f = fs.open(CONFIG_FILE, "w")
  f.write([[{
  "headingOffset": 0,
  "needleLength": 5,
  "controlSides": { "forward": "back", "back": "top", "left": "left", "right": "right" }
}
]])
  f.close()
end
local cfg = {}
do
  local f = fs.open(CONFIG_FILE, "r")
  local raw = f and f.readAll() or ""
  if f then f.close() end
  local ok, parsed = pcall(textutils.unserialiseJSON, raw)
  if ok and type(parsed) == "table" then cfg = parsed end
end

local NEEDLE_LENGTH_SUB = tonumber(cfg.needleLength) or 5

local function cfgSide(name, default)
  local cs = cfg.controlSides
  if type(cs) == "table" and type(cs[name]) == "string" then return cs[name] end
  return default
end
local CONTROL_SIDES = {
  forward = cfgSide("forward", "back"),
  back    = cfgSide("back",    "top"),
  left    = cfgSide("left",    "left"),
  right   = cfgSide("right",   "right"),
}
local relay = peripheral.find("redstone_relay")
local NEEDLE_AREA_W = 2 * math.ceil(NEEDLE_LENGTH_SUB / SUB_W) + 1
local NEEDLE_AREA_H = 2 * math.ceil(NEEDLE_LENGTH_SUB / SUB_H) + 1

-- 2-cell rounded blob for player markers; cells fully replaced with color+black.
local PLAYER_MARKER = { 0x2E, 0x1D }

-- Hollow circle, 2 cells wide -- same footprint as PLAYER_MARKER but outlined.
local WAYPOINT_MARKER = { 0x26, 0x19 }

-- Autopilot tunables.
local ARRIVAL_RADIUS = 15      -- blocks; stop when within this of target
local TURN_THRESHOLD = 20      -- degrees; |err| above this = pure turn, no forward
local FINE_THRESHOLD = 5       -- degrees; |err| above this = forward + correction
local TRAIL_STEP = 2           -- plot a trail dot every N cells from ship to target

local NAV_TYPES   = { "navigation_table", "ship_navigation_table", "compass" }
local NAV_METHODS = { "getRelativeAngle", "getYaw", "getRotationYaw", "getRotation" }
-- Edit minimap.cfg to tune (headingOffset, needleLength).
local HEADING_OFFSET_DEG = tonumber(cfg.headingOffset) or 0

local state = {
  bpp = 2,
  lod = 1,
  shipHeading = 0,
  target = nil,         -- { kind, name, x, z, color } - selected destination
  engaged = false,      -- autopilot driving controls?
  autoStatus = "",      -- short status string for the auto bar
  controls = {},        -- intended redstone state per channel; pending hardware
  targetCells = {},     -- list of clickable target hitboxes built each frame
  status = "starting",
  running = true,
  players = {},
  waypoints = {},
  sidecarAt = 0,
  lastFrame = nil,
  lastPos = nil,
  lastError = nil,
}
local buttons = {}

local function findMonitor()
  local m = peripheral.find("monitor")
  if m then return m end
  return term.current()
end

local monitor = findMonitor()
if monitor.setTextScale then monitor.setTextScale(0.5) end
local width, height = monitor.getSize()
local unpackValues = table.unpack or unpack

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

local function pickLod(bpp)
  if bpp <= 4 then return 1 end
  if bpp <= 24 then return 2 end
  return 3
end

local function urlencode(value)
  return tostring(value):gsub("([^%w%-_%.~])", function(c)
    return string.format("%%%02X", string.byte(c))
  end)
end

local function httpGetJson(url)
  local r, err = http.get(url, { ["accept"] = "application/json" })
  if not r then return nil, err end
  local body = r.readAll()
  r.close()
  return textutils.unserializeJSON(body), nil
end

-- Find nav peripheral by type then by method scan; mirrors how peripheral.find("speaker") works.
local function discoverNav()
  if NAV_PERIPHERAL then
    local p = peripheral.wrap(NAV_PERIPHERAL)
    if p then
      local m = NAV_METHOD
      if m and type(p[m]) == "function" then return p, m end
      for _, mm in ipairs(NAV_METHODS) do
        if type(p[mm]) == "function" then return p, mm end
      end
    end
  end
  for _, t in ipairs(NAV_TYPES) do
    local p = peripheral.find(t)
    if p then
      for _, m in ipairs(NAV_METHODS) do
        if type(p[m]) == "function" then return p, m end
      end
    end
  end
  for _, name in ipairs(peripheral.getNames()) do
    local p = peripheral.wrap(name)
    if p then
      for _, m in ipairs(NAV_METHODS) do
        if type(p[m]) == "function" then return p, m end
      end
    end
  end
  return nil, nil
end

local nav, navMethod = discoverNav()

local function readHeading()
  if not nav then return nil end
  local ok, result = pcall(nav[navMethod], nav)
  if not ok or result == nil then return nil end
  local rel
  if type(result) == "number" then rel = result
  elseif type(result) == "table" then rel = result.yaw or result.heading or result[1]
  end
  if not rel then return nil end
  -- Compass needle points at spawn (0, 0, 0). The peripheral returns its angle
  -- relative to ship-forward (CW degrees). Ship heading = world bearing to
  -- spawn minus that relative angle. Atan2 args use MC convention (X=east,
  -- Z=south, heading 0 = -Z = north, CW positive).
  if not state.lastPos then return nil end
  local sx, sz = state.lastPos.x, state.lastPos.z
  local bearingToSpawn = math.deg(math.atan2(-sx, sz))
  return (bearingToSpawn - rel + HEADING_OFFSET_DEG) % 360
end

local function applyPalette(palette)
  if not palette then return end
  for i = 1, math.min(#palette, 16) do
    local n = tonumber(palette[i], 16)
    if n then monitor.setPaletteColor(2 ^ (i - 1), n) end
  end
end

local info = httpGetJson(SERVER .. "/info")
if info and info.palette then applyPalette(info.palette) end

local function buildUrl(x, z)
  local mapHeight = math.max(3, height - 1)
  return SERVER .. "/frame?" .. table.concat({
    "x=" .. urlencode(math.floor(x * 10) / 10),
    "z=" .. urlencode(math.floor(z * 10) / 10),
    "w=" .. urlencode(width),
    "h=" .. urlencode(mapHeight),
    "bpp=" .. urlencode(state.bpp),
    "lod=" .. urlencode(state.lod),
  }, "&")
end

local function decodeTextRow(packed)
  local out = {}
  for i = 1, #packed do
    out[i] = string.char(string.byte(packed, i) + 0x40)
  end
  return table.concat(out)
end

local function drawCachedMap(mapH)
  if not state.lastFrame then return end
  for y = 1, math.min(#state.lastFrame.text, mapH) do
    monitor.setCursorPos(1, y)
    monitor.blit(decodeTextRow(state.lastFrame.text[y]), state.lastFrame.fg[y], state.lastFrame.bg[y])
  end
end

local function worldToCell(wx, wz, cx, cz, mapH)
  local bX = state.bpp * SUB_W
  local bY = state.bpp * SUB_H
  local col = math.floor((wx - cx) / bX + width / 2 + 0.5)
  local row = math.floor((wz - cz) / bY + mapH / 2 + 0.5)
  return col, row
end

-- (directionForHeading was only used by the stencil arrow; the needle uses the
-- raw heading directly.)

-- Convert MC yaw (0=S) to compass heading (0=N)
local function compassFromMcYaw(yaw)
  return ((yaw or 0) + 180) % 360
end

local function overlayCell(col, row, stenBits, color, mapH, override)
  if col < 1 or col > width or row < 1 or row > mapH then return end
  if not state.lastFrame or not state.lastFrame.text or not state.lastFrame.text[row] then return end
  local packed = state.lastFrame.text[row]
  local fg_row = state.lastFrame.fg[row]
  local bg_row = state.lastFrame.bg[row]
  if not fg_row or not bg_row or col > #packed or col > #fg_row or col > #bg_row then return end
  local cell_pattern = string.byte(packed, col) - 0x40
  local cell_fg = fg_row:sub(col, col)
  local cell_bg = bg_row:sub(col, col)
  local new_pattern, new_fg, new_bg
  if stenBits == 0 then
    -- nothing to draw here; re-blit original cell
    new_pattern, new_fg, new_bg = cell_pattern, cell_fg, cell_bg
  elseif override then
    -- replace fg pattern with stencil; keep bg color so it blends with terrain
    new_pattern = stenBits
    new_fg, new_bg = color, cell_bg
  else
    -- OR stencil into existing pattern; both terrain-fg and stencil pixels recolored
    new_pattern = bit32.bor(cell_pattern, stenBits)
    new_fg, new_bg = color, cell_bg
  end
  if bit32.band(new_pattern, 0x20) ~= 0 then
    new_pattern = bit32.bxor(new_pattern, 0x3F)
    new_fg, new_bg = new_bg, new_fg
  end
  monitor.setCursorPos(col, row)
  monitor.blit(string.char(new_pattern + 0x80), new_fg, new_bg)
end

local function overlaySelfTriangle(heading, mapH)
  local rad = math.rad(heading or 0)
  local dx = math.sin(rad)
  local dy = -math.cos(rad)  -- compass 0 = N = up = -Y on screen

  local centerCol = math.floor(width / 2 + 0.5)
  local centerRow = math.floor(mapH / 2 + 0.5)
  -- Sub-pixel coordinate of the center cells geometric center
  local centerSubX = (centerCol - 1) * SUB_W + (SUB_W - 1) / 2
  local centerSubY = (centerRow - 1) * SUB_H + (SUB_H - 1) / 2

  -- Walk the needle in fine steps, mark each sub-pixel into a per-cell bitmap.
  local cells = {}
  local steps = NEEDLE_LENGTH_SUB * 5
  for i = 0, steps do
    local t = i / steps
    local sxAbs = centerSubX + dx * NEEDLE_LENGTH_SUB * t
    local syAbs = centerSubY + dy * NEEDLE_LENGTH_SUB * t
    local sxR = math.floor(sxAbs + 0.5)
    local syR = math.floor(syAbs + 0.5)
    local col = math.floor(sxR / SUB_W) + 1
    local row = math.floor(syR / SUB_H) + 1
    local sx = sxR - (col - 1) * SUB_W
    local sy = syR - (row - 1) * SUB_H
    if sx >= 0 and sx < SUB_W and sy >= 0 and sy < SUB_H then
      local key = col * 1024 + row
      cells[key] = bit32.bor(cells[key] or 0, bit32.lshift(1, sy * SUB_W + sx))
    end
  end

  -- Tip cell: where the very last sub-pixel sits, colored differently so
  -- the head of the needle is distinguishable from the base.
  local tipSxR = math.floor(centerSubX + dx * NEEDLE_LENGTH_SUB + 0.5)
  local tipSyR = math.floor(centerSubY + dy * NEEDLE_LENGTH_SUB + 0.5)
  local tipCol = math.floor(tipSxR / SUB_W) + 1
  local tipRow = math.floor(tipSyR / SUB_H) + 1
  local tipKey = tipCol * 1024 + tipRow

  -- Re-blit the area around the center: cells on the needle get the stencil
  -- bits, the rest restore from cache (overlayCell with stenBits=0 path).
  local startCol = centerCol - math.floor(NEEDLE_AREA_W / 2)
  local startRow = centerRow - math.floor(NEEDLE_AREA_H / 2)
  for r = 0, NEEDLE_AREA_H - 1 do
    for c = 0, NEEDLE_AREA_W - 1 do
      local col = startCol + c
      local row = startRow + r
      local key = col * 1024 + row
      local color = (key == tipKey) and "2" or "0"
      overlayCell(col, row, cells[key] or 0, color, mapH, true)
    end
  end
end

-- Fully replace a single cell with a teletext pattern using forced fg/bg (no terrain preservation).
local function drawMarkerCell(col, row, pattern, fg, bg, mapH)
  if col < 1 or col > width or row < 1 or row > mapH then return end
  if bit32.band(pattern, 0x20) ~= 0 then
    pattern = bit32.bxor(pattern, 0x3F)
    fg, bg = bg, fg
  end
  monitor.setCursorPos(col, row)
  monitor.blit(string.char(pattern + 0x80), fg, bg)
end

local PLAYER_HEX_SLOTS = { "0", "1", "2", "3", "4", "d" }
local function colorForPlayer(key)
  local sum = 0
  for i = 1, #key do sum = sum + string.byte(key, i) end
  return PLAYER_HEX_SLOTS[(sum % #PLAYER_HEX_SLOTS) + 1]
end

local function isSelected(kind, name)
  return state.target and state.target.kind == kind and state.target.name == name
end

local function overlayOtherPlayers(cx, cz, mapH)
  for _, p in ipairs(state.players or {}) do
    if p.name ~= PLAYER_NAME and p.position then
      local col, row = worldToCell(p.position.x, p.position.z, cx, cz, mapH)
      local color = colorForPlayer(p.uuid or p.name or "?")
      local fg, bg = color, "f"
      if isSelected("player", p.name) then fg, bg = "f", color end
      drawMarkerCell(col, row, PLAYER_MARKER[1], fg, bg, mapH)
      drawMarkerCell(col + 1, row, PLAYER_MARKER[2], fg, bg, mapH)
      table.insert(state.targetCells, {
        col1 = col, col2 = col + 1, row = row,
        kind = "player", name = p.name,
        x = p.position.x, z = p.position.z, color = color,
      })
    end
  end
end

local NAMED_HEX = {
  white="0", yellow="1", red="2", cyan="3", lightblue="3", lime="4",
  green="d", darkgreen="5", gray="8", lightgray="6", blue="9",
  brown="c", orange="e", black="f",
}
local function paletteHexFor(name)
  return NAMED_HEX[(name or ""):lower()] or "1"
end

local function overlayWaypoints(cx, cz, mapH)
  for _, wp in ipairs(state.waypoints or {}) do
    if wp.x and wp.z then
      local col, row = worldToCell(wp.x, wp.z, cx, cz, mapH)
      local color = paletteHexFor(wp.color)
      local fg, bg = color, "f"
      if isSelected("waypoint", wp.name) then fg, bg = "f", color end
      drawMarkerCell(col, row, WAYPOINT_MARKER[1], fg, bg, mapH)
      drawMarkerCell(col + 1, row, WAYPOINT_MARKER[2], fg, bg, mapH)
      table.insert(state.targetCells, {
        col1 = col, col2 = col + 1, row = row,
        kind = "waypoint", name = wp.name,
        x = wp.x, z = wp.z, color = color,
      })
    end
  end
end

local function overlayDotTrail(cx, cz, mapH)
  if not state.target then return end
  local tcol, trow = worldToCell(state.target.x, state.target.z, cx, cz, mapH)
  local centerCol = math.floor(width / 2 + 0.5)
  local centerRow = math.floor(mapH / 2 + 0.5)
  local dxC = tcol - centerCol
  local dyC = trow - centerRow
  local steps = math.max(math.abs(dxC), math.abs(dyC))
  if steps < 2 then return end
  for i = TRAIL_STEP, steps - 1, TRAIL_STEP do
    local t = i / steps
    local c = math.floor(centerCol + dxC * t + 0.5)
    local r = math.floor(centerRow + dyC * t + 0.5)
    if c >= 1 and c <= width and r >= 1 and r <= mapH then
      overlayCell(c, r, 0x0C, state.target.color, mapH, true)
    end
  end
end

-- Channels: "forward", "left", "right", "back". Side mapping comes from
-- minimap.cfg controlSides. If no relay is attached, we still record the
-- intended state for the auto bar to display.
local function setControl(name, on)
  on = on and true or false
  state.controls[name] = on
  local side = CONTROL_SIDES[name]
  if relay and side then pcall(relay.setOutput, side, on) end
end

local function autopilotTick()
  if not state.engaged or not state.target or not state.lastPos then
    setControl("forward", false); setControl("left", false); setControl("right", false)
    return
  end
  local dx = (state.target.x or 0) - state.lastPos.x
  local dz = (state.target.z or 0) - state.lastPos.z
  local range = math.sqrt(dx * dx + dz * dz)
  if range < ARRIVAL_RADIUS then
    setControl("forward", false); setControl("left", false); setControl("right", false)
    state.engaged = false
    state.autoStatus = "ARRIVED"
    return
  end
  local desired = math.deg(math.atan2(dx, -dz)) % 360
  local err = ((desired - (state.shipHeading or 0)) + 540) % 360 - 180
  if math.abs(err) > TURN_THRESHOLD then
    setControl("forward", false)
    setControl("left", err < 0); setControl("right", err > 0)
    state.autoStatus = (err < 0 and "TURN L" or "TURN R") .. string.format(" %dm", math.floor(range))
  elseif math.abs(err) > FINE_THRESHOLD then
    setControl("forward", true)
    setControl("left", err < 0); setControl("right", err > 0)
    state.autoStatus = string.format("FWD %s %dm", err < 0 and "L" or "R", math.floor(range))
  else
    setControl("forward", true); setControl("left", false); setControl("right", false)
    state.autoStatus = string.format("FWD %dm", math.floor(range))
  end
end

local function drawText(x, y, text, fg, bg)
  monitor.setCursorPos(x, y)
  monitor.setTextColor(fg or colors.white)
  monitor.setBackgroundColor(bg or colors.black)
  monitor.write(text)
end

local function drawButton(id, x, y, label)
  buttons[id] = { x1 = x, y1 = y, x2 = x + #label - 1, y2 = y }
  drawText(x, y, label, colors.black, colors.lightGray)
end

local function drawAutoBar()
  if state.lastError then return end
  if not state.target then return end
  monitor.setCursorPos(1, 1)
  monitor.setBackgroundColor(colors.black)
  monitor.clearLine()
  local label = state.engaged and " STOP " or " AUTO "
  drawButton("auto", 1, 1, label)
  drawButton("clear_target", 8, 1, " X ")
  local dx = (state.target.x or 0) - (state.lastPos and state.lastPos.x or 0)
  local dz = (state.target.z or 0) - (state.lastPos and state.lastPos.z or 0)
  local range = math.floor(math.sqrt(dx * dx + dz * dz))
  local txt = string.format("%s %dm %s", state.target.name or "?", range, state.autoStatus or "")
  if 12 < width then drawText(12, 1, txt:sub(1, width - 11), colors.white, colors.black) end
end

local function drawOsd(x, y, z)
  local osdY = height
  buttons = {}
  drawButton("zoom_in", 1, osdY, " + ")
  drawButton("zoom_out", 5, osdY, " - ")
  drawButton("lod", 9, osdY, "L" .. state.lod)
  local headingStr = nav and tostring(math.floor((state.shipHeading or 0) + 0.5)) or "--"
  local pCount = #(state.players or {})
  local pInfo = "P" .. pCount
  if state.lastFrame and state.lastPos and state.players[1] and state.players[1].position then
    local pp = state.players[1]
    local mapH = math.max(3, height - 1)
    local pcol, prow = worldToCell(pp.position.x, pp.position.z, state.lastPos.x, state.lastPos.z, mapH)
    pInfo = pInfo .. ":" .. pcol .. "," .. prow
  end
  local coord = string.format("X%d Z%d H%s B%s %s",
    x, z, headingStr, tostring(state.bpp), pInfo)
  local startCol = math.max(13, width - #coord + 1)
  drawText(startCol, osdY, coord:sub(1, width - startCol + 1), colors.white, colors.black)
  if state.lastError then
    monitor.setCursorPos(1, 1)
    monitor.setTextColor(colors.red)
    monitor.setBackgroundColor(colors.black)
    monitor.write(state.lastError:sub(1, width))
  end
end

local function drawError(message)
  monitor.setBackgroundColor(colors.black)
  monitor.setTextColor(colors.red)
  monitor.clear()
  drawText(1, 1, "BlueMap minimap error", colors.red, colors.black)
  drawText(1, 2, tostring(message):sub(1, width), colors.white, colors.black)
end

local function maybeFetchSidecar()
  if os.clock() < state.sidecarAt then return end
  state.sidecarAt = os.clock() + SIDECAR_INTERVAL
  local p = httpGetJson(SERVER .. "/players")
  if p and p.players then state.players = p.players end
  local w = httpGetJson(SERVER .. "/waypoints")
  if w then state.waypoints = w end
end

local function fullRedraw()
  if not state.lastFrame or not state.lastPos then return end
  if state.target and state.target.kind == "player" then
    for _, pp in ipairs(state.players or {}) do
      if pp.name == state.target.name and pp.position then
        state.target.x = pp.position.x
        state.target.z = pp.position.z
        break
      end
    end
  end
  local mapH = math.max(3, height - 1)
  state.targetCells = {}
  drawCachedMap(mapH)
  overlayDotTrail(state.lastPos.x, state.lastPos.z, mapH)
  overlayWaypoints(state.lastPos.x, state.lastPos.z, mapH)
  overlayOtherPlayers(state.lastPos.x, state.lastPos.z, mapH)
  overlaySelfTriangle(state.shipHeading, mapH)
  drawOsd(math.floor(state.lastPos.x), math.floor(state.lastPos.y), math.floor(state.lastPos.z))
  drawAutoBar()
end

local function mapTick()
  maybeFetchSidecar()
  local x, y, z = gps.locate(0.5)
  if x then
    local data, err = httpGetJson(buildUrl(x, z))
    if data and data.text then
      state.status = "ok"
      state.lastFrame = data
      state.lastPos = { x = x, y = y or 0, z = z }
      fullRedraw()
    elseif data and data.error then
      drawError(data.error)
    else
      drawError(err or "http.get failed")
    end
  else
    drawError("No GPS lock")
  end
end

local function mapLoop()
  while state.running do
    local ok, err = pcall(mapTick)
    if not ok then state.lastError = tostring(err) end
    sleep(FRAME_INTERVAL)
  end
end

local function fastTick()
  local h = readHeading()
  if h then state.shipHeading = h end
  autopilotTick()
  if state.lastFrame and state.lastPos then
    local mapH = math.max(3, height - 1)
    overlaySelfTriangle(state.shipHeading, mapH)
    drawOsd(math.floor(state.lastPos.x), math.floor(state.lastPos.y), math.floor(state.lastPos.z))
    drawAutoBar()
  end
end

local function fastLoop()
  while state.running do
    local ok, err = pcall(fastTick)
    if not ok then state.lastError = tostring(err) end
    sleep(NAV_INTERVAL)
  end
end

local function handleTouch(_, side, x, y)
  local hit = false
  for id, btn in pairs(buttons) do
    if x >= btn.x1 and x <= btn.x2 and y >= btn.y1 and y <= btn.y2 then
      hit = true
      if id == "zoom_in" then
        state.bpp = clamp(state.bpp / 2, 0.25, 128)
        state.lod = pickLod(state.bpp)
      elseif id == "zoom_out" then
        state.bpp = clamp(state.bpp * 2, 0.25, 128)
        state.lod = pickLod(state.bpp)
      elseif id == "lod" then
        state.lod = state.lod + 1
        if state.lod > 3 then state.lod = 1 end
      elseif id == "auto" then
        if state.target then state.engaged = not state.engaged end
      elseif id == "clear_target" then
        state.target = nil
        state.engaged = false
        state.autoStatus = ""
      end
    end
  end
  if hit then return end
  for _, t in ipairs(state.targetCells or {}) do
    if y == t.row and x >= t.col1 and x <= t.col2 then
      state.target = { kind = t.kind, name = t.name, x = t.x, z = t.z, color = t.color }
      state.engaged = false
      state.autoStatus = ""
      return
    end
  end
end

local function eventLoop()
  while state.running do
    local event = { os.pullEvent() }
    if event[1] == "monitor_touch" then
      handleTouch(unpackValues(event))
    elseif event[1] == "term_resize" then
      width, height = monitor.getSize()
    elseif event[1] == "key" and event[2] == keys.q then
      state.running = false
    end
  end
end

monitor.setBackgroundColor(colors.black)
monitor.clear()
parallel.waitForAny(mapLoop, fastLoop, eventLoop)
