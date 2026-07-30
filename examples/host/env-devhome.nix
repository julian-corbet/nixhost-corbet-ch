# A tenant that is NOT a substrate: processes on the metal.
#
# `kind = "native"` exists for exactly this -- a desktop session, a compositor, a build daemon,
# anything in the host's own cgroup hierarchy rather than inside a container, VM or cluster. The
# other four kinds all describe something that CONTAINS workloads, which meant the one tenant on a
# mixed host that contains nothing was the one tenant with no address, and its claims silently did
# not exist for the arithmetic.
#
# It is summed like any other claimant. What it does not do is project further: `environments`
# beneath it stays empty, because a process on the metal has nothing inside it.
{ ... }:
{
  nixhost.environments.devhome = {
    kind = "native";

    resources = {
      ram.limitMiB = 4096;
      cpu.quotaCores = 2;

      # Declared `none` rather than omitted, and the difference is the point: `none` is the
      # default, so omitting it would mean the same thing to the checker -- but it would not say
      # so to a reader. A session that must never touch the card is a deliberate stance worth
      # writing down, not an absence.
      gpu.gpu0.access = "none";
    };
  };
}
