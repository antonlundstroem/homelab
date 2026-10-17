# Always-on Claude Code host — research spec (first pass)

*Status: **built 2026-10-17** up to the manual logins (VM up on its static address, config live; see the build notes at the end of §7). Research and capacity check 2026-10-16; every decision, with its date and reasoning, is in §8, and the one item still open there waits for the first sessions by design. Untracked file; rename/move freely.*

## 0. Recommendation (TL;DR)

1. **Run it as a NixOS VM on Incus (`claude`), not as a k3s pod.** Same lifecycle as node01: Terraform creates the VM from `images:nixos/25.11`, `nixos-rebuild switch --flake .#claude` owns everything inside. It is a *pet* (claude.ai login state, transcripts, checked-out repos, a fast-moving binary), it wants the strongest isolation boundary you have because it will run with few permission prompts, and its toolchain (KiCad alone is a multi-GB closure) is exactly the image-bloat case `CLAUDE.md` already warns about for the cluster.
2. **Phone + browser access comes first-party from Claude Code itself: Remote Control server mode (`claude remote-control`).** It lets you *start new sessions and continue existing ones* from the Claude iOS/Android app or claude.ai/code, with push notifications and photo attachments, and it opens **no inbound port** (outbound polling to Anthropic). Tailscale is not required for this path at all.
3. **Still put Tailscale in the VM** (it costs one sops secret): laptop SSH / `herdr --remote` attach, Tailscale SSH + the admin-console browser SSH as a fallback, and the hook for an optional self-hosted PWA later.
4. **herdr is the multiplexer (decided, v1).** `herdr server` is a documented headless mode "for supervised or service-style setups", it restores Claude panes after a reboot via `claude --resume`, and `~/nix` already pins it as a flake input. Its phone/web plugins (herdr web ui, collie) stay optional: they are a *self-hosted alternative* to Remote Control, young and single-maintainer.
5. **Claude Code comes from `github:sadjow/claude-code-nix` (decided), installed as-is, with all configuration in `/etc/claude-code/managed-settings.json` (decided 2026-10-16; no wrapper, nothing from `~/nix`).** The package wraps Anthropic's native Bun binary with `autoPatchelfHook` (no `nix-ld` needed), is unfree-licensed (needs `allowUnfree`), and auto-bumps hourly; its launcher already sets `DISABLE_AUTOUPDATER` and `DISABLE_INSTALLATION_CHECKS` and puts ripgrep, bubblewrap, socat and procps on PATH. The `~/nix` lock is at 2.1.300 (2026-10-14), upstream HEAD is 2.1.301. Settings keys and the `env` block (adaptive thinking off, non-essential model calls off; effort deliberately not set) all live in managed settings, written by `environment.etc`; `~/nix` does it differently, shipping settings through the wrapper's `--settings` flag. For the record, a live test on 2026-10-16 showed `claude remote-control` refuses to start under that wrapper, naming `--mcp-config`, `--settings` and `--agents` (interactive `/rc` is unaffected), so a flag-adding wrapper is incompatible with server mode anyway, and managed settings reach the same end state with no wrapper at all.
6. **The keyboard CAD toolchain is in nixpkgs**: `ergogen` 4.2.1, `kicad` 10.0.0 (`kicad-cli` headless), `openscad`/`openscad-unstable`, `freecad` 1.1.0. Firmware (the keyboards run ZMK, not QMK) is out of scope for v1.
7. **host001 fits it at 2 vCPU / 8 GiB / 64 GiB thin once HAOS is trimmed from 8 to 4 GiB** (decided 2026-10-17, measured below; committed VM RAM stays at 28 GiB), with the ZFS ARC on host001 capped at 4 GiB in the same rollout.

## 1. Requirements

Stated:
- A Claude Code session host that is always ready.
- Reach *existing* sessions **and start new ones** from the phone or a browser.
- Tailscale preferred because it is already everywhere, but not mandatory.
- First workload: keyboard design/development with ergogen and other CAD tools.
- Either an Incus VM on host001 or a pod in the k3s cluster.

Inferred / assumed (confirm):
- Personal claude.ai subscription (Pro/Max), not an API key or Team org. Remote Control needs this.
- One primary project directory to begin with (`budgie`, the ergogen design repo), more repos over time, some created by Claude itself.
- No GPU needed (ergogen is pure JS; `kicad-cli` renders via software GL).
- Claude will run with few prompts (`acceptEdits`/auto, possibly bypass inside the VM), so the host boundary matters.

## 2. What Claude Code gives you out of the box (verified against code.claude.com, Oct 2026)

| Mechanism | What it does | Fit here |
| - | - | - |
| **Remote Control, server mode** (`claude remote-control`) | A resident process in a project dir that registers with the Anthropic API and polls. From the Claude app / claude.ai/code you **create new sessions on it** (up to `--capacity`, default 32) or continue existing ones. Push notifications, photo/file attachments, diff pane, model/effort switching from the phone. | **Primary surface.** Solves "start new ones from phone/browser" with zero infra. |
| Remote Control, interactive (`claude --rc`, `/rc`) | Same, but one remote session per terminal session. | For ad-hoc sessions you open over SSH. |
| **Agent view** (`claude agents`, `claude --bg`, supervisor `claude daemon …`) | Local multi-session manager: background sessions survive closing the terminal, not a reboot. Docs do not expose it to phone/web. | Nice on the laptop; on the VM it overlaps with herdr/tmux. |
| **Channels** (`claude --channels plugin:telegram@claude-plugins-official`) | Telegram/Discord bot pushes messages into *one already-running* session; can relay permission prompts. Needs Bun. | Alternative "chat from phone" path. Not needed if Remote Control is used. |
| Cloud sessions / `claude --cloud` | Runs on Anthropic infra, not your homelab. Custom environments can install tools. | Only if you decide the homelab host is unnecessary. No Tailscale, no persistent machine. |
| Dispatch | Needs the Desktop app running with a display. | Not for a headless VM. |
| Scheduled tasks, cross-session messaging | Bonus once the host exists. | Later. |

