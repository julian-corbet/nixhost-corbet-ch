# lib/facts.nix -- `lib.probeFact`
#
# THE DEFECT CLASS, named precisely: a defensive cross-namespace read of the shape
# `config.nixfoo.bar or fallback` -- the idiom this whole family uses, `modules/nixhost.nix`'s own
# `mirrorOf` included -- conflates THREE states that are not one state:
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
# once so the other repos that each grew their own version of `mirrorOf` can read a fact through
# this instead.
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
# uncaught, straight out of the option's own default. `mirrorOf` in `modules/nixhost.nix` already
# discovered this the hard way (see that file's own header).
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
# An assertion that fires on every host that has not yet adopted a sibling module the way this
# repo's own ceiling checks do is exactly how `mirrorOf`'s design ended up collapsing (a) and (c)
# in the first place (see `modules/nixhost.nix`'s own header on MIRROR + ASSERT-RESOLVED): making
# the loud case the default makes the option unadoptable, so a caller pays for that loudness only
# when it explicitly asks (`mode = "assert"`) for a read it considers load-bearing. `mode = "warn"`
# is therefore the default, rendering into `config.warnings` (non-fatal, shown at build time) --
# never `config.assertions` -- unless the caller opts in.
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
in
rec {
  # { config, namespace, path, fallback, mode ? "warn" }:
  #
  #   config     -- the attrset to read from (a real NixOS/system-manager/nix-darwin `config`, or
  #                 plain data in a test -- this function touches nothing module-system-specific,
  #                 only `?` and ordinary attribute access, so either works identically).
  #   namespace  -- the SINGLE top-level attribute name whose presence means "the sibling module
  #                 is composed here", e.g. "nixcpu". Never a dotted path: state (a) is a question
  #                 about one sibling module, and `path` below is where the depth belongs.
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
      pathList = normalisePath path;
      dotted = lib.concatStringsSep "." pathList;
      optionPath = "${namespace}.${dotted}";

      # STATE (a), decided before anything about `nixfoo` is opened -- see this file's header.
      composed = config ? ${namespace};

      # Lazy on the `if` itself, not merely inside `attemptLeaf`: when `composed` is false this
      # binding is never forced, so `config.${namespace}` is never touched at all.
      attempt = if composed then attemptLeaf pathList config.${namespace} else null;

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
        ${optionPath} did not resolve, even though the `${namespace}` namespace IS composed on
        this host. One of three things is true: the option moved or was renamed somewhere inside
        `${namespace}`, it was declared with no default and never given a value, or the value it
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
