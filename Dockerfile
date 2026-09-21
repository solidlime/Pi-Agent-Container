# pi-agent — pi coding agent + pi-web UI in a container.
#
# Split of responsibilities (this is the whole design):
#   BUILD (this file)       : OS, git/ssh, chezmoi, build toolchain, Chromium
#                             runtime libs — root/apt work that never changes
#                             on its own.
#   FIRST BOOT (entrypoint) : every npm global — pi itself, pi-web, the
#                             extension tree. They land in /root, which is
#                             host-mounted whole, so they survive container
#                             recreation and are upgraded with `docker exec pi
#                             update`.
# Rationale: the two npm globals are ~1.4 GB and the dotfiles'
# run_onchange_install-npm-globals.sh installs exactly the same two packages.
# Baking them downloaded everything twice and kept a second copy in an image
# layer. See README "What is baked in vs installed on first boot".

FROM node:24-bookworm-slim

# npm global prefix lives under /root (host-mounted whole) → upgrades survive
# container recreation without rebuilding the image.
ENV NPM_CONFIG_PREFIX=/root/.npm-global
ENV PATH=/root/.npm-global/bin:/root/.local/bin:$PATH

# quieter npm for the installs pi runs at runtime (fund/audit/update-notifier
# lines are pure log noise in a container)
ENV NPM_CONFIG_FUND=false NPM_CONFIG_AUDIT=false NPM_CONFIG_UPDATE_NOTIFIER=false

# pi-web's own entry point is not inside a pi-coding-agent package, so
# pi-subagents cannot discover the host package from it and refuses to start
# child sessions ("neither a supported standalone Pi host nor the installed npm
# package is available"). Its resolver checks this override first:
#   pi-subagents/src/runs/background/async-execution.js
#     return resolvePiPackageRoot() || env[PI_CODING_AGENT_PACKAGE_ROOT_ENV] || ...
# and its own comment there says the override must be honoured. Pointing it at
# the single global copy keeps background AND foreground subagents alive;
# `docker exec` sessions inherit the value from the image.
ENV PI_SUBAGENTS_PI_CODING_AGENT_PACKAGE_ROOT=/root/.npm-global/lib/node_modules/@earendil-works/pi-coding-agent

# Base tools + chezmoi (dotfiles sync inside the container) + sshd.
# zsh/tmux/vim/fzf are baked on purpose: the dotfiles' run_once_install-shell.sh
# and run_once_install-vim.sh would otherwise apt-get them on first boot, and
# that output plus ~150 update-alternatives warnings floods `docker logs`.
# run_once also never re-runs in an existing volume — a recreated container
# would silently lose them.
RUN apt-get update \
  && apt-get install -y --no-install-recommends bash ca-certificates git ripgrep curl unzip openssh-server zsh tmux vim fzf \
  && rm -rf /var/lib/apt/lists/* \
  && curl -fsLS get.chezmoi.io | sh -s -- -b /usr/local/bin \
  && mkdir -p /run/sshd /root/.ssh \
  && echo 'PermitRootLogin prohibit-password' >> /etc/ssh/sshd_config \
  && echo 'PasswordAuthentication no' >> /etc/ssh/sshd_config

# Build toolchain: pi installs extensions into /root/.pi/agent/npm at runtime and
# node-pty rebuilds there, which needs python3/make/g++ (seen on NAS:
# "gyp ERR! find Python" from /root/.pi/agent/npm/node_modules/node-pty).
# Chromium runtime libs: agent-browser downloads Chrome for Testing at runtime;
# without these it dies with "error while loading shared libraries:
# libglib-2.0.so.0" (verified: ldd → 0 "not found", headless --dump-dom → DOM).
RUN apt-get update \
  && apt-get install -y --no-install-recommends python3 make g++ \
     fonts-liberation libasound2 libatk-bridge2.0-0 libatk1.0-0 libatspi2.0-0 \
     libcairo2 libcups2 libdbus-1-3 libexpat1 libgbm1 libglib2.0-0 libnspr4 \
     libnss3 libpango-1.0-0 libudev1 libvulkan1 libx11-6 libxcb1 \
     libxcomposite1 libxdamage1 libxext6 libxfixes3 libxkbcommon0 libxrandr2 \
     xdg-utils \
  && rm -rf /var/lib/apt/lists/*

# PDF export stack. pi's PDF export (pi-markdown-preview) shells out to
# pandoc -> xelatex as child processes, so both must be in the image or the
# export fails outright. fonts-noto-cjk is required *silently*: xelatex's
# default font (Latin Modern) has no CJK glyphs, so a Japanese markdown exports
# with every glyph dropped and no warning. The same font set also covers
# headless Chromium's Japanese rendering.
RUN apt-get update \
  && apt-get install -y --no-install-recommends pandoc texlive-xetex texlive-fonts-recommended lmodern fonts-noto-cjk \
  && rm -rf /var/lib/apt/lists/*

# update script: one-shot upgrade of pi/pi-web + dotfiles, all persisted in /root
COPY update.sh /usr/local/bin/update
RUN chmod +x /usr/local/bin/update

# unify script: npm cannot keep one pi-coding-agent here on its own — pi-web
# pins the version exactly and some extensions peer-range into older ones, so a
# second copy at a different version is guaranteed. This collapses them onto
# one. Run by the entrypoint on every boot and by `update`; offline, idempotent.
COPY unify-pi-install.sh /usr/local/bin/unify-pi-install
RUN chmod +x /usr/local/bin/unify-pi-install

# sshd gives non-interactive commands a minimal env (no Docker ENV PATH), so
# expose the npm-global bins directly + via profile for login shells.
# The symlinks dangle until the first boot installs pi/pi-web — nothing executes
# them before the entrypoint does, and they keep the names on PATH for
# `docker exec`.
RUN ln -sf /root/.npm-global/bin/pi /usr/local/bin/pi \
  && ln -sf /root/.npm-global/bin/pi-web /usr/local/bin/pi-web \
  && printf 'export PATH="/root/.npm-global/bin:/root/.local/bin:$PATH"\n' > /etc/profile.d/npm-global.sh

COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

WORKDIR /root/workspace
# pi-web binds 127.0.0.1 by default → --hostname 0.0.0.0 is required in a
# container. Its flags are -p/--port, -H/--hostname, --no-open (default port
# 30141); there is no --host/--no-browser, those exit with a parse error.
# Port 8787 = the old pi-web-ui port, kept so existing host mappings and
# bookmarks keep working. To move it, override the CMD instead of editing this:
#   docker run ... <image> pi-web --no-open --port <n> --hostname 0.0.0.0
# Publishing exposes an agent that can run high-privilege commands — pass
# -e PI_WEB_PASSWORD=<long-random> when it is reachable beyond the host.
EXPOSE 8787
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["pi-web", "--no-open", "--port", "8787", "--hostname", "0.0.0.0"]
