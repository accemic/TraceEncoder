# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
#
# TCL.PRE hook for the two-hart Rocket synthesis/implementation
# (run_rocket2_bitstream.tcl). Identical content to
# ../../rocket_linux/fpga/rocket_synth_pre.tcl -- vendored as its own copy
# here (not cross-referenced) for the same reason as this directory's
# gen_ip.tcl/abc_filelist.py: a small, generic, single-line build-flow hook,
# no cross-example TCL dependency needed for it.
#
# A project run executes in its OWN Vivado process -- `set_param` from the
# driver script does not apply there. Hence this hook: it sets the parameter
# that saved the first R4a OOC run (the same multi-threaded-optimizer crash
# class applies to the two-hart generat, which is even larger).
#
# Finding (2026-08-08 12:55, the predecessor repository):
# the multi-threaded optimizer died mid-"Cross Boundary and Area
# Optimization" with EXCEPTION_ACCESS_VIOLATION -- with 25 GiB of free RAM,
# so not a memory shortage. With a single thread, the same run completed
# (54,879 LUT, WNS +3.000 ns). The Rocket's flat generat is the difference
# to the CVA6 runs; synth_cva6_cfg_ooc.tcl:72 has set the same parameter
# all along.
set_param general.maxThreads 1
