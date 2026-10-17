{pkgs, ...}: {
  imports = [
    ./hardware-configuration.nix
    ./disko.nix
    ./networking.nix
    ./incus.nix
    ./garage.nix
  ];

  sops = {
    defaultSopsFile = ../../../secrets/hosts/001/garage.yaml;
    # age key auto-derived from /etc/ssh/ssh_host_ed25519_key — nothing to set.
    # services.garage uses DynamicUser=true, so there's no persistent `garage`
    # account to chown to. Leave the secret as root:root 0400 — systemd reads
    # EnvironmentFile as root before dropping privileges to the dynamic user.
    secrets.garage_env = {
      key = "garage_env";
      mode = "0400";
    };
  };

  # ZFS Support
  boot.supportedFilesystems = ["zfs"];
  boot.zfs.forceImportRoot = false;
  # Cap the ARC at 4 GiB (default was ~30 GiB = most of RAM). With 28 GiB committed
  # to VMs on a 31 GiB host, an uncapped ARC and VM memory fight, and the loser is
  # an OOM-killed qemu. Takes effect at boot; set live without a reboot with
  # `echo 4294967296 | sudo tee /sys/module/zfs/parameters/zfs_arc_max`.
  boot.kernelParams = ["zfs.zfs_arc_max=4294967296"];

  # Bootloader
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Time
  time.timeZone = "Europe/Stockholm";

  # SSH
  services.openssh = {
    enable = true;
    settings.PasswordAuthentication = false;
  };

  # User
  users.users.admin = {
    isNormalUser = true;
    extraGroups = ["wheel"];
    openssh.authorizedKeys.keys = ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEn6aDAJkpZfBKdrin86mgv97ZqAPg/5PlYRXPDe6B4W home"];
  };

  security.sudo.wheelNeedsPassword = false;
  # users.users.root.initialHashedPassword = "$6$..."; # mkpasswd -m sha-512

  environment.systemPackages = with pkgs; [vim git curl];

  system.stateVersion = "25.11";
  nix.settings = {
    experimental-features = ["nix-command" "flakes"];
    trusted-users = ["root" "@wheel"];
  };
}
