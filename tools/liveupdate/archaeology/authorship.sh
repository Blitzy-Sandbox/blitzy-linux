#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# authorship.sh — Directive 2: Trace Authorship and Chronology
#
# Runs git log across all Live Update subsystem files, aggregates
# per-author statistics (commit count, date range, components touched),
# identifies the original feature author and initial commit hash, and
# builds a chronological timeline of >=5 dated milestones.
#
# Two-tier path classification:
#   - EXCLUSIVE paths: files that exist solely for Live Update / KHO.
#     All commits touching these files are counted.
#   - SHARED paths: integration files (memblock.c, arch/x86, EFI) that
#     serve broader purposes.  Only commits whose message references
#     kho, kexec_handover, or liveupdate are counted.
#
# Output format (TSV to stdout):
#   Section 1 — Authors (one row per author, sorted by commit count desc):
#     author	email	commit_count	first_date	last_date	components
#
#   --- (section separator)
#
#   Section 2 — Milestones (chronological order):
#     date	milestone_name	commit_hash	author	description
#
# Structured logs are emitted to stderr in the format:
#   [LU-ARCH-D2-<timestamp>] [<level>] <message>
#
# Pass/Fail Criterion (Directive 2):
#   >= 5 dated milestones with commit hash evidence.
#
# Usage:
#   cd <kernel-repo-root>
#   bash tools/liveupdate/archaeology/authorship.sh
#   # TSV goes to stdout; logs go to stderr.

set -euo pipefail

# ===========================================================================
# Observability: correlation ID and structured logging
# ===========================================================================
readonly CORR_ID="LU-ARCH-D2-$(date -u +%Y%m%dT%H%M%S)"
readonly TAB=$'\t'

log() {
	local level="$1"
	shift
	echo "[$CORR_ID] [$(date -u +%Y-%m-%dT%H:%M:%SZ)] [$level] $*" >&2
}

# ===========================================================================
# Repository root detection
# ===========================================================================
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
	log "ERROR" "Not inside a git repository.  Run from the kernel tree root."
	exit 1
}
cd "$REPO_ROOT"
log "INFO" "Repository root: $REPO_ROOT"
log "INFO" "Starting Directive 2 — Trace Authorship and Chronology"

# ===========================================================================
# MANIFEST_PATHS — split into exclusive and shared categories.
#
# EXCLUSIVE_PATHS: files that exist only for Live Update / KHO.
# Every commit touching these files is relevant to the feature.
#
# SHARED_PATHS: integration files that serve broader subsystems
# (memblock, x86 boot, EFI).  Only commits with KHO/LU-related
# subject lines are counted to avoid polluting authorship data
# with thousands of unrelated commits.
# ===========================================================================
EXCLUSIVE_PATHS=(
	"kernel/liveupdate/"
	"include/linux/liveupdate.h"
	"include/uapi/linux/liveupdate.h"
	"include/linux/kexec_handover.h"
	"include/linux/kho/"
	"mm/memfd_luo.c"
	"lib/test_kho.c"
	"lib/tests/liveupdate.c"
	"tools/testing/selftests/liveupdate/"
)

SHARED_PATHS=(
	"mm/memblock.c"
	"mm/mm_init.c"
	"arch/x86/boot/compressed/kaslr.c"
	"arch/x86/kernel/e820.c"
	"arch/x86/kernel/kexec-bzimage64.c"
	"arch/x86/kernel/setup.c"
	"arch/x86/realmode/init.c"
	"drivers/firmware/efi/efi-init.c"
)

# Combined for milestone extraction (uses --grep filtering when needed)
MANIFEST_PATHS=( "${EXCLUSIVE_PATHS[@]}" "${SHARED_PATHS[@]}" )

# Grep pattern for filtering shared-path commits to KHO/LU-relevant only
readonly LU_GREP_PATTERN="kho\|kexec_handover\|liveupdate\|live.update\|KHO\|KEXEC_HANDOVER\|LIVEUPDATE\|memblock_mark_kho\|kho_scratch\|SETUP_KEXEC_KHO"

