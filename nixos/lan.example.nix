# nixos/lan.example.nix — schema for nixos/lan.nix (gitignored).
#
# Values that describe the user's LAN topology. Kept out of git so a public
# repo doesn't leak internal addressing. Same convention as
# .envrc.local / .envrc.local.example.
#
# Bootstrap on a new clone:
#   1. cp nixos/lan.example.nix nixos/lan.nix
#   2. edit nixos/lan.nix with real values
#   3. git add -fN nixos/lan.nix   # --force --intent-to-add so the flake can read it
#
# Nix flakes only see git-tracked files; without step 3 the dns module
# fails with "path nixos/lan.nix does not exist" at evaluation time.

{
  # IP that *.lan should resolve to — typically the cluster's
  # ingress-nginx LoadBalancer service IP (`kubectl -n ingress-nginx
  # get svc ingress-nginx-controller`).
  ingressIp = "10.0.0.10";

  # CIDR of the home LAN that the dns server is allowed to answer.
  # Anything outside this range gets refused (recursion-protection).
  lanCidr = "10.0.0.0/24";
}
