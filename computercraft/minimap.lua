local SERVER = "http://your-host.example.com:5055"
local PLAYER_NAME = "YourPlayerName"
local NAV_PERIPHERAL = nil
local NAV_METHOD = nil
local FRAME_INTERVAL = 1.0
local NAV_INTERVAL = 0.1
local SIDECAR_INTERVAL = 2.5

local SUB_W, SUB_H = 2, 3

-- 3-wide x 2-tall cell stencils (laid out row-major: (0,0),(1,0),(2,0),(0,1),(1,1),(2,1))
-- Bit positions per cell: 0=TL 1=TR 2=ML 3=MR 4=BL 5=BR
local TRIANGLE_STENCILS = {
  { 0x00, 0x3F, 0x00, 0x0B, 0x3F, 0x07 }, -- 1 = S (yaw ~0)
  { 0x3E, 0x34, 0x30, 0x2F, 0x07, 0x03 }, -- 2 = W (yaw ~90)
  { 0x38, 0x3F, 0x34, 0x00, 0x3F, 0x00 }, -- 3 = N (yaw ~180)
  { 0x30, 0x38, 0x3D, 0x03, 0x0B, 0x1F }, -- 4 = E (yaw ~270)
}

local SINGLE_CELL_TRIANGLES = {
  [1] = 0x1C, -- S: ML+MR+BL
  [2] = 0x2E, -- W: TR+ML+MR+BR (bit5 inversion)
  [3] = 0x0E, -- N: TR+ML+MR
  [4] = 0x1D, -- E: TL+ML+MR+BL
}

local WAYPOINT_BITS = 0x0C -- ML+MR middle dash

local state = {
  bpp = 2,
  lod = 1,
  lastX = nil, lastZ = nil,
  movementHeading = 0,
  shipYaw = 0,
  status = "starting",
  running = true,
  players = {},
  waypoints = {},
  sidecarAt = 0,
  lastFrame = nil,
  lastPos = nil,
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

local function discoverNav()
  if NAV_PERIPHERAL then
    local p = peripheral.wrap(NAV_PERIPHERAL)
    if p then return p, NAV_METHOD or "getYaw" end
  end
  for _, name in ipairs(peripheral.getNames()) do
    local p = peripheral.wrap(name)
    if p then
      for _, method in ipairs({"getYaw", "getRotationYaw", "getRotation", "getDirection", "getOrientation"}) do
        if type(p[method]) == "function" then return p, method end
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
  if type(result) == "table" then return result.yaw or result.heading or result[1] end
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

local function directionForYaw(yaw)
  return math.floor((((yaw or 0) % 360) / 90) + 0.5) % 4 + 1
end

-- OR a stencil into a single cell from the cached map and blit the result.
-- color is a CC palette hex char ('0'-'f') used for stencil-lit sub-pixels.
local function overlayCell(col, row, stenBits, color, mapH)
  if col < 1 or col > width or row < 1 or row > mapH then return end
  if not state.lastFrame or not state.lastFrame.text or not state.lastFrame.text[row] then return end
  local packed = state.lastFrame.text[row]
  if col > #packed then return end
  local cell_pattern = string.byte(packed, col) - 0x40
  local cell_fg = state.lastFrame.fg[row]:sub(col, col)
  local cell_bg = state.lastFrame.bg[row]:sub(col, col)
  local new_pattern = bit32.bor(cell_pattern, stenBits)
  local new_fg, new_bg
  if stenBits == 0 then
    new_fg, new_bg = cell_fg, cell_bg
  else
    new_fg, new_bg = color, cell_bg
  end
  if bit32.band(new_pattern, 0x20) ~= 0 then
    new_pattern = bit32.bxor(new_pattern, 0x3F)
    new_fg, new_bg = new_bg, new_fg
  end
  monitor.setCursorPos(col, row)
  monitor.blit(string.char(new_pattern + 0x80), new_fg, new_bg)
end

local function overlaySelfTriangle(yaw, mapH)
  local stencil = TRIANGLE_STENCILS[directionForYaw(yaw)]
  if not stencil then return end
  local centerCol = math.floor(width / 2 + 0.5)
  local centerRow = math.floor(mapH / 2 + 0.5)
  local startCol = centerCol - 1
  local startRow = centerRow - 1
  for sr = 0, 1 do
    for sc = 0, 2 do
      overlayCell(startCol + sc, startRow + sr, stencil[sr * 3 + sc + 1], "0", mapH)
    end
  end
end

local PLAYER_HEX_SLOTS = { "0", "1", "2", "3", "4", "d" }
local function colorForPlayer(key)
  local sum = 0
  for i = 1, #key do sum = sum + string.byte(key, i) end
  return PLAYER_HEX_SLOTS[(sum % #PLAYER_HEX_SLOTS) + 1]
end

local function overlayOtherPlayers(cx, cz, mapH)
  for _, p in ipairs(state.players or {}) do
    if p.name ~= PLAYER_NAME and p.position then
      local col, row = worldToCell(p.position.x, p.position.z, cx, cz, mapH)
      local stenBits = SINGLE_CELL_TRIANGLES[directionForYaw(p.rotation and p.rotation.yaw)]
      if stenBits then
        overlayCell(col, row, stenBits, colorForPlayer(p.uuid or p.name or "?"), mapH)
      end
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
      overlayCell(col, row, WAYPOINT_BITS, paletteHexFor(wp.color), mapH)
    end
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

local function fullRedraw()
  if not state.lastFrame or not state.lastPos then return end
  local mapH = math.max(3, height - 1)
  drawCachedMap(mapH)
  overlayWaypoints(state.lastPos.x, state.lastPos.z, mapH)
  overlayOtherPlayers(state.lastPos.x, state.lastPos.z, mapH)
  overlaySelfTriangle(state.shipYaw, mapH)
  drawOsd(math.floor(state.lastPos.x), math.floor(state.lastPos.y), math.floor(state.lastPos.z))
end

local function mapLoop()
  while state.running do
    maybeFetchSidecar()
    local x, y, z = gps.locate(0.5)
    if x then
      updateMovementHeading(x, z)
      local data, err = httpGetJson(buildUrl(x, z))
      if data and data.text then
        state.status = "ok"
        state.lastFrame = data
        state.lastPos = { x = x, y = y or 0, z = z }
        fullRedraw()
      elseif data and data.error then
        state.status = data.error
        drawError(data.error)
      else
        state.status = "http failed"
        drawError(err or "http.get failed")
      end
    else
      state.status = "no gps"
      drawError("No GPS lock")
    end
    sleep(FRAME_INTERVAL)
  end
end

local function fastLoop()
  while state.running do
    state.shipYaw = readShipYaw() or state.movementHeading
    if state.lastFrame and state.lastPos then
      local mapH = math.max(3, height - 1)
      overlaySelfTriangle(state.shipYaw, mapH)
      drawOsd(math.floor(state.lastPos.x), math.floor(state.lastPos.y), math.floor(state.lastPos.z))
    end
    sleep(NAV_INTERVAL)
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
parallel.waitForAny(mapLoop, fastLoop, eventLoop)
