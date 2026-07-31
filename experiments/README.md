# Experiments

Throwaway trials: spikes, one-off scripts, measurements not yet worth writing up properly.
Nothing here is guaranteed to work, be maintained, or survive the next cleanup pass. If
something in here turns out to matter, distill the actual finding into
[`../studies/`](../studies/README.md) and let the experiment stay disposable (or delete it).

This is also the open-questions ledger for nixhost's own judgment calls -- every entry below
corresponds to a claim reasoned in a module or README comment but not actually measured or
exercised by `checks/`. `nix flake check` proves the option surface and its eight assertion
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

**Question:** the mirrored device table carries a `vramMiB` per device (nixgpu's field, not this
repo's); nothing at level 2 claims a VRAM quantity against it -- an environment's only GPU claim is
the `none`/`shared`/`exclusive` access stance. That was a deliberate scope decision (VRAM
oversubscription fails at allocation time on the consumer's own silicon, which is arbitration nixgpu
already owns), but it has not been weighed against a real workload where "shared" hides a genuine
VRAM contention two co-resident environments both assumed would fit.

**Hypothesis:** access-stance-only is probably still correct -- a MiB-level VRAM budget per
environment would be exactly the "derived config" this module's own header refuses to own
(nixgpu's `pressure-watcher` already reads live sysfs VRAM pressure, which is a truer signal
than any static claim declared here could be) -- but this has not been checked against nixgpu's
real behavior to confirm a static claim would add nothing nixgpu doesn't already do better.

Note what changed with the mirrors: nothing in this module now reads `vramMiB` at all (the device
completeness assertion that used to force it is gone, since nixgpu enforces its own required
fields). So adding a VRAM ceiling here would mean this module reaching INSIDE an opaquely-mirrored
table for the first time, which is a bigger step than it was when the field was declared here.

**Method sketch:** once this module is wired into the same host nixgpu already runs on, compare
what nixgpu's live pressure-watcher actually observes against what a hypothetical static
per-environment VRAM claim here would have predicted, for at least one real contention event.

**Status:** open.

## 003 — the mirrors are proven against a STUB of each owner's option surface, not the owner

**Question:** all five level-1 mirrors (`cpu.*`, `ram.totalMiB`, `gpu`, `net`, `storage.disks`) are
now tested in both directions -- populated (the mirrored value equals the fact) and absent (the
defensive read takes its `null`/`{ }` fallback) -- but the "populated" half runs against
`checks/domain-stubs.nix`, a hand-written declaration of nixcpu/nixram/nixgpu/nixnet/nixstorage's
option SHAPE at exactly the paths the mirrors read. It is not those repos. Nothing in this repo
notices if an upstream option is renamed, retyped, or moved: a green check here means "the mirror
reads the shape that file describes", never "the mirror reads nixcpu".

This is the deliberate cost of taking no flake input on the owners (see `domain-stubs.nix`'s own
header for why five checks-only inputs is the worse trade), and it is a real gap, not a hypothetical
one: a rename upstream would leave every check here green while every host silently fell back to
`null` -- which the assert-resolved assertions would catch for the two ceilings, and would NOT catch
for `gpu`/`net`/`storage.disks`, where an empty table is a legitimate state.

**Update (`lib.probeFact`, `lib/facts.nix`):** the RUNTIME half of this gap is now closed. Every
level-1 mirror reads through `lib.probeFact`, which tells "domain not composed" apart from "domain
composed, but this leaf did not resolve" and renders the second as a `config.warnings` entry naming
the option path, the namespace, and the fallback in use -- for `gpu`/`net`/`storage.disks` exactly as
much as for the two ceilings (see `checks/default.nix`'s `fact-wiring/*` group, which proves this
against a REAL renamed `nixgpu` option surface, composed through the actual `nixhostModule`). A real
host that renames a fact out from under one of these mirrors now gets a warning instead of silence.

What remains open is narrower than the original question: this repo's own CI still cannot notice if
`checks/domain-stubs.nix` ITSELF drifts from the real nixcpu/nixgpu/nixram/nixnet/nixstorage option
surfaces -- a stub that stays wrong in the same way the real module changed would still show green
here. `lib.probeFact` protects every HOST that adopts it; it does not protect this repo's own test
fixture from going stale relative to the five repos it stands in for. The method sketch below (a CI
job in the consuming flake, or a `nix eval` surface-diff) is still the way to close that half.

**Hypothesis:** the stub is faithful today (it was written by reading each owner's option
declaration field by field, including which fields have no default), and the mirrors work exactly
as nixboot's `esp.fromLayout` defensive read already does in production against `nixstorage.layout`.
But faithfulness is a property of a moment, not of a design.

**Method sketch:** two candidates, and the choice is itself the open question. Either (a) a CI job
outside this repo -- in whichever flake actually composes the family -- that evaluates nixhost
against the real modules and asserts each mirror equals its source, which keeps this repo
input-free and puts the integration test where the integration actually happens; or (b) a
`nix eval` smoke test that fetches each owner's `options` and compares the paths this repo reads
against them, failing on a rename without depending on the modules at build time.

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

## 006 — should a GPU claim naming a device the mirrored inventory doesn't contain be an error?

**Question:** `environments.<name>.resources.gpu.<device>.access` and `resources.gpu.<device>` share
a key on purpose, and now that the device table is a mirror of `nixgpu.stableDevicePaths.devices`
there is, for the first time, a real inventory a claim could be checked against. Nothing checks it:
a claim naming `gpu1` on a host whose inventory has only `gpu0` evaluates cleanly, and the
exclusivity conflict check happily groups claims for a device that does not exist.

**Hypothesis:** leaving it unchecked is probably right, and for a specific structural reason rather
than conservatism. The conflict check does not divide against the inventory -- it groups claims by
name and needs no device table at all -- so an empty inventory disables nothing, and there is no
silent-guard-loss to repair (unlike `cores`/`totalMiB`, where MIRROR + ASSERT-RESOLVED was
mandatory). Adding the check would therefore mean either a new guard that self-disables whenever
nixgpu is absent -- the exact anti-pattern this repo's ceiling assertions exist to avoid -- or an
assert-resolved-style rule that any GPU claim REQUIRES nixgpu to be imported, which makes a
perfectly checkable claim undeclarable on a host that does not own the GPU domain.

**Method sketch:** count, across real hosts once several are wired up, how often a claim names a
device absent from the inventory, and whether those cases were typos (an argument for the check) or
hosts that legitimately declare claims before nixgpu is adopted (an argument against). A typo rate
above zero with no legitimate second case would settle it.

**Status:** open.

## 007 — `resources.cpu.coreTypes` is mirrored but read by nothing

**Question:** `coreTypes` (nixcpu's P-core/E-core split) is mirrored so the fact is addressable at
`<host>.cpu.coreTypes`, closing an asymmetry where nixcpu owned a CPU fact this namespace could not
reach. But no assertion here reads it, and in particular the CPU oversubscription check treats all
cores as interchangeable -- it sums `quotaCores` against `cores` with no notion that 8 of those
cores are efficiency cores that deliver a fraction of the throughput the same quota number buys on a
performance core.

**Hypothesis:** the sum is still the right check -- a quota is a quota, and which physical cores a
workload lands on is a scheduling decision (nixcpu's own description says as much), not something a
declaration-time envelope can predict. But "16 cores of ceiling" genuinely means two different
things on a hybrid host, and it is not obvious that the arithmetic should stay blind to that.

**Method sketch:** state a hybrid host's real `coreTypes` and a set of environment quotas that
together fit `cores` but would not fit if E-cores were discounted, then check whether the resulting
allocation actually behaves like the numbers promised. Only a measurement can say whether the
distinction belongs in this arithmetic or nowhere near it.

**Status:** open.

## 008 — `mirrorOf` reports a type error at the owner as an unresolved fact

**Question:** every level-1 mirror resolves through `mirrorOf`, which `tryEval`s the defensive read
so that a domain imported *without* the fact stated arrives as `null` instead of aborting evaluation
from inside an option default. That collapse also swallows a genuine TYPE error at the owner: a
`nixcpu.cores = "sixteen"` rejected by nixcpu's own `ints.positive` reaches nixhost as `null` and is
reported as "the fact did not resolve" rather than "the value was rejected". The assert-resolved
messages name all three possible causes and tell the operator to evaluate the owner's option
directly, but that is a mitigation, not a fix.

**Hypothesis:** the trade is right, and narrower than it sounds. A type error at the owner is loud
already whenever the owner reads its own field (nixcpu's assertions do, when `nixcpu.enable` is
true), so the masked window is only "facts stated for someone else to read, with the domain's own
policy switched off, and a value of the wrong type". Against that, refusing the collapse costs a
consistent failure mode for the *common* mistake (a fact simply never stated) and, as this repo
found the hard way, makes a mirror's definition list uninspectable — the module system forces every
definition's value while discharging `mkIf`/`mkMerge`, so a throwing default broke the check that
detects a second declaration.

**Method sketch:** the honest test is frequency, not reasoning: across real hosts, count how often a
level-1 fact fails to resolve, and how many of those turn out to be a rejected value rather than an
absent one. A non-trivial share would argue for distinguishing them — plausibly by having `mirrorOf`
report WHICH branch it took, and letting the assertion say so, rather than by removing the collapse.

**Status:** open.
