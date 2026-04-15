{lib, ...}: {
  networking.hostName = lib.mkForce "k3s";

  services.k3s = {
    enable = true;
    role = "server";
    extraFlags = [
      "--write-kubeconfig-mode=644"
      "--disable=traefik"
    ];
  };

  networking.firewall.allowedTCPPorts = [
    6443 # kube API
    10250 # kubelet
  ];
  networking.firewall.allowedUDPPorts = [
    8472 # flannel VXLAN
  ];

  swapDevices = lib.mkForce [];
}
