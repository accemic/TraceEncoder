// SPDX-FileCopyrightText: 2025 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @author   Alexander Weiss <aweiss@accemic.com>, Albert Schulz <aschulz@accemic.com>, Alexander Lange <alange@accemic.com>
 *
 * @brief  Dump TIP signals
 * @details
 *   File gets written after flush
 *   Dump modes:
 *   - RAW
 *   - PCINFO:   address,type,<dest>
 *   - PLAIN:    address specific count for taken, not taken and indirect branches
 */

module tip_dump #(
	string FILEPATH_TIP_PLN_TRACE_IP = "",
	string FILEPATH_TIP_DUMP_RAW     = "",
	string FILEPATH_TIP_DUMP_DETAILS = "",
	int    DUMP_COUNT_MAX            = 500, // Number of instructions to observe, linear address space required, starting from CODE_START
	int    CODE_START                = 0
) (
	input uwire logic clk,
	input uwire logic rst,
	// tip input
	tip_if.slave      tip
);

	import nexus_vendor::*;
	import nexus::*;
	import tip_pkg::*;
	import ct_etip_pkg::*;
	import file_pkg::*;

	int                                         fd_dump_plain       = 0;    // file handle for plain dump
	int                                         fd_dump_raw         = 0;    // file handle for raw dump
	int                                         fd_dump_details     = 0;    // file handle for detail dump

	int                                         dump_plain_entries  = 0;
	int                                         dump_raw_bytes      = 0;
	int                                         dump_detail_entries = 0;

	int                                         dump_count = 0;
	logic                                       files_opened = 1'b0;
	logic                                       dump_reported = 1'b0;

	tip_pcinfo_itype_e                          pcinfo_itype;       // NexRV instruction type
	tip_t                                       PrevTip;            // prev TIP Message
	logic                                       PrevTipValid;
	logic                                       is_jump;
	logic                                       is_first_tip;

	tip_instr_t[DUMP_COUNT_MAX-1:0]             instr;              // array of all instructions with place holder for branch / jump target_address (for branches & jumps)

	tip_t                                       tip_to_raw;         // TIP Message content -> raw file
	typedef logic [(($bits(tip_to_raw)/8)*8) : 0]   tip_to_raw_bits_t;  // reserve enough bytes for tip_msg_struct_t
	tip_to_raw_bits_t                               tip_to_raw_bits;

	task automatic open_dump_files();
		if (!files_opened) begin
			if ((FILEPATH_TIP_PLN_TRACE_IP != "") && (fd_dump_plain == 0)) begin
				file_open(FILEPATH_TIP_PLN_TRACE_IP, "w", fd_dump_plain);
			end
			if ((FILEPATH_TIP_DUMP_RAW != "") && (fd_dump_raw == 0)) begin
				file_open(FILEPATH_TIP_DUMP_RAW, "wb", fd_dump_raw);
			end
			if ((FILEPATH_TIP_DUMP_DETAILS != "") && (fd_dump_details == 0)) begin
				file_open(FILEPATH_TIP_DUMP_DETAILS, "w", fd_dump_details);
			end
			files_opened = (fd_dump_plain != 0) || (fd_dump_raw != 0) || (fd_dump_details != 0);
		end
	endtask

	task automatic close_dump_files();
		if (fd_dump_plain != 0) begin
			for (int i = 0; i < dump_count; i++) begin
				if (instr[i].i != 0) begin
					$fwrite(fd_dump_plain, "I\t%d\t0x%h\n", instr[i].i, instr[i].addr);
					dump_plain_entries++;
				end
				if (instr[i].e != 0) begin
					$fwrite(fd_dump_plain, "E\t%d\t0x%h\n", instr[i].e, instr[i].addr);
					dump_plain_entries++;
				end
				if (instr[i].n != 0) begin
					$fwrite(fd_dump_plain, "N\t%d\t0x%h\n", instr[i].n, instr[i].addr);
					dump_plain_entries++;
				end
			end
			$fclose(fd_dump_plain);
			fd_dump_plain = 0;
		end
		if (fd_dump_raw != 0) begin
			dump_raw_bytes = $ftell(fd_dump_raw);
			$fclose(fd_dump_raw);
			fd_dump_raw = 0;
		end
		if (fd_dump_details != 0) begin
			$fclose(fd_dump_details);
			fd_dump_details = 0;
		end
		files_opened = 1'b0;

		if (!dump_reported) begin
			if (FILEPATH_TIP_PLN_TRACE_IP != "") begin
				$display("*** INFO (%m, line %0d) tip_dump_plain saved to %s (%0d entries)", `__LINE__, FILEPATH_TIP_PLN_TRACE_IP, dump_plain_entries);
			end
			if (FILEPATH_TIP_DUMP_RAW != "") begin
				$display("*** INFO (%m, line %0d) tip_dump_raw saved to %s (%0d bytes)", `__LINE__, FILEPATH_TIP_DUMP_RAW, dump_raw_bytes);
			end
			if (FILEPATH_TIP_DUMP_DETAILS != "") begin
				$display("*** INFO (%m, line %0d) tip_dump_details saved to %s (%0d entries)", `__LINE__, FILEPATH_TIP_DUMP_DETAILS, dump_detail_entries);
			end
		end
		dump_reported = 1'b1;
	endtask

	initial begin

	PrevTipValid = 0;
	is_first_tip  = '1;

	// initialize plain statistics
	for (int i = 0; i < DUMP_COUNT_MAX; i++) begin
		instr[i]                = 'x;
		instr[i].addr           = CODE_START + 4*i;
		instr[i].i              = 0;
		instr[i].e              = 0;
		instr[i].n              = 0;
	end

	forever begin
		@(posedge clk iff !rst);
		open_dump_files();
		if (TipCFMsgIsValid(tip.iretire, tip.itype)) begin
			dump_count++;
		end
		if (fd_dump_details != 0) begin
			// buffer current tip as PrevTipMsg
			if (TipCFMsgIsValid(tip.iretire, tip.itype)) begin
				if (PrevTipValid) begin
					pcinfo_itype = GetPCInfoType(PrevTip.itype);
					is_jump =      (PrevTip.itype == EXCEPTION_TRAP)
								|| (PrevTip.itype == INTERRUPT)
								|| (PrevTip.itype == EXCEPTION_IR)
								|| (PrevTip.itype == TAKEN_BRANCH)
								|| (PrevTip.itype == UNINFERABLE_JUMP)
								|| (PrevTip.itype == UNINFERABLE_CALL)
								|| (PrevTip.itype == INFERRABLE_CALL)
								|| (PrevTip.itype == UNINFERABLE_TAIL_CALL)
								|| (PrevTip.itype == INFERRABLE_TAIL_CALL)
								|| (PrevTip.itype == RETURN)
								|| (PrevTip.itype == OTHER_UNINFERABLE_JUMP)
								|| (PrevTip.itype == OTHER_INFERABLE_JUMP);

					$fwrite(fd_dump_details, "0x%08X", PrevTip.iaddr);                      // always dump current instruction address
					$fwrite(fd_dump_details, ",%s%0d", pcinfo_itype.name(), 1 << (PrevTip.ilastsize+1));    // dump PCInfo type
					if (is_jump) begin                                                          // dump destination address
						$fwrite(fd_dump_details, ",0x%08H", tip.iaddr);
					end
					if (is_jump) begin                                                          // dump TIP instruction type
						$fwrite(fd_dump_details, ",(%s)", PrevTip.itype.name());
					end
					if (PrevTip.dretire) begin                                                  // dump TIP data access
						$fwrite(fd_dump_details, ",%s 0x%08H @addr: 0x%08H", PrevTip.dtype.name(), PrevTip.data, PrevTip.daddr);
					end
					$fwrite(fd_dump_details, "\n");
					dump_detail_entries++;
				end
				PrevTip.itype       = tip.itype;
				PrevTip.ecause      = tip.ecause;
				PrevTip.tval        = tip.tval;
				PrevTip.priv        = tip.priv;
				PrevTip.iaddr       = tip.iaddr;
				PrevTip._context    = tip._context;
				PrevTip.ctype       = tip.ctype;
				PrevTip.iretire     = tip.iretire;
				PrevTip.ilastsize   = tip.ilastsize;
				PrevTip.impdef      = tip.impdef;
				PrevTip.dretire     = tip.dretire;
				PrevTip.dtype       = tip.dtype;
				PrevTip.daddr       = tip.daddr;
				PrevTip.dsize       = tip.dsize;
				PrevTip.data        = tip.data;
				PrevTipValid        = 1;
			end
		end
		if (fd_dump_raw != 0) begin
			tip_to_raw.itype        = tip.itype;
			tip_to_raw.ecause       = tip.ecause;
			tip_to_raw.tval         = tip.tval;
			tip_to_raw.priv         = tip.priv;
			tip_to_raw.iaddr        = tip.iaddr;
			tip_to_raw._context     = tip._context;
			tip_to_raw.ctype        = tip.ctype;
			tip_to_raw.iretire      = tip.iretire;
			tip_to_raw.ilastsize    = tip.ilastsize;
			tip_to_raw.impdef       = tip.impdef;
			tip_to_raw.dretire      = tip.dretire;
			tip_to_raw.dtype        = tip.dtype;
			tip_to_raw.daddr        = tip.daddr;
			tip_to_raw.dsize        = tip.dsize;
			tip_to_raw.data         = tip.data;
//          tip_to_raw.sys_clk      = tip.sys_clk;
//          tip_to_raw.ext_clk      = tip.ext_clk;
			tip_to_raw_bits = tip_to_raw_bits_t'(tip_to_raw);

			for (int i = 0; i < ($bits(tip_to_raw)/8); i++) begin
				$fwrite(fd_dump_raw, "%c", tip_to_raw_bits[i*8 +:8]);
			end
		end
		if (FILEPATH_TIP_PLN_TRACE_IP != "") begin
			if (TipCFMsgIsValid(tip.iretire, tip.itype)) begin
				if (PrevTipValid) begin
					// update plain statistics
					automatic logic jump_out_addr_in_range;
					automatic logic jump_in_addr_in_range;
					automatic int jump_out_id;
					automatic int jump_in_id;

					jump_out_id             =  (PrevTip.iaddr - CODE_START) / 4;
					jump_out_addr_in_range  =  jump_out_id < DUMP_COUNT_MAX;

					jump_in_id              =  (tip.iaddr     - CODE_START) / 4;
					jump_in_addr_in_range   =  jump_in_id < DUMP_COUNT_MAX;

					if (is_first_tip) begin
						instr[(PrevTip.iaddr - CODE_START) / 4].i  =  1;
						is_first_tip = '0;
					end

					case (PrevTip.itype)
					TAKEN_BRANCH, INFERRABLE_CALL, INFERRABLE_TAIL_CALL, OTHER_INFERABLE_JUMP: begin
						if (jump_out_addr_in_range) begin
							instr[jump_out_id].e    =  instr[jump_out_id].e + 1;
						end
					end
					NOT_TAKEN_BRANCH: begin
						if (jump_out_addr_in_range) begin
							instr[jump_out_id].n    =  instr[jump_out_id].n + 1;
						end
					end
					EXCEPTION_TRAP, INTERRUPT, EXCEPTION_IR, UNINFERABLE_JUMP, UNINFERABLE_CALL, UNINFERABLE_TAIL_CALL, OTHER_UNINFERABLE_JUMP: begin
						if (jump_out_addr_in_range) begin
							instr[jump_out_id].i    =  instr[jump_out_id].i - 1;
						end
						if (jump_in_addr_in_range) begin
							instr[jump_in_id].i     =  instr[jump_in_id].i + 1;
						end
					end
					endcase
				end
				PrevTip.itype       = tip.itype;
				PrevTip.iaddr       = tip.iaddr;
				PrevTipValid        = 1;
			end
		end
		if (dump_count >= DUMP_COUNT_MAX) begin
			close_dump_files();
			break;  // break the forever loop
		end
	end
end

	final begin
		close_dump_files();
	end

endmodule // tip_dump
`default_nettype wire
