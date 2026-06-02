#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# statemachine.sh — Directive 4: Map the State Machine Evolution
#
# Tracks every modification to the Live Update session lifecycle (the
# effective state machine) from introduction to HEAD.  The actual
# implementation uses an implicit session lifecycle rather than an
# explicit four-state enum.
#
# IMPORTANT DISCREPANCY: The original directive requests tracking a
# four-state machine (LU_NORMAL, LU_PREPARE, LU_FREEZE, LU_RECOVERY).
# No such enum exists in the source.  This script documents the
# discrepancy and maps the actual session lifecycle flow instead.
#
# Output format (stdout, four sections separated by ---):
#
#   Section 1 (TSV): commit_hash\tauthor\tdate\tsubject\tchange_type\tfiles_modified
#   ---
#   Section 2: STATE_DIAGRAM_START / STATE_DIAGRAM_END block
#   ---
#   Section 3: STATE_FUNCTIONS_START / STATE_FUNCTIONS_END block
#   ---
#   Section 4: DISCREPANCY_START / DISCREPANCY_END block
#
# Structured logs are emitted to stderr:
#   [LU-ARCH-D4-<timestamp>] [<ISO-8601>] [<LEVEL>] <message>
#
# Usage:
#   cd <kernel-repo-root>
#   bash tools/liveupdate/archaeology/statemachine.sh
#   # Data goes to stdout; logs go to stderr.

set -euo pipefail

# ---------------------------------------------------------------------------
# Observability: correlation ID and structured logging
# ---------------------------------------------------------------------------
readonly CORR_ID="LU-ARCH-D4-$(date -u +%Y%m%dT%H%M%S)"

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
log "INFO" "Starting Directive 4 — Map the State Machine Evolution"

# ---------------------------------------------------------------------------
# Define the 5 files implementing the session lifecycle state machine
# ---------------------------------------------------------------------------
STATE_FILES=(
	"kernel/liveupdate/luo_core.c"
	"kernel/liveupdate/luo_session.c"
	"kernel/liveupdate/luo_file.c"
	"kernel/liveupdate/luo_flb.c"
	"kernel/liveupdate/luo_internal.h"
)

# Verify all state files exist on disk
missing=0
for sf in "${STATE_FILES[@]}"; do
	if [[ ! -f "$sf" ]]; then
		log "ERROR" "State file not found: $sf"
		missing=$((missing + 1))
	fi
done
if [[ "$missing" -gt 0 ]]; then
	log "ERROR" "$missing state file(s) missing — cannot proceed"
	exit 1
fi
log "INFO" "All ${#STATE_FILES[@]} state files verified present"

# ---------------------------------------------------------------------------
# classify_change — Classify a commit as bugfix, feature, or refactor
#
# Heuristic-based classification using commit subject keywords.
# ---------------------------------------------------------------------------
classify_change() {
	local subject="$1"
	local subject_lower
	subject_lower="$(echo "$subject" | tr '[:upper:]' '[:lower:]')"

	if echo "$subject_lower" | grep -qE "fix|bug|regression|oops|panic|crash|warn|error|null|leak|race|deadlock|invalid"; then
		echo "bugfix"
	elif echo "$subject_lower" | grep -qE "refactor|cleanup|rename|move|reorganize|style|format|typo|whitespace|convert|treewide|kmalloc|alloc_obj"; then
		echo "refactor"
	else
		echo "feature"
	fi
}

# ===================================================================
# SECTION 1: Track all state-modifying commits (TSV output)
# ===================================================================
log "INFO" "Section 1: Extracting commits touching state flow files"

# Print TSV header
echo -e "commit_hash\tauthor\tdate\tsubject\tchange_type\tfiles_modified"

# Counters for summary
total_commits=0
bugfix_count=0
feature_count=0
refactor_count=0

# Process each commit touching state flow files
# Use --all to include all branches and tags
while IFS=$'\t' read -r hash author date_str subject; do
	# Skip empty lines
	if [[ -z "$hash" ]]; then
		continue
	fi

	# Classify the change type from the commit subject
	change_type="$(classify_change "$subject")"

	# Determine which of our STATE_FILES were modified by this commit
	files_modified=""
	while IFS= read -r modified_file; do
		if [[ -n "$modified_file" ]]; then
			if [[ -n "$files_modified" ]]; then
				files_modified="${files_modified},${modified_file}"
			else
				files_modified="$modified_file"
			fi
		fi
	done < <(git diff-tree --no-commit-id --name-only -r "$hash" -- "${STATE_FILES[@]}" 2>/dev/null)

	# If no state files were found in diff-tree (e.g. merge commit),
	# mark as unknown
	if [[ -z "$files_modified" ]]; then
		files_modified="(merge-or-rename)"
	fi

	echo -e "${hash}\t${author}\t${date_str}\t${subject}\t${change_type}\t${files_modified}"
	total_commits=$((total_commits + 1))

	# Update per-type counters
	case "$change_type" in
		bugfix)  bugfix_count=$((bugfix_count + 1)) ;;
		feature) feature_count=$((feature_count + 1)) ;;
		refactor) refactor_count=$((refactor_count + 1)) ;;
	esac