# ===========================================================================
# Helper: map a file path to its component name
# ===========================================================================
map_component() {
	local filepath="$1"
	case "$filepath" in
		kernel/liveupdate/luo_core.c|kernel/liveupdate/luo_session.c|kernel/liveupdate/luo_internal.h)
			echo "LUO"
			;;
		kernel/liveupdate/luo_file.c)
			echo "LUO"
			;;
		kernel/liveupdate/luo_flb.c)
			echo "LUO"
			;;
		kernel/liveupdate/kexec_handover.c|kernel/liveupdate/kexec_handover_debug.c)
			echo "KHO"
			;;
		kernel/liveupdate/kexec_handover_debugfs.c|kernel/liveupdate/kexec_handover_internal.h)
			echo "KHO"
			;;
		kernel/liveupdate/Kconfig|kernel/liveupdate/Makefile)
			echo "KHO"
			;;
		include/linux/kho/*)
			echo "KHO-ABI"
			;;
		include/linux/liveupdate.h|include/uapi/linux/liveupdate.h)
			echo "API"
			;;
		include/linux/kexec_handover.h)
			echo "API"
			;;
		mm/memfd_luo*)
			echo "Memfd"
			;;
		mm/memblock*|mm/mm_init*)
			echo "Memblock"
			;;
		arch/x86/*)
			echo "x86"
			;;
		drivers/*)
			echo "EFI"
			;;
		lib/test_kho*|lib/tests/liveupdate*|lib/Kconfig.debug|lib/tests/Makefile)
			echo "Tests"
			;;
		tools/testing/selftests/liveupdate/*)
			echo "Selftests"
			;;
		*)
			echo "Other"
			;;
	esac
}

# ===========================================================================
# Helper: add a component to an author's component set (space-delimited)
# Globals: author_components (associative array)
# ===========================================================================
add_component() {
	local aname="$1"
	local comp="$2"
	if [[ -z "${author_components["$aname"]:-}" ]]; then
		author_components["$aname"]="$comp"
	else
		case " ${author_components["$aname"]} " in
			*" $comp "*)
				;;
			*)
				author_components["$aname"]="${author_components["$aname"]} $comp"
				;;
		esac
	fi
}

# ===========================================================================
# Helper: process a single commit line and update author aggregation arrays
# Format: author_name<TAB>author_email<TAB>author_date_iso<TAB>commit_hash
# ===========================================================================
process_commit() {
	local aname="$1"
	local aemail="$2"
	local adate="$3"
	local ahash="$4"
	local path_list="$5"

	# Increment commit count
	author_count["$aname"]=$(( ${author_count["$aname"]:-0} + 1 ))

	# Store email (last seen wins)
	author_email["$aname"]="$aemail"

	# Track earliest date
	if [[ -z "${author_first["$aname"]:-}" ]] || [[ "$adate" < "${author_first["$aname"]}" ]]; then
		author_first["$aname"]="$adate"
	fi

	# Track latest date
	if [[ -z "${author_last["$aname"]:-}" ]] || [[ "$adate" > "${author_last["$aname"]}" ]]; then
		author_last["$aname"]="$adate"
	fi

	# Map files to components using the provided path list
	local IFS=$'\n'
	for fpath in $path_list; do
		if [[ -n "$fpath" ]]; then
			local comp
			comp="$(map_component "$fpath")"
			add_component "$aname" "$comp"
		fi
	done
}

# ===========================================================================
# PHASE 1: Extract commits from EXCLUSIVE paths (all commits relevant)
# ===========================================================================
log "INFO" "Phase 1a: Extracting commits from ${#EXCLUSIVE_PATHS[@]} exclusive paths"

declare -A author_count
declare -A author_first
declare -A author_last
declare -A author_email
declare -A author_components
declare -A seen_hash

total_commits=0
exclusive_commits=0

while IFS=$'\t' read -r aname aemail adate ahash; do
	if [[ -z "$aname" || -z "$ahash" ]]; then
		continue
	fi

	# Deduplicate commits (same hash may appear from multiple branches)
	if [[ -n "${seen_hash["$ahash"]:-}" ]]; then
		continue
	fi
	seen_hash["$ahash"]=1

	# Get files changed in this commit that match exclusive paths
	file_list="$(git diff-tree --no-commit-id --name-only -r "$ahash" -- "${EXCLUSIVE_PATHS[@]}" 2>/dev/null)"
	if [[ -z "$file_list" ]]; then
		continue
	fi

	process_commit "$aname" "$aemail" "$adate" "$ahash" "$file_list"
	total_commits=$((total_commits + 1))
	exclusive_commits=$((exclusive_commits + 1))
done < <(git log --all --format="%an%x09%ae%x09%aI%x09%H" -- "${EXCLUSIVE_PATHS[@]}" 2>/dev/null)

log "INFO" "Phase 1a complete: $exclusive_commits commits from exclusive paths"

# ===========================================================================
# PHASE 1b: Extract KHO/LU-related commits from SHARED paths
# ===========================================================================
log "INFO" "Phase 1b: Extracting KHO/LU-related commits from ${#SHARED_PATHS[@]} shared paths"

shared_commits=0

while IFS=$'\t' read -r aname aemail adate ahash; do
	if [[ -z "$aname" || -z "$ahash" ]]; then
		continue
	fi

	# Deduplicate
	if [[ -n "${seen_hash["$ahash"]:-}" ]]; then
		continue
	fi
	seen_hash["$ahash"]=1

	# Get files changed in this commit matching shared paths
	file_list="$(git diff-tree --no-commit-id --name-only -r "$ahash" -- "${SHARED_PATHS[@]}" 2>/dev/null)"
	if [[ -z "$file_list" ]]; then
		continue
	fi

	process_commit "$aname" "$aemail" "$adate" "$ahash" "$file_list"
	total_commits=$((total_commits + 1))
	shared_commits=$((shared_commits + 1))
done < <(git log --all --format="%an%x09%ae%x09%aI%x09%H" --grep="$LU_GREP_PATTERN" -- "${SHARED_PATHS[@]}" 2>/dev/null)

log "INFO" "Phase 1b complete: $shared_commits commits from shared paths (filtered by KHO/LU keywords)"

# Count unique authors via wc for cross-verification with associative array size
unique_authors_wc="$(printf '%s\n' "${!author_count[@]}" | wc -l)"
unique_authors="${#author_count[@]}"
if (( unique_authors != unique_authors_wc )); then
	log "WARN" "Author count mismatch: array=${unique_authors} vs wc=${unique_authors_wc}"
fi
log "INFO" "Found $unique_authors unique authors across $total_commits total commits"

# ===========================================================================
# PHASE 2: Output Section 1 — Authors table (TSV, sorted by commit count)
# ===========================================================================
log "INFO" "Phase 2: Generating authors table (sorted by commit count descending)"

printf '%s\t%s\t%s\t%s\t%s\t%s\n' "author" "email" "commit_count" "first_date" "last_date" "components"

# Build sortable lines: commit_count<TAB>author_name<TAB>email<TAB>count<TAB>first<TAB>last<TAB>comps
declare -a author_lines=()

for aname in "${!author_count[@]}"; do
	cnt="${author_count[$aname]}"
	email="${author_email[$aname]}"
	first="${author_first[$aname]}"
	last="${author_last[$aname]}"
	comps="$(echo "${author_components[$aname]:-Other}" | tr ' ' '\n' | sort -u | tr '\n' ',' | sed 's/,$//')"
	author_lines+=("${cnt}${TAB}${aname}${TAB}${email}${TAB}${cnt}${TAB}${first}${TAB}${last}${TAB}${comps}")
done

# Sort by first field (commit count) descending, then emit fields 2+.
# Use process substitution to avoid SIGPIPE with set -o pipefail.
while IFS=$'\t' read -r _sortkey aname email cnt first last comps; do
	printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$aname" "$email" "$cnt" "$first" "$last" "$comps"
done < <(printf '%s\n' "${author_lines[@]}" | sort -t$'\t' -k1,1 -rn)

# ===========================================================================
# PHASE 3: Original Feature Author Identification
# ===========================================================================
log "INFO" "Phase 3: Identifying original feature author"

# Find the chronologically earliest commit touching any exclusive manifest path.
# Note: || true suppresses SIGPIPE (exit 141) caused by head closing the pipe
# while git log is still writing, which set -o pipefail would otherwise propagate.
first_commit_line="$(git log --all --reverse --format="%H%x09%an%x09%aI%x09%s" -- "${EXCLUSIVE_PATHS[@]}" 2>/dev/null | head -1)" || true

if [[ -n "$first_commit_line" ]]; then
	first_hash="$(echo "$first_commit_line" | cut -f1)"
	first_author="$(echo "$first_commit_line" | cut -f2)"
	first_date="$(echo "$first_commit_line" | cut -f3)"
	first_subject="$(echo "$first_commit_line" | cut -f4)"
	log "INFO" "Original feature author: $first_author at $first_date (commit: $first_hash)"
	log "INFO" "First commit subject: $first_subject"
else
	log "WARN" "No commits found touching exclusive manifest paths"
	first_hash="N/A"
	first_author="N/A"
	first_date="N/A"
fi

# Extract copyright holders from key source files for additional context
log "INFO" "Extracting copyright holders from key source files"
while IFS= read -r copyright_line; do
	log "INFO" "Copyright: $copyright_line"
done < <(grep -h "Copyright" kernel/liveupdate/kexec_handover.c kernel/liveupdate/luo_core.c mm/memfd_luo.c 2>/dev/null | sed 's/^[[:space:]]*\*[[:space:]]*//' | sort -u)

