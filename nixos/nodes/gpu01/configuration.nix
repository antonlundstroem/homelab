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

  # FHS-shaped wrapper so the k8s-device-plugin and gpu-feature-discovery
  # DaemonSets can find libnvidia-ml.so.1 from inside their pods. The plugin's
  # NVML probe (go-nvlib) walks fixed paths under `--container-driver-root`
  # (default /driver-root) — /usr/lib64, /usr/lib/x86_64-linux-gnu, ... — none
  # of which exist in NixOS's driver layout. Pointing the chart's nvidiaDriverRoot
  # at this wrapper makes the host path mount as /driver-root in the pod, with
  # libnvidia-ml.so.1 visible at /driver-root/usr/lib64/...
  #
  # The bind source MUST be the leaf nvidia-x11 store path, NOT /run/opengl-driver/lib
  # (which is an aggregate whose symlinks point to absolute /nix/store/... paths
  # that aren't visible inside the pod). The leaf nvidia-x11/lib uses relative
  # symlinks (libnvidia-ml.so -> libnvidia-ml.so.1 -> libnvidia-ml.so.595.58.03)
  # that resolve within the bind itself, so the probe's filepath.EvalSymlinks
  # succeeds without needing /nix/store mounted.
  #
  # The plugin pod doesn't need /dev/nvidia* at runtime under
  # deviceListStrategy=cdi-annotations: after the probe passes, it reads
  # /var/run/cdi/*.json (mounted) to enumerate devices for kubelet, instead of
  # calling NVML.Init.
  systemd.tmpfiles.rules = [
    "d /var/lib/nvidia-driver-root           0755 root root - -"
    "d /var/lib/nvidia-driver-root/usr       0755 root root - -"
    "d /var/lib/nvidia-driver-root/usr/lib64 0755 root root - -"
  ];
  fileSystems."/var/lib/nvidia-driver-root/usr/lib64" = {
    device = "${config.hardware.nvidia.package}/lib";
    fsType = "none";
    options = ["bind" "ro"];
  };

  services.k3s = {
    enable = true;
    role = "agent";
    serverAddr = "https://${ip}:6443";
    tokenFile = config.sops.secrets.k3s-token.path;

    extraFlags = [
      # NFD/GFD apply the canonical nvidia.com/gpu.* labels; the taint stays
      # so non-GPU workloads can't land here.
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

  environment.systemPackages = with pkgs; [vim git curl];

  system.stateVersion = "25.11";
  nix.settings = {
    experimental-features = ["nix-command" "flakes"];
    trusted-users = ["root" "@wheel"];
  };
}
