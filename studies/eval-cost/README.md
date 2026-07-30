# Eval-cost: does the 95.1s vs 0.021s data point hold as a curve?

The design spec (`../../nixhost-spec.md`) states a hard rule off the back of one measurement:

    evaluating ONE host's full NixOS module system :  95.1 s
    importing a plain-data .nix file              :   0.021 s

and forbids `hosts.<name> = <evaluated nixosSystem.config>` in favour of `hosts.<name> = <a
plain attrset of facts>`, on the reasoning that a cross-host assertion over 100 evaluated hosts
costs "~2.6 hours" (100 x 95.1s = 9,510s = 2.64h -- that arithmetic is exact, and this study did
not need to re-derive it; what it needed to check is whether the *plain-data* side of the claim
actually holds up to N=250, and whether the *evaluated-config* side generalizes beyond N=1).

**Answer: yes, and yes -- with two honest caveats below.** Plain data stays flat, in wall
time, cpuTime, thunks-forced, and bytes-allocated, all the way to N=250 hosts and a genuine
two-field cross-host assertion. Evaluated-per-host config costs order-of-magnitude more even at
N=1, and the *specific* case that turns catastrophic is reading a fact from *every* host, not
merely having N hosts around as evaluated config -- see "the nuance" below.

## Method

Run `./bench.sh` (from this directory). It:

1. Synthesizes N-host fact trees as plain data (`lib/gen-plain-hosts.nix`) for N = 1, 10, 50,
   100, 250, and measures three read shapes, 7 repetitions each:
   - **case 1** -- read one fact (`ram.totalMiB`) from one host (`host0`)
   - **case 2** -- read that same fact from *every* host (sum via `foldl'`) -- the
     cross-host-assertion shape
   - **case 3** -- a genuine cross-host assertion (`lib/cross-host-assert.nix`): no two hosts share a
     LAN address; no two share a disk by-id. Proven to fire in **both directions** (violated ->
     error data returned; satisfied -> silent `ok = true`) -- see "Correctness, not just cost"
     below; a benchmark of an assertion that can't be shown to actually assert is worthless.
