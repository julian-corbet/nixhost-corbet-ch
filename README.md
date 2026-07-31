# nixhost

**One host, addressed as a path — and the one arithmetic question nothing in this family could
answer before this repo existed: does what stands on a machine actually fit on it?**

## What nixhost is

Every hardware and software fact about a machine ends up spelled somewhere: a CPU core count in
a BIOS screenshot nobody re-reads, a RAM total in whoever provisioned the box's memory, a GPU's
PCI ID in a udev rule three repos over. None of it is reachable as one thing, and nothing
compares a claim against a total — a k3s node can be handed a RAM ceiling bigger than the box
actually has, and the only place that surfaces is an OOM kill at 3 a.m., not a build failure at
declaration time.

`nixhost` is the fix: one host, one `nixhost.name`, and everything true about it reachable as a
path rooted there —

```
fileserver.storage.disks.pool0
fileserver.gpu.gpu0                     # bare metal: the host's own inventory
fileserver.k3s.gpu.gpu0                 # a k3s environment's stance on the SAME card
fileserver.vm.container.gpu.gpu0        # and deeper -- a container inside a VM
workstation.cpu.microarch
```

— plus the arithmetic that makes those paths worth having: this module sums what every
environment standing on a host claims, checks it against what the host actually has, and
refuses to evaluate if the claims don't fit.

## Level 1 is a mirror. Nothing here declares a hardware fact.

**If you want to know what CPU a host has, that lives in exactly one spot — and it is not this
repo.** Every option under `resources` is `readOnly`, and its default is a defensive read of the
repository that owns the fact:

| `nixhost.resources.…` | mirrors | owner |
|---|---|---|
| `cpu.{arch,microarch,cores,threads,coreTypes,scheduler}` | `config.nixcpu.*` | [nixcpu](https://github.com/julian-corbet/nixcpu-corbet-ch) |
| `ram.totalMiB` | `config.nixram.hardware.totalMiB` | [nixram](https://github.com/julian-corbet/nixram-corbet-ch) |
| `gpu` | `config.nixgpu.stableDevicePaths.devices` | [nixgpu](https://github.com/julian-corbet/nixgpu-corbet-ch) |
| `net` | `config.nixnet.interfaces` | [nixnet](https://github.com/julian-corbet/nixnet-corbet-ch) |
| `storage.disks` | `config.nixstorage.disks` | [nixstorage](https://github.com/julian-corbet/nixstorage-corbet-ch) |

The read is `config.<domain>.<path> or <empty>` — **never a flake input on the domain**. That's
load-bearing in both directions: a domain repo has to stay usable by someone who has never heard of
nixhost, so the dependency can only point this way; and a host has to be able to import nixhost
while owning only some of those domains, so an absent domain resolves to `null`/`{ }` rather than
erroring.

There's a wrinkle worth knowing about, because a bare `or` gets it wrong: `or` tests whether an
attribute *path* exists, and a declared option's path exists the moment its module is imported —
definition or not. So for a field the owner requires (`nixcpu.cores` has no default), `or` hands back
the module system's own throwing thunk rather than the fallback, and a bare `or` cannot tell that
apart from a domain that was simply never imported. Both mirrors' defaults read through
[`lib.probeFact`](#the-cross-namespace-half-libprobefact) instead, which tells the two apart:
"the domain isn't imported at all" stays completely silent (there is no fact to mirror, and nothing
here can say there should be one), while "the domain is imported but this exact leaf didn't resolve" —
a rename, a value the owner rejected, or a required field genuinely never given a value — is
reported, by default as a `config.warnings` entry naming the option, the namespace, and the
fallback actually in use. Neither case is left to a hand-written assertion in this module anymore.

Setting one of these on a host is a build failure naming the owner to use instead, not an override —
a second copy of a fact wouldn't be redundancy, it would be two numbers that agree today and
disagree the day the hardware changes, with nothing comparing them.

### …and why some of those mirrors carry an assertion the others don't

`cpu.cores` and `ram.totalMiB` aren't only facts here, they're the **ceilings the oversubscription
arithmetic divides against**. An empty disk table or an empty GPU inventory is a legitimate state; a
missing core count is not — every comparison against it is vacuously true, so the check reports
success while checking nothing. That's strictly worse than the required option it replaced, and
worse in the invisible direction: no message, no warning, a green build.

So a mirrored ceiling is **mirror + assert-resolved**: `readOnly`, a defensive default, *and* an
assertion that fires whenever something actually depends on the ceiling and it didn't resolve.
"Depends on it" is never restated as its own predicate — it's `claimed > 0`, computed by the very
fold that would otherwise have divided against the missing number, so the guard can't drift out of
step with the arithmetic it guards. A host that claims nothing is never asked for a ceiling.

`cpu.arch` gets the same treatment for the same reason, one step removed: it isn't a ceiling, but the
microarch-vs-arch cross-check divides a claim by it in spirit — with no `arch`, that check silently
compares nothing. Every other mirror (`threads`, `microarch`, `coreTypes`, `scheduler`, `gpu`, `net`,
`storage.disks`) carries no *assertion*, because no arithmetic here divides against it, so a domain
that was never composed at all disables nothing and `null`/`{ }` is a truthful, silent answer. That
is not the same as carrying no report at all, though: each of these still runs through
`lib.probeFact`, so a domain that genuinely **is** composed but whose fact renamed, was rejected, or
was never given a value it requires (`nixcpu.threads`, in particular — see the module's own header)
still surfaces as a `config.warnings` entry. Non-fatal, but no longer invisible either.

## The model

```nix
# LEVEL 1 — the machine itself, stated at each fact's OWNER. nixhost mirrors all of it,
# read-only: none of these values is settable under `nixhost.resources`.
nixcpu = {
  arch      = "x86_64";                         # x86_64 | aarch64
  microarch = "x86_64-v3";                      # cross-checked against arch, below
  cores     = 16;  threads = 32;
  scheduler = "bore";
};
nixram.hardware.totalMiB = 128 * 1024;
nixgpu.stableDevicePaths.devices.gpu0 = { vendor = "amd"; pciId = "0x1002"; vramMiB = 16384; };
nixnet.interfaces.lan0 = { mac = "aa:bb:cc:dd:ee:ff"; addresses.lan = "192.168.1.10"; };
# nixstorage.disks.pool0 = { device = "/dev/disk/by-id/..."; };

nixhost = {
  name = "fileserver";                          # REQUIRED, no default — the namespace root

  stance = {
    backend  = "nixos";                         # nixos | system-manager | nix-darwin
    flavour  = "appliance";                     # free-form, example only — your own tag
    provider = "metal";                         # free-form, example only — metal | lxc | gce | ...
    class    = "standard";                      # capability tier, free-form. FACT ONLY —
    role     = "proxy";                         # what it's for, free-form.    nothing here
                                                #   derives from either; see below.
  };

  # Read back out of the mirrors above, at this host's own namespace root:
  #   fileserver.cpu.cores == 16, fileserver.gpu.gpu0.vramMiB == 16384, ...

  # LEVEL 2 — environments standing on this host. Each is a PROJECTION of level 1, never
  # the same object: k3s genuinely sees a constrained view and may be denied a device entirely.
  environments.cluster-node = {
    kind = "k3s";
    resources = {
      ram.limitMiB   = 100 * 1024;              # checked: sum across environments ≤ ram.totalMiB
      cpu.quotaCores = 10;                      # checked: sum across environments ≤ cpu.cores
      gpu.gpu0.access = "shared";                # none | shared | exclusive
    };
  };
};
```

## The path is as long as the nesting is deep

`environments` is recursive, because that is what the namespace already describes. Bare metal is
`host.gpu.gpu0`. A container inside a VM is `host.vm.container.gpu.gpu0`. Nothing about the second
is exotic — a VM that runs containers is the ordinary case — so capping the model at one level
would make it unable to state the common thing:

```nix
nixhost.environments.vm1 = {
  kind = "vm";
  resources.ram.limitMiB = 32768;

  environments.pod1 = {                       # a container inside that VM
    kind = "podman";
    resources.ram.limitMiB = 8192;

    environments.inner = {                    # and inside that
      kind = "lxc";
      resources.ram.limitMiB = 2048;
    };
  };
};
```

**Every envelope is checked against its immediate parent, never against the host.** A container
claiming 16 GiB inside a VM capped at 8 GiB is over-committed even on a 128 GiB machine — a guest
cannot hand out more than it was given. A flat sum against the host total would call that fine,
which is why the check is a walk and the violation names the node: `host.vm1.pod1: its
environments claim 16384 MiB, but host.vm1.pod1 has 8192 MiB`.

**GPU names stay host-scoped at every depth.** `host.vm.container.gpu.rx6800` is physically the
same card as `host.gpu.rx6800` — passthrough does not mint a new device — so the conflict check
flattens claims across the whole tree. A VM claiming a card `exclusive` while a container three
levels down claims it `shared` is one piece of silicon with two contradictory promises, and only
a full-tree flatten sees it.

How it is implemented, since it looks like it should not work: the submodule type is `let`-bound
and refers to *itself*. Nix's laziness is what makes that terminate — an option's `type` is only
forced when something actually reads that deep.

## Why a graph, not a tree

A tree would put `gpu` under exactly one parent. Real hardware doesn't cooperate: one physical
card is consumed by bare-metal apps running directly on the host AND by whatever pods a k3s
environment standing on that SAME host schedules onto it. `fileserver.gpu.gpu0` and
`fileserver.k3s.gpu.gpu0` are two different paths into one card, and `environments.<name>.
resources.gpu.<name>` deliberately shares its key with `resources.gpu.<name>` rather than each
environment inventing its own private device namespace — two environments claiming the
identically-named device really are contending for one piece of silicon, and the exclusive/
shared conflict check below only means anything because the name is shared, not merely similar.

Cross-host reads are the other reason it's a graph: `workstation` may reference `fileserver.
storage.luksHeaders`, and the transport — SSH, a shared flake output, a rendered registry — is
an implementation detail this repo has no opinion about. A tree has no notion of an edge that
crosses from one root to another; a graph's whole point is that it does.

## The arithmetic nothing else does today

Eight checks, each proven in `checks/` to fire when violated and stay silent when satisfied —
never one without the other, since an assertion test that cannot fail is worthless:

- **RAM oversubscription** — the sum of every environment's own `resources.ram.limitMiB`
  (environments with no declared limit are excluded, not treated as claiming zero) must not
  exceed `resources.ram.totalMiB`.
- **CPU oversubscription** — the same sum, in CORES, checked against `resources.cpu.cores` —
  deliberately never `resources.cpu.threads`. SMT does not manufacture real execution capacity;
  a claim that fits comfortably under a 32-thread count is still oversubscribed on a 16-core box.
- **GPU exclusivity conflicts** — a device claimed `"exclusive"` by one environment while any
  other environment claims it at all (`"shared"` or a second `"exclusive"`) is an ERROR, never a
  precedence puzzle resolved by whichever pod scheduled first.
- **Microarch vs. arch** — an x86_64 psABI level (`x86_64-v3`) declared while `arch = "aarch64"`,
  or the mirror-image ARM-family string declared on an `x86_64` host, fails the build. Both
  fields type-check as plain strings on their own; nothing but this cross-check would ever catch
  a value surviving a copy-paste from one host's config to another's. It is *not* redundant with
  nixcpu's own arch/microarch assertion: that one lives behind `nixcpu.enable`, while the facts
  resolve regardless, so a host that states them purely for something else to read is checked here
  and nowhere else.
- **Resolved RAM ceiling** — an environment declaring `ram.limitMiB` on a host whose
  `ram.totalMiB` never resolved fails the build. The failure this prevents is the *green* one: an
  oversubscription check comparing claims against nothing.
- **Resolved CPU ceiling** — the same, for `cpu.quotaCores` against `cpu.cores`.
- **Resolved arch** — a host with a `cpu.microarch` and no `cpu.arch` fails, because the
  microarch-vs-arch cross-check is a comparison of the two and would otherwise be vacuously true.
- **No second copy of a mirrored fact** — a level-1 resource declared on the host, rather than at
  the domain that owns it, fails the build with a message naming the option to use instead.

The last four are what makes level 1's move from hand-declared options to mirrors safe. Trading a
loud "declare this" for a quiet "guard disabled" would have been a strictly worse repo, so each
guard is proven both ways: the checks include a host with a RAM claim and no nixram (must fail) and
a host with environments that claim nothing and no domain modules at all (must build).

## What it refuses to own

- **Any hardware fact.** Not one of them: every level-1 resource is a read-only mirror of the
  domain that owns it (see the table above), and nixhost adds no flake input on any of those repos
  to get one. A GPU exists here as whatever [nixgpu](https://github.com/julian-corbet/nixgpu-corbet-ch)'s
  own inventory says it is — mirrored *opaquely*, because the shape of a device is nixgpu's to
  define and revise, and this module reads nothing inside an entry but its name. A disk exists here
  as [nixstorage](https://github.com/julian-corbet/nixstorage-corbet-ch)'s own table, same idiom,
  same reason.
- **How any domain works.** nixgpu decides the scheduling mechanism that actually shares a card;
  nixstorage decides a disk's filesystem shape; nixram decides what a memory level implies for
  zram. This module knows the quantities and none of the mechanisms.
- **Policy.** Which services actually run on a host is that host's own configuration's business.
  `environments.<name>` says a k3s node exists and how much of the host it may claim, never
  which pods it runs.
- **Derived config.** The moment a fact declared here turns into a tuning value — a cgroup
  weight, a nice level, a kernel parameter computed from `cpu.microarch` — this stops being a
  one-way fact table and becomes a policy engine with an opinion. Enums and quantities go in;
  nothing computed from them is allowed to live here.

  `stance.class` and `stance.role` are where this bites hardest, because they are the two fields
  a consumer most wants to branch on. They are declared here and derived *nowhere* here: the
  domain that owns the knob owns the derivation. A memory subsystem decides what a capability
  tier implies for swap sizing; a storage domain decides what it implies for a scrub cadence.
  Declaring them once is what stops each of those domains growing its own per-host table that
  drifts silently, because nothing compares them.

## The cross-host half: `lib.assertHosts`

Everything the module does validates ONE host against itself. `lib.assertHosts` — a plain
function, not a module — validates hosts against each other, because **per-host validity is not
validity across hosts**: two hosts can each be correct by every assertion either one is able to make
about itself while both claim the same physical disk by-id. Both builds pass. Both hosts then
write that disk. No module can catch it, because from inside either host nothing is wrong.

It implements only the checks no module can make — one fact, two claimants — and nothing the
module already does:

| check | consequence it prevents |
|---|---|
| `disk-claimed-once` | two hosts writing one physical disk |
| `lan-address-unique` | a silently unreachable service |
| `overlay-address-unique` | traffic routed to whichever peer the coordinator saw last |

It takes **plain data**, never evaluated configurations, and `studies/eval-cost/` measured why:
reading every host's facts through the module system is the one read shape that goes nonlinear,
putting a 100-host cross-host assertion at roughly 2.6 hours against ~0.05 s for the same
assertion over plain data. Every field in the tree is optional, so a partially-described host
produces zero violations rather than an error — a cross-host check that crashes on an incomplete host
cannot be adopted one host at a time.

## The cross-namespace half: `lib.probeFact`

A defensive `config.<domain>.<path> or <fallback>` read — the idiom every level-1 mirror above uses,
and the one every sibling repo in this family has independently hand-rolled at least once — conflates
three states that are not one state:

| state | meaning | reported as |
|---|---|---|
| **absent** | the sibling domain is not composed on this host at all | nothing — silent, always |
| **resolved** | it *is* composed, and the fact genuinely resolves (including to a value that happens to equal the fallback) | nothing — silent, always |
| **unresolved** | it *is* composed, but this exact leaf moved, was renamed, was rejected by its own type, or was required and never given a value | a message, by default |

A bare `or` cannot tell **unresolved** apart from **absent** — both land on the identical fallback
with no trace of which happened — and that is not a hypothetical gap: it is what cost this family
real weeks of dead features when a mirrored option moved underneath a defensive reader elsewhere in
this repo family, and it was caught live again the same week this mechanism was built. `lib.probeFact`
is the fix, built once so other repos stop reinventing it:

```nix
{ config, lib, ... }:
let
  probe = lib.probeFact {
    inherit config;
    namespace = "nixcpu";        # the ONE top-level attribute that means "the sibling is composed"
    path = [ "hardware" "totalMiB" ]; # or the dotted string "hardware.totalMiB" -- both normalise the same
    fallback = null;             # substituted for "absent" and "unresolved"; never inspected to
                                  # decide which state occurred
    # mode = "warn";             # default -- renders into `.warnings`, meant for `config.warnings`
    # mode = "assert";           # opt in for a load-bearing read -- renders into `.assertions`,
                                  # shaped for `config.assertions`, and produces nothing in `.warnings`
  };
in {
  options.mymodule.ramTotal = lib.mkOption {
    type = lib.types.nullOr lib.types.ints.positive;
    readOnly = true;
    default = probe.value;                # the resolved value, or `fallback`
  };

  config.warnings = probe.warnings;       # [] unless state == "unresolved" and mode == "warn"
  config.assertions = probe.assertions;   # [] unless state == "unresolved" and mode == "assert"
}
```

Mirroring several facts at once (this module's own dozen-odd level-1 mirrors, for instance) folds
every probe through `lib.collectProbes`, rather than writing that fold at every call site:

```nix
config.warnings = (lib.collectProbes [ probeA probeB probeC ]).warnings;
```

Like `assertHosts`, it is a **plain function**, not a module: it forces nothing NixOS-specific, and
answering "absent" costs nothing — it never opens the namespace at all, proven in `checks/facts.nix`
against a namespace whose own value would throw if it were ever forced, and again in
`checks/facts-integration.nix` against a real NixOS config whose *unrelated* module has a genuinely
failing assertion, to show that probing an absent namespace never goes anywhere near a system build.
See `lib/facts.nix`'s own header for the two evaluation traps (`tryEval` not catching an `or`
fallback, and `or null` not catching a mandatory-unset option) a hand-rolled version keeps falling
into, and `checks/default.nix`'s `fact-wiring/*` group for this exact mechanism proven end to end
against this module's own real mirrors, including a genuine renamed option.

## Three backends, one file

`nixosModules.nixhost`, `systemManagerModules.nixhost`, and `darwinModules.nixhost` all point at
the exact same file, unchanged. That's possible because the module only ever touches `options`
and `config.assertions` — primitives every module system built on `lib.evalModules` shares —
and never `pkgs`, `systemd`, or any NixOS-only integration. A Mac under nix-darwin has just as
real a CPU arch, RAM total, and set of environments standing on it as a bare-metal NixOS server
does, and none of that is a NixOS-specific concept — the same reasoning
[nixiam](https://github.com/julian-corbet/nixiam-corbet-ch)'s own `modules/posix.nix` already
established for a cross-host identity table. See `checks/default.nix`'s backend-parity tests for
the CI proof covering NixOS and system-manager; the `nix-darwin` alias itself is offered on the
strength of the same reasoning but is not yet backed by a check — see
[`experiments/README.md`](experiments/README.md#001--is-darwinmodulesnixhost-actually-usable-or-just-a-plausible-looking-alias).

## Usage

```nix
{
  inputs.nixhost.url = "github:julian-corbet/nixhost-corbet-ch";

  # nixhost itself depends on none of these -- they are the owners of the facts it mirrors, and a
  # host brings in whichever of them it actually has facts for.
  inputs.nixcpu.url = "github:julian-corbet/nixcpu-corbet-ch";
  inputs.nixram.url = "github:julian-corbet/nixram-corbet-ch";
  inputs.nixgpu.url = "github:julian-corbet/nixgpu-corbet-ch";

  outputs = { self, nixpkgs, nixhost, nixcpu, nixram, nixgpu, ... }: {
    nixosConfigurations.example-host = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        nixhost.nixosModules.default

        # The domains that OWN this host's hardware facts. nixhost mirrors them read-only; it
        # takes no flake input on any of them, so bring in only the ones you actually use --
        # a mirror with no owner present resolves to null/{ }, and only becomes an error if
        # something asks this module to check a claim against it.
        nixcpu.nixosModules.default
        nixram.nixosModules.default
        nixgpu.nixosModules.default

        {
          nixcpu = { arch = "x86_64"; cores = 16; threads = 32; };
          nixram.hardware.totalMiB = 65536;
          nixgpu.stableDevicePaths.devices.gpu0 = {
            vendor = "amd"; pciId = "0x1002"; vramMiB = 16384;
          };

          nixhost = {
            name = "example-host";
            stance.backend = "nixos";

            environments.cluster-node = {
              kind = "k3s";
              resources = {
                ram.limitMiB = 49152;
                cpu.quotaCores = 10;
                gpu.gpu0.access = "shared";
              };
            };
          };
        }
      ];
    };
  };
}
```

Reading a fact back out anywhere else in the same flake: `self.nixosConfigurations.example-host.
config.nixhost.resources.ram.totalMiB` — no separate query language, just the ordinary module
system every other fact in a NixOS configuration already goes through.

## Status

The module and its eight assertion groups are complete, exported for NixOS, system-manager, and
(unverified, see above) nix-darwin, and covered by eval-time tests proving every assertion both
fires on a genuinely broken input and stays silent on a genuinely correct one — including the
two boundary cases that matter most: claims summing to EXACTLY a total (must pass) and a CPU
claim that fits under `threads` but not `cores` (must still fail). See
[`experiments/README.md`](experiments/README.md) for what's reasoned but not yet measured: real
nix-darwin composition, whether a per-environment VRAM claim would add anything nixgpu's own
live pressure-watcher doesn't already do better, the mirrors against the REAL domain modules
rather than the option-shape stubs `checks/` supplies, whether a GPU claim naming a device the
mirrored inventory doesn't contain should itself be an error, the cross-host graph resolved across
two real hosts, and behavior at a host running more than a couple of environments at once.

## Repository layout

| Path | Purpose |
|---|---|
| `flake.nix` | Flake entry point: `nixosModules.default` / `systemManagerModules.default` / `darwinModules.default` (the same file, all three). |
| `modules/nixhost.nix` | The module: the full option surface (`stance`, `resources`, `environments`) and the eight assertion groups. Every `resources` field is a read-only mirror of the domain that owns it, read through `lib.probeFact`. |
| `lib/hosts.nix`, `lib/facts.nix` | The two plain-function `lib` outputs: `assertHosts` (cross-host) and `probeFact`/`collectProbes` (cross-namespace). Neither is a module, and neither is specific to this repo's own use of it — see their own sections above. |
| `examples/host/configuration.nix` | A complete, self-contained, entirely fictional host — the shape `checks/`'s `example/modules-evaluate` test proves evaluates cleanly on its own. |
| `checks/` | Eval-time tests: every assertion proven in both directions, plus NixOS/system-manager backend parity. `checks/domain-stubs.nix` supplies the mirrored domains' option SHAPE, so the mirrors can be tested without this repo taking a flake input on five other repos. `checks/facts.nix`/`checks/facts-integration.nix` prove `lib.probeFact` itself; the `fact-wiring/*` group in `checks/default.nix` proves it composed through this module's own real mirrors. |
| `experiments/`, `studies/` | Open questions this repo's own reasoning hasn't yet measured, and the (currently empty) record of the ones that have been. |
