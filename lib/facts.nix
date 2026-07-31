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
  #   namespace  -- the OWNER: the attribute path whose presence means "the module that declares
  #                 this fact is composed here". A single name (`"nixcpu"`) where a repo ships one
  #                 module, or a path -- list or dotted string -- where it ships several under one
  #                 namespace (`"nixiam.posix"`, `[ "nixstorage" "delivery" ]`). Put the boundary
  #                 at the MODULE, not at the repo: a host can compose an identity repo's lldap
  #                 module and not its posix module, and probing the bare namespace then reports
  #                 "the fact was renamed" about a host that simply never imported it.
  #
  #                 KNOWN LIMIT, stated rather than hidden: a rename of the owner's own deepest
  #                 segment (`nixiam.posix` -> `nixiam.unix`) is indistinguishable from "posix was
  #                 never composed here" -- both leave nothing at that path. This function reports
  #                 absent, i.e. silence, because a partially-composed sibling is the common and
  #                 legitimate case while an owner rename is caught by the consuming repo's own
  #                 checks, which compose the real producer. Choose the owner accordingly: deeper
  #                 buys accuracy about (a) and gives up detection of a rename AT that depth.
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
      ownerList = normaliseOwner namespace;
      dotted = lib.concatStringsSep "." pathList;
      ownerDotted = lib.concatStringsSep "." ownerList;
      # An empty `path` is legitimate and means "the owner IS the fact" -- the shape a consumer needs
      # when the thing it reads is itself a whole module's single option (`nixstorage.disks`,
      # `nixdesktop.startup`). Without this branch the message renders a trailing dot.
      optionPath = if pathList == [ ] then ownerDotted else "${ownerDotted}.${dotted}";

      # STATE (a), decided before anything under the owner is opened -- see this file's header.
      #
      # Wrapped in tryEval for the same reason `attemptLeaf` is. A single-segment owner only ever
      # did `config ? ns`, which forces nothing. A MULTI-segment owner must force every segment
      # except the last to WHNF just to test for the next key -- so an intermediate namespace whose
      # value throws (a mandatory option left unset, a value its own type rejected) would take the
      # whole evaluation down from inside a probe whose entire purpose is to survive that and
      # report it. An owner that cannot even be tested for presence is treated as absent, which is
      # the same conservative answer this function gives everywhere else it cannot see.
      composedAttempt = builtins.tryEval (lib.hasAttrByPath ownerList config);
      composed = composedAttempt.success && composedAttempt.value;

      # Lazy on the `if` itself, not merely inside `attemptLeaf`: when `composed` is false this
      # binding is never forced, so the owner subtree is never touched at all.
      attempt =
        if composed then attemptLeaf pathList (lib.getAttrFromPath ownerList config) else null;

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
