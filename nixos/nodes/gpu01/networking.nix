{...}: let
  lan = import ../../settings/networking/configuration.nix;
in {
  networking.hostName = "gpu01";
  networking.useNetworkd = true;
  networking.useDHCP = false;

  # k3s agent ports — kubelet API and the flannel VXLAN tunnel that carries
  # all cross-node pod traffic. Without 8472 open, pods on gpu01 can't reach
  # CoreDNS (which lives on the server), so every cluster-internal lookup
  # times out.
  networking.firewall.allowedTCPPorts = [10250];
  networking.firewall.allowedUDPPorts = [8472];

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
