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
* @brief    Accemic C-Trace Preprocessor Interfaces
*/

interface ct_sync_if ();

	import nexus::*;

	nexus_sync_reason_e	reason;
	logic 				done;

	modport master (
		output	reason,
		input   done
	);

	modport slave (
		input	reason,
		output  done
	);
endinterface

interface ct_hit_if ();

	logic       hit_valid;
	logic       hit;
	logic       region_entered;
	logic       region_exited;

	modport master_region (
		output	hit_valid, hit, region_entered, region_exited
	);

	modport slave_region (
		input	hit_valid, hit, region_entered, region_exited
	);

	modport master (
		output	hit_valid, hit
	);

	modport slave (
		input	hit_valid, hit
	);
endinterface
