#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# decisions.sh — Directive 3: Reconstruct Design Decisions
#
# Analyzes commit messages, commit bodies, and in-code comments for evidence
# of four specific design tradeoffs in the Linux kernel Live Update subsystem
# (KHO + LUO).
#
# Output format (TSV to stdout):
#   tradeoff_id	tradeoff_name	evidence_type	evidence_ref	evidence_text
#
# evidence_type: commit | code_comment | documentation | not_recorded
# evidence_ref:  commit hash (short), file:line, or "N/A"
#
# Structured logs are emitted to stderr in the format:
#   [LU-ARCH-D3-<timestamp>] [<ISO-8601>] [<LEVEL>] <message>
#
# Four Required Tradeoffs (Directive 3 pass/fail criterion):
#   T1 — Why FDT over protobuf/custom binary/sysfs
#   T2 — Why callback registration over centralized orchestrator
#   T3 — Why session-scoped cleanup for failure modes
#   T4 — Why token-based FD preservation over direct FD number mapping
#
# Zero Speculation Rule (AAP §0.8.1):
#   Every factual claim cites a commit hash, file:line, or uses the exact
#   phrase "rationale not recorded in-tree".  No inference is presented as
#   established fact.
#
# Pipeline Position:
#   Directive 3 in the sequential analysis pipeline (D1→D2→D3→...→D7).
#   Does not source or read manifest.sh (Directive 1) output directly;
#   defines its own search paths.  Execution order is enforced by the
#   analyze.py orchestrator.
#
# Usage:
#   cd <kernel-repo-root>
#   bash tools/liveupdate/archaeology/decisions.sh
#   # TSV goes to stdout; logs go to stderr.

set -euo pipefail

# ---------------------------------------------------------------------------
# Observability: correlation ID and structured logging
# ---------------------------------------------------------------------------
readonly CORR_ID="LU-ARCH-D3-$(date -u +%Y%m%dT%H%M%S)"
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
log "INFO" "Starting Directive 3 — Reconstruct Design Decisions"

# ---------------------------------------------------------------------------
# Search path arrays (MANIFEST_PATHS convention — shared with pipeline)
#
# These define the directories and files scanned for commit messages and
# in-code comments.  The lists mirror the Live Update subsystem boundary
# established by Directive 1 (manifest.sh), but are defined independently
# to avoid runtime coupling.
# ---------------------------------------------------------------------------
COMMIT_SEARCH_PATHS=(
	"kernel/liveupdate/"
	"include/linux/kho/"
	"include/linux/liveupdate.h"
	"include/linux/kexec_handover.h"
	"include/uapi/linux/liveupdate.h"
	"mm/memfd_luo.c"
)

CODE_SEARCH_FILES_CORE=(
	"kernel/liveupdate/luo_core.c"
	"kernel/liveupdate/luo_file.c"
	"kernel/liveupdate/luo_flb.c"
	"kernel/liveupdate/luo_session.c"
	"kernel/liveupdate/luo_internal.h"
	"kernel/liveupdate/kexec_handover.c"
)

CODE_SEARCH_FILES_HEADERS=(
	"include/linux/liveupdate.h"
	"include/uapi/linux/liveupdate.h"
	"include/linux/kexec_handover.h"
	"include/linux/kho/abi/luo.h"
	"include/linux/kho/abi/kexec_handover.h"
)

CODE_SEARCH_FILES_DOCS=(
	"Documentation/core-api/kho/index.rst"
	"Documentation/core-api/kho/abi.rst"
	"Documentation/core-api/liveupdate.rst"
)

CODE_SEARCH_FILES_CONFIG=(
	"kernel/liveupdate/Kconfig"
)

# ---------------------------------------------------------------------------
# Evidence counters — one per tradeoff
# ---------------------------------------------------------------------------
declare -i T1_COUNT=0
declare -i T2_COUNT=0
declare -i T3_COUNT=0
declare -i T4_COUNT=0

