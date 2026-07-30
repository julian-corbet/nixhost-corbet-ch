# lib/hosts.nix -- `lib.assertHosts`
#
# THE CROSS-HOST LAYER, and deliberately nothing else. `modules/nixhost.nix` already validates one
# host against itself -- RAM and CPU oversubscription, GPU exclusivity, arch/microarch agreement --
# and none of that is repeated here. This file implements only the checks a per-host module
# CANNOT make, which is a much shorter list than it first appears.
#
# ── PER-HOST VALIDITY IS NOT VALIDITY ACROSS HOSTS. This is the entire argument. ───────────────
#
# Two hosts can each declare a configuration that is correct by every assertion either one is able
# to make about itself, while both claim the SAME physical disk by-id. Both builds pass. Both hosts
# then open, format, or write that disk. No module can catch it, because from inside either host
# nothing is wrong -- the fact that makes it wrong lives in the other host's configuration. Only a
# read across hosts sees it, and by the time the consequence appears it is destroyed data rather
# than a failed build.
#
# The address checks are the same shape with a milder outcome: a duplicated address is a silently
# unreachable service rather than a lost pool. Same structure, same blindness, lower cost.
#
# That is the whole file. Three checks, all of the form "one fact, two claimants".
#
# ── WHY A PLAIN FUNCTION OVER PLAIN DATA, measured ──────────────────────────────────────────
#
# The NixOS module system has no partial evaluation: touching `config.<anything>` forces the entire
# fixpoint. So a module reading a fact out of ANOTHER host's evaluated configuration pays for that
# host's whole evaluation. Measured for this repo (`studies/eval-cost/`, N = 1..250, 7 reps,
# `NIX_SHOW_STATS` per run):
#
#     plain-data tree, incl. a genuine cross-host assertion : ~0.02-0.05 s wall, FLAT to N=250
#     ONE host's fact among N evaluated hosts               : also flat -- laziness does hold here
#     EVERY host's fact, i.e. exactly this file's job       : the nonlinear case
#
# The third row is why this is a function and not a module. A single cross-host lookup survives the
# module system; a cross-host read does not. A deliberately trivial fixture already costs ~0.6 s
# cpuTime and ~843,700 thunks at N=1 (146x the thunks of the heaviest plain-data case at N=250),
# and a real fully-loaded host config measures 95.1 s -- putting a 100-host cross-host assertion at
# roughly 2.6 HOURS against ~0.05 s for the same assertion over plain data. This is the wall NixOps
# hit and that colmena and deploy-rs deliberately walked away from.
#
# ── WHAT THIS FILE IS NOT ───────────────────────────────────────────────────────────────────
#
# It declares no fact, reads no `config`, imports no other repo, and touches no disk, unit or
# package. It also does not hold VALUES: this repo is public, so the tree is assembled privately
# and passed in -- the same division `nixid`'s uid/gid table already uses.
#
# ── THE TREE IT EXPECTS ─────────────────────────────────────────────────────────────────────
#
#   hosts.<slug>.resources = {
#     storage.disks.<name> = { device = "/dev/disk/by-id/..."; };
#     net.<name>           = { lan = "..."; overlay = "..."; };
#   };
#
# EVERY field is optional, and that is a deliberate adoption property rather than laxity: a tree
# containing a host that declares only a slug must produce zero violations, not an evaluation
# error. A cross-host check that crashes on a partially-described host cannot be adopted one host at a
# time, which means it is a check nobody adopts. It also lets the tree describe hosts that have no
# NixOS module at all -- a laptop, a router, an appliance -- which is precisely where a duplicated
# address is most likely to come from.
{ lib }:

let
  # Keyed dedup in ONE pass, deliberately not a pairwise compare: a cross-host check written O(n^2)
  # measures its own algorithm rather than the estate, and past 100 hosts that stops being academic.
  # fact value -> [ every slug claiming it ]
  claimants = extract: hosts:
    lib.foldl'
      (acc: slug:
        lib.foldl'
          (inner: key: inner // { ${key} = (inner.${key} or [ ]) ++ [ slug ]; })
          acc
          (extract hosts.${slug}))
      { }
      (lib.attrNames hosts);

  # ⚠ DEDUPE THE SLUGS, not just count the claims. Caught by this file's own near-miss test on
  # first run: a host declaring the same disk under two names appends its slug TWICE, so a naive
  # `length > 1` reported `claimed by 2 hosts (alpha, alpha)` -- a cross-host collision that does
  # not exist, blaming the wrong layer for a real but intra-host error. That error belongs to the
  # per-host disk table, which already refuses it (`nixstorage.disks` asserts on duplicate device
  # paths); this file must stay silent on it or two layers report one problem differently.
  contested = claims:
    lib.filter (k: lib.length (lib.unique claims.${k}) > 1) (lib.attrNames claims);

  # `or { }` at every level is the incomplete-host property from the header, not habit.
  disksOf = h: lib.mapAttrsToList (_: d: d.device or null) (h.resources.storage.disks or { });
  addrsOf = field: h: lib.mapAttrsToList (_: n: n.${field} or null) (h.resources.net or { });

  # A null means "this host did not declare this fact", which is not a claim and must never
  # collide with another host's null.
  declared = lib.filter (v: v != null);

  contestedFacts = hosts: check: extract: consequence:
    let claims = claimants (h: declared (extract h)) hosts; in
    map
      (key:
        let who = lib.unique claims.${key}; in
        {
          inherit check;
          fact = key;
          slugs = who;
          detail = "`${key}` is claimed by ${toString (lib.length who)} hosts (${lib.concatStringsSep ", " who}). ${consequence}";
        })
      (contested claims);
in
{
  # Returns `{ ok; violations; message; }` rather than throwing, so a caller renders the whole list
  # at once instead of repairing the hosts one aborted evaluation at a time.
  assertHosts = { hosts }:
    let
      violations =
        contestedFacts hosts "disk-claimed-once" disksOf
          "DATA LOSS RISK: two hosts writing one physical disk. Neither host's own build can detect this -- the fact that makes it wrong is in the other host's configuration."
        ++ contestedFacts hosts "lan-address-unique" (addrsOf "lan")
          "One of them will be unreachable, silently and non-deterministically, depending on which claimed the address most recently."
        ++ contestedFacts hosts "overlay-address-unique" (addrsOf "overlay")
          "Overlay peers resolve by address; a duplicate routes traffic to whichever peer the coordinator saw last.";
    in
    {
      inherit violations;
      ok = violations == [ ];

      # Pre-rendered because the caller that needs this is an `assertion`/`message` pair, and every
      # caller would otherwise write the same fold.
      message = lib.concatMapStringsSep "\n"
        (v: "  - [${v.check}] ${v.fact}: ${v.detail}")
        violations;
    };
}
