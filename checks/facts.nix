# checks/facts.nix
#
# `lib/facts.nix` proven in both directions, at the FUNCTION level -- no NixOS eval, no VM, because
# `probeFact` touches nothing module-system-specific: it reads `?` and plain attribute access off
# whatever attrset it is handed, so a plain Nix record stands in for a real `config` here exactly
# as faithfully as it would in production. `checks/facts-integration.nix` is the companion that
# proves the same three states against a REAL NixOS module eval (a genuine mandatory-unset option,
# a genuine rename, a genuine unrelated build failure) -- kept separate because that one DOES need
# `eval-config.nix`, and the point of this file is that most of the proof does not.
#
# Per this repo's own house rule: an assertion test that cannot fail is worthless. Every state
# below gets a near-miss or a decoy that would trip a plausible-but-wrong implementation, proven
# by literally including that wrong implementation and showing it actually gets fooled.
{ lib, probeFact, collectProbes }:

let
  check = name: ok: detail: { inherit name ok detail; };

  # A convenience over `probeFact` fixing the field names used repeatedly below.
  probe = config: namespace: path: fallback: mode:
    probeFact { inherit config namespace path fallback mode; };

  probeDefault = config: namespace: path: fallback:
    probeFact { inherit config namespace path fallback; };

  # ══ State (a): the namespace was never composed at all ═══════════════════════════════════════

  # `nixexplosive` is not a key ANYWHERE in this attrset -- not even nested under something that
  # merely LOOKS unrelated. If `probeFact` ever forced anything about it before checking `?`, the
  # only way to notice from here would be if that forcing itself threw; it structurally can't
  # (there is nothing to force), which is exactly the point: answering (a) costs nothing to ask.
  hostWithNoDomains = { unrelated = "some other fact entirely"; };

  absentResult = probeDefault hostWithNoDomains "nixexplosive" [ "leaf" ] "safe-fallback";

  # THE FIXPOINT-AVOIDANCE PROOF (requirement 4). A namespace that genuinely exists as a key, but
  # whose own value THROWS the instant anything forces it to WHNF -- standing in for "a sibling
  # module composed on this host, expensive or broken in some way this probe has no business
  # touching". Probing a namespace that is composed but never asking IT is fine; the tripwire here
  # is a DIFFERENT namespace this host also happens to carry, so this fixture proves probing one
  # namespace never so much as glances at another.
  hostWithATripwireAndAnAbsentNamespace = {
    nixtripwire = throw "lib.probeFact forced a namespace nobody asked it to probe";
  };

  tripwireIgnoredResult =
    probeDefault hostWithATripwireAndAnAbsentNamespace "nixexplosive" [ "leaf" ] "safe-fallback";

  # ══ State (b): composed, and the leaf genuinely resolves ═════════════════════════════════════

  hostWithAPlainFact = { nixcpu = { cores = 16; arch = "x86_64"; }; };

  plainResolvedResult = probeDefault hostWithAPlainFact "nixcpu" [ "cores" ] null;

  hostWithAnAttrsetFact = {
    nixgpu = { devices = { gpu0 = { vendor = "amd"; vramMiB = 16384; }; }; };
  };

  # Requirement 5: an attrset leaf, not just a scalar.
  attrsetResolvedResult = probeDefault hostWithAnAttrsetFact "nixgpu" [ "devices" ] { };

  # THE NEAR-MISS THAT MATTERS MOST FOR THIS STATE: a namespace composed, a leaf that resolves
  # CLEANLY, and the resolved value happens to be IDENTICAL to what `fallback` would have been.
  # A value-based implementation ("is the result equal to the fallback? then call it unresolved")
  # would misreport this as state (c) -- this is the fixture that catches exactly that bug, and
  # it is real: nixgpu's own device table and its own opaque-mirror fallback are BOTH `{ }` for an
  # ordinary host with no cards plugged in.
  hostWhereRealValueCoincidesWithFallback = { nixgpu = { devices = { }; }; };

  coincidingResult =
    probeDefault hostWhereRealValueCoincidesWithFallback "nixgpu" [ "devices" ] { };

  # ══ State (c): composed, but the leaf does not resolve ═══════════════════════════════════════

  # Sub-case 1 -- RENAMED. `nixcpu` is composed (it states `coreCount`), but `cores` -- the path
  # this call still asks for -- is gone. This is the exact shape a silent rename produces, and the
  # one a bare `x.y or fallback` cannot tell apart from state (a) at all (see the decoy below).
  hostWithARenamedLeaf = { nixcpu = { coreCount = 16; }; };

  renamedResult = probeDefault hostWithARenamedLeaf "nixcpu" [ "cores" ] null;

  # Sub-case 2 -- MANDATORY, NEVER SET. `cores` exists as a key (the option was declared) but its
  # value is exactly the throw the NixOS module system itself produces for a required option with
  # no definition -- reproduced verbatim here so this fixture needs no real module eval to prove
  # the same code path handles it.
  hostWithAMandatoryUnsetLeaf = {
    nixcpu = {
      cores = throw "The option `nixcpu.cores' is used but not defined.";
      arch = "x86_64";
    };
  };

  mandatoryUnsetResult = probeDefault hostWithAMandatoryUnsetLeaf "nixcpu" [ "cores" ] null;

  # Sub-case 3 -- an ATTRSET leaf, renamed. Requirement 5 again, this time on the unresolved path:
  # `nixgpu` is composed (`inventory` exists) but this call still asks for the old name, `devices`.
  hostWithARenamedAttrsetLeaf = { nixgpu = { inventory = { gpu0 = { }; }; }; };

  renamedAttrsetResult = probeDefault hostWithARenamedAttrsetLeaf "nixgpu" [ "devices" ] { };

  # Nested path, two levels deep, renamed at the DEEPER segment -- proves the rename detection
  # does not only work at the first level under the namespace.
  hostWithANestedRename = { nixram = { hardware = { installedMiB = 65536; }; }; };

  nestedRenameResult =
    probeDefault hostWithANestedRename "nixram" [ "hardware" "totalMiB" ] null;

  # ── THE META-TEST: a plausible-but-wrong implementation, shown to actually get fooled ─────────
  #
  # This is the "shown capable of failing" proof state (c) needs: not an assertion that the RIGHT
  # implementation works, but a DIFFERENT, real implementation of the same idiom -- the one every
  # sibling repo in this family already writes by hand -- that this file proves is blind to
  # exactly the case above.
  naiveDefensiveRead = config: namespace: path: fallback:
    let
      leaf = lib.foldl' (acc: seg: (acc.${seg} or fallback)) (config.${namespace} or { }) path;
    in
    builtins.tryEval leaf;

  naiveOnRenamedLeaf = naiveDefensiveRead hostWithARenamedLeaf "nixcpu" [ "cores" ] null;

  # ══ Mode: warn (default) vs. assert (opt-in) ══════════════════════════════════════════════════

  warnModeResult = probe hostWithARenamedLeaf "nixcpu" [ "cores" ] null "warn";
  assertModeResult = probe hostWithARenamedLeaf "nixcpu" [ "cores" ] null "assert";

  # Silence in BOTH modes for states (a) and (b) -- opting into "assert" must never turn a
  # legitimate absence or a genuinely empty fact into a build failure.
  absentAssertMode = probe hostWithNoDomains "nixexplosive" [ "leaf" ] "safe-fallback" "assert";
  resolvedAssertMode = probe hostWithAPlainFact "nixcpu" [ "cores" ] null "assert";

  # ══ collectProbes: the fold a caller mirroring several facts actually uses ══════════════════

  manyProbes = [
    (probeDefault hostWithAPlainFact "nixcpu" [ "cores" ] null) # resolved -- contributes nothing
    (probeDefault hostWithNoDomains "nixexplosive" [ "leaf" ] null) # absent -- contributes nothing
    (probe hostWithARenamedLeaf "nixcpu" [ "cores" ] null "warn") # unresolved, warn
    (probe hostWithARenamedAttrsetLeaf "nixgpu" [ "devices" ] { } "assert") # unresolved, assert
  ];
  collected = collectProbes manyProbes;

  # ══ Results ════════════════════════════════════════════════════════════════════════════════

  results = [
    # ── State (a) ──────────────────────────────────────────────────────────────────────────────
    (check "facts/absent-namespace-reports-absent"
      (absentResult.state == "absent")
      "a namespace not present in config at all must report state \"absent\"; got ${absentResult.state}")

    (check "facts/absent-namespace-uses-the-fallback-value"
      (absentResult.value == "safe-fallback")
      "an absent namespace must hand back the caller's own fallback verbatim; got ${builtins.toJSON absentResult.value}")

    (check "facts/absent-namespace-is-silent-in-warn-mode"
      (absentResult.warnings == [ ] && absentResult.assertions == [ ])
      "state (a) must never produce a warning or an assertion in warn mode: ${builtins.toJSON absentResult}")

    (check "facts/absent-namespace-stays-silent-even-in-assert-mode"
      (absentAssertMode.warnings == [ ] && absentAssertMode.assertions == [ ])
      "opting into assert mode must not turn a legitimate absence into a build failure: ${builtins.toJSON absentAssertMode}")

    (check "facts/probing-an-absent-namespace-never-forces-an-unrelated-tripwire"
      (tripwireIgnoredResult.state == "absent" && tripwireIgnoredResult.value == "safe-fallback")
      "a host carrying a DIFFERENT, deliberately-throwing namespace must not affect probing an absent one -- if this failed, something forced more of the host than the namespace actually being asked about")

    # ── State (b) ──────────────────────────────────────────────────────────────────────────────
    (check "facts/composed-plain-value-resolves-silently"
      (plainResolvedResult.state == "resolved"
        && plainResolvedResult.value == 16
        && plainResolvedResult.warnings == [ ]
        && plainResolvedResult.assertions == [ ])
      "a composed namespace with a genuinely present scalar leaf must resolve silently; got ${builtins.toJSON plainResolvedResult}")

    (check "facts/composed-attrset-value-resolves-silently"
      (attrsetResolvedResult.state == "resolved"
        && attrsetResolvedResult.value == { gpu0 = { vendor = "amd"; vramMiB = 16384; }; }
        && attrsetResolvedResult.warnings == [ ])
      "requirement 5: an attrset leaf must resolve exactly like a scalar one; got ${builtins.toJSON attrsetResolvedResult}")

    (check "facts/resolved-value-equal-to-fallback-is-still-silent"
      (coincidingResult.state == "resolved" && coincidingResult.warnings == [ ])
      "a genuinely resolved fact that happens to equal the fallback must still report \"resolved\", never \"unresolved\" -- a value-based implementation would get this wrong: ${builtins.toJSON coincidingResult}")

    # ── State (c): renamed leaf ────────────────────────────────────────────────────────────────
    (check "facts/renamed-leaf-reports-unresolved"
      (renamedResult.state == "unresolved")
      "a namespace composed with the OLD leaf name gone must report \"unresolved\", not silently fall back as though absent; got ${renamedResult.state}")

    (check "facts/renamed-leaf-uses-the-fallback-value"
      (renamedResult.value == null)
      "an unresolved leaf must still hand back the caller's fallback as its value")

    (check "facts/renamed-leaf-warns-by-default"
      (lib.length renamedResult.warnings == 1 && renamedResult.assertions == [ ])
      "state (c) must warn, not assert, unless the caller opts in: ${builtins.toJSON renamedResult}")

    (check "facts/renamed-leaf-warning-names-the-option-path"
      (lib.hasInfix "nixcpu.cores" (lib.head renamedResult.warnings))
      "the warning must name the exact option path that failed to resolve: ${lib.head renamedResult.warnings}")

    (check "facts/renamed-leaf-warning-names-the-namespace"
      (lib.hasInfix "nixcpu" (lib.head renamedResult.warnings)
        && lib.hasInfix "composed" (lib.head renamedResult.warnings))
      "the warning must say WHICH namespace is composed, not only the dotted path: ${lib.head renamedResult.warnings}")

    (check "facts/renamed-leaf-warning-names-the-fallback-in-use"
      (lib.hasInfix "null" (lib.head renamedResult.warnings)
        && lib.hasInfix "Falling back" (lib.head renamedResult.warnings))
      "the warning must say what this host is ACTUALLY running -- the fallback value -- not merely that something is wrong: ${lib.head renamedResult.warnings}")

    # ── State (c): the meta-test, proving this is a real failure mode ─────────────────────────
    (check "facts/naive-or-based-read-is-fooled-by-the-same-rename (meta-test)"
      (naiveOnRenamedLeaf.success && naiveOnRenamedLeaf.value == null)
      "the naive `x.y or fallback` idiom every sibling repo already writes by hand must succeed SILENTLY on a renamed leaf -- proving state (c) is a real, currently-unguarded failure mode, not a hypothetical one: got ${builtins.toJSON naiveOnRenamedLeaf}")

    # ── State (c): mandatory-unset leaf (trap 2) ──────────────────────────────────────────────
    (check "facts/mandatory-unset-leaf-reports-unresolved"
      (mandatoryUnsetResult.state == "unresolved")
      "a leaf that exists structurally but throws \"used but not defined\" the moment it is forced must report \"unresolved\", the same as a rename -- got ${mandatoryUnsetResult.state}")

    (check "facts/mandatory-unset-leaf-warns-by-default"
      (lib.length mandatoryUnsetResult.warnings == 1)
      "trap 2 from this file's own header: `or null` alone does not catch this throw -- proving the fix actually does")

    # ── State (c): attrset leaf, renamed and nested (requirement 5, unresolved path) ──────────
    (check "facts/renamed-attrset-leaf-reports-unresolved"
      (renamedAttrsetResult.state == "unresolved" && renamedAttrsetResult.value == { })
      "requirement 5 on the unresolved path: an attrset leaf that moved must be caught exactly like a scalar one; got ${builtins.toJSON renamedAttrsetResult}")

    (check "facts/nested-rename-two-levels-deep-is-caught"
      (nestedRenameResult.state == "unresolved")
      "a rename at the SECOND segment of a multi-level path (nixram.hardware.totalMiB -> nixram.hardware.installedMiB) must still be caught, not just a rename of the namespace's immediate child")

    # ── Mode: warn vs. assert ──────────────────────────────────────────────────────────────────
    (check "facts/default-mode-is-warn"
      (warnModeResult.state == "unresolved"
        && lib.length warnModeResult.warnings == 1
        && warnModeResult.assertions == [ ])
      "omitting `mode` entirely must behave exactly like mode = \"warn\"")

    (check "facts/assert-mode-produces-an-assertion-not-a-warning"
      (assertModeResult.state == "unresolved"
        && assertModeResult.warnings == [ ]
        && lib.length assertModeResult.assertions == 1
        && (lib.head assertModeResult.assertions).assertion == false)
      "mode = \"assert\" must move the report into `assertions`, shaped for direct use in config.assertions, and produce nothing in `warnings`: ${builtins.toJSON assertModeResult}")

    (check "facts/assert-mode-assertion-carries-the-same-message"
      (lib.hasInfix "nixcpu.cores" (lib.head assertModeResult.assertions).message)
      "the assertion record's own message must be just as specific as the warning's")

    (check "facts/resolved-fact-is-silent-even-in-assert-mode"
      (resolvedAssertMode.assertions == [ ] && resolvedAssertMode.warnings == [ ])
      "mode = \"assert\" must not turn a genuinely resolved fact into a failure -- only an unresolved one")

    # ── collectProbes ──────────────────────────────────────────────────────────────────────────
    (check "facts/collect-probes-folds-warnings-and-assertions-separately"
      (lib.length collected.warnings == 1
        && lib.length collected.assertions == 1
        && (lib.head collected.assertions).assertion == false)
      "collectProbes over a mix of resolved/absent/warn/assert probes must produce exactly one warning and one assertion, from the two probes that actually reported unresolved: ${builtins.toJSON collected}")

    (check "facts/collect-probes-ignores-resolved-and-absent-probes"
      (lib.hasInfix "nixcpu.cores" (lib.head collected.warnings)
        && lib.hasInfix "nixgpu.devices" (lib.head collected.assertions).message
        && !(lib.hasInfix "nixexplosive" (lib.head collected.warnings)))
      "the one warning and one assertion collected must trace back to the two UNRESOLVED probes specifically (nixcpu.cores, nixgpu.devices), not to the resolved or absent ones mixed in beside them: ${builtins.toJSON collected}")

    # ── Call-site contract: an invalid mode is a caller bug, not silence ──────────────────────
    (check "facts/invalid-mode-throws-rather-than-silently-doing-nothing"
      (!(builtins.tryEval (builtins.seq (probe hostWithARenamedLeaf "nixcpu" [ "cores" ] null "loudly").state true)).success)
      "an unrecognised `mode` must fail loudly at the call site -- silently producing neither a warning nor an assertion would be this exact defect class one layer up, in this file's own caller contract")
  ];
in
results
