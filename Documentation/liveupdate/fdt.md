# Flattened Device Tree (FDT) in the Linux Kernel

## Overview

The **Flattened Device Tree** (FDT), also known as a **Device Tree Blob** (DTB), is a
data structure and binary format that the Linux kernel uses to describe hardware
topology, configuration, and — in the case of the Kexec HandOver (KHO) subsystem —
serialized kernel state that must survive across a `kexec` reboot. The FDT is the
**sole serialization wire format** chosen by the KHO and Live Update Orchestrator (LUO)
subsystems for passing metadata between an outgoing kernel and an incoming kernel.

This document explains three things:

1. **What the FDT binary format is** and how libfdt implements it inside the kernel.
2. **Why FDT was chosen** over protocol buffers (protobuf), other custom binary
   formats, and sysfs-based approaches.
3. **How the kernel's Live Update subsystem actually wields FDT**, including creation,
   population, finalization, and consumption during early boot.

---

## 1. The FDT Binary Format

### 1.1 Origin and Specification

The FDT originates from the Open Firmware / IEEE 1275 standard and was adopted by the
PowerPC, ARM, and RISC-V Linux ports to describe platform hardware in a
firmware-neutral way. The binary encoding is specified in the
[Devicetree Specification](https://www.devicetree.org/specifications/) (maintained by
devicetree.org). Within the Linux source tree, the canonical implementation lives in
`scripts/dtc/libfdt/`.

### 1.2 Binary Layout

An FDT blob is a self-contained, position-independent binary with four regions laid
out contiguously in memory:

```
+-------------------------------+  offset 0
|  struct fdt_header (40 bytes) |
+-------------------------------+
|  Memory Reservation Map       |  (array of {address, size} pairs, 0-terminated)
+-------------------------------+
|  Structure Block              |  (nested BEGIN_NODE / END_NODE / PROP tokens)
+-------------------------------+
|  Strings Block                |  (null-terminated property name pool)
+-------------------------------+
```

The header (defined in `scripts/dtc/libfdt/fdt.h`) contains:

| Field                  | Size   | Description                                         |
|------------------------|--------|-----------------------------------------------------|
| `magic`                | 4 B    | `0xd00dfeed` — identifies the blob as FDT            |
| `totalsize`            | 4 B    | Total size of the entire blob in bytes               |
| `off_dt_struct`        | 4 B    | Offset from start of blob to the structure block     |
| `off_dt_strings`       | 4 B    | Offset from start of blob to the strings block       |
| `off_mem_rsvmap`       | 4 B    | Offset to the memory reservation map                 |
| `version`              | 4 B    | FDT format version (currently 17)                    |
| `last_comp_version`    | 4 B    | Lowest version with which the blob is compatible     |
| `boot_cpuid_phys`      | 4 B    | Physical CPU ID of the boot processor (v2+)          |
| `size_dt_strings`      | 4 B    | Size of the strings block (v3+)                      |
| `size_dt_struct`       | 4 B    | Size of the structure block (v17+)                   |

All multi-byte fields are stored in **big-endian** byte order regardless of the host
CPU architecture.

### 1.3 Structure Block Tokens

The structure block is a flat stream of 32-bit tokens:

| Token            | Value  | Meaning                                              |
|------------------|--------|------------------------------------------------------|
| `FDT_BEGIN_NODE` | `0x1`  | Start of a node; followed by the node name (NUL-padded to 4-byte alignment) |
| `FDT_END_NODE`   | `0x2`  | End of the current node                              |
| `FDT_PROP`       | `0x3`  | Property definition; followed by `{len, nameoff, data[]}` |
| `FDT_NOP`        | `0x4`  | No-operation padding token                           |
| `FDT_END`        | `0x9`  | Marks the end of the entire structure block          |

A property (`FDT_PROP`) carries:

- `len`: a 32-bit length of the property value in bytes.
- `nameoff`: a 32-bit offset into the strings block giving the property's name.
- `data[]`: the raw property value bytes, padded to 4-byte alignment.

This encoding makes the format **self-describing**: a parser can walk the token stream
without knowing the schema in advance, and property names are human-readable strings
rather than numeric field tags.

### 1.4 libfdt — The In-Kernel FDT Library

