# modules/nixhost.nix
#
# THE NAMESPACE ROOT: one host, addressed as a path. `nixhost.name` is the first segment
# of every fact this family can state about a machine -- `fileserver.storage.disks.solid0`,
# `workstation.cpu.microarch`, `fileserver.k3s.gpu.gpu0` -- and this module is where that
# segment, and everything hanging off it, gets declared and checked. It is imported ONCE per
# host, by that host's own configuration, never by a registry describing many hosts at once
# (that's a cross-host registry's job -- this module is imported once PER HOST, by that host's
# own configuration).
#
# THIS MODULE IS PURE DATA. Read that literally: no `systemd.services`, no
# `environment.systemPackages`, no `pkgs` argument at all -- nothing this module declares ever
# runs, installs a package, or configures a device. That is what makes the same file loadable,
# unchanged, as `nixosModules`, `systemManagerModules`, AND `darwinModules` (see flake.nix and
# this file's own "THREE BACKENDS, ONE FILE" note below) -- a Mac under nix-darwin has just as
# much of a CPU, a RAM total, and a set of environments standing on it as a NixOS server does,
# and none of that is a NixOS-specific concept. The precedent this follows exactly is nixiam's
# `modules/posix.nix`: no `pkgs`, nothing that runs, so importing it costs a host nothing beyond
# the fact table itself.
#
# ── Two levels, and why they are never the same object ──────────────────────────────────────
#
# LEVEL 1 (`resources`) is the machine itself: how many cores it physically has, how much RAM
# is actually installed, which GPUs are actually plugged in. LEVEL 2 (`environments`) is
# whatever stands ON that machine and consumes a PROJECTION of it -- a k3s node that is capped
# to 100 GiB out of 128 GiB actually installed, a podman container denied the GPU entirely, a VM
# quota-limited to 24 of 32 threads. An environment's `resources` block is never the level-1
# block reused or aliased -- it is an independent claim this module can check FOR CONSISTENCY
# against the level-1 total, which is the one thing nothing in this family could do before this
# repo existed: sum every environment's claimed RAM and compare it to what the host actually
# has, and refuse to evaluate if the claims don't fit.
#
# ── Why a GPU has two parents, and what that means for this file ────────────────────────────
#
# A GPU plugged into one host is simultaneously consumed by bare-metal apps on that host AND by
# whatever pods a k3s environment standing on the SAME host schedules onto it --
# `fileserver.gpu.gpu0` and `fileserver.k3s.gpu.gpu0` are two different paths into the
# same physical card. That is why `environments.<name>.resources.gpu.<gpuName>.access` is keyed
# by the SAME name as `resources.gpu.<gpuName>` rather than each environment inventing its own
# private GPU namespace -- two environments claiming the identically-named device are, in
# reality, contending for one piece of silicon, and the exclusive/shared conflict check below
# only means anything because the name is shared.
#
# ── LEVEL 1 IS A MIRROR. NOTHING HERE DECLARES A HARDWARE FACT. ──────────────────────────────
#
# Every option under `resources` is `readOnly`, and its default is read defensively out of the
# repository that OWNS the fact: `nixcpu` for the CPU, `nixram` for the RAM total, `nixgpu` for the
# device inventory, `nixnet` for the interface table, `nixstorage` for the disks. The rule is
# literal -- if you want to know what CPU a host has, that must live in exactly ONE spot. A second
# typeable copy here would not be redundancy, it would be drift with a delay: two numbers that
# agree on the day they are written and disagree the day a card is swapped, with nothing comparing
# them. `readOnly` is what makes that structural rather than a convention: the option's own default
# counts as a definition, so a host that sets one of these has "set it multiple times" and gets a
# build failure -- reported by this module's own assertion, naming the owning option to use instead,
# rather than as an override that quietly wins.
#
# The idiom is `config.<domain>.<path> or <empty>` -- never a flake input on the domain. This repo
# takes no input but a checks-only nixpkgs, and that is load-bearing in BOTH directions: a domain
# repo has to stay usable by someone who has never heard of nixhost (so the dependency can only
# point this way), and a host has to be able to import nixhost while owning only some of the
# domains (so the read has to tolerate the domain being absent, resolving to `null`/`{ }` rather
# than erroring). `mirrorOf` below is that read, and its own comment covers the one case a bare
# `or` gets wrong -- a domain imported with the fact never stated, which is not the same absence but
# means the same thing here.
#
# ── ...and why some of those mirrors need an assertion the others don't ──────────────────────
#
# `cpu.cores` and `ram.totalMiB` are not merely facts here, they are the CEILINGS the
# oversubscription arithmetic divides against. An empty disk table or an empty GPU inventory is a
# legitimate state -- a host with nothing recorded and no card plugged in -- but a missing core
# count is not: every comparison against it becomes vacuously true, so the check reports success
# while checking nothing. That is strictly WORSE than the required option it replaced, and it is
# worse in the invisible direction: no message, no warning, a green build.
#
# So a mirrored CEILING carries a third part -- MIRROR + ASSERT-RESOLVED: `readOnly`, a defensive
# default, AND an assertion that fires whenever something actually depends on the ceiling and it
# did not resolve. "Something depends on it" is deliberately not restated as its own predicate: it
# is `claimed > 0`, computed by the very fold that would otherwise have divided against the missing
# ceiling (see `budgetsFor` below), so the guard cannot drift out of step with the arithmetic it
# guards. A host with no environments is never asked for a ceiling it has no use for.
#
# `cpu.arch` carries the same kind of assertion one step removed: not a ceiling, but the one value
# the microarch cross-check compares against, so an unresolved `arch` makes that check vacuous in
# exactly the same way. Every other mirror is plain, because no check here depends on it -- and that
# is the whole rule for when to add one: an assertion belongs on a mirror if, and only if, something
# in this module would otherwise stop working without saying so.
#
# ── What this module refuses to own ──────────────────────────────────────────────────────────
#
# - HOW a domain works. A GPU exists here only as whatever nixgpu's own inventory says it is;
#   nixgpu decides the scheduling mechanism that shares it. A disk exists here only as
#   nixstorage's own table; nixstorage decides its filesystem shape.
# - POLICY. Which services actually run on a host is that host's own configuration, not this
#   module's business -- `environments.<name>` says a k3s node exists and how much of the host
#   it may claim, never which pods it runs.
# - DERIVED CONFIG. The moment a fact declared here turns into a tuning value (a cgroup weight,
#   a nice level, a specific kernel parameter), this stops being a one-way fact table and
#   becomes a policy engine with an opinion. Enums and quantities go in; nothing computed from
#   them is allowed to live here.
#
# ── THE SUBSTRATE CONTRACT: one declaration, four mechanisms ─────────────────────────────────
#
# `environments.<name>` is the seam between this module and the repositories that actually build
# a second-level entity. Every substrate -- k3s, vm, podman, lxc -- is a different mechanism, and
# they deliberately share no implementation: a cluster with a control plane, hardware emulation,
# an OCI runtime and a system container have nothing in common at the code level. What they DO
# share is the declaration, and it lives here.
#
# The division, and the reason it is worth having:
#
#   THIS MODULE declares that an environment EXISTS, what KIND it is, and what ENVELOPE it may
#   claim -- RAM, physical cores, and its access stance on each named GPU. It also owns the only
#   arithmetic nothing else can do: summing what every environment on a host claims and refusing
#   to evaluate when the total exceeds what the host actually has.
#
#   A SUBSTRATE REPO reads its own slice and builds the thing. It must NOT declare a second
#   resource envelope of its own. A substrate that grows its own `memoryLimit` beside
#   `environments.<name>.resources.ram.limitMiB` has created a fact with two owners, and the
#   oversubscription assertion above then guards a number nobody is using -- which is worse than
#   no assertion, because it reads as coverage.
#
# Read this slice DEFENSIVELY (`config.nixhost.environments or { }`), never as a flake input on
# this repo: the same one-way rule every other consumer in this family follows, so a substrate
# stays independently usable by someone who has never imported nixhost.
#
# ── ONE HOST HERE; MANY HOSTS IN `lib/hosts.nix` ───────────────────────────────────────────
#
# This module is imported once PER HOST, by that host's own configuration, and every assertion
# below validates that host against ITSELF. The cross-host half is deliberately not a module at
# all: `lib.assertHosts` is a plain function over plain data, because per-host validity is not
# validity across hosts -- two hosts can each be correct by every assertion either one is able to make
# about itself while both claim the same physical disk. Nothing here can see that; the fact that
# makes it wrong lives in the other host's configuration.
#
# The split is also a cost boundary, measured in `studies/eval-cost/`: a cross-host read through
# the module system is the one read shape that goes nonlinear (~2.6 h at 100 hosts against
# ~0.05 s for the same assertion over plain data), so the cross-host checks must never reach
# into another host's `config`.
#
# A SLUG NAMES A POSITION, NOT A PHYSICAL OBJECT. `nixhost.name` is reusable on purpose: replace
# a machine and its successor keeps the slug, because every cross-host reference to it stays
# valid. Hardware identity therefore lives entirely in the domain tables -- a disk's by-id path,
# an interface's address -- and those are what change on a replacement, never the name.
{ config, options, lib, ... }:

