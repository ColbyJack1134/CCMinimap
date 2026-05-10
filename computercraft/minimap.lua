local SERVER = "http://your-host.example.com:5055"
local PLAYER_NAME = "YourPlayerName"
local NAV_PERIPHERAL = nil  -- set to a peripheral name to override auto-detect
local NAV_METHOD = nil      -- set to a method name (e.g. "getYaw") to override
local REFRESH_SECONDS = 1.0
local SIDECAR_INTERVAL = 2.5

local SUB_W, SUB_H = 2, 3

local state = {
  bpp = 2,
  lod = 1,
  lastX = nil,
  lastZ = nil,
  movementHeading = 0,
  shipYaw = 0,
  status = "starting",
  running = true,
  players = {},
  waypoints = {},
  sidecarAt = 0,
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

local function atan2(y, x)
  if math.atan2 then return math.atan2(y, x) end
  return math.atan(y, x)
end

local function httpGetJson(url)
  local r, err = http.get(url, { ["accept"] = "application/json" })
  if not r then return nil, err end
  local body = r.readAll()
  r.close()
  return textutils.unserializeJSON(body), nil
end

-- Discover a nav peripheral that exposes the ship's yaw.
local function discoverNav()
  if NAV_PERIPHERAL then
    local p = peripheral.wrap(NAV_PERIPHERAL)
    if p then return p, NAV_METHOD or "getYaw" end
  end
  for _, name in ipairs(peripheral.getNames()) do
    local p = peripheral.wrap(name)
    if p then
      for _, method in ipairs({"getYaw", "getRotationYaw", "getRotation", "getDirection", "getOrientation"}) do
        if type(p[method]) == "function" then
          return p, method
        end
      end
    end
  end
  return nil, nil
end

local nav, navMethod = discoverNav()

local function readShipYaw()
  if not nav then return nil end
  local ok, result = pcall(nav[navMethod], nav)
  if not ok or result == nil then return nil end
  if type(result) == "number" then return result end
  if type(result) == "table" then
    return result.yaw or result.heading or result[1]
  end
  return nil
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
  local params = {
    "x=" .. urlencode(math.floor(x * 10) / 10),
    "z=" .. urlencode(math.floor(z * 10) / 10),
    "w=" .. urlencode(width),
    "h=" .. urlencode(mapHeight),
    "bpp=" .. urlencode(state.bpp),
    "lod=" .. urlencode(state.lod),
  }
  return SERVER .. "/frame?" .. table.concat(params, "&")
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

local function decodeTextRow(packed)
  local out = {}
  for i = 1, #packed do
    out[i] = string.char(string.byte(packed, i) + 0x40)
  end
  return table.concat(out)
end

local function drawFrame(data, mapH)
  local rows = math.min(#data.text, mapH)
  for y = 1, rows do
    monitor.setCursorPos(1, y)
    monitor.blit(decodeTextRow(data.text[y]), data.fg[y], data.bg[y])
  end
end

-- World (wx, wz) to monitor cell (col, row), centered on (cx, cz) at current zoom.
local function worldToCell(wx, wz, cx, cz, mapH)
  local blocksPerCellX = state.bpp * SUB_W
  local blocksPerCellY = state.bpp * SUB_H
  local col = math.floor((wx - cx) / blocksPerCellX + width / 2 + 0.5)
  local row = math.floor((wz - cz) / blocksPerCellY + mapH / 2 + 0.5)
  return col, row
end

-- 8-direction triangle: yaw 0 = south (MC convention).
local ARROWS = { "v", "/", "<", "\\", "^", "/", ">", "\\" }
local function arrowChar(yaw)
  local idx = math.floor((((yaw or 0) % 360) / 45) + 0.5) % 8
  return ARROWS[idx + 1]
end

-- Hash a player identifier to one of a few bright palette slots.
local MARKER_SLOTS = { 0, 1, 2, 3, 4, 13 }  -- snow, sand, lava, shoal, plains, leaf
local function colorForPlayer(key)
  local sum = 0
  for i = 1, #key do sum = sum + string.byte(key, i) end
  return 2 ^ MARKER_SLOTS[(sum % #MARKER_SLOTS) + 1]
end

local NAMED_COLORS = {
  white = colors.white, orange = colors.orange, magenta = colors.magenta,
  lightBlue = colors.lightBlue, yellow = colors.yellow, lime = colors.lime,
  pink = colors.pink, gray = colors.gray, cyan = colors.cyan, purple = colors.purple,
  blue = colors.blue, brown = colors.brown, green = colors.green, red = colors.red,
  black = colors.black, lightGray = colors.lightGray,
}
local function colorByName(name, fallback)
  return NAMED_COLORS[(name or ""):lower()] or fallback or colors.yellow
end

local function inBounds(col, row, mapH)
  return col >= 1 and col <= width and row >= 1 and row <= mapH
end

local function drawSelfTriangle(mapH)
  local col = math.floor(width / 2 + 0.5)
  local row = math.floor(mapH / 2 + 0.5)
  drawText(col, row, arrowChar(state.shipYaw), colors.white, colors.black)
end

local function drawOtherPlayers(cx, cz, mapH)
  for _, p in ipairs(state.players or {}) do
    if p.name ~= PLAYER_NAME and p.position then
      local col, row = worldToCell(p.position.x, p.position.z, cx, cz, mapH)
      if inBounds(col, row, mapH) then
        local color = colorForPlayer(p.uuid or p.name or "?")
        drawText(col, row, arrowChar(p.rotation and p.rotation.yaw), color, colors.black)
      end
    end
  end
end

local function drawWaypoints(cx, cz, mapH)
  for _, wp in ipairs(state.waypoints or {}) do
    if wp.x and wp.z then
      local col, row = worldToCell(wp.x, wp.z, cx, cz, mapH)
      if inBounds(col, row, mapH) then
        drawText(col, row, "*", colorByName(wp.color, colors.yellow), colors.black)
      end
    end
  end
end

local function drawOsd(x, y, z)
  local osdY = height
  buttons = {}
  drawButton("zoom_in", 1, osdY, " + ")
  drawButton("zoom_out", 5, osdY, " - ")
  drawButton("lod", 9, osdY, "L" .. state.lod)
  local coord = string.format("X%d Y%d Z%d H%03d B%s",
    x, y or 0, z, math.floor((state.shipYaw or 0) % 360 + 0.5), tostring(state.bpp))
  local startCol = math.max(13, width - #coord + 1)
  drawText(startCol, osdY, coord:sub(1, width - startCol + 1), colors.white, colors.black)
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

local function updateMovementHeading(x, z)
  if state.lastX and state.lastZ then
    local dx, dz = x - state.lastX, z - state.lastZ
    if math.abs(dx) + math.abs(dz) > 0.15 then
      state.movementHeading = (math.deg(atan2(-dx, dz)) + 360) % 360
    end
  end
  state.lastX, state.lastZ = x, z
end

local function fetchAndDraw(x, y, z)
  local mapH = math.max(3, height - 1)
  local data, err = httpGetJson(buildUrl(x, z))
  if not data then
    state.status = "http failed"
    drawError(err or "http.get failed")
    return
  end
  if not data.text then
    state.status = data.error or "bad json"
    drawError(data.error or textutils.serialize(data):sub(1, width * 2))
    return
  end
  state.status = "ok"
  drawFrame(data, mapH)
  drawWaypoints(x, z, mapH)
  drawOtherPlayers(x, z, mapH)
  drawSelfTriangle(mapH)
  drawOsd(math.floor(x), math.floor(y or 0), math.floor(z))
end

local function mapLoop()
  while state.running do
    maybeFetchSidecar()
    local x, y, z = gps.locate(2)
    if x then
      updateMovementHeading(x, z)
      state.shipYaw = readShipYaw() or state.movementHeading
      fetchAndDraw(x, y, z)
    else
      state.status = "no gps"
      drawError("No GPS lock")
    end
    sleep(REFRESH_SECONDS)
  end
end

local function handleTouch(_, side, x, y)
  for id, btn in pairs(buttons) do
    if x >= btn.x1 and x <= btn.x2 and y >= btn.y1 and y <= btn.y2 then
      if id == "zoom_in" then
        state.bpp = clamp(state.bpp / 2, 0.25, 128)
        state.lod = pickLod(state.bpp)
      elseif id == "zoom_out" then
        state.bpp = clamp(state.bpp * 2, 0.25, 128)
        state.lod = pickLod(state.bpp)
      elseif id == "lod" then
        state.lod = state.lod + 1
        if state.lod > 3 then state.lod = 1 end
      end
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
parallel.waitForAny(mapLoop, eventLoop)