The kernel's FDT support is provided by **libfdt**, gated behind `CONFIG_LIBFDT` (see
`lib/Kconfig`). The library is compiled from the sources in `scripts/dtc/libfdt/` and
offers two API families:

- **Sequential-write (SW) API** for creating new FDT blobs from scratch:
  `fdt_create()`, `fdt_finish_reservemap()`, `fdt_begin_node()`, `fdt_property()`,
  `fdt_property_string()`, `fdt_end_node()`, `fdt_finish()`.
- **Read-write (RW) API** for modifying an existing blob:
  `fdt_open_into()`, `fdt_add_subnode()`, `fdt_setprop()`, `fdt_getprop()`,
  `fdt_subnode_offset()`, `fdt_first_subnode()`, `fdt_next_subnode()`,
  `fdt_for_each_subnode()`, `fdt_pack()`.

The read-only API (`fdt_getprop()`, `fdt_check_header()`, `fdt_node_offset_by_compatible()`)
is used heavily during early boot to consume the incoming KHO FDT before the full
kernel memory allocator is available.

---

## 2. Why FDT — and Not Protocol Buffers, Custom Binary, or sysfs

The Live Update / KHO subsystem needed a serialization format for passing structured
metadata across a `kexec` transition. The four principal alternatives — protocol
buffers (protobuf), a bespoke custom binary format, sysfs-based state export, and
FDT — were evaluated against kernel-specific constraints.

### 2.1 Protocol Buffers (Protobuf)

Protocol buffers are Google's language-neutral serialization framework. They are
ubiquitous in userspace services but were **not adopted** by KHO for the following
reasons:

| Criterion | Protobuf | FDT |
|---|---|---|
| **Kernel linkability** | Requires a C runtime library (`protobuf-c` or equivalent) that is not part of the Linux kernel tree and has never been proposed for inclusion. Introducing it would add a new external dependency to the kernel build, which is contrary to the kernel's policy of minimizing third-party library imports. | `libfdt` has been in-tree since 2006 (commit by David Gibson, IBM). It is a well-audited, BSD-2-Clause / GPL-2.0-or-later licensed library already used by every ARM, PowerPC, and RISC-V kernel build. |
| **Early boot availability** | A protobuf decoder would need to be compiled into the decompressor or very early init code where only minimal C library support exists (no `malloc`, no `printf`, limited stack). | libfdt's read-only API (`fdt_getprop`, `fdt_check_header`) operates on a flat buffer with no dynamic allocation, making it safe to call from `__init` functions and even from the compressed-kernel KASLR code (`arch/x86/boot/compressed/kaslr.c`). |
| **Schema evolution** | Protobuf supports forward/backward compatible schema changes via field numbers, but the kernel already implements an equivalent mechanism using `compatible` version strings (e.g., `"kho-v1"`, `"luo-session-v2"`) checked at parse time. | Compatible strings are idiomatic in the devicetree ecosystem and match existing kernel ABI versioning patterns. |
| **Code size** | The protobuf-c library adds ~15–25 KB of text to a minimal configuration. | libfdt adds ~8 KB and is already counted in any kernel that enables `CONFIG_OF` (nearly all ARM/ARM64/RISC-V kernels). |
| **Human debuggability** | Protobuf is an opaque binary wire format; decoding requires the `.proto` schema file and a decoder tool. | An FDT blob can be dumped with `fdtdump` (ships with `dtc`) or inspected via the kernel's own debugfs interface (`/sys/kernel/debug/kho/out/fdt`). |

**In summary**: protobuf was never a realistic candidate because its runtime library is
not in the kernel tree, it cannot operate without dynamic allocation during early
boot, and FDT already provides equivalent self-describing, version-negotiated
serialization with a fraction of the code.

### 2.2 Custom Binary Format

A purpose-built binary format — fixed-size C structures written directly to memory —
would avoid any library dependency. The KHO subsystem does in fact use `__packed`
structures for the *payloads* referenced by FDT properties (e.g.,
`struct luo_session_ser`, `struct luo_file_ser`, `struct memfd_luo_folio_ser`), but
the **top-level metadata tree** is still FDT rather than a raw struct-based format.
The reasons are:

