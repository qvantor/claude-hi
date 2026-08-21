# claude-cron

Claude Code running on a schedule inside Docker. You log in once; a cron job
inside the container then sends your prompt to Claude at the time you configure.

* Schedule and prompt are set in `.env` — no code changes.
* Login is interactive on first start and **persists in a Docker volume**, so
  restarts and image rebuilds stay authenticated. If the session ever expires,
  the container says so loudly and tells you the one command to fix it.
* The scheduled run has full tool access inside `./workspace`, so it can do real
  work, not just chat.

## Quick start

```bash
cp .env.example .env
$EDITOR .env                 # set TZ, CRON_SCHEDULE, CLAUDE_PROMPT

docker compose up -d                                # start it
docker compose exec -it claude-cron claude-login    # log in, once
```

The login prints a URL. Open it, approve, and paste the code back:

```
Opening browser to sign in...
If the browser didn't open, visit: https://claude.com/cai/oauth/authorize?...
Paste code here:
```

Credentials live in the `claude-home` volume, so this is a one-time step —
restarts and rebuilds stay logged in. Confirm with:

```bash
docker compose logs --tail 20        # should no longer say NOT AUTHENTICATED
docker compose exec claude-cron claude auth status --text
```

That's it. At 05:00 in your `TZ`, Claude receives your prompt.

> **Log in with `exec -it`, not from a `docker compose up` terminal.** `up`
> attaches the container's *output* to your terminal but not your keyboard to its
> *input*, so a login prompt shown there can never be answered — it just looks
> frozen. `exec -it` (and `docker compose run`) attach stdin properly.
>
> Login URLs are single-use: if an attempt dies, its code is void and you need a
> fresh URL.

## Configuration (`.env`)

Write values **unquoted** — `CRON_SCHEDULE=0 5 * * *`, not `"0 5 * * *"`.
A literal `$` in a value must be doubled (`$$`), since Compose reads this file.

| Variable | Default | What it does |
| --- | --- | --- |
| `TZ` | `Europe/Berlin` | Timezone the schedule is interpreted in |
| `CRON_SCHEDULE` | `0 5 * * *` | Standard 5-field cron: `min hour dom mon dow` |
| `CLAUDE_PROMPT` | `hi claude, how are you` | The message sent to Claude |
| `CLAUDE_WORKDIR` | `/workspace` | Claude's working directory (`./workspace` on the host) |
| `CLAUDE_MODEL` | `sonnet` | `opus` / `sonnet` / `haiku` or a full model id; empty = account default |
| `CLAUDE_ARGS` | `--permission-mode bypassPermissions` | Extra CLI flags for the run |
| `JOB_TIMEOUT` | `1800` | Kill a hung run after N seconds; `0` disables |
| `RUN_ON_START` | `false` | Also run once immediately at container start |
| `CLAUDE_CODE_VERSION` | `latest` | CLI version baked into the image at build time |
| `CLAUDE_CODE_OAUTH_TOKEN` | — | Optional; skips interactive login (see below) |
| `ANTHROPIC_API_KEY` | — | Optional; Console billing instead of your subscription |

Schedule examples:

```
0 5 * * *      every day at 05:00
30 6 * * 1-5   weekdays at 06:30
0 */4 * * *    every 4 hours
*/5 * * * *    every 5 minutes (handy for testing)
```

**Changing the schedule or prompt requires recreating the container** — the
crontab is rendered at start-up:

```bash
docker compose up -d --force-recreate
```

## Day-to-day

```bash
# Run the job right now instead of waiting for the schedule
docker compose exec -it claude-cron claude-run-now

# Log in again (expired session, or switching accounts)
docker compose exec -it claude-cron claude-login

# Check auth without touching anything
docker compose exec claude-cron claude auth status --text

# Follow output live
docker compose logs -f

# Show the crontab the container actually installed
docker compose exec claude-cron cat /etc/cron.d/claude-cron
```

## Logs

* `./logs/job-YYYY-MM-DD.log` — one file per day, full output of every run.
* `./logs/claude-cron.log` — the same output as a single stream; this is what
  `docker compose logs` mirrors.

Each run is bracketed so runs are easy to find:

```
[2026-08-22 05:00:01 CEST] claude-cron START
...
[2026-08-22 05:00:14 CEST] claude-cron END exit=0
```

Overlapping runs are prevented with a lock: if a run is still going when the
next tick arrives, the tick logs `previous run still in progress -- skipping`.

## Headless servers (no interactive login)

If you can't attach a terminal, mint a long-lived token on a machine where you
can, and put it in `.env`:

```bash
claude setup-token          # on your laptop -> sk-ant-oat01-...
```

```dotenv
CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-xxxxxxxx
```

The container then skips the login step entirely. `ANTHROPIC_API_KEY` works the
same way, but bills per token through the Anthropic Console rather than using
your Claude subscription.

## How it works

| File | Role |
| --- | --- |
| `Dockerfile` | `node:22-bookworm-slim` + `cron` + the Claude Code CLI, plus a non-root `claude` user |
| `scripts/entrypoint.sh` | Runs as root: sets the timezone, renders `/etc/cron.d/claude-cron`, checks/performs login, then `exec cron -f` |
| `scripts/run-job.sh` | The job itself, run as `claude`: verifies auth, then `claude -p "$CLAUDE_PROMPT"` |
| `scripts/claude-login.sh` | `claude-login` on `PATH` inside the container |
| `scripts/claude-run-now.sh` | `claude-run-now` on `PATH` inside the container |

Two details worth knowing:

* **The job runs as a non-root user.** Claude Code refuses to bypass permission
  checks as root, and an unattended job that can't use tools isn't much use.
* **cron gets no environment.** The entrypoint snapshots the relevant variables
  into `/etc/claude-cron/job.env`, which the job sources before running.

## Security note

`--permission-mode bypassPermissions` means the scheduled run executes tools
without asking. It is confined to the container and to whatever you mount, but
`./workspace` **is** your host filesystem. Mount only what the job should be
able to change. For a chat-only job, set `CLAUDE_ARGS=--tools ""` instead.

## Troubleshooting

**Job never fires.** Check the container's clock and the installed crontab:

```bash
docker compose exec claude-cron date
docker compose exec claude-cron cat /etc/cron.d/claude-cron
```

**`CRON_SCHEDULE must have 5 fields`.** The value is quoted in `.env`. Remove
the quotes.

**Job logs `no valid Claude session`.** Run
`docker compose exec -it claude-cron claude-login`.

**The login prompt appears but typing does nothing.** You are looking at a
`docker compose up` terminal, which does not forward stdin. Log in from another
terminal with `docker compose exec -it claude-cron claude-login` instead.

**Permission errors on `./logs` or `./workspace` (Linux hosts).** Rebuild with
your own uid/gid:

```bash
docker compose build --build-arg UID=$(id -u) --build-arg GID=$(id -g)
```
