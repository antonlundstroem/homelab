{lib, ...}: let
  inherit (import ./lan.nix) k3sIp gateway;
in {
  networking.hostName = lib.mkForce "k3s";

  # Static IP — stable kubeconfig URL + lets us pin the API cert SAN.
  # Picked outside the router's DHCP pool to avoid lease conflicts.
  networking.useDHCP = lib.mkForce false;
  networking.interfaces.ens18.ipv4.addresses = [
    {
      address = k3sIp;
      prefixLength = 24;
    }
  ];
  networking.defaultGateway = gateway;
  networking.nameservers = ["1.1.1.1" "1.0.0.1"];

  services.k3s = {
    enable = true;
    role = "server";
    extraFlags = [
      "--write-kubeconfig-mode=644"
      "--disable=traefik"
      # Add the LAN IP to the API server's TLS cert SAN so kubectl
      # connects without --insecure-skip-tls-verify.
      "--tls-san=${k3sIp}"
      # Force IPv4-only cluster networking. Without these, k3s autodetects
      # the host's IPv6 and assigns pods/services IPv6 IPs that can't
      # escape to the LAN's IPv4 DNS, breaking external resolution from
      # inside pods (Helm installs, ArgoCD, etc.).
      "--cluster-cidr=10.42.0.0/16"
      "--service-cidr=10.43.0.0/16"
    ];

    manifests = {
      ingress-nginx.content = {
        apiVersion = "helm.cattle.io/v1";
        kind = "HelmChart";
        metadata = {
          name = "ingress-nginx";
          namespace = "kube-system";
        };
        spec = {
          chart = "ingress-nginx";
          repo = "https://kubernetes.github.io/ingress-nginx";
          version = "4.15.1";
          targetNamespace = "ingress-nginx";
          createNamespace = true;
          valuesContent = ''
            controller:
              service:
                type: LoadBalancer
              ingressClassResource:
                default: true
          '';
        };
      };

      argocd.content = {
        apiVersion = "helm.cattle.io/v1";
        kind = "HelmChart";
        metadata = {
          name = "argocd";
          namespace = "kube-system";
        };
        spec = {
          chart = "argo-cd";
          repo = "https://argoproj.github.io/argo-helm";
          version = "9.5.2";
          targetNamespace = "argocd";
          createNamespace = true;
          valuesContent = ''
            configs:
              params:
                server.insecure: true
            server:
              ingress:
                enabled: true
                ingressClassName: nginx
                hostname: argocd.lan
          '';
        };
      };

      argocd-root.content = {
        apiVersion = "argoproj.io/v1alpha1";
        kind = "Application";
        metadata = {
          name = "root";
          namespace = "argocd";
        };
        spec = {
          project = "default";
          source = {
            repoURL = "https://github.com/antonlundstroem/homelab.git";
            path = "gitops/argocd";
            targetRevision = "HEAD";
            directory.recurse = true;
          };
          destination = {
            server = "https://kubernetes.default.svc";
            namespace = "argocd";
          };
          syncPolicy = {
            automated = {
              prune = true;
              selfHeal = true;
            };
            syncOptions = ["CreateNamespace=true"];
          };
        };
      };
    };
  };

  networking.firewall.allowedTCPPorts = [
    6443 # kube API
    10250 # kubelet
    80 # ingress-nginx HTTP
    443 # ingress-nginx HTTPS
  ];
  networking.firewall.allowedUDPPorts = [
    8472 # flannel VXLAN
  ];

  swapDevices = lib.mkForce [];
}