1. **Extensibility without breakage.** A flat C struct cannot accommodate variable
   numbers of sessions, files, or subsystems without embedding linked-list pointers
   (which couple the format to kernel virtual address layout) or inventing a
   TLV-style container — which is just reimplementing FDT poorly. FDT's nested
   node structure naturally represents a variable-depth, variable-width tree of
   named properties.

2. **Multi-subsystem composition.** KHO is designed so that any kernel subsystem can
   register its own sub-FDT via `kho_add_subtree(name, fdt)`. The root KHO FDT
   stores physical pointers to each subsystem's sub-FDT. A custom binary format
   would need an equivalent registry mechanism; FDT provides this for free via
   named subnodes.

3. **In-field debugging.** Kernel developers can examine the entire KHO handover
   tree with `fdtdump` or via the debugfs blob interface. A custom binary format
   would require a bespoke decoder tool to be written and maintained.

4. **ABI stability tooling.** The devicetree community has decades of experience
   with maintaining stable ABIs expressed as FDT compatible strings. The KHO ABI
   headers (`include/linux/kho/abi/*.h`) use the same pattern:
   `KHO_FDT_COMPATIBLE "kho-v1"`, `LUO_FDT_SESSION_COMPATIBLE "luo-session-v2"`,
   `MEMBLOCK_KHO_NODE_COMPATIBLE "memblock-v1"`, etc.

However, the `__packed` serialization structures that the FDT properties *point to*
are effectively a custom binary format at the leaf level. The design is hybrid: **FDT
for the tree spine** (discovery, naming, versioning) and **packed C structures for the
data payloads** (session headers, file descriptors, folio arrays). This division means
FDT handles the parts that benefit from self-description and extensibility, while raw
binary handles the parts that need zero-copy performance for large data volumes
(e.g., thousands of folio descriptors in `struct memfd_luo_folio_ser`).

### 2.3 sysfs (System Filesystem)

sysfs (`/sys/`) is the kernel's standard interface for exporting per-device and
per-subsystem attributes to userspace as virtual files. It was **not chosen** as the
serialization transport for KHO state because:

1. **sysfs is a userspace interface, not a kernel-to-kernel transport.** KHO metadata
   must be passed in physical memory from one kernel instance to another across a
   `kexec` reboot. sysfs files exist only as virtual filesystem entries backed by
   callback functions — they are not persistent and do not survive `kexec`. The
   successor kernel has no access to the predecessor's sysfs tree.

2. **sysfs operates too late.** KHO state must be consumed during very early boot
   (e.g., `add_kho()` in `arch/x86/kernel/setup.c` runs before the VFS is mounted).
   sysfs is not available until after `sysfs_init()` runs, which occurs well after
   the memory subsystem is initialized. By that point, KHO's scratch regions and
   preserved memory must already be marked and protected.

3. **sysfs has no binary blob transport.** While sysfs *can* expose binary attributes
   (`sysfs_create_bin_file()`), serializing an entire tree of sessions, file
   descriptors, and memory maps as individual sysfs attributes would be fragmented
   and would require a complex userspace orchestrator to reassemble the pieces. FDT
   provides a single contiguous blob that can be written to a kexec segment in one
   operation.

**Where sysfs / debugfs does appear:**
The KHO subsystem uses **debugfs** (which is conceptually related to sysfs but
intended for debugging) as a secondary interface. Once the KHO FDT is finalized, it
is exposed to userspace as a binary blob at
`/sys/kernel/debug/kho/out/fdt` so that the `kexec` userspace tool can read the
blob and include it in the kexec file image. Additional debugfs files expose scratch
region physical addresses and lengths. The KHO documentation notes that these
debugfs interfaces "may change in the future" and "will be moved to sysfs once KHO
is stabilized" (see `Documentation/admin-guide/mm/kho.rst`).

So sysfs/debugfs is used as the *userspace access path* to the FDT blob, but the
blob itself is FDT — not a sysfs attribute tree.

---

## 3. How KHO Uses FDT in Practice

### 3.1 Outgoing Kernel: Building the FDT

When a KHO-capable kernel boots with `kho=on`, the following sequence constructs the
outgoing FDT:

