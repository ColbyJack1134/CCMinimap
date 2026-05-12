-- startup-pocket.lua: pocket variant of startup.lua. Install by saving this as
-- "startup.lua" on the pocket. On every boot it self-updates from the server
-- (remote /startup-pocket.lua -> local startup.lua), then syncs minimap-pocket
-- and runs it. Network failures are non-fatal — whatever is on disk runs.
-- __SERVER_URL__ is substituted by the server (app.py) from CLIENT_SERVER_URL.
local SERVER = "__SERVER_URL__"
local CONFIG = "minimap-pocket.cfg"

local function readFile(p)
  if not fs.exists(p) then return nil end
  local f = fs.open(p, "r")
  local s = f.readAll()
  f.close()
  return s
end

local function writeFile(p, s)
  local f = fs.open(p, "w")
  f.write(s)
  f.close()
end

local function fetchText(url)
  local ok, r = pcall(http.get, url)
  if not ok or not r then return nil end
  local body = r.readAll()
  r.close()
  return body
end

local function fetchJson(url)
  local body = fetchText(url)
  if not body then return nil end
  local ok, parsed = pcall(textutils.unserialiseJSON, body)
  if ok then return parsed end
  return nil
end

local function syncFile(remoteName, localName)
  local remote = fetchText(SERVER .. "/" .. remoteName)
  if not remote then return false end
  if readFile(localName) == remote then return false end
  if fs.exists(localName) then fs.delete(localName) end
  writeFile(localName, remote)
  print("Updated " .. localName)
  return true
end

-- 1. Self-update. The pocket's local startup.lua mirrors remote /startup-pocket.lua.
if syncFile("startup-pocket.lua", "startup.lua") then
  print("startup.lua updated; rebooting...")
  sleep(0.5)
  os.reboot()
end

-- 2. Pull the pocket client (same minimap.lua content under a different name).
syncFile("minimap-pocket.lua", "minimap-pocket.lua")

-- 2a. CLI dispatcher + shims. Same set as on the ship -- ship.lua dispatches
-- via rednet from the pocket.
syncFile("ship.lua", "ship.lua")
local SHIM_NAMES = {"goto", "burner", "stop", "hold", "status", "wp"}
for _, name in ipairs(SHIM_NAMES) do
  local path = name .. ".lua"
  local body = string.format('shell.run("ship", %q, ...)\n', name)
  if readFile(path) ~= body then writeFile(path, body) end
end

-- 3. Merge any new default config keys into minimap-pocket.cfg without overwriting.
-- Only pocket-relevant keys; the ship owns controller/peripheral tunables.
local defaults = fetchJson(SERVER .. "/config.defaults.pocket")
if type(defaults) == "table" then
  local raw = readFile(CONFIG)
  local current = nil
  if raw then
    local ok, parsed = pcall(textutils.unserialiseJSON, raw)
    if ok and type(parsed) == "table" then current = parsed end
  end
  current = current or {}
  local added = {}
  for k, v in pairs(defaults) do
    if current[k] == nil then
      current[k] = v
      added[#added + 1] = k
    end
  end
  if #added > 0 then
    writeFile(CONFIG, textutils.serialiseJSON(current))
    print("Added config defaults: " .. table.concat(added, ", "))
  end
end

shell.run("bg", "minimap-pocket")
