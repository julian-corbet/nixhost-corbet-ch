# Experiments

Throwaway trials: spikes, one-off scripts, measurements not yet worth writing up properly.
Nothing here is guaranteed to work, be maintained, or survive the next cleanup pass. If
something in here turns out to matter, distill the actual finding into
[`../studies/`](../studies/README.md) and let the experiment stay disposable (or delete it).

This is also the open-questions ledger for nixhost's own judgment calls -- every entry below
corresponds to a claim reasoned in a module or README comment but not actually measured or
exercised by `checks/`. `nix flake check` proves the option surface and its five assertion
groups *evaluate* correctly against small, hand-written fixtures (see `checks/default.nix`);
none of it has been run against real hosts.

All open.

## 001 — is `darwinModules.nixhost` actually usable, or just a plausible-looking alias?

**Question:** `flake.nix` exposes `darwinModules.nixhost` pointing at the same
`modules/nixhost.nix` file used for `nixosModules`/`systemManagerModules`, on the reasoning
that the module only uses bare `options`/`config.assertions` primitives common to every module
system built on `lib.evalModules`. This repo pulls in no `nix-darwin` input and has no check
that actually composes the module into a `darwinConfiguration` the way `checks/default.nix`
does for the other two backends -- the same open question a sibling pure-data repo's experiment 001
flags for its identically-shaped alias.

**Hypothesis:** nix-darwin's module system is close enough to NixOS's own (both are
`lib.evalModules` underneath) that a module this simple -- no `pkgs`, no `systemd`, no
platform-specific option namespace referenced -- composes without incident, on the strength of
the exact same reasoning the other pure-data repos in this family offer for the same claim.

**Method sketch:** add `nix-darwin` as a `checks`-only input, build a minimal
`darwinConfiguration` composing `darwinModules.nixhost` with a small fixture (the Mac from these
hosts is the natural real-world case: `aarch64`, no GPU, no `environments` at all),
and add it to the backend-parity checks alongside the existing NixOS/system-manager pair.

**Status:** open.

## 002 — should an environment's GPU claim carry a VRAM quantity, not just an access stance?

**Question:** `resources.gpu.<name>.vramMiB` is a level-1 hardware fact; nothing at level 2
claims a VRAM quantity against it -- an environment's only GPU claim is the `none`/`shared`/
`exclusive` access stance. That was a deliberate scope decision (see `modules/nixhost.nix`'s
own description on `vramMiB`: VRAM oversubscription fails at allocation time on the consumer's
own silicon, which is arbitration nixgpu already owns), but it has not been weighed against a
real workload where "shared" hides a genuine VRAM contention two co-resident environments both
assumed would fit.

**Hypothesis:** access-stance-only is probably still correct -- a MiB-level VRAM budget per
environment would be exactly the "derived config" this module's own header refuses to own
(nixgpu's `pressure-watcher` already reads live sysfs VRAM pressure, which is a truer signal
than any static claim declared here could be) -- but this has not been checked against nixgpu's
real behavior to confirm a static claim would add nothing nixgpu doesn't already do better.

**Method sketch:** once this module is wired into the same host nixgpu already runs on, compare
what nixgpu's live pressure-watcher actually observes against what a hypothetical static
per-environment VRAM claim here would have predicted, for at least one real contention event.

**Status:** open.

## 003 — `resources.storage.disks`'s reflection of `nixstorage.disks` is only proven empty

**Question:** `checks/default.nix` proves the defensive-read fallback (`config.nixstorage.disks
or { }` resolves to `{ }` when nixstorage is not imported at all, since this repo takes no
flake input on it by design) -- it has never been evaluated with a REAL `nixstorage.disks`
table actually present, to confirm the mirrored value at `nixhost.resources.storage.disks`
genuinely equals it, and that `readOnly = true` really does refuse a second, conflicting
definition here the way it is supposed to.

**Hypothesis:** this should work exactly as nixboot's `esp.fromLayout` defensive read already
does in production against `nixstorage.layout` -- the same idiom, one repo over -- but has not
actually been composed against a real `nixstorage.disks` table in this repo's own `checks/`.

**Method sketch:** add `nixstorage` as a `checks`-only input, compose both modules together
with a small disk fixture, and assert `config.nixhost.resources.storage.disks ==
config.nixstorage.disks` on the resulting evaluation.

**Status:** open.

## 004 — the cross-host graph itself (`workstation` reading `fileserver.storage.luksHeaders`) is asserted, not built

**Question:** the README's pitch describes cross-host reads as first-class, with the transport
as an implementation detail. This repo only ever evaluates ONE host's `nixhost` block at a
time -- nothing here assembles multiple hosts' evaluated configs into one queryable graph, or
proves that a second host can actually resolve a path rooted at a different host's `name`.
Whatever assembles that (this family's own flake composing several `nixosConfigurations.<name>`
and reading `self.nixosConfigurations.<name>.config.nixhost` back out, most plausibly) does not
exist in this repo, and whether that is the right place to draw the line -- one schema per
host, versus a registry-style aggregator that keys many machines by slug --
hasn't been tested against a real two-host reference.

**Hypothesis:** the line is probably right where it is -- nixhost declares the shape a single
evaluated config exposes at its own `config.nixhost` path; whatever flake actually owns
`self.nixosConfigurations` is the one place that can assemble several of those into a graph,
and it should not be this repo's job to know what a consuming flake's own output attribute set
looks like (the same reasoning a sibling pure-data repo's experiment 002 already applies to
`knownFlakeConfigurations`) -- but this has never been tried against a real multi-host flake.

**Method sketch:** wire `nixhost` into two real host configurations in one flake and confirm
`self.nixosConfigurations.host-b.config.nixhost.resources.ram.totalMiB` is genuinely readable
from `host-a`'s own evaluation (or from a plain `nix eval` against the flake), with no
transport-specific glue beyond ordinary flake output composition.

**Status:** open.

## 005 — untested at anything near a real multi-environment host's actual scale

**Question:** every fixture in `checks/default.nix` declares at most two environments and two
GPUs. fileserver alone (per its real host facts) runs k3s plus podman plus the
desktop's own bare-metal GPU use simultaneously, and a larger host could plausibly stack
more environments than that. Nothing here measures `nix flake check`'s eval time, or whether the
generated assertion MESSAGES stay legible, against a host with, say, ten declared environments
and several GPUs.

**Hypothesis:** the same reasoning a sibling registry repo gives for its ~100-host
registry applies here at a smaller multiplier -- attrset folds over a handful of environments
per host are nowhere near a real eval-time concern -- but "should not be" is an assumption, not
a benchmark.

**Method sketch:** generate a synthetic ten-or-more-environment fixture and confirm both eval
time and the rendered assertion messages (particularly the RAM/CPU oversubscription messages,
which list every claimant by name) stay fast and legible at that size.

**Status:** open.
