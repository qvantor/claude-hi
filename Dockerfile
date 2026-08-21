FROM node:22-bookworm-slim

# Pin the CLI at build time:  docker compose build --build-arg CLAUDE_CODE_VERSION=2.1.238
ARG CLAUDE_CODE_VERSION=latest
# Match these to your host uid/gid if bind-mount ownership matters (Linux hosts).
ARG UID=1000
ARG GID=1000

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates \
      cron \
      curl \
      git \
      jq \
      procps \
      ripgrep \
      tini \
      tzdata \
 && rm -rf /var/lib/apt/lists/*

RUN npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
 && npm cache clean --force

# Claude Code refuses to bypass permission checks while running as root, and the
# scheduled job needs to use tools unattended -- so the job runs as `claude`.
# node:22 already occupies uid 1000 with its `node` user; drop it first.
RUN userdel -r node 2>/dev/null || true \
 && groupadd -g "${GID}" claude \
 && useradd -m -u "${UID}" -g "${GID}" -s /bin/bash claude

ENV HOME=/home/claude \
    CLAUDE_WORKDIR=/workspace

RUN mkdir -p /home/claude/.claude /workspace /var/log/claude-cron /etc/claude-cron \
 && chown -R claude:claude /home/claude /workspace /var/log/claude-cron

COPY scripts/entrypoint.sh     /usr/local/bin/entrypoint.sh
COPY scripts/run-job.sh        /usr/local/bin/run-job.sh
COPY scripts/claude-login.sh   /usr/local/bin/claude-login
COPY scripts/claude-run-now.sh /usr/local/bin/claude-run-now
RUN chmod 0755 /usr/local/bin/entrypoint.sh \
               /usr/local/bin/run-job.sh \
               /usr/local/bin/claude-login \
               /usr/local/bin/claude-run-now

WORKDIR /workspace

# tini is PID 1 so cron's children get reaped, and so /proc/1/fd/1 stays the
# container's stdout for the job logger.
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
CMD ["cron", "-f", "-L", "2"]
