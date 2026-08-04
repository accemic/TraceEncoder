# -*- indent-tabs-mode:t; tab-width:4 -*-
# vim: tabstop=4:noexpandtab

#############################################################################
# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
#
# Implementation constraints for the ct_encoder_top synthesis wrapper.
#
# Intentionally empty: ct_encoder_top is a pin-reduced out-of-context
# synthesis wrapper used to gauge resource usage. No timing constraints are
# required for a utilization estimate. Add create_clock / clock-domain
# constraints here if this wrapper is ever taken through implementation.
#############################################################################
