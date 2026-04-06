# Live Update Archaeological Analysis — Onboarding Guide

**Target**: Linux kernel v7.0.0-rc3 "Baby Opossum Posse"
**Feature**: F-017 Live Update Subsystem
**Scope**: Live Update Orchestrator (LUO) + Kexec HandOver (KHO) development archaeology

---

## 1. Introduction

This document guides new developers through reproducing the Linux kernel
Live Update subsystem archaeological analysis from a clean machine. The
analysis (Feature F-017) systematically traces every commit, design decision,
authorship pattern, development bottleneck, and unresolved issue in the Live
Update subsystem from its inception to the current HEAD.

The analysis pipeline produces the following deliverables:

| Deliverable | Path | Description |
|---|---|---|
| Primary Narrative | `Documentation/liveupdate/archaeology.md` | Structured document (≥2,000 words) with 9 sections covering feature identity, authorship, timeline, design decisions, state machine evolution, bottlenecks, bugs, integration maturity, and open questions |
| Decision Log | `Documentation/liveupdate/decision-log.md` | Methodology decision log as a Markdown table documenting every non-trivial analysis choice |
| Executive Presentation | `Documentation/liveupdate/presentation.html` | Self-contained reveal.js HTML artifact with Mermaid diagrams for non-technical leadership |
| Onboarding Guide | `Documentation/liveupdate/onboarding.md` | This document |
| Observability Guide | `Documentation/liveupdate/observability.md` | Pipeline verification procedures, structured logging, metrics, and health checks |

The analysis is conducted entirely from in-tree evidence — commit messages,
source code, and documentation. No external mailing list archives or out-of-tree
sources are accessed. Every factual claim in the output traces to a specific
commit hash, file:line reference, or is explicitly annotated as "rationale not
recorded in-tree."

---

## 2. Prerequisites

### 2.1 System Requirements

The analysis pipeline requires the following tools. All are standard on Linux
development machines; no external packages or language-specific package managers
are needed.

| Tool | Minimum Version | Reason |
|---|---|---|
| `git` | ≥ 2.0 | `git log --follow --all` requires version 2.0+ for reliable rename tracking |
| `bash` | ≥ 4.2 | Associative arrays (`declare -A`) used in analysis scripts for per-author and per-file aggregation |
| `python3` | ≥ 3.6 | f-strings and `pathlib` used in the `analyze.py` orchestrator |
| `grep` | POSIX | Text pattern matching in commit messages and source files |
| `sed` | POSIX | Stream editing for data extraction |
| `awk` | POSIX | Field-based text processing in TSV pipelines |
| `sort` | POSIX | Sorting intermediate data for aggregation |
| `uniq` | POSIX | Deduplication and counting (`uniq -c`) |
| `wc` | POSIX | Word and line counting for verification |
| `date` | POSIX | Timestamp formatting for correlation IDs |
| `find` | POSIX | File discovery for manifest generation |
| `cut` | POSIX | Field extraction from TSV data |

### 2.2 Verification Commands

Run these commands to confirm your environment is ready:

```bash
# Verify git version (must be ≥ 2.0)
git --version

# Verify bash version (must be ≥ 4.2)
bash --version | head -1

# Verify python3 version (must be ≥ 3.6)
python3 --version

# Verify POSIX utilities are available
for cmd in grep sed awk sort uniq wc date find cut; do
    command -v "$cmd" >/dev/null 2>&1 && echo "OK: $cmd" || echo "MISSING: $cmd"
done
```

### 2.3 Python Standard Library Only

The `analyze.py` orchestrator uses **only Python standard library modules**:
`subprocess`, `csv`, `os`, `sys`, `datetime`, `pathlib`, `textwrap`, `re`,
`io`, and `json`. No `pip install` step is required. No virtual environment
is needed.

---

## 3. Repository Setup

### 3.1 Clone with Full History

Clone the Linux kernel repository with **complete** git history:

```bash
git clone https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git
cd linux
git checkout v7.0.0-rc3
```

