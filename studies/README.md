# studies

Written-up findings: things that were tried in [`../experiments/`](../experiments/README.md),
worked (or failed instructively), and are worth recording properly -- with the reasoning, not
just the result.

A study earns its place here once it changed a decision in the main project. Nothing has
closed yet. `nix flake check` proves `modules/nixhost.nix`'s option surface and its five
assertion groups behave as documented against small, hand-written fixtures -- including both
directions of every assertion (fires when violated, silent when satisfied) required by this
repo's own house rule that a test which cannot fail is worthless. It does not prove any of
`../experiments/README.md`'s open questions: whether `darwinModules.nixhost` actually composes
into a real nix-darwin configuration, whether a per-environment VRAM claim would add anything
nixgpu's live pressure-watcher doesn't already do better, whether `resources.storage.disks`
genuinely mirrors a real `nixstorage.disks` table rather than only its empty fallback, whether
the cross-host graph the README pitches actually resolves across two real hosts, or whether the
module holds up at a host running more than a couple of environments at once.

Nothing invented below -- this is a list of what would be worth writing up if one of those
experiments closes, not a result:

- **`darwinModules.nixhost` proven against a real nix-darwin eval** (experiment 001) -- once a
  `nix-darwin` input and a composed `darwinConfiguration` exist in `checks/`, the finding
  (parity confirmed, or a genuine incompatibility found and fixed) belongs here.
- **Whether a per-environment VRAM claim is worth adding** (experiment 002) -- the answer only
  means something once this module's `resources.gpu` has been compared against nixgpu's real,
  live VRAM-pressure behavior during an actual contention event.
- **`resources.storage.disks` proven against a real `nixstorage.disks` table** (experiment 003)
  -- actual composed evaluation, not just the defensive-empty fallback this repo's own checks
  currently prove.
- **The cross-host graph resolved across two real hosts** (experiment 004) -- whether reading
  one host's `nixhost` data from a second host's own evaluation is as transport-transparent in
  practice as the README's pitch claims.
- **Eval-time and message legibility at real multi-environment scale** (experiment 005) --
  actual timing and a look at the rendered assertion messages at ten-plus environments, not an
  assumption that a handful of attrset folds "should" stay fast and legible.

None of these have been run. Until one is, this directory stays empty of findings by design --
see `../experiments/README.md` for the reasoning behind each open question in the meantime.
