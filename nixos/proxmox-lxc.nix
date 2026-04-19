{
  lib,
  pkgs,
  ...
}: {
  networking.hostName = lib.mkDefault "lxc";
  networking.useDHCP = lib.mkDefault true;

  nix.settings.trusted-users = ["root" "@wheel"];
  nix.settings.experimental-features = ["nix-command" "flakes"];

  services.avahi.enable = true;
  services.avahi.nssmdns4 = true;
  services.avahi.publish = {
    enable = true;
    addresses = true;
  };

  environment.systemPackages = with pkgs; [
    vim
    git
  ];

  security.sudo.wheelNeedsPassword = false;

  services.openssh = {
    enable = true;
    settings.PasswordAuthentication = false;
    settings.KbdInteractiveAuthentication = false;
  };

  programs.ssh.startAgent = true;

  users.users.admin = {
    isNormalUser = true;
    description = "admin";
    extraGroups = ["wheel"];
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEn6aDAJkpZfBKdrin86mgv97ZqAPg/5PlYRXPDe6B4W home"
    ];
  };

  system.stateVersion = lib.mkDefault "25.11";
}