1. **Root FDT allocation** (`kho_init()` in `kernel/liveupdate/kexec_handover.c`):
   A single `PAGE_SIZE` (4 KiB) page is allocated and preserved via
   `kho_alloc_preserve(PAGE_SIZE)`. This page will hold the root KHO FDT for the
   lifetime of the kernel.

2. **Root FDT creation** (`kho_out_fdt_setup()`): The sequential-write API builds the
   skeleton:
   ```c
   fdt_create(root, PAGE_SIZE);
   fdt_finish_reservemap(root);
   fdt_begin_node(root, "");
   fdt_property_string(root, "compatible", "kho-v1");
   fdt_property(root, "preserved-memory-map", &empty, sizeof(empty));
   fdt_end_node(root);
   fdt_finish(root);
   ```

3. **Subsystem registration** (`kho_add_subtree()`): Each subsystem (e.g., LUO,
   memblock) creates its own sub-FDT page, populates it, and registers it with the
   root FDT. The root FDT is reopened with `fdt_open_into()`, a named subnode is
   added with `fdt_add_subnode()`, and the sub-FDT's physical address is stored as
   a `u64` property. The root FDT is then re-packed with `fdt_pack()`.

4. **LUO sub-FDT** (`luo_fdt_setup()` in `kernel/liveupdate/luo_core.c`): The Live
   Update Orchestrator creates its own `PAGE_SIZE` sub-FDT with:
   - `compatible = "luo-v1"`
   - `liveupdate-number` = the number of live updates performed plus one
   - Session and FLB subnode setup delegated to `luo_session_setup_outgoing()` and
     `luo_flb_setup_outgoing()`

5. **Finalization** (`kho_finalize()` triggered by writing `1` to
   `/sys/kernel/debug/kho/out/finalize`): The kernel serializes all preserved memory
   bitmaps into the FDT's `preserved-memory-map` property, writing physical addresses
   of linked-list chunks that describe every preserved page. After finalization, the
   system state is immutable — no new pages can be preserved.

### 3.2 kexec Transition

The userspace `kexec` tool reads the finalized FDT blob from
`/sys/kernel/debug/kho/out/fdt` and includes it as a `SETUP_KEXEC_KHO` setup data
block in the kexec file image. The `setup_kho()` function in
`arch/x86/kernel/kexec-bzimage64.c` attaches the FDT physical address, FDT size,
scratch region address, and scratch region size to the boot parameters.

### 3.3 Incoming Kernel: Consuming the FDT

When the new kernel boots after `kexec -e`:

1. **Very early boot** (`add_kho()` in `arch/x86/kernel/setup.c`): The
   `SETUP_KEXEC_KHO` data is detected. The FDT physical address and scratch regions
   are extracted and passed to `kho_populate()`.

2. **FDT validation** (`kho_populate()` in `kernel/liveupdate/kexec_handover.c`):
   `fdt_check_header()` validates the FDT blob. The `preserved-memory-map` property
   is read with `fdt_getprop()` to obtain the physical address of the memory
   preservation bitmap chain.

3. **Memory restoration**: The bitmap chain is walked to mark all preserved pages,
   preventing the page allocator from reclaiming them.

4. **Subsystem retrieval** (`kho_retrieve_subtree()`): Each subsystem calls
   `kho_retrieve_subtree("LUO", &phys)` to obtain the physical address of its
   sub-FDT. The sub-FDT is then parsed with `fdt_getprop()` to extract session
   headers, FLB headers, and file handler data.

5. **KASLR avoidance** (`process_kho_entries()` in
   `arch/x86/boot/compressed/kaslr.c`): During KASLR randomization, scratch regions
   are excluded from the candidate address space to ensure the new kernel does not
   land on top of preserved memory.

### 3.4 FDT Tree Hierarchy

The complete FDT tree at finalization time looks like this:

```
/ {
    compatible = "kho-v1";
    preserved-memory-map = <physical address of bitmap chain>;

    LUO {
        fdt = <physical address of LUO sub-FDT>;
    };

    memblock {
        fdt = <physical address of memblock sub-FDT>;
    };
}
```

The LUO sub-FDT (at the address stored in the `LUO` node) contains:

