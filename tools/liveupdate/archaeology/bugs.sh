#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# bugs.sh — Directive 6: Catalog Bugs (Resolved and Remaining)
#
# Searches for bug-related commit messages touching Live Update subsystem
# files, catalogs TODO/FIXME/HACK/XXX annotations in current HEAD, and
# enumerates WARN_ON/BUG_ON/BUILD_BUG_ON defensive patterns.
#
# Output format (TSV to stdout, three sections separated by "---"):
#   Section 1 — Resolved bugs:
#     RESOLVED<tab>commit_hash<tab>author<tab>date<tab>subject<tab>fix_for_hash
#   Section 2 — Remaining issues:
#     REMAINING<tab>file<tab>line<tab>pattern<tab>content
#   Section 3 — Defensive patterns:
#     DEFENSIVE<tab>file<tab>count<tab>pattern_type
#
# Structured logs are emitted to stderr in the format:
#   [LU-ARCH-D6-<timestamp>] [<ISO-8601>] [<LEVEL>] <message>
#
# Zero Speculation Rule (AAP §0.8.1):
#   Every bug entry cites a specific commit hash and/or file:line reference.
#   No inference about bug severity or impact is made.
#
# Pass/Fail Criteria (Directive 6):
#   - >=1 resolved bug commit with evidence
#   - Complete TODO/FIXME/HACK/XXX scan across all manifest files
#   - Defensive pattern census with per-file counts
#   - Zero fabricated hashes or file references
#
# Usage:
#   cd <kernel-repo-root>
#   bash tools/liveupdate/archaeology/bugs.sh
#   # TSV goes to stdout; logs go to stderr.

set -euo pipefail

# ---------------------------------------------------------------------------
# Observability: correlation ID and structured logging
# ---------------------------------------------------------------------------
readonly CORR_ID="LU-ARCH-D6-$(date -u +%Y%m%dT%H%M%S)"
readonly TAB=$'\t'

# log() — Emit structured log lines to stderr.
#
# Format: [<CORR_ID>] [<ISO-8601>] [<LEVEL>] <message>
# All analysis progress, warnings, and summaries go to stderr so that
# stdout remains a clean TSV stream for machine parsing by analyze.py.
log() {
	local level="$1"
	shift
	echo "[$CORR_ID] [$(date -u +%Y-%m-%dT%H:%M:%SZ)] [$level] $*" >&2
}

# ---------------------------------------------------------------------------
# Repository root detection
# ---------------------------------------------------------------------------
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
	log "ERROR" "Not inside a git repository. Run from the kernel tree root."
	exit 1
}
cd "$REPO_ROOT"
log "INFO" "Repository root: $REPO_ROOT"
log "INFO" "Starting Directive 6 — Catalog Bugs (Resolved and Remaining)"

# ---------------------------------------------------------------------------
# Live Update subsystem manifest paths (AAP §0.2.1)
#
# This indexed array follows the MANIFEST_PATHS convention shared with
# sibling scripts (manifest.sh, authorship.sh, bottlenecks.sh) in the
# archaeology pipeline.  Each entry is either a directory (searched
# recursively) or an individual file.
# ---------------------------------------------------------------------------
MANIFEST_PATHS=(
	"kernel/liveupdate/"
	"include/linux/liveupdate.h"
	"include/uapi/linux/liveupdate.h"
	"include/linux/kexec_handover.h"
	"include/linux/kho/"
	"mm/memfd_luo.c"
	"mm/memblock.c"
	"mm/mm_init.c"
	"arch/x86/boot/compressed/kaslr.c"
	"arch/x86/kernel/e820.c"
	"arch/x86/kernel/kexec-bzimage64.c"
	"arch/x86/kernel/setup.c"
	"arch/x86/realmode/init.c"
	"drivers/firmware/efi/efi-init.c"
	"lib/test_kho.c"
	"lib/tests/liveupdate.c"
)

# ---------------------------------------------------------------------------
# Validate that at least some manifest paths exist on disk
# ---------------------------------------------------------------------------
valid_path_count=0
for path in "${MANIFEST_PATHS[@]}"; do
	if [[ -e "$path" ]]; then
		valid_path_count=$((valid_path_count + 1))
	else
		log "WARN" "Manifest path does not exist: $path"
	fi
done
log "INFO" "Validated $valid_path_count / ${#MANIFEST_PATHS[@]} manifest paths"

if [[ "$valid_path_count" -eq 0 ]]; then
	log "ERROR" "No manifest paths found on disk — cannot proceed"
	exit 1
fi

