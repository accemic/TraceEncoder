// SPDX-FileCopyrightText: 2018 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-

/**
 */

/**
 * @brief   Provide easy-access-functions to Wishbone Bus
 * @author  Albert Schulz <aschulz@accemic.com>
 * @author  Thomas B. Preußer <tpreusser@accemic.com>
 * @author  Alexander Weiss <aweiss@accemic.com>
 */
module wb_helper #(
	int unsigned WB_DATA_WIDTH,
	int unsigned WB_ADDR_WIDTH,
	bit          DISPLAY_DEBUG_INFO         = '0,

	/// Ignore writing invalid data ('x) to Wishbone. Default to false.
	bit          PREVENT_ZERO_ENTRY_WRITING = '0,

	/// Finishes simulation, if any wishbone transaction is responded with an error
	bit          FINISH_SIMULATION_ON_ERROR = '0
)(
	input uwire logic clk,
	wb_if.master      wb,

	/// Indicates that an error occurred during any wishbone transaction
	output logic      error
);
	initial begin
		error = 0;
		clear();
		if(FINISH_SIMULATION_ON_ERROR) begin
			forever @(posedge error)    $stop;
		end
	end

	task display(string debug_info);
		if(DISPLAY_DEBUG_INFO || wb.err) $display(debug_info);
	endtask

	task clear;
		wb.addr     <= 'x;
		wb.data_m2s <= 'x;
		wb.cyc      <= '0;
		wb.stb      <= '0;
		wb.we       <= '0;
		wb.sel      <= '0;
	endtask

	task write_delayed (input int unsigned delay, input logic [WB_ADDR_WIDTH-1:0] addr, input logic [WB_DATA_WIDTH-1:0] data);
		if (!(PREVENT_ZERO_ENTRY_WRITING && data === 'x)) begin
			repeat(delay) @(posedge clk);

			wb.addr     <= addr;
			wb.data_m2s <= data;
			wb.cyc      <= '1;
			wb.stb      <= '1;
			wb.we       <= '1;
			wb.sel      <= '1;

			/// Sampling terminating signals at every rising edge
			/// @ref Wishbone Spec B4 3.1.3.1
			@(posedge clk iff wb.ack||wb.err);
			display($sformatf("WB write 0x%8h to 0x%8h %s", data, addr, wb.err? "FAILED" : ""));
			if(wb.err)
				 error <= 1;
			clear();
			@(posedge clk);//signal end of cycle
		end
	endtask

	task write (input logic [WB_ADDR_WIDTH-1:0] addr, input logic [WB_DATA_WIDTH-1:0] data);
		write_delayed(0, addr, data);
	endtask

	//------------------------------------------------------------------
	// Wishbone read cycle
	//------------------------------------------------------------------

	task read_delayed(
		input integer                       delay,
		input logic     [WB_ADDR_WIDTH-1:0] addr,
		output logic    [WB_DATA_WIDTH-1:0] data
	);
		repeat(delay) @(posedge clk);
		wb.addr     <= addr;
		wb.data_m2s <= 'x;
		wb.cyc      <= '1;
		wb.stb      <= '1;
		wb.we       <= '0;
		wb.sel      <= '1;

		/// Sampling terminating signals at every rising edge
		/// @ref Wishbone Spec B4 3.1.3.1
		@(posedge clk iff wb.ack||wb.err);
		data = wb.data_s2m;
		display($sformatf("WB read 0x%8h from 0x%8h %s", data, addr, wb.err? "FAILED" : ""));
		if(wb.err)  error <= 1;
		clear();
		@(posedge clk);//signal end of cycle
	endtask

	task read(input logic [WB_ADDR_WIDTH-1:0] addr, output logic [WB_DATA_WIDTH-1:0] data);
		read_delayed(0, addr, data);
	endtask

	/**
	 * Writes a configuration specified within a file to the mastered
	 * Wishbone bus. Each line of the config file that starts with
	 * a record class character followed by a hexadecimal number will
	 * continue the configuration process:
	 *
	 *  @ hhhh      # addr := <>            - updates the current address
	 *
	 *  : hhhh      # data := <>            - updates the current data value,
	 *              # write(addr, data)     - writes this value to the current address, and
	 *              # addr++                - increments the current address
	 *  = hhhh      # data := <>            - updates the current data value,
	 *              # read(addr) == data?   - checks the value read from the current address for equality
	 *              # addr++                - increments the current address
	 *   C hhhh     # data := data & <>     - clear all bits which are "0" (RMW)
	 *              # addr++                - increments the current address
	 *   S hhhh     # data := data | <>     - Set all bits which are "1" (RMW)
	 *              # addr++                - increments the current address
	 *  * hhhh      # repeat(<>) ...        - repeats the last operation for this many subsequent addresses
	 *  W tttt      # wait tttt ns
	 *
	 * Configuration records may be followed by arbitrary comments.
	 * The recommended style for comments is to use hash symbols ('#').
	 * Empty lines and lines starting with '#' are guaranteed to be ignored silently.
	 */
	task run_config(input string config_file);

		automatic int fd = $fopen(config_file, "r");
		if(fd == 0) $error("Could not open '%s'.", config_file);
		else begin
			automatic bit [WB_ADDR_WIDTH-1:0]   addr = 0;
			automatic bit [WB_DATA_WIDTH-1:0]   data = 0;
			automatic bit [WB_DATA_WIDTH-1:0]   rd_data = 0;
			automatic enum { NOP, WR, RD, CLR, SET }    op   = NOP;
			automatic string l;

			while($fgets(l, fd)) begin
				automatic byte                                              cls;
				automatic bit [math::max(WB_ADDR_WIDTH, WB_DATA_WIDTH)-1:0] val;

				if($sscanf(l, "%c %x", cls, val) == 2) begin
					automatic int unsigned  rep = 0;
					unique case(cls)
					"#": /* Silent Comment          */ begin end
					"@": /* Address Update          */ begin addr   = val; end
					":": /* Data Update & Write     */ begin data   = val; op = WR; rep = 1; end
					"=": /* Data Validation         */ begin data   = val; op = RD; rep = 1; end
					"C": /* Clear bits (RMW)        */ begin data   = val; op = CLR; rep = 1; end
					"S": /* Set bits (RMW)          */ begin data   = val; op = SET; rep = 1; end
					"*": /* Consecutive Repetition  */ begin rep    = val; end
					"W": /* Wait for the specified time (in hex) */  begin #val; end
					default:    $error("Ignoring unknown record class '%c'.", cls);
					endcase
					if(rep > 0) unique case(op)
					NOP: begin end
					WR:  begin repeat(rep) write(addr++, data); data = 'x; end
					RD:  begin repeat(rep) read(addr, val); assert(data === val) else $error("Reference Violation: @0x%0x %s", addr, l); addr++; data = 'x; end
					CLR: begin repeat(rep) read(addr, rd_data); write(addr++, rd_data & data); data = 'x; end
					SET: begin repeat(rep) read(addr, rd_data); write(addr++, rd_data | data); data = 'x; end
					endcase
				end
			end
			$fclose(fd);
		end
	endtask : run_config

	//------------------------------------------------------------------
	// Wishbone compare cycle (read data from addr and compare with expected data)
	//------------------------------------------------------------------

	task wb_cmp;
		input integer                       delay;
		input logic [WB_ADDR_WIDTH -1:0]    addr;
		input logic [WB_DATA_WIDTH-1:0]     data_expected;

		logic [WB_DATA_WIDTH-1:0]           data_read;

		begin
			read_delayed (delay, addr, data_read);
			if (data_read !== data_expected) begin
				display($sformatf("Data compare error. Received %h, expected %h at time %t", data_read, data_expected, $time));
			end
		end
	endtask

endmodule : wb_helper
