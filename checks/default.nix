# checks/default.nix
#
# EVAL-TIME tests only -- no VM, no build -- the same posture as the sibling nixluks/nixvault
# projects: each test composes `modules/nixhost.nix` with a small fixture through a
# real NixOS (or system-manager) evaluation and checks whether `system.build.toplevel` (or
# `makeSystemConfig`'s own gate) forces the module's assertions to throw.
#
# ── EVERY LEVEL-1 FACT IS SET AT ITS OWNER, and that shapes every fixture below ───────────────
#
# `nixhost.resources.*` is not settable: each field is a `readOnly` mirror of the domain repo that
# owns the fact. So a fixture states `nixcpu.cores = 16`, never `nixhost.resources.cpu.cores = 16`,
# and gets those option paths from `./domain-stubs.nix` -- see that file for why a stub rather than
# five checks-only flake inputs. Two eval entry points exist, and the difference between them is
# itself under test:
#
#   `nixosBuildFails`     -- the domains' option surfaces ARE present (the ordinary host).
#   `nixosBuildFailsBare` -- nixhost alone, no domain module anywhere. This is the state every
#                            mirror must survive by resolving to `null`/`{ }`, and the state in
#                            which a ceiling-dependent check must FAIL LOUDLY rather than pass
#                            vacuously.
#
# Both eval paths matter because the two absences reach the mirror by different routes -- a missing
# attribute path versus a declared option with no definition -- even though `lib.probeFact`
# deliberately gives them the same answer. Testing only the bare path would leave the route that
# goes through a throwing default entirely unexercised.
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
#   6. THE MIRRORS: every level-1 field equals the domain fact it mirrors; setting one directly is
#      a build failure, not an override; and with no domain module present at all they resolve to
#      `null`/`{ }` and the host still builds.
#   7. THE CEILINGS (MIRROR + ASSERT-RESOLVED): an environment claiming RAM or CPU on a host whose
#      total/core-count did not resolve FAILS, and so does a microarch with no arch to check against
#      -- the specific regression this group exists for is the opposite, a green build in which the
#      check compared against nothing -- while a host with no such claim builds fine with no facts
#      at all, including on a host where the domains are imported and simply say nothing.
#   8. THE FACT WIRING (`lib.probeFact`, spliced into `config.warnings` as `extraFactWarnings`): a
#      fully-populated host and a bare one both produce zero warnings; a domain composed with
#      nothing stated warns exactly once, for the one non-ceiling field (`nixcpu.threads`) that
#      genuinely has no upstream default; and a domain whose real option surface renamed the exact
#      path a mirror reads (`nixgpu.stableDevicePaths.devices` -> `nixgpu.inventory`) warns exactly
#      once, naming the option path, the namespace, and the fallback value in use, WITHOUT failing
#      the build -- proven through the real `nixhostModule`, not only `lib/facts.nix`'s own
#      function-level and synthetic-integration fixtures.
#
# Plus backend parity (NixOS vs. system-manager agree on the same fixtures) and the shipped
# `examples/host` evaluating cleanly on its own.
{ pkgs, lib, nixpkgs, system, nixhostModule, systemManagerLib, assertHosts, probeFact, collectProbes }:

