-- Self-updating boot: pulls latest startup.lua and minimap.lua from the server,
-- merges any new default config keys without overwriting existing ones, then
-- launches minimap. Network failures are non-fatal -- whatever is on disk runs.
-- __SERVER_URL__ is substituted by the server (app.py) from CLIENT_SERVER_URL.
local SERVER = "__SERVER_URL__"
local CONFIG = "minimap.cfg"

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

local function syncFile(name)
  local remote = fetchText(SERVER .. "/" .. name)
  if not remote then return false end
  if readFile(name) == remote then return false end
  if fs.exists(name) then fs.delete(name) end
  writeFile(name, remote)
  print("Updated " .. name)
  return true
end

-- 1. Self-update. If startup.lua itself changed, reboot so the new code runs.
if syncFile("startup.lua") then
  print("startup.lua updated; rebooting...")
  sleep(0.5)
  os.reboot()
end

-- 2. Update minimap.lua in place (not yet loaded, so no reboot needed).
syncFile("minimap.lua")

-- 2a. CLI dispatcher. Invoke commands as `minimap <cmd>`; minimap.lua
-- forwards to ship.lua when called with args.
syncFile("ship.lua")

-- 3. Merge new default config keys without overwriting existing ones.
local defaults = fetchJson(SERVER .. "/config.defaults")
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

shell.run("bg", "minimap")
