// SPDX-FileCopyrightText: 2025 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @author   Alexander Weiss <aweiss@accemic.com>, Albert Schulz <aschulz@accemic.com>, Alexander Lange <alange@accemic.com>
 *
 * @brief    Accemic CEDARtools.TraceEncoder Preprocessor Interfaces
 */

interface ct_sync_if ();

	import nexus::*;

	nexus_sync_reason_e reason;
	logic               done;

	modport master (
		output  reason,
		input   done
	);

	modport slave (
		input   reason,
		output  done
	);

endinterface // ct_sync_if

interface ct_hit_if ();

	logic hit_valid;
	logic hit;
	logic region_entered;
	logic region_exited;

	modport master_region (
		output  hit_valid, hit, region_entered, region_exited
	);

	modport slave_region (
		input   hit_valid, hit, region_entered, region_exited
	);

	modport master (
		output  hit_valid, hit
	);

	modport slave (
		input   hit_valid, hit
	);

endinterface // ct_hit_if

`default_nettype wire
