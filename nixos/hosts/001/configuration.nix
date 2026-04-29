{pkgs, ...}: {
  imports = [
    ./hardware-configuration.nix
    ./disko.nix
    ./garage.nix
    ./incus.nix
  ];

  sops = {
    defaultSopsFile = ../../../secrets/hosts/001/garage.yaml;
    # age key auto-derived from /etc/ssh/ssh_host_ed25519_key — nothing to set.
    # services.garage uses DynamicUser=true, so there's no persistent `garage`
    # account to chown to. Leave the secret as root:root 0400 — systemd reads
    # EnvironmentFile as root before dropping privileges to the dynamic user.
    secrets.garage_env = {
      key  = "garage_env";
      mode = "0400";
    };
  };

  # ZFS Support
  boot.supportedFilesystems = ["zfs"];
  boot.zfs.forceImportRoot = false;
  networking.hostId = "856d208d";

  # Bootloader
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Networking
  networking.hostName = "host001";
  networking.networkmanager.enable = true;

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
