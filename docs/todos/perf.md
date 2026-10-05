<!-- SPDX-License-Identifier: GPL-3.0-or-later -->

# Build performance decisions

## Current decision: stabilize before further optimization

2026-09-09: keep the implemented improvements and observe their stability during
normal work. All additional proposals below are deferred, including those
previously marked conditional. Recording an idea here does not authorize its
implementation. Do not add caching, scheduling changes or watchdog changes
without a new decision.

Investigation: 2026-09-09, incremental animation build `0f578ec3` at source
commit `56c09eca9`. Notification elapsed: 11m58s; foreground build: 11m54s.
Phase boundaries below combine usage logs, Ninja edge durations and artifact
timestamps; they are approximate, not a dedicated phase profile.

| Phase | Approximate duration |
| --- | ---: |
| Startup and graph generation | 26s |
| Compilation and archives | 14s |
| LTCG link | 108s |
| Wine startup/cleanup and post-link stall | 94s |
| Rich index, manifests, code delink/report | 112s |
| Target/base data delink and reports | 144s |
| Image-data refresh, including duplicate preparation | 76s |
| Function ledger | 22s |
| Module audits and finalization | 122s |

## Accepted scope

- Reuse one successful manifest preparation within the locked build. Standalone
  data refresh still prepares inputs; no unchecked skip flag or persistent cache.
- Batch symbol inspection, preserving exact per-object names and normalization
  checks. Discover and validate all symbol tables before renaming anything.
- Compute module-audit input fingerprints and image-wide content keys once in
  the existing build-scoped audit context.
- Log phase and expensive subprocess timings, including failed/interrupted
  operations, without changing their exceptions or exit behavior.

Read-only benchmarks: access-map reconstruction took 19.81s target + 19.71s
base per preparation. Two preparations therefore repeated at least 39.5s of
work. For 200-object samples, separate llvm-nm invocations took 2.48s/2.93s
(code/data); batched invocations took 0.035s/0.085s. Across three 2,758-object
scans, the serial cost extrapolated to about 115s. This is not an end-to-end
speedup measurement. Audit fingerprint/content-key repetition extrapolated to
about 20s. Savings from different proposals overlap and must not be added blindly.

## Verification result — 2026-09-09

Full pipeline job `e96eaf81f3064e2a95fb01bfbdc912c5` passed (exit 0):
5m28s including launch/setup, 5m18s inside the foreground build. Ninja had no
compilation or link work because engine inputs were unchanged. Consequently,
this is **not** evidence that an 11m58s relinking build now takes 5m28s.

The comparable post-Ninja pipeline went from approximately **7m56s to 4m29s**:
about **3m27s / 43% less wall time** in this single-run comparison. Repeated
benchmarks would be needed to separate machine-load variability.

| Instrumented phase | Duration |
| --- | ---: |
| Ninja graph | 14.5s |
| Ninja wrapper (no-op compilation/link) | 34.8s |
| Base rich index | 2.2s |
| Data preparation (once) | ~61s |
| Code COFF and report | 8.4s |
| Target data COFF | 34.5s |
| Base data COFF and reports | 41.7s |
| Image-data ledger | 7.2s |
| Function ledger | 21.4s |
| All-module audits | ~91s |
| README | 0.4s |

Base structure took 7.6s in parallel. Nested symbol inventories took
0.58s / 2.7s / 2.6s. These are included in the enclosing phases.

Validation:

- Ruff and all 294 tooling tests passed, including 19 new reuse, parsing,
  dependency-failure and interruption tests. The required match-db suite passed.
- EXE, PDB, function ledger, both code-object trees, code/cross-unit/data/strict
  comparison reports, image-data report and captured data TSVs retained their
  pre-build hashes. Code report: zero regressions, improvements, additions or removals.
- All 34 modules were audited; OPEN remains 14 in gfx and zero elsewhere.
  Module/aggregate audit JSON hashes refreshed with current ledger provenance;
  underlying audit TSVs are unchanged.
- All 2,758 code objects and 2,758 data objects produced the same symbol sets
  under individual and batched inspection.
- Original and optimized normalization, applied to copies of the same freshly
  delinked complete target-data tree, produced byte-identical results for all
  2,758 objects (845 renamed symbols in 203 objects). Four additional real
  alias fixtures also produced identical COFF.
