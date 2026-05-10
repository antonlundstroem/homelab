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
          root = {
            path = "/";
            pool = "default";
            size = "50GiB";
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
