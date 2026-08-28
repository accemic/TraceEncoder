# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
#
# TCL.PRE hook for the Rocket synthesis/implementation (run_rocket_bitstream.tcl).
#
# A project run executes in its OWN Vivado process -- `set_param` from the
# driver script does not apply there. Hence this hook: it sets the parameter
# that saved the first R4a OOC run.
#
# Finding (2026-08-08 12:55, the predecessor repository):
# the multi-threaded optimizer died mid-"Cross Boundary and Area
# Optimization" with EXCEPTION_ACCESS_VIOLATION -- with 25 GiB of free RAM,
# so not a memory shortage. With a single thread, the same run completed
# (54,879 LUT, WNS +3.000 ns). The Rocket's 8.8 MB flat generat is the
# difference to the CVA6 runs; synth_cva6_cfg_ooc.tcl:72 has set the same
# parameter all along.
set_param general.maxThreads 1
