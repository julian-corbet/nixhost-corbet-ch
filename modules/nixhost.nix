# modules/nixhost.nix
#
# THE NAMESPACE ROOT: one host, addressed as a path. `nixhost.name` is the first segment
# of every fact this family can state about a machine -- `fileserver.storage.disks.solid0`,
# `workstation.cpu.microarch`, `fileserver.k3s.gpu.apps` -- and this module is where that
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
# and none of that is a NixOS-specific concept. The precedent this follows exactly is nixid's
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
# `fileserver.gpu.apps` and `fileserver.k3s.gpu.apps` are two different paths into the
# same physical card. That is why `environments.<name>.resources.gpu.<gpuName>.access` is keyed
# by the SAME name as `resources.gpu.<gpuName>` rather than each environment inventing its own
# private GPU namespace -- two environments claiming the identically-named device are, in
# reality, contending for one piece of silicon, and the exclusive/shared conflict check below
# only means anything because the name is shared.
#
# ── What this module refuses to own ──────────────────────────────────────────────────────────
#
# - HOW a domain works. A GPU exists here as a vendor/PCI-ID/VRAM tuple; nixgpu decides the
#   scheduling mechanism that shares it. A disk exists here (read from nixstorage, see below);
#   nixstorage decides its filesystem shape.
# - POLICY. Which services actually run on a host is that host's own configuration, not this
#   module's business -- `environments.<name>` says a k3s node exists and how much of the host
#   it may claim, never which pods it runs.
# - DERIVED CONFIG. The moment a fact declared here turns into a tuning value (a cgroup weight,
#   a nice level, a specific kernel parameter), this stops being a one-way fact table and
#   becomes a policy engine with an opinion. Enums and quantities go in; nothing computed from
#   them is allowed to live here.
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
{ config, lib, ... }:

with lib;

