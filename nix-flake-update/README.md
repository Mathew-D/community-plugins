# Nix Flake Update

A read-only update checker for **flake-based NixOS configurations**.

Detects available updates across **all** flake inputs — not just `nixpkgs` — without modifying `flake.lock` or running `nix flake update`.

## Features

- Checks every input defined in your `flake.lock` (nixpkgs, home-manager, niri, custom overlays, etc.)
- Auto-detects your flake directory from common locations
- Displays per-input status: current locked revision, available revision, and update/up-to-date indicator
- Configurable check interval (default: 60 minutes); UI refreshes every second from cache
- Parallel `git ls-remote` queries (up to 8 at once) — fast even with many inputs
- Never runs `nix flake update`, `nixos-rebuild`, or `home-manager switch`
- Handles network failures and timeouts gracefully — errors are shown, service never crashes

## Example panel output

```
Nix Flake Update          ~/.config/nixos
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
3 input(s) have updates
───────────────────────────────────────
home-manager   +12   abc1234 → def5678   update
niri                 111aaaa             ok
nixpkgs        +247  aabbcc1 → 9988776   update
noctalia       +3    deadbee → cafebab   update
───────────────────────────────────────
Last checked: 2026-08-24 14:30:00
[ Check now ]
```

The `+N` commit count is available for GitHub-hosted inputs (queried via the
GitHub compare API — no auth required for public repos). Non-GitHub git inputs
show the rev change only.

## Requirements

- NixOS with flakes enabled
- `git` (for `git ls-remote`)
- `python3` (stdlib only — `json`, `subprocess`, `concurrent.futures`)

## Configuration

| Setting | Default | Description |
|---|---|---|
| **Flake path** | *(auto)* | Absolute path to your flake directory. Leave blank to auto-detect. |
| **Check interval** | `60` min | How often to check for updates in the background. |
| **Check timeout** | `5` min | Abort a check that takes longer than this. |
| **Show check notifications** | `false` | Notify on check start/end. |
| **Show update notifications** | `true` | Notify when updates are found. |

### Auto-detection order

If **Flake path** is left blank the plugin scans these locations and uses the first that contains a `flake.lock`:

1. `~/.config/nixos`
2. `~/nixos`
3. `~/.dotfiles`
4. `~/dotfiles`
5. `/etc/nixos`

## How it works

1. **Reads `flake.lock` as JSON** — the lock file is plain JSON; no `nix` invocation is needed to parse it.
2. **Extracts all root inputs** from the `nodes` map, respecting indirect references.
3. **Queries each remote** via `git ls-remote <url> <ref>` using the `original` entry's URL and branch. Requests run in parallel.
4. **Compares** the remote SHA with `locked.rev`. A mismatch means an update is available.

### Supported input types

| Type | Behaviour |
|---|---|
| `github` | Queries `https://github.com/<owner>/<repo>` |
| `gitlab` | Queries `https://<host>/<owner>/<repo>` |
| `git` | Queries the `url` field directly |
| `sourcehut` | Queries `https://git.sr.ht/<owner>/<repo>` |
| `path` | Shown as `local` — no remote to check |
| `tarball` | Shown as `tarball` — no git remote |
| `indirect` | Shown as `indirect` — registry inputs not queried |

## License

MIT
