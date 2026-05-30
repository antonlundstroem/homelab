{
  config,
  pkgs,
  modulesPath,
  lib,
  system,
  ...
}: let
  serialDevice =
    if pkgs.stdenv.hostPlatform.isx86
    then "ttyS0"
    else "ttyAMA0";
in {
  imports = [
    (modulesPath + "/profiles/qemu-guest.nix")
    ../../settings/system/configuration.nix
  ];

  # Builds the qcow2 imported into Incus. Replicates
  # `nixos/modules/virtualisation/incus-virtual-machine.nix` so we own
  # the image config here instead of inheriting upstream defaults.
  system.build.qemuImage = import (modulesPath + "/../lib/make-disk-image.nix") {
    inherit pkgs lib config;
    partitionTableType = "efi";
    format = "qcow2-compressed";
    copyChannel = config.system.installer.channel.enable;
  };

  fileSystems = {
    "/" = {
      device = "/dev/disk/by-label/nixos";
      autoResize = true;
      fsType = "ext4";
    };
    "/boot" = {
      device = "/dev/disk/by-label/ESP";
      fsType = "vfat";
    };
  };

  boot.growPartition = true;
  boot.loader.systemd-boot.enable = true;
  # image-builder needs this to know where to install the bootloader
  boot.loader.grub.device = "/dev/vda";

  boot.kernelParams = [
    "console=tty1"
    "console=${serialDevice}"
  ];

  # CPU hotplug — auto-online newly attached vCPUs
  services.udev.extraRules = ''
    SUBSYSTEM=="cpu", CONST{arch}=="x86-64", TEST=="online", ATTR{online}=="0", ATTR{online}="1"
  '';

  # Incus agent (vsock-based) handles `incus exec`, IP reporting in
  # `incus list`, file push/pull, graceful shutdown — replaces
  # qemu-guest-agent on Incus VMs.
  virtualisation.incus.agent.enable = lib.mkDefault true;

  networking.hostName = lib.mkDefault "base";
  networking.useDHCP = lib.mkDefault true;

  # Enable mDNS for `hostname.local` addresses
  services.avahi.enable = true;
  services.avahi.nssmdns4 = true;
  services.avahi.publish = {
    enable = true;
    addresses = true;
  };

  environment.systemPackages = with pkgs; [
    git # for pulling nix flakes
  ];

  system.stateVersion = lib.mkDefault "25.11";
}