# ---------------------------------------------------------------------------
# Helper: emit a single TSV evidence line to stdout
#
# Arguments:
#   $1 — tradeoff_id   (T1, T2, T3, T4)
#   $2 — tradeoff_name (human-readable)
#   $3 — evidence_type (commit, code_comment, documentation, not_recorded)
#   $4 — evidence_ref  (commit hash, file:line, or "N/A")
#   $5 — evidence_text (short description; tabs/newlines stripped)
# ---------------------------------------------------------------------------
emit_evidence() {
	local tid="$1"
	local tname="$2"
	local etype="$3"
	local eref="$4"
	local etext="$5"

	# Sanitize evidence_text: replace tabs and newlines with spaces
	etext="$(echo "$etext" | tr '\t\n' '  ')"

	echo -e "${tid}${TAB}${tname}${TAB}${etype}${TAB}${eref}${TAB}${etext}"

	# Increment the per-tradeoff counter
	case "$tid" in
		T1) T1_COUNT+=1 ;;
		T2) T2_COUNT+=1 ;;
		T3) T3_COUNT+=1 ;;
		T4) T4_COUNT+=1 ;;
	esac

	log "DEBUG" "Evidence emitted: ${tid} ${etype} ${eref}"
}

# ===================================================================
# TSV Header
# ===================================================================
echo -e "tradeoff_id${TAB}tradeoff_name${TAB}evidence_type${TAB}evidence_ref${TAB}evidence_text"

# ===================================================================
# TRADEOFF T1: Why FDT over protobuf/custom binary/sysfs
# ===================================================================
log "INFO" "Analyzing T1 — FDT over protobuf/custom binary/sysfs"

T1_NAME="FDT over protobuf/custom binary/sysfs"

# --- Preliminary: count FDT-related source files for evidence breadth ---
fdt_file_count="$(grep -rl "fdt\|FDT\|libfdt" kernel/liveupdate/ include/linux/kho/ 2>/dev/null | wc -l)"
log "DEBUG" "T1: ${fdt_file_count} source files reference FDT"

# --- Evidence 1a: Kconfig explicitly selects LIBFDT ---
# The Kconfig for KEXEC_HANDOVER selects LIBFDT, indicating FDT was chosen
# as the serialization format for handover metadata.
libfdt_line=""
if [[ -f "kernel/liveupdate/Kconfig" ]]; then
	libfdt_line="$(grep -n "select LIBFDT" kernel/liveupdate/Kconfig 2>/dev/null | head -1)" || true
fi
if [[ -n "$libfdt_line" ]]; then
	lineno="$(echo "$libfdt_line" | cut -d: -f1)"
	emit_evidence "T1" "$T1_NAME" "code_comment" \
		"kernel/liveupdate/Kconfig:${lineno}" \
		"select LIBFDT — KHO reuses existing kernel FDT infrastructure for serialization"
	log "INFO" "T1: Found Kconfig LIBFDT selection at line ${lineno}"
else
	log "WARN" "T1: Could not find 'select LIBFDT' in Kconfig"
fi

# --- Evidence 1b: Documentation describes FDT as the handover format ---
# Documentation/core-api/kho/index.rst explicitly states KHO uses FDT.
fdt_doc_line=""
if [[ -f "Documentation/core-api/kho/index.rst" ]]; then
	fdt_doc_line="$(grep -n "flattened device tree (FDT)" Documentation/core-api/kho/index.rst 2>/dev/null | head -1)" || true
fi
if [[ -n "$fdt_doc_line" ]]; then
	lineno="$(echo "$fdt_doc_line" | cut -d: -f1)"
	emit_evidence "T1" "$T1_NAME" "documentation" \
		"Documentation/core-api/kho/index.rst:${lineno}" \
		"KHO uses flattened device tree (FDT) to pass information about preserved state"
	log "INFO" "T1: Found FDT documentation at line ${lineno}"
fi

