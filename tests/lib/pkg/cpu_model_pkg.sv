// vim: set ts=4 et:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
/**
* Copyright (c) 2026 Accemic Technologies GmbH
* SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial
*
* @brief    Types for the scripted CPU model that drives the TIP interface.
*
* @details
*   `cpu_model` (tests/lib/cpu_model.sv) presents a task-based API
*   (.enter(), .run(), .branch_taken(), .call_to(), .ret(), .load(),
*   .store(), .interrupt(), ...) that mimics a RISC-V core.
*
*   Each task does two things:
*     (1) drives the encoder's TIP interface with the right itype /
*         iaddr / daddr / ... signals;
*     (2) appends a high-level event record to an in-sim event queue
*         that the scoreboard consumes.
*
*   The fact that the encoder's decoded output and the cpu_model's
*   event queue must agree IS the test. No real binary, no instruction
*   memory, no DPI required.
*/

package cpu_model_pkg;

	import tip_pkg::*;

	typedef enum int {
		CPU_ENTER,                  // tracing region begins
		CPU_EXIT,                   // tracing region ends
		CPU_RUN,                    // a single linear instruction retired
		CPU_JUMP,                   // direct (inferable) jump
		CPU_BRANCH_TAKEN,
		CPU_BRANCH_NOT_TAKEN,
		CPU_CALL,                   // inferable call (push return addr)
		CPU_TAIL_CALL,              // inferable tail-call (`jal x0, target` / `j target` ending
		                            // a function — no return address pushed; from the decoder's
		                            // perspective a CD PCInfo entry like a regular call, since
		                            // the target is recoverable from the program image).
		CPU_INDIRECT_CALL,          // indirect (function-pointer) call, jalr-like (push return addr)
		CPU_RET,                    // return (pop)
		CPU_UNINFERABLE_JUMP,       // indirect / computed jump
		CPU_INTERRUPT,              // interrupt co-reported with the trap-source
		                            // instruction retiring (iretire=1 + itype=INTERRUPT
		                            // in the same cycle). trap pc DID retire, occupies
		                            // an L PCInfo slot.
		CPU_INTERRUPT_ASYNC,        // pure asynchronous-marker interrupt
		                            // (iretire=0 + itype=INTERRUPT — spec "the number
		                            // of instructions retired may be zero" case). The
		                            // trap fired BEFORE cur_pc retired, so cur_pc is
		                            // re-executed after mret. No PCInfo slot is
		                            // emitted by this event; the slot is filled in
		                            // when cur_pc retires after mret.
		CPU_EXCEPTION,              // synchronous exception trap
		CPU_MRET,                   // exception/interrupt return
		CPU_LOAD,                   // data load retired
		CPU_STORE,                  // data store retired
		CPU_CSR_WRITE,              // CSR write — drives HSI events
		CPU_CSR_READ
	} cpu_event_kind_e;

	typedef struct {
		cpu_event_kind_e kind;
		tip_iaddr_t      pc;        // PC at which the event happened
		tip_iaddr_t      target;    // jump/call/branch target; exception handler; load/store addr; csr addr
		longint unsigned payload;   // data, cause, csr value, etc.
		int unsigned     size;      // for loads/stores (2^size bytes)
		bit              traced;    // 1 if instruction tracing was active when this retired;
		                            // untraced instructions are excluded from the expected-PC reference
		bit              data_traced; // 1 if data tracing was active when this retired;
		                            // gates whether loads/stores appear as CTXP MEM records
	} cpu_event_t;

	function automatic string event_kind_str(cpu_event_kind_e k);
		case (k)
			CPU_ENTER:               return "ENTER";
			CPU_EXIT:                return "EXIT";
			CPU_RUN:                 return "RUN";
			CPU_JUMP:                return "JUMP";
			CPU_BRANCH_TAKEN:        return "BRANCH_TAKEN";
			CPU_BRANCH_NOT_TAKEN:    return "BRANCH_NOT_TAKEN";
			CPU_CALL:                return "CALL";
			CPU_TAIL_CALL:           return "TAIL_CALL";
			CPU_INDIRECT_CALL:       return "INDIRECT_CALL";
			CPU_RET:                 return "RET";
			CPU_UNINFERABLE_JUMP:    return "UNINFERABLE_JUMP";
			CPU_INTERRUPT:           return "INTERRUPT";
			CPU_INTERRUPT_ASYNC:     return "INTERRUPT_ASYNC";
			CPU_EXCEPTION:           return "EXCEPTION";
			CPU_MRET:                return "MRET";
			CPU_LOAD:                return "LOAD";
			CPU_STORE:               return "STORE";
			CPU_CSR_WRITE:           return "CSR_WRITE";
			CPU_CSR_READ:            return "CSR_READ";
			default:                 return "UNKNOWN";
		endcase
	endfunction

endpackage : cpu_model_pkg
