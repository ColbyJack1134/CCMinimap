from __future__ import annotations

import io
import json
import os
import time

from flask import Flask, jsonify, request, send_file
from PIL import Image
from requests import RequestException

from bluemap import BlueMapClient, BlueMapConfig, BlueMapError
from cc_palette import MAP_PALETTE
from render import encode_blit, parse_frame_request, quantize_to_palette, render_subpixel_image


def create_app() -> Flask:
    app = Flask(__name__)
    client = BlueMapClient(BlueMapConfig.from_env())

    @app.after_request
    def security_headers(response):
        response.headers["x-content-type-options"] = "nosniff"
        response.headers["cache-control"] = "no-store"
        return response

    @app.get("/health")
    def health():
        return jsonify({"ok": True})

    @app.get("/info")
    def info():
        settings = client.settings()
        lowres = client.lowres_settings()
        return jsonify({
            "map": client.config.map_id,
            "name": settings.get("name"),
            "lowres": {
                "tileSize": lowres.tile_size,
                "lodFactor": lowres.lod_factor,
                "lodCount": lowres.lod_count,
            },
            "subpixel": {"w": 2, "h": 3},
            "palette": [f"{c.rgb[0]:02X}{c.rgb[1]:02X}{c.rgb[2]:02X}" for c in MAP_PALETTE],
        })

    @app.get("/frame")
    def frame():
        try:
            req = parse_frame_request(request.args)
            image = render_subpixel_image(client, req)
            quant = quantize_to_palette(image)
            text, fg, bg = encode_blit(quant, req.width, req.height)
            return jsonify({
                "w": req.width,
                "h": req.height,
                "x": req.x,
                "z": req.z,
                "text": text,
                "fg": fg,
                "bg": bg,
            })
        except ValueError as error:
            return jsonify({"error": str(error)}), 400
        except BlueMapError as error:
            return jsonify({"error": str(error)}), 502
        except RequestException as error:
            return jsonify({"error": f"BlueMap request failed: {error}"}), 502

    @app.get("/debug.png")
    def debug_png():
        try:
            req = parse_frame_request(request.args)
            scale = max(1, min(8, int(request.args.get("scale", "4"))))
            image = render_subpixel_image(client, req)
            quant = quantize_to_palette(image)
            rgb = quant.convert("RGB")
            rgb = rgb.resize((rgb.width * scale, rgb.height * scale), Image.Resampling.NEAREST)
            buffer = io.BytesIO()
            rgb.save(buffer, format="PNG")
            buffer.seek(0)
            return send_file(buffer, mimetype="image/png")
        except ValueError as error:
            return jsonify({"error": str(error)}), 400
        except BlueMapError as error:
            return jsonify({"error": str(error)}), 502
        except RequestException as error:
            return jsonify({"error": f"BlueMap request failed: {error}"}), 502


    _players_cache = {"data": None, "ts": 0.0}
    _PLAYERS_TTL = 1.0

    @app.get("/players")
    def players():
        now = time.time()
        if now - _players_cache["ts"] > _PLAYERS_TTL:
            try:
                _players_cache["data"] = client.live_players()
                _players_cache["ts"] = now
            except (RequestException, BlueMapError) as error:
                return jsonify({"error": str(error)}), 502
        return jsonify(_players_cache["data"] or {"players": []})

    def _bm_marker_waypoints():
        try:
            sets = client.live_markers() or {}
        except (RequestException, BlueMapError):
            return []
        out = []
        for set_id, mset in sets.items():
            if not isinstance(mset, dict):
                continue
            for marker_id, marker in (mset.get("markers") or {}).items():
                pos = marker.get("position") or {}
                if "x" in pos and "z" in pos:
                    out.append({
                        "name": marker.get("label") or marker_id,
                        "x": pos["x"],
                        "z": pos["z"],
                        "color": marker.get("lineColor") or marker.get("fillColor") or "yellow",
                        "source": "bluemap",
                    })
        return out

    def _file_waypoints():
        path = os.environ.get("WAYPOINTS_FILE", "/app/waypoints.json")
        try:
            with open(path) as f:
                data = json.load(f)
            if isinstance(data, list):
                return [dict(w, source="file") for w in data if isinstance(w, dict)]
        except FileNotFoundError:
            pass
        except (json.JSONDecodeError, OSError):
            return []
        return []

    @app.get("/waypoints")
    def waypoints():
        return jsonify(_file_waypoints() + _bm_marker_waypoints())

    @app.get("/minimap.lua")
    def minimap_lua():
        return send_file("/app/computercraft/minimap.lua", mimetype="text/plain; charset=utf-8")

    return app


app = create_app()


if __name__ == "__main__":
    port = int(os.environ.get("PORT", "5055"))
    app.run(host="0.0.0.0", port=port)
