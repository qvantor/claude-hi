#!/usr/bin/env bash
# Runs as root. Prepares timezone, crontab and credentials, then hands off to cron.
set -euo pipefail

LOG_DIR=/var/log/claude-cron
STREAM_LOG="${LOG_DIR}/claude-cron.log"
ENV_FILE=/etc/claude-cron/job.env
CRON_FILE=/etc/cron.d/claude-cron

log()  { printf '[claude-cron] %s\n' "$*"; }
rule() { printf '[claude-cron] %s\n' '--------------------------------------------------------------'; }

# ---------------------------------------------------------------- defaults ---
TZ="${TZ:-UTC}"
CRON_SCHEDULE="${CRON_SCHEDULE:-0 5 * * *}"
CLAUDE_PROMPT="${CLAUDE_PROMPT:-hi claude, how are you}"
CLAUDE_WORKDIR="${CLAUDE_WORKDIR:-/workspace}"
CLAUDE_ARGS="${CLAUDE_ARGS:---permission-mode bypassPermissions}"
CLAUDE_MODEL="${CLAUDE_MODEL:-}"
RUN_ON_START="${RUN_ON_START:-false}"
JOB_TIMEOUT="${JOB_TIMEOUT:-1800}"
HOME=/home/claude

# -------------------------------------------------------------- timezone -----
# Symlink /etc/localtime rather than relying on CRON_TZ: this way `0 5 * * *`
# means 05:00 in TZ for cron, for `date`, and for the log timestamps alike.
if [ -f "/usr/share/zoneinfo/${TZ}" ]; then
  ln -snf "/usr/share/zoneinfo/${TZ}" /etc/localtime
  printf '%s\n' "${TZ}" > /etc/timezone
else
  log "WARNING: unknown TZ '${TZ}' -- falling back to UTC"
  TZ=UTC
  ln -snf /usr/share/zoneinfo/UTC /etc/localtime
  printf 'UTC\n' > /etc/timezone
fi
export TZ

# ------------------------------------------------------- validate schedule ---
read -r -a _cron_fields <<< "${CRON_SCHEDULE}"
case "${CRON_SCHEDULE}" in
  @*) [ "${#_cron_fields[@]}" -eq 1 ] || { log "ERROR: bad CRON_SCHEDULE '${CRON_SCHEDULE}'"; exit 1; } ;;
  *)  [ "${#_cron_fields[@]}" -eq 5 ] || {
        log "ERROR: CRON_SCHEDULE must have 5 fields (min hour dom mon dow), got ${#_cron_fields[@]}: '${CRON_SCHEDULE}'"
        log "       Write it unquoted in .env, e.g.  CRON_SCHEDULE=0 5 * * *"
        exit 1
      } ;;
esac

# ------------------------------------------------------------- filesystem ----
# A freshly created named volume is root-owned; the login below has to be able
# to write credentials into it as the `claude` user.
mkdir -p "${LOG_DIR}" /etc/claude-cron "${CLAUDE_WORKDIR}" /home/claude/.claude
chown -R claude:claude /home/claude "${LOG_DIR}" 2>/dev/null || true
chown claude:claude "${CLAUDE_WORKDIR}" 2>/dev/null || true
touch "${STREAM_LOG}" && chown claude:claude "${STREAM_LOG}"

# Anything other than cron -- `docker compose run --rm claude-cron claude-login`,
# a debug shell -- just needs the filesystem prepared, not a crontab.
case "${1:-}" in
  cron) ;;
  *) exec "$@" ;;
esac

# ---------------------------------------------------------------- job env ----
# cron wipes the environment, so snapshot what the job needs into a file it can
# source. %q keeps prompts with spaces, quotes or newlines intact.
{
  for _name in $(compgen -v); do
    case "${_name}" in
      ANTHROPIC_*|CLAUDE_*|TZ|HOME|JOB_TIMEOUT|\
      HTTP_PROXY|HTTPS_PROXY|NO_PROXY|http_proxy|https_proxy|no_proxy)
        [ -n "${!_name:-}" ] && printf '%s=%q\n' "${_name}" "${!_name}" ;;
    esac
  done
} > "${ENV_FILE}"
chown root:claude "${ENV_FILE}"
chmod 0640 "${ENV_FILE}"

# ---------------------------------------------------------------- crontab ----
# Field 6 is the user the job runs as. Output goes to the stream log, which the
# tail below mirrors into `docker compose logs`.
{
  echo "SHELL=/bin/bash"
  echo "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  echo ""
  echo "${CRON_SCHEDULE} claude /usr/local/bin/run-job.sh >> ${STREAM_LOG} 2>&1"
} > "${CRON_FILE}"
chown root:root "${CRON_FILE}"
chmod 0644 "${CRON_FILE}"

# ------------------------------------------------------------------- auth ----
auth_status_json() { runuser -u claude -- claude auth status --json 2>/dev/null || true; }
auth_ok() { auth_status_json | jq -e '.loggedIn == true' >/dev/null 2>&1; }

login_hint() {
  rule
  log "NOT AUTHENTICATED -- the scheduled run will fail until you log in."
  log ""
  log "  Run this now, in any terminal:"
  log ""
  log "      docker compose exec -it claude-cron claude-login"
  log ""
  log "  It prints a URL; open it, approve, paste the code back. Credentials are"
  log "  saved to the claude-home volume, so this is a one-time step."
  rule
}

if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  log "auth: using ANTHROPIC_API_KEY from the environment"
elif [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
  log "auth: using CLAUDE_CODE_OAUTH_TOKEN from the environment"
elif auth_ok; then
  _info="$(auth_status_json)"
  log "auth: logged in as $(jq -r '.email // "unknown"' <<< "${_info}") ($(jq -r '.subscriptionType // .authMethod // "?"' <<< "${_info}"))"
else
  # Covers both "never logged in" and "refresh token no longer valid".
  # Deliberately does NOT start the login here. `docker compose up` attaches the
  # container's output to your terminal but not your keyboard to its stdin, so a
  # login prompt raised from the entrypoint can never be answered -- it just looks
  # frozen and cron never starts. Login belongs in `exec -it`, which does attach
  # stdin. Covers both "never logged in" and "refresh token no longer valid".
  login_hint
fi

# ---------------------------------------------------------------- summary ----
rule
log "timezone : ${TZ}  (now: $(date '+%Y-%m-%d %H:%M:%S %Z'))"
log "schedule : ${CRON_SCHEDULE}"
log "prompt   : ${CLAUDE_PROMPT}"
log "workdir  : ${CLAUDE_WORKDIR}"
log "model    : ${CLAUDE_MODEL:-<default>}"
log "args     : ${CLAUDE_ARGS}"
log "logs     : ${LOG_DIR}/job-YYYY-MM-DD.log  (also streamed to docker logs)"
log "run now  : docker compose exec -it claude-cron claude-run-now"
rule

# Mirror job output into the container's stdout. Cron jobs run as `claude` and
# cannot write to /proc/1/fd/1 (root-owned), so root tails the stream log here.
tail -n 0 -F "${STREAM_LOG}" &

if [ "${RUN_ON_START,,}" = "true" ]; then
  log "RUN_ON_START=true -- firing the job once now"
  ( runuser -u claude -- /usr/local/bin/run-job.sh >> "${STREAM_LOG}" 2>&1 || true ) &
fi

exec "$@"
