{modulesPath, ...}: {
  imports = [
    "${modulesPath}/profiles/qemu-guest.nix"
  ];

  boot.loader.grub = {
    enable = true;
    device = "/dev/vda";
  };

  networking.hostName = "nixos";
  networking.useDHCP = true;

  services.openssh = {
    enable = true;
    settings.PermitRootLogin = "prohibit-password";
  };

  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEn6aDAJkpZfBKdrin86mgv97ZqAPg/5PlYRXPDe6B4W home"
  ];

  system.stateVersion = "25.11";
}
