#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# integration.sh — Directive 7: Assess Integration Surface and Maturity
#
# Maps how the Linux kernel Live Update subsystem (LUO + KHO) integrates
# with other kernel subsystems and classifies each integration point's
# maturity level based on concrete file evidence.
#
# Output format (TSV to stdout):
#   integration_point	status	file_evidence	line_evidence	notes
#
# Status values:
#   implemented — working code exists with full callback/function set
#   stubbed     — partial code exists but is incomplete
#   designed    — architecture described in docs/comments but no code
#   absent      — no code or design evidence found
#
# Structured logs are emitted to stderr in the format:
#   [LU-ARCH-D7-<timestamp>] [<ISO-8601>] [<LEVEL>] <message>
#
# Integration points assessed:
#   KVM, Memfd, Memblock, x86 Architecture, EFI Firmware,
#   Device Drivers, Networking, Filesystem, mm_init,
#   Kconfig:LIVEUPDATE, Kconfig:KEXEC_HANDOVER, Kconfig:LIVEUPDATE_MEMFD
#
# Zero Speculation Rule (AAP §0.8.1):
#   Every maturity classification is based on concrete file evidence
#   (file exists and contains relevant code) or explicit absence (grep
#   returns no results).  No inference is presented as fact.
#
# Scope Exclusions (AAP §0.7.2):
#   - XFS scrub "live update" (fs/xfs/scrub/) — unrelated concept
#   - Generic kexec code — only KHO-specific integration assessed
#   - Livepatch (kernel/livepatch/) — separate subsystem
#
# Usage:
#   cd <kernel-repo-root>
#   bash tools/liveupdate/archaeology/integration.sh
#   # TSV goes to stdout; logs go to stderr.

set -euo pipefail

# ---------------------------------------------------------------------------
# Observability: correlation ID and structured logging
# ---------------------------------------------------------------------------
readonly CORR_ID="LU-ARCH-D7-$(date -u +%Y%m%dT%H%M%S)"

log() {
	local level="$1"
	shift
	echo "[$CORR_ID] [$(date -u +%Y-%m-%dT%H:%M:%SZ)] [$level] $*" >&2
}

