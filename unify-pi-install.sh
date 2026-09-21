#!/bin/sh
# unify-pi-install — keep exactly ONE @earendil-works/pi-coding-agent per machine.
#
# WHY: @agegr/pi-web pins its pi dependency to an EXACT version (0.9.1 -> 0.85.1),
# so `npm i -g pi-coding-agent@latest pi-web@latest` always leaves pi-web with a
# second copy at a different version. Extension packages resolve the host package
# from the extension tree, and a second/older copy there kills child sessions:
#   background: "neither a supported standalone Pi host nor the installed npm
#                package is available"  (pi-subagents resolveAsyncPiPackageRoot)
#   foreground: "Cannot find package '.../pi-coding-agent/index.js'"
# Hence: one physical copy at the newest version, everything else symlinked to it.
#
# WHAT (idempotent, no network):
#   1. pi-web's nested @earendil-works/*  -> symlinks to the top-level copies
#   2. extension tree manifest: `overrides` pin the @earendil-works/* packages
#      to the installed version, so npm can no longer pull a second copy to
#      satisfy a peer range (pi-goal-x's ">=0.83.0 <0.85.0" was doing exactly
#      that: it silently installed pi-coding-agent@0.84.4)
#   3. extension tree: replace any real pi-coding-agent with a symlink
#   4. drop the legacy @mariozechner/pi-* copies (pre-rename leftovers)
#   5. report the invariant (physical copy count)
#
# Deliberate consequence: pi-web then runs against the newest pi-coding-agent
# instead of the version it pinned — one physical copy is the whole point.
#
# This file ships, byte-for-byte, through two carriers. Keep them identical
# (`cmp` them after editing either one):
#   container  : Pi-Agent-Container/unify-pi-install.sh
#                baked to /usr/local/bin/unify-pi-install, run by docker-entrypoint.sh
#   other hosts: dotfiles/dot_local/bin/executable_unify-pi-install
#                run by scripts/run_onchange_install-npm-globals.sh.tmpl
#
# Testing: PI_PREFIX / PI_EXT_TREE override the two roots (tests/unify-pi-install-test.sh).

set -eu

SCOPE="@earendil-works"
PREFIX=${PI_PREFIX:-${NPM_CONFIG_PREFIX:-$HOME/.npm-global}}
GLOBAL_NM="$PREFIX/lib/node_modules"

# npm's global prefix is not always ~/.npm-global (homebrew, Entware /opt,
# Debian /usr): ask npm when the assumed root has no pi scope at all.
if [ ! -d "$GLOBAL_NM/$SCOPE" ] && [ -z "${PI_PREFIX:-}" ] && command -v npm >/dev/null 2>&1; then
    probed=$(npm root -g 2>/dev/null || true)
    if [ -n "$probed" ] && [ -d "$probed/$SCOPE" ]; then
        GLOBAL_NM="$probed"
        PREFIX=${probed%/lib/node_modules}
    fi
fi

EXT_TREE=${PI_EXT_TREE:-$HOME/.pi/agent/npm}
EXT_NM="$EXT_TREE/node_modules"
HOST="$GLOBAL_NM/$SCOPE/pi-coding-agent"

if [ ! -f "$HOST/package.json" ]; then
    echo "unify: no global pi-coding-agent at $HOST — nothing to unify (skipped)"
    exit 0
fi
HOST_VERSION=$(node -p "require('$HOST/package.json').version")

# Package names in the global scope — drives the `overrides` list, so a new
# @earendil-works/* dependency needs no edit (the symlinking iterates the
# directory instead). The satellites (pi-ai, pi-tui, pi-agent-core,
# pi-telemetry, chord) live inside pi-coding-agent's own node_modules, not
# next to it, so union both scopes.
PKG_NAMES=$(
    { ls -1 "$GLOBAL_NM/$SCOPE" 2>/dev/null; ls -1 "$HOST/node_modules/$SCOPE" 2>/dev/null; } \
        | grep -v '^\.' | sort -u | tr '\n' ' '
)

