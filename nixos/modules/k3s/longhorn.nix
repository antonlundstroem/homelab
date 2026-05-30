# Longhorn node prerequisites — imported by the always-on k3s storage nodes
# (node01, node02) so each is Longhorn-ready without copy-paste. gpu01 omitted
# for now (intermittent → never a replica host); add the import there if it ever
# becomes always-on. This does NOT deploy Longhorn; the chart is a future gitops
# app (see CLAUDE.md "Storage strategy"). Cost while Longhorn is undeployed is
# effectively zero: open-iscsi with no targets is an idle socket-activated
# daemon, iscsi_tcp is a small module.
{
  config,
  pkgs,
  ...
}: {
  boot.kernelModules = ["iscsi_tcp"];

  services.openiscsi = {
    enable = true;
    # Per-node-unique IQN, derived from hostname so this module is safe to import
    # everywhere. open-iscsi requires a name when enabled; two nodes sharing an
    # IQN breaks Longhorn volume attach/detach.
    name = "iqn.2016-04.com.open-iscsi:${config.networking.hostName}";
  };

  # iscsiadm on k3s's service PATH so Longhorn's manager can find it. `path` is a
  # listOf option → MERGES by concatenation with any other module's additions
  # (e.g. gpu01's nvidia-container-runtime + runc). No mkForce needed.
  systemd.services.k3s.path = [pkgs.openiscsi];

  environment.systemPackages = [pkgs.nfs-utils]; # RWX (NFS-backed) volumes
}