- Raw data-object tree hashes changed across regeneration. A separate temporary
  regeneration using the original pipeline also differed from the current tree
  in 385 target objects. Thus whole-run raw data COFF byte stability is not
  established; do not claim all generated objects stayed byte-identical. The
  normalization equivalence check above isolates the changed implementation.
  Investigating data-emission repeatability is a separate follow-up, not part
  of these accepted optimizations.
- Existing EGL warnings, target PDB EOF skips for modules 730/742, and missing
  declarations-index notice remain. No new verification failures appeared.
- The measured README score block and ledger did not change. No engine source,
  compiler flags, watchdog thresholds, build concurrency or persistent caching
  were changed.

## Conditional and deferred work

Complexity and maintenance describe implementation effort and ongoing burden.
These items are recorded for consideration, not approved for implementation.

| Proposal | Benefit evidence | Complexity | Maintenance | Decision and error-safety requirement |
| --- | --- | --- | --- | --- |
| Shared relocation indexes instead of per-module image scans | All 34 modules' expected-site scans measured 10.57s | Medium | Low-medium | Conditional: preserve overlapping owners, physical-site coverage and boundary rules; compare complete site sets. |
| Overlap code delink/report with data preparation and processing | Serial independent phases; benefit not yet measured | Medium-high | Medium | Conditional after simpler changes: explicit dependencies, bounded memory/concurrency, drain/cancel all workers on failure, no early completion notification. |
| Overlap module audits with data-object generation/reporting | About 91s of audits versus 83s of data processing after their prerequisites | Medium-high | Medium | Deferred: first prove all read/write dependencies; complete preparation and function-ledger derivation before auditing, bound resource use, and propagate all worker failures before declaring completion. |
| Cache retail access evidence between builds | One target access reconstruction measured 19.81s | Medium-high | Medium-high | Defer: key EXE/PDB, rich index, tools and classification/configuration inputs; publish atomically; failed regeneration must not bless stale evidence. |
| Cache target data objects/normalization | Regenerated despite unchanged target manifests in the measured build | High | High | Defer: current-base aliases and consumer manifests affect output; key every dependency, verify completeness, preserve normalization checks and fail visibly on corruption. Savings overlap batching. |
| Remove Wine's post-link stall | Log confirms 61s idle before watchdog recovery | High | High | Separate investigation: recover actual process completion/exit status, distinguish unfinished PDB writes and failed links; do not infer success from fresh timestamps or lower the idle threshold alone. |
| Cache Ninja graph generation | About 22s; generator reported no changes | Medium-high | Medium-high | Defer: include-topology and source-set changes must invalidate the graph, not only vcproj mtimes; missing dependencies must never suppress compilation. |
| Reuse parsed rich indexes within a build | Repeated JSON parsing observed; gain unmeasured | Medium | Medium | Profile first: explicit immutable inputs and bounded memory; no process-global cache that survives input changes. |
| Optimize remaining gfx/render audit hot spots | gfx 24.6s and render 12.4s in the measured build | Unknown until profiled | Depends on cause | Profile first: 37s is the combined stage budget, not recoverable savings; preserve complete evidence and verdicts. |
| Reuse verified audit results when every dependency is unchanged | Avoids identical verification on true no-op inputs; hit rate unmeasured | High | High | Deferred: complete dependency keys, output integrity checks, atomic publication and explicit hit/miss reasons; never treat an old result as current after a failed refresh. |
| Increase compilation/objdiff parallelism | Compilation was 11.5s; objdiff already used 24 threads | Low-medium | Low | Not worthwhile for this workload; reconsider only with a representative compile-heavy profile. |

Target-data generation and base-data generation are not independent as currently
implemented: the base reads the target symbol map, and both touch the data
project configuration and target normalization. Structure extraction already
runs in parallel; objdiff comparison itself was fast (0.76s code, 6.24s data,
5.45s strict data).

## Additional savings estimates

The denominator is the measured **328-second no-op build**, including launch
and setup. These are component costs or scheduling ceilings, not measured
speedups. Savings overlap and cannot be summed; percentages would be smaller
for a build that also recompiles and relinks.

| Candidate | Potential seconds saved | Fraction of 328s | Qualification |
| --- | ---: | ---: | --- |
| Shared relocation inventory | Up to 10.6s | Up to 3.2% | Measured total scan cost; replacement still has work to do. |
| Overlap code processing with preparation | Up to 8.4s | Up to 2.6% | Code-stage duration limits the benefit of this overlap alone. |
| Overlap audits with data generation/reports | Up to about 83s | Up to about 25% | Scheduling ceiling, reduced by CPU/memory/I/O contention and coordination overhead. |
| Cache unchanged retail access evidence | About 20s on a hit | About 6% | Access reconstruction alone; cache lookup/invalidation costs and hit rate not measured. |
| Cache unchanged target data objects | Up to 34.5s on a hit | Up to 10.5% | Entire target-data stage ceiling, not a guaranteed saving. |
| Reuse parsed rich indexes | Unmeasured | Unknown | Profile before assigning a number. |
| Optimize audit hot loops | Unmeasured | Unknown | gfx + render take 37s combined; do not present that as savings. |

