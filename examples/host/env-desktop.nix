# One tenant, declaring itself.
#
# This file contributes a single node to `nixhost.environments` and knows nothing else about the
# host -- not the RAM total, not the core count, not which other tenants exist. That is the whole
# point of the shape: `environments` is an `attrsOf submodule`, so the module system merges
# contributions from as many files as there are tenants, and the arithmetic in
# modules/nixhost.nix then aggregates UPWARD and compares the sum against the mirrored ceiling.
#
# The direction matters. Nothing here divides a budget: this workload states what it wants, and
# the check either passes or names this node as part of an overcommit. A file that instead
# received "your share is 8192" would have to be rewritten every time a sibling changed, and would
# go stale silently the moment the host's RAM did.
{ ... }:
{
  nixhost.environments.desktop-workload = {
    kind = "podman";

    resources = {
      ram.limitMiB = 8192;
      cpu.quotaCores = 4;

      # `shared` on the one card declared at the host level. Shared claims co-reside with any
      # number of other shared claims, so this file does not need to know who else wants the GPU
      # -- only that it is not asking to be alone with it. An `exclusive` claim WOULD conflict
      # with a sibling's, and that is caught by the flattened GPU check regardless of which file
      # either claim was written in.
      gpu.gpu0.access = "shared";
    };
  };
}