> **Note**: The full clone is approximately 5 GB and may take 10–30 minutes
> depending on network speed. This is a one-time cost.

### 3.2 CRITICAL — Shallow Clones Will Break Everything

> ⚠️ **WARNING**: Using `git clone --depth=N` or any shallow clone will cause
> **ALL** analysis scripts to produce incomplete or incorrect results. The
> scripts will not error out — they will silently return partial data.

Shallow clones break the analysis because:

- **`git log --follow --all`** requires full commit history to track file
  renames. The KHO code was moved from its original location to
  `kernel/liveupdate/` in commit `48a1b2321d76` (2025-11-01). Without full
  history, `--follow` cannot trace back through this rename.
- **Authorship analysis** (Directive 2) aggregates commits across the entire
  development history. A shallow clone truncates the commit chain, missing
  early contributors like Alexander Graf (Amazon) who originated the KHO
  concept.
- **First-commit detection** (Directive 1) uses `git log --reverse` to find
  the earliest commit per file. In a shallow clone, this returns the oldest
  *available* commit, not the actual first commit.
- **Milestone extraction** (Directive 2) identifies dated events across the
  full timeline. Shallow clones compress the visible timeline.

**If you already have a shallow clone**, convert it to a full clone:

```bash
git fetch --unshallow
```

### 3.3 Verify Repository Integrity

After cloning, verify the repository contains the expected commit history:

```bash
# Verify kernel version
head -5 Makefile
# Expected: VERSION = 7, PATCHLEVEL = 0, SUBLEVEL = 0, EXTRAVERSION = -rc3

# Verify Live Update commit count
git log --oneline -- kernel/liveupdate/ | wc -l
# Expected: 55 commits (as of v7.0.0-rc3 HEAD)

# Verify the first commit is reachable
git log --reverse --oneline -- kernel/liveupdate/ | head -1
# Expected: 48a1b2321d76 liveupdate: kho: move to kernel/liveupdate

# Verify core source files exist
ls kernel/liveupdate/luo_core.c kernel/liveupdate/kexec_handover.c
# Both files must exist

# Verify the subsystem has the expected file count
ls kernel/liveupdate/ | wc -l
# Expected: 11 files (Kconfig, Makefile, 5 .c files, 2 .h files, 2 debug .c files)
```

---

## 4. Understanding the Analysis Pipeline

### 4.1 The Eight Directives

The archaeological analysis is structured as 8 sequential directives, each
building on findings from prior directives. Directives 1–7 are implemented as
shell scripts that extract structured data from the git repository. Directive 8
is a Python orchestrator that synthesizes all findings into the narrative
document.

| Directive | Script | Purpose |
|---|---|---|
| 1 — Establish Feature Boundary | `manifest.sh` | Identifies ALL Live Update files by searching for `live_update`, `kho`, `kexec_handover`, `luo_`, and related Kconfig symbols. Outputs a TSV manifest with file path, first-commit date, and last-commit date per file. |
| 2 — Trace Authorship | `authorship.sh` | Runs `git log --follow --all` across the Directive 1 manifest. Aggregates per-author commit count, date range, and components touched. Extracts ≥5 dated milestones for the chronological timeline. |
| 3 — Reconstruct Design Decisions | `decisions.sh` | Searches commit messages and in-code comments for evidence of 4 specific design tradeoffs: FDT choice, callback registration, session-scoped cleanup, and token-based FD preservation. |
| 4 — Map State Machine Evolution | `statemachine.sh` | Tracks all commits modifying the session lifecycle flow in `luo_core.c`, `luo_session.c`, and `luo_file.c`. Classifies each as bug fix, feature, or refactor. Generates a text-based state diagram from current HEAD. |
| 5 — Identify Bottlenecks | `bottlenecks.sh` | Analyzes the commit timeline for inactivity periods >3 months, reverted commits, persistent TODO/FIXME/HACK comments across ≥3 commits, and incomplete components. |
| 6 — Catalog Bugs | `bugs.sh` | Searches for bug-related commit messages, scans current HEAD for TODO/FIXME/HACK/WARN_ON/BUG_ON markers, and pairs introduce-commit with fix-commit for resolved bugs. |
| 7 — Assess Integration | `integration.sh` | Maps integration points (KVM, memfd, drivers, networking, filesystem) by searching for cross-references. Classifies maturity as implemented, stubbed, designed, or absent. Documents the Kconfig dependency chain. |
| 8 — Compile Narrative | `analyze.py` | Python orchestrator that runs all 7 shell scripts, parses their TSV output, and synthesizes the final `archaeology.md` narrative with all 9 required sections and Mermaid diagrams. Verifies ≥2,000 word count. |

