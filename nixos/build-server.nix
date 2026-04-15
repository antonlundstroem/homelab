{pkgs, ...}: let
  repoUrl = "https://github.com/REPLACE_ME/homelab.git";
  repoPath = "/var/lib/homelab";
  imagesPath = "/var/www/images";
in {
  services.nginx = {
    enable = true;
    virtualHosts."build.lan" = {
      root = imagesPath;
      locations."/".extraConfig = "autoindex on;";
    };
  };

  systemd.tmpfiles.rules = [
    "d ${imagesPath} 0755 nginx nginx -"
    "d ${repoPath}   0755 root  root  -"
  ];

  systemd.services.build-images = {
    description = "Build homelab NixOS images";
    path = with pkgs; [git nix coreutils];
    serviceConfig = {
      Type = "oneshot";
      User = "root";
    };
    script = ''
      set -euo pipefail

      if [ ! -d ${repoPath}/.git ]; then
        git clone ${repoUrl} ${repoPath}
      fi

      cd ${repoPath}
      git fetch --prune
      git reset --hard origin/main

      nix build .#proxmox-vm     -o ${imagesPath}/nixos-vm.qcow2
      nix build .#proxmox-vm-k3s -o ${imagesPath}/nixos-k3s.qcow2

      chown -R nginx:nginx ${imagesPath}
    '';
  };

  systemd.timers.build-images = {
    description = "Rebuild homelab images hourly";
    wantedBy = ["timers.target"];
    timerConfig = {
      OnCalendar = "hourly";
      Persistent = true;
    };
  };

  networking.firewall.allowedTCPPorts = [80];

  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 14d";
  };
  nix.optimise.automatic = true;
}
