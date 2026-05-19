// vim: set ts=4 et:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none
/**
* Copyright (c) 2026 Accemic Technologies GmbH
* SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
*
* @brief    Scripted RISC-V CPU model that drives the TIP interface.
*
* @details
*   Testbenches call this module's tasks to "execute" a program. Each
*   task drives the encoder-facing TIP signals with the right itype /
*   iaddr / daddr / ... AND logs a high-level event into `event_q`
*   that the scoreboard cross-checks against the encoder's decoded
*   output.
*
*   Time advances implicitly: every retired instruction takes
*   `CYCLES_PER_INSTR` tip_clk cycles. The knob lets tests stress
*   timestamp behaviour by spreading retirements out.
*
*   Conventions per the RISC-V Trace Spec ingress port
*   (https://github.com/riscv-non-isa/riscv-trace-spec/blob/main/ingressPort.adoc):
*
*     - SR (single-retirement) mode: `iretire` is a 1-bit strobe (high
*       for exactly one tip_clk cycle per retired instruction). Set by
*       `tip_pkg::TIP_IRETIRE_WIDTH == 1`.
*     - `ilastsize` carries log2 of the instruction size in halfwords:
*         0 => 1 halfword (16-bit, RVC)
*         1 => 2 halfwords (32-bit, the default in this model)
*     - `iaddr` is always the SOURCE PC of the retired instruction
*       (the branch / call / return / jump itself, not the target).
*     - For `INTERRUPT` and `EXCEPTION_TRAP` itypes the Accemic
*       encoder treats the trap notification itself as a retirement
*       (iretire=1, iaddr = PC of the trapping instruction). `cause`
*       is the 4-bit lower portion of mcause/scause (the high "is
*       interrupt" bit is conveyed by itype, not ecause).
*     - `tval` is only meaningful for `EXCEPTION_TRAP`; carries
*       mtval/stval (faulting address etc.). Zero everywhere else.
*     - When `iretire == 0` all other TIP signals are "don't care" per
*       spec. This model holds them at their last-driven value.
*
*   API surface:
*     enter / exit_trace                   lifecycle
*     run                                  straight-line execution
*     jump_to / uninferable_jump           direct / indirect jumps
*     branch_taken / branch_not_taken      conditional branches
*     call_to / ret                        function call / return
*     interrupt / exception_trap / mret    traps
*     load_data / store_data               data accesses
*     csr_write                            HSI events (CSR side-effects)
*     set_priv / set_context               priv-level / context tracking
*     idle                                 pass time without retiring
*
*   See tests/lib/README.md and tests/instruction/01_basic/ for usage.
*/

