// Copyright 2021 Thales DIS design services SAS
//
// Licensed under the Solderpad Hardware Licence, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.0
// You may obtain a copy of the License at https://solderpad.org/licenses/
//
// Original Author: Jean-Roch COULON - Thales
//
// ACCEMIC DELTA D6 (2026-08-03, package R2.0):
// NEW configuration "cv64a6_imac_sv39_ctrace" -- an FPU-less RV64 stage-1 config
// for the C-Trace integration (copy of cv64a6_imafdc_sv39_config_pkg.sv,
// selected as usual via the file list: --target cv64a6_imac_sv39_ctrace).
// Deltas against the copy template:
//   1. RVF/RVD = 0 (build_config_pkg: FpPresent=0 -> cvfpu is generated away);
//      XF16/XF16ALT/XF8/XFVec were already 0.
//   2. CvxifEn = 0 (no coprocessor; the example COPRO crashes xelab 2026.1,
//      see cva6_trace_wrap.sv -- not configured here in the first place).
//   3. BExtEn = 0 AND ZKN = 0. ZKN=0 is a mandatory consequence, not a choice:
//      build_config_pkg.sv:70 forces `RVB = RVB || ZKN` -- with the
//      template's ZKN=1, the B extension would silently come back.
//   4. NrCommitPorts = 1 (stage-1 contract: cva6_trace_wrap/shim are
//      single-port; build_config_pkg.sv:49 passes the value through unchanged
//      when SuperscalarEn=0. Stage 2 = 2 ports, only after a later gap).
//   5. Address regions set to the KV260 window, analogous to an earlier delta
//      (cv32a6_ima_sv32_fpga_config_pkg.sv:143-177, CVA6_PIN.md):
//      Execute/Cached 0x6400_0000 +0x0C00_0000, NonIdempotent
//      0x0200_0000 +0x0E00_1000. CAUTION before the bitstream stage: an
//      earlier board finding capped the CACHED length at 64 MiB
//      (cache-line bursts above 0x6800_0000 correlated with a board failure)
//      -- irrelevant for the pure XSIM elaboration gate, re-evaluate before
//      a KV260 bitstream.
// NO deltas (deliberately kept as the template): TechnoCut=0 and FpgaEn=0 were
// already there (FpgaEn only in stage 2); RVC/Zcb/Zicond/MMU Sv39/RVA/RVS/RVU/caches
// unchanged.
// Risk context: the combination of RV64 without an FPU + NrCommitPorts=1 is not
// covered by upstream CI (risk R3, docs/handoffs/R0_A3_rocket_cv64a6_feasibility.md
// -- precedent: an earlier first Sv32 elaboration broke XSIM).


