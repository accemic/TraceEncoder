#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
"""
Auto-generated SystemVerilog Wishbone Register Access Generator

This script parses a SystemRDL description of a Wishbone-accessible
address map and generates two SystemVerilog helper files:

  1. <addrmap>_wb_pkg.sv
     - SystemVerilog package that contains:
         * Register base addresses (ADDR_<REGNAME>)
         * Bit-field position and width constants (BITPOS_*, WIDTH_*)
         * Memory base addresses and sizes (ADDR_<MEM>,
           <MEM>_NUM_ENTRIES, <MEM>_ENTRY_BYTES)

  2. <addrmap>_wb_helper.sv
     - SystemVerilog helper module that provides:
         * A simple Wishbone master BFM (read/write tasks)
         * Per-register tasks:
             - Write_<reg>(...)
             - Read_<reg>(...)
         * Per-field tasks:
             - Single-bit fields:
                 Set_<reg>_<field>(value)
                     Set or clear this single bit (value = 1 / 0).
                     Implemented as a read–modify–write on that bit.
                 Get_<reg>_<field>(value)
                     Read back the bit (value = reg[bitpos]).
                     Only generated if sw == rw or sw == r.
             - Multi-bit fields:
                 Set_<reg>_<field>(value)
                     Overwrite the complete field with the given value
                     (field = value, via read–modify–write on the field slice).
                 SetMask_<reg>_<field>(value)
                     Set all bits that are '1' in value:
                         field |= value;
                 ClearMask_<reg>_<field>(value)
                     Clear all bits that are '1' in value:
                         field &= ~value;
                 Get_<reg>_<field>(value)
                     Read back the field:
                         value = field;
                     Only generated if sw == rw or sw == r.

In addition, external memories declared in the RDL (e.g. "external mem_t mem0")
are supported. For each such memory, helper tasks are generated:

  * Write_<MemName>(index, data)
      - Write a full memory entry at the given index.
  * Read_<MemName>(index, data)
      - Read a full memory entry.
  * SetMask_<MemName>(index, mask)
      - Read–modify–write: entry |= mask.
  * ClearMask_<MemName>(index, mask)
      - Read–modify–write: entry &= ~mask.
  * Get_<MemName>(index, data)
      - Read the current entry.
      - Only generated if sw == rw or sw == r on the memory.

<MemName> is derived from the RDL property "name" (memX->name) if present,
with spaces and punctuation converted to underscores. For example:

    external act_st_mem_t mem0 @ 0x4000;
    mem0->name = "ACT-ST Memory";

…will result in:

    localparam logic [31:0] ADDR_ACT_ST_MEMORY = 32'h00004000;
    task Write_ACT_ST_Memory(input int index,
                             input  logic [63:0] data);
        write(ADDR_ACT_ST_MEMORY + index * 8, data);
    endtask

Usage
-----
    generate_wb_pkg.py <input.rdl> [output_dir]

  * <input.rdl>  : SystemRDL file that defines one top-level addrmap.
  * [output_dir] : Directory where the generated SystemVerilog files are
                   written. If omitted, the directory of <input.rdl> is used.

The name of the top-level addrmap in the RDL (for example 'ct_cs_cpuif')
is used as the base name for both the package and the helper module:

  Package file      : <addrmap>_wb_pkg.sv
  Helper module file: <addrmap>_wb_helper.sv
  Package name      : <addrmap>_wb_pkg
  Helper module name: <addrmap>_wb_helper

The helper performs read–modify–write cycles for field-level operations
so that only the targeted bits are changed, while all other bits in the
register are preserved.
"""

import sys
import os
import re
from systemrdl import RDLCompiler, RDLListener, RDLWalker
from systemrdl.node import AddrmapNode, RegfileNode, MemNode


