# The tiny option surface the contrast fixture (gen-nixos-hosts.nix) declares on top of
# nixpkgs's own default nixosSystem module list, so its evaluated config carries the SAME three
# facts gen-plain-hosts.nix produces as plain data (ram total, one LAN address, one disk by-id) --
# nothing more. Deliberately NOT modules/nixhost.nix: this study must not touch that file or the
# real module it measures the cost of avoiding.
{ lib, ... }:
{
  options.myFacts = lib.mkOption {
    type = lib.types.attrsOf lib.types.anything;
    default = { };
    description = ''
      Stand-in fact bag for this study only. Scoped here rather than reusing nixhost's own
      `resources` option so that a change to the real module's shape can never silently change
      what this benchmark measures.
    '';
  };
}
