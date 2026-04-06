#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# manifest.sh — Directive 1: Establish the Feature Boundary
#
# Identifies ALL files comprising the Linux kernel Live Update subsystem
# (KHO + LUO), then extracts first-commit and last-commit dates per file,
# producing a structured TSV manifest on stdout.
#
# Output format (TSV to stdout):
#   file_path	component	first_commit_hash	first_commit_date	last_commit_hash	last_commit_date
#
# Structured logs are emitted to stderr in the format:
#   [LU-ARCH-D1-<timestamp>] [<ISO-8601>] [<LEVEL>] <message>
#
# Pass/Fail Criterion (Directive 1):
#   >= 1 file per component (state_machine, fdt_serialization, fd_token,
#   callback_registration) and zero unrelated files.  KVM integration is
#   explicitly marked ABSENT because no KVM-specific live-update code exists.
#
# Scope Exclusions (AAP §0.7.2):
#   - XFS scrub "live update" (fs/xfs/scrub/) — different concept
#   - Generic kexec code (kernel/kexec*.c) — unless KHO-specific
#   - Livepatch (kernel/livepatch/, Documentation/livepatch/) — different subsystem
#   - Non-x86 architectures — only x86 has ARCH_SUPPORTS_KEXEC_HANDOVER
#
# Usage:
#   cd <kernel-repo-root>
#   bash tools/liveupdate/archaeology/manifest.sh
#   # TSV goes to stdout; logs go to stderr.

set -euo pipefail

# ---------------------------------------------------------------------------
# Observability: correlation ID and structured logging
# ---------------------------------------------------------------------------
readonly CORR_ID="LU-ARCH-D1-$(date -u +%Y%m%dT%H%M%S)"
readonly TAB=$'\t'

log() {
	local level="$1"
	shift
	echo "[$CORR_ID] [$(date -u +%Y-%m-%dT%H:%M:%SZ)] [$level] $*" >&2
}

# ---------------------------------------------------------------------------
# Repository root detection
# ---------------------------------------------------------------------------
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
	log "ERROR" "Not inside a git repository.  Run from the kernel tree root."
	exit 1
}
cd "$REPO_ROOT"
log "INFO" "Repository root: $REPO_ROOT"
log "INFO" "Starting Directive 1 — Establish the Feature Boundary"

# ---------------------------------------------------------------------------
# Declare associative arrays for deduplication and component tracking
# ---------------------------------------------------------------------------
declare -A SEEN          # file_path -> 1  (dedup guard)
declare -A COMP_COUNT    # component -> count

# Accumulator: parallel indexed arrays (avoid mapfile issues on older bash)
declare -a MANIFEST_FILE=()
declare -a MANIFEST_COMP=()

# ---------------------------------------------------------------------------
# Helper: register a file into the manifest (with dedup)
# ---------------------------------------------------------------------------
add_file() {
	local file="$1"
	local component="$2"

	# Skip if already registered
	if [[ -n "${SEEN[$file]+x}" ]]; then
		return 0
	fi

	# Verify the file actually exists on disk
	if [[ ! -f "$file" ]]; then
		log "WARN" "File does not exist on disk, skipping: $file"
		return 0
	fi

	SEEN["$file"]=1
	MANIFEST_FILE+=("$file")
	MANIFEST_COMP+=("$component")
	COMP_COUNT["$component"]=$(( ${COMP_COUNT["$component"]:-0} + 1 ))
}

# ---------------------------------------------------------------------------
# Helper: extract first-commit and last-commit info for a file
#
# Outputs TAB-separated: first_hash first_date last_hash last_date
# Uses --reverse on the current branch for speed (avoids expensive --follow
# across 1.4M commits).  Falls back gracefully when history is unavailable.
# Also updates global earliest/latest date trackers for summary.
# ---------------------------------------------------------------------------
EARLIEST_DATE=""
LATEST_DATE=""

get_commit_info() {
	local file="$1"
	local first_info first_hash first_date
	local last_info last_hash last_date

	# First commit — oldest commit touching this path (fast: no --follow)
	first_info="$(git log --reverse --format="%H${TAB}%aI" -- "$file" 2>/dev/null | head -1)"

	first_hash="$(echo "$first_info" | cut -f1)"
	first_date="$(echo "$first_info" | cut -f2)"

	# Last commit — most recent on current branch
	last_info="$(git log -1 --format="%H${TAB}%aI" -- "$file" 2>/dev/null)"
	last_hash="$(echo "$last_info" | cut -f1)"
	last_date="$(echo "$last_info" | cut -f2)"

	# Handle files with no git history (newly created, not committed)
	if [[ -z "$first_hash" ]]; then
		log "WARN" "No git history for $file"
		echo "N/A${TAB}N/A${TAB}N/A${TAB}N/A"
		return 0
	fi

	echo "${first_hash}${TAB}${first_date}${TAB}${last_hash}${TAB}${last_date}"
}

