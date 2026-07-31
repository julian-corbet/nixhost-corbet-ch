# lib/facts.nix -- `lib.probeFact`
#
# THE DEFECT CLASS, named precisely: a defensive cross-namespace read of the shape
# `config.nixfoo.bar or fallback` -- the idiom this whole family uses -- conflates THREE states
# that are not one state:
#
#   (a) the sibling module (`nixfoo`) is not composed on this host at all   -- legitimate, silent
#   (b) it IS composed, and the fact is genuinely absent/empty              -- legitimate, silent
#   (c) it IS composed, but the specific LEAF moved, was renamed, or its
#       value was rejected by its own type, so the read silently falls back -- a DEFECT
#
# A bare `or` cannot tell (c) from (a)/(b), because all three routes end at the identical
# fallback value with no trace of which one was taken. That is not a corner case: this exact
# shape cost real weeks of dead features when `nixstorage.layout` moved underneath a defensive
# reader elsewhere in this family, nearly repeated itself on the `nixid` -> `nixiam` rename, and
# was caught live in `nixllm` the same week this file was written. This module is the fix, built
# once so no repo in this family has to reinvent it.
#
# ── THE TWO TRAPS A NAIVE IMPLEMENTATION FALLS INTO, both measured, not theorised ─────────────
#
# TRAP 1 -- `builtins.tryEval (x.y or fallback)` is theatre when `fallback` is a benign value.
# `or` is resolved by the LANGUAGE before `tryEval` ever runs: if `y` is structurally absent, `or`
# already substitutes `fallback` -- successfully, with no throw anywhere -- so `tryEval`'s
# `success` comes back `true` whether the read found a real value or silently took the fallback.
# The two are indistinguishable from the outside no matter how tightly `tryEval` wraps them,
# because there was never anything for it to catch.
#
# THE FIX: give `or` a FALLBACK THAT THROWS instead of a value, and force the result *inside*
# `tryEval`. Now a structurally-absent leaf produces a genuine throw (the `or`'s own fallback
# firing), and `tryEval` has something real to catch. `attemptLeaf` below is exactly
# `namespaceValue.path or (throw ...)`, generalised over an arbitrary-depth `path` via
# `lib.attrByPath` so a rename two levels inside a mirrored table is caught the same way a
# top-level rename is.
#
# TRAP 2 -- `x.y or null` does not protect a MANDATORY option with no upstream default (`nixcpu.
# cores`, `nixcpu.arch` in this family): the module system counts the option's own declaration as
# already having an attribute at that path, definition or not, so `or` finds `y` PRESENT and never
# reaches its fallback at all. Forcing it then throws "the option `...' is used but not defined",
# uncaught, straight out of the option's own default.
#
# THE FIX is the same one: because `attemptLeaf` wraps the ENTIRE expression -- including a leaf
# that exists structurally but throws the moment something forces it -- in `tryEval`, this throw
# is caught too. Trap 1's fix and trap 2's fix are the same line of code; neither the "leaf is not
# there" throw nor the "leaf is there but mandatory-unset" throw need a different code path.
#
# ── WHY THE NAMESPACE IS PROBED SEPARATELY FROM THE LEAF -- and why that answers (a) for free ──
#
# `config ? nixfoo` is a STRUCTURAL test: does the merged config attrset have a key named
# `nixfoo`. It is answerable from the option system's own DECLARATIONS -- a cost every host
# imports already pays just by composing the sibling module at all -- and it forces nothing about
# what `nixfoo` itself contains. So state (a) is decided before `attemptLeaf` is even built (see
# the `if composed then ... else null` below): a namespace nobody imported here is never opened,
# which is what keeps this a cheap fact-read rather than a system eval (`checks/facts.nix` proves
# this with a namespace whose own value would throw if it were ever forced, composed alongside an
# UNRELATED module whose own assertion fails -- proving the absent-state answer needs neither).
#
# Once `composed` is true, EVERY remaining case collapses to one question: did `attemptLeaf`
# succeed? A "yes" is state (b), silent, whatever the value actually is -- including a value that
# happens to equal `fallback` by coincidence, which is exactly the near-miss this file's own tests
# prove does NOT get misreported as (c) (see `checks/facts.nix`'s
# `resolvedValueEqualsFallbackIsStillSilent`). A "no" is state (c), and ONLY state (c) ever
# produces a warning or assertion.
#
# ── WARN BY DEFAULT, ASSERT ON REQUEST ────────────────────────────────────────────────────────
#
# An assertion firing on every host that has not yet adopted a sibling module would make the
# option unadoptable, so a caller pays for that loudness only when it explicitly asks
# (`mode = "assert"`) for a read it considers load-bearing. `mode = "warn"` is therefore the
# default, rendering into `config.warnings` (non-fatal, shown at build time) -- never
# `config.assertions` -- unless the caller opts in.
{ lib }:

