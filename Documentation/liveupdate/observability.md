# Live Update Archaeological Analysis — Observability Guide

**Subsystem**: Live Update Orchestrator (LUO) + Kexec HandOver (KHO), Feature F-017
**Target**: Linux kernel v7.0.0-rc3 "Baby Opossum Posse"
**Pipeline**: `tools/liveupdate/archaeology/`

## 1. Overview

This document describes how to verify the correctness and completeness of the
Live Update archaeological analysis pipeline. It covers structured logging
conventions, the metrics summary emitted on completion, automated health
checks, and step-by-step local verification procedures.

The analysis pipeline consists of **7 shell scripts** (Directives 1–7) plus
**1 Python orchestrator** (Directive 8) that together produce a structured
narrative document (`Documentation/liveupdate/archaeology.md`). Each script
performs a specific archaeological directive against the Linux kernel git
history and source tree, producing structured intermediate output that the
orchestrator synthesizes into the final narrative.

| Script | Directive | Purpose |
|---|---|---|
| `manifest.sh` | 1 | Establish the feature boundary — file manifest with commit dates |
| `authorship.sh` | 2 | Trace authorship and chronology — per-author stats and timeline |
| `decisions.sh` | 3 | Reconstruct design decisions — 4 specific tradeoff analyses |
| `statemachine.sh` | 4 | Map state machine evolution — session lifecycle commit tracking |
| `bottlenecks.sh` | 5 | Identify development bottlenecks — gaps, reverts, persistent debt |
| `bugs.sh` | 6 | Catalog bugs — resolved/remaining issues, defensive patterns |
| `integration.sh` | 7 | Assess integration surface — cross-subsystem maturity classification |
| `analyze.py` | 8 | Compile archaeological narrative — synthesize all findings |

All scripts reside in `tools/liveupdate/archaeology/`. The orchestrator
(`analyze.py`) invokes the shell scripts in sequence, collects their output,
and produces the final deliverable.

## 2. Structured Logging

### 2.1 Correlation IDs

Every directive execution is tagged with a **unique correlation ID** for
end-to-end traceability. The correlation ID appears as the first field on
every structured log line emitted by that directive.

**Format**: `LU-ARCH-D<directive_number>-<ISO8601_timestamp>`

**Examples**:
```
LU-ARCH-D1-20260216T143022    (Directive 1 — manifest.sh)
LU-ARCH-D2-20260216T143045    (Directive 2 — authorship.sh)
LU-ARCH-D8-20260216T143312    (Directive 8 — analyze.py)
```

The correlation ID is generated at script startup using the directive number
and the current UTC timestamp truncated to seconds. This format is:

- **Human-readable**: the directive number is immediately visible.
- **Sortable**: ISO 8601 timestamps sort lexicographically.
- **Greppable**: `grep 'LU-ARCH-D3'` isolates all Directive 3 log lines.

### 2.2 Log Format

All scripts emit structured log lines to **stderr** (stdout is reserved for
data output). The log line format is:

```
[<correlation_id>] [<ISO8601_timestamp>] [<level>] <message>
```

**Log Levels**:

| Level | Meaning |
|---|---|
| `INFO` | Normal progress — file discovered, author found, milestone extracted |
| `WARN` | Non-fatal anomaly — missing expected data, empty intermediate result |
| `ERROR` | Fatal failure — script cannot continue, invalid repository state |

**Example log lines**:
```
[LU-ARCH-D1-20260216T143022] [2026-02-16T14:30:23Z] [INFO] Discovered file: kernel/liveupdate/luo_core.c
[LU-ARCH-D1-20260216T143022] [2026-02-16T14:30:24Z] [INFO] First commit: 48a1b2321d76 (2025-11-01)
[LU-ARCH-D1-20260216T143022] [2026-02-16T14:30:25Z] [INFO] Manifest complete: 50 files
[LU-ARCH-D6-20260216T143155] [2026-02-16T14:31:56Z] [WARN] No HACK markers found in current HEAD
[LU-ARCH-D8-20260216T143312] [2026-02-16T14:33:15Z] [ERROR] Word count 1823 below threshold 2000
```

