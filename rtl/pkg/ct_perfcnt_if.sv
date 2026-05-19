// vim: set ts=4 et:
// -*- indent-tabs-mode: t; tab-width: 4 -*-

/**
* Copyright (c) 2025 by Accemic Technologies GmbH Kiefersfelden Germany
* SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
*
* @author   Alexander Weiss <aweiss@accemic.com>
* @author	Albert Schulz <aschulz@accemic.com>
* @author	Alexander Lange <alange@accemic.com>
*
* @brief    Accemic C-Trace Performance Counter Interface
*/

interface ct_perfcnt_if
();

	import ct_pkg::*;

	// range 0..N-1: ranges
	// range N:      cnt all events outside the ranges

	logic 			 		[NUM_PERFCNT_IFETCH_TH_RANGES : 0]	ifetch_th_counter_clr_axis;
	logic 			 		[NUM_PERFCNT_IFETCH_TH_RANGES : 0]	ifetch_th_counter_clr_etip;
	ct_perfcnt_counter_t	[NUM_PERFCNT_IFETCH_TH_RANGES : 0]	ifetch_th_counter_value;

	logic 					[NUM_PERFCNT_DATA_RD_TH_RANGES : 0]	data_rd_th_counter_clr_axis;
	logic 					[NUM_PERFCNT_DATA_RD_TH_RANGES : 0]	data_rd_th_counter_clr_etip;
	ct_perfcnt_counter_t	[NUM_PERFCNT_DATA_RD_TH_RANGES : 0]	data_rd_th_counter_value;

	logic 					[NUM_PERFCNT_DATA_RD_RANGES : 0]	data_rd_counter_clr_axis;
	logic 					[NUM_PERFCNT_DATA_RD_RANGES : 0]	data_rd_counter_clr_etip;
	ct_perfcnt_counter_t	[NUM_PERFCNT_DATA_RD_RANGES : 0]	data_rd_counter_value;

	logic 					[NUM_PERFCNT_DATA_WR_RANGES : 0]	data_wr_counter_clr_axis;
	logic 					[NUM_PERFCNT_DATA_WR_RANGES : 0]	data_wr_counter_clr_etip;
	ct_perfcnt_counter_t	[NUM_PERFCNT_DATA_WR_RANGES : 0]	data_wr_counter_value;

	modport master (
		input	ifetch_th_counter_clr_axis,   data_rd_th_counter_clr_axis,   data_rd_counter_clr_axis,   data_wr_counter_clr_axis,
		input	ifetch_th_counter_clr_etip,   data_rd_th_counter_clr_etip,   data_rd_counter_clr_etip,   data_wr_counter_clr_etip,
		output  ifetch_th_counter_value, data_rd_th_counter_value, data_rd_counter_value, data_wr_counter_value
	);

	modport slave_axis (
		output	ifetch_th_counter_clr_axis,   data_rd_th_counter_clr_axis,   data_rd_counter_clr_axis,   data_wr_counter_clr_axis,
		input   ifetch_th_counter_value, data_rd_th_counter_value, data_rd_counter_value, data_wr_counter_value
	);

	modport slave_etip (
		output	ifetch_th_counter_clr_etip,   data_rd_th_counter_clr_etip,   data_rd_counter_clr_etip,   data_wr_counter_clr_etip,
		input   ifetch_th_counter_value, data_rd_th_counter_value, data_rd_counter_value, data_wr_counter_value
	);

endinterface
