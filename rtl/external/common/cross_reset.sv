// SPDX-FileCopyrightText: 2018-2024 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-

/**
 * @author  Thomas B. Preußer <tpreusser@accemic.com>
 * @brief   Reset generator delivering safe synchronized resets for multiple
 *          clock domains.
 *
 *      hold'[N-1]  <= hold[N-1]
 *      hold'[i]    <= hold[i] || rst[i+1]
 *
 *            (LDPE)
 *            +-----+
 *   rst0 ----+S    |                                   |\
 *            |    Q+-------+----------------+----------| o------+
 *            |     |       |                |          |/       |
 *         +--+R    |       |                |                   |
 *         |  +-----+       |     (FDPE)     |  (FDPE)           |
 *         |                |    +------+    | +------+          |
 *         |                +----+S     |    +-+S     |          |
 *         |                     |     Q+-+    |     Q+-+---------------------- rst[i]
 *         +---------+  hold[i] -+1D    | +----+1D    | |        |
 *                   |           |      | |    |      | |        |
 *            +--+   |         +-+>C1   | |  +-+>C1   | |        |
 *          . |   \  |         | +------+ |  | +------+ |        |  (FDCE)
 *          . |  & | |         |          |  |          |        | +------+
 *          . |    +-+         |          |  |          | +--\   +-+R     | rst_ack[i]
 *            |    |           |          |  |          +-+ & \    |     Q+-+
 *          +-+   /            |          |  |            |    +---+1D    | |
 *          | +--+             |          +---------------+   /    |      | |
 *          |                  |             |            +--/   +-+>C1   | |
 *          |                  |             |                   | +------+ |
 *          |                  |             |                   |          |
 * clk[i] ---------------------+-------------+-------------------+          |
 *          |                                                               |
 *          +---------------------------------------------------------------+
 */

module cross_reset #(
	int unsigned      N,                      // number of clock domains
	logic             RELEASE_LEFT2RIGHT = 0, // ordered release of resets from left to right
	logic[N-1:0][7:0] BUFFERS            = 0  // string of '-' OR 'G', 'H', 'R' to request reset on BUFx
)(
	input   logic         rst0,  // Input Reset (simply OR multiple sources)
	input   logic [N-1:0] clk,
	input   logic [N-1:0] hold,
	output  logic [N-1:0] rst_u, // synchronized reset before optional buffer insertion
	output  logic [N-1:0] rst
);

	// Reset Latch
	//  - holds input reset until copied to all synchronized outputs
	logic           rst_latch   = 0;
	uwire [N-1:0]   rst_ack;
	uwire           rst_done    = &rst_ack;
	always @(rst0 or rst_done) begin
		if(rst0)            rst_latch <= 1;
		else if(rst_done)   rst_latch <= 0;
	end

	// Latch Output Synchronized into all Clock Domains
	for(genvar  i = 0; i < N; i++) begin : genSync
		uwire  c = clk[i];

		(* ASYNC_REG = "true", SHIFT_EXTRACT = "no" *) logic [1:0]  Rst = 0;
		uwire  hld = RELEASE_LEFT2RIGHT? (i < N-1? rst[i+1] : 1'b0) : hold[i];
		always_ff @(posedge rst_latch or posedge c) begin
			if(rst_latch)   Rst <= '1;
			else            Rst <= { Rst[0], hld };
		end
		assign  rst_u[i] = Rst[1];

		// Insert Reset Buffer as Requested
		case(BUFFERS[i])
		//"G"
		8'h47:  BUFG rst_buf(.O(rst[i]), .I(Rst[1]));
		//"H"
		8'h48:  BUFH rst_buf(.O(rst[i]), .I(Rst[1]));
		//"R"
		8'h52:  BUFR rst_buf(.O(rst[i]), .I(Rst[1]));
		//"-"
		8'h2D,
		0:  assign  rst[i] = Rst[1];
		default: begin
			initial begin
				$error("%m: Unknown buffer[%0d] type '%s'", i, BUFFERS[i]);
				$finish;
			end
		end
		endcase

		logic  Ack = 0;
		always_ff @(negedge rst_latch or posedge c) begin
			if(!rst_latch)  Ack <= 0;
			else            Ack <= rst[i] && Rst[0];
		end
		assign  rst_ack[i] = Ack;
	end : genSync

endmodule : cross_reset