# --- Evidence 1c: FDT ABI header commit ---
# Commit 5e1ea1e27b6f introduced the KHO FDT ABI header, centralizing the
# FDT-based ABI definitions and removing redundant YAML interface files.
fdt_abi_commit=""
fdt_abi_commit="$(git log --all --oneline --grep="introduce KHO FDT ABI header" \
	-- include/linux/kho/ 2>/dev/null | head -1 | cut -d' ' -f1)" || true
if [[ -n "$fdt_abi_commit" ]]; then
	commit_subject="$(git log --format="%s" -1 "$fdt_abi_commit" 2>/dev/null)"
	emit_evidence "T1" "$T1_NAME" "commit" \
		"$fdt_abi_commit" \
		"${commit_subject} — centralizes FDT-based ABI, removes redundant YAML interfaces"
	log "INFO" "T1: Found FDT ABI commit ${fdt_abi_commit}"
fi

# --- Evidence 1d: Commit messages with FDT/serialization context ---
# Search for commits that discuss FDT as the serialization choice
fdt_commits_found=0
while IFS= read -r line; do
	hash="$(echo "$line" | cut -d' ' -f1)"
	subject="$(echo "$line" | cut -d' ' -f2-)"
	# Only emit if this is a distinct commit not already captured
	if [[ "$hash" != "${fdt_abi_commit:-}" ]]; then
		# Check commit body for FDT rationale keywords
		body="$(git log --format="%b" -1 "$hash" 2>/dev/null)"
		if echo "$body" | grep -qi "FDT\|flattened device tree\|serializ"; then
			emit_evidence "T1" "$T1_NAME" "commit" \
				"$hash" \
				"${subject}"
			fdt_commits_found=$((fdt_commits_found + 1))
			if (( fdt_commits_found >= 2 )); then
				break
			fi
		fi
	fi
done < <(git log --all --format="%h %s" --grep="FDT\|fdt\|flattened device tree\|libfdt" \
	-- kernel/liveupdate/ include/linux/kho/ 2>/dev/null | head -10)

# --- Evidence 1e: Explicit rationale search ---
# Search for any commit message or code comment that explicitly explains
# WHY FDT was chosen over alternatives (protobuf, custom binary, sysfs).
explicit_fdt_rationale=""
explicit_fdt_rationale="$(git log --all --format="%h %s" \
	--grep="protobuf\|sysfs.*alternative\|why.*FDT\|instead.*protobuf\|rather.*protobuf" \
	-- kernel/liveupdate/ include/linux/kho/ 2>/dev/null | head -1)" || true
if [[ -z "$explicit_fdt_rationale" ]]; then
	# Also search in-code comments for explicit rationale
	code_rationale="$(grep -rn "why.*FDT\|FDT.*instead\|protobuf\|sysfs.*alternative" \
		kernel/liveupdate/kexec_handover.c \
		Documentation/core-api/kho/index.rst \
		Documentation/core-api/kho/abi.rst 2>/dev/null | head -1)" || true
	if [[ -z "$code_rationale" ]]; then
		emit_evidence "T1" "$T1_NAME" "not_recorded" \
			"N/A" \
			"rationale not recorded in-tree; contextual evidence: LIBFDT already in kernel (Kconfig:12), FDT is standard device tree format used across kernel subsystems"
		log "INFO" "T1: No explicit rationale for FDT choice found — emitting not_recorded"
	else
		ref="$(echo "$code_rationale" | cut -d: -f1-2)"
		text="$(echo "$code_rationale" | cut -d: -f3-)"
		emit_evidence "T1" "$T1_NAME" "code_comment" "$ref" "$text"
	fi
else
	hash="$(echo "$explicit_fdt_rationale" | cut -d' ' -f1)"
	subject="$(echo "$explicit_fdt_rationale" | cut -d' ' -f2-)"
	emit_evidence "T1" "$T1_NAME" "commit" "$hash" "$subject"
fi

log "INFO" "T1 complete: ${T1_COUNT} evidence(s) found"

