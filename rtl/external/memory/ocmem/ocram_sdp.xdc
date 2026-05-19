# -*- indent-tabs-mode:t; tab-width:4 -*-
# vim: tabstop=4:noexpandtab
#############################################################################
# Copyright (c) 2018 by Accemic Technologies GmbH Kiefersfelden Germany
# SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
#
# @author	Thomas B. Preußer <tpreusser@accemic.com>
# @brief	Implementation constraints for ocram_dsp.
#############################################################################

# This timing constraint is required for supporting independent clocks
# for an implementation using distributed RAM.
set wr_clock  [get_clocks -quiet -of_objects [get_pins -quiet {mem*/WCLK}]]
set rd_period [get_property -quiet period [get_clocks -quiet -of_objects [get_pins -quiet {ReadDataReg*[*]/C}]]]
set_max_delay -quiet -from $wr_clock -to [get_pins -quiet {ReadDataReg*[*]/D}] -datapath_only $rd_period