# ===========================================================================
# PHASE 4: Milestone Extraction — Section 2
# ===========================================================================
log "INFO" "Phase 4: Extracting chronological milestones"

# Section separator
echo "---"

printf '%s\t%s\t%s\t%s\t%s\n' "date" "milestone_name" "commit_hash" "author" "description"

milestone_count=0
declare -a milestone_rows=()

# Helper: buffer a milestone row for later sorted output and increment counter.
emit_milestone() {
	local mdate="$1"
	local mname="$2"
	local mhash="$3"
	local mauthor="$4"
	local mdesc="$5"

	if [[ -z "$mdate" || -z "$mhash" ]]; then
		return 0
	fi

	milestone_rows+=("${mdate}${TAB}${mname}${TAB}${mhash}${TAB}${mauthor}${TAB}${mdesc}")
	milestone_count=$((milestone_count + 1))
	log "INFO" "Milestone $milestone_count: $mname ($mdate) by $mauthor [$mhash]"
}

# Helper: extract fields from a git log line (tab-separated: date hash author subject)
parse_milestone_line() {
	local line="$1"
	m_date="$(echo "$line" | cut -f1)"
	m_hash="$(echo "$line" | cut -f2)"
	m_author="$(echo "$line" | cut -f3)"
	m_desc="$(echo "$line" | cut -f4)"
}

