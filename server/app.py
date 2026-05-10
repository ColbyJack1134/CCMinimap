from __future__ import annotations

import io
import os

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

    @app.get("/minimap.lua")
    def minimap_lua():
        return send_file("/app/computercraft/minimap.lua", mimetype="text/plain; charset=utf-8")

    return app


app = create_app()


if __name__ == "__main__":
    port = int(os.environ.get("PORT", "5055"))
    app.run(host="0.0.0.0", port=port)
