# Claude Code on the claude VM: the binary installed untouched, and ALL
# configuration through Claude Code's managed-policy files under /etc/claude-code
# (settings, CLAUDE.md house rules, the `rc` skill). No wrapper, nothing from
# ~/nix — see docs/CLAUDE-CODE-HOST.md §6/§8 for why.
{
  inputs,
  pkgs,
  ...
}: let
  claude = inputs.claude-latest.packages.${pkgs.stdenv.hostPlatform.system}.claude-code;
  repos = "/home/claude/repos";

  # Helper behind the `rc` skill and the units' ExecStartPre, so the logic lives in Nix
  # rather than in prose Claude has to follow.
  # Trust: Claude Code saves per-directory trust as `projects.<dir>.hasTrustDialogAccepted`
  # in ~/.claude.json, never for $HOME itself, and server mode refuses an untrusted directory
  # ("Workspace not trusted") because a service has no TTY to answer the dialog. Each unit
  # therefore seeds its own directory's flag before starting (`rc trust <dir>`), which is
  # exactly what accepting the dialog writes. The same call seeds `remoteDialogSeen`, the flag
  # the one-time "Enable Remote Control? (y/n)" consent writes (found by diffing the file after
  # answering it once on 2026-10-17), so nothing here ever needs an interactive first run.
  rc = pkgs.writeShellApplication {
    name = "rc";
    runtimeInputs = [pkgs.jq pkgs.coreutils pkgs.systemd];
    text = ''
      repos="$HOME/repos"
      trust() {
        local dir="$1" f="$HOME/.claude.json" tmp
        [ -s "$f" ] || echo '{}' > "$f"
        tmp="$(mktemp "$f.XXXXXX")"
        jq --arg p "$dir" '.remoteDialogSeen = true | .projects[$p] = ((.projects[$p] // {}) + {hasTrustDialogAccepted: true})' "$f" > "$tmp"
        mv "$tmp" "$f"
        chmod 600 "$f"
      }
      case "''${1:-}" in
        trust) trust "$2" ;;
        start)
          [ -d "$repos/$2/.git" ] || { echo "rc: no git repository at $repos/$2" >&2; exit 1; }
          # add-wants rather than enable: NixOS-generated units carry no [Install] section.
          systemctl --user add-wants default.target "claude-remote-control@$2.service"
          systemctl --user start "claude-remote-control@$2.service"
          systemctl --user --no-pager --no-legend list-units "claude-remote-control@*" ;;
        stop)
          systemctl --user disable --now "claude-remote-control@$2.service"
          systemctl --user --no-pager --no-legend --all list-units "claude-remote-control@*" ;;
        list) systemctl --user --no-pager --no-legend --all list-units "claude-remote-control*" ;;
        *) echo "usage: rc start <repo> | rc stop <repo> | rc list" >&2; exit 2 ;;
      esac
    '';
  };

  # Shared shape of the Remote Control server units. User units apply to every
  # user's systemd instance, so ConditionUser pins them to the agent user.
  rcServer = {
    unitConfig = {
      ConditionUser = "claude";
      # Server mode exits immediately without a claude.ai login ("You must be logged in to
      # use Remote Control"), so gate on the credential file instead of restart-looping.
      # After the one-time `claude auth login`: `systemctl --user start claude-remote-control-repos`.
      ConditionPathExists = "%h/.claude/.credentials.json";
    };
    # Sessions inherit this PATH, so the whole system profile (gh, kicad-cli,
    # ergogen, ...) must be on it. The symlink survives rebuilds without a restart.
    path = ["/run/current-system/sw"];
    serviceConfig = {
      Restart = "always";
      # Server mode gives up after ~10 min without network and exits; restart it.
      RestartSec = 10;
    };
  };
