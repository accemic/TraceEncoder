// Generator : SpinalHDL dev    git head : b4412ad3871dc6d7164fb726b30106dde25312e1
// Component : TGC5B_AXI4L_H2E
// Git hash  : 1c0c57ebccdb2e867d6e6c68ad4fc03e37fbe819
// Date      : 09/06/2026, 12:31:13
// ==================================================
// MINRES© TGC-CG
// Copyright 2020-2022 MINRES© Technologies GmbH
// Core config: TGC5B_AXI4L_H2E (hash: ecababb8345510fc9133035ddf2a3116ca7a57bf)

`timescale 1ns/1ps

module TGC5B_AXI4L_H2E (
  input  wire [31:0]   reset_vector_i,
  output reg  [3:0]    h2e_inst_itype_o,
  output wire [3:0]    h2e_inst_cause_o,
  output wire [31:0]   h2e_inst_tval_o,
  output reg  [2:0]    h2e_inst_priv_o,
  output wire [31:0]   h2e_inst_iaddr_o,
  output wire [1:0]    h2e_inst_context_o,
  output wire [63:0]   h2e_inst_time_o,
  output wire [1:0]    h2e_inst_ctype_o,
  output wire          h2e_inst_iretire_o,
  output wire [1:0]    h2e_inst_ilastsize_o,
  output reg  [3:0]    h2e_data_dtype_o,
  output reg  [31:0]   h2e_data_daddr_o,
  output reg  [7:0]    h2e_data_dsize_o,
  output reg           h2e_data_dretire_o,
  output reg  [31:0]   h2e_data_sdata_o,
  output reg  [1:0]    h2e_data_lresp_o,
  output reg  [31:0]   h2e_data_ldata_o,
  input  wire          h2e_stall_req_i,
  output wire          h2e_stall_gnt_o,
  output reg           wfi_o,
  output wire          idle_o,
  input  wire [63:0]   mtime_i,
  input  wire          tim_irq_i,
  input  wire          sw_irq_i,
  input  wire          ext_irq_i,
  output wire [31:0]   core_trace_instr_o,
  output wire [31:0]   core_trace_pc_o,
  output wire          core_trace_valid_o,
  output wire          core_trace_irq_o,
  output wire          core_trace_exc_o,
  output wire [3:0]    core_trace_exccode_o,
  output wire [4:0]    core_trace_reg_addr_o,
  output wire          core_trace_reg_wr_o,
  output wire [31:0]   core_trace_reg_val_o,
  output wire          iBusAxiL_arvalid,
  input  wire          iBusAxiL_arready,
  output wire [31:0]   iBusAxiL_araddr,
  output wire [2:0]    iBusAxiL_arprot,
  input  wire          iBusAxiL_rvalid,
  output wire          iBusAxiL_rready,
  input  wire [31:0]   iBusAxiL_rdata,
  input  wire [1:0]    iBusAxiL_rresp,
  output wire          dBusAxiL_awvalid,
  input  wire          dBusAxiL_awready,
  output wire [31:0]   dBusAxiL_awaddr,
  output wire [2:0]    dBusAxiL_awprot,
  output wire          dBusAxiL_wvalid,
  input  wire          dBusAxiL_wready,
  output wire [31:0]   dBusAxiL_wdata,
  output wire [3:0]    dBusAxiL_wstrb,
  input  wire          dBusAxiL_bvalid,
  output wire          dBusAxiL_bready,
  input  wire [1:0]    dBusAxiL_bresp,
  output wire          dBusAxiL_arvalid,
  input  wire          dBusAxiL_arready,
  output wire [31:0]   dBusAxiL_araddr,
  output wire [2:0]    dBusAxiL_arprot,
  input  wire          dBusAxiL_rvalid,
  output wire          dBusAxiL_rready,
  input  wire [31:0]   dBusAxiL_rdata,
  input  wire [1:0]    dBusAxiL_rresp,
  input  wire          clk,
  input  wire          reset
);
  localparam BranchCtrlEnum_INC = 2'd0;
  localparam BranchCtrlEnum_B = 2'd1;
  localparam BranchCtrlEnum_JAL = 2'd2;
  localparam BranchCtrlEnum_JALR = 2'd3;
  localparam EnvCtrl_NONE = 3'd0;
  localparam EnvCtrl_XRET = 3'd1;
  localparam EnvCtrl_DRET = 3'd2;
  localparam EnvCtrl_WFI = 3'd3;
  localparam EnvCtrl_ECALL = 3'd4;
  localparam EnvCtrl_EBREAK = 3'd5;
  localparam AluBitwiseCtrl_XOR_1 = 2'd0;
  localparam AluBitwiseCtrl_OR_1 = 2'd1;
  localparam AluBitwiseCtrl_AND_1 = 2'd2;
  localparam AluCtrl_ADD_SUB = 2'd0;
  localparam AluCtrl_SLT_SLTU = 2'd1;
  localparam AluCtrl_BITWISE = 2'd2;
  localparam Src2Ctrl_RS = 2'd0;
  localparam Src2Ctrl_IMI = 2'd1;
  localparam Src2Ctrl_IMS = 2'd2;
  localparam Src2Ctrl_PC = 2'd3;
  localparam Src1Ctrl_RS = 2'd0;
  localparam Src1Ctrl_IMU = 2'd1;
  localparam Src1Ctrl_PC_INCREMENT = 2'd2;
  localparam Src1Ctrl_URS1 = 2'd3;

  wire                IBusSimple_rspJoin_rspBuffer_c_io_pop_ready;
  wire                IBusSimple_rspJoin_rspBuffer_c_io_push_ready;
  wire                IBusSimple_rspJoin_rspBuffer_c_io_pop_valid;
  wire                IBusSimple_rspJoin_rspBuffer_c_io_pop_payload_error;
  wire       [31:0]   IBusSimple_rspJoin_rspBuffer_c_io_pop_payload_data;
  wire       [0:0]    IBusSimple_rspJoin_rspBuffer_c_io_occupancy;
  wire       [0:0]    IBusSimple_rspJoin_rspBuffer_c_io_availability;
  wire       [31:0]   __decode_LEGAL_INSTRUCTION;
  wire       [31:0]   __decode_LEGAL_INSTRUCTION_1;
  wire       [31:0]   __decode_LEGAL_INSTRUCTION_2;
  wire                __decode_LEGAL_INSTRUCTION_3;
  wire       [0:0]    __decode_LEGAL_INSTRUCTION_4;
  wire       [12:0]   __decode_LEGAL_INSTRUCTION_5;
  wire       [31:0]   __decode_LEGAL_INSTRUCTION_6;
  wire       [31:0]   __decode_LEGAL_INSTRUCTION_7;
  wire       [31:0]   __decode_LEGAL_INSTRUCTION_8;
  wire                __decode_LEGAL_INSTRUCTION_9;
  wire       [0:0]    __decode_LEGAL_INSTRUCTION_10;
  wire       [6:0]    __decode_LEGAL_INSTRUCTION_11;
  wire       [31:0]   __decode_LEGAL_INSTRUCTION_12;
  wire       [31:0]   __decode_LEGAL_INSTRUCTION_13;
  wire       [31:0]   __decode_LEGAL_INSTRUCTION_14;
  wire                __decode_LEGAL_INSTRUCTION_15;
  wire       [0:0]    __decode_LEGAL_INSTRUCTION_16;
  wire       [0:0]    __decode_LEGAL_INSTRUCTION_17;
  wire       [31:0]   __execute_BRANCH_TARGET;
  wire       [1:0]    __IBusSimple_jump_pcLoad_payload_1;
  wire       [1:0]    __IBusSimple_jump_pcLoad_payload_2;
  wire       [31:0]   __IBusSimple_fetchPc_pc;
  wire       [2:0]    __IBusSimple_fetchPc_pc_1;
  wire       [2:0]    __IBusSimple_pending_next;
  wire       [2:0]    __IBusSimple_pending_next_1;
  wire       [0:0]    __IBusSimple_pending_next_2;
  wire       [2:0]    __IBusSimple_pending_next_3;
  wire       [0:0]    __IBusSimple_pending_next_4;
  wire       [2:0]    __IBusSimple_rspJoin_rspBuffer_discardCounter;
  wire       [0:0]    __IBusSimple_rspJoin_rspBuffer_discardCounter_1;
  wire       [2:0]    __IBusSimple_rspJoin_rspBuffer_discardCounter_2;
  wire       [0:0]    __IBusSimple_rspJoin_rspBuffer_discardCounter_3;
  wire       [0:0]    ____execute_REGFILE_WRITE_DATA;
  wire       [1:0]    ____CsrFile_exceptionPortCtrl_exceptionContext_code_1;
  wire       [1:0]    ____CsrFile_exceptionPortCtrl_exceptionContext_code_1_1;
  wire       [2:0]    ____CsrFile_exceptionPortCtrl_exceptionContext_code_3;
  wire                __when;
  wire                __when_1;
  reg        [3:0]    __CsrFile_exceptionPortCtrl_exceptionContext_code_7;
  reg        [31:0]   __CsrFile_exceptionPortCtrl_exceptionContext_mtval;
  reg        [31:0]   __CsrFile_exceptionPortCtrl_exceptionContext_pc;
  wire       [29:0]   __CsrFile_irq_payload_targetAddr;
  wire       [29:0]   __CsrFile_irq_payload_targetAddr_1;
  wire       [2:0]    ____execute_SRC1;
  wire       [4:0]    ____execute_SRC1_1;
  wire       [11:0]   ____execute_SRC2_2;
  wire       [31:0]   __execute_SrcSelector_add;
  wire       [31:0]   __execute_SrcSelector_sub;
  wire       [19:0]   ____branchSrc2;
  wire       [11:0]   ____branchSrc2_4;
  wire       [2:0]    __DBusSimple_memoryExceptionPort_payload_code;
  wire       [2:0]    __DBusSimple_memoryExceptionPort_payload_code_1;
  wire                __execute_BarrelShifter_reversed;
  wire       [0:0]    __execute_BarrelShifter_reversed_1;
  wire       [23:0]   __execute_BarrelShifter_reversed_2;
  wire                __execute_BarrelShifter_reversed_3;
  wire       [0:0]    __execute_BarrelShifter_reversed_4;
  wire       [12:0]   __execute_BarrelShifter_reversed_5;
  wire                __execute_BarrelShifter_reversed_6;
  wire       [0:0]    __execute_BarrelShifter_reversed_7;
  wire       [1:0]    __execute_BarrelShifter_reversed_8;
  wire       [32:0]   __execute_BarrelShifter_shifted;
  wire       [32:0]   __execute_BarrelShifter_shifted_1;
  wire       [31:0]   ____decode_SHIFT_SIGNED;
  wire       [31:0]   ____decode_SHIFT_SIGNED_1;
  wire       [31:0]   ____decode_SHIFT_SIGNED_2;
  wire                ____decode_SHIFT_SIGNED_3;
  wire       [0:0]    ____decode_SHIFT_SIGNED_4;
  wire                ____decode_SHIFT_SIGNED_5;
  wire       [31:0]   ____decode_SHIFT_SIGNED_6;
  wire       [0:0]    ____decode_SHIFT_SIGNED_7;
  wire       [0:0]    ____decode_SHIFT_SIGNED_8;
  wire       [31:0]   ____decode_SHIFT_SIGNED_9;
  wire       [0:0]    ____decode_SHIFT_SIGNED_10;
  wire       [31:0]   ____decode_SHIFT_SIGNED_11;
  wire       [21:0]   ____decode_SHIFT_SIGNED_12;
  wire                ____decode_SHIFT_SIGNED_13;
  wire       [0:0]    ____decode_SHIFT_SIGNED_14;
  wire       [31:0]   ____decode_SHIFT_SIGNED_15;
  wire                ____decode_SHIFT_SIGNED_16;
  wire       [31:0]   ____decode_SHIFT_SIGNED_17;
  wire       [31:0]   ____decode_SHIFT_SIGNED_18;
  wire       [0:0]    ____decode_SHIFT_SIGNED_19;
  wire       [0:0]    ____decode_SHIFT_SIGNED_20;
  wire       [31:0]   ____decode_SHIFT_SIGNED_21;
  wire       [0:0]    ____decode_SHIFT_SIGNED_22;
  wire       [31:0]   ____decode_SHIFT_SIGNED_23;
  wire       [17:0]   ____decode_SHIFT_SIGNED_24;
  wire       [5:0]    ____decode_SHIFT_SIGNED_25;
  wire       [31:0]   ____decode_SHIFT_SIGNED_26;
  wire       [31:0]   ____decode_SHIFT_SIGNED_27;
  wire                ____decode_SHIFT_SIGNED_28;
  wire       [31:0]   ____decode_SHIFT_SIGNED_29;
  wire       [0:0]    ____decode_SHIFT_SIGNED_30;
  wire       [31:0]   ____decode_SHIFT_SIGNED_31;
  wire       [31:0]   ____decode_SHIFT_SIGNED_32;
  wire       [2:0]    ____decode_SHIFT_SIGNED_33;
  wire                ____decode_SHIFT_SIGNED_34;
  wire       [0:0]    ____decode_SHIFT_SIGNED_35;
  wire       [31:0]   ____decode_SHIFT_SIGNED_36;
  wire       [0:0]    ____decode_SHIFT_SIGNED_37;
  wire       [31:0]   ____decode_SHIFT_SIGNED_38;
  wire                ____decode_SHIFT_SIGNED_39;
  wire                ____decode_SHIFT_SIGNED_40;
  wire       [31:0]   ____decode_SHIFT_SIGNED_41;
  wire                ____decode_SHIFT_SIGNED_42;
  wire       [31:0]   ____decode_SHIFT_SIGNED_43;
  wire       [0:0]    ____decode_SHIFT_SIGNED_44;
  wire                ____decode_SHIFT_SIGNED_45;
  wire       [31:0]   ____decode_SHIFT_SIGNED_46;
  wire       [14:0]   ____decode_SHIFT_SIGNED_47;
  wire       [0:0]    ____decode_SHIFT_SIGNED_48;
  wire       [31:0]   ____decode_SHIFT_SIGNED_49;
  wire       [31:0]   ____decode_SHIFT_SIGNED_50;
  wire                ____decode_SHIFT_SIGNED_51;
  wire                ____decode_SHIFT_SIGNED_52;
  wire       [0:0]    ____decode_SHIFT_SIGNED_53;
  wire       [1:0]    ____decode_SHIFT_SIGNED_54;
  wire       [31:0]   ____decode_SHIFT_SIGNED_55;
  wire       [31:0]   ____decode_SHIFT_SIGNED_56;
  wire       [31:0]   ____decode_SHIFT_SIGNED_57;
  wire       [31:0]   ____decode_SHIFT_SIGNED_58;
  wire       [11:0]   ____decode_SHIFT_SIGNED_59;
  wire                ____decode_SHIFT_SIGNED_60;
  wire                ____decode_SHIFT_SIGNED_61;
  wire       [0:0]    ____decode_SHIFT_SIGNED_62;
  wire       [31:0]   ____decode_SHIFT_SIGNED_63;
  wire       [0:0]    ____decode_SHIFT_SIGNED_64;
  wire       [31:0]   ____decode_SHIFT_SIGNED_65;
  wire       [0:0]    ____decode_SHIFT_SIGNED_66;
  wire                ____decode_SHIFT_SIGNED_67;
  wire       [9:0]    ____decode_SHIFT_SIGNED_68;
  wire       [0:0]    ____decode_SHIFT_SIGNED_69;
  wire       [31:0]   ____decode_SHIFT_SIGNED_70;
  wire                ____decode_SHIFT_SIGNED_71;
  wire                ____decode_SHIFT_SIGNED_72;
  wire                ____decode_SHIFT_SIGNED_73;
  wire       [0:0]    ____decode_SHIFT_SIGNED_74;
  wire       [0:0]    ____decode_SHIFT_SIGNED_75;
  wire       [31:0]   ____decode_SHIFT_SIGNED_76;
  wire       [2:0]    ____decode_SHIFT_SIGNED_77;
  wire       [31:0]   ____decode_SHIFT_SIGNED_78;
  wire       [31:0]   ____decode_SHIFT_SIGNED_79;
  wire                ____decode_SHIFT_SIGNED_80;
  wire                ____decode_SHIFT_SIGNED_81;
  wire       [6:0]    ____decode_SHIFT_SIGNED_82;
  wire       [0:0]    ____decode_SHIFT_SIGNED_83;
  wire       [31:0]   ____decode_SHIFT_SIGNED_84;
  wire                ____decode_SHIFT_SIGNED_85;
  wire       [0:0]    ____decode_SHIFT_SIGNED_86;
  wire       [31:0]   ____decode_SHIFT_SIGNED_87;
  wire       [0:0]    ____decode_SHIFT_SIGNED_88;
  wire       [31:0]   ____decode_SHIFT_SIGNED_89;
  wire       [0:0]    ____decode_SHIFT_SIGNED_90;
  wire       [0:0]    ____decode_SHIFT_SIGNED_91;
  wire       [31:0]   ____decode_SHIFT_SIGNED_92;
  wire       [4:0]    ____decode_SHIFT_SIGNED_93;
  wire       [31:0]   ____decode_SHIFT_SIGNED_94;
  wire       [31:0]   ____decode_SHIFT_SIGNED_95;
  wire       [0:0]    ____decode_SHIFT_SIGNED_96;
  wire       [1:0]    ____decode_SHIFT_SIGNED_97;
  wire       [3:0]    ____decode_SHIFT_SIGNED_98;
  wire       [1:0]    ____decode_SHIFT_SIGNED_99;
  wire       [31:0]   ____decode_SHIFT_SIGNED_100;
  wire       [31:0]   ____decode_SHIFT_SIGNED_101;
  wire                ____decode_SHIFT_SIGNED_102;
  wire                ____decode_SHIFT_SIGNED_103;
  wire       [0:0]    ____decode_SHIFT_SIGNED_104;
  wire       [0:0]    ____decode_SHIFT_SIGNED_105;
  wire       [0:0]    ____decode_SHIFT_SIGNED_106;
  wire       [0:0]    ____decode_SHIFT_SIGNED_107;
  wire       [0:0]    ____decode_SHIFT_SIGNED_108;
  wire       [0:0]    ____decode_SHIFT_SIGNED_109;
  wire       [31:0]   execute_REGFILE_WRITE_DATA /* verilator public */ ;
  wire                decode_SHIFT_SIGNED /* verilator public */ ;
  wire                decode_SHIFT_LEFT /* verilator public */ ;
  wire                decode_DO_SHIFT /* verilator public */ ;
  wire                decode_MEMORY_STORE /* verilator public */ ;
  wire                decode_MEMORY_ENABLE /* verilator public */ ;
  wire       [1:0]    decode_BRANCH_CTRL /* verilator public */ ;
  wire       [1:0]    __decode_BRANCH_CTRL;
  wire       [1:0]    __decode_to_execute_BRANCH_CTRL;
  wire       [1:0]    __decode_to_execute_BRANCH_CTRL_1;
  wire       [2:0]    decode_ENV_CTRL /* verilator public */ ;
  wire       [2:0]    __decode_ENV_CTRL;
  wire       [2:0]    __decode_to_execute_ENV_CTRL;
  wire       [2:0]    __decode_to_execute_ENV_CTRL_1;
  wire                decode_IS_CSR /* verilator public */ ;
  wire       [1:0]    decode_ALU_BITWISE_CTRL /* verilator public */ ;
  wire       [1:0]    __decode_ALU_BITWISE_CTRL;
  wire       [1:0]    __decode_to_execute_ALU_BITWISE_CTRL;
  wire       [1:0]    __decode_to_execute_ALU_BITWISE_CTRL_1;
  wire                decode_SRC_LESS_UNSIGNED /* verilator public */ ;
  wire       [1:0]    decode_ALU_CTRL /* verilator public */ ;
  wire       [1:0]    __decode_ALU_CTRL;
  wire       [1:0]    __decode_to_execute_ALU_CTRL;
  wire       [1:0]    __decode_to_execute_ALU_CTRL_1;
  wire                decode_RS2_USE /* verilator public */ ;
  wire                decode_RS1_USE /* verilator public */ ;
  wire                execute_REGFILE_WRITE_VALID /* verilator public */ ;
  wire       [1:0]    decode_SRC2_CTRL /* verilator public */ ;
  wire       [1:0]    __decode_SRC2_CTRL;
  wire       [1:0]    __decode_to_execute_SRC2_CTRL;
  wire       [1:0]    __decode_to_execute_SRC2_CTRL_1;
  wire       [1:0]    decode_SRC1_CTRL /* verilator public */ ;
  wire       [1:0]    __decode_SRC1_CTRL;
  wire       [1:0]    __decode_to_execute_SRC1_CTRL;
  wire       [1:0]    __decode_to_execute_SRC1_CTRL_1;
  wire                decode_CSR_READ_OPCODE /* verilator public */ ;
  wire                decode_CSR_WRITE_OPCODE /* verilator public */ ;
  wire       [31:0]   decode_PC /* verilator public */ ;
  wire                decode_LEGAL_INSTRUCTION;
  wire                decode_INSTRUCTION_READY;
  wire       [1:0]    __decode_BRANCH_CTRL_1;
  wire       [2:0]    __decode_ENV_CTRL_1;
  wire       [1:0]    __decode_ALU_BITWISE_CTRL_1;
  wire       [1:0]    __decode_ALU_CTRL_1;
  wire       [1:0]    __decode_SRC2_CTRL_1;
  wire       [1:0]    __decode_SRC1_CTRL_1;
  wire       [31:0]   execute_SHIFTED_SRC1;
  wire                execute_DO_SHIFT;
  wire                execute_SHIFT_SIGNED;
  wire                execute_SHIFT_LEFT;
  wire                execute_RS2_USE;
  wire                execute_RS1_USE;
  wire       [31:0]   execute_MEMORY_READ_DATA;
  wire                execute_ACCESS_FAULT;
  wire       [31:0]   execute_MEMORY_ADDRESS;
  wire       [31:0]   execute_SRC_ADD;
  reg        [31:0]   execute_RS2 /* verilator public */ ;
  wire                execute_MEMORY_STORE;
  wire                execute_MEMORY_ENABLE;
  wire                execute_ALIGNEMENT_FAULT;
  wire                execute_IS_FENCEI;
  reg        [31:0]   __decode_to_execute_INSTRUCTION;
  wire                decode_IS_FENCEI /* verilator public */ ;
  wire       [31:0]   execute_BRANCH_TARGET;
  wire                execute_BRANCH_DO /* verilator public */ ;
  reg        [31:0]   execute_RS1 /* verilator public */ ;
  wire       [1:0]    execute_BRANCH_CTRL /* verilator public */ ;
  wire       [1:0]    __execute_BRANCH_CTRL;
  wire                execute_SRC_USE_SUB_LESS;
  wire                execute_SRC_LESS_UNSIGNED;
  wire                execute_SRC_ADD_ZERO;
  wire       [1:0]    execute_SRC2_CTRL;
  wire       [1:0]    __execute_SRC2_CTRL;
  wire       [1:0]    execute_SRC1_CTRL;
  wire       [1:0]    __execute_SRC1_CTRL;
  wire                decode_SRC_USE_SUB_LESS /* verilator public */ ;
  wire                decode_SRC_ADD_ZERO /* verilator public */ ;
  wire                execute_CSR_READ_OPCODE;
  wire                execute_CSR_WRITE_OPCODE;
  wire                execute_IS_CSR;
  wire       [31:0]   execute_SRC_ADD_SUB;
  wire                execute_SRC_LESS;
  wire       [1:0]    execute_ALU_CTRL;
  wire       [1:0]    __execute_ALU_CTRL;
  wire       [31:0]   execute_SRC2;
  wire       [31:0]   execute_SRC1;
  wire       [1:0]    execute_ALU_BITWISE_CTRL;
  wire       [1:0]    __execute_ALU_BITWISE_CTRL;
  reg        [31:0]   execute_RegisterFileReg_data;
  wire                __execute_RegisterFileReg_valid;
  reg                 decode_REGFILE_WRITE_VALID /* verilator public */ ;
  wire       [31:0]   decode_INSTRUCTION /* verilator public */ ;
  wire       [31:0]   __execute_RegisterFileReg_address;
  wire                __when_H2E_l75;
  wire       [1:0]    __when_H2E_l82;
  wire       [1:0]    __when_H2E_l82_1;
  wire       [2:0]    execute_ENV_CTRL;
  wire       [2:0]    __execute_ENV_CTRL;
  wire       [31:0]   execute_PC /* verilator public */ ;
  wire       [31:0]   execute_INSTRUCTION /* verilator public */ ;
  reg                 decode_arbitration_haltItself;
  reg                 decode_arbitration_haltByOther;
  reg                 decode_arbitration_removeIt;
  wire                decode_arbitration_flushIt;
  reg                 decode_arbitration_flushNext;
  reg                 decode_arbitration_isValid;
  wire                decode_arbitration_isStuck;
  wire                decode_arbitration_isStuckByOthers;
  wire                decode_arbitration_isFlushed;
  wire                decode_arbitration_isMoving;
  wire                decode_arbitration_isFiring;
  wire                decode_arbitration_isRegFSpawn;
  wire                decode_arbitration_flushItSV;
  wire                decode_arbitration_isFlushedNonSV;
  reg                 execute_arbitration_haltItself;
  reg                 execute_arbitration_haltByOther;
  reg                 execute_arbitration_removeIt;
  wire                execute_arbitration_flushIt;
  reg                 execute_arbitration_flushNext;
  reg                 execute_arbitration_isValid;
  wire                execute_arbitration_isStuck;
  wire                execute_arbitration_isStuckByOthers;
  wire                execute_arbitration_isFlushed;
  wire                execute_arbitration_isMoving;
  wire                execute_arbitration_isFiring;
  wire                execute_arbitration_isRegFSpawn;
  wire                execute_arbitration_flushItSV;
  wire                execute_arbitration_isFlushedNonSV;
  wire       [31:0]   lastStageInstruction /* verilator public */ ;
  wire       [31:0]   lastStagePc /* verilator public */ ;
  wire                lastStageIsValid /* verilator public */ ;
  wire                lastStageIsFiring /* verilator public */ ;
  reg                 IBusSimple_fetcherHalt;
  wire                IBusSimple_forceNoDecodeCond;
  reg                 IBusSimple_incomingInstruction;
  wire                IBusSimple_pcValids_0;
  wire                IBusSimple_pcValids_1;
  wire                iBus_cmd_valid;
  wire                iBus_cmd_ready;
  wire       [31:0]   iBus_cmd_payload_addr;
  wire                iBus_rsp_valid;
  wire                iBus_rsp_payload_error;
  wire       [31:0]   iBus_rsp_payload_data;
  wire                IBusSimple_instrFetchExceptionPort_valid;
  reg        [3:0]    IBusSimple_instrFetchExceptionPort_payload_code;
  wire       [31:0]   IBusSimple_instrFetchExceptionPort_payload_mtval;
  wire       [31:0]   IBusSimple_instrFetchExceptionPort_payload_pc;
  reg        [31:0]   __execute_RegisterFileReg_data;
  reg        [31:0]   __execute_RegisterFileReg_data_1;
  wire       [31:0]   __CsrFile_mtvec_mode;
  wire                CsrFile_writeEnable;
  wire                CsrFile_readEnable;
  reg                 CsrFile_jumpInterface_valid;
  reg        [31:0]   CsrFile_jumpInterface_payload;
  wire                CsrFile_thirdPartyWake;
  wire                CsrFile_exceptionPendings_0;
  wire                CsrFile_exceptionPendings_1;
  wire                contextSwitching;
  reg        [1:0]    CsrPlugin_privilege;
  wire                CsrFile_forceMachineWire;
  reg                 CsrFile_selfException_valid;
  reg        [3:0]    CsrFile_selfException_payload_code;
  reg        [31:0]   CsrFile_selfException_payload_mtval;
  wire       [31:0]   CsrFile_selfException_payload_pc;
  wire                CsrFile_allowInterrupts;
  wire                CsrFile_allowException;
  wire       [3:0]    CsrFile_cause;
  wire       [31:0]   CsrFile_tval;
  wire       [1:0]    CsrFile_context;
  wire       [63:0]   CsrFile_time;
  wire       [63:0]   CsrFile_cycle;
  wire                Branch_jumpInterface_valid;
  wire       [31:0]   Branch_jumpInterface_payload;
  reg                 Branch_branchExceptionPort_valid;
  wire       [3:0]    Branch_branchExceptionPort_payload_code;
  wire       [31:0]   Branch_branchExceptionPort_payload_mtval;
  wire       [31:0]   Branch_branchExceptionPort_payload_pc;
  wire                Branch_inDebugNoFetchFlag;
  reg                 DBusSimple_memoryExceptionPort_valid;
  reg        [3:0]    DBusSimple_memoryExceptionPort_payload_code;
  wire       [31:0]   DBusSimple_memoryExceptionPort_payload_mtval;
  wire       [31:0]   DBusSimple_memoryExceptionPort_payload_pc;
  wire                sharedDBus_cmd_valid;
  wire                sharedDBus_cmd_ready;
  wire                sharedDBus_cmd_payload_wr;
  wire       [31:0]   sharedDBus_cmd_payload_address;
  wire       [31:0]   sharedDBus_cmd_payload_data;
  wire       [1:0]    sharedDBus_cmd_payload_size;
  wire                sharedDBus_rsp_ready;
  wire                sharedDBus_rsp_error;
  wire       [31:0]   sharedDBus_rsp_data;
  wire                cdDBus_cmd_valid;
  wire                cdDBus_cmd_ready;
  wire                cdDBus_cmd_payload_wr;
  wire       [31:0]   cdDBus_cmd_payload_address;
  wire       [31:0]   cdDBus_cmd_payload_data;
  wire       [1:0]    cdDBus_cmd_payload_size;
  wire                cdDBus_rsp_ready;
  wire                cdDBus_rsp_error;
  wire       [31:0]   cdDBus_rsp_data;
  wire                dBus_cmd_valid;
  wire                dBus_cmd_ready;
  wire                dBus_cmd_payload_wr;
  wire       [31:0]   dBus_cmd_payload_address;
  wire       [31:0]   dBus_cmd_payload_data;
  wire       [1:0]    dBus_cmd_payload_size;
  wire                dBus_rsp_ready;
  wire                dBus_rsp_error;
  wire       [31:0]   dBus_rsp_data;
  wire                decodeExceptionPort_valid;
  wire       [3:0]    decodeExceptionPort_payload_code;
  wire       [31:0]   decodeExceptionPort_payload_mtval;
  wire       [31:0]   decodeExceptionPort_payload_pc;
  wire                IBusSimple_externalFlush;
  wire                IBusSimple_jump_pcLoad_valid;
  wire       [31:0]   IBusSimple_jump_pcLoad_payload;
  wire       [1:0]    __IBusSimple_jump_pcLoad_payload;
  wire                IBusSimple_fetchPc_output_valid;
  wire                IBusSimple_fetchPc_output_ready;
  wire       [31:0]   IBusSimple_fetchPc_output_payload;
  reg        [31:0]   IBusSimple_fetchPc_pcReg /* verilator public */ ;
  reg                 IBusSimple_fetchPc_correction;
  reg                 IBusSimple_fetchPc_correctionReg;
  wire                IBusSimple_fetchPc_output_fire;
  wire                IBusSimple_fetchPc_corrected;
  reg                 IBusSimple_fetchPc_pcRegPropagate;
  reg                 IBusSimple_fetchPc_booted;
  reg                 IBusSimple_fetchPc_inc;
  wire                when_InstructionFetch_l139;
  wire                when_InstructionFetch_l139_1;
  reg        [31:0]   IBusSimple_fetchPc_pc;
  wire       [31:0]   IBusSimple_fetchPc_pcSV;
  reg                 IBusSimple_fetchPc_flushed;
  wire                when_InstructionFetch_l186;
  wire                IBusSimple_iBusRsp_redoFetch;
  wire                IBusSimple_iBusRsp_fetchStages_0_input_valid;
  wire                IBusSimple_iBusRsp_fetchStages_0_input_ready;
  wire       [31:0]   IBusSimple_iBusRsp_fetchStages_0_input_payload;
  wire                IBusSimple_iBusRsp_fetchStages_0_output_valid;
  wire                IBusSimple_iBusRsp_fetchStages_0_output_ready;
  wire       [31:0]   IBusSimple_iBusRsp_fetchStages_0_output_payload;
  reg                 IBusSimple_iBusRsp_fetchStages_0_halt;
  wire                IBusSimple_iBusRsp_fetchStages_1_input_valid;
  wire                IBusSimple_iBusRsp_fetchStages_1_input_ready;
  wire       [31:0]   IBusSimple_iBusRsp_fetchStages_1_input_payload;
  wire                IBusSimple_iBusRsp_fetchStages_1_output_valid;
  wire                IBusSimple_iBusRsp_fetchStages_1_output_ready;
  wire       [31:0]   IBusSimple_iBusRsp_fetchStages_1_output_payload;
  wire                IBusSimple_iBusRsp_fetchStages_1_halt;
  wire                __IBusSimple_iBusRsp_fetchStages_0_input_ready;
  wire                IBusSimple_iBusRsp_fetchStages_0_input_haltWhen_valid;
  wire                IBusSimple_iBusRsp_fetchStages_0_input_haltWhen_ready;
  wire       [31:0]   IBusSimple_iBusRsp_fetchStages_0_input_haltWhen_payload;
  wire                __IBusSimple_iBusRsp_fetchStages_1_input_ready;
  wire                IBusSimple_iBusRsp_fetchStages_1_input_haltWhen_valid;
  wire                IBusSimple_iBusRsp_fetchStages_1_input_haltWhen_ready;
  wire       [31:0]   IBusSimple_iBusRsp_fetchStages_1_input_haltWhen_payload;
  wire                IBusSimple_iBusRsp_flush;
  wire                IBusSimple_iBusRsp_fetchStages_0_output_toEvent_valid;
  wire                IBusSimple_iBusRsp_fetchStages_0_output_toEvent_ready;
  wire                __IBusSimple_iBusRsp_fetchStages_1_input_valid;
  reg                 __IBusSimple_iBusRsp_fetchStages_1_input_valid_1;
  reg                 IBusSimple_iBusRsp_readyForError;
  wire                IBusSimple_iBusRsp_output_valid;
  wire                IBusSimple_iBusRsp_output_ready;
  wire       [31:0]   IBusSimple_iBusRsp_output_payload_pc;
  wire                IBusSimple_iBusRsp_output_payload_rsp_error;
  wire       [31:0]   IBusSimple_iBusRsp_output_payload_rsp_data;
  wire                IBusSimple_iBusRsp_output_payload_isRvc;
  wire                IBusSimple_iBusRsp_output_payload_legalRvc;
  wire                when_InstructionFetch_l370;
  reg                 IBusSimple_injector_nextPcCalc_valids_0;
  wire                when_InstructionFetch_l379;
  reg                 IBusSimple_injector_nextPcCalc_valids_1;
  wire                when_InstructionFetch_l379_1;
  reg                 IBusSimple_injector_decodeRemoved;
  wire                IBusSimple_cmd_valid;
  wire                IBusSimple_cmd_ready;
  wire       [31:0]   IBusSimple_cmd_payload_addr;
  wire                IBusSimple_cmd_s2mPipe_valid;
  wire                IBusSimple_cmd_s2mPipe_ready;
  wire       [31:0]   IBusSimple_cmd_s2mPipe_payload_addr;
  reg                 IBusSimple_cmd_rValidN;
  reg        [31:0]   IBusSimple_cmd_rData_addr;
  wire                IBusSimple_pending_inc;
  wire                IBusSimple_pending_dec;
  reg        [2:0]    IBusSimple_pending_value;
  wire       [2:0]    IBusSimple_pending_next;
  wire                IBusSimple_cmdFork_canEmit;
  wire                when_IBusSimple_l79;
  wire                IBusSimple_cmd_fire;
  wire                IBusSimple_rspJoin_rspBuffer_output_valid;
  wire                IBusSimple_rspJoin_rspBuffer_output_ready;
  wire                IBusSimple_rspJoin_rspBuffer_output_payload_error;
  wire       [31:0]   IBusSimple_rspJoin_rspBuffer_output_payload_data;
  reg        [2:0]    IBusSimple_rspJoin_rspBuffer_discardCounter;
  wire                iBus_rsp_toStream_valid;
  wire                iBus_rsp_toStream_ready;
  wire                iBus_rsp_toStream_payload_error;
  wire       [31:0]   iBus_rsp_toStream_payload_data;
  wire                IBusSimple_rspJoin_rspBuffer_flush;
  wire                io_pop_fire;
  wire       [31:0]   IBusSimple_rspJoin_fetchRsp_pc;
  reg                 IBusSimple_rspJoin_fetchRsp_rsp_error;
  wire       [31:0]   IBusSimple_rspJoin_fetchRsp_rsp_data;
  wire                IBusSimple_rspJoin_fetchRsp_isRvc;
  wire                IBusSimple_rspJoin_fetchRsp_legalRvc;
  wire                when_IBusSimple_l146;
  wire                IBusSimple_rspJoin_join_valid;
  wire                IBusSimple_rspJoin_join_ready;
  wire       [31:0]   IBusSimple_rspJoin_join_payload_pc;
  wire                IBusSimple_rspJoin_join_payload_rsp_error;
  wire       [31:0]   IBusSimple_rspJoin_join_payload_rsp_data;
  wire                IBusSimple_rspJoin_join_payload_isRvc;
  wire                IBusSimple_rspJoin_join_payload_legalRvc;
  reg                 IBusSimple_rspJoin_exceptionDetected;
  wire                IBusSimple_rspJoin_join_fire;
  wire                __IBusSimple_rspJoin_join_ready;
  wire                IBusSimple_rspJoin_join_haltWhen_valid;
  wire                IBusSimple_rspJoin_join_haltWhen_ready;
  wire       [31:0]   IBusSimple_rspJoin_join_haltWhen_payload_pc;
  wire                IBusSimple_rspJoin_join_haltWhen_payload_rsp_error;
  wire       [31:0]   IBusSimple_rspJoin_join_haltWhen_payload_rsp_data;
  wire                IBusSimple_rspJoin_join_haltWhen_payload_isRvc;
  wire                IBusSimple_rspJoin_join_haltWhen_payload_legalRvc;
  wire       [31:0]   IBusSimple_rspJoin_badAddr;
  wire                when_IBusSimple_l160;
  wire       [4:0]    __when_H2E_l82_2;
  wire       [4:0]    __when_H2E_l82_3;
  wire                when_H2E_l82;
  wire                when_H2E_l84;
  wire                when_H2E_l86;
  wire                when_H2E_l88;
  wire                when_H2E_l90;
  wire                when_H2E_l92;
  wire                when_H2E_l94;
  wire                when_H2E_l96;
  wire                when_H2E_l73;
  wire                when_H2E_l75;
  wire                when_H2E_l77;
  wire                when_H2E_l79;
  wire                when_H2E_l107;
  wire                when_H2E_l109;
  wire                cdDBus_cmd_fire;
  reg        [31:0]   cdDBus_cmd_payload_address_regNextWhen;
  reg        [31:0]   __h2e_data_sdata_o;
  reg        [1:0]    cdDBus_cmd_payload_size_regNextWhen;
  reg                 cdDBus_cmd_payload_wr_regNextWhen;
  reg        [31:0]   execute_INSTRUCTION_regNext;
  reg                 CsrFile_readEnable_regNext;
  reg                 CsrFile_writeEnable_regNext;
  reg                 decode_H2E_stall;
  wire                when_H2E_l203;
  reg                 decode_H2E_idleRegs_0;
  reg                 decode_H2E_idleRegs_1;
  reg        [31:0]   RegisterFileReg_regFile_0 /* verilator public */ ;
  reg        [31:0]   RegisterFileReg_regFile_1 /* verilator public */ ;
  reg        [31:0]   RegisterFileReg_regFile_2 /* verilator public */ ;
  reg        [31:0]   RegisterFileReg_regFile_3 /* verilator public */ ;
  reg        [31:0]   RegisterFileReg_regFile_4 /* verilator public */ ;
  reg        [31:0]   RegisterFileReg_regFile_5 /* verilator public */ ;
  reg        [31:0]   RegisterFileReg_regFile_6 /* verilator public */ ;
  reg        [31:0]   RegisterFileReg_regFile_7 /* verilator public */ ;
  reg        [31:0]   RegisterFileReg_regFile_8 /* verilator public */ ;
  reg        [31:0]   RegisterFileReg_regFile_9 /* verilator public */ ;
  reg        [31:0]   RegisterFileReg_regFile_10 /* verilator public */ ;
  reg        [31:0]   RegisterFileReg_regFile_11 /* verilator public */ ;
  reg        [31:0]   RegisterFileReg_regFile_12 /* verilator public */ ;
  reg        [31:0]   RegisterFileReg_regFile_13 /* verilator public */ ;
  reg        [31:0]   RegisterFileReg_regFile_14 /* verilator public */ ;
  reg        [31:0]   RegisterFileReg_regFile_15 /* verilator public */ ;
  reg        [31:0]   RegisterFileReg_regFile_16 /* verilator public */ ;
  reg        [31:0]   RegisterFileReg_regFile_17 /* verilator public */ ;
  reg        [31:0]   RegisterFileReg_regFile_18 /* verilator public */ ;
  reg        [31:0]   RegisterFileReg_regFile_19 /* verilator public */ ;
  reg        [31:0]   RegisterFileReg_regFile_20 /* verilator public */ ;
  reg        [31:0]   RegisterFileReg_regFile_21 /* verilator public */ ;
  reg        [31:0]   RegisterFileReg_regFile_22 /* verilator public */ ;
  reg        [31:0]   RegisterFileReg_regFile_23 /* verilator public */ ;
  reg        [31:0]   RegisterFileReg_regFile_24 /* verilator public */ ;
  reg        [31:0]   RegisterFileReg_regFile_25 /* verilator public */ ;
  reg        [31:0]   RegisterFileReg_regFile_26 /* verilator public */ ;
  reg        [31:0]   RegisterFileReg_regFile_27 /* verilator public */ ;
  reg        [31:0]   RegisterFileReg_regFile_28 /* verilator public */ ;
  reg        [31:0]   RegisterFileReg_regFile_29 /* verilator public */ ;
  reg        [31:0]   RegisterFileReg_regFile_30 /* verilator public */ ;
  wire       [4:0]    execute_RegisterFileReg_regFileReadAddress1;
  wire       [4:0]    execute_RegisterFileReg_regFileReadAddress2;
  reg        [31:0]   __execute_RS1;
  reg        [31:0]   __execute_RS2;
  wire                when_RegisterFile_l298;
  wire                execute_RegisterFileReg_selAsync;
  wire       [4:0]    execute_RegisterFileReg_address;
  wire                execute_RegisterFileReg_valid;
  wire       [4:0]    __when_RegisterFile_l255;
  wire                when_RegisterFile_l255;
  wire                when_RegisterFile_l255_1;
  wire                when_RegisterFile_l255_2;
  wire                when_RegisterFile_l255_3;
  wire                when_RegisterFile_l255_4;
  wire                when_RegisterFile_l255_5;
  wire                when_RegisterFile_l255_6;
  wire                when_RegisterFile_l255_7;
  wire                when_RegisterFile_l255_8;
  wire                when_RegisterFile_l255_9;
  wire                when_RegisterFile_l255_10;
  wire                when_RegisterFile_l255_11;
  wire                when_RegisterFile_l255_12;
  wire                when_RegisterFile_l255_13;
  wire                when_RegisterFile_l255_14;
  wire                when_RegisterFile_l255_15;
  wire                when_RegisterFile_l255_16;
  wire                when_RegisterFile_l255_17;
  wire                when_RegisterFile_l255_18;
  wire                when_RegisterFile_l255_19;
  wire                when_RegisterFile_l255_20;
  wire                when_RegisterFile_l255_21;
  wire                when_RegisterFile_l255_22;
  wire                when_RegisterFile_l255_23;
  wire                when_RegisterFile_l255_24;
  wire                when_RegisterFile_l255_25;
  wire                when_RegisterFile_l255_26;
  wire                when_RegisterFile_l255_27;
  wire                when_RegisterFile_l255_28;
  wire                when_RegisterFile_l255_29;
  wire                when_RegisterFile_l255_30;
  reg        [31:0]   execute_IntAlu_bitwise;
  reg        [31:0]   __execute_REGFILE_WRITE_DATA;
  wire       [1:0]    CsrFile_misa_base;
  wire       [25:0]   CsrFile_misa_extensions;
  reg        [1:0]    CsrFile_mtvec_mode;
  reg        [3:0]    CsrFile_mtvec_submode;
  reg        [25:0]   CsrFile_mtvec_base;
  reg        [31:0]   CsrFile_mepc;
  reg                 CsrFile_mstatus_MIE;
  reg                 CsrFile_mstatus_MPIE;
  reg        [1:0]    CsrFile_mstatus_MPP;
  reg                 CsrFile_mip_MEIP;
  reg                 CsrFile_mip_MTIP;
  reg                 CsrFile_mip_MSIP;
  reg                 CsrFile_mie_MEIE;
  reg                 CsrFile_mie_MTIE;
  reg                 CsrFile_mie_MSIE;
  reg        [31:0]   CsrFile_mscratch;
  reg                 CsrFile_mcause_interrupt;
  reg        [3:0]    CsrFile_mcause_exceptionCode;
  reg        [31:0]   CsrFile_mtval;
  reg        [63:0]   CsrFile_mcycle;
  reg        [63:0]   CsrFile_minstret;
  reg        [63:0]   CsrFile_mtime;
  wire       [10:0]   __execute_RegisterFileReg_data_2;
  wire       [31:0]   __execute_RegisterFileReg_data_3;
  wire       [0:0]    __execute_RegisterFileReg_data_4;
  wire                __execute_RegisterFileReg_data_5;
  wire       [31:0]   __execute_RegisterFileReg_data_6;
  wire       [31:0]   __execute_RegisterFileReg_data_7;
  wire       [31:0]   __execute_RegisterFileReg_data_8;
  wire       [31:0]   __execute_RegisterFileReg_data_9;
  wire       [31:0]   __execute_RegisterFileReg_data_10;
  wire       [31:0]   __execute_RegisterFileReg_data_11;
  wire       [31:0]   __execute_RegisterFileReg_data_12;
  wire       [31:0]   __execute_RegisterFileReg_data_13;
  wire       [31:0]   __execute_RegisterFileReg_data_14;
  wire       [31:0]   __execute_RegisterFileReg_data_15;
  wire                CsrFile_minstret_write;
  wire                when_CsrFile_l869;
  wire                __when_CsrFile_l993;
  wire                __when_CsrFile_l993_1;
  wire                __when_CsrFile_l993_2;
  reg                 CsrFile_exceptionPortCtrl_exceptionValids_decode;
  reg                 CsrFile_exceptionPortCtrl_exceptionValids_execute;
  reg                 CsrFile_exceptionPortCtrl_exceptionValidsRegs_decode;
  reg                 CsrFile_exceptionPortCtrl_exceptionValidsRegs_execute;
  reg        [3:0]    CsrFile_exceptionPortCtrl_exceptionContext_code;
  reg        [31:0]   CsrFile_exceptionPortCtrl_exceptionContext_mtval;
  reg        [31:0]   CsrFile_exceptionPortCtrl_exceptionContext_pc;
  wire       [1:0]    CsrFile_exceptionPortCtrl_exceptionTargetPrivilegeUncapped;
  wire       [1:0]    CsrFile_exceptionPortCtrl_exceptionTargetPrivilege;
  wire       [1:0]    __CsrFile_exceptionPortCtrl_exceptionContext_code;
  wire                __CsrFile_exceptionPortCtrl_exceptionContext_code_1;
  wire       [2:0]    __CsrFile_exceptionPortCtrl_exceptionContext_code_2;
  wire       [2:0]    __CsrFile_exceptionPortCtrl_exceptionContext_code_3;
  wire                __CsrFile_exceptionPortCtrl_exceptionContext_code_4;
  wire                __CsrFile_exceptionPortCtrl_exceptionContext_code_5;
  wire       [1:0]    __CsrFile_exceptionPortCtrl_exceptionContext_code_6;
  wire                when_CsrFile_l951;
  wire                when_CsrFile_l951_1;
  wire                when_CsrFile_l966;
  reg                 CsrFile_clint_valid;
  reg        [3:0]    CsrFile_clint_code /* verilator public */ ;
  reg        [1:0]    CsrFile_clint_targetPrivilege;
  wire                when_CsrFile_l987;
  wire                when_CsrFile_l993;
  wire                when_CsrFile_l993_1;
  wire                when_CsrFile_l993_2;
  wire                CsrFile_exception;
  reg                 CsrFile_lastStageWasWfi;
  reg                 CsrFile_irq_valid;
  wire       [3:0]    CsrFile_irq_payload_code;
  wire       [1:0]    CsrFile_irq_payload_targetPrivilege;
  wire       [31:0]   CsrFile_irq_payload_targetAddr;
  reg        [1:0]    CsrFile_xtvec_mode;
  reg        [3:0]    CsrFile_xtvec_submode;
  reg        [25:0]   CsrFile_xtvec_base;
  wire       [29:0]   CsrFile_xtvecBase;
  reg                 CsrFile_pendingIrq_valid;
  reg        [3:0]    CsrFile_pendingIrq_payload_code;
  reg        [1:0]    CsrFile_pendingIrq_payload_targetPrivilege;
  reg        [31:0]   CsrFile_pendingIrq_payload_targetAddr;
  reg                 CsrFile_irq_valid_delayed;
  wire                when_CsrFile_l1052;
  reg                 CsrFile_pipelineFlush_pcValids_0;
  wire                CsrFile_pipelineFlush_active;
  wire                when_CsrFile_l1063;
  wire                when_CsrFile_l1068;
  reg                 CsrFile_pipelineFlush_done;
  wire                when_CsrFile_l1073;
  wire                when_CsrFile_l1074;
  wire                CsrFile_interruptJump /* verilator public */ ;
  reg                 CsrFile_hadException /* verilator public */ ;
  reg        [1:0]    CsrFile_targetPrivilege;
  reg        [3:0]    CsrFile_trapCause;
  wire                CsrFile_trapCauseEbreakDebug;
  reg        [1:0]    CsrFile_excXtvec_mode;
  reg        [3:0]    CsrFile_excXtvec_submode;
  reg        [25:0]   CsrFile_excXtvec_base;
  wire                CsrFile_trapEnterDebug;
  wire                when_CsrFile_l1126;
  wire                when_CsrFile_l1137;
  wire                when_CsrFile_l1196;
  wire       [1:0]    switch_CsrFile_l1200;
  reg                 execute_CsrFile_wfiWake;
  wire                when_CsrFile_l1258;
  wire                when_CsrFile_l1262;
  reg                 __idle_o;
  reg                 __idle_o_1;
  wire                when_CsrFile_l1275;
  wire                execute_CsrFile_blockedBySideEffects;
  reg                 execute_CsrFile_illegalAccess;
  reg                 execute_CsrFile_illegalInstruction;
  wire                when_CsrFile_l1292;
  wire                when_CsrFile_l1300;
  wire                when_CsrFile_l1301;
  wire                when_CsrFile_l1307;
  wire                when_CsrFile_l1315;
  reg                 execute_CsrFile_writeInstruction;
  reg                 execute_CsrFile_readInstruction;
  wire       [31:0]   execute_CsrFile_readToWriteData;
  wire                switch_Misc_l245;
  reg        [31:0]   __CsrFile_mtvec_mode_1;
  wire                when_CsrFile_l1359;
  wire       [11:0]   execute_CsrFile_csrAddress;
  reg        [31:0]   __execute_SRC1;
  wire                __execute_SRC2;
  reg        [19:0]   __execute_SRC2_1;
  wire                __execute_SRC2_2;
  reg        [19:0]   __execute_SRC2_3;
  reg        [31:0]   __execute_SRC2_4;
  (* keep *) reg        [31:0]   execute_SrcSelector_add;
  (* keep *) wire       [31:0]   execute_SrcSelector_sub;
  wire                execute_SrcSelector_less;
  wire                execute_Branch_eq;
  wire       [2:0]    switch_Misc_l245_1;
  reg                 __execute_BRANCH_DO;
  reg                 __execute_BRANCH_DO_1;
  wire       [31:0]   branchSrc1;
  wire                __branchSrc2;
  reg        [10:0]   __branchSrc2_1;
  wire                __branchSrc2_2;
  reg        [19:0]   __branchSrc2_3;
  wire                __branchSrc2_4;
  reg        [18:0]   __branchSrc2_5;
  reg        [31:0]   __branchSrc2_6;
  wire       [31:0]   branchSrc2;
  wire                when_Branch_l172;
  reg                 __execute_DBusSimple_memAccessActive;
  wire                sharedDBus_cmd_fire;
  wire                when_DBusSimple_l242;
  reg                 execute_DBusSimple_skipCmd;
  wire                execute_DBusSimple_memAccessActive;
  reg        [31:0]   __sharedDBus_cmd_payload_data;
  wire                when_DBusSimple_l278;
  wire                execute_DBusSimple_wait4rsp;
  wire                when_DBusSimple_l325;
  wire                when_DBusSimple_l332;
  wire                when_DBusSimple_l340;
  reg        [31:0]   execute_DBusSimple_rspShifted;
  wire       [1:0]    switch_DBusSimple_l358;
  wire       [1:0]    switch_Misc_l245_2;
  wire                __execute_DBusSimple_rspFormated;
  reg        [31:0]   __execute_DBusSimple_rspFormated_1;
  wire                __execute_DBusSimple_rspFormated_2;
  reg        [31:0]   __execute_DBusSimple_rspFormated_3;
  reg        [31:0]   execute_DBusSimple_rspFormated;
  wire                when_DBusSimple_l384;
  wire                DBusSimple_memory_active;
  reg                 __when_HazardDataBypass_l150;
  reg                 __when_HazardDataBypass_l150_1;
  wire                writeBackWrites_valid;
  wire       [4:0]    writeBackWrites_payload_address;
  wire       [31:0]   writeBackWrites_payload_data;
  reg                 writeBackWrites_stage_valid;
  reg        [4:0]    writeBackWrites_stage_payload_address;
  reg        [31:0]   writeBackWrites_stage_payload_data;
  wire                when_HazardDataBypass_l106;
  wire                when_HazardDataBypass_l109;
  wire                when_HazardDataBypass_l137;
  wire                when_HazardDataBypass_l140;
  wire                when_HazardDataBypass_l150;
  wire       [4:0]    execute_BarrelShifter_amplitude;
  wire       [31:0]   execute_BarrelShifter_reversed;
  wire       [31:0]   execute_BarrelShifter_shifted;
  wire                when_Shifter_l111;
  reg        [31:0]   __execute_RegisterFileReg_data_16;
  wire       [28:0]   __decode_SHIFT_SIGNED;
  wire                __decode_SHIFT_SIGNED_1;
  wire                __decode_SHIFT_SIGNED_2;
  wire                __decode_SHIFT_SIGNED_3;
  wire       [1:0]    __decode_SRC1_CTRL_2;
  wire       [1:0]    __decode_SRC2_CTRL_2;
  wire       [1:0]    __decode_ALU_CTRL_2;
  wire       [1:0]    __decode_ALU_BITWISE_CTRL_2;
  wire       [2:0]    __decode_ENV_CTRL_2;
  wire       [1:0]    __decode_BRANCH_CTRL_2;
  wire                when_Pipeline_l122;
  reg        [31:0]   decode_to_execute_PC;
  wire                when_Pipeline_l122_1;
  reg        [31:0]   decode_to_execute_INSTRUCTION;
  wire                when_Pipeline_l122_2;
  reg                 decode_to_execute_CSR_WRITE_OPCODE;
  wire                when_Pipeline_l122_3;
  reg                 decode_to_execute_CSR_READ_OPCODE;
  wire                when_Pipeline_l122_4;
  reg        [1:0]    decode_to_execute_SRC1_CTRL;
  wire                when_Pipeline_l122_5;
  reg        [1:0]    decode_to_execute_SRC2_CTRL;
  wire                when_Pipeline_l122_6;
  reg                 decode_to_execute_REGFILE_WRITE_VALID;
  wire                when_Pipeline_l122_7;
  reg                 decode_to_execute_RS1_USE;
  wire                when_Pipeline_l122_8;
  reg                 decode_to_execute_RS2_USE;
  wire                when_Pipeline_l122_9;
  reg        [1:0]    decode_to_execute_ALU_CTRL;
  wire                when_Pipeline_l122_10;
  reg                 decode_to_execute_SRC_USE_SUB_LESS;
  wire                when_Pipeline_l122_11;
  reg                 decode_to_execute_SRC_LESS_UNSIGNED;
  wire                when_Pipeline_l122_12;
  reg        [1:0]    decode_to_execute_ALU_BITWISE_CTRL;
  wire                when_Pipeline_l122_13;
  reg                 decode_to_execute_SRC_ADD_ZERO;
  wire                when_Pipeline_l122_14;
  reg                 decode_to_execute_IS_CSR;
  wire                when_Pipeline_l122_15;
  reg        [2:0]    decode_to_execute_ENV_CTRL;
  wire                when_Pipeline_l122_16;
  reg        [1:0]    decode_to_execute_BRANCH_CTRL;
  wire                when_Pipeline_l122_17;
  reg                 decode_to_execute_IS_FENCEI;
  wire                when_Pipeline_l122_18;
  reg                 decode_to_execute_MEMORY_ENABLE;
  wire                when_Pipeline_l122_19;
  reg                 decode_to_execute_MEMORY_STORE;
  wire                when_Pipeline_l122_20;
  reg                 decode_to_execute_DO_SHIFT;
  wire                when_Pipeline_l122_21;
  reg                 decode_to_execute_SHIFT_LEFT;
  wire                when_Pipeline_l122_22;
  reg                 decode_to_execute_SHIFT_SIGNED;
  wire                when_Pipeline_l173;
  wire                when_Pipeline_l176;
  wire                when_CsrFile_l1386;
  wire                when_CsrFile_l1386_1;
  wire                when_CsrFile_l1386_2;
  wire                when_CsrFile_l1386_3;
  wire                when_CsrFile_l1386_4;
  wire                when_CsrFile_l1386_5;
  wire                when_CsrFile_l1386_6;
  wire                when_CsrFile_l1386_7;
  wire                when_CsrFile_l1386_8;
  wire                when_CsrFile_l1386_9;
  wire                when_CsrFile_l1386_10;
  reg                 when_CsrFile_l1437;
  wire                when_CsrFile_l1435;
  wire                when_CsrFile_l1436;
  wire                when_CsrFile_l1442;
  wire                __dBusAxiL_awvalid;
  wire                __when_Utils_l732;
  wire       [31:0]   __dBusAxiL_awaddr;
  wire                __dBusAxiL_awvalid_1;
  wire                when_Utils_l732;
  wire                dBusAxiL_b_fire;
  reg                 pendingWrites_incrementIt;
  reg                 pendingWrites_decrementIt;
  wire       [2:0]    pendingWrites_valueNext;
  reg        [2:0]    pendingWrites_value;
  wire                pendingWrites_mayOverflow;
  wire                pendingWrites_mayUnderflow;
  wire                pendingWrites_willOverflowIfInc;
  wire                pendingWrites_willOverflow;
  wire                pendingWrites_willUnderflowIfDec;
  wire                pendingWrites_willUnderflow;
  reg        [2:0]    pendingWrites_finalIncrement;
  wire                when_Utils_l767;
  wire                when_Utils_l769;
  wire                __dBus_cmd_ready;
  wire                dBus_cmd_haltWhen_valid;
  reg                 dBus_cmd_haltWhen_ready;
  wire                dBus_cmd_haltWhen_payload_wr;
  wire       [31:0]   dBus_cmd_haltWhen_payload_address;
  wire       [31:0]   dBus_cmd_haltWhen_payload_data;
  wire       [1:0]    dBus_cmd_haltWhen_payload_size;
  wire                dBus_cmd_haltWhen_fork2_outputs_0_valid;
  wire                dBus_cmd_haltWhen_fork2_outputs_0_ready;
  wire                dBus_cmd_haltWhen_fork2_outputs_0_payload_wr;
  wire       [31:0]   dBus_cmd_haltWhen_fork2_outputs_0_payload_address;
  wire       [31:0]   dBus_cmd_haltWhen_fork2_outputs_0_payload_data;
  wire       [1:0]    dBus_cmd_haltWhen_fork2_outputs_0_payload_size;
  wire                dBus_cmd_haltWhen_fork2_outputs_1_valid;
  reg                 dBus_cmd_haltWhen_fork2_outputs_1_ready;
  wire                dBus_cmd_haltWhen_fork2_outputs_1_payload_wr;
  wire       [31:0]   dBus_cmd_haltWhen_fork2_outputs_1_payload_address;
  wire       [31:0]   dBus_cmd_haltWhen_fork2_outputs_1_payload_data;
  wire       [1:0]    dBus_cmd_haltWhen_fork2_outputs_1_payload_size;
  reg                 dBus_cmd_haltWhen_fork2_logic_linkEnable_0;
  reg                 dBus_cmd_haltWhen_fork2_logic_linkEnable_1;
  wire                when_Stream_l1186;
  wire                when_Stream_l1186_1;
  wire                dBus_cmd_haltWhen_fork2_outputs_0_fire;
  wire                dBus_cmd_haltWhen_fork2_outputs_1_fire;
  wire                when_Stream_l552;
  reg                 dBus_cmd_haltWhen_fork2_outputs_1_throwWhen_valid;
  wire                dBus_cmd_haltWhen_fork2_outputs_1_throwWhen_ready;
  wire                dBus_cmd_haltWhen_fork2_outputs_1_throwWhen_payload_wr;
  wire       [31:0]   dBus_cmd_haltWhen_fork2_outputs_1_throwWhen_payload_address;
  wire       [31:0]   dBus_cmd_haltWhen_fork2_outputs_1_throwWhen_payload_data;
  wire       [1:0]    dBus_cmd_haltWhen_fork2_outputs_1_throwWhen_payload_size;
  reg        [3:0]    __dBusAxiL_wstrb;

  assign __when = (|{decodeExceptionPort_valid,IBusSimple_instrFetchExceptionPort_valid});
  assign __when_1 = (|{DBusSimple_memoryExceptionPort_valid,{Branch_branchExceptionPort_valid,CsrFile_selfException_valid}});
  assign __execute_BRANCH_TARGET = (branchSrc1 + branchSrc2);
  assign __IBusSimple_jump_pcLoad_payload_1 = (__IBusSimple_jump_pcLoad_payload & (~ __IBusSimple_jump_pcLoad_payload_2));
  assign __IBusSimple_jump_pcLoad_payload_2 = (__IBusSimple_jump_pcLoad_payload - 2'b01);
  assign __IBusSimple_fetchPc_pc_1 = {IBusSimple_fetchPc_inc,2'b00};
  assign __IBusSimple_fetchPc_pc = {29'd0, __IBusSimple_fetchPc_pc_1};
  assign __IBusSimple_pending_next = (IBusSimple_pending_value + __IBusSimple_pending_next_1);
  assign __IBusSimple_pending_next_2 = IBusSimple_pending_inc;
  assign __IBusSimple_pending_next_1 = {2'd0, __IBusSimple_pending_next_2};
  assign __IBusSimple_pending_next_4 = IBusSimple_pending_dec;
  assign __IBusSimple_pending_next_3 = {2'd0, __IBusSimple_pending_next_4};
  assign __IBusSimple_rspJoin_rspBuffer_discardCounter_1 = (IBusSimple_rspJoin_rspBuffer_c_io_pop_valid && (IBusSimple_rspJoin_rspBuffer_discardCounter != 3'b000));
  assign __IBusSimple_rspJoin_rspBuffer_discardCounter = {2'd0, __IBusSimple_rspJoin_rspBuffer_discardCounter_1};
  assign __IBusSimple_rspJoin_rspBuffer_discardCounter_3 = IBusSimple_pending_dec;
  assign __IBusSimple_rspJoin_rspBuffer_discardCounter_2 = {2'd0, __IBusSimple_rspJoin_rspBuffer_discardCounter_3};
  assign ____execute_REGFILE_WRITE_DATA = execute_SRC_LESS;
  assign ____CsrFile_exceptionPortCtrl_exceptionContext_code_1 = (__CsrFile_exceptionPortCtrl_exceptionContext_code & (~ ____CsrFile_exceptionPortCtrl_exceptionContext_code_1_1));
  assign ____CsrFile_exceptionPortCtrl_exceptionContext_code_1_1 = (__CsrFile_exceptionPortCtrl_exceptionContext_code - 2'b01);
  assign ____CsrFile_exceptionPortCtrl_exceptionContext_code_3 = (__CsrFile_exceptionPortCtrl_exceptionContext_code_2 - 3'b001);
  assign __CsrFile_irq_payload_targetAddr = (CsrFile_xtvecBase + __CsrFile_irq_payload_targetAddr_1);
  assign __CsrFile_irq_payload_targetAddr_1 = {26'd0, CsrFile_clint_code};
  assign ____execute_SRC1 = 3'b100;
  assign ____execute_SRC1_1 = execute_INSTRUCTION[19 : 15];
  assign ____execute_SRC2_2 = {execute_INSTRUCTION[31 : 25],execute_INSTRUCTION[11 : 7]};
  assign __execute_SrcSelector_add = (execute_SRC1 + execute_SRC2);
  assign __execute_SrcSelector_sub = (execute_SRC1 - execute_SRC2);
  assign ____branchSrc2 = {{{execute_INSTRUCTION[31],execute_INSTRUCTION[19 : 12]},execute_INSTRUCTION[20]},execute_INSTRUCTION[30 : 21]};
  assign ____branchSrc2_4 = {{{execute_INSTRUCTION[31],execute_INSTRUCTION[7]},execute_INSTRUCTION[30 : 25]},execute_INSTRUCTION[11 : 8]};
  assign __DBusSimple_memoryExceptionPort_payload_code = (execute_MEMORY_STORE ? 3'b111 : 3'b101);
  assign __DBusSimple_memoryExceptionPort_payload_code_1 = (execute_MEMORY_STORE ? 3'b110 : 3'b100);
  assign __execute_BarrelShifter_shifted = ($signed(__execute_BarrelShifter_shifted_1) >>> execute_BarrelShifter_amplitude);
  assign __execute_BarrelShifter_shifted_1 = {(execute_SHIFT_SIGNED && execute_SRC1[31]),execute_BarrelShifter_reversed};
  assign __decode_LEGAL_INSTRUCTION = 32'h0000207f;
  assign __decode_LEGAL_INSTRUCTION_1 = (decode_INSTRUCTION & 32'h0000107f);
  assign __decode_LEGAL_INSTRUCTION_2 = 32'h00001073;
  assign __decode_LEGAL_INSTRUCTION_3 = ((decode_INSTRUCTION & 32'h0000407f) == 32'h00004063);
  assign __decode_LEGAL_INSTRUCTION_4 = ((decode_INSTRUCTION & 32'h0000207f) == 32'h00002013);
  assign __decode_LEGAL_INSTRUCTION_5 = {((decode_INSTRUCTION & 32'h0000603f) == 32'h00000023),{((decode_INSTRUCTION & 32'h0000107f) == 32'h00000013),{((decode_INSTRUCTION & __decode_LEGAL_INSTRUCTION_6) == 32'h00000003),{(__decode_LEGAL_INSTRUCTION_7 == __decode_LEGAL_INSTRUCTION_8),{__decode_LEGAL_INSTRUCTION_9,{__decode_LEGAL_INSTRUCTION_10,__decode_LEGAL_INSTRUCTION_11}}}}}};
  assign __decode_LEGAL_INSTRUCTION_6 = 32'h0000505f;
  assign __decode_LEGAL_INSTRUCTION_7 = (decode_INSTRUCTION & 32'h0000207f);
  assign __decode_LEGAL_INSTRUCTION_8 = 32'h00000003;
  assign __decode_LEGAL_INSTRUCTION_9 = ((decode_INSTRUCTION & 32'h0000607f) == 32'h0000000f);
  assign __decode_LEGAL_INSTRUCTION_10 = ((decode_INSTRUCTION & 32'h0000707b) == 32'h00000063);
  assign __decode_LEGAL_INSTRUCTION_11 = {((decode_INSTRUCTION & 32'hfe00007f) == 32'h00000033),{((decode_INSTRUCTION & 32'hbe00705f) == 32'h00005013),{((decode_INSTRUCTION & __decode_LEGAL_INSTRUCTION_12) == 32'h00001013),{(__decode_LEGAL_INSTRUCTION_13 == __decode_LEGAL_INSTRUCTION_14),{__decode_LEGAL_INSTRUCTION_15,{__decode_LEGAL_INSTRUCTION_16,__decode_LEGAL_INSTRUCTION_17}}}}}};
  assign __decode_LEGAL_INSTRUCTION_12 = 32'hfe00305f;
  assign __decode_LEGAL_INSTRUCTION_13 = (decode_INSTRUCTION & 32'hbe00707f);
  assign __decode_LEGAL_INSTRUCTION_14 = 32'h00000033;
  assign __decode_LEGAL_INSTRUCTION_15 = ((decode_INSTRUCTION & 32'hffefffff) == 32'h00000073);
  assign __decode_LEGAL_INSTRUCTION_16 = ((decode_INSTRUCTION & 32'hffffffff) == 32'h10500073);
  assign __decode_LEGAL_INSTRUCTION_17 = ((decode_INSTRUCTION & 32'hffffffff) == 32'h30200073);
  assign __execute_BarrelShifter_reversed = execute_SRC1[6];
  assign __execute_BarrelShifter_reversed_1 = execute_SRC1[7];
  assign __execute_BarrelShifter_reversed_2 = {execute_SRC1[8],{execute_SRC1[9],{execute_SRC1[10],{execute_SRC1[11],{execute_SRC1[12],{execute_SRC1[13],{execute_SRC1[14],{execute_SRC1[15],{execute_SRC1[16],{__execute_BarrelShifter_reversed_3,{__execute_BarrelShifter_reversed_4,__execute_BarrelShifter_reversed_5}}}}}}}}}}};
  assign __execute_BarrelShifter_reversed_3 = execute_SRC1[17];
  assign __execute_BarrelShifter_reversed_4 = execute_SRC1[18];
  assign __execute_BarrelShifter_reversed_5 = {execute_SRC1[19],{execute_SRC1[20],{execute_SRC1[21],{execute_SRC1[22],{execute_SRC1[23],{execute_SRC1[24],{execute_SRC1[25],{execute_SRC1[26],{execute_SRC1[27],{__execute_BarrelShifter_reversed_6,{__execute_BarrelShifter_reversed_7,__execute_BarrelShifter_reversed_8}}}}}}}}}}};
  assign __execute_BarrelShifter_reversed_6 = execute_SRC1[28];
  assign __execute_BarrelShifter_reversed_7 = execute_SRC1[29];
  assign __execute_BarrelShifter_reversed_8 = {execute_SRC1[30],execute_SRC1[31]};
  assign ____decode_SHIFT_SIGNED = 32'h00007054;
  assign ____decode_SHIFT_SIGNED_1 = (decode_INSTRUCTION & 32'h00003054);
  assign ____decode_SHIFT_SIGNED_2 = 32'h00001010;
  assign ____decode_SHIFT_SIGNED_3 = ((decode_INSTRUCTION & 32'h00000020) == 32'h00000020);
  assign ____decode_SHIFT_SIGNED_4 = ((decode_INSTRUCTION & 32'h00000058) == 32'h0);
  assign ____decode_SHIFT_SIGNED_5 = (|((decode_INSTRUCTION & ____decode_SHIFT_SIGNED_6) == 32'h00001008));
  assign ____decode_SHIFT_SIGNED_7 = (|{__decode_SHIFT_SIGNED_3,{____decode_SHIFT_SIGNED_8,____decode_SHIFT_SIGNED_10}});
  assign ____decode_SHIFT_SIGNED_12 = {(|____decode_SHIFT_SIGNED_13),{(|____decode_SHIFT_SIGNED_14),{____decode_SHIFT_SIGNED_16,{____decode_SHIFT_SIGNED_19,____decode_SHIFT_SIGNED_24}}}};
  assign ____decode_SHIFT_SIGNED_6 = 32'h00001048;
  assign ____decode_SHIFT_SIGNED_8 = ((decode_INSTRUCTION & ____decode_SHIFT_SIGNED_9) == 32'h00001008);
  assign ____decode_SHIFT_SIGNED_10 = ((decode_INSTRUCTION & ____decode_SHIFT_SIGNED_11) == 32'h00000004);
  assign ____decode_SHIFT_SIGNED_13 = ((decode_INSTRUCTION & 32'h00000058) == 32'h00000040);
  assign ____decode_SHIFT_SIGNED_14 = ((decode_INSTRUCTION & ____decode_SHIFT_SIGNED_15) == 32'h00000050);
  assign ____decode_SHIFT_SIGNED_16 = (|(____decode_SHIFT_SIGNED_17 == ____decode_SHIFT_SIGNED_18));
  assign ____decode_SHIFT_SIGNED_19 = (|{____decode_SHIFT_SIGNED_20,____decode_SHIFT_SIGNED_22});
  assign ____decode_SHIFT_SIGNED_24 = {(|____decode_SHIFT_SIGNED_25),{____decode_SHIFT_SIGNED_39,{____decode_SHIFT_SIGNED_44,____decode_SHIFT_SIGNED_47}}};
  assign ____decode_SHIFT_SIGNED_9 = 32'h00001008;
  assign ____decode_SHIFT_SIGNED_11 = 32'h0000001c;
  assign ____decode_SHIFT_SIGNED_15 = 32'h10003050;
  assign ____decode_SHIFT_SIGNED_17 = (decode_INSTRUCTION & 32'h30003050);
  assign ____decode_SHIFT_SIGNED_18 = 32'h10000050;
  assign ____decode_SHIFT_SIGNED_20 = ((decode_INSTRUCTION & ____decode_SHIFT_SIGNED_21) == 32'h20000050);
  assign ____decode_SHIFT_SIGNED_22 = ((decode_INSTRUCTION & ____decode_SHIFT_SIGNED_23) == 32'h00100050);
  assign ____decode_SHIFT_SIGNED_25 = {(____decode_SHIFT_SIGNED_26 == ____decode_SHIFT_SIGNED_27),{____decode_SHIFT_SIGNED_28,{____decode_SHIFT_SIGNED_30,____decode_SHIFT_SIGNED_33}}};
  assign ____decode_SHIFT_SIGNED_39 = (|{____decode_SHIFT_SIGNED_40,____decode_SHIFT_SIGNED_42});
  assign ____decode_SHIFT_SIGNED_44 = (|____decode_SHIFT_SIGNED_45);
  assign ____decode_SHIFT_SIGNED_47 = {(|____decode_SHIFT_SIGNED_48),{____decode_SHIFT_SIGNED_51,{____decode_SHIFT_SIGNED_53,____decode_SHIFT_SIGNED_59}}};
  assign ____decode_SHIFT_SIGNED_21 = 32'h20003050;
  assign ____decode_SHIFT_SIGNED_23 = 32'h00103050;
  assign ____decode_SHIFT_SIGNED_26 = (decode_INSTRUCTION & 32'h00001040);
  assign ____decode_SHIFT_SIGNED_27 = 32'h00001040;
  assign ____decode_SHIFT_SIGNED_28 = ((decode_INSTRUCTION & ____decode_SHIFT_SIGNED_29) == 32'h00002040);
  assign ____decode_SHIFT_SIGNED_30 = (____decode_SHIFT_SIGNED_31 == ____decode_SHIFT_SIGNED_32);
  assign ____decode_SHIFT_SIGNED_33 = {____decode_SHIFT_SIGNED_34,{____decode_SHIFT_SIGNED_35,____decode_SHIFT_SIGNED_37}};
  assign ____decode_SHIFT_SIGNED_40 = ((decode_INSTRUCTION & ____decode_SHIFT_SIGNED_41) == 32'h00001050);
  assign ____decode_SHIFT_SIGNED_42 = ((decode_INSTRUCTION & ____decode_SHIFT_SIGNED_43) == 32'h00002050);
  assign ____decode_SHIFT_SIGNED_45 = ((decode_INSTRUCTION & ____decode_SHIFT_SIGNED_46) == 32'h00000024);
  assign ____decode_SHIFT_SIGNED_48 = (____decode_SHIFT_SIGNED_49 == ____decode_SHIFT_SIGNED_50);
  assign ____decode_SHIFT_SIGNED_51 = (|____decode_SHIFT_SIGNED_52);
  assign ____decode_SHIFT_SIGNED_53 = (|____decode_SHIFT_SIGNED_54);
  assign ____decode_SHIFT_SIGNED_59 = {____decode_SHIFT_SIGNED_60,{____decode_SHIFT_SIGNED_66,____decode_SHIFT_SIGNED_68}};
  assign ____decode_SHIFT_SIGNED_29 = 32'h00002040;
  assign ____decode_SHIFT_SIGNED_31 = (decode_INSTRUCTION & 32'h00400040);
  assign ____decode_SHIFT_SIGNED_32 = 32'h00000040;
  assign ____decode_SHIFT_SIGNED_34 = ((decode_INSTRUCTION & 32'h00000050) == 32'h00000040);
  assign ____decode_SHIFT_SIGNED_35 = ((decode_INSTRUCTION & ____decode_SHIFT_SIGNED_36) == 32'h00001000);
  assign ____decode_SHIFT_SIGNED_37 = ((decode_INSTRUCTION & ____decode_SHIFT_SIGNED_38) == 32'h0);
  assign ____decode_SHIFT_SIGNED_41 = 32'h00001050;
  assign ____decode_SHIFT_SIGNED_43 = 32'h00002050;
  assign ____decode_SHIFT_SIGNED_46 = 32'h00000064;
  assign ____decode_SHIFT_SIGNED_49 = (decode_INSTRUCTION & 32'h00001000);
  assign ____decode_SHIFT_SIGNED_50 = 32'h00001000;
  assign ____decode_SHIFT_SIGNED_52 = ((decode_INSTRUCTION & 32'h00003000) == 32'h00002000);
  assign ____decode_SHIFT_SIGNED_54 = {(____decode_SHIFT_SIGNED_55 == ____decode_SHIFT_SIGNED_56),(____decode_SHIFT_SIGNED_57 == ____decode_SHIFT_SIGNED_58)};
  assign ____decode_SHIFT_SIGNED_60 = (|{____decode_SHIFT_SIGNED_61,{____decode_SHIFT_SIGNED_62,____decode_SHIFT_SIGNED_64}});
  assign ____decode_SHIFT_SIGNED_66 = (|____decode_SHIFT_SIGNED_67);
  assign ____decode_SHIFT_SIGNED_68 = {(|____decode_SHIFT_SIGNED_69),{____decode_SHIFT_SIGNED_71,{____decode_SHIFT_SIGNED_74,____decode_SHIFT_SIGNED_82}}};
  assign ____decode_SHIFT_SIGNED_36 = 32'h00001030;
  assign ____decode_SHIFT_SIGNED_38 = 32'h00000038;
  assign ____decode_SHIFT_SIGNED_55 = (decode_INSTRUCTION & 32'h00005000);
  assign ____decode_SHIFT_SIGNED_56 = 32'h00001000;
  assign ____decode_SHIFT_SIGNED_57 = (decode_INSTRUCTION & 32'h00002010);
  assign ____decode_SHIFT_SIGNED_58 = 32'h00002000;
  assign ____decode_SHIFT_SIGNED_61 = ((decode_INSTRUCTION & 32'h00000044) == 32'h00000040);
  assign ____decode_SHIFT_SIGNED_62 = ((decode_INSTRUCTION & ____decode_SHIFT_SIGNED_63) == 32'h00002010);
  assign ____decode_SHIFT_SIGNED_64 = ((decode_INSTRUCTION & ____decode_SHIFT_SIGNED_65) == 32'h40000030);
  assign ____decode_SHIFT_SIGNED_67 = ((decode_INSTRUCTION & 32'h00004014) == 32'h00004010);
  assign ____decode_SHIFT_SIGNED_69 = ((decode_INSTRUCTION & ____decode_SHIFT_SIGNED_70) == 32'h00002010);
  assign ____decode_SHIFT_SIGNED_71 = (|{____decode_SHIFT_SIGNED_72,____decode_SHIFT_SIGNED_73});
  assign ____decode_SHIFT_SIGNED_74 = (|{____decode_SHIFT_SIGNED_75,____decode_SHIFT_SIGNED_77});
  assign ____decode_SHIFT_SIGNED_82 = {(|____decode_SHIFT_SIGNED_83),{____decode_SHIFT_SIGNED_85,{____decode_SHIFT_SIGNED_90,____decode_SHIFT_SIGNED_98}}};
  assign ____decode_SHIFT_SIGNED_63 = 32'h00002014;
  assign ____decode_SHIFT_SIGNED_65 = 32'h40000034;
  assign ____decode_SHIFT_SIGNED_70 = 32'h00006014;
  assign ____decode_SHIFT_SIGNED_72 = ((decode_INSTRUCTION & 32'h00000054) == 32'h00000040);
  assign ____decode_SHIFT_SIGNED_73 = ((decode_INSTRUCTION & 32'h00000064) == 32'h00000020);
  assign ____decode_SHIFT_SIGNED_75 = ((decode_INSTRUCTION & ____decode_SHIFT_SIGNED_76) == 32'h0);
  assign ____decode_SHIFT_SIGNED_77 = {(____decode_SHIFT_SIGNED_78 == ____decode_SHIFT_SIGNED_79),{____decode_SHIFT_SIGNED_80,____decode_SHIFT_SIGNED_81}};
  assign ____decode_SHIFT_SIGNED_83 = ((decode_INSTRUCTION & ____decode_SHIFT_SIGNED_84) == 32'h00000010);
  assign ____decode_SHIFT_SIGNED_85 = (|{__decode_SHIFT_SIGNED_2,{____decode_SHIFT_SIGNED_86,____decode_SHIFT_SIGNED_88}});
  assign ____decode_SHIFT_SIGNED_90 = (|{____decode_SHIFT_SIGNED_91,____decode_SHIFT_SIGNED_93});
  assign ____decode_SHIFT_SIGNED_98 = {(|____decode_SHIFT_SIGNED_99),{____decode_SHIFT_SIGNED_102,{____decode_SHIFT_SIGNED_104,____decode_SHIFT_SIGNED_107}}};
  assign ____decode_SHIFT_SIGNED_76 = 32'h00000044;
  assign ____decode_SHIFT_SIGNED_78 = (decode_INSTRUCTION & 32'h00000018);
  assign ____decode_SHIFT_SIGNED_79 = 32'h0;
  assign ____decode_SHIFT_SIGNED_80 = ((decode_INSTRUCTION & 32'h00006004) == 32'h00002000);
  assign ____decode_SHIFT_SIGNED_81 = ((decode_INSTRUCTION & 32'h00005004) == 32'h00001000);
  assign ____decode_SHIFT_SIGNED_84 = 32'h00000010;
  assign ____decode_SHIFT_SIGNED_86 = ((decode_INSTRUCTION & ____decode_SHIFT_SIGNED_87) == 32'h00002010);
  assign ____decode_SHIFT_SIGNED_88 = ((decode_INSTRUCTION & ____decode_SHIFT_SIGNED_89) == 32'h00000010);
  assign ____decode_SHIFT_SIGNED_91 = ((decode_INSTRUCTION & ____decode_SHIFT_SIGNED_92) == 32'h00001010);
  assign ____decode_SHIFT_SIGNED_93 = {(____decode_SHIFT_SIGNED_94 == ____decode_SHIFT_SIGNED_95),{__decode_SHIFT_SIGNED_3,{____decode_SHIFT_SIGNED_96,____decode_SHIFT_SIGNED_97}}};
  assign ____decode_SHIFT_SIGNED_99 = {__decode_SHIFT_SIGNED_2,(____decode_SHIFT_SIGNED_100 == ____decode_SHIFT_SIGNED_101)};
  assign ____decode_SHIFT_SIGNED_102 = (|{__decode_SHIFT_SIGNED_2,____decode_SHIFT_SIGNED_103});
  assign ____decode_SHIFT_SIGNED_104 = (|{____decode_SHIFT_SIGNED_105,____decode_SHIFT_SIGNED_106});
  assign ____decode_SHIFT_SIGNED_107 = (|{____decode_SHIFT_SIGNED_108,____decode_SHIFT_SIGNED_109});
  assign ____decode_SHIFT_SIGNED_87 = 32'h00002050;
  assign ____decode_SHIFT_SIGNED_89 = 32'h00001050;
  assign ____decode_SHIFT_SIGNED_92 = 32'h00001010;
  assign ____decode_SHIFT_SIGNED_94 = (decode_INSTRUCTION & 32'h00002010);
  assign ____decode_SHIFT_SIGNED_95 = 32'h00002010;
  assign ____decode_SHIFT_SIGNED_96 = ((decode_INSTRUCTION & 32'h00000050) == 32'h00000010);
  assign ____decode_SHIFT_SIGNED_97 = {((decode_INSTRUCTION & 32'h0000000c) == 32'h00000004),((decode_INSTRUCTION & 32'h00000028) == 32'h0)};
  assign ____decode_SHIFT_SIGNED_100 = (decode_INSTRUCTION & 32'h00000070);
  assign ____decode_SHIFT_SIGNED_101 = 32'h00000020;
  assign ____decode_SHIFT_SIGNED_103 = ((decode_INSTRUCTION & 32'h00000020) == 32'h0);
  assign ____decode_SHIFT_SIGNED_105 = ((decode_INSTRUCTION & 32'h00000014) == 32'h00000004);
  assign ____decode_SHIFT_SIGNED_106 = __decode_SHIFT_SIGNED_1;
  assign ____decode_SHIFT_SIGNED_108 = ((decode_INSTRUCTION & 32'h00000044) == 32'h00000004);
  assign ____decode_SHIFT_SIGNED_109 = __decode_SHIFT_SIGNED_1;
  StreamFifoLowLatency IBusSimple_rspJoin_rspBuffer_c (
    .io_push_valid         (iBus_rsp_toStream_valid                                 ), //i
    .io_push_ready         (IBusSimple_rspJoin_rspBuffer_c_io_push_ready            ), //o
    .io_push_payload_error (iBus_rsp_toStream_payload_error                         ), //i
    .io_push_payload_data  (iBus_rsp_toStream_payload_data[31:0]                    ), //i
    .io_pop_valid          (IBusSimple_rspJoin_rspBuffer_c_io_pop_valid             ), //o
    .io_pop_ready          (IBusSimple_rspJoin_rspBuffer_c_io_pop_ready             ), //i
    .io_pop_payload_error  (IBusSimple_rspJoin_rspBuffer_c_io_pop_payload_error     ), //o
    .io_pop_payload_data   (IBusSimple_rspJoin_rspBuffer_c_io_pop_payload_data[31:0]), //o
    .io_flush              (1'b0                                                    ), //i
    .io_occupancy          (IBusSimple_rspJoin_rspBuffer_c_io_occupancy             ), //o
    .io_availability       (IBusSimple_rspJoin_rspBuffer_c_io_availability          ), //o
    .clk                   (clk                                                     ), //i
    .reset                 (reset                                                   )  //i
  );
  always @(*) begin
    case(__CsrFile_exceptionPortCtrl_exceptionContext_code_6)
      2'b00 : begin
        __CsrFile_exceptionPortCtrl_exceptionContext_code_7 = CsrFile_selfException_payload_code;
        __CsrFile_exceptionPortCtrl_exceptionContext_mtval = CsrFile_selfException_payload_mtval;
        __CsrFile_exceptionPortCtrl_exceptionContext_pc = CsrFile_selfException_payload_pc;
      end
      2'b01 : begin
        __CsrFile_exceptionPortCtrl_exceptionContext_code_7 = Branch_branchExceptionPort_payload_code;
        __CsrFile_exceptionPortCtrl_exceptionContext_mtval = Branch_branchExceptionPort_payload_mtval;
        __CsrFile_exceptionPortCtrl_exceptionContext_pc = Branch_branchExceptionPort_payload_pc;
      end
      default : begin
        __CsrFile_exceptionPortCtrl_exceptionContext_code_7 = DBusSimple_memoryExceptionPort_payload_code;
        __CsrFile_exceptionPortCtrl_exceptionContext_mtval = DBusSimple_memoryExceptionPort_payload_mtval;
        __CsrFile_exceptionPortCtrl_exceptionContext_pc = DBusSimple_memoryExceptionPort_payload_pc;
      end
    endcase
  end

  assign execute_REGFILE_WRITE_DATA = __execute_REGFILE_WRITE_DATA;
  assign decode_SHIFT_SIGNED = __decode_SHIFT_SIGNED[28];
  assign decode_SHIFT_LEFT = __decode_SHIFT_SIGNED[27];
  assign decode_DO_SHIFT = __decode_SHIFT_SIGNED[26];
  assign decode_MEMORY_STORE = __decode_SHIFT_SIGNED[25];
  assign decode_MEMORY_ENABLE = __decode_SHIFT_SIGNED[24];
  assign decode_BRANCH_CTRL = __decode_BRANCH_CTRL;
  assign __decode_to_execute_BRANCH_CTRL = __decode_to_execute_BRANCH_CTRL_1;
  assign decode_ENV_CTRL = __decode_ENV_CTRL;
  assign __decode_to_execute_ENV_CTRL = __decode_to_execute_ENV_CTRL_1;
  assign decode_IS_CSR = __decode_SHIFT_SIGNED[16];
  assign decode_ALU_BITWISE_CTRL = __decode_ALU_BITWISE_CTRL;
  assign __decode_to_execute_ALU_BITWISE_CTRL = __decode_to_execute_ALU_BITWISE_CTRL_1;
  assign decode_SRC_LESS_UNSIGNED = __decode_SHIFT_SIGNED[12];
  assign decode_ALU_CTRL = __decode_ALU_CTRL;
  assign __decode_to_execute_ALU_CTRL = __decode_to_execute_ALU_CTRL_1;
  assign decode_RS2_USE = __decode_SHIFT_SIGNED[8];
  assign decode_RS1_USE = __decode_SHIFT_SIGNED[7];
  assign execute_REGFILE_WRITE_VALID = decode_to_execute_REGFILE_WRITE_VALID;
  assign decode_SRC2_CTRL = __decode_SRC2_CTRL;
  assign __decode_to_execute_SRC2_CTRL = __decode_to_execute_SRC2_CTRL_1;
  assign decode_SRC1_CTRL = __decode_SRC1_CTRL;
  assign __decode_to_execute_SRC1_CTRL = __decode_to_execute_SRC1_CTRL_1;
  assign decode_CSR_READ_OPCODE = (decode_INSTRUCTION[13 : 7] != 7'h20);
  assign decode_CSR_WRITE_OPCODE = (! (((decode_INSTRUCTION[14 : 13] == 2'b01) && (decode_INSTRUCTION[19 : 15] == 5'h0)) || ((decode_INSTRUCTION[14 : 13] == 2'b11) && (decode_INSTRUCTION[19 : 15] == 5'h0))));
  assign decode_PC = IBusSimple_iBusRsp_output_payload_pc;
  assign decode_LEGAL_INSTRUCTION = (|{((decode_INSTRUCTION & 32'h0000005f) == 32'h00000017),{((decode_INSTRUCTION & 32'h0000007f) == 32'h0000006f),{((decode_INSTRUCTION & __decode_LEGAL_INSTRUCTION) == 32'h00002073),{(__decode_LEGAL_INSTRUCTION_1 == __decode_LEGAL_INSTRUCTION_2),{__decode_LEGAL_INSTRUCTION_3,{__decode_LEGAL_INSTRUCTION_4,__decode_LEGAL_INSTRUCTION_5}}}}}});
  assign decode_INSTRUCTION_READY = (IBusSimple_iBusRsp_output_valid && (! IBusSimple_injector_decodeRemoved));
  assign execute_SHIFTED_SRC1 = execute_BarrelShifter_shifted;
  assign execute_DO_SHIFT = decode_to_execute_DO_SHIFT;
  assign execute_SHIFT_SIGNED = decode_to_execute_SHIFT_SIGNED;
  assign execute_SHIFT_LEFT = decode_to_execute_SHIFT_LEFT;
  assign execute_RS2_USE = decode_to_execute_RS2_USE;
  assign execute_RS1_USE = decode_to_execute_RS1_USE;
  assign execute_MEMORY_READ_DATA = sharedDBus_rsp_data;
  assign execute_ACCESS_FAULT = 1'b0;
  assign execute_MEMORY_ADDRESS = sharedDBus_cmd_payload_address;
  assign execute_SRC_ADD = execute_SrcSelector_add;
  always @(*) begin
    execute_RS2 = __execute_RS2;
    execute_RS1 = __execute_RS1;
    if(writeBackWrites_stage_valid) begin
      if(when_HazardDataBypass_l106) begin
        execute_RS1 = writeBackWrites_stage_payload_data;
      end
      if(when_HazardDataBypass_l109) begin
        execute_RS2 = writeBackWrites_stage_payload_data;
      end
    end
  end

  assign execute_MEMORY_STORE = decode_to_execute_MEMORY_STORE;
  assign execute_MEMORY_ENABLE = decode_to_execute_MEMORY_ENABLE;
  assign execute_ALIGNEMENT_FAULT = ((((sharedDBus_cmd_payload_size == 2'b11) && (sharedDBus_cmd_payload_address[2 : 0] != 3'b000)) || ((sharedDBus_cmd_payload_size == 2'b10) && (sharedDBus_cmd_payload_address[1 : 0] != 2'b00))) || ((sharedDBus_cmd_payload_size == 2'b01) && (sharedDBus_cmd_payload_address[0 : 0] != 1'b0)));
  assign execute_IS_FENCEI = decode_to_execute_IS_FENCEI;
  always @(*) begin
    __decode_to_execute_INSTRUCTION = decode_INSTRUCTION;
    if(decode_IS_FENCEI) begin
      __decode_to_execute_INSTRUCTION[31 : 12] = 20'h0;
      __decode_to_execute_INSTRUCTION[22] = 1'b1;
    end
  end

  assign decode_IS_FENCEI = __decode_SHIFT_SIGNED[23];
  assign execute_BRANCH_TARGET = {__execute_BRANCH_TARGET[31 : 1],1'b0};
  assign execute_BRANCH_DO = __execute_BRANCH_DO_1;
  assign execute_BRANCH_CTRL = __execute_BRANCH_CTRL;
  assign execute_SRC_USE_SUB_LESS = decode_to_execute_SRC_USE_SUB_LESS;
  assign execute_SRC_LESS_UNSIGNED = decode_to_execute_SRC_LESS_UNSIGNED;
  assign execute_SRC_ADD_ZERO = decode_to_execute_SRC_ADD_ZERO;
  assign execute_SRC2_CTRL = __execute_SRC2_CTRL;
  assign execute_SRC1_CTRL = __execute_SRC1_CTRL;
  assign decode_SRC_USE_SUB_LESS = __decode_SHIFT_SIGNED[11];
  assign decode_SRC_ADD_ZERO = __decode_SHIFT_SIGNED[15];
  assign execute_CSR_READ_OPCODE = decode_to_execute_CSR_READ_OPCODE;
  assign execute_CSR_WRITE_OPCODE = decode_to_execute_CSR_WRITE_OPCODE;
  assign execute_IS_CSR = decode_to_execute_IS_CSR;
  assign execute_SRC_ADD_SUB = (execute_SRC_USE_SUB_LESS ? execute_SrcSelector_sub : execute_SrcSelector_add);
  assign execute_SRC_LESS = execute_SrcSelector_less;
  assign execute_ALU_CTRL = __execute_ALU_CTRL;
  assign execute_SRC2 = __execute_SRC2_4;
  assign execute_SRC1 = __execute_SRC1;
  assign execute_ALU_BITWISE_CTRL = __execute_ALU_BITWISE_CTRL;
  always @(*) begin
    execute_RegisterFileReg_data = execute_REGFILE_WRITE_DATA;
    execute_arbitration_haltItself = 1'b0;
    IBusSimple_fetcherHalt = 1'b0;
    CsrFile_jumpInterface_valid = 1'b0;
    CsrFile_jumpInterface_payload = 32'h0;
    if(when_CsrFile_l966) begin
      IBusSimple_fetcherHalt = 1'b1;
    end
    CsrFile_irq_valid = CsrFile_clint_valid;
    if(when_CsrFile_l1126) begin
      IBusSimple_fetcherHalt = 1'b1;
      CsrFile_jumpInterface_valid = 1'b1;
      CsrFile_jumpInterface_payload = (CsrFile_hadException ? {{CsrFile_excXtvec_base,CsrFile_excXtvec_submode},2'b00} : CsrFile_pendingIrq_payload_targetAddr);
      if(when_CsrFile_l1137) begin
        case(CsrFile_targetPrivilege)
          2'b11 : begin
            CsrFile_irq_valid = 1'b0;
          end
          default : begin
          end
        endcase
      end
    end
    if(when_CsrFile_l1196) begin
      IBusSimple_fetcherHalt = 1'b1;
      CsrFile_jumpInterface_valid = 1'b1;
      case(switch_CsrFile_l1200)
        2'b11 : begin
          CsrFile_jumpInterface_payload = CsrFile_mepc;
        end
        default : begin
        end
      endcase
    end
    wfi_o = 1'b0;
    if(when_CsrFile_l1258) begin
      CsrFile_jumpInterface_valid = 1'b1;
      CsrFile_jumpInterface_payload = (execute_PC + 32'h00000004);
      if(when_CsrFile_l1262) begin
        IBusSimple_fetcherHalt = 1'b1;
        execute_arbitration_haltItself = 1'b1;
        wfi_o = 1'b1;
      end
    end
    if(when_CsrFile_l1359) begin
      execute_RegisterFileReg_data = __execute_RegisterFileReg_data;
      if(execute_CsrFile_blockedBySideEffects) begin
        execute_arbitration_haltItself = 1'b1;
      end
    end
    if(when_DBusSimple_l278) begin
      execute_arbitration_haltItself = 1'b1;
    end
    if(when_DBusSimple_l325) begin
      execute_arbitration_haltItself = 1'b1;
    end
    if(when_DBusSimple_l384) begin
      execute_RegisterFileReg_data = execute_DBusSimple_rspFormated;
    end
    if(when_Shifter_l111) begin
      if(execute_SHIFT_LEFT) begin
        execute_RegisterFileReg_data = __execute_RegisterFileReg_data_16;
      end else begin
        execute_RegisterFileReg_data = execute_SHIFTED_SRC1;
      end
    end
  end

  assign __execute_RegisterFileReg_valid = execute_REGFILE_WRITE_VALID;
  always @(*) begin
    decode_REGFILE_WRITE_VALID = __decode_SHIFT_SIGNED[4];
    if(when_RegisterFile_l298) begin
      decode_REGFILE_WRITE_VALID = 1'b0;
    end
  end

  assign decode_INSTRUCTION = IBusSimple_iBusRsp_output_payload_rsp_data;
  assign __execute_RegisterFileReg_address = execute_INSTRUCTION;
  assign __when_H2E_l75 = execute_BRANCH_DO;
  assign __when_H2E_l82 = __when_H2E_l82_1;
  assign execute_ENV_CTRL = __execute_ENV_CTRL;
  assign execute_PC = decode_to_execute_PC;
  assign execute_INSTRUCTION = decode_to_execute_INSTRUCTION;
  always @(*) begin
    decode_arbitration_haltItself = 1'b0;
    decode_H2E_stall = 1'b0;
    if(when_H2E_l203) begin
      decode_arbitration_haltItself = 1'b1;
      decode_H2E_stall = 1'b1;
    end
  end

  always @(*) begin
    decode_arbitration_haltByOther = 1'b0;
    if(CsrFile_pipelineFlush_active) begin
      decode_arbitration_haltByOther = 1'b1;
    end
    if(when_CsrFile_l1275) begin
      decode_arbitration_haltByOther = 1'b1;
    end
  end

  always @(*) begin
    decode_arbitration_removeIt = 1'b0;
    if(__when) begin
      decode_arbitration_removeIt = 1'b1;
    end
    if(decode_arbitration_isFlushed) begin
      decode_arbitration_removeIt = 1'b1;
    end
  end

  assign decode_arbitration_flushIt = 1'b0;
  always @(*) begin
    decode_arbitration_flushNext = 1'b0;
    CsrFile_exceptionPortCtrl_exceptionValids_decode = CsrFile_exceptionPortCtrl_exceptionValidsRegs_decode;
    if(__when) begin
      decode_arbitration_flushNext = 1'b1;
      CsrFile_exceptionPortCtrl_exceptionValids_decode = 1'b1;
    end
    if(decode_arbitration_isFlushed) begin
      CsrFile_exceptionPortCtrl_exceptionValids_decode = 1'b0;
    end
  end

  assign decode_arbitration_isRegFSpawn = 1'b0;
  assign decode_arbitration_flushItSV = 1'b0;
  always @(*) begin
    execute_arbitration_haltByOther = 1'b0;
    if(when_Branch_l172) begin
      execute_arbitration_haltByOther = 1'b1;
    end
    if(when_HazardDataBypass_l150) begin
      execute_arbitration_haltByOther = 1'b1;
    end
  end

  always @(*) begin
    execute_arbitration_removeIt = 1'b0;
    CsrFile_exceptionPortCtrl_exceptionValids_execute = CsrFile_exceptionPortCtrl_exceptionValidsRegs_execute;
    if(__when_1) begin
      execute_arbitration_removeIt = 1'b1;
      CsrFile_exceptionPortCtrl_exceptionValids_execute = 1'b1;
    end
    if(execute_arbitration_isFlushed) begin
      CsrFile_exceptionPortCtrl_exceptionValids_execute = 1'b0;
    end
    if(execute_arbitration_isFlushed) begin
      execute_arbitration_removeIt = 1'b1;
    end
  end

  assign execute_arbitration_flushIt = 1'b0;
  always @(*) begin
    execute_arbitration_flushNext = 1'b0;
    if(__when_1) begin
      execute_arbitration_flushNext = 1'b1;
    end
    if(when_CsrFile_l1126) begin
      execute_arbitration_flushNext = 1'b1;
    end
    if(when_CsrFile_l1196) begin
      execute_arbitration_flushNext = 1'b1;
    end
    if(when_CsrFile_l1258) begin
      execute_arbitration_flushNext = 1'b1;
    end
    if(Branch_jumpInterface_valid) begin
      execute_arbitration_flushNext = 1'b1;
    end
  end

  assign execute_arbitration_isRegFSpawn = 1'b0;
  assign execute_arbitration_flushItSV = 1'b0;
  assign lastStageInstruction = execute_INSTRUCTION;
  assign lastStagePc = execute_PC;
  assign lastStageIsValid = execute_arbitration_isValid;
  assign lastStageIsFiring = execute_arbitration_isFiring;
  assign IBusSimple_forceNoDecodeCond = 1'b0;
  always @(*) begin
    IBusSimple_incomingInstruction = 1'b0;
    if(IBusSimple_iBusRsp_fetchStages_1_input_valid) begin
      IBusSimple_incomingInstruction = 1'b1;
    end
  end

  always @(*) begin
    __execute_RegisterFileReg_data = __execute_RegisterFileReg_data_1;
    execute_CsrFile_illegalAccess = 1'b1;
    execute_CsrFile_writeInstruction = ((execute_arbitration_isValid && execute_IS_CSR) && execute_CSR_WRITE_OPCODE);
    execute_CsrFile_readInstruction = ((execute_arbitration_isValid && execute_IS_CSR) && execute_CSR_READ_OPCODE);
    __execute_RegisterFileReg_data_1 = 32'h0;
    case(execute_CsrFile_csrAddress)
      12'hf11 : begin
        execute_CsrFile_illegalAccess = 1'b0;
        __execute_RegisterFileReg_data[10 : 0] = __execute_RegisterFileReg_data_2;
        __execute_RegisterFileReg_data_1[10 : 0] = __execute_RegisterFileReg_data_2;
      end
      12'hf12 : begin
        execute_CsrFile_illegalAccess = 1'b0;
        __execute_RegisterFileReg_data[31 : 0] = __execute_RegisterFileReg_data_3;
        __execute_RegisterFileReg_data_1[31 : 0] = __execute_RegisterFileReg_data_3;
      end
      12'hf13 : begin
        execute_CsrFile_illegalAccess = 1'b0;
        __execute_RegisterFileReg_data[0 : 0] = __execute_RegisterFileReg_data_4;
        __execute_RegisterFileReg_data_1[0 : 0] = __execute_RegisterFileReg_data_4;
      end
      12'hf14 : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'h301 : begin
        execute_CsrFile_illegalAccess = 1'b0;
        __execute_RegisterFileReg_data[31 : 30] = CsrFile_misa_base;
        __execute_RegisterFileReg_data_1[31 : 30] = CsrFile_misa_base;
        __execute_RegisterFileReg_data[25 : 0] = CsrFile_misa_extensions;
        __execute_RegisterFileReg_data_1[25 : 0] = CsrFile_misa_extensions;
      end
      12'h300 : begin
        execute_CsrFile_illegalAccess = 1'b0;
        __execute_RegisterFileReg_data[7 : 7] = CsrFile_mstatus_MPIE;
        __execute_RegisterFileReg_data_1[7 : 7] = CsrFile_mstatus_MPIE;
        __execute_RegisterFileReg_data[3 : 3] = CsrFile_mstatus_MIE;
        __execute_RegisterFileReg_data_1[3 : 3] = CsrFile_mstatus_MIE;
        __execute_RegisterFileReg_data[12 : 11] = CsrFile_mstatus_MPP;
        __execute_RegisterFileReg_data_1[12 : 11] = CsrFile_mstatus_MPP;
      end
      12'h344 : begin
        execute_CsrFile_illegalAccess = 1'b0;
        __execute_RegisterFileReg_data[11 : 11] = CsrFile_mip_MEIP;
        __execute_RegisterFileReg_data_1[11 : 11] = CsrFile_mip_MEIP;
        __execute_RegisterFileReg_data[7 : 7] = CsrFile_mip_MTIP;
        __execute_RegisterFileReg_data_1[7 : 7] = CsrFile_mip_MTIP;
        __execute_RegisterFileReg_data[3 : 3] = CsrFile_mip_MSIP;
        __execute_RegisterFileReg_data_1[3 : 3] = CsrFile_mip_MSIP;
      end
      12'h304 : begin
        execute_CsrFile_illegalAccess = 1'b0;
        __execute_RegisterFileReg_data[11 : 11] = CsrFile_mie_MEIE;
        __execute_RegisterFileReg_data_1[11 : 11] = CsrFile_mie_MEIE;
        __execute_RegisterFileReg_data[7 : 7] = CsrFile_mie_MTIE;
        __execute_RegisterFileReg_data_1[7 : 7] = CsrFile_mie_MTIE;
        __execute_RegisterFileReg_data[3 : 3] = CsrFile_mie_MSIE;
        __execute_RegisterFileReg_data_1[3 : 3] = CsrFile_mie_MSIE;
      end
      12'h305 : begin
        execute_CsrFile_illegalAccess = 1'b0;
        __execute_RegisterFileReg_data[31 : 6] = CsrFile_mtvec_base;
        __execute_RegisterFileReg_data_1[31 : 6] = CsrFile_mtvec_base;
        __execute_RegisterFileReg_data[5 : 2] = CsrFile_mtvec_submode;
        __execute_RegisterFileReg_data_1[5 : 2] = CsrFile_mtvec_submode;
        __execute_RegisterFileReg_data[0 : 0] = __execute_RegisterFileReg_data_5;
        __execute_RegisterFileReg_data_1[0 : 0] = __execute_RegisterFileReg_data_5;
      end
      12'h341 : begin
        execute_CsrFile_illegalAccess = 1'b0;
        __execute_RegisterFileReg_data[31 : 0] = CsrFile_mepc;
        __execute_RegisterFileReg_data_1[31 : 0] = CsrFile_mepc;
      end
      12'h340 : begin
        execute_CsrFile_illegalAccess = 1'b0;
        __execute_RegisterFileReg_data[31 : 0] = CsrFile_mscratch;
        __execute_RegisterFileReg_data_1[31 : 0] = CsrFile_mscratch;
      end
      12'h342 : begin
        execute_CsrFile_illegalAccess = 1'b0;
        __execute_RegisterFileReg_data[31 : 31] = CsrFile_mcause_interrupt;
        __execute_RegisterFileReg_data_1[31 : 31] = CsrFile_mcause_interrupt;
        __execute_RegisterFileReg_data[3 : 0] = CsrFile_mcause_exceptionCode;
        __execute_RegisterFileReg_data_1[3 : 0] = CsrFile_mcause_exceptionCode;
      end
      12'h343 : begin
        execute_CsrFile_illegalAccess = 1'b0;
        __execute_RegisterFileReg_data[31 : 0] = CsrFile_mtval;
        __execute_RegisterFileReg_data_1[31 : 0] = CsrFile_mtval;
      end
      12'hb00 : begin
        execute_CsrFile_illegalAccess = 1'b0;
        __execute_RegisterFileReg_data[31 : 0] = __execute_RegisterFileReg_data_6;
        __execute_RegisterFileReg_data_1[31 : 0] = __execute_RegisterFileReg_data_6;
      end
      12'hb80 : begin
        execute_CsrFile_illegalAccess = 1'b0;
        __execute_RegisterFileReg_data[31 : 0] = __execute_RegisterFileReg_data_7;
        __execute_RegisterFileReg_data_1[31 : 0] = __execute_RegisterFileReg_data_7;
      end
      12'hb02 : begin
        execute_CsrFile_illegalAccess = 1'b0;
        __execute_RegisterFileReg_data[31 : 0] = __execute_RegisterFileReg_data_8;
        __execute_RegisterFileReg_data_1[31 : 0] = __execute_RegisterFileReg_data_8;
      end
      12'hb82 : begin
        execute_CsrFile_illegalAccess = 1'b0;
        __execute_RegisterFileReg_data[31 : 0] = __execute_RegisterFileReg_data_9;
        __execute_RegisterFileReg_data_1[31 : 0] = __execute_RegisterFileReg_data_9;
      end
      12'hc00 : begin
        execute_CsrFile_illegalAccess = 1'b0;
        __execute_RegisterFileReg_data[31 : 0] = __execute_RegisterFileReg_data_10;
        __execute_RegisterFileReg_data_1[31 : 0] = __execute_RegisterFileReg_data_10;
      end
      12'hc80 : begin
        execute_CsrFile_illegalAccess = 1'b0;
        __execute_RegisterFileReg_data[31 : 0] = __execute_RegisterFileReg_data_11;
        __execute_RegisterFileReg_data_1[31 : 0] = __execute_RegisterFileReg_data_11;
      end
      12'hc01 : begin
        execute_CsrFile_illegalAccess = 1'b0;
        __execute_RegisterFileReg_data[31 : 0] = __execute_RegisterFileReg_data_12;
        __execute_RegisterFileReg_data_1[31 : 0] = __execute_RegisterFileReg_data_12;
      end
      12'hc81 : begin
        execute_CsrFile_illegalAccess = 1'b0;
        __execute_RegisterFileReg_data[31 : 0] = __execute_RegisterFileReg_data_13;
        __execute_RegisterFileReg_data_1[31 : 0] = __execute_RegisterFileReg_data_13;
      end
      12'hc02 : begin
        execute_CsrFile_illegalAccess = 1'b0;
        __execute_RegisterFileReg_data[31 : 0] = __execute_RegisterFileReg_data_14;
        __execute_RegisterFileReg_data_1[31 : 0] = __execute_RegisterFileReg_data_14;
      end
      12'hc82 : begin
        execute_CsrFile_illegalAccess = 1'b0;
        __execute_RegisterFileReg_data[31 : 0] = __execute_RegisterFileReg_data_15;
        __execute_RegisterFileReg_data_1[31 : 0] = __execute_RegisterFileReg_data_15;
      end
      12'hc03 : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hc83 : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hb03 : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hb83 : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'h323 : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hc04 : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hc84 : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hb04 : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hb84 : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'h324 : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hc05 : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hc85 : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hb05 : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hb85 : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'h325 : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hc06 : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hc86 : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hb06 : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hb86 : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'h326 : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hc07 : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hc87 : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hb07 : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hb87 : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'h327 : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hc08 : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hc88 : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hb08 : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hb88 : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'h328 : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hc09 : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hc89 : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hb09 : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hb89 : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'h329 : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hc0a : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hc8a : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hb0a : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hb8a : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'h32a : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hc0b : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hc8b : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hb0b : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hb8b : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'h32b : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hc0c : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hc8c : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hb0c : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hb8c : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'h32c : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hc0d : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hc8d : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hb0d : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hb8d : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'h32d : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hc0e : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hc8e : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hb0e : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hb8e : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'h32e : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hc0f : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hc8f : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hb0f : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hb8f : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'h32f : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hc10 : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hc90 : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hb10 : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hb90 : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'h330 : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hc11 : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hc91 : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hb11 : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hb91 : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'h331 : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hc12 : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hc92 : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hb12 : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hb92 : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'h332 : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hc13 : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hc93 : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hb13 : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hb93 : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'h333 : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hc14 : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hc94 : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hb14 : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hb94 : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'h334 : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hc15 : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hc95 : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hb15 : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hb95 : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'h335 : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hc16 : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hc96 : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hb16 : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hb96 : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'h336 : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hc17 : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hc97 : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hb17 : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hb97 : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'h337 : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hc18 : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hc98 : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hb18 : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hb98 : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'h338 : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hc19 : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hc99 : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hb19 : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hb99 : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'h339 : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hc1a : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hc9a : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hb1a : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hb9a : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'h33a : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hc1b : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hc9b : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hb1b : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hb9b : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'h33b : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hc1c : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hc9c : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hb1c : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hb9c : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'h33c : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hc1d : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hc9d : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hb1d : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hb9d : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'h33d : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hc1e : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hc9e : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hb1e : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hb9e : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'h33e : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hc1f : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hc9f : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hb1f : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'hb9f : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      12'h33f : begin
        execute_CsrFile_illegalAccess = 1'b0;
      end
      default : begin
      end
    endcase
    if(when_CsrFile_l1437) begin
      execute_CsrFile_illegalAccess = 1'b1;
      execute_CsrFile_readInstruction = 1'b0;
      execute_CsrFile_writeInstruction = 1'b0;
    end
    if(when_CsrFile_l1442) begin
      execute_CsrFile_illegalAccess = 1'b0;
    end
  end

  assign CsrFile_thirdPartyWake = 1'b0;
  assign CsrFile_forceMachineWire = 1'b0;
  assign CsrFile_allowInterrupts = 1'b1;
  assign CsrFile_allowException = 1'b1;
  assign Branch_inDebugNoFetchFlag = 1'b0;
  assign cdDBus_cmd_valid = sharedDBus_cmd_valid;
  assign cdDBus_cmd_payload_wr = sharedDBus_cmd_payload_wr;
  assign cdDBus_cmd_payload_address = sharedDBus_cmd_payload_address;
  assign cdDBus_cmd_payload_data = sharedDBus_cmd_payload_data;
  assign cdDBus_cmd_payload_size = sharedDBus_cmd_payload_size;
  assign sharedDBus_cmd_ready = cdDBus_cmd_ready;
  assign sharedDBus_rsp_error = cdDBus_rsp_error;
  assign sharedDBus_rsp_data = cdDBus_rsp_data;
  assign sharedDBus_rsp_ready = cdDBus_rsp_ready;
  assign IBusSimple_externalFlush = (|{execute_arbitration_flushNext,decode_arbitration_flushNext});
  assign IBusSimple_jump_pcLoad_valid = (|{Branch_jumpInterface_valid,CsrFile_jumpInterface_valid});
  assign __IBusSimple_jump_pcLoad_payload = {Branch_jumpInterface_valid,CsrFile_jumpInterface_valid};
  assign IBusSimple_jump_pcLoad_payload = (__IBusSimple_jump_pcLoad_payload_1[0] ? CsrFile_jumpInterface_payload : Branch_jumpInterface_payload);
  always @(*) begin
    IBusSimple_fetchPc_correction = 1'b0;
    IBusSimple_fetchPc_pc = (IBusSimple_fetchPc_pcReg + __IBusSimple_fetchPc_pc);
    IBusSimple_fetchPc_flushed = 1'b0;
    if(IBusSimple_jump_pcLoad_valid) begin
      IBusSimple_fetchPc_correction = 1'b1;
      IBusSimple_fetchPc_pc = IBusSimple_jump_pcLoad_payload;
      IBusSimple_fetchPc_flushed = 1'b1;
    end
    IBusSimple_fetchPc_pc[0] = 1'b0;
    IBusSimple_fetchPc_pc[1] = 1'b0;
  end

  assign IBusSimple_fetchPc_output_fire = (IBusSimple_fetchPc_output_valid && IBusSimple_fetchPc_output_ready);
  assign IBusSimple_fetchPc_corrected = (IBusSimple_fetchPc_correction || IBusSimple_fetchPc_correctionReg);
  always @(*) begin
    IBusSimple_fetchPc_pcRegPropagate = 1'b0;
    if(IBusSimple_iBusRsp_fetchStages_1_input_ready) begin
      IBusSimple_fetchPc_pcRegPropagate = 1'b1;
    end
  end

  assign when_InstructionFetch_l139 = (IBusSimple_fetchPc_correction || IBusSimple_fetchPc_pcRegPropagate);
  assign when_InstructionFetch_l139_1 = ((! IBusSimple_fetchPc_output_valid) && IBusSimple_fetchPc_output_ready);
  assign when_InstructionFetch_l186 = (IBusSimple_fetchPc_booted && ((IBusSimple_fetchPc_output_ready || IBusSimple_fetchPc_correction) || IBusSimple_fetchPc_pcRegPropagate));
  assign IBusSimple_fetchPc_output_valid = ((! IBusSimple_fetcherHalt) && IBusSimple_fetchPc_booted);
  assign IBusSimple_fetchPc_output_payload = IBusSimple_fetchPc_pc;
  assign IBusSimple_iBusRsp_redoFetch = 1'b0;
  assign IBusSimple_iBusRsp_fetchStages_0_input_valid = IBusSimple_fetchPc_output_valid;
  assign IBusSimple_fetchPc_output_ready = IBusSimple_iBusRsp_fetchStages_0_input_ready;
  assign IBusSimple_iBusRsp_fetchStages_0_input_payload = IBusSimple_fetchPc_output_payload;
  always @(*) begin
    IBusSimple_iBusRsp_fetchStages_0_halt = 1'b0;
    if(when_IBusSimple_l79) begin
      IBusSimple_iBusRsp_fetchStages_0_halt = 1'b1;
    end
  end

  assign __IBusSimple_iBusRsp_fetchStages_0_input_ready = (! IBusSimple_iBusRsp_fetchStages_0_halt);
  assign IBusSimple_iBusRsp_fetchStages_0_input_haltWhen_valid = (IBusSimple_iBusRsp_fetchStages_0_input_valid && __IBusSimple_iBusRsp_fetchStages_0_input_ready);
  assign IBusSimple_iBusRsp_fetchStages_0_input_ready = (IBusSimple_iBusRsp_fetchStages_0_input_haltWhen_ready && __IBusSimple_iBusRsp_fetchStages_0_input_ready);
  assign IBusSimple_iBusRsp_fetchStages_0_input_haltWhen_payload = IBusSimple_iBusRsp_fetchStages_0_input_payload;
  assign IBusSimple_iBusRsp_fetchStages_0_output_valid = IBusSimple_iBusRsp_fetchStages_0_input_haltWhen_valid;
  assign IBusSimple_iBusRsp_fetchStages_0_input_haltWhen_ready = IBusSimple_iBusRsp_fetchStages_0_output_ready;
  assign IBusSimple_iBusRsp_fetchStages_0_output_payload = IBusSimple_iBusRsp_fetchStages_0_input_haltWhen_payload;
  assign IBusSimple_iBusRsp_fetchStages_1_halt = 1'b0;
  assign __IBusSimple_iBusRsp_fetchStages_1_input_ready = (! IBusSimple_iBusRsp_fetchStages_1_halt);
  assign IBusSimple_iBusRsp_fetchStages_1_input_haltWhen_valid = (IBusSimple_iBusRsp_fetchStages_1_input_valid && __IBusSimple_iBusRsp_fetchStages_1_input_ready);
  assign IBusSimple_iBusRsp_fetchStages_1_input_ready = (IBusSimple_iBusRsp_fetchStages_1_input_haltWhen_ready && __IBusSimple_iBusRsp_fetchStages_1_input_ready);
  assign IBusSimple_iBusRsp_fetchStages_1_input_haltWhen_payload = IBusSimple_iBusRsp_fetchStages_1_input_payload;
  assign IBusSimple_iBusRsp_fetchStages_1_output_valid = IBusSimple_iBusRsp_fetchStages_1_input_haltWhen_valid;
  assign IBusSimple_iBusRsp_fetchStages_1_input_haltWhen_ready = IBusSimple_iBusRsp_fetchStages_1_output_ready;
  assign IBusSimple_iBusRsp_fetchStages_1_output_payload = IBusSimple_iBusRsp_fetchStages_1_input_haltWhen_payload;
  assign IBusSimple_iBusRsp_flush = ((decode_arbitration_removeIt || (decode_arbitration_flushNext && (! decode_arbitration_isStuck))) || IBusSimple_iBusRsp_redoFetch);
  assign IBusSimple_iBusRsp_fetchStages_0_output_toEvent_valid = IBusSimple_iBusRsp_fetchStages_0_output_valid;
  assign IBusSimple_iBusRsp_fetchStages_0_output_ready = IBusSimple_iBusRsp_fetchStages_0_output_toEvent_ready;
  assign IBusSimple_iBusRsp_fetchStages_0_output_toEvent_ready = ((1'b0 && (! __IBusSimple_iBusRsp_fetchStages_1_input_valid)) || IBusSimple_iBusRsp_fetchStages_1_input_ready);
  assign __IBusSimple_iBusRsp_fetchStages_1_input_valid = __IBusSimple_iBusRsp_fetchStages_1_input_valid_1;
  assign IBusSimple_iBusRsp_fetchStages_1_input_valid = __IBusSimple_iBusRsp_fetchStages_1_input_valid;
  assign IBusSimple_iBusRsp_fetchStages_1_input_payload = IBusSimple_fetchPc_pcReg;
  always @(*) begin
    IBusSimple_iBusRsp_readyForError = 1'b1;
    if(when_InstructionFetch_l370) begin
      IBusSimple_iBusRsp_readyForError = 1'b0;
    end
  end

  assign when_InstructionFetch_l370 = (! IBusSimple_pcValids_0);
  assign when_InstructionFetch_l379 = (! (! IBusSimple_iBusRsp_fetchStages_1_input_ready));
  assign when_InstructionFetch_l379_1 = (! execute_arbitration_isStuck);
  assign IBusSimple_pcValids_0 = IBusSimple_injector_nextPcCalc_valids_0;
  assign IBusSimple_pcValids_1 = IBusSimple_injector_nextPcCalc_valids_1;
  assign IBusSimple_iBusRsp_output_ready = (! decode_arbitration_isStuck);
  always @(*) begin
    decode_arbitration_isValid = IBusSimple_iBusRsp_output_valid;
    if(IBusSimple_forceNoDecodeCond) begin
      decode_arbitration_isValid = 1'b0;
    end
  end

  assign IBusSimple_cmd_ready = IBusSimple_cmd_rValidN;
  assign IBusSimple_cmd_s2mPipe_valid = (IBusSimple_cmd_valid || (! IBusSimple_cmd_rValidN));
  assign IBusSimple_cmd_s2mPipe_payload_addr = (IBusSimple_cmd_rValidN ? IBusSimple_cmd_payload_addr : IBusSimple_cmd_rData_addr);
  assign iBus_cmd_valid = IBusSimple_cmd_s2mPipe_valid;
  assign IBusSimple_cmd_s2mPipe_ready = iBus_cmd_ready;
  assign iBus_cmd_payload_addr = IBusSimple_cmd_s2mPipe_payload_addr;
  assign IBusSimple_pending_next = (__IBusSimple_pending_next - __IBusSimple_pending_next_3);
  assign IBusSimple_cmdFork_canEmit = (IBusSimple_iBusRsp_fetchStages_0_output_ready && (IBusSimple_pending_value != 3'b111));
  assign when_IBusSimple_l79 = (IBusSimple_iBusRsp_fetchStages_0_input_valid && ((! IBusSimple_cmdFork_canEmit) || (! IBusSimple_cmd_ready)));
  assign IBusSimple_cmd_valid = (IBusSimple_iBusRsp_fetchStages_0_input_valid && IBusSimple_cmdFork_canEmit);
  assign IBusSimple_cmd_fire = (IBusSimple_cmd_valid && IBusSimple_cmd_ready);
  assign IBusSimple_pending_inc = IBusSimple_cmd_fire;
  assign IBusSimple_cmd_payload_addr = {IBusSimple_iBusRsp_fetchStages_0_input_payload[31 : 2],2'b00};
  assign iBus_rsp_toStream_valid = iBus_rsp_valid;
  assign iBus_rsp_toStream_payload_error = iBus_rsp_payload_error;
  assign iBus_rsp_toStream_payload_data = iBus_rsp_payload_data;
  assign iBus_rsp_toStream_ready = IBusSimple_rspJoin_rspBuffer_c_io_push_ready;
  assign IBusSimple_rspJoin_rspBuffer_flush = ((IBusSimple_rspJoin_rspBuffer_discardCounter != 3'b000) || IBusSimple_iBusRsp_flush);
  assign IBusSimple_rspJoin_rspBuffer_output_valid = (IBusSimple_rspJoin_rspBuffer_c_io_pop_valid && (IBusSimple_rspJoin_rspBuffer_discardCounter == 3'b000));
  assign IBusSimple_rspJoin_rspBuffer_output_payload_error = IBusSimple_rspJoin_rspBuffer_c_io_pop_payload_error;
  assign IBusSimple_rspJoin_rspBuffer_output_payload_data = IBusSimple_rspJoin_rspBuffer_c_io_pop_payload_data;
  assign IBusSimple_rspJoin_rspBuffer_c_io_pop_ready = (IBusSimple_rspJoin_rspBuffer_output_ready || IBusSimple_rspJoin_rspBuffer_flush);
  assign io_pop_fire = (IBusSimple_rspJoin_rspBuffer_c_io_pop_valid && IBusSimple_rspJoin_rspBuffer_c_io_pop_ready);
  assign IBusSimple_pending_dec = io_pop_fire;
  assign IBusSimple_rspJoin_fetchRsp_pc = IBusSimple_iBusRsp_fetchStages_1_output_payload;
  always @(*) begin
    IBusSimple_rspJoin_fetchRsp_rsp_error = IBusSimple_rspJoin_rspBuffer_output_payload_error;
    if(when_IBusSimple_l146) begin
      IBusSimple_rspJoin_fetchRsp_rsp_error = 1'b0;
    end
  end

  assign IBusSimple_rspJoin_fetchRsp_rsp_data = IBusSimple_rspJoin_rspBuffer_output_payload_data;
  assign when_IBusSimple_l146 = (! IBusSimple_rspJoin_rspBuffer_output_valid);
  always @(*) begin
    IBusSimple_rspJoin_exceptionDetected = 1'b0;
    IBusSimple_instrFetchExceptionPort_payload_code = 4'bxxxx;
    if(when_IBusSimple_l160) begin
      IBusSimple_instrFetchExceptionPort_payload_code = 4'b0001;
      IBusSimple_rspJoin_exceptionDetected = 1'b1;
    end
  end

  assign IBusSimple_rspJoin_join_valid = (IBusSimple_iBusRsp_fetchStages_1_output_valid && IBusSimple_rspJoin_rspBuffer_output_valid);
  assign IBusSimple_rspJoin_join_payload_pc = IBusSimple_rspJoin_fetchRsp_pc;
  assign IBusSimple_rspJoin_join_payload_rsp_error = IBusSimple_rspJoin_fetchRsp_rsp_error;
  assign IBusSimple_rspJoin_join_payload_rsp_data = IBusSimple_rspJoin_fetchRsp_rsp_data;
  assign IBusSimple_rspJoin_join_payload_isRvc = IBusSimple_rspJoin_fetchRsp_isRvc;
  assign IBusSimple_rspJoin_join_payload_legalRvc = IBusSimple_rspJoin_fetchRsp_legalRvc;
  assign IBusSimple_rspJoin_join_fire = (IBusSimple_rspJoin_join_valid && IBusSimple_rspJoin_join_ready);
  assign IBusSimple_iBusRsp_fetchStages_1_output_ready = (IBusSimple_iBusRsp_fetchStages_1_output_valid ? IBusSimple_rspJoin_join_fire : IBusSimple_rspJoin_join_ready);
  assign IBusSimple_rspJoin_rspBuffer_output_ready = IBusSimple_rspJoin_join_fire;
  assign __IBusSimple_rspJoin_join_ready = (! IBusSimple_rspJoin_exceptionDetected);
  assign IBusSimple_rspJoin_join_haltWhen_valid = (IBusSimple_rspJoin_join_valid && __IBusSimple_rspJoin_join_ready);
  assign IBusSimple_rspJoin_join_ready = (IBusSimple_rspJoin_join_haltWhen_ready && __IBusSimple_rspJoin_join_ready);
  assign IBusSimple_rspJoin_join_haltWhen_payload_pc = IBusSimple_rspJoin_join_payload_pc;
  assign IBusSimple_rspJoin_join_haltWhen_payload_rsp_error = IBusSimple_rspJoin_join_payload_rsp_error;
  assign IBusSimple_rspJoin_join_haltWhen_payload_rsp_data = IBusSimple_rspJoin_join_payload_rsp_data;
  assign IBusSimple_rspJoin_join_haltWhen_payload_isRvc = IBusSimple_rspJoin_join_payload_isRvc;
  assign IBusSimple_rspJoin_join_haltWhen_payload_legalRvc = IBusSimple_rspJoin_join_payload_legalRvc;
  assign IBusSimple_iBusRsp_output_valid = IBusSimple_rspJoin_join_haltWhen_valid;
  assign IBusSimple_rspJoin_join_haltWhen_ready = IBusSimple_iBusRsp_output_ready;
  assign IBusSimple_iBusRsp_output_payload_pc = IBusSimple_rspJoin_join_haltWhen_payload_pc;
  assign IBusSimple_iBusRsp_output_payload_rsp_error = IBusSimple_rspJoin_join_haltWhen_payload_rsp_error;
  assign IBusSimple_iBusRsp_output_payload_rsp_data = IBusSimple_rspJoin_join_haltWhen_payload_rsp_data;
  assign IBusSimple_iBusRsp_output_payload_isRvc = IBusSimple_rspJoin_join_haltWhen_payload_isRvc;
  assign IBusSimple_iBusRsp_output_payload_legalRvc = IBusSimple_rspJoin_join_haltWhen_payload_legalRvc;
  assign IBusSimple_rspJoin_badAddr = {IBusSimple_rspJoin_join_payload_pc[31 : 2],2'b00};
  assign IBusSimple_instrFetchExceptionPort_payload_mtval = IBusSimple_rspJoin_badAddr;
  assign IBusSimple_instrFetchExceptionPort_payload_pc = IBusSimple_rspJoin_badAddr;
  assign when_IBusSimple_l160 = (IBusSimple_rspJoin_join_valid && IBusSimple_rspJoin_join_payload_rsp_error);
  assign IBusSimple_instrFetchExceptionPort_valid = (IBusSimple_rspJoin_exceptionDetected && IBusSimple_iBusRsp_readyForError);
  always @(*) begin
    if(core_trace_exc_o) begin
      h2e_inst_itype_o = 4'b0001;
    end else begin
      if(core_trace_irq_o) begin
        h2e_inst_itype_o = 4'b0010;
      end else begin
        if(when_H2E_l73) begin
          h2e_inst_itype_o = 4'b0011;
        end else begin
          if(when_H2E_l75) begin
            h2e_inst_itype_o = 4'b0100;
          end else begin
            if(when_H2E_l77) begin
              h2e_inst_itype_o = 4'b0101;
            end else begin
              if(when_H2E_l79) begin
                if(when_H2E_l82) begin
                  h2e_inst_itype_o = 4'b1000;
                end else begin
                  if(when_H2E_l84) begin
                    h2e_inst_itype_o = 4'b1001;
                  end else begin
                    if(when_H2E_l86) begin
                      h2e_inst_itype_o = 4'b1010;
                    end else begin
                      if(when_H2E_l88) begin
                        h2e_inst_itype_o = 4'b1011;
                      end else begin
                        if(when_H2E_l90) begin
                          h2e_inst_itype_o = 4'b1100;
                        end else begin
                          if(when_H2E_l92) begin
                            h2e_inst_itype_o = 4'b1101;
                          end else begin
                            if(when_H2E_l94) begin
                              h2e_inst_itype_o = 4'b1110;
                            end else begin
                              if(when_H2E_l96) begin
                                h2e_inst_itype_o = 4'b1111;
                              end else begin
                                h2e_inst_itype_o = 4'b0000;
                              end
                            end
                          end
                        end
                      end
                    end
                  end
                end
              end else begin
                h2e_inst_itype_o = 4'b0000;
              end
            end
          end
        end
      end
    end
  end

  assign __when_H2E_l82_2 = __execute_RegisterFileReg_address[11 : 7];
  assign __when_H2E_l82_3 = __execute_RegisterFileReg_address[19 : 15];
  assign when_H2E_l82 = ((__when_H2E_l82 == BranchCtrlEnum_JALR) && (((__when_H2E_l82_2 == 5'h01) && (__when_H2E_l82_3 != 5'h05)) || ((__when_H2E_l82_2 == 5'h05) && (__when_H2E_l82_3 != 5'h01))));
  assign when_H2E_l84 = ((__when_H2E_l82 == BranchCtrlEnum_JAL) && ((__when_H2E_l82_2 == 5'h01) || (__when_H2E_l82_2 == 5'h05)));
  assign when_H2E_l86 = (((__when_H2E_l82 == BranchCtrlEnum_JALR) && (__when_H2E_l82_2 == 5'h0)) && ((__when_H2E_l82_3 != 5'h05) || (__when_H2E_l82_3 != 5'h01)));
  assign when_H2E_l88 = ((__when_H2E_l82 == BranchCtrlEnum_JAL) && (__when_H2E_l82_2 == 5'h0));
  assign when_H2E_l90 = ((__when_H2E_l82 == BranchCtrlEnum_JALR) && (((__when_H2E_l82_2 == 5'h01) && (__when_H2E_l82_3 == 5'h05)) || ((__when_H2E_l82_2 == 5'h05) && (__when_H2E_l82_3 == 5'h01))));
  assign when_H2E_l92 = ((((__when_H2E_l82 == BranchCtrlEnum_JALR) && ((__when_H2E_l82_3 == 5'h01) || (__when_H2E_l82_3 == 5'h05))) && (__when_H2E_l82_2 != 5'h01)) && (__when_H2E_l82_2 != 5'h05));
  assign when_H2E_l94 = ((((__when_H2E_l82 == BranchCtrlEnum_JALR) && (__when_H2E_l82_3 != 5'h01)) && (__when_H2E_l82_3 != 5'h05)) && (__when_H2E_l82_2 == 5'h0));
  assign when_H2E_l96 = (((__when_H2E_l82 == BranchCtrlEnum_JAL) && (__when_H2E_l82_2 != 5'h01)) && (__when_H2E_l82_2 != 5'h05));
  assign when_H2E_l73 = (execute_ENV_CTRL == EnvCtrl_XRET);
  assign when_H2E_l75 = ((((__when_H2E_l82 == BranchCtrlEnum_B) || (__when_H2E_l82 == BranchCtrlEnum_JAL)) || (__when_H2E_l82 == BranchCtrlEnum_JALR)) && (! __when_H2E_l75));
  assign when_H2E_l77 = ((__when_H2E_l82 == BranchCtrlEnum_B) && __when_H2E_l75);
  assign when_H2E_l79 = (((__when_H2E_l82 == BranchCtrlEnum_JAL) || (__when_H2E_l82 == BranchCtrlEnum_JALR)) && __when_H2E_l75);
  assign h2e_inst_cause_o = CsrFile_cause;
  assign h2e_inst_tval_o = CsrFile_tval;
  assign h2e_inst_time_o = CsrFile_cycle;
  assign when_H2E_l107 = 1'b0;
  always @(*) begin
    if(when_H2E_l107) begin
      h2e_inst_priv_o = 3'b100;
    end else begin
      if(when_H2E_l109) begin
        h2e_inst_priv_o = 3'b011;
      end else begin
        h2e_inst_priv_o = 3'b000;
      end
    end
  end

  assign when_H2E_l109 = (CsrPlugin_privilege == 2'b11);
  assign h2e_inst_iaddr_o = execute_PC;
  assign h2e_inst_context_o = CsrFile_context;
  assign h2e_inst_ctype_o = 2'b00;
  assign h2e_inst_iretire_o = execute_arbitration_isFiring;
  assign h2e_inst_ilastsize_o = 2'b01;
  assign cdDBus_cmd_fire = (cdDBus_cmd_valid && cdDBus_cmd_ready);
  always @(*) begin
    h2e_data_daddr_o = 32'h0;
    h2e_data_dtype_o = 4'b0000;
    h2e_data_dsize_o = 8'h0;
    h2e_data_dretire_o = 1'b0;
    h2e_data_sdata_o = 32'h0;
    h2e_data_lresp_o = 2'b00;
    h2e_data_ldata_o = 32'h0;
    if(cdDBus_rsp_ready) begin
      h2e_data_dtype_o = (cdDBus_cmd_payload_wr_regNextWhen ? 4'b0001 : 4'b0000);
      h2e_data_daddr_o = cdDBus_cmd_payload_address_regNextWhen;
      h2e_data_dsize_o = {6'd0, cdDBus_cmd_payload_size_regNextWhen};
      h2e_data_sdata_o = __h2e_data_sdata_o;
      h2e_data_ldata_o = cdDBus_rsp_data;
      if(cdDBus_cmd_payload_wr_regNextWhen) begin
        h2e_data_dretire_o = 1'b1;
      end else begin
        h2e_data_lresp_o[1] = 1'b1;
        h2e_data_lresp_o[0] = cdDBus_rsp_error;
      end
    end
  end

  assign when_H2E_l203 = ((decode_arbitration_isValid && (! decode_arbitration_isStuckByOthers)) && h2e_stall_req_i);
  assign h2e_stall_gnt_o = decode_H2E_idleRegs_1;
  assign execute_RegisterFileReg_regFileReadAddress1 = execute_INSTRUCTION[19 : 15];
  assign execute_RegisterFileReg_regFileReadAddress2 = execute_INSTRUCTION[24 : 20];
  always @(*) begin
    case(execute_RegisterFileReg_regFileReadAddress1)
      5'h01 : begin
        __execute_RS1 = RegisterFileReg_regFile_0;
      end
      5'h02 : begin
        __execute_RS1 = RegisterFileReg_regFile_1;
      end
      5'h03 : begin
        __execute_RS1 = RegisterFileReg_regFile_2;
      end
      5'h04 : begin
        __execute_RS1 = RegisterFileReg_regFile_3;
      end
      5'h05 : begin
        __execute_RS1 = RegisterFileReg_regFile_4;
      end
      5'h06 : begin
        __execute_RS1 = RegisterFileReg_regFile_5;
      end
      5'h07 : begin
        __execute_RS1 = RegisterFileReg_regFile_6;
      end
      5'h08 : begin
        __execute_RS1 = RegisterFileReg_regFile_7;
      end
      5'h09 : begin
        __execute_RS1 = RegisterFileReg_regFile_8;
      end
      5'h0a : begin
        __execute_RS1 = RegisterFileReg_regFile_9;
      end
      5'h0b : begin
        __execute_RS1 = RegisterFileReg_regFile_10;
      end
      5'h0c : begin
        __execute_RS1 = RegisterFileReg_regFile_11;
      end
      5'h0d : begin
        __execute_RS1 = RegisterFileReg_regFile_12;
      end
      5'h0e : begin
        __execute_RS1 = RegisterFileReg_regFile_13;
      end
      5'h0f : begin
        __execute_RS1 = RegisterFileReg_regFile_14;
      end
      5'h10 : begin
        __execute_RS1 = RegisterFileReg_regFile_15;
      end
      5'h11 : begin
        __execute_RS1 = RegisterFileReg_regFile_16;
      end
      5'h12 : begin
        __execute_RS1 = RegisterFileReg_regFile_17;
      end
      5'h13 : begin
        __execute_RS1 = RegisterFileReg_regFile_18;
      end
      5'h14 : begin
        __execute_RS1 = RegisterFileReg_regFile_19;
      end
      5'h15 : begin
        __execute_RS1 = RegisterFileReg_regFile_20;
      end
      5'h16 : begin
        __execute_RS1 = RegisterFileReg_regFile_21;
      end
      5'h17 : begin
        __execute_RS1 = RegisterFileReg_regFile_22;
      end
      5'h18 : begin
        __execute_RS1 = RegisterFileReg_regFile_23;
      end
      5'h19 : begin
        __execute_RS1 = RegisterFileReg_regFile_24;
      end
      5'h1a : begin
        __execute_RS1 = RegisterFileReg_regFile_25;
      end
      5'h1b : begin
        __execute_RS1 = RegisterFileReg_regFile_26;
      end
      5'h1c : begin
        __execute_RS1 = RegisterFileReg_regFile_27;
      end
      5'h1d : begin
        __execute_RS1 = RegisterFileReg_regFile_28;
      end
      5'h1e : begin
        __execute_RS1 = RegisterFileReg_regFile_29;
      end
      5'h1f : begin
        __execute_RS1 = RegisterFileReg_regFile_30;
      end
      default : begin
        __execute_RS1 = 32'h0;
      end
    endcase
  end

  always @(*) begin
    case(execute_RegisterFileReg_regFileReadAddress2)
      5'h01 : begin
        __execute_RS2 = RegisterFileReg_regFile_0;
      end
      5'h02 : begin
        __execute_RS2 = RegisterFileReg_regFile_1;
      end
      5'h03 : begin
        __execute_RS2 = RegisterFileReg_regFile_2;
      end
      5'h04 : begin
        __execute_RS2 = RegisterFileReg_regFile_3;
      end
      5'h05 : begin
        __execute_RS2 = RegisterFileReg_regFile_4;
      end
      5'h06 : begin
        __execute_RS2 = RegisterFileReg_regFile_5;
      end
      5'h07 : begin
        __execute_RS2 = RegisterFileReg_regFile_6;
      end
      5'h08 : begin
        __execute_RS2 = RegisterFileReg_regFile_7;
      end
      5'h09 : begin
        __execute_RS2 = RegisterFileReg_regFile_8;
      end
      5'h0a : begin
        __execute_RS2 = RegisterFileReg_regFile_9;
      end
      5'h0b : begin
        __execute_RS2 = RegisterFileReg_regFile_10;
      end
      5'h0c : begin
        __execute_RS2 = RegisterFileReg_regFile_11;
      end
      5'h0d : begin
        __execute_RS2 = RegisterFileReg_regFile_12;
      end
      5'h0e : begin
        __execute_RS2 = RegisterFileReg_regFile_13;
      end
      5'h0f : begin
        __execute_RS2 = RegisterFileReg_regFile_14;
      end
      5'h10 : begin
        __execute_RS2 = RegisterFileReg_regFile_15;
      end
      5'h11 : begin
        __execute_RS2 = RegisterFileReg_regFile_16;
      end
      5'h12 : begin
        __execute_RS2 = RegisterFileReg_regFile_17;
      end
      5'h13 : begin
        __execute_RS2 = RegisterFileReg_regFile_18;
      end
      5'h14 : begin
        __execute_RS2 = RegisterFileReg_regFile_19;
      end
      5'h15 : begin
        __execute_RS2 = RegisterFileReg_regFile_20;
      end
      5'h16 : begin
        __execute_RS2 = RegisterFileReg_regFile_21;
      end
      5'h17 : begin
        __execute_RS2 = RegisterFileReg_regFile_22;
      end
      5'h18 : begin
        __execute_RS2 = RegisterFileReg_regFile_23;
      end
      5'h19 : begin
        __execute_RS2 = RegisterFileReg_regFile_24;
      end
      5'h1a : begin
        __execute_RS2 = RegisterFileReg_regFile_25;
      end
      5'h1b : begin
        __execute_RS2 = RegisterFileReg_regFile_26;
      end
      5'h1c : begin
        __execute_RS2 = RegisterFileReg_regFile_27;
      end
      5'h1d : begin
        __execute_RS2 = RegisterFileReg_regFile_28;
      end
      5'h1e : begin
        __execute_RS2 = RegisterFileReg_regFile_29;
      end
      5'h1f : begin
        __execute_RS2 = RegisterFileReg_regFile_30;
      end
      default : begin
        __execute_RS2 = 32'h0;
      end
    endcase
  end

  assign when_RegisterFile_l298 = (decode_INSTRUCTION[11 : 7] == 5'h0);
  assign execute_RegisterFileReg_selAsync = 1'b0;
  assign execute_RegisterFileReg_address = __execute_RegisterFileReg_address[11 : 7];
  assign execute_RegisterFileReg_valid = (((__execute_RegisterFileReg_valid && execute_arbitration_isFiring) && (execute_RegisterFileReg_address != 5'h0)) || execute_RegisterFileReg_selAsync);
  assign __when_RegisterFile_l255 = execute_RegisterFileReg_address;
  assign when_RegisterFile_l255 = (execute_RegisterFileReg_valid && (__when_RegisterFile_l255 == 5'h01));
  assign when_RegisterFile_l255_1 = (execute_RegisterFileReg_valid && (__when_RegisterFile_l255 == 5'h02));
  assign when_RegisterFile_l255_2 = (execute_RegisterFileReg_valid && (__when_RegisterFile_l255 == 5'h03));
  assign when_RegisterFile_l255_3 = (execute_RegisterFileReg_valid && (__when_RegisterFile_l255 == 5'h04));
  assign when_RegisterFile_l255_4 = (execute_RegisterFileReg_valid && (__when_RegisterFile_l255 == 5'h05));
  assign when_RegisterFile_l255_5 = (execute_RegisterFileReg_valid && (__when_RegisterFile_l255 == 5'h06));
  assign when_RegisterFile_l255_6 = (execute_RegisterFileReg_valid && (__when_RegisterFile_l255 == 5'h07));
  assign when_RegisterFile_l255_7 = (execute_RegisterFileReg_valid && (__when_RegisterFile_l255 == 5'h08));
  assign when_RegisterFile_l255_8 = (execute_RegisterFileReg_valid && (__when_RegisterFile_l255 == 5'h09));
  assign when_RegisterFile_l255_9 = (execute_RegisterFileReg_valid && (__when_RegisterFile_l255 == 5'h0a));
  assign when_RegisterFile_l255_10 = (execute_RegisterFileReg_valid && (__when_RegisterFile_l255 == 5'h0b));
  assign when_RegisterFile_l255_11 = (execute_RegisterFileReg_valid && (__when_RegisterFile_l255 == 5'h0c));
  assign when_RegisterFile_l255_12 = (execute_RegisterFileReg_valid && (__when_RegisterFile_l255 == 5'h0d));
  assign when_RegisterFile_l255_13 = (execute_RegisterFileReg_valid && (__when_RegisterFile_l255 == 5'h0e));
  assign when_RegisterFile_l255_14 = (execute_RegisterFileReg_valid && (__when_RegisterFile_l255 == 5'h0f));
  assign when_RegisterFile_l255_15 = (execute_RegisterFileReg_valid && (__when_RegisterFile_l255 == 5'h10));
  assign when_RegisterFile_l255_16 = (execute_RegisterFileReg_valid && (__when_RegisterFile_l255 == 5'h11));
  assign when_RegisterFile_l255_17 = (execute_RegisterFileReg_valid && (__when_RegisterFile_l255 == 5'h12));
  assign when_RegisterFile_l255_18 = (execute_RegisterFileReg_valid && (__when_RegisterFile_l255 == 5'h13));
  assign when_RegisterFile_l255_19 = (execute_RegisterFileReg_valid && (__when_RegisterFile_l255 == 5'h14));
  assign when_RegisterFile_l255_20 = (execute_RegisterFileReg_valid && (__when_RegisterFile_l255 == 5'h15));
  assign when_RegisterFile_l255_21 = (execute_RegisterFileReg_valid && (__when_RegisterFile_l255 == 5'h16));
  assign when_RegisterFile_l255_22 = (execute_RegisterFileReg_valid && (__when_RegisterFile_l255 == 5'h17));
  assign when_RegisterFile_l255_23 = (execute_RegisterFileReg_valid && (__when_RegisterFile_l255 == 5'h18));
  assign when_RegisterFile_l255_24 = (execute_RegisterFileReg_valid && (__when_RegisterFile_l255 == 5'h19));
  assign when_RegisterFile_l255_25 = (execute_RegisterFileReg_valid && (__when_RegisterFile_l255 == 5'h1a));
  assign when_RegisterFile_l255_26 = (execute_RegisterFileReg_valid && (__when_RegisterFile_l255 == 5'h1b));
  assign when_RegisterFile_l255_27 = (execute_RegisterFileReg_valid && (__when_RegisterFile_l255 == 5'h1c));
  assign when_RegisterFile_l255_28 = (execute_RegisterFileReg_valid && (__when_RegisterFile_l255 == 5'h1d));
  assign when_RegisterFile_l255_29 = (execute_RegisterFileReg_valid && (__when_RegisterFile_l255 == 5'h1e));
  assign when_RegisterFile_l255_30 = (execute_RegisterFileReg_valid && (__when_RegisterFile_l255 == 5'h1f));
  assign core_trace_reg_addr_o = execute_RegisterFileReg_address;
  assign core_trace_reg_wr_o = execute_RegisterFileReg_valid;
  assign core_trace_reg_val_o = execute_RegisterFileReg_data;
  always @(*) begin
    case(execute_ALU_BITWISE_CTRL)
      AluBitwiseCtrl_AND_1 : begin
        execute_IntAlu_bitwise = (execute_SRC1 & execute_SRC2);
      end
      AluBitwiseCtrl_OR_1 : begin
        execute_IntAlu_bitwise = (execute_SRC1 | execute_SRC2);
      end
      default : begin
        execute_IntAlu_bitwise = (execute_SRC1 ^ execute_SRC2);
      end
    endcase
  end

  always @(*) begin
    case(execute_ALU_CTRL)
      AluCtrl_BITWISE : begin
        __execute_REGFILE_WRITE_DATA = execute_IntAlu_bitwise;
      end
      AluCtrl_SLT_SLTU : begin
        __execute_REGFILE_WRITE_DATA = {31'd0, ____execute_REGFILE_WRITE_DATA};
      end
      default : begin
        __execute_REGFILE_WRITE_DATA = execute_SRC_ADD_SUB;
      end
    endcase
  end

  always @(*) begin
    CsrPlugin_privilege = 2'b11;
    if(CsrFile_forceMachineWire) begin
      CsrPlugin_privilege = 2'b11;
    end
  end

  assign CsrFile_misa_base = 2'b01;
  assign CsrFile_misa_extensions = 26'h0000100;
  assign __execute_RegisterFileReg_data_2 = 11'h669;
  assign __execute_RegisterFileReg_data_3 = 32'h80000002;
  assign __execute_RegisterFileReg_data_4 = 1'b1;
  assign __execute_RegisterFileReg_data_5 = CsrFile_mtvec_mode[0];
  assign __execute_RegisterFileReg_data_6 = CsrFile_mcycle[31 : 0];
  assign __execute_RegisterFileReg_data_7 = CsrFile_mcycle[63 : 32];
  assign __execute_RegisterFileReg_data_8 = CsrFile_minstret[31 : 0];
  assign __execute_RegisterFileReg_data_9 = CsrFile_minstret[63 : 32];
  assign __execute_RegisterFileReg_data_10 = CsrFile_mcycle[31 : 0];
  assign __execute_RegisterFileReg_data_11 = CsrFile_mcycle[63 : 32];
  assign __execute_RegisterFileReg_data_12 = CsrFile_mtime[31 : 0];
  assign __execute_RegisterFileReg_data_13 = CsrFile_mtime[63 : 32];
  assign __execute_RegisterFileReg_data_14 = CsrFile_minstret[31 : 0];
  assign __execute_RegisterFileReg_data_15 = CsrFile_minstret[63 : 32];
  assign CsrFile_context = CsrFile_mstatus_MPP;
  assign CsrFile_time = CsrFile_mtime;
  assign CsrFile_cycle = CsrFile_mcycle;
  assign CsrFile_minstret_write = ((execute_IS_CSR && execute_CSR_WRITE_OPCODE) && ((execute_INSTRUCTION[31 : 20] == 12'hb02) || (execute_INSTRUCTION[31 : 20] == 12'hb82)));
  assign when_CsrFile_l869 = (((execute_arbitration_isFiring && (! CsrFile_minstret_write)) && (execute_ENV_CTRL != EnvCtrl_ECALL)) && (execute_ENV_CTRL != EnvCtrl_EBREAK));
  assign __when_CsrFile_l993 = (CsrFile_mip_MSIP && CsrFile_mie_MSIE);
  assign __when_CsrFile_l993_1 = (CsrFile_mip_MTIP && CsrFile_mie_MTIE);
  assign __when_CsrFile_l993_2 = (CsrFile_mip_MEIP && CsrFile_mie_MEIE);
  assign CsrFile_exceptionPortCtrl_exceptionTargetPrivilegeUncapped = 2'b11;
  assign CsrFile_exceptionPortCtrl_exceptionTargetPrivilege = ((CsrPlugin_privilege < CsrFile_exceptionPortCtrl_exceptionTargetPrivilegeUncapped) ? CsrFile_exceptionPortCtrl_exceptionTargetPrivilegeUncapped : CsrPlugin_privilege);
  assign __CsrFile_exceptionPortCtrl_exceptionContext_code = {decodeExceptionPort_valid,IBusSimple_instrFetchExceptionPort_valid};
  assign __CsrFile_exceptionPortCtrl_exceptionContext_code_1 = ____CsrFile_exceptionPortCtrl_exceptionContext_code_1[0];
  assign __CsrFile_exceptionPortCtrl_exceptionContext_code_2 = {DBusSimple_memoryExceptionPort_valid,{Branch_branchExceptionPort_valid,CsrFile_selfException_valid}};
  assign __CsrFile_exceptionPortCtrl_exceptionContext_code_3 = (__CsrFile_exceptionPortCtrl_exceptionContext_code_2 & (~ ____CsrFile_exceptionPortCtrl_exceptionContext_code_3));
  assign __CsrFile_exceptionPortCtrl_exceptionContext_code_4 = __CsrFile_exceptionPortCtrl_exceptionContext_code_3[1];
  assign __CsrFile_exceptionPortCtrl_exceptionContext_code_5 = __CsrFile_exceptionPortCtrl_exceptionContext_code_3[2];
  assign __CsrFile_exceptionPortCtrl_exceptionContext_code_6 = {__CsrFile_exceptionPortCtrl_exceptionContext_code_5,__CsrFile_exceptionPortCtrl_exceptionContext_code_4};
  assign when_CsrFile_l951 = (! decode_arbitration_isStuck);
  assign when_CsrFile_l951_1 = (! execute_arbitration_isStuck);
  assign when_CsrFile_l966 = (|{CsrFile_exceptionPortCtrl_exceptionValids_execute,CsrFile_exceptionPortCtrl_exceptionValids_decode});
  assign CsrFile_exceptionPendings_0 = CsrFile_exceptionPortCtrl_exceptionValidsRegs_decode;
  assign CsrFile_exceptionPendings_1 = CsrFile_exceptionPortCtrl_exceptionValidsRegs_execute;
  assign CsrFile_tval = CsrFile_exceptionPortCtrl_exceptionContext_mtval;
  assign when_CsrFile_l987 = (CsrFile_mstatus_MIE || (CsrPlugin_privilege < 2'b11));
  assign when_CsrFile_l993 = ((__when_CsrFile_l993 && 1'b1) && (! 1'b0));
  assign when_CsrFile_l993_1 = ((__when_CsrFile_l993_1 && 1'b1) && (! 1'b0));
  assign when_CsrFile_l993_2 = ((__when_CsrFile_l993_2 && 1'b1) && (! 1'b0));
  assign CsrFile_exception = (CsrFile_exceptionPortCtrl_exceptionValids_execute && CsrFile_allowException);
  assign CsrFile_irq_payload_code = CsrFile_clint_code;
  assign CsrFile_irq_payload_targetPrivilege = CsrFile_clint_targetPrivilege;
  always @(*) begin
    CsrFile_xtvec_mode = 2'bxx;
    CsrFile_xtvec_submode = 4'bxxxx;
    CsrFile_xtvec_base = 26'bxxxxxxxxxxxxxxxxxxxxxxxxxx;
    case(CsrFile_clint_targetPrivilege)
      2'b11 : begin
        CsrFile_xtvec_mode = CsrFile_mtvec_mode;
        CsrFile_xtvec_submode = CsrFile_mtvec_submode;
        CsrFile_xtvec_base = CsrFile_mtvec_base;
      end
      default : begin
      end
    endcase
  end

  assign CsrFile_xtvecBase = {CsrFile_xtvec_base,CsrFile_xtvec_submode};
  assign CsrFile_irq_payload_targetAddr = ((CsrFile_xtvec_mode == 2'b00) ? {CsrFile_xtvecBase,2'b00} : {__CsrFile_irq_payload_targetAddr,2'b00});
  assign when_CsrFile_l1052 = (! execute_arbitration_haltItself);
  assign CsrFile_pipelineFlush_active = ((((CsrFile_irq_valid || CsrFile_irq_valid_delayed) || CsrFile_pendingIrq_valid) && CsrFile_allowInterrupts) && decode_arbitration_isValid);
  assign when_CsrFile_l1063 = (! execute_arbitration_isStuck);
  assign when_CsrFile_l1068 = ((! CsrFile_pipelineFlush_active) || decode_arbitration_removeIt);
  always @(*) begin
    CsrFile_pipelineFlush_done = CsrFile_pipelineFlush_pcValids_0;
    if(when_CsrFile_l1073) begin
      CsrFile_pipelineFlush_done = 1'b0;
    end
    if(CsrFile_hadException) begin
      CsrFile_pipelineFlush_done = 1'b0;
    end
  end

  assign when_CsrFile_l1073 = (|CsrFile_exceptionPortCtrl_exceptionValidsRegs_execute);
  assign when_CsrFile_l1074 = (CsrFile_pipelineFlush_done && CsrFile_pendingIrq_valid);
  assign CsrFile_interruptJump = ((CsrFile_pendingIrq_valid && CsrFile_pipelineFlush_done) && CsrFile_allowInterrupts);
  always @(*) begin
    CsrFile_targetPrivilege = CsrFile_irq_payload_targetPrivilege;
    if(CsrFile_hadException) begin
      CsrFile_targetPrivilege = CsrFile_exceptionPortCtrl_exceptionTargetPrivilege;
    end
  end

  always @(*) begin
    CsrFile_trapCause = CsrFile_irq_payload_code;
    if(CsrFile_hadException) begin
      CsrFile_trapCause = CsrFile_exceptionPortCtrl_exceptionContext_code;
    end
  end

  assign CsrFile_cause = CsrFile_trapCause;
  assign CsrFile_trapCauseEbreakDebug = 1'b0;
  always @(*) begin
    CsrFile_excXtvec_mode = 2'bxx;
    CsrFile_excXtvec_submode = 4'bxxxx;
    CsrFile_excXtvec_base = 26'bxxxxxxxxxxxxxxxxxxxxxxxxxx;
    case(CsrFile_exceptionPortCtrl_exceptionTargetPrivilege)
      2'b11 : begin
        CsrFile_excXtvec_mode = CsrFile_mtvec_mode;
        CsrFile_excXtvec_submode = CsrFile_mtvec_submode;
        CsrFile_excXtvec_base = CsrFile_mtvec_base;
      end
      default : begin
      end
    endcase
  end

  assign CsrFile_trapEnterDebug = 1'b0;
  assign when_CsrFile_l1126 = (CsrFile_hadException || CsrFile_interruptJump);
  assign when_CsrFile_l1137 = (! CsrFile_trapEnterDebug);
  assign when_CsrFile_l1196 = (execute_arbitration_isValid && (execute_ENV_CTRL == EnvCtrl_XRET));
  assign switch_CsrFile_l1200 = execute_INSTRUCTION[29 : 28];
  assign contextSwitching = CsrFile_jumpInterface_valid;
  assign when_CsrFile_l1258 = (execute_arbitration_isValid && (execute_ENV_CTRL == EnvCtrl_WFI));
  assign when_CsrFile_l1262 = ((! execute_CsrFile_wfiWake) && CsrFile_allowInterrupts);
  assign idle_o = __idle_o_1;
  assign when_CsrFile_l1275 = (|(execute_arbitration_isValid && (execute_ENV_CTRL == EnvCtrl_XRET)));
  assign execute_CsrFile_blockedBySideEffects = 1'b0;
  always @(*) begin
    execute_CsrFile_illegalInstruction = 1'b0;
    if(when_CsrFile_l1300) begin
      if(when_CsrFile_l1301) begin
        execute_CsrFile_illegalInstruction = 1'b1;
      end
    end
  end

  always @(*) begin
    CsrFile_selfException_valid = 1'b0;
    CsrFile_selfException_payload_code = 4'bxxxx;
    CsrFile_selfException_payload_mtval = 32'h0;
    if(when_CsrFile_l1292) begin
      CsrFile_selfException_payload_mtval = execute_INSTRUCTION;
      CsrFile_selfException_valid = 1'b1;
      CsrFile_selfException_payload_code = 4'b0010;
    end
    if(when_CsrFile_l1307) begin
      CsrFile_selfException_valid = 1'b1;
      case(CsrPlugin_privilege)
        2'b00 : begin
          CsrFile_selfException_payload_code = 4'b1000;
        end
        default : begin
          CsrFile_selfException_payload_code = 4'b1011;
        end
      endcase
    end
    if(when_CsrFile_l1315) begin
      CsrFile_selfException_payload_mtval = execute_PC;
      CsrFile_selfException_valid = 1'b1;
      CsrFile_selfException_payload_code = 4'b0011;
    end
  end

  assign CsrFile_selfException_payload_pc = execute_PC;
  assign when_CsrFile_l1292 = (execute_CsrFile_illegalAccess || execute_CsrFile_illegalInstruction);
  assign when_CsrFile_l1300 = (execute_arbitration_isValid && (execute_ENV_CTRL == EnvCtrl_XRET));
  assign when_CsrFile_l1301 = (CsrPlugin_privilege < execute_INSTRUCTION[29 : 28]);
  assign when_CsrFile_l1307 = (execute_arbitration_isValid && (execute_ENV_CTRL == EnvCtrl_ECALL));
  assign when_CsrFile_l1315 = (execute_arbitration_isValid && (execute_ENV_CTRL == EnvCtrl_EBREAK));
  assign CsrFile_writeEnable = ((execute_CsrFile_writeInstruction && (! execute_CsrFile_blockedBySideEffects)) && (! execute_arbitration_isStuckByOthers));
  assign CsrFile_readEnable = ((execute_CsrFile_readInstruction && (! execute_CsrFile_blockedBySideEffects)) && (! execute_arbitration_isStuckByOthers));
  assign execute_CsrFile_readToWriteData = __execute_RegisterFileReg_data;
  assign switch_Misc_l245 = execute_INSTRUCTION[13];
  always @(*) begin
    case(switch_Misc_l245)
      1'b0 : begin
        __CsrFile_mtvec_mode_1 = execute_SRC1;
      end
      default : begin
        __CsrFile_mtvec_mode_1 = (execute_INSTRUCTION[12] ? (execute_CsrFile_readToWriteData & (~ execute_SRC1)) : (execute_CsrFile_readToWriteData | execute_SRC1));
      end
    endcase
  end

  assign __CsrFile_mtvec_mode = __CsrFile_mtvec_mode_1;
  assign when_CsrFile_l1359 = (execute_arbitration_isValid && execute_IS_CSR);
  assign execute_CsrFile_csrAddress = execute_INSTRUCTION[31 : 20];
  assign core_trace_instr_o = execute_INSTRUCTION;
  assign core_trace_pc_o = execute_PC;
  assign core_trace_valid_o = execute_arbitration_isFiring;
  assign core_trace_irq_o = CsrFile_interruptJump;
  assign core_trace_exc_o = CsrFile_hadException;
  assign core_trace_exccode_o = CsrFile_trapCause;
  always @(*) begin
    case(execute_SRC1_CTRL)
      Src1Ctrl_RS : begin
        __execute_SRC1 = execute_RS1;
      end
      Src1Ctrl_PC_INCREMENT : begin
        __execute_SRC1 = {29'd0, ____execute_SRC1};
      end
      Src1Ctrl_IMU : begin
        __execute_SRC1 = {execute_INSTRUCTION[31 : 12],12'h0};
      end
      default : begin
        __execute_SRC1 = {27'd0, ____execute_SRC1_1};
      end
    endcase
  end

  assign __execute_SRC2 = execute_INSTRUCTION[31];
  always @(*) begin
    __execute_SRC2_1[19] = __execute_SRC2;
    __execute_SRC2_1[18] = __execute_SRC2;
    __execute_SRC2_1[17] = __execute_SRC2;
    __execute_SRC2_1[16] = __execute_SRC2;
    __execute_SRC2_1[15] = __execute_SRC2;
    __execute_SRC2_1[14] = __execute_SRC2;
    __execute_SRC2_1[13] = __execute_SRC2;
    __execute_SRC2_1[12] = __execute_SRC2;
    __execute_SRC2_1[11] = __execute_SRC2;
    __execute_SRC2_1[10] = __execute_SRC2;
    __execute_SRC2_1[9] = __execute_SRC2;
    __execute_SRC2_1[8] = __execute_SRC2;
    __execute_SRC2_1[7] = __execute_SRC2;
    __execute_SRC2_1[6] = __execute_SRC2;
    __execute_SRC2_1[5] = __execute_SRC2;
    __execute_SRC2_1[4] = __execute_SRC2;
    __execute_SRC2_1[3] = __execute_SRC2;
    __execute_SRC2_1[2] = __execute_SRC2;
    __execute_SRC2_1[1] = __execute_SRC2;
    __execute_SRC2_1[0] = __execute_SRC2;
  end

  assign __execute_SRC2_2 = ____execute_SRC2_2[11];
  always @(*) begin
    __execute_SRC2_3[19] = __execute_SRC2_2;
    __execute_SRC2_3[18] = __execute_SRC2_2;
    __execute_SRC2_3[17] = __execute_SRC2_2;
    __execute_SRC2_3[16] = __execute_SRC2_2;
    __execute_SRC2_3[15] = __execute_SRC2_2;
    __execute_SRC2_3[14] = __execute_SRC2_2;
    __execute_SRC2_3[13] = __execute_SRC2_2;
    __execute_SRC2_3[12] = __execute_SRC2_2;
    __execute_SRC2_3[11] = __execute_SRC2_2;
    __execute_SRC2_3[10] = __execute_SRC2_2;
    __execute_SRC2_3[9] = __execute_SRC2_2;
    __execute_SRC2_3[8] = __execute_SRC2_2;
    __execute_SRC2_3[7] = __execute_SRC2_2;
    __execute_SRC2_3[6] = __execute_SRC2_2;
    __execute_SRC2_3[5] = __execute_SRC2_2;
    __execute_SRC2_3[4] = __execute_SRC2_2;
    __execute_SRC2_3[3] = __execute_SRC2_2;
    __execute_SRC2_3[2] = __execute_SRC2_2;
    __execute_SRC2_3[1] = __execute_SRC2_2;
    __execute_SRC2_3[0] = __execute_SRC2_2;
  end

  always @(*) begin
    case(execute_SRC2_CTRL)
      Src2Ctrl_RS : begin
        __execute_SRC2_4 = execute_RS2;
      end
      Src2Ctrl_IMI : begin
        __execute_SRC2_4 = {__execute_SRC2_1,execute_INSTRUCTION[31 : 20]};
      end
      Src2Ctrl_IMS : begin
        __execute_SRC2_4 = {__execute_SRC2_3,{execute_INSTRUCTION[31 : 25],execute_INSTRUCTION[11 : 7]}};
      end
      default : begin
        __execute_SRC2_4 = execute_PC;
      end
    endcase
  end

  always @(*) begin
    execute_SrcSelector_add = __execute_SrcSelector_add;
    if(execute_SRC_ADD_ZERO) begin
      execute_SrcSelector_add = execute_SRC1;
    end
  end

  assign execute_SrcSelector_sub = __execute_SrcSelector_sub;
  assign execute_SrcSelector_less = ((execute_SRC1[31] == execute_SRC2[31]) ? execute_SrcSelector_sub[31] : (execute_SRC_LESS_UNSIGNED ? execute_SRC2[31] : execute_SRC1[31]));
  assign execute_Branch_eq = (execute_SRC1 == execute_SRC2);
  assign switch_Misc_l245_1 = execute_INSTRUCTION[14 : 12];
  always @(*) begin
    casez(switch_Misc_l245_1)
      3'b000 : begin
        __execute_BRANCH_DO = execute_Branch_eq;
      end
      3'b001 : begin
        __execute_BRANCH_DO = (! execute_Branch_eq);
      end
      3'b1?1 : begin
        __execute_BRANCH_DO = (! execute_SRC_LESS);
      end
      default : begin
        __execute_BRANCH_DO = execute_SRC_LESS;
      end
    endcase
  end

  always @(*) begin
    case(execute_BRANCH_CTRL)
      BranchCtrlEnum_INC : begin
        __execute_BRANCH_DO_1 = 1'b0;
      end
      BranchCtrlEnum_JAL : begin
        __execute_BRANCH_DO_1 = 1'b1;
      end
      BranchCtrlEnum_JALR : begin
        __execute_BRANCH_DO_1 = 1'b1;
      end
      default : begin
        __execute_BRANCH_DO_1 = __execute_BRANCH_DO;
      end
    endcase
  end

  assign branchSrc1 = ((execute_BRANCH_CTRL == BranchCtrlEnum_JALR) ? execute_RS1 : execute_PC);
  assign __branchSrc2 = ____branchSrc2[19];
  always @(*) begin
    __branchSrc2_1[10] = __branchSrc2;
    __branchSrc2_1[9] = __branchSrc2;
    __branchSrc2_1[8] = __branchSrc2;
    __branchSrc2_1[7] = __branchSrc2;
    __branchSrc2_1[6] = __branchSrc2;
    __branchSrc2_1[5] = __branchSrc2;
    __branchSrc2_1[4] = __branchSrc2;
    __branchSrc2_1[3] = __branchSrc2;
    __branchSrc2_1[2] = __branchSrc2;
    __branchSrc2_1[1] = __branchSrc2;
    __branchSrc2_1[0] = __branchSrc2;
  end

  assign __branchSrc2_2 = execute_INSTRUCTION[31];
  always @(*) begin
    __branchSrc2_3[19] = __branchSrc2_2;
    __branchSrc2_3[18] = __branchSrc2_2;
    __branchSrc2_3[17] = __branchSrc2_2;
    __branchSrc2_3[16] = __branchSrc2_2;
    __branchSrc2_3[15] = __branchSrc2_2;
    __branchSrc2_3[14] = __branchSrc2_2;
    __branchSrc2_3[13] = __branchSrc2_2;
    __branchSrc2_3[12] = __branchSrc2_2;
    __branchSrc2_3[11] = __branchSrc2_2;
    __branchSrc2_3[10] = __branchSrc2_2;
    __branchSrc2_3[9] = __branchSrc2_2;
    __branchSrc2_3[8] = __branchSrc2_2;
    __branchSrc2_3[7] = __branchSrc2_2;
    __branchSrc2_3[6] = __branchSrc2_2;
    __branchSrc2_3[5] = __branchSrc2_2;
    __branchSrc2_3[4] = __branchSrc2_2;
    __branchSrc2_3[3] = __branchSrc2_2;
    __branchSrc2_3[2] = __branchSrc2_2;
    __branchSrc2_3[1] = __branchSrc2_2;
    __branchSrc2_3[0] = __branchSrc2_2;
  end

  assign __branchSrc2_4 = ____branchSrc2_4[11];
  always @(*) begin
    __branchSrc2_5[18] = __branchSrc2_4;
    __branchSrc2_5[17] = __branchSrc2_4;
    __branchSrc2_5[16] = __branchSrc2_4;
    __branchSrc2_5[15] = __branchSrc2_4;
    __branchSrc2_5[14] = __branchSrc2_4;
    __branchSrc2_5[13] = __branchSrc2_4;
    __branchSrc2_5[12] = __branchSrc2_4;
    __branchSrc2_5[11] = __branchSrc2_4;
    __branchSrc2_5[10] = __branchSrc2_4;
    __branchSrc2_5[9] = __branchSrc2_4;
    __branchSrc2_5[8] = __branchSrc2_4;
    __branchSrc2_5[7] = __branchSrc2_4;
    __branchSrc2_5[6] = __branchSrc2_4;
    __branchSrc2_5[5] = __branchSrc2_4;
    __branchSrc2_5[4] = __branchSrc2_4;
    __branchSrc2_5[3] = __branchSrc2_4;
    __branchSrc2_5[2] = __branchSrc2_4;
    __branchSrc2_5[1] = __branchSrc2_4;
    __branchSrc2_5[0] = __branchSrc2_4;
  end

  always @(*) begin
    case(execute_BRANCH_CTRL)
      BranchCtrlEnum_JAL : begin
        __branchSrc2_6 = {{__branchSrc2_1,{{{execute_INSTRUCTION[31],execute_INSTRUCTION[19 : 12]},execute_INSTRUCTION[20]},execute_INSTRUCTION[30 : 21]}},1'b0};
      end
      BranchCtrlEnum_JALR : begin
        __branchSrc2_6 = {__branchSrc2_3,execute_INSTRUCTION[31 : 20]};
      end
      default : begin
        __branchSrc2_6 = {{__branchSrc2_5,{{{execute_INSTRUCTION[31],execute_INSTRUCTION[7]},execute_INSTRUCTION[30 : 25]},execute_INSTRUCTION[11 : 8]}},1'b0};
      end
    endcase
  end

  assign branchSrc2 = __branchSrc2_6;
  assign Branch_jumpInterface_valid = ((execute_arbitration_isValid && execute_BRANCH_DO) && (! execute_arbitration_isStuckByOthers));
  assign Branch_jumpInterface_payload = execute_BRANCH_TARGET;
  always @(*) begin
    Branch_branchExceptionPort_valid = ((execute_arbitration_isValid && execute_BRANCH_DO) && Branch_jumpInterface_payload[1]);
    if(execute_arbitration_isStuckByOthers) begin
      Branch_branchExceptionPort_valid = 1'b0;
    end
  end

  assign Branch_branchExceptionPort_payload_code = 4'b0000;
  assign Branch_branchExceptionPort_payload_mtval = execute_BRANCH_TARGET;
  assign Branch_branchExceptionPort_payload_pc = execute_PC;
  assign when_Branch_l172 = ((execute_arbitration_isValid && execute_IS_FENCEI) && 1'b0);
  assign dBus_cmd_valid = cdDBus_cmd_valid;
  assign dBus_cmd_payload_wr = cdDBus_cmd_payload_wr;
  assign dBus_cmd_payload_address = cdDBus_cmd_payload_address;
  assign dBus_cmd_payload_data = cdDBus_cmd_payload_data;
  assign dBus_cmd_payload_size = cdDBus_cmd_payload_size;
  assign sharedDBus_cmd_fire = (sharedDBus_cmd_valid && sharedDBus_cmd_ready);
  assign when_DBusSimple_l242 = (! execute_arbitration_isStuck);
  always @(*) begin
    execute_DBusSimple_skipCmd = 1'b0;
    if(execute_ALIGNEMENT_FAULT) begin
      execute_DBusSimple_skipCmd = 1'b1;
    end
  end

  assign execute_DBusSimple_memAccessActive = (((execute_arbitration_isValid && execute_MEMORY_ENABLE) && (! execute_DBusSimple_skipCmd)) && (! __execute_DBusSimple_memAccessActive));
  assign sharedDBus_cmd_valid = ((execute_DBusSimple_memAccessActive && (! execute_arbitration_isStuckByOthers)) && (! execute_arbitration_isFlushed));
  assign sharedDBus_cmd_payload_wr = execute_MEMORY_STORE;
  assign sharedDBus_cmd_payload_size = execute_INSTRUCTION[13 : 12];
  always @(*) begin
    case(sharedDBus_cmd_payload_size)
      2'b00 : begin
        __sharedDBus_cmd_payload_data = {{{execute_RS2[7 : 0],execute_RS2[7 : 0]},execute_RS2[7 : 0]},execute_RS2[7 : 0]};
      end
      2'b01 : begin
        __sharedDBus_cmd_payload_data = {execute_RS2[15 : 0],execute_RS2[15 : 0]};
      end
      default : begin
        __sharedDBus_cmd_payload_data = execute_RS2[31 : 0];
      end
    endcase
  end

  assign sharedDBus_cmd_payload_data = __sharedDBus_cmd_payload_data;
  assign when_DBusSimple_l278 = (execute_DBusSimple_memAccessActive && (! sharedDBus_cmd_ready));
  assign sharedDBus_cmd_payload_address = execute_SRC_ADD;
  assign execute_DBusSimple_wait4rsp = (! execute_MEMORY_STORE);
  assign when_DBusSimple_l325 = (((execute_arbitration_isValid && execute_MEMORY_ENABLE) && execute_DBusSimple_wait4rsp) && ((! sharedDBus_rsp_ready) || (! __execute_DBusSimple_memAccessActive)));
  always @(*) begin
    DBusSimple_memoryExceptionPort_valid = 1'b0;
    DBusSimple_memoryExceptionPort_payload_code = 4'bxxxx;
    if(when_DBusSimple_l332) begin
      DBusSimple_memoryExceptionPort_valid = 1'b1;
      DBusSimple_memoryExceptionPort_payload_code = {1'd0, __DBusSimple_memoryExceptionPort_payload_code};
    end
    if(execute_ALIGNEMENT_FAULT) begin
      DBusSimple_memoryExceptionPort_payload_code = {1'd0, __DBusSimple_memoryExceptionPort_payload_code_1};
      DBusSimple_memoryExceptionPort_valid = 1'b1;
    end
    if(when_DBusSimple_l340) begin
      DBusSimple_memoryExceptionPort_valid = 1'b0;
    end
  end

  assign DBusSimple_memoryExceptionPort_payload_mtval = execute_MEMORY_ADDRESS;
  assign DBusSimple_memoryExceptionPort_payload_pc = execute_PC;
  assign when_DBusSimple_l332 = ((sharedDBus_rsp_ready && sharedDBus_rsp_error) || execute_ACCESS_FAULT);
  assign when_DBusSimple_l340 = (! ((execute_arbitration_isValid && execute_MEMORY_ENABLE) && (1'b0 || (! execute_arbitration_isStuckByOthers))));
  always @(*) begin
    execute_DBusSimple_rspShifted = execute_MEMORY_READ_DATA;
    case(switch_DBusSimple_l358)
      2'b01 : begin
        execute_DBusSimple_rspShifted[7 : 0] = execute_MEMORY_READ_DATA[15 : 8];
      end
      2'b10 : begin
        execute_DBusSimple_rspShifted[15 : 0] = execute_MEMORY_READ_DATA[31 : 16];
      end
      2'b11 : begin
        execute_DBusSimple_rspShifted[7 : 0] = execute_MEMORY_READ_DATA[31 : 24];
      end
      default : begin
      end
    endcase
  end

  assign switch_DBusSimple_l358 = execute_MEMORY_ADDRESS[1 : 0];
  assign switch_Misc_l245_2 = execute_INSTRUCTION[13 : 12];
  assign __execute_DBusSimple_rspFormated = (execute_DBusSimple_rspShifted[7] && (! execute_INSTRUCTION[14]));
  always @(*) begin
    __execute_DBusSimple_rspFormated_1[31] = __execute_DBusSimple_rspFormated;
    __execute_DBusSimple_rspFormated_1[30] = __execute_DBusSimple_rspFormated;
    __execute_DBusSimple_rspFormated_1[29] = __execute_DBusSimple_rspFormated;
    __execute_DBusSimple_rspFormated_1[28] = __execute_DBusSimple_rspFormated;
    __execute_DBusSimple_rspFormated_1[27] = __execute_DBusSimple_rspFormated;
    __execute_DBusSimple_rspFormated_1[26] = __execute_DBusSimple_rspFormated;
    __execute_DBusSimple_rspFormated_1[25] = __execute_DBusSimple_rspFormated;
    __execute_DBusSimple_rspFormated_1[24] = __execute_DBusSimple_rspFormated;
    __execute_DBusSimple_rspFormated_1[23] = __execute_DBusSimple_rspFormated;
    __execute_DBusSimple_rspFormated_1[22] = __execute_DBusSimple_rspFormated;
    __execute_DBusSimple_rspFormated_1[21] = __execute_DBusSimple_rspFormated;
    __execute_DBusSimple_rspFormated_1[20] = __execute_DBusSimple_rspFormated;
    __execute_DBusSimple_rspFormated_1[19] = __execute_DBusSimple_rspFormated;
    __execute_DBusSimple_rspFormated_1[18] = __execute_DBusSimple_rspFormated;
    __execute_DBusSimple_rspFormated_1[17] = __execute_DBusSimple_rspFormated;
    __execute_DBusSimple_rspFormated_1[16] = __execute_DBusSimple_rspFormated;
    __execute_DBusSimple_rspFormated_1[15] = __execute_DBusSimple_rspFormated;
    __execute_DBusSimple_rspFormated_1[14] = __execute_DBusSimple_rspFormated;
    __execute_DBusSimple_rspFormated_1[13] = __execute_DBusSimple_rspFormated;
    __execute_DBusSimple_rspFormated_1[12] = __execute_DBusSimple_rspFormated;
    __execute_DBusSimple_rspFormated_1[11] = __execute_DBusSimple_rspFormated;
    __execute_DBusSimple_rspFormated_1[10] = __execute_DBusSimple_rspFormated;
    __execute_DBusSimple_rspFormated_1[9] = __execute_DBusSimple_rspFormated;
    __execute_DBusSimple_rspFormated_1[8] = __execute_DBusSimple_rspFormated;
    __execute_DBusSimple_rspFormated_1[7 : 0] = execute_DBusSimple_rspShifted[7 : 0];
  end

  assign __execute_DBusSimple_rspFormated_2 = (execute_DBusSimple_rspShifted[15] && (! execute_INSTRUCTION[14]));
  always @(*) begin
    __execute_DBusSimple_rspFormated_3[31] = __execute_DBusSimple_rspFormated_2;
    __execute_DBusSimple_rspFormated_3[30] = __execute_DBusSimple_rspFormated_2;
    __execute_DBusSimple_rspFormated_3[29] = __execute_DBusSimple_rspFormated_2;
    __execute_DBusSimple_rspFormated_3[28] = __execute_DBusSimple_rspFormated_2;
    __execute_DBusSimple_rspFormated_3[27] = __execute_DBusSimple_rspFormated_2;
    __execute_DBusSimple_rspFormated_3[26] = __execute_DBusSimple_rspFormated_2;
    __execute_DBusSimple_rspFormated_3[25] = __execute_DBusSimple_rspFormated_2;
    __execute_DBusSimple_rspFormated_3[24] = __execute_DBusSimple_rspFormated_2;
    __execute_DBusSimple_rspFormated_3[23] = __execute_DBusSimple_rspFormated_2;
    __execute_DBusSimple_rspFormated_3[22] = __execute_DBusSimple_rspFormated_2;
    __execute_DBusSimple_rspFormated_3[21] = __execute_DBusSimple_rspFormated_2;
    __execute_DBusSimple_rspFormated_3[20] = __execute_DBusSimple_rspFormated_2;
    __execute_DBusSimple_rspFormated_3[19] = __execute_DBusSimple_rspFormated_2;
    __execute_DBusSimple_rspFormated_3[18] = __execute_DBusSimple_rspFormated_2;
    __execute_DBusSimple_rspFormated_3[17] = __execute_DBusSimple_rspFormated_2;
    __execute_DBusSimple_rspFormated_3[16] = __execute_DBusSimple_rspFormated_2;
    __execute_DBusSimple_rspFormated_3[15 : 0] = execute_DBusSimple_rspShifted[15 : 0];
  end

  always @(*) begin
    case(switch_Misc_l245_2)
      2'b00 : begin
        execute_DBusSimple_rspFormated = __execute_DBusSimple_rspFormated_1;
      end
      2'b01 : begin
        execute_DBusSimple_rspFormated = __execute_DBusSimple_rspFormated_3;
      end
      default : begin
        execute_DBusSimple_rspFormated = execute_DBusSimple_rspShifted;
      end
    endcase
  end

  assign when_DBusSimple_l384 = (execute_arbitration_isValid && execute_MEMORY_ENABLE);
  assign cdDBus_cmd_ready = dBus_cmd_ready;
  assign cdDBus_rsp_error = dBus_rsp_error;
  assign cdDBus_rsp_data = dBus_rsp_data;
  assign cdDBus_rsp_ready = dBus_rsp_ready;
  assign DBusSimple_memory_active = 1'b0;
  always @(*) begin
    __when_HazardDataBypass_l150 = 1'b0;
    if(when_HazardDataBypass_l137) begin
      __when_HazardDataBypass_l150 = 1'b0;
    end
  end

  always @(*) begin
    __when_HazardDataBypass_l150_1 = 1'b0;
    if(when_HazardDataBypass_l140) begin
      __when_HazardDataBypass_l150_1 = 1'b0;
    end
  end

  assign writeBackWrites_valid = (__execute_RegisterFileReg_valid && execute_arbitration_isFiring);
  assign writeBackWrites_payload_address = __execute_RegisterFileReg_address[11 : 7];
  assign writeBackWrites_payload_data = execute_RegisterFileReg_data;
  assign when_HazardDataBypass_l106 = (writeBackWrites_stage_payload_address == execute_INSTRUCTION[19 : 15]);
  assign when_HazardDataBypass_l109 = (writeBackWrites_stage_payload_address == execute_INSTRUCTION[24 : 20]);
  assign when_HazardDataBypass_l137 = (! execute_RS1_USE);
  assign when_HazardDataBypass_l140 = (! execute_RS2_USE);
  assign when_HazardDataBypass_l150 = (execute_arbitration_isValid && ((__when_HazardDataBypass_l150 || __when_HazardDataBypass_l150_1) || 1'b0));
  assign execute_BarrelShifter_amplitude = execute_SRC2[4 : 0];
  assign execute_BarrelShifter_reversed = (execute_SHIFT_LEFT ? {execute_SRC1[0],{execute_SRC1[1],{execute_SRC1[2],{execute_SRC1[3],{execute_SRC1[4],{execute_SRC1[5],{__execute_BarrelShifter_reversed,{__execute_BarrelShifter_reversed_1,__execute_BarrelShifter_reversed_2}}}}}}}} : execute_SRC1);
  assign execute_BarrelShifter_shifted = __execute_BarrelShifter_shifted[31:0];
  assign when_Shifter_l111 = (execute_arbitration_isValid && execute_DO_SHIFT);
  always @(*) begin
    __execute_RegisterFileReg_data_16[0] = execute_SHIFTED_SRC1[31];
    __execute_RegisterFileReg_data_16[1] = execute_SHIFTED_SRC1[30];
    __execute_RegisterFileReg_data_16[2] = execute_SHIFTED_SRC1[29];
    __execute_RegisterFileReg_data_16[3] = execute_SHIFTED_SRC1[28];
    __execute_RegisterFileReg_data_16[4] = execute_SHIFTED_SRC1[27];
    __execute_RegisterFileReg_data_16[5] = execute_SHIFTED_SRC1[26];
    __execute_RegisterFileReg_data_16[6] = execute_SHIFTED_SRC1[25];
    __execute_RegisterFileReg_data_16[7] = execute_SHIFTED_SRC1[24];
    __execute_RegisterFileReg_data_16[8] = execute_SHIFTED_SRC1[23];
    __execute_RegisterFileReg_data_16[9] = execute_SHIFTED_SRC1[22];
    __execute_RegisterFileReg_data_16[10] = execute_SHIFTED_SRC1[21];
    __execute_RegisterFileReg_data_16[11] = execute_SHIFTED_SRC1[20];
    __execute_RegisterFileReg_data_16[12] = execute_SHIFTED_SRC1[19];
    __execute_RegisterFileReg_data_16[13] = execute_SHIFTED_SRC1[18];
    __execute_RegisterFileReg_data_16[14] = execute_SHIFTED_SRC1[17];
    __execute_RegisterFileReg_data_16[15] = execute_SHIFTED_SRC1[16];
    __execute_RegisterFileReg_data_16[16] = execute_SHIFTED_SRC1[15];
    __execute_RegisterFileReg_data_16[17] = execute_SHIFTED_SRC1[14];
    __execute_RegisterFileReg_data_16[18] = execute_SHIFTED_SRC1[13];
    __execute_RegisterFileReg_data_16[19] = execute_SHIFTED_SRC1[12];
    __execute_RegisterFileReg_data_16[20] = execute_SHIFTED_SRC1[11];
    __execute_RegisterFileReg_data_16[21] = execute_SHIFTED_SRC1[10];
    __execute_RegisterFileReg_data_16[22] = execute_SHIFTED_SRC1[9];
    __execute_RegisterFileReg_data_16[23] = execute_SHIFTED_SRC1[8];
    __execute_RegisterFileReg_data_16[24] = execute_SHIFTED_SRC1[7];
    __execute_RegisterFileReg_data_16[25] = execute_SHIFTED_SRC1[6];
    __execute_RegisterFileReg_data_16[26] = execute_SHIFTED_SRC1[5];
    __execute_RegisterFileReg_data_16[27] = execute_SHIFTED_SRC1[4];
    __execute_RegisterFileReg_data_16[28] = execute_SHIFTED_SRC1[3];
    __execute_RegisterFileReg_data_16[29] = execute_SHIFTED_SRC1[2];
    __execute_RegisterFileReg_data_16[30] = execute_SHIFTED_SRC1[1];
    __execute_RegisterFileReg_data_16[31] = execute_SHIFTED_SRC1[0];
  end

  assign __decode_SHIFT_SIGNED_1 = ((decode_INSTRUCTION & 32'h00004050) == 32'h00004050);
  assign __decode_SHIFT_SIGNED_2 = ((decode_INSTRUCTION & 32'h00000004) == 32'h00000004);
  assign __decode_SHIFT_SIGNED_3 = ((decode_INSTRUCTION & 32'h00000048) == 32'h00000048);
  assign __decode_SHIFT_SIGNED = {(|((decode_INSTRUCTION & 32'h40003054) == 32'h40001010)),{(|((decode_INSTRUCTION & ____decode_SHIFT_SIGNED) == 32'h00001010)),{(|(____decode_SHIFT_SIGNED_1 == ____decode_SHIFT_SIGNED_2)),{(|____decode_SHIFT_SIGNED_3),{(|____decode_SHIFT_SIGNED_4),{____decode_SHIFT_SIGNED_5,{____decode_SHIFT_SIGNED_7,____decode_SHIFT_SIGNED_12}}}}}}};
  assign __decode_SRC1_CTRL_2 = __decode_SHIFT_SIGNED[1 : 0];
  assign __decode_SRC1_CTRL_1 = __decode_SRC1_CTRL_2;
  assign __decode_SRC2_CTRL_2 = __decode_SHIFT_SIGNED[3 : 2];
  assign __decode_SRC2_CTRL_1 = __decode_SRC2_CTRL_2;
  assign __decode_ALU_CTRL_2 = __decode_SHIFT_SIGNED[10 : 9];
  assign __decode_ALU_CTRL_1 = __decode_ALU_CTRL_2;
  assign __decode_ALU_BITWISE_CTRL_2 = __decode_SHIFT_SIGNED[14 : 13];
  assign __decode_ALU_BITWISE_CTRL_1 = __decode_ALU_BITWISE_CTRL_2;
  assign __decode_ENV_CTRL_2 = __decode_SHIFT_SIGNED[20 : 18];
  assign __decode_ENV_CTRL_1 = __decode_ENV_CTRL_2;
  assign __decode_BRANCH_CTRL_2 = __decode_SHIFT_SIGNED[22 : 21];
  assign __decode_BRANCH_CTRL_1 = __decode_BRANCH_CTRL_2;
  assign decodeExceptionPort_valid = ((decode_arbitration_isValid && decode_INSTRUCTION_READY) && (((! decode_LEGAL_INSTRUCTION) || 1'b0) || 1'b0));
  assign decodeExceptionPort_payload_code = 4'b0010;
  assign decodeExceptionPort_payload_mtval = decode_INSTRUCTION;
  assign decodeExceptionPort_payload_pc = decode_PC;
  assign when_Pipeline_l122 = ((! execute_arbitration_isStuck) && (! CsrFile_exceptionPortCtrl_exceptionValids_execute));
  assign when_Pipeline_l122_1 = (! execute_arbitration_isStuck);
  assign when_Pipeline_l122_2 = (! execute_arbitration_isStuck);
  assign when_Pipeline_l122_3 = (! execute_arbitration_isStuck);
  assign __decode_to_execute_SRC1_CTRL_1 = decode_SRC1_CTRL;
  assign __decode_SRC1_CTRL = __decode_SRC1_CTRL_1;
  assign when_Pipeline_l122_4 = (! execute_arbitration_isStuck);
  assign __execute_SRC1_CTRL = decode_to_execute_SRC1_CTRL;
  assign __decode_to_execute_SRC2_CTRL_1 = decode_SRC2_CTRL;
  assign __decode_SRC2_CTRL = __decode_SRC2_CTRL_1;
  assign when_Pipeline_l122_5 = (! execute_arbitration_isStuck);
  assign __execute_SRC2_CTRL = decode_to_execute_SRC2_CTRL;
  assign when_Pipeline_l122_6 = (! execute_arbitration_isStuck);
  assign when_Pipeline_l122_7 = (! execute_arbitration_isStuck);
  assign when_Pipeline_l122_8 = (! execute_arbitration_isStuck);
  assign __decode_to_execute_ALU_CTRL_1 = decode_ALU_CTRL;
  assign __decode_ALU_CTRL = __decode_ALU_CTRL_1;
  assign when_Pipeline_l122_9 = (! execute_arbitration_isStuck);
  assign __execute_ALU_CTRL = decode_to_execute_ALU_CTRL;
  assign when_Pipeline_l122_10 = (! execute_arbitration_isStuck);
  assign when_Pipeline_l122_11 = (! execute_arbitration_isStuck);
  assign __decode_to_execute_ALU_BITWISE_CTRL_1 = decode_ALU_BITWISE_CTRL;
  assign __decode_ALU_BITWISE_CTRL = __decode_ALU_BITWISE_CTRL_1;
  assign when_Pipeline_l122_12 = (! execute_arbitration_isStuck);
  assign __execute_ALU_BITWISE_CTRL = decode_to_execute_ALU_BITWISE_CTRL;
  assign when_Pipeline_l122_13 = (! execute_arbitration_isStuck);
  assign when_Pipeline_l122_14 = (! execute_arbitration_isStuck);
  assign __decode_to_execute_ENV_CTRL_1 = decode_ENV_CTRL;
  assign __decode_ENV_CTRL = __decode_ENV_CTRL_1;
  assign when_Pipeline_l122_15 = (! execute_arbitration_isStuck);
  assign __execute_ENV_CTRL = decode_to_execute_ENV_CTRL;
  assign __decode_to_execute_BRANCH_CTRL_1 = decode_BRANCH_CTRL;
  assign __when_H2E_l82_1 = execute_BRANCH_CTRL;
  assign __decode_BRANCH_CTRL = __decode_BRANCH_CTRL_1;
  assign when_Pipeline_l122_16 = (! execute_arbitration_isStuck);
  assign __execute_BRANCH_CTRL = decode_to_execute_BRANCH_CTRL;
  assign when_Pipeline_l122_17 = (! execute_arbitration_isStuck);
  assign when_Pipeline_l122_18 = (! execute_arbitration_isStuck);
  assign when_Pipeline_l122_19 = (! execute_arbitration_isStuck);
  assign when_Pipeline_l122_20 = (! execute_arbitration_isStuck);
  assign when_Pipeline_l122_21 = (! execute_arbitration_isStuck);
  assign when_Pipeline_l122_22 = (! execute_arbitration_isStuck);
  assign decode_arbitration_isFlushed = (((|execute_arbitration_flushNext) || (|{execute_arbitration_flushIt,decode_arbitration_flushIt})) || 1'b0);
  assign execute_arbitration_isFlushed = ((1'b0 || (|execute_arbitration_flushIt)) || 1'b0);
  assign decode_arbitration_isStuckByOthers = (decode_arbitration_haltByOther || (1'b0 || (execute_arbitration_haltItself || execute_arbitration_haltByOther)));
  assign decode_arbitration_isStuck = (decode_arbitration_haltItself || decode_arbitration_isStuckByOthers);
  assign decode_arbitration_isMoving = ((! decode_arbitration_isStuck) && (! decode_arbitration_removeIt));
  assign decode_arbitration_isFiring = (decode_arbitration_isMoving && decode_arbitration_isValid);
  assign execute_arbitration_isStuckByOthers = (execute_arbitration_haltByOther || 1'b0);
  assign execute_arbitration_isStuck = (execute_arbitration_haltItself || execute_arbitration_isStuckByOthers);
  assign execute_arbitration_isMoving = ((! execute_arbitration_isStuck) && (! execute_arbitration_removeIt));
  assign execute_arbitration_isFiring = (execute_arbitration_isMoving && execute_arbitration_isValid);
  assign when_Pipeline_l173 = ((! execute_arbitration_isStuck) || execute_arbitration_removeIt);
  assign when_Pipeline_l176 = ((! decode_arbitration_isStuck) && (! decode_arbitration_removeIt));
  assign when_CsrFile_l1386 = (CsrFile_writeEnable && (! execute_CsrFile_illegalAccess));
  assign when_CsrFile_l1386_1 = (CsrFile_writeEnable && (! execute_CsrFile_illegalAccess));
  assign when_CsrFile_l1386_2 = (CsrFile_writeEnable && (! execute_CsrFile_illegalAccess));
  assign when_CsrFile_l1386_3 = (CsrFile_writeEnable && (! execute_CsrFile_illegalAccess));
  assign when_CsrFile_l1386_4 = (CsrFile_writeEnable && (! execute_CsrFile_illegalAccess));
  assign when_CsrFile_l1386_5 = (CsrFile_writeEnable && (! execute_CsrFile_illegalAccess));
  assign when_CsrFile_l1386_6 = (CsrFile_writeEnable && (! execute_CsrFile_illegalAccess));
  assign when_CsrFile_l1386_7 = (CsrFile_writeEnable && (! execute_CsrFile_illegalAccess));
  assign when_CsrFile_l1386_8 = (CsrFile_writeEnable && (! execute_CsrFile_illegalAccess));
  assign when_CsrFile_l1386_9 = (CsrFile_writeEnable && (! execute_CsrFile_illegalAccess));
  assign when_CsrFile_l1386_10 = (CsrFile_writeEnable && (! execute_CsrFile_illegalAccess));
  always @(*) begin
    when_CsrFile_l1437 = 1'b0;
    if(when_CsrFile_l1435) begin
      when_CsrFile_l1437 = 1'b1;
    end
    if(when_CsrFile_l1436) begin
      when_CsrFile_l1437 = 1'b1;
    end
  end

  assign when_CsrFile_l1435 = ((execute_CsrFile_csrAddress[11 : 10] == 2'b11) && execute_CSR_WRITE_OPCODE);
  assign when_CsrFile_l1436 = (CsrPlugin_privilege < execute_CsrFile_csrAddress[9 : 8]);
  assign when_CsrFile_l1442 = ((! execute_arbitration_isValid) || (! execute_IS_CSR));
  assign iBusAxiL_arvalid = iBus_cmd_valid;
  assign iBusAxiL_araddr = {iBus_cmd_payload_addr[31 : 2],2'b00};
  assign iBusAxiL_arprot = 3'b110;
  assign iBus_cmd_ready = iBusAxiL_arready;
  assign iBus_rsp_valid = iBusAxiL_rvalid;
  assign iBus_rsp_payload_data = iBusAxiL_rdata;
  assign iBus_rsp_payload_error = (! (iBusAxiL_rresp == 2'b00));
  assign iBusAxiL_rready = 1'b1;
  assign when_Utils_l732 = ((__dBusAxiL_awvalid && __when_Utils_l732) && __dBusAxiL_awvalid_1);
  assign dBusAxiL_b_fire = (dBusAxiL_bvalid && dBusAxiL_bready);
  always @(*) begin
    pendingWrites_incrementIt = 1'b0;
    if(when_Utils_l732) begin
      pendingWrites_incrementIt = 1'b1;
    end
  end

  always @(*) begin
    pendingWrites_decrementIt = 1'b0;
    if(dBusAxiL_b_fire) begin
      pendingWrites_decrementIt = 1'b1;
    end
  end

  assign pendingWrites_mayOverflow = (pendingWrites_value == 3'b111);
  assign pendingWrites_mayUnderflow = (pendingWrites_value == 3'b000);
  assign pendingWrites_willOverflowIfInc = (pendingWrites_mayOverflow && (! pendingWrites_decrementIt));
  assign pendingWrites_willOverflow = (pendingWrites_willOverflowIfInc && pendingWrites_incrementIt);
  assign pendingWrites_willUnderflowIfDec = (pendingWrites_mayUnderflow && (! pendingWrites_incrementIt));
  assign pendingWrites_willUnderflow = (pendingWrites_willUnderflowIfDec && pendingWrites_decrementIt);
  assign when_Utils_l767 = (pendingWrites_incrementIt && (! pendingWrites_decrementIt));
  always @(*) begin
    if(when_Utils_l767) begin
      pendingWrites_finalIncrement = 3'b001;
    end else begin
      if(when_Utils_l769) begin
        pendingWrites_finalIncrement = 3'b111;
      end else begin
        pendingWrites_finalIncrement = 3'b000;
      end
    end
  end

  assign when_Utils_l769 = ((! pendingWrites_incrementIt) && pendingWrites_decrementIt);
  assign pendingWrites_valueNext = (pendingWrites_value + pendingWrites_finalIncrement);
  assign __dBus_cmd_ready = (! (pendingWrites_value == 3'b111));
  assign dBus_cmd_haltWhen_valid = (dBus_cmd_valid && __dBus_cmd_ready);
  assign dBus_cmd_ready = (dBus_cmd_haltWhen_ready && __dBus_cmd_ready);
  assign dBus_cmd_haltWhen_payload_wr = dBus_cmd_payload_wr;
  assign dBus_cmd_haltWhen_payload_address = dBus_cmd_payload_address;
  assign dBus_cmd_haltWhen_payload_data = dBus_cmd_payload_data;
  assign dBus_cmd_haltWhen_payload_size = dBus_cmd_payload_size;
  always @(*) begin
    dBus_cmd_haltWhen_ready = 1'b1;
    if(when_Stream_l1186) begin
      dBus_cmd_haltWhen_ready = 1'b0;
    end
    if(when_Stream_l1186_1) begin
      dBus_cmd_haltWhen_ready = 1'b0;
    end
  end

  assign when_Stream_l1186 = ((! dBus_cmd_haltWhen_fork2_outputs_0_ready) && dBus_cmd_haltWhen_fork2_logic_linkEnable_0);
  assign when_Stream_l1186_1 = ((! dBus_cmd_haltWhen_fork2_outputs_1_ready) && dBus_cmd_haltWhen_fork2_logic_linkEnable_1);
  assign dBus_cmd_haltWhen_fork2_outputs_0_valid = (dBus_cmd_haltWhen_valid && dBus_cmd_haltWhen_fork2_logic_linkEnable_0);
  assign dBus_cmd_haltWhen_fork2_outputs_0_payload_wr = dBus_cmd_haltWhen_payload_wr;
  assign dBus_cmd_haltWhen_fork2_outputs_0_payload_address = dBus_cmd_haltWhen_payload_address;
  assign dBus_cmd_haltWhen_fork2_outputs_0_payload_data = dBus_cmd_haltWhen_payload_data;
  assign dBus_cmd_haltWhen_fork2_outputs_0_payload_size = dBus_cmd_haltWhen_payload_size;
  assign dBus_cmd_haltWhen_fork2_outputs_0_fire = (dBus_cmd_haltWhen_fork2_outputs_0_valid && dBus_cmd_haltWhen_fork2_outputs_0_ready);
  assign dBus_cmd_haltWhen_fork2_outputs_1_valid = (dBus_cmd_haltWhen_valid && dBus_cmd_haltWhen_fork2_logic_linkEnable_1);
  assign dBus_cmd_haltWhen_fork2_outputs_1_payload_wr = dBus_cmd_haltWhen_payload_wr;
  assign dBus_cmd_haltWhen_fork2_outputs_1_payload_address = dBus_cmd_haltWhen_payload_address;
  assign dBus_cmd_haltWhen_fork2_outputs_1_payload_data = dBus_cmd_haltWhen_payload_data;
  assign dBus_cmd_haltWhen_fork2_outputs_1_payload_size = dBus_cmd_haltWhen_payload_size;
  assign dBus_cmd_haltWhen_fork2_outputs_1_fire = (dBus_cmd_haltWhen_fork2_outputs_1_valid && dBus_cmd_haltWhen_fork2_outputs_1_ready);
  assign __dBusAxiL_awvalid = dBus_cmd_haltWhen_fork2_outputs_0_valid;
  assign dBus_cmd_haltWhen_fork2_outputs_0_ready = __when_Utils_l732;
  assign __dBusAxiL_awvalid_1 = dBus_cmd_haltWhen_fork2_outputs_0_payload_wr;
  assign __dBusAxiL_awaddr = dBus_cmd_haltWhen_fork2_outputs_0_payload_address;
  assign dBusAxiL_araddr = __dBusAxiL_awaddr;
  assign dBusAxiL_arprot = 3'b010;
  assign dBusAxiL_arvalid = (__dBusAxiL_awvalid && (! __dBusAxiL_awvalid_1));
  assign dBusAxiL_awaddr = __dBusAxiL_awaddr;
  assign dBusAxiL_awprot = 3'b010;
  assign dBusAxiL_awvalid = (__dBusAxiL_awvalid && __dBusAxiL_awvalid_1);
  assign __when_Utils_l732 = (__dBusAxiL_awvalid_1 ? dBusAxiL_awready : dBusAxiL_arready);
  assign when_Stream_l552 = (! dBus_cmd_haltWhen_fork2_outputs_1_payload_wr);
  always @(*) begin
    dBus_cmd_haltWhen_fork2_outputs_1_throwWhen_valid = dBus_cmd_haltWhen_fork2_outputs_1_valid;
    dBus_cmd_haltWhen_fork2_outputs_1_ready = dBus_cmd_haltWhen_fork2_outputs_1_throwWhen_ready;
    if(when_Stream_l552) begin
      dBus_cmd_haltWhen_fork2_outputs_1_throwWhen_valid = 1'b0;
      dBus_cmd_haltWhen_fork2_outputs_1_ready = 1'b1;
    end
  end

  assign dBus_cmd_haltWhen_fork2_outputs_1_throwWhen_payload_wr = dBus_cmd_haltWhen_fork2_outputs_1_payload_wr;
  assign dBus_cmd_haltWhen_fork2_outputs_1_throwWhen_payload_address = dBus_cmd_haltWhen_fork2_outputs_1_payload_address;
  assign dBus_cmd_haltWhen_fork2_outputs_1_throwWhen_payload_data = dBus_cmd_haltWhen_fork2_outputs_1_payload_data;
  assign dBus_cmd_haltWhen_fork2_outputs_1_throwWhen_payload_size = dBus_cmd_haltWhen_fork2_outputs_1_payload_size;
  assign dBusAxiL_wvalid = dBus_cmd_haltWhen_fork2_outputs_1_throwWhen_valid;
  assign dBus_cmd_haltWhen_fork2_outputs_1_throwWhen_ready = dBusAxiL_wready;
  assign dBusAxiL_wdata = dBus_cmd_haltWhen_fork2_outputs_1_throwWhen_payload_data;
  always @(*) begin
    case(dBus_cmd_haltWhen_fork2_outputs_1_throwWhen_payload_size)
      2'b00 : begin
        __dBusAxiL_wstrb = 4'b0001;
      end
      2'b01 : begin
        __dBusAxiL_wstrb = 4'b0011;
      end
      default : begin
        __dBusAxiL_wstrb = 4'b1111;
      end
    endcase
  end

  assign dBusAxiL_wstrb = (__dBusAxiL_wstrb <<< dBus_cmd_haltWhen_fork2_outputs_1_throwWhen_payload_address[1 : 0]);
  assign dBus_rsp_ready = (dBusAxiL_bvalid || dBusAxiL_rvalid);
  assign dBus_rsp_error = ((dBusAxiL_rvalid && (! (dBusAxiL_rresp == 2'b00))) || (dBusAxiL_bvalid && (! (dBusAxiL_bresp == 2'b00))));
  assign dBus_rsp_data = dBusAxiL_rdata;
  assign dBusAxiL_rready = 1'b1;
  assign dBusAxiL_bready = 1'b1;
  always @(posedge clk or posedge reset) begin
    if(reset) begin
      IBusSimple_fetchPc_pcReg <= reset_vector_i;
      IBusSimple_fetchPc_correctionReg <= 1'b0;
      IBusSimple_fetchPc_booted <= 1'b0;
      IBusSimple_fetchPc_inc <= 1'b0;
      __IBusSimple_iBusRsp_fetchStages_1_input_valid_1 <= 1'b0;
      IBusSimple_injector_nextPcCalc_valids_0 <= 1'b0;
      IBusSimple_injector_nextPcCalc_valids_1 <= 1'b0;
      IBusSimple_injector_decodeRemoved <= 1'b0;
      IBusSimple_cmd_rValidN <= 1'b1;
      IBusSimple_pending_value <= 3'b000;
      IBusSimple_rspJoin_rspBuffer_discardCounter <= 3'b000;
      decode_H2E_idleRegs_0 <= 1'b0;
      decode_H2E_idleRegs_1 <= 1'b0;
      RegisterFileReg_regFile_0 <= 32'h0;
      RegisterFileReg_regFile_1 <= 32'h0;
      RegisterFileReg_regFile_2 <= 32'h0;
      RegisterFileReg_regFile_3 <= 32'h0;
      RegisterFileReg_regFile_4 <= 32'h0;
      RegisterFileReg_regFile_5 <= 32'h0;
      RegisterFileReg_regFile_6 <= 32'h0;
      RegisterFileReg_regFile_7 <= 32'h0;
      RegisterFileReg_regFile_8 <= 32'h0;
      RegisterFileReg_regFile_9 <= 32'h0;
      RegisterFileReg_regFile_10 <= 32'h0;
      RegisterFileReg_regFile_11 <= 32'h0;
      RegisterFileReg_regFile_12 <= 32'h0;
      RegisterFileReg_regFile_13 <= 32'h0;
      RegisterFileReg_regFile_14 <= 32'h0;
      RegisterFileReg_regFile_15 <= 32'h0;
      RegisterFileReg_regFile_16 <= 32'h0;
      RegisterFileReg_regFile_17 <= 32'h0;
      RegisterFileReg_regFile_18 <= 32'h0;
      RegisterFileReg_regFile_19 <= 32'h0;
      RegisterFileReg_regFile_20 <= 32'h0;
      RegisterFileReg_regFile_21 <= 32'h0;
      RegisterFileReg_regFile_22 <= 32'h0;
      RegisterFileReg_regFile_23 <= 32'h0;
      RegisterFileReg_regFile_24 <= 32'h0;
      RegisterFileReg_regFile_25 <= 32'h0;
      RegisterFileReg_regFile_26 <= 32'h0;
      RegisterFileReg_regFile_27 <= 32'h0;
      RegisterFileReg_regFile_28 <= 32'h0;
      RegisterFileReg_regFile_29 <= 32'h0;
      RegisterFileReg_regFile_30 <= 32'h0;
      CsrFile_mtvec_mode <= 2'b00;
      CsrFile_mtvec_submode <= 4'b1000;
      CsrFile_mtvec_base <= 26'h0;
      CsrFile_mepc <= 32'h0;
      CsrFile_mstatus_MIE <= 1'b0;
      CsrFile_mstatus_MPIE <= 1'b0;
      CsrFile_mstatus_MPP <= 2'b11;
      CsrFile_mie_MEIE <= 1'b0;
      CsrFile_mie_MTIE <= 1'b0;
      CsrFile_mie_MSIE <= 1'b0;
      CsrFile_mscratch <= 32'h0;
      CsrFile_mcause_interrupt <= 1'b0;
      CsrFile_mcause_exceptionCode <= 4'b0000;
      CsrFile_mcycle <= 64'h0;
      CsrFile_minstret <= 64'h0;
      CsrFile_exceptionPortCtrl_exceptionValidsRegs_decode <= 1'b0;
      CsrFile_exceptionPortCtrl_exceptionValidsRegs_execute <= 1'b0;
      CsrFile_clint_valid <= 1'b0;
      CsrFile_lastStageWasWfi <= 1'b0;
      CsrFile_pendingIrq_valid <= 1'b0;
      CsrFile_pendingIrq_payload_code <= 4'b0000;
      CsrFile_pendingIrq_payload_targetPrivilege <= 2'b11;
      CsrFile_pipelineFlush_pcValids_0 <= 1'b0;
      CsrFile_hadException <= 1'b0;
      execute_CsrFile_wfiWake <= 1'b0;
      __idle_o <= 1'b0;
      __idle_o_1 <= 1'b0;
      __execute_DBusSimple_memAccessActive <= 1'b0;
      writeBackWrites_stage_valid <= 1'b0;
      execute_arbitration_isValid <= 1'b0;
      pendingWrites_value <= 3'b000;
      dBus_cmd_haltWhen_fork2_logic_linkEnable_0 <= 1'b1;
      dBus_cmd_haltWhen_fork2_logic_linkEnable_1 <= 1'b1;
      IBusSimple_cmd_rData_addr <= 32'h0;
      cdDBus_cmd_payload_address_regNextWhen <= 32'h0;
      __h2e_data_sdata_o <= 32'h0;
      cdDBus_cmd_payload_size_regNextWhen <= 2'b00;
      cdDBus_cmd_payload_wr_regNextWhen <= 1'b0;
      execute_INSTRUCTION_regNext <= 32'h0;
      CsrFile_readEnable_regNext <= 1'b0;
      CsrFile_writeEnable_regNext <= 1'b0;
      CsrFile_mip_MEIP <= 1'b0;
      CsrFile_mip_MTIP <= 1'b0;
      CsrFile_mip_MSIP <= 1'b0;
      CsrFile_mtval <= 32'h0;
      CsrFile_mtime <= 64'h0;
      CsrFile_exceptionPortCtrl_exceptionContext_code <= 4'b0000;
      CsrFile_exceptionPortCtrl_exceptionContext_mtval <= 32'h0;
      CsrFile_exceptionPortCtrl_exceptionContext_pc <= 32'h0;
      CsrFile_clint_code <= 4'b0000;
      CsrFile_clint_targetPrivilege <= 2'b00;
      CsrFile_pendingIrq_payload_targetAddr <= 32'h0;
      CsrFile_irq_valid_delayed <= 1'b0;
      writeBackWrites_stage_payload_address <= 5'h0;
      writeBackWrites_stage_payload_data <= 32'h0;
      decode_to_execute_PC <= 32'h0;
      decode_to_execute_INSTRUCTION <= 32'h0;
      decode_to_execute_CSR_WRITE_OPCODE <= 1'b0;
      decode_to_execute_CSR_READ_OPCODE <= 1'b0;
      decode_to_execute_SRC1_CTRL <= Src1Ctrl_RS;
      decode_to_execute_SRC2_CTRL <= Src2Ctrl_RS;
      decode_to_execute_REGFILE_WRITE_VALID <= 1'b0;
      decode_to_execute_RS1_USE <= 1'b0;
      decode_to_execute_RS2_USE <= 1'b0;
      decode_to_execute_ALU_CTRL <= AluCtrl_ADD_SUB;
      decode_to_execute_SRC_USE_SUB_LESS <= 1'b0;
      decode_to_execute_SRC_LESS_UNSIGNED <= 1'b0;
      decode_to_execute_ALU_BITWISE_CTRL <= AluBitwiseCtrl_XOR_1;
      decode_to_execute_SRC_ADD_ZERO <= 1'b0;
      decode_to_execute_IS_CSR <= 1'b0;
      decode_to_execute_ENV_CTRL <= EnvCtrl_NONE;
      decode_to_execute_BRANCH_CTRL <= BranchCtrlEnum_INC;
      decode_to_execute_IS_FENCEI <= 1'b0;
      decode_to_execute_MEMORY_ENABLE <= 1'b0;
      decode_to_execute_MEMORY_STORE <= 1'b0;
      decode_to_execute_DO_SHIFT <= 1'b0;
      decode_to_execute_SHIFT_LEFT <= 1'b0;
      decode_to_execute_SHIFT_SIGNED <= 1'b0;
    end else begin
      if(IBusSimple_fetchPc_correction) begin
        IBusSimple_fetchPc_correctionReg <= 1'b1;
      end
      if(IBusSimple_fetchPc_output_fire) begin
        IBusSimple_fetchPc_correctionReg <= 1'b0;
      end
      IBusSimple_fetchPc_booted <= 1'b1;
      if(when_InstructionFetch_l139) begin
        IBusSimple_fetchPc_inc <= 1'b0;
      end
      if(IBusSimple_fetchPc_output_fire) begin
        IBusSimple_fetchPc_inc <= 1'b1;
      end
      if(when_InstructionFetch_l139_1) begin
        IBusSimple_fetchPc_inc <= 1'b0;
      end
      if(when_InstructionFetch_l186) begin
        IBusSimple_fetchPc_pcReg <= IBusSimple_fetchPc_pc;
      end
      if(IBusSimple_iBusRsp_flush) begin
        __IBusSimple_iBusRsp_fetchStages_1_input_valid_1 <= 1'b0;
      end
      if(IBusSimple_iBusRsp_fetchStages_0_output_toEvent_ready) begin
        __IBusSimple_iBusRsp_fetchStages_1_input_valid_1 <= (IBusSimple_iBusRsp_fetchStages_0_output_toEvent_valid && (! 1'b0));
      end
      if(IBusSimple_fetchPc_flushed) begin
        IBusSimple_injector_nextPcCalc_valids_0 <= 1'b0;
      end
      if(when_InstructionFetch_l379) begin
        IBusSimple_injector_nextPcCalc_valids_0 <= 1'b1;
      end
      if(IBusSimple_fetchPc_flushed) begin
        IBusSimple_injector_nextPcCalc_valids_1 <= 1'b0;
      end
      if(when_InstructionFetch_l379_1) begin
        IBusSimple_injector_nextPcCalc_valids_1 <= IBusSimple_injector_nextPcCalc_valids_0;
      end
      if(IBusSimple_fetchPc_flushed) begin
        IBusSimple_injector_nextPcCalc_valids_1 <= 1'b0;
      end
      if(decode_arbitration_removeIt) begin
        IBusSimple_injector_decodeRemoved <= 1'b1;
      end
      if(IBusSimple_fetchPc_correction) begin
        IBusSimple_injector_decodeRemoved <= 1'b0;
      end
      if(IBusSimple_cmd_valid) begin
        IBusSimple_cmd_rValidN <= 1'b0;
      end
      if(IBusSimple_cmd_s2mPipe_ready) begin
        IBusSimple_cmd_rValidN <= 1'b1;
      end
      if(IBusSimple_cmd_ready) begin
        IBusSimple_cmd_rData_addr <= IBusSimple_cmd_payload_addr;
      end
      IBusSimple_pending_value <= IBusSimple_pending_next;
      IBusSimple_rspJoin_rspBuffer_discardCounter <= (IBusSimple_rspJoin_rspBuffer_discardCounter - __IBusSimple_rspJoin_rspBuffer_discardCounter);
      if(IBusSimple_iBusRsp_flush) begin
        IBusSimple_rspJoin_rspBuffer_discardCounter <= (IBusSimple_pending_value - __IBusSimple_rspJoin_rspBuffer_discardCounter_2);
      end
      if(cdDBus_cmd_fire) begin
        cdDBus_cmd_payload_address_regNextWhen <= cdDBus_cmd_payload_address;
      end
      if(cdDBus_cmd_fire) begin
        __h2e_data_sdata_o <= cdDBus_cmd_payload_data;
      end
      if(cdDBus_cmd_fire) begin
        cdDBus_cmd_payload_size_regNextWhen <= cdDBus_cmd_payload_size;
      end
      if(cdDBus_cmd_fire) begin
        cdDBus_cmd_payload_wr_regNextWhen <= cdDBus_cmd_payload_wr;
      end
      execute_INSTRUCTION_regNext <= execute_INSTRUCTION;
      CsrFile_readEnable_regNext <= CsrFile_readEnable;
      CsrFile_writeEnable_regNext <= CsrFile_writeEnable;
      decode_H2E_idleRegs_0 <= decode_H2E_stall;
      decode_H2E_idleRegs_1 <= decode_H2E_idleRegs_0;
      if(when_RegisterFile_l255) begin
        RegisterFileReg_regFile_0 <= execute_RegisterFileReg_data;
      end
      if(when_RegisterFile_l255_1) begin
        RegisterFileReg_regFile_1 <= execute_RegisterFileReg_data;
      end
      if(when_RegisterFile_l255_2) begin
        RegisterFileReg_regFile_2 <= execute_RegisterFileReg_data;
      end
      if(when_RegisterFile_l255_3) begin
        RegisterFileReg_regFile_3 <= execute_RegisterFileReg_data;
      end
      if(when_RegisterFile_l255_4) begin
        RegisterFileReg_regFile_4 <= execute_RegisterFileReg_data;
      end
      if(when_RegisterFile_l255_5) begin
        RegisterFileReg_regFile_5 <= execute_RegisterFileReg_data;
      end
      if(when_RegisterFile_l255_6) begin
        RegisterFileReg_regFile_6 <= execute_RegisterFileReg_data;
      end
      if(when_RegisterFile_l255_7) begin
        RegisterFileReg_regFile_7 <= execute_RegisterFileReg_data;
      end
      if(when_RegisterFile_l255_8) begin
        RegisterFileReg_regFile_8 <= execute_RegisterFileReg_data;
      end
      if(when_RegisterFile_l255_9) begin
        RegisterFileReg_regFile_9 <= execute_RegisterFileReg_data;
      end
      if(when_RegisterFile_l255_10) begin
        RegisterFileReg_regFile_10 <= execute_RegisterFileReg_data;
      end
      if(when_RegisterFile_l255_11) begin
        RegisterFileReg_regFile_11 <= execute_RegisterFileReg_data;
      end
      if(when_RegisterFile_l255_12) begin
        RegisterFileReg_regFile_12 <= execute_RegisterFileReg_data;
      end
      if(when_RegisterFile_l255_13) begin
        RegisterFileReg_regFile_13 <= execute_RegisterFileReg_data;
      end
      if(when_RegisterFile_l255_14) begin
        RegisterFileReg_regFile_14 <= execute_RegisterFileReg_data;
      end
      if(when_RegisterFile_l255_15) begin
        RegisterFileReg_regFile_15 <= execute_RegisterFileReg_data;
      end
      if(when_RegisterFile_l255_16) begin
        RegisterFileReg_regFile_16 <= execute_RegisterFileReg_data;
      end
      if(when_RegisterFile_l255_17) begin
        RegisterFileReg_regFile_17 <= execute_RegisterFileReg_data;
      end
      if(when_RegisterFile_l255_18) begin
        RegisterFileReg_regFile_18 <= execute_RegisterFileReg_data;
      end
      if(when_RegisterFile_l255_19) begin
        RegisterFileReg_regFile_19 <= execute_RegisterFileReg_data;
      end
      if(when_RegisterFile_l255_20) begin
        RegisterFileReg_regFile_20 <= execute_RegisterFileReg_data;
      end
      if(when_RegisterFile_l255_21) begin
        RegisterFileReg_regFile_21 <= execute_RegisterFileReg_data;
      end
      if(when_RegisterFile_l255_22) begin
        RegisterFileReg_regFile_22 <= execute_RegisterFileReg_data;
      end
      if(when_RegisterFile_l255_23) begin
        RegisterFileReg_regFile_23 <= execute_RegisterFileReg_data;
      end
      if(when_RegisterFile_l255_24) begin
        RegisterFileReg_regFile_24 <= execute_RegisterFileReg_data;
      end
      if(when_RegisterFile_l255_25) begin
        RegisterFileReg_regFile_25 <= execute_RegisterFileReg_data;
      end
      if(when_RegisterFile_l255_26) begin
        RegisterFileReg_regFile_26 <= execute_RegisterFileReg_data;
      end
      if(when_RegisterFile_l255_27) begin
        RegisterFileReg_regFile_27 <= execute_RegisterFileReg_data;
      end
      if(when_RegisterFile_l255_28) begin
        RegisterFileReg_regFile_28 <= execute_RegisterFileReg_data;
      end
      if(when_RegisterFile_l255_29) begin
        RegisterFileReg_regFile_29 <= execute_RegisterFileReg_data;
      end
      if(when_RegisterFile_l255_30) begin
        RegisterFileReg_regFile_30 <= execute_RegisterFileReg_data;
      end
      CsrFile_mip_MEIP <= ext_irq_i;
      CsrFile_mip_MTIP <= tim_irq_i;
      CsrFile_mip_MSIP <= sw_irq_i;
      CsrFile_mtime <= mtime_i;
      CsrFile_mtvec_mode[1] <= 1'b0;
      CsrFile_mcycle <= (CsrFile_mcycle + 64'h0000000000000001);
      if(when_CsrFile_l869) begin
        CsrFile_minstret <= (CsrFile_minstret + 64'h0000000000000001);
      end
      if(__when) begin
        CsrFile_exceptionPortCtrl_exceptionContext_code <= (__CsrFile_exceptionPortCtrl_exceptionContext_code_1 ? IBusSimple_instrFetchExceptionPort_payload_code : decodeExceptionPort_payload_code);
        CsrFile_exceptionPortCtrl_exceptionContext_mtval <= (__CsrFile_exceptionPortCtrl_exceptionContext_code_1 ? IBusSimple_instrFetchExceptionPort_payload_mtval : decodeExceptionPort_payload_mtval);
        CsrFile_exceptionPortCtrl_exceptionContext_pc <= (__CsrFile_exceptionPortCtrl_exceptionContext_code_1 ? IBusSimple_instrFetchExceptionPort_payload_pc : decodeExceptionPort_payload_pc);
      end
      if(__when_1) begin
        CsrFile_exceptionPortCtrl_exceptionContext_code <= __CsrFile_exceptionPortCtrl_exceptionContext_code_7;
        CsrFile_exceptionPortCtrl_exceptionContext_mtval <= __CsrFile_exceptionPortCtrl_exceptionContext_mtval;
        CsrFile_exceptionPortCtrl_exceptionContext_pc <= __CsrFile_exceptionPortCtrl_exceptionContext_pc;
      end
      if(when_CsrFile_l951) begin
        CsrFile_exceptionPortCtrl_exceptionValidsRegs_decode <= 1'b0;
      end else begin
        CsrFile_exceptionPortCtrl_exceptionValidsRegs_decode <= CsrFile_exceptionPortCtrl_exceptionValids_decode;
      end
      if(when_CsrFile_l951_1) begin
        CsrFile_exceptionPortCtrl_exceptionValidsRegs_execute <= (CsrFile_exceptionPortCtrl_exceptionValids_decode && (! decode_arbitration_isStuck));
      end else begin
        CsrFile_exceptionPortCtrl_exceptionValidsRegs_execute <= 1'b0;
      end
      CsrFile_clint_valid <= 1'b0;
      if(when_CsrFile_l987) begin
        if(when_CsrFile_l993) begin
          CsrFile_clint_valid <= 1'b1;
          CsrFile_clint_code <= 4'b0011;
          CsrFile_clint_targetPrivilege <= 2'b11;
        end
        if(when_CsrFile_l993_1) begin
          CsrFile_clint_valid <= 1'b1;
          CsrFile_clint_code <= 4'b0111;
          CsrFile_clint_targetPrivilege <= 2'b11;
        end
        if(when_CsrFile_l993_2) begin
          CsrFile_clint_valid <= 1'b1;
          CsrFile_clint_code <= 4'b1011;
          CsrFile_clint_targetPrivilege <= 2'b11;
        end
      end
      CsrFile_lastStageWasWfi <= (execute_arbitration_isFiring && (execute_ENV_CTRL == EnvCtrl_WFI));
      CsrFile_irq_valid_delayed <= CsrFile_irq_valid;
      if(when_CsrFile_l1052) begin
        CsrFile_irq_valid_delayed <= 1'b0;
      end
      if(CsrFile_pipelineFlush_active) begin
        CsrFile_pendingIrq_payload_code <= CsrFile_irq_payload_code;
        CsrFile_pendingIrq_payload_targetPrivilege <= CsrFile_irq_payload_targetPrivilege;
        CsrFile_pendingIrq_payload_targetAddr <= CsrFile_irq_payload_targetAddr;
        CsrFile_pendingIrq_valid <= 1'b1;
        if(when_CsrFile_l1063) begin
          CsrFile_pipelineFlush_pcValids_0 <= 1'b1;
        end
      end
      if(when_CsrFile_l1068) begin
        CsrFile_pipelineFlush_pcValids_0 <= 1'b0;
      end
      if(when_CsrFile_l1074) begin
        CsrFile_pendingIrq_valid <= 1'b0;
      end
      CsrFile_hadException <= CsrFile_exception;
      if(when_CsrFile_l1126) begin
        if(when_CsrFile_l1137) begin
          case(CsrFile_targetPrivilege)
            2'b11 : begin
              CsrFile_mstatus_MIE <= 1'b0;
              CsrFile_mstatus_MPIE <= CsrFile_mstatus_MIE;
              CsrFile_mstatus_MPP <= CsrPlugin_privilege;
              CsrFile_mcause_interrupt <= (! CsrFile_hadException);
              CsrFile_mcause_exceptionCode <= CsrFile_trapCause;
              CsrFile_mepc <= ((CsrFile_hadException && (CsrFile_trapCause == 4'b0010)) ? CsrFile_exceptionPortCtrl_exceptionContext_pc : execute_PC);
              if(CsrFile_hadException) begin
                CsrFile_mtval <= CsrFile_exceptionPortCtrl_exceptionContext_mtval;
              end
            end
            default : begin
            end
          endcase
        end
      end
      if(when_CsrFile_l1196) begin
        case(switch_CsrFile_l1200)
          2'b11 : begin
            CsrFile_mstatus_MIE <= CsrFile_mstatus_MPIE;
            CsrFile_mstatus_MPIE <= 1'b1;
            CsrFile_mstatus_MPP <= 2'b11;
          end
          default : begin
          end
        endcase
      end
      execute_CsrFile_wfiWake <= ((|{__when_CsrFile_l993_2,{__when_CsrFile_l993_1,__when_CsrFile_l993}}) || CsrFile_thirdPartyWake);
      __idle_o <= (wfi_o && (! IBusSimple_incomingInstruction));
      __idle_o_1 <= __idle_o;
      if(sharedDBus_cmd_fire) begin
        __execute_DBusSimple_memAccessActive <= 1'b1;
      end
      if(when_DBusSimple_l242) begin
        __execute_DBusSimple_memAccessActive <= 1'b0;
      end
      writeBackWrites_stage_valid <= writeBackWrites_valid;
      writeBackWrites_stage_payload_address <= writeBackWrites_payload_address;
      writeBackWrites_stage_payload_data <= writeBackWrites_payload_data;
      if(when_Pipeline_l122) begin
        decode_to_execute_PC <= decode_PC;
      end
      if(when_Pipeline_l122_1) begin
        decode_to_execute_INSTRUCTION <= __decode_to_execute_INSTRUCTION;
      end
      if(when_Pipeline_l122_2) begin
        decode_to_execute_CSR_WRITE_OPCODE <= decode_CSR_WRITE_OPCODE;
      end
      if(when_Pipeline_l122_3) begin
        decode_to_execute_CSR_READ_OPCODE <= decode_CSR_READ_OPCODE;
      end
      if(when_Pipeline_l122_4) begin
        decode_to_execute_SRC1_CTRL <= __decode_to_execute_SRC1_CTRL;
      end
      if(when_Pipeline_l122_5) begin
        decode_to_execute_SRC2_CTRL <= __decode_to_execute_SRC2_CTRL;
      end
      if(when_Pipeline_l122_6) begin
        decode_to_execute_REGFILE_WRITE_VALID <= decode_REGFILE_WRITE_VALID;
      end
      if(when_Pipeline_l122_7) begin
        decode_to_execute_RS1_USE <= decode_RS1_USE;
      end
      if(when_Pipeline_l122_8) begin
        decode_to_execute_RS2_USE <= decode_RS2_USE;
      end
      if(when_Pipeline_l122_9) begin
        decode_to_execute_ALU_CTRL <= __decode_to_execute_ALU_CTRL;
      end
      if(when_Pipeline_l122_10) begin
        decode_to_execute_SRC_USE_SUB_LESS <= decode_SRC_USE_SUB_LESS;
      end
      if(when_Pipeline_l122_11) begin
        decode_to_execute_SRC_LESS_UNSIGNED <= decode_SRC_LESS_UNSIGNED;
      end
      if(when_Pipeline_l122_12) begin
        decode_to_execute_ALU_BITWISE_CTRL <= __decode_to_execute_ALU_BITWISE_CTRL;
      end
      if(when_Pipeline_l122_13) begin
        decode_to_execute_SRC_ADD_ZERO <= decode_SRC_ADD_ZERO;
      end
      if(when_Pipeline_l122_14) begin
        decode_to_execute_IS_CSR <= decode_IS_CSR;
      end
      if(when_Pipeline_l122_15) begin
        decode_to_execute_ENV_CTRL <= __decode_to_execute_ENV_CTRL;
      end
      if(when_Pipeline_l122_16) begin
        decode_to_execute_BRANCH_CTRL <= __decode_to_execute_BRANCH_CTRL;
      end
      if(when_Pipeline_l122_17) begin
        decode_to_execute_IS_FENCEI <= decode_IS_FENCEI;
      end
      if(when_Pipeline_l122_18) begin
        decode_to_execute_MEMORY_ENABLE <= decode_MEMORY_ENABLE;
      end
      if(when_Pipeline_l122_19) begin
        decode_to_execute_MEMORY_STORE <= decode_MEMORY_STORE;
      end
      if(when_Pipeline_l122_20) begin
        decode_to_execute_DO_SHIFT <= decode_DO_SHIFT;
      end
      if(when_Pipeline_l122_21) begin
        decode_to_execute_SHIFT_LEFT <= decode_SHIFT_LEFT;
      end
      if(when_Pipeline_l122_22) begin
        decode_to_execute_SHIFT_SIGNED <= decode_SHIFT_SIGNED;
      end
      if(when_Pipeline_l173) begin
        execute_arbitration_isValid <= 1'b0;
      end
      if(when_Pipeline_l176) begin
        execute_arbitration_isValid <= decode_arbitration_isValid;
      end
      case(execute_CsrFile_csrAddress)
        12'h300 : begin
          if(when_CsrFile_l1386) begin
            CsrFile_mstatus_MPIE <= __CsrFile_mtvec_mode[7];
            CsrFile_mstatus_MIE <= __CsrFile_mtvec_mode[3];
          end
        end
        12'h304 : begin
          if(when_CsrFile_l1386_1) begin
            CsrFile_mie_MEIE <= __CsrFile_mtvec_mode[11];
            CsrFile_mie_MTIE <= __CsrFile_mtvec_mode[7];
            CsrFile_mie_MSIE <= __CsrFile_mtvec_mode[3];
          end
        end
        12'h305 : begin
          if(when_CsrFile_l1386_2) begin
            CsrFile_mtvec_base <= __CsrFile_mtvec_mode[31 : 6];
            CsrFile_mtvec_submode <= __CsrFile_mtvec_mode[5 : 2];
            CsrFile_mtvec_mode[0] <= __CsrFile_mtvec_mode[0];
          end
        end
        12'h341 : begin
          if(when_CsrFile_l1386_3) begin
            CsrFile_mepc[31 : 2] <= __CsrFile_mtvec_mode[31 : 2];
          end
        end
        12'h340 : begin
          if(when_CsrFile_l1386_4) begin
            CsrFile_mscratch <= __CsrFile_mtvec_mode[31 : 0];
          end
        end
        12'h342 : begin
          if(when_CsrFile_l1386_5) begin
            CsrFile_mcause_interrupt <= __CsrFile_mtvec_mode[31];
            CsrFile_mcause_exceptionCode <= __CsrFile_mtvec_mode[3 : 0];
          end
        end
        12'h343 : begin
          if(when_CsrFile_l1386_6) begin
            CsrFile_mtval <= __CsrFile_mtvec_mode[31 : 0];
          end
        end
        12'hb00 : begin
          if(when_CsrFile_l1386_7) begin
            CsrFile_mcycle[31 : 0] <= __CsrFile_mtvec_mode[31 : 0];
          end
        end
        12'hb80 : begin
          if(when_CsrFile_l1386_8) begin
            CsrFile_mcycle[63 : 32] <= __CsrFile_mtvec_mode[31 : 0];
          end
        end
        12'hb02 : begin
          if(when_CsrFile_l1386_9) begin
            CsrFile_minstret[31 : 0] <= __CsrFile_mtvec_mode[31 : 0];
          end
        end
        12'hb82 : begin
          if(when_CsrFile_l1386_10) begin
            CsrFile_minstret[63 : 32] <= __CsrFile_mtvec_mode[31 : 0];
          end
        end
        default : begin
        end
      endcase
      pendingWrites_value <= pendingWrites_valueNext;
      if(dBus_cmd_haltWhen_fork2_outputs_0_fire) begin
        dBus_cmd_haltWhen_fork2_logic_linkEnable_0 <= 1'b0;
      end
      if(dBus_cmd_haltWhen_fork2_outputs_1_fire) begin
        dBus_cmd_haltWhen_fork2_logic_linkEnable_1 <= 1'b0;
      end
      if(dBus_cmd_haltWhen_ready) begin
        dBus_cmd_haltWhen_fork2_logic_linkEnable_0 <= 1'b1;
        dBus_cmd_haltWhen_fork2_logic_linkEnable_1 <= 1'b1;
      end
    end
  end


endmodule

module StreamFifoLowLatency (
  input  wire          io_push_valid,
  output wire          io_push_ready,
  input  wire          io_push_payload_error,
  input  wire [31:0]   io_push_payload_data,
  output wire          io_pop_valid,
  input  wire          io_pop_ready,
  output wire          io_pop_payload_error,
  output wire [31:0]   io_pop_payload_data,
  input  wire          io_flush,
  output wire [0:0]    io_occupancy,
  output wire [0:0]    io_availability,
  input  wire          clk,
  input  wire          reset
);

  wire                fifo_io_push_ready;
  wire                fifo_io_pop_valid;
  wire                fifo_io_pop_payload_error;
  wire       [31:0]   fifo_io_pop_payload_data;
  wire       [0:0]    fifo_io_occupancy;
  wire       [0:0]    fifo_io_availability;

  StreamFifo fifo (
    .io_push_valid         (io_push_valid                 ), //i
    .io_push_ready         (fifo_io_push_ready            ), //o
    .io_push_payload_error (io_push_payload_error         ), //i
    .io_push_payload_data  (io_push_payload_data[31:0]    ), //i
    .io_pop_valid          (fifo_io_pop_valid             ), //o
    .io_pop_ready          (io_pop_ready                  ), //i
    .io_pop_payload_error  (fifo_io_pop_payload_error     ), //o
    .io_pop_payload_data   (fifo_io_pop_payload_data[31:0]), //o
    .io_flush              (io_flush                      ), //i
    .io_occupancy          (fifo_io_occupancy             ), //o
    .io_availability       (fifo_io_availability          ), //o
    .clk                   (clk                           ), //i
    .reset                 (reset                         )  //i
  );
  assign io_push_ready = fifo_io_push_ready;
  assign io_pop_valid = fifo_io_pop_valid;
  assign io_pop_payload_error = fifo_io_pop_payload_error;
  assign io_pop_payload_data = fifo_io_pop_payload_data;
  assign io_occupancy = fifo_io_occupancy;
  assign io_availability = fifo_io_availability;

endmodule

module StreamFifo (
  input  wire          io_push_valid,
  output reg           io_push_ready,
  input  wire          io_push_payload_error,
  input  wire [31:0]   io_push_payload_data,
  output reg           io_pop_valid,
  input  wire          io_pop_ready,
  output reg           io_pop_payload_error,
  output reg  [31:0]   io_pop_payload_data,
  input  wire          io_flush,
  output wire [0:0]    io_occupancy,
  output wire [0:0]    io_availability,
  input  wire          clk,
  input  wire          reset
);

  reg                 oneStage_doFlush;
  wire                oneStage_buffer_valid;
  wire                oneStage_buffer_ready;
  wire                oneStage_buffer_payload_error;
  wire       [31:0]   oneStage_buffer_payload_data;
  reg                 io_push_rValid;
  reg                 io_push_rData_error;
  reg        [31:0]   io_push_rData_data;
  wire                when_Stream_l448;
  wire                when_Stream_l1360;

  always @(*) begin
    oneStage_doFlush = io_flush;
    io_pop_valid = oneStage_buffer_valid;
    io_pop_payload_error = oneStage_buffer_payload_error;
    io_pop_payload_data = oneStage_buffer_payload_data;
    if(when_Stream_l1360) begin
      io_pop_valid = io_push_valid;
      io_pop_payload_error = io_push_payload_error;
      io_pop_payload_data = io_push_payload_data;
      if(io_pop_ready) begin
        oneStage_doFlush = 1'b1;
      end
    end
  end

  always @(*) begin
    io_push_ready = oneStage_buffer_ready;
    if(when_Stream_l448) begin
      io_push_ready = 1'b1;
    end
  end

  assign when_Stream_l448 = (! oneStage_buffer_valid);
  assign oneStage_buffer_valid = io_push_rValid;
  assign oneStage_buffer_payload_error = io_push_rData_error;
  assign oneStage_buffer_payload_data = io_push_rData_data;
  assign oneStage_buffer_ready = io_pop_ready;
  assign io_occupancy = oneStage_buffer_valid;
  assign io_availability = (! oneStage_buffer_valid);
  assign when_Stream_l1360 = (! oneStage_buffer_valid);
  always @(posedge clk or posedge reset) begin
    if(reset) begin
      io_push_rValid <= 1'b0;
      io_push_rData_error <= 1'b0;
      io_push_rData_data <= 32'h0;
    end else begin
      if(io_push_ready) begin
        io_push_rValid <= io_push_valid;
      end
      if(io_push_ready) begin
        io_push_rData_error <= io_push_payload_error;
        io_push_rData_data <= io_push_payload_data;
      end
      if(oneStage_doFlush) begin
        io_push_rValid <= 1'b0;
      end
    end
  end


endmodule
