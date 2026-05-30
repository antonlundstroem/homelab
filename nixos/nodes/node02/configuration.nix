## node02 configuration
## bare-metal k3s workload
{
  pkgs,
  config,
  ...
}: let
  lan = import ../../settings/networking/configuration.nix;
  inherit (lan.nodes.node01) ip;
in {
  imports = [
    ./disko.nix
    ./hardware-configuration.nix
    ./networking.nix
    # TODO: UNCOMMENT
    #../../modules/k3s/longhorn.nix
  ];

  nixpkgs.config.allowUnfree = true;

  # TODO: UNCOMMENT
  #sops = {
  #  defaultSopsFile = ../../../secrets/nodes/node02/secrets.yaml;
  #  secrets.k3s-token = {
  #    path = "/etc/k3s/token";
  #    mode = "0600";
  #    owner = "root";
  #  };
  #};

  #boot.kernelPackages = pkgs.linuxPackages_latest;

  # TODO: UNCOMMENT
  #services.k3s = {
  #  enable = true;
  #  role = "agent";
  #  serverAddr = "https://${ip}:6443";
  #  tokenFile = config.sops.secrets.k3s-token.path;
  #};

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
  ];

  system.stateVersion = "25.11";
  nix.settings = {
    experimental-features = ["nix-command" "flakes"];
    trusted-users = ["root" "@wheel"];
  };
}
