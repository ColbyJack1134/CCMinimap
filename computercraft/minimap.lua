local SERVER = "http://your-host.example.com:5055"
local REFRESH_SECONDS = 1.0

local state = {
  bpp = 2,
  lod = 1,
  lastX = nil,
  lastZ = nil,
  heading = 0,
  status = "starting",
  running = true,
}

local buttons = {}

local function findMonitor()
  local m = peripheral.find("monitor")
  if m then return m end
  return term.current()
end

local monitor = findMonitor()
if monitor.setTextScale then
  monitor.setTextScale(0.5)
end
local width, height = monitor.getSize()
local unpackValues = table.unpack or unpack

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
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

local function applyPalette(palette)
  if not palette then return end
  for i = 1, math.min(#palette, 16) do
    local hex = palette[i]
    local n = tonumber(hex, 16)
    if n then
      monitor.setPaletteColor(2 ^ (i - 1), n)
    end
  end
end

local info = httpGetJson(SERVER .. "/info")
if info and info.palette then
  applyPalette(info.palette)
end

local function buildUrl(x, z)
  local mapHeight = math.max(3, height - 2)
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

local function updateHeading(x, z)
  if state.lastX and state.lastZ then
    local dx = x - state.lastX
    local dz = z - state.lastZ
    if math.abs(dx) + math.abs(dz) > 0.15 then
      state.heading = (math.deg(atan2(-dx, dz)) + 360) % 360
    end
  end
  state.lastX = x
  state.lastZ = z
end

-- Decode the wire text (bytes 0x40-0x5F) into actual teletext chars (0x80-0x9F).
local function decodeTextRow(packed)
  local out = {}
  for i = 1, #packed do
    out[i] = string.char(string.byte(packed, i) + 0x40)
  end
  return table.concat(out)
end

local function drawFrame(data)
  local mapHeight = math.min(#data.text, height - 2)
  for y = 1, mapHeight do
    local text = decodeTextRow(data.text[y])
    local fg = data.fg[y]
    local bg = data.bg[y]
    monitor.setCursorPos(1, y)
    monitor.blit(text, fg, bg)
  end
end

local function drawOsd(x, y, z)
  local controlsY = height - 1
  local footerY = height
  local coord = string.format("X:%d Y:%d Z:%d H:%03d", x, y or 0, z, state.heading)
  drawText(1, footerY, coord:sub(1, width), colors.white, colors.black)
  buttons = {}
  drawButton("zoom_in", 1, controlsY, " + ")
  drawButton("zoom_out", 5, controlsY, " - ")
  drawButton("lod", 9, controlsY, "L" .. state.lod)
  drawText(13, controlsY, (("bpp:%s %s"):format(state.bpp, state.status)):sub(1, math.max(1, width - 12)), colors.lightGray, colors.black)
end

local function drawError(message)
  monitor.setBackgroundColor(colors.black)
  monitor.setTextColor(colors.red)
  monitor.clear()
  drawText(1, 1, "BlueMap minimap error", colors.red, colors.black)
  drawText(1, 2, tostring(message):sub(1, width), colors.white, colors.black)
end

local function fetchFrame(x, y, z)
  local data, err = httpGetJson(buildUrl(x, z))
  if not data then
    state.status = "http failed"
    drawError(err or "http.get failed")
    return
  end
  if not data.text then
    state.status = "bad json"
    drawError(textutils.serialize(data):sub(1, width * 2))
    return
  end
  state.status = "ok"
  drawFrame(data)
  drawOsd(math.floor(x), math.floor(y or 0), math.floor(z))
end

local function mapLoop()
  while state.running do
    local x, y, z = gps.locate(2)
    if x then
      updateHeading(x, z)
      fetchFrame(x, y, z)
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
      elseif id == "zoom_out" then
        state.bpp = clamp(state.bpp * 2, 0.25, 128)
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
