# BlueMap Minimap

Dockerized helper service and ComputerCraft client for rendering a BlueMap-backed minimap on an advanced monitor.

## Service

The service only fetches from `BLUEMAP_BASE_URL` configured in the environment. Requests cannot supply arbitrary upstream URLs.

```sh
docker compose up -d --build
```

Endpoints:

- `GET /health`
- `GET /info`
- `GET /frame?x=-127&z=-174&w=80&h=48&bpp=4&lod=1&heading=0&rotate=0`
- `GET /debug.png?x=-127&z=-174&w=80&h=48&bpp=4&lod=1&scale=4`

`/frame` returns ComputerCraft `monitor.blit` background rows using the 16-color palette.

## ComputerCraft

Copy `computercraft/minimap.lua` to the advanced computer. Edit the `SERVER` value at the top so it points to the Docker host as seen from Minecraft/ComputerCraft, for example:

```lua
local SERVER = "http://192.168.1.50:5055"
```

Attach an advanced monitor, make sure HTTP is enabled in the mod config, and run:

```lua
minimap
```

Touch controls:

- `+`: zoom in
- `-`: zoom out
- `ROT`/`NUP`: rotated or north-up view
- `L1`/`L2`/`L3`: BlueMap low-res LOD

Press `q` on the computer terminal to exit.

## Security Notes

- No request parameter is used as a URL or filesystem path.
- Map id is validated at startup.
- Request inputs are numeric, bounded, and finite.
- Container runs as an unprivileged user with dropped capabilities and read-only root filesystem.
- The cache volume stores only BlueMap PNG tiles fetched from the configured BlueMap origin.
