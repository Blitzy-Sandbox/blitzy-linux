#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# bottlenecks.sh — Directive 5: Identify Development Bottlenecks
#
# Analyzes the commit timeline for the Linux kernel Live Update subsystem
# to identify inactivity periods (>3 months), reverted commits, persistent
# technical debt markers (TODO/FIXME/HACK across >=3 commits), and
# incomplete components (mentioned/designed but not yet implemented).
#
# Two-tier path classification (consistent with authorship.sh):
#   - EXCLUSIVE paths: files that exist solely for Live Update / KHO.
#     All commits are relevant for inactivity and revert analysis.
#   - SHARED paths: integration files (memblock.c) that serve broader
#     purposes.  Only commits with KHO/LU-related messages are counted
#     to avoid polluting bottleneck data with unrelated history.
#
# Output format (TSV to stdout):
#   bottleneck_type	classification	evidence_hash	evidence_detail	date_range
#
#   bottleneck_type values: INACTIVITY, REVERT, PERSISTENT_MARKER, INCOMPLETE
#   classification values: blocked, contested, abandoned, deferred
#
# Structured logs are emitted to stderr in the format:
#   [LU-ARCH-D5-<timestamp>] [<level>] <message>
#
# Zero Speculation Rule (AAP §0.8.1):
#   Every classification is supported by commit evidence (dates, hashes, grep
#   results).  Where rationale is absent, the exact phrasing "rationale not
#   recorded in-tree" is used — no inference presented as fact.
#
# Thresholds:
#   - Inactivity: >3 months (>90 days) gap between consecutive commits
#   - Persistent markers: same TODO/FIXME/HACK present across >=3 commits
#
# Usage:
#   cd <kernel-repo-root>
#   bash tools/liveupdate/archaeology/bottlenecks.sh
#   # TSV goes to stdout; logs go to stderr.

set -euo pipefail

# ===========================================================================
# Observability: correlation ID and structured logging
# ===========================================================================
readonly CORR_ID="LU-ARCH-D5-$(date -u +%Y%m%dT%H%M%S)"
readonly TAB=$'\t'

