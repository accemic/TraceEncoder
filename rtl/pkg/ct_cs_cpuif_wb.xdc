# -*- indent-tabs-mode:t; tab-width:4 -*-
# vim: tabstop=4:noexpandtab
#############################################################################
# Copyright (c) 2025 by Accemic Technologies GmbH Kiefersfelden Germany
# SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
#
# @author	Alexander Weiss <aweiss@accemic.com>
# @brief	Timing constraints for ct_cs_cpuif_wb
#############################################################################

# The cs_tip / cs_proc / cs_atb / cs_dec interface outputs carry pseudo-static
# control/status values from the wb_clk domain to the tip, proc, atb and decoder
# clock domains combinationally. Any path that crosses these interface nets is
# asynchronous by design and must be excluded from timing analysis.
set_false_path -through [get_nets -quiet {cs_tip* cs_proc* cs_atb* cs_dec*}]
