// SPDX-FileCopyrightText: 2021 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-

/**
 */
package wishbone;
	//@brief Get mask for wishbone hub from address and size. Map mask to wishbone 32 range.
	function logic [29:0] wb32_getmask32(logic [31:0] addr, logic [31:0] size);
		if($clog2(size) == $clog2(size+1)) begin
			$error("Address window size of 0x%0x is not a power of two.", size);
			$finish;
		end
		if(addr & (size-1)) begin
			$error("Base address of 0x%0x is not aligned for a size of 0x%0x.", addr, size);
			$finish;
		end
		return (addr | ((size-1) & 'x)) >> 2;
	endfunction : wb32_getmask32

	//@brief Get mask for wishbone hub from address and size. Map mask to wishbone 32 range.
	function logic [61:0] wb32_getmask64(logic [63:0] addr, logic [63:0] size);
		//Patch for int bug in clog2
		automatic logic [31:0]  s = size[63:32] | size[31:0];
		if((size[63:32] && size[31:0]) || ($clog2(s) == $clog2(s+1))) begin
			$error("Address window size of 0x%0x is not a power of two.", size);
			$finish;
		end
		if(addr & (size-1)) begin
			$error("Base address of 0x%0x is not aligned for a size of 0x%0x.", addr, size);
			$finish;
		end
		return (addr | ((size-1) & 'x)) >> 2;
	endfunction : wb32_getmask64

	/*
	 * @brief   Convert size into mask. Useful for wb_hub
	 * @details e.g.
	 *                'h1000 -> 'h0xxx
	 */
	function logic [63:0] size2mask(logic [63:0] size);
		if($clog2(size) == $clog2(size+1)) begin
			$error("Address window size of 0x%0x is not a power of two.", size);
			$finish;
		end
		return (size-1) & 'x;
	endfunction : size2mask

	/*
	 * @brief   Get width of an address mask
	 */
	function logic [31:0] mask2width(logic [63:0] mask);
		mask2width=0;
		for(int i=0;i<63;i++)begin
			if(mask[i]===1)
			mask2width=i+1;

		end
	endfunction : mask2width

	/*
	 * @brief   Get part width of for wb_width_converter
	 */
	function int unsigned getpartwidth(int unsigned WIDE_DATA_WIDTH,int unsigned PART_COUNT);
		getpartwidth= 1 + (WIDE_DATA_WIDTH-1)/PART_COUNT;
	endfunction

endpackage : wishbone

//--------------------------------------------------------------------------------
// Wishbone interface
//--------------------------------------------------------------------------------
interface wb_if #(
	// Defaults added locally so ct_encoder can be elaborated as an OOC
	// synthesis top (interface ports flatten to ports). They match the
	// env's WB_DATA_WIDTH/WB_ADDR_WIDTH; every real instantiation overrides
	// them explicitly, so simulation is unaffected. Synth-support only.
	int DATA_WIDTH = 32,
	int ADDR_WIDTH = 32,
	int NUM_SEL    = DATA_WIDTH / 8
);

	logic   [DATA_WIDTH-1:0]    data_m2s;
	logic   [DATA_WIDTH-1:0]    data_s2m;
	logic   [ADDR_WIDTH-1:0]    addr;
	logic                       cyc;
	logic   [NUM_SEL-1:0]       sel;
	logic   stb;
	logic   we;
	logic   ack;
	logic   err;

	task clear_master;
		addr     <= 'x;
		data_m2s <= 'x;
		cyc      <= '0;
		stb      <= '0;
		we       <= '0;
		sel      <= '0;
	endtask

	task clear_slave;
		ack      <= '0;
		err      <= '0;
		data_s2m <= 'x;
	endtask

	task write;
		input logic [ADDR_WIDTH-1:0] addr_in;
		input logic [DATA_WIDTH-1:0] data_in;

		begin
			addr     <= addr_in;
			data_m2s <= data_in;
			cyc      <= '1;
			stb      <= '1;
			we       <= '1;
			sel      <= '1;
		end
	endtask

	task read;
		input logic [ADDR_WIDTH -1:0] addr_in;

		begin
			addr <= addr_in;
			cyc  <= '1;
			stb  <= '1;
			we   <= '0;
			sel  <= '1;
		end
	endtask

	function logic pending_wb_request();
		return cyc && stb && !ack && !err;
	endfunction

	modport master (
		output      data_m2s, addr, cyc, sel, stb, we,
		input       data_s2m, ack, err,
		import      clear_master, write, read);

	modport slave (
		input       data_m2s, addr, cyc, sel, stb, we,
		output      data_s2m, ack, err,
		import      clear_slave, pending_wb_request);

	initial clear_master();

endinterface : wb_if