class RegisterAddressExtractor(RDLListener):
    """
    Walks the elaborated RDL design and aggregates registers by
    hierarchical name (including regfile prefixes).

    - If a logical register appears only once, it is treated as a simple
      register.
    - If it appears multiple times at regular address strides, it is
      treated as an array (e.g. regfile[NUM] instances), and only the
      first element's address is used as the base address.
    """

    def __init__(self) -> None:
        self._groups = {}

    def _logical_name(self, node) -> str:
        """
        Build a hierarchical logical name including regfile instance names,
        e.g. trTeFilter_Control for reg Control inside regfile trTeFilter.
        """
        parts = []
        p = node.parent
        # Walk upwards until the addrmap
        while p is not None and not isinstance(p, AddrmapNode):
            if isinstance(p, RegfileNode):
                if p.inst_name:
                    parts.append(p.inst_name)
            p = p.parent
        parts.reverse()
        parts.append(node.inst_name)
        return "_".join(parts)

    def enter_Reg(self, node) -> None:
        logical_name = self._logical_name(node)
        reg_addr = int(node.absolute_address)

        # Collect fields from this instance (all instances of the same
        # logical name are expected to have identical fields).
        fields = []
        for field in node.fields():
            try:
                sw = field.get_property("sw")
            except Exception:
                sw = None
            field_info = {
                "name": field.inst_name,
                "lsb": field.low,
                "msb": field.high,
                "width": field.width,
                "sw": sw,
            }
            fields.append(field_info)

        group = self._groups.get(logical_name)
        if group is None:
            group = {
                "name": logical_name,
                "addresses": [],
                "fields": fields,
            }
            self._groups[logical_name] = group

        group["addresses"].append(reg_addr)

    def get_registers(self):
        """
        Returns a list of logical register descriptions:

            {
                'name'      : <logical name, e.g. trTeFilter_Control>,
                'address'   : <base address (first instance)>,
                'fields'    : [ {name,lsb,msb,width,sw}, ... ],
                'is_array'  : True/False,
                'array_len' : number of instances (>=1),
                'stride'    : address stride in bytes (0 if not array)
            }
        """
        registers = []
        for name, group in self._groups.items():
            addrs = sorted(set(group["addresses"]))
            base = addrs[0]
            if len(addrs) > 1:
                stride = addrs[1] - addrs[0]
                is_array = True
                array_len = len(addrs)
            else:
                stride = 0
                is_array = False
                array_len = 1

            registers.append(
                {
                    "name": name,
                    "address": base,
                    "fields": group["fields"],
                    "is_array": is_array,
                    "array_len": array_len,
                    "stride": stride,
                }
            )

        # Sort by address for a stable, readable output
        registers.sort(key=lambda r: r["address"])
        return registers


class MemoryExtractor(RDLListener):
    """
    Collects external memories (MemNode) and their properties:

        {
            'inst_name' : 'mem0',
            'base_name' : 'ACT_ST_Memory',   # derived from mem0->name or inst_name
            'address'   : base address,
            'width'     : memwidth in bits,
            'entries'   : mementries,
            'sw'        : sw property (if any)
        }
    """

    def __init__(self) -> None:
        self.memories = []

    @staticmethod
    def _sanitize_name(raw: str) -> str:
        # Replace non-alphanumeric with underscores, collapse, strip.
        s = re.sub(r"[^0-9a-zA-Z]+", "_", raw)
        s = re.sub(r"_+", "_", s)
        s = s.strip("_")
        if not s:
            s = "mem"
        # Avoid leading digit
        if s[0].isdigit():
            s = "M_" + s
        return s

    def enter_Mem(self, node: MemNode) -> None:
        # Only handle memories with a concrete address (externals)
        try:
            base_addr = int(node.absolute_address)
        except Exception:
            return

        inst_name = node.inst_name or "mem"
        # Prefer RDL "name" property if present
        user_name = None
        try:
            user_name = node.get_property("name")
        except Exception:
            user_name = None

        base_name_src = user_name if isinstance(user_name, str) and user_name.strip() else inst_name
        base_name = self._sanitize_name(base_name_src)

        # memwidth & mementries from properties
        def _prop_int(pname, default=0):
            try:
                v = node.get_property(pname)
                return int(v)
            except Exception:
                return default

        width = _prop_int("memwidth", 0)
        entries = _prop_int("mementries", 0)

        try:
            sw = node.get_property("sw")
        except Exception:
            sw = None

        self.memories.append(
            {
                "inst_name": inst_name,
                "base_name": base_name,
                "address": base_addr,
                "width": width,
                "entries": entries,
                "sw": sw,
            }
        )

    def get_memories(self):
        # Sort by address for readability
        self.memories.sort(key=lambda m: m["address"])
        return self.memories


