# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
#
# The BOARD version of the cv64a6 core configuration (delta D6) -- derived,
# not copied. Own vendored copy of
# examples/kv260/cva6_linux64/fpga/cva6_linux64_board_cfg.tcl (content
# byte-identical, same per-example-vendoring reasoning as gen_ip.tcl):
# sourced by run_cva6_2_bitstream.tcl, synth_cva6_2_ooc.tcl and
# synth_cva6_2_soc_ooc.tcl (in this directory) for the RV64 (cv64a6) build
# variant of this dual-core example -- NOT needed for the RV32
# (cv32a6_ima_sv32_fpga) variant, whose config_pkg already carries the
# board-proven conservative CachedRegionLength.
#
# Why it exists
# -----------------
# `cv64a6_imac_sv39_ctrace_config_pkg.sv` sets `CachedRegionLength` to
# 192 MiB. For simulation that is correct and verified; for the BOARD it is
# the state that reproducibly correlated with a failure within ~5 s on the
# RV32 twin (cacheable memory above 0x6800_0000 => cache-line bursts on the
# PS HP port). The board-proven conservative state is `CachedRegionLength`
# = 64 MiB with `ExecuteRegionLength` = 192 MiB unchanged -- see
# third_party/cva6_ref/CVA6_PIN.md's "D5 addendum" and its requirement:
# "every new config (D6 included) adopts this conservative state before a
# bitstream, or proves the opposite on the board."
#
# Why DERIVED rather than copied
# ------------------------------
# The D6 file lives in third_party/ and belongs to the packages responsible
# for the vendored CVA6 core (ongoing work there). A second copy in this
# tree would be a permanent drift source. This procedure reads the D6 file
# fresh on EVERY run, replaces EXACTLY one constant, and writes the result
# into the build directory. It aborts if the starting state is not the
# expected one -- a silent derivation from a since-changed template would
# be worse than no derivation at all.
#
# Usage:
#   source [file join $script_dir cva6_linux64_board_cfg.tcl]
#   set cfg_sv [r4b_board_config_pkg $repo_root $outdir]
# and in the CVA6 file list
#   --exclude cv64a6_imac_sv39_ctrace_config_pkg.sv
# taking $cfg_sv instead.

proc r4b_board_config_pkg {repo_root outdir} {
	set src [file join $repo_root examples kv260 third_party cva6_ref core include \
	             cv64a6_imac_sv39_ctrace_config_pkg.sv]
	if {![file exists $src]} { error "r4b_board_config_pkg: template missing: $src" }

	# Read/write binary: the template carries CRLF. Without -translation
	# binary, Tcl would write LF back and the derived file would differ on
	# EVERY line -- a diff against the template would then be worthless.
	set fh [open $src r]; fconfigure $fh -translation binary
	set txt [read $fh]; close $fh

	# Expected starting state: both regions 192 MiB (0x0C00_0000).
	set n_exec [regexp -all {ExecuteRegionLength:\s*1024'\(\{64'h0C00_0000\}\)} $txt]
	set n_cach [regexp -all {CachedRegionLength:\s*1024'\(\{64'h0C00_0000\}\)}  $txt]
	if {$n_exec != 1} {
		error "r4b_board_config_pkg: ExecuteRegionLength=192MiB found $n_exec times (expected 1) -- D6 has changed, check the derivation by hand"
	}
	if {$n_cach != 1} {
		# Already conservative? Then the derivation is superfluous, but the
		# caller should be TOLD, not left to guess.
		set n_ok [regexp -all {CachedRegionLength:\s*1024'\(\{64'h0400_0000\}\)} $txt]
		if {$n_ok == 1} {
			puts "### R4B_CFG: D6 already carries Cached=64MiB -- the derivation is a no-op"
		} else {
			error "r4b_board_config_pkg: CachedRegionLength is neither 192 nor 64 MiB -- check D6 by hand"
		}
	}

	# Line-by-line replacement instead of a regex back-reference: only the
	# ONE line with CachedRegionLength is touched, the rest of the file
	# stays byte-identical (including indentation). A back-reference regsub
	# here would be harder to read than the loop and have the same effect.
	set lines [split $txt "\n"]
	set nsub 0
	for {set i 0} {$i < [llength $lines]} {incr i} {
		set l [lindex $lines $i]
		if {[string first "CachedRegionLength:" $l] >= 0 &&
		    [string first "64'h0C00_0000" $l] >= 0} {
			lset lines $i [string map {64'h0C00_0000 64'h0400_0000} $l]
			incr nsub
		}
	}
	if {$nsub != $n_cach} {
		error "r4b_board_config_pkg: $nsub substitutions, $n_cach expected -- derivation aborted"
	}
	set txt [join $lines "\n"]

	# Header lines in the template's own line ending (CRLF, if it has one),
	# so that `tail -n +5 <derived> | diff - <template>` reports exactly
	# one line.
	set eol [expr {[string first "\r\n" $txt] >= 0 ? "\r\n" : "\n"}]
	set hdr {}
	append hdr "// DERIVED from third_party/cva6_ref/core/include/cv64a6_imac_sv39_ctrace_config_pkg.sv$eol"
	append hdr "// by examples/kv260/cva6_linux64/fpga/cva6_linux64_board_cfg.tcl -- DO NOT EDIT BY HAND.$eol"
	append hdr "// Only change: CachedRegionLength 192 MiB -> 64 MiB (board-proven conservative$eol"
	append hdr "// state, CVA6_PIN.md D5 addendum). Substitutions: $nsub$eol"

	file mkdir $outdir
	set dst [file join $outdir cva6_linux64_board_config_pkg.sv]
	set fh [open $dst w]; fconfigure $fh -translation binary
	puts -nonewline $fh $hdr$txt; close $fh
	puts "### R4B_CFG: board configuration derived ($nsub substitution) -> $dst"
	return $dst
}
