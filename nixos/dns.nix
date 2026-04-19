{lib, ...}: let
  ingressIp = "192.168.1.139"; # k3s ingress-nginx LB IP
  lanCidr = "192.168.1.0/24";
in {
  networking.hostName = lib.mkForce "dns";

  services.unbound = {
    enable = true;
    settings = {
      server = {
        interface = ["0.0.0.0" "::"];
        access-control = [
          "${lanCidr} allow"
          "127.0.0.0/8 allow"
          "::1/128 allow"
        ];
        local-zone = [''"lan." redirect''];
        local-data = [''"lan. IN A ${ingressIp}"''];
      };
      forward-zone = [
        {
          name = ".";
          forward-addr = ["1.1.1.1" "1.0.0.1"];
        }
      ];
    };
  };

  networking.firewall.allowedTCPPorts = [53];
  networking.firewall.allowedUDPPorts = [53];
}
