# -*- indent-tabs-mode:t; tab-width:4 -*-
# vim: tabstop=4:noexpandtab

#############################################################################
# Copyright (c) 2018-2024 by Accemic Technologies GmbH Kiefersfelden Germany
# SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
#
# @author	Thomas B. Preußer <tpreusser@accemic.com>
# @brief	Timing constraints for cross-clock FIFO fifo2clk_fwft.
#############################################################################

# Cross-clock pointer transfer must only be bounded by (smaller) clock period.
#	Note:	This is a sufficient but not necessarily required constraint.
#			It would be sufficient if the arrival times of all bits in the
#			the destination clock domain just do not spread beyond the smaller
#			clock period. Thus, the max_delay may be increased arbitrarily as
#			long as a min_delay is specified within a distance of one period.
#			Use this opportunity to relax critical designs.

set wrclk_pins	[get_pins {blkWrite.WPtr*/C}]
set rdclk_pins	[get_pins {blkRead.RPtr*/C}]
set wr_period	[get_property period [get_clocks -of_objects $wrclk_pins]]
set rd_period	[get_property period [get_clocks -of_objects $rdclk_pins]]
set cross_period [expr "min($wr_period, $rd_period)"]

set_max_delay -from $wrclk_pins -to [get_pins {blkRead.WPtr*/D}]  -datapath_only $cross_period
set_max_delay -from $rdclk_pins -to [get_pins {blkWrite.RPtr*/D}] -datapath_only $cross_period

# This timing constraint is required for supporting independent clocks
# for an implementation using distributed RAM.
# The -quiet option filters the flood of warnings that would be emitted
# for other implementations.
set wrclk_pin [get_clocks -quiet -of_objects [get_pins -quiet {genMemory.Mem*/WCLK}]]
set_max_delay -quiet -from $wrclk_pin -to [get_pins -quiet {genMemory.ReadReg*/D}] -datapath_only $rd_period