### 2.3 Per-Directive Logging Detail

Each directive logs specific events relevant to its analysis scope:

**Directive 1 — manifest.sh** (Feature Boundary):
- Each file discovered and added to the manifest
- First-commit hash and date for each file
- Last-commit hash and date for each file
- Total file count at completion
- Component classification (core state machine, FDT serialization, FD token,
  callback registration, KVM integration) per file

**Directive 2 — authorship.sh** (Authorship and Chronology):
- Each unique author found with commit count
- Date range (earliest, latest) per author
- Components touched per author (kernel/liveupdate/, include/, mm/, arch/, etc.)
- Each milestone extracted with commit hash and date
- Total milestone count (must be ≥5 for pass)

**Directive 3 — decisions.sh** (Design Decisions):
- Each of the 4 design tradeoff searches initiated
- Evidence found: commit hash and relevant message excerpt
- Evidence not found: explicit "rationale not recorded in-tree" log line
- In-code comment evidence: file:line references

**Directive 4 — statemachine.sh** (State Machine Evolution):
- Each state-modifying commit found with hash, author, date
- Classification of each commit: bug fix, feature addition, or refactor
- State transitions added, removed, or renamed (if any)
- Current HEAD state machine summary

**Directive 5 — bottlenecks.sh** (Development Bottlenecks):
- Inactivity gaps detected (periods with >3 months between commits)
- Reverted commits found (or "no reverts found")
- Persistent TODO/FIXME/HACK markers tracked across ≥3 commits
- Incomplete components identified with classification
  (blocked, contested, abandoned, or deferred)

**Directive 6 — bugs.sh** (Bug Catalog):
- Bug-related commit messages found (keywords: fix, bug, regression, oops,
  panic, null, leak, race, deadlock)
- Introduce-commit / fix-commit pairs for resolved bugs
- Current HEAD TODO/FIXME/HACK counts per file
- Current HEAD WARN_ON/BUG_ON counts per file
- Summary: total resolved bugs, total remaining issues

**Directive 7 — integration.sh** (Integration Surface):
- Each integration point assessed with name and file evidence
- Maturity classification: implemented, stubbed, designed, or absent
- Kconfig dependency chain traversal
- Cross-reference validation between Live Update files and other subsystems

**Directive 8 — analyze.py** (Narrative Synthesis):
- Each narrative section generation started and completed
- Intermediate script invocation results (exit code, output size)
- Mermaid diagram count embedded in final document
- Word count verification result (PASS/FAIL with actual count)
- Final metrics summary emission

## 3. Metrics Summary

The `analyze.py` orchestrator produces a **metrics summary block** on
completion, emitted to stderr. Each metric is a key-value pair with an
expected range and pass/fail threshold derived from actual repository
evidence.

### 3.1 Metric Definitions

| Metric | Description | Expected Value | Pass/Fail Threshold |
|---|---|---|---|
| `manifest_file_count` | Total files in the feature boundary manifest | ~50 | ≥5 (one per component) |
| `total_commits_analyzed` | Total unique commits touching manifest files | ~85 (LU-specific files) | ≥10 |
| `total_authors_found` | Unique commit authors across manifest files | ~17 | ≥3 |
| `total_milestones_identified` | Dated milestones in the chronological timeline | ≥6 | **≥5** (Directive 2 pass/fail) |
| `total_bottlenecks_found` | Count of classified development bottlenecks | ≥3 | ≥0 (informational) |
| `total_bugs_catalogued` | Count of resolved + remaining issues | ≥5 | ≥0 (informational) |
| `total_integration_points` | Count of assessed integration surfaces | 8 | ≥4 |
| `narrative_word_count` | Final archaeology.md word count | 2,000–4,000 | **≥2,000** (hard pass/fail) |
| `mermaid_diagram_count` | Mermaid diagrams embedded in archaeology.md | ≥4 | **≥4** (required diagrams) |

