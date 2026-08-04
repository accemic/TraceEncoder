# -*- indent-tabs-mode:t; tab-width:4 -*-
# vim: tabstop=4:noexpandtab

#############################################################################
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
#
# Out-of-context implementation constraints for the TGC5B + CEDARtools.TraceEncoder example
# SoC (ct_soc_synth_wrap).
#
# Target: AMD/Xilinx Kria K26 SOM (Kria KV260 carrier) — part
#   xck26-sfvc784-2LV-c
# abc's built-in part shortcuts do not include xck26, so an OOC synthesis run
# for utilization/timing must select this part on the Vivado host (Vivado
# 2022.1, per .abc.config), e.g. via the project settings or synth_design
# -part.
#
# This is an OUT-OF-CONTEXT synthesis wrapper for a resource/timing estimate:
# only the primary clock is constrained; no carrier I/O pins are placed. When
# taking the design to a bitstream on the KV260, add the PS/PL clock source,
# the trace-output pinout (PMOD/FMC/ILA) and reset here.
#############################################################################

# Single PL clock. 100 MHz is a representative PL fabric rate for the K26;
# the whole example runs in one clock domain (see ct_soc_synth_wrap).
create_clock -name clk -period 10.000 [get_ports clk]
