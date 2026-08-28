# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
#
# TCL.PRE hook for the dual-CVA6 synthesis/implementation
# (run_cva6_2_bitstream.tcl). Own vendored copy of
# examples/kv260/rocket_linux/fpga/rocket_synth_pre.tcl -- same
# per-example-vendoring reasoning as gen_ip.tcl/abc_filelist.py (small,
# self-contained build-flow file; content byte-identical).
#
# A project run executes in its OWN Vivado process -- `set_param` from the
# driver script does not apply there. Hence this hook: it sets the parameter
# that saved the first single-threaded-synthesis-required OOC runs of this
# design family.
#
# Finding (2026-08-08 12:55, the predecessor repository,
# originally observed on the Rocket flow this hook was first written for):
# the multi-threaded optimizer died mid-"Cross Boundary and Area
# Optimization" with EXCEPTION_ACCESS_VIOLATION -- with 25 GiB of free RAM,
# so not a memory shortage. With a single thread, the same run completed.
# synth_cva6_cfg_ooc.tcl and synth_cva6_2_ooc.tcl/synth_cva6_2_soc_ooc.tcl
# (in this directory) set the same parameter directly for the same reason;
# this hook additionally covers the TCL.PRE step of the full bitstream
# flow's project-run process, which a plain set_param in the driver script
# cannot reach.
set_param general.maxThreads 1
