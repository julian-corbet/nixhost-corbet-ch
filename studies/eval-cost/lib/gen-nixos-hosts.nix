# CONTRAST fixture only -- see ../README.md. The SAME three facts gen-plain-hosts.nix produces
# as plain data, here sourced from a genuinely evaluated `lib.nixosSystem` per host instead: the
# full stock nixpkgs module list (~400 modules covering boot, systemd, users, networking, ...)
# plus exactly one extra module of ours (facts-options.nix). This is deliberately the MINIMUM a
# real host could be while still being a real NixOS module-system evaluation, per the design
# spec's own instruction ("use a minimal nixosSystem so this is honest about what it measures").
#
# It is NOT a floor on real-world cost, and this file must not be read as one: an actual estate
# host also imports nixk3s/nixgpu/nixstorage/nixboot/... and dozens of enabled services, each
# contributing its own option surface on top of what this fixture pays for. See README.md for
# why the gap between what this measures and the design spec's own 95.1s/host figure is exactly
# the "trivial config understates real cost" the task asked to flag, not a discrepancy to
# resolve.
#
# { n, collide ? null, nixpkgsRef ? ... }:
#   n          -- host count (this study only exercises 1, 3, 5 here -- see README.md for why
#                 larger N is extrapolated, not measured, for this branch).
#   collide    -- same meaning as gen-plain-hosts.nix's own arg, for the both-directions proof.
#   nixpkgsRef -- a flake reference string. Defaults to the exact rev ../../../flake.lock (the
#                 nixhost repo root's own lockfile -- this file lives two levels under it, at
#                 studies/eval-cost/lib/) already resolves nixpkgs to, read directly from that
#                 lockfile below (not copy-pasted by hand) so the two branches this study
#                 compares always eval against the SAME nixpkgs even after `nix flake update`
#                 moves the pin -- a stale hand-copied rev here would silently start comparing
#                 two different nixpkgs revisions and no longer isolate "plain data vs.
#                 evaluated config" as the only variable.
{ n
, collide ? null
, nixpkgsRef ? (
    let
      locked = (builtins.fromJSON (builtins.readFile ../../../flake.lock)).nodes.nixpkgs.locked;
    in
    "github:${locked.owner}/${locked.repo}/${locked.rev}"
  )
}:
let
  npkgs = builtins.getFlake nixpkgsRef;
  lib = npkgs.lib;

  factsFor = i: {
    ram.totalMiB = 65536;
    net.lan0.addresses.lan =
      if collide == "ip" && i == 1 then
        "198.51.100.1"
      else
        "198.51.100.${toString (i + 1)}";
    storage.disks.disk0.byId =
      if collide == "disk" && i == 1 then
        "ata-DISK-host0-0"
      else
        "ata-DISK-host${toString i}-0";
  };

  mkHost = i: {
    name = "host${toString i}";
    value = lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ./facts-options.nix
        {
          myFacts = factsFor i;
          system.stateVersion = "24.05";
        }
      ];
    };
  };
in
builtins.listToAttrs (map mkHost (builtins.genList (i: i) n))