### 3.2 Expected Value Derivation

All expected values are derived from actual repository analysis of Linux
kernel v7.0.0-rc3, not from estimation or speculation:

- **manifest_file_count (~50)**: Counted by enumerating files in
  `kernel/liveupdate/` (11 files), `include/linux/kho/` + headers (7),
  `mm/` integration files (5), `arch/x86/` integration (7),
  `drivers/firmware/efi/efi-init.c` (1), `lib/` tests (4),
  `tools/testing/selftests/liveupdate/` (8), and `Documentation/` (6).
  Source: `find` enumeration across all subsystem directories.

- **total_commits_analyzed (~85)**: Derived from
  `git log --all --oneline -- <LU-specific files> | sort -u | wc -l`
  across all files exclusive to the Live Update subsystem (excludes shared
  files like `mm/memblock.c` and `arch/x86/kernel/e820.c` which have
  thousands of non-LU commits).

- **total_authors_found (~17)**: Derived from
  `git log --all --format="%an" -- <LU-specific files> | sort -u | wc -l`.
  The 17 unique authors include: Alexander Graf, Andrew Morton,
  Arnd Bergmann, Dan Carpenter, Evangelos Petrongonas, Jani Nikula,
  Jason Miu, Kees Cook, Linus Torvalds, Long Wei, Mike Rapoport
  (Microsoft), Pasha Tatashin, Pratyush Yadav, Pratyush Yadav (Google),
  Ran Xiaokai, Tycho Andersen (AMD), and Zhu Yanjun. Note: Pratyush Yadav
  appears under two author identities reflecting an affiliation change
  (Amazon → Google).

- **total_milestones_identified (≥6)**: Six milestones are identifiable from
  the commit record: (1) 2025-05-09 KHO Foundation, (2) 2025-08-21
  `is_kho_boot()`, (3) 2025-09-21 KHO API rework, (4) 2025-11-01 LUO
  integration and KHO move, (5) 2025-11/12 memfd handler, (6) 2026-01 to
  2026-02 stabilization. Source: `git log --all --reverse -- kernel/liveupdate/`.

- **total_integration_points (8)**: Eight integration surfaces are assessed:
  KVM (absent), memfd (implemented), memblock/memory management
  (implemented), x86 architecture (implemented), EFI firmware (implemented),
  device drivers (absent), networking (absent), filesystem (absent).

- **mermaid_diagram_count (≥4)**: Four diagrams are required per AAP §0.8.6:
  (1) component dependency graph, (2) authorship contribution visualization,
  (3) state machine evolution, (4) integration maturity matrix.

### 3.3 Metrics Output Format

The orchestrator emits the metrics summary in a machine-parseable format:

```
[LU-ARCH-D8-<timestamp>] [<timestamp>] [INFO] === METRICS SUMMARY ===
[LU-ARCH-D8-<timestamp>] [<timestamp>] [INFO] metric:manifest_file_count=50
[LU-ARCH-D8-<timestamp>] [<timestamp>] [INFO] metric:total_commits_analyzed=85
[LU-ARCH-D8-<timestamp>] [<timestamp>] [INFO] metric:total_authors_found=17
[LU-ARCH-D8-<timestamp>] [<timestamp>] [INFO] metric:total_milestones_identified=6
[LU-ARCH-D8-<timestamp>] [<timestamp>] [INFO] metric:total_bottlenecks_found=4
[LU-ARCH-D8-<timestamp>] [<timestamp>] [INFO] metric:total_bugs_catalogued=8
[LU-ARCH-D8-<timestamp>] [<timestamp>] [INFO] metric:total_integration_points=8
[LU-ARCH-D8-<timestamp>] [<timestamp>] [INFO] metric:narrative_word_count=2847
[LU-ARCH-D8-<timestamp>] [<timestamp>] [INFO] metric:mermaid_diagram_count=4
[LU-ARCH-D8-<timestamp>] [<timestamp>] [INFO] === PASS/FAIL SUMMARY ===
[LU-ARCH-D8-<timestamp>] [<timestamp>] [INFO] check:milestones=PASS (6 >= 5)
[LU-ARCH-D8-<timestamp>] [<timestamp>] [INFO] check:word_count=PASS (2847 >= 2000)
[LU-ARCH-D8-<timestamp>] [<timestamp>] [INFO] check:mermaid_diagrams=PASS (4 >= 4)
[LU-ARCH-D8-<timestamp>] [<timestamp>] [INFO] check:components_covered=PASS (5 >= 5)
```

