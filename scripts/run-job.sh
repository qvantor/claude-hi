#!/usr/bin/env bash
# The scheduled job. Runs as the `claude` user, either from cron or via
# `claude-run-now`. stdout is teed to the day's log file; under cron the
# crontab line appends it to the stream log, which the entrypoint mirrors
# into `docker compose logs`.
set -uo pipefail

ENV_FILE=/etc/claude-cron/job.env
LOG_DIR=/var/log/claude-cron
LOCK_FILE=/tmp/claude-cron.lock

if [ -r "${ENV_FILE}" ]; then
  set -a
  # shellcheck disable=SC1090
  . "${ENV_FILE}"
  set +a
fi

: "${CLAUDE_PROMPT:=hi claude, how are you}"
: "${CLAUDE_WORKDIR:=/workspace}"
: "${CLAUDE_ARGS:=--permission-mode bypassPermissions}"
: "${CLAUDE_MODEL:=}"
: "${JOB_TIMEOUT:=1800}"

mkdir -p "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/job-$(date +%F).log"
exec > >(tee -a "${LOG_FILE}") 2>&1

# Don't let a slow run overlap with the next tick.
exec 9>"${LOCK_FILE}"
if ! flock -n 9; then
  echo "[$(date '+%F %T %Z')] previous run still in progress -- skipping this tick"
  exit 0
fi

echo "=============================================================="
echo "[$(date '+%F %T %Z')] claude-cron START"
echo "  workdir : ${CLAUDE_WORKDIR}"
echo "  prompt  : ${CLAUDE_PROMPT}"
echo "--------------------------------------------------------------"

# Catches a session that expired since the container last started, and says so
# in plain language instead of letting the CLI fail cryptically at 05:00.
if [ -z "${ANTHROPIC_API_KEY:-}" ] && [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
  if ! claude auth status --json 2>/dev/null | jq -e '.loggedIn == true' >/dev/null 2>&1; then
    echo "ERROR: no valid Claude session (never logged in, or the login expired)."
    echo "       Fix it with:  docker compose exec -it claude-cron claude-login"
    echo "[$(date '+%F %T %Z')] claude-cron END exit=1"
    exit 1
  fi
fi

cd "${CLAUDE_WORKDIR}" || { echo "ERROR: cannot cd to ${CLAUDE_WORKDIR}"; exit 1; }

# CLAUDE_ARGS arrives from .env as one flag string. eval-ing it into an array
# does the quote removal a plain word-split cannot, so a value like
#   CLAUDE_ARGS=--tools ""
# reaches the CLI as a genuine empty argument rather than two quote characters.
declare -a CLAUDE_ARGV=()
if [ -n "${CLAUDE_ARGS}" ]; then
  if ! eval "CLAUDE_ARGV=(${CLAUDE_ARGS})" 2>/dev/null; then
    echo "ERROR: CLAUDE_ARGS is not parseable as shell words: ${CLAUDE_ARGS}"
    echo "[$(date '+%F %T %Z')] claude-cron END exit=1"
    exit 1
  fi
fi

declare -a MODEL_ARGV=()
[ -n "${CLAUDE_MODEL}" ] && MODEL_ARGV=(--model "${CLAUDE_MODEL}")

if [ "${JOB_TIMEOUT}" -gt 0 ] 2>/dev/null; then
  timeout --signal=TERM --kill-after=30s "${JOB_TIMEOUT}" \
    claude -p "${CLAUDE_PROMPT}" --output-format text \
      "${MODEL_ARGV[@]}" "${CLAUDE_ARGV[@]}"
else
  claude -p "${CLAUDE_PROMPT}" --output-format text \
    "${MODEL_ARGV[@]}" "${CLAUDE_ARGV[@]}"
fi
status=$?

echo ""
if [ "${status}" -eq 124 ]; then
  echo "TIMED OUT after ${JOB_TIMEOUT}s (raise JOB_TIMEOUT in .env, or 0 to disable)"
fi
echo "[$(date '+%F %T %Z')] claude-cron END exit=${status}"
echo "=============================================================="
exit "${status}"
