#!/bin/sh
# docker-entrypoint.sh — first-boot setup, then exec CMD.
#
# Ordering matters and is enforced by doing all of it in this one shell:
#   1. dotfiles sync (chezmoi)  — installs pi, pi-web and the extension list
#   2. npm globals fallback     — only if step 1 did not produce them
#   3. extension tree sync      — needs pi from step 1 or 2
#   4. exec pi-web
# Never start two npm processes at once: they write into the same
# /root/.pi/agent/npm prefix and race, which floods the log with
# "npm warn tar TAR_ENTRY_ERROR ENOENT" and node-gyp "spawn sh ENOENT"
# (1200+ lines observed on a fresh volume).

set -e

mkdir -p /root/workspace

# SSH: start sshd if a public key was provided via SSH_AUTHORIZED_KEYS.
# Key-based only (PasswordAuthentication no baked into image).
if [ -n "$SSH_AUTHORIZED_KEYS" ]; then
    echo "==> starting sshd (port 22 in-container)..."
    mkdir -p /root/.ssh
    echo "$SSH_AUTHORIZED_KEYS" > /root/.ssh/authorized_keys
    chmod 700 /root/.ssh
    chmod 600 /root/.ssh/authorized_keys
    ssh-keygen -A >/dev/null
    /usr/sbin/sshd
fi

# 1. dotfiles. This also installs the npm globals through the dotfiles'
#    run_onchange_install-npm-globals.sh. GH_TOKEN is only needed for a private
#    dotfiles repo — without it the container boots with a stock /root.
if [ -n "$GH_TOKEN" ] && ! [ -d "$HOME/.local/share/chezmoi/.git" ]; then
    echo "==> Syncing dotfiles via chezmoi..."
    export PATH="$HOME/.local/bin:$PATH"
    export TMPDIR="$HOME/.cache/chezmoi-tmp"
    mkdir -p "$TMPDIR"
    # non-interactive: stdinIsATTY guard in config template skips prompts
    chezmoi init --apply "https://x-access-token:${GH_TOKEN}@github.com/solidlime/dotfiles.git" \
        || echo "WARN: chezmoi sync failed — continuing with stock config"
fi

# 2. npm globals fallback. The image does not bake pi/pi-web (the dotfiles do).
#    This keeps a stock container working when the sync is skipped or fails, and
#    heals a partial install. Deliberately sequential — see the header.
#    No --ignore-scripts: this mirrors the dotfiles' install, which is the path
#    that has actually been proven to produce a working pi.
if ! command -v pi >/dev/null 2>&1; then
    echo "==> installing pi (npm global)..."
    npm install -g --no-fund --no-audit @earendil-works/pi-coding-agent
fi
if ! command -v pi-web >/dev/null 2>&1; then
    echo "==> installing pi-web (npm global)..."
    npm install -g --no-fund --no-audit @agegr/pi-web
fi

# 3. Extension packages: install/refresh them HERE, in ONE process, BEFORE
#    pi-web starts. A single serialized run leaves the tree complete, so later
#    pi processes find nothing to install and stay quiet.
if [ -f "$HOME/.pi/agent/settings.json" ]; then
    echo "==> pi extensions: syncing (serialized)..."
    # Output goes to a file instead of /dev/null: a failed sync has to stay
    # diagnosable without flooding `docker logs` when it succeeds.
    timeout 600 pi update --extensions --no-approve >>"$HOME/.pi/pi-update.log" 2>&1 \
        || echo "WARN: extension sync failed — see $HOME/.pi/pi-update.log (pi will retry at runtime, may race)"
fi

exec "$@"
