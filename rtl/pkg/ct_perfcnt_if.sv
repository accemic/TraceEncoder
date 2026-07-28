// SPDX-FileCopyrightText: 2025 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @author   Alexander Weiss <aweiss@accemic.com>, Albert Schulz <aschulz@accemic.com>, Alexander Lange <alange@accemic.com>
 *
 * @brief    Accemic CEDARtools.TraceEncoder Performance Counter Interface
 */

interface ct_perfcnt_if ();

	import ct_pkg::*;

	// range 0..N-1: ranges
	// range N:      cnt all events outside the ranges

	logic                [NUM_PERFCNT_IFETCH_TH_RANGES:0] ifetch_th_counter_clr_axis;
	logic                [NUM_PERFCNT_IFETCH_TH_RANGES:0] ifetch_th_counter_clr_etip;
	ct_perfcnt_counter_t [NUM_PERFCNT_IFETCH_TH_RANGES:0] ifetch_th_counter_value;

	logic                [NUM_PERFCNT_DATA_RD_TH_RANGES:0] data_rd_th_counter_clr_axis;
	logic                [NUM_PERFCNT_DATA_RD_TH_RANGES:0] data_rd_th_counter_clr_etip;
	ct_perfcnt_counter_t [NUM_PERFCNT_DATA_RD_TH_RANGES:0] data_rd_th_counter_value;

	logic                [NUM_PERFCNT_DATA_RD_RANGES:0] data_rd_counter_clr_axis;
	logic                [NUM_PERFCNT_DATA_RD_RANGES:0] data_rd_counter_clr_etip;
	ct_perfcnt_counter_t [NUM_PERFCNT_DATA_RD_RANGES:0] data_rd_counter_value;

	logic                [NUM_PERFCNT_DATA_WR_RANGES:0] data_wr_counter_clr_axis;
	logic                [NUM_PERFCNT_DATA_WR_RANGES:0] data_wr_counter_clr_etip;
	ct_perfcnt_counter_t [NUM_PERFCNT_DATA_WR_RANGES:0] data_wr_counter_value;

	modport master (
		input   ifetch_th_counter_clr_axis, data_rd_th_counter_clr_axis, data_rd_counter_clr_axis, data_wr_counter_clr_axis,
		input   ifetch_th_counter_clr_etip, data_rd_th_counter_clr_etip, data_rd_counter_clr_etip, data_wr_counter_clr_etip,
		output  ifetch_th_counter_value, data_rd_th_counter_value, data_rd_counter_value, data_wr_counter_value
	);

	modport slave_axis (
		output  ifetch_th_counter_clr_axis, data_rd_th_counter_clr_axis, data_rd_counter_clr_axis, data_wr_counter_clr_axis,
		input   ifetch_th_counter_value, data_rd_th_counter_value, data_rd_counter_value, data_wr_counter_value
	);

	modport slave_etip (
		output  ifetch_th_counter_clr_etip, data_rd_th_counter_clr_etip, data_rd_counter_clr_etip, data_wr_counter_clr_etip,
		input   ifetch_th_counter_value, data_rd_th_counter_value, data_rd_counter_value, data_wr_counter_value
	);

endinterface // ct_perfcnt_if

`default_nettype wire
