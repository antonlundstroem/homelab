{
  pkgs,
  config,
  ...
}: let
  lan = import ../../settings/networking/configuration.nix;
  inherit (lan.services.k3s) ip mac;
  inherit (lan) gateway;
in {
  imports = [
    ./hardware-configuration.nix
    ./networking.nix
  ];

  nixpkgs.config.allowUnfree = true;

  sops = {
    defaultSopsFile = ../../../secrets/nodes/gpu01/secrets.yaml;
    secrets.k3s-token = {
      path = "/etc/k3s/token";
      mode = "0600";
      owner = "root";
    };
  };

  #boot.kernelPackages = pkgs.linuxPackages_latest;

  services.xserver.videoDrivers = ["nvidia"];
  hardware.nvidia = {
    modesetting.enable = true;
    open = false; # use proprietary driver
    package = config.boot.kernelPackages.nvidiaPackages.stable;
  };
  hardware.nvidia-container-toolkit.enable = true;
  #virtualisation.containerd.enable = true;

  services.k3s = {
    enable = true;
    role = "agent";
    serverAddr = "https://${ip}:6443";
    tokenFile = config.sops.secrets.k3s-token.path;

    extraFlags = [
      #"--node-label=node-role.kubernetes.io/gpu=true"
      "--node-label=nvidia.com/gpu=true"
      "--node-taint=nvidia.com/gpu=true:NoSchedule"
    ];
  };

  # ZFS Support
  #boot.supportedFilesystems = ["zfs"];
  #boot.zfs.forceImportRoot = false;

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

  environment.systemPackages = with pkgs; [
    vim
    git
    curl
    nvidia-container-toolkit
    nvidia-container-toolkit.tools
  ];

  system.stateVersion = "25.11";
  nix.settings = {
    experimental-features = ["nix-command" "flakes"];
    trusted-users = ["root" "@wheel"];
  };
}