### 4.2 Data Flow

The pipeline follows a strict sequential dependency. Each script produces
structured TSV output on stdout (diagnostic logging goes to stderr). The
Python orchestrator consumes all intermediate outputs to generate the final
narrative.

```
┌─────────────────────────────────────────────────────────────┐
│                    Phase 1: Foundation                       │
│  manifest.sh ──────────────► authorship.sh                  │
│  (file boundary)              (authors + timeline)          │
└─────────────────────┬───────────────────┬───────────────────┘
                      │                   │
┌─────────────────────▼───────────────────▼───────────────────┐
│                  Phase 2: Deep Analysis                      │
│  decisions.sh    statemachine.sh    bottlenecks.sh           │
│  (4 tradeoffs)   (session lifecycle) (gaps + reverts)        │
│                                                              │
│  bugs.sh         integration.sh                              │
│  (resolved +     (KVM/memfd/drivers                          │
│   remaining)      maturity)                                  │
└─────────────────────────────┬───────────────────────────────┘
                              │
┌─────────────────────────────▼───────────────────────────────┐
│                   Phase 3: Synthesis                         │
│  analyze.py ──► Documentation/liveupdate/archaeology.md     │
│  (orchestrator)  (≥2,000 words, 9 sections, Mermaid)        │
└─────────────────────────────────────────────────────────────┘
```

All scripts are located in `tools/liveupdate/archaeology/`.

---

## 5. Running the Analysis

### 5.1 Script Execution Order

Scripts **must** be run in order because later directives depend on outputs
from earlier ones. Run all commands from the repository root directory.

```bash
# Ensure scripts are executable
chmod +x tools/liveupdate/archaeology/*.sh

# ── Phase 1: Foundation ──────────────────────────────────────

# Directive 1: Generate the file manifest
bash tools/liveupdate/archaeology/manifest.sh > /tmp/lu-manifest.tsv
echo "manifest.sh exit code: $?"

# Directive 2: Extract authorship and chronology
bash tools/liveupdate/archaeology/authorship.sh > /tmp/lu-authorship.tsv
echo "authorship.sh exit code: $?"

# ── Phase 2: Deep Analysis ───────────────────────────────────

# Directive 3: Reconstruct design decisions
bash tools/liveupdate/archaeology/decisions.sh > /tmp/lu-decisions.tsv
echo "decisions.sh exit code: $?"

# Directive 4: Map state machine evolution
bash tools/liveupdate/archaeology/statemachine.sh > /tmp/lu-statemachine.txt
echo "statemachine.sh exit code: $?"

# Directive 5: Identify development bottlenecks
bash tools/liveupdate/archaeology/bottlenecks.sh > /tmp/lu-bottlenecks.tsv
echo "bottlenecks.sh exit code: $?"

# Directive 6: Catalog bugs (resolved and remaining)
bash tools/liveupdate/archaeology/bugs.sh > /tmp/lu-bugs.tsv
echo "bugs.sh exit code: $?"

# Directive 7: Assess integration surface and maturity
bash tools/liveupdate/archaeology/integration.sh > /tmp/lu-integration.tsv
echo "integration.sh exit code: $?"

# ── Phase 3: Synthesis ───────────────────────────────────────

# Directive 8: Compile the archaeological narrative
python3 tools/liveupdate/archaeology/analyze.py
echo "analyze.py exit code: $?"
```