# ---------------------------------------------------------------------------
# Helper: update global date range trackers
# Called from the main loop (not a subshell) so globals are retained.
# ---------------------------------------------------------------------------
update_date_range() {
	local first_date="$1"
	local last_date="$2"

	if [[ "$first_date" != "N/A" && -n "$first_date" ]]; then
		if [[ -z "$EARLIEST_DATE" ]] || [[ "$first_date" < "$EARLIEST_DATE" ]]; then
			EARLIEST_DATE="$first_date"
		fi
	fi
	if [[ "$last_date" != "N/A" && -n "$last_date" ]]; then
		if [[ -z "$LATEST_DATE" ]] || [[ "$last_date" > "$LATEST_DATE" ]]; then
			LATEST_DATE="$last_date"
		fi
	fi
}

# ===================================================================
# PHASE 2: Identify subsystem files via multi-strategy discovery
# ===================================================================
log "INFO" "Phase 2: Identifying Live Update subsystem files"

# -------------------------------------------------------------------
# Strategy 1: Core LUO/KHO directory  (kernel/liveupdate/)
# -------------------------------------------------------------------
log "INFO" "Strategy 1: Scanning kernel/liveupdate/"
while IFS= read -r f; do
	case "$(basename "$f")" in
		Kconfig|Makefile)
			add_file "$f" "build"
			;;
		kexec_handover.c)
			add_file "$f" "fdt_serialization"
			;;
		kexec_handover_debug.c|kexec_handover_debugfs.c|kexec_handover_internal.h)
			add_file "$f" "kho_core"
			;;
		luo_core.c|luo_session.c|luo_internal.h)
			add_file "$f" "state_machine"
			;;
		luo_file.c)
			add_file "$f" "fd_token"
			;;
		luo_flb.c)
			add_file "$f" "callback_registration"
			;;
		*)
			# Unknown file inside kernel/liveupdate/ — include as kho_core
			add_file "$f" "kho_core"
			;;
	esac
done < <(find kernel/liveupdate/ -type f 2>/dev/null | sort)
log "INFO" "Strategy 1 complete: ${#MANIFEST_FILE[@]} files so far"

# -------------------------------------------------------------------
# Strategy 2: Public API headers (known paths)
# -------------------------------------------------------------------
log "INFO" "Strategy 2: Public API headers"
HEADERS=(
	"include/linux/liveupdate.h"
	"include/uapi/linux/liveupdate.h"
	"include/linux/kexec_handover.h"
	"include/linux/kho/abi/kexec_handover.h"
	"include/linux/kho/abi/luo.h"
	"include/linux/kho/abi/memblock.h"
	"include/linux/kho/abi/memfd.h"
)
for h in "${HEADERS[@]}"; do
	add_file "$h" "api_headers"
done
log "INFO" "Strategy 2 complete: ${#MANIFEST_FILE[@]} files so far"

# -------------------------------------------------------------------
# Strategy 3: Memory management integration (mm/)
# -------------------------------------------------------------------
log "INFO" "Strategy 3: Memory management integration (mm/)"
while IFS= read -r f; do
	case "$(basename "$f")" in
		memfd_luo.c)
			add_file "$f" "memfd"
			;;
		memblock.c)
			add_file "$f" "memblock"
			;;
		mm_init.c)
			add_file "$f" "mm_init"
			;;
		Kconfig|Makefile)
			add_file "$f" "build"
			;;
		*)
			# Other mm/ files with KHO/LUO references — include as mm_init
			add_file "$f" "mm_init"
			;;
	esac
done < <(grep -rl "kho_\|kexec_handover\|KEXEC_HANDOVER\|LIVEUPDATE\|liveupdate\|MEMBLOCK_KHO_SCRATCH" mm/ 2>/dev/null | sort -u)
log "INFO" "Strategy 3 complete: ${#MANIFEST_FILE[@]} files so far"

# -------------------------------------------------------------------
# Strategy 4: Architecture integration (x86 only)
# -------------------------------------------------------------------
log "INFO" "Strategy 4: x86 architecture integration"