To extract metrics programmatically:

```bash
python3 tools/liveupdate/archaeology/analyze.py 2>&1 | grep '^.*metric:' | \
    sed 's/.*metric://'
```

## 4. Health Checks

### 4.1 Script Exit Codes

All 7 analysis scripts and the orchestrator must exit with code **0** for
the pipeline to be considered healthy. The orchestrator checks each script's
exit code automatically and logs failures.

| Script | Expected Exit Code | Failure Meaning |
|---|---|---|
| `manifest.sh` | 0 | Repository access failure or no LU files found |
| `authorship.sh` | 0 | Git log parsing failure or no commits found |
| `decisions.sh` | 0 | Commit message search failure |
| `statemachine.sh` | 0 | State file analysis failure |
| `bottlenecks.sh` | 0 | Timeline analysis failure |
| `bugs.sh` | 0 | Bug search or HEAD scan failure |
| `integration.sh` | 0 | Integration file discovery failure |
| `analyze.py` | 0 | Synthesis failure, word count below threshold, or script failures |

**Verification** (manual, after each script):

```bash
bash manifest.sh > /dev/null 2>&1; echo "manifest.sh exit: $?"
bash authorship.sh > /dev/null 2>&1; echo "authorship.sh exit: $?"
bash decisions.sh > /dev/null 2>&1; echo "decisions.sh exit: $?"
bash statemachine.sh > /dev/null 2>&1; echo "statemachine.sh exit: $?"
bash bottlenecks.sh > /dev/null 2>&1; echo "bottlenecks.sh exit: $?"
bash bugs.sh > /dev/null 2>&1; echo "bugs.sh exit: $?"
bash integration.sh > /dev/null 2>&1; echo "integration.sh exit: $?"
python3 analyze.py; echo "analyze.py exit: $?"
```

All lines must show `exit: 0`.

### 4.2 Non-Empty Intermediate Outputs

Each shell script must produce **non-empty** output to stdout. Empty output
indicates a logic error, missing repository data, or incorrect working
directory.

**Verification**:

```bash
cd tools/liveupdate/archaeology/

bash manifest.sh > /tmp/lu-manifest.tsv
test -s /tmp/lu-manifest.tsv && echo "manifest: OK" || echo "manifest: EMPTY"

bash authorship.sh > /tmp/lu-authorship.tsv
test -s /tmp/lu-authorship.tsv && echo "authorship: OK" || echo "authorship: EMPTY"

bash decisions.sh > /tmp/lu-decisions.tsv
test -s /tmp/lu-decisions.tsv && echo "decisions: OK" || echo "decisions: EMPTY"

bash statemachine.sh > /tmp/lu-statemachine.txt
test -s /tmp/lu-statemachine.txt && echo "statemachine: OK" || echo "statemachine: EMPTY"

bash bottlenecks.sh > /tmp/lu-bottlenecks.tsv
test -s /tmp/lu-bottlenecks.tsv && echo "bottlenecks: OK" || echo "bottlenecks: EMPTY"

bash bugs.sh > /tmp/lu-bugs.tsv
test -s /tmp/lu-bugs.tsv && echo "bugs: OK" || echo "bugs: EMPTY"

bash integration.sh > /tmp/lu-integration.tsv
test -s /tmp/lu-integration.tsv && echo "integration: OK" || echo "integration: EMPTY"
```

All outputs must report `OK`. If any report `EMPTY`, investigate the
corresponding script's stderr log for `ERROR` or `WARN` messages.