module cpu_model #(
	// tip_clk cycles per retired instruction. Larger = more time between
	// retirements = more timestamp messages.
	parameter int CYCLES_PER_INSTR = 4,
	// Default size of a retired instruction, in log2(halfwords) per spec.
	// 1 = 32-bit (RV32I), 0 = 16-bit (RVC). Tests can override per-task.
	parameter int DEFAULT_ILASTSIZE = 1,
	// Optional path for a NexRv PCInfo file derived from the scripted
	// scenario. Format (one line per retired instruction):
	//   0x<src_pc>,<type><length_bytes>[,0x<target_pc>]
	// Type codes (NexRv): L=Linear, BD=Branch Direct, JD=Jump Direct,
	// JI=Jump Indirect, CD=Call Direct, CI=Call Indirect, R=Return,
	// E=Exception, XX=Unknown. Written on simulation end. Empty = no file.
	parameter string NEXRV_INFO_PATH = ""
) (
	input  uwire logic clk,    // tip_clk
	input  uwire logic rst,    // tip_rst (active high)
	tip_if.master      tip
);

	import tip_pkg::*;
	import cpu_model_pkg::*;

	// ------------------------------------------------------------------
	// Output regs (continuously assigned to the TIP interface)
	// ------------------------------------------------------------------
	tip_iretire_t   r_iretire   = 0;
	tip_itype_e     r_itype     = OTHER;
	tip_ecause_e    r_ecause    = tip_ecause_e'(0);
	tip_iaddr_t     r_tval      = 0;
	tip_priv_t      r_priv      = 3;    // M-mode by default
	tip_iaddr_t     r_iaddr     = TIP_DEFAULT_IADDR;
	tip_context_t   r_context   = 0;
	tip_time_t      r_time      = 0;
	tip_ctype_t     r_ctype     = 0;
	// ilastsize: log2(halfwords). 1 = 32-bit, 0 = RVC (16-bit). Per
	// RISC-V trace-spec ingressPort.adoc the encoder treats the
	// instruction size as 2^ilastsize halfwords.
	tip_ilastsize_t r_ilastsize = tip_ilastsize_t'(DEFAULT_ILASTSIZE);
	tip_impdef_t    r_impdef    = 0;

	tip_dretire_t   r_dretire   = 0;
	tip_dtype_e     r_dtype     = LOAD;
	tip_daddr_t     r_daddr     = TIP_DEFAULT_DADDR;
	tip_dsize_t     r_dsize     = 2;    // word
	tip_data_t      r_data      = TIP_DEFAULT_DATA;
	logic [TIP_SDATA_WIDTH-1:0] r_sdata = 0;
	logic [TIP_LRESP_WIDTH-1:0] r_lresp = 0;
	logic [TIP_LDATA_WIDTH-1:0] r_ldata = 0;

	assign tip.iretire   = r_iretire;
	assign tip.itype     = r_itype;
	assign tip.ecause    = r_ecause;
	assign tip.tval      = r_tval;
	assign tip.priv      = r_priv;
	assign tip.iaddr     = r_iaddr;
	assign tip._context  = r_context;
	assign tip._time     = r_time;
	assign tip.ctype     = r_ctype;
	assign tip.ilastsize = r_ilastsize;
	assign tip.impdef    = r_impdef;
	assign tip.dretire   = r_dretire;
	assign tip.dtype     = r_dtype;
	assign tip.daddr     = r_daddr;
	assign tip.dsize     = r_dsize;
	assign tip.data      = r_data;
	assign tip.sdata     = r_sdata;
	assign tip.lresp     = r_lresp;
	assign tip.ldata     = r_ldata;

	// Free-running time counter (TIP time signal)
	always_ff @(posedge clk) begin
		if (rst) r_time <= 0;
		else     r_time <= r_time + 1;
	end

	// Defensive reset of retirement strobes
	always_ff @(posedge clk) begin
		if (rst) begin
			r_iretire <= 0;
			r_dretire <= 0;
		end
	end

	// ------------------------------------------------------------------
	// Internal program / event state
	// ------------------------------------------------------------------
	tip_iaddr_t cur_pc        = 0;
	tip_iaddr_t call_stack[$];     // inferable-call return addresses
	tip_iaddr_t trap_stack[$];     // mepc-style trap return addresses
	logic       enabled       = 0;

	cpu_event_t event_q[$];

	function automatic int event_count();
		return event_q.size();
	endfunction

	function automatic cpu_event_t pop_event();
		cpu_event_t e = event_q[0];
		event_q.delete(0);
		return e;
	endfunction

	function automatic cpu_event_t peek_event(int idx = 0);
		return event_q[idx];
	endfunction

	function automatic void log_event(
		cpu_event_kind_e kind,
		tip_iaddr_t      pc,
		tip_iaddr_t      target  = '0,
		longint unsigned payload = 0,
		int unsigned     size    = 0
	);
		cpu_event_t e;
		e.kind    = kind;
		e.pc      = pc;
		e.target  = target;
		e.payload = payload;
		e.size    = size;
		event_q.push_back(e);
	endfunction

	// ------------------------------------------------------------------
	// Low-level pulse helper: drive one retired instruction for one
	// clock cycle, pad with idle cycles up to CYCLES_PER_INSTR.
	//
	// iretire is a 1-bit strobe (SR mode). ilastsize is log2(halfwords).
	// ecause / tval are meaningful only when itype is INTERRUPT (ecause)
	// or EXCEPTION_TRAP (ecause + tval).
	// ------------------------------------------------------------------
	task automatic drive_instr_pulse(
		input tip_itype_e     itype_,
		input tip_iaddr_t     iaddr_,
		input tip_ilastsize_t ilastsize_ = tip_ilastsize_t'(DEFAULT_ILASTSIZE),
		input tip_ecause_e    ecause_    = tip_ecause_e'(0),
		input tip_iaddr_t     tval_      = '0
	);
		// Idle padding before retirement (so each instruction occupies
		// CYCLES_PER_INSTR cycles total).
		repeat (CYCLES_PER_INSTR - 1) @(posedge clk);
		// Drive the retirement on the next clock edge.
		@(negedge clk);
		r_iretire   = 1;
		r_itype     = itype_;
		r_iaddr     = iaddr_;
		r_ilastsize = ilastsize_;
		r_ecause    = ecause_;
		r_tval      = tval_;
		@(posedge clk);
		@(negedge clk);
		r_iretire   = 0;
		r_dretire   = 0;
		// Clear ecause/tval after the trap pulse so they don't leak
		// into the next retirement.
		r_ecause    = tip_ecause_e'(0);
		r_tval      = '0;
	endtask

	// ------------------------------------------------------------------
	// Lifecycle
	// ------------------------------------------------------------------
	task automatic enter(input tip_iaddr_t start_pc);
		cur_pc  = start_pc;
		r_iaddr = start_pc;
		enabled = 1;
		log_event(CPU_ENTER, start_pc);
	endtask

	task automatic exit_trace();
		enabled = 0;
		log_event(CPU_EXIT, cur_pc);
	endtask

	// Run `cycles` clock cycles without retiring anything.
	task automatic idle(input int cycles);
		repeat (cycles) @(posedge clk);
	endtask

	// ------------------------------------------------------------------
	// Straight-line execution
	// ------------------------------------------------------------------
	// Retire enough 32-bit instructions to cover `n_bytes`. (Compressed
	// 16-bit RVC is not modelled here; instructions are 4 bytes each.
	// For RVC scenarios construct your own loop with the desired
	// ilastsize_ on each pulse.)
	task automatic run(input int n_bytes);
		int n_instr;
		n_instr = (n_bytes + 3) / 4;
		for (int i = 0; i < n_instr; i++) begin
			drive_instr_pulse(.itype_(OTHER), .iaddr_(cur_pc));
			log_event(CPU_RUN, cur_pc);
			cur_pc = cur_pc + 4;
		end
	endtask

	// ------------------------------------------------------------------
	// Control flow
	// ------------------------------------------------------------------
	task automatic jump_to(input tip_iaddr_t target);
		drive_instr_pulse(.itype_(UNINFERABLE_JUMP), .iaddr_(cur_pc));
		log_event(CPU_JUMP, cur_pc, target);
		cur_pc = target;
	endtask

	task automatic branch_taken(input tip_iaddr_t target);
		drive_instr_pulse(.itype_(TAKEN_BRANCH), .iaddr_(cur_pc));
		log_event(CPU_BRANCH_TAKEN, cur_pc, target);
		cur_pc = target;
	endtask

	task automatic branch_not_taken();
		drive_instr_pulse(.itype_(NOT_TAKEN_BRANCH), .iaddr_(cur_pc));
		log_event(CPU_BRANCH_NOT_TAKEN, cur_pc);
		cur_pc = cur_pc + 4;
	endtask

	task automatic call_to(input tip_iaddr_t target);
		drive_instr_pulse(.itype_(INFERRABLE_CALL), .iaddr_(cur_pc));
		call_stack.push_back(cur_pc + 4);
		log_event(CPU_CALL, cur_pc, target);
		cur_pc = target;
	endtask

	task automatic ret();
		tip_iaddr_t ret_pc;
		if (call_stack.size() == 0) begin
			$error("[cpu_model] ret() with empty call stack at pc=%08x", cur_pc);
			return;
		end
		drive_instr_pulse(.itype_(RETURN), .iaddr_(cur_pc));
		ret_pc = call_stack[$];
		call_stack.pop_back();
		log_event(CPU_RET, cur_pc, ret_pc);
		cur_pc = ret_pc;
	endtask

	task automatic uninferable_jump(input tip_iaddr_t target);
		drive_instr_pulse(.itype_(UNINFERABLE_JUMP), .iaddr_(cur_pc));
		log_event(CPU_UNINFERABLE_JUMP, cur_pc, target);
		cur_pc = target;
	endtask

	// ------------------------------------------------------------------
	// Exceptions / interrupts
	//
	// `cause` is the 4-bit low-order portion of mcause/scause. The "is
	// interrupt" high bit is conveyed by `itype` (INTERRUPT vs
	// EXCEPTION_TRAP), so it isn't repeated in ecause.
	//
	// `tval` is meaningful only for EXCEPTION_TRAP (mtval/stval — the
	// faulting address for page faults, etc.). Interrupts ignore it.
	// ------------------------------------------------------------------
	task automatic interrupt(input int cause, input tip_iaddr_t handler);
		drive_instr_pulse(
			.itype_  (INTERRUPT),
			.iaddr_  (cur_pc),
			.ecause_ (tip_ecause_e'(cause))
		);
		trap_stack.push_back(cur_pc);
		log_event(CPU_INTERRUPT, cur_pc, handler, cause);
		cur_pc = handler;
	endtask

	task automatic exception_trap(
		input int         cause,
		input tip_iaddr_t handler,
		input tip_iaddr_t tval = '0
	);
		drive_instr_pulse(
			.itype_  (EXCEPTION_TRAP),
			.iaddr_  (cur_pc),
			.ecause_ (tip_ecause_e'(cause)),
			.tval_   (tval)
		);
		trap_stack.push_back(cur_pc);
		log_event(CPU_EXCEPTION, cur_pc, handler, cause);
		cur_pc = handler;
	endtask

	task automatic mret();
		tip_iaddr_t ret_pc;
		if (trap_stack.size() == 0) begin
			$error("[cpu_model] mret() with empty trap stack at pc=%08x", cur_pc);
			return;
		end
		drive_instr_pulse(.itype_(EXCEPTION_IR), .iaddr_(cur_pc));
		ret_pc = trap_stack[$];
		trap_stack.pop_back();
		log_event(CPU_MRET, cur_pc, ret_pc);
		cur_pc = ret_pc;
	endtask

	// ------------------------------------------------------------------
	// Data trace
	//
	// A load/store-bearing instruction asserts BOTH iretire (the
	// instruction completed) and dretire (the data access completed) in
	// the same cycle. dsize is log2(byte count): 0=B, 1=H, 2=W, 3=D.
	// ------------------------------------------------------------------
	task automatic drive_dretire_pulse(
		input tip_dtype_e dtype_,
		input tip_iaddr_t daddr_,
		input tip_dsize_t dsize_,
		input tip_data_t  data_ = '0
	);
		repeat (CYCLES_PER_INSTR - 1) @(posedge clk);
		@(negedge clk);
		r_iretire   = 1;
		r_itype     = OTHER;
		r_iaddr     = cur_pc;
		r_ilastsize = tip_ilastsize_t'(DEFAULT_ILASTSIZE);
		r_dretire   = 1;
		r_dtype     = dtype_;
		r_daddr     = daddr_;
		r_dsize     = dsize_;
		r_data      = data_;
		r_sdata     = data_[TIP_SDATA_WIDTH-1:0];
		@(posedge clk);
		@(negedge clk);
		r_iretire = 0;
		r_dretire = 0;
	endtask

	// size: log2 of byte count (0=B, 1=H, 2=W, 3=D, ...)
	task automatic load_data(input tip_iaddr_t addr, input int size);
		drive_dretire_pulse(LOAD, addr, tip_dsize_t'(size));
		log_event(CPU_LOAD, cur_pc, addr, 0, size);
		cur_pc = cur_pc + 4;
	endtask

	task automatic store_data(input tip_iaddr_t addr, input int size, input tip_data_t data);
		drive_dretire_pulse(STORE, addr, tip_dsize_t'(size), data);
		log_event(CPU_STORE, cur_pc, addr, data, size);
		cur_pc = cur_pc + 4;
	endtask

	// ------------------------------------------------------------------
	// CSR writes (drive HSI events from software-side stimulus). The
	// actual Wishbone write is issued by csr_helper in the testbench;
	// this task only updates the cpu_model's event log so the scoreboard
	// knows a CSR write happened.
	// ------------------------------------------------------------------
	task automatic csr_write(input int csr_addr, input tip_data_t val);
		log_event(CPU_CSR_WRITE, cur_pc, tip_iaddr_t'(csr_addr), val);
	endtask

	// ------------------------------------------------------------------
	// Privilege / context state — held until the next call. Per spec,
	// priv reflects the privilege level of all instructions in the next
	// retired block. context is reported under the policy set by ctype.
	// ------------------------------------------------------------------
	task automatic set_priv(input tip_priv_t p);
		r_priv = p;
	endtask

	task automatic set_context(input tip_context_t ctx, input tip_ctype_t ct = 2 /* precise */);
		r_context = ctx;
		r_ctype   = ct;
	endtask

	// ------------------------------------------------------------------
	// NexRv PCInfo writer
	//
	// Walks event_q and produces a NexRv-format PCInfo file describing
	// the scripted scenario as a sequence of retired instructions. The
	// NexRv reference decoder uses this file as its "program memory"
	// when validating encoder output messages.
	//
	// Type-code mapping (matches tip_pkg::GetPCInfoType in the encoder):
	//   CPU_RUN, CPU_LOAD, CPU_STORE, CPU_BRANCH_NOT_TAKEN  -> L
	//   CPU_BRANCH_TAKEN                                    -> BD
	//   CPU_JUMP                                            -> JD
	//   CPU_UNINFERABLE_JUMP                                -> JI
	//   CPU_CALL                                            -> CD
	//   CPU_RET, CPU_MRET                                   -> R
	//   CPU_INTERRUPT, CPU_EXCEPTION                        -> E
	//   CPU_ENTER, CPU_EXIT, CPU_CSR_*                      -> skipped
	//
	// Length is `1 << (DEFAULT_ILASTSIZE + 1)` bytes (4 for RV32I,
	// 2 for RVC). All instructions in the current scenario share the
	// same length; extend the event_q to carry per-event size if RVC
	// support is needed.
	// ------------------------------------------------------------------
	function automatic int write_nexrv_info(input string path);
		int fd;
		int n_written = 0;
		int unsigned len_bytes = 1 << (DEFAULT_ILASTSIZE + 1);
		if (path == "") return 0;
		fd = $fopen(path, "w");
		if (fd == 0) begin
			$error("[cpu_model] failed to open '%s' for NexRv info write", path);
			return 0;
		end
		foreach (event_q[i]) begin
			case (event_q[i].kind)
				CPU_RUN, CPU_LOAD, CPU_STORE, CPU_BRANCH_NOT_TAKEN: begin
					$fwrite(fd, "0x%08x,L%0d\n", event_q[i].pc, len_bytes);
					n_written++;
				end
				CPU_BRANCH_TAKEN: begin
					$fwrite(fd, "0x%08x,BD%0d,0x%08x\n", event_q[i].pc, len_bytes, event_q[i].target);
					n_written++;
				end
				CPU_JUMP: begin
					$fwrite(fd, "0x%08x,JD%0d,0x%08x\n", event_q[i].pc, len_bytes, event_q[i].target);
					n_written++;
				end
				CPU_UNINFERABLE_JUMP: begin
					$fwrite(fd, "0x%08x,JI%0d,0x%08x\n", event_q[i].pc, len_bytes, event_q[i].target);
					n_written++;
				end
				CPU_CALL: begin
					$fwrite(fd, "0x%08x,CD%0d,0x%08x\n", event_q[i].pc, len_bytes, event_q[i].target);
					n_written++;
				end
				CPU_RET, CPU_MRET: begin
					$fwrite(fd, "0x%08x,R%0d\n", event_q[i].pc, len_bytes);
					n_written++;
				end
				CPU_INTERRUPT, CPU_EXCEPTION: begin
					$fwrite(fd, "0x%08x,E%0d,0x%08x\n", event_q[i].pc, len_bytes, event_q[i].target);
					n_written++;
				end
				// CPU_ENTER, CPU_EXIT, CPU_CSR_WRITE, CPU_CSR_READ: skipped
				default: ;
			endcase
		end
		$fclose(fd);
		$display("*** INFO (%m, line %0d) nexrv_info saved to %s (%0d entries)",
			`__LINE__, path, n_written);
		return n_written;
	endfunction

	// Auto-write on simulation end if a path was supplied.
	final begin
		if (NEXRV_INFO_PATH != "") void'(write_nexrv_info(NEXRV_INFO_PATH));
	end

	// ------------------------------------------------------------------
	// Debug print
	// ------------------------------------------------------------------
	function automatic void dump_events();
		$display("[cpu_model] event log (%0d entries):", event_q.size());
		foreach (event_q[i]) begin
			$display("  %4d: %-18s pc=%08x target=%08x payload=%016x size=%0d",
				i,
				event_kind_str(event_q[i].kind),
				event_q[i].pc,
				event_q[i].target,
				event_q[i].payload,
				event_q[i].size);
		end
	endfunction

endmodule : cpu_model

`default_nettype wire