with lib;

let
  cfg = config.nixhost;

  # ── Reading a fact out of the domain that owns it, without depending on that domain ──────────
  #
  # Every level-1 mirror's default goes through here. `config.<domain>.<path> or <fallback>` is the
  # family idiom and does most of the work, but it has ONE hole, and closing it is what this helper
  # is for: `or` tests whether the attribute PATH exists, and a declared option's path exists the
  # moment its module is imported, definition or not. So for a domain field with no default upstream
  # (`nixcpu.arch`, `nixcpu.cores`, `nixcpu.threads` are all required at the owner), `or` does not
  # return the fallback -- it returns the module system's own throwing thunk, and forcing it aborts
  # evaluation with "The option `nixcpu.cores' is used but not defined."
  #
  # Two absences, one meaning. "The domain is not imported" and "the domain is imported but the fact
  # was never stated" are, from this module's side, the same situation: there is no fact to mirror.
  # Collapsing them into `null` here is what lets the ASSERT-RESOLVED assertions below report BOTH
  # with a message that can say which option to set and why this module needed it -- rather than one
  # producing a tidy assertion and the other a raw abort from the middle of an option default, where
  # nothing can add context to it.
  #
  # ⚠ WHAT THIS COSTS, because it is not free: `tryEval` also swallows a genuine TYPE error from the
  # owner. A `nixcpu.cores = "sixteen"` rejected by nixcpu's own `ints.positive` arrives here as
  # `null` and is reported as an unresolved fact rather than a rejected value -- a real
  # misdiagnosis, and the reason every assert-resolved message below explicitly names all three
  # causes and tells the operator to evaluate the owner's option directly to tell them apart. The
  # alternative was leaving the raw abort in place for that one case, which buys a precise message
  # for a rare mistake at the price of an inconsistent failure mode for a common one (and, as the
  # `overriddenMirrors` check below found the hard way, at the price of not being able to inspect a
  # mirror's definitions at all: the module system forces every definition's value while discharging
  # `mkIf`/`mkMerge`, so a throwing default poisons even a question as small as "how many
  # definitions does this option have").
  #
  # Not deep: `tryEval` forces to WHNF, so a throw nested inside a mirrored attrset still surfaces
  # at whoever reads that far in. That is correct -- the inside of a mirrored table is the owner's
  # business, and an error from it should be reported by the owner's own words.
  mirrorOf = fallback: read:
    let attempt = builtins.tryEval read;
    in if attempt.success then attempt.value else fallback;

  # A quantity that must be strictly positive, and may be fractional -- the shape a CPU quota
  # claim actually needs (podman and cgroup quotas are routinely expressed as e.g. 1.5 cores),
  # which no single `types.ints.*` helper covers on its own.
  positiveNumber = types.addCheck
    (types.either types.int types.float)
    (x: x > 0);

  # ── Level 2: one environment's stance on one named GPU ─────────────────────────────────────
  gpuClaimSubmodule = types.submodule {
    options = {
      access = mkOption {
        type = types.enum [ "none" "shared" "exclusive" ];
        default = "none";
        description = ''
          What this environment is allowed to do with the identically-named
          `resources.gpu.<name>` entry: `"none"` (the default -- claiming nothing is always
          safe and never conflicts with anything), `"shared"` (this environment co-resides with
          any number of other `"shared"` claimants), or `"exclusive"` (no other environment may
          claim this device at all, in ANY access mode). Two environments both claiming the
          same device -- one `"exclusive"`, the other anything else -- is asserted below as a
          hard conflict, never resolved by precedence: an exclusive claim that silently loses to
          a scheduling decision is worse than a build failure that says so up front.
        '';
      };
    };
  };

  # ── Level 2: one environment standing on this host ─────────────────────────────────────────
  environmentSubmodule = types.submodule {
    options = {
      kind = mkOption {
        type = types.enum [ "k3s" "vm" "podman" "lxc" ];
        example = "k3s";
        description = ''
          What kind of environment this is. Required, with no default: an environment this
          module cannot classify is one whose resource claims cannot be reasoned about at all
          -- there is no safe generic guess between "a whole VM" and "one podman container"
          that would not misrepresent the claim to whoever reads this table next.

          Each member of this enum has exactly one implementing repository, and this option is
          the seam between them: `k3s`, `vm`, `podman` and `lxc` are four different mechanisms
          -- a cluster with a control plane, hardware emulation, an OCI runtime, a system
          container -- that share a DECLARATION and share almost no code. Adding a member here
          is how a new substrate becomes a first-class peer of the others.
        '';
      };

      resources = {
        ram = {
          limitMiB = mkOption {
            type = types.nullOr types.ints.positive;
            default = null;
            example = 102400;
            description = ''
              This environment's own RAM ceiling, or `null` (the default) for an environment
              that claims no enforced limit at all -- a podman container run with no `-m` flag,
              say. `null` is excluded from the oversubscription sum below entirely, on purpose:
              an unlimited environment makes no claim to check against the host total, and
              treating an absent limit as zero would silently let every OTHER environment's
              claims run right up to the host's full total as if this one used nothing, which
              is the opposite of conservative.
            '';
          };
        };

        cpu = {
          quotaCores = mkOption {
            type = types.nullOr positiveNumber;
            default = null;
            example = 24;
            description = ''
              This environment's own CPU ceiling, in CORES (not threads -- see
              `resources.cpu.cores`'s own description for why the distinction is load-bearing),
              fractional values allowed (a cgroup quota of 1.5 cores is a real, common shape).
              `null` (the default) means no enforced ceiling; excluded from the
              oversubscription sum below for the same reason `ram.limitMiB`'s absence is: an
              unlimited environment makes no claim, and defaulting it to zero would understate
              every other environment's real contention for the same cores.
            '';
          };
        };

        gpu = mkOption {
          type = types.attrsOf gpuClaimSubmodule;
          default = { };
          description = ''
            This environment's stance on zero or more of the host's `resources.gpu.<name>`
            devices, keyed by the SAME name as that table -- see this file's own header for why
            a GPU has two parents and the name has to agree for the conflict check below to
            mean anything. An environment with no entry here makes no claim on any GPU at all,
            equivalent to every device defaulting to `"none"`.

            ⚠ GPU NAMES ARE HOST-SCOPED AT EVERY DEPTH, including inside a nested environment.
            `host.vm.container.gpu.rx6800` is physically the SAME card as `host.gpu.rx6800` --
            passing a device through to a guest does not mint a new one. So the conflict check
            below flattens claims across the WHOLE tree, not one level of it: without that, a VM
            claiming a card `exclusive` and a container three levels down claiming it `shared`
            would never be detected, and exactly one of those two promises is a lie.
          '';
        };
      };

      # ── The recursion. An environment may itself host environments. ─────────────────────────
      #
      # Nesting is not a nicety, it is what the namespace actually describes. Bare metal is
      # `host.gpu.app`; a container inside a VM is `host.vm.container.gpu.app`. The path is as
      # long as the nesting is deep, and capping it at one level would make the model unable to
      # state the ordinary case of a VM that runs containers.
      #
      # This is a SELF-REFERENTIAL type, and it terminates because Nix is lazy: an option's
      # `type` is only forced when something actually reads that deep, so the definition may
      # name itself without recursing at evaluation time.
      #
      # The consequence for every check below: an envelope is a projection of its IMMEDIATE
      # PARENT, never of the host. A container inside a VM capped at 8 GiB cannot claim 16 GiB
      # however much the host has, so the arithmetic is a walk that compares each node against
      # its own parent -- not a single sum against the top-level total.
      environments = mkOption {
        type = types.attrsOf environmentSubmodule;
        default = { };
        description = ''
          Environments standing on THIS environment, same shape as the host's own
          `environments` -- a VM that runs podman containers, a k3s node inside a VM.

          Empty (the default) for a leaf. What breaks without it: the namespace could not
          express `host.vm.container.gpu.app` at all, and a container's claim would have to be
          declared as though it stood directly on the host -- which would check it against the
          wrong ceiling and let a guest over-claim its own parent silently.
        '';
      };
    };
  };

  # ── Consistency arithmetic ──────────────────────────────────────────────────────────────────

  # ── The tree walk ───────────────────────────────────────────────────────────────────────────
  #
  # `environments` is recursive (see the submodule above), so none of this can be a single sum
  # over one level. Every check below walks the whole tree and compares each node against its
  # OWN parent's ceiling -- a container inside a VM capped at 8 GiB is over-committed at 16 GiB
  # regardless of how much the host has, and a flat sum against the host total would call that
  # fine.
  #
  # Paths are carried through the walk so a violation can name the offender as
  # `host.vm1.pod1` rather than just "some environment". At depth 3 in a tree of a dozen
  # environments, a message that cannot say WHERE is a message nobody can act on.

  # ONE traversal, feeding every check below. An earlier draft of this walked the tree twice --
  # once for GPU claims and once, separately, inside the overcommit check -- and passed `null` as
  # a stand-in for "the host" so the two could share a ceiling function. Two traversals of the
  # same tree is two places for a depth bug to hide, and the null-as-host trick meant the host
  # was not really a node like the others. Both are gone: the host is now simply the root
  # container, and everything derives from a single list.

  # Every CONTAINER of environments, root first, then each environment that itself hosts more.
  # `ceilings` is what that container has to give out; `children` is what claims it.
  #
  # `ceilingIsMirrored` is the one field that is not about arithmetic: it records WHERE this
  # container's ceiling came from, because that decides what a `null` ceiling MEANS. On a nested
  # container the ceiling is an operator-declared limit and `null` is a real, final answer --
  # "unlimited", see `ram.limitMiB`'s own description. On the root it is a mirror of a domain fact,
  # and `null` means the fact never arrived, which is not a host with no limit but a check with
  # nothing to check against. Same value, opposite meanings; only the origin distinguishes them.
  envContainers =
    let
      walk = prefix: envs:
        concatMap
          (n:
            let node = envs.${n}; here = "${prefix}.${n}"; in
            [{
              path = here;
              children = node.environments;
              ram = node.resources.ram.limitMiB;
              cpu = node.resources.cpu.quotaCores;
              ceilingIsMirrored = false;
            }]
            ++ walk here node.environments)
          (attrNames envs);
    in
    [{
      path = "host";
      children = cfg.environments;
      ram = cfg.resources.ram.totalMiB;
      # Physical cores, never threads: SMT adds schedulable slots, not execution capacity.
      cpu = cfg.resources.cpu.cores;
      ceilingIsMirrored = true;
    }]
    ++ walk "host" cfg.environments;

  # Every environment node, derived from the same walk rather than re-walking.
  allEnvNodes =
    concatMap
      (c: map (n: { path = "${c.path}.${n}"; env = c.children.${n}; }) (attrNames c.children))
      envContainers;

  # Children's claims summed against the ceiling of the container they actually stand in. `null`
  # is excluded rather than counted as zero, for the reason each option's own description gives:
  # an unlimited environment makes no bounded claim, and counting it as zero would let every
  # sibling run up to the full ceiling as though this one used nothing.
  #
  # BOTH questions asked below are answered from this ONE record, on purpose: "do the claims fit?"
  # is `claimed > ceiling`, and "is there a ceiling to fit them under at all?" is `claimed > 0`
  # beside a `null` ceiling. The second is the MIRROR + ASSERT-RESOLVED half (see this file's
  # header), and the reason it is derived from the same fold rather than written as its own
  # traversal of `cfg.environments` is that a separately-written "does anything depend on this
  # ceiling" test can drift out of step with the arithmetic it exists to protect -- and the failure
  # mode of that drift is the silent one, a guard that has quietly stopped guarding.
  budgetsFor = pick: map
    (c: {
      inherit (c) path ceilingIsMirrored;
      claimed = foldl'
        (acc: n: let v = pick c.children.${n}; in if v == null then acc else acc + v)
        0
        (attrNames c.children);
      ceiling = pick { resources = { ram.limitMiB = c.ram; cpu.quotaCores = c.cpu; }; };
    })
    envContainers;

  ramBudgets = budgetsFor (e: e.resources.ram.limitMiB);
  cpuBudgets = budgetsFor (e: e.resources.cpu.quotaCores);

  # `claimed > 0` comes FIRST in both functions below, and that is a statement about MEANING, not a
  # micro-optimisation: a container whose children claim nothing has no use for a ceiling, so its
  # ceiling must not be examined at all -- neither compared against, nor reported as missing. Nix's
  # `&&` short-circuits, so writing the condition in this order says exactly that and costs nothing.
  overcommitted = unit: concatMap
    (b: optional (b.claimed > 0 && b.ceiling != null && b.claimed > b.ceiling)
      "${b.path}: its environments claim ${toString b.claimed} ${unit}, but ${b.path} has ${toString b.ceiling} ${unit}");

  # A ceiling that came from a MIRROR and did not resolve, while something depends on it. Only the
  # root container can be in this state (see `envContainers`' own note on `ceilingIsMirrored`), but
  # the test is written over the whole list rather than against the root by index: if a second
  # mirrored ceiling ever appears at another depth, this keeps covering it instead of silently
  # covering only the one case its author had in mind.
  ceilingUnresolved = any (b: b.claimed > 0 && b.ceilingIsMirrored && b.ceiling == null);

  ramViolations = overcommitted "MiB" ramBudgets;
  cpuViolations = overcommitted "cores" cpuBudgets;
  ramCeilingUnresolved = ceilingUnresolved ramBudgets;
  cpuCeilingUnresolved = ceilingUnresolved cpuBudgets;

  # Every non-"none" GPU claim in the ENTIRE tree, grouped by device name. Flattened across all
  # depths on purpose: a device name is host-scoped (see the gpu option's own description), so a
  # VM claiming a card exclusively and a container three levels down claiming it shared are
  # contending for one piece of silicon and must collide here.
  gpuClaimsByDevice =
    foldl'
      (acc: node:
        foldl'
          (acc2: gpuName:
            let access = node.env.resources.gpu.${gpuName}.access;
            in
            if access == "none" then acc2
            else acc2 // {
              ${gpuName} = (acc2.${gpuName} or [ ]) ++ [{ env = node.path; inherit access; }];
            })
          acc
          (attrNames node.env.resources.gpu))
      { }
      allEnvNodes;

  # A device is in conflict when more than one environment claims it AND at least one of those
  # claims is "exclusive" -- any number of "shared" claimants alone is fine (that is the whole
  # point of "shared"); two "exclusive" claimants, or one "exclusive" beside any other claim,
  # both count. Not a precedence puzzle: exactly one of the two promises is false, and resolving
  # it by attribute ordering would silently pick a winner.
  gpuConflicts = filterAttrs
    (_: claims: length claims > 1 && any (c: c.access == "exclusive") claims)
    gpuClaimsByDevice;

  # `x86_64-v1`..`-v4` are the real psABI microarchitecture levels CachyOS kernel package names
  # carry (`linux-cachyos-…-x86_64-v3`); an aarch64-family string here
  # (`armv8.2-a`, a bare `arm`/`aarch64` prefix) is the mirror-image mistake. Vendor-specific
  # names that classify as neither (`apple-m1`, `neoverse-n1`, `cortex-a76`, `bore` -- which is
  # a SCHEDULER, not a microarch, and belongs in `scheduler` instead) are deliberately left
  # unclassified rather than forced into either bucket: this check exists to catch the ONE
  # concrete, silent typo the spec names (an x86_64 psABI string surviving a copy-paste onto an
  # aarch64 host, or vice versa), not to police every microarch string the world might spell.
  looksLikeX86Microarch = s: builtins.match "x86_64(-v[1-4])?" s != null;
  looksLikeAarch64Microarch = s: builtins.match "(aarch64|arm|armv[0-9].*)(-.*)?" s != null;

  # ⚠ THIS CHECK IS NOT REDUNDANT WITH nixcpu's OWN arch/microarch ASSERTION, even though both
  # values are now mirrored out of nixcpu. nixcpu's version lives inside its `config = mkIf
  # cfg.enable`, so it runs only for a host that turns nixcpu's policy on -- while the FACTS
  # resolve regardless of `enable`, because nixcpu declares them outside that `mkIf`. A host that
  # states nixcpu facts for something else to read, without enabling nixcpu itself, is therefore a
  # host whose arch/microarch coherence nothing upstream ever looked at, and this is the only place
  # that still does.
  #
  # `microarch != null` FIRST, and `arch != null` before either classifier: both operands are
  # mirrors now, and each may be absent independently (a host with nixcpu imported but only some
  # fields set, or no nixcpu at all). Forcing `arch` when no microarch was declared would turn a
  # perfectly ordinary host -- nixhost imported, nixcpu not -- into a build failure over a fact
  # nothing on it uses.
  microarchMismatch =
    cfg.resources.cpu.microarch != null && cfg.resources.cpu.arch != null && (
      (cfg.resources.cpu.arch != "x86_64" && looksLikeX86Microarch cfg.resources.cpu.microarch) ||
      (cfg.resources.cpu.arch != "aarch64" && looksLikeAarch64Microarch cfg.resources.cpu.microarch)
    );

  # The ASSERT-RESOLVED companion to the check above, and the same reasoning as the RAM/CPU
  # ceilings: `microarch` is compared against `arch`, so an unresolved `arch` does not relax that
  # comparison, it deletes it -- `microarchMismatch` would sit at `false` forever and report a
  # clean bill of health for a host whose two CPU facts were never compared at all.
  #
  # Reachable precisely BECAUSE the mirrors resolve through `mirrorOf`: nixcpu declares `arch` with
  # no default, so without that collapse an unstated `arch` would abort evaluation with the module
  # system's own message instead of arriving here as `null`, and this assertion would be the
  # unreachable half of a pair (which is what an earlier draft of this module measured, before
  # `mirrorOf` existed). A host with a microarch and no arch is a host nixcpu itself only refuses
  # when `nixcpu.enable` is true, so this is the check that covers the fact-only case.
  archUnresolved = cfg.resources.cpu.microarch != null && cfg.resources.cpu.arch == null;

  # ── A mirror with a SECOND definition, caught where it was typed ─────────────────────────────
  #
  # `readOnly` already refuses a host's own definition on any of these options: the option's default
  # counts as a definition, so a single external one is already "set multiple times". But it refuses
  # it at READ time, and this module reads its own mirrors lazily on purpose (see the operand-order
  # note above -- forcing a ceiling nothing depends on would fail a host that has no use for it).
  # The gap that leaves is narrow but exactly the wrong shape: a stray
  # `nixhost.resources.cpu.cores = 8` on a host that claims no CPU is never read, therefore never
  # rejected, and reads to whoever wrote it as accepted. It could never mislead a CONSUMER -- any
  # read of that option throws instead of returning 8 -- but a second copy of a fact should fail at
  # the spot where it was typed, not at whoever happens to read it next, and this repo's entire
  # claim is that there is no such second spot.
  #
  # So the check below asks a different question: how many definitions does the option have? One (its
  # own default) is right; a second means a host declared a fact it can only mirror. `tryEval` is how
  # that question gets asked, because the module system reports a readOnly violation by throwing
  # from the option itself rather than by returning anything inspectable.
  #
  # ⚠ THIS ONLY WORKS BECAUSE THE DEFAULTS GO THROUGH `mirrorOf`, and finding that out is what
  # bought that helper. Reading `opt.definitions` is not the cheap structural question it looks
  # like: the module system discharges `mkIf`/`mkMerge` properties while building the definition
  # list, which FORCES every definition's value -- including the option's own default. With a
  # default that throws (a domain imported without the fact stated), this check therefore reported a
  # phantom "you declared this twice" on a host that had declared nothing at all. `mirrorOf` makes
  # every default resolve to a value instead of a throw, which leaves the readOnly violation as the
  # only thing left in here that can throw.
  mirrorOverridden = opt: !(builtins.tryEval (length opt.definitions)).success;

  overriddenMirrors = filter (m: mirrorOverridden m.opt)
    (
      let r = options.nixhost.resources; in [
        { path = "resources.cpu.arch"; owner = "nixcpu.arch"; opt = r.cpu.arch; }
        { path = "resources.cpu.microarch"; owner = "nixcpu.microarch"; opt = r.cpu.microarch; }
        { path = "resources.cpu.cores"; owner = "nixcpu.cores"; opt = r.cpu.cores; }
        { path = "resources.cpu.threads"; owner = "nixcpu.threads"; opt = r.cpu.threads; }
        { path = "resources.cpu.coreTypes"; owner = "nixcpu.coreTypes"; opt = r.cpu.coreTypes; }
        { path = "resources.cpu.scheduler"; owner = "nixcpu.scheduler"; opt = r.cpu.scheduler; }
        { path = "resources.ram.totalMiB"; owner = "nixram.hardware.totalMiB"; opt = r.ram.totalMiB; }
        { path = "resources.gpu"; owner = "nixgpu.stableDevicePaths.devices"; opt = r.gpu; }
        { path = "resources.storage.disks"; owner = "nixstorage.disks"; opt = r.storage.disks; }
        { path = "resources.net"; owner = "nixnet.interfaces"; opt = r.net; }
      ]
    );
