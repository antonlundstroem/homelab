{
  description = "homelab";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = {
    self,
    nixpkgs,
    disko,
  }: let
    system = "x86_64-linux";
    pkgs = nixpkgs.legacyPackages.${system};

    mkSystem = modules:
      nixpkgs.lib.nixosSystem {
        inherit system;
        modules = modules;
      };

    # The upstream `system.build.images.<variant>` outputs are directories
    # containing one image file. Terraform's filesha256 needs a single file
    # path, and .envrc already references $PWD/nixos-* as files — so unwrap.
    extractFile = name: glob: image:
      pkgs.runCommand name {} ''
        cp ${image}/${glob} $out
      '';
  in {
    nixosConfigurations = {
      nixos = mkSystem [
        disko.nixosModules.disko
        ./nixos/disko.nix
        ./nixos/host.nix
      ];

      base = mkSystem [./nixos/proxmox.nix];
      k3s-server = mkSystem [./nixos/proxmox.nix ./nixos/k3s-server.nix];

      base-lxc = mkSystem [./nixos/proxmox-lxc.nix];

      # TODO(dns-as-lxc): move dns back to an LXC once the Proxmox
      # keyctl/root@pam friction is sorted (see CLAUDE.md "LAN DNS").
      # The base-lxc config above is kept ready for that swap.
      dns = mkSystem [./nixos/proxmox.nix ./nixos/dns.nix];
    };

    packages.${system} = {
      proxmox-lxc =
        extractFile "nixos-proxmox-lxc.tar.xz" "tarball/*.tar.xz"
        self.nixosConfigurations.base-lxc.config.system.build.images.proxmox-lxc;
      proxmox-vm =
        extractFile "nixos-proxmox-vm.qcow2" "*.qcow2"
        self.nixosConfigurations.base.config.system.build.images.qemu;
      proxmox-vm-k3s-server =
        extractFile "nixos-proxmox-vm-k3s-server.qcow2" "*.qcow2"
        self.nixosConfigurations.k3s-server.config.system.build.images.qemu;
      proxmox-vm-dns =
        extractFile "nixos-proxmox-vm-dns.qcow2" "*.qcow2"
        self.nixosConfigurations.dns.config.system.build.images.qemu;
      default = self.packages.${system}.proxmox-lxc;
    };

    devShells.${system}.default = pkgs.mkShell {
      packages = [
        pkgs.opentofu
        pkgs.helm
        ## TODO: delete later once we get dns up and running
        (pkgs.writeShellScriptBin "refresh-kubeconfig" ''
          set -euo pipefail
          repo_root=''${REPO_ROOT:-$PWD}
          ip=$(cd "$repo_root/terraform" && ${pkgs.opentofu}/bin/tofu output -json k3s_server_vm_ipv4 \
            | ${pkgs.jq}/bin/jq -r '[.. | strings | select(startswith("192.168."))][0]')
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
