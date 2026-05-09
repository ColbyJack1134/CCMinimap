from __future__ import annotations

import io
import os

from flask import Flask, jsonify, request, send_file
from requests import RequestException

from bluemap import BlueMapClient, BlueMapConfig, BlueMapError
from render import image_to_cc_rows, parse_frame_request, render_map_image


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
        return jsonify(
            {
                "map": client.config.map_id,
                "name": settings.get("name"),
                "lowres": {
                    "tileSize": lowres.tile_size,
                    "lodFactor": lowres.lod_factor,
                    "lodCount": lowres.lod_count,
                },
            }
        )

    @app.get("/frame")
    def frame():
        try:
            frame_request = parse_frame_request(request.args)
            image = render_map_image(client, frame_request)
            rows = image_to_cc_rows(image)
            return jsonify(
                {
                    "w": image.width,
                    "h": image.height,
                    "x": frame_request.x,
                    "z": frame_request.z,
                    "rows": rows,
                }
            )
        except ValueError as error:
            return jsonify({"error": str(error)}), 400
        except BlueMapError as error:
            return jsonify({"error": str(error)}), 502
        except RequestException as error:
            return jsonify({"error": f"BlueMap request failed: {error}"}), 502

    @app.get("/debug.png")
    def debug_png():
        try:
            frame_request = parse_frame_request(request.args)
            scale = max(1, min(8, int(request.args.get("scale", "4"))))
            image = render_map_image(client, frame_request, scale=scale)
            buffer = io.BytesIO()
            image.save(buffer, format="PNG")
            buffer.seek(0)
            return send_file(buffer, mimetype="image/png")
        except ValueError as error:
            return jsonify({"error": str(error)}), 400
        except BlueMapError as error:
            return jsonify({"error": str(error)}), 502
        except RequestException as error:
            return jsonify({"error": f"BlueMap request failed: {error}"}), 502

    return app


app = create_app()


if __name__ == "__main__":
    port = int(os.environ.get("PORT", "5055"))
    app.run(host="0.0.0.0", port=port)
