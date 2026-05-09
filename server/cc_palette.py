from __future__ import annotations

from dataclasses import dataclass
from math import sqrt
from typing import Iterable


@dataclass(frozen=True)
class CCColor:
    name: str
    code: str
    rgb: tuple[int, int, int]


PALETTE: tuple[CCColor, ...] = (
    CCColor("white", "0", (240, 240, 240)),
    CCColor("orange", "1", (242, 178, 51)),
    CCColor("magenta", "2", (229, 127, 216)),
    CCColor("lightBlue", "3", (153, 178, 242)),
    CCColor("yellow", "4", (222, 222, 108)),
    CCColor("lime", "5", (127, 204, 25)),
    CCColor("pink", "6", (242, 178, 204)),
    CCColor("gray", "7", (76, 76, 76)),
    CCColor("lightGray", "8", (153, 153, 153)),
    CCColor("cyan", "9", (76, 153, 178)),
    CCColor("purple", "a", (178, 102, 229)),
    CCColor("blue", "b", (51, 102, 204)),
    CCColor("brown", "c", (127, 102, 76)),
    CCColor("green", "d", (87, 166, 78)),
    CCColor("red", "e", (204, 76, 76)),
    CCColor("black", "f", (17, 17, 17)),
)


def nearest_code(rgb: tuple[int, int, int], palette: Iterable[CCColor] = PALETTE) -> str:
    r, g, b = rgb
    best_code = "f"
    best_distance = float("inf")

    for color in palette:
        cr, cg, cb = color.rgb
        distance = sqrt((r - cr) ** 2 + (g - cg) ** 2 + (b - cb) ** 2)
        if distance < best_distance:
            best_distance = distance
            best_code = color.code

    return best_code
