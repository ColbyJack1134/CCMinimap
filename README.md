# BlueMap Minimap

A live in-game minimap, OSD, and waypoint-following autopilot for [Create
Aeronautics](https://github.com/Sciecode/create-aeronautics)-style airships,
rendered on an advanced monitor in
[CC:Tweaked](https://tweaked.cc/) and (optionally) mirrored to an
advanced pocket computer as a remote control.

Tiles come from a [BlueMap](https://bluemap.bluecolored.de/) server you
already run; this project's docker service proxies them, converts to
CC's 16-colour palette using a half-block sub-pixel scheme, and serves
the Lua client over HTTP.

<!-- Screenshots go here -->

## What it does

- **Map**: north-up, ship-centered, fetched from BlueMap with zoom &
  LOD controls.
- **OSD**: position, heading, altitude, burner level, ship-speed.
- **Altitude tape**: thermometer-style strip on the right edge showing
  ship altitude, BlueMap-sampled ground level, and a yellow burner-level
  marker at the ship's altitude row.
- **Speedometer dial** in the bottom-left (ship monitor only).
- **Waypoints**: tap to set, dot-trail to the target. Sourced from
  BlueMap's marker layer and/or a `waypoints.json` file the docker
  service reads.
- **Autopilot**: directional redstone outputs on a configurable relay
  drive your ship's WASD signals; on engage from low altitude it climbs
  to a cruise-AGL setpoint before moving, then PD-controls the burner
  level via pulsed +/- relay outputs while flying, ramps the burner
  down on arrival, and disengages on touchdown. ALT toggle for
  altitude-only hold (current altitude) independent of horizontal.
- **Pocket remote**: an advanced pocket with an ender modem mirrors the
  ship state over rednet and lets you tap waypoints / toggle AUTO /
  toggle ALT from anywhere on the server.

## Dependencies

- A Minecraft server with:
  - [BlueMap](https://bluemap.bluecolored.de/) installed and **live
    data + lowres tiles** enabled (default for recent versions).
  - [Create Aeronautics](https://github.com/Sciecode/create-aeronautics)
    (this project uses its `altitude_sensor`, `velocity_sensor`, and
    `navigation_table` peripherals).
  - [CC:Tweaked](https://tweaked.cc/) with `http.enabled=true` and the
    proxy's hostname in the `http.allowed_websites` whitelist.
- A host that can run docker (the proxy service has a ~96 MB memory
  cap and one CPU thread).

## Server setup

1. `cp .env.example .env` and fill in:
   - `BLUEMAP_BASE_URL` – the BlueMap http origin (e.g.
     `http://your-server:8100`).
   - `BLUEMAP_MAP_ID` – the map id BlueMap exposes (`world`,
     `overworld`, your dimension id, etc.).
   - `CLIENT_SERVER_URL` – the public URL the CC computers will use
     to reach this proxy. Must be reachable from inside Minecraft and
     present in CC:T's http whitelist.
   - `CLIENT_PLAYER_NAME` – your MC username, used to skip drawing
     your own player dot. Leave blank for multi-user installs (each
     CC can override per-device, see "Multi-user" below).
2. `docker compose up -d --build`.
3. Open `http://your-host:5055/health`; expect `{"ok": true}`.
4. Optionally edit `waypoints.json` (server-side; volume-mounted into
   the container). Format mirrors `waypoints.example.json`. Reload by
   restarting the container.

## In-game wiring

### Ship CC computer

Attach (any sides / via wired modems):

- An advanced **monitor** (the more cells the better).
- **altitude_sensor**, **velocity_sensor**, **navigation_table** with a
  compass inside (Create Aeronautics peripherals).
- A **wired modem network** with two `redstone_relay`s on it:
  - Relay 0 carries the four directional redstone-link channels for
    your ship's forward/back/left/right controls.
  - Relay 1 carries `liftUp` (burner +1), `liftDown` (burner -1), and
    a `liftLevel` analog input that reads the current burner level
    back to the computer.
- A **wireless or ender modem** (separate from the wired network) for
  pocket-remote support. Ender modem recommended (no range / dimension
  limits).

Install:

```
> wget http://your-host:5055/startup.lua startup.lua
> reboot
```

On first boot, `startup.lua` self-updates, pulls `minimap.lua`, writes
`minimap.cfg` from `/config.defaults`, and launches the client.

Tune in `minimap.cfg`:

- `channels` / `inputs` – physical relay+side mapping. Defaults assume
  relay 0 is mounted with the computer's "forward" facing the relay's
  front face.
- `hoverBurnerLevel` – burner level at which lift balances weight. Find
  by trial; the PD controller centers on this.
- `liftKp`, `liftKd` – position/velocity gains for the altitude
  controller. Lower Kp / higher Kd if it oscillates.
- `cruiseAltitudeAboveGround` – AGL setpoint when AUTO is engaged.
- `airshipName`, `controlSecret` – pairing values (see below).

### Pocket

Slot an **ender modem upgrade** into the back of an advanced pocket.
Then:

```
> wget http://your-host:5055/startup-pocket.lua startup.lua
> reboot
```

The pocket mirrors ship state at ~2 Hz over rednet and forwards taps
back as commands. It uses HTTP to pull its own `/frame` so map fetching
isn't on the rednet hot path.

### Pairing

Both the ship and pocket `.cfg`s have:

- `airshipName` (default `"main"`) – the rednet hostname the ship
  hosts on. Pockets look this up. Multiple players on the same MC
  server use different names so each pocket finds its own ship.
- `controlSecret` (default `"changeme"`) – a shared password. The
  pocket signs every command with it; the ship drops commands whose
  secret doesn't match.

Change both to matching values on both devices. The defaults are
public, so anyone could control a ship still on them.

### Multi-user

If two players share one BlueMap proxy:

- Set `CLIENT_PLAYER_NAME` blank in the server `.env`.
- Each CC sets its own `playerName` in `minimap.cfg`.
- Each player picks their own `airshipName` + `controlSecret`.
