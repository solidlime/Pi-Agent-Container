# Pi-Agent-Container

[pi](https://pi.dev) coding agent + the pi-web UI in one container, configured
from a [chezmoi](https://chezmoi.io) dotfiles repo, with everything persisted on
the host.

- **Image**: `ghcr.io/solidlime/pi-agent-container:latest` (linux/amd64, ~1.1 GB)
- **Built by**: GitHub Actions on every push to `main` (`.github/workflows/build.yml`)

## Run

```yaml
services:
  pi:
    image: ghcr.io/solidlime/pi-agent-container:latest
    container_name: pi
    restart: unless-stopped
    ports: ["8787:8787"]
    environment:
      GH_TOKEN: ${GH_TOKEN}   # token with read access to the dotfiles repo
    volumes:
      - /path/to/pi/root:/root
```

`docker compose up -d`, then open `http://<host>:8787`.

`GH_TOKEN` is only needed on the **first boot**: once the dotfiles are cloned
into `/root/.local/share/chezmoi`, the sync is skipped and the token is unused.

If the host already has the `gh` CLI logged in, mount its config instead of
putting a token anywhere — the entrypoint picks it up when `GH_TOKEN` is empty:

```yaml
    volumes:
      - /path/to/pi/root:/root
      - ~/.config/gh:/root/.config/gh:ro
```

(The Windows gh CLI keeps its config under `%APPDATA%\GitHub CLI` instead, so
mount that path there. A host without gh just gets an empty directory — the
entrypoint then boots stock, exactly like an unset `GH_TOKEN`.)

Without a mount, the same thing from the shell:

```sh
GH_TOKEN="$(gh auth token)" docker compose up -d
```

`/root` is mounted **whole**, so npm globals (`/root/.npm-global`), pi state and
extensions (`/root/.pi`), the chezmoi source (`/root/.local/share/chezmoi`) and
the workspace (`/root/workspace`) all survive container recreation.

## What is baked in vs installed on first boot

| In the image | Installed on first boot (into the /root volume) |
| --- | --- |
| node 24 + OS | `@earendil-works/pi-coding-agent` (pi itself) |
| git, ripgrep, curl, unzip, zsh, tmux, vim, fzf, sshd | `@agegr/pi-web` (UI + node-pty) |
| chezmoi | the pi extension tree (`/root/.pi/agent/npm`, ~280 packages) |
| python3/make/g++ | agent-browser's Chromium download |
| Chromium runtime libraries | everything the dotfiles' `run_*` scripts do |

The two npm globals are ~1.4 GB and the dotfiles already install them
(`run_onchange_install-npm-globals.sh`), so baking them downloaded everything
twice and kept a second copy in an image layer. The entrypoint installs them
**only if the dotfiles sync did not** — a stock container with no `GH_TOKEN`
still works.

The build toolchain and the Chromium libraries stay in the image on purpose:
they are needed at **runtime**, not at build time.

## Update

```sh
docker exec pi update      # npm globals + dotfiles (all persisted in /root)
docker restart pi          # pick up new binaries
```

## Notes for whoever edits this (learned the hard way)

- **Never run two npm processes at once.** They write into the same
  `/root/.pi/agent/npm` prefix and race: `npm warn tar TAR_ENTRY_ERROR ENOENT`
  plus node-gyp `spawn sh ENOENT`, 1200+ lines on a fresh volume. The entrypoint
  runs every install step serially, in one shell, before pi-web starts.
- **`npm cache clean --force` has to be in the same `RUN` as the install** — in a
  later layer the cache is already committed. (Moot now: the image installs no
  npm packages.)
- **Don't move zsh/tmux/vim/fzf out of the apt line.** The dotfiles install them
  from `run_once_*` scripts, and `run_once` never re-runs in an existing volume —
  a recreated container would silently lose them. On top of that, the first-boot
  apt output plus ~150 `update-alternatives` warnings floods `docker logs`.
- **pi-web flags**: `-p/--port`, `-H/--hostname`, `--no-open`. There is no
  `--host` or `--no-browser` — they exit with a parse error. It binds 127.0.0.1
  by default, so `--hostname 0.0.0.0` is required in a container.
- **Port 8787 exposes an agent that can run high-privilege commands.** Set
  `PI_WEB_PASSWORD` when it is reachable beyond the host.
- **`GH_TOKEN` (env) wins over the gh CLI config.** The entrypoint reads
  `~/.config/gh/hosts.yml` only when `GH_TOKEN` is empty, and takes the first
  `oauth_token:` it finds — fine for one account, arbitrary with several.
- **`GH_TOKEN` ends up in the volume in plaintext.** `chezmoi init` clones the
  dotfiles with the token embedded in the URL, so it is stored in
  `/root/.local/share/chezmoi/.git/config` — on the host mount, readable by
  anything that can read that directory. Keep the mount's permissions tight, or
  switch to a deploy key / read-only fine-grained token.

## CI

Push to `main` → GitHub Actions builds and pushes
`ghcr.io/solidlime/pi-agent-container:{latest, sha-<short>, <tag>}` (plus a smoke
test that the OS-level pieces survived the build). On the host:

```sh
docker compose pull && docker compose up -d
```

The smoke test cannot check the first-boot path (it needs the dotfiles and ~10
minutes). That one is verified by hand with a throwaway volume:

```sh
docker run --rm -e GH_TOKEN=... -v /tmp/pi-test-root:/root \
  -p 8788:8787 ghcr.io/solidlime/pi-agent-container:latest
```