# -----------------------------------------------------------------------
# Milestone 1: KHO Foundation — first commit introducing KHO
# The earliest commit touching include/linux/kexec_handover.h is the
# original KHO helper generation by Alexander Graf.
# -----------------------------------------------------------------------
# All milestone pipelines use || true to suppress SIGPIPE (exit 141) caused
# by head/tail closing the pipe while git log is still writing output.
# With set -o pipefail, SIGPIPE would otherwise terminate the script.

line="$(git log --all --reverse --format="%aI%x09%H%x09%an%x09%s" \
	-- include/linux/kexec_handover.h kernel/liveupdate/kexec_handover.c \
	2>/dev/null | head -1)" || true
if [[ -n "$line" ]]; then
	parse_milestone_line "$line"
	emit_milestone "$m_date" "KHO_Foundation" "$m_hash" "$m_author" "$m_desc"
fi

# -----------------------------------------------------------------------
# Milestone 2: KHO Memory Preservation — page-level preservation enabled
# Third commit in the kexec_handover.h timeline (Mike Rapoport).
# -----------------------------------------------------------------------
line="$(git log --all --reverse --format="%aI%x09%H%x09%an%x09%s" \
	-- include/linux/kexec_handover.h \
	2>/dev/null | head -3 | tail -1)" || true
