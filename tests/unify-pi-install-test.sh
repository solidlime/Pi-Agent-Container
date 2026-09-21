#!/bin/sh
# Fixture test for unify-pi-install.sh — no npm, no network, no container.
#
# Reproduces the container's duplication in a scratch tree and asserts the script
# collapses it. Run: sh tests/unify-pi-install-test.sh
set -eu

REPO=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# scratch "global": pi-coding-agent + satellites nested inside it (as npm does)
G="$TMP/npm-global/lib/node_modules"
mkdir -p "$G/@earendil-works/pi-coding-agent/node_modules/@earendil-works/pi-tui"
printf '{"name":"@earendil-works/pi-coding-agent","version":"9.9.9"}\n' > "$G/@earendil-works/pi-coding-agent/package.json"
printf '{"name":"@earendil-works/pi-tui","version":"9.9.9"}\n' > "$G/@earendil-works/pi-coding-agent/node_modules/@earendil-works/pi-tui/package.json"

# scratch global pi-web with a nested duplicate (the exact pin)
mkdir -p "$G/@agegr/pi-web/node_modules/@earendil-works/pi-coding-agent"
printf '{"name":"@agegr/pi-web","version":"0.9.1"}\n' > "$G/@agegr/pi-web/package.json"
printf '{"name":"@earendil-works/pi-coding-agent","version":"0.1.0"}\n' > "$G/@agegr/pi-web/node_modules/@earendil-works/pi-coding-agent/package.json"
# a satellite link left orphaned by the same kind of update
ln -s "$TMP/orphaned/pi-tui" "$G/@agegr/pi-web/node_modules/@earendil-works/pi-tui"

# scratch extension tree: a DANGLING link where the host package belongs (what a
# pi-web update leaves behind), legacy copies, and an unrelated override that
# must survive the manifest rewrite.
E="$TMP/pi-agent/npm"
mkdir -p "$E/node_modules/@earendil-works" "$E/node_modules/@mariozechner/pi-coding-agent"
printf '{"name":"pi-extensions","dependencies":{"pi-goal-x":"1.0.0"},"overrides":{"unrelated-pkg":"1.2.3"}}\n' > "$E/package.json"
ln -s "$TMP/orphaned/pi-coding-agent" "$E/node_modules/@earendil-works/pi-coding-agent"
printf '{"name":"@mariozechner/pi-coding-agent","version":"0.73.1"}\n' > "$E/node_modules/@mariozechner/pi-coding-agent/package.json"
# extensions that peer-depend on the legacy (pre-rename) packages: one on the
# host package, one on a satellite — the guard must cover both.
mkdir -p "$E/node_modules/pi-rtk-optimizer"
printf '{"name":"pi-rtk-optimizer","peerDependencies":{"@mariozechner/pi-coding-agent":"^0.74.0"}}\n' > "$E/node_modules/pi-rtk-optimizer/package.json"
mkdir -p "$E/node_modules/@mariozechner/pi-ai" "$E/node_modules/pi-legacy-ai-user"
printf '{"name":"@mariozechner/pi-ai","version":"0.73.1"}\n' > "$E/node_modules/@mariozechner/pi-ai/package.json"
printf '{"name":"pi-legacy-ai-user","peerDependencies":{"@mariozechner/pi-ai":"^0.73.0"}}\n' > "$E/node_modules/pi-legacy-ai-user/package.json"

dangling=$(readlink "$E/node_modules/@earendil-works/pi-coding-agent")
out=$(PI_PREFIX="$TMP/npm-global" PI_EXT_TREE="$E" sh "$REPO/unify-pi-install.sh")
echo "$out"

fail=0
check() { # check <description> <expected> <actual>
    if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
    else printf 'FAIL %s (expected %s, got %s)\n' "$1" "$2" "$3"; fail=1; fi
}

check "fixture really started dangling" "$TMP/orphaned/pi-coding-agent" "$dangling"
check "dangling extension link re-pointed" "$G/@earendil-works/pi-coding-agent" \
    "$(readlink "$E/node_modules/@earendil-works/pi-coding-agent")"
check "dangling satellite link re-pointed" "$G/@earendil-works/pi-coding-agent/node_modules/@earendil-works/pi-tui" \
    "$(readlink "$G/@agegr/pi-web/node_modules/@earendil-works/pi-tui")"
check "unrelated override preserved" "1.2.3" \
    "$(node -p "require('$E/package.json').overrides['unrelated-pkg']")"
check "legacy satellite kept (peer-depended)" "1" \
    "$(find "$E" -path '*/@mariozechner/pi-ai' -type d | wc -l | tr -d ' ')"
check "nested pi-web copy is now a symlink" "$G/@earendil-works/pi-coding-agent" \
    "$(readlink "$G/@agegr/pi-web/node_modules/@earendil-works/pi-coding-agent")"
check "extension tree copy is now a symlink" "$G/@earendil-works/pi-coding-agent" \
    "$(readlink "$E/node_modules/@earendil-works/pi-coding-agent")"
check "physical @earendil-works copies" "1" \
    "$(find "$TMP/npm-global" "$E" -path '*/@earendil-works/pi-coding-agent' -type d -not -type l | wc -l | tr -d ' ')"
check "legacy copy survived (still referenced)" "1" \
    "$(find "$TMP/npm-global" "$E" -path '*/@mariozechner/pi-coding-agent' -type d | wc -l | tr -d ' ')"
check "overrides pinned to host version" "9.9.9" \
    "$(node -p "require('$E/package.json').overrides['@earendil-works/pi-coding-agent']")"
check "invariant line reports physical=1" "1" \
    "$(echo "$out" | sed -n 's/.*physical=\([0-9]*\) .*/\1/p' | head -1)"
case "$out" in *WARN*) check "no WARN in output" "no-warn" "WARN-present";; *) check "no WARN in output" "no-warn" "no-warn";; esac

# idempotency: a second run must not change anything and must not warn
out2=$(PI_PREFIX="$TMP/npm-global" PI_EXT_TREE="$E" sh "$REPO/unify-pi-install.sh")
check "second run is a no-op" "" "$(printf '%s' "$out2" | grep -v '^unify: pi-coding-agent@' | grep -v 'legacy @mariozechner' || true)"

[ "$fail" = "0" ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"
