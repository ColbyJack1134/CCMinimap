from __future__ import annotations

import math
from dataclasses import dataclass

from PIL import Image

from bluemap import BlueMapClient
from cc_palette import nearest_code


@dataclass(frozen=True)
class FrameRequest:
    x: float
    z: float
    width: int = 80
    height: int = 48
    lod: int = 1
    blocks_per_pixel: float = 4.0


def parse_frame_request(args) -> FrameRequest:
    def number(name, default, minimum, maximum):
        raw = args.get(name, default)
        try:
            parsed = float(raw)
        except (TypeError, ValueError):
            raise ValueError(f"{name} must be numeric")
        if not math.isfinite(parsed) or parsed < minimum or parsed > maximum:
            raise ValueError(f"{name} must be between {minimum} and {maximum}")
        return parsed

    def integer(name, default, minimum, maximum):
        return int(number(name, default, minimum, maximum))

    return FrameRequest(
        x=number("x", 0.0, -30_000_000, 30_000_000),
        z=number("z", 0.0, -30_000_000, 30_000_000),
        width=integer("w", 80, 8, 240),
        height=integer("h", 48, 8, 160),
        lod=integer("lod", 1, 1, 3),
        blocks_per_pixel=number("bpp", 4.0, 0.5, 128.0),
    )


def _paste_tile(client, canvas, lod, tile_x, tile_z, origin_x, origin_z):
    lowres = client.lowres_settings()
    _, _, _, _, lod_scale = client.world_to_lowres_tile(0, 0, lod)
    tile_world = lowres.tile_size * lod_scale
    tile = client.fetch_lowres_tile(lod, tile_x, tile_z)
    if tile is None:
        return
    color_half = tile.crop((0, 0, lowres.tile_size + 1, lowres.tile_size + 1))
    px = round((tile_x * tile_world - origin_x) / lod_scale)
    py = round((tile_z * tile_world - origin_z) / lod_scale)
    canvas.alpha_composite(color_half, (px, py))


def render_map_image(client: BlueMapClient, req: FrameRequest, scale: int = 1) -> Image.Image:
    lowres = client.lowres_settings()
    lod_scale = float(lowres.lod_factor ** (req.lod - 1))
    out_w = req.width * scale
    out_h = req.height * scale

    crop_world_w = req.width * req.blocks_per_pixel
    crop_world_h = req.height * req.blocks_per_pixel
    source_px_w = max(1, math.ceil(crop_world_w / lod_scale))
    source_px_h = max(1, math.ceil(crop_world_h / lod_scale))
    origin_x = req.x - crop_world_w / 2
    origin_z = req.z - crop_world_h / 2

    canvas = Image.new("RGBA", (source_px_w + 4, source_px_h + 4), (0, 0, 0, 255))
    tile_world = lowres.tile_size * lod_scale
    min_tile_x = math.floor(origin_x / tile_world)
    max_tile_x = math.floor((origin_x + crop_world_w) / tile_world)
    min_tile_z = math.floor(origin_z / tile_world)
    max_tile_z = math.floor((origin_z + crop_world_h) / tile_world)

    for tile_z in range(min_tile_z, max_tile_z + 1):
        for tile_x in range(min_tile_x, max_tile_x + 1):
            _paste_tile(client, canvas, req.lod, tile_x, tile_z, origin_x, origin_z)

    image = canvas.crop((0, 0, source_px_w, source_px_h)).convert("RGB")
    image = image.resize((out_w, out_h), Image.Resampling.BILINEAR)
    return image


def image_to_cc_rows(image: Image.Image) -> list[str]:
    rgb = image.convert("RGB")
    pixels = rgb.load()
    rows = []
    for y in range(rgb.height):
        row = []
        for x in range(rgb.width):
            row.append(nearest_code(pixels[x, y]))
        rows.append("".join(row))
    return rows