let
  # `lib.attrByPath` never forces the value it eventually returns -- it only forces enough of each
  # INTERMEDIATE attrset to test `? nextSegment` as it walks deeper, which is unavoidable (you
  # cannot ask an attrset for its keys without evaluating it to WHNF) and is exactly the cost of
  # reading a fact that genuinely IS there. The `throw` is the `default` argument: if any segment
  # of `path` is missing, this is what comes back, UNFORCED -- so it is `builtins.tryEval` below
  # that actually triggers and catches it, never the `attrByPath` call itself.
  attemptLeaf = path: namespaceValue:
    builtins.tryEval
      (lib.attrByPath path (throw "lib.probeFact: leaf did not resolve") namespaceValue);

  normalisePath = path: if builtins.isList path then path else lib.splitString "." path;

  # `namespace` accepts a PATH, not only a single top-level name, and the difference is not
  # cosmetic -- it decides state (a) correctly on a host that composes only part of a sibling repo.
  #
  # Sibling projects ship several independently-composable modules under ONE namespace: a host can
  # import an identity repo's `lldap` and `pocket-id` modules and not its `posix` module. A reader
  # of `nixiam.posix.identities` on such a host asks `config ? nixiam` -- true, because lldap
  # declared it -- concludes the sibling IS composed, finds the leaf missing, and reports state (c),
  # "the option moved or was renamed". Nothing moved. `nixiam.posix` was never composed.
  #
  # That was live: it fired twice on a production mail host, and its message sent a reader hunting
  # for a rename that does not exist. Naming the OWNER subtree -- `[ "nixiam" "posix" ]` -- puts the
  # composed-test where the module boundary actually is. A single-segment namespace is just the
  # one-element case, so every existing call site keeps its exact meaning.
  normaliseOwner = ns: if builtins.isList ns then ns else lib.splitString "." ns;
