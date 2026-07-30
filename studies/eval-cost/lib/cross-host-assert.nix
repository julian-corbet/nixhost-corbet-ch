# A genuine cross-host assertion over the plain-data tree: no two hosts share a LAN address; no
# two hosts share a disk by-id. This is the "arithmetic nothing else does today" nixhost's own
# README promises, exercised at estate scale rather than the two-or-three-fixture size
# `../../../checks/default.nix` proves the real module's assertions at.
#
# Deliberately keyed-dedup (`acc // { ${k} = ...; }` over a fold), not a pairwise
# `lib.lists.unique`-style O(n^2) compare -- the point of this study is cross-host-eval cost, and an
# assertion written the slow way would measure its own algorithm, not the cost this study is
# actually after (the same reasoning nixhost's own RAM/CPU oversubscription checks already apply
# by summing claimants once rather than comparing every pair).
{ hosts }:
let
  hostList = builtins.attrValues hosts;

  # fact -> [names of every host that claims it]
  collect = extract:
    builtins.foldl'
      (acc: h:
        let k = extract h; in
        acc // { ${k} = (acc.${k} or [ ]) ++ [ h.name ]; }
      )
      { }
      hostList;

  duplicatesOf = claims:
    builtins.filter (k: builtins.length claims.${k} > 1) (builtins.attrNames claims);

  ipClaims = collect (h: h.net.lan0.addresses.lan);
  diskClaims = collect (h: h.storage.disks.disk0.byId);

  ipDuplicates = duplicatesOf ipClaims;
  diskDuplicates = duplicatesOf diskClaims;
in
{
  inherit ipDuplicates diskDuplicates;
  ok = ipDuplicates == [ ] && diskDuplicates == [ ];
}
