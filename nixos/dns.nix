{lib, ...}: let
  inherit (import ./lan.nix) ingressIp lanCidr;
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