# ---------------------------------------------------------------------------
# Helper: expand MANIFEST_PATHS to individual source files (.c and .h)
# Used by Section 3 for per-file defensive pattern counting.
# Directories are recursed; individual files are emitted directly.
# Output is sorted and deduplicated.
# ---------------------------------------------------------------------------
expand_manifest_files() {
	for path in "${MANIFEST_PATHS[@]}"; do
		if [[ -d "$path" ]]; then
			find "$path" -type f \( -name "*.c" -o -name "*.h" \) 2>/dev/null
		elif [[ -f "$path" ]]; then
			echo "$path"
		fi
	done | sort -u
}

# =========================================================================
# SECTION 1: Resolved Bugs — Commit Message Analysis
# =========================================================================
log "INFO" "Section 1: Building Fixes: trailer map"

# Step 1a: Build an associative array mapping commit hash → Fixes: hash.
# Parses git log --all --format='%H%n%(trailers:key=Fixes,valueonly)' to
# extract Fixes: trailers for every commit touching manifest paths.
# This map is consulted when emitting resolved bug records so that each
# fix commit can reference the commit it addresses.
declare -A FIXES_MAP
current_hash=""
while IFS= read -r line; do
	# A 40-char lowercase hex string is a commit hash
	if [[ ${#line} -eq 40 ]] && [[ "$line" =~ ^[0-9a-f]+$ ]]; then
		current_hash="$line"
	elif [[ -n "$line" && -n "$current_hash" ]]; then
		# Non-empty line after a hash is the Fixes: trailer value.
		# Extract the referenced commit hash (first word before space).
		fix_hash=$(echo "$line" | sed 's/^[[:space:]]*//' | cut -d' ' -f1)
		if [[ -n "$fix_hash" ]] && [[ "$fix_hash" =~ ^[0-9a-f]+ ]]; then
			FIXES_MAP["$current_hash"]="$fix_hash"
		fi
		current_hash=""
	else
		# Empty line or no current hash — reset state
		current_hash=""
	fi
done < <(git log --all --format='%H%n%(trailers:key=Fixes,valueonly)' \
	-- "${MANIFEST_PATHS[@]}" 2>/dev/null)

log "INFO" "Fixes: trailer map built with ${#FIXES_MAP[@]} entries"

# Step 1b: Define bug-related keywords for commit message searching.
# These keywords cover the full spectrum of bug indicators requested by
# Directive 6: fix, bug, regression, oops, panic, null, leak, race,
# deadlock, warning, error, crash, overflow, underflow, use-after-free,
# double-free, memleak.
BUG_KEYWORDS="fix\|bug\|regression\|oops\|panic\|null\|leak\|race\|deadlock\|warning\|error\|crash\|overflow\|underflow\|use-after-free\|double-free\|memleak"

# Step 1c: Quick scan using git log --all --oneline --grep to report the
# total number of candidate commits before detailed extraction.
quick_count=$(git log --all --oneline \
	--grep="$BUG_KEYWORDS" -i \
	-- "${MANIFEST_PATHS[@]}" 2>/dev/null | wc -l)
log "INFO" "Quick scan: $quick_count candidate bug-related commits"

# Step 1d: Full extraction using git log --all --format='%H<TAB>%an<TAB>%aI<TAB>%s'
# with --grep for bug keywords.  For each matching commit, look up the
# Fixes: trailer in the pre-built map and emit a TSV record.
log "INFO" "Section 1: Extracting resolved bug details"

resolved_count=0
while IFS="${TAB}" read -r hash author date subject; do
	[[ -z "$hash" ]] && continue

	# Look up Fixes: trailer from the pre-built map
	fixes_hash="${FIXES_MAP[$hash]:-}"

	printf 'RESOLVED\t%s\t%s\t%s\t%s\t%s\n' \
		"$hash" "$author" "$date" "$subject" "$fixes_hash"
	resolved_count=$((resolved_count + 1))
done < <(git log --all --format="%H${TAB}%an${TAB}%aI${TAB}%s" \
	--grep="$BUG_KEYWORDS" -i \
	-- "${MANIFEST_PATHS[@]}" 2>/dev/null)

log "INFO" "Found $resolved_count bug-related commits"

# =========================================================================
# SECTION 2: Remaining Issues — TODO/FIXME/HACK/XXX in Current HEAD
# =========================================================================
echo -e "---"
log "INFO" "Section 2: Scanning current HEAD for TODO/FIXME/HACK/XXX"

remaining_count=0
while IFS= read -r match_line; do
	[[ -z "$match_line" ]] && continue

	# Parse grep output format:  file:linenum:content
	file="${match_line%%:*}"
	rest="${match_line#*:}"
	linenum="${rest%%:*}"
	content="${rest#*:}"

	# Determine which annotation pattern matched (priority: FIXME > TODO > HACK > XXX)
	pattern=""
	case "$content" in
		*FIXME*)  pattern="FIXME" ;;
		*TODO*)   pattern="TODO" ;;
		*HACK*)   pattern="HACK" ;;
		*XXX*)    pattern="XXX" ;;
	esac

	# Trim leading whitespace from content for cleaner output
	trimmed=$(echo "$content" | sed 's/^[[:space:]]*//')

	printf 'REMAINING\t%s\t%s\t%s\t%s\n' \
		"$file" "$linenum" "$pattern" "$trimmed"
	remaining_count=$((remaining_count + 1))
