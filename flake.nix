{
  description = "nixhost -- the namespace root: one host addressed as a path (name.cpu.cores, name.storage.disks.solid0), the environments standing on it declared as PROJECTIONS of its own hardware, and the arithmetic nothing else in this family does today -- does an environment's claimed RAM/CPU/GPU exceed what the host actually has. Pure data -- no systemd units, no packages, nothing that runs.";

  inputs = {
    # Used by `checks` only. The module itself takes no `pkgs` argument and never references
    # this input, so a consumer that does not follow it pays no second nixpkgs.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    # Also used by `checks` only (backend-parity eval tests) -- the module itself is exported
    # unchanged for both backends, see modules/nixhost.nix's own header for why that costs
    # nothing to be true here.
    system-manager.url = "github:numtide/system-manager";
    system-manager.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, system-manager }:
    let
      lib = nixpkgs.lib;
      supportedSystems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = lib.genAttrs supportedSystems;
      pkgsFor = system: import nixpkgs { inherit system; };
    in
    {
      # ---------------------------------------------------------------
      # The same file on every backend -- not a convenience, the whole point. This module has
      # no `pkgs` argument and does nothing but declare options and assertions, so there is no
      # backend-specific installer to write and nothing for the backends to disagree about. See
      # modules/nixhost.nix's own header for the "pure data" boundary this rests on.
      #
      # `darwinModules` is not backed by a nix-darwin input or a check in this repo's own CI --
      # pulling one in would give this namespace root a dependency on a much larger closure for
      # a module that touches nothing nix-darwin-specific. nix-darwin's own module system
      # accepts the same bare `options`/`config.assertions` primitives this file uses and
      # nothing else, so the alias is offered as-is rather than omitted on the strength of an
      # equally untested claim in the other direction -- see experiments/README.md.
      # ---------------------------------------------------------------
      nixosModules.nixhost = ./modules/nixhost.nix;
      nixosModules.default = self.nixosModules.nixhost;
      systemManagerModules.nixhost = ./modules/nixhost.nix;
      systemManagerModules.default = self.systemManagerModules.nixhost;
      darwinModules.nixhost = ./modules/nixhost.nix;
      darwinModules.default = self.darwinModules.nixhost;

      # ---------------------------------------------------------------
      # The CROSS-HOST half, and deliberately a plain function rather than a module.
      #
      # Everything above validates one host against itself. `lib.assertHosts` validates hosts
      # against each other -- and per-host validity is not validity across hosts: two hosts can each be
      # correct by every assertion either can make about itself while both claim the same physical
      # disk. No module can catch that, because from inside either host nothing is wrong.
      #
      # It is a function over PLAIN DATA, never over evaluated configurations, and this repo
      # measured why (`studies/eval-cost/`): reading every host's facts through the module system
      # is the one read shape that goes nonlinear, putting a 100-host cross-host assertion at
      # roughly 2.6 hours against ~0.05 s for the same assertion over plain data.
      #
      # The VALUES it checks are not here and never will be -- this repo is public. The tree is
      # assembled privately and passed in, exactly as `nixiam`'s uid/gid table is filled by whoever
      # imports it.
      # ---------------------------------------------------------------
      lib = {
        assertHosts = (import ./lib/hosts.nix { inherit lib; }).assertHosts;
      };

      checks = forAllSystems (system:
        import ./checks {
          pkgs = pkgsFor system;
          inherit lib nixpkgs system;
          nixhostModule = self.nixosModules.nixhost;
          systemManagerLib = system-manager.lib;
          assertHosts = self.lib.assertHosts;
        });

      formatter = forAllSystems (system: (pkgsFor system).nixpkgs-fmt);
    };
}
