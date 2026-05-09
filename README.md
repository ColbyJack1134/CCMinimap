# BlueMap Minimap

Dockerized helper service and ComputerCraft client for rendering a BlueMap-backed minimap on an advanced monitor. The map is always north-up; OSD overlay is drawn client-side in CC.

## Service

The service only fetches from `BLUEMAP_BASE_URL` configured in the environment. Requests cannot supply arbitrary upstream URLs.

```sh
docker compose up -d --build
```

Endpoints:

- `GET /health`
- `GET /info` — configured map id, name, and lowres tile metadata
- `GET /frame?x=-127&z=-174&w=80&h=48&bpp=4&lod=1` — JSON `{w, h, x, z, rows}`. Each row is a string of CC palette codes (`0-f`), one per pixel, suitable for `monitor.blit` background.
- `GET /debug.png?x=-127&z=-174&w=80&h=48&bpp=4&lod=1&scale=4` — PNG render of the same view, optionally upscaled by `scale` (1-8) so it's visible in a browser.

Parameters:

- `x`, `z` — world center of the frame.
- `w`, `h` — output grid size in CC chars/pixels. Match your monitor.
- `bpp` (blocks per pixel) — **the zoom**. Higher = wider area shown. `bpp=4` at 80x48 covers a 320x192-block area; `bpp=16` covers 1280x768.
- `lod` (1-3) — which BlueMap pyramid level to source from. LOD 1 is finest, LOD 2 is 5x zoomed, LOD 3 is 25x. Pick one high enough to avoid pulling huge numbers of tiles for big `bpp`. Rule of thumb: bpp <= 5 -> lod 1, bpp <= 25 -> lod 2, otherwise lod 3.
- `scale` (debug.png only) — pixel multiplier for browser viewing. Does not change the area covered, only how big each CC pixel is in the PNG.

## ComputerCraft

`computercraft/minimap.lua` has `SERVER` preset to the docker host. Add it to your CC computer (e.g. `edit minimap.lua` and paste, or wget from a pastebin), make sure the host is in CC:T's HTTP whitelist, attach an advanced monitor, and run:

```lua
minimap
```

Touch controls:

- `+`: zoom in (decrease bpp)
- `-`: zoom out (increase bpp)
- `L1`/`L2`/`L3`: cycle BlueMap LOD source

Press `q` on the computer terminal to exit.

## Security Notes

- No request parameter is used as a URL or filesystem path.
- Map id is validated at startup.
- Request inputs are numeric, bounded, and finite.
- Container runs unprivileged with dropped capabilities, read-only root filesystem, and a 96M memory cap.
- The cache volume stores only BlueMap PNG tiles fetched from the configured BlueMap origin.
