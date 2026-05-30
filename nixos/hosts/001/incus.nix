{
  users.users.admin.extraGroups = ["incus-admin"]; # expand this with an 'admin' module so we can set users.users.${config.admin}
  # Networking
  networking.nftables.enable = true;
  networking.firewall.interfaces.incusbr0.allowedTCPPorts = [
    53
    67
  ];
  networking.firewall.interfaces.incusbr0.allowedUDPPorts = [
    53
    67
  ];

  # Incus
  virtualisation.incus.enable = true;

  virtualisation.incus.ui.enable = true;
  networking.firewall.allowedTCPPorts = [8443];

  virtualisation.incus.preseed = {
    config = {
      "core.https_address" = ":8443";
    };
    networks = [
      {
        config = {
          "ipv4.address" = "10.0.100.1/24";
          "ipv4.nat" = "true";
        };
        name = "incusbr0";
        type = "bridge";
      }
    ];
    profiles = [
      {
        name = "default";
        devices = {
          eth0 = {
            name = "eth0";
            network = "incusbr0";
            type = "nic";
          };
          # No size here — per-VM root disk size is set per instance in
          # Terraform (terraform/hosts/001/main.tf), which overrides this device.
          # This stays only as a fallback root for any VM that doesn't specify one.
          root = {
            path = "/";
            pool = "default";
            type = "disk";
          };
        };
      }
      {
        name = "lan";
        devices = {
          eth0 = {
            type = "nic";
            name = "eth0";
            nictype = "bridged";
            parent = "br0";
          };
        };
      }
    ];
    storage_pools = [
      {
        config = {
          source = "rpool/incus";
        };
        driver = "zfs";
        name = "default";
      }
    ];
  };
}