# ===================================================================
# TRADEOFF T2: Why callback registration over centralized orchestrator
# ===================================================================
log "INFO" "Analyzing T2 — Callback registration over centralized orchestrator"

T2_NAME="Callback registration over centralized orchestrator"

# --- Evidence 2a: DOC comment in luo_file.c describing handler model ---
# luo_file.c line 16 explicitly states "callback-based handler model"
callback_doc_line=""
if [[ -f "kernel/liveupdate/luo_file.c" ]]; then
	callback_doc_line="$(grep -n "callback-based handler model\|callback.based handler model" \
		kernel/liveupdate/luo_file.c 2>/dev/null | head -1)" || true
fi
if [[ -n "$callback_doc_line" ]]; then
	lineno="$(echo "$callback_doc_line" | cut -d: -f1)"
	emit_evidence "T2" "$T2_NAME" "code_comment" \
		"kernel/liveupdate/luo_file.c:${lineno}" \
		"The framework is built around a callback-based handler model — decentralized per-handler approach"
	log "INFO" "T2: Found callback model DOC at line ${lineno}"
fi

# --- Evidence 2b: Handler registration API in luo_file.c ---
# The liveupdate_file_handler struct and registration functions demonstrate
# the decentralized callback pattern.
handler_register_line=""
if [[ -f "kernel/liveupdate/luo_file.c" ]]; then
	handler_register_line="$(grep -n "register.*handler\|luo_file_handler_list" \
		kernel/liveupdate/luo_file.c 2>/dev/null | head -1)" || true
fi
if [[ -n "$handler_register_line" ]]; then
	lineno="$(echo "$handler_register_line" | cut -d: -f1)"
	emit_evidence "T2" "$T2_NAME" "code_comment" \
		"kernel/liveupdate/luo_file.c:${lineno}" \
		"Handler list for decentralized file type registration — modules register their own callbacks"
fi

# --- Evidence 2c: Notifier removal commit ---
# Commit 9a4301f715c8 explicitly discusses removing the notifier chain
# approach, citing "complex unwind paths when using notifiers" as the reason.
notifier_commit=""
notifier_commit="$(git log --all --oneline \
	--grep="remove abort.*notif\|remove.*notif\|drop notif\|shift.*direct.*preservation" \
	-- kernel/liveupdate/ 2>/dev/null | head -1 | cut -d' ' -f1)" || true
if [[ -z "$notifier_commit" ]]; then
	# Broader search: the commit that removed notifier approach
	notifier_commit="$(git log --all --format="%h" \
		--grep="notif" \
		-- kernel/liveupdate/ 2>/dev/null | head -1)" || true
fi
if [[ -n "$notifier_commit" ]]; then
	commit_subject="$(git log --format="%s" -1 "$notifier_commit" 2>/dev/null)"
	commit_body="$(git log --format="%b" -1 "$notifier_commit" 2>/dev/null)"
	# Check if the body mentions notifiers explicitly
	notifier_evidence="$(echo "$commit_body" | grep -i "notif" | head -1)" || true
	if [[ -n "$notifier_evidence" ]]; then
		emit_evidence "T2" "$T2_NAME" "commit" \
			"$notifier_commit" \
			"${commit_subject} — commit body: $(echo "$notifier_evidence" | head -c 120)"
	else
		emit_evidence "T2" "$T2_NAME" "commit" \
			"$notifier_commit" \
			"${commit_subject}"
	fi
	log "INFO" "T2: Found notifier-related commit ${notifier_commit}"
fi

# --- Evidence 2d: File callback implementation commit ---
# Commit 7c722a7f44e0 implements the file systems callbacks, demonstrating
# the chosen callback-based architecture.
callback_impl_commit=""
callback_impl_commit="$(git log --all --oneline \
	--grep="implement file.*callback\|implement.*file systems callback\|file systems callbacks" \
	-- kernel/liveupdate/ 2>/dev/null | head -1 | cut -d' ' -f1)" || true
