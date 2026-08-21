#!/usr/bin/env bash
# Fire the scheduled job immediately:
#     docker compose exec -it claude-cron claude-run-now
set -euo pipefail

if [ "$(id -u)" -eq 0 ]; then
  exec runuser -u claude -- /usr/local/bin/run-job.sh "$@"
fi
exec /usr/local/bin/run-job.sh "$@"
