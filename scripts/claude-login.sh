#!/usr/bin/env bash
# Interactive login helper:  docker compose exec -it claude-cron claude-login
set -euo pipefail

if [ ! -t 0 ]; then
  echo "claude-login needs a terminal. Run it with -it:" >&2
  echo "    docker compose exec -it claude-cron claude-login" >&2
  exit 1
fi

if [ "$(id -u)" -eq 0 ]; then
  # Credentials must land in the claude user's home, which is the persisted volume.
  exec runuser -u claude -- claude auth login "$@"
fi
exec claude auth login "$@"