in {
  environment.systemPackages = [claude rc];

  # Highest-precedence settings file; Claude never writes to it, so ~/.claude/settings.json
  # stays writable for the bits Claude edits itself. Settings keys and the env block
  # share this one file. Deliberately absent: any effort pin (decided), DISABLE_TELEMETRY,
  # CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC (the latter disables Remote Control).
  # mode 0444 makes NixOS install real files instead of store symlinks; `claude doctor`
  # otherwise warns that the file is reached through a link outside /etc/claude-code.
  environment.etc."claude-code/managed-settings.json".mode = "0444";
  environment.etc."claude-code/managed-settings.json".text = builtins.toJSON {
    permissions.defaultMode = "auto";
    skipDangerousModePermissionPrompt = true;
    editorMode = "vim";
    # every terminal-started session (herdr panes) is phone-reachable too
    remoteControlAtStartup = true;
    env = {
      CLAUDE_CODE_DISABLE_ADAPTIVE_THINKING = "1";
      DISABLE_NON_ESSENTIAL_MODEL_CALLS = "1";
      # repos reached via /add-dir load their own CLAUDE.md
      CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD = "1";
    };
    # sandbox = { ... };  # on, with a domain allowlist, once the first sessions show what they need
  };

  # Managed-policy CLAUDE.md: loaded in every session on this machine, not excludable.
  environment.etc."claude-code/CLAUDE.md".mode = "0444";
  environment.etc."claude-code/CLAUDE.md".text = ''
    # House rules on this VM (claude, the keyboard-design agent host)

    - Repos live under ~/repos, one directory per repository. This session's directory
      (~/repos) is the orchestrator: start new projects here.
    - New project: `gh repo create <name> --private --clone` from ~/repos, then offer to start
      its Remote Control server with the `rc` skill, and tell the user the server is called <name>.
    - Remote Control servers start and stop only through the `rc` skill (`rc start|stop|list`).
      Stop the servers of repos nobody is working on; each one is a resident process.
    - Firmware is out of scope here: the keyboards run ZMK, but no ZMK toolchain is installed.
  '';

  # Enterprise skill location: /etc/claude-code/.claude/skills/<name>/SKILL.md.
  # Model-invocable on purpose: typed custom slash commands from the phone are not
  # in the documented set, "start rc for budgie" in plain words is the interface.
  environment.etc."claude-code/.claude/skills/rc/SKILL.md".mode = "0444";
  environment.etc."claude-code/.claude/skills/rc/SKILL.md".text = ''
    ---
    name: rc
    description: Start, stop or list the Remote Control servers for repos under ~/repos. Use only when the user explicitly asks, e.g. "start rc for budgie", "stop budgie's server", "which servers are running".
    ---
    Arguments: $ARGUMENTS — a verb (start, stop, list), then a repo name under ~/repos.
    Run the matching command with the Bash tool, then tell the user which servers are running, by name:

    - start <repo>: `rc start <repo>` — the repo must be a git repository under ~/repos; the server
      returns after reboots until stopped, and its directory is trusted automatically.
    - stop <repo>:  `rc stop <repo>`
    - list:         `rc list`
  '';

  systemd.user.services = {
    # The always-on orchestrator: entry point from the phone for new repos, housekeeping,
    # and starting per-repo servers. It runs in ~/repos, not ~: Claude Code never saves
    # trust for the home directory and server mode refuses to start there. same-dir
    # because ~/repos is not a git repository.
    claude-remote-control-repos =
      rcServer
      // {
        description = "Claude Code Remote Control orchestrator (Homelab Orchestrator, in ~/repos)";
        wantedBy = ["default.target"];
        serviceConfig =
          rcServer.serviceConfig
          // {
            WorkingDirectory = repos;
            ExecStartPre = "${rc}/bin/rc trust ${repos}";
            # systemd honours double quotes in ExecStart, so the display name may carry a space
            ExecStart = "${claude}/bin/claude remote-control --name \"Homelab Orchestrator\" --spawn same-dir";
          };
      };

    # Template: one server per repo under ~/repos, started on demand via the rc skill.
    # No wantedBy here (instances are enabled per repo with add-wants).
    "claude-remote-control@" =
      rcServer
      // {
        description = "Claude Code Remote Control server for ~/repos/%i";
        serviceConfig =
          rcServer.serviceConfig
          // {
            WorkingDirectory = "${repos}/%i";
            ExecStartPre = "${rc}/bin/rc trust ${repos}/%i";
            ExecStart = "${claude}/bin/claude remote-control --name %i --spawn worktree";
          };
      };
  };
}