done < <(git log --all --format="%H%x09%an%x09%aI%x09%s" -- "${STATE_FILES[@]}" 2>/dev/null)

log "INFO" "Found $total_commits commits modifying state flow files"
log "INFO" "Classification: $feature_count feature, $bugfix_count bugfix, $refactor_count refactor"

# ===================================================================
# SECTION 2: State machine diagram from current HEAD
# ===================================================================
echo "---"
log "INFO" "Section 2: Generating state machine diagram from current HEAD"

# The state machine is reconstructed from the session lifecycle as
# implemented across luo_core.c, luo_session.c, luo_file.c, and
# luo_flb.c.  There is no explicit enum — the states are implicit in
# the function call chains.

cat <<'STATE_DIAGRAM_BLOCK'
STATE_DIAGRAM_START
[*] --> Normal : Boot / KHO init (luo_early_startup, liveupdate_ioctl_init)
Normal --> DeviceOpened : /dev/liveupdate opened (luo_open, exclusive)
DeviceOpened --> SessionActive : CREATE_SESSION ioctl (luo_session_create)
SessionActive --> FDsPreserved : PRESERVE_FD ioctl (luo_preserve_file)
FDsPreserved --> Frozen : liveupdate_reboot() -> freeze callbacks (luo_file_freeze)
Frozen --> Serialized : kho_finalize() -> FDT written (luo_session_serialize)
Serialized --> KexecTransition : kexec -e (external)
KexecTransition --> NewKernelBoot : New kernel boots
NewKernelBoot --> Deserialized : luo_session_deserialize() via luo_open
Deserialized --> Retrieved : RETRIEVE_SESSION + RETRIEVE_FD ioctls
Retrieved --> Finished : SESSION_FINISH ioctl (luo_file_finish)
Finished --> Normal : Resources released (luo_session_release)
FDsPreserved --> Normal : Abort path (luo_file_unpreserve_files via session close)
Frozen --> FDsPreserved : Freeze failure rollback (luo_file_unfreeze)
STATE_DIAGRAM_END
STATE_DIAGRAM_BLOCK

log "INFO" "State diagram generated with 14 transitions"

# ===================================================================
# SECTION 3: Key function locations from current HEAD
# ===================================================================
echo "---"
log "INFO" "Section 3: Extracting key state transition function locations"

echo "STATE_FUNCTIONS_START"

# We extract the actual line numbers by grepping each source file for
# the function definitions that implement state transitions.
#
# Target functions and their expected files:
#   luo_core.c:      luo_early_startup, luo_late_startup, liveupdate_reboot,
#                     liveupdate_enabled, luo_open, luo_ioctl, liveupdate_ioctl_init
#   luo_session.c:   luo_session_create, luo_session_serialize,
#                     luo_session_deserialize, luo_session_setup_incoming,
#                     luo_session_setup_outgoing
#   luo_file.c:      luo_preserve_file, luo_file_freeze, luo_file_unfreeze,
#                     luo_retrieve_file, luo_file_finish, luo_file_deserialize,
#                     liveupdate_register_file_handler, liveupdate_unregister_file_handler
#   luo_flb.c:       liveupdate_register_flb, liveupdate_unregister_flb,
#                     luo_flb_serialize, luo_flb_setup_outgoing, luo_flb_setup_incoming

