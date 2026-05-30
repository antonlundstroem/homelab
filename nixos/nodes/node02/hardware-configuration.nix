# Seeded from host001's hardware-configuration.nix — node02 IS that physical box
# (the old host001, repurposed as a baremetal k3s agent). Same board / CPU / NVMe,
# so these modules apply. VERIFY (or regenerate with `nixos-generate-config`) on the
# first install in case anything differs.
{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}: {
  imports = [(modulesPath + "/installer/scan/not-detected.nix")];

  boot.initrd.availableKernelModules = ["xhci_pci" "ahci" "nvme" "usb_storage" "usbhid" "sd_mod"];
  boot.initrd.kernelModules = [];
  boot.kernelModules = ["kvm-intel"];
  boot.extraModulePackages = [];

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  hardware.cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
}
