{...}: let
  lan = import ../../settings/networking/configuration.nix;
in {
  networking.hostName = "gpu01";
  networking.useNetworkd = true;
  networking.useDHCP = false;

  systemd.network = {
    enable = true;
    networks."10-lan" = {
      matchConfig.Name = "enp39s0";
      address = ["${lan.nodes.gpu01.ip}/24"];
      gateway = [lan.gateway];
      dns = ["1.1.1.1" "9.9.9.9"];
      networkConfig.IPv6AcceptRA = true;
      linkConfig.RequiredForOnline = "routable";
    };
  };
}