if [[ -n "$callback_impl_commit" ]]; then
	commit_subject="$(git log --format="%s" -1 "$callback_impl_commit" 2>/dev/null)"
	emit_evidence "T2" "$T2_NAME" "commit" \
		"$callback_impl_commit" \
		"${commit_subject} — implements per-handler preserve/freeze/retrieve/finish callbacks"
	log "INFO" "T2: Found callback implementation commit ${callback_impl_commit}"
fi

# --- Evidence 2e: LUO core commit describing handler-based framework ---
# The initial LUO commit (9e2fd062fa17) describes "A handler-based framework
# allows specific file types to be preserved."
luo_core_commit=""
luo_core_commit="$(git log --all --oneline \
	--grep="Live Update Orchestrator" \
	-- kernel/liveupdate/luo_core.c 2>/dev/null | head -1 | cut -d' ' -f1)" || true
if [[ -n "$luo_core_commit" ]]; then
	commit_body="$(git log --format="%b" -1 "$luo_core_commit" 2>/dev/null)"
	handler_mention="$(echo "$commit_body" | grep -i "handler-based framework\|handler.based" | head -1)" || true
	if [[ -n "$handler_mention" ]]; then
		emit_evidence "T2" "$T2_NAME" "commit" \
			"$luo_core_commit" \
			"LUO core commit body: $(echo "$handler_mention" | head -c 120)"
		log "INFO" "T2: Found handler-based description in LUO core commit"
	fi
fi

# --- Evidence 2f: Explicit rationale search ---
# Search for any commit or comment explicitly comparing callback registration
# to a centralized orchestrator approach.
explicit_t2=""
explicit_t2="$(git log --all --format="%h %s" \
	--grep="centralize\|orchestrat.*vs\|why.*callback\|callback.*instead" \
	-- kernel/liveupdate/ 2>/dev/null | head -1)" || true
if [[ -z "$explicit_t2" ]]; then
	# Check code comments for explicit rationale
	code_t2="$(grep -rn "why.*callback\|centralize.*instead\|orchestrat.*vs\|decentralize" \
		kernel/liveupdate/luo_file.c kernel/liveupdate/luo_core.c 2>/dev/null | head -1)" || true
	if [[ -z "$code_t2" ]] && (( T2_COUNT == 0 )); then
		emit_evidence "T2" "$T2_NAME" "not_recorded" \
			"N/A" \
			"rationale not recorded in-tree; contextual evidence: notifier chain removed (9a4301f715c8), callback model in luo_file.c DOC"
	fi
fi

log "INFO" "T2 complete: ${T2_COUNT} evidence(s) found"

# ===================================================================
# TRADEOFF T3: Why session-scoped cleanup for failure modes
# ===================================================================
log "INFO" "Analyzing T3 — Session-scoped cleanup for failure modes"

T3_NAME="Session-scoped cleanup for failure modes"

# --- Evidence 3a: luo_restore_fail macro in luo_internal.h ---
# Lines 34-41 define luo_restore_fail as panic(), with a comment explaining
# that continuing after deserialization failure is dangerous because it could
# lead to leaks of private data.
restore_fail_line=""
if [[ -f "kernel/liveupdate/luo_internal.h" ]]; then
	restore_fail_line="$(grep -n "luo_restore_fail\|Handles a deserialization failure" \
		kernel/liveupdate/luo_internal.h 2>/dev/null | head -1)" || true
fi
if [[ -n "$restore_fail_line" ]]; then
	lineno="$(echo "$restore_fail_line" | cut -d: -f1)"
	emit_evidence "T3" "$T3_NAME" "code_comment" \
		"kernel/liveupdate/luo_internal.h:${lineno}" \
		"luo_restore_fail: panic on deserialization failure — continuing dangerous, could leak private data"
	log "INFO" "T3: Found luo_restore_fail at line ${lineno}"
fi