class TypeAnchorExtractor(RDLListener):
    """
    Collects ispresent=false registers from the compiled RDL design as
    "type anchors": registers whose layout is needed in SystemVerilog as
    typedefs but which the designer did NOT want exposed in the addrmap
    (neither as an MMIO register nor in the HTML docs).

    PeakRDL-regblock and PeakRDL-html both honour ispresent=false and
    drop such registers entirely, taking their struct/enum types with
    them. This extractor walks the design with skip_not_present=False so
    it can still see those registers and rebuild matching SV types.

    For each hidden register we record:
        - inst_name (register name, e.g. "trActCapStCmd")
        - ordered field list, each with {name, low, high, width, encode}
    and for every encode enum we also record:
        - enum type name (e.g. "trActCapStCmd_e")
        - ordered members, each with {name, value}

    The output naming convention deliberately matches what PeakRDL-regblock
    would have emitted, so existing RTL consumers continue to use the same
    identifiers (ct_cs_cpuif__trActCapStCmd__out_t, etc.) unchanged.
    """

    def __init__(self) -> None:
        self.registers = []
        self.enums = {}
        self._current = None

    def enter_Reg(self, node) -> None:
        # Only collect registers the designer explicitly hid via
        # ispresent=false — present regs are already handled by PeakRDL.
        try:
            present = node.get_property("ispresent")
        except Exception:
            present = True
        if present:
            return
        self._current = {
            "name": node.inst_name,
            "fields": [],
        }
        self.registers.append(self._current)

    def enter_Field(self, node) -> None:
        if self._current is None:
            return
        # Only collect fields belonging to the currently-open hidden reg.
        if node.parent.inst_name != self._current["name"]:
            return

        try:
            enc_type = node.get_property("encode")
        except Exception:
            enc_type = None

        enc_name = None
        if enc_type is not None:
            enc_name = getattr(enc_type, "__name__", None) or enc_type.type_name
            if enc_name and enc_name not in self.enums:
                members = []
                for member in enc_type:
                    members.append(
                        {
                            "name": member.name,
                            "value": int(member.value),
                        }
                    )
                self.enums[enc_name] = members

        self._current["fields"].append(
            {
                "name": node.inst_name,
                "low": node.low,
                "high": node.high,
                "width": node.width,
                "encode": enc_name,
            }
        )

    def exit_Reg(self, node) -> None:
        try:
            present = node.get_property("ispresent")
        except Exception:
            present = True
        if not present:
            self._current = None


def safe_print(msg: str) -> None:
    """Print without fancy unicode to keep logs/tooling happy."""
    msg = msg.replace("\u2713", "[OK]").replace("\u2717", "[X]")
    print(msg)


def generate_types_package(
    registers, enums, addrmap_name: str, package_name: str, output_file: str
) -> None:
    """
    Emit a SystemVerilog package with enum + struct typedefs for the given
    ispresent=false registers. Names mirror PeakRDL-regblock's convention
    so existing RTL identifiers stay unchanged.
    """

    lines = [
        "// ============================================================================",
        "// Auto-generated SystemVerilog types package",
        "// Rebuilds the enum + struct typedefs of ispresent=false registers that",
        "// PeakRDL-regblock drops from ct_cs_cpuif_pkg.sv. Generated from the same",
        "// RDL source — keep in sync by rerunning `make rdl`.",
        "// DO NOT EDIT MANUALLY - Changes will be overwritten!",
        "// ============================================================================",
        "",
        f"package {package_name};",
        "",
    ]

    def _enum_width(members):
        max_val = max((m["value"] for m in members), default=0)
        return max(1, max_val.bit_length())

    if enums:
        lines += [
            "    // Enumerations",
            "    // ========================================================================",
        ]
        for enum_name, members in enums.items():
            width = _enum_width(members)
            sv_type = f"{addrmap_name}__{enum_name}_e"
            lines.append(f"    typedef enum logic [{width - 1}:0] {{")
            for i, m in enumerate(members):
                sep = "," if i < len(members) - 1 else ""
                lines.append(
                    f"        {addrmap_name}__{enum_name}__{m['name']} = 'h{m['value']:x}{sep}"
                )
            lines.append(f"    }} {sv_type};")
            lines.append("")

    if registers:
        lines += [
            "    // Field sub-structs and composite register structs",
            "    // ========================================================================",
        ]
        for reg in registers:
            for f in reg["fields"]:
                sub_type = f"{addrmap_name}__{reg['name']}__{f['name']}__out_t"
                lines += [
                    "    typedef struct {",
                    f"        logic [{f['width'] - 1}:0] value;",
                    f"    }} {sub_type};",
                    "",
                ]
            parent_type = f"{addrmap_name}__{reg['name']}__out_t"
            lines.append("    typedef struct {")
            for f in reg["fields"]:
                sub_type = f"{addrmap_name}__{reg['name']}__{f['name']}__out_t"
                lines.append(f"        {sub_type} {f['name']};")
            lines.append(f"    }} {parent_type};")
            lines.append("")

    lines.append("endpackage")
    lines.append("")

    with open(output_file, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))

    safe_print(f"[OK] Generated types package: {output_file}")


