# BlueMap Minimap

Minecraft minimap and autopilot for Create Aeronautics airships, using BlueMap
and CC:Tweaked.

## Screenshots

<!-- TODO -->

## Features

- Map view, north-up, ship-centered. Zoom and LOD buttons.
- OSD: position, heading, altitude, burner level, speed.
- Altitude tape with ground line and burner-level marker.
- Speedometer dial.
- Tappable waypoints from `waypoints.json` and BlueMap markers.
- Autopilot: climbs to a cruise AGL setpoint, PD-holds altitude, lands on arrival.
- ALT button for altitude-only hold at current altitude.
- Pocket remote mirrors ship state over rednet and forwards taps as commands.

## Controls

| Button | Action |
|---|---|
| `+` / `-` | Zoom in/out |
| `L1`/`L2`/`L3` | Cycle BlueMap LOD |
| `ALT` | Toggle altitude hold |
| `AUTO` | Engage autopilot (needs a target) |
| `X` | Clear target |

Tap a waypoint dot or another player to set them as the target.

## Dependencies

- [BlueMap](https://bluemap.bluecolored.de/)
- [Create Aeronautics](https://github.com/Sciecode/create-aeronautics)
- [CC:Tweaked](https://tweaked.cc/)
- Docker

## Server setup

1. Copy `.env.example` to `.env` and fill in the values.
2. `docker compose up -d --build`
3. `curl http://your-host:5055/health` returns `{"ok": true}`.

`waypoints.json` is volume-mounted into the container. Format in
`waypoints.example.json`. Restart the container after editing.

## Ship CC computer

Peripherals (any side, or via wired modems):

- Advanced monitor
- `altitude_sensor`, `velocity_sensor`, `navigation_table` with a compass
- Two `redstone_relay`s on a wired modem network:
  - Relay 0: forward/back/left/right WASD redstone links
  - Relay 1: `liftUp`, `liftDown`, and a `liftLevel` analog input for the burner
- A wireless or ender modem for the pocket remote

Install:

```
> wget http://your-host:5055/startup.lua startup.lua
> reboot
```

Tune via `minimap.cfg`:

- `channels` / `inputs`: relay and side mapping
- `hoverBurnerLevel`: burner level that holds altitude steady. Find by trial.
- `liftKp`, `liftKd`: altitude PD gains. Lower Kp and higher Kd if it oscillates.
- `cruiseAltitudeAboveGround`: target AGL when AUTO is engaged
- `airshipName`, `controlSecret`: pairing values (see below)

## Pocket

Slot an ender modem into the back of an advanced pocket computer.

```
> wget http://your-host:5055/startup-pocket.lua startup.lua
> reboot
```

## Pairing

Both `minimap.cfg` and `minimap-pocket.cfg` have `airshipName` and
`controlSecret`. The ship hosts on rednet as `airship-<airshipName>`; the
pocket looks that up and signs each command with `controlSecret`. The defaults
(`main` / `changeme`) are public, so change both on each device before flying.

## Multi-user

For multiple players on one BlueMap proxy:

- Blank `CLIENT_PLAYER_NAME` in `.env`
- Each CC sets its own `playerName` in `minimap.cfg`
- Each player picks their own `airshipName` and `controlSecret`
