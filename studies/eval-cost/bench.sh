#!/usr/bin/env bash
# Eval-cost harness for the nixhost design spec's own hard rule: "the namespace is DATA, never
# evaluated config" (../../nixhost-spec.md). Measures, with a real timer and NIX_SHOW_STATS
# eval-engine counters (not just wall time -- see README.md for why wall time alone would
# mislead), the four cases the study brief asks for:
#
#   1. plain-data tree: read ONE fact from ONE host, at N = 1, 10, 50, 100, 250
#   2. plain-data tree: read one fact from EVERY host (the cross-host-assertion shape)
#   3. plain-data tree: a genuine cross-host assertion (no shared IP, no shared disk by-id)
#   4. CONTRAST at small N only (1, 3, 5): the same two reads, but sourced from a genuinely
#      evaluated `lib.nixosSystem` per host instead of plain data
#
# Run: ./bench.sh   (from this directory; needs network on first run only, to fetch the pinned
# nixpkgs rev used by case 4 -- see lib/gen-nixos-hosts.nix's own header).
#
# Output: results/summary.csv (one row per case x N x repetition) and results/raw/*.json (the
# full NIX_SHOW_STATS dump for every single run, kept so a claim in README.md can be checked
# against the actual counters rather than taken on faith).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

REPS_PLAIN=7
REPS_NIXOS=5
NS_PLAIN=(1 10 50 100 250)
NS_NIXOS=(1 3 5)

RAW_DIR="results/raw"
CSV="results/summary.csv"
rm -rf "$RAW_DIR"
mkdir -p "$RAW_DIR"
echo "case,n,rep,wall_seconds,cpu_time_seconds,nr_thunks,nr_exprs,nr_function_calls,gc_total_bytes" > "$CSV"

# run_one <case_label> <n> <rep> <impure:yes|no> <nix-expr>
# Times one `nix eval` invocation with a real wall clock (date +%s.%N, process-external -- not
# nix's own --show-trace or shell $SECONDS, which only has 1s resolution) and captures the full
# NIX_SHOW_STATS engine-counter dump to its own file so per-run GC/thunk data survives.
run_one() {
  local case_label="$1" n="$2" rep="$3" impure="$4" expr="$5"
  local statsfile="${RAW_DIR}/${case_label}.n${n}.rep${rep}.json"
  # --impure is required for EVERY case here, not just case 4's builtins.getFlake: `nix eval
  # --expr` resolves the relative `./lib/...` import against the CLI invocation, which Nix's
  # pure-eval mode refuses regardless of whether the imported file itself does anything
  # impure. It is not a second, separate impurity on top of case 4's -- it is the same "the
  # shell isn't a flake" restriction in both branches. ($4 is accepted for readability at each
  # call site, not because the two branches differ here.)
  local impure_flag=(--impure)

  local t0 t1 wall
  t0=$(date +%s.%N)
  NIX_SHOW_STATS=1 NIX_SHOW_STATS_PATH="$statsfile" \
    nix eval "${impure_flag[@]}" --json --expr "$expr" > /dev/null
  t1=$(date +%s.%N)
  wall=$(awk -v a="$t0" -v b="$t1" 'BEGIN { printf "%.6f", b - a }')

  local cpu thunks exprs fcalls gcbytes
  cpu=$(jq -r '.cpuTime' "$statsfile")
  thunks=$(jq -r '.nrThunks' "$statsfile")
  exprs=$(jq -r '.nrExprs' "$statsfile")
  fcalls=$(jq -r '.nrFunctionCalls' "$statsfile")
  gcbytes=$(jq -r '.gc.totalBytes' "$statsfile")

  echo "${case_label},${n},${rep},${wall},${cpu},${thunks},${exprs},${fcalls},${gcbytes}" >> "$CSV"
}

echo "== plain-data cases (1/2/3), N in ${NS_PLAIN[*]}, ${REPS_PLAIN} reps each =="
for n in "${NS_PLAIN[@]}"; do
  expr1="(import ./lib/gen-plain-hosts.nix { n = ${n}; }).host0.ram.totalMiB"
  expr2="builtins.foldl' (a: h: a + h.ram.totalMiB) 0 (builtins.attrValues (import ./lib/gen-plain-hosts.nix { n = ${n}; }))"
  expr3="(import ./lib/cross-host-assert.nix { hosts = import ./lib/gen-plain-hosts.nix { n = ${n}; }; }).ok"

  for rep in $(seq 1 "$REPS_PLAIN"); do
    echo "  n=${n} rep=${rep}/${REPS_PLAIN}"
    run_one "1-plain-one-fact-one-host"   "$n" "$rep" no "$expr1"
    run_one "2-plain-one-fact-every-host" "$n" "$rep" no "$expr2"
    run_one "3-plain-cross-host-assert"        "$n" "$rep" no "$expr3"
  done
done

echo "== nixosSystem CONTRAST (case 4), N in ${NS_NIXOS[*]}, ${REPS_NIXOS} reps each =="
for n in "${NS_NIXOS[@]}"; do
  expr4a="(import ./lib/gen-nixos-hosts.nix { n = ${n}; }).host0.config.myFacts.ram.totalMiB"
  expr4b="builtins.foldl' (a: h: a + h.config.myFacts.ram.totalMiB) 0 (builtins.attrValues (import ./lib/gen-nixos-hosts.nix { n = ${n}; }))"

  for rep in $(seq 1 "$REPS_NIXOS"); do
    echo "  n=${n} rep=${rep}/${REPS_NIXOS}"
    run_one "4a-nixos-one-fact-one-host"   "$n" "$rep" yes "$expr4a"
    run_one "4b-nixos-one-fact-every-host" "$n" "$rep" yes "$expr4b"
  done
done

echo "== correctness check: cross-host-assert fires in BOTH directions (not timed) =="
{
  echo "-- plain data, n=100, no collide -> expect ok=true --"
  nix eval --impure --json --expr \
    '(import ./lib/cross-host-assert.nix { hosts = import ./lib/gen-plain-hosts.nix { n = 100; }; }).ok'
  echo "-- plain data, n=100, collide=ip -> expect ok=false, ipDuplicates=[\"198.51.100.1\"] --"
  nix eval --impure --json --expr \
    '(import ./lib/cross-host-assert.nix { hosts = import ./lib/gen-plain-hosts.nix { n = 100; collide = "ip"; }; })'
  echo "-- plain data, n=100, collide=disk -> expect ok=false, diskDuplicates=[\"ata-DISK-host0-0\"] --"
  nix eval --impure --json --expr \
    '(import ./lib/cross-host-assert.nix { hosts = import ./lib/gen-plain-hosts.nix { n = 100; collide = "disk"; }; })'
  echo "-- nixosSystem-sourced facts, n=3, collide=ip -> expect ok=false --"
  nix eval --impure --json --expr \
    'let hosts = builtins.mapAttrs (_: v: v.config.myFacts) (import ./lib/gen-nixos-hosts.nix { n = 3; collide = "ip"; }); in (import ./lib/cross-host-assert.nix { inherit hosts; })'
} | tee "${RAW_DIR}/correctness-check.txt"

echo
echo "Done. Timing table: ${CSV}"
echo "Raw per-run engine stats: ${RAW_DIR}/"
