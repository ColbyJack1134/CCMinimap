from __future__ import annotations

import math
from dataclasses import dataclass

from PIL import Image, ImageDraw

from bluemap import BlueMapClient
from cc_palette import nearest_code


@dataclass(frozen=True)
class FrameRequest:
    x: float
    z: float
    heading: float = 0.0
    width: int = 80
    height: int = 48
    lod: int = 1
    blocks_per_pixel: float = 4.0
    rotate: bool = False
    marker: bool = True


def clamp_int(value: int, minimum: int, maximum: int) -> int:
    return max(minimum, min(maximum, value))


def parse_bool(value: str | None, default: bool = False) -> bool:
    if value is None:
        return default
    return value.lower() in {"1", "true", "yes", "on"}


def parse_frame_request(args) -> FrameRequest:
    def number(name: str, default: float, minimum: float, maximum: float) -> float:
        raw = args.get(name, default)
        try:
            parsed = float(raw)
        except (TypeError, ValueError):
            raise ValueError(f"{name} must be numeric")
        if not math.isfinite(parsed) or parsed < minimum or parsed > maximum:
            raise ValueError(f"{name} must be between {minimum} and {maximum}")
        return parsed

    def integer(name: str, default: int, minimum: int, maximum: int) -> int:
        return int(number(name, default, minimum, maximum))

    return FrameRequest(
        x=number("x", 0.0, -30_000_000, 30_000_000),
        z=number("z", 0.0, -30_000_000, 30_000_000),
        heading=number("heading", 0.0, -3600.0, 3600.0) % 360.0,
        width=integer("w", 80, 8, 240),
        height=integer("h", 48, 8, 160),
        lod=integer("lod", 1, 1, 3),
        blocks_per_pixel=number("bpp", 4.0, 0.5, 128.0),
        rotate=parse_bool(args.get("rotate"), False),
        marker=parse_bool(args.get("marker"), True),
    )


def _paste_tile(client: BlueMapClient, canvas: Image.Image, lod: int, tile_x: int, tile_z: int, origin_x: float, origin_z: float) -> None:
    lowres = client.lowres_settings()
    _, _, _, _, lod_scale = client.world_to_lowres_tile(0, 0, lod)
    tile_world = lowres.tile_size * lod_scale
    tile = client.fetch_lowres_tile(lod, tile_x, tile_z)
    if tile is None:
        return

    # BlueMap lowres PNGs store color in the top half and metadata in the bottom half.
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
    if req.rotate:
        diagonal = math.hypot(crop_world_w, crop_world_h)
        source_world_w = source_world_h = diagonal
    else:
        source_world_w = crop_world_w
        source_world_h = crop_world_h

    source_px_w = max(1, math.ceil(source_world_w / lod_scale))
    source_px_h = max(1, math.ceil(source_world_h / lod_scale))
    origin_x = req.x - source_world_w / 2
    origin_z = req.z - source_world_h / 2

    canvas = Image.new("RGBA", (source_px_w + 4, source_px_h + 4), (0, 0, 0, 255))
    tile_world = lowres.tile_size * lod_scale
    min_tile_x = math.floor(origin_x / tile_world)
    max_tile_x = math.floor((origin_x + source_world_w) / tile_world)
    min_tile_z = math.floor(origin_z / tile_world)
    max_tile_z = math.floor((origin_z + source_world_h) / tile_world)

    for tile_z in range(min_tile_z, max_tile_z + 1):
        for tile_x in range(min_tile_x, max_tile_x + 1):
            _paste_tile(client, canvas, req.lod, tile_x, tile_z, origin_x, origin_z)

    image = canvas.crop((0, 0, source_px_w, source_px_h)).convert("RGB")
    if req.rotate:
        image = image.rotate(req.heading, resample=Image.Resampling.BILINEAR, expand=False)
        left = (image.width - math.ceil(crop_world_w / lod_scale)) // 2
        top = (image.height - math.ceil(crop_world_h / lod_scale)) // 2
        image = image.crop((left, top, left + math.ceil(crop_world_w / lod_scale), top + math.ceil(crop_world_h / lod_scale)))

    image = image.resize((out_w, out_h), Image.Resampling.BILINEAR)

    if req.marker:
        draw = ImageDraw.Draw(image)
        cx = out_w // 2
        cy = out_h // 2
        draw.line((cx - 3 * scale, cy, cx + 3 * scale, cy), fill=(255, 255, 255), width=max(1, scale))
        draw.line((cx, cy - 3 * scale, cx, cy + 3 * scale), fill=(255, 255, 255), width=max(1, scale))

    return image


def image_to_cc_rows(image: Image.Image) -> list[str]:
    rgb = image.convert("RGB")
    pixels = rgb.load()
    rows: list[str] = []
    for y in range(rgb.height):
        row = []
        for x in range(rgb.width):
            row.append(nearest_code(pixels[x, y]))
        rows.append("".join(row))
    return rows