relink_scope() {
    # $1 = a node_modules dir whose @earendil-works/* should point at the globals
    dir="$1/$SCOPE"
    [ -d "$dir" ] || return 0
    for p in "$dir"/*; do
        # [ -e ] follows the link, so a DANGLING symlink fails it — the state
        # this script exists to repair (a pi-web update left the link orphaned).
        # A dangling symlink is exactly what this script repairs, so it stays
        # in scope: [ -e ] follows the link and fails on a dangling one, while
        # the [ -L ] branch below catches it.
        name=$(basename "$p")
        # pi-coding-agent sits next to the scope dir; the satellites are nested
        # inside it — link to whichever copy exists, newest wins.
        target="$GLOBAL_NM/$SCOPE/$name"
        [ -d "$target" ] || target="$HOST/node_modules/$SCOPE/$name"
        if [ ! -d "$target" ]; then
            continue # not present globally (yet) — leave the tree alone
        fi
        if [ -L "$p" ]; then
            [ "$(readlink "$p")" = "$target" ] || { rm -f "$p"; ln -s "$target" "$p"; }
            continue
        fi
        rm -rf "$p"
        ln -s "$target" "$p"
        echo "unify: $p -> $target"
    done
}

# 1. pi-web's own nested tree (the exact pin that creates copy #2)
relink_scope "$GLOBAL_NM/pi-web/node_modules"
relink_scope "$GLOBAL_NM/@agegr/pi-web/node_modules"

# 2. extension tree: pin the scope via overrides
if [ -f "$EXT_TREE/package.json" ]; then
    node -e '
const fs = require("fs");
const [file, version, names] = process.argv.slice(1);
const list = names.split(/\s+/).filter(Boolean);
let pkg;
try { pkg = JSON.parse(fs.readFileSync(file, "utf8")); } catch (e) { console.log("unify: manifest unreadable (" + e.message + ")"); process.exit(0); }
const want = {};
for (const n of list) want["@earendil-works/" + n] = version;
// Merge, never replace: this file belongs to pi and may carry unrelated
// overrides (a wholesale assignment silently drops them).
const merged = Object.assign({}, pkg.overrides || {}, want);
if (JSON.stringify(pkg.overrides || {}) !== JSON.stringify(merged)) {
  pkg.overrides = merged;
  fs.writeFileSync(file, JSON.stringify(pkg, null, 2) + "\n");
  console.log("unify: overrides pinned to " + version + " in " + file);
}
' "$EXT_TREE/package.json" "$HOST_VERSION" "$PKG_NAMES"
fi

# 3. extension tree: stray real copies -> symlink to the global one
RELINK="$EXT_NM/$SCOPE/pi-coding-agent"
if [ -d "$EXT_NM/$SCOPE" ] && [ ! -L "$RELINK" ]; then
    rm -rf "$RELINK"
    ln -s "$HOST" "$RELINK"
    echo "unify: extension tree pi-coding-agent -> $HOST"
fi
relink_scope "$EXT_NM"

# 4. legacy pre-rename copies (per package: the guard must match what is deleted)
if [ -d "$EXT_NM/@mariozechner" ]; then
    for p in pi-coding-agent pi-ai pi-tui pi-agent-core; do
        [ -e "$EXT_NM/@mariozechner/$p" ] || continue
        # A dependency KEY ("...":) — not the legacy package's own "name" field.
        # One grep per package: an extension may peer-depend on any of the four.
        if grep -rql "\"@mariozechner/$p\"[[:space:]]*:" "$EXT_NM" \
                --include=package.json --exclude-dir='@mariozechner' 2>/dev/null; then
            echo "unify: legacy @mariozechner/$p left in place (still referenced)"
        else
            rm -rf "$EXT_NM/@mariozechner/$p" && echo "unify: removed legacy @mariozechner/$p"
        fi
    done
    rmdir "$EXT_NM/@mariozechner" 2>/dev/null || true
fi

# 5. invariant report — only the current package name counts: the legacy
# @mariozechner/pi-coding-agent is a different name and is reported apart.
physical=$(find "$PREFIX" "$EXT_TREE" -path "*/$SCOPE/pi-coding-agent" -type d -not -type l 2>/dev/null | wc -l | tr -d ' ')
links=$(find "$PREFIX" "$EXT_TREE" -path "*/$SCOPE/pi-coding-agent" -type l 2>/dev/null | wc -l | tr -d ' ')
echo "unify: pi-coding-agent@$HOST_VERSION — physical=$physical symlink=$links (target: 1)"
if [ "$physical" != "1" ]; then
    echo "unify: WARN multiple physical copies remain:"
    find "$PREFIX" "$EXT_TREE" -path "*/$SCOPE/pi-coding-agent" -type d -not -type l 2>/dev/null | sed 's/^/  /'
fi
legacy=$(find "$PREFIX" "$EXT_TREE" -path '*/@mariozechner/pi-coding-agent' -type d 2>/dev/null | wc -l | tr -d ' ')
[ "$legacy" = "0" ] || echo "unify: legacy @mariozechner/pi-coding-agent present ($legacy copy, still referenced by an extension)"
exit 0