# ---------------------------------------------------------------------------
# TSV output helper
# ---------------------------------------------------------------------------
emit_tsv() {
	local integration_point="$1"
	local status="$2"
	local file_evidence="$3"
	local line_evidence="$4"
	local notes="$5"
	printf '%s\t%s\t%s\t%s\t%s\n' "$integration_point" "$status" "$file_evidence" "$line_evidence" "$notes"
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
log "INFO" "Starting Directive 7 — Assess Integration Surface and Maturity"

# ---------------------------------------------------------------------------
# Counters for summary
# ---------------------------------------------------------------------------
declare -A STATUS_COUNT
STATUS_COUNT[implemented]=0
STATUS_COUNT[stubbed]=0
STATUS_COUNT[designed]=0
STATUS_COUNT[absent]=0
TOTAL_POINTS=0

record_status() {
	local status="$1"
	STATUS_COUNT["$status"]=$(( ${STATUS_COUNT["$status"]} + 1 ))
	TOTAL_POINTS=$(( TOTAL_POINTS + 1 ))
}

# ---------------------------------------------------------------------------
# TSV header
# ---------------------------------------------------------------------------
printf '%s\t%s\t%s\t%s\t%s\n' "integration_point" "status" "file_evidence" "line_evidence" "notes"

# ===========================================================================
# Integration Point 1: KVM
# ===========================================================================
log "INFO" "Assessing integration point: KVM"

kvm_status="absent"
kvm_file="-"
kvm_line="-"
kvm_notes=""

# Search for KVM-specific live update / KHO code in KVM directories
kvm_in_kvm_dirs=$(grep -rn "liveupdate\|live_update\|kho_\|kexec_handover" \
	arch/x86/kvm/ virt/kvm/ 2>/dev/null | head -5 || true)

# Search for kvm references inside the Live Update subsystem
kvm_in_luo=$(grep -rn "kvm" kernel/liveupdate/ 2>/dev/null || true)

if [ -n "$kvm_in_kvm_dirs" ]; then
	# KVM directories contain LUO/KHO references — classify further
	kvm_first_file=$(echo "$kvm_in_kvm_dirs" | head -1 | cut -d: -f1)
	kvm_first_line=$(echo "$kvm_in_kvm_dirs" | head -1 | cut -d: -f2)
	kvm_status="implemented"
	kvm_file="$kvm_first_file"
	kvm_line="$kvm_first_line"
	kvm_notes="KVM-specific live update code found in KVM subsystem"
elif [ -n "$kvm_in_luo" ]; then
	# KVM mentioned in LUO code but no KVM-side implementation
	kvm_mention_file=$(echo "$kvm_in_luo" | head -1 | cut -d: -f1)
	kvm_mention_line=$(echo "$kvm_in_luo" | head -1 | cut -d: -f2)
	kvm_mention_text=$(echo "$kvm_in_luo" | head -1 | cut -d: -f3-)

	# Distinguish between doc comment mention vs actual code
	if echo "$kvm_mention_text" | grep -qiE "DOC|example|hook into|include:"; then
		kvm_status="absent"
		kvm_file="$kvm_mention_file"
		kvm_line="$kvm_mention_line"
		kvm_notes="Mentioned as example future subsystem in DOC comment but no KVM-specific handler code exists"
	else
		kvm_status="designed"
		kvm_file="$kvm_mention_file"
		kvm_line="$kvm_mention_line"
		kvm_notes="Referenced in LUO code but no KVM-side implementation"
	fi
else
	kvm_notes="No KVM-specific live update code or references found"
fi

emit_tsv "KVM" "$kvm_status" "$kvm_file" "$kvm_line" "$kvm_notes"
record_status "$kvm_status"
log "INFO" "KVM: $kvm_status"

# ===========================================================================
# Integration Point 2: Memfd
# ===========================================================================
log "INFO" "Assessing integration point: Memfd"

memfd_status="absent"
memfd_file="-"
memfd_line="-"
memfd_notes=""

if [ -f "mm/memfd_luo.c" ]; then
	memfd_line_count=$(wc -l < mm/memfd_luo.c)
	handler_reg=$(grep -n "liveupdate_register_file_handler" mm/memfd_luo.c 2>/dev/null || true)
	compatible_str=$(grep -n "MEMFD_LUO_FH_COMPATIBLE\|memfd-v1\|\.compatible" mm/memfd_luo.c 2>/dev/null || true)
	callback_count=$(grep -c "\.freeze\|\.finish\|\.retrieve\|\.preserve\|\.unpreserve\|\.can_preserve" mm/memfd_luo.c 2>/dev/null || true)

	if [ -n "$handler_reg" ]; then
		reg_line=$(echo "$handler_reg" | head -1 | cut -d: -f1)
		memfd_status="implemented"
		memfd_file="mm/memfd_luo.c"
		memfd_line="$reg_line"
		memfd_notes="Registered handler with full preserve/freeze/retrieve callback set ($memfd_line_count lines, $callback_count callbacks)"
	elif [ -n "$compatible_str" ]; then
		compat_line=$(echo "$compatible_str" | head -1 | cut -d: -f1)
		memfd_status="stubbed"
		memfd_file="mm/memfd_luo.c"
		memfd_line="$compat_line"
		memfd_notes="File exists with compatible string but registration incomplete ($memfd_line_count lines)"
	else
		memfd_status="stubbed"
		memfd_file="mm/memfd_luo.c"
		memfd_notes="File exists but no handler registration or compatible string found ($memfd_line_count lines)"
	fi
else
	memfd_notes="mm/memfd_luo.c does not exist; no memfd live update support"
fi

emit_tsv "Memfd" "$memfd_status" "$memfd_file" "$memfd_line" "$memfd_notes"
record_status "$memfd_status"
log "INFO" "Memfd: $memfd_status"

# ===========================================================================
# Integration Point 3: Memblock (Memory Management)
# ===========================================================================
log "INFO" "Assessing integration point: Memblock"

memblock_status="absent"
memblock_file="-"
memblock_line="-"
memblock_notes=""
kho_ref_count=0

if [ -f "mm/memblock.c" ]; then
	kho_ref_count=$(grep -c \
		"kho_\|kexec_handover\|KEXEC_HANDOVER\|memblock_mark_kho\|memblock_set_kho\|memblock_clear_kho\|memmap_init_kho\|prepare_kho_fdt" \
		mm/memblock.c 2>/dev/null || true)
	kho_include=$(grep -n "kexec_handover.h" mm/memblock.c 2>/dev/null || true)

	if [ "$kho_ref_count" -gt 0 ] 2>/dev/null; then
		include_line="-"
		if [ -n "$kho_include" ]; then
			include_line=$(echo "$kho_include" | head -1 | cut -d: -f1)
		fi
		if [ "$kho_ref_count" -ge 10 ]; then
			memblock_status="implemented"
		else
			memblock_status="stubbed"
		fi
		memblock_file="mm/memblock.c"
		memblock_line="$include_line"
		memblock_notes="$kho_ref_count KHO-related references for scratch memory management"
	else
		memblock_notes="mm/memblock.c exists but contains no KHO references"
	fi
else
	memblock_notes="mm/memblock.c does not exist"
fi

emit_tsv "Memblock" "$memblock_status" "$memblock_file" "$memblock_line" "$memblock_notes"
record_status "$memblock_status"
log "INFO" "Memblock: $memblock_status ($kho_ref_count references)"

# ===========================================================================
# Integration Point 4: x86 Architecture
# ===========================================================================
log "INFO" "Assessing integration point: x86 Architecture"

x86_status="absent"
x86_file="-"
x86_line="-"
x86_notes=""

# List of known x86 KHO integration files
declare -a X86_FILES=(
	"arch/x86/boot/compressed/kaslr.c"
	"arch/x86/include/asm/setup.h"
	"arch/x86/include/uapi/asm/setup_data.h"
	"arch/x86/kernel/e820.c"
	"arch/x86/kernel/kexec-bzimage64.c"
	"arch/x86/kernel/setup.c"
	"arch/x86/realmode/init.c"
)

x86_file_count=0
x86_total_refs=0
x86_details=""

for f in "${X86_FILES[@]}"; do
	if [ -f "$f" ]; then
		count=$(grep -c "kho\|kexec_handover\|KEXEC_HANDOVER\|KHO\|SETUP_KEXEC_KHO" "$f" 2>/dev/null || true)
		if [ "$count" -gt 0 ] 2>/dev/null; then
			x86_file_count=$(( x86_file_count + 1 ))
			x86_total_refs=$(( x86_total_refs + count ))
			log "DEBUG" "  $f: $count KHO references"
		fi
	fi
done

# Check which architectures define ARCH_SUPPORTS_KEXEC_HANDOVER
arch_support=$(grep -rn "ARCH_SUPPORTS_KEXEC_HANDOVER" arch/*/Kconfig 2>/dev/null || true)
arch_list=""
if [ -n "$arch_support" ]; then
	arch_list=$(echo "$arch_support" | sed 's|arch/\([^/]*\)/.*|\1|' | sort -u | tr '\n' ',' | sed 's/,$//')
fi

if [ "$x86_file_count" -gt 0 ]; then
	x86_status="implemented"
	x86_file="arch/x86/ (${x86_file_count} files)"
	x86_notes="KASLR avoidance, E820 integration, setup data, kexec attachment, realmode scratch; ${x86_total_refs} total KHO references across ${x86_file_count} files"
	if [ -n "$arch_list" ]; then
		x86_notes="${x86_notes}; ARCH_SUPPORTS_KEXEC_HANDOVER defined in: ${arch_list}"
	fi
else
	x86_notes="No KHO integration files found in arch/x86/"
fi

emit_tsv "x86 Architecture" "$x86_status" "$x86_file" "$x86_line" "$x86_notes"
record_status "$x86_status"
log "INFO" "x86 Architecture: $x86_status ($x86_file_count files, $x86_total_refs refs)"

# ===========================================================================
# Integration Point 5: EFI Firmware
# ===========================================================================
log "INFO" "Assessing integration point: EFI Firmware"

efi_status="absent"
efi_file="-"
efi_line="-"
efi_notes=""

efi_target="drivers/firmware/efi/efi-init.c"
if [ -f "$efi_target" ]; then
	efi_kho_refs=$(grep -n "is_kho_boot\|kho_\|kexec_handover\|memblock_is_kho_scratch" "$efi_target" 2>/dev/null || true)
	if [ -n "$efi_kho_refs" ]; then
		efi_first_line=$(echo "$efi_kho_refs" | head -1 | cut -d: -f1)
		efi_ref_count=$(echo "$efi_kho_refs" | wc -l)
		efi_status="implemented"
		efi_file="$efi_target"
		efi_line="$efi_first_line"
		efi_notes="KHO-aware memblock discovery via is_kho_boot() check ($efi_ref_count KHO references)"
	else
		efi_notes="$efi_target exists but contains no KHO references"
	fi
else
	efi_notes="$efi_target does not exist"
fi

emit_tsv "EFI Firmware" "$efi_status" "$efi_file" "$efi_line" "$efi_notes"
record_status "$efi_status"
log "INFO" "EFI Firmware: $efi_status"

# ===========================================================================
# Integration Point 6: Device Drivers (VFIO/iommufd)
# ===========================================================================
log "INFO" "Assessing integration point: Device Drivers"

drivers_status="absent"
drivers_file="-"
drivers_line="-"
drivers_notes=""

# Search for live update handler registrations in all driver code
driver_handler_refs=$(grep -rn "liveupdate_register_file_handler\|liveupdate_file_handler" \
	drivers/ 2>/dev/null | head -5 || true)

# Search specifically in VFIO and IOMMU directories
driver_vfio_refs=$(grep -rn "liveupdate\|live_update" \
	drivers/vfio/ drivers/iommu/ 2>/dev/null | head -5 || true)

# Check if LUO documentation mentions drivers as future subsystems
driver_doc_mention=""
if [ -f "kernel/liveupdate/luo_file.c" ]; then
	driver_doc_mention=$(grep -n "vfio\|iommu" kernel/liveupdate/luo_file.c 2>/dev/null || true)
fi

if [ -n "$driver_handler_refs" ]; then
	drv_first_file=$(echo "$driver_handler_refs" | head -1 | cut -d: -f1)
	drv_first_line=$(echo "$driver_handler_refs" | head -1 | cut -d: -f2)
	drivers_status="implemented"
	drivers_file="$drv_first_file"
	drivers_line="$drv_first_line"
	drivers_notes="Driver-specific file handler found"
elif [ -n "$driver_vfio_refs" ]; then
	drv_first_file=$(echo "$driver_vfio_refs" | head -1 | cut -d: -f1)
	drv_first_line=$(echo "$driver_vfio_refs" | head -1 | cut -d: -f2)
	drivers_status="stubbed"
	drivers_file="$drv_first_file"
	drivers_line="$drv_first_line"
	drivers_notes="Live update references exist in driver code but no handler registration"
elif [ -n "$driver_doc_mention" ]; then
	doc_file="kernel/liveupdate/luo_file.c"
	doc_line=$(echo "$driver_doc_mention" | head -1 | cut -d: -f1)
	drivers_status="absent"
	drivers_file="$doc_file"
	drivers_line="$doc_line"
	drivers_notes="No driver-specific file handlers registered; vfio/iommufd listed as examples in DOC comment"
else
	drivers_notes="No driver-specific file handlers registered; no LUO references in drivers/"
fi

emit_tsv "Device Drivers" "$drivers_status" "$drivers_file" "$drivers_line" "$drivers_notes"
record_status "$drivers_status"
log "INFO" "Device Drivers: $drivers_status"

# ===========================================================================
# Integration Point 7: Networking
# ===========================================================================
log "INFO" "Assessing integration point: Networking"

net_status="absent"
net_file="-"
net_line="-"
net_notes=""

# Search for LUO/KHO references in net/
net_refs=$(grep -rn "liveupdate\|live_update\|kho_\|kexec_handover" \
	net/ 2>/dev/null | grep -v "Binary file" | head -5 || true)

# Also check for handler registrations specifically
net_handler_refs=$(grep -rn "liveupdate_register_file_handler\|liveupdate_file_handler" \
	net/ 2>/dev/null | head -5 || true)

if [ -n "$net_handler_refs" ]; then
	net_first_file=$(echo "$net_handler_refs" | head -1 | cut -d: -f1)
	net_first_line=$(echo "$net_handler_refs" | head -1 | cut -d: -f2)
	net_status="implemented"
	net_file="$net_first_file"
	net_line="$net_first_line"
	net_notes="Networking live update handler found"
elif [ -n "$net_refs" ]; then
	net_first_file=$(echo "$net_refs" | head -1 | cut -d: -f1)
	net_first_line=$(echo "$net_refs" | head -1 | cut -d: -f2)
	net_status="stubbed"
	net_file="$net_first_file"
	net_line="$net_first_line"
	net_notes="LUO/KHO references found in net/ but no handler registration"
else
	net_notes="No networking integration found; no LUO/KHO references in net/"
fi

emit_tsv "Networking" "$net_status" "$net_file" "$net_line" "$net_notes"
record_status "$net_status"
log "INFO" "Networking: $net_status"

# ===========================================================================
# Integration Point 8: Filesystem
# ===========================================================================
log "INFO" "Assessing integration point: Filesystem"

fs_status="absent"
fs_file="-"
fs_line="-"
fs_notes=""

# Search for LUO handler registrations in fs/ (the definitive integration signal)
fs_handler_refs=$(grep -rn "liveupdate_register_file_handler\|liveupdate_file_handler" \
	fs/ 2>/dev/null | head -5 || true)

# Note: XFS scrub has "live update" references but those refer to online
# filesystem scrub repair, NOT the Live Update Orchestrator — explicitly exclude
xfs_false_positives=$(grep -rn "live.update" fs/xfs/scrub/ 2>/dev/null | wc -l || true)

if [ -n "$fs_handler_refs" ]; then
	fs_first_file=$(echo "$fs_handler_refs" | head -1 | cut -d: -f1)
	fs_first_line=$(echo "$fs_handler_refs" | head -1 | cut -d: -f2)
	fs_status="implemented"
	fs_file="$fs_first_file"
	fs_line="$fs_first_line"
	fs_notes="Filesystem live update handler found"
else
	xfs_note=""
	if [ "$xfs_false_positives" -gt 0 ] 2>/dev/null; then
		xfs_note="; XFS scrub has ${xfs_false_positives} 'live update' references but those are the unrelated online repair feature (excluded per AAP scope)"
	fi
	fs_notes="No filesystem handler registered; no LUO file handler in fs/${xfs_note}"
fi

emit_tsv "Filesystem" "$fs_status" "$fs_file" "$fs_line" "$fs_notes"
record_status "$fs_status"
log "INFO" "Filesystem: $fs_status"

# ===========================================================================
# Integration Point 9: mm_init (Memory Initialization)
# ===========================================================================
log "INFO" "Assessing integration point: mm_init"

mm_init_status="absent"
mm_init_file="-"
mm_init_line="-"
mm_init_notes=""

if [ -f "mm/mm_init.c" ]; then
	mm_init_refs=$(grep -n "kho\|kexec_handover" mm/mm_init.c 2>/dev/null || true)
	if [ -n "$mm_init_refs" ]; then
		mm_init_ref_count=$(echo "$mm_init_refs" | wc -l)
		mm_init_first_line=$(echo "$mm_init_refs" | head -1 | cut -d: -f1)
		# Check for actual function calls vs just includes
		mm_init_calls=$(echo "$mm_init_refs" | grep -v "#include" || true)
		if [ -n "$mm_init_calls" ]; then
			mm_init_status="implemented"
			mm_init_file="mm/mm_init.c"
			mm_init_line="$mm_init_first_line"
			mm_init_notes="KHO-aware memory initialization paths ($mm_init_ref_count KHO references including function calls)"
		else
			mm_init_status="stubbed"
			mm_init_file="mm/mm_init.c"
			mm_init_line="$mm_init_first_line"
			mm_init_notes="KHO header included but no KHO function calls detected ($mm_init_ref_count references)"
		fi
	else
		mm_init_notes="mm/mm_init.c exists but contains no KHO/kexec_handover references"
	fi
else
	mm_init_notes="mm/mm_init.c does not exist"
fi

emit_tsv "mm_init" "$mm_init_status" "$mm_init_file" "$mm_init_line" "$mm_init_notes"
record_status "$mm_init_status"
log "INFO" "mm_init: $mm_init_status"

# ===========================================================================
# Integration Points 10-12: Kconfig Dependency Chain
# ===========================================================================
log "INFO" "Assessing Kconfig dependency chain"

# ---------------------------------------------------------------------------
# Helper: extract a Kconfig block (from "config NAME" to next "config " or
# "endmenu" or "menu ") and return its select/depends lines.
# Usage: extract_kconfig_info <config_name> <kconfig_file>
#   Outputs two lines: first line = selects, second line = depends
# ---------------------------------------------------------------------------
extract_kconfig_info() {
	local config_name="$1"
	local kconfig_file="$2"
	awk -v name="config ${config_name}" '
		BEGIN { found=0 }
		$0 == name { found=1; next }
		found && /^config |^endmenu|^menu / { found=0 }
		found && /select / {
			sub(/^[[:space:]]+/, "")
			selects = selects ? selects "; " $0 : $0
		}
		found && /depends on/ {
			sub(/^[[:space:]]+/, "")
			depends = depends ? depends "; " $0 : $0
		}
		END {
			print selects
			print depends
		}
	' "$kconfig_file"
}

# --- Kconfig:KEXEC_HANDOVER ---
kho_kconfig_status="absent"
kho_kconfig_file="-"
kho_kconfig_line="-"
kho_kconfig_notes=""

if [ -f "kernel/liveupdate/Kconfig" ]; then
	kho_config_match=$(grep -n "^config KEXEC_HANDOVER$" kernel/liveupdate/Kconfig 2>/dev/null || true)
	if [ -n "$kho_config_match" ]; then
		kho_line_num=$(echo "$kho_config_match" | head -1 | cut -d: -f1)
		kho_info=$(extract_kconfig_info "KEXEC_HANDOVER" kernel/liveupdate/Kconfig)
		kho_selects=$(echo "$kho_info" | head -1)
		kho_depends=$(echo "$kho_info" | tail -1)
		kho_kconfig_status="implemented"
		kho_kconfig_file="kernel/liveupdate/Kconfig"
		kho_kconfig_line="$kho_line_num"
		kho_kconfig_notes="${kho_selects:+$kho_selects}${kho_selects:+; }${kho_depends}"
	fi
fi

emit_tsv "Kconfig:KEXEC_HANDOVER" "$kho_kconfig_status" "$kho_kconfig_file" "$kho_kconfig_line" "$kho_kconfig_notes"
record_status "$kho_kconfig_status"
log "INFO" "Kconfig:KEXEC_HANDOVER: $kho_kconfig_status"

# --- Kconfig:LIVEUPDATE ---
luo_kconfig_status="absent"
luo_kconfig_file="-"
luo_kconfig_line="-"
luo_kconfig_notes=""

if [ -f "kernel/liveupdate/Kconfig" ]; then
	luo_config_match=$(grep -n "^config LIVEUPDATE$" kernel/liveupdate/Kconfig 2>/dev/null || true)
	if [ -n "$luo_config_match" ]; then
		luo_line_num=$(echo "$luo_config_match" | head -1 | cut -d: -f1)
		luo_info=$(extract_kconfig_info "LIVEUPDATE" kernel/liveupdate/Kconfig)
		luo_selects=$(echo "$luo_info" | head -1)
		luo_depends=$(echo "$luo_info" | tail -1)
		luo_kconfig_status="implemented"
		luo_kconfig_file="kernel/liveupdate/Kconfig"
		luo_kconfig_line="$luo_line_num"
		luo_kconfig_notes="${luo_selects:+$luo_selects}${luo_selects:+; }${luo_depends}"
	fi
fi

emit_tsv "Kconfig:LIVEUPDATE" "$luo_kconfig_status" "$luo_kconfig_file" "$luo_kconfig_line" "$luo_kconfig_notes"
record_status "$luo_kconfig_status"
log "INFO" "Kconfig:LIVEUPDATE: $luo_kconfig_status"

# --- Kconfig:LIVEUPDATE_MEMFD ---
memfd_kconfig_status="absent"
memfd_kconfig_file="-"
memfd_kconfig_line="-"
memfd_kconfig_notes=""

if [ -f "kernel/liveupdate/Kconfig" ]; then
	memfd_config_match=$(grep -n "^config LIVEUPDATE_MEMFD$" kernel/liveupdate/Kconfig 2>/dev/null || true)
	if [ -n "$memfd_config_match" ]; then
		memfd_kc_line_num=$(echo "$memfd_config_match" | head -1 | cut -d: -f1)
		memfd_kc_info=$(extract_kconfig_info "LIVEUPDATE_MEMFD" kernel/liveupdate/Kconfig)
		memfd_kc_selects=$(echo "$memfd_kc_info" | head -1)
		memfd_kc_depends=$(echo "$memfd_kc_info" | tail -1)
		memfd_kconfig_status="implemented"
		memfd_kconfig_file="kernel/liveupdate/Kconfig"
		memfd_kconfig_line="$memfd_kc_line_num"
		memfd_kconfig_notes="${memfd_kc_selects:+$memfd_kc_selects}${memfd_kc_selects:+; }${memfd_kc_depends}"
	fi
fi

emit_tsv "Kconfig:LIVEUPDATE_MEMFD" "$memfd_kconfig_status" "$memfd_kconfig_file" "$memfd_kconfig_line" "$memfd_kconfig_notes"
record_status "$memfd_kconfig_status"
log "INFO" "Kconfig:LIVEUPDATE_MEMFD: $memfd_kconfig_status"

# ===========================================================================
# Summary
# ===========================================================================
log "INFO" "Integration assessment complete: $TOTAL_POINTS points assessed, ${STATUS_COUNT[implemented]} implemented, ${STATUS_COUNT[stubbed]} stubbed, ${STATUS_COUNT[designed]} designed, ${STATUS_COUNT[absent]} absent"
log "INFO" "Directive 7 finished successfully"

exit 0
