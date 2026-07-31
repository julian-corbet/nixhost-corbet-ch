# checks/facts-integration.nix
#
# `checks/facts.nix` proves `lib.probeFact` at the function level, against plain attrsets standing
# in for `config` -- deliberately, since the function touches nothing module-system-specific. This
# file is the companion that composes it against a REAL NixOS module evaluation instead, for the
# two things a plain-data fixture cannot show on its own:
#
#   1. A genuinely mandatory, no-default option (`nixcpu.cores`, reusing the exact stub
#      `checks/domain-stubs.nix` already supplies for `modules/nixhost.nix`'s own mirrors) really
#      does throw "used but not defined" from inside the module system when read and never given a
#      value -- not a hand-written stand-in throw, the real one.
#
#   2. Requirement 4, concretely: answering state (a) must not cost a system eval. This file
#      builds one NixOS configuration with an UNRELATED module whose own assertion genuinely
#      fails, so `config.system.build.toplevel` itself throws -- and then proves `probeFact`,
#      asked about a namespace that is absent from THIS SAME config, still reports "absent"
#      without ever touching `system.build.toplevel` at all.
{ pkgs, lib, nixpkgs, system, probeFact }:

let
  check = name: ok: detail: { inherit name ok detail; };

  domainStubs = import ./domain-stubs.nix { inherit lib; };

  nixosBase = [
    {
      boot.loader.grub.enable = false;
      fileSystems."/" = { device = "none"; fsType = "tmpfs"; };
      system.stateVersion = "25.05";
    }
  ];

  evalNixosWith = modules:
    (import (nixpkgs + "/nixos/lib/eval-config.nix") {
      inherit system;
      modules = modules ++ nixosBase;
    }).config;

  # ══ Fixture 1: nixcpu genuinely composed, `cores` genuinely never set ═══════════════════════
  #
  # `domainStubs` declares `nixcpu.cores` with no default, exactly as the real nixcpu does (see
  # that file's own header on why that fidelity is the point) -- so this config's own
  # `config.nixcpu.cores` really is the module system's own throwing thunk, not a stand-in.
  cfgMandatoryUnset = evalNixosWith [ domainStubs { nixcpu.arch = "x86_64"; } ];

  mandatoryUnsetProbe = probeFact {
    config = cfgMandatoryUnset;
    namespace = "nixcpu";
    path = [ "cores" ];
    fallback = null;
  };

  # ══ Fixture 2: nixcpu genuinely composed, `arch` genuinely set -- must resolve cleanly ═══════
  cfgResolved = evalNixosWith [ domainStubs { nixcpu = { arch = "x86_64"; cores = 16; }; } ];

  resolvedProbe = probeFact {
    config = cfgResolved;
    namespace = "nixcpu";
    path = [ "cores" ];
    fallback = null;
  };

  # ══ Fixture 3: nixcpu not imported here at all, ALONGSIDE an unrelated module that genuinely
  # fails its own assertion -- so system.build.toplevel for this config is not buildable. ═══════
  brokenSiblingModule = {
    options.someUnrelatedThing.enable = lib.mkEnableOption "a module with nothing to do with nixcpu";
    config.assertions = [{
      assertion = false;
      message = "deliberately broken, for this fixture's own requirement-4 proof -- never a real failure";
    }];
  };

  cfgAbsentWithBrokenSibling = evalNixosWith [ brokenSiblingModule ];

  toplevelActuallyFails =
    !(builtins.tryEval (builtins.seq cfgAbsentWithBrokenSibling.system.build.toplevel true)).success;

  absentProbeDespiteBrokenSibling = probeFact {
    config = cfgAbsentWithBrokenSibling;
    namespace = "nixcpu";
    path = [ "cores" ];
    fallback = "no-cpu-fact-here";
  };

  # ══ Fixture 4: a genuine rename inside a real module -- `nixcpu` composed, but the stub used
  # here declares `coreCount`, not `cores`, so `config.nixcpu` is real and populated while the
  # OLD path this call still asks for is genuinely gone. ═══════════════════════════════════════
  renamedStub = { lib, ... }: {
    options.nixcpu.coreCount = lib.mkOption {
      type = lib.types.ints.positive;
      default = 16;
      description = "Stand-in for nixcpu having renamed `cores` to `coreCount` upstream.";
    };
  };

  cfgRenamed = evalNixosWith [ renamedStub ];

  renamedProbe = probeFact {
    config = cfgRenamed;
    namespace = "nixcpu";
    path = [ "cores" ];
    fallback = null;
  };

  results = [
    (check "facts-integration/real-mandatory-unset-option-reports-unresolved"
      (mandatoryUnsetProbe.state == "unresolved")
      "a REAL NixOS module's own required-with-no-default option (nixcpu.cores), genuinely never given a value, must be reported as \"unresolved\" through the module system's own throw -- not a hand-written stand-in")

    (check "facts-integration/real-mandatory-unset-warns-with-the-real-option-path"
      (lib.length mandatoryUnsetProbe.warnings == 1
        && lib.hasInfix "nixcpu.cores" (lib.head mandatoryUnsetProbe.warnings))
      "the warning generated against a real module eval must still name the option path")

    (check "facts-integration/real-genuinely-set-option-resolves-cleanly"
      (resolvedProbe.state == "resolved" && resolvedProbe.value == 16 && resolvedProbe.warnings == [ ])
      "a real NixOS module's option, genuinely given a value, must resolve silently through the exact same code path that catches the mandatory-unset case above -- proving the split is state-based, not a special case for failure")

    (check "facts-integration/toplevel-genuinely-fails-for-this-fixture (sanity)"
      toplevelActuallyFails
      "this fixture's own unrelated module must genuinely fail its assertion, or fixture 3 below proves nothing about avoiding a system eval")

    (check "facts-integration/absent-state-does-not-require-toplevel-to-succeed"
      (absentProbeDespiteBrokenSibling.state == "absent"
        && absentProbeDespiteBrokenSibling.value == "no-cpu-fact-here")
      "requirement 4: probing an absent namespace must report \"absent\" cleanly even inside a config whose own system.build.toplevel is genuinely unbuildable -- reading a fact must not cost a system eval, and this proves the read never went anywhere near one")

    (check "facts-integration/real-rename-inside-a-composed-module-reports-unresolved"
      (renamedProbe.state == "unresolved" && lib.length renamedProbe.warnings == 1)
      "nixcpu genuinely composed (coreCount = 16 is real, live config), but the OLD path (cores) genuinely gone -- must report \"unresolved\", the real-module-eval proof of the exact defect class this mechanism exists for")
  ];
in
results