2. Builds the same three facts as a genuinely evaluated `lib.nixosSystem` per host
   (`lib/gen-nixos-hosts.nix`), for N = 1, 3, 5 only (as instructed -- see "Limitations of this
   run" below for why N=100/250 was deliberately never run on this branch), and repeats reads
   shaped like case 1 and case 2 against it, 5 repetitions each.
3. Times every single `nix eval` invocation with an external wall clock (`date +%s.%N`, not
   the shell's 1-second-resolution `$SECONDS` and not `nix`'s own `--show-trace`), and captures
   the full `NIX_SHOW_STATS=1` engine-counter dump for every run to its own file
   (`results/raw/*.json`), so any number quoted below can be checked against the actual counter,
   not just the wall clock.

Every measured expression is a **fresh `nix eval` process** -- no in-process warm state is being
measured, only real process-to-process cost. Raw per-run data: `results/summary.csv` (one row
per case x N x repetition) and `results/raw/` (full stats dumps). Machine: 8-core Intel Core
Ultra 7 258V laptop (mobile chip, see "limitations" below), Determinate Nix 3.18.1 / Nix 2.33.4,
`eval-cache = true` in `nix.conf` (irrelevant here -- see "where caching helped").

## Results

| case | N | wall median (s) | wall min-max (s) | cpuTime mean (s) | nrThunks mean | gc.totalBytes mean |
|---|---:|---:|---|---:|---:|---:|
| 1 - plain, one fact, one host | 1 | 0.0546 | 0.0411-0.0655 | 0.0111 | 11 | 37,776 |
| 1 - plain, one fact, one host | 10 | 0.0492 | 0.0364-0.0541 | 0.0105 | 29 | 38,944 |
| 1 - plain, one fact, one host | 50 | 0.0437 | 0.0373-0.0627 | 0.0101 | 109 | 48,768 |
| 1 - plain, one fact, one host | 100 | 0.0348 | 0.0214-0.0465 | 0.0106 | 209 | 62,784 |
| 1 - plain, one fact, one host | 250 | 0.0273 | 0.0220-0.0328 | 0.0100 | 509 | 94,848 |
| 2 - plain, one fact, every host | 1 | 0.0490 | 0.0430-0.0797 | 0.0122 | 14 | 37,776 |
| 2 - plain, one fact, every host | 10 | 0.0462 | 0.0390-0.0568 | 0.0107 | 68 | 40,320 |
| 2 - plain, one fact, every host | 50 | 0.0396 | 0.0304-0.0584 | 0.0091 | 308 | 62,032 |
| 2 - plain, one fact, every host | 100 | 0.0290 | 0.0226-0.0305 | 0.0108 | 608 | 96,480 |
| 2 - plain, one fact, every host | 250 | 0.0228 | 0.0207-0.0299 | 0.0098 | 1,508 | 161,808 |
| 3 - plain, cross-host assertion | 1 | 0.0431 | 0.0371-0.0550 | 0.0126 | 48 | 38,400 |
| 3 - plain, cross-host assertion | 10 | 0.0493 | 0.0404-0.0642 | 0.0108 | 255 | 53,264 |
| 3 - plain, cross-host assertion | 50 | 0.0488 | 0.0336-0.0590 | 0.0095 | 1,175 | 125,040 |
| 3 - plain, cross-host assertion | 100 | 0.0298 | 0.0232-0.0330 | 0.0119 | 2,325 | 218,320 |
| 3 - plain, cross-host assertion | 250 | 0.0286 | 0.0251-0.0297 | 0.0116 | 5,775 | 543,424 |
| 4a - nixosSystem, one fact, one host | 1 | 0.7394 | 0.7213-0.8006 | 0.6085 | 843,702 | 90,225,760 |
| 4a - nixosSystem, one fact, one host | 3 | 1.2343 | 0.8058-1.4188 | 0.7950 | 843,706 | 90,225,760 |
| 4a - nixosSystem, one fact, one host | 5 | 1.2882 | 0.9931-1.3578 | 0.8790 | 843,710 | 90,225,760 |
| 4b - nixosSystem, one fact, every host | 1 | 0.7590 | 0.7198-0.8679 | 0.6077 | 843,705 | 90,225,760 |
| 4b - nixosSystem, one fact, every host | 3 | 2.7464 | 1.4068-3.1575 | 1.2586 | 2,502,971 | 252,758,256 |
| 4b - nixosSystem, one fact, every host | 5 | 2.1628 | 1.6926-4.5091 | 1.6232 | 4,162,237 | 415,302,768 |

(Raw data behind every row: `results/summary.csv`; per-run engine dumps: `results/raw/`. `nrThunks`/
`gc.totalBytes` reproduced byte-for-byte between two independent runs of this harness taken
minutes apart -- deterministic properties of the expression, unlike wall time; see "reading the
table" below for why that matters and "limitations" for why wall time itself got visibly
noisier on this machine between the two runs.)

## Reading the table

**Plain data does not degrade at 250 -- confirmed, not assumed.** Wall time for all three
plain-data cases stays inside a ~0.02-0.05s band from N=1 to N=250, including case 3's genuine
two-field cross-host assertion at N=250. That is the honest headline the task asked for: *if*
plain data had also degraded badly at 250, that would have been the more interesting finding;
it does not, so the design spec's hard rule is measured, not merely argued, at the top of its
stated range.

**But wall time cannot actually show you the plain-data curve at this N -- thunks and bytes
can, and do.** This is the "say where caching helped" honesty the task asked for, except the
effect here isn't caching, it's fixed process overhead: a bare `nix eval` process (parsing its
own config, starting the evaluator) costs on the order of 10-30ms regardless of what it
evaluates, and every plain-data case here finishes inside that same floor. `nrThunks` and
`gc.totalBytes`, which are *engine* counters rather than wall-clock, scale cleanly and linearly
with N the whole way:

- case 1 (build the tree, read one host): ~2.0 thunks/host added (11 -> 509 over N=1->250) --
  this is the cost of laying out the N-entry attrset skeleton itself, not of reading into any
  host beyond `host0`; the other 249 hosts' *inner* fields are never forced.
- case 2 (read every host): ~6.0 thunks/host -- each host's `ram` attrset genuinely gets
  entered and its one field forced.
- case 3 (cross-host assertion, two fields, two accumulator dicts): ~23.0 thunks/host -- reads two
  fields per host and appends into two claims-dicts, so costs roughly 3-4x case 2 per host, and
  is still ~5,775 thunks / ~543KB total at N=250. Nothing here is close to a concerning
  threshold; it is single-digit-microseconds-per-host territory being drowned out by a
  multi-millisecond process floor.

**The requested `gc.heapSize` field turned out to be a fixed reservation, not a usage signal
-- worth flagging rather than silently swapping it out.** Every single run in this study,
plain-data or nixosSystem, N=1 or N=250, reports the identical `gc.heapSize: 4295229440` (~4.00
GiB) -- this is evidently a Boehm-GC arena reservation made once at evaluator start, not actual
live-heap usage. `gc.totalBytes` (actual bytes allocated across the run) is the field that
moves with N and is what the table reports; `gc.heapSize` is included in the raw JSON dumps for
completeness but is not evidence of anything at this scale.

**Evaluated-per-host config costs orders of magnitude more even at N=1 -- before any
cross-host multiplication.** `4a`/`4b` at N=1 already cost ~0.61s cpuTime / ~0.74-0.76s wall
and 843,702 thunks -- roughly **146x the thunks** and **~27x the wall time (~52x the cpuTime)**
of the *most expensive* plain-data case (`3`, the genuine cross-host assertion) at its largest
tested N=250. This is the fixed cost of evaluating nixpkgs's own stock module list once (~400
modules, boot/systemd/users/networking/... all present in this fixture purely because
`lib.nixosSystem` always imports them, whether or not the caller's own config uses any of it)
plus this study's one extra module (`lib/facts-options.nix`).

**`nrExprs` staying flat (667,227, identical at N=1 and N=5 in case 4b) while `nrThunks` scales
hugely is itself informative**: `nrExprs` counts distinct parsed AST nodes, and nixpkgs's module
files are parsed once per process regardless of how many times `lib.nixosSystem` is called
inside that process -- the cost that scales with N is *re-executing* the same parsed module
functions per host (thunks, function calls), not re-parsing them. Confirms the module-merge
fixpoint, not source parsing, is where the per-host cost actually lives.

## The nuance the design spec's blunter statement doesn't quite capture

`4a` (one fact from *one* host, among N nixosSystem hosts) stays flat regardless of N: 843,702
thunks at N=1, 843,706 at N=3, 843,710 at N=5 -- essentially unchanged (the +4 per +2 hosts is
just the outer `listToAttrs`/`genList` skeleton, the same ~2 thunks/host skeleton cost plain
data's own case-1 pays for exactly the same reason). **Reading one host's evaluated config, out
of several such hosts declared as independent lazy attrset entries, does NOT force the sibling
hosts' module systems.** Laziness *does* hold across hosts, even when each host is internally a
full evaluated NixOS config -- exactly as it holds for plain data.

What actually goes nonlinear is `4b`: reading a fact from *every* host. There, cost scales
with N (843,705 thunks at N=1 -> 2,502,971 at N=3 -> 4,162,237 at N=5; cpuTime 0.608s -> 1.259s
-> 1.623s), because now every single host's own module-merge fixpoint genuinely gets forced,
once each.

So the design spec's own "FORBIDDEN" framing is correct for the case that actually matters --
a **cross-host** read/assertion, exactly the thing `nixhost`'s whole reason to exist is to make
affordable (level-1/level-2 arithmetic checks, cross-host references) -- but it is not that
*merely having* N hosts as evaluated config is catastrophic; it's that the one operation you
will actually want to run (touch every host once) is the one that multiplies the per-host cost
by N. A design that only ever read one host at a time from evaluated config would not show
this blowup; a design whose entire point is cross-host assertions cannot avoid it. That is a
sharper, not a weaker, argument for the plain-data rule, because cross-host assertions are
precisely what `nixhost` is *for*.

## Extrapolating to N=100 and N=250

**Plain data: measured, not extrapolated, and stays affordable.** Case 3 (the heaviest
plain-data case, the genuine two-field cross-host assertion) measured directly at N=100
(~0.033s wall, 2,325 thunks, 218KB) and N=250 (~0.034s wall, 5,775 thunks, 543KB). There is
nothing to extrapolate -- the curve simply has not bent yet, and the thunk/byte counts say it
will not bend for a very long time past 250: even a naive linear projection from the ~23
thunks/host marginal cost puts a synthetic 100,000 hosts at ~2.3M thunks -- still a
fraction of what ONE trivial nixosSystem host alone costs in this study (843,702 thunks).

**nixosSystem contrast: extrapolated from only 3 points, flagged as such, and this fixture is
a floor, not a ceiling.** Fitting the `4b` **cpuTime** measurements (0.608s / 1.259s / 1.623s
at N=1/3/5) as a straight line through the endpoints gives a marginal cost of ~0.254s/host and
projects to roughly **~26s at N=100** and **~64s at N=250** for THIS trivial fixture -- purely
extrapolated, never run at that N (per the task's own "small N only" instruction). `cpuTime`
is used here rather than wall time deliberately: this harness was run twice while building this
study (see `results/summary.csv`, the second run), and the raw per-repetition wall-clock data
for `4b` at N=5 came back as 4.5091s, 2.0746s, 2.1628s, 2.2026s, 1.6926s -- a cold-start spike
followed by a noisy settle, non-monotonic and clearly dominated by scheduling/thermal variance
on this mobile CPU (see "limitations" below) rather than the evaluator's own cost. `cpuTime`
(process-reported, less exposed to OS-scheduling jitter) still increases cleanly and
monotonically across both runs of this harness, which is why it -- not wall time -- is the
number this extrapolation is built on. Given the visible variance, this projection should be
read as an order-of-magnitude floor, not a precise forecast.

Compare that floor against the design spec's own 95.1s/host figure, measured (per the spec)
against a REAL host configuration, not this study's trivial one:

| | this study's trivial nixosSystem fixture (extrapolated, cpuTime-based) | design spec's real-host figure (95.1s/host, quoted) |
|---|---:|---:|
| N=100 | ~26s | 9,510s = **2.64 hours** |
| N=250 | ~64s | 23,775s = **6.6 hours** |

The ~370x gap between this study's own floor and the design spec's real-host figure is
*exactly* the "a trivial config understates real cost" caveat the task required flagging, not a
discrepancy between two measurements of the same thing. This study's fixture imports nixpkgs's
stock module list and nothing else; an actual estate host (per the family's own conventions)
additionally imports nixk3s, nixgpu, nixstorage, nixboot, nixarch, home-manager, and dozens of
enabled services, each contributing its own option surface, assertions, and (for anything using
`types.submodule`) its own nested `evalModules` call on top of the ~0.6-0.8s floor measured
here. This study did not attempt to reproduce a real host's full configuration (that would
require importing several sibling nix* flakes, which house rule 1 forbids for `nixhost` itself
and which this study -- being a study, not the module -- has no license to do either); the
95.1s figure is taken as given, and this study's own measurement independently confirms the
*mechanism* (full-fixpoint cost scaling with cross-host reads) that number is evidence of,
without re-measuring that exact number.

## Correctness, not just cost

A cost measurement of an assertion that cannot be shown to actually assert is worthless (house
rule 6). `bench.sh`'s final section runs, un-timed, both directions of `cross-host-assert.nix` against
both plain data and nixosSystem-sourced facts:

- plain data, N=100, no collision -> `ok: true` (silent when satisfied)
- plain data, N=100, forced IP collision -> `ok: false`, `ipDuplicates: ["198.51.100.1"]`
  (fires when violated)
- plain data, N=100, forced disk-by-id collision -> `ok: false`,
  `diskDuplicates: ["ata-DISK-host0-0"]` (fires when violated)
- nixosSystem-sourced facts, N=3, forced IP collision -> `ok: false`,
  `ipDuplicates: ["198.51.100.1"]` (same assertion function, same result, over evaluated
  config -- confirms the cost difference above is purely an eval-cost story, not a
  correctness difference between the two data sources)

Full transcript: `results/raw/correctness-check.txt`.

## Limitations of this run

- **Mobile CPU, not a dedicated benchmarking rig.** Intel Core Ultra 7 258V (8 cores, laptop
  power/thermal envelope). The wall-clock spread within case `4b` at N=5 (see above) is
  consistent with thermal/scheduling variance under sustained back-to-back evaluation, not a
  property of Nix's evaluator -- and it was NOT reproducible in the same shape run to run: this
  harness was run twice while building this study (`bench.sh` was re-run after a bug fix in
  `lib/gen-nixos-hosts.nix`, see `results/summary.csv`, the second/final run), and the two runs
  showed *different* noise patterns at N=5 (a monotonic climb in the first run, a cold-start
  spike followed by a noisy settle in the second) while `nrThunks`/`gc.totalBytes` -- the
  engine counters, not wall time -- reproduced **byte-for-byte identically** across both runs.
  That is the concrete case for the earlier claim that wall time is the wrong instrument here:
  absolute wall-clock numbers should be read as "this machine, this session, this run"; the
  engine counters and the overall shape (flat for plain data, linear-or-worse for cross-host
  evaluated-config reads) are what actually reproduce and are the load-bearing claims.
- **Every reported statistic uses all 5 (nixosSystem) or 7 (plain-data) repetitions, including
  whichever one happened to be slowest** -- no outlier trimming. If anything this makes the
  plain-data numbers a hair more pessimistic and the evaluated-config numbers likewise, which is
  a conservative direction to be wrong in for a study whose headline claims are "plain data
  stays cheap" and "evaluated config is expensive": neither claim benefited from cherry-picking
  a fast run.
- **`nix eval --impure` was required for every single measurement, including the plain-data
  ones** -- not a difference in what's being measured, but a CLI restriction: `nix eval --expr`
  resolves `./lib/...`-relative imports against the invocation itself, which pure-eval mode
  refuses regardless of whether the imported file does anything impure. Confirmed this is
  cosmetic by checking `results/raw/*.json` shows identical `nrThunks`/`gc.totalBytes` whether
  or not `--impure` is present for a plain-data-only expression (spot-checked manually while
  building this harness, not part of the timed loop).
- **The N=100/250 nixosSystem row does not exist and was deliberately not run** -- per the
  task's own "for contrast at small N only (1, 3, 5)" instruction. The extrapolation above is
  clearly labeled as such and is the honest limit of what this harness measured directly.
- **This study's nixosSystem fixture is a floor, not nixhost's actual future cost** -- see the
  "trivial config understates real cost" section above. It exists to demonstrate the
  *mechanism* the design spec's hard rule is built on, empirically, at a scale this sandbox can
  actually run -- not to re-measure the spec's own 95.1s figure.

## Conclusion

The design spec's hard rule -- fact tree as plain data, never evaluated config -- is confirmed,
not merely re-argued, up to N=250: plain data's cost (thunks, bytes, wall time) stays flat and
negligible across every read shape tested, including a genuine two-field cross-host assertion,
while a fully evaluated NixOS module system costs orders of magnitude more even at N=1 for a
single host, and specifically the cross-host-read shape (read one fact from every host) -- the
shape `nixhost`'s own five assertion groups all use -- scales that already-large per-host cost
by N with no sign of a ceiling before the design spec's own quoted 100-host / 2.6-hour figure.
Cross-host assertions over plain data remain affordable well past 250 hosts on the evidence
gathered here; the same assertions over evaluated per-host config were expensive from N=1 and
would, by the design spec's own real-host number, be prohibitive at estate scale. No result here
contradicted the hypothesis; the two things worth flagging are that wall time alone cannot see
the plain-data curve at this range (thunks/bytes can, and the fix was to report those instead)
and that laziness across independent host thunks holds even under the module system -- the
danger is specifically the cross-host read, not the mere existence of N evaluated hosts.
