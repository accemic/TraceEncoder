// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// ============================================================================
// Auto-generated Wishbone Register Access Package
// Contains: Register addresses, bitfield positions, and memory layout constants
// DO NOT EDIT MANUALLY - Changes will be overwritten!
// ============================================================================

package ct_cs_cpuif_wb_pkg;

    // Register Base Addresses
    // ========================================================================
    localparam logic [31:0] ADDR_TE_TRTECONTROL                 = 32'h00000000;
    localparam logic [31:0] ADDR_TE_TRTEIMPL                    = 32'h00000004;
    localparam logic [31:0] ADDR_TE_TRTEINSTFEATURES            = 32'h00000008;
    localparam logic [31:0] ADDR_TE_TRTEINSTFILTERS             = 32'h0000000C;
    localparam logic [31:0] ADDR_TE_TRTEDATACONTROL             = 32'h00000010;
    localparam logic [31:0] ADDR_TE_TRTEDATAFILTERS             = 32'h0000001C;
    localparam logic [31:0] ADDR_TE_TRTSCONTROL                 = 32'h00000040;
    localparam logic [31:0] ADDR_TE_TRTSCOUNTERLOW              = 32'h00000048;
    localparam logic [31:0] ADDR_TE_TRTSCOUNTERHIGH             = 32'h0000004C;
    localparam logic [31:0] ADDR_TE_TRTEFILTER_CONTROL          = 32'h00000400;  // 16 instances, stride 0x20
    localparam logic [31:0] ADDR_TE_TRTEFILTER_MATCH            = 32'h00000404;  // 16 instances, stride 0x20
    localparam logic [31:0] ADDR_TE_TRTEFILTER_MATCHCHOICEECAUSELOW = 32'h00000408;  // 16 instances, stride 0x20
    localparam logic [31:0] ADDR_TE_TRTEFILTER_MATCHCHOICEECAUSEHIGH = 32'h0000040C;  // 16 instances, stride 0x20
    localparam logic [31:0] ADDR_TE_TRTEFILTER_MATCHVALUEIMPDEF = 32'h00000410;  // 16 instances, stride 0x20
    localparam logic [31:0] ADDR_TE_TRTEFILTER_MATCHMASKIMPDEF  = 32'h00000414;  // 16 instances, stride 0x20
    localparam logic [31:0] ADDR_TE_TRTEFILTER_MATCHCHOICEDATA  = 32'h00000418;  // 16 instances, stride 0x20
    localparam logic [31:0] ADDR_TE_TRTECOMP_CONTROL            = 32'h00000600;  // 8 instances, stride 0x20
    localparam logic [31:0] ADDR_TE_TRTECOMP_PMATCHLOW          = 32'h00000610;  // 8 instances, stride 0x20
    localparam logic [31:0] ADDR_TE_TRTECOMP_PMATCHHIGH         = 32'h00000614;  // 8 instances, stride 0x20
    localparam logic [31:0] ADDR_TE_TRTECOMP_SMATCHLOW          = 32'h00000618;  // 8 instances, stride 0x20
    localparam logic [31:0] ADDR_TE_TRTECOMP_SMATCHHIGH         = 32'h0000061C;  // 8 instances, stride 0x20
    localparam logic [31:0] ADDR_TE_TRTECSRCONTROL              = 32'h00000E00;
    localparam logic [31:0] ADDR_TE_TRTETIPFIFOSTATUS           = 32'h00000E04;
    localparam logic [31:0] ADDR_ATB_TRATBBRIDGECONTROL         = 32'h00001000;
    localparam logic [31:0] ADDR_ATB_TRATBBRIDGEIMPL            = 32'h00001004;
    localparam logic [31:0] ADDR_PC_TRPCCONTROL                 = 32'h00003000;
    localparam logic [31:0] ADDR_PC_TRPCIMPL                    = 32'h00003004;
    localparam logic [31:0] ADDR_PC_TRTECONSTANTS               = 32'h00003008;
    localparam logic [31:0] ADDR_PC_TRPERFCNTCONTROL            = 32'h00003010;
    localparam logic [31:0] ADDR_PC_TRTEPERFCNTIFETCHRANGE_LOW  = 32'h00003100;  // 3 instances, stride 0x8
    localparam logic [31:0] ADDR_PC_TRTEPERFCNTIFETCHRANGE_HIGH = 32'h00003104;  // 3 instances, stride 0x8
    localparam logic [31:0] ADDR_PC_TRTEPERFCNTDATARDTHRANGE_LOW = 32'h00003200;  // 3 instances, stride 0x8
    localparam logic [31:0] ADDR_PC_TRTEPERFCNTDATARDTHRANGE_HIGH = 32'h00003204;  // 3 instances, stride 0x8
    localparam logic [31:0] ADDR_PC_TRTEPERFCNTDATARDRANGE_LOW  = 32'h00003300;  // 7 instances, stride 0x8
    localparam logic [31:0] ADDR_PC_TRTEPERFCNTDATARDRANGE_HIGH = 32'h00003304;  // 7 instances, stride 0x8
    localparam logic [31:0] ADDR_PC_TRTEPERFCNTDATAWRRANGE_LOW  = 32'h00003400;  // 7 instances, stride 0x8
    localparam logic [31:0] ADDR_PC_TRTEPERFCNTDATAWRRANGE_HIGH = 32'h00003404;  // 7 instances, stride 0x8
    localparam logic [31:0] ADDR_TRWPCONTROL                    = 32'h00004000;
    localparam logic [31:0] ADDR_TRWPIMPL                       = 32'h00004004;
    localparam logic [31:0] ADDR_ADDR                           = 32'h00004100;
    localparam logic [31:0] ADDR_CMD                            = 32'h00004104;
    localparam logic [31:0] ADDR_TRDFCONTROL                    = 32'h00005000;
    localparam logic [31:0] ADDR_TRDFIMPL                       = 32'h00005004;
    localparam logic [31:0] ADDR_KEY0                           = 32'h00006000;
    localparam logic [31:0] ADDR_KEY1                           = 32'h00006004;

    // Memory Base Addresses and Sizes
    // ========================================================================
    localparam logic [31:0] ADDR_WATCHPOINTS_MEMORY_ACT_ST      = 32'h00004100;  // instance 'watchpoints'
    localparam int WATCHPOINTS_MEMORY_ACT_ST_NUM_ENTRIES = 15;
    localparam int WATCHPOINTS_MEMORY_ACT_ST_ENTRY_BYTES = 8;
    localparam logic [31:0] ADDR_DF_RANGEFILTER_MEMORY          = 32'h00006000;  // instance 'mem1'
    localparam int DF_RANGEFILTER_MEMORY_NUM_ENTRIES    = 15;
    localparam int DF_RANGEFILTER_MEMORY_ENTRY_BYTES    = 8;

    // Bitfield Positions and Widths
    // ========================================================================

    // Register: te_trTeControl @ 0x0000
    localparam int BITPOS_te_trTeControl_Active                    = 0;
    localparam int BITPOS_te_trTeControl_Enable                    = 1;
    localparam int BITPOS_te_trTeControl_InstTracing               = 2;
    localparam int BITPOS_te_trTeControl_Empty                     = 3;
    localparam int BITPOS_te_trTeControl_InstMode_LSB             = 4;
    localparam int BITPOS_te_trTeControl_InstMode_MSB             = 6;
    localparam int WIDTH_te_trTeControl_InstMode                 = 3;
    localparam int BITPOS_te_trTeControl_SendConfig_LSB           = 7;
    localparam int BITPOS_te_trTeControl_SendConfig_MSB           = 8;
    localparam int WIDTH_te_trTeControl_SendConfig               = 2;
    localparam int BITPOS_te_trTeControl_Context                   = 9;
    localparam int BITPOS_te_trTeControl_InhibitSrc                = 15;
    localparam int BITPOS_te_trTeControl_InstSyncMode_LSB         = 16;
    localparam int BITPOS_te_trTeControl_InstSyncMode_MSB         = 19;
    localparam int WIDTH_te_trTeControl_InstSyncMode             = 4;
    localparam int BITPOS_te_trTeControl_InstSyncMax_LSB          = 20;
    localparam int BITPOS_te_trTeControl_InstSyncMax_MSB          = 23;
    localparam int WIDTH_te_trTeControl_InstSyncMax              = 4;
    localparam int BITPOS_te_trTeControl_Format_LSB               = 24;
    localparam int BITPOS_te_trTeControl_Format_MSB               = 26;
    localparam int WIDTH_te_trTeControl_Format                   = 3;
    localparam int BITPOS_te_trTeControl_InstSyncReq               = 27;

    // Register: te_trTeImpl @ 0x0004
    localparam int BITPOS_te_trTeImpl_VerMajor_LSB                = 0;
    localparam int BITPOS_te_trTeImpl_VerMajor_MSB                = 3;
    localparam int WIDTH_te_trTeImpl_VerMajor                    = 4;
    localparam int BITPOS_te_trTeImpl_VerMinor_LSB                = 4;
    localparam int BITPOS_te_trTeImpl_VerMinor_MSB                = 7;
    localparam int WIDTH_te_trTeImpl_VerMinor                    = 4;
    localparam int BITPOS_te_trTeImpl_CompType_LSB                = 8;
    localparam int BITPOS_te_trTeImpl_CompType_MSB                = 11;
    localparam int WIDTH_te_trTeImpl_CompType                    = 4;
    localparam int BITPOS_te_trTeImpl_ProtocolMajor_LSB           = 16;
    localparam int BITPOS_te_trTeImpl_ProtocolMajor_MSB           = 19;
    localparam int WIDTH_te_trTeImpl_ProtocolMajor               = 4;
    localparam int BITPOS_te_trTeImpl_ProtocolMinor_LSB           = 20;
    localparam int BITPOS_te_trTeImpl_ProtocolMinor_MSB           = 23;
    localparam int WIDTH_te_trTeImpl_ProtocolMinor               = 4;

    // Register: te_trTeInstFeatures @ 0x0008
    localparam int BITPOS_te_trTeInstFeatures_SrcID_LSB           = 16;
    localparam int BITPOS_te_trTeInstFeatures_SrcID_MSB           = 27;
    localparam int WIDTH_te_trTeInstFeatures_SrcID               = 12;
    localparam int BITPOS_te_trTeInstFeatures_SrcBits_LSB         = 28;
    localparam int BITPOS_te_trTeInstFeatures_SrcBits_MSB         = 31;
    localparam int WIDTH_te_trTeInstFeatures_SrcBits             = 4;

    // Register: te_trTeInstFilters @ 0x000C
    localparam int BITPOS_te_trTeInstFilters_Filters_LSB          = 0;
    localparam int BITPOS_te_trTeInstFilters_Filters_MSB          = 15;
    localparam int WIDTH_te_trTeInstFilters_Filters              = 16;

    // Register: te_trTeDataControl @ 0x0010
    localparam int BITPOS_te_trTeDataControl_DataImplemented       = 0;
    localparam int BITPOS_te_trTeDataControl_DataTracing           = 1;
    localparam int BITPOS_te_trTeDataControl_DataAddrCompress_LSB = 18;
    localparam int BITPOS_te_trTeDataControl_DataAddrCompress_MSB = 19;
    localparam int WIDTH_te_trTeDataControl_DataAddrCompress     = 2;
    localparam int BITPOS_te_trTeDataControl_DataSplitLoad         = 20;

    // Register: te_trTeDataFilters @ 0x001C
    localparam int BITPOS_te_trTeDataFilters_Filters_LSB          = 0;
    localparam int BITPOS_te_trTeDataFilters_Filters_MSB          = 15;
    localparam int WIDTH_te_trTeDataFilters_Filters              = 16;

    // Register: te_trTsControl @ 0x0040
    localparam int BITPOS_te_trTsControl_Active                    = 0;
    localparam int BITPOS_te_trTsControl_Count                     = 1;
    localparam int BITPOS_te_trTsControl_Reset                     = 2;
    localparam int BITPOS_te_trTsControl_Type_LSB                 = 4;
    localparam int BITPOS_te_trTsControl_Type_MSB                 = 6;
    localparam int WIDTH_te_trTsControl_Type                     = 3;
    localparam int BITPOS_te_trTsControl_Prescale_LSB             = 8;
    localparam int BITPOS_te_trTsControl_Prescale_MSB             = 9;
    localparam int WIDTH_te_trTsControl_Prescale                 = 2;
    localparam int BITPOS_te_trTsControl_Enable                    = 15;
    localparam int BITPOS_te_trTsControl_Width_LSB                = 24;
    localparam int BITPOS_te_trTsControl_Width_MSB                = 29;
    localparam int WIDTH_te_trTsControl_Width                    = 6;

    // Register: te_trTsCounterLow @ 0x0048
    localparam int BITPOS_te_trTsCounterLow_Value_LSB             = 0;
    localparam int BITPOS_te_trTsCounterLow_Value_MSB             = 31;
    localparam int WIDTH_te_trTsCounterLow_Value                 = 32;

    // Register: te_trTsCounterHigh @ 0x004C
    localparam int BITPOS_te_trTsCounterHigh_Value_LSB            = 0;
    localparam int BITPOS_te_trTsCounterHigh_Value_MSB            = 31;
    localparam int WIDTH_te_trTsCounterHigh_Value                = 32;

    // Register: te_trTeFilter_Control @ 0x0400
    localparam int BITPOS_te_trTeFilter_Control_Enable             = 0;
    localparam int BITPOS_te_trTeFilter_Control_MatchPrivilege     = 1;
    localparam int BITPOS_te_trTeFilter_Control_MatchEcause        = 2;
    localparam int BITPOS_te_trTeFilter_Control_MatchInterrupt     = 3;
    localparam int BITPOS_te_trTeFilter_Control_MatchComp1         = 4;
    localparam int BITPOS_te_trTeFilter_Control_Comp1_LSB         = 5;
    localparam int BITPOS_te_trTeFilter_Control_Comp1_MSB         = 7;
    localparam int WIDTH_te_trTeFilter_Control_Comp1             = 3;
    localparam int BITPOS_te_trTeFilter_Control_MatchComp2         = 8;
    localparam int BITPOS_te_trTeFilter_Control_Comp2_LSB         = 9;
    localparam int BITPOS_te_trTeFilter_Control_Comp2_MSB         = 11;
    localparam int WIDTH_te_trTeFilter_Control_Comp2             = 3;
    localparam int BITPOS_te_trTeFilter_Control_MatchComp3         = 12;
    localparam int BITPOS_te_trTeFilter_Control_Comp3_LSB         = 13;
    localparam int BITPOS_te_trTeFilter_Control_Comp3_MSB         = 15;
    localparam int WIDTH_te_trTeFilter_Control_Comp3             = 3;
    localparam int BITPOS_te_trTeFilter_Control_Impdef             = 16;
    localparam int BITPOS_te_trTeFilter_Control_Dtype              = 24;
    localparam int BITPOS_te_trTeFilter_Control_Dsize              = 25;

    // Register: te_trTeFilter_Match @ 0x0404
    localparam int BITPOS_te_trTeFilter_Match_ChoicePrivilege_LSB = 0;
    localparam int BITPOS_te_trTeFilter_Match_ChoicePrivilege_MSB = 7;
    localparam int WIDTH_te_trTeFilter_Match_ChoicePrivilege     = 8;
    localparam int BITPOS_te_trTeFilter_Match_ValueInterrupt       = 8;

    // Register: te_trTeFilter_MatchChoiceEcauseLow @ 0x0408
    localparam int BITPOS_te_trTeFilter_MatchChoiceEcauseLow_Value_LSB = 0;
    localparam int BITPOS_te_trTeFilter_MatchChoiceEcauseLow_Value_MSB = 31;
    localparam int WIDTH_te_trTeFilter_MatchChoiceEcauseLow_Value = 32;

    // Register: te_trTeFilter_MatchChoiceEcauseHigh @ 0x040C
    localparam int BITPOS_te_trTeFilter_MatchChoiceEcauseHigh_Value_LSB = 0;
    localparam int BITPOS_te_trTeFilter_MatchChoiceEcauseHigh_Value_MSB = 31;
    localparam int WIDTH_te_trTeFilter_MatchChoiceEcauseHigh_Value = 32;

    // Register: te_trTeFilter_MatchValueImpdef @ 0x0410
    localparam int BITPOS_te_trTeFilter_MatchValueImpdef_Value_LSB = 0;
    localparam int BITPOS_te_trTeFilter_MatchValueImpdef_Value_MSB = 31;
    localparam int WIDTH_te_trTeFilter_MatchValueImpdef_Value    = 32;

    // Register: te_trTeFilter_MatchMaskImpdef @ 0x0414
    localparam int BITPOS_te_trTeFilter_MatchMaskImpdef_Value_LSB = 0;
    localparam int BITPOS_te_trTeFilter_MatchMaskImpdef_Value_MSB = 31;
    localparam int WIDTH_te_trTeFilter_MatchMaskImpdef_Value     = 32;

    // Register: te_trTeFilter_MatchChoiceData @ 0x0418
    localparam int BITPOS_te_trTeFilter_MatchChoiceData_Dtype_LSB = 0;
    localparam int BITPOS_te_trTeFilter_MatchChoiceData_Dtype_MSB = 15;
    localparam int WIDTH_te_trTeFilter_MatchChoiceData_Dtype     = 16;
    localparam int BITPOS_te_trTeFilter_MatchChoiceData_Dsize_LSB = 16;
    localparam int BITPOS_te_trTeFilter_MatchChoiceData_Dsize_MSB = 23;
    localparam int WIDTH_te_trTeFilter_MatchChoiceData_Dsize     = 8;

    // Register: te_trTeComp_Control @ 0x0600
    localparam int BITPOS_te_trTeComp_Control_PInput_LSB          = 0;
    localparam int BITPOS_te_trTeComp_Control_PInput_MSB          = 1;
    localparam int WIDTH_te_trTeComp_Control_PInput              = 2;
    localparam int BITPOS_te_trTeComp_Control_SInput_LSB          = 2;
    localparam int BITPOS_te_trTeComp_Control_SInput_MSB          = 3;
    localparam int WIDTH_te_trTeComp_Control_SInput              = 2;
    localparam int BITPOS_te_trTeComp_Control_PFunction_LSB       = 4;
    localparam int BITPOS_te_trTeComp_Control_PFunction_MSB       = 6;
    localparam int WIDTH_te_trTeComp_Control_PFunction           = 3;
    localparam int BITPOS_te_trTeComp_Control_SFunction_LSB       = 8;
    localparam int BITPOS_te_trTeComp_Control_SFunction_MSB       = 10;
    localparam int WIDTH_te_trTeComp_Control_SFunction           = 3;
    localparam int BITPOS_te_trTeComp_Control_MatchMode_LSB       = 12;
    localparam int BITPOS_te_trTeComp_Control_MatchMode_MSB       = 13;
    localparam int WIDTH_te_trTeComp_Control_MatchMode           = 2;
    localparam int BITPOS_te_trTeComp_Control_PNotify              = 14;
    localparam int BITPOS_te_trTeComp_Control_SNotify              = 15;

    // Register: te_trTeComp_PMatchLow @ 0x0610
    localparam int BITPOS_te_trTeComp_PMatchLow_Value_LSB         = 0;
    localparam int BITPOS_te_trTeComp_PMatchLow_Value_MSB         = 31;
    localparam int WIDTH_te_trTeComp_PMatchLow_Value             = 32;

    // Register: te_trTeComp_PMatchHigh @ 0x0614
    localparam int BITPOS_te_trTeComp_PMatchHigh_Value_LSB        = 0;
    localparam int BITPOS_te_trTeComp_PMatchHigh_Value_MSB        = 31;
    localparam int WIDTH_te_trTeComp_PMatchHigh_Value            = 32;

    // Register: te_trTeComp_SMatchLow @ 0x0618
    localparam int BITPOS_te_trTeComp_SMatchLow_Value_LSB         = 0;
    localparam int BITPOS_te_trTeComp_SMatchLow_Value_MSB         = 31;
    localparam int WIDTH_te_trTeComp_SMatchLow_Value             = 32;

    // Register: te_trTeComp_SMatchHigh @ 0x061C
    localparam int BITPOS_te_trTeComp_SMatchHigh_Value_LSB        = 0;
    localparam int BITPOS_te_trTeComp_SMatchHigh_Value_MSB        = 31;
    localparam int WIDTH_te_trTeComp_SMatchHigh_Value            = 32;

    // Register: te_trTeCsrControl @ 0x0E00
    localparam int BITPOS_te_trTeCsrControl_trTeCsrSendSync        = 0;
    localparam int BITPOS_te_trTeCsrControl_trTeCsrSendPC          = 1;
    localparam int BITPOS_te_trTeCsrControl_trTeCsrSendTS          = 2;
    localparam int BITPOS_te_trTeCsrControl_trTeCsrSendCC          = 3;

    // Register: te_trTeTipFifoStatus @ 0x0E04
    localparam int BITPOS_te_trTeTipFifoStatus_trTeTipFifoMaxFill_LSB = 0;
    localparam int BITPOS_te_trTeTipFifoStatus_trTeTipFifoMaxFill_MSB = 14;
    localparam int WIDTH_te_trTeTipFifoStatus_trTeTipFifoMaxFill = 15;
    localparam int BITPOS_te_trTeTipFifoStatus_trTeTipFifoMaxFillClear = 15;
    localparam int BITPOS_te_trTeTipFifoStatus_trTeTipFifoNumOverflows_LSB = 16;
    localparam int BITPOS_te_trTeTipFifoStatus_trTeTipFifoNumOverflows_MSB = 30;
    localparam int WIDTH_te_trTeTipFifoStatus_trTeTipFifoNumOverflows = 15;
    localparam int BITPOS_te_trTeTipFifoStatus_trTeTipFifoNumOverflowsClear = 31;

    // Register: atb_trAtbBridgeControl @ 0x1000
    localparam int BITPOS_atb_trAtbBridgeControl_Active            = 0;
    localparam int BITPOS_atb_trAtbBridgeControl_Enable            = 1;
    localparam int BITPOS_atb_trAtbBridgeControl_Empty             = 3;
    localparam int BITPOS_atb_trAtbBridgeControl_ID_LSB           = 8;
    localparam int BITPOS_atb_trAtbBridgeControl_ID_MSB           = 14;
    localparam int WIDTH_atb_trAtbBridgeControl_ID               = 7;

    // Register: atb_trAtbBridgeImpl @ 0x1004
    localparam int BITPOS_atb_trAtbBridgeImpl_VerMajor_LSB        = 0;
    localparam int BITPOS_atb_trAtbBridgeImpl_VerMajor_MSB        = 3;
    localparam int WIDTH_atb_trAtbBridgeImpl_VerMajor            = 4;
    localparam int BITPOS_atb_trAtbBridgeImpl_VerMinor_LSB        = 4;
    localparam int BITPOS_atb_trAtbBridgeImpl_VerMinor_MSB        = 7;
    localparam int WIDTH_atb_trAtbBridgeImpl_VerMinor            = 4;
    localparam int BITPOS_atb_trAtbBridgeImpl_CompType_LSB        = 8;
    localparam int BITPOS_atb_trAtbBridgeImpl_CompType_MSB        = 11;
    localparam int WIDTH_atb_trAtbBridgeImpl_CompType            = 4;
    localparam int BITPOS_atb_trAtbBridgeImpl_AsyncFreq_LSB       = 12;
    localparam int BITPOS_atb_trAtbBridgeImpl_AsyncFreq_MSB       = 14;
    localparam int WIDTH_atb_trAtbBridgeImpl_AsyncFreq           = 3;

    // Register: pc_trPcControl @ 0x3000
    localparam int BITPOS_pc_trPcControl_Active                    = 0;

    // Register: pc_trPcImpl @ 0x3004
    localparam int BITPOS_pc_trPcImpl_VerMajor_LSB                = 0;
    localparam int BITPOS_pc_trPcImpl_VerMajor_MSB                = 3;
    localparam int WIDTH_pc_trPcImpl_VerMajor                    = 4;
    localparam int BITPOS_pc_trPcImpl_VerMinor_LSB                = 4;
    localparam int BITPOS_pc_trPcImpl_VerMinor_MSB                = 7;
    localparam int WIDTH_pc_trPcImpl_VerMinor                    = 4;
    localparam int BITPOS_pc_trPcImpl_CompType_LSB                = 8;
    localparam int BITPOS_pc_trPcImpl_CompType_MSB                = 11;
    localparam int WIDTH_pc_trPcImpl_CompType                    = 4;

    // Register: pc_trTeConstants @ 0x3008
    localparam int BITPOS_pc_trTeConstants_num_trace_filter_LSB   = 0;
    localparam int BITPOS_pc_trTeConstants_num_trace_filter_MSB   = 4;
    localparam int WIDTH_pc_trTeConstants_num_trace_filter       = 5;
    localparam int BITPOS_pc_trTeConstants_num_trace_comparators_LSB = 5;
    localparam int BITPOS_pc_trTeConstants_num_trace_comparators_MSB = 8;
    localparam int WIDTH_pc_trTeConstants_num_trace_comparators  = 4;
    localparam int BITPOS_pc_trTeConstants_num_perfcnt_ifetch_th_ranges_LSB = 9;
    localparam int BITPOS_pc_trTeConstants_num_perfcnt_ifetch_th_ranges_MSB = 12;
    localparam int WIDTH_pc_trTeConstants_num_perfcnt_ifetch_th_ranges = 4;
    localparam int BITPOS_pc_trTeConstants_num_perfcnt_data_rd_th_ranges_LSB = 13;
    localparam int BITPOS_pc_trTeConstants_num_perfcnt_data_rd_th_ranges_MSB = 16;
    localparam int WIDTH_pc_trTeConstants_num_perfcnt_data_rd_th_ranges = 4;
    localparam int BITPOS_pc_trTeConstants_num_perfcnt_data_rd_ranges_LSB = 17;
    localparam int BITPOS_pc_trTeConstants_num_perfcnt_data_rd_ranges_MSB = 20;
    localparam int WIDTH_pc_trTeConstants_num_perfcnt_data_rd_ranges = 4;
    localparam int BITPOS_pc_trTeConstants_num_perfcnt_data_wr_ranges_LSB = 21;
    localparam int BITPOS_pc_trTeConstants_num_perfcnt_data_wr_ranges_MSB = 24;
    localparam int WIDTH_pc_trTeConstants_num_perfcnt_data_wr_ranges = 4;

    // Register: pc_trPerfCntControl @ 0x3010
    localparam int BITPOS_pc_trPerfCntControl_IFetchThreshold_LSB = 0;
    localparam int BITPOS_pc_trPerfCntControl_IFetchThreshold_MSB = 7;
    localparam int WIDTH_pc_trPerfCntControl_IFetchThreshold     = 8;
    localparam int BITPOS_pc_trPerfCntControl_DataWrThreshold_LSB = 8;
    localparam int BITPOS_pc_trPerfCntControl_DataWrThreshold_MSB = 15;
    localparam int WIDTH_pc_trPerfCntControl_DataWrThreshold     = 8;

    // Register: pc_trTePerfCntIFetchRange_Low @ 0x3100
    localparam int BITPOS_pc_trTePerfCntIFetchRange_Low_Value_LSB = 0;
    localparam int BITPOS_pc_trTePerfCntIFetchRange_Low_Value_MSB = 31;
    localparam int WIDTH_pc_trTePerfCntIFetchRange_Low_Value     = 32;

    // Register: pc_trTePerfCntIFetchRange_High @ 0x3104
    localparam int BITPOS_pc_trTePerfCntIFetchRange_High_Value_LSB = 0;
    localparam int BITPOS_pc_trTePerfCntIFetchRange_High_Value_MSB = 31;
    localparam int WIDTH_pc_trTePerfCntIFetchRange_High_Value    = 32;

    // Register: pc_trTePerfCntDataRdThRange_Low @ 0x3200
    localparam int BITPOS_pc_trTePerfCntDataRdThRange_Low_Value_LSB = 0;
    localparam int BITPOS_pc_trTePerfCntDataRdThRange_Low_Value_MSB = 31;
    localparam int WIDTH_pc_trTePerfCntDataRdThRange_Low_Value   = 32;

    // Register: pc_trTePerfCntDataRdThRange_High @ 0x3204
    localparam int BITPOS_pc_trTePerfCntDataRdThRange_High_Value_LSB = 0;
    localparam int BITPOS_pc_trTePerfCntDataRdThRange_High_Value_MSB = 31;
    localparam int WIDTH_pc_trTePerfCntDataRdThRange_High_Value  = 32;

    // Register: pc_trTePerfCntDataRdRange_Low @ 0x3300
    localparam int BITPOS_pc_trTePerfCntDataRdRange_Low_Value_LSB = 0;
    localparam int BITPOS_pc_trTePerfCntDataRdRange_Low_Value_MSB = 31;
    localparam int WIDTH_pc_trTePerfCntDataRdRange_Low_Value     = 32;

    // Register: pc_trTePerfCntDataRdRange_High @ 0x3304
    localparam int BITPOS_pc_trTePerfCntDataRdRange_High_Value_LSB = 0;
    localparam int BITPOS_pc_trTePerfCntDataRdRange_High_Value_MSB = 31;
    localparam int WIDTH_pc_trTePerfCntDataRdRange_High_Value    = 32;

    // Register: pc_trTePerfCntDataWrRange_Low @ 0x3400
    localparam int BITPOS_pc_trTePerfCntDataWrRange_Low_Value_LSB = 0;
    localparam int BITPOS_pc_trTePerfCntDataWrRange_Low_Value_MSB = 31;
    localparam int WIDTH_pc_trTePerfCntDataWrRange_Low_Value     = 32;

    // Register: pc_trTePerfCntDataWrRange_High @ 0x3404
    localparam int BITPOS_pc_trTePerfCntDataWrRange_High_Value_LSB = 0;
    localparam int BITPOS_pc_trTePerfCntDataWrRange_High_Value_MSB = 31;
    localparam int WIDTH_pc_trTePerfCntDataWrRange_High_Value    = 32;

    // Register: trWpControl @ 0x4000
    localparam int BITPOS_trWpControl_Active                       = 0;

    // Register: trWpImpl @ 0x4004
    localparam int BITPOS_trWpImpl_VerMajor_LSB                   = 0;
    localparam int BITPOS_trWpImpl_VerMajor_MSB                   = 3;
    localparam int WIDTH_trWpImpl_VerMajor                       = 4;
    localparam int BITPOS_trWpImpl_VerMinor_LSB                   = 4;
    localparam int BITPOS_trWpImpl_VerMinor_MSB                   = 7;
    localparam int WIDTH_trWpImpl_VerMinor                       = 4;
    localparam int BITPOS_trWpImpl_CompType_LSB                   = 8;
    localparam int BITPOS_trWpImpl_CompType_MSB                   = 11;
    localparam int WIDTH_trWpImpl_CompType                       = 4;

    // Register: Addr @ 0x4100
    localparam int BITPOS_Addr_Value_LSB                          = 0;
    localparam int BITPOS_Addr_Value_MSB                          = 31;
    localparam int WIDTH_Addr_Value                              = 32;

    // Register: Cmd @ 0x4104
    localparam int BITPOS_Cmd_Cmd_LSB                             = 0;
    localparam int BITPOS_Cmd_Cmd_MSB                             = 5;
    localparam int WIDTH_Cmd_Cmd                                 = 6;
    localparam int BITPOS_Cmd_Sink_LSB                            = 6;
    localparam int BITPOS_Cmd_Sink_MSB                            = 7;
    localparam int WIDTH_Cmd_Sink                                = 2;
    localparam int BITPOS_Cmd_DirectData_LSB                      = 8;
    localparam int BITPOS_Cmd_DirectData_MSB                      = 31;
    localparam int WIDTH_Cmd_DirectData                          = 24;

    // Register: trDfControl @ 0x5000
    localparam int BITPOS_trDfControl_Active                       = 0;

    // Register: trDfImpl @ 0x5004
    localparam int BITPOS_trDfImpl_VerMajor_LSB                   = 0;
    localparam int BITPOS_trDfImpl_VerMajor_MSB                   = 3;
    localparam int WIDTH_trDfImpl_VerMajor                       = 4;
    localparam int BITPOS_trDfImpl_VerMinor_LSB                   = 4;
    localparam int BITPOS_trDfImpl_VerMinor_MSB                   = 7;
    localparam int WIDTH_trDfImpl_VerMinor                       = 4;
    localparam int BITPOS_trDfImpl_CompType_LSB                   = 8;
    localparam int BITPOS_trDfImpl_CompType_MSB                   = 11;
    localparam int WIDTH_trDfImpl_CompType                       = 4;

    // Register: Key0 @ 0x6000
    localparam int BITPOS_Key0_Value_LSB                          = 0;
    localparam int BITPOS_Key0_Value_MSB                          = 31;
    localparam int WIDTH_Key0_Value                              = 32;

    // Register: Key1 @ 0x6004
    localparam int BITPOS_Key1_Value_LSB                          = 0;
    localparam int BITPOS_Key1_Value_MSB                          = 31;
    localparam int WIDTH_Key1_Value                              = 32;

endpackage