let
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
      modules = [ nixhostModule ] ++ modules ++ nixosBase;
    }).config;

  evalNixos = extraConfig: evalNixosWith [ domainStubs extraConfig ];

  # nixhost with NO domain module anywhere -- the adoption case, and the only state in which a
  # defensive `config.<domain>.<path> or <empty>` read actually takes its fallback.
  evalNixosBare = extraConfig: evalNixosWith [ extraConfig ];

  # NixOS enforces assertions when `system.build.toplevel` is forced, not on a bare read of
  # `config.assertions` (a passive list); forcing toplevel is also what makes an UNSET required
  # option (no `default`, e.g. `nixhost.name`, or a domain's own `nixcpu.cores`) actually error,
  # since nothing else would force it. `seq` reaches the wrapping throw without deep-forcing the
  # whole system closure.
  buildFails = config:
    !(builtins.tryEval (builtins.seq config.system.build.toplevel true)).success;

  nixosBuildFails = extraConfig: buildFails (evalNixos extraConfig);
  nixosBuildFailsBare = extraConfig: buildFails (evalNixosBare extraConfig);

  # system-manager's makeSystemConfig gates its entire return value on assertions passing, so a
  # bare `.config` access already throws when one fails -- the same shape nixluks/nixvault's own
  # backend-parity tests rely on.
  evalSm = extraConfig:
    (systemManagerLib.makeSystemConfig {
      modules = [
        nixhostModule
        domainStubs
        extraConfig
        { nixpkgs.hostPlatform = system; }
      ];
    }).config;

  smBuildFails = extraConfig:
    !(builtins.tryEval (builtins.seq (evalSm extraConfig) true)).success;

  check = name: ok: detail: { inherit name ok detail; };

  # ══ Fixtures ═══════════════════════════════════════════════════════════════════════════════

  # `//` is shallow, and these fragments share namespaces (`nixcpu.microarch` beside
  # `nixcpu.cores`), so composing them with `//` would silently delete an earlier fragment's
  # siblings -- a fixture that then tests something other than what it reads as.
  facts = lib.foldl' lib.recursiveUpdate { };

  cpu16c32t = { nixcpu = { arch = "x86_64"; cores = 16; threads = 32; }; };
  ram128g = { nixram.hardware.totalMiB = 131072; };
  ram64g = { nixram.hardware.totalMiB = 65536; };
  oneAmdCard = {
    nixgpu.stableDevicePaths.devices.gpu0 = {
      vendor = "amd";
      pciId = "0x1002";
      vramMiB = 16384;
    };
  };

  # A fixture is domain-owned FACTS plus this repo's own `nixhost` block. The two never share a
  # top-level key, so `//` is safe at that seam -- and it is what lets a fixture restate `name` or
  # `stance` to override the common default without two definitions colliding.
  hostWith = factFragments: nixhostBlock:
    (facts factFragments) // {
      nixhost = { name = "test-host"; stance.backend = "nixos"; } // nixhostBlock;
    };

  baseFacts = [ cpu16c32t ram128g ];

  validMinimal = hostWith baseFacts { };

  nameMissing = (facts baseFacts) // { nixhost.stance.backend = "nixos"; };

  nameEmpty = hostWith baseFacts { name = ""; };

  # `class`/`role` are nullOr str, so "" type-checks. The assertion exists because "" reads as
  # SET to a null-check and UNSET to any comparison -- see the module's own assertion message.
  classEmpty = hostWith baseFacts { stance = { backend = "nixos"; class = ""; }; };

  roleEmpty = hostWith baseFacts { stance = { backend = "nixos"; role = ""; }; };

  # The nearest NON-violations, and the ones that matter: a real value must pass, and so must the
  # default of not declaring these at all -- an assertion that fired on every host which simply
  # does not track a class would make the option unadoptable.
  classAndRoleSet = hostWith baseFacts {
    stance = { backend = "nixos"; class = "standard"; role = "proxy"; };
  };

  classAndRoleUnset = hostWith baseFacts { };

  # ── Nesting fixtures. The recursion is new behaviour and the flat fixtures above cannot
  # exercise it at all: every one of them is one level deep, so they would pass identically
  # against a module that silently ignored nested environments.

  # host.vm.container.gpu.app -- three levels, the ordinary case of a VM running containers.
  nestedThreeDeep = hostWith [ cpu16c32t ram64g oneAmdCard ] {
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

  # THE CASE A FLAT SUM MISSES: the container over-claims its PARENT (16 GiB inside an 8 GiB
  # VM) while remaining far below the host total (65536). A check that only summed against the
  # host would call this fine.
  nestedOvercommit = hostWith [ cpu16c32t ram64g ] {
    environments.vm1 = {
      kind = "vm";
      resources.ram.limitMiB = 8192;
      environments.pod1 = { kind = "podman"; resources.ram.limitMiB = 16384; };
    };
  };

  # ── FLOORS: reserveMiB (memory.low) and hardReserveMiB (memory.min) ─────────────────────────

  # Hard floors that fit under the host total. Must build.
  hardReservesFit = hostWith [ cpu16c32t ram64g ] {
    environments = {
      desktop = { kind = "native"; resources.ram.hardReserveMiB = 8192; };
      cluster = { kind = "k3s"; resources.ram.hardReserveMiB = 32768; };
    };
  };

  # THE POINT: memory.min promised twice. 40960 + 32768 > 65536, and the kernel cannot partially
  # honour a guarantee -- it OOMs instead. Unlike limitMiB, a null reservation is zero here, so
  # this sum is complete rather than a lower bound.
  hardReservesOverCommitted = hostWith [ cpu16c32t ram64g ] {
    environments = {
      desktop = { kind = "native"; resources.ram.hardReserveMiB = 40960; };
      cluster = { kind = "k3s"; resources.ram.hardReserveMiB = 32768; };
    };
  };

  # THE DELIBERATE ASYMMETRY: the SAME numbers as soft floors must BUILD. memory.low is a
  # preference the kernel resolves proportionally and can always walk back, so several tenants
  # each preferring more than exists between them is legitimate, not a contradiction.
  softReservesOverSubscribedIsFine = hostWith [ cpu16c32t ram64g ] {
    environments = {
      desktop = { kind = "native"; resources.ram.reserveMiB = 40960; };
      cluster = { kind = "k3s"; resources.ram.reserveMiB = 32768; };
    };
  };

  # Nested: a hard floor inside a VM is checked against the VM's own limit, not the host's total.
  # 12288 reserved inside an 8192 VM, on a host with 64 GiB spare.
  hardReserveOverParentNotHost = hostWith [ cpu16c32t ram64g ] {
    environments.vm1 = {
      kind = "vm";
      resources.ram.limitMiB = 8192;
      environments.pod1 = { kind = "podman"; resources.ram.hardReserveMiB = 12288; };
    };
  };

  # One environment contradicting ITSELF -- no sibling involved, so neither sum can see these.
  floorAboveOwnCap = hostWith [ cpu16c32t ram64g ] {
    environments.app = {
      kind = "podman";
      resources.ram = { limitMiB = 4096; hardReserveMiB = 8192; };
    };
  };

  softFloorAboveOwnCap = hostWith [ cpu16c32t ram64g ] {
    environments.app = {
      kind = "podman";
      resources.ram = { limitMiB = 4096; reserveMiB = 8192; };
    };
  };

  # A hard floor above the soft one makes the soft one dead: memory.min already protects that much
  # unconditionally, so memory.low never gets a chance to apply.
  hardFloorAboveSoftFloor = hostWith [ cpu16c32t ram64g ] {
    environments.app = {
      kind = "podman";
      resources.ram = { reserveMiB = 2048; hardReserveMiB = 4096; };
    };
  };

  # ── `native`: a claimant that is not a substrate ────────────────────────────────────────────
  # The four container/VM/cluster kinds all describe something that CONTAINS workloads, which left
  # processes on the metal (a desktop session, a compositor) with no address at all -- so the one
  # tenant on a mixed host that is not a substrate was the one whose claims silently did not exist.

  # A native tenant beside a k3s node, together fitting the host. Must build.
  nativeBesideCluster = hostWith [ cpu16c32t ram64g ] {
    environments = {
      devhome = { kind = "native"; resources.ram.limitMiB = 8192; };
      cluster = { kind = "k3s"; resources.ram.limitMiB = 32768; };
    };
  };

  # THE POINT OF THE MEMBER: the native claim must actually COUNT. 40960 + 32768 > 65536, and it
  # only overcommits once the native tenant is included -- a module that accepted `native` as a
  # label but skipped it in the fold would pass this.
  nativeCountsInTheSum = hostWith [ cpu16c32t ram64g ] {
    environments = {
      devhome = { kind = "native"; resources.ram.limitMiB = 40960; };
      cluster = { kind = "k3s"; resources.ram.limitMiB = 32768; };
    };
  };

  # A native tenant must be subject to the GPU conflict check like any other claimant: here it
  # claims the card exclusively while a cluster node also wants it.
  nativeGpuConflict = hostWith [ cpu16c32t ram64g oneAmdCard ] {
    environments = {
      devhome = { kind = "native"; resources.gpu.gpu0.access = "exclusive"; };
      cluster = { kind = "k3s"; resources.gpu.gpu0.access = "shared"; };
    };
  };

  # Same shape for CPU, and against the parent's quota rather than the host's core count.
  nestedCpuOvercommit = hostWith baseFacts {
    environments.vm1 = {
      kind = "vm";
      resources.cpu.quotaCores = 4;
      environments.pod1 = { kind = "podman"; resources.cpu.quotaCores = 8; };
    };
  };

  # A GPU claimed exclusive by a VM and shared by a container THREE levels down. Physically one
  # card -- passthrough does not mint a new device -- so exactly one of those promises is false.
  # A one-level flatten would never see it.
  nestedGpuConflict = hostWith [ cpu16c32t ram128g oneAmdCard ] {
    environments.vm1 = {
      kind = "vm";
      resources.gpu.gpu0.access = "exclusive";
      environments.pod1 = {
        kind = "podman";
        environments.inner = { kind = "lxc"; resources.gpu.gpu0.access = "shared"; };
      };
    };
  };

  # NEAREST NON-VIOLATION: a nested env with no declared limit at all must be EXCLUDED from its
  # parent's sum, not counted as zero and not counted as unlimited. Its sibling claims 4096 of
  # the parent's 8192, so the parent is fine.
  nestedUnlimitedChild = hostWith [ cpu16c32t ram64g ] {
    environments.vm1 = {
      kind = "vm";
      resources.ram.limitMiB = 8192;
      environments.bounded = { kind = "podman"; resources.ram.limitMiB = 4096; };
      environments.unbounded = { kind = "podman"; };
    };
  };

  # NEAREST NON-VIOLATION: a deep tree where every level genuinely fits.
  nestedFits = hostWith [ cpu16c32t ram64g ] {
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

  microarchMatchingArch = hostWith
    [ cpu16c32t ram128g { nixcpu.microarch = "x86_64-v3"; } ]
    { };

  microarchNull = validMinimal;

  aarch64Small = {
    nixcpu = { arch = "aarch64"; cores = 8; threads = 8; };
    nixram.hardware.totalMiB = 16384;
  };

  microarchUnclassifiedVendorName = hostWith
    [ aarch64Small { nixcpu.microarch = "apple-m1"; } ]
    { };

  microarchX86OnAarch64 = hostWith
    [ aarch64Small { nixcpu.microarch = "x86_64-v3"; } ]
    { };

  microarchAarch64OnX86 = hostWith
    [ cpu16c32t ram128g { nixcpu.microarch = "aarch64-apple-m1"; } ]
    { };

  # A microarch mirrored in while `arch` never resolved. The microarch/arch cross-check compares
  # the two, so this must never pass quietly -- see `ceiling/`'s own note on which mechanism
  # actually catches it today.
  microarchWithoutArch = (facts [ ram128g { nixcpu = { microarch = "x86_64-v3"; cores = 16; threads = 32; }; } ]) // {
    nixhost = { name = "test-host"; stance.backend = "nixos"; };
  };

  ramWithinBudget = hostWith baseFacts {
    environments = {
      a = { kind = "podman"; resources.ram.limitMiB = 65536; };
      b = { kind = "podman"; resources.ram.limitMiB = 65536; }; # sums to exactly totalMiB
    };
  };

  ramOverBudget = hostWith baseFacts {
    environments = {
      a = { kind = "podman"; resources.ram.limitMiB = 65536; };
      b = { kind = "podman"; resources.ram.limitMiB = 65537; }; # one MiB over
    };
  };

  ramUnlimitedEnvironmentExcluded = hostWith baseFacts {
    environments = {
      capped = { kind = "podman"; resources.ram.limitMiB = 131072; }; # exactly the total alone
      uncapped = { kind = "vm"; }; # no limitMiB at all -- must not push the sum over
    };
  };

  cpuWithinBudget = hostWith baseFacts {
    environments = {
      a = { kind = "k3s"; resources.cpu.quotaCores = 16; }; # exactly cores
    };
  };

  # 24 fits comfortably under `threads` (32) but must still fail against `cores` (16) -- the
  # test that proves the sum is checked against cores, never the larger threads figure.
  cpuOverCoresButUnderThreads = hostWith baseFacts {
    environments = {
      a = { kind = "k3s"; resources.cpu.quotaCores = 24; };
    };
  };

  gpuTwoExclusiveConflict = hostWith [ cpu16c32t ram128g oneAmdCard ] {
    environments = {
      k3s = { kind = "k3s"; resources.gpu.gpu0.access = "exclusive"; };
      podman = { kind = "podman"; resources.gpu.gpu0.access = "exclusive"; };
    };
  };

  gpuExclusiveAndSharedConflict = hostWith [ cpu16c32t ram128g oneAmdCard ] {
    environments = {
      k3s = { kind = "k3s"; resources.gpu.gpu0.access = "exclusive"; };
      podman = { kind = "podman"; resources.gpu.gpu0.access = "shared"; };
    };
  };

  gpuTwoSharedOk = hostWith [ cpu16c32t ram128g oneAmdCard ] {
    environments = {
      k3s = { kind = "k3s"; resources.gpu.gpu0.access = "shared"; };
      podman = { kind = "podman"; resources.gpu.gpu0.access = "shared"; };
    };
  };

  gpuLoneExclusiveOk = hostWith [ cpu16c32t ram128g oneAmdCard ] {
    environments = {
      k3s = { kind = "k3s"; resources.gpu.gpu0.access = "exclusive"; };
    };
  };

  gpuDifferentDevicesOk = hostWith
    [
      cpu16c32t
      ram128g
      {
        nixgpu.stableDevicePaths.devices = {
          gpu0 = { vendor = "amd"; pciId = "0x1002"; vramMiB = 16384; };
          gpu1 = { vendor = "amd"; pciId = "0x1002"; vramMiB = 16384; };
        };
      }
    ]
    {
      environments = {
        k3s = { kind = "k3s"; resources.gpu.gpu0.access = "exclusive"; };
        podman = { kind = "podman"; resources.gpu.gpu1.access = "exclusive"; };
      };
    };

  # ── Mirror fixtures ───────────────────────────────────────────────────────────────────────────

  # Every mirrored fact populated at its owner, including the two this module could not reach at
  # all before (`cpu.coreTypes`) or could only ever prove empty (`storage.disks`).
  everyFactStated = {
    nixcpu = {
      arch = "x86_64";
      microarch = "x86_64-v3";
      cores = 16;
      threads = 24;
      scheduler = "bore";
      coreTypes = {
        performance = { cores = 8; threadsPerCore = 2; };
        efficiency = { cores = 8; threadsPerCore = 1; };
      };
    };
    nixram.hardware.totalMiB = 131072;
    nixgpu.stableDevicePaths.devices.gpu0 = {
      vendor = "amd";
      pciId = "0x1002";
      vramMiB = 16384;
    };
    nixnet.interfaces.lan0 = {
      mac = "aa:bb:cc:dd:ee:ff";
      addresses.lan = "192.0.2.10";
    };
    nixstorage.disks.pool0 = { device = "/dev/disk/by-id/ata-EXAMPLE_A"; };
  };

  everyMirrorPopulated = hostWith [ everyFactStated ] { };
  mirrored = (evalNixos everyMirrorPopulated).nixhost.resources;

  # Nothing but nixhost. Every mirror must take its defensive fallback here.
  noDomainsAtAll = { nixhost = { name = "test-host"; stance.backend = "nixos"; }; };
  unmirrored = (evalNixosBare noDomainsAtAll).nixhost.resources;

  # Setting a mirror on the host. `readOnly` counts the option's own default as one definition, so
  # a single external definition is already "set multiple times" and fails -- which is what makes
  # "exactly one spot" structural rather than a documented convention.
  cpuCoresSetDirectly = hostWith baseFacts { resources.cpu.cores = 8; };
  gpuSetDirectly = hostWith baseFacts {
    resources.gpu.gpu0 = { vendor = "amd"; pciId = "0x1002"; vramMiB = 16384; };
  };
  netSetDirectly = hostWith baseFacts { resources.net.lan0 = { mac = "aa:bb:cc:dd:ee:ff"; }; };

  # ── Ceiling fixtures: MIRROR + ASSERT-RESOLVED ────────────────────────────────────────────────

  # A RAM claim on a host with no nixram anywhere. Before the assert-resolved half existed, this
  # was the silent case: `totalMiB` null, the oversubscription comparison skipped, build green.
  ramClaimNoDomains = {
    nixhost = {
      name = "test-host";
      stance.backend = "nixos";
      environments.a = { kind = "k3s"; resources.ram.limitMiB = 4096; };
    };
  };

  cpuClaimNoDomains = {
    nixhost = {
      name = "test-host";
      stance.backend = "nixos";
      environments.a = { kind = "k3s"; resources.cpu.quotaCores = 4; };
    };
  };

  # The other shape of absence: the domains ARE imported, the facts were simply never stated. The
  # two reach the mirror differently -- nixram's own default is `null`, while nixcpu's `cores` has no
  # default at all and would abort evaluation if its mirror did not go through `lib.probeFact` --
  # and both must come out as the same loud assertion. Neither may pass.
  ramClaimFactUnstated = { nixhost = { name = "test-host"; stance.backend = "nixos"; environments.a = { kind = "k3s"; resources.ram.limitMiB = 4096; }; }; };
  cpuClaimFactUnstated = { nixhost = { name = "test-host"; stance.backend = "nixos"; environments.a = { kind = "k3s"; resources.cpu.quotaCores = 4; }; }; };

  # NEAREST NON-VIOLATION for the mirror design as a whole: the domains are imported and NOTHING is
  # stated. `nixcpu.arch`/`cores`/`threads` have no default upstream, so each of those mirrors reads
  # a value the module system would abort on -- and this host must still build, because nothing on
  # it depends on any of them. Guards the exact bug class where `overriddenMirrors`' own
  # `opt.definitions` read (which forces every definition's value) tells a host that declared
  # nothing that it declared a fact twice.
  domainsImportedNothingStated = { nixhost = { name = "test-host"; stance.backend = "nixos"; }; };

  # NEAREST NON-VIOLATION, and the property that keeps this module adoptable: environments may
  # exist, and may claim a GPU, on a host that owns none of the mirrored domains -- as long as
  # nothing asks for a comparison against a ceiling. An unlimited environment makes no claim.
  environmentsWithoutClaimsNoDomains = {
    nixhost = {
      name = "test-host";
      stance.backend = "nixos";
      environments = {
        a = { kind = "k3s"; resources.gpu.gpu0.access = "shared"; };
        b = { kind = "podman"; };
      };
    };
  };

  # ── Fact-wiring fixtures: `lib.probeFact` proven THROUGH the real module, not just abstractly ──
  #
  # `checks/facts.nix` proves `lib.probeFact` at the function level, and `checks/facts-integration.nix`
  # proves it against a real NixOS eval of its OWN small stand-in fixtures. Neither ever composes the
  # real `modules/nixhost.nix` -- the ten actual probe call sites (`archProbe` through `netProbe`) and
  # the `config.warnings = extraFactWarnings;` line that splices their result into this host's own
  # build -- so neither proves the WIRING is right. A caller could get any one of those ten calls
  # backwards (wrong `namespace`, wrong `path`, a probe left out of `extraFactWarnings` entirely) and
  # every test above this line would stay green. These fixtures close that gap, reusing whatever is
  # already defined above and adding only the one decoy nothing above provides: a domain whose real
  # option surface renamed the exact path a mirror reads.
  #
  # `nixgpu` genuinely composed (`inventory` exists, and resolves cleanly on its own), but
  # `stableDevicePaths.devices` -- the path `gpuProbe` still asks for -- is gone: the real shape
  # `nixstorage.layout`'s own rename produced, reproduced here against `nixgpu` specifically because
  # its mirror's fallback is an attrset (`{ }`), proving requirement 5 end-to-end as well as the
  # scalar case `nixcpu.threads` below already covers.
  nixgpuRenamedStub = { lib, ... }: {
    options.nixgpu.inventory = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      description = "Stand-in for nixgpu having renamed `stableDevicePaths.devices` to `inventory`.";
    };
  };

  nixgpuRenamedHost = { nixhost = { name = "test-host"; stance.backend = "nixos"; }; };

  # Deliberately through `evalNixosWith` directly, never `evalNixos`/`evalNixosBare`: this fixture
  # composes its OWN, deliberately-renamed nixgpu surface, not `domainStubs`' faithful one.
  nixgpuRenamedEval = evalNixosWith [ nixgpuRenamedStub nixgpuRenamedHost ];

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

    (check "floors/hard-reserves-that-fit-build"
      (!(nixosBuildFails hardReservesFit))
      "8192 + 32768 hard-reserved on a 65536MiB host fits and must evaluate")

    (check "floors/hard-reserves-over-capacity-fail"
      (nixosBuildFails hardReservesOverCommitted)
      "memory.min promised twice is a guarantee the kernel cannot partially honour -- it resolves it by killing something, so the build must say so first")

    (check "floors/soft-reserves-may-be-over-subscribed"
      (!(nixosBuildFails softReservesOverSubscribedIsFine))
      "the IDENTICAL numbers as soft floors must build: memory.low is a preference resolved proportionally under pressure, and several tenants each preferring more than exists is legitimate -- if this ever fails, the two floor kinds have been collapsed into one")

    (check "floors/hard-reserve-is-checked-against-its-PARENT"
      (nixosBuildFails hardReserveOverParentNotHost)
      "12288MiB reserved inside an 8192MiB VM must fail even though the host has 64GiB spare -- a guest cannot guarantee more than it was given")

    (check "floors/hard-floor-above-own-cap-fails"
      (nixosBuildFails floorAboveOwnCap)
      "an environment cannot be guaranteed memory it is itself capped below; no sibling is involved, so neither sum sees this")

    (check "floors/soft-floor-above-own-cap-fails"
      (nixosBuildFails softFloorAboveOwnCap)
      "an environment cannot prefer to keep more than it may use")

    (check "floors/hard-floor-above-soft-floor-fails"
      (nixosBuildFails hardFloorAboveSoftFloor)
      "memory.min above memory.low makes the soft floor dead -- the hard one already protects that much unconditionally")

    (check "native/beside-a-cluster-builds-fine"
      (!(nixosBuildFails nativeBesideCluster))
      "a desktop session on the metal alongside a k3s node is the mixed-host case this member exists for and must evaluate")

    (check "native/claim-counts-in-the-parent-sum"
      (nixosBuildFails nativeCountsInTheSum)
      "40960 native + 32768 cluster exceeds a 65536MiB host, and ONLY once the native claim is counted -- a module that accepted `native` as a label but skipped it in the fold would pass this, which is the whole failure the member was added to prevent")

    (check "native/is-subject-to-gpu-conflict-detection"
      (nixosBuildFails nativeGpuConflict)
      "a native tenant claiming a card exclusively while a cluster node claims it shared is one piece of silicon with two contradictory promises -- being on the metal rather than in a container must not exempt a claimant from the conflict check")

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
  ];

  # ── The mirrors: one fact, one owner, one value ───────────────────────────────────────────────
  #
  # These are the tests that would have been impossible before, because the facts were declared
  # here: an equality check between a mirror and its source only means something once there IS a
  # source. Note that `resources.gpu`/`net`/`storage.disks` are compared as whole attrsets --
  # nixhost mirrors them opaquely on purpose, so the test asserts identity, not field-by-field
  # agreement it has no business knowing about.
  mirrorResults = [
    (check "mirror/cpu-scalars-mirror-nixcpu"
      (mirrored.cpu.arch == "x86_64"
        && mirrored.cpu.microarch == "x86_64-v3"
        && mirrored.cpu.cores == 16
        && mirrored.cpu.threads == 24
        && mirrored.cpu.scheduler == "bore")
      "every scalar CPU fact must equal the nixcpu option it mirrors -- a mirror that reads a different value than its owner is worse than no mirror")

    (check "mirror/cpu-core-types-mirror-nixcpu"
      (mirrored.cpu.coreTypes == {
        performance = { cores = 8; threadsPerCore = 2; };
        efficiency = { cores = 8; threadsPerCore = 1; };
      })
      "coreTypes is the field nixhost lacked entirely before this change: nixcpu owns the P/E split, and it must be readable at this namespace's own path")

    (check "mirror/ram-total-mirrors-nixram"
      (mirrored.ram.totalMiB == 131072)
      "the RAM ceiling must equal nixram.hardware.totalMiB, in the same unit -- a conversion here would be a silent factor of 1024")

    (check "mirror/gpu-inventory-mirrors-nixgpu"
      (mirrored.gpu == { gpu0 = { vendor = "amd"; pciId = "0x1002"; vramMiB = 16384; }; })
      "the device table must be nixgpu's own, passed through unchanged -- including fields nixhost never reads")

    (check "mirror/net-interfaces-mirror-nixnet"
      (mirrored.net == { lan0 = { mac = "aa:bb:cc:dd:ee:ff"; addresses.lan = "192.0.2.10"; }; })
      "the interface table must be nixnet's own (nixnet.interfaces), passed through unchanged")

    (check "mirror/disks-mirror-nixstorage"
      (mirrored.storage.disks == { pool0 = { device = "/dev/disk/by-id/ata-EXAMPLE_A"; }; })
      "the oldest mirror in this module, and until now only ever proven EMPTY: a populated nixstorage.disks must arrive here verbatim")

    (check "mirror/every-mirror-populated-builds-fine"
      (!(nixosBuildFails everyMirrorPopulated))
      "a host with every level-1 fact stated at its owner must build -- if this fails, the mirrors themselves broke the module")

    (check "mirror/absent-domains-resolve-to-empty-not-an-error"
      (unmirrored.cpu.arch == null
        && unmirrored.cpu.microarch == null
        && unmirrored.cpu.cores == null
        && unmirrored.cpu.threads == null
        && unmirrored.cpu.coreTypes == null
        && unmirrored.cpu.scheduler == null
        && unmirrored.ram.totalMiB == null
        && unmirrored.gpu == { }
        && unmirrored.net == { }
        && unmirrored.storage.disks == { })
      "with no domain module present at all, every defensive read must take its fallback -- a host may import nixhost without owning nixcpu/nixram/nixgpu/nixnet/nixstorage")

    (check "mirror/host-with-no-domains-builds-fine"
      (!(nixosBuildFailsBare noDomainsAtAll))
      "nixhost alone must be adoptable: a host that mirrors nothing and claims nothing has no missing ceiling and must build")

    (check "mirror/setting-cpu-cores-directly-fails-the-build"
      (nixosBuildFails cpuCoresSetDirectly)
      "nixhost.resources.cpu.cores is readOnly -- setting it must FAIL rather than override the mirror, or the fact is typeable in two places again")

    (check "mirror/setting-gpu-directly-fails-the-build"
      (nixosBuildFails gpuSetDirectly)
      "nixhost.resources.gpu is readOnly -- a device declared here instead of in nixgpu must fail the build")

    (check "mirror/setting-net-directly-fails-the-build"
      (nixosBuildFails netSetDirectly)
      "nixhost.resources.net is readOnly -- an interface declared here instead of in nixnet must fail the build")
  ];

  # ── The ceilings: MIRROR + ASSERT-RESOLVED ───────────────────────────────────────────────────
  #
  # THE REGRESSION THIS GROUP EXISTS FOR: `cores` and `totalMiB` stopped being required options
  # when they became mirrors, and a mirror resolves to `null` on a host that does not own the
  # domain. Every oversubscription check is a comparison against those numbers, so a null one does
  # not loosen a check, it deletes it -- silently, with a green build. Each fixture below pairs a
  # claim with a missing ceiling and must FAIL; the last one pairs no claim with a missing ceiling
  # and must PASS, because a guard that fires when nothing depends on the fact is a guard nobody
  # can adopt.
  ceilingResults = [
    (check "ceiling/ram-claim-with-no-nixram-fails-the-build"
      (nixosBuildFailsBare ramClaimNoDomains)
      "an environment claiming RAM on a host whose totalMiB never resolved must FAIL -- passing here means the oversubscription check compared against nothing and reported success")

    (check "ceiling/cpu-claim-with-no-nixcpu-fails-the-build"
      (nixosBuildFailsBare cpuClaimNoDomains)
      "an environment claiming CPU on a host whose core count never resolved must FAIL, for the same reason")

    (check "ceiling/ram-claim-with-the-fact-unstated-fails-the-build"
      (nixosBuildFails ramClaimFactUnstated)
      "nixram imported but hardware.totalMiB never set must fail just as loudly as nixram not being imported at all -- from this module's side the two are the same absence")

    (check "ceiling/cpu-claim-with-the-fact-unstated-fails-the-build"
      (nixosBuildFails cpuClaimFactUnstated)
      "nixcpu imported but cores never set must also fail -- and reach nixhost's own assertion rather than aborting out of the option default, which is what `lib.probeFact` exists to guarantee")

    # nixcpu declares `arch` with no default, so this fixture is also the one that proves
    # `lib.probeFact` turns that into a `null` this module can reason about: without it the failure
    # would be an abort from inside an option default, and `archUnresolved` would be unreachable code.
    (check "ceiling/microarch-without-a-resolved-arch-fails-the-build"
      (nixosBuildFails microarchWithoutArch)
      "a microarch with no arch to check it against must never pass quietly -- the cross-check compares the two, so an unresolved arch would leave it vacuously true")

    (check "ceiling/domains-imported-but-nothing-stated-builds-fine"
      (!(nixosBuildFails domainsImportedNothingStated))
      "a host with the domains imported and no fact stated must build: nixcpu's arch/cores/threads have no default upstream, so this fails the moment anything reads a mirror it does not need -- including the readOnly-override check, which forces every definition's value")

    (check "ceiling/environments-that-claim-nothing-need-no-ceiling"
      (!(nixosBuildFailsBare environmentsWithoutClaimsNoDomains))
      "environments may exist, and may claim a GPU, on a host that owns none of the mirrored domains: the assert-resolved guards must fire only when something actually divides against a missing ceiling")
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

    (check "backend-parity/unresolved-ram-ceiling-fails-on-both"
      (nixosBuildFails ramClaimFactUnstated && smBuildFails ramClaimFactUnstated)
      "the assert-resolved half is pure `config.assertions` like everything else here, so both backends must refuse an unresolved ceiling identically")
  ];

  # ── The shipped example: a complete, self-contained stub host ────────────────────────────────
  #
  # Composed with the same domain stubs as everything above, because the example states its facts
  # where they are owned (`nixcpu.cores`, not `nixhost.resources.cpu.cores`) and a real host gets
  # those paths by importing the domain repos -- which this one takes no input on.
  exampleHost = lib.nixosSystem {
    inherit system;
    modules = [ nixhostModule domainStubs ../examples/host/configuration.nix ];
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

  # The CROSS-NAMESPACE group: `lib/facts.nix`. `factsResults` needs no NixOS evaluation at all
  # (see that file's own header for why `probeFact` touches nothing module-system-specific), and
  # `factsIntegrationResults` is the companion that composes it against a real module eval for the
  # two things a plain-data fixture cannot show: a genuine mandatory-unset option throwing the
  # module system's own error, and requirement 4 proven against a real, genuinely-unbuildable
  # `system.build.toplevel` sitting right beside the namespace being probed.
  factsResults = import ./facts.nix { inherit lib probeFact collectProbes; };
  factsIntegrationResults = import ./facts-integration.nix { inherit pkgs lib nixpkgs system probeFact; };

  # The THIRD leg of the fact-reporting proof, and the only one that composes the real
  # `modules/nixhost.nix` -- see the fixtures' own header just above `## Results` for why the other
  # two are not enough on their own.
  factWiringResults = [
    (check "fact-wiring/fully-populated-host-has-no-warnings"
      ((evalNixos everyMirrorPopulated).warnings == [ ])
      "a host with every level-1 fact genuinely stated at its owner must produce zero warnings through the real module's own wiring -- any warning here is a false positive in `extraFactWarnings`, not a real defect")

    (check "fact-wiring/no-domains-at-all-has-no-warnings"
      ((evalNixosBare noDomainsAtAll).warnings == [ ])
      "state (a), wired through the real module: a host importing none of the five domains must report zero warnings -- absence is silent, not merely non-fatal")

    (check "fact-wiring/domain-composed-nothing-stated-warns-once-for-the-one-mandatory-extra-field"
      (let w = (evalNixos domainsImportedNothingStated).warnings; in
        lib.length w == 1 && lib.hasInfix "nixcpu.threads" (lib.head w))
      "nixcpu composed and nothing stated: arch/cores are ceilings (silent here, since nothing claims RAM/CPU -- see the ceiling group above) and microarch/coreTypes/scheduler resolve cleanly through their own real defaults, but threads has no default upstream either and carries no ceiling to gate an assertion on -- it must be the one and only warning produced, not zero and not more than one")

    (check "fact-wiring/real-rename-of-a-non-ceiling-mirror-warns-through-the-real-module"
      (let w = nixgpuRenamedEval.warnings; in
        lib.length w == 1
        && lib.hasInfix "nixgpu.stableDevicePaths.devices" (lib.head w)
        && lib.hasInfix "nixgpu" (lib.head w)
        && lib.hasInfix "{ }" (lib.head w))
      "the decoy that matters most: nixgpu genuinely composed (as `inventory`, not `stableDevicePaths.devices`) through the REAL nixhostModule -- if `gpuProbe`'s call site ever gets its namespace or path wrong, or drops out of `extraFactWarnings`, this is what stops reporting it. The one warning must name the option path, the namespace, and the fallback (`{ }`) actually in use, per requirement 2")

    (check "fact-wiring/real-rename-of-a-non-ceiling-mirror-does-not-fail-the-build"
      (!(buildFails nixgpuRenamedEval))
      "requirement 3: warn is the default. A renamed non-ceiling mirror must never fail the build on its own through the real module's wiring -- only mode = \"assert\" (which this module does not use for these seven) would do that")
  ];

  results = moduleResults ++ mirrorResults ++ ceilingResults ++ backendParityChecks ++ exampleResults ++ hostsResults ++ factsResults ++ factsIntegrationResults ++ factWiringResults;

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