```
/ {
    compatible = "luo-v1";
    liveupdate-number = <N>;

    luo-session {
        compatible = "luo-session-v2";
        luo-session-header = <physical address of session array>;
    };

    luo-flb {
        compatible = "luo-flb-v1";
        luo-flb-header = <physical address of FLB array>;
    };
};
```

The memblock sub-FDT contains:

```
/ {
    compatible = "memblock-v1";

    <reservation-name> {
        compatible = "reserve-mem-v1";
        start = <physical address>;
        size = <size in bytes>;
    };
};
```

### 3.5 Relationship to debugfs (and Future sysfs)

The FDT blob is not directly accessible to userspace during normal operation. The
kernel exposes it through **debugfs** at:

| Path | Content |
|---|---|
| `/sys/kernel/debug/kho/out/finalize` | Write `1` to enter finalization; write `0` to abort |
| `/sys/kernel/debug/kho/out/fdt` | The finalized root FDT blob (binary) |
| `/sys/kernel/debug/kho/out/scratch_phys` | Physical addresses of scratch regions |
| `/sys/kernel/debug/kho/out/scratch_len` | Sizes of scratch regions |
| `/sys/kernel/debug/kho/out/sub_fdts/<name>` | Individual sub-FDT blobs registered by subsystems |
| `/sys/kernel/debug/kho/in/fdt` | The incoming FDT from the previous kernel (read-only, after KHO boot) |
| `/sys/kernel/debug/kho/in/sub_fdts/<name>` | Incoming sub-FDTs from the previous kernel |

These debugfs entries use `debugfs_create_blob()` and `debugfs_create_file()` (see
`kernel/liveupdate/kexec_handover_debugfs.c`). The current documentation notes that
these interfaces will eventually migrate to sysfs once the KHO ABI stabilizes.

---

## 4. Summary

| Serialization Option | Role in KHO |
|---|---|
| **FDT (Flattened Device Tree)** | **Primary wire format.** The metadata tree spine: root node, subsystem subnodes, property pointers. Used for discovery, naming, ABI versioning (`compatible` strings), and multi-subsystem composition. Backed by the in-tree `libfdt` library (`CONFIG_LIBFDT`). |
| **Protocol Buffers** | **Not used.** No protobuf runtime exists in the kernel tree. Cannot operate during early boot without dynamic allocation. Adds unnecessary external dependency for a role that FDT already fills. |
| **Custom binary (`__packed` structs)** | **Used for data payloads.** Leaf-level data (session arrays, file descriptor metadata, folio bitmaps) is serialized as `__packed` C structures pointed to by FDT properties. This hybrid approach gives FDT's self-description at the tree level and zero-copy binary performance at the data level. |
| **sysfs / debugfs** | **Used as the userspace access path.** debugfs exposes the finalized FDT blob and scratch region metadata to the `kexec` userspace tool. sysfs does not directly participate in kernel-to-kernel state transfer because it does not survive `kexec`. Future plans include migrating debugfs interfaces to sysfs once the ABI stabilizes. |

The architectural choice can be summarized as: **FDT is the envelope; packed structs
are the letter; debugfs is the mailbox.**

---

## 5. References

All references below are to files within the Linux kernel v7.0.0-rc3 source tree:

- `scripts/dtc/libfdt/fdt.h` — FDT binary format header structure
- `scripts/dtc/libfdt/libfdt.h` — libfdt API declarations
- `include/linux/kho/abi/kexec_handover.h` — KHO FDT ABI specification
- `include/linux/kho/abi/luo.h` — LUO FDT ABI specification
- `include/linux/kho/abi/memblock.h` — memblock FDT ABI specification
- `include/linux/kho/abi/memfd.h` — memfd serialization structures
- `kernel/liveupdate/kexec_handover.c` — KHO core: FDT creation, finalization, population
- `kernel/liveupdate/kexec_handover_debugfs.c` — debugfs interface for FDT blobs
- `kernel/liveupdate/luo_core.c` — LUO sub-FDT creation and subsystem registration
- `kernel/liveupdate/Kconfig` — `CONFIG_KEXEC_HANDOVER` selects `LIBFDT`
- `Documentation/core-api/kho/index.rst` — KHO subsystem overview
- `Documentation/admin-guide/mm/kho.rst` — KHO usage guide and debugfs interface list
