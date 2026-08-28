// SPDX-FileCopyrightText: 2025 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// vim: set ts=4 noet:
// -*- indent-tabs-mode: t; tab-width: 4 -*-
`default_nettype none

/**
 * @author   Alexander Weiss <aweiss@accemic.com>, Albert Schulz <aschulz@accemic.com>, Alexander Lange <alange@accemic.com>
 *
 * @brief    CEDARtools.TraceEncoder Package
 */

package ct_pkg;

	import ct_cs_cpuif_pkg::*;

	// ------------------------------------------------------------------
	// Build profile (generic, vendor-neutral; ct_pkg compiles first, the
	// other packages mirror these switches). They select which feature
	// groups exist in the netlist; message/field widths, FIFO payloads and
	// the ACT delay line derive from them, so a slim profile shrinks the
	// datapath automatically. Defaults = everything enabled (identical
	// behavior to the historical fixed configuration).
	//   CT_EN_DAQ         : DAQ / ACT-CAP instrumentation messages (the
	//                       only consumer of >64-bit field payloads)
	//   CT_EN_DATA_TRACE  : data-trace messages + filters
	//   CT_EN_ACT         : ACT-CAP/ACT-ST watchpoint/cross-trigger blocks
	//   CT_EN_*_ (suite)  : per-feature switches for the Accemic compression
	//                       suite; each feature's logic (and its model
	//                       storage) consts away individually when 0.
	//                       CT_EN_COMPRESSION is the derived OR -- kept as
	//                       the collective gate for shared plumbing (e.g.
	//                       the composer return stack serves only IR).
	//   CT_SINGLE_CLOCK   : integrator drives tip/proc/atb from ONE clock
	//                       (the ATB/AXIS handshake typically ends in an
	//                       AXI(S) FIFO owning the real clock transfer) --
	//                       internal gray-pointer CDC FIFOs become plain
	//                       single-clock FIFOs
	//   CT_TS_WIDTH       : internal/wire timestamp width (64 = historical
	//                       behavior). Narrowing slims the eTIP FIFO entry
	//                       and every message field array; with timestamps
	//                       DISABLED (trTsControl.Enable=0) the emitted
	//                       byte stream is identical for any value here
	//                       (the TSTAMP field carries 0 either way).
	// ------------------------------------------------------------------
	localparam bit CT_EN_DAQ         = 1;
	localparam bit CT_EN_DATA_TRACE  = 1;
	localparam bit CT_EN_ACT         = 1;
	localparam bit CT_EN_FILTERS     = 1; // address comparator filters (cf/df qualifiers)
	//   CT_EN_FILTER_SYNC : anchoring for the CF filter (W2). Without it a
	//                       filtered stream is not decodable, and that is a
	//                       measurement, not an opinion: with a context
	//                       filter selected, the cv64a6 two-process run
	//                       (sim/cva6_rv64/run_cva6_ctx_e2e.ps1) produced a
	//                       stream with NOT ONE ProgTraceSync in it -- not
	//                       even the trace-enable anchor -- and NexRv
	//                       decoded 0 of 218 instructions. Two holes, one
	//                       switch:
	//                         (a) the sync generator anchors on any retire
	//                             (sync_anchor_ok = tip.iretire), but the CF
	//                             slot that carries the verdict only exists
	//                             for a QUALIFIED retire -- a verdict landing
	//                             on a filtered-out instruction was dropped.
	//                             It is now held for the next qualified beat.
	//                         (b) region entry/exit produced nothing at all,
	//                             although ct_L23_preproc_cf has computed
	//                             region_entered/region_exited since the
	//                             beginning and routes them into the composer.
	//                             Exit now takes the trace-off correlation
	//                             (TCODE 33, EVCODE=Program Trace Disabled --
	//                             the SAME slot as DoCorrDisable, so the
	//                             proven ETIP_PAR_MSG bound is untouched),
	//                             entry becomes a TRACE_ENABLE sync (SYNC=5).
	//                       No new message type, no CAPS bit, no decoder
	//                       change: a filter pause is on the wire exactly like
	//                       a software trace pause, which is what it is.
	//                       Byte neutrality is STRUCTURAL, not measured luck:
	//                       the block is gated on trTeInstFilters != 0, and
	//                       that register resets to 0 ("trace all"). There is
	//                       deliberately no runtime opt-out -- the behaviour
	//                       it replaces is an undecodable stream, not an
	//                       alternative mode. Requires CT_EN_FILTERS.
	//                       Full-profile default 1; slim profiles follow
	//                       CT_EN_FILTERS.
	localparam bit CT_EN_FILTER_SYNC = 1;
	// Encoder-level event groups: generic
	// event ports (tip.debug_mode / tip.evti / tip.power_down -- integrator
	// contract; adapters without the signal tie it 0). Full-profile default
	// 1; slim profiles set 0 (the whole event path consts away, tie-0 keeps
	// the off-netlist LUT-neutral).
	//   CT_EN_DEBUG_EVENTS : debug-mode handling -- no trace while
	//                        tip.debug_mode=1, Correlation EVCODE=0 on entry
	//                        (N-Trace Required), SYNC=3 on exit (Required)
	//   CT_EN_POWER_EVENTS : Correlation EVCODE=1 on power-down entry,
	//                        SYNC=9 after power-down exit (both optional)
	//   CT_EN_EVTI         : external trigger marker -- SYNC=0 on a
	//                        tip.evti pulse while tracing (optional)
	localparam bit CT_EN_DEBUG_EVENTS = 1;
	localparam bit CT_EN_POWER_EVENTS = 1;
	localparam bit CT_EN_EVTI         = 1;
	//   CT_EN_TRIG_SYNC   : watchpoint/trigger marker -- a tip.trigger pulse
	//                       upgrades the next retire to SYNC=6 (Trace Event)
	//                       while trTeControl.InstTrigEnable is set
	//   CT_EN_SEQ_SYNC    : full sync with SYNC=4 instead of the RCODE-0
	//                       pre-drain when trTeControl.InstSeqSyncEnable is
	//                       set (N-Trace binds SYNC=4 to BTM -- documented
	//                       Accemic extension, runtime reset 0)
	//   CT_EN_OWNERSHIP   : Ownership messages (TCODE 2) on context events /
	//                       privilege changes / after every sync while
	//                       trTeControl.Context is set (N-Trace 7.1)
	//   CT_EN_CONFIG_MSG  : vendor config message TCODE 58, which makes the
	//                       stream self-describing; emission mode in
	//                       trTeControl.SendConfig (full-profile reset
	//                       CFG_ONCE). Payload layout: see the
	//                       config-message constants further down.
	localparam bit CT_EN_TRIG_SYNC    = 1;
	localparam bit CT_EN_SEQ_SYNC     = 1;
	localparam bit CT_EN_OWNERSHIP    = 1;
	localparam bit CT_EN_CONFIG_MSG   = 1;
	//   CT_EN_QUOTA_SYNC  : trace-output quota synchronization (P2) -- makes
	//                       the two InstSyncMode cadence modes measured on
	//                       the TRACE OUTPUT itself functional: 1 =
	//                       ITR_SYNC_TRACE_MSG (count on-wire messages), 4 =
	//                       ITR_SYNC_TRACE_BYTES (count bytes as accepted on
	//                       ATB, whole beats incl. alignment padding and
	//                       flush idle beats). Dedicated quota counters in
	//                       the egress modules (mseo_mdo_formatter /
	//                       compact_packer / te_packetizer) raise a HELD
	//                       overflow level once 2^(trTeInstSyncMax+4) is
	//                       reached; the sync generator turns it into a
	//                       PERIODIC sync (SYNC=2) and rearms the counters
	//                       through the crossed SyncCntClr. Compiled out ->
	//                       modes 1/4 stay writable but inert (exactly the
	//                       pre-P2 behaviour, no WARL clamp -- structure
	//                       stability like trTeProtocolSel) and the
	//                       counters/CDC trim away (byte-neutral). Full-
	//                       profile default 1; see
	//                       doc/integration.adoc#feature-flags.
	localparam bit CT_EN_QUOTA_SYNC   = 1;
	//   CT_EN_DF_ADDR_COMPRESS : data-trace address compression (P3) --
	//                       makes trTeDataControl.DataAddrCompress mode 1
	//                       (XOR) functional: the DF address leaves as the
	//                       XOR against the PREVIOUS data-trace message's
	//                       address (byte-granular -- no PC shift), and the
	//                       first DF after a re-anchor event (any
	//                       synchronizing CF emission, a DataTracing rising
	//                       edge, any ERROR emission, reset) is upgraded to
	//                       the synchronizing form TCODE 13/14
	//                       (DataWrite/ReadSync) carrying the FULL address,
	//                       re-seating the reference on both sides. Modes
	//                       2/3 (DIFF/dynamic) stay unimplemented
	//                       (sign/encodability -- see doc); the WARL
	//                       wrapper legalizes a 2/3 write to 0. Requires
	//                       CT_EN_DATA_TRACE (elaboration guard in
	//                       ct_L2_nexus_formatter; the compact packer is
	//                       CF-only anyway). Runtime reset DTR_ADDR_FULL
	//                       keeps the wire stream byte-identical to the
	//                       pre-P3 reference family; compiled out -> the
	//                       reference register/flag trim away and the mode
	//                       field is WARL-clamped to FULL (byte-neutral).
	//                       Full-profile default 1; see
	//                       doc/integration.adoc#feature-flags.
	localparam bit CT_EN_DF_ADDR_COMPRESS = 1;
	//   CT_EN_DEVICE_ID   : Device ID message (TCODE 1, IEEE-ISTO 5001
	//                       4.3.2) -- a single static identifier message at
	//                       trace start, so a stock Nexus decoder learns WHICH
	//                       device produced the stream without any
	//                       out-of-band setup. The value is the ct_encoder
	//                       parameter CT_DEVICE_ID (per INSTANCE, layout per
	//                       ISTO Table B-5: RN | PN | MID); the emission mode
	//                       is trTeControl.SendDeviceId (DID_NONE /
	//                       DID_ONCE). CTTE emits the ID as a VENDOR_VARIABLE
	//                       field (leading zeros stripped) instead of the
	//                       "Fixed 32" of Table 4-7 -- a documented deviation
	//                       (doc/trace-format.adoc), taken because a fixed
	//                       32-bit field would need a SRC special case in
	//                       both egress paths and in the decoder's table
	//                       mechanism. N-Trace 1.0 does NOT adopt TCODE 1
	//                       (Table 9), so the runtime reset is DID_NONE --
	//                       deliberately different from SendConfig -- and the
	//                       default stream stays strictly N-Trace 1.0.
	//                       Compiled out -> the message, the payload wiring
	//                       and the eTIP slot trim away, SendDeviceId reads
	//                       DID_NONE (byte-neutral). Full-profile default 1;
	//                       see doc/integration.adoc#feature-flags.
	localparam bit CT_EN_DEVICE_ID    = 1;
	//   CT_EN_WATCHPOINT_MSG : Watchpoint message (TCODE 15, IEEE-ISTO 5001
	//                       4.3.23) -- says WHICH watchpoint fired instead of
	//                       the anonymous SYNC=6 trigger marker. Source is
	//                       the new ACT-ST command ACT_CAP_ST_WATCHPOINT
	//                       (watchpoints[] table entry or CPU CSR 0x0B10):
	//                       WPHIT = Cmd.DirectData[15:0] AND trWpMask.WEM,
	//                       i.e. software owns the slot<->bit convention and
	//                       the WEM mask decides which slots may report.
	//                       Reset WEM = 0 masks every hit, so an existing
	//                       build stays byte-identical until software opts
	//                       in (structural byte-neutrality). Requires
	//                       CT_EN_ACT (the ACT-ST command path IS the hit
	//                       source; elaboration guard in the composer).
	//                       Compiled out -> command decode, payload and the
	//                       eTIP slot trim away and the WEM field reads 0.
	//                       Full-profile default 1; see
	//                       doc/integration.adoc#feature-flags.
	localparam bit CT_EN_WATCHPOINT_MSG = 1;
	//   CT_EN_BTM         : Branch Trace Messaging mode (N-Trace InstMode=3,
	//                       TCODE 3 DirectBranch / TCODE 4 IndirectBranch --
	//                       one message per taken/indirect branch instead of
	//                       accumulated history). The SECOND N-Trace 1.0
	//                       instruction-trace mode next to HTM (InstMode=6):
	//                       with it CTTE implements the full N-Trace 1.0
	//                       message set (both modes settable, Table 8
	//                       "3 OR 6" fully satisfied -- no longer HTM-only).
	//                       Runtime-selected via the WARL trTeControl.InstMode
	//                       (legalized to accept 3 only when CT_EN_BTM=1);
	//                       the compression suite (RH/RB/JTC/BP/RptInstr) is
	//                       HTM-only and inert in BTM mode by construction.
	//                       Compiled out -> InstMode WARL rejects 3 (HTM-only,
	//                       exactly the pre-seq-24 behaviour). Voll-default 1;
	//                       slim/featparity profile intent 0 (HTM is the
	//                       bandwidth-lean choice for the size-constrained
	//                       profiles) -- the v2 measurement profiles
	//                       (phase_d_matrix_v2.sh) keep it at 1; see
	//                       doc/integration.adoc#feature-flags.
	localparam bit CT_EN_BTM          = 1;
	//   CT_EN_TRIG_REGS   : TCI trigger CONFIGURATION register block (P7,
	//                       trTeTrigExtInControl @te:0x054). CTTE owns exactly
	//                       ONE external trigger input -- the generic
	//                       tip.trigger event port -- so external trigger
	//                       input #0 exists and #1..7 read the TCI-prescribed
	//                       "does not exist" constant 0 (Table 20). Action
	//                       encoding per TCI Table 20: 0 = no action, 2 =
	//                       trace-on (trTeInstTracing 0->1), 3 = trace-off
	//                       (1->0), 4 = trace-notify (the existing SYNC=6
	//                       Trace-Event marker). Actions 2/3 are additionally
	//                       gated by trTeControl.InstTrigEnable exactly as the
	//                       TCI text prescribes; action 4 is a SECOND source of
	//                       the same marker one-shot, so a build with both
	//                       InstTrigEnable=1 and Action0=4 still emits exactly
	//                       ONE marker (de-dup by construction -- the pending
	//                       latch, not a counter). The historical
	//                       InstTrigEnable behaviour is UNCHANGED (AW decision
	//                       E-P7-2, 2026-08-04): this switch only ADDS the
	//                       register-driven routing. 4 = trace-notify needs
	//                       CT_EN_TRIG_SYNC (it reuses that marker path) and
	//                       WARL-legalizes to 0 without it. The debug-trigger
	//                       register (0x050) and the trigger OUTPUT register
	//                       (0x058) stay read-only 0 -- CTTE has neither a
	//                       debug-trigger interface nor a trigger output port,
	//                       and TCI Table 19/21 make "fixed at 0" the
	//                       prescribed answer for a non-existent trigger.
	//                       Compiled out -> Action0 becomes a read-only
	//                       constant 0, its storage and the routing trim away
	//                       (byte-neutral: the reset value is "no action").
	//                       No CAPS bit: the block adds no message type and no
	//                       field to the wire format -- the on-wire effect of a
	//                       notify is the SYNC=6 marker already advertised by
	//                       CAPS.13 (TRIG_SYNC), and trace-on/off is
	//                       indistinguishable from a software-driven
	//                       InstTracing change. Discovery is the register block
	//                       itself (WARL read-back). Full-profile default 1;
	//                       see doc/integration.adoc#feature-flags.
	localparam bit CT_EN_TRIG_REGS    = 1;
	//   CT_EN_DF_DROP     : data-trace drop policy (P7, N-Trace/TCI
	//                       trTeDataControl.DataDropEna) -- "allow dropping
	//                       data trace to avoid instruction trace overflows".
	//                       A watermark on the eTIP CVS FIFO fill level
	//                       (CT_DF_DROP_WATERMARK) suppresses the DF eTIP arms
	//                       BEFORE the FIFO runs full, so the instruction
	//                       trace keeps its bandwidth instead of losing whole
	//                       beats. The loss is announced with its OWN
	//                       single-message marker: ERROR (TCODE 8) /
	//                       ETYPE=QUEUE_OVERRUN / ECODE=0x02 (DF_MSG_LOST) --
	//                       deliberately WITHOUT the SYNC=7 re-anchor of the
	//                       generic eTIP overflow path, because forcing an
	//                       instruction re-anchor per dropped data message
	//                       would be the exact opposite of the feature's
	//                       promise. One marker per drop EPISODE (rearmed when
	//                       the fill falls back below the watermark). No new
	//                       wire format: ERROR/ECODE is standard N-Trace, so
	//                       every decoder PARSES the marker unchanged. The
	//                       SEMANTICS are not free, though (measured on
	//                       tests/data/06_df_drop): a decoder that treats any
	//                       Error as a full desync throws away exactly the
	//                       instruction trace this marker promises is intact
	//                       -- 269 of 760 PCs with the pre-P7 NexRv pin. The
	//                       reference decoder now scopes ECODE=0x02 to the
	//                       data-trace reference.
	//                       Runtime reset DataDropEna=0 keeps every existing
	//                       stream byte-identical; compiled out -> DataDropEna
	//                       is a read-only constant 0 and the watermark
	//                       compare trims away. Requires CT_EN_DATA_TRACE
	//                       (elaboration guard in the composer). CAPS bit 22.
	//                       Full-profile default 1; see
	//                       doc/integration.adoc#feature-flags.
	localparam bit CT_EN_DF_DROP      = 1;
	//                       (The fill level the policy trips at is
	//                       CT_DF_DROP_WATERMARK, derived from
	//                       ETIP_CVS_FIFO_DEPTH further down.)
	//   CT_EN_SYNC_STATUS : diagnostic RO CSR trTeSyncStatus.SyncReqSource
	//                       (@te:0xE08, A2/E2). Compiled out -> the WHOLE
	//                       register is OMITTED from the generated regblock
	//                       (RDL `ifndef` around the reg definition -- PeakRDL
	//                       never generates its address-decode/readback), the
	//                       wrapper gates the matching hwif assignment. Pure
	//                       diagnostic: on-wire stream identical (every explicit
	//                       request uses the single vendor SYNC code 14).
	//                       Full-profile default 1; slim-profile intent 0 --
	//                       the v2 measurement profiles (phase_d_matrix_v2.sh)
	//                       keep it at 1; see doc/integration.adoc#feature-flags.
	localparam bit CT_EN_SYNC_STATUS  = 1;
	//   CT_EN_INST_SYNC_REQ : explicit sync request over the TE register
	//                       (P8/G11, TCI trTeControl.InstSyncReq bit 27). The
	//                       field has always existed and always auto-cleared;
	//                       what was missing is a consumer -- writing 1 was
	//                       accepted and did nothing. With the switch on, the
	//                       write raises a request that the sync generator
	//                       serves on the first QUALIFYING retire with the same
	//                       on-wire code as every other explicit request:
	//                       SYNC=14 (NEXUS_SYNC_REQ). It is the THIRD source of
	//                       the one request path, next to the ACT-CAP CF_SYNC
	//                       command and the ATB sync-request input, and unlike
	//                       the latter it is NOT gated on an InstSyncMode: the
	//                       field itself is the trigger, in every cadence mode.
	//                       Crossing: the write is a one-cycle wb_clk pulse,
	//                       and a pulse alone cannot cross safely (two of them
	//                       closer than one tip_clk period cancel in a toggle
	//                       synchronizer). It is therefore PACED, not held:
	//                       ct_sync_req_pacer launches one request at a time
	//                       and waits for the sync generator's ack (crossed
	//                       back as a strobe) before launching the next, so
	//                       two launches are always a full round trip apart.
	//                       A held level was tried first and discarded: the
	//                       signal_ack_lock_fsm the ATB request uses needs to
	//                       see its input FALL before it rearms, so a write in
	//                       the ack cycle would either wedge it for ever or be
	//                       lost. That pacing is what makes the two gate
	//                       promises provable (formal P-SYNC-9/10, which
	//                       instantiate the pacer itself): no request is lost
	//                       in the crossing, and none is served twice.
	//                       Depth is one in flight plus ONE remembered: a
	//                       write arriving while a request is outstanding is
	//                       launched after the ack and gets its OWN sync
	//                       message (measured: two writes back to back -> 2
	//                       SYNC=14); only a write arriving when one is
	//                       already queued collapses into it (three writes ->
	//                       still 2). A request placed while instruction
	//                       tracing is paused is DEFERRED, not dropped (unlike
	//                       the hardware event one-shots) -- after the resume
	//                       anchor (SYNC=5) it is served on the next retire.
	//                       Diagnosis: trTeSyncStatus.SyncReqSource reports the
	//                       new source value 4 (SYNC_REQ_TE), kept distinct
	//                       from 1 (SYNC_REQ_CSR = the hart's own ACT-CAP
	//                       CF_SYNC) because the two requesters are different
	//                       actors -- the traced hart vs the external control
	//                       bus. No CAPS bit: the feature adds neither a
	//                       message type nor a wire field (SYNC=14 exists and
	//                       is already produced by two other sources), so a
	//                       decoder learns nothing from one; the price, stated
	//                       openly, is that there is no STATIC discovery -- the
	//                       field is write-only and always reads back 0 (RDL
	//                       `sw = w; singlepulse;`), so software
	//                       probes the feature functionally via SyncReqSource.
	//                       Compiled out -> the pending flag, the handshake and
	//                       the latch trim away and the write is inert again,
	//                       exactly the pre-P8 behaviour (and the reset
	//                       configuration is byte-identical either way: nothing
	//                       happens until software writes the bit).
	//                       Full-profile default 1; see
	//                       doc/integration.adoc#feature-flags.
	localparam bit CT_EN_INST_SYNC_REQ = 1;
	// Config message v1: format version and the structural sizing constants
	// advertised in payload field P3.
	// These constants are the single source of truth -- the implementing
	// modules (composer return stack, msg_gen JTC/BP tables) consume them,
	// so the advertised values can never drift from the built hardware.
	localparam logic [3:0]  CT_CFGMSG_VER      = 4'd1;
	localparam int unsigned CT_RET_STACK_DEPTH = 16;  // implicit-return stack slots
	localparam int unsigned CT_JTC_ENTRIES     = 64;  // jump-target cache entries
	localparam int unsigned CT_BP_ENTRIES      = 512; // branch-predict table entries
	// Compression suite, per feature:
	localparam bit CT_EN_IMPLICIT_RETURN  = 1; // trTeInstFeatures.InstEnImplicitReturn
	localparam bit CT_EN_REPEATED_HISTORY = 1; // trTeInstFeatures.InstEnRepeatedHistory
	localparam bit CT_EN_WIDE_ICNT        = 1; // trTeInstFeatures.InstEnWideIcnt
	localparam bit CT_EN_REPEAT_BRANCH    = 1; // trTeInstFeatures.InstEnRepeatBranch
	localparam bit CT_EN_JTC              = 1; // trTeInstFeatures.InstEnJumpTargetCache
	localparam bit CT_EN_BP               = 1; // trTeInstFeatures.InstEnBranchPrediction
	// IBHS (TCODE 29, IndirectBranchHistorySync -- N-Trace Table 9 standard
	// message: synchronizing messages CARRY the pending branch
	// history instead of pre-flushing it as ResourceFull(RCODE=1) -- one
	// message where two went before. Runtime enable
	// trTeInstFeatures.InstEnIbhs (reset 0 = historical two-message form).
	localparam bit CT_EN_IBHS             = 1;
	// RepeatInstruction (TCODE 31/32): single-instruction
	// spin-loop compression (a TAKEN_BRANCH targeting its own address).
	// Iterations after the first are counted instead of emitting one HIST
	// bit each; the run closes as ONE RepeatInstruction message carrying
	// R-CNT. NOTE: 31/32 are IEEE-ISTO-5001-2012 messages (4.3.14/15); in
	// N-Trace 1.0 Table 9 these TCODEs are "Reserved for future
	// extensions" -- hence the runtime enable trTeInstFeatures.
	// InstEnRepeatInstr resets to 0 (default stream stays strictly
	// N-Trace-1.0; same pattern as the BP/JTC vendor features).
	localparam bit CT_EN_REPEAT_INSTR     = 1;
	localparam bit CT_EN_COMPRESSION = CT_EN_IMPLICIT_RETURN | CT_EN_REPEATED_HISTORY
	                                 | CT_EN_WIDE_ICNT | CT_EN_REPEAT_BRANCH
	                                 | CT_EN_JTC | CT_EN_BP | CT_EN_IBHS
	                                 | CT_EN_REPEAT_INSTR;
	localparam bit CT_SINGLE_CLOCK   = 0;
	localparam int unsigned CT_TS_WIDTH = 64;
	// Architectural address width of the attached hart (RISC-V XLEN). 32 =
	// historical behaviour; 64 widens the WHOLE address path -- the TIP
	// instruction/data address, the Nexus F-ADDR/U-ADDR fields, the address
	// comparators, the JTC/BP models and the eTIP payload. It is a SYNTHESIS
	// parameter, not a runtime mode: a decoder cannot derive the width from a
	// variable-length address field, so the netlist advertises it on-wire
	// through the config message (CAPS bit 23 ADDR64, CT_ADDR64 below).
	//
	// At 32 every downstream width, constant and fold reduces to exactly the
	// historical expression, so the emitted byte stream is identical (the
	// REF_FINAL family selection sees the same CAPS word -- ADDR64 = 0).
	// Only 32 and 64 are legal; ct_encoder checks it at elaboration.
	localparam int unsigned CT_XLEN = 32;
	// Derived, single source of truth for "this netlist carries 64-bit
	// addresses" -- CAPS bit 23 and every width expression read THIS, never
	// a second switch that could disagree with CT_XLEN.
	localparam bit CT_ADDR64 = (CT_XLEN == 64);
	// Width of the TIP context bus (tip._context -> tip_pkg::TIP_CONTEXT_WIDTH).
	// 2 = historical behaviour. It is the width of the CORE-side context
	// identifier the integrator feeds in, not a wire field: the Ownership
	// message carries the value in nexus_process_t.PROCESS, which is 44 bits
	// wide and leaves the encoder as a VENDOR_VARIABLE field with leading
	// zeros stripped. A decoder therefore needs NO announcement of this width
	// (unlike CT_XLEN / CAPS.23, where a variable-length address field cannot
	// tell a 40-bit address from a 40-bit-significant 64-bit one) -- the
	// PROCESS field is self-delimiting and the whole value is on the wire.
	//
	// Sized for the identifier the attached hart actually has:
	//   2  historical / cores without a context register
	//   16 RISC-V satp.ASID (Sv39/Sv48, RV64 -- CVA6Cfg.ASID_WIDTH=16)
	//   9  RISC-V satp.ASID (Sv32, RV32)
	// Above 44 the value would be truncated SILENTLY in the composer's
	// NEXUS_MSG_PROCESS_WIDTH'(tip._context) cast, so ct_encoder refuses it at
	// elaboration.
	//
	// Byte neutrality: at 2 every expression reduces to the historical one.
	// Beyond that the width only becomes visible on the wire when
	// trTeControl.Context is set AND the integrator drives a value that does
	// not fit in 2 bits -- with the reset configuration (Context=0) no
	// Ownership message is emitted at all.
	localparam int unsigned CT_CONTEXT_WIDTH = 2;
	// Block ingress (R1.3 / gap X1): accept MORE THAN ONE retired
	// instruction per tip beat. 0 = historical single-retirement (SR)
	// ingress -- `tip.iretire` is a one-bit STROBE and a beat carries at
	// most one instruction, so a superscalar hart (cv64a6 with
	// NrCommitPorts=2, dual-issue cv32a65x) cannot be attached without
	// serialising its commit stream. 1 switches `tip.iretire` to the
	// meaning the RISC-V trace ingress port actually gives it: the NUMBER
	// OF HALFWORDS retired by the block this beat reports.
	//
	// The block form is not an Accemic invention, it is what the ingress
	// definition prescribes and what the reference core emits. In CVA6's
	// ITI (`corev_apu/instr_tracing/ITI/cva6_iti/block_retirement.sv`) the
	// per-commit-port systolic stage accumulates `counter_o += compressed
	// ? 1 : 2` and closes the block at the first non-linear instruction:
	//   iretire   = halfwords of the whole block
	//   iaddr     = address of the FIRST instruction of the block
	//   ilastsize = log2(halfwords) of the LAST instruction
	//   itype     = termination type of the block
	// so the instruction `itype` talks about sits at
	//   iaddr + 2*(iretire - (1 << ilastsize))
	// and the block's successor at iaddr + 2*iretire. tip_pkg derives all
	// three (TipBeatHalfwords / TipLastIaddr / TipBlockNextIaddr) from the
	// switch; with it at 0 every one of them constant-folds to exactly the
	// historical expression, so an OFF build carries no block logic at all
	// and byte neutrality is structural.
	//
	// The NETLIST is not bit-for-bit the pre-R1.3 one, and that number is
	// measured rather than asserted: OOC on xck26-sfvc784-2LV-c with Vivado
	// 2022.1.2 gives 26 267 -> 26 283 LUTs and 20 752 -> 20 744 FFs, i.e.
	// +16 / -8 -- restructuring noise an order of magnitude below the +-300
	// LUT band doc/integration.adoc calls causally uninterpretable. What the
	// tool repacks around is the re-driven anchor assignment in the
	// composer's exclusive-sync branch and the re-associated successor
	// expression, neither of which adds logic.
	//
	// Only the LAST instruction of a block can be a control-flow event
	// (that is what terminates a block), so nothing about branch history,
	// HTM/BTM, JTC or the return stack changes: one block still carries at
	// most one CF event. What changes is the rate at which ICNT fills.
	//
	// NO CAPS bit, for the same reason as CT_EN_TRIG_REGS: the switch adds
	// no message type and no wire field. A block beat produces the same
	// messages a serialised beat sequence would, with the same ICNT -- the
	// decoder cannot tell the two apart and would learn nothing from an
	// announcement. It is an INTEGRATION property of the netlist (the
	// width of an input bus), discoverable at the port, not on the wire.
	//
	// Limitation, stated rather than hidden: the address comparators
	// (`ct_L23_preproc_comp_filters`), the ACT watchpoint search
	// (`ct_L23_preproc_act_st`) and the performance counters
	// (`ct_L23_preproc_perfcnt`) compare ONE address per beat and keep
	// seeing the block START. A block spans an address RANGE, so
	// instruction-granular filtering is not expressible on this ingress at
	// all -- it is a property of the port, not a shortfall of the filter.
	localparam bit CT_EN_BLOCK_TIP = 0;
	// Width of the tip.iretire bus when CT_EN_BLOCK_TIP = 1 (ignored
	// otherwise -- the SR ingress is one bit by definition).
	//
	// The upper bound is NOT a preference. The composer's ICNT pre-drain
	// fires when `icnt_cum + beat_halfwords` reaches 2^NEXUS_MSG_I_CNT_WIDTH
	// and then restarts the accumulator AT beat_halfwords; that is only
	// sound while a SINGLE beat stays below the threshold, so
	// 2^CT_IRETIRE_WIDTH - 1 must be < 2^8. ct_encoder enforces it at
	// elaboration.
	//
	// The resulting integration contract is explicit: a core whose block
	// generator has no bound of its own (CVA6's ITI accumulates until the
	// next control-flow instruction, IRETIRE_LEN = 32) must have its
	// adapter SPLIT a longer run into several blocks terminated with
	// `itype = OTHER`. That costs nothing on the wire -- an OTHER block
	// raises no CF event, it only accumulates -- and it keeps the bound a
	// checkable property instead of a hope.
	//
	// 8 covers 127 instructions per beat at RV32I sizing; a 2-commit-port
	// hart needs 3 (4 halfwords).
	localparam int unsigned CT_IRETIRE_WIDTH = 8;
	// M-Serialize (FINDINGS_etip_collisions §3): present eTIP slots one per
	// cycle through a small skid queue instead of P-parallel -- the FIFO
	// stores ONE entry per slot (parallel: P entries/slot). Message order
	// and per-message timestamps are unchanged (byte stream identical);
	// multi-slot beats that exceed the skid drop WHOLE into the designed
	// overflow->resync path (structurally unreachable for CF+DF at <= 1
	// event/instruction; DAQ-dense workloads gate via etip_budget_analyzer).
	// Default 1 = FULL-profile default since R2 2026-07-19; data
	// basis: seq-23 T5, full suite PASS + manifest 15/15 byte-identical,
	// -228 LUTs / BRAM 17.5->9.5). Slim/featparity profiles keep 0 (the skid
	// costs +185 LUTs there); the profile scripts set it explicitly.
	localparam bit CT_ETIP_SERIALIZE = 1;
	// eTIP FIFO implementation style ("auto" = library heuristic). "shift"
	// forces SRL-based storage (storage + read mux live in one LUT per bit,
	// near-zero FF cost) -- attractive for
	// the slim shallow profiles where the auto heuristic still picks LUTRAM.
	localparam CT_ETIP_FIFO_STYLE = "auto";
	// eTIP interface diet, each default = historical:
	//   CT_ETIP_CDC_SLIM     : single-clock builds only -- shrink the decouple
	//                          stage behind the CVS FIFO from depth 4
	//                          ("registers" store + read mux) to the minimal
	//                          pointer-free A/B register pair (fifo1clk_fwft
	//                          MIN_DEPTH=2, back-to-back capable). Keeps the
	//                          prefetch the consumer needs for full rate --
	//                          a measured attempt to REMOVE the stage entirely
	//                          halved the peak delivery rate (CVS PO-stage
	//                          reload cadence) and truncated burst tails.
	//   CT_EN_ETIP_WATERMARK : 1 = historical trTeTipFifoMaxFill CSR watermark
	//                          chain (fill tracking through the FIFO stats
	//                          counters). 0 = CSR reads 0 and the whole
	//                          cnt_avail/fill/compare chain trims away; the
	//                          end-of-sim watermark report stays (sim-only
	//                          shadow), so depth tuning evidence is unchanged.
	localparam bit CT_ETIP_CDC_SLIM     = 0;
	localparam bit CT_EN_ETIP_WATERMARK = 1;
	//   CT_EN_FIFO_HIST : eTIP CVS FIFO fill-level histogram:
	//                     16 saturating 16-bit counters, one
	//                     per fill threshold b*DEPTH/16, incremented on the
	//                     UPWARD crossing of that level -- answers the FIFO
	//                     sizing question empirically (distribution, not just
	//                     the MaxFill watermark). Read via 8 RO CSRs
	//                     trTeTipFifoHist0..7, cleared via
	//                     trTeTipFifoStatus.HistClear. Deliberately NO CDC:
	//                     counters live in tip_clk and are wired straight to
	//                     the wb-read hwif -- READ CONTRACT: only while the
	//                     trace is quiescent (trTeControl.Enable=0). Pure
	//                     diagnostic, on-wire stream identical. Compiled out
	//                     -> registers OMITTED from the regblock (I-01
	//                     register-omission pattern). Voll 1; slim-profile
	//                     intent 0 -- the v2 measurement profiles
	//                     (phase_d_matrix_v2.sh) keep it at 1; see
	//                     doc/integration.adoc#feature-flags.
	//                     The counter arithmetic carries (* use_dsp *) so it
	//                     maps into (otherwise unused) DSP48 slices instead
	//                     of fabric LUTs.
	localparam bit CT_EN_FIFO_HIST      = 1;
	//   CT_FIFO_HIST_BINS : number of histogram ranges/counters (AW
	//                     2026-07-20). Constraints (elab-checked): even
	//                     (two 16-bit bins per read), 2..64, and a divisor
	//                     of ETIP_CVS_FIFO_DEPTH (exact integer thresholds
	//                     (b+1)*DEPTH/BINS). Read-out is SERIAL (AW): ONE
	//                     data CSR trTeTipFifoHistData returns bin pair
	//                     [2*RdIdx, 2*RdIdx+1] and auto-increments the
	//                     pointer -- the CSR map is INDEPENDENT of BINS
	//                     (no RDL regen when changing this value) and the
	//                     expensive per-register readback is avoided.
	localparam int unsigned CT_FIFO_HIST_BINS = 16;
	// Timestamp unit. 1 = historical: ts counter +
	// prescaler, 64-bit readback CDC, trTs* CSRs, TSTAMP fields in messages
	// (trTsControl.Enable resets to 1, so EVERY historical reference stream
	// carries 1-bit-0 TSTAMP fields). 0 = no TS hardware: ts_value==0 and
	// trTsEnable==0 (the TSTAMP fields VANISH from the wire), trTs* CSRs
	// read 0 (Enable reset flips to 0, Width reads 0 = "no timestamp
	// implemented"). Byte contract is therefore proven against a NEW
	// reference -- the historical netlist with trTsControl.Enable cleared
	// by SW (TB leg +NO_TSTAMP) -- never against the historical md5s.
	localparam bit CT_EN_TIMESTAMP = 1;
	//   CT_EN_AXIS_TS     : timestamp element on the AXIS instrumentation
	//                       beat (C0a). A DAQ_PC_CURR beat then carries
	//                       ts_value[31:0] as element 2 (Strb 0xFFF instead
	//                       of the historical 0xFF), so an in-fabric
	//                       consumer can order and correlate PC samples
	//                       without a Nexus decoder. The value follows the
	//                       timestamp unit (trTsControl.Type / Active /
	//                       Count / Prescale); trTsControl.Enable keeps
	//                       gating ONLY the wire TSTAMP fields, so the ATB
	//                       byte stream is identical in either position of
	//                       this switch. No CAPS bit: the AXIS sink is not
	//                       a Nexus wire format (same rule as
	//                       CT_EN_BLOCK_TIP). Requires CT_EN_TIMESTAMP
	//                       (the ts_value source) and CT_EN_ACT (the AXIS
	//                       sink is fed by the ACT-CAP command path);
	//                       elaboration guards in the AXIS composer.
	//                       Compiled out -> element 2 and the wider strobe
	//                       trim away, beats are byte-identical to the
	//                       historical AXIS format. Full-profile default 1;
	//                       see doc/integration.adoc#feature-flags.
	localparam bit CT_EN_AXIS_TS = 1;
	// Micro CSR: hand-written drop-in for the generated
	// regblock in CF-only slim profiles (ct_cs_micro inside ct_cs_cpuif_wb).
	// Implements exactly the slim SW contract (live regs + discovery
	// constants + read-0 gated groups, swwel identical).
	// Default 0 = generated regblock (RDL remains the SSOT for every other
	// profile). It is NOT a free choice: ct_cs_micro.sv rejects at
	// elaboration every profile whose registers it does not implement, and
	// there are THREE such $fatals, not one --
	//   * DAQ / DATA_TRACE / ACT / FILTERS / COMPRESSION  (the CF-only rule)
	//   * CT_EN_TRIG_REGS   (P7): the trigger configuration block 0x050/
	//     0x054/0x058 is not decoded; reading a constant 0 while the routing
	//     is BUILT would be a lying discovery answer
	//   * CT_EN_FIFO_HIST   (P8): the eTIP FIFO fill histogram 0xe10/0xe14
	//     is not decoded; with the bins counting in tip_clk, a constant 0
	//     would hide a built diagnostic just as silently
	// The twin's fidelity to the generated block -- every field read back at
	// the same width AND from a source that wide -- is held mechanically by
	// scripts/check_micro_csr_twin.py (make lint, CI stage 1).
	localparam bit CT_MICRO_CSR = 0;
	// MSEO/MDO bit slicer: field steps assembled per cycle. 2 = historical
	// (an output slice can cross one field boundary per cycle -> sustains
	// ~1 slice/cycle even across many short fields). 1 halves the slicer's
	// field-mux/shift datapath; a boundary-crossing slice then needs 2
	// cycles (lower sustained wire rate on short-field messages -- fine
	// where the profile is bandwidth-uncritical). Wire BYTES are identical
	// either way (assembly timing only).
	localparam int unsigned CT_SLICER_STEPS = 2;
	// Compact packer (single-module packer pattern): msg_gen's generic
	// trace message is turned into MDO/MSEO chunks DIRECTLY by a per-TCODE
	// layout table (ct_L2_compact_packer), replacing the generic
	// nexus_formatter 10-field array, the message buffer and the barrel bit
	// slicer of the historical path. Wire bytes are identical (same field
	// order, leading-zero suppression and MSEO field/message boundaries);
	// only assembly timing differs (~1 slice/cycle, one extra cycle per
	// message and per variable-field handoff -- fine where the profile is
	// bandwidth-uncritical). CF-only: the layout table carries the program
	// trace TCODEs (9/11/12/27/28/30/33/56/57, ERROR, FLUSH) but not
	// DF/DAQ formats, so it requires CT_EN_DAQ = CT_EN_DATA_TRACE =
	// CT_EN_ACT = 0 (elaboration $fatal otherwise). Default 0 = historical
	// formatter/slicer path, byte- and netlist-identical.
	localparam bit CT_COMPACT_PACKER = 0;

	// E-Trace backend (Efficient Trace for RISC-V v2.0, te_inst packets):
	// replaces the ENTIRE N-Trace L2 (msg_gen + formatter/packer + MSEO) with
	// ct_L2_te_inst_gen + ct_L2_te_packetizer behind the same eTIP. The ATB
	// byte stream then carries reference-raw framed te_inst packets (header
	// byte = payload_len | 0x40, little-endian payload, whole-packet
	// sign-based compression) -- directly consumable by the vendored
	// reference decoder (third_party/riscv-trace-spec-ref). Feature state
	// (2026-07-25): delta-address mode, mandatory formats 1/2/3.x PLUS
	// Format 0 (0.0 branch-prediction, 0.1 jump-target-cache), optional
	// modes implicit-return and sijump, periodic mid-trace resync, real
	// ecause/tval/priv/ilastsize via the eTIP sideband, and -- with
	// CT_EN_DATA_TRACE / CT_EN_DAQ|CT_EN_ACT -- te_data data-trace packets
	// plus vendor DAQ packets. Default 0 = byte- and netlist-identical
	// N-Trace build.
	//
	// PROTOCOL = SYNTHESIS PARAMETER (AW directive 2026-08-04): these two
	// switches are the NETLIST MASTER -- they set the eTIP sideband widths
	// (ct_etip_pkg) and the RDL profile, and they are the defaults of the
	// ct_encoder EN_ETRACE/EN_NTRACE parameters. The per-INSTANCE choice is
	// made at the instantiation (a multi-encoder SoC mixes N-Trace and
	// E-Trace encoders in one netlist); exactly one back end per encoder,
	// enforced by the elaboration guard in ct_encoder. There is no runtime
	// protocol select -- trTeProtocolSel.Protocol is read-only discovery,
	// driven by the parameter.
	localparam bit CT_EN_ETRACE = 0;
	// N-Trace backend switch: 1 (default) = the historical Nexus chain.
	// Setting BOTH switches no longer builds a dual encoder; it only means
	// "the netlist contains encoders of both kinds", and every ct_encoder
	// instance must then pick its back end explicitly (the unparameterised
	// default would be ambiguous and trips the elaboration guard).
	localparam bit CT_EN_NTRACE = 1;
	// Mirror of tools/etrace/etrace_common.py (single source of truth for
	// the reference-model side): iaddress_width_p=32, iaddress_lsb_p=1.
	localparam int unsigned CT_ETRACE_ADDR_BITS    = 31;
	// Longest packet: F3.1 exception = 2+2+1+3+4+1+1+31+32(tval) = 77 bits.
	// CF-only: 80 (F3.1 with tval). +DATA_TRACE: unified load/store te_data
	// (2+2+2+3+64+32 = 105). +DAQ/ACT: vendor DAQ packet (8 + 3x64 = 200).
	localparam int unsigned CT_ETRACE_PKT_MAX_BITS =
		(CT_EN_DAQ || CT_EN_ACT) ? 208 : (CT_EN_DATA_TRACE ? 112 : 80);

	// Config-message CAPS bitmap (v1 bit positions, SPEC section 3): the
	// compiled-in feature map advertised on-wire. sijump is an integration
	// attribute of the attached core (CT_SIJUMP parameter of ct_encoder),
	// not a package constant -- the caller passes it in. ENAB is built at
	// the emission site by masking CAPS with the runtime enables.
	//
	// Bit 23 ADDR64 is the odd one out: not a feature but the ADDRESS WIDTH
	// of this netlist (CT_ADDR64 = CT_XLEN == 64). It has to travel on-wire
	// because a decoder cannot derive the width from the stream -- F-ADDR
	// and U-ADDR are variable-length with leading zeros stripped, so a
	// 40-bit address and a 40-bit-significant 64-bit address look exactly
	// alike. The decoder reads the bit and sizes its own PC state and its
	// JTC fold accordingly. CT_CFGMSG_VER stays 1: the information is
	// boolean, and the alternative (a PARAM4 field) is a structural change
	// in the compact packer, whose six variable segments are all taken.
	// It has no runtime enable, so ENAB mirrors CAPS.
	function automatic logic [23:0] ct_cfgmsg_caps(input bit sijump);
		return {
			CT_ADDR64,                    // 23 ADDR64
			CT_EN_DF_DROP,                // 22 DF_DROP
			CT_EN_DF_ADDR_COMPRESS,       // 21 DF_ADDR_COMPRESS
			CT_EN_WATCHPOINT_MSG,         // 20 WATCHPOINT_MSG
			CT_EN_DEVICE_ID,              // 19 DEVICE_ID
			CT_EN_QUOTA_SYNC,             // 18 QUOTA_SYNC
			bit'(CT_EN_DAQ || CT_EN_ACT), // 17 DAQ
			CT_EN_DATA_TRACE,             // 16 DATA_TRACE
			CT_EN_TIMESTAMP,              // 15 TIMESTAMP
			CT_EN_SEQ_SYNC,               // 14 SEQ_SYNC
			CT_EN_TRIG_SYNC,              // 13 TRIG_SYNC
			CT_EN_EVTI,                   // 12 EVTI
			CT_EN_POWER_EVENTS,           // 11 POWER_EVENTS
			CT_EN_DEBUG_EVENTS,           // 10 DEBUG_EVENTS
			CT_EN_REPEAT_INSTR,           //  9 REPEAT_INSTR
			CT_EN_IBHS,                   //  8 IBHS
			CT_EN_OWNERSHIP,              //  7 OWNERSHIP
			sijump,                       //  6 SIJUMP
			CT_EN_BP,                     //  5 BP (steering: -bp walk)
			CT_EN_JTC,                    //  4 JTC
			CT_EN_REPEAT_BRANCH,          //  3 RB
			CT_EN_WIDE_ICNT,              //  2 WIDE_ICNT
			CT_EN_REPEATED_HISTORY,       //  1 RH
			CT_EN_IMPLICIT_RETURN         //  0 IR
		};
	endfunction

	localparam SRC_ID_MAX_WIDTH = 12; // corresponds to NTRACE_MAX_SRC
	localparam ADDR_WIDTH       = CT_XLEN; // Nexus F-ADDR / U-ADDR width
	localparam ADDR_MAX_WIDTH   = 64; // corresponds to NTRACE_MAX_ADDR
	localparam HIST_WIDTH       = 32; // Nexus HIST width
	localparam HIST_MAX_WIDTH   = 32; // corresponds to NTRACE_MAX_HIST
	localparam TSTAMP_WIDTH     = 64; // Nexus TSTAMP width
	localparam TSTAMP_MAX_WIDTH = 64; // corresponds to NTRACE_MAX_TSTAMP

	localparam SYNC_COUNT_AEMPTY = 50; // send "xxx Branch with Sync Message" if SyncCount < SYNC_COUNT_AEMPTY

	// Max # of parallel eTIP messages the composer can raise in ONE tip beat.
	//
	// PROVEN, not counted (P4 re-audit finding B-1). The composer has THIRTEEN
	// slot allocation sites; the previous form of this constant was an
	// argument over five of them and three sources sat outside it entirely.
	// formal/composer_slots (P-SLOT-1) now checks the composer's own
	// a_p4_slot_bound over the real module with a free environment -- every
	// tip beat, every sync verdict, every ACT-ST command and every CSR value
	// the solver can construct -- for SPLIT_DATA_ACCESS 0 and 1. The value
	// below is the number that proof accepts, and the run_red R-TIGHT check
	// shows one less is refuted, i.e. it is also the MINIMUM.
	//
	// Term by term, with the composer line each one budgets:
	//
	//  2  CF event (:746) + the accumulator-clearing slot of the same beat.
	//     The ICNT pre-drain (:620), the debug-entry marker and the low-power
	//     entry marker (:522) SHARE that second slot: each of them consumes
	//     and CLEARS the cumulated halfword count (`icnt_cum_next = 0`), and
	//     the marker block runs BEFORE the pre-drain, so after a marker the
	//     pre-drain condition (cumulated + <= 8 >= 256) cannot hold. That is
	//     a combinational exclusion, which is why the k-induction proof goes
	//     through with free state.
	//  1  Trace-off correlation, TCODE 33 (:964). Sticky `DoCorrDisable` is
	//     cleared only by the flush ack, so it can still be pending on the
	//     NEXT trace-on beat -- together with the device ID, the config and a
	//     processed retire. This source had no term at all before B-1; it is
	//     the reason a control-flow-only profile needs 3 slots, not 2.
	//  +  Ownership, TCODE 2 (:772) -- the slot FOLLOWING the sync CF in the
	//     same beat (N-Trace 7.1).
	//  +  Config, TCODE 58 (:491) -- trace-on edge or sync beat.
	//  +  Device ID, TCODE 1 (:456) -- trace-on edge, before the config slot.
	//     Additive to the config slot of the SAME beat; also measured, the
	//     composer telemetry prints "ONE beat carries Device ID (slot 0) AND
	//     Config (slot 1)" in the did/both/src legs of
	//     tests/instruction/31_status_msgs.
	//  +2 Data flow. With SPLIT_DATA_ACCESS = 1 the store arm (:799) and the
	//     split-load response arm (:812) are INDEPENDENT ifs and a beat can
	//     raise both; with 0 there is a single arm (:826). SPLIT_DATA_ACCESS
	//     is a parameter of ct_encoder and a package constant cannot see it,
	//     so the constant budgets the worse of the two rather than
	//     introducing a second source of truth for the same fact. The P7 drop
	//     marker (:845) takes the slot of the DF message it suppresses, so it
	//     only needs a term where there is no data trace at all.
	//  +  DAQ (:940), shared with the watchpoint arm (:875): both are selected
	//     by the SAME beat qualifier (act_cap_st.valid) with mutually
	//     exclusive command codes, and the ACT-ST path delivers at most one
	//     command per beat -- so a watchpoint slot always REPLACES the DAQ
	//     slot. Checked by a_p4_wp_daq_exclusive and by the run_red R-EXCL
	//     mutation. CT_EN_WATCHPOINT_MSG also requires CT_EN_ACT (composer
	//     elaboration guard), so this term is present whenever the arm is.
	//  -  The flush marker (:981) never allocates: it re-uses the last slot,
	//     or slot 0 if the beat has none.
	//
	// The CVS FIFO stores a full P-wide slot per entry, so every term here is
	// paid P times in the queue and in the compaction crossbar -- which is
	// why the terms are feature-gated and a control-flow-only profile is
	// unaffected by all of them but the correlation slot.
	//
	// The bound is checked at its allocation site by the immediate assertion
	// a_p4_slot_bound (a concurrent property CANNOT see it -- see the comment
	// there), and MaxSlotsSim reports the measured demand
	// (scripts/collect_slot_watermarks.sh aggregates it over the sim logs).
	// (I8 is a DIFFERENT invariant, doc/verification.adoc -- the old name in
	// this comment sent the reader to the wrong checker. P4 re-audit C-1.)
	localparam ETIP_PAR_MSG        = 2
	                               + 1
	                               + (CT_EN_OWNERSHIP ? 1 : 0)
	                               + (CT_EN_CONFIG_MSG ? 1 : 0)
	                               + (CT_EN_DEVICE_ID ? 1 : 0)
	                               + (CT_EN_DATA_TRACE ? 2 : (CT_EN_DF_DROP ? 1 : 0))
	                               + ((CT_EN_ACT || CT_EN_DAQ) ? 1 : 0);
	// Number of slot ALLOCATION SITES in the composer, i.e. of
	// `msg_id_next = msg_id_next + 1` statements. This sizes the slot
	// counter, and it must be an UPPER bound: a counter that WRAPS would
	// let an exceeded bound slip past a_p4_slot_bound unnoticed -- the
	// guard would then be exactly as silent as the defect it guards.
	// Checked mechanically against the real source by
	// formal/composer_slots/run.sh before every formal run.
	localparam int unsigned ETIP_SLOT_SITES = 13;
	// eTIP buffering depths (M2, measured basis): in every cli workload the
	// CVS fill watermark stayed at 0 (proc drains faster than the composer
	// produces); the deep 128-entry cascade only pays off for DF/DAQ bursts
	// and stalled-sink scenarios. A control-flow-only profile ships 32 --
	// sustained CF rate is <= 1 event/instruction and overload falls into
	// the designed overflow->resync path. Integrators tune via the trTeTipFifoMaxFill
	// watermark CSR (also reported at end-of-sim by the composer).
	localparam ETIP_CVS_FIFO_DEPTH = (CT_EN_DATA_TRACE || CT_EN_ACT || CT_EN_DAQ) ? 128 : 32;
	// Data-trace drop watermark (P7, CT_EN_DF_DROP): fill level at or above
	// which the DF eTIP arms are suppressed while trTeDataControl.DataDropEna
	// is set. 3/4 of the depth leaves a quarter of the queue as headroom for
	// the instruction trace -- the resource the policy exists to protect.
	// Derived, so it follows a re-tuned depth automatically.
	localparam int unsigned CT_DF_DROP_WATERMARK = (ETIP_CVS_FIFO_DEPTH * 3) / 4;
	// The CDC stage of the eTIP cascade only needs real depth when it
	// crosses clocks (gray-pointer CDC). In a single-clock build it is a
	// plain FIFO directly behind the CVS stage -- 4 entries decouple the
	// handshake, the CVS stage provides the buffering. CT_ETIP_CDC_SLIM
	// shrinks the single-clock stage to fifo1clk_fwft's minimal A/B register
	// pair (depth 2, back-to-back) -- prefetch semantics preserved, entry
	// store and read mux minimal.
	localparam ETIP_CDC_FIFO_DEPTH = CT_SINGLE_CLOCK ? (CT_ETIP_CDC_SLIM ? 2 : 4)
	                               : (CT_EN_DATA_TRACE || CT_EN_ACT || CT_EN_DAQ) ? 128 : 16;

	localparam ATB_FUNNEL_IMPUT_FIFO_DEPTH = 16;
	localparam ATB_MAX_CHUNKS               =  4; // 4 x 8/16/32 Bit
	localparam ATB_CVS_FIFO_DEPTH           =  8;
	localparam ATB_CDC_FIFO_DEPTH           =  8;

	localparam NUM_ATB = 2; // # of ATB inputs of funnel

	localparam DISP_ALL  = 32'hFFFFFFFF;
	localparam DISP_NONE = '0;
	localparam DISP_1    = 32'h00000001 << 0;
	localparam DISP_2    = 32'h00000001 << 1; // info output from nexus formatter
	localparam DISP_3    = 32'h00000001 << 2; // info output from msoe mdo formatter
	localparam DISP_4    = 32'h00000001 << 3;

	localparam DISP = DISP_3;

	typedef enum logic [1:0] {
		DATA_RD        = 0, // count # of data reads
		DATA_WR        = 1, // count # of data writes
		INSTR_FETCH_TH = 2, // count # of instruction fetches exceeding threshold
		DATA_RD_TH     = 3  // count # of data reads exceeding threshold
	} ct_perfcnt_type_e;

	localparam NUM_PERFCNT_IFETCH_TH_RANGES_WIDTH  = $clog2(NUM_PERFCNT_IFETCH_TH_RANGES);
	localparam NUM_PERFCNT_DATA_RD_TH_RANGES_WIDTH = $clog2(NUM_PERFCNT_DATA_RD_TH_RANGES);
	localparam NUM_PERFCNT_DATA_RD_RANGES_WIDTH    = $clog2(NUM_PERFCNT_DATA_RD_RANGES);
	localparam NUM_PERFCNT_DATA_WR_RANGES_WIDTH    = $clog2(NUM_PERFCNT_DATA_WR_RANGES);

	localparam SYNCCNT_WIDTH             = 21; // must be greater than cs_tip.trTeInstSyncMax(=16) + 4
	localparam PERFCNT_WIDTH             = 32;
	localparam TRACE_MATCH_WIDTH         = 32;
	localparam PERFCNT_TH_WIDTH          =  8;
	localparam EXCEPTION_STACK_DEPTH     =  4; // 4 for debugging of overflow, later: 16 or 32
	localparam NUM_TRACE_COMPARATORS_WIDTH = $clog2(NUM_TRACE_COMPARATORS); // width of # of trace comparators (max 4)
	// Data width of a trace comparator = the widest value it can be fed
	// (tip.iaddr / tip.daddr / tval), i.e. the architectural address width.
	// TRACE_MATCH_WIDTH above stays 32: that is the width of ONE CSR
	// register -- a 64-bit comparator bound is the {High,Low} pair.
	localparam TRACE_COMPARATORS_WIDTH   = CT_XLEN; // data width of trace comparator
	localparam MATCH_CNT_WIDTH           =  8; // width of FilterMatchEcause / FilterMatchInterrupt counter
	localparam SEARCH_RESULT_WIDTH       =  2;
	localparam MAX_DAQ_DATA_ELEMENTS     =  3;
	// Preproc alignment budget: must cover the WORST qualifier-chain latency
	// of the blocks the profile instantiates (ct_L23_preproc checks this
	// with a $fatal guard in simulation; act_st/df_range additionally guard
	// their own chain against the budget at ELABORATION -- see the
	// ct_elab_guard_violation poison pattern there):
	//   ACT        : act_st = 1 + vbs(4*M0_DIM-1 = 39) -> chain 41 + act_proc 1 = 42
	//   DATA_TRACE : df_range = vbs(4*M1_DIM-1=15) + 1, + df 1 -> chain 17
	//   FILTERS    : comp_filters 2 + cf 1          -> chain  3
	//   floor      : sync_gen 2 (always present)
	// The ACT branch grew 20 -> 44 with the watchpoint capacity (M0_DIM
	// 4 -> 10, C0b): every EXTRA_DELAY_MAX-deep alignment pipe in the
	// preproc blocks pays for it, so the deep budget is charged to
	// CT_EN_ACT ONLY -- a DATA_TRACE-only profile keeps the historical 20
	// (its own chain is 17; the elaboration guards catch any future
	// under-budget instead of a silent mis-alignment).
	// (The pass-1 formula `CT_EN_ACT ? 20 : 1` under-budgeted every non-ACT
	// profile: ACT=0+DT=1 produced an EMPTY ATB stream, and PT-only ran with
	// budget 1 < required 2 -- found by single-factor bisection 2026-07-19.)
	localparam PREPROC_DELAY_MAX         = CT_EN_ACT        ? 44
	                                     : CT_EN_DATA_TRACE ? 20
	                                     : CT_EN_FILTERS    ?  4
	                                     :                     2;
	// +1: the delay_t vector must HOLD the value PREPROC_DELAY_MAX itself
	// ($clog2(N) only covers 0..N-1; the old sizing degenerated to 0 bits
	// for the budget-1 profile).
	localparam PREPROC_DELAY_MAX_WIDTH   = $clog2(PREPROC_DELAY_MAX + 1);
	localparam EXTRA_DELAY_MAX           = PREPROC_DELAY_MAX; // Maximum configurable additional pipeline depth (default: 20)
	                                                          // Allows synchronization with other preprocessing modules.

	typedef logic [SYNCCNT_WIDTH-1:0]                    ct_synccnt_counter_t;
	typedef logic [PERFCNT_WIDTH-1:0]                    ct_perfcnt_counter_t;
	typedef logic [SEARCH_RESULT_WIDTH-1:0]              ct_search_result_t;
	typedef logic [SRC_ID_MAX_WIDTH-1:0]                 ct_src_id_t;
	typedef logic [NUM_TRACE_FILTER-1:0]                 ct_trace_filter_t;
	typedef logic [NUM_TRACE_COMPARATORS-1:0]            ct_trace_comp_t;
	typedef logic [TRACE_COMPARATORS_WIDTH-1:0]          ct_trace_comp_data_t;
	typedef logic [2:0]                                  ct_trace_filter_match_comp_t; // three comparator selectors (1..3) per filter
	typedef logic [2:0][NUM_TRACE_COMPARATORS_WIDTH-1:0] ct_trace_filter_comp_t;        // comparator selector id | comparator id
	typedef logic [EXCEPTION_STACK_DEPTH-1:0]            ct_exception_stack_t;
	typedef logic [EXCEPTION_STACK_DEPTH:0]              ct_exception_stack_marker_t;
	typedef logic [TRACE_MATCH_WIDTH-1:0]                ct_trace_match_t;
	typedef logic [MATCH_CNT_WIDTH-1:0]                  ct_trace_match_cnt_t;
	typedef logic [PERFCNT_TH_WIDTH-1:0]                 ct_perfcnt_th_t;

	localparam ACT_CAP_INT_ELEMENT_WIDTH = 32;
	localparam ACT_CAP_AXIS_TDATA_WIDTH  = 3 * ACT_CAP_INT_ELEMENT_WIDTH;
	// tid carries the ACT-CAP command (doc/enhanced-features.adoc: "tid
	// (8 bit) is the ACT-CAP command"): ct_L23_preproc_composer_axis
	// assigns Id_t'(act_cap_st.cmd.Cmd.value). Checked against the source
	// of that value -- trActCapStCmd.Cmd is a 6-bit RDL field (Cmd[5:0])
	// whose enum trActCapStCmd_e needs 4 bits -- so 8 covers it with room
	// to spare and the cast cannot truncate a legal command. The referenced
	// act_cap_cmd_t.data.id_data.id of the original TODO does not exist in
	// this design; the register field above is the authoritative source.
	localparam ACT_CAP_AXIS_TID_WIDTH    = 8;

	// CTTE internal sub message type
	typedef enum logic [2:0] {
		SUB_MSG_NONE  = 0, // sub message is not valid
		SUB_MSG_CF    = 1, // sub message is etip_cf_msg_struct_t
		SUB_MSG_DF    = 2, // sub message is etip_df_msg_struct_t
		SUB_MSG_DAQ   = 3, // sub message is etip_daq_msg_struct_t
		SUB_MSG_OTHER = 4
	} ct_sub_type_e;

	// ACT-CAP/ST definitions
	localparam ACT_CAP_DATA_WIDTH = 32;
	localparam ACT_CAP_ADDR_WIDTH = CT_XLEN;
	typedef logic [ACT_CAP_DATA_WIDTH-1:0] ct_act_cap_data_t;
	typedef logic [ACT_CAP_ADDR_WIDTH-1:0] ct_act_cap_addr_t;

	// ATC-CAP/ST TE register access
	typedef enum logic [7:0] {
		ACT_CAP_TE_INSTR_TRACING = 0, // trTeControl.InstTracing
		ACT_CAP_TE_DATA_TRACING  = 1  // trTeDataControl.DataTracing
	} ct_act_cap_te_ctrl_e;

	typedef struct packed {
		ct_act_cap_te_ctrl_e ctrl;
		logic [15:0]         data;
	} ct_act_cap_te_t;

	// Definitions for M0 (act_st)
	// DIM 4 -> 10 (C0b): 1023 watchpoint slots. The search tree is a
	// RAM-backed perfect binary tree (vector_binary_search_2clk, one
	// ocram per level, II=1) -- the structure carries DIM=14/16k per its
	// own header reference, so the real cost of this step is NOT the tree
	// (~2 BRAM36) but the PREPROC_DELAY_MAX growth above: the chain is
	// 4*M0_DIM cycles and every alignment pipe follows it.
	localparam int M0_DIM    = 10;
	localparam int M0_N      = (2**M0_DIM)-1;
	localparam int M0_STAGES = (M0_N > 1) ? $clog2(M0_N) : 1;

	// Key = iaddr, so it follows the architectural address width: the search
	// tree itself is instantiated with tip_iaddr_t (ct_L23_preproc_act_st),
	// and the ocram_write_if that fills it is typed m0_kr_t -- the two must
	// agree or elaboration fails. The CSR-side watchpoints memory keeps its
	// 32-bit word pair, so at XLEN = 64 the upper key half is written as 0:
	// a watchpoint can be placed anywhere in the low 4 GiB and NEVER matches
	// a higher address (a documented configuration limit, not a truncation
	// -- the full-width address enters the comparison unchanged).
	localparam type   M0_K           = logic [CT_XLEN-1:0]; // key = iaddr
	localparam type   M0_R           = logic [31:0]; // 32 Bit value
	localparam string M0_SEARCH_MODE = "VALUE";      // "VALUE, "RANGE"
	localparam int    M0_NUM_KEYS    = (M0_SEARCH_MODE == "VALUE") ? 1 : 2;

	typedef struct packed {
		M0_K [M0_NUM_KEYS-1:0] key;
		M0_R                   value;
	} m0_kr_t;

	// Definitions for M1 (df range)
	localparam int M1_DIM    = 4;
	localparam int M1_N      = (2**M1_DIM)-1;
	localparam int M1_STAGES = (M1_N > 1) ? $clog2(M1_N) : 1;

	// Same contract as M0_K, for the data-address range filter (df_range is
	// instantiated with tip_daddr_t): bounds are CSR-programmable in the low
	// 4 GiB, the compared address is full width.
	localparam type   M1_K           = logic [CT_XLEN-1:0]; // hit, if key0 <= daddr <= key1
	localparam string M1_SEARCH_MODE = "RANGE";      // "VALUE, "RANGE"
	localparam int    M1_NUM_KEYS    = (M1_SEARCH_MODE == "VALUE") ? 1 : 2;

	typedef struct packed {
		M1_K [M1_NUM_KEYS-1:0] key;
	} m1_kr_t;

	typedef logic [PREPROC_DELAY_MAX_WIDTH-1:0] delay_t;

endpackage // ct_pkg

`default_nettype wire