### 5.2 Expected Script Behavior

- **Each `.sh` script** outputs structured TSV data to **stdout** and emits
  diagnostic log messages to **stderr**. Redirect stdout to capture the data;
  stderr will show progress information.
- **`analyze.py`** reads intermediate outputs (either from `/tmp/lu-*.tsv`
  files or by invoking scripts directly), generates the `archaeology.md`
  narrative, and verifies the ≥2,000 word count before declaring success.
- **Exit codes**: All scripts must exit with code 0. A non-zero exit code
  indicates a failure that must be investigated before proceeding.

### 5.3 Estimated Runtime

On a machine with full git history available:

| Phase | Scripts | Expected Time |
|---|---|---|
| Phase 1 (Foundation) | `manifest.sh`, `authorship.sh` | ~30–60 seconds |
| Phase 2 (Deep Analysis) | 5 scripts | ~1–3 minutes |
| Phase 3 (Synthesis) | `analyze.py` | ~10–30 seconds |
| **Total** | | **~2–5 minutes** |

Runtime depends primarily on git log traversal speed, which varies with disk
I/O and repository size.

---

## 6. Expected Outputs and Verification

### 6.1 Deliverable Files

After a successful run, the following files should exist:

| File | Location | Verification |
|---|---|---|
| Primary Narrative | `Documentation/liveupdate/archaeology.md` | ≥2,000 words, 9 sections, Mermaid diagrams |
| Decision Log | `Documentation/liveupdate/decision-log.md` | Markdown table with Decision / Alternatives / Rationale / Risks |
| Executive Presentation | `Documentation/liveupdate/presentation.html` | Opens in browser, all reveal.js slides render, Mermaid diagrams visible |
| Onboarding Guide | `Documentation/liveupdate/onboarding.md` | This document |
| Observability Guide | `Documentation/liveupdate/observability.md` | Logging, metrics, and health check documentation |

### 6.2 Verification Checklist

Run these checks after the pipeline completes to confirm output integrity:

```bash
# 1. Verify archaeology.md exists and meets word count
wc -w Documentation/liveupdate/archaeology.md
# Expected: ≥ 2,000 words

# 2. Verify 9 sections exist (count level-2 headings)
grep -c '^## ' Documentation/liveupdate/archaeology.md
# Expected: 9

# 3. Verify Mermaid diagrams are present (≥4 required)
grep -c '```mermaid' Documentation/liveupdate/archaeology.md
# Expected: ≥ 4

# 4. Verify commit hashes are valid
grep -oE '[0-9a-f]{12}' Documentation/liveupdate/archaeology.md | sort -u | while read hash; do
    if ! git log --oneline -1 "$hash" >/dev/null 2>&1; then
        echo "INVALID HASH: $hash"
    fi
done
# Expected: no output (all hashes valid)

# 5. Verify presentation.html is well-formed
python3 -c "
import html.parser
p = html.parser.HTMLParser()
with open('Documentation/liveupdate/presentation.html') as f:
    p.feed(f.read())
print('HTML parsed successfully')
"