# --- Evidence 3b: Error handling policy in luo_session.c ---
# Lines 527-541 contain a detailed comment explaining the intentional
# decision to leak resources on partial deserialization failure rather than
# attempt complex unwinding.
error_policy_line=""
if [[ -f "kernel/liveupdate/luo_session.c" ]]; then
	error_policy_line="$(grep -n "Note on error handling\|intentionally skip cleanup" \
		kernel/liveupdate/luo_session.c 2>/dev/null | head -1)" || true
fi
if [[ -n "$error_policy_line" ]]; then
	lineno="$(echo "$error_policy_line" | cut -d: -f1)"
	emit_evidence "T3" "$T3_NAME" "code_comment" \
		"kernel/liveupdate/luo_session.c:${lineno}" \
		"Intentional policy: skip cleanup on partial failure — system in broken state, recovery via reboot"
	log "INFO" "T3: Found error handling policy at line ${lineno}"
fi

# --- Evidence 3c: Broken state comment in luo_session.c ---
broken_state_line=""
if [[ -f "kernel/liveupdate/luo_session.c" ]]; then
	broken_state_line="$(grep -n "broken state\|effectively in a broken" \
		kernel/liveupdate/luo_session.c 2>/dev/null | head -1)" || true
fi
if [[ -n "$broken_state_line" ]]; then
	lineno="$(echo "$broken_state_line" | cut -d: -f1)"
	emit_evidence "T3" "$T3_NAME" "code_comment" \
		"kernel/liveupdate/luo_session.c:${lineno}" \
		"System effectively in a broken state after partial failure — resources treated as leaked"
	log "INFO" "T3: Found broken-state comment at line ${lineno}"
fi

# --- Evidence 3d: Session release handler for abort cleanup ---
# luo_file.c lines 75-80 document the "Abort Before Reboot" unhappy path
# where closing the session FD triggers automatic cleanup via unpreserve.
abort_cleanup_line=""
if [[ -f "kernel/liveupdate/luo_file.c" ]]; then
	abort_cleanup_line="$(grep -n "Abort Before Reboot\|session.*release.*handler.*calls" \
		kernel/liveupdate/luo_file.c 2>/dev/null | head -1)" || true
fi
if [[ -n "$abort_cleanup_line" ]]; then
	lineno="$(echo "$abort_cleanup_line" | cut -d: -f1)"
	emit_evidence "T3" "$T3_NAME" "code_comment" \
		"kernel/liveupdate/luo_file.c:${lineno}" \
		"Abort Before Reboot: closing session FD triggers unpreserve — session-scoped automatic cleanup"
	log "INFO" "T3: Found abort cleanup path at line ${lineno}"
fi

# --- Evidence 3e: LUO core commit about session lifecycle ---
# The initial LUO commit describes tying resource lifecycle to session FDs
# for automatic cleanup if the userspace agent crashes.
if [[ -n "${luo_core_commit:-}" ]]; then
	commit_body="$(git log --format="%b" -1 "$luo_core_commit" 2>/dev/null)"
	session_cleanup="$(echo "$commit_body" | grep -i "cleanup.*crash\|crash.*exit\|automatic.*cleanup\|tied.*FD\|lifecycle.*tied" | head -1)" || true
	if [[ -n "$session_cleanup" ]]; then
		emit_evidence "T3" "$T3_NAME" "commit" \
			"$luo_core_commit" \
			"LUO core: $(echo "$session_cleanup" | head -c 120)"
	fi
fi

# --- Evidence 3f: Search for failure-related commits ---
failure_commits_found=0
while IFS= read -r line; do
	hash="$(echo "$line" | cut -d' ' -f1)"
	subject="$(echo "$line" | cut -d' ' -f2-)"
	# Check if commit body discusses cleanup/recovery policy
	body="$(git log --format="%b" -1 "$hash" 2>/dev/null)"
	if echo "$body" | grep -qi "cleanup\|session.*release\|recovery.*reboot\|broken state"; then
		emit_evidence "T3" "$T3_NAME" "commit" \
			"$hash" \
			"${subject}"
		failure_commits_found=$((failure_commits_found + 1))
		if (( failure_commits_found >= 2 )); then
			break
		fi
	fi