def generate_sv_package(registers, memories, package_name: str, output_file: str) -> None:
    """Generate SystemVerilog package with address/bitfield/memory constants."""

    lines = [
        "// ============================================================================",
        "// Auto-generated Wishbone Register Access Package",
        "// Contains: Register addresses, bitfield positions, and memory layout constants",
        "// DO NOT EDIT MANUALLY - Changes will be overwritten!",
        "// ============================================================================",
        "",
        f"package {package_name};",
        "",
    ]

    # Register base addresses
    lines += [
        "    // Register Base Addresses",
        "    // ========================================================================",
    ]

    for reg in registers:
        name = reg["name"]
        addr = reg["address"]
        name_upper = name.upper()
        comment_parts = []
        if reg["is_array"]:
            comment_parts.append(
                f"{reg['array_len']} instances, stride 0x{reg['stride']:X}"
            )
        comment = ""
        if comment_parts:
            comment = "  // " + ", ".join(comment_parts)

        lines.append(
            f"    localparam logic [31:0] ADDR_{name_upper:30s} = 32'h{addr:08X};{comment}"
        )

    # Memory base addresses
    if memories:
        lines += [
            "",
            "    // Memory Base Addresses and Sizes",
            "    // ========================================================================",
        ]
        for mem in memories:
            base_name = mem["base_name"]
            base_upper = base_name.upper()
            addr = mem["address"]
            width = mem["width"]
            entries = mem["entries"]
            entry_bytes = width // 8 if width else 0
            comment = f"  // instance '{mem['inst_name']}'"
            lines.append(
                f"    localparam logic [31:0] ADDR_{base_upper:30s} = 32'h{addr:08X};{comment}"
            )
            if entries:
                lines.append(
                    f"    localparam int {base_upper}_NUM_ENTRIES{' '*(24-len(base_upper))} = {entries};"
                )
            if entry_bytes:
                lines.append(
                    f"    localparam int {base_upper}_ENTRY_BYTES{' '*(24-len(base_upper))} = {entry_bytes};"
                )

    # Bitfield constants
    lines += [
        "",
        "    // Bitfield Positions and Widths",
        "    // ========================================================================",
    ]

    for reg in registers:
        if reg["fields"]:
            name = reg["name"]
            lines.append("")
            lines.append(f"    // Register: {name} @ 0x{reg['address']:04X}")

            for field in reg["fields"]:
                field_name = field["name"]
                const_name = f"{name}_{field_name}"

                if field["width"] == 1:
                    lines.append(
                        f"    localparam int BITPOS_{const_name:40s} = {field['lsb']};"
                    )
                else:
                    pad = " " * (35 - len(const_name))
                    pad_w = " " * (39 - len(const_name))
                    lines.append(
                        f"    localparam int BITPOS_{const_name}_LSB{pad} = {field['lsb']};"
                    )
                    lines.append(
                        f"    localparam int BITPOS_{const_name}_MSB{pad} = {field['msb']};"
                    )
                    lines.append(
                        f"    localparam int WIDTH_{const_name}{pad_w} = {field['width']};"
                    )

    lines.append("")
    lines.append("endpackage")
    lines.append("")

    with open(output_file, "w", encoding="utf-8") as f:
        f.write('\n'.join(lines))

    safe_print(f"[OK] Generated package: {output_file}")
    safe_print(f"  - {len(registers)} logical registers")
    safe_print(f"  - {sum(len(r['fields']) for r in registers)} fields")
    safe_print(f"  - {len(memories)} memories")


