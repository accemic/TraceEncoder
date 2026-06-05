# -*- indent-tabs-mode:t; tab-width:4 -*-
# vim: tabstop=4:noexpandtab

#############################################################################
# Copyright (c) 2018 by Accemic Technologies GmbH Kiefersfelden Germany
# SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
#
# @author	Thomas B. Preußer <tpreusser@accemic.com>
# @brief	Timing constraints for cross-clock FIFO fifo2clk_fwft.
#############################################################################

set periods [join [get_property period [get_clocks -of_objects [get_pins {genSync[*].Ack_reg/C}]]] ,]
set guard_pin [get_pins {rst_latch_reg/G}]
create_clock -period [expr max($periods)] $guard_pin

set_false_path -to [get_pins {rst_latch_reg/PRE}]
set_false_path -to [get_pins {genSync[*].Rst_reg[*]/PRE}]
set_false_path -to [get_pins {genSync[*].Rst_reg[0]/D}]
set_false_path -to [get_pins {genSync[*].Ack_reg/D}]
set_max_delay -from $guard_pin -to [get_pins {genSync[*].Ack_reg/CLR}] -datapath_only [expr min($periods)]