log() {
	local level="$1"
	shift
	echo "[$CORR_ID] [$level] $*" >&2
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
log "INFO" "Starting Directive 5 — Identify Development Bottlenecks"

# ===========================================================================
# Path classification: EXCLUSIVE vs SHARED
#
# EXCLUSIVE_PATHS: files that exist solely for Live Update / KHO.
# Every commit touching these files is relevant.
#
# SHARED_PATHS: integration files that serve broader subsystems.
# Only commits whose message references kho/kexec_handover/liveupdate
# are considered to avoid noise from unrelated history.
#
# MANIFEST_PATHS: union of both, for marker and incomplete scans.
# ===========================================================================
EXCLUSIVE_PATHS=(
	"kernel/liveupdate/"
	"include/linux/liveupdate.h"
	"include/uapi/linux/liveupdate.h"
	"include/linux/kexec_handover.h"
	"include/linux/kho/"
	"mm/memfd_luo.c"
)

SHARED_PATHS=(
	"mm/memblock.c"
)

MANIFEST_PATHS=( "${EXCLUSIVE_PATHS[@]}" "${SHARED_PATHS[@]}" )

# Grep pattern for filtering shared-path commits to KHO/LU-relevant only
readonly LU_GREP="kho\|kexec_handover\|liveupdate\|live.update\|KHO\|KEXEC_HANDOVER\|LIVEUPDATE\|kho_scratch\|SETUP_KEXEC_KHO"

# Inactivity gap threshold in seconds (90 days = 3 months)
readonly GAP_THRESHOLD_SECONDS=$(( 90 * 24 * 60 * 60 ))
readonly GAP_THRESHOLD_DAYS=90

# Counters for summary
count_inactivity=0
count_revert=0
count_persistent=0
count_incomplete=0

# ===========================================================================
# Print TSV header
# ===========================================================================
echo -e "bottleneck_type\tclassification\tevidence_hash\tevidence_detail\tdate_range"

# ===========================================================================
# Helper: convert ISO 8601 date to epoch seconds via GNU date -d
# Falls back to 0 on parse failure.
# ===========================================================================
iso_to_epoch() {
	local iso_date="$1"
	date -d "$iso_date" +%s 2>/dev/null || echo "0"
}

# ===========================================================================
# Helper: extract short date (YYYY-MM-DD) from ISO 8601
# ===========================================================================
iso_to_short() {
	local iso_date="$1"
	echo "${iso_date%%T*}"
}

# ===========================================================================
# Temporary files with cleanup trap
# ===========================================================================
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

# ###########################################################################
# PHASE 1: Inactivity Period Analysis
#
# Extracts chronological commit dates from EXCLUSIVE paths (all commits)
# plus KHO-filtered commits from SHARED paths.  Computes gaps >90 days.
# ###########################################################################
log "INFO" "Phase 1: Analyzing inactivity periods (gaps > ${GAP_THRESHOLD_DAYS} days)"

# Collect commit dates from exclusive paths (all commits relevant)
git log --all --format="%aI${TAB}%H" -- "${EXCLUSIVE_PATHS[@]}" 2>/dev/null \
	> "${tmpdir}/dates_raw.tsv" || true

# Collect KHO-related commit dates from shared paths
for spath in "${SHARED_PATHS[@]}"; do
	git log --all --format="%aI${TAB}%H${TAB}%s" -- "$spath" 2>/dev/null \
		| grep -i "$LU_GREP" \
		| cut -f1,2 \
		>> "${tmpdir}/dates_raw.tsv" || true
done

# Sort chronologically, deduplicate by commit hash, convert to epoch
sort -t"${TAB}" -k1,1 "${tmpdir}/dates_raw.tsv" \
	| awk -F'\t' '!seen[$2]++ { print }' \
	> "${tmpdir}/dates_dedup.tsv"

# Build epoch-sorted file: epoch<TAB>iso_date<TAB>hash
while IFS="${TAB}" read -r iso_date commit_hash rest; do
	if [[ -z "$iso_date" || -z "$commit_hash" ]]; then
		continue
	fi
	epoch="$(iso_to_epoch "$iso_date")"
	if [[ "$epoch" -eq 0 ]]; then
		continue
	fi
	echo "${epoch}${TAB}${iso_date}${TAB}${commit_hash}"
done < "${tmpdir}/dates_dedup.tsv" | sort -t"${TAB}" -k1,1n \
	> "${tmpdir}/dates_sorted.tsv"

# Walk consecutive pairs and detect gaps exceeding threshold
prev_epoch=""
prev_date=""
prev_hash=""

while IFS="${TAB}" read -r epoch iso_date commit_hash; do
	if [[ -z "$prev_epoch" ]]; then
		prev_epoch="$epoch"
		prev_date="$iso_date"
		prev_hash="$commit_hash"
		continue
	fi

	gap_seconds=$(( epoch - prev_epoch ))
	if [[ "$gap_seconds" -gt "$GAP_THRESHOLD_SECONDS" ]]; then
		gap_days=$(( gap_seconds / 86400 ))
		short_before="$(iso_to_short "$prev_date")"
		short_after="$(iso_to_short "$iso_date")"

		# Classification: default to "deferred" per Zero Speculation Rule.
		# We document the gap and evidence without inferring causation.
		classification="deferred"

		echo -e "INACTIVITY\t${classification}\t${prev_hash}\tGap of ${gap_days} days between ${short_before} and ${short_after}\t${short_before} to ${short_after}"
		count_inactivity=$(( count_inactivity + 1 ))
	fi

	prev_epoch="$epoch"
	prev_date="$iso_date"
	prev_hash="$commit_hash"
done < "${tmpdir}/dates_sorted.tsv"

log "INFO" "Found ${count_inactivity} inactivity periods exceeding ${GAP_THRESHOLD_DAYS} days"

# ###########################################################################
# PHASE 2: Reverted Commits
#
# Searches for "Revert" in commit messages touching EXCLUSIVE paths (all)
# and SHARED paths (KHO-filtered).  Deduplicates and extracts evidence.
# ###########################################################################
log "INFO" "Phase 2: Searching for reverted commits"

# Exclusive paths: all reverts are relevant
{
	git log --all --format="%H${TAB}%aI${TAB}%s" --grep="Revert" \
		-- "${EXCLUSIVE_PATHS[@]}" 2>/dev/null || true
	git log --all --format="%H${TAB}%aI${TAB}%s" --grep="revert" -i \
		-- "${EXCLUSIVE_PATHS[@]}" 2>/dev/null || true
} > "${tmpdir}/reverts_exclusive.tsv"

# Shared paths: only KHO-related reverts
for spath in "${SHARED_PATHS[@]}"; do
	{
		git log --all --format="%H${TAB}%aI${TAB}%s" --grep="Revert" \
			-- "$spath" 2>/dev/null || true
		git log --all --format="%H${TAB}%aI${TAB}%s" --grep="revert" -i \
			-- "$spath" 2>/dev/null || true
	} | grep -i "$LU_GREP" >> "${tmpdir}/reverts_shared.tsv" || true
done

# Merge and deduplicate
cat "${tmpdir}/reverts_exclusive.tsv" "${tmpdir}/reverts_shared.tsv" 2>/dev/null \
	| sort -t"${TAB}" -k1,1 -u \
	> "${tmpdir}/reverts_all.tsv"

while IFS="${TAB}" read -r rev_hash rev_date rev_subject; do
	if [[ -z "$rev_hash" || -z "$rev_subject" ]]; then
		continue
	fi

	# Extract the original reverted commit hash from the commit body.
	# Standard git revert format: "This reverts commit <hash>."
	original_hash=""
	original_hash="$(git log -1 --format="%b" "$rev_hash" 2>/dev/null \
		| grep -oP 'This reverts commit \K[0-9a-f]+' || true)"
	if [[ -z "$original_hash" ]]; then
		original_hash="N/A"
	fi

	short_date="$(iso_to_short "$rev_date")"

	# Classification: "contested" — a revert indicates a change was backed
	# out.  Per Zero Speculation Rule, we do not infer the specific reason
	# without further commit message evidence.
	classification="contested"

	detail="Reverts ${original_hash}: ${rev_subject}"
	echo -e "REVERT\t${classification}\t${rev_hash}\t${detail}\t${short_date}"
	count_revert=$(( count_revert + 1 ))
done < "${tmpdir}/reverts_all.tsv"

if [[ "$count_revert" -eq 0 ]]; then
	log "INFO" "No reverted commits found in manifest files"
else
	log "INFO" "Found ${count_revert} reverted commits"
fi

# ###########################################################################
# PHASE 3: Persistent TODO/FIXME/HACK Markers
#
# Finds markers in current HEAD source files, then checks how many commits
# have touched the file since the marker was introduced.  A marker is
# "persistent" if it has survived across >=3 commits to the same file.
# ###########################################################################
log "INFO" "Phase 3: Analyzing persistent TODO/FIXME/HACK markers"

# Search for markers in LUO-exclusive source and KHO-related shared files.
# For mm/memblock.c, only include markers related to KHO/scratch.
{
	grep -rn "TODO\|FIXME\|HACK" kernel/liveupdate/ 2>/dev/null || true
	grep -rn "TODO\|FIXME\|HACK" mm/memfd_luo.c 2>/dev/null || true
	grep -n "TODO\|FIXME\|HACK" mm/memblock.c 2>/dev/null \
		| grep -i "kho\|scratch\|handover\|liveupdate" || true
} > "${tmpdir}/markers.txt"

while IFS=: read -r mfile mline mtext; do
	if [[ -z "$mfile" || -z "$mline" || -z "$mtext" ]]; then
		continue
	fi

	# Extract a searchable pattern from the marker text.
	# Strip leading whitespace, comment delimiters, and truncate.
	pattern="$(echo "$mtext" \
		| sed 's|^[[:space:]]*[/*]*[[:space:]]*||; s|[[:space:]]*\*/[[:space:]]*$||' \
		| head -c 60)"

	if [[ -z "$pattern" ]]; then
		continue
	fi

	# Find when this marker was first introduced using git log -S
	# (pickaxe: finds commits that changed the count of the pattern).
	intro_hash=""
	intro_hash="$(git log --all --reverse --diff-filter=A --format="%H" \
		-S "$pattern" -- "$mfile" 2>/dev/null | head -1 || true)"
	if [[ -z "$intro_hash" ]]; then
		# Fallback: first commit introducing any change with this pattern
		intro_hash="$(git log --all --reverse --format="%H" \
			-S "$pattern" -- "$mfile" 2>/dev/null | head -1 || true)"
	fi
	if [[ -z "$intro_hash" ]]; then
		# Last fallback: first commit touching the file
		intro_hash="$(git log --all --reverse --format="%H" \
			-- "$mfile" 2>/dev/null | head -1 || true)"
	fi

	# Count commits touching this file since the marker was introduced.
	# If >=3 commits have been made to the file while the marker persists,
	# it qualifies as persistent technical debt.
	if [[ -n "$intro_hash" ]]; then
		commits_since="$(git log --all --oneline "$intro_hash"..HEAD \
			-- "$mfile" 2>/dev/null | wc -l || true)"
		commits_since="${commits_since:-0}"
		# Strip whitespace from wc output
		commits_since="$(echo "$commits_since" | tr -d '[:space:]')"
	else
		commits_since="0"
	fi

	if [[ "$commits_since" -ge 3 ]]; then
		intro_date_short="N/A"
		if [[ -n "$intro_hash" ]]; then
			intro_date="$(git log -1 --format="%aI" "$intro_hash" 2>/dev/null || true)"
			if [[ -n "$intro_date" ]]; then
				intro_date_short="$(iso_to_short "$intro_date")"
			fi
		fi

		detail="${pattern} at ${mfile}:${mline} persisted across ${commits_since} commits since introduction"
		echo -e "PERSISTENT_MARKER\tdeferred\t${intro_hash}\t${detail}\t${intro_date_short} to current"
		count_persistent=$(( count_persistent + 1 ))
	fi
done < "${tmpdir}/markers.txt"

log "INFO" "Found ${count_persistent} persistent technical debt markers (>=3 commits)"

# ###########################################################################
# PHASE 4: Incomplete Components
#
# Identifies features mentioned in design documentation or code comments
# but not yet implemented.  Each finding is supported by file:line evidence.
# ###########################################################################
log "INFO" "Phase 4: Identifying incomplete (mentioned but unimplemented) components"

# --- 4a: KVM integration ---
# luo_core.c DOC block lists "kvm" as an example subsystem that can hook
# into LUO, but no KVM-specific live update handler exists.
kvm_evidence_line=""
kvm_evidence_line="$( { grep -n "kvm" kernel/liveupdate/luo_core.c 2>/dev/null || true; } \
	| head -1 | cut -d: -f1 )"
if [[ -n "$kvm_evidence_line" ]]; then
	kvm_handler_count="$( { grep -rn \
		"liveupdate_register_file_handler.*kvm\|kvm.*liveupdate_file_handler" \
		kernel/ drivers/ 2>/dev/null || true; } | wc -l )"
	kvm_handler_count="$(echo "$kvm_handler_count" | tr -d '[:space:]')"
	if [[ "$kvm_handler_count" -eq 0 ]]; then
		echo -e "INCOMPLETE\tdeferred\tN/A\tKVM integration: luo_core.c:${kvm_evidence_line} lists kvm as example subsystem but no KVM file handler registered\t-"
		count_incomplete=$(( count_incomplete + 1 ))
	fi
fi

# --- 4b: Device driver handlers (vfio, iommufd) ---
# luo_file.c DOC block lists "vfio, memfd, or iommufd" as target file types
# but only memfd handler exists (mm/memfd_luo.c).
vfio_evidence_line=""
vfio_evidence_line="$( { grep -n "vfio" kernel/liveupdate/luo_file.c 2>/dev/null || true; } \
	| head -1 | cut -d: -f1 )"
if [[ -n "$vfio_evidence_line" ]]; then
	vfio_handler_count="$( { grep -rn \
		"liveupdate_register_file_handler.*vfio\|vfio.*liveupdate_file_handler" \
		kernel/ drivers/ 2>/dev/null || true; } | wc -l )"
	vfio_handler_count="$(echo "$vfio_handler_count" | tr -d '[:space:]')"
	iommufd_handler_count="$( { grep -rn \
		"liveupdate_register_file_handler.*iommufd\|iommufd.*liveupdate_file_handler" \
		kernel/ drivers/ 2>/dev/null || true; } | wc -l )"
	iommufd_handler_count="$(echo "$iommufd_handler_count" | tr -d '[:space:]')"
	if [[ "$vfio_handler_count" -eq 0 && "$iommufd_handler_count" -eq 0 ]]; then
		echo -e "INCOMPLETE\tdeferred\tN/A\tDevice driver handlers: luo_file.c:${vfio_evidence_line} mentions vfio and iommufd but only memfd handler exists\t-"
		count_incomplete=$(( count_incomplete + 1 ))
	fi
fi

# --- 4c: IOMMU integration ---
# luo_core.c DOC block lists "iommu" as an example subsystem.
iommu_evidence_line=""
iommu_evidence_line="$( { grep -n "iommu" kernel/liveupdate/luo_core.c 2>/dev/null || true; } \
	| head -1 | cut -d: -f1 )"
if [[ -n "$iommu_evidence_line" ]]; then
	iommu_handler_count="$( { grep -rn \
		"liveupdate.*iommu\|iommu.*liveupdate" \
		drivers/iommu/ 2>/dev/null || true; } | wc -l )"
	iommu_handler_count="$(echo "$iommu_handler_count" | tr -d '[:space:]')"
	if [[ "$iommu_handler_count" -eq 0 ]]; then
		echo -e "INCOMPLETE\tdeferred\tN/A\tIOMMU integration: luo_core.c:${iommu_evidence_line} lists iommu as example subsystem but no IOMMU handler registered\t-"
		count_incomplete=$(( count_incomplete + 1 ))
	fi
fi

# --- 4d: Interrupt subsystem integration ---
# luo_core.c DOC block lists "interrupts" as an example subsystem.
irq_evidence_line=""
irq_evidence_line="$( { grep -n "interrupts" kernel/liveupdate/luo_core.c 2>/dev/null || true; } \
	| head -1 | cut -d: -f1 )"
if [[ -n "$irq_evidence_line" ]]; then
	irq_handler_count="$( { grep -rn \
		"liveupdate.*interrupt\|interrupt.*liveupdate" \
		kernel/irq/ 2>/dev/null || true; } | wc -l )"
	irq_handler_count="$(echo "$irq_handler_count" | tr -d '[:space:]')"
	if [[ "$irq_handler_count" -eq 0 ]]; then
		echo -e "INCOMPLETE\tdeferred\tN/A\tInterrupt integration: luo_core.c:${irq_evidence_line} lists interrupts as example subsystem but no interrupt handler registered\t-"
		count_incomplete=$(( count_incomplete + 1 ))
	fi
fi

# --- 4e: NUMA node hot-plug ---
# kexec_handover.c has explicit FIXME for node hot-plug/remove.
fixme_line=""
fixme_line="$( { grep -n "FIXME.*node hot-plug" kernel/liveupdate/kexec_handover.c 2>/dev/null || true; } \
	| head -1 | cut -d: -f1 )"
if [[ -n "$fixme_line" ]]; then
	echo -e "INCOMPLETE\tdeferred\tN/A\tNUMA hot-plug: kexec_handover.c:${fixme_line} FIXME for node hot-plug/remove handling not implemented\t-"
	count_incomplete=$(( count_incomplete + 1 ))
fi

# --- 4f: Multi-architecture support ---
# ARCH_SUPPORTS_KEXEC_HANDOVER is defined in arch Kconfigs.  Document
# which architectures support it and flag limited coverage.
arch_count="$( { grep -rl "ARCH_SUPPORTS_KEXEC_HANDOVER" arch/ 2>/dev/null || true; } \
	| grep "Kconfig" | wc -l )"
arch_count="$(echo "$arch_count" | tr -d '[:space:]')"
if [[ "$arch_count" -le 2 ]]; then
	arch_list="$( { grep -rl "ARCH_SUPPORTS_KEXEC_HANDOVER" arch/ 2>/dev/null || true; } \
		| grep "Kconfig" \
		| sed 's|arch/||; s|/Kconfig||' \
		| tr '\n' ',' | sed 's/,$//' )"
	echo -e "INCOMPLETE\tdeferred\tN/A\tMulti-architecture support: ARCH_SUPPORTS_KEXEC_HANDOVER defined only in ${arch_list} (${arch_count} arch(es))\t-"
	count_incomplete=$(( count_incomplete + 1 ))
fi

# --- 4g: Filesystem integration ---
# luo_core.c DOC mentions "participating filesystems" as example subsystems.
fs_evidence_line=""
fs_evidence_line="$( { grep -n "filesystems" kernel/liveupdate/luo_core.c 2>/dev/null || true; } \
	| head -1 | cut -d: -f1 )"
if [[ -n "$fs_evidence_line" ]]; then
	fs_handler_count="$( { grep -rn "liveupdate_register_file_handler" fs/ 2>/dev/null || true; } \
		| wc -l )"
	fs_handler_count="$(echo "$fs_handler_count" | tr -d '[:space:]')"
	if [[ "$fs_handler_count" -eq 0 ]]; then
		echo -e "INCOMPLETE\tdeferred\tN/A\tFilesystem integration: luo_core.c:${fs_evidence_line} mentions participating filesystems but no FS handler registered\t-"
		count_incomplete=$(( count_incomplete + 1 ))
	fi
fi

# --- 4h: Memblock scratch allocation constraint ---
# mm/memblock.c has a TODO about allocation outside of scratch region.
memblock_todo_line=""
memblock_todo_line="$( { grep -n "TODO.*Allocation must be outside of scratch" mm/memblock.c 2>/dev/null || true; } \
	| head -1 | cut -d: -f1 )"
if [[ -n "$memblock_todo_line" ]]; then
	echo -e "INCOMPLETE\tdeferred\tN/A\tMemblock scratch constraint: mm/memblock.c:${memblock_todo_line} TODO for allocation outside scratch region\t-"
	count_incomplete=$(( count_incomplete + 1 ))
fi

log "INFO" "Found ${count_incomplete} incomplete components"

# ###########################################################################
# PHASE 5: Summary and Exit
# ###########################################################################
total=$(( count_inactivity + count_revert + count_persistent + count_incomplete ))
log "INFO" "Bottleneck analysis complete: ${count_inactivity} inactivity gaps, ${count_revert} reverts, ${count_persistent} persistent markers, ${count_incomplete} incomplete components"
log "INFO" "Total bottlenecks identified: ${total}"
log "INFO" "Directive 5 complete"

exit 0
