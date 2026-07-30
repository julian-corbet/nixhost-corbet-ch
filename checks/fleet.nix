# checks/fleet.nix
#
# `lib/fleet.nix` proven in both directions. Three cross-host checks, each shown to FIRE on a real
# collision and stay SILENT on everything that merely resembles one -- this repo's house rule being
# that an assertion test which cannot fail is worthless.
#
# The near-misses matter more than the hits here, because every one of them is a shape that would
# make the check useless if it over-fired:
#
#   - two hosts that both declare NO disks at all (two nulls must not collide)
#   - one host declaring the same disk twice under two names (that is the per-host module's
#     problem, not a fleet collision, and reporting it here would blame the wrong layer)
#   - a host that declares only a slug (the incremental-adoption property)
#   - the same string appearing as one host's LAN address and another's OVERLAY address (different
#     namespaces; a collision across them is not a conflict)
{ lib, assertFleet }:

let
  check = name: ok: detail: { inherit name ok detail; };

  mkHost = { disks ? { }, net ? { } }: { resources = { storage.disks = disks; inherit net; }; };

  disk = d: { device = d; };

  # ── FIRES ────────────────────────────────────────────────────────────────────────────────
  sharedDisk = assertFleet {
    hosts = {
      alpha = mkHost { disks.primary = disk "/dev/disk/by-id/ata-EXAMPLE_SHARED"; };
      beta = mkHost { disks.other = disk "/dev/disk/by-id/ata-EXAMPLE_SHARED"; };
    };
  };

  sharedLan = assertFleet {
    hosts = {
      alpha = mkHost { net.uplink = { lan = "198.51.100.10"; }; };
      beta = mkHost { net.uplink = { lan = "198.51.100.10"; }; };
    };
  };

  sharedOverlay = assertFleet {
    hosts = {
      alpha = mkHost { net.mesh = { overlay = "203.0.113.5"; }; };
      beta = mkHost { net.mesh = { overlay = "203.0.113.5"; }; };
    };
  };

  # Three hosts on one disk -- the count must be right, not merely non-zero.
  threeWay = assertFleet {
    hosts = lib.genAttrs [ "alpha" "beta" "gamma" ]
      (_: mkHost { disks.primary = disk "/dev/disk/by-id/ata-EXAMPLE_TRIPLE"; });
  };

  # ── STAYS SILENT ─────────────────────────────────────────────────────────────────────────
  distinct = assertFleet {
    hosts = {
      alpha = mkHost {
        disks.primary = disk "/dev/disk/by-id/ata-EXAMPLE_A";
        net.uplink = { lan = "198.51.100.10"; overlay = "203.0.113.10"; };
      };
      beta = mkHost {
        disks.primary = disk "/dev/disk/by-id/ata-EXAMPLE_B";
        net.uplink = { lan = "198.51.100.11"; overlay = "203.0.113.11"; };
      };
    };
  };

  # Two hosts declaring nothing. If `null` were treated as a claimed value both would "collide" on
  # it, and the check would fire on every under-described fleet -- the exact failure that makes a
  # cross-host check unadoptable.
  bothEmpty = assertFleet {
    hosts = { alpha = mkHost { }; beta = mkHost { }; };
  };

  # A host that is only a slug: no `resources` attribute at all.
  slugOnly = assertFleet {
    hosts = { alpha = { }; beta = mkHost { disks.primary = disk "/dev/disk/by-id/ata-EXAMPLE_A"; }; };
  };

  # One host, same disk under two names. A real error, but the per-host module's error -- if this
  # fired here it would report "claimed by 1 hosts" and point the operator at the wrong layer.
  selfDuplicate = assertFleet {
    hosts.alpha = mkHost {
      disks.first = disk "/dev/disk/by-id/ata-EXAMPLE_SAME";
      disks.second = disk "/dev/disk/by-id/ata-EXAMPLE_SAME";
    };
  };

  # The same string as one host's LAN address and another's overlay address. Different namespaces:
  # a LAN address and an overlay address are not in conflict just because they read alike.
  crossNamespace = assertFleet {
    hosts = {
      alpha = mkHost { net.uplink = { lan = "198.51.100.10"; }; };
      beta = mkHost { net.mesh = { overlay = "198.51.100.10"; }; };
    };
  };

  emptyFleet = assertFleet { hosts = { }; };

  firedWith = r: c: lib.any (v: v.check == c) r.violations;

  results = [
    (check "fleet/shared-disk-fires"
      (!sharedDisk.ok && firedWith sharedDisk "disk-claimed-once")
      "two hosts claiming one disk by-id was not reported -- this is the collision that destroys data and that no per-host build can see")

    (check "fleet/shared-disk-names-both-hosts"
      (let v = lib.head sharedDisk.violations; in v.slugs == [ "alpha" "beta" ])
      "the disk collision did not name both claimants; got ${builtins.toJSON (lib.head sharedDisk.violations).slugs}")

    (check "fleet/shared-lan-fires"
      (!sharedLan.ok && firedWith sharedLan "lan-address-unique")
      "two hosts claiming one LAN address was not reported")

    (check "fleet/shared-overlay-fires"
      (!sharedOverlay.ok && firedWith sharedOverlay "overlay-address-unique")
      "two hosts claiming one overlay address was not reported")

    (check "fleet/counts-all-claimants"
      (lib.length threeWay.violations == 1
        && (lib.head threeWay.violations).slugs == [ "alpha" "beta" "gamma" ])
      "three hosts on one disk should be ONE violation naming all three; got ${toString (lib.length threeWay.violations)} violation(s): ${builtins.toJSON (map (v: v.slugs) threeWay.violations)}")

    (check "fleet/distinct-facts-silent"
      distinct.ok
      "a fleet where every disk and address is unique reported violations: ${distinct.message}")

    (check "fleet/two-empty-hosts-silent"
      bothEmpty.ok
      "two hosts that declare no disks and no addresses were reported as colliding -- `null` is being treated as a claimed value, which would make this check fire on every incompletely-described fleet: ${bothEmpty.message}")

    (check "fleet/slug-only-host-silent"
      slugOnly.ok
      "a host with no `resources` attribute at all broke the check instead of being skipped, which forbids adopting this one host at a time: ${slugOnly.message}")

    (check "fleet/self-duplicate-not-a-fleet-violation"
      selfDuplicate.ok
      "one host declaring the same disk under two names was reported as a CROSS-host collision. It is a real error, but the per-host module's error -- reporting it here says `claimed by 1 hosts` and sends the operator to the wrong layer: ${selfDuplicate.message}")

    (check "fleet/lan-and-overlay-are-separate-namespaces"
      crossNamespace.ok
      "the same string used as one host's LAN address and another's overlay address was reported as a conflict; they are different namespaces: ${crossNamespace.message}")

    (check "fleet/empty-fleet-is-ok"
      (emptyFleet.ok && emptyFleet.violations == [ ])
      "an empty fleet did not come back clean")
  ];
in
results