# 6. Verify decision-log.md has the table structure
grep -c '|' Documentation/liveupdate/decision-log.md
# Expected: ≥ 30 (header rows + data rows for 8+ decisions)
```

---

## 7. Common Pitfalls

### 7.1 Shallow Clones (Most Common Failure)

**Symptom**: Scripts produce fewer results than expected — fewer commits,
fewer authors, incomplete timelines.

**Cause**: `git clone --depth=N` truncates commit history.

**Fix**:
```bash
git fetch --unshallow
```

**Detection**:
```bash
git rev-parse --is-shallow-repository
# "true" means you have a shallow clone — analysis will be incomplete
```

### 7.2 Wrong Branch or Tag

**Symptom**: Commit counts or file contents do not match expected values.

**Cause**: The analysis was developed against v7.0.0-rc3. A different HEAD
produces different commit counts and may reference commits that do not exist.

**Fix**:
```bash
git checkout v7.0.0-rc3
```

**Detection**:
```bash
head -4 Makefile | grep -E 'VERSION|PATCHLEVEL|SUBLEVEL|EXTRAVERSION'
# Expected: VERSION=7, PATCHLEVEL=0, SUBLEVEL=0, EXTRAVERSION=-rc3
```

### 7.3 Missing Git History for Renamed Files

**Symptom**: `manifest.sh` reports a first-commit date that is too recent
for files that were renamed or moved.

**Cause**: `git log --follow` requires full history to track renames. The
KHO code was moved from its original location to `kernel/liveupdate/` in
commit `48a1b2321d76` (2025-11-01 "liveupdate: kho: move to
kernel/liveupdate"). Without full history, the rename chain is broken.

**Fix**: Ensure full clone (see §7.1).

### 7.4 Script Permissions

**Symptom**: `bash: permission denied` when running scripts.

**Fix**:
```bash
chmod +x tools/liveupdate/archaeology/*.sh
```

### 7.5 Python Version

**Symptom**: `SyntaxError` on f-strings or `ModuleNotFoundError` for
`pathlib`.

**Cause**: Python 2.x or Python < 3.6 is being used.

**Fix**: Explicitly invoke `python3`:
```bash
python3 tools/liveupdate/archaeology/analyze.py
```

**Detection**:
```bash
python3 --version
# Must be ≥ 3.6
```

### 7.6 Working Directory

**Symptom**: Scripts fail to find files or produce empty output.

**Cause**: Some scripts expect to be run from the repository root so that
relative paths like `kernel/liveupdate/` resolve correctly.

**Fix**: Always run from the repository root:
```bash
cd /path/to/linux
bash tools/liveupdate/archaeology/manifest.sh
```

Or if running from within the script directory, verify the scripts handle
path resolution correctly (check each script's header comments for working
directory requirements).

---

## 8. Domain Context

### 8.1 What is Live Update?

Live Update is a mechanism for replacing a running Linux kernel with a new
version via kexec while **preserving selected resources** across the
transition. Unlike a standard reboot, designated hardware devices may
continue DMA activity throughout the kernel transition, and userspace state
(such as memfd-backed memory regions) can be restored immediately in the
new kernel.

The subsystem consists of two major layers:

- **Live Update Orchestrator (LUO)**: The coordination framework in
  `kernel/liveupdate/`. Manages named sessions, file descriptor preservation
  via a token-based ioctl API (`/dev/liveupdate`), File-Lifecycle-Bound (FLB)
  global data, and the overall freeze/serialize/kexec/deserialize/retrieve
  lifecycle. Primary source: `luo_core.c` (copyright Google LLC 2025, authored
  by Pasha Tatashin).

- **Kexec HandOver (KHO)**: The memory preservation layer in
  `kernel/liveupdate/kexec_handover.c`. Uses bitmap-tracked page/folio
  handover with Flattened Device Tree (FDT) serialization and CMA-backed
  scratch regions. Original concept by Alexander Graf (Amazon, copyright 2023),
  with significant contributions from Mike Rapoport (Microsoft) and
  Changyuan Lyu (Google).

### 8.2 Primary Use Case

The primary target use case is **VM-transparent hypervisor updates** in cloud
environments — updating the host kernel while virtual machines continue running
with minimal disruption. This is stated explicitly in the LUO Kconfig help text
(`kernel/liveupdate/Kconfig` lines 69–71): the feature "primarily targets
virtual machine hosts to quickly update the kernel hypervisor with minimal
disruption to the running virtual machines."

However, the framework is designed to be workload-agnostic. The `luo_core.c`
DOC comment (lines 22–25) describes a non-hypervisor example: an in-memory
cache like memcached with gigabytes of data preserved via memfd across a
kernel update.

### 8.3 Current Development Status

As of kernel v7.0.0-rc3, the Live Update subsystem is **in active
development** and not yet a stable feature:

- **Architecture support**: `ARCH_SUPPORTS_KEXEC_HANDOVER` is defined for
  both x86 (`arch/x86/Kconfig:2020`) and arm64 (`arch/arm64/Kconfig:1621`).
  However, architecture-specific integration code (KASLR avoidance, E820
  handling, kexec boot parameter attachment, scratch region management) exists
  only for x86 (6 files in `arch/x86/`). arm64 has the Kconfig gate but no
  corresponding boot integration code.
- **File handlers**: Only one concrete file handler exists — memfd
  preservation (`mm/memfd_luo.c`, 523 lines, registered as `"memfd-v1"`).
- **KVM integration**: Despite being the primary use case, no KVM-specific
  live update code exists. `luo_core.c` line 34 lists "kvm" as an example
  future subsystem participant, but no KVM handler is registered.
- **Known technical debt**: One FIXME persists at
  `kernel/liveupdate/kexec_handover.c:657` — NUMA node hot-plug/remove
  handling is not implemented for KHO scratch regions.

### 8.4 Existing Kernel Documentation

For deeper understanding of the Live Update subsystem, consult these in-tree
documentation files:

| Document | Path | Content |
|---|---|---|
| LUO Core API | `Documentation/core-api/liveupdate.rst` | Sessions, file preservation, FLB, public and internal API references (authored by Pasha Tatashin) |
| KHO Subsystem Overview | `Documentation/core-api/kho/index.rst` | FDT format, scratch regions, finalization phase |
| KHO ABI Specification | `Documentation/core-api/kho/abi.rst` | FDT structure, vmalloc preservation ABI |
| KHO Usage Guide | `Documentation/admin-guide/mm/kho.rst` | Prerequisites, `kho=on` parameter, kexec workflow, debugfs interfaces |
| Userspace ioctl API | `Documentation/userspace-api/liveupdate.rst` | `/dev/liveupdate` ioctl commands (CREATE_SESSION, PRESERVE_FD, RETRIEVE_FD, FINISH) |
| Memfd Preservation | `Documentation/mm/memfd_preservation.rst` | Memfd-backed memory preservation via LUO |

### 8.5 Key Source Files

| File | Lines | Purpose |
|---|---|---|
| `kernel/liveupdate/luo_core.c` | 452 | LUO core — `/dev/liveupdate` misc device, ioctl dispatch, `liveupdate_reboot()`, `liveupdate_enabled()` |
| `kernel/liveupdate/luo_session.c` | 646 | Session management — create, retrieve, serialize, deserialize, quiesce/resume |
| `kernel/liveupdate/luo_file.c` | 926 | File handler registration — preserve, freeze, unfreeze, retrieve, finish lifecycle |
| `kernel/liveupdate/luo_flb.c` | 654 | File-Lifecycle-Bound global data — shared objects across sessions |
| `kernel/liveupdate/kexec_handover.c` | 1610 | KHO core — bitmap-tracked page preservation, FDT assembly, scratch regions |
| `mm/memfd_luo.c` | 523 | Memfd handler — the only concrete file handler implementation |
| `include/linux/liveupdate.h` | — | Public LUO API — handler structs, registration functions |
| `include/uapi/linux/liveupdate.h` | — | Userspace ioctl definitions — session/FD ioctls, token struct |
| `include/linux/kexec_handover.h` | — | Public KHO API — folio/page preservation, vmalloc, subtree management |

---

## 9. How to Extend the Analysis

### 9.1 Adding New Files to the Manifest

When new source files are added to the Live Update subsystem, update the
search patterns in `tools/liveupdate/archaeology/manifest.sh`. The script
discovers files by searching for patterns like `live_update`, `kho`,
`kexec_handover`, `luo_`, `LIVEUPDATE`, and `KEXEC_HANDOVER`. To include
files from a new subsystem (e.g., a KVM handler), add the appropriate grep
pattern to the manifest discovery section.

### 9.2 Tracking Additional Design Decisions

To add new design tradeoff analysis, update the keyword patterns in
`tools/liveupdate/archaeology/decisions.sh`. Each design decision search
consists of a set of keywords applied to commit messages and in-code
comments. Add new entries following the existing pattern for each of the
4 original tradeoffs.

### 9.3 Adding Architecture Support

When additional architectures enable `ARCH_SUPPORTS_KEXEC_HANDOVER` (arm64
already has the Kconfig gate at `arch/arm64/Kconfig:1621` but lacks boot
integration code), update `tools/liveupdate/archaeology/integration.sh` to
search for architecture-specific integration files in the new `arch/<arch>/`
directory.

### 9.4 Updating for New File Handlers

As new file handlers are registered with LUO (e.g., KVM, VFIO, iommufd),
update the integration maturity classification in
`tools/liveupdate/archaeology/integration.sh`. Each handler should be
classified as implemented, stubbed, designed, or absent based on the code
presence analysis. The `analyze.py` orchestrator will automatically include
the updated classification in the Integration Maturity Matrix section.

### 9.5 Updating the Narrative for New Kernel Versions

When analyzing a newer kernel version:

1. Update the expected commit count in this onboarding document and in the
   verification checks (currently 55 commits in `kernel/liveupdate/`).
2. Re-run the full pipeline — it will automatically pick up new commits,
   authors, and file changes.
3. Review the generated `archaeology.md` for accuracy against the new HEAD.
4. Update the `presentation.html` metrics if significant changes occurred.

---

## 10. Suggested Next Tasks

The following tasks were identified during the archaeological analysis of the
Live Update subsystem. Each is grounded in specific in-tree evidence:

### 10.1 Implement KVM File Handler

The primary use case for Live Update — VM-transparent hypervisor updates — has
**no KVM-specific code** in the subsystem. `luo_core.c` (line 34) lists "kvm"
as an example future subsystem participant, and `kernel/liveupdate/Kconfig`
(lines 69–71) describes the VM host use case, but no KVM handler is registered
with `liveupdate_register_file_handler()`. This is the highest-impact
development task.

### 10.2 Address FIXME — NUMA Node Hot-Plug

The sole FIXME in the subsystem at `kernel/liveupdate/kexec_handover.c:657`
reads: `/* FIXME: deal with node hot-plug/remove */`. The current code
allocates KHO scratch regions based on a static count of NUMA nodes at
init time (`nodes_weight(node_states[N_MEMORY]) + 2`). If nodes are
hot-plugged or removed after initialization, scratch region allocation will
be incorrect.

### 10.3 Complete arm64 Architecture Integration

`ARCH_SUPPORTS_KEXEC_HANDOVER` is already defined as `def_bool y` in
`arch/arm64/Kconfig:1621`, meaning arm64 kernels can enable
`CONFIG_KEXEC_HANDOVER`. However, no arm64-specific boot integration code
exists — there are no equivalents to the x86 KASLR avoidance
(`arch/x86/boot/compressed/kaslr.c`), E820 integration
(`arch/x86/kernel/e820.c`), setup data passing
(`arch/x86/kernel/setup.c`), or kexec boot parameter attachment
(`arch/x86/kernel/kexec-bzimage64.c`). Completing the arm64 integration
would enable Live Update on ARM-based cloud servers.

### 10.4 Implement Device Driver Handlers

Beyond memfd, the framework needs handlers for device passthrough scenarios:
- **VFIO**: For passing through physical devices to VMs and preserving
  that mapping across kernel updates.
- **iommufd**: For preserving IOMMU configuration across kexec.
- **Interrupt controllers**: For maintaining interrupt routing.

These are listed as example subsystems in `luo_core.c` (line 34) but have
no implementation.

### 10.5 Extend Analysis with Mailing List Evidence

The current archaeological analysis is limited to in-tree evidence per AAP
§0.7.2. Several design decisions have rationale "not recorded in-tree" that
may be documented in linux-kernel mailing list discussions (lore.kernel.org).
A follow-up analysis could correlate LKML patch series cover letters with
commit hashes to fill rationale gaps.

---

## Appendix A: Kconfig Dependency Chain

The complete Kconfig dependency tree for enabling the full Live Update
subsystem, as documented in `kernel/liveupdate/Kconfig`:

```
LIVEUPDATE
├── depends on: KEXEC_HANDOVER
│   ├── depends on: ARCH_SUPPORTS_KEXEC_HANDOVER
│   │   ├── x86:   arch/x86/Kconfig:2020 (def_bool y, with full boot integration)
│   │   └── arm64: arch/arm64/Kconfig:1621 (def_bool y, no boot integration code)
│   ├── depends on: ARCH_SUPPORTS_KEXEC_FILE
│   ├── depends on: !DEFERRED_STRUCT_PAGE_INIT
│   ├── select: MEMBLOCK_KHO_SCRATCH (mm/Kconfig)
│   ├── select: KEXEC_FILE
│   ├── select: LIBFDT
│   └── select: CMA
│
├── KEXEC_HANDOVER_DEBUG (optional)
│   └── depends on: KEXEC_HANDOVER
│
├── KEXEC_HANDOVER_DEBUGFS (optional, default y)
│   ├── depends on: KEXEC_HANDOVER
│   └── select: DEBUG_FS
│
├── KEXEC_HANDOVER_ENABLE_DEFAULT (optional)
│   └── depends on: KEXEC_HANDOVER
│
├── LIVEUPDATE_MEMFD (optional, default LIVEUPDATE)
│   ├── depends on: LIVEUPDATE
│   ├── depends on: MEMFD_CREATE
│   └── depends on: SHMEM
│
└── LIVEUPDATE_TEST (optional, debug only)
    └── depends on: LIVEUPDATE
