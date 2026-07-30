# checks/default.nix
#
# EVAL-TIME tests only -- no VM, no build -- the same posture as the sibling nixluks/nixvault
# projects: each test composes `modules/nixhost.nix` with a small fixture through a
# real NixOS (or system-manager) evaluation and checks whether `system.build.toplevel` (or
# `makeSystemConfig`'s own gate) forces the module's assertions to throw.
#
# The claims worth failing CI over -- one group per assertion this module implements, each
# proven to FIRE when violated and stay SILENT when satisfied, per this repo's own house rule
# that an assertion test which cannot fail is worthless:
#
#   1. `nixhost.name` has no default and rejects the empty string -- omitting it entirely, and
#      setting it to `""`, both fail the build; a real name never does.
#   2. `resources.cpu.microarch` is checked against `resources.cpu.arch` in BOTH directions (an
#      x86_64 psABI string on an aarch64 host, and the reverse) and is silent for a matching
#      pair, for `null`, and for a real vendor-specific microarch name that classifies as
#      neither family (`apple-m1`) -- proving the check does not over-fire on real hardware.
#   3. Environment RAM claims summing over `resources.ram.totalMiB` fail the build; summing to
#      EXACTLY the total is fine (a boundary, not an off-by-one); an environment with no
#      declared `ram.limitMiB` is excluded from the sum entirely.
#   4. Environment CPU claims are checked against `resources.cpu.cores`, deliberately never
#      `resources.cpu.threads` -- a claim that fits under threads but exceeds cores still fails.
#   5. A GPU claimed `"exclusive"` by more than one environment, or `"exclusive"` by one and
#      anything else by another, fails the build; the same device claimed `"shared"` by several
#      environments does not; a lone `"exclusive"` claimant does not; two DIFFERENT devices each
#      claimed `"exclusive"` by a different environment does not (no cross-device conflict).
#   6. A declared `resources.gpu.<name>` entry with an empty vendor/pciId or non-positive
#      vramMiB fails the build; a fully-populated entry does not.
#
# Plus backend parity (NixOS vs. system-manager agree on the same fixtures) and the shipped
# `examples/host` evaluating cleanly on its own.
{ pkgs, lib, nixpkgs, system, nixhostModule, systemManagerLib, assertHosts }:

let
  evalNixos = extraConfig:
    (import (nixpkgs + "/nixos/lib/eval-config.nix") {
      inherit system;
      modules = [
        nixhostModule
        extraConfig
        {
          boot.loader.grub.enable = false;
          fileSystems."/" = { device = "none"; fsType = "tmpfs"; };
          system.stateVersion = "25.05";
        }
      ];
    }).config;

  # NixOS enforces assertions when `system.build.toplevel` is forced, not on a bare read of
  # `config.assertions` (a passive list); forcing toplevel is also what makes an UNSET required
  # option (no `default`, e.g. `nixhost.name`) actually error, since nothing else would force it.
  # `seq` reaches the wrapping throw without deep-forcing the whole system closure.
  nixosBuildFails = extraConfig:
    !(builtins.tryEval (builtins.seq (evalNixos extraConfig).system.build.toplevel true)).success;

  # system-manager's makeSystemConfig gates its entire return value on assertions passing, so a
  # bare `.config` access already throws when one fails -- the same shape nixluks/nixvault's own
  # backend-parity tests rely on.
  evalSm = extraConfig:
    (systemManagerLib.makeSystemConfig {
      modules = [
        nixhostModule
        extraConfig
        { nixpkgs.hostPlatform = system; }
      ];
    }).config;

  smBuildFails = extraConfig:
    !(builtins.tryEval (builtins.seq (evalSm extraConfig) true)).success;

  check = name: ok: detail: { inherit name ok detail; };

  # ══ Fixtures ═══════════════════════════════════════════════════════════════════════════════

  minimalHardware = {
    cpu = { arch = "x86_64"; cores = 16; threads = 32; };
    ram.totalMiB = 131072;
  };

  validMinimal = {
    nixhost = {
      name = "test-host";
      stance.backend = "nixos";
      resources = minimalHardware;
    };
  };

  nameMissing = {
    nixhost = {
      stance.backend = "nixos";
      resources = minimalHardware;
    };
  };

  nameEmpty = {
    nixhost = {
      name = "";
      stance.backend = "nixos";
      resources = minimalHardware;
    };
  };

  # `class`/`role` are nullOr str, so "" type-checks. The assertion exists because "" reads as
  # SET to a null-check and UNSET to any comparison -- see the module's own assertion message.
  classEmpty = {
    nixhost = {
      name = "test-host";
      stance = { backend = "nixos"; class = ""; };
      resources = minimalHardware;
    };
  };

  roleEmpty = {
    nixhost = {
      name = "test-host";
      stance = { backend = "nixos"; role = ""; };
      resources = minimalHardware;
    };
  };

  # The nearest NON-violations, and the ones that matter: a real value must pass, and so must the
  # default of not declaring these at all -- an assertion that fired on every host which simply
  # does not track a class would make the option unadoptable.
  classAndRoleSet = {
    nixhost = {
      name = "test-host";
      stance = { backend = "nixos"; class = "standard"; role = "proxy"; };
      resources = minimalHardware;
    };
  };

  classAndRoleUnset = {
    nixhost = {
      name = "test-host";
      stance.backend = "nixos";
      resources = minimalHardware;
    };
  };

  # ── Nesting fixtures. The recursion is new behaviour and the flat fixtures above cannot
  # exercise it at all: every one of them is one level deep, so they would pass identically
  # against a module that silently ignored nested environments.

  # host.vm.container.gpu.app -- three levels, the ordinary case of a VM running containers.
  nestedThreeDeep = {
    nixhost = {
      name = "test-host";
      stance.backend = "nixos";
      resources = minimalHardware // {
        ram.totalMiB = 65536;
        gpu.gpu0 = { vendor = "amd"; pciId = "1002:73bf"; vramMiB = 16384; };
      };
      environments.vm1 = {
        kind = "vm";
        resources.ram.limitMiB = 32768;
        environments.pod1 = {
          kind = "podman";
          resources.ram.limitMiB = 8192;
          environments.inner = { kind = "lxc"; resources.ram.limitMiB = 2048; };
        };
      };
    };
  };

  # THE CASE A FLAT SUM MISSES: the container over-claims its PARENT (16 GiB inside an 8 GiB
  # VM) while remaining far below the host total (65536). A check that only summed against the
  # host would call this fine.
  nestedOvercommit = {
    nixhost = {
      name = "test-host";
      stance.backend = "nixos";
      resources = minimalHardware // { ram.totalMiB = 65536; };
      environments.vm1 = {
        kind = "vm";
        resources.ram.limitMiB = 8192;
        environments.pod1 = { kind = "podman"; resources.ram.limitMiB = 16384; };
      };
    };
  };

  # Same shape for CPU, and against the parent's quota rather than the host's core count.
  nestedCpuOvercommit = {
    nixhost = {
      name = "test-host";
      stance.backend = "nixos";
      resources = minimalHardware // { cpu = { arch = "x86_64"; cores = 16; threads = 32; }; };
      environments.vm1 = {
        kind = "vm";
        resources.cpu.quotaCores = 4;
        environments.pod1 = { kind = "podman"; resources.cpu.quotaCores = 8; };
      };
    };
  };

  # A GPU claimed exclusive by a VM and shared by a container THREE levels down. Physically one
  # card -- passthrough does not mint a new device -- so exactly one of those promises is false.
  # A one-level flatten would never see it.
  nestedGpuConflict = {
    nixhost = {
      name = "test-host";
      stance.backend = "nixos";
      resources = minimalHardware // {
        gpu.gpu0 = { vendor = "amd"; pciId = "1002:73bf"; vramMiB = 16384; };
      };
      environments.vm1 = {
        kind = "vm";
        resources.gpu.gpu0.access = "exclusive";
        environments.pod1 = {
          kind = "podman";
          environments.inner = { kind = "lxc"; resources.gpu.gpu0.access = "shared"; };
        };
      };
    };
  };

  # NEAREST NON-VIOLATION: a nested env with no declared limit at all must be EXCLUDED from its
  # parent's sum, not counted as zero and not counted as unlimited. Its sibling claims 4096 of
  # the parent's 8192, so the parent is fine.
  nestedUnlimitedChild = {
    nixhost = {
      name = "test-host";
      stance.backend = "nixos";
      resources = minimalHardware // { ram.totalMiB = 65536; };
      environments.vm1 = {
        kind = "vm";
        resources.ram.limitMiB = 8192;
        environments.bounded = { kind = "podman"; resources.ram.limitMiB = 4096; };
        environments.unbounded = { kind = "podman"; };
      };
    };
  };

  # NEAREST NON-VIOLATION: a deep tree where every level genuinely fits.
  nestedFits = {
    nixhost = {
      name = "test-host";
      stance.backend = "nixos";
      resources = minimalHardware // { ram.totalMiB = 65536; };
      environments.vm1 = {
        kind = "vm";
        resources.ram.limitMiB = 32768;
        environments.pod1 = {
          kind = "podman";
          resources.ram.limitMiB = 16384;
          environments.inner = { kind = "lxc"; resources.ram.limitMiB = 8192; };
        };
      };
    };
  };

  microarchMatchingArch = {
    nixhost = {
      name = "test-host";
      stance.backend = "nixos";
      resources = minimalHardware // {
        cpu = minimalHardware.cpu // { microarch = "x86_64-v3"; };
      };
    };
  };

  microarchNull = validMinimal;

  microarchUnclassifiedVendorName = {
    nixhost = {
      name = "test-host";
      stance.backend = "nixos";
      resources = {
        cpu = { arch = "aarch64"; cores = 8; threads = 8; microarch = "apple-m1"; };
        ram.totalMiB = 16384;
      };
    };
  };

  microarchX86OnAarch64 = {
    nixhost = {
      name = "test-host";
      stance.backend = "nixos";
      resources = {
        cpu = { arch = "aarch64"; cores = 8; threads = 8; microarch = "x86_64-v3"; };
        ram.totalMiB = 16384;
      };
    };
  };

  microarchAarch64OnX86 = {
    nixhost = {
      name = "test-host";
      stance.backend = "nixos";
      resources = minimalHardware // {
        cpu = minimalHardware.cpu // { microarch = "aarch64-apple-m1"; };
      };
    };
  };

  ramWithinBudget = {
    nixhost = {
      name = "test-host";
      stance.backend = "nixos";
      resources = minimalHardware;
      environments = {
        a = { kind = "podman"; resources.ram.limitMiB = 65536; };
        b = { kind = "podman"; resources.ram.limitMiB = 65536; }; # sums to exactly totalMiB
      };
    };
  };

  ramOverBudget = {
    nixhost = {
      name = "test-host";
      stance.backend = "nixos";
      resources = minimalHardware;
      environments = {
        a = { kind = "podman"; resources.ram.limitMiB = 65536; };
        b = { kind = "podman"; resources.ram.limitMiB = 65537; }; # one MiB over
      };
    };
  };

  ramUnlimitedEnvironmentExcluded = {
    nixhost = {
      name = "test-host";
      stance.backend = "nixos";
      resources = minimalHardware;
      environments = {
        capped = { kind = "podman"; resources.ram.limitMiB = 131072; }; # exactly the total alone
        uncapped = { kind = "vm"; }; # no limitMiB at all -- must not push the sum over
      };
    };
  };

  cpuWithinBudget = {
    nixhost = {
      name = "test-host";
      stance.backend = "nixos";
      resources = minimalHardware; # 16 cores, 32 threads
      environments = {
        a = { kind = "k3s"; resources.cpu.quotaCores = 16; }; # exactly cores
      };
    };
  };

  # 24 fits comfortably under `threads` (32) but must still fail against `cores` (16) -- the
  # test that proves the sum is checked against cores, never the larger threads figure.
  cpuOverCoresButUnderThreads = {
    nixhost = {
      name = "test-host";
      stance.backend = "nixos";
      resources = minimalHardware; # 16 cores, 32 threads
      environments = {
        a = { kind = "k3s"; resources.cpu.quotaCores = 24; };
      };
    };
  };

  gpuTwoExclusiveConflict = {
    nixhost = {
      name = "test-host";
      stance.backend = "nixos";
      resources = minimalHardware // {
        gpu.gpu0 = { vendor = "amd"; pciId = "0x1002"; vramMiB = 16384; };
      };
      environments = {
        k3s = { kind = "k3s"; resources.gpu.gpu0.access = "exclusive"; };
        podman = { kind = "podman"; resources.gpu.gpu0.access = "exclusive"; };
      };
    };
  };

  gpuExclusiveAndSharedConflict = {
    nixhost = {
      name = "test-host";
      stance.backend = "nixos";
      resources = minimalHardware // {
        gpu.gpu0 = { vendor = "amd"; pciId = "0x1002"; vramMiB = 16384; };
      };
      environments = {
        k3s = { kind = "k3s"; resources.gpu.gpu0.access = "exclusive"; };
        podman = { kind = "podman"; resources.gpu.gpu0.access = "shared"; };
      };
    };
  };

  gpuTwoSharedOk = {
    nixhost = {
      name = "test-host";
      stance.backend = "nixos";
      resources = minimalHardware // {
        gpu.gpu0 = { vendor = "amd"; pciId = "0x1002"; vramMiB = 16384; };
      };
      environments = {
        k3s = { kind = "k3s"; resources.gpu.gpu0.access = "shared"; };
        podman = { kind = "podman"; resources.gpu.gpu0.access = "shared"; };
      };
    };
  };

  gpuLoneExclusiveOk = {
    nixhost = {
      name = "test-host";
      stance.backend = "nixos";
      resources = minimalHardware // {
        gpu.gpu0 = { vendor = "amd"; pciId = "0x1002"; vramMiB = 16384; };
      };
      environments = {
        k3s = { kind = "k3s"; resources.gpu.gpu0.access = "exclusive"; };
      };
    };
  };

  gpuDifferentDevicesOk = {
    nixhost = {
      name = "test-host";
      stance.backend = "nixos";
      resources = minimalHardware // {
        gpu = {
          gpu0 = { vendor = "amd"; pciId = "0x1002"; vramMiB = 16384; };
          gpu1 = { vendor = "amd"; pciId = "0x1002"; vramMiB = 16384; };
        };
      };
      environments = {
        k3s = { kind = "k3s"; resources.gpu.gpu0.access = "exclusive"; };
        podman = { kind = "podman"; resources.gpu.gpu1.access = "exclusive"; };
      };
    };
  };

  gpuIncompleteDevice = {
    nixhost = {
      name = "test-host";
      stance.backend = "nixos";
      resources = minimalHardware // {
        gpu.gpu0 = { vendor = ""; pciId = "0x1002"; vramMiB = 16384; };
      };
    };
  };

  gpuCompleteDeviceOk = {
    nixhost = {
      name = "test-host";
      stance.backend = "nixos";
      resources = minimalHardware // {
        gpu.gpu0 = { vendor = "amd"; pciId = "0x1002"; vramMiB = 16384; };
      };
    };
  };

  # ══ Results ════════════════════════════════════════════════════════════════════════════════

  moduleResults = [
    (check "module/valid-minimal-host-builds-fine"
      (!(nixosBuildFails validMinimal))
      "a minimal, fully-stated host should never fail the build")

    (check "module/missing-name-fails-the-build"
      (nixosBuildFails nameMissing)
      "nixhost.name has no default -- omitting it must fail the build")

    (check "module/empty-name-fails-the-build"
      (nixosBuildFails nameEmpty)
      "nixhost.name = \"\" must fail the build, same as omitting it entirely")

    (check "module/empty-class-fails-the-build"
      (nixosBuildFails classEmpty)
      "stance.class = \"\" must fail the build -- it reads as declared to a null-check and as absent to any comparison, so two consumers of the same fact disagree silently")

    (check "module/empty-role-fails-the-build"
      (nixosBuildFails roleEmpty)
      "stance.role = \"\" must fail the build, same reasoning as class")

    (check "module/real-class-and-role-build-fine"
      (!(nixosBuildFails classAndRoleSet))
      "a genuine class and role must never fail the build -- the assertion is about the empty string, not about declaring these at all")

    (check "module/omitting-class-and-role-builds-fine"
      (!(nixosBuildFails classAndRoleUnset))
      "leaving class and role unset must build: null means `not tracked for this host`, and an assertion firing on every host that does not track them would make the options unadoptable")

    (check "nesting/three-levels-deep-builds-fine"
      (!(nixosBuildFails nestedThreeDeep))
      "host.vm.container is the ordinary case of a VM running containers and must evaluate -- if this fails the recursion itself is broken")

    (check "nesting/child-overcommitting-its-PARENT-fails"
      (nixosBuildFails nestedOvercommit)
      "a container claiming 16GiB inside an 8GiB VM must fail even though the host has 65536MiB spare -- this is the exact case a flat sum against the host total would pass")

    (check "nesting/child-overcommitting-parent-CPU-fails"
      (nixosBuildFails nestedCpuOvercommit)
      "a container claiming 8 cores inside a VM quota-limited to 4 must fail even though the host has 16 physical cores")

    (check "nesting/gpu-conflict-across-depths-fails"
      (nixosBuildFails nestedGpuConflict)
      "a card claimed exclusive by a VM and shared by a container three levels down is one piece of silicon with two contradictory promises -- a one-level flatten would never see it")

    (check "nesting/unlimited-nested-child-is-excluded-from-parent-sum"
      (!(nixosBuildFails nestedUnlimitedChild))
      "a nested environment with no declared limit makes no bounded claim and must be excluded from its parent's sum -- counting it as zero, or as unlimited, would both be wrong")

    (check "nesting/deep-tree-that-fits-builds-fine"
      (!(nixosBuildFails nestedFits))
      "a three-level tree where every level fits inside its parent must evaluate -- the checks must not fire merely because nesting exists")

    (check "module/microarch-matching-arch-builds-fine"
      (!(nixosBuildFails microarchMatchingArch))
      "x86_64-v3 on an x86_64 host must never fail the build")

    (check "module/microarch-null-builds-fine"
      (!(nixosBuildFails microarchNull))
      "a host that declares no microarch at all must never fail the build")

    (check "module/microarch-unclassified-vendor-name-builds-fine"
      (!(nixosBuildFails microarchUnclassifiedVendorName))
      "a real vendor-specific microarch name (apple-m1) on an aarch64 host must not be falsely flagged")

    (check "module/microarch-x86-on-aarch64-fails-the-build"
      (nixosBuildFails microarchX86OnAarch64)
      "an x86_64 psABI microarch string declared on an aarch64 host must fail the build")

    (check "module/microarch-aarch64-on-x86-fails-the-build"
      (nixosBuildFails microarchAarch64OnX86)
      "an aarch64-family microarch string declared on an x86_64 host must fail the build (the mirror-image mistake)")

    (check "module/ram-claims-summing-to-exactly-the-total-builds-fine"
      (!(nixosBuildFails ramWithinBudget))
      "RAM claims summing to EXACTLY the host total must not fail -- this is a boundary, not an off-by-one")

    (check "module/ram-claims-over-the-total-fails-the-build"
      (nixosBuildFails ramOverBudget)
      "RAM claims summing to one MiB over the host total must fail the build")

    (check "module/unlimited-environment-excluded-from-ram-sum"
      (!(nixosBuildFails ramUnlimitedEnvironmentExcluded))
      "an environment with no declared ram.limitMiB must not be treated as claiming zero and must not push another environment's exact-total claim over the edge")

    (check "module/cpu-claim-exactly-at-cores-builds-fine"
      (!(nixosBuildFails cpuWithinBudget))
      "a CPU claim summing to exactly resources.cpu.cores must not fail")

    (check "module/cpu-claim-over-cores-but-under-threads-fails-the-build"
      (nixosBuildFails cpuOverCoresButUnderThreads)
      "a CPU claim (24) that fits under threads (32) but exceeds cores (16) must still fail -- proves the sum is checked against cores, never threads")

    (check "module/gpu-two-exclusive-claims-fails-the-build"
      (nixosBuildFails gpuTwoExclusiveConflict)
      "two environments both claiming the same GPU exclusively must fail the build")

    (check "module/gpu-exclusive-and-shared-claims-fails-the-build"
      (nixosBuildFails gpuExclusiveAndSharedConflict)
      "one environment claiming a GPU exclusively while another claims it shared must fail the build -- an error, not a precedence puzzle")

    (check "module/gpu-two-shared-claims-builds-fine"
      (!(nixosBuildFails gpuTwoSharedOk))
      "two environments both claiming the same GPU as shared must never fail the build")

    (check "module/gpu-lone-exclusive-claim-builds-fine"
      (!(nixosBuildFails gpuLoneExclusiveOk))
      "a single environment claiming a GPU exclusively, with no other claimant, must never fail the build")

    (check "module/gpu-different-devices-each-exclusive-builds-fine"
      (!(nixosBuildFails gpuDifferentDevicesOk))
      "two environments each claiming a DIFFERENT device exclusively must never fail the build -- no cross-device conflict")

    (check "module/gpu-incomplete-device-fails-the-build"
      (nixosBuildFails gpuIncompleteDevice)
      "a declared GPU device with an empty vendor must fail the build")

    (check "module/gpu-complete-device-builds-fine"
      (!(nixosBuildFails gpuCompleteDeviceOk))
      "a fully-populated GPU device with no environment claims must never fail the build")
  ];

  # ── Backend parity: the same input, both module systems, same answer ─────────────────────────
  backendParityChecks = [
    (check "backend-parity/valid-minimal-host-builds-on-both"
      (!(nixosBuildFails validMinimal) && !(smBuildFails validMinimal))
      "a valid, minimal host must never fail on either backend")

    (check "backend-parity/empty-name-fails-on-both"
      (nixosBuildFails nameEmpty && smBuildFails nameEmpty)
      "an empty nixhost.name must fail identically on both backends")

    (check "backend-parity/ram-over-budget-fails-on-both"
      (nixosBuildFails ramOverBudget && smBuildFails ramOverBudget)
      "a RAM oversubscription must fail identically on both backends")

    (check "backend-parity/cpu-over-cores-fails-on-both"
      (nixosBuildFails cpuOverCoresButUnderThreads && smBuildFails cpuOverCoresButUnderThreads)
      "a CPU-over-cores oversubscription must fail identically on both backends")

    (check "backend-parity/gpu-exclusive-conflict-fails-on-both"
      (nixosBuildFails gpuTwoExclusiveConflict && smBuildFails gpuTwoExclusiveConflict)
      "a GPU exclusivity conflict must fail identically on both backends")

    (check "backend-parity/microarch-mismatch-fails-on-both"
      (nixosBuildFails microarchX86OnAarch64 && smBuildFails microarchX86OnAarch64)
      "a microarch/arch mismatch must fail identically on both backends")
  ];

  # ── The shipped example: a complete, self-contained stub host ────────────────────────────────
  exampleHost = lib.nixosSystem {
    inherit system;
    modules = [ nixhostModule ../examples/host/configuration.nix ];
  };

  exampleResults = [
    (check "example/modules-evaluate"
      (builtins.tryEval (builtins.seq exampleHost.config.system.build.toplevel true)).success
      "the shipped generic example (examples/host) failed to evaluate -- it is meant to be internally consistent by construction")
  ];

  # The CROSS-HOST group: `lib/hosts.nix`, which implements only the checks a per-host module
  # cannot make. Kept in its own file because it needs no NixOS evaluation at all -- it is a plain
  # function over plain data, which is the whole reason it exists (see that file's header for the
  # measured cost of the alternative).
  hostsResults = import ./hosts.nix { inherit lib assertHosts; };

  results = moduleResults ++ backendParityChecks ++ exampleResults ++ hostsResults;

  failed = builtins.filter (r: !r.ok) results;

  report = lib.concatMapStringsSep "\n" (r: "  - ${r.name}: ${r.detail}") failed;
in
if failed != [ ]
then
  throw ''
    nixhost eval-tests FAILED (${toString (builtins.length failed)}/${toString (builtins.length results)}):
    ${report}
  ''
else {
  # Depending on `passedCount` forces `results`, so the tests genuinely run under `nix flake
  # check` rather than merely being defined.
  eval-tests = pkgs.runCommand "nixhost-eval-tests"
    { passedCount = toString (builtins.length results); }
    ''
      echo "all $passedCount nixhost eval tests passed"
      touch $out
    '';
}