### 2.1 Remote Control server mode: the facts that shape the design

- **Flags**: `--name`, `--spawn same-dir|worktree|session`, `--capacity N`, `--permission-mode <mode>`, `--[no-]create-session-in-dir`, `--continue` / `--session-id` (resume for ~4 h after the server stopped), `--verbose`, `--debug`. `--sandbox`/`--no-sandbox` were **removed in v2.1.300**; sandboxing is configured in settings instead. Global flags placed before `remote-control` are not carried into the sessions the server creates; Claude Code lets a flag through only when dropping it is harmless (`--verbose`, `--model`, and, per the laptop test in §0, `--effort`) and otherwise refuses to start and names the flags (`--settings`, `--mcp-config`, `--agents`). Server mode only: interactive `--rc`/`/rc` sessions take the normal flags.
- **Auth**: requires a **full-scope claude.ai login** (Pro/Max/Team/Enterprise). `ANTHROPIC_API_KEY`, `claude setup-token` / `CLAUDE_CODE_OAUTH_TOKEN` are explicitly *not* enough ("can only make model requests"). So: a one-time interactive `claude auth login` on the host (SSH session → paste the code), credentials land in `~/.claude/.credentials.json` (0600) and are **refreshed in place**, which means the home directory is state that must persist. Logins also expire eventually (CLI warns 3 days before); an unattended server stops making progress until you SSH in and `/login` again. Period not documented; observe it.
- **First run needs a TTY**: a one-time `Enable Remote Control? (y/n)` and the workspace-trust prompt. When stdin/stdout isn't a terminal and trust is missing, it exits with `Workspace not trusted`. Run it once by hand, then supervise it under tmux/herdr from a systemd user service (`loginctl enable-linger`). The docs themselves say to use tmux/screen on remote machines.
- **Networking**: outbound HTTPS only (`api.anthropic.com`, `claude.ai`, `platform.claude.com` for token refresh, `downloads.claude.ai` for updates, `registry.npmjs.org`/`github.com` for plugins). No inbound ports. While connected, the **transcript is stored on Anthropic servers** to sync devices; execution and files stay local.
- **Resilience**: a network outage longer than ~10 min makes the server process exit → `Restart=always`. A crashed session is re-served when you message it (≥ v2.1.238). Sessions are per project directory: the server runs *in* the repo; `--spawn worktree` gives each phone-started session its own git worktree.
- **From the phone** you can pick Manual / Accept edits / Plan / Auto, but **not Bypass**. Some commands are terminal-only (`/plugin`, `/resume`).
- **Version drift matters**: several RC error paths end in "run `claude update`". A Nix-installed binary cannot self-update, so plan for frequent `nix flake update` (nixpkgs unstable was ~1 week behind the docs' latest in Oct 2026) or use the native installer with `programs.nix-ld.enable = true`.
- **Sandboxing stance from Anthropic**: run `--dangerously-skip-permissions` only inside a container/VM/sandbox-runtime, never as root (Claude refuses). The built-in Bash sandbox (bubblewrap + socat on Linux) works fully in a VM; in an unprivileged container it needs `enableWeakerNestedSandbox`, which the docs call a considerable weakening.

## 3. herdr and its phone/web plugins (third-party)

**herdr** (`herdrdev/herdr`, Rust, Apache-2.0, v0.9.5 on 2026-10-14, ~44k stars): a terminal multiplexer that knows agent state (working / blocked / idle). What matters for an always-on box:
- Background server survives client detach and SSH drops (ignores SIGHUP); `herdr server stop` ends panes.
- After a server/VM restart it **restores the layout and resumes Claude Code panes via `claude --resume <id>`** (native restore, on by default). Running processes themselves do not survive.
- Remote attach from the laptop is plain SSH: `herdr --remote claude`. Phones are not a herdr feature.
- Socket API at `~/.config/herdr/herdr.sock` (newline-delimited JSON; `agent.start`, `agent.prompt`, `pane.split`, `agent.wait`…), plus `herdr pane run`, `herdr agent wait` CLI. This is what the web plugins drive.
- Plugins are arbitrary argv commands with one-shot startup hooks, explicitly *not* supervised daemons, and **not sandboxed**. Install with `herdr plugin install owner/repo`.
- Not in nixpkgs. Upstream flake exposes `packages.x86_64-linux.herdr` and `overlays.default` (needs `rust-overlay`), so it is one flake input away.

Phone/web front ends for herdr (all MIT/Apache, all 2026, all single-maintainer):

| Project | Shape | Can start new sessions? | Exposure / auth |
| - | - | - | - |
| **herdr web ui** (`devswha/herdr-web-ui`) | herdr plugin; `herdr plugin install devswha/herdr-web-ui`; needs herdr ≥ 0.9, Bun ≥ 1.4, Node ≥ 18; listens `127.0.0.1:7317` | Mostly view/continue; "New worktree" starts an agent beside an existing one | `tailscale serve --bg --https=443 http://127.0.0.1:7317`; tailnet identity = you, other devices pair with a code |
| **collie** (`AltanS/collie`) | Separate Bun bridge + PWA, systemd *user* unit, `collie start` runs `tailscale serve` for you | **Yes**: `+ New` → machine, agent, folder, optional worktree | Tailnet only (warns against Funnel); `COLLIE_TRUSTED_USER`; mandatory device pairing; push when an agent blocks |
| herdr-remote (`psw7205/herdr-remote`) | Go bridge + PWA | Yes, but **requires a patched herdr fork** | Tailscale Serve identity headers |

Assessment: these reproduce what Remote Control does, self-hosted over Tailscale, with more moving parts (Bun, Node, curl-pipe-sh installers, non-sandboxed plugin code) and they serve your transcripts to any browser that authenticates. They are the right answer **if** you want to avoid routing through claude.ai; otherwise Remote Control wins on effort. You can also do both: run `claude remote-control` inside a herdr pane.

## 4. Where to run it: Incus VM vs k3s pod (vs Incus container)

| Dimension | Incus VM (NixOS, like node01) | k3s pod (StatefulSet on node02) |
| - | - | - |
| Isolation for a low-prompt agent | Own kernel; the boundary Anthropic recommends for unattended use | Shared node02 kernel with every other workload; needs `runAsNonRoot`, no privileged, and `enableWeakerNestedSandbox` for the Bash sandbox |
| State model | Login, transcripts, repos on the VM disk, backed up to Garage; same "precious-ish" posture as HAOS | Must live on a **local-path PVC**, which this repo defines as disposable; re-login + re-clone on every rebuild |
| Ownership fit (CLAUDE.md) | Terraform = lifecycle, NixOS = interior. Clean. | ArgoCD = manifests, but Claude Code's config/plugins/login are imperative and change under ArgoCD's feet |
| Updating Claude Code (ships several times a week) | `nix flake update` + `nixos-rebuild switch`, or native installer self-update | Build OCI image (`dockerTools.buildLayeredImage`) → push → bump manifest, per release |
| Toolchain size | Nix store on its own thin zvol; irrelevant | KiCad + FreeCAD closure = multi-GB image; the bloat case `CLAUDE.md` already flags |
| Reaching it | Remote Control: nothing. Tailscale in-VM (`services.tailscale`, `--ssh`), `services.tailscale.serve` for an optional web UI | Remote Control: nothing. Tailscale operator Ingress for a web UI; `kubectl exec` for the interactive login |
| Interactive ops (login renewal, plugin installs) | `ssh claude@claude` over the tailnet | `kubectl exec -it` into the pod |
| Resources | 4 vCPU / 8 GiB / 64 GiB thin (Anthropic floor: 1 CPU, 1 GiB, 5 GiB *per agent*; KiCad render wants more) | Same numbers as requests/limits on a 16 GB worker shared with everything else |
| Reboot behaviour | systemd user service + tmux/herdr restore | Pod restarts; sessions resumable from the PVC |
| When it wins | This use case | Many short-lived agents, scale-to-zero, Agent SDK pod-per-session with an HTTP gateway |

**Incus system container** (NixOS image on the `images:` remote, `security.nesting=true`) is the lighter middle option: less RAM than a VM, but bubblewrap's fresh `/proc` mount inside an unprivileged LXC is the same problem as in a pod, and the repo's Terraform pattern is VM-shaped. Only worth it if host001 RAM is tight; verify `/sandbox` works before committing.

Verdict: **VM.**

## 4a. Capacity check: host001 (measured 2026-10-16, uptime 1h10)

| Resource | host001 | Committed to VMs today | Actually in use | After claude at 2 vCPU / 8 GiB / 64 GiB thin and haos at 4 GiB |
| - | - | - | - | - |
| CPU | 6 cores, i5-9500 @ 3.0 GHz, no hyper-threading | 8 vCPU (node01 4 + haos 4), already 1.3× | load average ~2.7 | 10 vCPU, 1.7× over-commit |
| RAM | 31 GiB + 4 GiB swap (unused) | 24 GiB (node01 16 + haos 8) | VMs 8.3 GiB (node01 5.9, haos 2.4); host "used" 13 GiB, 18 GiB available; ZFS ARC 2.7 GiB with a **30.2 GiB cap** | 28 GiB committed on paper (node01 16 + haos 4 + claude 8) |
| Disk | rpool 232 GB, 210 GB free, 9% used, healthy | thin ceilings 264 GiB (node01 200 + haos 64) already exceed the pool | 16.4 GiB written (node01 13.0, haos 3.4); `rpool/nix` 15 GiB + `rpool/root` 5 GiB reserved; `rpool/incus` has **no quota** | ceilings 328 GiB, real growth ~15–25 GiB (NixOS + KiCad closure + repos) |

Inside node01 the guest sees 15 GiB with 2.9 GiB used and 12 GiB available (k3s-server ~1 GiB), so node01's 16 GiB is generous and could drop to 12 later. HAOS runs at 2.4 GiB of its 8 GiB.

What this means:
- **Yes, it fits** at 2 vCPU / 8 GiB with haos trimmed to 4 GiB (decided 2026-10-17; the first draft said 4 GiB, which is Claude Code's documented minimum, and with no swap on the VM an overrun is an OOM kill rather than a slowdown). Claude Code sessions are light on CPU; `kicad-cli pcb render` is the only hungry step and it is bursty. Incus hot-plugs vCPUs and memory on a running VM (`limits.cpu` and `limits.memory` are live-updatable; memory increases use hotplug with 16 increments before a restart is needed), so start small and raise it from Terraform when a render queue annoys you.
- **Cap the ARC on host001 before adding a third VM.** With `zfs_arc_max` at its default (30.2 GiB here) and VM RAM over-committed, the two fight for the same memory and an unlucky moment OOM-kills a qemu. Something like `boot.kernelParams = ["zfs.zfs_arc_max=4294967296"]` (4 GiB) in `nixos/hosts/001/` is the usual VM-host setting. This is a host001 change, so it rides a normal `nixos-rebuild switch --flake .#host001` (and a reboot for the kernel param).
- **RAM budget**: 28 GiB committed on a 31 GiB host leaves ~3 GiB for the host, Garage, Incus and a capped ARC, which is thin on paper but fine in practice because haos sits at 2.4 GiB. Decided 2026-10-17: trim haos from 8 to 4 GiB in the same apply that creates `claude` at 8 GiB (a Terraform edit; Incus shrinks live via balloon, slowly, and may need a second apply or a HAOS restart), so committed RAM stays at 28 GiB. haos runs at 2.4 GiB and Home Assistant documents 2 GB as the VM minimum; RAM-hungry add-ons (camera NVR, local voice, databases) are what would change that, and `limits.memory` goes back up live. If claude ever needs more than 8 GiB, trim node01 from 16 to 12 GiB.
- **Disk**: a 64 GiB thin ceiling costs nothing up front; the pool has 210 GB free. Do the `rpool/incus` quota from the CLAUDE.md TODO at the same time, since three thin zvols now promise more than the pool holds.

## 5. Keyboard toolchain on NixOS (what Claude will actually run)

- **ergogen 4.2.1** (`nixpkgs`): `ergogen config.yaml -o out` → `points/`, `outlines/` (DXF, SVG), `pcbs/*.kicad_pcb`, `cases/*.jscad`. Since 4.1 it writes **KiCad 8 format** PCBs (`template: kicad8`, `meta.engine: 4.1.0`), which KiCad 9/10 open; ceoloide's footprint library is the de-facto standard and lives in the project repo. Case `.jscad` → STL needs the OpenJSCAD CLI (npm, `npx @jscad/cli`), or route cases through OpenSCAD instead.
- **kicad 10.0.0**: `kicad-cli pcb export svg|pdf|gerbers|drill`, `kicad-cli pcb drc`, `kicad-cli pcb render --side top -o top.png` (raytraced PNG, software GL is fine headless). Routing is still a human job in the GUI on the laptop. `kicad-small` drops the 3D model packages if closure size matters (renders become bare boards).
- **openscad / openscad-unstable**, **freecad 1.1.0** (`FreeCADCmd` headless), Python CAD (cadquery/build123d) not found in nixpkgs search → `uv` venv if ever needed.
- Firmware: the keyboards run **ZMK** (not QMK); scoped out of v1 by decision (2026-10-16).
- **Seeing results from the phone**: (a) Claude commits SVG/PNG previews and you view them in the forge; (b) `kicad-cli`/`openscad` write PNGs into a directory served read-only over the tailnet via `services.tailscale.serve`; (c) self-host `ergogen-gui` (Node 20, live SVG + KiCanvas PCB preview) behind Tailscale. Photos you send from the app land in `~/.claude/uploads/` so Claude can look at a sketch or a printed plate.

## 6. Proposed design: `claude`

**Terraform (`terraform/hosts/001/main.tf`)**: `incus_instance.claude`, `type = "virtual-machine"`, `image = "images:nixos/25.11"`, profiles `["default","lan"]`, `limits.cpu = 2`, `limits.memory = 8GiB` (decided 2026-10-17 together with haos going to `4GiB` in the same apply, §4a; both are live-updatable), root disk `64GiB` thin on pool `default`, `wait_for agent`, bridged `eth0` on `br0` with `var.CLAUDE_MAC` (new variable in `variables.tf`, value in `.envrc.local` and the `.example`), same `authorized_keys` push as node01.

**Flake inputs (`flake.nix`)**: the same upstream inputs the laptop uses; no dependency on `~/nix` (private) and nothing copied from it:
```nix
claude-latest.url = "github:sadjow/claude-code-nix";          # native binary, autoPatchelf'd
herdr.url = "github:ogulcancelik/herdr";                     # own nixpkgs lock: it needs zig_0_16, newer than our pin
```
`mkSystem` needs `specialArgs = { inherit inputs; }` so the node config can reach `inputs.claude-latest.packages.x86_64-linux.claude-code` and `inputs.herdr.packages.x86_64-linux.default`, plus `nixpkgs.config.allowUnfree = true` (or an `allowUnfreePredicate` for `claude-code`). herdr builds against its own locked nixpkgs (it needs `zig_0_16`, which our April pin lacks, so `follows` broke evaluation), a second nixpkgs evaluation and a from-source build on the laptop; it built fine on 2026-10-17.

**Claude config (`nixos/nodes/claude/claude.nix`)**: one file, all managed settings, no wrapper. `environment.etc` writes the JSON from a Nix attrset, so it is reviewed in git like everything else, and the binary is installed untouched:
```nix
{ inputs, pkgs, ... }: {
  environment.systemPackages = [ inputs.claude-latest.packages.${pkgs.stdenv.hostPlatform.system}.claude-code ];
  environment.etc."claude-code/managed-settings.json".text = builtins.toJSON {
    permissions.defaultMode = "auto";              # decided (§8)
    skipDangerousModePermissionPrompt = true;
    editorMode = "vim";
    remoteControlAtStartup = true;                 # every terminal-started session is phone-reachable
    env = {
      CLAUDE_CODE_DISABLE_ADAPTIVE_THINKING = "1";
      DISABLE_NON_ESSENTIAL_MODEL_CALLS = "1";
      CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD = "1";   # repos reached via /add-dir load their own CLAUDE.md
      # no CLAUDE_CODE_EFFORT_LEVEL here and no effortLevel key above: model default, changed per session (decided 2026-10-17)
    };
    # sandbox = { ... };                           # on, with a domain allowlist (§8 item 1: after the first sessions)
    # statusLine = { type = "command"; command = "${pkgs.jq}/bin/jq -r ..."; };   # optional, absolute store path
  };
  # managed-policy CLAUDE.md: loaded in every session, carries the house rules (self-service servers, see §6 NixOS bullets)
  environment.etc."claude-code/CLAUDE.md".text = ''
    # House rules on this VM
    - New project: `gh repo create <name> --private --clone` from ~/repos, then offer to start its
      Remote Control server with the rc skill, and tell the user the server is called <name>.
    - Servers start and stop only through the rc skill; stop servers of repos nobody is working on.
  '';
  # enterprise skill location: /etc/claude-code/.claude/skills/<name>/SKILL.md, loaded in every session
  environment.etc."claude-code/.claude/skills/rc/SKILL.md".text = ''
    ---
    name: rc
    description: Start, stop or list the Remote Control servers for repos under ~/repos, only when the user explicitly asks ("start rc for budgie", "stop budgie's server", "which servers run").
    ---
    Arguments: $ARGUMENTS (verb, then repo name).
    - start <repo>: systemctl --user add-wants default.target claude-remote-control@<repo>.service && systemctl --user start claude-remote-control@<repo>
    - stop <repo>:  systemctl --user disable --now claude-remote-control@<repo>
    - list:         systemctl --user list-units 'claude-remote-control@*' --no-pager
    Then tell the user which servers are running, by name.
  '';
}
```
Leave `DISABLE_TELEMETRY` and `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` unset: the latter makes Remote Control unavailable, and `~/nix` only blanks them to cancel its wrapper module's defaults.

**NixOS (`nixos/nodes/claude/configuration.nix`)**, importing `nixos/modules/incus-guest`:
- Static IP from `lan.nodes.claude` (add to `configuration.nix` + `.example.nix`), hostname `claude`.
- `users.users.claude`: normal user, `linger = true`, **not root** (bypass mode refuses root), SSH key as in `settings/system`.
- Packages: `claude-code` from `claude-latest`, installed by `claude.nix` above (its launcher already sets `DISABLE_AUTOUPDATER`, `DISABLE_INSTALLATION_CHECKS` and `USE_BUILTIN_RIPGREP=0` and puts ripgrep, bubblewrap, socat and procps on PATH, so none of those need listing), `herdr`, `git`, `gh` (Claude creates repos with `gh repo create` and reads Actions logs with `gh run view --log`), `ergogen`, `kicad` (full, decided 2026-10-17: the 3D models are what make a render a preview; `kicad-small` if closure size ever matters), `openscad-unstable`, `nodejs`, `python3`, `bun` (only if a channel or herdr web plugin is used).
- Tailscale, v1 (decided 2026-10-17): `services.tailscale.enable = true` and one manual `tailscale up --ssh` after first boot; state persists in `/var/lib/tailscale`, so no auth key and no sops recipient are needed before the VM exists. Later, if a rebuild-from-nothing should rejoin unattended: `authKeyFile = config.sops.secrets.tailscale_authkey.path; extraUpFlags = ["--ssh"];`. Optional `services.tailscale.serve` for a preview dir or web UI. Tag the node (`tag:claude`) and scope ACLs so only your devices reach it.
- sops, not in v1: nothing on the VM needs a secret at build time once Tailscale is joined by hand and the forge credential is set up interactively. When one is needed: new recipient `&claude` in `.sops.yaml` (from the VM's host key, so only after first boot), `secrets/nodes/claude/secrets.yaml` (Tailscale auth key, forge token or deploy key, optional Telegram bot token). Remember the reinstall hazard from `docs/SOPS.md`.
- GitHub access (decided 2026-10-17; the credential is supplied after the build): Claude on the VM must clone and push the keyboard repos, **create new repositories** for things it develops, and **read GitHub Actions logs** (`gh run list`, `gh run view --log`) to act on failed builds, for example the ZMK firmware builds in `zmk-config`. That is account-level access, not a per-repo deploy key, so it comes from one interactive `gh auth login` on the VM (device-code flow, works over SSH; the token persists in `~/.config/gh/hosts.yml`, so until backups exist a VM rebuild means logging in again). `gh`'s default OAuth scopes (`repo`, `read:org`, `gist`, `workflow`) cover all three needs, and git pushes over HTTPS reuse the token via `gh auth setup-git`. The identity is your own account (decided 2026-10-17), so the VM can push to everything you own; keeping it to the keyboard repos then rests on the house rules, auto mode and the sandbox, not on GitHub permissions. Commit identity (`user.name`/`user.email`) is declared with `programs.git` in NixOS.
- Claude config: entirely the **managed settings** file from `claude.nix` above. Settings keys (permission mode, `skipDangerousModePermissionPrompt`, vim keys, `remoteControlAtStartup`, sandbox with a domain allowlist) and the `env` block (adaptive thinking off, non-essential model calls off; no effort pin, see the decided line in §8) share that one file; nothing wraps the binary. Status line: none in v1, or a small `jq` script as `statusLine.command` using an absolute store path. `~/.claude/settings.json` stays writable for the bits Claude itself edits.
- herdr: `systemd.user.services.herdr-server` running `herdr server` (the documented headless mode), `Restart=always`, config delivered declaratively through `HERDR_CONFIG_PATH=/etc/herdr/config.toml` (`environment.etc`) with `onboarding = false`, `[session] resume_agents_on_restore = true`, `[server] headless_cols/headless_rows`. herdr is **not** the vehicle for the Remote Control servers (checked against herdr's session-state and plugin docs, 2026-10-17): its restore recreates workspaces, panes, cwd and agent sessions, explicitly not "running shells, servers, tests, or arbitrary processes", and plugin `[[startup]]` hooks are one-shot commands rather than supervised daemons, so systemd keeps the servers. Optional mirror for the laptop view: the house rule may also run `herdr workspace create --cwd ~/repos/<name> --label <name> --no-focus`, so `herdr --remote claude` shows one workspace per repo. Plugin registrations (`~/.config/herdr/plugins.json`) stay imperative, as on the laptop. Attach from the laptop with `herdr --remote claude`.
- Remote Control servers (decided 2026-10-17, your design; replaces a Nix list of repos and automatic per-repo servers): **one always-on orchestrator server**, shown on the phone as `Homelab Orchestrator`: `systemd.user.services.claude-remote-control-repos` running `claude remote-control --name "Homelab Orchestrator" --spawn same-dir` in `/home/claude/repos` (same-dir because that directory is not a git repository; no wrapper, so no global flags before the verb, §2.1), `Restart=always`. It runs in `~/repos`, not `~`: Claude Code never saves trust for the home directory and server mode refuses to start there ("Workspace not trusted", found at build time). Beside it one systemd user **template** unit `claude-remote-control@.service`, declared once, with `WorkingDirectory=/home/claude/repos/%i` and `ExecStart=claude remote-control --name %i --spawn worktree`, started **only on demand** per repo. The phone's server list is therefore `Homelab Orchestrator` plus the repositories in active use, and resident Claude processes (each server is one, pre-creating one session via `--create-session-in-dir`) stay bounded by what you started, not by how many repos exist. Both units carry `ConditionPathExists=%h/.claude/.credentials.json`: without a claude.ai login server mode exits at once, so they stay inactive until the one-time `claude auth login`, after which the orchestrator unit is started once by hand; and an `ExecStartPre=rc trust <dir>` that seeds the directory's trust flag (`projects.<dir>.hasTrustDialogAccepted` in `~/.claude.json`, the flag the interactive dialog writes), since a service has no TTY to answer the dialog (built 2026-10-17).
- The `rc` skill, declarative: `environment.etc."claude-code/.claude/skills/rc/SKILL.md"`, the enterprise skill location Claude Code loads for every session on the machine (`/etc/claude-code/.claude/skills/<name>/SKILL.md`). The skill calls a small `rc` helper (a `writeShellApplication` in `claude.nix`, so the logic is in Nix rather than in prose Claude has to follow): `rc start <repo>` checks the repo is a git repository, then `systemctl --user add-wants default.target claude-remote-control@<repo>.service && systemctl --user start ...` (add-wants rather than enable: NixOS-generated units carry no [Install] section; a started server also returns after a reboot until stopped); `rc stop <repo>` is `systemctl --user disable --now ...`; `rc list` lists the units; `rc trust <dir>` is what the units' `ExecStartPre` uses. It stays model-invocable: the documented set of slash commands that work from the phone is built-ins only, so "start rc for budgie" in plain words is the interface, and the description scopes it to explicit requests. From the phone: open `Homelab Orchestrator`, ask for budgie's server, and `budgie` appears in the server list within seconds; the same for a repo Claude created a minute earlier.
- House rule in the managed CLAUDE.md (`/etc/claude-code/CLAUDE.md`, loaded in every session, not excludable): new project → `gh repo create <name> --private --clone` from `~/repos` → offer to start its server with the `rc` skill → name the server. Servers start and stop only through `rc`, never left running for repos nobody is working on.
- Interactive panes in herdr get `remoteControlAtStartup = true` from managed settings, so every `claude` you open on the VM is also reachable from the phone, while new phone-started sessions land on the server above.
- Backup, deferred (decided 2026-10-17, re-login and re-clone accepted for v1): restic/rclone timer → a `claude` bucket on host001 Garage for `/home/claude` (`~/.claude` credentials + transcripts + settings, repos). Small, nightly. Without it a rebuild costs a re-login and re-clone, which is tolerable but annoying.
- Firewall: inbound only SSH (LAN) + Tailscale. Egress open in v1; the devcontainer's default-deny `iptables` script is the reference if you later want an allowlist.
- Permission posture: start from `auto`, which is what the laptop runs (§8 item 2), and add the sandbox domain allowlist once the first sessions show what they need; `acceptEdits` + sandbox is the stricter fallback, bypass only if you accept "the VM is the blast radius".

**v2 (optional)**: `herdr plugin install devswha/herdr-web-ui` or `collie` behind `tailscale serve` if you want a self-hosted PWA next to the Claude app; a Telegram channel if chat-style nudges appeal.

## 7. Done-when

- [ ] From the Claude app on the phone (not on the LAN): open **Code**, see the `budgie` server, **start a new session**, ask it to regenerate the keyboard from `config.yaml`; it runs ergogen + `kicad-cli` and you can see the resulting preview (committed file or tailnet-served PNG).
- [ ] From a laptop browser at claude.ai/code: continue that same session.
- [ ] `ssh claude@claude` over the tailnet works; `herdr --remote claude` shows the same running sessions, and the sidebar reflects working/blocked/idle.
- [ ] `sudo reboot` on claude → `herdr server` is back, restored Claude panes resume via `claude --resume`, and the Remote Control server is listed online again within ~2 minutes with no manual step.
- [x] host001 after the change: ARC capped at 4 GiB, haos at 4 GiB, claude at 8 GiB, committed VM RAM 28 GiB (`rpool/incus` quota deferred). *Verified 2026-10-17: `c_max` 4.0 GiB live and `zfs.zfs_arc_max` in the newest boot entry; haos `limits.memory` 4GiB with 2.6 GiB in use; claude created at 2 vCPU / 8 GiB / 64 GiB.*
- [x] `nixos-rebuild switch --flake .#claude` is the only way config lands (in place since 2026-10-17; the first rollout was `nixos-rebuild boot` + reboot); the only imperative state is the claude.ai and GitHub logins, `~/.claude`, herdr plugins, the repos under `~/repos` and which of them have a server enabled (backing all of it up is deferred, §8).
- [x] On claude, `claude remote-control --help` prints the flag list (no "not carried over" refusal). *Verified 2026-10-17 as the agent user: `--name`, `--spawn`, `--capacity` listed; `claude doctor` reads `/etc/claude-code/managed-settings.json`.*
- [ ] A fresh `claude` session has the managed settings in effect with no `~/.claude/settings.json` present (permission mode, vim keys, the `env` block). Needs the login.
- [ ] From the phone, in the `Homelab Orchestrator` server: "start a repo for X" → Claude creates `X` on GitHub and under `~/repos` and offers its server; "start rc for X" → `X` appears in the phone's server list within seconds; "stop rc for X" removes it; all with no step on the laptop. `systemctl --user list-units 'claude-remote-control@*'` matches what the phone shows.
- [ ] A permission prompt raised by a session is answerable from the phone; a finished task produces a push notification.

### Build notes (2026-10-17)

Built this day up to the manual logins; `claude` is up on its static address with the config live. What differed from the plan:
- The image server had dropped `nixos/25.11`; `claude` boots `images:nixos/26.05`. node01's Terraform keeps 25.11 with a warning comment, since a changed image forces a replace.
- The bootstrap image runs dbus-broker and our pin classic dbus, so the 26.05 switch-inhibitor check refused the first live `switch`; `nixos-rebuild boot` plus a reboot did it. Later switches are normal.
- herdr cannot follow our nixpkgs (needs `zig_0_16`); it builds from its own lock.
- The three `/etc/claude-code` files use `mode = "0444"` so NixOS installs real files; `claude doctor` flags the store symlink otherwise (it still reads it).
- The Remote Control units are gated on `~/.claude/.credentials.json`: without a login, server mode exits at once ("You must be logged in to use Remote Control"), which was a 10 s restart loop. NixOS's user-unit reload did not stop the in-flight loop; an explicit `systemctl --user daemon-reload` in the agent's manager did.
- Stale `known_hosts` entries for the reused DHCP address needed `ssh-keygen -R`.
- Server mode refused the home directory ("Workspace not trusted. /home/claude is your home directory, and for security home-directory trust is never saved"), so the orchestrator moved to `~/repos` (unit `claude-remote-control-repos`; shown as `Homelab Orchestrator`, renamed by the user the same day). Units seed their directory's trust flag through `rc trust` in `ExecStartPre`; the flag name was confirmed against the laptop's `~/.claude.json`. The one-time "Enable Remote Control? (y/n)" consent then stopped the service the same way; answered once through a scripted pseudo-terminal, which showed it writes `remoteDialogSeen: true` (plus a generated `remoteControlMachineId`) to `~/.claude.json`, so `rc trust` seeds that flag as well. With both seeded the orchestrator runs under systemd and reports Connected.
- `--name` is the title of the server's pre-created session, chosen when its environment is first created. A restart reconnects to the preserved environment through `~/.claude/projects/<dir>/bridge-pointer.json` and keeps the old title, so renaming the running orchestrator is done from the app or with `/rename` in that session (both update the local title too); the unit's `--name "Homelab Orchestrator"` applies to the next fresh environment. Do not delete the pointer file to force a new one: the folder then counts as "already served by a terminal `claude remote-control` on this device" until the server-side environment expires, and the unit loops on that for about a minute per attempt (tried and reverted 2026-10-17).
- `sudo -iu claude` has no systemd user session (`systemctl --user` fails on a missing `XDG_RUNTIME_DIR`); interactive bash now falls back to the lingering manager's runtime dir.
- Verified on the VM: hostname, static address and gateway; `claude` lingering with `herdr-server` active; claude-code 2.1.302, herdr 0.9.5, gh 2.89, ergogen 4.2.1, kicad-cli 10.0.0; `herdr workspace list` works as the agent user over a plain SSH command with `HERDR_CONFIG_PATH` set; 7.9 GiB visible, 2 vCPU, 63 GB root.
- Incus reports HAOS on a different LAN address than `docs/haos-vm.md` documents; not touched here.
- Pending, by hand, in this order: `sudo tailscale up --ssh`; as `claude` over SSH (not `sudo -iu claude`: that shell has no systemd user session and `systemctl --user` fails with "$DBUS_SESSION_BUS_ADDRESS and $XDG_RUNTIME_DIR not defined"; `export XDG_RUNTIME_DIR=/run/user/$(id -u)` fixes it, and the node config now sets that fallback in interactive bash): `claude auth login`, `systemctl --user start claude-remote-control-repos`, `gh auth login`, clone `budgie` into `~/repos`; then the phone-side checks above (directory trust is seeded by the units, no interactive first run needed).

## 8. Decisions

Decided 2026-10-16: **herdr** over tmux; Claude Code from **`github:sadjow/claude-code-nix`** (`claude-latest`), configured **entirely through managed settings** in `environment.etc`, no wrapper, nothing from `~/nix` (which ships settings via its wrapper's `--settings` flag, a flag server mode refuses, §2.1); ZMK firmware tooling skipped for now. Decided 2026-10-17: **effort is not set anywhere**, no `CLAUDE_CODE_EFFORT_LEVEL` in the `env` block and no `effortLevel` key; sessions start at the model default and change it with `/effort` or the phone's effort control. (An env pin would make the phone's effort control refuse, and `effortLevel` does not accept `max`, so neither gives "max, but changeable".) Decided 2026-10-17, defaults accepted: host001 **ARC cap 4 GiB** (`boot.kernelParams = ["zfs.zfs_arc_max=4294967296"]`), rolled out with claude; **Tailscale joined once by hand**, no auth key or sops in v1; **backups deferred**, re-login accepted; **`rpool/incus` quota deferred**; full **`kicad`**; **Remote Control** is the phone surface for the first two weeks before any self-hosted PWA; **`auto`** permission mode; **scope guard** stands: no kubeconfig, ArgoCD or Incus credentials on the VM. Also decided 2026-10-17: the VM is named **`claude`** (hostname, `incus_instance.claude`, `nixosConfigurations.claude`, `nixos/nodes/claude/`, `lan.nodes.claude`, `TF_VAR_CLAUDE_MAC`; the Incus guests are `node01` and `haos`, so no number). Its **LAN address and NIC MAC are chosen**: the next after `haos` in the `.5x` block and in the `00:16:3e:42:00:0x` sequence. Both live only in the gitignored networking file and `.envrc.local` (plus the two `.example` files), never in this document, because the repo is public. **RAM: 8 GiB at creation, with haos trimmed 8 → 4 GiB in the same apply** (2026-10-17): committed VM RAM stays 28 GiB; no swap on the VM makes an overrun a kill rather than a slowdown; haos runs at 2.4 GiB against Home Assistant's documented 2 GB VM minimum, and if the balloon does not release the memory live the new haos limit lands at its next restart. **Project layout and GitHub access** (2026-10-17): one always-on orchestrator server, `Homelab Orchestrator` on the phone, in `~/repos` (not `~`: home-directory trust is never saved) plus a systemd template unit started per repo on demand through a managed `rc` skill (start, stop, list), so the phone lists `Homelab Orchestrator` plus the repositories in active use, resident processes stay bounded by what you started, and repos Claude creates become servers on request with no laptop involved (your design, replacing automatic per-repo servers); `budgie` first (`keebs` holds keymaps, `zmk-config` and `zmk-keyboard-budgie` firmware); repos live under `~/repos/<name>`; GitHub access is account-level through `gh auth login` after the build, because Claude must create repos and read Actions logs, not only push to `budgie`, so a per-repo deploy key is out. **GitHub identity: your own account** (2026-10-17), logged in with `gh auth login` on the VM after the build; the VM can then push to everything you own, so keeping it to the keyboard repos rests on the house rules, auto mode and the sandbox rather than on GitHub permissions, and a fine-grained token scoped to the keyboard repos is the fallback if that ever feels too wide.

1. **Sandbox allowlist** for the keyboard repos, once the first sessions show what they need. Everything else is decided above.

## 9. Sources

- Claude Code docs: [Remote Control](https://code.claude.com/docs/en/remote-control), [Mobile](https://code.claude.com/docs/en/mobile), [Sandbox environments](https://code.claude.com/docs/en/sandbox-environments), [Sandboxing](https://code.claude.com/docs/en/sandboxing), [Agent view](https://code.claude.com/docs/en/agent-view), [Channels](https://code.claude.com/docs/en/channels), [Authentication](https://code.claude.com/docs/en/authentication), [Sessions](https://code.claude.com/docs/en/sessions), [Network configuration](https://code.claude.com/docs/en/network-config), [Agent SDK hosting](https://code.claude.com/docs/en/agent-sdk/hosting), [Corporate launcher](https://code.claude.com/docs/en/corporate-launcher)
- herdr: [repo](https://github.com/herdrdev/herdr), [CLI reference](https://herdr.dev/docs/cli-reference/), [configuration](https://herdr.dev/docs/configuration/), [persistence & remote](https://herdr.dev/docs/persistence-remote/), [session state](https://herdr.dev/docs/session-state/), [socket API](https://herdr.dev/docs/socket-api/), [plugins](https://herdr.dev/docs/plugins/)
- Claude Code packaging: [sadjow/claude-code-nix](https://github.com/sadjow/claude-code-nix) (native binary, autoPatchelf, hourly bumps, cachix `claude-code`), [nix-wrapper-modules claude-code module](https://github.com/BirdeeHub/nix-wrapper-modules/blob/main/wrapperModules/c/claude-code/module.nix)
- Incus: [instance options](https://linuxcontainers.org/incus/docs/main/reference/instance_options/) (`limits.cpu` / `limits.memory` live updates)
- Plugins: [herdr web ui](https://herdrweb.dev/), [collie](https://github.com/AltanS/collie), [herdr-remote](https://github.com/psw7205/herdr-remote)
- Tailscale: [SSH Console](https://tailscale.com/kb/1216/tailscale-ssh-console)
- Keyboard tooling: [ergogen usage](https://docs.ergogen.xyz/usage/), [ceoloide/ergogen-footprints](https://github.com/ceoloide/ergogen-footprints), [KiCad CLI](https://docs.kicad.org/9.0/en/cli/cli.html), [KiCad Docker images](https://www.kicad.org/download/docker/), [ergogen-gui](https://github.com/runinit/ergogen-gui), [ergogen-docker](https://github.com/vigilancer/ergogen-docker)
- nixpkgs versions via search.nixos.org / NixHub (2026-10-16): ergogen 4.2.1, kicad 10.0.0, openscad-unstable 2021.01-unstable-2026-02-25, freecad 1.1.0 (claude-code 2.1.293 there, superseded by claude-code-nix)
- host001 measurements taken over SSH on 2026-10-16: `free`, `lscpu`, `zpool list`, `zfs list`, `incus list`, `incus config get`, `/proc/spl/kstat/zfs/arcstats`; node01 guest `free`
- Laptop test 2026-10-16 (claude-code 2.1.300 via the `~/nix` wrapper): `claude remote-control --help` exits 1 with the "not carried over" error naming `--mcp-config`, `--settings`, `--agents`; `--effort` is not named. Wrapper exec line read from `readlink -f $(command -v claude)`; `nix-wrapper-modules/wrapperModules/c/claude-code/module.nix` emits `--agents`, `--mcp-config` and `--settings` unconditionally (no `mkIf`/`!= {}` guard).