in
rec {
  # { config, namespace, path, fallback, mode ? "warn" }:
  #
  #   config     -- the attrset to read from (a real NixOS/system-manager/nix-darwin `config`, or
  #                 plain data in a test -- this function touches nothing module-system-specific,
  #                 only `?` and ordinary attribute access, so either works identically).
  #   namespace  -- the OWNER. ⚠ ONLY ITS FIRST SEGMENT IS THE PRESENCE TEST. A dotted or list
  #                 spelling (`"nixiam.posix"`, `[ "nixstorage" "delivery" ]`) is accepted for
  #                 readability, but every segment past the first is folded into `path` before use,
  #                 and the composed-test is `config ? <first segment>` and nothing deeper. See the
  #                 implementation comment at the split, which explains why: the presence question
  #                 is "is the sibling REPO composed", and only a top-level attribute can answer it
  #                 without collapsing back into the very defect this file exists to remove.
  #
  #                 THIS PARAGRAPH USED TO SAY THE OPPOSITE -- "put the boundary at the MODULE, not
  #                 at the repo" -- and it was stale from the moment the presence test moved
  #                 (nixhost 60827e9). It is corrected rather than deleted because the wrong version
  #                 was load-bearing: two consumer repos independently built workarounds for what
  #                 they reasonably diagnosed as a probeFact bug, when the behaviour was deliberate
  #                 and only the documentation was lying.
  #
  #                 THE CONSEQUENCE A CALLER MUST PLAN FOR: a PARTIALLY-composed namespace makes
  #                 every un-composed leaf under it report `unresolved`, not `absent` -- because the
  #                 first segment exists, so the sibling counts as composed. Probing
  #                 `nixdesktop.layouts` on a host that composes only `nixdesktop.startup` warns
  #                 "layouts did not resolve, even though nixdesktop IS composed", which is true and
  #                 useless. That is not a bug to route around: it is the price of never going
  #                 silent on a rename, which is the failure that cost this estate weeks.
  #
  #                 SO: probe only what you actually consume, and gate the resulting warning behind
  #                 the option that consumes it. A probe whose value nothing reads should not exist;
  #                 a probe whose value is read only when an option is set should warn only then.
  #                 An always-on warning for an optional seam trains operators to ignore warnings,
  #                 which costs more than the seam is worth.
  #
  #                 IRREDUCIBLE LIMIT, stated rather than hidden: renaming the owner's own FIRST
  #                 segment (`nixiam` -> something else) is indistinguishable from "that repo was
  #                 never composed here" -- both leave nothing at the top level, and this function
  #                 reports `absent`, i.e. silence. Nothing in a `config` can tell those apart. The
  #                 backstop is the consuming repo's own checks, which compose the real producer and
  #                 carry a rename decoy.
  #   path       -- the leaf's path INSIDE that namespace, as a list (`[ "cores" ]`) or a
  #                 dot-separated string (`"hardware.totalMiB"`) -- both spellings normalise to
  #                 the same list before use, so a caller uses whichever reads better at its own
  #                 call site.
  #   fallback   -- the value substituted for states (a) and (c). Never inspected to help decide
  #                 which state occurred (see this file's header on why a value-based test is
  #                 unsound the moment a leaf can legitimately resolve to the same value used as
  #                 the fallback).
  #   mode       -- "warn" (default) -- an unresolved leaf becomes one string in the returned
  #                 `warnings`, meant to be spliced into the caller's own `config.warnings`.
  #              -- "assert" -- an unresolved leaf becomes one `{ assertion = false; message; }`
  #                 record in the returned `assertions`, meant to be spliced into the caller's own
  #                 `config.assertions`, for a read the caller considers load-bearing enough to
  #                 fail the build over. Absence (state a) and genuine emptiness (state b) never
  #                 produce a warning OR an assertion, in either mode.
  #
  # Returns `{ state; value; optionPath; warnings; assertions; }`. `state` is one of
  # `"absent"` / `"resolved"` / `"unresolved"` -- the three-way answer this whole file exists to
  # make available, for a caller that wants to report or count them rather than only render a
  # message.
  probeFact =
    { config
    , namespace
    , path
    , fallback
    , mode ? "warn"
    }:
    assert lib.assertMsg (mode == "warn" || mode == "assert")
      "lib.probeFact: mode must be \"warn\" or \"assert\", got ${builtins.toJSON mode} -- a third, silently-ignored mode would be this same defect class one layer up.";
    let
      # The namespace is the TOP-LEVEL attribute and nothing deeper. A dotted `namespace` is
      # accepted for convenience, but every segment past the first is folded into the path here,
      # because "is the sibling composed" is a question only the top-level attr can answer.
      #
      # This split is load-bearing, and getting it wrong reintroduces the exact defect this file
      # exists to remove. A caller passing `namespace = "nixstorage.disks"; path = [ ]` makes the
      # presence test ask whether `disks` exists -- so the moment nixstorage renames it, the test
      # says "not composed", the probe reports state (a), and it goes SILENT. That is the
      # conflation the whole design removes, rebuilt inside the thing removing it. Four repos'
      # rename decoys caught it; without them it would have shipped as a guard that had quietly
      # stopped guarding.
      ownerRaw = normaliseOwner namespace;
      nsAttr = builtins.head ownerRaw;
      pathList = (builtins.tail ownerRaw) ++ normalisePath path;
      dotted = lib.concatStringsSep "." pathList;
      ownerDotted = nsAttr;
      optionPath = if pathList == [ ] then nsAttr else "${nsAttr}.${dotted}";

      # STATE (a), decided before anything under the namespace is opened -- see this file's header.
      # A single attribute test forces nothing, so an unadopted sibling costs no evaluation.
      composed = config ? ${nsAttr};

      # Lazy on the `if` itself, not merely inside `attemptLeaf`: when `composed` is false this
      # binding is never forced, so the namespace subtree is never touched at all.
      attempt = if composed then attemptLeaf pathList config.${nsAttr} else null;

      resolved = composed && attempt.success;

      state =
        if !composed then "absent"
        else if resolved then "resolved"
        else "unresolved";

      value = if resolved then attempt.value else fallback;

      # `toPretty` can itself choke on an exotic fallback (a function, say); a probe reporting an
      # unresolved fact must never itself become the thing that fails a build over a rendering
      # problem, so this degrades to a plain placeholder rather than propagating a throw.
      fallbackRendered =
        let attempt' = builtins.tryEval (lib.generators.toPretty { } fallback);
        in if attempt'.success then attempt'.value else "<a value this probe cannot render>";

      message = ''
        ${optionPath} did not resolve, even though the `${ownerDotted}` namespace IS composed on
        this host. One of three things is true: the option moved or was renamed somewhere inside
        `${ownerDotted}`, it was declared with no default and never given a value, or the value it
        was given was rejected by its own type -- evaluate `config.${optionPath}` directly to see
        which. Falling back to ${fallbackRendered} in the meantime: that is what this host is
        actually doing right now, not what its configuration appears to say.
      '';
    in
    {
      inherit state value optionPath;
      warnings = lib.optional (state == "unresolved" && mode == "warn") message;
      assertions = lib.optional (state == "unresolved" && mode == "assert") {
        assertion = false;
        inherit message;
      };
    };

  # A caller mirroring several facts at once -- nixhost's own dozen-odd level-1 mirrors, for
  # instance -- folds every probe's `warnings`/`assertions` into the one pair of lists
  # `config.warnings`/`config.assertions` already expect, rather than writing this fold at every
  # call site.
  collectProbes = probes: {
    warnings = lib.concatMap (p: p.warnings) probes;
    assertions = lib.concatMap (p: p.assertions) probes;
  };
}
