# Synthesizes N hosts of fleet facts as PLAIN DATA -- an ordinary attrset built by
# `builtins.listToAttrs`, no `lib.evalModules`, no options, no fixpoint. This is the shape the
# design spec's hard rule requires (`../../../nixhost-spec.md`'s "REQUIRED" block): a fact tree
# that evaluates with no module system at all, so reading `hosts.hostN.<fact>` forces only that
# one host's thunk and nothing else.
#
# { n, collide ? null }:
#   n       -- host count to synthesize.
#   collide -- null (default, all facts unique) | "ip" | "disk". Forces host1's address or disk
#              by-id to collide with host0's, so fleet-assert.nix's assertion can be proven in
#              BOTH directions (fires when violated, silent when satisfied) -- a study measuring
#              cost is worthless if it never checks the thing it costs to compute is also
#              correct.
{ n, collide ? null }:
let
  range = builtins.genList (i: i) n;

  mkHost = i: {
    name = "host${toString i}";
    value = {
      cpu = {
        arch = "x86_64";
        microarch = "x86_64-v3";
        cores = 16;
        threads = 32;
      };
      ram.totalMiB = 65536;
      net.lan0.addresses.lan =
        if collide == "ip" && i == 1 then
          "198.51.100.1" # deliberately == host0's own address, below
        else
          "198.51.100.${toString (i + 1)}"; # unique per host; N stays <= 250 so one octet suffices
      storage.disks.disk0.byId =
        if collide == "disk" && i == 1 then
          "ata-DISK-host0-0" # deliberately == host0's own by-id, below
        else
          "ata-DISK-host${toString i}-0";
    };
  };
in
builtins.listToAttrs (map mkHost range)