### 4.3 Word Count Threshold

The final `Documentation/liveupdate/archaeology.md` must contain **≥2,000
words**. This is a hard pass/fail criterion. The orchestrator verifies this
automatically before declaring success.

**Manual verification**:

```bash
wc -w < Documentation/liveupdate/archaeology.md
```

Expected output: a number ≥ 2000. If below threshold, check that all 7
directive scripts produced non-empty output — missing directive data results
in shorter narrative sections.

### 4.4 Commit Hash Validity

Every commit hash referenced in the narrative document must resolve to a
real commit in the repository. Fabricated or placeholder hashes violate the
Zero Speculation Rule.

**Verification**:

```bash
grep -oE '[0-9a-f]{12,40}' Documentation/liveupdate/archaeology.md | \
    sort -u | while read hash; do
        if ! git log --oneline -1 "$hash" > /dev/null 2>&1; then
            echo "INVALID HASH: $hash"
        fi
    done
```

Expected output: no lines. Any `INVALID HASH` output indicates a
documentation error that must be corrected.

**Known valid hashes** (verified from the repository at v7.0.0-rc3):

| Hash (short) | Commit Subject |
|---|---|
| `48a1b2321d76` | liveupdate: kho: move to kernel/liveupdate |
| `3dc92c311498` | kexec: add Kexec HandOver (KHO) generation helpers |
| `c609c144b0e8` | kexec: add KHO parsing support |
| `fc33e4b44b27` | kexec: enable KHO support for memory preservation |
| `d6d511639185` | kexec: introduce is\_kho\_boot() |
| `8375b76517cb` | kho: replace kho\_preserve\_phys() with kho\_preserve\_pages() |
| `a667300bd53f` | kho: add support for preserving vmalloc allocations |
| `70f9133096c8` | kho: drop notifiers |
| `f85b1c6af5bc` | liveupdate: luo\_file: remember retrieve() status |

### 4.5 File Reference Validity

All `file:line` references in the narrative must point to existing content
in the current HEAD. Sample verification for key references:

```bash
# Verify the FIXME at kexec_handover.c:657
sed -n '657p' kernel/liveupdate/kexec_handover.c | grep -q 'FIXME'
echo "kexec_handover.c:657 FIXME: $?"   # Must be 0

# Verify LUO DOC comment in luo_core.c
sed -n '9p' kernel/liveupdate/luo_core.c | grep -q 'Live Update Orchestrator'
echo "luo_core.c:9 DOC: $?"             # Must be 0

# Verify luo_file.c handler registration docs
sed -n '19p' kernel/liveupdate/luo_file.c | grep -q 'Handler Registration'
echo "luo_file.c:19 Handler: $?"        # Must be 0
```

All checks must exit with code 0.

## 5. Local Verification Procedures

### 5.1 Quick Smoke Test (< 1 minute)

Verify that the pipeline can access the repository and produce basic output:

```bash
cd tools/liveupdate/archaeology/

# Test manifest script produces TSV output
bash manifest.sh 2>/dev/null | head -5
# Expected: 5 lines of tab-separated file paths with commit dates

# Verify exit code
echo "Exit: $?"
# Expected: Exit: 0

# Verify file count is reasonable
bash manifest.sh 2>/dev/null | wc -l
# Expected: ~50 (the number of files in the LU subsystem manifest)
```

### 5.2 Full Pipeline Verification (< 5 minutes)

Run the complete orchestrator and check for pass/fail results:

```bash
cd tools/liveupdate/archaeology/

# Run full pipeline, capture structured output
python3 analyze.py 2>&1 | tee /tmp/lu-pipeline.log

# Extract pass/fail results
grep -E '(PASS|FAIL|ERROR|metric:)' /tmp/lu-pipeline.log
```