# Include arch/x86/Kconfig for ARCH_SUPPORTS_KEXEC_HANDOVER definition
if grep -q "ARCH_SUPPORTS_KEXEC_HANDOVER" arch/x86/Kconfig 2>/dev/null; then
	add_file "arch/x86/Kconfig" "x86_arch"
fi

# Grep for KHO-specific references in arch/x86/ (excluding the Kconfig we just added)
while IFS= read -r f; do
	# Validate each file genuinely contains KHO/kexec_handover references
	# (not just generic kexec). The grep already filtered, so add directly.
	add_file "$f" "x86_arch"
done < <(grep -rl "kho\|kexec_handover\|KEXEC_HANDOVER\|SETUP_KEXEC_KHO\|kho_data" arch/x86/ 2>/dev/null \
	| grep -v "^arch/x86/Kconfig$" \
	| sort -u)
log "INFO" "Strategy 4 complete: ${#MANIFEST_FILE[@]} files so far"

# -------------------------------------------------------------------
# Strategy 5: Firmware integration (EFI)
# -------------------------------------------------------------------
log "INFO" "Strategy 5: Firmware integration"
if [[ -f "drivers/firmware/efi/efi-init.c" ]]; then
	if grep -q "is_kho_boot\|kho_" drivers/firmware/efi/efi-init.c 2>/dev/null; then
		add_file "drivers/firmware/efi/efi-init.c" "efi"
	fi
fi
log "INFO" "Strategy 5 complete: ${#MANIFEST_FILE[@]} files so far"

# -------------------------------------------------------------------
# Strategy 6: Test infrastructure
# -------------------------------------------------------------------
log "INFO" "Strategy 6: Test infrastructure"

# In-kernel test files
for tf in lib/test_kho.c lib/tests/liveupdate.c; do
	if [[ -f "$tf" ]]; then
		add_file "$tf" "tests"
	fi
done

# lib/Kconfig.debug contains LIVEUPDATE_TEST and TEST_KHO symbols
if [[ -f "lib/Kconfig.debug" ]]; then
	if grep -q "LIVEUPDATE_TEST\|TEST_KHO" lib/Kconfig.debug 2>/dev/null; then
		add_file "lib/Kconfig.debug" "tests"
	fi
fi

# lib/tests/Makefile builds LIVEUPDATE_TEST
if [[ -f "lib/tests/Makefile" ]]; then
	if grep -q "LIVEUPDATE_TEST\|liveupdate" lib/tests/Makefile 2>/dev/null; then
		add_file "lib/tests/Makefile" "tests"
	fi
fi

# Userspace selftests
while IFS= read -r f; do
	add_file "$f" "selftests"
done < <(find tools/testing/selftests/liveupdate/ -type f 2>/dev/null | sort)
log "INFO" "Strategy 6 complete: ${#MANIFEST_FILE[@]} files so far"

# -------------------------------------------------------------------
# Strategy 7: Documentation
# -------------------------------------------------------------------
log "INFO" "Strategy 7: Documentation"
DOC_FILES=(
	"Documentation/core-api/liveupdate.rst"
	"Documentation/userspace-api/liveupdate.rst"
	"Documentation/admin-guide/mm/kho.rst"
	"Documentation/core-api/kho/index.rst"
	"Documentation/core-api/kho/abi.rst"
	"Documentation/mm/memfd_preservation.rst"
)
for d in "${DOC_FILES[@]}"; do
	add_file "$d" "documentation"
done
log "INFO" "Strategy 7 complete: ${#MANIFEST_FILE[@]} files so far"

# -------------------------------------------------------------------
# Strategy 8: Validation — exclude false positives
# -------------------------------------------------------------------
log "INFO" "Strategy 8: Validating — checking for false positives"

# Build a validated manifest by re-checking each discovered file.
# We apply exclusion rules and verify relevance.
declare -a VALID_FILE=()
declare -a VALID_COMP=()
declare -A VALID_COMP_COUNT=()
excluded_count=0

