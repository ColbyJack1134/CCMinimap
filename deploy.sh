#!/usr/bin/env bash
# Pull latest and rebuild the server container.
#
# CLIENT_* are stripped from the environment first: docker compose lets shell
# env override the project .env, and Spruce's .env uses the same variable
# names -- a contaminated deploy shell (e.g. after `set -a; . .env` over in
# Spruce) once re-pointed every served client at the wrong server and froze
# their self-updates for weeks (2026-06-06).
set -euo pipefail
cd "$(dirname "$0")"
git pull --ff-only
exec env -u CLIENT_SERVER_URL -u CLIENT_PLAYER_NAME docker compose up -d --build
