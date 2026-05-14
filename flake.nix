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
  };

  outputs = {
    self,
    nixpkgs,
    disko,
    sops-nix,
  }: let
    system = "x86_64-linux";
    pkgs = nixpkgs.legacyPackages.${system};

    lan = import ./nixos/settings/networking/configuration.nix;

    mkSystem = modules:
      nixpkgs.lib.nixosSystem {
        inherit system;
        modules = modules;
      };
  in {
    nixosConfigurations = {
      #nixos = mkSystem [
      #  disko.nixosModules.disko
      #  ./nixos/disko.nix
      #  ./nixos/host.nix
      #];

      host001 = mkSystem [
        disko.nixosModules.disko
        sops-nix.nixosModules.sops
        ./nixos/hosts/001/configuration.nix
      ];

      k3s = mkSystem [
        sops-nix.nixosModules.sops
        ./nixos/services/k3s/configuration.nix
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
          ip=${lan.services.k3s.ip}
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