done < <(
	for path in "${MANIFEST_PATHS[@]}"; do
		# -H forces filename display even for single-file paths;
		# without it, grep omits the filename prefix for individual
		# files, breaking the file:linenum:content parse format.
		grep -rHn "TODO\|FIXME\|HACK\|XXX" "$path" 2>/dev/null || true
	done | sort -u
)

log "INFO" "Found $remaining_count TODO/FIXME/HACK annotations in current HEAD"

# =========================================================================
# SECTION 3: Defensive Patterns — WARN_ON/BUG_ON in Current HEAD
# =========================================================================
echo -e "---"
log "INFO" "Section 3: Scanning for defensive patterns (WARN_ON/BUG_ON)"

total_warn=0
total_bug=0
total_build=0

# Iterate over every individual source file expanded from manifest paths.
# For each file, count occurrences of three defensive pattern categories:
#   WARN_ON   — includes WARN_ON() and WARN_ON_ONCE()
#   BUG_ON    — pure BUG_ON() excluding BUILD_BUG_ON variants
#   BUILD_BUG_ON — includes BUILD_BUG_ON() and BUILD_BUG_ON_ZERO()
#
# Counting strategy:
#   grep -c "WARN_ON"      → counts lines matching WARN_ON or WARN_ON_ONCE
#   grep -c "BUILD_BUG_ON" → counts lines matching BUILD_BUG_ON or BUILD_BUG_ON_ZERO
#   grep -c "BUG_ON"       → counts ALL BUG_ON lines (including BUILD_BUG_ON)
#   BUG_ON exclusive = (total BUG_ON lines) - (BUILD_BUG_ON lines)
while IFS= read -r file; do
	[[ -z "$file" ]] && continue

	# Count WARN_ON matches (includes WARN_ON_ONCE variants).
	# Note: grep -c outputs "0" and exits 1 for no matches, so we use
	# the || assignment pattern to avoid double-output from || echo.
	warn_count=$(grep -c "WARN_ON" "$file" 2>/dev/null) || warn_count=0

	# Count BUILD_BUG_ON matches (includes BUILD_BUG_ON_ZERO)
	build_count=$(grep -c "BUILD_BUG_ON" "$file" 2>/dev/null) || build_count=0

	# Count BUG_ON matches excluding BUILD_BUG_ON:
	# grep -c "BUG_ON" catches both BUG_ON and BUILD_BUG_ON, so subtract.
	total_bugon=$(grep -c "BUG_ON" "$file" 2>/dev/null) || total_bugon=0
	bug_count=$((total_bugon - build_count))
	if [[ $bug_count -lt 0 ]]; then
		bug_count=0
	fi

	# Emit non-zero counts as TSV records
	if [[ "$warn_count" -gt 0 ]]; then
		printf 'DEFENSIVE\t%s\t%d\tWARN_ON\n' "$file" "$warn_count"
		total_warn=$((total_warn + warn_count))
	fi
	if [[ "$bug_count" -gt 0 ]]; then
		printf 'DEFENSIVE\t%s\t%d\tBUG_ON\n' "$file" "$bug_count"
		total_bug=$((total_bug + bug_count))
	fi
	if [[ "$build_count" -gt 0 ]]; then
		printf 'DEFENSIVE\t%s\t%d\tBUILD_BUG_ON\n' "$file" "$build_count"
		total_build=$((total_build + build_count))
	fi
done < <(expand_manifest_files)

log "INFO" "Defensive patterns: $total_warn WARN_ON, $total_bug BUG_ON, $total_build BUILD_BUG_ON"

# =========================================================================
# Summary and exit
# =========================================================================
log "INFO" "=========================================="
log "INFO" "Directive 6 Summary"
log "INFO" "=========================================="
log "INFO" "Resolved bugs (commit messages): $resolved_count"
log "INFO" "Remaining issues (TODO/FIXME/HACK): $remaining_count"
log "INFO" "Defensive patterns total: $((total_warn + total_bug + total_build))"
log "INFO" "  WARN_ON (inc. WARN_ON_ONCE): $total_warn"
log "INFO" "  BUG_ON: $total_bug"
log "INFO" "  BUILD_BUG_ON (inc. BUILD_BUG_ON_ZERO): $total_build"
log "INFO" "Directive 6 complete — bug catalog generated successfully"

exit 0