let
  cfg = config.nixhost;

  # A quantity that must be strictly positive, and may be fractional -- the shape a CPU quota
  # claim actually needs (podman and cgroup quotas are routinely expressed as e.g. 1.5 cores),
  # which no single `types.ints.*` helper covers on its own.
  positiveNumber = types.addCheck
    (types.either types.int types.float)
    (x: x > 0);

  # ── Level 1: one physical GPU this host actually has a card for ───────────────────────────
  gpuDeviceSubmodule = types.submodule {
    options = {
      vendor = mkOption {
        type = types.str;
        example = "amd";
        description = ''
          The silicon vendor, in the operator's own words -- not restricted to a fixed enum
          here, because that catalogue belongs to whichever domain actually dispatches on it
          (nixgpu's `toolchain.vendor`, say), and this table only needs to carry the fact, not
          police its spelling. Required: a GPU entry that cannot say whose silicon it is cannot
          be matched against a vendor-scoped mechanism (ROCm vs. oneAPI vs. CUDA) by anything
          reading this table downstream.
        '';
      };

      pciId = mkOption {
        type = types.str;
        example = "0x1002";
        description = ''
          The PCI vendor ID exactly as `/sys/class/drm/cardN/device/vendor` reports it (AMD is
          `0x1002`, Intel `0x8086`, NVIDIA `0x10de` -- catalogue facts about the hardware, not a
          choice this repo or any operator makes). This is the STABLE identity a udev rule or
          a device plugin actually matches on; `vendor`, above, is for humans reading a rendered
          table, never for matching a device.
        '';
      };

      vramMiB = mkOption {
        type = types.ints.positive;
        example = 16384;
        description = ''
          VRAM actually on the card, in MiB. Recorded here as a level-1 hardware fact only --
          nothing in this module sums per-environment VRAM demand against it, because
          `environments.<name>.resources.gpu.<name>.access` is an access STANCE
          (`none`/`shared`/`exclusive`), not a MiB quantity; a card that is oversubscribed on
          VRAM fails at allocation time on the consumer's own silicon, which is arbitration
          nixgpu already owns. Kept here so a rendered table can say how big the card actually
          is next to who is allowed to touch it.
        '';
      };
    };
  };

  # ── Level 1: one network interface this host actually has ─────────────────────────────────
  netInterfaceSubmodule = types.submodule {
    options = {
      mac = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "aa:bb:cc:dd:ee:ff";
        description = ''
          This interface's hardware MAC, or `null` (the default) for an interface with no
          stable one worth recording -- an overlay-network (NetBird/WireGuard) interface most
          often has nothing meaningful here, since its identity is the tunnel key, not a MAC.
        '';
      };

      addresses = mkOption {
        type = types.attrsOf types.str;
        default = { };
        example = { lan = "192.0.2.10"; overlay = "198.51.100.10"; };
        description = ''
          Every address this interface answers to, keyed by role rather than a fixed column
          set, for a concrete reason: one host's interface has one LAN address, another has a LAN address AND an
          overlay one simultaneously, and a third has only a dynamic public address nothing
          else here needs to name. Add a role by using it; there is no enum to extend first.
        '';
      };
    };
  };

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
        type = types.enum [ "k3s" "vm" "podman" ];
        example = "k3s";
        description = ''
          What kind of environment this is. Required, with no default: an environment this
          module cannot classify is one whose resource claims cannot be reasoned about at all
          -- there is no safe generic guess between "a whole VM" and "one podman container"
          that would not misrepresent the claim to whoever reads this table next.
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
          '';
        };
      };
    };
  };

  # ── Consistency arithmetic ──────────────────────────────────────────────────────────────────

  envNames = attrNames cfg.environments;

  ramClaimants = filter
    (n: cfg.environments.${n}.resources.ram.limitMiB != null)
    envNames;
  ramClaimSum = foldl'
    (acc: n: acc + cfg.environments.${n}.resources.ram.limitMiB)
    0
    ramClaimants;

  cpuClaimants = filter
    (n: cfg.environments.${n}.resources.cpu.quotaCores != null)
    envNames;
  cpuClaimSum = foldl'
    (acc: n: acc + cfg.environments.${n}.resources.cpu.quotaCores)
    0
    cpuClaimants;

  # Every non-"none" GPU claim, flattened across every environment, grouped by the DEVICE name
  # it claims -- {"gpu0" = [ {env="k3s"; access="exclusive";} {env="podman"; access="shared";} ]; }.
  gpuClaimsByDevice =
    foldl'
      (acc: envName:
        foldl'
          (acc2: gpuName:
            let access = cfg.environments.${envName}.resources.gpu.${gpuName}.access;
            in
            if access == "none" then acc2
            else acc2 // {
              ${gpuName} = (acc2.${gpuName} or [ ]) ++ [{ env = envName; inherit access; }];
            })
          acc
          (attrNames cfg.environments.${envName}.resources.gpu))
      { }
      envNames;

  # A device is in conflict when more than one environment claims it AND at least one of those
  # claims is "exclusive" -- any number of "shared" claimants alone is fine (that is the whole
  # point of "shared"); two "exclusive" claimants, or one "exclusive" next to any other claim,
  # both count, per this file's header and rule 4 of the design this module implements.
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

  microarchMismatch =
    cfg.resources.cpu.microarch != null && (
      (cfg.resources.cpu.arch != "x86_64" && looksLikeX86Microarch cfg.resources.cpu.microarch) ||
      (cfg.resources.cpu.arch != "aarch64" && looksLikeAarch64Microarch cfg.resources.cpu.microarch)
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

    resources = {
      cpu = {
        arch = mkOption {
          type = types.enum [ "x86_64" "aarch64" ];
          example = "x86_64";
          description = ''
            This host's actual instruction-set architecture. Required, with no default: every
            other CPU fact below is meaningless without it, and it is the one half of the
            `microarch` consistency check this module runs -- see that option's own description.
          '';
        };

        microarch = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = "x86_64-v3";
          description = ''
            The microarchitecture/psABI level this host's kernel is actually built for, if that
            fact matters here -- LOAD-BEARING today for fileserver, which runs a
            `linux-cachyos-…-x86_64-v3` kernel package with nothing outside that package name
            declaring the fact. `null` (the default) is correct when no such level is tracked.
            When set, it is checked against `arch` below: an x86_64 psABI string
            (`x86_64`/`x86_64-v1`..`-v4`) declared while `arch = "aarch64"`, or the mirror-image
            ARM-family string declared while `arch = "x86_64"`, fails the build. That specific
            failure is not hypothetical inside this family -- a microarch string surviving a
            copy-paste from one host's config to another's, unnoticed because both fields still
            type-check as plain strings, is exactly the class of drift this whole repo exists to
            catch arithmetically instead of by proofreading.
          '';
        };

        cores = mkOption {
          type = types.ints.positive;
          example = 16;
          description = ''
            Physical cores actually installed. Required, with no default: this is the ceiling
            every environment's own `resources.cpu.quotaCores` is checked against below, in
            CORES -- an oversubscription check with no idea how many cores exist checks nothing.
          '';
        };

        threads = mkOption {
          type = types.ints.positive;
          example = 32;
          description = ''
            Logical threads actually exposed (cores × SMT factor). Recorded as a distinct fact
            from `cores` on purpose: the oversubscription assertion below deliberately sums
            environment CPU quotas against `cores`, never `threads` -- a "24 cores" cgroup quota
            on a 16-core/32-thread host is oversubscribed by 8 real cores even though 24 is well
            under the 32 logical threads a naive check against `threads` would have allowed
            silently through.
          '';
        };

        scheduler = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = "bore";
          description = ''
            The CPU scheduler variant this host's kernel actually runs, if that fact is worth
            tracking -- CachyOS ships several (`bore`, `bmq`, ...) as distinct kernel packages
            rather than a runtime-tunable, so which one is running is otherwise recoverable only
            from the installed package name. `null` (the default) is correct on a host where
            this is not a meaningful distinction (a stock distribution kernel, for instance).
          '';
        };
      };

      ram = {
        totalMiB = mkOption {
          type = types.ints.positive;
          example = 131072;
          description = ''
            RAM actually installed, in MiB. Required, with no default: this is the ceiling
            every environment's own `resources.ram.limitMiB` is checked against below -- an
            oversubscription check with no idea how much RAM exists checks nothing.
          '';
        };
      };

      gpu = mkOption {
        type = types.attrsOf gpuDeviceSubmodule;
        default = { };
        example = literalExpression ''
          { gpu0 = { vendor = "amd"; pciId = "0x1002"; vramMiB = 16384; }; }
        '';
        description = ''
          The GPUs this host actually has a card for, keyed by a short stable name --the SAME
          name `environments.<name>.resources.gpu.<name>.access` claims against, so an
          environment's claim and this table's device are provably talking about the same
          silicon rather than two independently-spelled strings that happen to currently agree.
          Empty (the default) for a host with no GPU at all.
        '';
      };

      storage = {
        disks = mkOption {
          type = types.attrs;
          readOnly = true;
          default = config.nixstorage.disks or { };
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
          '';
        };
      };

      net = mkOption {
        type = types.attrsOf netInterfaceSubmodule;
        default = { };
        example = literalExpression ''
          { lan0 = { mac = "aa:bb:cc:dd:ee:ff"; addresses.lan = "192.168.1.10"; }; }
        '';
        description = ''
          The network interfaces this host actually has, keyed by a short stable name. Empty
          (the default) for a host where no interface is worth recording at this path.
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

      # Forces `resources.cpu.arch` to be read even on a host that never sets `microarch`, and
      # is silent whenever `microarch` is null or genuinely matches `arch`'s own family.
      {
        assertion = !microarchMismatch;
        message = ''
          nixhost.resources.cpu.microarch = "${toString cfg.resources.cpu.microarch}" does not
          match nixhost.resources.cpu.arch = "${cfg.resources.cpu.arch}". An x86_64 psABI level
          declared on an aarch64 host (or the reverse) is a typo surviving a copy-paste between
          two hosts' configs, not a real configuration -- both fields still type-check as plain
          strings, which is exactly why nothing but this check would ever catch it.
        '';
      }

      # The arithmetic this whole repo exists to make possible: does the sum of every
      # environment's own declared RAM ceiling exceed what this host actually has installed.
      {
        assertion = ramClaimSum <= cfg.resources.ram.totalMiB;
        message = ''
          nixhost.environments: RAM claimed by ${toString (length ramClaimants)} environment(s)
          (${concatStringsSep ", " (map (n: "${n}=${toString cfg.environments.${n}.resources.ram.limitMiB}MiB") ramClaimants)})
          sums to ${toString ramClaimSum}MiB, which exceeds
          nixhost.resources.ram.totalMiB = ${toString cfg.resources.ram.totalMiB}MiB actually
          installed. Environments with no declared `ram.limitMiB` are excluded from this sum
          (an unlimited claim is not a bounded one to check), so the real, live oversubscription
          risk is at least this large. Lower a claim, or add RAM.
        '';
      }

      # Same arithmetic, CPU cores (never threads -- see `resources.cpu.threads`'s own
      # description for why summing against threads would silently allow real oversubscription).
      {
        assertion = cpuClaimSum <= cfg.resources.cpu.cores;
        message = ''
          nixhost.environments: CPU claimed by ${toString (length cpuClaimants)} environment(s)
          (${concatStringsSep ", " (map (n: "${n}=${toString cfg.environments.${n}.resources.cpu.quotaCores}") cpuClaimants)})
          sums to ${toString cpuClaimSum} cores, which exceeds
          nixhost.resources.cpu.cores = ${toString cfg.resources.cpu.cores} physical cores
          actually installed on this host (checked against CORES, deliberately never the higher
          `threads` figure -- SMT does not manufacture real execution capacity). Environments
          with no declared `cpu.quotaCores` are excluded from this sum. Lower a claim, or this
          host does not have the CPU this set of environments collectively assumes.
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
      gpuConflicts
    # Every declared physical GPU must actually be populated -- forces `vendor`/`pciId`/`vramMiB`
    # to be read even though nothing else in this module consumes them, so an entry left as an
    # empty `{ }` (which type-checks under `gpuDeviceSubmodule` right up until something reads a
    # field with no default) is caught here instead of by whichever downstream consumer happens
    # to read it first.
    ++ mapAttrsToList
      (gpuName: g: {
        assertion = g.vendor != "" && g.pciId != "" && g.vramMiB > 0;
        message = ''
          nixhost.resources.gpu."${gpuName}" is missing a non-empty vendor, a non-empty pciId,
          or a positive vramMiB. A GPU entry declared but left incomplete is indistinguishable,
          to anything reading this table, from a card that genuinely has no vendor -- state all
          three, or remove the entry entirely.
        '';
      })
      cfg.resources.gpu;
}