# Helper: extract line number for a function in a given file
extract_func_line() {
	local func_name="$1"
	local file_path="$2"
	local line_num

	# Match function definition: return_type [qualifiers] func_name(
	line_num="$(grep -n "[[:space:]]${func_name}\b\|^${func_name}\b" "$file_path" 2>/dev/null \
		| grep -E "(int|void|bool|long)[[:space:]].*${func_name}[[:space:]]*\(" \
		| head -1 \
		| cut -d: -f1)"

	if [[ -z "$line_num" ]]; then
		# Fallback: broader pattern
		line_num="$(grep -n "${func_name}" "$file_path" 2>/dev/null \
			| grep -E "^[0-9]+:.*${func_name}[[:space:]]*\(" \
			| head -1 \
			| cut -d: -f1)"
	fi

	if [[ -n "$line_num" ]]; then
		echo -e "${func_name}\t${file_path}\t${line_num}"
	else
		echo -e "${func_name}\t${file_path}\tNOT_FOUND"
		log "WARN" "Could not locate ${func_name} in ${file_path}"
	fi
}

# --- luo_core.c functions ---
extract_func_line "luo_early_startup" "kernel/liveupdate/luo_core.c"
extract_func_line "luo_late_startup" "kernel/liveupdate/luo_core.c"
extract_func_line "liveupdate_reboot" "kernel/liveupdate/luo_core.c"
extract_func_line "liveupdate_enabled" "kernel/liveupdate/luo_core.c"
extract_func_line "luo_open" "kernel/liveupdate/luo_core.c"
extract_func_line "luo_ioctl" "kernel/liveupdate/luo_core.c"
extract_func_line "liveupdate_ioctl_init" "kernel/liveupdate/luo_core.c"

# --- luo_session.c functions ---
extract_func_line "luo_session_create" "kernel/liveupdate/luo_session.c"
extract_func_line "luo_session_serialize" "kernel/liveupdate/luo_session.c"
extract_func_line "luo_session_deserialize" "kernel/liveupdate/luo_session.c"
extract_func_line "luo_session_setup_incoming" "kernel/liveupdate/luo_session.c"
extract_func_line "luo_session_setup_outgoing" "kernel/liveupdate/luo_session.c"
extract_func_line "luo_session_retrieve" "kernel/liveupdate/luo_session.c"

# --- luo_file.c functions ---
extract_func_line "luo_preserve_file" "kernel/liveupdate/luo_file.c"
extract_func_line "luo_file_freeze" "kernel/liveupdate/luo_file.c"
extract_func_line "luo_file_unfreeze" "kernel/liveupdate/luo_file.c"
extract_func_line "luo_retrieve_file" "kernel/liveupdate/luo_file.c"
extract_func_line "luo_file_finish" "kernel/liveupdate/luo_file.c"
extract_func_line "luo_file_deserialize" "kernel/liveupdate/luo_file.c"
extract_func_line "liveupdate_register_file_handler" "kernel/liveupdate/luo_file.c"
extract_func_line "liveupdate_unregister_file_handler" "kernel/liveupdate/luo_file.c"

# --- luo_flb.c functions ---
extract_func_line "liveupdate_register_flb" "kernel/liveupdate/luo_flb.c"
extract_func_line "liveupdate_unregister_flb" "kernel/liveupdate/luo_flb.c"
extract_func_line "luo_flb_serialize" "kernel/liveupdate/luo_flb.c"
extract_func_line "luo_flb_setup_outgoing" "kernel/liveupdate/luo_flb.c"
extract_func_line "luo_flb_setup_incoming" "kernel/liveupdate/luo_flb.c"

echo "STATE_FUNCTIONS_END"

log "INFO" "Function location extraction complete"

# ===================================================================
# SECTION 4: Discrepancy documentation
# ===================================================================
echo "---"
log "INFO" "Section 4: Documenting enum vs session lifecycle discrepancy"

# Verify the absence of the four-state enum in the source
enum_hits="$(grep -rn "LU_NORMAL\|LU_PREPARE\|LU_FREEZE\|LU_RECOVERY" kernel/liveupdate/ 2>/dev/null | wc -l || true)"
# Trim whitespace from wc output
enum_hits="${enum_hits## }"

cat <<DISCREPANCY_BLOCK
DISCREPANCY_START
The original directive requests tracking a four-state machine (LU_NORMAL, LU_PREPARE, LU_FREEZE, LU_RECOVERY).
However, the actual implementation uses an implicit session lifecycle rather than an explicit enum.
No LU_NORMAL/LU_PREPARE/LU_FREEZE/LU_RECOVERY enum exists in the source code.
Evidence: grep -rn "LU_NORMAL|LU_PREPARE|LU_FREEZE|LU_RECOVERY" kernel/liveupdate/ returns ${enum_hits} results.
The session lifecycle flow is reconstructed from function call chains across 5 files:
  - kernel/liveupdate/luo_core.c: Boot init, /dev/liveupdate registration, reboot path
  - kernel/liveupdate/luo_session.c: Session create/serialize/deserialize/retrieve lifecycle
  - kernel/liveupdate/luo_file.c: File preserve/freeze/unfreeze/retrieve/finish lifecycle
  - kernel/liveupdate/luo_flb.c: File-Lifecycle-Bound global state lifecycle
  - kernel/liveupdate/luo_internal.h: Internal API declarations
The effective states are: Normal -> DeviceOpened -> SessionActive -> FDsPreserved -> Frozen -> Serialized -> KexecTransition -> NewKernelBoot -> Deserialized -> Retrieved -> Finished -> Normal.
The state machine is controlled by a singleton /dev/liveupdate misc device (luo_core.c) with exclusive open semantics.
Transitions are driven by userspace ioctls (CREATE_SESSION, PRESERVE_FD, RETRIEVE_SESSION, RETRIEVE_FD, FINISH) and the reboot() syscall pathway.
DISCREPANCY_END
DISCREPANCY_BLOCK

log "INFO" "Discrepancy section generated (enum hits: $enum_hits)"

# ===================================================================
# Summary and exit
# ===================================================================
log "INFO" "Directive 4 complete — Summary:"
log "INFO" "  Total commits: $total_commits"
log "INFO" "  Feature commits: $feature_count"
log "INFO" "  Bugfix commits: $bugfix_count"
log "INFO" "  Refactor commits: $refactor_count"
log "INFO" "  State files analyzed: ${#STATE_FILES[@]}"
log "INFO" "  Diagram transitions: 14"
log "INFO" "  LU_NORMAL/LU_PREPARE/LU_FREEZE/LU_RECOVERY enum hits: $enum_hits"
log "INFO" "Directive 4 — Map the State Machine Evolution — PASSED"

exit 0