for i in "${!MANIFEST_FILE[@]}"; do
	file="${MANIFEST_FILE[$i]}"
	comp="${MANIFEST_COMP[$i]}"
	exclude=false

	# Exclusion Rule 1: XFS scrub "live update" references
	if [[ "$file" == fs/xfs/scrub/* ]]; then
		log "WARN" "Excluding XFS scrub false positive: $file"
		exclude=true
	fi

	# Exclusion Rule 2: Livepatch subsystem
	if [[ "$file" == kernel/livepatch/* ]] || [[ "$file" == Documentation/livepatch/* ]]; then
		log "WARN" "Excluding livepatch false positive: $file"
		exclude=true
	fi

	# Exclusion Rule 3: Generic kexec code without KHO specifics
	if [[ "$file" == kernel/kexec*.c ]] && [[ "$file" != kernel/liveupdate/* ]]; then
		if ! grep -q "kho\|kexec_handover\|KEXEC_HANDOVER" "$file" 2>/dev/null; then
			log "WARN" "Excluding generic kexec without KHO: $file"
			exclude=true
		fi
	fi

	# Exclusion Rule 4: Non-x86 architecture files
	if [[ "$file" == arch/* ]] && [[ "$file" != arch/x86/* ]]; then
		log "WARN" "Excluding non-x86 arch file: $file"
		exclude=true
	fi

	if [[ "$exclude" == "false" ]]; then
		VALID_FILE+=("$file")
		VALID_COMP+=("$comp")
		VALID_COMP_COUNT["$comp"]=$(( ${VALID_COMP_COUNT["$comp"]:-0} + 1 ))
	else
		excluded_count=$((excluded_count + 1))
	fi
done

log "INFO" "Validation complete: ${#VALID_FILE[@]} files retained, $excluded_count excluded"

# ===================================================================
# PHASE 3: Extract git history and produce TSV output
# ===================================================================
log "INFO" "Phase 3: Extracting git history for ${#VALID_FILE[@]} files"

# TSV header
echo "file_path${TAB}component${TAB}first_commit_hash${TAB}first_commit_date${TAB}last_commit_hash${TAB}last_commit_date"

total_files=0
for i in "${!VALID_FILE[@]}"; do
	file="${VALID_FILE[$i]}"
	comp="${VALID_COMP[$i]}"

	commit_info="$(get_commit_info "$file")"
	echo "${file}${TAB}${comp}${TAB}${commit_info}"
	total_files=$((total_files + 1))

	# Extract dates from commit_info to update global date range
	# commit_info format: first_hash\tfirst_date\tlast_hash\tlast_date
	ci_first_date="$(echo "$commit_info" | cut -f2)"
	ci_last_date="$(echo "$commit_info" | cut -f4)"
	update_date_range "$ci_first_date" "$ci_last_date"

	# Progress logging every 10 files
	if (( total_files % 10 == 0 )); then
		log "INFO" "Processed $total_files / ${#VALID_FILE[@]} files"
	fi
done

# -------------------------------------------------------------------
# Special KVM integration marker — explicitly absent
# -------------------------------------------------------------------
echo "ABSENT:kvm_integration${TAB}kvm${TAB}N/A${TAB}N/A${TAB}N/A${TAB}N/A"
log "INFO" "KVM integration: ABSENT — no KVM-specific live-update code in tree"

# ===================================================================
# PHASE 4: Pass/fail criterion and summary
# ===================================================================
log "INFO" "Phase 4: Validating pass/fail criteria"

# Required components (per Directive 1 acceptance criteria)
REQUIRED_COMPONENTS=(
	"state_machine"
	"fdt_serialization"
	"fd_token"
	"callback_registration"
)

pass=true
for rc in "${REQUIRED_COMPONENTS[@]}"; do
	count="${VALID_COMP_COUNT[$rc]:-0}"
	if (( count == 0 )); then
		log "ERROR" "FAIL: Required component '$rc' has 0 files"
		pass=false
	else
		log "INFO" "PASS: Component '$rc' has $count file(s)"
	fi
done

# Log coverage for all components
log "INFO" "Component coverage summary:"
for comp in $(echo "${!VALID_COMP_COUNT[@]}" | tr ' ' '\n' | sort); do
	log "INFO" "  $comp = ${VALID_COMP_COUNT[$comp]}"
done
log "INFO" "  kvm = 0 (absent — explicitly documented)"

# Final summary (date range computed during Phase 3 via get_commit_info)
log "INFO" "=========================================="
log "INFO" "Manifest Summary"
log "INFO" "=========================================="
log "INFO" "Total files in manifest: $total_files"
log "INFO" "Total components: ${#VALID_COMP_COUNT[@]} (+ kvm absent)"
log "INFO" "Earliest commit date: ${EARLIEST_DATE:-unknown}"
log "INFO" "Latest commit date: ${LATEST_DATE:-unknown}"

if [[ "$pass" == "true" ]]; then
	log "INFO" "Directive 1 PASS: All required components have >= 1 file"
else
	log "ERROR" "Directive 1 FAIL: Missing required component(s)"
	exit 1
fi

log "INFO" "Directive 1 complete — manifest generated successfully"
exit 0
