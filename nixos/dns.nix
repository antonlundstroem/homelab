{lib, ...}: let
  inherit (import ./lan.nix) ingressIp lanCidr dnsIp gateway;
in {
  networking.hostName = lib.mkForce "dns";

  # Static IP — DNS infra must not be on a leased address. Picked
  # outside the router's DHCP pool so no other client can grab it.
  networking.useDHCP = lib.mkForce false;
  networking.interfaces.ens18.ipv4.addresses = [
    {
      address = dnsIp;
      prefixLength = 24;
    }
  ];
  networking.defaultGateway = gateway;
  networking.nameservers = ["1.1.1.1" "1.0.0.1"];

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
