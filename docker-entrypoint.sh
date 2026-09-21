#!/bin/sh
# docker-entrypoint.sh — first-boot setup, then exec CMD.
#
# Ordering matters and is enforced by doing all of it in this one shell:
#   1. dotfiles sync (chezmoi)  — installs pi, pi-web and the extension list
#   1b. /usr/bin/chromium link  — after chezmoi, which provides its target
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
#    GH_TOKEN normally comes from the environment; when it is empty, fall back to
#    a gh CLI config mounted read-only (-v ~/.config/gh:/root/.config/gh:ro), so a
#    host that is already `gh auth login`-ed needs no extra env var.
if [ -z "$GH_TOKEN" ] && [ -f "$HOME/.config/gh/hosts.yml" ]; then
    GH_TOKEN=$(sed -n 's/^[[:space:]]*oauth_token: *//p' "$HOME/.config/gh/hosts.yml" | head -1 | tr -d ' \r')
    if [ -n "$GH_TOKEN" ]; then
        echo "==> using the gh CLI token from $HOME/.config/gh/hosts.yml"
    fi
fi
if [ -n "$GH_TOKEN" ] && ! [ -d "$HOME/.local/share/chezmoi/.git" ]; then
    echo "==> Syncing dotfiles via chezmoi..."
    export PATH="$HOME/.local/bin:$PATH"
    export TMPDIR="$HOME/.cache/chezmoi-tmp"
    mkdir -p "$TMPDIR"
    # non-interactive: stdinIsATTY guard in config template skips prompts
    chezmoi init --apply "https://x-access-token:${GH_TOKEN}@github.com/solidlime/dotfiles.git" \
        || echo "WARN: chezmoi sync failed — continuing with stock config"
fi

# 1b. /usr/bin/chromium: agent-browser looks for the browser at this exact path
#     on Linux, but /usr is outside the mounted /root volume, so a container
#     recreate wipes it. chezmoi provides the real wrapper at
#     $HOME/.local/bin/chromium — it resolves agent-browser's version-pinned
#     Chrome at call time, so a hardcoded path would dangle after every update.
#     Re-point it on every boot. Idempotent, and if the dotfiles sync failed the
#     symlink just dangles (ln -sf does not require the target to exist) rather
#     than breaking the boot.
ln -sf "$HOME/.local/bin/chromium" /usr/bin/chromium \
    || echo "WARN: could not create /usr/bin/chromium symlink"

# 2. npm globals fallback. The image does not bake pi/pi-web (the dotfiles do).
#    This keeps a stock container working when the sync is skipped or fails, and
#    heals a partial install. Deliberately sequential — see the header.
#    No --ignore-scripts: this mirrors the dotfiles' install, which is the path
#    that has actually been proven to produce a working pi.
#
#    pi-web comes first: it pins its pi-coding-agent to an EXACT version, so the
#    CLI is then installed at that same pin (read from pi-web's manifest), never
#    @latest. Two @latest installs would disagree and npm would silently nest a
#    second, older pi-coding-agent under pi-web; extensions resolve that copy
#    while a different one is running, which breaks child sessions. Matching the
#    pin makes npm reuse the one copy, so no nested duplicate is created.
if ! command -v pi-web >/dev/null 2>&1; then
    echo "==> installing pi-web (npm global, latest)..."
    npm install -g --no-fund --no-audit @agegr/pi-web@latest
fi
if ! command -v pi >/dev/null 2>&1; then
    NPMROOT=$(npm root -g)
    PIN=$(node -e 'const fs=require("fs");const r=process.argv[1];process.stdout.write(JSON.parse(fs.readFileSync(r+"/@agegr/pi-web/package.json","utf8")).dependencies["@earendil-works/pi-coding-agent"])' "$NPMROOT")
    echo "==> installing pi (npm global, pi-web pin $PIN)..."
    npm install -g --no-fund --no-audit "@earendil-works/pi-coding-agent@$PIN"
fi

# Same stale-override heal as update.sh, before pi touches the tree below:
# unify-pi-install (now removed) pinned @earendil-works/* in
# ~/.pi/agent/npm/package.json, and a leftover pin makes the npm run by
# `pi update --extensions` install a second, mismatched copy. Only
# @earendil-works/* keys are dropped; idempotent and never fatal.
node -e 'const f=process.env.HOME+"/.pi/agent/npm/package.json",fs=require("fs");try{const p=JSON.parse(fs.readFileSync(f,"utf8"));if(p.overrides){const keys=Object.keys(p.overrides).filter(k=>k.startsWith("@earendil-works/"));if(keys.length){keys.forEach(k=>delete p.overrides[k]);if(!Object.keys(p.overrides).length)delete p.overrides;fs.writeFileSync(f,JSON.stringify(p,null,2)+"\n");console.log("removed "+keys.length+" stale @earendil-works overrides")}}}catch(e){}' || true

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
