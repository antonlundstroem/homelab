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
    git-hooks = {
      url = "github:cachix/git-hooks.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = {
    self,
    nixpkgs,
    disko,
    sops-nix,
    git-hooks,
  }: let
    system = "x86_64-linux";
    pkgs = nixpkgs.legacyPackages.${system};

    lan = import ./nixos/settings/networking/configuration.nix;

    mkSystem = modules:
      nixpkgs.lib.nixosSystem {
        inherit system;
        modules = modules;
      };

    preCommitCheck = git-hooks.lib.${system}.run {
      src = ./.;
      hooks = {
        # Built-in secret scanner (Rust, fast, no network) — catches real credentials.
        ripsecrets.enable = true;

        # Custom guard: never commit local-only files. They're gitignored / intent-to-add'd
        # so the pure flake can read them; committing them leaks to the public repo. No
        # built-in blocks specific paths, so this one stays custom.
        block-local-only = {
          enable = true;
          name = "block local-only files";
          entry = "${pkgs.writeShellScript "block-local-only" ''
            staged="$(${pkgs.git}/bin/git diff --cached --name-only)"
            blocked=0
            for f in nixos/settings/networking/configuration.nix .envrc.local; do
              if printf '%s\n' "$staged" | ${pkgs.gnugrep}/bin/grep -qxF -- "$f"; then
                echo "✗ refusing to commit local-only file: $f" >&2
                blocked=1
              fi
            done
            [ "$blocked" -eq 0 ] || { echo "  unstage it (git restore --staged <f>) or bypass: git commit --no-verify" >&2; exit 1; }
          ''}";
          language = "system";
          pass_filenames = false;
        };
      };
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
    };

    checks.${system}.pre-commit-check = preCommitCheck;

    devShells.${system}.default = pkgs.mkShell {
      inherit (preCommitCheck) shellHook;
      buildInputs = preCommitCheck.enabledPackages;
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
