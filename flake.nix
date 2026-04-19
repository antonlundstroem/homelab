{
  description = "homelab";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixos-generators = {
      url = "github:nix-community/nixos-generators";
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
    nixos-generators,
    disko,
  }: let
    system = "x86_64-linux";
    pkgs = nixpkgs.legacyPackages.${system};

    lxcImage = nixos-generators.nixosGenerate {
      inherit system;
      format = "proxmox-lxc";
      modules = [./nixos/proxmox-lxc.nix];
    };

    dnsLxcImage = nixos-generators.nixosGenerate {
      inherit system;
      format = "proxmox-lxc";
      modules = [./nixos/proxmox-lxc.nix ./nixos/dns.nix];
    };

    vmImage = nixos-generators.nixosGenerate {
      inherit system;
      format = "qcow";
      modules = [./nixos/proxmox.nix];
    };

    k3sImage = nixos-generators.nixosGenerate {
      inherit system;
      format = "qcow";
      modules = [./nixos/proxmox.nix ./nixos/k3s.nix];
    };
  in {
    packages.${system} = {
      proxmox-lxc = pkgs.runCommand "nixos-proxmox-lxc.tar.xz" {} ''
        cp ${lxcImage}/tarball/*.tar.xz $out
      '';
      proxmox-lxc-dns = pkgs.runCommand "nixos-proxmox-lxc-dns.tar.xz" {} ''
        cp ${dnsLxcImage}/tarball/*.tar.xz $out
      '';
      proxmox-vm = pkgs.runCommand "nixos-proxmox-vm.qcow2" {} ''
        cp ${vmImage}/*.qcow2 $out
      '';
      proxmox-vm-k3s = pkgs.runCommand "nixos-proxmox-vm-k3s.qcow2" {} ''
        cp ${k3sImage}/*.qcow2 $out
      '';
      default = self.packages.${system}.proxmox-lxc;
    };

    nixosConfigurations.nixos = nixpkgs.lib.nixosSystem {
      inherit system;
      modules = [
        disko.nixosModules.disko
        ./nixos/disko.nix
        ./nixos/host.nix
      ];
    };

    nixosConfigurations.base = nixpkgs.lib.nixosSystem {
      inherit system;
      modules = [
        ./nixos/proxmox.nix
      ];
    };

    nixosConfigurations.k3s = nixpkgs.lib.nixosSystem {
      inherit system;
      modules = [
        ./nixos/proxmox.nix
        ./nixos/k3s.nix
      ];
    };

    nixosConfigurations.dns = nixpkgs.lib.nixosSystem {
      inherit system;
      modules = [
        ./nixos/proxmox-lxc.nix
        ./nixos/dns.nix
      ];
    };

    devShells.${system}.default = pkgs.mkShell {
      packages = [pkgs.opentofu];
    };
  };
}