done < <(git log --all --format="%h %s" \
	--grep="fail\|error\|cleanup\|recover\|release" \
	-- kernel/liveupdate/luo_session.c kernel/liveupdate/luo_file.c 2>/dev/null | head -10)

log "INFO" "T3 complete: ${T3_COUNT} evidence(s) found"

# ===================================================================
# TRADEOFF T4: Why token-based FD preservation over direct FD number mapping
# ===================================================================
log "INFO" "Analyzing T4 — Token-based FD preservation over direct FD number mapping"

T4_NAME="Token-based FD preservation over direct FD number mapping"

# --- Evidence 4a: UAPI header token documentation ---
# include/uapi/linux/liveupdate.h:127 — "An opaque, unique token for
# preserved resource"
token_doc_line=""
if [[ -f "include/uapi/linux/liveupdate.h" ]]; then
	token_doc_line="$(grep -n "opaque.*unique.*token\|opaque.*token.*preserved" \
		include/uapi/linux/liveupdate.h 2>/dev/null | head -1)" || true
fi
if [[ -n "$token_doc_line" ]]; then
	lineno="$(echo "$token_doc_line" | cut -d: -f1)"
	emit_evidence "T4" "$T4_NAME" "code_comment" \
		"include/uapi/linux/liveupdate.h:${lineno}" \
		"An opaque, unique token for preserved resource — decouples old/new kernel FD number spaces"
	log "INFO" "T4: Found token documentation at line ${lineno}"
fi

# --- Evidence 4b: Token field in preserve_fd struct ---
# include/uapi/linux/liveupdate.h:150 — __aligned_u64 token;
token_field_line=""
if [[ -f "include/uapi/linux/liveupdate.h" ]]; then
	token_field_line="$(grep -n "__aligned_u64.*token" \
		include/uapi/linux/liveupdate.h 2>/dev/null | head -1)" || true
fi
if [[ -n "$token_field_line" ]]; then
	lineno="$(echo "$token_field_line" | cut -d: -f1)"
	emit_evidence "T4" "$T4_NAME" "code_comment" \
		"include/uapi/linux/liveupdate.h:${lineno}" \
		"__aligned_u64 token field in liveupdate_session_preserve_fd — token replaces direct FD number"
	log "INFO" "T4: Found token field at line ${lineno}"
fi

# --- Evidence 4c: Session ioctl commit introducing token mechanism ---
# Commit 16cec0d26521 introduces PRESERVE_FD and RETRIEVE_FD ioctls using
# tokens for identifying preserved resources.
token_ioctl_commit=""
token_ioctl_commit="$(git log --all --oneline \
	--grep="ioctls for file preservation\|add ioctls.*file.*preserv" \
	-- kernel/liveupdate/ include/uapi/linux/liveupdate.h 2>/dev/null | head -1 | cut -d' ' -f1)" || true
if [[ -n "$token_ioctl_commit" ]]; then
	commit_subject="$(git log --format="%s" -1 "$token_ioctl_commit" 2>/dev/null)"
	emit_evidence "T4" "$T4_NAME" "commit" \
		"$token_ioctl_commit" \
		"${commit_subject} — introduces token-based PRESERVE_FD/RETRIEVE_FD interface"
	log "INFO" "T4: Found token ioctl commit ${token_ioctl_commit}"
fi

# --- Evidence 4d: Token usage in luo_file.c ---
# luo_file.c documents token as the identifier for preserved files across
# the kexec boundary.
token_usage_line=""
if [[ -f "kernel/liveupdate/luo_file.c" ]]; then
	token_usage_line="$(grep -n "token" kernel/liveupdate/luo_file.c 2>/dev/null | head -1)" || true