if [[ -n "$line" ]]; then
	parse_milestone_line "$line"
	emit_milestone "$m_date" "KHO_Memory_Preservation" "$m_hash" "$m_author" "$m_desc"
fi

# -----------------------------------------------------------------------
# Milestone 3: KHO Test Infrastructure — first test module
# -----------------------------------------------------------------------
line="$(git log --all --reverse --format="%aI%x09%H%x09%an%x09%s" \
	-- lib/test_kho.c \
	2>/dev/null | head -1)" || true
if [[ -n "$line" ]]; then
	parse_milestone_line "$line"
	emit_milestone "$m_date" "KHO_Test_Infrastructure" "$m_hash" "$m_author" "$m_desc"
fi

# -----------------------------------------------------------------------
# Milestone 4: is_kho_boot() — runtime KHO boot detection
# -----------------------------------------------------------------------
line="$(git log --all --format="%aI%x09%H%x09%an%x09%s" \
	--grep="is_kho_boot" -- \
	2>/dev/null | sort -t$'\t' -k1,1 | head -1)" || true
if [[ -n "$line" ]]; then
	parse_milestone_line "$line"
	emit_milestone "$m_date" "is_kho_boot_Introduced" "$m_hash" "$m_author" "$m_desc"
fi

# -----------------------------------------------------------------------
# Milestone 5: KHO API Rework — page API replacement with folio API
# -----------------------------------------------------------------------
line="$(git log --all --format="%aI%x09%H%x09%an%x09%s" \
	--grep="replace.*kho_preserve\|kho.*replace" \
	-- include/linux/kexec_handover.h kernel/liveupdate/kexec_handover.c \
	2>/dev/null | sort -t$'\t' -k1,1 | head -1)" || true
if [[ -n "$line" ]]; then
	parse_milestone_line "$line"
	emit_milestone "$m_date" "KHO_API_Rework" "$m_hash" "$m_author" "$m_desc"
fi

# -----------------------------------------------------------------------
# Milestone 6: KHO Move to kernel/liveupdate/ — directory restructure
# -----------------------------------------------------------------------
line="$(git log --all --format="%aI%x09%H%x09%an%x09%s" \
	--grep="move to kernel/liveupdate" \
	-- kernel/liveupdate/ \
	2>/dev/null | sort -t$'\t' -k1,1 | head -1)" || true
if [[ -n "$line" ]]; then
	parse_milestone_line "$line"
	emit_milestone "$m_date" "KHO_Move_To_Liveupdate" "$m_hash" "$m_author" "$m_desc"
fi

# -----------------------------------------------------------------------
# Milestone 7: LUO Core Introduction — Live Update Orchestrator
# -----------------------------------------------------------------------
line="$(git log --all --reverse --format="%aI%x09%H%x09%an%x09%s" \
	-- kernel/liveupdate/luo_core.c \
	2>/dev/null | head -1)" || true
if [[ -n "$line" ]]; then
	parse_milestone_line "$line"
	emit_milestone "$m_date" "LUO_Core_Introduction" "$m_hash" "$m_author" "$m_desc"
fi

# -----------------------------------------------------------------------
# Milestone 8: LUO File Preservation — file handler callbacks
# -----------------------------------------------------------------------
line="$(git log --all --reverse --format="%aI%x09%H%x09%an%x09%s" \
	-- kernel/liveupdate/luo_file.c \
	2>/dev/null | head -1)" || true
if [[ -n "$line" ]]; then
	parse_milestone_line "$line"
	emit_milestone "$m_date" "LUO_File_Preservation" "$m_hash" "$m_author" "$m_desc"
fi

# -----------------------------------------------------------------------
# Milestone 9: Memfd Preservation — first concrete file handler
# -----------------------------------------------------------------------
line="$(git log --all --reverse --format="%aI%x09%H%x09%an%x09%s" \
	-- mm/memfd_luo.c \
	2>/dev/null | head -1)" || true