package cva6_config_pkg;

  localparam CVA6ConfigXlen = 64;

  localparam CVA6ConfigRVF = 0;
  localparam CVA6ConfigRVD = 0;
  localparam CVA6ConfigF16En = 0;
  localparam CVA6ConfigF16AltEn = 0;
  localparam CVA6ConfigF8En = 0;
  localparam CVA6ConfigFVecEn = 0;

  localparam CVA6ConfigCvxifEn = 0;
  localparam CVA6ConfigCExtEn = 1;
  localparam CVA6ConfigZcbExtEn = 1;
  localparam CVA6ConfigZcmpExtEn = 0;
  localparam CVA6ConfigAExtEn = 1;
  localparam CVA6ConfigHExtEn = 0;  // always disabled
  localparam CVA6ConfigBExtEn = 0;
  localparam CVA6ConfigVExtEn = 0;
  localparam CVA6ConfigRVZiCond = 1;

  localparam CVA6ConfigAxiIdWidth = 4;
  localparam CVA6ConfigAxiAddrWidth = 64;
  localparam CVA6ConfigAxiDataWidth = 64;
  localparam CVA6ConfigFetchUserEn = 0;
  localparam CVA6ConfigFetchUserWidth = CVA6ConfigXlen;
  localparam CVA6ConfigDataUserEn = 0;
  localparam CVA6ConfigDataUserWidth = CVA6ConfigXlen;

  localparam CVA6ConfigIcacheByteSize = 16384;
  localparam CVA6ConfigIcacheSetAssoc = 4;
  localparam CVA6ConfigIcacheLineWidth = 128;
  localparam CVA6ConfigDcacheByteSize = 32768;
  localparam CVA6ConfigDcacheSetAssoc = 8;
  localparam CVA6ConfigDcacheLineWidth = 128;

  localparam CVA6ConfigDcacheFlushOnFence = 1'b0;
  localparam CVA6ConfigDcacheFlushOnFenceI = 1'b0;
  localparam CVA6ConfigDcacheInvalidateOnFlush = 1'b0;

  localparam CVA6ConfigDcacheIdWidth = 1;
  localparam CVA6ConfigMemTidWidth = 2;

  localparam CVA6ConfigWtDcacheWbufDepth = 8;

  localparam CVA6ConfigNrScoreboardEntries = 8;

  localparam CVA6ConfigNrLoadPipeRegs = 1;
  localparam CVA6ConfigNrStorePipeRegs = 0;
  localparam CVA6ConfigNrLoadBufEntries = 2;

  localparam CVA6ConfigRASDepth = 2;
  localparam CVA6ConfigBTBEntries = 32;
  localparam CVA6ConfigBHTEntries = 128;

  localparam CVA6ConfigTvalEn = 1;

  localparam CVA6ConfigNrPMPEntries = 8;

  localparam CVA6ConfigPerfCounterEn = 1;

  localparam config_pkg::cache_type_t CVA6ConfigDcacheType = config_pkg::WT;

  localparam CVA6ConfigMmuPresent = 1;

  localparam CVA6ConfigRvfiTrace = 1;

  localparam config_pkg::cva6_user_cfg_t cva6_cfg = '{
      XLEN: unsigned'(CVA6ConfigXlen),
      VLEN: unsigned'(64),
      FpgaEn: bit'(0),  // for Xilinx and Altera
      FpgaAlteraEn: bit'(0),  // for Altera (only)
      TechnoCut: bit'(0),
      SuperscalarEn: bit'(0),
      ALUBypass: bit'(0),
      NrCommitPorts: unsigned'(1),  // D6: stage-1 contract (template: 2)
      AxiAddrWidth: unsigned'(CVA6ConfigAxiAddrWidth),
      AxiDataWidth: unsigned'(CVA6ConfigAxiDataWidth),
      AxiIdWidth: unsigned'(CVA6ConfigAxiIdWidth),
      AxiUserWidth: unsigned'(CVA6ConfigDataUserWidth),
      MemTidWidth: unsigned'(CVA6ConfigMemTidWidth),
      NrLoadBufEntries: unsigned'(CVA6ConfigNrLoadBufEntries),
      RVF: bit'(CVA6ConfigRVF),
      RVD: bit'(CVA6ConfigRVD),
      XF16: bit'(CVA6ConfigF16En),
      XF16ALT: bit'(CVA6ConfigF16AltEn),
      XF8: bit'(CVA6ConfigF8En),
      RVA: bit'(CVA6ConfigAExtEn),
      RVB: bit'(CVA6ConfigBExtEn),
      ZKN: bit'(0),  // D6: ZKN would force RVB (build_config_pkg.sv:70)
      RVV: bit'(CVA6ConfigVExtEn),
      RVC: bit'(CVA6ConfigCExtEn),
      RVH: bit'(CVA6ConfigHExtEn),
      RVZCB: bit'(CVA6ConfigZcbExtEn),
      RVZCMT: bit'(0),
      RVZCMP: bit'(CVA6ConfigZcmpExtEn),
      XFVec: bit'(CVA6ConfigFVecEn),
      CvxifEn: bit'(CVA6ConfigCvxifEn),
      CoproType: config_pkg::COPRO_NONE,
      RVZiCond: bit'(CVA6ConfigRVZiCond),
      RVZiCbom: bit'(0),
      RVZicntr: bit'(1),
      RVZihpm: bit'(1),
      NrScoreboardEntries: unsigned'(CVA6ConfigNrScoreboardEntries),
      PerfCounterEn: bit'(CVA6ConfigPerfCounterEn),
      MmuPresent: bit'(CVA6ConfigMmuPresent),
      RVS: bit'(1),
      RVU: bit'(1),
      SoftwareInterruptEn: bit'(1),
      HaltAddress: 64'h800,
      ExceptionAddress: 64'h808,
      RASDepth: unsigned'(CVA6ConfigRASDepth),
      BTBEntries: unsigned'(CVA6ConfigBTBEntries),
      BPType: config_pkg::BHT,
      BHTEntries: unsigned'(CVA6ConfigBHTEntries),
      BHTHist: unsigned'(3),
      DmBaseAddress: 64'h0,
      TvalEn: bit'(CVA6ConfigTvalEn),
      DirectVecOnly: bit'(0),
      NrPMPEntries: unsigned'(CVA6ConfigNrPMPEntries),
      PMPCfgRstVal: {64{64'h0}},
      PMPAddrRstVal: {64{64'h0}},
      PMPEntryReadOnly: 64'd0,
      PMPNapotEn: bit'(1),
      NOCType: config_pkg::NOC_TYPE_AXI4_ATOP,
      // D6 (Accemic, analogous to D5): regions set to the KV260 window instead of
      // the upstream Genesys2 board -- otherwise the very first fetch at
      // 0x6400_0000 takes an instruction access fault (mcause 1).
      //   non-idempotent: peripheral window CLINT..UART
      //   executable/cacheable: the DRAM window (re-evaluate the cached length
      //   before a bitstream, see the D5 board finding in the header comment)
      NrNonIdempotentRules: unsigned'(1),
      NonIdempotentAddrBase: 1024'({64'h0200_0000}),
      NonIdempotentLength: 1024'({64'h0E00_1000}),
      NrExecuteRegionRules: unsigned'(1),
      ExecuteRegionAddrBase: 1024'({64'h6400_0000}),
      ExecuteRegionLength: 1024'({64'h0C00_0000}),
      NrCachedRegionRules: unsigned'(1),
      CachedRegionAddrBase: 1024'({64'h6400_0000}),
      CachedRegionLength: 1024'({64'h0C00_0000}),
      MaxOutstandingStores: unsigned'(7),
      DebugEn: bit'(1),
      SDTRIG: bit'(0),
      Mcontrol6: bit'(0),
      Icount: bit'(0),
      Etrigger: bit'(0),
      Itrigger: bit'(0),
      AxiBurstWriteEn: bit'(0),
      IcacheByteSize: unsigned'(CVA6ConfigIcacheByteSize),
      IcacheSetAssoc: unsigned'(CVA6ConfigIcacheSetAssoc),
      IcacheLineWidth: unsigned'(CVA6ConfigIcacheLineWidth),
      DCacheType: CVA6ConfigDcacheType,
      DcacheByteSize: unsigned'(CVA6ConfigDcacheByteSize),
      DcacheSetAssoc: unsigned'(CVA6ConfigDcacheSetAssoc),
      DcacheLineWidth: unsigned'(CVA6ConfigDcacheLineWidth),
      DcacheFlushOnFence: unsigned'(CVA6ConfigDcacheFlushOnFence),
      DcacheFlushOnFenceI: unsigned'(CVA6ConfigDcacheFlushOnFenceI),
      DcacheInvalidateOnFlush: unsigned'(CVA6ConfigDcacheInvalidateOnFlush),
      DataUserEn: unsigned'(CVA6ConfigDataUserEn),
      WtDcacheWbufDepth: int'(CVA6ConfigWtDcacheWbufDepth),
      FetchUserWidth: unsigned'(CVA6ConfigFetchUserWidth),
      FetchUserEn: unsigned'(CVA6ConfigFetchUserEn),
      InstrTlbEntries: int'(16),
      DataTlbEntries: int'(16),
      UseSharedTlb: bit'(0),
      SvnapotEn: bit'(1),
      SharedTlbDepth: int'(64),
      NrLoadPipeRegs: int'(CVA6ConfigNrLoadPipeRegs),
      NrStorePipeRegs: int'(CVA6ConfigNrStorePipeRegs),
      DcacheIdWidth: int'(CVA6ConfigDcacheIdWidth)
  };

endpackage