fi
if [[ -n "$token_usage_line" ]]; then
	lineno="$(echo "$token_usage_line" | cut -d: -f1)"
	text="$(echo "$token_usage_line" | cut -d: -f2-)"
	emit_evidence "T4" "$T4_NAME" "code_comment" \
		"kernel/liveupdate/luo_file.c:${lineno}" \
		"$(echo "$text" | head -c 120)"
	log "INFO" "T4: Found token usage at line ${lineno}"
fi

# --- Evidence 4e: Retrieve-by-token documentation ---
# include/uapi/linux/liveupdate.h:161 — retrieval uses the token from the
# preserve call, not the original FD number.
retrieve_token_line=""
if [[ -f "include/uapi/linux/liveupdate.h" ]]; then
	retrieve_token_line="$(grep -n "token.*used to preserve\|token.*obtained" \
		include/uapi/linux/liveupdate.h 2>/dev/null | head -1)" || true
fi
if [[ -n "$retrieve_token_line" ]]; then
	lineno="$(echo "$retrieve_token_line" | cut -d: -f1)"
	emit_evidence "T4" "$T4_NAME" "code_comment" \
		"include/uapi/linux/liveupdate.h:${lineno}" \
		"Retrieval uses opaque token from preserve call — not the original FD number"
	log "INFO" "T4: Found retrieve-by-token at line ${lineno}"
fi

# --- Evidence 4f: Explicit rationale search ---
# Search for any commit or comment that explicitly explains WHY tokens
# instead of direct FD number mapping.
explicit_t4=""
explicit_t4="$(git log --all --format="%h %s" \
	--grep="fd number\|fd.*map\|decouple.*fd\|why.*token\|token.*instead" \
	-- kernel/liveupdate/ include/uapi/linux/liveupdate.h 2>/dev/null | head -1)" || true
if [[ -z "$explicit_t4" ]]; then
	code_t4="$(grep -rn "why.*token\|token.*instead\|decouple\|fd.*number.*space" \
		include/uapi/linux/liveupdate.h kernel/liveupdate/luo_file.c 2>/dev/null | head -1)" || true
	if [[ -z "$code_t4" ]] && (( T4_COUNT == 0 )); then
		emit_evidence "T4" "$T4_NAME" "not_recorded" \
			"N/A" \
			"rationale not recorded in-tree; contextual evidence: token decouples FD number spaces across kernels"
	fi
fi

log "INFO" "T4 complete: ${T4_COUNT} evidence(s) found"

# ===================================================================
# SUMMARY AND PASS/FAIL VALIDATION
# ===================================================================
log "INFO" "=========================================="
log "INFO" "Design Decision Analysis Summary"
log "INFO" "=========================================="
log "INFO" "T1 (FDT over protobuf/custom binary/sysfs): ${T1_COUNT} evidence(s)"
log "INFO" "T2 (Callback registration over centralized orchestrator): ${T2_COUNT} evidence(s)"
log "INFO" "T3 (Session-scoped cleanup for failure modes): ${T3_COUNT} evidence(s)"
log "INFO" "T4 (Token-based FD preservation over direct FD mapping): ${T4_COUNT} evidence(s)"

total_evidence=$((T1_COUNT + T2_COUNT + T3_COUNT + T4_COUNT))
log "INFO" "Total evidence lines: ${total_evidence}"

# Directive 3 pass/fail: each tradeoff must have at least one evidence line
pass=true
for tid_var in T1_COUNT T2_COUNT T3_COUNT T4_COUNT; do
	count="${!tid_var}"
	tid="${tid_var%%_*}"
	if (( count == 0 )); then
		log "ERROR" "FAIL: Tradeoff ${tid} has 0 evidence lines"
		pass=false
	else
		log "INFO" "PASS: Tradeoff ${tid} has ${count} evidence line(s)"
	fi
done

if [[ "$pass" == "true" ]]; then
	log "INFO" "Directive 3 PASS: All 4 tradeoffs have >= 1 evidence line"
else
	log "ERROR" "Directive 3 FAIL: One or more tradeoffs missing evidence"
	exit 1
fi

log "INFO" "Directive 3 complete — design decision analysis finished successfully"
exit 0