if [[ -n "$line" ]]; then
	parse_milestone_line "$line"
	emit_milestone "$m_date" "Memfd_Preservation" "$m_hash" "$m_author" "$m_desc"
fi

# -----------------------------------------------------------------------
# Milestone 10: Userspace Selftests — test infrastructure for userspace API
# -----------------------------------------------------------------------
line="$(git log --all --reverse --format="%aI%x09%H%x09%an%x09%s" \
	-- tools/testing/selftests/liveupdate/ \
	2>/dev/null | head -1)" || true
if [[ -n "$line" ]]; then
	parse_milestone_line "$line"
	emit_milestone "$m_date" "Userspace_Selftests" "$m_hash" "$m_author" "$m_desc"
fi

# -----------------------------------------------------------------------
# Milestone 11: FLB Introduction — File-Lifecycle-Bound global state
# -----------------------------------------------------------------------
line="$(git log --all --reverse --format="%aI%x09%H%x09%an%x09%s" \
	-- kernel/liveupdate/luo_flb.c \
	2>/dev/null | head -1)" || true
if [[ -n "$line" ]]; then
	parse_milestone_line "$line"
	emit_milestone "$m_date" "FLB_Introduction" "$m_hash" "$m_author" "$m_desc"
fi

# -----------------------------------------------------------------------
# Milestone 12: KHO ABI Headers — formal ABI specification
# -----------------------------------------------------------------------
line="$(git log --all --reverse --format="%aI%x09%H%x09%an%x09%s" \
	-- include/linux/kho/abi/ \
	2>/dev/null | head -1)" || true
if [[ -n "$line" ]]; then
	parse_milestone_line "$line"
	emit_milestone "$m_date" "KHO_ABI_Headers" "$m_hash" "$m_author" "$m_desc"
fi

# -----------------------------------------------------------------------
# Milestone 13: Stabilization Fixes — latest bug fix commit
# -----------------------------------------------------------------------
line="$(git log --all --format="%aI%x09%H%x09%an%x09%s" \
	--grep="fix" \
	-- kernel/liveupdate/ include/linux/kexec_handover.h \
	2>/dev/null | sort -t$'\t' -k1,1 | tail -1)" || true
if [[ -n "$line" ]]; then
	parse_milestone_line "$line"
	emit_milestone "$m_date" "Stabilization_Fixes" "$m_hash" "$m_author" "$m_desc"
fi

# ---------------------------------------------------------------------------
# Output all buffered milestones sorted by date (chronological ascending).
# This ensures the "Milestones (chronological order)" header contract is met
# regardless of the order in which individual milestone git-log queries run.
# ---------------------------------------------------------------------------
if (( ${#milestone_rows[@]} > 0 )); then
	printf '%s\n' "${milestone_rows[@]}" | sort -t"${TAB}" -k1,1
fi

# ===========================================================================
# PHASE 5: Summary, pass/fail verification, and exit
# ===========================================================================
log "INFO" "Phase 5: Summary and verification"

if (( milestone_count >= 5 )); then
	log "INFO" "PASS: Identified $milestone_count milestones (minimum required: 5)"
else
	log "WARN" "Only $milestone_count milestones found, below minimum of 5"
fi

log "INFO" "=========================================="
log "INFO" "Authorship Analysis Summary"
log "INFO" "=========================================="
log "INFO" "Unique authors: $unique_authors"
log "INFO" "Total commits: $total_commits (exclusive: $exclusive_commits, shared: $shared_commits)"
log "INFO" "Milestones identified: $milestone_count"
if [[ -n "${first_author:-}" && "$first_author" != "N/A" ]]; then
	log "INFO" "Original feature author: $first_author ($first_date)"
fi
log "INFO" "Authorship analysis complete: $unique_authors authors, $total_commits commits, $milestone_count milestones"

log "INFO" "Directive 2 complete — authorship and chronology generated successfully"
exit 0
