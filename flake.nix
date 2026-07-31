{
  description = "nixhost -- the namespace root: one host addressed as a path (name.cpu.cores, name.storage.disks.solid0), the environments standing on it declared as PROJECTIONS of its own hardware, and the arithmetic nothing else in this family does today -- does an environment's claimed RAM/CPU/GPU exceed what the host actually has. Pure data -- no systemd units, no packages, nothing that runs.";

  inputs = {
    # checks-only: the module itself takes no `pkgs` and never references this input, so a
    # consumer that doesn't follow it pays no second nixpkgs.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    # checks-only: backend-parity eval tests. The module is exported unchanged for both backends.
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
      # One file for all three backends: no `pkgs` argument, only options/assertions, so there is
      # no backend-specific installer to write. `darwinModules` has no nix-darwin input or CI
      # check here (would pull in a much larger closure for nothing darwin-specific), offered
      # as-is because nix-darwin's module system accepts the same bare options/assertions.
      nixosModules.nixhost = ./modules/nixhost.nix;
      nixosModules.default = self.nixosModules.nixhost;
      systemManagerModules.nixhost = ./modules/nixhost.nix;
      systemManagerModules.default = self.systemManagerModules.nixhost;
      darwinModules.nixhost = ./modules/nixhost.nix;
      darwinModules.default = self.darwinModules.nixhost;

      # The CROSS-HOST half, deliberately a plain function rather than a module. Everything above
      # validates one host against itself; `lib.assertHosts` validates hosts against each other --
      # two hosts can each be correct by every assertion either makes about itself while both
      # claim the same physical disk, and no module can catch that from inside either host.
      #
      # A function over PLAIN DATA, never over evaluated configurations: `studies/eval-cost/`
      # measured that reading every host's facts through the module system is the one read shape
      # that goes nonlinear, putting a 100-host cross-host assertion at ~2.6 hours against ~0.05s
      # for the same assertion over plain data.
      #
      # The VALUES it checks are not here and never will be -- this repo is public. The tree is
      # assembled privately and passed in, exactly as `nixiam`'s uid/gid table is filled by whoever
      # imports it.
      lib = {
        assertHosts = (import ./lib/hosts.nix { inherit lib; }).assertHosts;

        # The CROSS-NAMESPACE half: a defensive `config.nixfoo.bar or fallback` read cannot tell
        # "nixfoo is not composed here" from "nixfoo is composed but `bar` moved, was renamed, or
        # was rejected by its own type" -- both land on the same fallback with no trace of which
        # happened, and the second is a silent defect, not a supported state. `lib.probeFact` is
        # the fix, built once here rather than reinvented per-repo (see `lib/facts.nix` for the
        # defect class and the two evaluation traps a naive fix falls into). A plain function over
        # `config`/plain data, like `assertHosts` above: forces nothing NixOS-specific and costs
        # nothing when the namespace was never composed (`checks/facts.nix` proves this against a
        # namespace whose own value would throw if forced at all).
        inherit (import ./lib/facts.nix { inherit lib; }) probeFact collectProbes;
      };

      checks = forAllSystems (system:
        import ./checks {
          pkgs = pkgsFor system;
          inherit lib nixpkgs system;
          nixhostModule = self.nixosModules.nixhost;
          systemManagerLib = system-manager.lib;
          assertHosts = self.lib.assertHosts;
          probeFact = self.lib.probeFact;
          collectProbes = self.lib.collectProbes;
        });

      formatter = forAllSystems (system: (pkgsFor system).nixpkgs-fmt);
    };
}
