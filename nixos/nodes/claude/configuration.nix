# claude — always-on Claude Code host for the keyboard repos (ergogen/KiCad),
# reachable from the phone via Claude Code Remote Control. Design and decisions:
# docs/CLAUDE-CODE-HOST.md. Everything Claude-specific is in ./claude.nix,
# the multiplexer in ./herdr.nix; this file is the VM itself.
{
  lib,
  pkgs,
  ...
}: let
  lan = import ../../settings/networking/configuration.nix;
  inherit (lan.nodes.claude) ip mac;
  inherit (lan) gateway;
in {
  imports = [
    ../../modules/incus-guest/configuration.nix
    ./claude.nix
    ./herdr.nix
  ];

  networking.hostName = lib.mkForce "claude";

  # Static IP, same mechanism as node01: Terraform sets the NIC MAC (var.CLAUDE_MAC),
  # the guest matches on it. Address outside the router's DHCP pool.
  networking.useDHCP = lib.mkForce false;
  networking.defaultGateway = gateway;
  systemd.network.links."10-lan0" = {
    matchConfig.MACAddress = mac;
    linkConfig.Name = "lan0";
  };
  networking.interfaces.lan0.ipv4.addresses = [
    {
      address = ip;
      prefixLength = 24;
    }
  ];
  networking.nameservers = ["1.1.1.1" "1.0.0.1"];

  time.timeZone = "Europe/Stockholm";

  # claude-code is unfree.
  nixpkgs.config.allowUnfree = true;

  # The agent user. Unprivileged (bypass-permissions mode refuses root anyway);
  # lingers so its user services (herdr, Remote Control servers) run from boot
  # without a login. The admin user from settings/system stays for nixos-rebuild.
  users.users.claude = {
    isNormalUser = true;
    description = "Claude Code agent";
    linger = true;
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEn6aDAJkpZfBKdrin86mgv97ZqAPg/5PlYRXPDe6B4W home"
    ];
  };
  # Repos live under ~/repos (one Remote Control server per repo, started on demand).
  systemd.tmpfiles.rules = [
    "d /home/claude/repos 0755 claude users -"
  ];

  # Tailscale: joined once by hand (`sudo tailscale up --ssh`), state persists in
  # /var/lib/tailscale. No auth key / sops in v1 by decision.
  services.tailscale = {
    enable = true;
    openFirewall = true;
  };
  networking.firewall.trustedInterfaces = ["tailscale0"];
  # Inbound: SSH (openssh opens 22) + tailscale. Egress open in v1.

  # Commit identity for everything Claude pushes (GitHub login is the user's own
  # account via `gh auth login`, done by hand after the first boot).
  programs.git = {
    enable = true;
    config = {
      user = {
        name = "anton";
        email = "anton@lundstrom.nix";
      };
      init.defaultBranch = "main";
    };
  };

  # Keyboard CAD toolchain + what Claude needs around it. claude-code and herdr
  # are added by their own modules. Firmware (ZMK) deliberately not installed.
  environment.systemPackages = with pkgs; [
    gh # repo creation + Actions logs (`gh repo create`, `gh run view --log`)
    ergogen
    kicad # full: 3D models make `kicad-cli pcb render` a real preview
    openscad-unstable
    nodejs
    python3
    jq
    vim
    curl
  ];

  # `sudo -iu claude` sets up no systemd user session, so `systemctl --user` fails with
  # "$DBUS_SESSION_BUS_ADDRESS and $XDG_RUNTIME_DIR not defined". Point such shells at the
  # lingering manager's runtime dir (SSH logins already get it from pam_systemd).
  programs.bash.interactiveShellInit = ''
    if [ -z "''${XDG_RUNTIME_DIR:-}" ] && [ -d "/run/user/$(id -u)" ]; then
      export XDG_RUNTIME_DIR="/run/user/$(id -u)"
    fi
  '';

  swapDevices = lib.mkForce [];
}
