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
fileserver.gpu.apps                     # bare metal: the host's own consumers
fileserver.k3s.gpu.apps                 # pods on the SAME card
fileserver.vm.container.gpu.apps        # and deeper -- a container inside a VM
workstation.cpu.microarch
```

— plus the arithmetic that makes those paths worth having: this module sums what every
environment standing on a host claims, checks it against what the host actually has, and
refuses to evaluate if the claims don't fit.

## The model

```nix
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

  # LEVEL 1 — the machine itself.
  resources = {
    cpu = {
      arch      = "x86_64";                     # x86_64 | aarch64
      microarch = "x86_64-v3";                  # checked against arch, below
      cores     = 16;  threads = 32;
      scheduler = "bore";
    };
    ram.totalMiB = 128 * 1024;
    gpu.gpu0     = { vendor = "amd"; pciId = "0x1002"; vramMiB = 16384; };
    storage.disks = { }; # read-only mirror of config.nixstorage.disks — never restated here
    net.lan0     = { mac = "aa:bb:cc:dd:ee:ff"; addresses.lan = "192.168.1.10"; };
  };

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
`host.gpu.app`. A container inside a VM is `host.vm.container.gpu.app`. Nothing about the second
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
environment standing on that SAME host schedules onto it. `fileserver.gpu.apps` and
`fileserver.k3s.gpu.apps` are two different paths into one card, and `environments.<name>.
resources.gpu.<name>` deliberately shares its key with `resources.gpu.<name>` rather than each
environment inventing its own private device namespace — two environments claiming the
identically-named device really are contending for one piece of silicon, and the exclusive/
shared conflict check below only means anything because the name is shared, not merely similar.

Cross-host reads are the other reason it's a graph: `workstation` may reference `fileserver.
storage.luksHeaders`, and the transport — SSH, a shared flake output, a rendered registry — is
an implementation detail this repo has no opinion about. A tree has no notion of an edge that
crosses from one root to another; a graph's whole point is that it does.

## The arithmetic nothing else does today

Five checks, each proven in `checks/` to fire when violated and stay silent when satisfied —
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
  a value surviving a copy-paste from one host's config to another's.
- **GPU device completeness** — a declared `resources.gpu.<name>` entry with an empty vendor/
  pciId or a non-positive `vramMiB` fails the build, rather than silently looking exactly like a
  card that genuinely has no vendor to whatever reads this table next.

## What it refuses to own

- **How any domain works.** A GPU exists here as a vendor/PCI-ID/VRAM tuple; [nixgpu](https://github.com/julian-corbet/nixgpu-corbet-ch)
  decides the scheduling mechanism that actually shares it. A disk exists here only as a
  read-only mirror of [nixstorage](https://github.com/julian-corbet/nixstorage-corbet-ch)'s own
  table — nixhost never restates a disk, and never adds a flake input on nixstorage to get one;
  see `modules/nixhost.nix`'s own `resources.storage.disks` for the defensive-read idiom.
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

## Three backends, one file

`nixosModules.nixhost`, `systemManagerModules.nixhost`, and `darwinModules.nixhost` all point at
the exact same file, unchanged. That's possible because the module only ever touches `options`
and `config.assertions` — primitives every module system built on `lib.evalModules` shares —
and never `pkgs`, `systemd`, or any NixOS-only integration. A Mac under nix-darwin has just as
real a CPU arch, RAM total, and set of environments standing on it as a bare-metal NixOS server
does, and none of that is a NixOS-specific concept — the same reasoning
[nixid](https://github.com/julian-corbet/nixid-corbet-ch)'s own `modules/posix.nix` already
established for a cross-host identity table. See `checks/default.nix`'s backend-parity tests for
the CI proof covering NixOS and system-manager; the `nix-darwin` alias itself is offered on the
strength of the same reasoning but is not yet backed by a check — see
[`experiments/README.md`](experiments/README.md#001--is-darwinmodulesnixhost-actually-usable-or-just-a-plausible-looking-alias).

## Usage

```nix
{
  inputs.nixhost.url = "github:julian-corbet/nixhost-corbet-ch";

  outputs = { self, nixpkgs, nixhost, ... }: {
    nixosConfigurations.example-host = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        nixhost.nixosModules.default

        {
          nixhost = {
            name = "example-host";
            stance.backend = "nixos";

            resources = {
              cpu = { arch = "x86_64"; cores = 16; threads = 32; };
              ram.totalMiB = 65536;
              gpu.gpu0 = { vendor = "amd"; pciId = "0x1002"; vramMiB = 16384; };
            };

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

The module and its five assertion groups are complete, exported for NixOS, system-manager, and
(unverified, see above) nix-darwin, and covered by eval-time tests proving every assertion both
fires on a genuinely broken input and stays silent on a genuinely correct one — including the
two boundary cases that matter most: claims summing to EXACTLY a total (must pass) and a CPU
claim that fits under `threads` but not `cores` (must still fail). See
[`experiments/README.md`](experiments/README.md) for what's reasoned but not yet measured: real
nix-darwin composition, whether a per-environment VRAM claim would add anything nixgpu's own
live pressure-watcher doesn't already do better, `resources.storage.disks` against a genuinely
populated `nixstorage.disks` table, the cross-host graph resolved across two real hosts, and
behavior at a host running more than a couple of environments at once.

## Repository layout

| Path | Purpose |
|---|---|
| `flake.nix` | Flake entry point: `nixosModules.default` / `systemManagerModules.default` / `darwinModules.default` (the same file, all three). |
| `modules/nixhost.nix` | The module: the full option surface (`stance`, `resources`, `environments`) and the five assertion groups. |
| `examples/host/configuration.nix` | A complete, self-contained, entirely fictional host — the shape `checks/`'s `example/modules-evaluate` test proves evaluates cleanly on its own. |
| `checks/` | Eval-time tests: every assertion proven in both directions, plus NixOS/system-manager backend parity. |
| `experiments/`, `studies/` | Open questions this repo's own reasoning hasn't yet measured, and the (currently empty) record of the ones that have been. |
