`default_nettype none

// vim: set ts=4 et:
// -*- indent-tabs-mode: t; tab-width: 4 -*-

/**
* Copyright (c) 2012-2020 by Accemic Technologies GmbH Kiefersfelden Germany
* SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
*
* @brief   Clock domain crossing for high frequency
* @detail  vector_cdc2 with request–acknowledge handshake for safe CDC
*  		   Source domain (d_clk) runs free counter d_data and transfers it to q_clk domain.
*		   Synchronous resets in both domains.
*
* @author  Alexander Weiss <aweiss@accemic.com>
*/

module vector_cdc2 #(
	parameter int unsigned DATA_WIDTH = 32,
	parameter logic [DATA_WIDTH-1:0] INIT = '0  // initial value after reset
)(
	input uwire logic 					d_clk,
	input uwire logic 					d_rst,
	input uwire logic [DATA_WIDTH-1:0]	d_data,
	input uwire logic 					q_clk,
	input uwire logic 					q_rst,
	output uwire logic [DATA_WIDTH-1:0]	q_data
);

  // Source domain (d_clk)
  logic         		 DToggle;
  logic [DATA_WIDTH-1:0] DData;
  logic 				 AckSync1, AckSync2, LastAck;
  logic 				 AckToggle;  // handshake back from q_clk domain

  always_ff @(posedge d_clk or posedge d_rst) begin
	if (d_rst) begin
	  DData      <= 8'd0;
	  DToggle    <= 1'b0;
	  AckSync1   <= 1'b0;
	  AckSync2   <= 1'b0;
	  LastAck    <= 1'b1;
	end else begin
	  // synchronize AckToggle into d_clk domain
	  AckSync1 <= AckToggle;
	  AckSync2 <= AckSync1;

	  if (AckSync2 != LastAck) begin
		// previous transfer acknowledged: launch next
		LastAck   <= AckSync2;
		DData      <= d_data;
		DToggle    <= ~DToggle;
	  end
	end
  end

  // Destination domain (q_clk)
  logic ReqSync1, ReqSync2, LastReq;
  logic [DATA_WIDTH-1:0] QData;

  always_ff @(posedge q_clk or posedge q_rst) begin
	if (q_rst) begin
	  ReqSync1  <= 1'b0;
	  ReqSync2  <= 1'b0;
	  LastReq   <= 1'b0;
	  AckToggle  <= 1'b0;
	  QData     <= 8'd0;
	end else begin
	  // synchronize DToggle into q_clk domain
	  ReqSync1 <= DToggle;
	  ReqSync2 <= ReqSync1;

	  if (ReqSync2 != LastReq) begin
		// new transfer request detected
		LastReq   <= ReqSync2;
		QData     <= DData;
		// send acknowledgement back
		AckToggle <= ~AckToggle;
	  end
	end
  end

  assign q_data = QData;

endmodule
`default_nettype wire









/*

  //-----------------------------------------------------------------------------
  // Handshake toggle in d_clk domain
  //-----------------------------------------------------------------------------
  logic         		 DToggle;
  logic [DATA_WIDTH-1:0] DData;

  always_ff @(posedge d_clk) begin
	if (d_rst) begin
	  DToggle <= 1'b0;
	  DData   <= INIT;
	end else begin
	  DData   <= d_data;
	  DToggle <= ~DToggle;  // toggle every cycle to indicate new data
	end
  end

  //-----------------------------------------------------------------------------
  // 2-stage synchronizer for the toggle into clk2 domain
  //-----------------------------------------------------------------------------
  logic QToggle1, QToggle2;

  always_ff @(posedge q_clk) begin
	if (q_rst) begin
	  QToggle1 <= 1'b0;
	  QToggle2 <= 1'b0;
	end else begin
	  QToggle1 <= DToggle;
	  QToggle2 <= QToggle1;
	end
  end

  //-----------------------------------------------------------------------------
  // Edge detection & data capture in clk2 domain
  //-----------------------------------------------------------------------------
  logic 				 LastToggle;
  logic [DATA_WIDTH-1:0] QData;

  always_ff @(posedge q_clk) begin
	if (q_rst) begin
	  LastToggle <= 1'b0;
	  QData      <= INIT;
	end else begin
	  // On toggle change, capture the latest prod_data
	  if (QToggle2 != LastToggle) begin
		QData    	<= DData;
		LastToggle 	<= QToggle2;
	  end
	  // else: no change ⇒ hold previous data_out
	end
  end

  assign q_data = QData;

endmodule


*/