**Expected output pattern**:
```
... metric:manifest_file_count=50
... metric:total_commits_analyzed=85
... metric:total_authors_found=17
... metric:narrative_word_count=NNNN
... check:milestones=PASS (N >= 5)
... check:word_count=PASS (NNNN >= 2000)
... check:mermaid_diagrams=PASS (N >= 4)
... check:components_covered=PASS (N >= 5)
```

No line should contain `FAIL` or `ERROR`. If any do, consult the full log
at `/tmp/lu-pipeline.log` and the per-directive stderr output.

### 5.3 Narrative Integrity Check

Verify the structure and content of the final narrative document:

```bash
# Verify word count (must be >= 2000)
wc -w < Documentation/liveupdate/archaeology.md

# Verify section count (must be 9 top-level sections)
grep -c '^## ' Documentation/liveupdate/archaeology.md

# Verify Mermaid diagram count (must be >= 4)
grep -c '```mermaid' Documentation/liveupdate/archaeology.md

# Verify no unclosed Mermaid blocks
OPEN=$(grep -c '```mermaid' Documentation/liveupdate/archaeology.md)
CLOSE=$(grep -c '^```$' Documentation/liveupdate/archaeology.md)
echo "Mermaid blocks: $OPEN open, code-block closes: $CLOSE (closes >= opens)"
```

### 5.4 Cross-Reference Verification

Validate all commit hashes and file references in the narrative:

```bash
# Extract and validate all referenced commit hashes (12+ hex chars)
echo "=== Commit Hash Validation ==="
INVALID=0
grep -oE '[0-9a-f]{12}' Documentation/liveupdate/archaeology.md | \
    sort -u | while read hash; do
        if ! git log --oneline -1 "$hash" > /dev/null 2>&1; then
            echo "INVALID HASH: $hash"
            INVALID=$((INVALID + 1))
        fi
    done
echo "Invalid hashes: $INVALID (must be 0)"

# Spot-check key file:line references
echo "=== File Reference Spot Checks ==="
test -f kernel/liveupdate/luo_core.c && echo "luo_core.c: EXISTS" || echo "luo_core.c: MISSING"
test -f kernel/liveupdate/kexec_handover.c && echo "kexec_handover.c: EXISTS" || echo "kexec_handover.c: MISSING"
test -f mm/memfd_luo.c && echo "memfd_luo.c: EXISTS" || echo "memfd_luo.c: MISSING"
test -f include/linux/liveupdate.h && echo "liveupdate.h: EXISTS" || echo "liveupdate.h: MISSING"
test -f include/uapi/linux/liveupdate.h && echo "uapi/liveupdate.h: EXISTS" || echo "uapi/liveupdate.h: MISSING"
```

### 5.5 Deliverable Completeness Check

Verify all expected deliverable files exist:

```bash
echo "=== Deliverable Files ==="
for f in \
    Documentation/liveupdate/archaeology.md \
    Documentation/liveupdate/decision-log.md \
    Documentation/liveupdate/presentation.html \
    Documentation/liveupdate/onboarding.md \
    Documentation/liveupdate/observability.md; do
    test -f "$f" && echo "EXISTS: $f" || echo "MISSING: $f"
done

echo "=== Analysis Scripts ==="
for f in \
    tools/liveupdate/archaeology/manifest.sh \
    tools/liveupdate/archaeology/authorship.sh \
    tools/liveupdate/archaeology/decisions.sh \
    tools/liveupdate/archaeology/statemachine.sh \
    tools/liveupdate/archaeology/bottlenecks.sh \
    tools/liveupdate/archaeology/bugs.sh \
    tools/liveupdate/archaeology/integration.sh \
    tools/liveupdate/archaeology/analyze.py; do
    test -f "$f" && echo "EXISTS: $f" || echo "MISSING: $f"
