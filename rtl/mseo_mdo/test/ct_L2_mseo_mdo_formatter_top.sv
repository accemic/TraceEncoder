// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @brief Synthesis/implementation wrapper for ct_L2_mseo_mdo_formatter.
 */
module ct_L2_mseo_mdo_formatter_top #(
	parameter int unsigned NEXUS_MAX_FIELDS           = nexus_vendor::NEXUS_MAX_FIELDS,
	parameter int unsigned NEXUS_MAX_FIELD_DATA_WIDTH = nexus_vendor::NEXUS_MAX_FIELD_DATA_WIDTH,
	parameter int unsigned MDO_WIDTH                  = 30
) (
	input  uwire logic                              proc_clk,
	input  uwire logic                              proc_rst,
	input  uwire logic                              atb_atclk,
	input  uwire logic                              atb_atresetn,
	output uwire logic                              atb_atvalid,
	output uwire logic [atb_pkg::ATDATA_WIDTH-1:0]  atb_atdata,
	output uwire logic [atb_pkg::ATBYTES_WIDTH-1:0] atb_atbytes,
	output uwire logic [atb_pkg::ATID_WIDTH-1:0]    atb_atid,
	output uwire logic                              atb_afready
);
	import nexus::*;

	nexus_message_t nexus_msg = '0;
	logic [31:0]    Seed = 32'h1;
	logic           synq_req_trace_byte_count;
	logic           synq_req_trace_msg_count;
	logic           ready_out;

	ct_cs_procclk_if cs_proc();
	ct_cs_atbclk_if  cs_atb();
	atb_if atb();

	always_ff @(posedge proc_clk) begin
		if (proc_rst) begin
			nexus_msg <= '0;
			Seed      <= 32'h1;
		end else begin
			Seed <= {Seed[30:0], Seed[31] ^ Seed[21] ^ Seed[1] ^ Seed[0]};

			if (ready_out) begin
				nexus_msg.id <= Seed;
				for (int i = 0; i < NEXUS_MAX_FIELDS; i++) begin
					nexus_msg.fields[i].name <= nexus_field_name_e'(i[5:0]);
					if (i < ((Seed[$clog2(NEXUS_MAX_FIELDS)-1:0] % NEXUS_MAX_FIELDS) + 1)) begin
						nexus_msg.fields[i].field_type <= (i[0]) ? nexus::FIXED : nexus::VARIABLE;
						nexus_msg.fields[i].data_width <= (i % (NEXUS_MAX_FIELD_DATA_WIDTH - 1)) + 1;
						nexus_msg.fields[i].data <=
							{{(NEXUS_MAX_FIELD_DATA_WIDTH-32){1'b0}}, Seed} ^
							(NEXUS_MAX_FIELD_DATA_WIDTH'(i) << (i % 7));
					end else begin
						nexus_msg.fields[i].field_type <= nexus::FIELD_INVALID;
						nexus_msg.fields[i].data_width <= '0;
						nexus_msg.fields[i].data <= '0;
					end
				end
			end else begin
				nexus_msg <= '0;
			end
		end
	end

	always_ff @(posedge atb_atclk) begin
		if (!atb_atresetn) begin
			atb.atready <= 1'b1;
			atb.afvalid <= 1'b0;
			atb.syncreq <= 1'b0;
		end else begin
			// Toggle ready to keep backpressure/CDC paths active.
			atb.atready <= Seed[0];
			atb.afvalid <= 1'b0;
			atb.syncreq <= 1'b0;
		end
	end

	assign cs_atb.trAtbId = '0;

	ct_L2_mseo_mdo_formatter #(
		.NEXUS_MAX_FIELDS(NEXUS_MAX_FIELDS),
		.NEXUS_MAX_FIELD_DATA_WIDTH(NEXUS_MAX_FIELD_DATA_WIDTH),
		.MDO_WIDTH(MDO_WIDTH)
	) dut (
		.proc_clk,
		.proc_rst,
		.atb_atclk,
		.atb_atresetn,
		.nexus_msg,
		.cs_proc,
		.cs_atb,
		.atb,
		.synq_req_trace_byte_count,
		.synq_req_trace_msg_count,
		.quota_cnt_clr             (1'b0),
		.ready_out
	);

	assign atb_atvalid = atb.atvalid;
	assign atb_atdata  = atb.atdata;
	assign atb_atbytes = atb.atbytes;
	assign atb_atid    = atb.atid;
	assign atb_afready = atb.afready;

endmodule

`default_nettype wire
