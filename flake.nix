{
  description = "homelab";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # claude VM (nixos/nodes/claude): Claude Code's native binary, autoPatchelf'd, unfree.
    # Not following our nixpkgs on purpose: the package pins what the binary was patched against.
    claude-latest.url = "github:sadjow/claude-code-nix";
    # herdr: terminal multiplexer for agent sessions, runs headless on the claude VM.
    # Not following our nixpkgs: herdr needs zig_0_16, newer than our pin provides,
    # so it builds against its own locked nixpkgs (one extra nixpkgs eval, no other cost).
    herdr.url = "github:ogulcancelik/herdr";
  };

  outputs = inputs @ {
    self,
    nixpkgs,
    disko,
    sops-nix,
    ...
  }: let
    system = "x86_64-linux";
    pkgs = nixpkgs.legacyPackages.${system};

    lan = import ./nixos/settings/networking/configuration.nix;

    mkSystem = modules:
      nixpkgs.lib.nixosSystem {
        inherit system;
        # lets node configs reach flake inputs (claude-latest, herdr) as `inputs`
        specialArgs = {inherit inputs;};
        modules = modules;
      };
  in {
    nixosConfigurations = {
      host001 = mkSystem [
        disko.nixosModules.disko
        sops-nix.nixosModules.sops
        ./nixos/hosts/001/configuration.nix
      ];

      gpu01 = mkSystem [
        sops-nix.nixosModules.sops
        ./nixos/nodes/gpu01/configuration.nix
      ];

      node02 = mkSystem [
        disko.nixosModules.disko
        sops-nix.nixosModules.sops
        ./nixos/nodes/node02/configuration.nix
      ];

      node01 = mkSystem [
        sops-nix.nixosModules.sops
        ./nixos/nodes/node01/configuration.nix
      ];

      # Always-on Claude Code host (Remote Control + herdr) for the keyboard repos.
      # Spec: docs/CLAUDE-CODE-HOST.md. No sops in v1: Tailscale and GitHub are joined by hand.
      claude = mkSystem [
        ./nixos/nodes/claude/configuration.nix
      ];
    };

    devShells.${system}.default = pkgs.mkShell {
      packages = [
        pkgs.sops
        pkgs.opentofu
        pkgs.kubernetes-helm
        pkgs.awscli2
        pkgs.gh
        pkgs.kubeseal
        ## TODO: delete later once we get dns up and running
        (pkgs.writeShellScriptBin "refresh-kubeconfig" ''
          set -euo pipefail
          repo_root=''${REPO_ROOT:-$PWD}
          ip=${lan.nodes.node01.ip}
          echo "k3s server IP: $ip"
          ${pkgs.openssh}/bin/ssh -i ~/.ssh/homelab "admin@$ip" cat /etc/rancher/k3s/k3s.yaml \
            | sed -E "s|server: https://[^[:space:]]+|server: https://$ip:6443|" \
            > "$repo_root/.kubeconfig"
          chmod 600 "$repo_root/.kubeconfig"
          echo "wrote $repo_root/.kubeconfig"
        '')
      ];
    };
  };
}