```

**Required kernel config for selftests** (`tools/testing/selftests/liveupdate/config`):

```
CONFIG_BLK_DEV_INITRD=y
CONFIG_KEXEC_FILE=y
CONFIG_KEXEC_HANDOVER=y
CONFIG_KEXEC_HANDOVER_ENABLE_DEFAULT=y
CONFIG_KEXEC_HANDOVER_DEBUGFS=y
CONFIG_KEXEC_HANDOVER_DEBUG=y
CONFIG_LIVEUPDATE=y
CONFIG_LIVEUPDATE_TEST=y
CONFIG_MEMFD_CREATE=y
CONFIG_TMPFS=y
CONFIG_SHMEM=y
```

---

## Appendix B: Repository File Inventory

The Live Update subsystem spans the following directories. This inventory
is the input for the archaeological analysis manifest (Directive 1).

| Directory | Files | Content |
|---|---|---|
| `kernel/liveupdate/` | 11 | Core LUO + KHO source, Kconfig, Makefile, internal headers |
| `include/linux/` | 2 | `liveupdate.h`, `kexec_handover.h` — public API headers |
| `include/uapi/linux/` | 1 | `liveupdate.h` — userspace ioctl API |
| `include/linux/kho/abi/` | 4 | `kexec_handover.h`, `luo.h`, `memblock.h`, `memfd.h` — ABI definitions |
| `mm/` | 5 | `memfd_luo.c`, `memblock.c`, `mm_init.c`, `Kconfig`, `Makefile` |
| `arch/x86/` | 7 | Boot integration: KASLR, E820, setup, kexec, realmode |
| `drivers/firmware/efi/` | 1 | `efi-init.c` — EFI KHO memblock discovery |
| `lib/` | 4 | `test_kho.c`, `tests/liveupdate.c`, `Kconfig.debug`, `tests/Makefile` |
| `tools/testing/selftests/liveupdate/` | 8+ | Userspace selftests: `liveupdate.c`, `luo_kexec_simple.c`, `luo_multi_session.c`, utilities |
| `Documentation/` | 6 | RST documentation for LUO API, KHO, memfd, userspace API |