done
```

All files must report `EXISTS`.

## 6. Troubleshooting

### 6.1 Empty Manifest Output

**Symptom**: `manifest.sh` produces no output or very few lines.

**Causes and Remedies**:
- **Wrong working directory**: Scripts expect to run from the repository
  root or `tools/liveupdate/archaeology/`. Verify with `git rev-parse
  --show-toplevel`.
- **Pattern mismatch**: The `find` and `grep` patterns in `manifest.sh`
  target `kernel/liveupdate/`, `include/linux/kho/`, `mm/memfd_luo.c`, etc.
  If the repository structure has changed, update the patterns.
- **Permissions**: Ensure `manifest.sh` has execute permission:
  `chmod +x tools/liveupdate/archaeology/manifest.sh`.

### 6.2 Missing Commit Data

**Symptom**: Author counts, commit counts, or milestone dates are lower than
expected or zero.

**Causes and Remedies**:
- **Shallow clone**: The most common failure mode. Verify the repository is
  not shallow:
  ```bash
  git rev-parse --is-shallow-repository
  # Must output: false
  ```
  If `true`, fetch the full history: `git fetch --unshallow`.
- **Missing remote branches**: Some commits may be on non-default branches.
  Ensure all branches are fetched: `git fetch --all`.
- **Wrong tag/branch**: Ensure the checkout is at the analyzed version:
  ```bash
  head -5 Makefile | grep -E 'VERSION|PATCHLEVEL|SUBLEVEL|EXTRAVERSION'
  # Expected: VERSION = 7, PATCHLEVEL = 0, SUBLEVEL = 0, EXTRAVERSION = -rc3
  ```

### 6.3 Word Count Below Threshold

**Symptom**: `narrative_word_count` is below 2,000.

**Causes and Remedies**:
- **Missing directive output**: If one or more shell scripts produced empty
  output, the corresponding narrative section will be truncated. Check the
  non-empty intermediate outputs health check (§4.2).
- **Script errors**: Review stderr output from each script for `ERROR`
  messages. The orchestrator logs each script invocation and its exit code.
- **Repository data insufficient**: In an extremely stripped repository, the
  analysis may produce less data. This pipeline is designed for the full
  Linux kernel v7.0.0-rc3 repository.

### 6.4 Invalid Commit Hashes

**Symptom**: The cross-reference verification (§5.4) reports `INVALID HASH`
entries.

**Causes and Remedies**:
- **Wrong checkout**: The hashes were extracted from a specific repository
  version. Ensure the checkout matches the analyzed tag/branch.
- **Rebased history**: If the repository has been rebased since analysis,
  commit hashes may have changed. Re-run the full analysis pipeline.
- **Shallow clone**: Shallow clones do not contain all commit objects.
  See §6.2.

### 6.5 Script Permission Errors

**Symptom**: `bash: permission denied` or similar errors when running
scripts.

**Remedy**:
```bash
chmod +x tools/liveupdate/archaeology/*.sh
```

The Python orchestrator (`analyze.py`) does not require execute permission
when invoked as `python3 analyze.py`.

### 6.6 Python Version Errors

**Symptom**: `SyntaxError` on f-strings or `ModuleNotFoundError` for
standard library modules.

**Causes and Remedies**:
- **Python 2 invoked**: Explicitly use `python3`, not `python`:
  ```bash
  python3 --version    # Must be >= 3.6
  ```
- **Very old Python 3**: f-strings require Python ≥ 3.6, `pathlib` requires
  Python ≥ 3.4. Update Python if needed.

### 6.7 Git Version Compatibility

**Symptom**: `git log --follow` does not track renames or `--all` is not
recognized.

**Causes and Remedies**:
- **Git version too old**: Verify `git --version` reports ≥ 2.0. The
  `--follow` flag and `--all` flag require modern git. Update git if needed.

### 6.8 Orchestrator Cannot Find Scripts

**Symptom**: `analyze.py` reports `FileNotFoundError` for shell scripts.

**Causes and Remedies**:
- **Wrong working directory**: The orchestrator expects to find sibling
  scripts in the same directory (`tools/liveupdate/archaeology/`). Run it
  from that directory:
  ```bash
  cd tools/liveupdate/archaeology/
  python3 analyze.py
  ```
- **Alternatively**, run from repository root and ensure the orchestrator
  resolves paths relative to its own location.
