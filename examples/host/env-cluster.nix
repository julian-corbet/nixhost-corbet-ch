# The cluster node, declaring itself -- see env-desktop.nix for why each tenant gets its own file.
#
# In a real configuration this file is the one a Kubernetes-side module would own: whatever repo
# manages the cluster knows what the node reserves, and can contribute that node here without
# touching either the host's facts or any other tenant's claim.
{ ... }:
{
  nixhost.environments.cluster-node = {
    kind = "k3s";

    resources = {
      ram.limitMiB = 49152;
      cpu.quotaCores = 10;
      gpu.gpu0.access = "shared";
    };

    # `environments` beneath this node is available and left empty. A k3s node genuinely does
    # contain things (pods), so unlike the native tenant it is a real substrate -- but pod-level
    # claims are managed by the cluster's own admission machinery, and restating them here would
    # be a second copy of a number kubelet already enforces.
  };
}
