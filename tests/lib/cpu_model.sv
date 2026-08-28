// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
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
 *   (https://docs.riscv.org/reference/e-trace/v2.0/ingressPort.html):
 *
 *     - SR (single-retirement) mode: `iretire` is a 1-bit strobe (high
 *       for exactly one tip_clk cycle per retired instruction). Set by
 *       `tip_pkg::TIP_IRETIRE_WIDTH == 1`.
 *     - `ilastsize` carries log2 of the instruction size in halfwords:
 *         0 => 1 halfword (16-bit, RVC)
 *         1 => 2 halfwords (32-bit, the default in this model)
 *     - `iaddr` is always the SOURCE PC of the retired instruction
 *       (the branch / call / return / jump itself, not the target).
 *     - `INTERRUPT` / `EXCEPTION_TRAP` itypes are legal with EITHER
 *       iretire=1 (the trap fires in the same cycle the trap-source
 *       instruction retires — "co-reported"; tip.iaddr is the
 *       trapping pc) OR iretire=0 (asynchronous marker — the trap
 *       fires between instructions; per riscv-trace-spec
 *       ingressPort.adoc "the number of instructions retired may be
 *       zero"). On an iretire=0 trap beat tip.iaddr IS defined and
 *       carries the address of the not-yet-retired instruction (=
 *       mepc), exactly as a real CPU drives it at trap entry; the
 *       spec's "all other signals undefined" clause is gated on
 *       itype=0 (the idle beat) and does NOT apply to trap markers.
 *       The `interrupt(.async(...))` task drives both shapes; the
 *       co-reported shape advances mepc=cur_pc+4 (trap pc executed),
 *       the async-marker shape uses mepc=cur_pc (trap pc re-runs
 *       after mret) and drives tip.iaddr=cur_pc accordingly so the
 *       encoder's pending-next-iaddr capture has a defined value.
 *       `cause` is the 4-bit lower portion of mcause/scause — the
 *       high "is interrupt" bit is conveyed by itype, not ecause.
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
	int    CYCLES_PER_INSTR   = 4,
	// Default size of a retired instruction, in log2(halfwords) per spec.
	// 1 = 32-bit (RV32I), 0 = 16-bit (RVC). Tests can override per-task.
	int    DEFAULT_ILASTSIZE  = 1,
	// Optional path for a NexRv PCInfo file derived from the scripted
	// scenario. Format (one line per retired instruction):
	//   0x<src_pc>,<type><length_bytes>[,0x<target_pc>]
	// Type codes: L=Linear, BD=Branch Direct, JD=Jump Direct,
	// JI=Jump Indirect, CD=Call Direct, R=Return. NexRv loads this
	// as a dense, sorted array — entries are sorted and gaps in the
	// address range are filled with sentinel L entries. Written on
	// simulation end. Empty = no file.
	string NEXRV_INFO_PATH    = "",
	// Optional path for an execution-ordered "expected PC sequence"
	// file, one PC per line in the order the cpu_model executed them.
	// This is what the decoded NexRv output should match
	// line-for-line. Empty = no file.
	string EXPECTED_PCS_PATH  = "",
	// Optional path for an execution-ordered "expected data trace"
	// file. One line per data access:
	//   LOAD|STORE,0x<daddr>,<size_bytes>
	// Used by scripts/decode_and_check_data.sh to verify the encoder
	// emitted exactly the load/store sequence the cpu_model issued.
	// Empty = no file.
	string EXPECTED_DATA_PATH = "",
	// Optional path for an execution-ordered "expected CTXP" file — the
	// CTTE eXPort records (SYNC / BRANCH_* / CALL / RETURN / MEMREAD_n /
	// MEMWRITE_n / DAQ_*) the NexRv reference decoder should produce from the
	// trace, in program order. Compared (normalized) against NexRv's CTXP text
	// export by scripts/decode_and_check.sh --ctxp. Empty = no file.
	string EXPECTED_CTXP_PATH = ""
) (
	input  uwire logic clk, // tip_clk
	input  uwire logic rst, // tip_rst (active high)
	tip_if.master      tip
);

	import tip_pkg::*;
	import cpu_model_pkg::*;
	import nexus_vendor::*;   // ACT_CAP_CMD (CSR id of the ACT-CAP command register)

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
	// Generic event sideband (seq 24, B1)
	logic           r_debug_mode = 0;
	logic           r_evti       = 0;
	logic           r_power_down = 0;
	logic           r_trigger    = 0;

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
	assign tip.debug_mode = r_debug_mode;
	assign tip.evti       = r_evti;
	assign tip.power_down = r_power_down;
	assign tip.trigger    = r_trigger;

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
	// TB-side mirror of "instruction tracing active". The test sets this
	// (via set_inst_traced) to match when it programs trTeControl.InstTracing/
	// Enable, so events retired during an instruction-tracing pause are tagged
	// untraced and excluded from the expected-PC reference. Default: traced.
	bit         inst_traced   = 1'b1;
	// TB-side mirror of "data tracing active" (trTeDataControl.DataTracing).
	// Tests with data trace off (e.g. the ACT-CAP test, which still issues
	// loads/stores to feed the DAQ data-context commands) set this 0 so those
	// accesses are NOT emitted as standalone CTXP MEM records. Default: traced.
	bit         data_traced   = 1'b1;

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
		e.traced      = inst_traced;
		e.data_traced = data_traced;
		event_q.push_back(e);
	endfunction

	// Mirror the encoder's instruction-tracing enable state for expected-PC
	// bookkeeping. Call with 0 just before driving instructions that execute
	// while instruction tracing is paused (InstTracing=0 / Enable=0), and with
	// 1 again after tracing resumes. Events logged while 0 are kept in the
	// event log (for liveness/debug) but omitted from the expected-PC list.
	task automatic set_inst_traced(input bit on);
		inst_traced = on;
	endtask

	// Mirror the encoder's data-tracing enable state (trTeDataControl.DataTracing)
	// for the expected-CTXP reference. Call with 0 when data tracing is off so
	// loads/stores are not emitted as CTXP MEM records (they may still run to
	// feed ACT-CAP DAQ data-context commands). Default: data-traced.
	task automatic set_data_traced(input bit on);
		data_traced = on;
	endtask

	// Split-load pending-overwrite bookkeeping (SPLIT_DATA_ACCESS=1): the
	// composer holds exactly ONE pending split load; a LOAD whose lresp
	// never arrives before the next LOAD is silently replaced and never
	// emits a data message. cpu_model cannot see lresp (the TB drives it
	// hierarchically), so the TB marks the doomed load itself, right after
	// issuing it. The event stays in the log (liveness/debug) but is
	// excluded from the expected-data/CTXP references — the oracle encodes
	// the documented overwrite contract, not a decoder shortfall.
	task automatic mark_last_event_data_untraced();
		if (event_q.size() > 0) event_q[event_q.size()-1].data_traced = 1'b0;
		else $error("[cpu_model] mark_last_event_data_untraced: event log empty");
	endtask

	// ------------------------------------------------------------------
	// Low-level pulse helper: drive one retired instruction for one
	// clock cycle, pad with idle cycles up to CYCLES_PER_INSTR.
	//
	// iretire is a 1-bit strobe (SR mode). ilastsize is log2(halfwords).
	// ecause / tval are meaningful only when itype is INTERRUPT (ecause)
	// or EXCEPTION_TRAP (ecause + tval).
	// ------------------------------------------------------------------
	// iretire value for a SINGLE retired instruction, in whichever shape
	// this build's ingress uses. SR: the strobe, 1. Block: the instruction's
	// own halfword count, 2^ilastsize -- driving a bare 1 there would claim
	// a one-halfword block for a 32-bit instruction, which is not "the
	// single-retirement case of a block ingress" but a malformed beat.
	// At CT_EN_BLOCK_TIP = 0 this folds to the literal 1, so every existing
	// scenario drives exactly the bits it drove before.
	function automatic tip_iretire_t sr_iretire(input tip_ilastsize_t ilastsize_);
		int hw;
		hw = 1 << ilastsize_;
		sr_iretire = ct_pkg::CT_EN_BLOCK_TIP ? tip_iretire_t'(hw) : tip_iretire_t'(1);
	endfunction

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
		r_iretire   = sr_iretire(ilastsize_);
		r_itype     = itype_;
		r_iaddr     = iaddr_;
		r_ilastsize = ilastsize_;
		r_ecause    = ecause_;
		r_tval      = tval_;
		@(posedge clk);
		@(negedge clk);
		r_iretire   = 0;
		r_dretire   = 0;
		// Reset itype/ecause/tval to "no event" defaults so they don't
		// leak across idle cycles. The encoder's composer treats
		// `tip.itype == INTERRUPT | EXCEPTION_TRAP` as a trap-arrival
		// marker combinationally (no edge detection — see
		// ct_L23_preproc_composer_etip.sv `is_trap_event`); leaving
		// r_itype sticky at INTERRUPT would re-fire the marker on every
		// subsequent idle cycle until the next pulse overrides it,
		// producing CYCLES_PER_INSTR phantom IBHs per real interrupt.
		r_itype     = OTHER;
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
	// Generic event sideband (seq 24, B1)
	// ------------------------------------------------------------------
	// Enter debug mode: per the tip_if port contract the level rises on a
	// beat AFTER the last pre-debug retire (this task drives it on an idle
	// beat). While in debug the encoder emits/counts nothing, so the caller
	// should retire debug-window instructions between debug_enter/-_exit
	// with set_inst_traced(0) -- this task flips the expected-PC gating
	// itself for convenience.
	task automatic debug_enter();
		@(posedge clk);
		r_debug_mode <= 1'b1;
		set_inst_traced(1'b0);
		@(posedge clk);
	endtask

	// Exit debug mode: level falls before the first post-debug retire.
	task automatic debug_exit();
		@(posedge clk);
		r_debug_mode <= 1'b0;
		set_inst_traced(1'b1);
		@(posedge clk);
	endtask

	// One-cycle external trace trigger pulse (SYNC=0 marker on the next
	// retire while tracing is active).
	task automatic evti_pulse();
		@(posedge clk);
		r_evti <= 1'b1;
		@(posedge clk);
		r_evti <= 1'b0;
		@(posedge clk);
	endtask

	// Retire one OTHER instruction that carries a context report (ingress
	// ctype=2 "report precisely" + context value): with trTeControl.Context
	// set the encoder emits an Ownership message (TCODE 2, FORMAT=2) for it.
	// Logged as a normal run instruction in the expected-PC reference.
	task automatic context_report(input tip_context_t ctx);
		r_context = ctx;
		r_ctype   = tip_ctype_t'(2);
		drive_instr_pulse(.itype_(OTHER), .iaddr_(cur_pc));
		log_event(CPU_RUN, cur_pc);
		cur_pc = cur_pc + 4;
		r_ctype   = '0;
		r_context = '0;
	endtask

	// One-cycle watchpoint/trigger pulse (SYNC=6 marker on the next retire
	// while tracing is active and trTeControl.InstTrigEnable is set).
	task automatic trigger_pulse();
		@(posedge clk);
		r_trigger <= 1'b1;
		@(posedge clk);
		r_trigger <= 1'b0;
		@(posedge clk);
	endtask

	// Power-down window: no retires are expected while the level is high.
	task automatic power_down_enter();
		@(posedge clk);
		r_power_down <= 1'b1;
		@(posedge clk);
	endtask

	task automatic power_down_exit();
		@(posedge clk);
		r_power_down <= 1'b0;
		@(posedge clk);
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
	// Block ingress (R1.3, ct_pkg::CT_EN_BLOCK_TIP)
	//
	// ONE tip beat reports SEVERAL retired instructions:
	//   iretire   = halfwords of the whole block
	//   iaddr     = FIRST instruction of the block
	//   ilastsize = size of the LAST instruction
	//   itype     = how the block terminated
	// Only the last instruction of a block may be a control-flow event --
	// that is what ends a block -- so the tasks below take `n_lead` linear
	// instructions plus one terminator.
	//
	// The point of the whole gate is the LOGGING: these tasks log one oracle
	// event PER INSTRUCTION, exactly as the single-retirement tasks do. The
	// expected-PC reference a block scenario produces is therefore identical
	// to the one the same instructions produce when driven one per beat, and
	// "block reporting does not change the reconstructed flow" is checked
	// against an oracle that never saw a block. A comparison of the
	// encoder's own halfword count against the encoder's own halfword count
	// would prove nothing.
	//
	// 32-bit instructions only (ilastsize = 1, two halfwords each). Mixed
	// RVC sizing is an ilastsize question the SR tasks already cover; the
	// block shape is orthogonal to it.
	// ------------------------------------------------------------------
	task automatic drive_block_pulse(
		input tip_itype_e itype_,
		input tip_iaddr_t iaddr_first_,
		input int         n_instr_
	);
		int hw;
		if (!ct_pkg::CT_EN_BLOCK_TIP) begin
			$error("[cpu_model] BLOCK-TASK-IN-SR-BUILD: block tasks need ct_pkg::CT_EN_BLOCK_TIP=1 (tip.iretire is one bit here and would truncate)");
			$finish;
		end
		if (n_instr_ < 1) begin
			$error("[cpu_model] drive_block_pulse: n_instr must be >= 1 (got %0d)", n_instr_);
			$finish;
		end
		// Computed BEFORE the call/assignment, never as a cast inside an
		// argument: XSIM 2026.1 with -debug off mistranslates an int'() cast
		// in argument position (the value arrives as 0).
		hw = 2 * n_instr_;
		repeat (CYCLES_PER_INSTR - 1) @(posedge clk);
		@(negedge clk);
		r_iretire   = tip_iretire_t'(hw);
		r_itype     = itype_;
		r_iaddr     = iaddr_first_;
		r_ilastsize = tip_ilastsize_t'(1);
		r_ecause    = tip_ecause_e'(0);
		r_tval      = '0;
		@(posedge clk);
		@(negedge clk);
		r_iretire   = 0;
		r_dretire   = 0;
		r_itype     = OTHER;
		r_ecause    = tip_ecause_e'(0);
		r_tval      = '0;
	endtask

	// Log `n` linear instructions from cur_pc and advance it. Shared tail of
	// every block task, so the oracle can only be written one way.
	function automatic void log_block_lead(input int n);
		for (int i = 0; i < n; i++) begin
			log_event(CPU_RUN, cur_pc);
			cur_pc = cur_pc + 4;
		end
	endfunction

	// A purely linear block: n_instr instructions, terminated by OTHER.
	// (OTHER is also how an adapter splits a long linear run to keep iretire
	// inside CT_IRETIRE_WIDTH -- it raises no CF event, it only accumulates.)
	task automatic run_block(input int n_instr);
		drive_block_pulse(.itype_(OTHER), .iaddr_first_(cur_pc), .n_instr_(n_instr));
		log_block_lead(n_instr);
	endtask

	// n_lead linear instructions followed by a taken branch, in ONE beat.
	task automatic block_branch_taken(input int n_lead, input tip_iaddr_t target);
		tip_iaddr_t cf_pc;
		cf_pc = cur_pc + tip_iaddr_t'(4 * n_lead);
		drive_block_pulse(.itype_(TAKEN_BRANCH), .iaddr_first_(cur_pc), .n_instr_(n_lead + 1));
		log_block_lead(n_lead);
		log_event(CPU_BRANCH_TAKEN, cf_pc, target);
		cur_pc = target;
	endtask

	// n_lead linear instructions followed by a NOT-taken branch, in ONE beat.
	// Execution falls through to the instruction after the branch.
	task automatic block_branch_not_taken(input int n_lead, input tip_iaddr_t target = '0);
		tip_iaddr_t cf_pc, tgt;
		cf_pc = cur_pc + tip_iaddr_t'(4 * n_lead);
		tgt   = (target == '0) ? (cf_pc + 8) : target;
		drive_block_pulse(.itype_(NOT_TAKEN_BRANCH), .iaddr_first_(cur_pc), .n_instr_(n_lead + 1));
		log_block_lead(n_lead);
		log_event(CPU_BRANCH_NOT_TAKEN, cf_pc, tgt);
		cur_pc = cf_pc + 4;
	endtask

	// n_lead linear instructions followed by a direct call, in ONE beat.
	// Exercises the composer's return-address push, which in block mode has
	// to derive the return address from the BLOCK span (iaddr + 2*iretire),
	// not from iaddr + one instruction.
	task automatic block_call_to(input int n_lead, input tip_iaddr_t target);
		tip_iaddr_t cf_pc;
		cf_pc = cur_pc + tip_iaddr_t'(4 * n_lead);
		drive_block_pulse(.itype_(INFERRABLE_CALL), .iaddr_first_(cur_pc), .n_instr_(n_lead + 1));
		log_block_lead(n_lead);
		call_stack.push_back(cf_pc + 4);
		log_event(CPU_CALL, cf_pc, target);
		cur_pc = target;
	endtask

	// n_lead linear instructions followed by a return, in ONE beat.
	task automatic block_ret(input int n_lead);
		tip_iaddr_t cf_pc, ret_pc;
		if (call_stack.size() == 0) begin
			$error("[cpu_model] block_ret() with empty call stack at pc=%08x", cur_pc);
			return;
		end
		cf_pc = cur_pc + tip_iaddr_t'(4 * n_lead);
		drive_block_pulse(.itype_(RETURN), .iaddr_first_(cur_pc), .n_instr_(n_lead + 1));
		log_block_lead(n_lead);
		ret_pc = call_stack[$];
		call_stack.pop_back();
		log_event(CPU_RET, cf_pc, ret_pc);
		cur_pc = ret_pc;
	endtask

	// n_lead linear instructions followed by an indirect (uninferable) jump.
	task automatic block_uninferable_jump(input int n_lead, input tip_iaddr_t target);
		tip_iaddr_t cf_pc;
		cf_pc = cur_pc + tip_iaddr_t'(4 * n_lead);
		drive_block_pulse(.itype_(UNINFERABLE_JUMP), .iaddr_first_(cur_pc), .n_instr_(n_lead + 1));
		log_block_lead(n_lead);
		log_event(CPU_UNINFERABLE_JUMP, cf_pc, target);
		cur_pc = target;
	endtask

	// ------------------------------------------------------------------
	// Control flow
	// ------------------------------------------------------------------
	// Direct, inferable unconditional jump (`j label` = jal x0). Drives
	// OTHER_INFERABLE_JUMP so the encoder emits NO message and NO history bit
	// for it — the decoder follows it purely from the program image (PCInfo
	// type JD). This is the inferable loop-back `j` that absint's scheduler_run
	// uses at 0xa10410c8, and it is materially different from a taken
	// conditional branch (BD), which DOES carry a recoverable history bit.
	task automatic jump_to(input tip_iaddr_t target);
		drive_instr_pulse(.itype_(OTHER_INFERABLE_JUMP), .iaddr_(cur_pc));
		log_event(CPU_JUMP, cur_pc, target);
		cur_pc = target;
	endtask

	task automatic branch_taken(input tip_iaddr_t target);
		drive_instr_pulse(.itype_(TAKEN_BRANCH), .iaddr_(cur_pc));
		log_event(CPU_BRANCH_TAKEN, cur_pc, target);
		cur_pc = target;
	endtask

	// A not-taken conditional branch. `target` is the address the branch
	// WOULD jump to if taken — recorded in PCInfo as the BD target even
	// though execution falls through to cur_pc+4. Defaults to cur_pc+8.
	task automatic branch_not_taken(input tip_iaddr_t target = '0);
		tip_iaddr_t tgt;
		tgt = (target == '0) ? (cur_pc + 8) : target;
		drive_instr_pulse(.itype_(NOT_TAKEN_BRANCH), .iaddr_(cur_pc));
		log_event(CPU_BRANCH_NOT_TAKEN, cur_pc, tgt);
		cur_pc = cur_pc + 4;
	endtask

	task automatic call_to(input tip_iaddr_t target);
		drive_instr_pulse(.itype_(INFERRABLE_CALL), .iaddr_(cur_pc));
		call_stack.push_back(cur_pc + 4);
		log_event(CPU_CALL, cur_pc, target);
		cur_pc = target;
	endtask

	// Direct, inferable tail call (`jal x0, target` = `j target` at the
	// end of a function body — the return address register is left
	// untouched, so the eventual `ret` returns to the caller's caller).
	// Drives INFERRABLE_TAIL_CALL itype. In BRANCH_HIST mode the encoder
	// emits NO message for it (inferable from the program image, no
	// HIST bit); the decoder follows it from the CD PCInfo entry. Use
	// this to exercise the encoder's handling of an indirect-CF event
	// (e.g. an INTERRUPT) directly followed by an inferable tail call —
	// the trap's queued CF eTIP and the tail-call's CF eTIP coexist in
	// the composer's slot buffer and the tail-call's iaddr supplies the
	// next_iaddr for the trap.
	task automatic tail_call_to(input tip_iaddr_t target);
		drive_instr_pulse(.itype_(INFERRABLE_TAIL_CALL), .iaddr_(cur_pc));
		log_event(CPU_TAIL_CALL, cur_pc, target);
		cur_pc = target;
	endtask

	// Indirect (function-pointer) call: jalr-like. Like call_to but the target
	// is computed (UNINFERABLE_CALL itype -> "CI" PCInfo), so the decoder must
	// resolve it from an IndirectBranchHistory message rather than the program
	// image. Models e.g. a scheduler dispatching through a function pointer.
	task automatic indirect_call_to(input tip_iaddr_t target);
		drive_instr_pulse(.itype_(UNINFERABLE_CALL), .iaddr_(cur_pc));
		call_stack.push_back(cur_pc + 4);
		log_event(CPU_INDIRECT_CALL, cur_pc, target);
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
	// Spec-conformant trap-marker shape selector:
	//
	//   async = 0 (default): "co-reported" — the cur_pc instruction
	//       retires AND the trap fires in the same cycle. Driven as
	//       iretire=1 + itype=INTERRUPT for one cycle (the trap is
	//       carried as the itype of the retiring beat). mret resumes
	//       at cur_pc + 4 (the trap pc DID execute). The trap pc
	//       occupies an L PCInfo slot and appears once in expected.pcs.
	//
	//   async = 1: "pure asynchronous marker" — no instruction retires
	//       this beat. Driven as iretire=0 + itype=INTERRUPT for one
	//       cycle; per riscv-trace-spec ingressPort.adoc the trap can
	//       arrive on a tip beat with iretire=0 and "the number of
	//       instructions retired may be zero". tip.iaddr IS driven on
	//       this beat (see file header) and carries cur_pc — the
	//       address of the not-yet-retired instruction (= mepc). The
	//       composer reads it to fill in the previous CF's next_iaddr
	//       (pending_cf_next_iaddr capture) and to anchor the trap CF
	//       itself; leaving r_iaddr stale would write the previous
	//       CF's source as its own target. mret resumes at cur_pc
	//       (the not-yet-executed instruction re-runs). The trap pc
	//       gets no PCInfo slot from this event — it will be filled
	//       in by the CPU_RUN that re-retires it after mret.
	//
	// Both shapes are legal per spec and a conforming encoder must
	// produce an IndirectBranchHistory message with BTYPE=INTERRUPT
	// for either; the zero-vs-nonzero iretire affects ICNT
	// (inclusive/exclusive of the trap pc) but not the message
	// emission. This task exercises both shapes via the `async` flag;
	// see tests/instruction/02_interrupts for sample scenarios.
	task automatic interrupt(
		input int          cause,
		input tip_iaddr_t  handler,
		input bit          async     = 0,
		input bit          bad_iaddr = 0   // async only: drive a POISON tip.iaddr
	);
		if (async) begin
			// iretire=0 marker: drive itype=INTERRUPT for one cycle with
			// iretire held low.
			//
			// Per the trace-spec discussion riscv-trace-spec#324, tip.iaddr is
			// arguably not meant to be set for an asynchronous interrupt. The
			// encoder does NOT use the interrupt's own source PC: an interrupt
			// is encoded as an Indirect Branch (ICNT + target UADDR) and the
			// decoder reconstructs the source by walking ICNT. So for the
			// interrupt's own message tip.iaddr is a don't-care — proven by the
			// `bad_iaddr` proof scenario in this group, which poisons it on a
			// post-sequential interrupt and still decodes bit-correctly.
			//
			// We still drive cur_pc by default, because when an async interrupt
			// immediately FOLLOWS a taken CF, the composer captures that prior
			// branch's target (next_iaddr) from this beat's tip.iaddr via its
			// pending_cf_next_iaddr mechanism. That is the only real dependency
			// on the interrupt beat's iaddr.
			repeat (CYCLES_PER_INSTR - 1) @(posedge clk);
			@(negedge clk);
			r_iretire = 0;
			r_itype   = INTERRUPT;
			r_iaddr   = bad_iaddr ? 32'hBAD0_BAD0 : cur_pc;
			r_ecause  = tip_ecause_e'(cause);
			@(posedge clk);
			@(negedge clk);
			r_itype   = OTHER;
			r_ecause  = tip_ecause_e'(0);
			trap_stack.push_back(cur_pc);
			log_event(CPU_INTERRUPT_ASYNC, cur_pc, handler, cause);
		end else begin
			// iretire=1 co-report: cur_pc retired and the trap fired
			// in the same cycle. Resume at cur_pc + 4 on mret so we
			// don't re-classify the trap PC as both E (here) and L
			// (after mret).
			drive_instr_pulse(
				.itype_  (INTERRUPT),
				.iaddr_  (cur_pc),
				.ecause_ (tip_ecause_e'(cause))
			);
			trap_stack.push_back(cur_pc + 4);
			log_event(CPU_INTERRUPT, cur_pc, handler, cause);
		end
		cur_pc = handler;
	endtask

	task automatic exception_trap(
		input tip_ecause_e cause,
		input tip_iaddr_t  handler,
		input tip_iaddr_t  tval      = '0,
		input bit          no_retire = 0
	);
		// Synchronous exception. Two shapes:
		//
		//  no_retire=0 (co-reported): the trap-source instruction retires this
		//    beat (iretire=1, iaddr=cur_pc); resume at cur_pc+4.
		//
		//  no_retire=1 (illegal-instruction style): the faulting instruction is
		//    fetched but NEVER retires (iretire=0). Its iaddr/ilastsize are still
		//    communicated on the trap beat — exactly as a real CPU drives an
		//    illegal-instruction trap. The encoder's `count_halfwords` includes
		//    EXCEPTION_TRAP regardless of iretire (see composer_etip), so the
		//    decoder still walks the faulting instruction and reconstructs its PC
		//    (mepc) even though it never retired. The faulting PC therefore still
		//    appears once in expected.pcs (CPU_EXCEPTION -> "L").
		if (no_retire) begin
			repeat (CYCLES_PER_INSTR - 1) @(posedge clk);
			@(negedge clk);
			r_iretire   = 0;
			r_itype     = EXCEPTION_TRAP;
			r_iaddr     = cur_pc;
			r_ilastsize = tip_ilastsize_t'(DEFAULT_ILASTSIZE);
			r_ecause    = cause;
			r_tval      = tval;
			@(posedge clk);
			@(negedge clk);
			r_itype     = OTHER;
			r_ecause    = tip_ecause_e'(0);
			r_tval      = '0;
		end else begin
			drive_instr_pulse(
				.itype_  (EXCEPTION_TRAP),
				.iaddr_  (cur_pc),
				.ecause_ (cause),
				.tval_   (tval)
			);
		end
		trap_stack.push_back(cur_pc + 4);
		// no_retire=1: faulting instruction never retired (iretire=0) -> NO expected.pcs slot
		// (iretire ingress rule; 1:1 with AMD + the count_halfwords=iretire encoder). no_retire=0:
		// co-reported, the instruction retired -> keep the L slot.
		if (no_retire) log_event(CPU_EXCEPTION_NORETIRE, cur_pc, handler, cause);
		else           log_event(CPU_EXCEPTION,          cur_pc, handler, cause);
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
		r_iretire   = sr_iretire(tip_ilastsize_t'(DEFAULT_ILASTSIZE));
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
	task automatic load_data(input tip_iaddr_t addr, input int size,
	                         input tip_data_t data = '0);
		drive_dretire_pulse(LOAD, addr, tip_dsize_t'(size), data);
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
	// ACT-CAP (CSR Access Protocol) command — CSR-based instrumentation.
	//
	// Models the CPU executing `csrw ACT_CAP_CMD, x`: a functional NOP
	// (no system-bus side effect) whose write the encoder observes on the
	// TIP data channel. The ACT-CAP preprocessor (ct_L23_preproc_act_cap)
	// fires on (dretire && dtype==CSR_READ_WRITE && daddr==ACT_CAP_CMD)
	// and decodes tip.data with the RDL bit layout of trActCapStCmd
	// @ 0x0B10 (see tip_pkg::cmd_to_tip_data / tip_data_to_cmd):
	//   data[5:0]  = Cmd         (trActCapStCmd_e)
	//   data[7:6]  = Sink        (trActCapStSink_e: NEXUS / AXIS / AXIS_NEXUS / TE)
	//   data[31:8] = DirectData  (24-bit payload)
	// The retiring csrw itself is reported as an OTHER instruction so the
	// instruction stream stays well-formed.
	// ------------------------------------------------------------------
	task automatic act_cap_cmd(input logic [5:0]  cmd,
	                           input logic [1:0]  sink,
	                           input logic [23:0] direct_data = '0);
		tip_data_t d;
		d        = '0;
		d[5:0]   = cmd;
		d[7:6]   = sink;
		d[31:8]  = direct_data;
		drive_dretire_pulse(CSR_READ_WRITE, tip_iaddr_t'(ACT_CAP_CMD),
		                    tip_dsize_t'(2) /* word */, d);
		log_event(CPU_CSR_WRITE, cur_pc, tip_iaddr_t'(ACT_CAP_CMD), d);
		cur_pc = cur_pc + 4;
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
	// Maps a cpu_event to the static PCInfo type code the NexRv decoder
	// expects (single character of L/B/J/C/R/E, plus the D/I direct /
	// indirect qualifier where it matters).
	function automatic string pcinfo_type_str(cpu_event_kind_e k);
		// NEXRV pcinfo is a STATIC instruction-type table. The
		// interrupt/exception semantics are carried by the trace
		// messages themselves (TCODE), not by an E entry in pcinfo,
		// so we report the underlying instruction type (Linear) for
		// trap PCs — the decoder doesn't need to know "an interrupt
		// CAN happen here" to decode the trace.
		case (k)
			// CPU_CSR_WRITE models a `csrw` (e.g. an ACT-CAP command @0x0B10)
			// — a normal retired instruction (itype=OTHER) from the trace's
			// point of view, so it occupies a Linear PCInfo slot and a PC in
			// the executed stream.
			CPU_RUN, CPU_LOAD, CPU_STORE, CPU_CSR_WRITE,
			CPU_INTERRUPT, CPU_EXCEPTION: return "L";
			// CPU_INTERRUPT_ASYNC: the trap fired BEFORE cur_pc retired
			// (iretire=0 + itype=INTERRUPT — riscv-trace-spec ingressPort.adoc
			// "the number of instructions retired may be zero"). The PCInfo
			// slot for cur_pc is filled in when cur_pc retires after mret, so
			// this event itself has no PCInfo type and no expected.pcs entry.
			// CPU_EXCEPTION_NORETIRE: synchronous exception whose faulting
			// instruction never retired (iretire=0) -> not counted, no slot
			// (1:1 with AMD; matches the count_halfwords=iretire encoder fix).
			CPU_INTERRUPT_ASYNC, CPU_EXCEPTION_NORETIRE: return "";
			// A conditional branch is a "BD" (Branch Direct) in PCInfo
			// whether or not it was taken at runtime — the HIST bit in
			// the trace resolves the direction. A not-taken branch
			// continues to pc+len (no gap); a taken branch jumps to the
			// PCInfo target.
			CPU_BRANCH_TAKEN,
			CPU_BRANCH_NOT_TAKEN:    return "BD";
			CPU_JUMP:                return "JD";
			CPU_UNINFERABLE_JUMP:    return "JI";
			CPU_CALL:                return "CD";
			// Inferable tail-call (jal x0, target): rd is x0, so no
			// return address is linked and nothing is pushed onto the
			// return-address stack — the callee returns to the tail-
			// caller's caller. The DECODER's program-image PCInfo must
			// therefore be JD (a non-pushing direct jump), matching how
			// NexRv's own `-conv -objd` classifies the `j target` pseudo
			// (NexRvConv.c: `j`->JD, `jal`->CD). Emitting CD here would
			// push a spurious frame that the handler's mret then pops by
			// mistake, desyncing NexRv's call-stack return check.
			// (tip_pkg.GetPCInfoType maps INFERRABLE_TAIL_CALL->CD for the
			// trace itype encoding — a separate concern from the decoder's
			// program-memory PCInfo, which is what this file feeds.)
			CPU_TAIL_CALL:           return "JD";
			CPU_INDIRECT_CALL:       return "CI";
			CPU_RET, CPU_MRET:       return "R";
			default:                 return "";   // skipped
		endcase
	endfunction

	// ------------------------------------------------------------------
	// PC text format -- a CONTRACT with the reference decoder, not a taste
	// question. Every --pc gate diffs this model's expected-PC file against
	// NexRv's -pcout output line for line, so the two must print an address
	// with the same number of digits: 0x%08x while CT_XLEN = 32, 0x%016x at
	// 64 (NexRvDeco.c pcout). The PCInfo file uses the same width; NexRv
	// parses it with SCNx64, so a wider field stays readable either way.
	//
	// The format string MUST be a literal at every $sformatf call site, and
	// the width choice therefore lives in the `if` below rather than in a
	// parameter handed to the formatter. This used to read
	//     localparam string PC_HEX_FMT = <ternary>;
	//     return $sformatf(PC_HEX_FMT, a);
	// which is legal SystemVerilog and works under XSIM, but Verilator 5.040
	// -- the backend pinned in .abc.config, i.e. the one `make sim` uses --
	// does NOT substitute a non-literal format: it emitted the format string
	// itself, so pc_hex() returned the eleven characters "0x%08x" followed by
	// the address in decimal. Every artefact this model writes goes through
	// pc_hex (expected.pcs, the NexRv PCInfo, expected.data), so EVERY --pc
	// gate on the default backend was comparing against garbage, and the
	// PCInfo the decoder was handed could not be parsed either (D1-F2,
	// measured: 1 of 26 PCs decoded in tests/instruction/01_basic).
	// scripts/check_sim_fmt.py keeps the class out of the tree; the reference
	// sanity check in scripts/decode_and_check.sh catches a garbage oracle
	// from any other cause.
	// ------------------------------------------------------------------
	function automatic string pc_hex(input tip_iaddr_t a);
		if (tip_pkg::TIP_IADDRESS_WIDTH > 32) return $sformatf("0x%016x", a);
		else                                  return $sformatf("0x%08x", a);
	endfunction

	function automatic int write_nexrv_info(input string path);
		// NexRv loads the PCInfo into an array indexed by
		// (addr - base) / 4. Entries MUST be sorted by address and
		// each address MUST appear at most once. Build a sorted
		// (pc, type, target) table here, dedupe, then emit.
		int fd;
		int n_written = 0;
		int unsigned len_bytes = 1 << (DEFAULT_ILASTSIZE + 1);
		tip_iaddr_t  pcs        [$];
		string       types_at   [tip_iaddr_t];   // associative array pc -> type
		tip_iaddr_t  targets_at [tip_iaddr_t];

		if (path == "") return 0;

		// Build the (pc -> type, target) map in event order. First
		// observation of a PC wins; later visits with the same type
		// are no-ops, later visits with a DIFFERENT type are a test
		// authoring error and are flagged.
		foreach (event_q[i]) begin
			string t;
			t = pcinfo_type_str(event_q[i].kind);
			if (t == "") continue;
			if (types_at.exists(event_q[i].pc)) begin
				if (types_at[event_q[i].pc] != t) begin
					$error("[cpu_model] write_nexrv_info: PC %s has conflicting types '%s' and '%s' — NexRv pcinfo requires one type per PC. Restructure the test scenario.",
						pc_hex(event_q[i].pc), types_at[event_q[i].pc], t);
				end
				continue;
			end
			types_at[event_q[i].pc]   = t;
			targets_at[event_q[i].pc] = event_q[i].target;
			pcs.push_back(event_q[i].pc);
		end

		// Sort PCs ascending.
		pcs.sort();

		fd = $fopen(path, "w");
		if (fd == 0) begin
			$error("[cpu_model] failed to open '%s' for NexRv info write", path);
			return 0;
		end

		// NexRv loads pcinfo as a dense array indexed by
		// (addr - base) / len_bytes. Any 4-byte slot in [base..top]
		// that the cpu_model never visited must still be present in
		// the file or array lookups break. Fill those with a
		// neutral L4 sentinel — the trace will never reference these
		// addresses, so the sentinel type is irrelevant.
		begin
			automatic tip_iaddr_t base = pcs[0];
			automatic tip_iaddr_t top  = pcs[pcs.size() - 1];
			automatic int        n_gap = 0;
			for (tip_iaddr_t a = base; a <= top; a += len_bytes) begin
				if (types_at.exists(a)) begin
					automatic string t = types_at[a];
					if (t == "L" || t == "R") begin
						$fwrite(fd, "%s,%s%0d\n", pc_hex(a), t, len_bytes);
					end else begin
						$fwrite(fd, "%s,%s%0d,%s\n", pc_hex(a), t, len_bytes, pc_hex(targets_at[a]));
					end
				end else begin
					$fwrite(fd, "%s,L%0d\n", pc_hex(a), len_bytes);  // gap-fill sentinel
					n_gap++;
				end
				n_written++;
			end
			if (n_gap > 0)
				$display("*** INFO (%m, line %0d) nexrv_info: %0d gap-fill L sentinels inserted",
					`__LINE__, n_gap);
		end
		$fclose(fd);
		$display("*** INFO (%m, line %0d) nexrv_info saved to %s (%0d entries)",
			`__LINE__, path, n_written);
		return n_written;
	endfunction

	// Execution-ordered list of PCs the cpu_model actually retired (no
	// dedup, no sort, no gap-fill). This is the reference the NexRv
	// decoder output is compared against.
	function automatic int write_expected_pcs(input string path);
		int fd;
		int n_written = 0;
		if (path == "") return 0;
		fd = $fopen(path, "w");
		if (fd == 0) begin
			$error("[cpu_model] failed to open '%s' for expected-PC write", path);
			return 0;
		end
		foreach (event_q[i]) begin
			if (pcinfo_type_str(event_q[i].kind) == "") continue;
			// Instructions retired while instruction tracing was paused are
			// not in the trace, so they are not in the decoded PC stream.
			if (!event_q[i].traced) continue;
			$fwrite(fd, "%s\n", pc_hex(event_q[i].pc));
			n_written++;
		end
		$fclose(fd);
		$display("*** INFO (%m, line %0d) expected_pcs saved to %s (%0d entries)",
			`__LINE__, path, n_written);
		return n_written;
	endfunction

	// Execution-ordered list of data accesses the cpu_model issued.
	// Format per line:  LOAD|STORE,0x<daddr>,<size_bytes>
	// size_bytes is in DECIMAL (1/2/4/8) — same encoding NexRv prints
	// in its data-message decode, so the two are diff-able as-is.
	// Gated on .data_traced like the CTXP MEM records: accesses issued
	// while data tracing is off (set_data_traced(0), e.g. the off-window
	// of the DataTracing re-anchor test) never reach the wire and must
	// not appear in the reference either.
	function automatic int write_expected_data(input string path);
		int fd;
		int n_written = 0;
		if (path == "") return 0;
		fd = $fopen(path, "w");
		if (fd == 0) begin
			$error("[cpu_model] failed to open '%s' for expected-data write", path);
			return 0;
		end
		foreach (event_q[i]) begin
			automatic int unsigned size_bytes = 1 << event_q[i].size;
			if (!event_q[i].data_traced) continue;
			case (event_q[i].kind)
				CPU_LOAD:  begin
					$fwrite(fd, "LOAD,%s,%0d\n", pc_hex(event_q[i].target), size_bytes);
					n_written++;
				end
				CPU_STORE: begin
					$fwrite(fd, "STORE,%s,%0d\n", pc_hex(event_q[i].target), size_bytes);
					n_written++;
				end
				default: ;
			endcase
		end
		$fclose(fd);
		$display("*** INFO (%m, line %0d) expected_data saved to %s (%0d entries)",
			`__LINE__, path, n_written);
		return n_written;
	endfunction

	// ------------------------------------------------------------------
	// Execution-ordered "expected CTXP" reference. Replays the event log
	// the way the encoder + NexRv reference decoder produce CTXP records,
	// so NexRv's CTXP text export can be diffed against it (normalized for
	// the trailing "@ <cycle>" and hex leading zeros; see
	// scripts/decode_and_check.sh --ctxp).
	//
	// Record set (matches NexRv's NexRvCTXP / NexRvDeco mapping):
	//   - instruction control flow (gated on .traced): SYNC at trace entry,
	//     BRANCH_TAKEN / BRANCH_NOTTAKEN / CALL / RETURN / INTERRUPT / RFI;
	//   - data accesses (gated on .data_traced): MEMREAD_n / MEMWRITE_n;
	//   - ACT-CAP DAQ commands (CPU_CSR_WRITE @ ACT_CAP_CMD, sink -> Nexus):
	//     DAQ_DATA / SYNC / DAQ_LAST_PC / MEMx_n / DAQ_COUNTER per command.
	// ------------------------------------------------------------------
	// ACT-CAP command codes (rdl/ct_cs_cpuif.rdl trActCapStCmd_e).
	localparam int unsigned CMD_PC_CURR      = 1;
	localparam int unsigned CMD_PC_CURR_LAST = 2;
	localparam int unsigned CMD_DIRECT_DATA  = 3;
	localparam int unsigned CMD_DATA         = 4;
	localparam int unsigned CMD_DADDR        = 5;
	localparam int unsigned CMD_DATA_DADDR   = 6;
	localparam int unsigned CMD_IFETCH_TH    = 8;
	localparam int unsigned CMD_DATA_RD_TH   = 9;
	localparam int unsigned CMD_DATA_WR      = 10;
	localparam int unsigned CMD_DATA_RD      = 11;
	localparam int unsigned CMD_CF_SYNC      = 12;
	localparam int unsigned CMD_WATCHPOINT   = 14;

	function automatic int write_expected_ctxp(input string path);
		int fd;
		int n_written = 0;
		int unsigned ilen_bytes = 1 << (DEFAULT_ILASTSIZE + 1);   // 32-bit -> 4
		// Captured data-access context, mirroring the composer's Prev* tracking.
		tip_daddr_t      prev_daddr   = '0;
		longint unsigned prev_data    = '0;
		int unsigned     prev_sz_log2 = 0;
		bit              prev_write   = 0;
		tip_iaddr_t      prev_iaddr   = '0;   // last retired instruction PC
		tip_iaddr_t      last_pc_exc  = '0;   // PC before the last exception/interrupt

		if (path == "") return 0;
		fd = $fopen(path, "w");
		if (fd == 0) begin
			$error("[cpu_model] failed to open '%s' for expected-CTXP write", path);
			return 0;
		end

		foreach (event_q[i]) begin
			automatic cpu_event_t e = event_q[i];
			automatic int unsigned bytes;
			automatic string rw;
			case (e.kind)
				CPU_ENTER: begin
					if (e.traced) begin
						$fwrite(fd, "#0:SYNC::0x%0h\n", e.pc); n_written++;
					end
				end
				CPU_BRANCH_TAKEN: begin
					if (e.traced) begin
						$fwrite(fd, "#0:BRANCH_TAKEN:0x%0h:0x%0h\n", e.pc, e.target); n_written++;
					end
					prev_iaddr = e.pc;
				end
				CPU_BRANCH_NOT_TAKEN: begin
					if (e.traced) begin
						$fwrite(fd, "#0:BRANCH_NOTTAKEN:0x%0h:0x%0h\n", e.pc, e.pc + ilen_bytes); n_written++;
					end
					prev_iaddr = e.pc;
				end
				CPU_JUMP, CPU_UNINFERABLE_JUMP: begin
					if (e.traced) begin
						$fwrite(fd, "#0:BRANCH_TAKEN:0x%0h:0x%0h\n", e.pc, e.target); n_written++;
					end
					prev_iaddr = e.pc;
				end
				CPU_CALL, CPU_INDIRECT_CALL: begin
					if (e.traced) begin
						$fwrite(fd, "#0:CALL:0x%0h:0x%0h\n", e.pc, e.target); n_written++;
					end
					prev_iaddr = e.pc;
				end
				CPU_RET: begin
					if (e.traced) begin
						$fwrite(fd, "#0:RETURN:0x%0h:0x%0h\n", e.pc, e.target); n_written++;
					end
					prev_iaddr = e.pc;
				end
				CPU_INTERRUPT, CPU_EXCEPTION, CPU_EXCEPTION_NORETIRE: begin
					last_pc_exc = prev_iaddr;
					if (e.traced) begin
						$fwrite(fd, "#0:INTERRUPT:0x%0h:0x%0h\n", prev_iaddr, e.target); n_written++;
					end
					prev_iaddr = e.target;
				end
				CPU_MRET: begin
					if (e.traced) begin
						$fwrite(fd, "#0:RFI:0x%0h:0x%0h\n", e.pc, e.target); n_written++;
					end
					prev_iaddr = e.pc;
				end
				CPU_LOAD: begin
					if (e.data_traced) begin
						$fwrite(fd, "#0:MEMREAD_%0d:0x%0h:0x%0h\n", 1 << e.size, e.target, e.payload);
						n_written++;
					end
					prev_daddr = e.target; prev_data = e.payload;
					prev_sz_log2 = e.size; prev_write = 0; prev_iaddr = e.pc;
				end
				CPU_STORE: begin
					if (e.data_traced) begin
						$fwrite(fd, "#0:MEMWRITE_%0d:0x%0h:0x%0h\n", 1 << e.size, e.target, e.payload);
						n_written++;
					end
					prev_daddr = e.target; prev_data = e.payload;
					prev_sz_log2 = e.size; prev_write = 1; prev_iaddr = e.pc;
				end
				CPU_CSR_WRITE: begin
					if (e.target == tip_iaddr_t'(ACT_CAP_CMD)) begin
						automatic int unsigned cmd  = e.payload[5:0];
						automatic int unsigned sink = e.payload[7:6];
						automatic longint unsigned dd = e.payload[31:8];
						// sink: 0=NEXUS, 1=AXIS, 2=AXIS_NEXUS, 3=TE. Nexus DAQ
						// records appear only for NEXUS / AXIS_NEXUS.
						if (sink == 0 || sink == 2) begin
							bytes = 1 << prev_sz_log2;
							rw    = prev_write ? "WRITE" : "READ";
							case (cmd)
								CMD_PC_CURR: begin
									if (dd != 0) begin $fwrite(fd, "#0:DAQ_DATA::0x%0h\n", dd); n_written++; end
									$fwrite(fd, "#0:SYNC::0x%0h\n", e.pc); n_written++;
								end
								CMD_PC_CURR_LAST: begin
									if (dd != 0) begin $fwrite(fd, "#0:DAQ_DATA::0x%0h\n", dd); n_written++; end
									$fwrite(fd, "#0:DAQ_LAST_PC::0x%0h\n", last_pc_exc); n_written++;
									$fwrite(fd, "#0:SYNC::0x%0h\n", e.pc); n_written++;
								end
								CMD_DIRECT_DATA: begin
									$fwrite(fd, "#0:DAQ_DATA::0x%0h\n", dd); n_written++;
								end
								CMD_DATA: begin
									if (dd != 0) begin $fwrite(fd, "#0:DAQ_DATA::0x%0h\n", dd); n_written++; end
									$fwrite(fd, "#0:MEM%s_%0d::0x%0h\n", rw, bytes, prev_data); n_written++;
								end
								CMD_DADDR: begin
									if (dd != 0) begin $fwrite(fd, "#0:DAQ_DATA::0x%0h\n", dd); n_written++; end
									$fwrite(fd, "#0:MEM%s_0:0x%0h:\n", rw, prev_daddr); n_written++;
								end
								CMD_DATA_DADDR: begin
									if (dd != 0) begin $fwrite(fd, "#0:DAQ_DATA::0x%0h\n", dd); n_written++; end
									$fwrite(fd, "#0:MEM%s_%0d:0x%0h:0x%0h\n", rw, bytes, prev_daddr, prev_data); n_written++;
								end
								CMD_IFETCH_TH:  begin $fwrite(fd, "#0:DAQ_COUNTER:0x0:0x%0h\n", 0 << 19); n_written++; end
								CMD_DATA_RD_TH: begin $fwrite(fd, "#0:DAQ_COUNTER:0x0:0x%0h\n", 1 << 19); n_written++; end
								CMD_DATA_WR:    begin $fwrite(fd, "#0:DAQ_COUNTER:0x0:0x%0h\n", 2 << 19); n_written++; end
								CMD_DATA_RD:    begin $fwrite(fd, "#0:DAQ_COUNTER:0x0:0x%0h\n", 3 << 19); n_written++; end
								CMD_CF_SYNC:    begin $fwrite(fd, "#0:SYNC::0x%0h\n", e.pc); n_written++; end
								// Watchpoint (P4): the encoder emits TCODE 15 with
								// WPHIT = DirectData[15:0] AND trWpMask.WEM, and the
								// decoder exports it as a WATCHPOINT record. The mask
								// lives in a CSR the cpu_model does not see, so this
								// oracle assumes the all-ones mask (the tests that
								// compare CTXP run with WEM = 0xFFFF); a masked leg
								// must not be diffed against this reference.
								CMD_WATCHPOINT: begin
									if ((dd & 24'hFFFF) != 0) begin
										$fwrite(fd, "#0:WATCHPOINT::0x%0h\n", dd & 24'hFFFF); n_written++;
									end
								end
								default: ;
							endcase
						end
						// The csrw itself is a CSR_READ_WRITE data access: it
						// updates the captured context for the next DAQ command.
						prev_daddr = tip_daddr_t'(ACT_CAP_CMD); prev_data = e.payload;
						prev_sz_log2 = 2 /* word */; prev_write = 1;
					end
					prev_iaddr = e.pc;
				end
				CPU_RUN: prev_iaddr = e.pc;
				default: ;
			endcase
		end
		$fclose(fd);
		$display("*** INFO (%m, line %0d) expected_ctxp saved to %s (%0d records)",
			`__LINE__, path, n_written);
		return n_written;
	endfunction

	// Auto-write on simulation end if a path was supplied.
	final begin
		if (NEXRV_INFO_PATH    != "") void'(write_nexrv_info(NEXRV_INFO_PATH));
		if (EXPECTED_PCS_PATH  != "") void'(write_expected_pcs(EXPECTED_PCS_PATH));
		if (EXPECTED_DATA_PATH != "") void'(write_expected_data(EXPECTED_DATA_PATH));
		if (EXPECTED_CTXP_PATH != "") void'(write_expected_ctxp(EXPECTED_CTXP_PATH));
	end

	// ------------------------------------------------------------------
	// Debug print
	// ------------------------------------------------------------------
	function automatic void dump_events();
		$display("[cpu_model] event log (%0d entries):", event_q.size());
		foreach (event_q[i]) begin
			$display("  %4d: %-18s pc=%s target=%s payload=%016x size=%0d",
				i,
				event_kind_str(event_q[i].kind),
				pc_hex(event_q[i].pc),
				pc_hex(event_q[i].target),
				event_q[i].payload,
				event_q[i].size);
		end
	endfunction

endmodule : cpu_model

`default_nettype wire
