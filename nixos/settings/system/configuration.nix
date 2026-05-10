{
  nix.settings.experimental-features = ["nix-command" "flakes"];

  # Enable ssh
  services.openssh = {
    enable = true;
    settings.PasswordAuthentication = false;
    settings.KbdInteractiveAuthentication = false;
  };

  programs.ssh.startAgent = true;

  # Admin user
  users.users.admin = {
    isNormalUser = true;
    description = "admin";
    extraGroups = ["wheel"];
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEn6aDAJkpZfBKdrin86mgv97ZqAPg/5PlYRXPDe6B4W home"
    ];
  };

  nix.settings.trusted-users = ["root" "@wheel"];

  security.sudo.wheelNeedsPassword = false;
}
