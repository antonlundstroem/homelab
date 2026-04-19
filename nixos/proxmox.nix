{
  config,
  pkgs,
  modulesPath,
  lib,
  system,
  ...
}: {
  imports = [
    (modulesPath + "/profiles/qemu-guest.nix")
  ];

  config = {
    #Provide a default hostname
    networking.hostName = lib.mkDefault "base";
    networking.useDHCP = lib.mkDefault true;

    # Enable QEMU Guest for Proxmox
    services.qemuGuest.enable = lib.mkDefault true;

    # Install grub to the virtual disk's MBR so SeaBIOS can boot.
    # Must be /dev/vda — make-disk-image (used by system.build.images.qemu)
    # presents the install disk over virtio. Pair this with a virtio disk
    # interface in the Terraform VM resource so future nixos-rebuilds also find it.
    boot.loader.grub.enable = lib.mkDefault true;
    boot.loader.grub.devices = ["/dev/vda"];

    boot.growPartition = lib.mkDefault true;

    # Allow remote updates with flakes and non-root users
    nix.settings.trusted-users = ["root" "@wheel"];
    nix.settings.experimental-features = ["nix-command" "flakes"];

    # Enable mDNS for `hostname.local` addresses
    services.avahi.enable = true;
    services.avahi.nssmdns4 = true;
    services.avahi.publish = {
      enable = true;
      addresses = true;
    };

    # Some sane packages we need on every system
    environment.systemPackages = with pkgs; [
      vim # for emergencies
      git # for pulling nix flakes
    ];

    # Don't ask for passwords
    security.sudo.wheelNeedsPassword = false;

    # Enable ssh
    services.openssh = {
      enable = true;
      settings.PasswordAuthentication = false;
      settings.KbdInteractiveAuthentication = false;
    };

    programs.ssh.startAgent = true;

    # Default filesystem
    fileSystems."/" = lib.mkDefault {
      device = "/dev/disk/by-label/nixos";
      autoResize = true;
      fsType = "ext4";
    };

    users.users.admin = {
      isNormalUser = true;
      description = "admin";
      extraGroups = ["wheel"];
      openssh.authorizedKeys.keys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEn6aDAJkpZfBKdrin86mgv97ZqAPg/5PlYRXPDe6B4W home"
      ];
    };

    system.stateVersion = lib.mkDefault "25.11";
  };
}
