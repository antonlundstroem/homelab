{
  ### Needed by ZFS
  networking.hostId = "856d208d";
  #################

  networking.hostName = "host001";

  networking.networkmanager.enable = false;
  networking.useNetworkd = true;
  networking.useDHCP = false;

  systemd.network = {
    enable = true;

    netdevs."20-br0" = {
      netdevConfig = {
        Kind = "bridge";
        Name = "br0";
      };
    };

    networks = {
      "30-enp0s31f6" = {
        matchConfig.Name = "enp0s31f6";
        networkConfig.Bridge = "br0";
        linkConfig.RequiredForOnline = "enslaved";
      };

      "40-br0" = {
        matchConfig.Name = "br0";
        networkConfig = {
          DHCP = "ipv4";
          IPv6AcceptRA = true;
        };
        linkConfig.RequiredForOnline = "routable";
      };
    };
  };
}