in
{
  options.nixhost = {
    name = mkOption {
      type = types.str;
      example = "fileserver";
      description = ''
        The namespace root: the first path segment of every fact this family can state about
        this host (`<name>.storage.disks.solid0`, `<name>.cpu.microarch`, ...). Required, with
        NO default, on purpose: this is the one field a sensible-looking guess is actively
        dangerous for. A default of, say, `"host"` would type-check on every machine
        simultaneously -- silently giving every host the SAME namespace root, so a
        cross-host reference resolved against one machine's data would resolve just as
        "successfully" against another's. There is no safe default for a value whose entire
        job is to be unique.
      '';
    };

    stance = {
      backend = mkOption {
        type = types.enum [ "nixos" "system-manager" "nix-darwin" ];
        example = "nixos";
        description = ''
          Which of the three backends this file is actually loaded as on this host --
          `nixosModules.nixhost`, `systemManagerModules.nixhost`, or `darwinModules.nixhost`
          (see flake.nix). Required, with no default: this module cannot detect which backend
          composed it without depending on a backend-specific primitive in its OWN option
          surface, which is exactly the thing that would break loading it under the other two
          (see this file's header). A caller states the fact it already knows -- which flake
          output it imported -- rather than this module guessing wrong for the two backends it
          was not loaded under.
        '';
      };

      flavour = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "nixnas";
        description = ''
          The distribution/appliance flavour layered on top of `backend`, in whatever
          vocabulary the operator importing this module actually uses (this family's own repos
          happen to include appliance-flavour projects named things like `nixnas` or `nixarch`
          -- shown here purely as an example spelling, never as a fixed catalogue: a different
          operator's flavours are its own to name). `null` (the default) is the correct, final
          answer for a plain host with no such layer, not a placeholder for "not yet decided".
        '';
      };

      provider = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "metal";
        description = ''
          Where this host actually runs, in whatever vocabulary the operator uses (bare metal, an
          LXC container, a cloud VM -- `"metal"`/`"lxc"`/`"gce"`/`"vultr"` shown only as example
          spellings, an open set that grows by using a new one, never a fixed enum). `null` (the
          default) means this fact simply is not tracked for this host, not that it is unknown.
        '';
      };

      # ── class and role: FACTS ONLY. Nothing here may derive from them. ──────────────────────
      #
      # These two exist because consuming domains need to branch on them, and every domain that
      # needs the answer would otherwise carry its own per-host copy -- which is exactly how one
      # fact ends up typed in five places and drifting in four.
      #
      # ⚠ THE ONE-WAY RULE, and it is why these are declared here and derived nowhere here: the
      # moment this module turns `class` into a value -- a zram percentage, a cgroup weight, a
      # journald cap -- it stops being a fact table and becomes a policy engine with an opinion,
      # and every consumer inherits that opinion whether or not it wanted it. The domain that
      # owns the knob owns the derivation: nixram decides what a memory class implies for zram,
      # a storage domain decides what it implies for a scrub cadence. Enums and quantities in;
      # nothing computed from them lives here.
      #
      # Free-form strings rather than an enum, deliberately, for the same reason as `flavour` and
      # `provider` above: a public module has no business fixing one operator's tier vocabulary.
      class = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "standard";
        description = ''
          The capability tier this host belongs to, in the operator's own vocabulary (something
          like `"tiny"`/`"standard"`/`"fat"`, shown as example spellings only -- an open set,
          never a fixed enum).

          What breaks without it: every domain that must scale a value to the size of the machine
          -- a memory subsystem sizing swap, a deploy pipeline deciding whether a host can afford
          to build in place or must receive a prebuilt image -- has to answer "how big is this
          host" for itself. In practice that means each one grows its own per-host table, and
          those tables drift silently, because nothing compares them. Declared once here, they
          all read the same answer.

          This module never derives anything from it. See the header comment above.
        '';
      };

      role = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "proxy";
        description = ''
          What this host is FOR, in the operator's own vocabulary -- again an open set, never an
          enum.

          What breaks without it: role-keyed policy has nowhere to key off, so "this is the mail
          host" ends up implicit in which modules happen to be imported. That is unstateable and
          therefore uncheckable -- no assertion can compare a host's intended role against what
          it actually got, because the intent was never written down anywhere.

          Distinct from `class` on purpose: two hosts can share a capability tier and do entirely
          unrelated jobs, and collapsing the two into one field forces exactly the kind of
          per-host special-casing this table exists to remove.
        '';
      };
    };

    # ── LEVEL 1: THE MACHINE ITSELF -- AND EVERY FIELD OF IT A MIRROR ────────────────────────
    #
    # Not one option below is settable on a host. Each is `readOnly` with its default read
    # defensively out of the repository that owns the fact, so "what CPU does this host have" has
    # exactly one answer at exactly one address, and this path is a second WAY IN to that answer
    # rather than a second copy of it. See this file's header for the full argument, including why
    # two of these need an assertion the rest do not.
    resources = {
      # ── CPU: field for field, nixcpu's own `options.nixcpu` ─────────────────────────────────
      #
      # nixcpu was already a strict superset of everything this block used to declare by hand, so
      # nothing was dropped in the move and one field was GAINED (`coreTypes`, below) -- the
      # asymmetry resolved in the only direction it could, since nixcpu is the sole owner of CPU
      # topology as a fact and this module has no business being the second place a P/E split can
      # be typed.
      #
      # ⚠ THE TYPES HERE ARE DELIBERATELY LOOSER THAN AT THE OWNER. `arch` is `nullOr str` where
      # nixcpu closes it to a two-member enum, and `microarch` is `nullOr str` where nixcpu closes
      # it to its own `lib/catalogue.nix` keys. That is not laziness: a mirror that restates the
      # owner's catalogue owns a second copy of that catalogue, and the day nixcpu's grows a member
      # -- a third instruction-set family, a fifth psABI level -- the mirror would REJECT a value
      # its owner had already accepted, failing this repo's build over a fact that is none of its
      # business. The constraints kept are only the ones this module's own arithmetic depends on:
      # `cores`/`threads` (and `ram.totalMiB`) stay `ints.positive`, because a zero or negative
      # ceiling would make the comparisons below meaningless rather than merely unfamiliar.
      cpu = {
        arch = mkOption {
          type = types.nullOr types.str;
          readOnly = true;
          default = mirrorOf null (config.nixcpu.arch or null);
          example = "x86_64";
          description = ''
            A read-only MIRROR of `config.nixcpu.arch`: this host's actual instruction-set
            family. `null` when that fact does not resolve -- nixcpu not imported (a supported
            state: nixhost is adoptable on its own), or imported without `arch` stated.

            It is one half of the `microarch` consistency check below, which is why an unresolved
            `arch` is not silently tolerated the moment a `microarch` exists to check against it
            (see that option, and this module's own `archUnresolved` assertion).
          '';
        };

        microarch = mkOption {
          type = types.nullOr types.str;
          readOnly = true;
          default = mirrorOf null (config.nixcpu.microarch or null);
          example = "x86_64-v3";
          description = ''
            A read-only MIRROR of `config.nixcpu.microarch`: the microarchitecture/psABI level
            this host's kernel is actually built for. `null` when no such level is tracked, which
            is a real answer rather than a placeholder -- a stock distribution kernel has nothing
            to say here.

            When set, it is checked against `arch` above: an x86_64 psABI string
            (`x86_64`/`x86_64-v1`..`-v4`) declared while `arch = "aarch64"`, or the mirror-image
            ARM-family string declared while `arch = "x86_64"`, fails the build. That check is not
            redundant with nixcpu's own arch/microarch assertion -- nixcpu's runs only when
            `nixcpu.enable` is true, while the facts resolve regardless, so a host that states
            them purely for something else to read is checked HERE and nowhere else. See
            `microarchMismatch` above for the full reasoning.
          '';
        };

        cores = mkOption {
          type = types.nullOr types.ints.positive;
          readOnly = true;
          default = mirrorOf null (config.nixcpu.cores or null);
          example = 16;
          description = ''
            A read-only MIRROR of `config.nixcpu.cores`: physical cores actually installed. This
            is the CEILING every environment's own `resources.cpu.quotaCores` is checked against
            below, in CORES.

            Being a ceiling is what makes this one of the two mirrors with an ASSERT-RESOLVED
            assertion attached (see this file's header). `null` here is not "a host with no core
            limit" -- there is no such machine -- it is a fact that never arrived, and every
            comparison against it silently passes. So the moment an environment on this host
            claims CPU, an unresolved value fails the build instead of quietly disabling the
            check. A host that declares no CPU claims is never asked for it.
          '';
        };

        threads = mkOption {
          type = types.nullOr types.ints.positive;
          readOnly = true;
          default = mirrorOf null (config.nixcpu.threads or null);
          example = 32;
          description = ''
            A read-only MIRROR of `config.nixcpu.threads`: logical threads actually exposed
            (cores x SMT factor). Recorded as a distinct fact from `cores` on purpose: the
            oversubscription assertion below deliberately sums environment CPU quotas against
            `cores`, never `threads` -- a "24 cores" cgroup quota on a 16-core/32-thread host is
            oversubscribed by 8 real cores even though 24 is well under the 32 logical threads a
            naive check against `threads` would have allowed silently through.

            No ASSERT-RESOLVED assertion, unlike `cores`, and the difference is exactly the rule:
            nothing in this module divides against `threads`, so an absent value disables no check
            here. Whether a host is REQUIRED to state it at all is nixcpu's call, not this
            module's -- nixcpu declares it with no default and asserts `threads >= cores`, and a
            second copy of that requirement here would be the double declaration this whole
            change exists to remove.
          '';
        };

        coreTypes = mkOption {
          type = types.nullOr types.attrs;
          readOnly = true;
          default = mirrorOf null (config.nixcpu.coreTypes or null);
          example = literalExpression ''
            {
              performance = { cores = 4; threadsPerCore = 1; };
              efficiency  = { cores = 4; threadsPerCore = 1; };
            }
          '';
          description = ''
            A read-only MIRROR of `config.nixcpu.coreTypes`: the P-core/E-core split on a host
            whose cores are NOT interchangeable, or `null` (the common case) for a symmetric one.

            Mirrored OPAQUELY as `attrs`, deliberately, and for the same reason `storage.disks`
            is: nothing in this module reads inside it. The shape of a core-group split -- which
            groups exist, whether each carries a thread multiplier -- is nixcpu's to define and
            revise, and a submodule here that restated it would have to be revised in step with a
            repo this one takes no input on. What this option is for is making the fact
            ADDRESSABLE at `<name>.cpu.coreTypes`, not for policing it.

            Present at all only because the asymmetry was real: nixcpu owned this fact and this
            module had no path to it, so a consumer reading everything else about a host through
            `<name>.cpu.*` had to reach into a different namespace for this one field.
          '';
        };

        scheduler = mkOption {
          type = types.nullOr types.str;
          readOnly = true;
          default = mirrorOf null (config.nixcpu.scheduler or null);
          example = "bore";
          description = ''
            A read-only MIRROR of `config.nixcpu.scheduler`: the CPU scheduler variant this
            host's kernel actually runs -- CachyOS ships several (`bore`, `bmq`, ...) as distinct
            kernel packages rather than a runtime-tunable, so which one is running is otherwise
            recoverable only from the installed package name. `null` on a host where this is not
            a meaningful distinction.
          '';
        };
      };

      ram = {
        totalMiB = mkOption {
          type = types.nullOr types.ints.positive;
          readOnly = true;
          default = mirrorOf null (config.nixram.hardware.totalMiB or null);
          example = 131072;
          description = ''
            A read-only MIRROR of `config.nixram.hardware.totalMiB`: RAM actually installed, in
            MiB. Same unit on both sides of the mirror on purpose -- a conversion in a defensive
            read is a silent factor-of-1024 waiting to happen.

            This is the CEILING every environment's own `resources.ram.limitMiB` is checked
            against below, and therefore the second of the two mirrors carrying an ASSERT-RESOLVED
            assertion: an unresolved total does not loosen the oversubscription check, it deletes
            it, since every claim then "fits". So an environment declaring a RAM claim on a host
            whose total never resolved fails the build. A host with no RAM claims is never asked.

            Note the asymmetry with nixram's side of the mirror, which is deliberate on both
            ends: nixram defaults this to `null` and requires it of nobody, because its own
            zram/oomd/sysctl policy is driven entirely by a chosen level bucket and never by a
            literal RAM number. The requirement is not a property of the fact, it is a property of
            what a particular consumer does with it -- so it belongs here, at the read site that
            actually divides against it, and only when something does.
          '';
        };
      };

      gpu = mkOption {
        type = types.attrs;
        readOnly = true;
        default = mirrorOf { } (config.nixgpu.stableDevicePaths.devices or { });
        description = ''
          A read-only MIRROR of `config.nixgpu.stableDevicePaths.devices` (see nixgpu's own
          `modules/stable-device-paths/options.nix`): the GPUs -- and GPU-shaped devices, a
          BMC/IPMI framebuffer included -- this host actually has, keyed by a short stable name.
          Empty when nixgpu is not imported here, or when it is and the inventory is genuinely
          empty; unlike a missing core count, an empty device table is a legitimate state (a host
          with no card in it) and so needs no ASSERT-RESOLVED companion.

          The key is the load-bearing part, and it is ALL this module needs: it is the same name
          `environments.<name>.resources.gpu.<name>.access` claims against, so a claim and a
          device are provably talking about one piece of silicon rather than two
          independently-spelled strings that happen to agree today.

          ⚠ MIRRORED OPAQUELY (`types.attrs`), and that is a decision, not an oversight. This
          module used to declare a `vendor`/`pciId`/`vramMiB` submodule here, with an assertion
          that read all three -- an assertion whose only job was to force the fields of this
          module's OWN required submodule to be read. Once the table belongs to nixgpu, both the
          submodule and that assertion are the wrong side of the boundary: nixgpu declares those
          three fields as required and enforces them itself, and a copy of its field names here
          would make this repo fail to evaluate the day nixgpu adds a fourth or renames one. So
          what was checked here is checked at the owner, and what is left here is the name -- which
          is the only thing the claim/conflict arithmetic below ever reads. Nothing in this module
          divides against `vramMiB`: an environment's GPU claim is an access STANCE
          (`none`/`shared`/`exclusive`), never a MiB quantity, so there is no VRAM ceiling to lose
          by not knowing the number. Whether a claim naming a device the inventory does not
          contain should itself be an error is a real open question, deliberately not answered
          here -- see `experiments/README.md`.
        '';
      };

      storage = {
        disks = mkOption {
          type = types.attrs;
          readOnly = true;
          default = mirrorOf { } (config.nixstorage.disks or { });
          description = ''
            A read-only MIRROR of `config.nixstorage.disks` (see nixstorage's own
            `modules/disks.nix`), reached through this host's own namespace so
            `<name>.storage.disks.<diskName>` is a real path in this family's graph without a
            second, independently-maintained copy of the disk table existing here. Read
            defensively (`config.nixstorage.disks or { }`, the same idiom nixboot uses for
            `nixstorage.layout`): a host that imports nixhost without nixstorage simply sees an
            empty table here, never an error. nixhost never adds a flake input on nixstorage to
            get this -- see this file's header on what it refuses to own -- so this option
            exists ONLY to make an already-declared-elsewhere fact addressable at this path; it
            is never a place to declare a disk directly, hence `readOnly`.

            This was the first mirror in this module and is the template every other one above
            follows, `types.attrs` included: the shape of a disk is nixstorage's to define.
          '';
        };
      };

      net = mkOption {
        type = types.attrs;
        readOnly = true;
        default = mirrorOf { } (config.nixnet.interfaces or { });
        description = ''
          A read-only MIRROR of `config.nixnet.interfaces` (see nixnet's own `modules/core.nix`):
          the network interfaces this host actually has, keyed by a short stable name, each
          carrying whatever nixnet says an interface carries -- today a MAC and a role-keyed
          address map. Empty when nixnet is not imported here.

          Mirrored opaquely for the same reason as `gpu` and `storage.disks`: nothing in this
          module reads inside an interface entry. Note the path asymmetry -- nixnet calls this
          `nixnet.interfaces`, not `nixnet.resources.net` -- which is exactly right and worth
          stating: a mirror reads the owner at the owner's own address and re-exposes it at this
          namespace's address, and demanding the two paths match would be this repo dictating
          another repo's option layout for its own convenience.
        '';
      };
    };

    environments = mkOption {
      type = types.attrsOf environmentSubmodule;
      default = { };
      description = ''
        Every environment standing on this host -- a k3s node, a VM, a podman container -- each
        one a PROJECTION of `resources` above, never the same object: an environment's own
        `resources` block is an independent CLAIM this module checks for consistency against
        the level-1 total, not a reference to it. Empty (the default) for a bare host with
        nothing standing on it yet.
      '';
    };
  };

  config.assertions =
    [
      # Forces `name` to actually be read (see its own option description for why a default
      # would defeat the point), and rejects the one value that would still type-check as `str`
      # while being exactly as useless as leaving it unset: the empty string.
      {
        assertion = cfg.name != "";
        message = ''
          nixhost.name is unset (or empty). This is the namespace root every fact about this
          host hangs off -- see this module's own header. There is no safe default: state the
          real hostname explicitly.
        '';
      }

      # `stance.class` and `stance.role` are `nullOr str`, so `""` type-checks -- and `""` is
      # strictly WORSE than `null` here, which is why it gets its own assertion rather than being
      # left to the type. A consumer asking `class != null` sees a host that HAS a class; a
      # consumer asking `class == "tiny"` sees one that does not match. So an empty string reads
      # as "declared" to one branch and "absent" to the other, and the two disagree silently and
      # permanently. `null` at least means the same thing to every reader.
      {
        assertion = cfg.stance.class != "";
        message = ''
          nixhost.stance.class is the empty string. Use `null` to mean "not tracked for this
          host" -- `""` is not a weaker version of that, it is a value that reads as SET to a
          null-check and as UNSET to any comparison, so two consumers of the same fact will
          disagree about it and neither will error.
        '';
      }

      {
        assertion = cfg.stance.role != "";
        message = ''
          nixhost.stance.role is the empty string. Use `null` to mean "not tracked for this
          host" -- see `stance.class`'s own assertion for why `""` is worse than absent rather
          than equivalent to it.
        '';
      }

      # Silent whenever `microarch` is null, whenever `arch` is null (the assertion below covers
      # that case with a message that can actually say what to do about it), and whenever the two
      # genuinely belong to the same family.
      {
        assertion = !microarchMismatch;
        message = ''
          nixhost.resources.cpu.microarch = "${toString cfg.resources.cpu.microarch}" does not
          match nixhost.resources.cpu.arch = "${toString cfg.resources.cpu.arch}". An x86_64 psABI
          level declared on an aarch64 host (or the reverse) is a typo surviving a copy-paste
          between two hosts' configs, not a real configuration -- both fields still type-check as
          plain strings, which is exactly why nothing but this check would ever catch it. Both
          values are mirrors of nixcpu's own `arch`/`microarch`, so the fix belongs there.
        '';
      }

      # ── MIRROR + ASSERT-RESOLVED: the three checks that refuse to guard nothing ─────────────
      #
      # Each of the three fires ONLY when something on this host actually depends on the missing
      # fact, and that condition is the entire design. It is what keeps nixhost adoptable by a host
      # that owns none of the domains it mirrors -- every mirror resolves to `null`/`{ }` there and
      # nothing errors -- while making it impossible for that same host to ASK for a check and be
      # handed silence instead.
      #
      # ALL THREE WAYS A FACT CAN FAIL TO ARRIVE end up here as one message, because `mirrorOf`
      # collapses them (see its own comment): the domain is not imported, the domain is imported but
      # the fact was never stated, or the owner rejected the value it was given. Each message below
      # therefore names all three and says how to tell them apart -- evaluate the owner's own option
      # -- rather than asserting the most likely one and misdiagnosing the other two.
      {
        assertion = !ramCeilingUnresolved;
        message = ''
          nixhost: an environment on this host declares `resources.ram.limitMiB`, but
          nixhost.resources.ram.totalMiB did not resolve. That option is a read-only MIRROR of
          `config.nixram.hardware.totalMiB`, so one of three things is true: nixram is not imported
          on this host, it is imported and `hardware.totalMiB` was never set, or the value it was
          given was rejected by nixram's own type. Evaluate `config.nixram.hardware.totalMiB`
          directly to see which.

          This is not a relaxed check, it is an absent one: the RAM oversubscription assertion is a
          comparison against that total, so with no total every claim "fits" and the check passes
          while checking nothing. Set `nixram.hardware.totalMiB`, or drop the environment's RAM
          claim -- an environment with no `ram.limitMiB` makes no bounded claim and needs no
          ceiling.
        '';
      }

      {
        assertion = !cpuCeilingUnresolved;
        message = ''
          nixhost: an environment on this host declares `resources.cpu.quotaCores`, but
          nixhost.resources.cpu.cores did not resolve. That option is a read-only MIRROR of
          `config.nixcpu.cores` -- nixcpu not imported, imported with `cores` never set, or set to a
          value nixcpu's own type rejected; evaluate `config.nixcpu.cores` to see which.

          Same consequence as the RAM case above: the CPU oversubscription assertion divides
          against physical cores, so with no core count every quota "fits". Set `nixcpu.cores`, or
          drop the environment's CPU quota.
        '';
      }

      {
        assertion = !archUnresolved;
        message = ''
          nixhost.resources.cpu.microarch = "${toString cfg.resources.cpu.microarch}" is declared,
          but nixhost.resources.cpu.arch did not resolve -- and the microarch check above is a
          comparison of the two, so it has nothing to compare and would report a clean result for a
          host whose CPU facts were never cross-checked at all.

          Both are mirrors of nixcpu, so this state means nixcpu carries a microarch without an arch
          -- something nixcpu itself only refuses when `nixcpu.enable` is true, which is exactly why
          the fact-only host needs this check. Set `nixcpu.arch`.
        '';
      }

      # ── THE OTHER HALF OF "EXACTLY ONE SPOT": a mirror declared on the host ─────────────────
      #
      # Not an assert-resolved check -- the opposite. Above, a fact that never arrived; here, a fact
      # that arrived twice. See `overriddenMirrors` above for why this is asked eagerly rather than
      # left to the read-time `readOnly` failure the module system would produce on its own.
      {
        assertion = overriddenMirrors == [ ];
        message = ''
          nixhost: ${toString (length overriddenMirrors)} level-1 resource(s) are declared on this
          host, but every one of them is a read-only MIRROR of the domain that owns the fact:

          ${concatStringsSep "\n          " (map (m: "nixhost.${m.path} -> declare it at `${m.owner}` instead") overriddenMirrors)}

          This is the one rule the level-1 half of this module exists to enforce: a hardware fact
          lives at exactly ONE address. A second copy here would not be redundancy, it would be two
          numbers that agree today and disagree the day the hardware changes, with nothing comparing
          them. Move the value to the option named above -- nixhost will read it back at this path
          unchanged.
        '';
      }

      # The arithmetic this whole repo exists to make possible, now applied at EVERY level of the
      # tree rather than only at the host: do the environments standing on a node claim more than
      # that node itself has? A single sum against the host total would pass a container claiming
      # 16 GiB inside a VM capped at 8 GiB, because the host has 128 GiB -- and that container is
      # over-committed regardless of what the host has.
      {
        assertion = ramViolations == [ ];
        message = ''
          nixhost: RAM over-committed at ${toString (length ramViolations)} level(s) of the
          environment tree:

          ${concatStringsSep "\n          " ramViolations}

          Each line compares one node's children against THAT NODE's own ceiling, not the host's
          -- a guest cannot hand out more than it was given, however much the machine underneath
          has. Environments with no declared `ram.limitMiB` are excluded from these sums (an
          unlimited claim is not a bounded one to check), so the real oversubscription is at
          least this large. Lower a claim, raise the parent's limit, or add RAM.
        '';
      }

      # Same walk, CPU cores -- never threads. See `resources.cpu.threads`'s own description for
      # why summing against threads would silently permit real oversubscription.
      {
        assertion = cpuViolations == [ ];
        message = ''
          nixhost: CPU over-committed at ${toString (length cpuViolations)} level(s) of the
          environment tree:

          ${concatStringsSep "\n          " cpuViolations}

          Checked against physical CORES at the host and against a nested environment's own
          `cpu.quotaCores` below it, deliberately never the higher `threads` figure -- SMT adds
          schedulable slots, not execution capacity, so quoting against threads over-commits by
          up to 2x while looking fine. Environments with no declared quota are excluded.
        '';
      }
    ]
    # One assertion per GPU device that more than one environment claims where at least one
    # claim is "exclusive" -- see `gpuConflicts`' own definition above for the exact rule.
    ++ mapAttrsToList
      (gpuName: claims: {
        assertion = false;
        message = ''
          nixhost.environments: GPU "${gpuName}" is claimed by more than one environment, and at
          least one claim is "exclusive": ${concatStringsSep ", " (map (c: "${c.env}=${c.access}") claims)}.
          An exclusive claim next to ANY other claim on the same device -- including a second
          exclusive claim -- is a conflict this module refuses to resolve by precedence: whichever
          environment actually loses that race at runtime does so silently, discovered only when
          its workload behaves as if the device were never there. Change every claim but one to
          "none", or reduce every remaining claim to "shared" if genuine co-residency is intended.
        '';
      })
      gpuConflicts;

  # THE GPU DEVICE-COMPLETENESS ASSERTION THAT USED TO LIVE HERE IS GONE, and its absence is the
  # change, not an omission. It read every declared device's `vendor`/`pciId`/`vramMiB` and failed on
  # an empty one -- a check that existed only to force the required fields of THIS module's own GPU
  # submodule to be read, back when this module declared that submodule. `resources.gpu` is now an
  # opaque mirror of `nixgpu.stableDevicePaths.devices`, which declares all three as required and
  # enforces them itself, at the one place that also knows what a fourth field would mean. Keeping a
  # copy here would have meant this repo failing to evaluate the day nixgpu renames or adds a field,
  # over a table it does not own -- see `resources.gpu`'s own description.
}

