#!/bin/sh
# update — one-shot upgrade of everything inside the container.
# All state lives in volumes (/root/.npm-global, /root/.local/share/chezmoi,
# /root/.pi/agent), so updates persist across container restart AND recreation.
# Usage:  docker exec pi update
#         docker restart pi        # picks up new binaries (volumes preserved)

set -e
export PATH=/root/.npm-global/bin:/root/.local/bin:$PATH
export DEBIAN_FRONTEND=noninteractive

# Build tools are baked into the image now (pi rebuilds node-pty at runtime
# in /root/.pi/agent/npm). Just make sure they're present if the image is old.
command -v python3 >/dev/null 2>&1 || {
    echo "==> installing build tools (old image)..."
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends python3 make g++ >/dev/null
    rm -rf /var/lib/apt/lists/*
}

echo "==> npm globals: updating pi + pi-web + tools..."
# No --allow-scripts here: npm has no such flag (it stores it as an unknown
# config key and ignores it). Lifecycle scripts run unless ignore-scripts is
# set, which is what rebuilds node-pty — same behaviour, just honest.
#
# `npm update -g` stays inside the recorded semver range. pi is 0.x, where the
# recorded range only allows patch updates, so a new minor (0.86 → 0.87) would
# never arrive. Install pi-web explicitly, then the CLI at the version pi-web
# pins (read from its manifest) — never @latest. Two @latest installs would
# disagree and npm would nest a second, older pi-coding-agent under pi-web;
# extensions resolve that copy while a different one is running, which breaks
# child sessions. `npm update -g` runs between the two so the CLI pin is applied
# to pi-web's final manifest, not a soon-to-be-updated one.
npm install -g --no-fund --no-audit @agegr/pi-web@latest
npm update -g --no-fund --no-audit
NPMROOT=$(npm root -g)
PIN=$(node -e 'const fs=require("fs");const r=process.argv[1];process.stdout.write(JSON.parse(fs.readFileSync(r+"/@agegr/pi-web/package.json","utf8")).dependencies["@earendil-works/pi-coding-agent"])' "$NPMROOT")
npm install -g --no-fund --no-audit "@earendil-works/pi-coding-agent@$PIN"

# Drop the overrides unify-pi-install left in the extension-tree manifest. They
# pin @earendil-works/* to the version unify last unified to; once the CLI has
# moved to pi-web's pin they would make the next npm that touches the tree
# install a second, mismatched copy — the duplicate that breaks child sessions.
# Only the @earendil-works/* keys are removed (unrelated overrides survive).
# Idempotent and never fatal: missing file / broken JSON / no keys are no-ops.
node -e 'const f=process.env.HOME+"/.pi/agent/npm/package.json",fs=require("fs");try{const p=JSON.parse(fs.readFileSync(f,"utf8"));if(p.overrides){const keys=Object.keys(p.overrides).filter(k=>k.startsWith("@earendil-works/"));if(keys.length){keys.forEach(k=>delete p.overrides[k]);if(!Object.keys(p.overrides).length)delete p.overrides;fs.writeFileSync(f,JSON.stringify(p,null,2)+"\n");console.log("removed "+keys.length+" stale @earendil-works overrides")}}}catch(e){}' || true

# Legacy UI (pi-web-ui) cleanup. It is only removed when it is NOT the running
# PID1: unlinking a live Next.js process breaks it, so a container still started
# with the old CMD is left alone (switch CMD to pi-web, restart, re-run).
if npm ls -g --depth=0 pi-web-ui >/dev/null 2>&1; then
    PID1_CMD=$(tr '\0' ' ' < /proc/1/cmdline 2>/dev/null || echo "")
    case "$PID1_CMD" in
        *pi-web-ui*)
            echo "    legacy UI is PID1 — switch CMD to pi-web, restart, then re-run update"
            ;;
        *)
            echo "==> removing legacy UI (pi-web-ui)..."
            npm uninstall -g --no-fund --no-audit pi-web-ui || echo "WARN: uninstall failed"
            # stale socket of the old server (new UI does not use this name)
            rm -f "$HOME/.pi-web/pi-web-ui.sock"
            # pi added this entry itself when the extension was installed;
            # drop it so a missing package does not break pi's package load.
            node -e 'const f=process.env.HOME+"/.pi/agent/settings.json",fs=require("fs");try{const s=JSON.parse(fs.readFileSync(f,"utf8"));if(Array.isArray(s.packages)){const n=s.packages.length;s.packages=s.packages.filter(p=>p!=="npm:pi-web-ui");if(s.packages.length!==n){fs.writeFileSync(f,JSON.stringify(s,null,2)+"\n");console.log("    settings.json: removed npm:pi-web-ui")}}}catch(e){console.log("    settings.json: skipped ("+e.message+")")}' || true
            ;;
    esac
fi

echo "==> dotfiles: chezmoi update --apply..."
if [ -d "$HOME/.local/share/chezmoi/.git" ]; then
    TMPDIR="$HOME/.cache/chezmoi-tmp"
    mkdir -p "$TMPDIR"
    # --force: pi rewrites commandcode-models.json at runtime, which would
    # trigger an interactive "has changed" prompt — fatal under docker exec (no TTY).
    TMPDIR="$TMPDIR" chezmoi update --apply --force || echo "WARN: chezmoi update failed"
else
    echo "    (no chezmoi source yet — will sync on next start with GH_TOKEN)"
fi

echo "==> versions:"
pi --version || echo "WARN: pi not runnable"
# pi-web has no --version flag (unknown options exit 1), so read npm instead.
npm ls -g --depth=0 2>/dev/null | grep -E "pi-web|pi-coding-agent" || true
echo "==> done. Now run: docker restart pi"