The audit/data overlap proposal would move function-ledger derivation before
the parallel work. After code evidence and data preparation are complete, audits
appear not to require the data COFF reports or image-data ledger. The data lane
takes approximately 34.5 + 41.7 + 7.2 = 83.4s, versus approximately 91s for
audits, so overlapping those paths could hide much of the shorter path. This
dependency assessment still needs an implementation-level safety review.

Wine stall recovery could save approximately 61s on affected relinks, but saved
zero in the measured no-op run because that run did not hit the stall. Do not
apply its percentage to the 328-second denominator.

If optimization is resumed, the suggested investigation order is shared
relocation inventory, profiling gfx/render audit internals, audit/data overlap,
then persistent caches. This order is advisory, not an active work queue.

## Why small function edits still trigger whole-image audits

LTCG and identical-code folding operate on the linked executable. One edited
function can alter other functions' inlining, ownership, addresses or data
references. Therefore, unchanged source in another unit is not proof that its
linked output or datum-use verdict is unchanged.

| Inputs changed | Appropriate verification |
| --- | --- |
| Source changed and the executable was relinked | Verify the new whole-image result; do not restrict checks to the edited TU. |
| EXE/PDB unchanged but audit tooling, policy or other evidence changed | Rerun the affected verification. |
| Every audit dependency and required output is unchanged and verified | Reuse could be safe with complete dependency-based invalidation; not implemented. |

The current pipeline deliberately regenerates and audits conservatively. The
last verification run needed those audits despite a no-op compiler invocation:
the audit implementation itself had changed. An ordinary no-op build with all
audit inputs unchanged could avoid repeated work once safe reuse is implemented.

Future reuse must account for the exact inputs an audit reads: EXE/PDB, rich and
data/access indexes, function ledger, relevant source hashes, reviews, ownership
and classification policies, tool versions and schemas. An EXE hash alone or a
list of edited TUs is insufficient. Cache hits must verify required outputs;
missing, incompatible or corrupt entries require regeneration, and a failed
regeneration must remain visibly failed rather than falling back to stale data.

## Stability observation for the current improvements

Use subsequent normal builds to collect evidence; no extra optimization or
automatic build loop is requested by this decision.

- Keep phase timings and distinguish no-op runs, small edits/relinks and broader
  header-triggered rebuilds. Compare like workloads before revising estimates.
- Check that data preparation occurs once and all expected audits still run.
  Standalone data refresh must continue to prepare its own inputs.
- Check warnings, exit status and completion notifications, not just wall time.
  Investigate new failures or stale-output symptoms before pursuing more speed.
- When image and policy inputs are unchanged, compare reports, ledger and audit
  rows. For relinks, inspect global regressions rather than requiring identical
  output everywhere. Keep raw data-COFF repeatability separate from normalization
  correctness, as recorded in the verification result above.
- Preserve original failure causes, including missing inputs, malformed symbol
  output, failed subprocesses and interruption. Keep the existing error-contract
  tests and build serialization intact.
- No stability duration or required build count has been set. Reassess after
  representative normal runs, with explicit approval before expanding scope.

## Rejected shortcuts

- Shorten the watchdog threshold and call fresh EXE/PDB timestamps success.
- Skip global verification because only one source unit changed.
- Remove anchored disassembly; it supplies correctness evidence.
- Run full builds concurrently against shared output artifacts or Wine prefixes.
- Change compiler/linker flags to make matching builds faster.
- Silently reuse old output after a failed generation step.

## Acceptance checks

For each optimization, compare outputs on identical inputs (COFF, reports and
ledger, excluding only intentional timing metadata). Exercise missing inputs,
subprocess failure, malformed output and interruption where applicable. Failed
stages must remain visibly failed; optional shadow-stage warnings must not turn
into claims of fresh evidence. Run the tooling tests and a complete build,
compare global regressions, and record end-to-end timings before prioritizing
additional architectural changes. Keep the build lock and existing matching
semantics unchanged.
