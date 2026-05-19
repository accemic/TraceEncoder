# -*- indent-tabs-mode:t; tab-width:4 -*-
# vim: tabstop=4:noexpandtab

#############################################################################
# Copyright (c) 2018 by Accemic Technologies GmbH Kiefersfelden Germany
# SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
#
# This source code is provided by Accemic Technologies GmbH ("Accemic")
# for evaluation purposes only and is distributed on an "as-is" basis
# without warranties of any kind, either express or implied, including
# but not limited to fitness for a particular purpose. Accemic retains
# all intellectual property rights in this code.
# This code is provided for non-commercial, educational, or internal
# research purposes only. Any other use, including incorporation into
# a commercial product, reproduction, distribution, or modification,
# is strictly prohibited without prior written consent and an explicit
# licensing agreement with Accemic.
# By using this code, you acknowledge that any use beyond the limited
# rights granted here will require a licensing agreement. Accemic will
# not be liable for any damages arising from the use or misuse of this
# code.
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