def generate_helper_module(
    registers, memories, package_name: str, helper_module_name: str, output_file: str
) -> None:
    """Generate helper module following wb_helper pattern."""

    def is_readable(sw) -> bool:
        """
        Returns True if the given sw property value indicates that SW
        can read the component. For our purposes:
          - None (unspecified) -> readable (default rw)
          - 'rw' or 'r' (case-insensitive) -> readable
          - everything else -> not readable
        """
        if sw is None:
            return True
        sval = str(sw).lower()
        return sval in ("rw", "r")

    lines = [
        "// ============================================================================",
        "// Auto-generated Wishbone Register Access Helper Module",
        "// DO NOT EDIT MANUALLY - Changes will be overwritten!",
        "//",
        "// Usage in testbench:",
        f"//   import {package_name}::*;",
        f"//   {helper_module_name} #(.WB_DATA_WIDTH(32), .WB_ADDR_WIDTH(32)) helper(clk, wb);",
        "//",
        "//   // Generic register access",
        "//   //   helper.write(ADDR_<REG>, 32'hAABBCCDD);",
        "//   //   helper.read(ADDR_<REG>, data);",
        "//   //   helper.Write_<reg>(32'hAABBCCDD);",
        "//   //   helper.Read_<reg>(data);",
        "//",
        "//   // Field-level helpers (examples):",
        "//   //   Set_trTeDataFilters_Filters(16'h3);         // field = 16'h3",
        "//   //   Get_trTeDataFilters_Filters(value);         // read field (only if sw=r/rw)",
        "//   //   SetMask_trTeDataFilters_Filters(16'h3);     // field |= 16'h3",
        "//   //   ClearMask_trTeDataFilters_Filters(16'h3);   // field &= ~16'h3",
        "//   //   Set_trTsControl_Active(1'b0);              // clear single bit",
        "//   //   Get_trTsControl_Active(value);             // read single bit (only if sw=r/rw)",
        "//",
        "//   // For register arrays (e.g. regfile[NUM]), tasks take an index:",
        "//   //   Write_trTeFilter_Control(id, data);",
        "//   //   Read_trTeFilter_Control(id, data);",
        "//   //   Set_trTeFilter_Control_Enable(id, 1'b1);",
        "//   //   Get_trTeFilter_Control_Enable(id, value);",
        "//",
        "//   // For memories (external mem), tasks take an index:",
        "//   //   Write_ACT_ST_Memory(entry, data64);",
        "//   //   Read_ACT_ST_Memory(entry, data64);",
        "//   //   SetMask_ACT_ST_Memory(entry, mask64);",
        "//   //   ClearMask_ACT_ST_Memory(entry, mask64);",
        "//   //   Get_ACT_ST_Memory(entry, data64);     // only if sw=r/rw",
        "// ============================================================================",
        "",
        f"module {helper_module_name} #(",
        "\tint unsigned WB_DATA_WIDTH  = 32,",
        "\tint unsigned WB_ADDR_WIDTH  = 32",
        ")(",
        "\tinput  uwire logic clk,",
        "\twb_if.master wb",
        ");",
        "",
        f"\timport {package_name}::*;",
        "",
        "\t// ========================================================================",
        "\t// Basic Wishbone Transactions",
        "\t// ========================================================================",
        "",
        "\ttask clear;",
        "\t\twb.addr     <= 'x;",
        "\t\twb.data_m2s <= 'x;",
        "\t\twb.cyc      <= '0;",
        "\t\twb.stb      <= '0;",
        "\t\twb.we       <= '0;",
        "\t\twb.sel      <= '0;",
        "\tendtask",
        "",
        "\ttask write(input logic [WB_ADDR_WIDTH-1:0] addr, input logic [WB_DATA_WIDTH-1:0] data);",
        "\t\twb.addr     <= addr;",
        "\t\twb.data_m2s <= data;",
        "\t\twb.cyc      <= '1;",
        "\t\twb.stb      <= '1;",
        "\t\twb.we       <= '1;",
        "\t\twb.sel      <= '1;",
        "\t\t@(posedge clk iff wb.ack || wb.err);",
        "\t\tclear();",
        "\t\t@(posedge clk);",
        "\tendtask",
        "",
        "\ttask read(input logic [WB_ADDR_WIDTH-1:0] addr, output logic [WB_DATA_WIDTH-1:0] data);",
        "\t\twb.addr     <= addr;",
        "\t\twb.data_m2s <= 'x;",
        "\t\twb.cyc      <= '1;",
        "\t\twb.stb      <= '1;",
        "\t\twb.we       <= '0;",
        "\t\twb.sel      <= '1;",
        "\t\t@(posedge clk iff wb.ack || wb.err);",
        "\t\tdata = wb.data_s2m;",
        "\t\tclear();",
        "\t\t@(posedge clk);",
        "\tendtask",
        "",
        "\t// Single-bit helper: set a single bit to the given value",
        "\ttask SetBitField(input logic [WB_ADDR_WIDTH-1:0] addr, input int bit_pos, input logic value);",
        "\t\tlogic [WB_DATA_WIDTH-1:0] reg_data;",
        "\t\tread(addr, reg_data);",
        "\t\treg_data[bit_pos] = value;",
        "\t\twrite(addr, reg_data);",
        "\tendtask",
        "",
        "\t// Multi-bit helper: overwrite a bitfield with a new value",
        "\ttask SetField(input logic [WB_ADDR_WIDTH-1:0] addr,",
        "\t\t         input int msb, input int lsb,",
        "\t\t         input logic [WB_DATA_WIDTH-1:0] value);",
        "\t\tlogic [WB_DATA_WIDTH-1:0] reg_data;",
        "\t\tlogic [WB_DATA_WIDTH-1:0] mask;",
        "\t\tint width, i;",
        "\t\twidth = msb - lsb + 1;",
        "\t\tread(addr, reg_data);",
        "\t\tmask = '0;",
        "\t\tfor (i = 0; i < width; i = i + 1) begin",
        "\t\t\tmask[lsb + i] = 1'b1;",
        "\t\tend",
        "\t\treg_data = (reg_data & ~mask);",
        "\t\tfor (i = 0; i < width; i = i + 1) begin",
        "\t\t\treg_data[lsb + i] = value[i];",
        "\t\tend",
        "\t\twrite(addr, reg_data);",
        "\tendtask",
        "",
        "\t// ========================================================================",
        "\t// Register-Specific Access Tasks",
        "\t// ========================================================================",
    ]

    # Register-level tasks
    for reg in registers:
        name = reg["name"]                    # e.g. "trTeFilter_Control"
        name_upper = name.upper()             # e.g. "TRTEFILTER_CONTROL"
        addr = reg["address"]
        is_array = reg["is_array"]
        stride = reg["stride"]

        base_addr_expr = f"ADDR_{name_upper}"
        if is_array and stride != 0:
            stride_expr = f"32'h{stride:08X}"
            addr_expr = f"{base_addr_expr} + id * {stride_expr}"
            index_decl = "input int id, "
            index_decl_read = "input int id, "
            array_comment = (
                f"\t// Register array: {name}[{reg['array_len']}] "
                f"@ 0x{addr:04X}, stride 0x{stride:X}"
            )
        else:
            addr_expr = base_addr_expr
            index_decl = ""
            index_decl_read = ""
            array_comment = None

        lines.append("")
        if array_comment:
            lines.append(array_comment)
        lines.append(f"\t// Register: {name} @ 0x{addr:04X}")

        # Write task
        if is_array and stride != 0:
            lines.append(
                f"\ttask Write_{name}({index_decl}input logic [WB_DATA_WIDTH-1:0] data);"
            )
        else:
            lines.append(
                f"\ttask Write_{name}(input logic [WB_DATA_WIDTH-1:0] data);"
            )
        lines.append(f"\t\twrite({addr_expr}, data);")
        lines.append("\tendtask")

        # Read task (always generated)
        if is_array and stride != 0:
            lines.append("")
            lines.append(
                f"\ttask Read_{name}({index_decl_read}output logic [WB_DATA_WIDTH-1:0] data);"
            )
        else:
            lines.append("")
            lines.append(
                f"\ttask Read_{name}(output logic [WB_DATA_WIDTH-1:0] data);"
            )
        lines.append(f"\t\tread({addr_expr}, data);")
        lines.append("\tendtask")

        # Field-level tasks
        for field in reg["fields"]:
            field_name = field["name"]
            const_name = f"{name}_{field_name}"
            width = field["width"]
            sw = field.get("sw")

            # Choose addr expression with id if this is an array
            if is_array and stride != 0:
                bit_addr_expr = addr_expr  # expression using id
                idx_param_prefix = "input int id, "
            else:
                bit_addr_expr = base_addr_expr
                idx_param_prefix = ""

            if width == 1:
                # Single-bit field: Set + (optional) Get
                lines.append("")
                lines.append(f"\t// Single-bit field: {name}.{field_name}")
                if is_array and stride != 0:
                    lines.append(
                        f"\ttask Set_{name}_{field_name}({idx_param_prefix}input logic value);"
                    )
                else:
                    lines.append(
                        f"\ttask Set_{name}_{field_name}(input logic value);"
                    )
                lines.append(
                    f"\t\tSetBitField({bit_addr_expr}, BITPOS_{const_name}, value);"
                )
                lines.append("\tendtask")
                # Get only if readable
                if is_readable(sw):
                    lines.append("")
                    if is_array and stride != 0:
                        lines.append(
                            f"\ttask Get_{name}_{field_name}({idx_param_prefix}output logic value);"
                        )
                    else:
                        lines.append(
                            f"\ttask Get_{name}_{field_name}(output logic value);"
                        )
                    lines.append("\t\tlogic [WB_DATA_WIDTH-1:0] reg_data;")
                    lines.append(f"\t\tread({bit_addr_expr}, reg_data);")
                    lines.append(
                        f"\t\tvalue = reg_data[BITPOS_{const_name}];"
                    )
                    lines.append("\tendtask")
            else:
                # Multi-bit field: Set(value), ClearMask(value), SetMask(value), (optional) Get(value)
                lines.append("")
                lines.append(f"\t// Multi-bit field: {name}.{field_name}")
                # Set: field = value (RMW on slice)
                if is_array and stride != 0:
                    lines.append(
                        f"\ttask Set_{name}_{field_name}({idx_param_prefix}input logic [{width-1}:0] value);"
                    )
                else:
                    lines.append(
                        f"\ttask Set_{name}_{field_name}(input logic [{width-1}:0] value);"
                    )
                lines.append(
                    f"\t\tSetField({bit_addr_expr}, "
                    f"BITPOS_{const_name}_MSB, BITPOS_{const_name}_LSB, value);"
                )
                lines.append("\tendtask")
                lines.append("")
                # ClearMask: field &= ~value
                if is_array and stride != 0:
                    lines.append(
                        f"\ttask ClearMask_{name}_{field_name}({idx_param_prefix}input logic [{width-1}:0] value);"
                    )
                else:
                    lines.append(
                        f"\ttask ClearMask_{name}_{field_name}(input logic [{width-1}:0] value);"
                    )
                lines.append("\t\tlogic [WB_DATA_WIDTH-1:0] reg_data;")
                lines.append(f"\t\tread({bit_addr_expr}, reg_data);")
                lines.append(
                    f"\t\treg_data[BITPOS_{const_name}_LSB +: {width}] &= ~value;"
                )
                lines.append(f"\t\twrite({bit_addr_expr}, reg_data);")
                lines.append("\tendtask")
                lines.append("")
                # SetMask: field |= value
                if is_array and stride != 0:
                    lines.append(
                        f"\ttask SetMask_{name}_{field_name}({idx_param_prefix}input logic [{width-1}:0] value);"
                    )
                else:
                    lines.append(
                        f"\ttask SetMask_{name}_{field_name}(input logic [{width-1}:0] value);"
                    )
                lines.append("\t\tlogic [WB_DATA_WIDTH-1:0] reg_data;")
                lines.append(f"\t\tread({bit_addr_expr}, reg_data);")
                lines.append(
                    f"\t\treg_data[BITPOS_{const_name}_LSB +: {width}] |= value;"
                )
                lines.append(f"\t\twrite({bit_addr_expr}, reg_data);")
                lines.append("\tendtask")
                # Get only if readable
                if is_readable(sw):
                    lines.append("")
                    if is_array and stride != 0:
                        lines.append(
                            f"\ttask Get_{name}_{field_name}({idx_param_prefix}output logic [{width-1}:0] value);"
                        )
                    else:
                        lines.append(
                            f"\ttask Get_{name}_{field_name}(output logic [{width-1}:0] value);"
                        )
                    lines.append("\t\tlogic [WB_DATA_WIDTH-1:0] reg_data;")
                    lines.append(f"\t\tread({bit_addr_expr}, reg_data);")
                    lines.append(
                        f"\t\tvalue = reg_data[BITPOS_{const_name}_LSB +: {width}];"
                    )
                    lines.append("\tendtask")

    # Memory-level tasks
    if memories:
        lines.append("")
        lines.append("\t// ========================================================================")
        lines.append("\t// Memory Access Tasks (external mem)")
        lines.append("\t// ========================================================================")
        for mem in memories:
            base_name = mem["base_name"]          # e.g. ACT_ST_Memory
            base_upper = base_name.upper()        # e.g. ACT_ST_MEMORY
            addr = mem["address"]
            width = mem["width"] or 32
            entry_bytes = (mem["width"] // 8) if mem["width"] else 4
            sw = mem.get("sw")

            lines.append("")
            lines.append(f"\t// Memory: {base_name} @ 0x{addr:04X}")
            lines.append(
                f"\ttask Write_{base_name}(input int index, input logic [{width-1}:0] data);"
            )
            if width > 32:
                lines.append(f"\t\tfor (int word_idx = 0; word_idx < {width // 32}; word_idx++) begin")
                lines.append(
                    f"\t\t\twrite(ADDR_{base_upper} + index * {entry_bytes} + word_idx * (WB_DATA_WIDTH/8),"
                )
                lines.append(
                    f"\t\t\t\tdata[word_idx * WB_DATA_WIDTH +: WB_DATA_WIDTH]);"
                )
                lines.append("\t\tend")
            else:
                lines.append(
                    f"\t\twrite(ADDR_{base_upper} + index * {entry_bytes}, data);"
                )
            lines.append("\tendtask")
            lines.append("")
            lines.append(
                f"\ttask Read_{base_name}(input int index, output logic [{width-1}:0] data);"
            )
            if width > 32:
                lines.append("\t\tlogic [WB_DATA_WIDTH-1:0] word_data;")
                lines.append("\t\tdata = '0;")
                lines.append(f"\t\tfor (int word_idx = 0; word_idx < {width // 32}; word_idx++) begin")
                lines.append(
                    f"\t\t\tread(ADDR_{base_upper} + index * {entry_bytes} + word_idx * (WB_DATA_WIDTH/8), word_data);"
                )
                lines.append(
                    f"\t\t\tdata[word_idx * WB_DATA_WIDTH +: WB_DATA_WIDTH] = word_data;"
                )
                lines.append("\t\tend")
            else:
                lines.append(
                    f"\t\tread(ADDR_{base_upper} + index * {entry_bytes}, data);"
                )
            lines.append("\tendtask")
            lines.append("")
            # ClearMask
            lines.append(
                f"\ttask ClearMask_{base_name}(input int index, input logic [{width-1}:0] mask);"
            )
            lines.append(f"\t\tlogic [{width-1}:0] entry;")
            lines.append(f"\t\tRead_{base_name}(index, entry);")
            lines.append("\t\tentry &= ~mask;")
            lines.append(f"\t\tWrite_{base_name}(index, entry);")
            lines.append("\tendtask")
            lines.append("")
            # SetMask
            lines.append(
                f"\ttask SetMask_{base_name}(input int index, input logic [{width-1}:0] mask);"
            )
            lines.append(f"\t\tlogic [{width-1}:0] entry;")
            lines.append(f"\t\tRead_{base_name}(index, entry);")
            lines.append("\t\tentry |= mask;")
            lines.append(f"\t\tWrite_{base_name}(index, entry);")
            lines.append("\tendtask")
            # Get only if readable
            if is_readable(sw):
                lines.append("")
                lines.append(
                    f"\ttask Get_{base_name}(input int index, output logic [{width-1}:0] data);"
                )
                lines.append(f"\t\tRead_{base_name}(index, data);")
                lines.append("\tendtask")

    lines.append("")
    lines.append("endmodule")
    lines.append("")

    with open(output_file, "w", encoding="utf-8") as f:
        f.write('\n'.join(lines))

    safe_print(f"[OK] Generated helper module: {output_file}")


def main() -> None:
    if len(sys.argv) < 2:
        safe_print("Usage: generate_wb_pkg.py <input.rdl> [output_dir]")
        sys.exit(1)

    rdl_file = sys.argv[1]
    rdl_file = os.path.abspath(rdl_file)
    rdl_dir = os.path.dirname(rdl_file)

    # Second argument: output directory (optional)
    output_dir = sys.argv[2] if len(sys.argv) > 2 else rdl_dir
    output_dir = os.path.abspath(output_dir)

    safe_print(f"Processing     : {rdl_file}")
    safe_print(f"Output dir     : {output_dir}")

    rdlc = RDLCompiler()
    try:
        rdlc.compile_file(rdl_file)
        root = rdlc.elaborate()
    except Exception as e:
        safe_print(f"ERROR: Failed to compile RDL file: {e}")
        sys.exit(1)

    # Determine top-level addrmap instance name from elaborated model.
    top_addrmap = None
    for child in root.children():
        if isinstance(child, AddrmapNode):
            top_addrmap = child
            break

    if top_addrmap is None:
        safe_print("ERROR: Could not find top-level addrmap in RDL design.")
        sys.exit(1)

    addrmap_name = getattr(top_addrmap, "inst_name", None) or getattr(
        top_addrmap, "orig_type_name", None
    )

    if not addrmap_name:
        # Final fallback: base name of the RDL file
        addrmap_name = os.path.splitext(os.path.basename(rdl_file))[0]

    pkg_name = f"{addrmap_name}_wb_pkg"
    helper_module_name = f"{addrmap_name}_wb_helper"

    pkg_file = os.path.join(output_dir, f"{addrmap_name}_wb_pkg.sv")
    helper_file = os.path.join(output_dir, f"{addrmap_name}_wb_helper.sv")

    safe_print(f"Top-level addrmap: {addrmap_name}")
    safe_print(f"Package name      : {pkg_name}")
    safe_print(f"Package file      : {pkg_file}")
    safe_print(f"Helper module name: {helper_module_name}")
    safe_print(f"Helper file       : {helper_file}")

    reg_extractor = RegisterAddressExtractor()
    mem_extractor = MemoryExtractor()
    walker = RDLWalker(unroll=True)
    walker.walk(root, reg_extractor)
    walker.walk(root, mem_extractor)

    # Walk again with skip_not_present=False to recover ispresent=false
    # registers as SystemVerilog type anchors (see TypeAnchorExtractor).
    type_anchor_extractor = TypeAnchorExtractor()
    RDLWalker(unroll=True, skip_not_present=False).walk(root, type_anchor_extractor)

    registers = reg_extractor.get_registers()
    memories = mem_extractor.get_memories()
    type_anchor_regs = type_anchor_extractor.registers
    type_anchor_enums = type_anchor_extractor.enums

    if not registers and not memories:
        safe_print("WARNING: No registers or memories found in RDL file!")
        sys.exit(1)

    # Generate outputs
    generate_sv_package(registers, memories, pkg_name, pkg_file)
    generate_helper_module(registers, memories, pkg_name, helper_module_name, helper_file)

    if type_anchor_regs or type_anchor_enums:
        types_pkg_name = f"{addrmap_name}_types_pkg"
        types_pkg_file = os.path.join(output_dir, f"{addrmap_name}_types_pkg.sv")
        generate_types_package(
            type_anchor_regs,
            type_anchor_enums,
            addrmap_name,
            types_pkg_name,
            types_pkg_file,
        )

    safe_print("")
    safe_print("[OK] Generation complete!")


if __name__ == "__main__":
    main()
