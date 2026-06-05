// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// ============================================================================
// Auto-generated Wishbone Register Access Helper Module
// DO NOT EDIT MANUALLY - Changes will be overwritten!
//
// Usage in testbench:
//   import ct_cs_cpuif_wb_pkg::*;
//   ct_cs_cpuif_wb_helper #(.WB_DATA_WIDTH(32), .WB_ADDR_WIDTH(32)) helper(clk, wb);
//
//   // Generic register access
//   //   helper.write(ADDR_<REG>, 32'hAABBCCDD);
//   //   helper.read(ADDR_<REG>, data);
//   //   helper.Write_<reg>(32'hAABBCCDD);
//   //   helper.Read_<reg>(data);
//
//   // Field-level helpers (examples):
//   //   Set_trTeDataFilters_Filters(16'h3);         // field = 16'h3
//   //   Get_trTeDataFilters_Filters(value);         // read field (only if sw=r/rw)
//   //   SetMask_trTeDataFilters_Filters(16'h3);     // field |= 16'h3
//   //   ClearMask_trTeDataFilters_Filters(16'h3);   // field &= ~16'h3
//   //   Set_trTsControl_Active(1'b0);              // clear single bit
//   //   Get_trTsControl_Active(value);             // read single bit (only if sw=r/rw)
//
//   // For register arrays (e.g. regfile[NUM]), tasks take an index:
//   //   Write_trTeFilter_Control(id, data);
//   //   Read_trTeFilter_Control(id, data);
//   //   Set_trTeFilter_Control_Enable(id, 1'b1);
//   //   Get_trTeFilter_Control_Enable(id, value);
//
//   // For memories (external mem), tasks take an index:
//   //   Write_ACT_ST_Memory(entry, data64);
//   //   Read_ACT_ST_Memory(entry, data64);
//   //   SetMask_ACT_ST_Memory(entry, mask64);
//   //   ClearMask_ACT_ST_Memory(entry, mask64);
//   //   Get_ACT_ST_Memory(entry, data64);     // only if sw=r/rw
// ============================================================================

module ct_cs_cpuif_wb_helper #(
	int unsigned WB_DATA_WIDTH  = 32,
	int unsigned WB_ADDR_WIDTH  = 32
)(
	input  uwire logic clk,
	wb_if.master wb
);

	import ct_cs_cpuif_wb_pkg::*;

	// ========================================================================
	// Basic Wishbone Transactions
	// ========================================================================

	task clear;
		wb.addr     <= 'x;
		wb.data_m2s <= 'x;
		wb.cyc      <= '0;
		wb.stb      <= '0;
		wb.we       <= '0;
		wb.sel      <= '0;
	endtask

	task write(input logic [WB_ADDR_WIDTH-1:0] addr, input logic [WB_DATA_WIDTH-1:0] data);
		wb.addr     <= addr;
		wb.data_m2s <= data;
		wb.cyc      <= '1;
		wb.stb      <= '1;
		wb.we       <= '1;
		wb.sel      <= '1;
		@(posedge clk iff wb.ack || wb.err);
		clear();
		@(posedge clk);
	endtask

	task read(input logic [WB_ADDR_WIDTH-1:0] addr, output logic [WB_DATA_WIDTH-1:0] data);
		wb.addr     <= addr;
		wb.data_m2s <= 'x;
		wb.cyc      <= '1;
		wb.stb      <= '1;
		wb.we       <= '0;
		wb.sel      <= '1;
		@(posedge clk iff wb.ack || wb.err);
		data = wb.data_s2m;
		clear();
		@(posedge clk);
	endtask

	// Single-bit helper: set a single bit to the given value
	task SetBitField(input logic [WB_ADDR_WIDTH-1:0] addr, input int bit_pos, input logic value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(addr, reg_data);
		reg_data[bit_pos] = value;
		write(addr, reg_data);
	endtask

	// Multi-bit helper: overwrite a bitfield with a new value
	task SetField(input logic [WB_ADDR_WIDTH-1:0] addr,
		         input int msb, input int lsb,
		         input logic [WB_DATA_WIDTH-1:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		logic [WB_DATA_WIDTH-1:0] mask;
		int width, i;
		width = msb - lsb + 1;
		read(addr, reg_data);
		mask = '0;
		for (i = 0; i < width; i = i + 1) begin
			mask[lsb + i] = 1'b1;
		end
		reg_data = (reg_data & ~mask);
		for (i = 0; i < width; i = i + 1) begin
			reg_data[lsb + i] = value[i];
		end
		write(addr, reg_data);
	endtask

	// ========================================================================
	// Register-Specific Access Tasks
	// ========================================================================

	// Register: te_trTeControl @ 0x0000
	task Write_te_trTeControl(input logic [WB_DATA_WIDTH-1:0] data);
		write(ADDR_TE_TRTECONTROL, data);
	endtask

	task Read_te_trTeControl(output logic [WB_DATA_WIDTH-1:0] data);
		read(ADDR_TE_TRTECONTROL, data);
	endtask

	// Single-bit field: te_trTeControl.Active
	task Set_te_trTeControl_Active(input logic value);
		SetBitField(ADDR_TE_TRTECONTROL, BITPOS_te_trTeControl_Active, value);
	endtask

	// Single-bit field: te_trTeControl.Enable
	task Set_te_trTeControl_Enable(input logic value);
		SetBitField(ADDR_TE_TRTECONTROL, BITPOS_te_trTeControl_Enable, value);
	endtask

	// Single-bit field: te_trTeControl.InstTracing
	task Set_te_trTeControl_InstTracing(input logic value);
		SetBitField(ADDR_TE_TRTECONTROL, BITPOS_te_trTeControl_InstTracing, value);
	endtask

	// Single-bit field: te_trTeControl.Empty
	task Set_te_trTeControl_Empty(input logic value);
		SetBitField(ADDR_TE_TRTECONTROL, BITPOS_te_trTeControl_Empty, value);
	endtask

	// Multi-bit field: te_trTeControl.InstMode
	task Set_te_trTeControl_InstMode(input logic [2:0] value);
		SetField(ADDR_TE_TRTECONTROL, BITPOS_te_trTeControl_InstMode_MSB, BITPOS_te_trTeControl_InstMode_LSB, value);
	endtask

	task ClearMask_te_trTeControl_InstMode(input logic [2:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_TE_TRTECONTROL, reg_data);
		reg_data[BITPOS_te_trTeControl_InstMode_LSB +: 3] &= ~value;
		write(ADDR_TE_TRTECONTROL, reg_data);
	endtask

	task SetMask_te_trTeControl_InstMode(input logic [2:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_TE_TRTECONTROL, reg_data);
		reg_data[BITPOS_te_trTeControl_InstMode_LSB +: 3] |= value;
		write(ADDR_TE_TRTECONTROL, reg_data);
	endtask

	// Multi-bit field: te_trTeControl.SendConfig
	task Set_te_trTeControl_SendConfig(input logic [1:0] value);
		SetField(ADDR_TE_TRTECONTROL, BITPOS_te_trTeControl_SendConfig_MSB, BITPOS_te_trTeControl_SendConfig_LSB, value);
	endtask

	task ClearMask_te_trTeControl_SendConfig(input logic [1:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_TE_TRTECONTROL, reg_data);
		reg_data[BITPOS_te_trTeControl_SendConfig_LSB +: 2] &= ~value;
		write(ADDR_TE_TRTECONTROL, reg_data);
	endtask

	task SetMask_te_trTeControl_SendConfig(input logic [1:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_TE_TRTECONTROL, reg_data);
		reg_data[BITPOS_te_trTeControl_SendConfig_LSB +: 2] |= value;
		write(ADDR_TE_TRTECONTROL, reg_data);
	endtask

	// Single-bit field: te_trTeControl.Context
	task Set_te_trTeControl_Context(input logic value);
		SetBitField(ADDR_TE_TRTECONTROL, BITPOS_te_trTeControl_Context, value);
	endtask

	// Single-bit field: te_trTeControl.InhibitSrc
	task Set_te_trTeControl_InhibitSrc(input logic value);
		SetBitField(ADDR_TE_TRTECONTROL, BITPOS_te_trTeControl_InhibitSrc, value);
	endtask

	// Multi-bit field: te_trTeControl.InstSyncMode
	task Set_te_trTeControl_InstSyncMode(input logic [3:0] value);
		SetField(ADDR_TE_TRTECONTROL, BITPOS_te_trTeControl_InstSyncMode_MSB, BITPOS_te_trTeControl_InstSyncMode_LSB, value);
	endtask

	task ClearMask_te_trTeControl_InstSyncMode(input logic [3:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_TE_TRTECONTROL, reg_data);
		reg_data[BITPOS_te_trTeControl_InstSyncMode_LSB +: 4] &= ~value;
		write(ADDR_TE_TRTECONTROL, reg_data);
	endtask

	task SetMask_te_trTeControl_InstSyncMode(input logic [3:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_TE_TRTECONTROL, reg_data);
		reg_data[BITPOS_te_trTeControl_InstSyncMode_LSB +: 4] |= value;
		write(ADDR_TE_TRTECONTROL, reg_data);
	endtask

	// Multi-bit field: te_trTeControl.InstSyncMax
	task Set_te_trTeControl_InstSyncMax(input logic [3:0] value);
		SetField(ADDR_TE_TRTECONTROL, BITPOS_te_trTeControl_InstSyncMax_MSB, BITPOS_te_trTeControl_InstSyncMax_LSB, value);
	endtask

	task ClearMask_te_trTeControl_InstSyncMax(input logic [3:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_TE_TRTECONTROL, reg_data);
		reg_data[BITPOS_te_trTeControl_InstSyncMax_LSB +: 4] &= ~value;
		write(ADDR_TE_TRTECONTROL, reg_data);
	endtask

	task SetMask_te_trTeControl_InstSyncMax(input logic [3:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_TE_TRTECONTROL, reg_data);
		reg_data[BITPOS_te_trTeControl_InstSyncMax_LSB +: 4] |= value;
		write(ADDR_TE_TRTECONTROL, reg_data);
	endtask

	// Multi-bit field: te_trTeControl.Format
	task Set_te_trTeControl_Format(input logic [2:0] value);
		SetField(ADDR_TE_TRTECONTROL, BITPOS_te_trTeControl_Format_MSB, BITPOS_te_trTeControl_Format_LSB, value);
	endtask

	task ClearMask_te_trTeControl_Format(input logic [2:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_TE_TRTECONTROL, reg_data);
		reg_data[BITPOS_te_trTeControl_Format_LSB +: 3] &= ~value;
		write(ADDR_TE_TRTECONTROL, reg_data);
	endtask

	task SetMask_te_trTeControl_Format(input logic [2:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_TE_TRTECONTROL, reg_data);
		reg_data[BITPOS_te_trTeControl_Format_LSB +: 3] |= value;
		write(ADDR_TE_TRTECONTROL, reg_data);
	endtask

	// Single-bit field: te_trTeControl.InstSyncReq
	task Set_te_trTeControl_InstSyncReq(input logic value);
		SetBitField(ADDR_TE_TRTECONTROL, BITPOS_te_trTeControl_InstSyncReq, value);
	endtask

	// Register: te_trTeImpl @ 0x0004
	task Write_te_trTeImpl(input logic [WB_DATA_WIDTH-1:0] data);
		write(ADDR_TE_TRTEIMPL, data);
	endtask

	task Read_te_trTeImpl(output logic [WB_DATA_WIDTH-1:0] data);
		read(ADDR_TE_TRTEIMPL, data);
	endtask

	// Multi-bit field: te_trTeImpl.VerMajor
	task Set_te_trTeImpl_VerMajor(input logic [3:0] value);
		SetField(ADDR_TE_TRTEIMPL, BITPOS_te_trTeImpl_VerMajor_MSB, BITPOS_te_trTeImpl_VerMajor_LSB, value);
	endtask

	task ClearMask_te_trTeImpl_VerMajor(input logic [3:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_TE_TRTEIMPL, reg_data);
		reg_data[BITPOS_te_trTeImpl_VerMajor_LSB +: 4] &= ~value;
		write(ADDR_TE_TRTEIMPL, reg_data);
	endtask

	task SetMask_te_trTeImpl_VerMajor(input logic [3:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_TE_TRTEIMPL, reg_data);
		reg_data[BITPOS_te_trTeImpl_VerMajor_LSB +: 4] |= value;
		write(ADDR_TE_TRTEIMPL, reg_data);
	endtask

	// Multi-bit field: te_trTeImpl.VerMinor
	task Set_te_trTeImpl_VerMinor(input logic [3:0] value);
		SetField(ADDR_TE_TRTEIMPL, BITPOS_te_trTeImpl_VerMinor_MSB, BITPOS_te_trTeImpl_VerMinor_LSB, value);
	endtask

	task ClearMask_te_trTeImpl_VerMinor(input logic [3:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_TE_TRTEIMPL, reg_data);
		reg_data[BITPOS_te_trTeImpl_VerMinor_LSB +: 4] &= ~value;
		write(ADDR_TE_TRTEIMPL, reg_data);
	endtask

	task SetMask_te_trTeImpl_VerMinor(input logic [3:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_TE_TRTEIMPL, reg_data);
		reg_data[BITPOS_te_trTeImpl_VerMinor_LSB +: 4] |= value;
		write(ADDR_TE_TRTEIMPL, reg_data);
	endtask

	// Multi-bit field: te_trTeImpl.CompType
	task Set_te_trTeImpl_CompType(input logic [3:0] value);
		SetField(ADDR_TE_TRTEIMPL, BITPOS_te_trTeImpl_CompType_MSB, BITPOS_te_trTeImpl_CompType_LSB, value);
	endtask

	task ClearMask_te_trTeImpl_CompType(input logic [3:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_TE_TRTEIMPL, reg_data);
		reg_data[BITPOS_te_trTeImpl_CompType_LSB +: 4] &= ~value;
		write(ADDR_TE_TRTEIMPL, reg_data);
	endtask

	task SetMask_te_trTeImpl_CompType(input logic [3:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_TE_TRTEIMPL, reg_data);
		reg_data[BITPOS_te_trTeImpl_CompType_LSB +: 4] |= value;
		write(ADDR_TE_TRTEIMPL, reg_data);
	endtask

	// Multi-bit field: te_trTeImpl.ProtocolMajor
	task Set_te_trTeImpl_ProtocolMajor(input logic [3:0] value);
		SetField(ADDR_TE_TRTEIMPL, BITPOS_te_trTeImpl_ProtocolMajor_MSB, BITPOS_te_trTeImpl_ProtocolMajor_LSB, value);
	endtask

	task ClearMask_te_trTeImpl_ProtocolMajor(input logic [3:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_TE_TRTEIMPL, reg_data);
		reg_data[BITPOS_te_trTeImpl_ProtocolMajor_LSB +: 4] &= ~value;
		write(ADDR_TE_TRTEIMPL, reg_data);
	endtask

	task SetMask_te_trTeImpl_ProtocolMajor(input logic [3:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_TE_TRTEIMPL, reg_data);
		reg_data[BITPOS_te_trTeImpl_ProtocolMajor_LSB +: 4] |= value;
		write(ADDR_TE_TRTEIMPL, reg_data);
	endtask

	// Multi-bit field: te_trTeImpl.ProtocolMinor
	task Set_te_trTeImpl_ProtocolMinor(input logic [3:0] value);
		SetField(ADDR_TE_TRTEIMPL, BITPOS_te_trTeImpl_ProtocolMinor_MSB, BITPOS_te_trTeImpl_ProtocolMinor_LSB, value);
	endtask

	task ClearMask_te_trTeImpl_ProtocolMinor(input logic [3:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_TE_TRTEIMPL, reg_data);
		reg_data[BITPOS_te_trTeImpl_ProtocolMinor_LSB +: 4] &= ~value;
		write(ADDR_TE_TRTEIMPL, reg_data);
	endtask

	task SetMask_te_trTeImpl_ProtocolMinor(input logic [3:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_TE_TRTEIMPL, reg_data);
		reg_data[BITPOS_te_trTeImpl_ProtocolMinor_LSB +: 4] |= value;
		write(ADDR_TE_TRTEIMPL, reg_data);
	endtask

	// Register: te_trTeInstFeatures @ 0x0008
	task Write_te_trTeInstFeatures(input logic [WB_DATA_WIDTH-1:0] data);
		write(ADDR_TE_TRTEINSTFEATURES, data);
	endtask

	task Read_te_trTeInstFeatures(output logic [WB_DATA_WIDTH-1:0] data);
		read(ADDR_TE_TRTEINSTFEATURES, data);
	endtask

	// Multi-bit field: te_trTeInstFeatures.SrcID
	task Set_te_trTeInstFeatures_SrcID(input logic [11:0] value);
		SetField(ADDR_TE_TRTEINSTFEATURES, BITPOS_te_trTeInstFeatures_SrcID_MSB, BITPOS_te_trTeInstFeatures_SrcID_LSB, value);
	endtask

	task ClearMask_te_trTeInstFeatures_SrcID(input logic [11:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_TE_TRTEINSTFEATURES, reg_data);
		reg_data[BITPOS_te_trTeInstFeatures_SrcID_LSB +: 12] &= ~value;
		write(ADDR_TE_TRTEINSTFEATURES, reg_data);
	endtask

	task SetMask_te_trTeInstFeatures_SrcID(input logic [11:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_TE_TRTEINSTFEATURES, reg_data);
		reg_data[BITPOS_te_trTeInstFeatures_SrcID_LSB +: 12] |= value;
		write(ADDR_TE_TRTEINSTFEATURES, reg_data);
	endtask

	// Multi-bit field: te_trTeInstFeatures.SrcBits
	task Set_te_trTeInstFeatures_SrcBits(input logic [3:0] value);
		SetField(ADDR_TE_TRTEINSTFEATURES, BITPOS_te_trTeInstFeatures_SrcBits_MSB, BITPOS_te_trTeInstFeatures_SrcBits_LSB, value);
	endtask

	task ClearMask_te_trTeInstFeatures_SrcBits(input logic [3:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_TE_TRTEINSTFEATURES, reg_data);
		reg_data[BITPOS_te_trTeInstFeatures_SrcBits_LSB +: 4] &= ~value;
		write(ADDR_TE_TRTEINSTFEATURES, reg_data);
	endtask

	task SetMask_te_trTeInstFeatures_SrcBits(input logic [3:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_TE_TRTEINSTFEATURES, reg_data);
		reg_data[BITPOS_te_trTeInstFeatures_SrcBits_LSB +: 4] |= value;
		write(ADDR_TE_TRTEINSTFEATURES, reg_data);
	endtask

	// Register: te_trTeInstFilters @ 0x000C
	task Write_te_trTeInstFilters(input logic [WB_DATA_WIDTH-1:0] data);
		write(ADDR_TE_TRTEINSTFILTERS, data);
	endtask

	task Read_te_trTeInstFilters(output logic [WB_DATA_WIDTH-1:0] data);
		read(ADDR_TE_TRTEINSTFILTERS, data);
	endtask

	// Multi-bit field: te_trTeInstFilters.Filters
	task Set_te_trTeInstFilters_Filters(input logic [15:0] value);
		SetField(ADDR_TE_TRTEINSTFILTERS, BITPOS_te_trTeInstFilters_Filters_MSB, BITPOS_te_trTeInstFilters_Filters_LSB, value);
	endtask

	task ClearMask_te_trTeInstFilters_Filters(input logic [15:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_TE_TRTEINSTFILTERS, reg_data);
		reg_data[BITPOS_te_trTeInstFilters_Filters_LSB +: 16] &= ~value;
		write(ADDR_TE_TRTEINSTFILTERS, reg_data);
	endtask

	task SetMask_te_trTeInstFilters_Filters(input logic [15:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_TE_TRTEINSTFILTERS, reg_data);
		reg_data[BITPOS_te_trTeInstFilters_Filters_LSB +: 16] |= value;
		write(ADDR_TE_TRTEINSTFILTERS, reg_data);
	endtask

	// Register: te_trTeDataControl @ 0x0010
	task Write_te_trTeDataControl(input logic [WB_DATA_WIDTH-1:0] data);
		write(ADDR_TE_TRTEDATACONTROL, data);
	endtask

	task Read_te_trTeDataControl(output logic [WB_DATA_WIDTH-1:0] data);
		read(ADDR_TE_TRTEDATACONTROL, data);
	endtask

	// Single-bit field: te_trTeDataControl.DataImplemented
	task Set_te_trTeDataControl_DataImplemented(input logic value);
		SetBitField(ADDR_TE_TRTEDATACONTROL, BITPOS_te_trTeDataControl_DataImplemented, value);
	endtask

	// Single-bit field: te_trTeDataControl.DataTracing
	task Set_te_trTeDataControl_DataTracing(input logic value);
		SetBitField(ADDR_TE_TRTEDATACONTROL, BITPOS_te_trTeDataControl_DataTracing, value);
	endtask

	// Multi-bit field: te_trTeDataControl.DataAddrCompress
	task Set_te_trTeDataControl_DataAddrCompress(input logic [1:0] value);
		SetField(ADDR_TE_TRTEDATACONTROL, BITPOS_te_trTeDataControl_DataAddrCompress_MSB, BITPOS_te_trTeDataControl_DataAddrCompress_LSB, value);
	endtask

	task ClearMask_te_trTeDataControl_DataAddrCompress(input logic [1:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_TE_TRTEDATACONTROL, reg_data);
		reg_data[BITPOS_te_trTeDataControl_DataAddrCompress_LSB +: 2] &= ~value;
		write(ADDR_TE_TRTEDATACONTROL, reg_data);
	endtask

	task SetMask_te_trTeDataControl_DataAddrCompress(input logic [1:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_TE_TRTEDATACONTROL, reg_data);
		reg_data[BITPOS_te_trTeDataControl_DataAddrCompress_LSB +: 2] |= value;
		write(ADDR_TE_TRTEDATACONTROL, reg_data);
	endtask

	// Single-bit field: te_trTeDataControl.DataSplitLoad
	task Set_te_trTeDataControl_DataSplitLoad(input logic value);
		SetBitField(ADDR_TE_TRTEDATACONTROL, BITPOS_te_trTeDataControl_DataSplitLoad, value);
	endtask

	// Register: te_trTeDataFilters @ 0x001C
	task Write_te_trTeDataFilters(input logic [WB_DATA_WIDTH-1:0] data);
		write(ADDR_TE_TRTEDATAFILTERS, data);
	endtask

	task Read_te_trTeDataFilters(output logic [WB_DATA_WIDTH-1:0] data);
		read(ADDR_TE_TRTEDATAFILTERS, data);
	endtask

	// Multi-bit field: te_trTeDataFilters.Filters
	task Set_te_trTeDataFilters_Filters(input logic [15:0] value);
		SetField(ADDR_TE_TRTEDATAFILTERS, BITPOS_te_trTeDataFilters_Filters_MSB, BITPOS_te_trTeDataFilters_Filters_LSB, value);
	endtask

	task ClearMask_te_trTeDataFilters_Filters(input logic [15:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_TE_TRTEDATAFILTERS, reg_data);
		reg_data[BITPOS_te_trTeDataFilters_Filters_LSB +: 16] &= ~value;
		write(ADDR_TE_TRTEDATAFILTERS, reg_data);
	endtask

	task SetMask_te_trTeDataFilters_Filters(input logic [15:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_TE_TRTEDATAFILTERS, reg_data);
		reg_data[BITPOS_te_trTeDataFilters_Filters_LSB +: 16] |= value;
		write(ADDR_TE_TRTEDATAFILTERS, reg_data);
	endtask

	// Register: te_trTsControl @ 0x0040
	task Write_te_trTsControl(input logic [WB_DATA_WIDTH-1:0] data);
		write(ADDR_TE_TRTSCONTROL, data);
	endtask

	task Read_te_trTsControl(output logic [WB_DATA_WIDTH-1:0] data);
		read(ADDR_TE_TRTSCONTROL, data);
	endtask

	// Single-bit field: te_trTsControl.Active
	task Set_te_trTsControl_Active(input logic value);
		SetBitField(ADDR_TE_TRTSCONTROL, BITPOS_te_trTsControl_Active, value);
	endtask

	// Single-bit field: te_trTsControl.Count
	task Set_te_trTsControl_Count(input logic value);
		SetBitField(ADDR_TE_TRTSCONTROL, BITPOS_te_trTsControl_Count, value);
	endtask

	// Single-bit field: te_trTsControl.Reset
	task Set_te_trTsControl_Reset(input logic value);
		SetBitField(ADDR_TE_TRTSCONTROL, BITPOS_te_trTsControl_Reset, value);
	endtask

	// Multi-bit field: te_trTsControl.Type
	task Set_te_trTsControl_Type(input logic [2:0] value);
		SetField(ADDR_TE_TRTSCONTROL, BITPOS_te_trTsControl_Type_MSB, BITPOS_te_trTsControl_Type_LSB, value);
	endtask

	task ClearMask_te_trTsControl_Type(input logic [2:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_TE_TRTSCONTROL, reg_data);
		reg_data[BITPOS_te_trTsControl_Type_LSB +: 3] &= ~value;
		write(ADDR_TE_TRTSCONTROL, reg_data);
	endtask

	task SetMask_te_trTsControl_Type(input logic [2:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_TE_TRTSCONTROL, reg_data);
		reg_data[BITPOS_te_trTsControl_Type_LSB +: 3] |= value;
		write(ADDR_TE_TRTSCONTROL, reg_data);
	endtask

	// Multi-bit field: te_trTsControl.Prescale
	task Set_te_trTsControl_Prescale(input logic [1:0] value);
		SetField(ADDR_TE_TRTSCONTROL, BITPOS_te_trTsControl_Prescale_MSB, BITPOS_te_trTsControl_Prescale_LSB, value);
	endtask

	task ClearMask_te_trTsControl_Prescale(input logic [1:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_TE_TRTSCONTROL, reg_data);
		reg_data[BITPOS_te_trTsControl_Prescale_LSB +: 2] &= ~value;
		write(ADDR_TE_TRTSCONTROL, reg_data);
	endtask

	task SetMask_te_trTsControl_Prescale(input logic [1:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_TE_TRTSCONTROL, reg_data);
		reg_data[BITPOS_te_trTsControl_Prescale_LSB +: 2] |= value;
		write(ADDR_TE_TRTSCONTROL, reg_data);
	endtask

	// Single-bit field: te_trTsControl.Enable
	task Set_te_trTsControl_Enable(input logic value);
		SetBitField(ADDR_TE_TRTSCONTROL, BITPOS_te_trTsControl_Enable, value);
	endtask

	// Multi-bit field: te_trTsControl.Width
	task Set_te_trTsControl_Width(input logic [5:0] value);
		SetField(ADDR_TE_TRTSCONTROL, BITPOS_te_trTsControl_Width_MSB, BITPOS_te_trTsControl_Width_LSB, value);
	endtask

	task ClearMask_te_trTsControl_Width(input logic [5:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_TE_TRTSCONTROL, reg_data);
		reg_data[BITPOS_te_trTsControl_Width_LSB +: 6] &= ~value;
		write(ADDR_TE_TRTSCONTROL, reg_data);
	endtask

	task SetMask_te_trTsControl_Width(input logic [5:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_TE_TRTSCONTROL, reg_data);
		reg_data[BITPOS_te_trTsControl_Width_LSB +: 6] |= value;
		write(ADDR_TE_TRTSCONTROL, reg_data);
	endtask

	// Register: te_trTsCounterLow @ 0x0048
	task Write_te_trTsCounterLow(input logic [WB_DATA_WIDTH-1:0] data);
		write(ADDR_TE_TRTSCOUNTERLOW, data);
	endtask

	task Read_te_trTsCounterLow(output logic [WB_DATA_WIDTH-1:0] data);
		read(ADDR_TE_TRTSCOUNTERLOW, data);
	endtask

	// Multi-bit field: te_trTsCounterLow.Value
	task Set_te_trTsCounterLow_Value(input logic [31:0] value);
		SetField(ADDR_TE_TRTSCOUNTERLOW, BITPOS_te_trTsCounterLow_Value_MSB, BITPOS_te_trTsCounterLow_Value_LSB, value);
	endtask

	task ClearMask_te_trTsCounterLow_Value(input logic [31:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_TE_TRTSCOUNTERLOW, reg_data);
		reg_data[BITPOS_te_trTsCounterLow_Value_LSB +: 32] &= ~value;
		write(ADDR_TE_TRTSCOUNTERLOW, reg_data);
	endtask

	task SetMask_te_trTsCounterLow_Value(input logic [31:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_TE_TRTSCOUNTERLOW, reg_data);
		reg_data[BITPOS_te_trTsCounterLow_Value_LSB +: 32] |= value;
		write(ADDR_TE_TRTSCOUNTERLOW, reg_data);
	endtask

	// Register: te_trTsCounterHigh @ 0x004C
	task Write_te_trTsCounterHigh(input logic [WB_DATA_WIDTH-1:0] data);
		write(ADDR_TE_TRTSCOUNTERHIGH, data);
	endtask

	task Read_te_trTsCounterHigh(output logic [WB_DATA_WIDTH-1:0] data);
		read(ADDR_TE_TRTSCOUNTERHIGH, data);
	endtask

	// Multi-bit field: te_trTsCounterHigh.Value
	task Set_te_trTsCounterHigh_Value(input logic [31:0] value);
		SetField(ADDR_TE_TRTSCOUNTERHIGH, BITPOS_te_trTsCounterHigh_Value_MSB, BITPOS_te_trTsCounterHigh_Value_LSB, value);
	endtask

	task ClearMask_te_trTsCounterHigh_Value(input logic [31:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_TE_TRTSCOUNTERHIGH, reg_data);
		reg_data[BITPOS_te_trTsCounterHigh_Value_LSB +: 32] &= ~value;
		write(ADDR_TE_TRTSCOUNTERHIGH, reg_data);
	endtask

	task SetMask_te_trTsCounterHigh_Value(input logic [31:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_TE_TRTSCOUNTERHIGH, reg_data);
		reg_data[BITPOS_te_trTsCounterHigh_Value_LSB +: 32] |= value;
		write(ADDR_TE_TRTSCOUNTERHIGH, reg_data);
	endtask

	// Register array: te_trTeFilter_Control[16] @ 0x0400, stride 0x20
	// Register: te_trTeFilter_Control @ 0x0400
	task Write_te_trTeFilter_Control(input int id, input logic [WB_DATA_WIDTH-1:0] data);
		write(ADDR_TE_TRTEFILTER_CONTROL + id * 32'h00000020, data);
	endtask

	task Read_te_trTeFilter_Control(input int id, output logic [WB_DATA_WIDTH-1:0] data);
		read(ADDR_TE_TRTEFILTER_CONTROL + id * 32'h00000020, data);
	endtask

	// Single-bit field: te_trTeFilter_Control.Enable
	task Set_te_trTeFilter_Control_Enable(input int id, input logic value);
		SetBitField(ADDR_TE_TRTEFILTER_CONTROL + id * 32'h00000020, BITPOS_te_trTeFilter_Control_Enable, value);
	endtask

	// Single-bit field: te_trTeFilter_Control.MatchPrivilege
	task Set_te_trTeFilter_Control_MatchPrivilege(input int id, input logic value);
		SetBitField(ADDR_TE_TRTEFILTER_CONTROL + id * 32'h00000020, BITPOS_te_trTeFilter_Control_MatchPrivilege, value);
	endtask

	// Single-bit field: te_trTeFilter_Control.MatchEcause
	task Set_te_trTeFilter_Control_MatchEcause(input int id, input logic value);
		SetBitField(ADDR_TE_TRTEFILTER_CONTROL + id * 32'h00000020, BITPOS_te_trTeFilter_Control_MatchEcause, value);
	endtask

	// Single-bit field: te_trTeFilter_Control.MatchInterrupt
	task Set_te_trTeFilter_Control_MatchInterrupt(input int id, input logic value);
		SetBitField(ADDR_TE_TRTEFILTER_CONTROL + id * 32'h00000020, BITPOS_te_trTeFilter_Control_MatchInterrupt, value);
	endtask

	// Single-bit field: te_trTeFilter_Control.MatchComp1
	task Set_te_trTeFilter_Control_MatchComp1(input int id, input logic value);
		SetBitField(ADDR_TE_TRTEFILTER_CONTROL + id * 32'h00000020, BITPOS_te_trTeFilter_Control_MatchComp1, value);
	endtask

	// Multi-bit field: te_trTeFilter_Control.Comp1
	task Set_te_trTeFilter_Control_Comp1(input int id, input logic [2:0] value);
		SetField(ADDR_TE_TRTEFILTER_CONTROL + id * 32'h00000020, BITPOS_te_trTeFilter_Control_Comp1_MSB, BITPOS_te_trTeFilter_Control_Comp1_LSB, value);
	endtask

	task ClearMask_te_trTeFilter_Control_Comp1(input int id, input logic [2:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_TE_TRTEFILTER_CONTROL + id * 32'h00000020, reg_data);
		reg_data[BITPOS_te_trTeFilter_Control_Comp1_LSB +: 3] &= ~value;
		write(ADDR_TE_TRTEFILTER_CONTROL + id * 32'h00000020, reg_data);
	endtask

	task SetMask_te_trTeFilter_Control_Comp1(input int id, input logic [2:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_TE_TRTEFILTER_CONTROL + id * 32'h00000020, reg_data);
		reg_data[BITPOS_te_trTeFilter_Control_Comp1_LSB +: 3] |= value;
		write(ADDR_TE_TRTEFILTER_CONTROL + id * 32'h00000020, reg_data);
	endtask

	// Single-bit field: te_trTeFilter_Control.MatchComp2
	task Set_te_trTeFilter_Control_MatchComp2(input int id, input logic value);
		SetBitField(ADDR_TE_TRTEFILTER_CONTROL + id * 32'h00000020, BITPOS_te_trTeFilter_Control_MatchComp2, value);
	endtask

	// Multi-bit field: te_trTeFilter_Control.Comp2
	task Set_te_trTeFilter_Control_Comp2(input int id, input logic [2:0] value);
		SetField(ADDR_TE_TRTEFILTER_CONTROL + id * 32'h00000020, BITPOS_te_trTeFilter_Control_Comp2_MSB, BITPOS_te_trTeFilter_Control_Comp2_LSB, value);
	endtask

	task ClearMask_te_trTeFilter_Control_Comp2(input int id, input logic [2:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_TE_TRTEFILTER_CONTROL + id * 32'h00000020, reg_data);
		reg_data[BITPOS_te_trTeFilter_Control_Comp2_LSB +: 3] &= ~value;
		write(ADDR_TE_TRTEFILTER_CONTROL + id * 32'h00000020, reg_data);
	endtask

	task SetMask_te_trTeFilter_Control_Comp2(input int id, input logic [2:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_TE_TRTEFILTER_CONTROL + id * 32'h00000020, reg_data);
		reg_data[BITPOS_te_trTeFilter_Control_Comp2_LSB +: 3] |= value;
		write(ADDR_TE_TRTEFILTER_CONTROL + id * 32'h00000020, reg_data);
	endtask

	// Single-bit field: te_trTeFilter_Control.MatchComp3
	task Set_te_trTeFilter_Control_MatchComp3(input int id, input logic value);
		SetBitField(ADDR_TE_TRTEFILTER_CONTROL + id * 32'h00000020, BITPOS_te_trTeFilter_Control_MatchComp3, value);
	endtask

	// Multi-bit field: te_trTeFilter_Control.Comp3
	task Set_te_trTeFilter_Control_Comp3(input int id, input logic [2:0] value);
		SetField(ADDR_TE_TRTEFILTER_CONTROL + id * 32'h00000020, BITPOS_te_trTeFilter_Control_Comp3_MSB, BITPOS_te_trTeFilter_Control_Comp3_LSB, value);
	endtask

	task ClearMask_te_trTeFilter_Control_Comp3(input int id, input logic [2:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_TE_TRTEFILTER_CONTROL + id * 32'h00000020, reg_data);
		reg_data[BITPOS_te_trTeFilter_Control_Comp3_LSB +: 3] &= ~value;
		write(ADDR_TE_TRTEFILTER_CONTROL + id * 32'h00000020, reg_data);
	endtask

	task SetMask_te_trTeFilter_Control_Comp3(input int id, input logic [2:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_TE_TRTEFILTER_CONTROL + id * 32'h00000020, reg_data);
		reg_data[BITPOS_te_trTeFilter_Control_Comp3_LSB +: 3] |= value;
		write(ADDR_TE_TRTEFILTER_CONTROL + id * 32'h00000020, reg_data);
	endtask

	// Single-bit field: te_trTeFilter_Control.Impdef
	task Set_te_trTeFilter_Control_Impdef(input int id, input logic value);
		SetBitField(ADDR_TE_TRTEFILTER_CONTROL + id * 32'h00000020, BITPOS_te_trTeFilter_Control_Impdef, value);
	endtask

	// Single-bit field: te_trTeFilter_Control.Dtype
	task Set_te_trTeFilter_Control_Dtype(input int id, input logic value);
		SetBitField(ADDR_TE_TRTEFILTER_CONTROL + id * 32'h00000020, BITPOS_te_trTeFilter_Control_Dtype, value);
	endtask

	// Single-bit field: te_trTeFilter_Control.Dsize
	task Set_te_trTeFilter_Control_Dsize(input int id, input logic value);
		SetBitField(ADDR_TE_TRTEFILTER_CONTROL + id * 32'h00000020, BITPOS_te_trTeFilter_Control_Dsize, value);
	endtask

	// Register array: te_trTeFilter_Match[16] @ 0x0404, stride 0x20
	// Register: te_trTeFilter_Match @ 0x0404
	task Write_te_trTeFilter_Match(input int id, input logic [WB_DATA_WIDTH-1:0] data);
		write(ADDR_TE_TRTEFILTER_MATCH + id * 32'h00000020, data);
	endtask

	task Read_te_trTeFilter_Match(input int id, output logic [WB_DATA_WIDTH-1:0] data);
		read(ADDR_TE_TRTEFILTER_MATCH + id * 32'h00000020, data);
	endtask

	// Multi-bit field: te_trTeFilter_Match.ChoicePrivilege
	task Set_te_trTeFilter_Match_ChoicePrivilege(input int id, input logic [7:0] value);
		SetField(ADDR_TE_TRTEFILTER_MATCH + id * 32'h00000020, BITPOS_te_trTeFilter_Match_ChoicePrivilege_MSB, BITPOS_te_trTeFilter_Match_ChoicePrivilege_LSB, value);
	endtask

	task ClearMask_te_trTeFilter_Match_ChoicePrivilege(input int id, input logic [7:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_TE_TRTEFILTER_MATCH + id * 32'h00000020, reg_data);
		reg_data[BITPOS_te_trTeFilter_Match_ChoicePrivilege_LSB +: 8] &= ~value;
		write(ADDR_TE_TRTEFILTER_MATCH + id * 32'h00000020, reg_data);
	endtask

	task SetMask_te_trTeFilter_Match_ChoicePrivilege(input int id, input logic [7:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_TE_TRTEFILTER_MATCH + id * 32'h00000020, reg_data);
		reg_data[BITPOS_te_trTeFilter_Match_ChoicePrivilege_LSB +: 8] |= value;
		write(ADDR_TE_TRTEFILTER_MATCH + id * 32'h00000020, reg_data);
	endtask

	// Single-bit field: te_trTeFilter_Match.ValueInterrupt
	task Set_te_trTeFilter_Match_ValueInterrupt(input int id, input logic value);
		SetBitField(ADDR_TE_TRTEFILTER_MATCH + id * 32'h00000020, BITPOS_te_trTeFilter_Match_ValueInterrupt, value);
	endtask

	// Register array: te_trTeFilter_MatchChoiceEcauseLow[16] @ 0x0408, stride 0x20
	// Register: te_trTeFilter_MatchChoiceEcauseLow @ 0x0408
	task Write_te_trTeFilter_MatchChoiceEcauseLow(input int id, input logic [WB_DATA_WIDTH-1:0] data);
		write(ADDR_TE_TRTEFILTER_MATCHCHOICEECAUSELOW + id * 32'h00000020, data);
	endtask

	task Read_te_trTeFilter_MatchChoiceEcauseLow(input int id, output logic [WB_DATA_WIDTH-1:0] data);
		read(ADDR_TE_TRTEFILTER_MATCHCHOICEECAUSELOW + id * 32'h00000020, data);
	endtask

	// Multi-bit field: te_trTeFilter_MatchChoiceEcauseLow.Value
	task Set_te_trTeFilter_MatchChoiceEcauseLow_Value(input int id, input logic [31:0] value);
		SetField(ADDR_TE_TRTEFILTER_MATCHCHOICEECAUSELOW + id * 32'h00000020, BITPOS_te_trTeFilter_MatchChoiceEcauseLow_Value_MSB, BITPOS_te_trTeFilter_MatchChoiceEcauseLow_Value_LSB, value);
	endtask

	task ClearMask_te_trTeFilter_MatchChoiceEcauseLow_Value(input int id, input logic [31:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_TE_TRTEFILTER_MATCHCHOICEECAUSELOW + id * 32'h00000020, reg_data);
		reg_data[BITPOS_te_trTeFilter_MatchChoiceEcauseLow_Value_LSB +: 32] &= ~value;
		write(ADDR_TE_TRTEFILTER_MATCHCHOICEECAUSELOW + id * 32'h00000020, reg_data);
	endtask

	task SetMask_te_trTeFilter_MatchChoiceEcauseLow_Value(input int id, input logic [31:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_TE_TRTEFILTER_MATCHCHOICEECAUSELOW + id * 32'h00000020, reg_data);
		reg_data[BITPOS_te_trTeFilter_MatchChoiceEcauseLow_Value_LSB +: 32] |= value;
		write(ADDR_TE_TRTEFILTER_MATCHCHOICEECAUSELOW + id * 32'h00000020, reg_data);
	endtask

	// Register array: te_trTeFilter_MatchChoiceEcauseHigh[16] @ 0x040C, stride 0x20
	// Register: te_trTeFilter_MatchChoiceEcauseHigh @ 0x040C
	task Write_te_trTeFilter_MatchChoiceEcauseHigh(input int id, input logic [WB_DATA_WIDTH-1:0] data);
		write(ADDR_TE_TRTEFILTER_MATCHCHOICEECAUSEHIGH + id * 32'h00000020, data);
	endtask

	task Read_te_trTeFilter_MatchChoiceEcauseHigh(input int id, output logic [WB_DATA_WIDTH-1:0] data);
		read(ADDR_TE_TRTEFILTER_MATCHCHOICEECAUSEHIGH + id * 32'h00000020, data);
	endtask

	// Multi-bit field: te_trTeFilter_MatchChoiceEcauseHigh.Value
	task Set_te_trTeFilter_MatchChoiceEcauseHigh_Value(input int id, input logic [31:0] value);
		SetField(ADDR_TE_TRTEFILTER_MATCHCHOICEECAUSEHIGH + id * 32'h00000020, BITPOS_te_trTeFilter_MatchChoiceEcauseHigh_Value_MSB, BITPOS_te_trTeFilter_MatchChoiceEcauseHigh_Value_LSB, value);
	endtask

	task ClearMask_te_trTeFilter_MatchChoiceEcauseHigh_Value(input int id, input logic [31:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_TE_TRTEFILTER_MATCHCHOICEECAUSEHIGH + id * 32'h00000020, reg_data);
		reg_data[BITPOS_te_trTeFilter_MatchChoiceEcauseHigh_Value_LSB +: 32] &= ~value;
		write(ADDR_TE_TRTEFILTER_MATCHCHOICEECAUSEHIGH + id * 32'h00000020, reg_data);
	endtask

	task SetMask_te_trTeFilter_MatchChoiceEcauseHigh_Value(input int id, input logic [31:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_TE_TRTEFILTER_MATCHCHOICEECAUSEHIGH + id * 32'h00000020, reg_data);
		reg_data[BITPOS_te_trTeFilter_MatchChoiceEcauseHigh_Value_LSB +: 32] |= value;
		write(ADDR_TE_TRTEFILTER_MATCHCHOICEECAUSEHIGH + id * 32'h00000020, reg_data);
	endtask

	// Register array: te_trTeFilter_MatchValueImpdef[16] @ 0x0410, stride 0x20
	// Register: te_trTeFilter_MatchValueImpdef @ 0x0410
	task Write_te_trTeFilter_MatchValueImpdef(input int id, input logic [WB_DATA_WIDTH-1:0] data);
		write(ADDR_TE_TRTEFILTER_MATCHVALUEIMPDEF + id * 32'h00000020, data);
	endtask

	task Read_te_trTeFilter_MatchValueImpdef(input int id, output logic [WB_DATA_WIDTH-1:0] data);
		read(ADDR_TE_TRTEFILTER_MATCHVALUEIMPDEF + id * 32'h00000020, data);
	endtask

	// Multi-bit field: te_trTeFilter_MatchValueImpdef.Value
	task Set_te_trTeFilter_MatchValueImpdef_Value(input int id, input logic [31:0] value);
		SetField(ADDR_TE_TRTEFILTER_MATCHVALUEIMPDEF + id * 32'h00000020, BITPOS_te_trTeFilter_MatchValueImpdef_Value_MSB, BITPOS_te_trTeFilter_MatchValueImpdef_Value_LSB, value);
	endtask

	task ClearMask_te_trTeFilter_MatchValueImpdef_Value(input int id, input logic [31:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_TE_TRTEFILTER_MATCHVALUEIMPDEF + id * 32'h00000020, reg_data);
		reg_data[BITPOS_te_trTeFilter_MatchValueImpdef_Value_LSB +: 32] &= ~value;
		write(ADDR_TE_TRTEFILTER_MATCHVALUEIMPDEF + id * 32'h00000020, reg_data);
	endtask

	task SetMask_te_trTeFilter_MatchValueImpdef_Value(input int id, input logic [31:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_TE_TRTEFILTER_MATCHVALUEIMPDEF + id * 32'h00000020, reg_data);
		reg_data[BITPOS_te_trTeFilter_MatchValueImpdef_Value_LSB +: 32] |= value;
		write(ADDR_TE_TRTEFILTER_MATCHVALUEIMPDEF + id * 32'h00000020, reg_data);
	endtask

	// Register array: te_trTeFilter_MatchMaskImpdef[16] @ 0x0414, stride 0x20
	// Register: te_trTeFilter_MatchMaskImpdef @ 0x0414
	task Write_te_trTeFilter_MatchMaskImpdef(input int id, input logic [WB_DATA_WIDTH-1:0] data);
		write(ADDR_TE_TRTEFILTER_MATCHMASKIMPDEF + id * 32'h00000020, data);
	endtask

	task Read_te_trTeFilter_MatchMaskImpdef(input int id, output logic [WB_DATA_WIDTH-1:0] data);
		read(ADDR_TE_TRTEFILTER_MATCHMASKIMPDEF + id * 32'h00000020, data);
	endtask

	// Multi-bit field: te_trTeFilter_MatchMaskImpdef.Value
	task Set_te_trTeFilter_MatchMaskImpdef_Value(input int id, input logic [31:0] value);
		SetField(ADDR_TE_TRTEFILTER_MATCHMASKIMPDEF + id * 32'h00000020, BITPOS_te_trTeFilter_MatchMaskImpdef_Value_MSB, BITPOS_te_trTeFilter_MatchMaskImpdef_Value_LSB, value);
	endtask

	task ClearMask_te_trTeFilter_MatchMaskImpdef_Value(input int id, input logic [31:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_TE_TRTEFILTER_MATCHMASKIMPDEF + id * 32'h00000020, reg_data);
		reg_data[BITPOS_te_trTeFilter_MatchMaskImpdef_Value_LSB +: 32] &= ~value;
		write(ADDR_TE_TRTEFILTER_MATCHMASKIMPDEF + id * 32'h00000020, reg_data);
	endtask

	task SetMask_te_trTeFilter_MatchMaskImpdef_Value(input int id, input logic [31:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_TE_TRTEFILTER_MATCHMASKIMPDEF + id * 32'h00000020, reg_data);
		reg_data[BITPOS_te_trTeFilter_MatchMaskImpdef_Value_LSB +: 32] |= value;
		write(ADDR_TE_TRTEFILTER_MATCHMASKIMPDEF + id * 32'h00000020, reg_data);
	endtask

	// Register array: te_trTeFilter_MatchChoiceData[16] @ 0x0418, stride 0x20
	// Register: te_trTeFilter_MatchChoiceData @ 0x0418
	task Write_te_trTeFilter_MatchChoiceData(input int id, input logic [WB_DATA_WIDTH-1:0] data);
		write(ADDR_TE_TRTEFILTER_MATCHCHOICEDATA + id * 32'h00000020, data);
	endtask

	task Read_te_trTeFilter_MatchChoiceData(input int id, output logic [WB_DATA_WIDTH-1:0] data);
		read(ADDR_TE_TRTEFILTER_MATCHCHOICEDATA + id * 32'h00000020, data);
	endtask

	// Multi-bit field: te_trTeFilter_MatchChoiceData.Dtype
	task Set_te_trTeFilter_MatchChoiceData_Dtype(input int id, input logic [15:0] value);
		SetField(ADDR_TE_TRTEFILTER_MATCHCHOICEDATA + id * 32'h00000020, BITPOS_te_trTeFilter_MatchChoiceData_Dtype_MSB, BITPOS_te_trTeFilter_MatchChoiceData_Dtype_LSB, value);
	endtask

	task ClearMask_te_trTeFilter_MatchChoiceData_Dtype(input int id, input logic [15:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_TE_TRTEFILTER_MATCHCHOICEDATA + id * 32'h00000020, reg_data);
		reg_data[BITPOS_te_trTeFilter_MatchChoiceData_Dtype_LSB +: 16] &= ~value;
		write(ADDR_TE_TRTEFILTER_MATCHCHOICEDATA + id * 32'h00000020, reg_data);
	endtask

	task SetMask_te_trTeFilter_MatchChoiceData_Dtype(input int id, input logic [15:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_TE_TRTEFILTER_MATCHCHOICEDATA + id * 32'h00000020, reg_data);
		reg_data[BITPOS_te_trTeFilter_MatchChoiceData_Dtype_LSB +: 16] |= value;
		write(ADDR_TE_TRTEFILTER_MATCHCHOICEDATA + id * 32'h00000020, reg_data);
	endtask

	// Multi-bit field: te_trTeFilter_MatchChoiceData.Dsize
	task Set_te_trTeFilter_MatchChoiceData_Dsize(input int id, input logic [7:0] value);
		SetField(ADDR_TE_TRTEFILTER_MATCHCHOICEDATA + id * 32'h00000020, BITPOS_te_trTeFilter_MatchChoiceData_Dsize_MSB, BITPOS_te_trTeFilter_MatchChoiceData_Dsize_LSB, value);
	endtask

	task ClearMask_te_trTeFilter_MatchChoiceData_Dsize(input int id, input logic [7:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_TE_TRTEFILTER_MATCHCHOICEDATA + id * 32'h00000020, reg_data);
		reg_data[BITPOS_te_trTeFilter_MatchChoiceData_Dsize_LSB +: 8] &= ~value;
		write(ADDR_TE_TRTEFILTER_MATCHCHOICEDATA + id * 32'h00000020, reg_data);
	endtask

	task SetMask_te_trTeFilter_MatchChoiceData_Dsize(input int id, input logic [7:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_TE_TRTEFILTER_MATCHCHOICEDATA + id * 32'h00000020, reg_data);
		reg_data[BITPOS_te_trTeFilter_MatchChoiceData_Dsize_LSB +: 8] |= value;
		write(ADDR_TE_TRTEFILTER_MATCHCHOICEDATA + id * 32'h00000020, reg_data);
	endtask

	// Register array: te_trTeComp_Control[8] @ 0x0600, stride 0x20
	// Register: te_trTeComp_Control @ 0x0600
	task Write_te_trTeComp_Control(input int id, input logic [WB_DATA_WIDTH-1:0] data);
		write(ADDR_TE_TRTECOMP_CONTROL + id * 32'h00000020, data);
	endtask

	task Read_te_trTeComp_Control(input int id, output logic [WB_DATA_WIDTH-1:0] data);
		read(ADDR_TE_TRTECOMP_CONTROL + id * 32'h00000020, data);
	endtask

	// Multi-bit field: te_trTeComp_Control.PInput
	task Set_te_trTeComp_Control_PInput(input int id, input logic [1:0] value);
		SetField(ADDR_TE_TRTECOMP_CONTROL + id * 32'h00000020, BITPOS_te_trTeComp_Control_PInput_MSB, BITPOS_te_trTeComp_Control_PInput_LSB, value);
	endtask

	task ClearMask_te_trTeComp_Control_PInput(input int id, input logic [1:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_TE_TRTECOMP_CONTROL + id * 32'h00000020, reg_data);
		reg_data[BITPOS_te_trTeComp_Control_PInput_LSB +: 2] &= ~value;
		write(ADDR_TE_TRTECOMP_CONTROL + id * 32'h00000020, reg_data);
	endtask

	task SetMask_te_trTeComp_Control_PInput(input int id, input logic [1:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_TE_TRTECOMP_CONTROL + id * 32'h00000020, reg_data);
		reg_data[BITPOS_te_trTeComp_Control_PInput_LSB +: 2] |= value;
		write(ADDR_TE_TRTECOMP_CONTROL + id * 32'h00000020, reg_data);
	endtask

	// Multi-bit field: te_trTeComp_Control.SInput
	task Set_te_trTeComp_Control_SInput(input int id, input logic [1:0] value);
		SetField(ADDR_TE_TRTECOMP_CONTROL + id * 32'h00000020, BITPOS_te_trTeComp_Control_SInput_MSB, BITPOS_te_trTeComp_Control_SInput_LSB, value);
	endtask

	task ClearMask_te_trTeComp_Control_SInput(input int id, input logic [1:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_TE_TRTECOMP_CONTROL + id * 32'h00000020, reg_data);
		reg_data[BITPOS_te_trTeComp_Control_SInput_LSB +: 2] &= ~value;
		write(ADDR_TE_TRTECOMP_CONTROL + id * 32'h00000020, reg_data);
	endtask

	task SetMask_te_trTeComp_Control_SInput(input int id, input logic [1:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_TE_TRTECOMP_CONTROL + id * 32'h00000020, reg_data);
		reg_data[BITPOS_te_trTeComp_Control_SInput_LSB +: 2] |= value;
		write(ADDR_TE_TRTECOMP_CONTROL + id * 32'h00000020, reg_data);
	endtask

	// Multi-bit field: te_trTeComp_Control.PFunction
	task Set_te_trTeComp_Control_PFunction(input int id, input logic [2:0] value);
		SetField(ADDR_TE_TRTECOMP_CONTROL + id * 32'h00000020, BITPOS_te_trTeComp_Control_PFunction_MSB, BITPOS_te_trTeComp_Control_PFunction_LSB, value);
	endtask

	task ClearMask_te_trTeComp_Control_PFunction(input int id, input logic [2:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_TE_TRTECOMP_CONTROL + id * 32'h00000020, reg_data);
		reg_data[BITPOS_te_trTeComp_Control_PFunction_LSB +: 3] &= ~value;
		write(ADDR_TE_TRTECOMP_CONTROL + id * 32'h00000020, reg_data);
	endtask

	task SetMask_te_trTeComp_Control_PFunction(input int id, input logic [2:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_TE_TRTECOMP_CONTROL + id * 32'h00000020, reg_data);
		reg_data[BITPOS_te_trTeComp_Control_PFunction_LSB +: 3] |= value;
		write(ADDR_TE_TRTECOMP_CONTROL + id * 32'h00000020, reg_data);
	endtask

	// Multi-bit field: te_trTeComp_Control.SFunction
	task Set_te_trTeComp_Control_SFunction(input int id, input logic [2:0] value);
		SetField(ADDR_TE_TRTECOMP_CONTROL + id * 32'h00000020, BITPOS_te_trTeComp_Control_SFunction_MSB, BITPOS_te_trTeComp_Control_SFunction_LSB, value);
	endtask

	task ClearMask_te_trTeComp_Control_SFunction(input int id, input logic [2:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_TE_TRTECOMP_CONTROL + id * 32'h00000020, reg_data);
		reg_data[BITPOS_te_trTeComp_Control_SFunction_LSB +: 3] &= ~value;
		write(ADDR_TE_TRTECOMP_CONTROL + id * 32'h00000020, reg_data);
	endtask

	task SetMask_te_trTeComp_Control_SFunction(input int id, input logic [2:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_TE_TRTECOMP_CONTROL + id * 32'h00000020, reg_data);
		reg_data[BITPOS_te_trTeComp_Control_SFunction_LSB +: 3] |= value;
		write(ADDR_TE_TRTECOMP_CONTROL + id * 32'h00000020, reg_data);
	endtask

	// Multi-bit field: te_trTeComp_Control.MatchMode
	task Set_te_trTeComp_Control_MatchMode(input int id, input logic [1:0] value);
		SetField(ADDR_TE_TRTECOMP_CONTROL + id * 32'h00000020, BITPOS_te_trTeComp_Control_MatchMode_MSB, BITPOS_te_trTeComp_Control_MatchMode_LSB, value);
	endtask

	task ClearMask_te_trTeComp_Control_MatchMode(input int id, input logic [1:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_TE_TRTECOMP_CONTROL + id * 32'h00000020, reg_data);
		reg_data[BITPOS_te_trTeComp_Control_MatchMode_LSB +: 2] &= ~value;
		write(ADDR_TE_TRTECOMP_CONTROL + id * 32'h00000020, reg_data);
	endtask

	task SetMask_te_trTeComp_Control_MatchMode(input int id, input logic [1:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_TE_TRTECOMP_CONTROL + id * 32'h00000020, reg_data);
		reg_data[BITPOS_te_trTeComp_Control_MatchMode_LSB +: 2] |= value;
		write(ADDR_TE_TRTECOMP_CONTROL + id * 32'h00000020, reg_data);
	endtask

	// Single-bit field: te_trTeComp_Control.PNotify
	task Set_te_trTeComp_Control_PNotify(input int id, input logic value);
		SetBitField(ADDR_TE_TRTECOMP_CONTROL + id * 32'h00000020, BITPOS_te_trTeComp_Control_PNotify, value);
	endtask

	// Single-bit field: te_trTeComp_Control.SNotify
	task Set_te_trTeComp_Control_SNotify(input int id, input logic value);
		SetBitField(ADDR_TE_TRTECOMP_CONTROL + id * 32'h00000020, BITPOS_te_trTeComp_Control_SNotify, value);
	endtask

	// Register array: te_trTeComp_PMatchLow[8] @ 0x0610, stride 0x20
	// Register: te_trTeComp_PMatchLow @ 0x0610
	task Write_te_trTeComp_PMatchLow(input int id, input logic [WB_DATA_WIDTH-1:0] data);
		write(ADDR_TE_TRTECOMP_PMATCHLOW + id * 32'h00000020, data);
	endtask

	task Read_te_trTeComp_PMatchLow(input int id, output logic [WB_DATA_WIDTH-1:0] data);
		read(ADDR_TE_TRTECOMP_PMATCHLOW + id * 32'h00000020, data);
	endtask

	// Multi-bit field: te_trTeComp_PMatchLow.Value
	task Set_te_trTeComp_PMatchLow_Value(input int id, input logic [31:0] value);
		SetField(ADDR_TE_TRTECOMP_PMATCHLOW + id * 32'h00000020, BITPOS_te_trTeComp_PMatchLow_Value_MSB, BITPOS_te_trTeComp_PMatchLow_Value_LSB, value);
	endtask

	task ClearMask_te_trTeComp_PMatchLow_Value(input int id, input logic [31:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_TE_TRTECOMP_PMATCHLOW + id * 32'h00000020, reg_data);
		reg_data[BITPOS_te_trTeComp_PMatchLow_Value_LSB +: 32] &= ~value;
		write(ADDR_TE_TRTECOMP_PMATCHLOW + id * 32'h00000020, reg_data);
	endtask

	task SetMask_te_trTeComp_PMatchLow_Value(input int id, input logic [31:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_TE_TRTECOMP_PMATCHLOW + id * 32'h00000020, reg_data);
		reg_data[BITPOS_te_trTeComp_PMatchLow_Value_LSB +: 32] |= value;
		write(ADDR_TE_TRTECOMP_PMATCHLOW + id * 32'h00000020, reg_data);
	endtask

	// Register array: te_trTeComp_PMatchHigh[8] @ 0x0614, stride 0x20
	// Register: te_trTeComp_PMatchHigh @ 0x0614
	task Write_te_trTeComp_PMatchHigh(input int id, input logic [WB_DATA_WIDTH-1:0] data);
		write(ADDR_TE_TRTECOMP_PMATCHHIGH + id * 32'h00000020, data);
	endtask

	task Read_te_trTeComp_PMatchHigh(input int id, output logic [WB_DATA_WIDTH-1:0] data);
		read(ADDR_TE_TRTECOMP_PMATCHHIGH + id * 32'h00000020, data);
	endtask

	// Multi-bit field: te_trTeComp_PMatchHigh.Value
	task Set_te_trTeComp_PMatchHigh_Value(input int id, input logic [31:0] value);
		SetField(ADDR_TE_TRTECOMP_PMATCHHIGH + id * 32'h00000020, BITPOS_te_trTeComp_PMatchHigh_Value_MSB, BITPOS_te_trTeComp_PMatchHigh_Value_LSB, value);
	endtask

	task ClearMask_te_trTeComp_PMatchHigh_Value(input int id, input logic [31:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_TE_TRTECOMP_PMATCHHIGH + id * 32'h00000020, reg_data);
		reg_data[BITPOS_te_trTeComp_PMatchHigh_Value_LSB +: 32] &= ~value;
		write(ADDR_TE_TRTECOMP_PMATCHHIGH + id * 32'h00000020, reg_data);
	endtask

	task SetMask_te_trTeComp_PMatchHigh_Value(input int id, input logic [31:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_TE_TRTECOMP_PMATCHHIGH + id * 32'h00000020, reg_data);
		reg_data[BITPOS_te_trTeComp_PMatchHigh_Value_LSB +: 32] |= value;
		write(ADDR_TE_TRTECOMP_PMATCHHIGH + id * 32'h00000020, reg_data);
	endtask

	// Register array: te_trTeComp_SMatchLow[8] @ 0x0618, stride 0x20
	// Register: te_trTeComp_SMatchLow @ 0x0618
	task Write_te_trTeComp_SMatchLow(input int id, input logic [WB_DATA_WIDTH-1:0] data);
		write(ADDR_TE_TRTECOMP_SMATCHLOW + id * 32'h00000020, data);
	endtask

	task Read_te_trTeComp_SMatchLow(input int id, output logic [WB_DATA_WIDTH-1:0] data);
		read(ADDR_TE_TRTECOMP_SMATCHLOW + id * 32'h00000020, data);
	endtask

	// Multi-bit field: te_trTeComp_SMatchLow.Value
	task Set_te_trTeComp_SMatchLow_Value(input int id, input logic [31:0] value);
		SetField(ADDR_TE_TRTECOMP_SMATCHLOW + id * 32'h00000020, BITPOS_te_trTeComp_SMatchLow_Value_MSB, BITPOS_te_trTeComp_SMatchLow_Value_LSB, value);
	endtask

	task ClearMask_te_trTeComp_SMatchLow_Value(input int id, input logic [31:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_TE_TRTECOMP_SMATCHLOW + id * 32'h00000020, reg_data);
		reg_data[BITPOS_te_trTeComp_SMatchLow_Value_LSB +: 32] &= ~value;
		write(ADDR_TE_TRTECOMP_SMATCHLOW + id * 32'h00000020, reg_data);
	endtask

	task SetMask_te_trTeComp_SMatchLow_Value(input int id, input logic [31:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_TE_TRTECOMP_SMATCHLOW + id * 32'h00000020, reg_data);
		reg_data[BITPOS_te_trTeComp_SMatchLow_Value_LSB +: 32] |= value;
		write(ADDR_TE_TRTECOMP_SMATCHLOW + id * 32'h00000020, reg_data);
	endtask

	// Register array: te_trTeComp_SMatchHigh[8] @ 0x061C, stride 0x20
	// Register: te_trTeComp_SMatchHigh @ 0x061C
	task Write_te_trTeComp_SMatchHigh(input int id, input logic [WB_DATA_WIDTH-1:0] data);
		write(ADDR_TE_TRTECOMP_SMATCHHIGH + id * 32'h00000020, data);
	endtask

	task Read_te_trTeComp_SMatchHigh(input int id, output logic [WB_DATA_WIDTH-1:0] data);
		read(ADDR_TE_TRTECOMP_SMATCHHIGH + id * 32'h00000020, data);
	endtask

	// Multi-bit field: te_trTeComp_SMatchHigh.Value
	task Set_te_trTeComp_SMatchHigh_Value(input int id, input logic [31:0] value);
		SetField(ADDR_TE_TRTECOMP_SMATCHHIGH + id * 32'h00000020, BITPOS_te_trTeComp_SMatchHigh_Value_MSB, BITPOS_te_trTeComp_SMatchHigh_Value_LSB, value);
	endtask

	task ClearMask_te_trTeComp_SMatchHigh_Value(input int id, input logic [31:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_TE_TRTECOMP_SMATCHHIGH + id * 32'h00000020, reg_data);
		reg_data[BITPOS_te_trTeComp_SMatchHigh_Value_LSB +: 32] &= ~value;
		write(ADDR_TE_TRTECOMP_SMATCHHIGH + id * 32'h00000020, reg_data);
	endtask

	task SetMask_te_trTeComp_SMatchHigh_Value(input int id, input logic [31:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_TE_TRTECOMP_SMATCHHIGH + id * 32'h00000020, reg_data);
		reg_data[BITPOS_te_trTeComp_SMatchHigh_Value_LSB +: 32] |= value;
		write(ADDR_TE_TRTECOMP_SMATCHHIGH + id * 32'h00000020, reg_data);
	endtask

	// Register: te_trTeCsrControl @ 0x0E00
	task Write_te_trTeCsrControl(input logic [WB_DATA_WIDTH-1:0] data);
		write(ADDR_TE_TRTECSRCONTROL, data);
	endtask

	task Read_te_trTeCsrControl(output logic [WB_DATA_WIDTH-1:0] data);
		read(ADDR_TE_TRTECSRCONTROL, data);
	endtask

	// Single-bit field: te_trTeCsrControl.trTeCsrSendSync
	task Set_te_trTeCsrControl_trTeCsrSendSync(input logic value);
		SetBitField(ADDR_TE_TRTECSRCONTROL, BITPOS_te_trTeCsrControl_trTeCsrSendSync, value);
	endtask

	// Single-bit field: te_trTeCsrControl.trTeCsrSendPC
	task Set_te_trTeCsrControl_trTeCsrSendPC(input logic value);
		SetBitField(ADDR_TE_TRTECSRCONTROL, BITPOS_te_trTeCsrControl_trTeCsrSendPC, value);
	endtask

	// Single-bit field: te_trTeCsrControl.trTeCsrSendTS
	task Set_te_trTeCsrControl_trTeCsrSendTS(input logic value);
		SetBitField(ADDR_TE_TRTECSRCONTROL, BITPOS_te_trTeCsrControl_trTeCsrSendTS, value);
	endtask

	// Single-bit field: te_trTeCsrControl.trTeCsrSendCC
	task Set_te_trTeCsrControl_trTeCsrSendCC(input logic value);
		SetBitField(ADDR_TE_TRTECSRCONTROL, BITPOS_te_trTeCsrControl_trTeCsrSendCC, value);
	endtask

	// Register: te_trTeTipFifoStatus @ 0x0E04
	task Write_te_trTeTipFifoStatus(input logic [WB_DATA_WIDTH-1:0] data);
		write(ADDR_TE_TRTETIPFIFOSTATUS, data);
	endtask

	task Read_te_trTeTipFifoStatus(output logic [WB_DATA_WIDTH-1:0] data);
		read(ADDR_TE_TRTETIPFIFOSTATUS, data);
	endtask

	// Multi-bit field: te_trTeTipFifoStatus.trTeTipFifoMaxFill
	task Set_te_trTeTipFifoStatus_trTeTipFifoMaxFill(input logic [14:0] value);
		SetField(ADDR_TE_TRTETIPFIFOSTATUS, BITPOS_te_trTeTipFifoStatus_trTeTipFifoMaxFill_MSB, BITPOS_te_trTeTipFifoStatus_trTeTipFifoMaxFill_LSB, value);
	endtask

	task ClearMask_te_trTeTipFifoStatus_trTeTipFifoMaxFill(input logic [14:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_TE_TRTETIPFIFOSTATUS, reg_data);
		reg_data[BITPOS_te_trTeTipFifoStatus_trTeTipFifoMaxFill_LSB +: 15] &= ~value;
		write(ADDR_TE_TRTETIPFIFOSTATUS, reg_data);
	endtask

	task SetMask_te_trTeTipFifoStatus_trTeTipFifoMaxFill(input logic [14:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_TE_TRTETIPFIFOSTATUS, reg_data);
		reg_data[BITPOS_te_trTeTipFifoStatus_trTeTipFifoMaxFill_LSB +: 15] |= value;
		write(ADDR_TE_TRTETIPFIFOSTATUS, reg_data);
	endtask

	// Single-bit field: te_trTeTipFifoStatus.trTeTipFifoMaxFillClear
	task Set_te_trTeTipFifoStatus_trTeTipFifoMaxFillClear(input logic value);
		SetBitField(ADDR_TE_TRTETIPFIFOSTATUS, BITPOS_te_trTeTipFifoStatus_trTeTipFifoMaxFillClear, value);
	endtask

	// Multi-bit field: te_trTeTipFifoStatus.trTeTipFifoNumOverflows
	task Set_te_trTeTipFifoStatus_trTeTipFifoNumOverflows(input logic [14:0] value);
		SetField(ADDR_TE_TRTETIPFIFOSTATUS, BITPOS_te_trTeTipFifoStatus_trTeTipFifoNumOverflows_MSB, BITPOS_te_trTeTipFifoStatus_trTeTipFifoNumOverflows_LSB, value);
	endtask

	task ClearMask_te_trTeTipFifoStatus_trTeTipFifoNumOverflows(input logic [14:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_TE_TRTETIPFIFOSTATUS, reg_data);
		reg_data[BITPOS_te_trTeTipFifoStatus_trTeTipFifoNumOverflows_LSB +: 15] &= ~value;
		write(ADDR_TE_TRTETIPFIFOSTATUS, reg_data);
	endtask

	task SetMask_te_trTeTipFifoStatus_trTeTipFifoNumOverflows(input logic [14:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_TE_TRTETIPFIFOSTATUS, reg_data);
		reg_data[BITPOS_te_trTeTipFifoStatus_trTeTipFifoNumOverflows_LSB +: 15] |= value;
		write(ADDR_TE_TRTETIPFIFOSTATUS, reg_data);
	endtask

	// Single-bit field: te_trTeTipFifoStatus.trTeTipFifoNumOverflowsClear
	task Set_te_trTeTipFifoStatus_trTeTipFifoNumOverflowsClear(input logic value);
		SetBitField(ADDR_TE_TRTETIPFIFOSTATUS, BITPOS_te_trTeTipFifoStatus_trTeTipFifoNumOverflowsClear, value);
	endtask

	// Register: atb_trAtbBridgeControl @ 0x1000
	task Write_atb_trAtbBridgeControl(input logic [WB_DATA_WIDTH-1:0] data);
		write(ADDR_ATB_TRATBBRIDGECONTROL, data);
	endtask

	task Read_atb_trAtbBridgeControl(output logic [WB_DATA_WIDTH-1:0] data);
		read(ADDR_ATB_TRATBBRIDGECONTROL, data);
	endtask

	// Single-bit field: atb_trAtbBridgeControl.Active
	task Set_atb_trAtbBridgeControl_Active(input logic value);
		SetBitField(ADDR_ATB_TRATBBRIDGECONTROL, BITPOS_atb_trAtbBridgeControl_Active, value);
	endtask

	// Single-bit field: atb_trAtbBridgeControl.Enable
	task Set_atb_trAtbBridgeControl_Enable(input logic value);
		SetBitField(ADDR_ATB_TRATBBRIDGECONTROL, BITPOS_atb_trAtbBridgeControl_Enable, value);
	endtask

	// Single-bit field: atb_trAtbBridgeControl.Empty
	task Set_atb_trAtbBridgeControl_Empty(input logic value);
		SetBitField(ADDR_ATB_TRATBBRIDGECONTROL, BITPOS_atb_trAtbBridgeControl_Empty, value);
	endtask

	// Multi-bit field: atb_trAtbBridgeControl.ID
	task Set_atb_trAtbBridgeControl_ID(input logic [6:0] value);
		SetField(ADDR_ATB_TRATBBRIDGECONTROL, BITPOS_atb_trAtbBridgeControl_ID_MSB, BITPOS_atb_trAtbBridgeControl_ID_LSB, value);
	endtask

	task ClearMask_atb_trAtbBridgeControl_ID(input logic [6:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_ATB_TRATBBRIDGECONTROL, reg_data);
		reg_data[BITPOS_atb_trAtbBridgeControl_ID_LSB +: 7] &= ~value;
		write(ADDR_ATB_TRATBBRIDGECONTROL, reg_data);
	endtask

	task SetMask_atb_trAtbBridgeControl_ID(input logic [6:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_ATB_TRATBBRIDGECONTROL, reg_data);
		reg_data[BITPOS_atb_trAtbBridgeControl_ID_LSB +: 7] |= value;
		write(ADDR_ATB_TRATBBRIDGECONTROL, reg_data);
	endtask

	// Register: atb_trAtbBridgeImpl @ 0x1004
	task Write_atb_trAtbBridgeImpl(input logic [WB_DATA_WIDTH-1:0] data);
		write(ADDR_ATB_TRATBBRIDGEIMPL, data);
	endtask

	task Read_atb_trAtbBridgeImpl(output logic [WB_DATA_WIDTH-1:0] data);
		read(ADDR_ATB_TRATBBRIDGEIMPL, data);
	endtask

	// Multi-bit field: atb_trAtbBridgeImpl.VerMajor
	task Set_atb_trAtbBridgeImpl_VerMajor(input logic [3:0] value);
		SetField(ADDR_ATB_TRATBBRIDGEIMPL, BITPOS_atb_trAtbBridgeImpl_VerMajor_MSB, BITPOS_atb_trAtbBridgeImpl_VerMajor_LSB, value);
	endtask

	task ClearMask_atb_trAtbBridgeImpl_VerMajor(input logic [3:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_ATB_TRATBBRIDGEIMPL, reg_data);
		reg_data[BITPOS_atb_trAtbBridgeImpl_VerMajor_LSB +: 4] &= ~value;
		write(ADDR_ATB_TRATBBRIDGEIMPL, reg_data);
	endtask

	task SetMask_atb_trAtbBridgeImpl_VerMajor(input logic [3:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_ATB_TRATBBRIDGEIMPL, reg_data);
		reg_data[BITPOS_atb_trAtbBridgeImpl_VerMajor_LSB +: 4] |= value;
		write(ADDR_ATB_TRATBBRIDGEIMPL, reg_data);
	endtask

	// Multi-bit field: atb_trAtbBridgeImpl.VerMinor
	task Set_atb_trAtbBridgeImpl_VerMinor(input logic [3:0] value);
		SetField(ADDR_ATB_TRATBBRIDGEIMPL, BITPOS_atb_trAtbBridgeImpl_VerMinor_MSB, BITPOS_atb_trAtbBridgeImpl_VerMinor_LSB, value);
	endtask

	task ClearMask_atb_trAtbBridgeImpl_VerMinor(input logic [3:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_ATB_TRATBBRIDGEIMPL, reg_data);
		reg_data[BITPOS_atb_trAtbBridgeImpl_VerMinor_LSB +: 4] &= ~value;
		write(ADDR_ATB_TRATBBRIDGEIMPL, reg_data);
	endtask

	task SetMask_atb_trAtbBridgeImpl_VerMinor(input logic [3:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_ATB_TRATBBRIDGEIMPL, reg_data);
		reg_data[BITPOS_atb_trAtbBridgeImpl_VerMinor_LSB +: 4] |= value;
		write(ADDR_ATB_TRATBBRIDGEIMPL, reg_data);
	endtask

	// Multi-bit field: atb_trAtbBridgeImpl.CompType
	task Set_atb_trAtbBridgeImpl_CompType(input logic [3:0] value);
		SetField(ADDR_ATB_TRATBBRIDGEIMPL, BITPOS_atb_trAtbBridgeImpl_CompType_MSB, BITPOS_atb_trAtbBridgeImpl_CompType_LSB, value);
	endtask

	task ClearMask_atb_trAtbBridgeImpl_CompType(input logic [3:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_ATB_TRATBBRIDGEIMPL, reg_data);
		reg_data[BITPOS_atb_trAtbBridgeImpl_CompType_LSB +: 4] &= ~value;
		write(ADDR_ATB_TRATBBRIDGEIMPL, reg_data);
	endtask

	task SetMask_atb_trAtbBridgeImpl_CompType(input logic [3:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_ATB_TRATBBRIDGEIMPL, reg_data);
		reg_data[BITPOS_atb_trAtbBridgeImpl_CompType_LSB +: 4] |= value;
		write(ADDR_ATB_TRATBBRIDGEIMPL, reg_data);
	endtask

	// Multi-bit field: atb_trAtbBridgeImpl.AsyncFreq
	task Set_atb_trAtbBridgeImpl_AsyncFreq(input logic [2:0] value);
		SetField(ADDR_ATB_TRATBBRIDGEIMPL, BITPOS_atb_trAtbBridgeImpl_AsyncFreq_MSB, BITPOS_atb_trAtbBridgeImpl_AsyncFreq_LSB, value);
	endtask

	task ClearMask_atb_trAtbBridgeImpl_AsyncFreq(input logic [2:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_ATB_TRATBBRIDGEIMPL, reg_data);
		reg_data[BITPOS_atb_trAtbBridgeImpl_AsyncFreq_LSB +: 3] &= ~value;
		write(ADDR_ATB_TRATBBRIDGEIMPL, reg_data);
	endtask

	task SetMask_atb_trAtbBridgeImpl_AsyncFreq(input logic [2:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_ATB_TRATBBRIDGEIMPL, reg_data);
		reg_data[BITPOS_atb_trAtbBridgeImpl_AsyncFreq_LSB +: 3] |= value;
		write(ADDR_ATB_TRATBBRIDGEIMPL, reg_data);
	endtask

	// Register: pc_trPcControl @ 0x3000
	task Write_pc_trPcControl(input logic [WB_DATA_WIDTH-1:0] data);
		write(ADDR_PC_TRPCCONTROL, data);
	endtask

	task Read_pc_trPcControl(output logic [WB_DATA_WIDTH-1:0] data);
		read(ADDR_PC_TRPCCONTROL, data);
	endtask

	// Single-bit field: pc_trPcControl.Active
	task Set_pc_trPcControl_Active(input logic value);
		SetBitField(ADDR_PC_TRPCCONTROL, BITPOS_pc_trPcControl_Active, value);
	endtask

	// Register: pc_trPcImpl @ 0x3004
	task Write_pc_trPcImpl(input logic [WB_DATA_WIDTH-1:0] data);
		write(ADDR_PC_TRPCIMPL, data);
	endtask

	task Read_pc_trPcImpl(output logic [WB_DATA_WIDTH-1:0] data);
		read(ADDR_PC_TRPCIMPL, data);
	endtask

	// Multi-bit field: pc_trPcImpl.VerMajor
	task Set_pc_trPcImpl_VerMajor(input logic [3:0] value);
		SetField(ADDR_PC_TRPCIMPL, BITPOS_pc_trPcImpl_VerMajor_MSB, BITPOS_pc_trPcImpl_VerMajor_LSB, value);
	endtask

	task ClearMask_pc_trPcImpl_VerMajor(input logic [3:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_PC_TRPCIMPL, reg_data);
		reg_data[BITPOS_pc_trPcImpl_VerMajor_LSB +: 4] &= ~value;
		write(ADDR_PC_TRPCIMPL, reg_data);
	endtask

	task SetMask_pc_trPcImpl_VerMajor(input logic [3:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_PC_TRPCIMPL, reg_data);
		reg_data[BITPOS_pc_trPcImpl_VerMajor_LSB +: 4] |= value;
		write(ADDR_PC_TRPCIMPL, reg_data);
	endtask

	// Multi-bit field: pc_trPcImpl.VerMinor
	task Set_pc_trPcImpl_VerMinor(input logic [3:0] value);
		SetField(ADDR_PC_TRPCIMPL, BITPOS_pc_trPcImpl_VerMinor_MSB, BITPOS_pc_trPcImpl_VerMinor_LSB, value);
	endtask

	task ClearMask_pc_trPcImpl_VerMinor(input logic [3:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_PC_TRPCIMPL, reg_data);
		reg_data[BITPOS_pc_trPcImpl_VerMinor_LSB +: 4] &= ~value;
		write(ADDR_PC_TRPCIMPL, reg_data);
	endtask

	task SetMask_pc_trPcImpl_VerMinor(input logic [3:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_PC_TRPCIMPL, reg_data);
		reg_data[BITPOS_pc_trPcImpl_VerMinor_LSB +: 4] |= value;
		write(ADDR_PC_TRPCIMPL, reg_data);
	endtask

	// Multi-bit field: pc_trPcImpl.CompType
	task Set_pc_trPcImpl_CompType(input logic [3:0] value);
		SetField(ADDR_PC_TRPCIMPL, BITPOS_pc_trPcImpl_CompType_MSB, BITPOS_pc_trPcImpl_CompType_LSB, value);
	endtask

	task ClearMask_pc_trPcImpl_CompType(input logic [3:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_PC_TRPCIMPL, reg_data);
		reg_data[BITPOS_pc_trPcImpl_CompType_LSB +: 4] &= ~value;
		write(ADDR_PC_TRPCIMPL, reg_data);
	endtask

	task SetMask_pc_trPcImpl_CompType(input logic [3:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_PC_TRPCIMPL, reg_data);
		reg_data[BITPOS_pc_trPcImpl_CompType_LSB +: 4] |= value;
		write(ADDR_PC_TRPCIMPL, reg_data);
	endtask

	// Register: pc_trTeConstants @ 0x3008
	task Write_pc_trTeConstants(input logic [WB_DATA_WIDTH-1:0] data);
		write(ADDR_PC_TRTECONSTANTS, data);
	endtask

	task Read_pc_trTeConstants(output logic [WB_DATA_WIDTH-1:0] data);
		read(ADDR_PC_TRTECONSTANTS, data);
	endtask

	// Multi-bit field: pc_trTeConstants.num_trace_filter
	task Set_pc_trTeConstants_num_trace_filter(input logic [4:0] value);
		SetField(ADDR_PC_TRTECONSTANTS, BITPOS_pc_trTeConstants_num_trace_filter_MSB, BITPOS_pc_trTeConstants_num_trace_filter_LSB, value);
	endtask

	task ClearMask_pc_trTeConstants_num_trace_filter(input logic [4:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_PC_TRTECONSTANTS, reg_data);
		reg_data[BITPOS_pc_trTeConstants_num_trace_filter_LSB +: 5] &= ~value;
		write(ADDR_PC_TRTECONSTANTS, reg_data);
	endtask

	task SetMask_pc_trTeConstants_num_trace_filter(input logic [4:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_PC_TRTECONSTANTS, reg_data);
		reg_data[BITPOS_pc_trTeConstants_num_trace_filter_LSB +: 5] |= value;
		write(ADDR_PC_TRTECONSTANTS, reg_data);
	endtask

	// Multi-bit field: pc_trTeConstants.num_trace_comparators
	task Set_pc_trTeConstants_num_trace_comparators(input logic [3:0] value);
		SetField(ADDR_PC_TRTECONSTANTS, BITPOS_pc_trTeConstants_num_trace_comparators_MSB, BITPOS_pc_trTeConstants_num_trace_comparators_LSB, value);
	endtask

	task ClearMask_pc_trTeConstants_num_trace_comparators(input logic [3:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_PC_TRTECONSTANTS, reg_data);
		reg_data[BITPOS_pc_trTeConstants_num_trace_comparators_LSB +: 4] &= ~value;
		write(ADDR_PC_TRTECONSTANTS, reg_data);
	endtask

	task SetMask_pc_trTeConstants_num_trace_comparators(input logic [3:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_PC_TRTECONSTANTS, reg_data);
		reg_data[BITPOS_pc_trTeConstants_num_trace_comparators_LSB +: 4] |= value;
		write(ADDR_PC_TRTECONSTANTS, reg_data);
	endtask

	// Multi-bit field: pc_trTeConstants.num_perfcnt_ifetch_th_ranges
	task Set_pc_trTeConstants_num_perfcnt_ifetch_th_ranges(input logic [3:0] value);
		SetField(ADDR_PC_TRTECONSTANTS, BITPOS_pc_trTeConstants_num_perfcnt_ifetch_th_ranges_MSB, BITPOS_pc_trTeConstants_num_perfcnt_ifetch_th_ranges_LSB, value);
	endtask

	task ClearMask_pc_trTeConstants_num_perfcnt_ifetch_th_ranges(input logic [3:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_PC_TRTECONSTANTS, reg_data);
		reg_data[BITPOS_pc_trTeConstants_num_perfcnt_ifetch_th_ranges_LSB +: 4] &= ~value;
		write(ADDR_PC_TRTECONSTANTS, reg_data);
	endtask

	task SetMask_pc_trTeConstants_num_perfcnt_ifetch_th_ranges(input logic [3:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_PC_TRTECONSTANTS, reg_data);
		reg_data[BITPOS_pc_trTeConstants_num_perfcnt_ifetch_th_ranges_LSB +: 4] |= value;
		write(ADDR_PC_TRTECONSTANTS, reg_data);
	endtask

	// Multi-bit field: pc_trTeConstants.num_perfcnt_data_rd_th_ranges
	task Set_pc_trTeConstants_num_perfcnt_data_rd_th_ranges(input logic [3:0] value);
		SetField(ADDR_PC_TRTECONSTANTS, BITPOS_pc_trTeConstants_num_perfcnt_data_rd_th_ranges_MSB, BITPOS_pc_trTeConstants_num_perfcnt_data_rd_th_ranges_LSB, value);
	endtask

	task ClearMask_pc_trTeConstants_num_perfcnt_data_rd_th_ranges(input logic [3:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_PC_TRTECONSTANTS, reg_data);
		reg_data[BITPOS_pc_trTeConstants_num_perfcnt_data_rd_th_ranges_LSB +: 4] &= ~value;
		write(ADDR_PC_TRTECONSTANTS, reg_data);
	endtask

	task SetMask_pc_trTeConstants_num_perfcnt_data_rd_th_ranges(input logic [3:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_PC_TRTECONSTANTS, reg_data);
		reg_data[BITPOS_pc_trTeConstants_num_perfcnt_data_rd_th_ranges_LSB +: 4] |= value;
		write(ADDR_PC_TRTECONSTANTS, reg_data);
	endtask

	// Multi-bit field: pc_trTeConstants.num_perfcnt_data_rd_ranges
	task Set_pc_trTeConstants_num_perfcnt_data_rd_ranges(input logic [3:0] value);
		SetField(ADDR_PC_TRTECONSTANTS, BITPOS_pc_trTeConstants_num_perfcnt_data_rd_ranges_MSB, BITPOS_pc_trTeConstants_num_perfcnt_data_rd_ranges_LSB, value);
	endtask

	task ClearMask_pc_trTeConstants_num_perfcnt_data_rd_ranges(input logic [3:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_PC_TRTECONSTANTS, reg_data);
		reg_data[BITPOS_pc_trTeConstants_num_perfcnt_data_rd_ranges_LSB +: 4] &= ~value;
		write(ADDR_PC_TRTECONSTANTS, reg_data);
	endtask

	task SetMask_pc_trTeConstants_num_perfcnt_data_rd_ranges(input logic [3:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_PC_TRTECONSTANTS, reg_data);
		reg_data[BITPOS_pc_trTeConstants_num_perfcnt_data_rd_ranges_LSB +: 4] |= value;
		write(ADDR_PC_TRTECONSTANTS, reg_data);
	endtask

	// Multi-bit field: pc_trTeConstants.num_perfcnt_data_wr_ranges
	task Set_pc_trTeConstants_num_perfcnt_data_wr_ranges(input logic [3:0] value);
		SetField(ADDR_PC_TRTECONSTANTS, BITPOS_pc_trTeConstants_num_perfcnt_data_wr_ranges_MSB, BITPOS_pc_trTeConstants_num_perfcnt_data_wr_ranges_LSB, value);
	endtask

	task ClearMask_pc_trTeConstants_num_perfcnt_data_wr_ranges(input logic [3:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_PC_TRTECONSTANTS, reg_data);
		reg_data[BITPOS_pc_trTeConstants_num_perfcnt_data_wr_ranges_LSB +: 4] &= ~value;
		write(ADDR_PC_TRTECONSTANTS, reg_data);
	endtask

	task SetMask_pc_trTeConstants_num_perfcnt_data_wr_ranges(input logic [3:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_PC_TRTECONSTANTS, reg_data);
		reg_data[BITPOS_pc_trTeConstants_num_perfcnt_data_wr_ranges_LSB +: 4] |= value;
		write(ADDR_PC_TRTECONSTANTS, reg_data);
	endtask

	// Register: pc_trPerfCntControl @ 0x3010
	task Write_pc_trPerfCntControl(input logic [WB_DATA_WIDTH-1:0] data);
		write(ADDR_PC_TRPERFCNTCONTROL, data);
	endtask

	task Read_pc_trPerfCntControl(output logic [WB_DATA_WIDTH-1:0] data);
		read(ADDR_PC_TRPERFCNTCONTROL, data);
	endtask

	// Multi-bit field: pc_trPerfCntControl.IFetchThreshold
	task Set_pc_trPerfCntControl_IFetchThreshold(input logic [7:0] value);
		SetField(ADDR_PC_TRPERFCNTCONTROL, BITPOS_pc_trPerfCntControl_IFetchThreshold_MSB, BITPOS_pc_trPerfCntControl_IFetchThreshold_LSB, value);
	endtask

	task ClearMask_pc_trPerfCntControl_IFetchThreshold(input logic [7:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_PC_TRPERFCNTCONTROL, reg_data);
		reg_data[BITPOS_pc_trPerfCntControl_IFetchThreshold_LSB +: 8] &= ~value;
		write(ADDR_PC_TRPERFCNTCONTROL, reg_data);
	endtask

	task SetMask_pc_trPerfCntControl_IFetchThreshold(input logic [7:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_PC_TRPERFCNTCONTROL, reg_data);
		reg_data[BITPOS_pc_trPerfCntControl_IFetchThreshold_LSB +: 8] |= value;
		write(ADDR_PC_TRPERFCNTCONTROL, reg_data);
	endtask

	// Multi-bit field: pc_trPerfCntControl.DataWrThreshold
	task Set_pc_trPerfCntControl_DataWrThreshold(input logic [7:0] value);
		SetField(ADDR_PC_TRPERFCNTCONTROL, BITPOS_pc_trPerfCntControl_DataWrThreshold_MSB, BITPOS_pc_trPerfCntControl_DataWrThreshold_LSB, value);
	endtask

	task ClearMask_pc_trPerfCntControl_DataWrThreshold(input logic [7:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_PC_TRPERFCNTCONTROL, reg_data);
		reg_data[BITPOS_pc_trPerfCntControl_DataWrThreshold_LSB +: 8] &= ~value;
		write(ADDR_PC_TRPERFCNTCONTROL, reg_data);
	endtask

	task SetMask_pc_trPerfCntControl_DataWrThreshold(input logic [7:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_PC_TRPERFCNTCONTROL, reg_data);
		reg_data[BITPOS_pc_trPerfCntControl_DataWrThreshold_LSB +: 8] |= value;
		write(ADDR_PC_TRPERFCNTCONTROL, reg_data);
	endtask

	// Register array: pc_trTePerfCntIFetchRange_Low[3] @ 0x3100, stride 0x8
	// Register: pc_trTePerfCntIFetchRange_Low @ 0x3100
	task Write_pc_trTePerfCntIFetchRange_Low(input int id, input logic [WB_DATA_WIDTH-1:0] data);
		write(ADDR_PC_TRTEPERFCNTIFETCHRANGE_LOW + id * 32'h00000008, data);
	endtask

	task Read_pc_trTePerfCntIFetchRange_Low(input int id, output logic [WB_DATA_WIDTH-1:0] data);
		read(ADDR_PC_TRTEPERFCNTIFETCHRANGE_LOW + id * 32'h00000008, data);
	endtask

	// Multi-bit field: pc_trTePerfCntIFetchRange_Low.Value
	task Set_pc_trTePerfCntIFetchRange_Low_Value(input int id, input logic [31:0] value);
		SetField(ADDR_PC_TRTEPERFCNTIFETCHRANGE_LOW + id * 32'h00000008, BITPOS_pc_trTePerfCntIFetchRange_Low_Value_MSB, BITPOS_pc_trTePerfCntIFetchRange_Low_Value_LSB, value);
	endtask

	task ClearMask_pc_trTePerfCntIFetchRange_Low_Value(input int id, input logic [31:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_PC_TRTEPERFCNTIFETCHRANGE_LOW + id * 32'h00000008, reg_data);
		reg_data[BITPOS_pc_trTePerfCntIFetchRange_Low_Value_LSB +: 32] &= ~value;
		write(ADDR_PC_TRTEPERFCNTIFETCHRANGE_LOW + id * 32'h00000008, reg_data);
	endtask

	task SetMask_pc_trTePerfCntIFetchRange_Low_Value(input int id, input logic [31:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_PC_TRTEPERFCNTIFETCHRANGE_LOW + id * 32'h00000008, reg_data);
		reg_data[BITPOS_pc_trTePerfCntIFetchRange_Low_Value_LSB +: 32] |= value;
		write(ADDR_PC_TRTEPERFCNTIFETCHRANGE_LOW + id * 32'h00000008, reg_data);
	endtask

	// Register array: pc_trTePerfCntIFetchRange_High[3] @ 0x3104, stride 0x8
	// Register: pc_trTePerfCntIFetchRange_High @ 0x3104
	task Write_pc_trTePerfCntIFetchRange_High(input int id, input logic [WB_DATA_WIDTH-1:0] data);
		write(ADDR_PC_TRTEPERFCNTIFETCHRANGE_HIGH + id * 32'h00000008, data);
	endtask

	task Read_pc_trTePerfCntIFetchRange_High(input int id, output logic [WB_DATA_WIDTH-1:0] data);
		read(ADDR_PC_TRTEPERFCNTIFETCHRANGE_HIGH + id * 32'h00000008, data);
	endtask

	// Multi-bit field: pc_trTePerfCntIFetchRange_High.Value
	task Set_pc_trTePerfCntIFetchRange_High_Value(input int id, input logic [31:0] value);
		SetField(ADDR_PC_TRTEPERFCNTIFETCHRANGE_HIGH + id * 32'h00000008, BITPOS_pc_trTePerfCntIFetchRange_High_Value_MSB, BITPOS_pc_trTePerfCntIFetchRange_High_Value_LSB, value);
	endtask

	task ClearMask_pc_trTePerfCntIFetchRange_High_Value(input int id, input logic [31:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_PC_TRTEPERFCNTIFETCHRANGE_HIGH + id * 32'h00000008, reg_data);
		reg_data[BITPOS_pc_trTePerfCntIFetchRange_High_Value_LSB +: 32] &= ~value;
		write(ADDR_PC_TRTEPERFCNTIFETCHRANGE_HIGH + id * 32'h00000008, reg_data);
	endtask

	task SetMask_pc_trTePerfCntIFetchRange_High_Value(input int id, input logic [31:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_PC_TRTEPERFCNTIFETCHRANGE_HIGH + id * 32'h00000008, reg_data);
		reg_data[BITPOS_pc_trTePerfCntIFetchRange_High_Value_LSB +: 32] |= value;
		write(ADDR_PC_TRTEPERFCNTIFETCHRANGE_HIGH + id * 32'h00000008, reg_data);
	endtask

	// Register array: pc_trTePerfCntDataRdThRange_Low[3] @ 0x3200, stride 0x8
	// Register: pc_trTePerfCntDataRdThRange_Low @ 0x3200
	task Write_pc_trTePerfCntDataRdThRange_Low(input int id, input logic [WB_DATA_WIDTH-1:0] data);
		write(ADDR_PC_TRTEPERFCNTDATARDTHRANGE_LOW + id * 32'h00000008, data);
	endtask

	task Read_pc_trTePerfCntDataRdThRange_Low(input int id, output logic [WB_DATA_WIDTH-1:0] data);
		read(ADDR_PC_TRTEPERFCNTDATARDTHRANGE_LOW + id * 32'h00000008, data);
	endtask

	// Multi-bit field: pc_trTePerfCntDataRdThRange_Low.Value
	task Set_pc_trTePerfCntDataRdThRange_Low_Value(input int id, input logic [31:0] value);
		SetField(ADDR_PC_TRTEPERFCNTDATARDTHRANGE_LOW + id * 32'h00000008, BITPOS_pc_trTePerfCntDataRdThRange_Low_Value_MSB, BITPOS_pc_trTePerfCntDataRdThRange_Low_Value_LSB, value);
	endtask

	task ClearMask_pc_trTePerfCntDataRdThRange_Low_Value(input int id, input logic [31:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_PC_TRTEPERFCNTDATARDTHRANGE_LOW + id * 32'h00000008, reg_data);
		reg_data[BITPOS_pc_trTePerfCntDataRdThRange_Low_Value_LSB +: 32] &= ~value;
		write(ADDR_PC_TRTEPERFCNTDATARDTHRANGE_LOW + id * 32'h00000008, reg_data);
	endtask

	task SetMask_pc_trTePerfCntDataRdThRange_Low_Value(input int id, input logic [31:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_PC_TRTEPERFCNTDATARDTHRANGE_LOW + id * 32'h00000008, reg_data);
		reg_data[BITPOS_pc_trTePerfCntDataRdThRange_Low_Value_LSB +: 32] |= value;
		write(ADDR_PC_TRTEPERFCNTDATARDTHRANGE_LOW + id * 32'h00000008, reg_data);
	endtask

	// Register array: pc_trTePerfCntDataRdThRange_High[3] @ 0x3204, stride 0x8
	// Register: pc_trTePerfCntDataRdThRange_High @ 0x3204
	task Write_pc_trTePerfCntDataRdThRange_High(input int id, input logic [WB_DATA_WIDTH-1:0] data);
		write(ADDR_PC_TRTEPERFCNTDATARDTHRANGE_HIGH + id * 32'h00000008, data);
	endtask

	task Read_pc_trTePerfCntDataRdThRange_High(input int id, output logic [WB_DATA_WIDTH-1:0] data);
		read(ADDR_PC_TRTEPERFCNTDATARDTHRANGE_HIGH + id * 32'h00000008, data);
	endtask

	// Multi-bit field: pc_trTePerfCntDataRdThRange_High.Value
	task Set_pc_trTePerfCntDataRdThRange_High_Value(input int id, input logic [31:0] value);
		SetField(ADDR_PC_TRTEPERFCNTDATARDTHRANGE_HIGH + id * 32'h00000008, BITPOS_pc_trTePerfCntDataRdThRange_High_Value_MSB, BITPOS_pc_trTePerfCntDataRdThRange_High_Value_LSB, value);
	endtask

	task ClearMask_pc_trTePerfCntDataRdThRange_High_Value(input int id, input logic [31:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_PC_TRTEPERFCNTDATARDTHRANGE_HIGH + id * 32'h00000008, reg_data);
		reg_data[BITPOS_pc_trTePerfCntDataRdThRange_High_Value_LSB +: 32] &= ~value;
		write(ADDR_PC_TRTEPERFCNTDATARDTHRANGE_HIGH + id * 32'h00000008, reg_data);
	endtask

	task SetMask_pc_trTePerfCntDataRdThRange_High_Value(input int id, input logic [31:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_PC_TRTEPERFCNTDATARDTHRANGE_HIGH + id * 32'h00000008, reg_data);
		reg_data[BITPOS_pc_trTePerfCntDataRdThRange_High_Value_LSB +: 32] |= value;
		write(ADDR_PC_TRTEPERFCNTDATARDTHRANGE_HIGH + id * 32'h00000008, reg_data);
	endtask

	// Register array: pc_trTePerfCntDataRdRange_Low[7] @ 0x3300, stride 0x8
	// Register: pc_trTePerfCntDataRdRange_Low @ 0x3300
	task Write_pc_trTePerfCntDataRdRange_Low(input int id, input logic [WB_DATA_WIDTH-1:0] data);
		write(ADDR_PC_TRTEPERFCNTDATARDRANGE_LOW + id * 32'h00000008, data);
	endtask

	task Read_pc_trTePerfCntDataRdRange_Low(input int id, output logic [WB_DATA_WIDTH-1:0] data);
		read(ADDR_PC_TRTEPERFCNTDATARDRANGE_LOW + id * 32'h00000008, data);
	endtask

	// Multi-bit field: pc_trTePerfCntDataRdRange_Low.Value
	task Set_pc_trTePerfCntDataRdRange_Low_Value(input int id, input logic [31:0] value);
		SetField(ADDR_PC_TRTEPERFCNTDATARDRANGE_LOW + id * 32'h00000008, BITPOS_pc_trTePerfCntDataRdRange_Low_Value_MSB, BITPOS_pc_trTePerfCntDataRdRange_Low_Value_LSB, value);
	endtask

	task ClearMask_pc_trTePerfCntDataRdRange_Low_Value(input int id, input logic [31:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_PC_TRTEPERFCNTDATARDRANGE_LOW + id * 32'h00000008, reg_data);
		reg_data[BITPOS_pc_trTePerfCntDataRdRange_Low_Value_LSB +: 32] &= ~value;
		write(ADDR_PC_TRTEPERFCNTDATARDRANGE_LOW + id * 32'h00000008, reg_data);
	endtask

	task SetMask_pc_trTePerfCntDataRdRange_Low_Value(input int id, input logic [31:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_PC_TRTEPERFCNTDATARDRANGE_LOW + id * 32'h00000008, reg_data);
		reg_data[BITPOS_pc_trTePerfCntDataRdRange_Low_Value_LSB +: 32] |= value;
		write(ADDR_PC_TRTEPERFCNTDATARDRANGE_LOW + id * 32'h00000008, reg_data);
	endtask

	// Register array: pc_trTePerfCntDataRdRange_High[7] @ 0x3304, stride 0x8
	// Register: pc_trTePerfCntDataRdRange_High @ 0x3304
	task Write_pc_trTePerfCntDataRdRange_High(input int id, input logic [WB_DATA_WIDTH-1:0] data);
		write(ADDR_PC_TRTEPERFCNTDATARDRANGE_HIGH + id * 32'h00000008, data);
	endtask

	task Read_pc_trTePerfCntDataRdRange_High(input int id, output logic [WB_DATA_WIDTH-1:0] data);
		read(ADDR_PC_TRTEPERFCNTDATARDRANGE_HIGH + id * 32'h00000008, data);
	endtask

	// Multi-bit field: pc_trTePerfCntDataRdRange_High.Value
	task Set_pc_trTePerfCntDataRdRange_High_Value(input int id, input logic [31:0] value);
		SetField(ADDR_PC_TRTEPERFCNTDATARDRANGE_HIGH + id * 32'h00000008, BITPOS_pc_trTePerfCntDataRdRange_High_Value_MSB, BITPOS_pc_trTePerfCntDataRdRange_High_Value_LSB, value);
	endtask

	task ClearMask_pc_trTePerfCntDataRdRange_High_Value(input int id, input logic [31:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_PC_TRTEPERFCNTDATARDRANGE_HIGH + id * 32'h00000008, reg_data);
		reg_data[BITPOS_pc_trTePerfCntDataRdRange_High_Value_LSB +: 32] &= ~value;
		write(ADDR_PC_TRTEPERFCNTDATARDRANGE_HIGH + id * 32'h00000008, reg_data);
	endtask

	task SetMask_pc_trTePerfCntDataRdRange_High_Value(input int id, input logic [31:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_PC_TRTEPERFCNTDATARDRANGE_HIGH + id * 32'h00000008, reg_data);
		reg_data[BITPOS_pc_trTePerfCntDataRdRange_High_Value_LSB +: 32] |= value;
		write(ADDR_PC_TRTEPERFCNTDATARDRANGE_HIGH + id * 32'h00000008, reg_data);
	endtask

	// Register array: pc_trTePerfCntDataWrRange_Low[7] @ 0x3400, stride 0x8
	// Register: pc_trTePerfCntDataWrRange_Low @ 0x3400
	task Write_pc_trTePerfCntDataWrRange_Low(input int id, input logic [WB_DATA_WIDTH-1:0] data);
		write(ADDR_PC_TRTEPERFCNTDATAWRRANGE_LOW + id * 32'h00000008, data);
	endtask

	task Read_pc_trTePerfCntDataWrRange_Low(input int id, output logic [WB_DATA_WIDTH-1:0] data);
		read(ADDR_PC_TRTEPERFCNTDATAWRRANGE_LOW + id * 32'h00000008, data);
	endtask

	// Multi-bit field: pc_trTePerfCntDataWrRange_Low.Value
	task Set_pc_trTePerfCntDataWrRange_Low_Value(input int id, input logic [31:0] value);
		SetField(ADDR_PC_TRTEPERFCNTDATAWRRANGE_LOW + id * 32'h00000008, BITPOS_pc_trTePerfCntDataWrRange_Low_Value_MSB, BITPOS_pc_trTePerfCntDataWrRange_Low_Value_LSB, value);
	endtask

	task ClearMask_pc_trTePerfCntDataWrRange_Low_Value(input int id, input logic [31:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_PC_TRTEPERFCNTDATAWRRANGE_LOW + id * 32'h00000008, reg_data);
		reg_data[BITPOS_pc_trTePerfCntDataWrRange_Low_Value_LSB +: 32] &= ~value;
		write(ADDR_PC_TRTEPERFCNTDATAWRRANGE_LOW + id * 32'h00000008, reg_data);
	endtask

	task SetMask_pc_trTePerfCntDataWrRange_Low_Value(input int id, input logic [31:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_PC_TRTEPERFCNTDATAWRRANGE_LOW + id * 32'h00000008, reg_data);
		reg_data[BITPOS_pc_trTePerfCntDataWrRange_Low_Value_LSB +: 32] |= value;
		write(ADDR_PC_TRTEPERFCNTDATAWRRANGE_LOW + id * 32'h00000008, reg_data);
	endtask

	// Register array: pc_trTePerfCntDataWrRange_High[7] @ 0x3404, stride 0x8
	// Register: pc_trTePerfCntDataWrRange_High @ 0x3404
	task Write_pc_trTePerfCntDataWrRange_High(input int id, input logic [WB_DATA_WIDTH-1:0] data);
		write(ADDR_PC_TRTEPERFCNTDATAWRRANGE_HIGH + id * 32'h00000008, data);
	endtask

	task Read_pc_trTePerfCntDataWrRange_High(input int id, output logic [WB_DATA_WIDTH-1:0] data);
		read(ADDR_PC_TRTEPERFCNTDATAWRRANGE_HIGH + id * 32'h00000008, data);
	endtask

	// Multi-bit field: pc_trTePerfCntDataWrRange_High.Value
	task Set_pc_trTePerfCntDataWrRange_High_Value(input int id, input logic [31:0] value);
		SetField(ADDR_PC_TRTEPERFCNTDATAWRRANGE_HIGH + id * 32'h00000008, BITPOS_pc_trTePerfCntDataWrRange_High_Value_MSB, BITPOS_pc_trTePerfCntDataWrRange_High_Value_LSB, value);
	endtask

	task ClearMask_pc_trTePerfCntDataWrRange_High_Value(input int id, input logic [31:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_PC_TRTEPERFCNTDATAWRRANGE_HIGH + id * 32'h00000008, reg_data);
		reg_data[BITPOS_pc_trTePerfCntDataWrRange_High_Value_LSB +: 32] &= ~value;
		write(ADDR_PC_TRTEPERFCNTDATAWRRANGE_HIGH + id * 32'h00000008, reg_data);
	endtask

	task SetMask_pc_trTePerfCntDataWrRange_High_Value(input int id, input logic [31:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_PC_TRTEPERFCNTDATAWRRANGE_HIGH + id * 32'h00000008, reg_data);
		reg_data[BITPOS_pc_trTePerfCntDataWrRange_High_Value_LSB +: 32] |= value;
		write(ADDR_PC_TRTEPERFCNTDATAWRRANGE_HIGH + id * 32'h00000008, reg_data);
	endtask

	// Register: trWpControl @ 0x4000
	task Write_trWpControl(input logic [WB_DATA_WIDTH-1:0] data);
		write(ADDR_TRWPCONTROL, data);
	endtask

	task Read_trWpControl(output logic [WB_DATA_WIDTH-1:0] data);
		read(ADDR_TRWPCONTROL, data);
	endtask

	// Single-bit field: trWpControl.Active
	task Set_trWpControl_Active(input logic value);
		SetBitField(ADDR_TRWPCONTROL, BITPOS_trWpControl_Active, value);
	endtask

	// Register: trWpImpl @ 0x4004
	task Write_trWpImpl(input logic [WB_DATA_WIDTH-1:0] data);
		write(ADDR_TRWPIMPL, data);
	endtask

	task Read_trWpImpl(output logic [WB_DATA_WIDTH-1:0] data);
		read(ADDR_TRWPIMPL, data);
	endtask

	// Multi-bit field: trWpImpl.VerMajor
	task Set_trWpImpl_VerMajor(input logic [3:0] value);
		SetField(ADDR_TRWPIMPL, BITPOS_trWpImpl_VerMajor_MSB, BITPOS_trWpImpl_VerMajor_LSB, value);
	endtask

	task ClearMask_trWpImpl_VerMajor(input logic [3:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_TRWPIMPL, reg_data);
		reg_data[BITPOS_trWpImpl_VerMajor_LSB +: 4] &= ~value;
		write(ADDR_TRWPIMPL, reg_data);
	endtask

	task SetMask_trWpImpl_VerMajor(input logic [3:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_TRWPIMPL, reg_data);
		reg_data[BITPOS_trWpImpl_VerMajor_LSB +: 4] |= value;
		write(ADDR_TRWPIMPL, reg_data);
	endtask

	// Multi-bit field: trWpImpl.VerMinor
	task Set_trWpImpl_VerMinor(input logic [3:0] value);
		SetField(ADDR_TRWPIMPL, BITPOS_trWpImpl_VerMinor_MSB, BITPOS_trWpImpl_VerMinor_LSB, value);
	endtask

	task ClearMask_trWpImpl_VerMinor(input logic [3:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_TRWPIMPL, reg_data);
		reg_data[BITPOS_trWpImpl_VerMinor_LSB +: 4] &= ~value;
		write(ADDR_TRWPIMPL, reg_data);
	endtask

	task SetMask_trWpImpl_VerMinor(input logic [3:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_TRWPIMPL, reg_data);
		reg_data[BITPOS_trWpImpl_VerMinor_LSB +: 4] |= value;
		write(ADDR_TRWPIMPL, reg_data);
	endtask

	// Multi-bit field: trWpImpl.CompType
	task Set_trWpImpl_CompType(input logic [3:0] value);
		SetField(ADDR_TRWPIMPL, BITPOS_trWpImpl_CompType_MSB, BITPOS_trWpImpl_CompType_LSB, value);
	endtask

	task ClearMask_trWpImpl_CompType(input logic [3:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_TRWPIMPL, reg_data);
		reg_data[BITPOS_trWpImpl_CompType_LSB +: 4] &= ~value;
		write(ADDR_TRWPIMPL, reg_data);
	endtask

	task SetMask_trWpImpl_CompType(input logic [3:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_TRWPIMPL, reg_data);
		reg_data[BITPOS_trWpImpl_CompType_LSB +: 4] |= value;
		write(ADDR_TRWPIMPL, reg_data);
	endtask

	// Register: Addr @ 0x4100
	task Write_Addr(input logic [WB_DATA_WIDTH-1:0] data);
		write(ADDR_ADDR, data);
	endtask

	task Read_Addr(output logic [WB_DATA_WIDTH-1:0] data);
		read(ADDR_ADDR, data);
	endtask

	// Multi-bit field: Addr.Value
	task Set_Addr_Value(input logic [31:0] value);
		SetField(ADDR_ADDR, BITPOS_Addr_Value_MSB, BITPOS_Addr_Value_LSB, value);
	endtask

	task ClearMask_Addr_Value(input logic [31:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_ADDR, reg_data);
		reg_data[BITPOS_Addr_Value_LSB +: 32] &= ~value;
		write(ADDR_ADDR, reg_data);
	endtask

	task SetMask_Addr_Value(input logic [31:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_ADDR, reg_data);
		reg_data[BITPOS_Addr_Value_LSB +: 32] |= value;
		write(ADDR_ADDR, reg_data);
	endtask

	// Register: Cmd @ 0x4104
	task Write_Cmd(input logic [WB_DATA_WIDTH-1:0] data);
		write(ADDR_CMD, data);
	endtask

	task Read_Cmd(output logic [WB_DATA_WIDTH-1:0] data);
		read(ADDR_CMD, data);
	endtask

	// Multi-bit field: Cmd.Cmd
	task Set_Cmd_Cmd(input logic [5:0] value);
		SetField(ADDR_CMD, BITPOS_Cmd_Cmd_MSB, BITPOS_Cmd_Cmd_LSB, value);
	endtask

	task ClearMask_Cmd_Cmd(input logic [5:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_CMD, reg_data);
		reg_data[BITPOS_Cmd_Cmd_LSB +: 6] &= ~value;
		write(ADDR_CMD, reg_data);
	endtask

	task SetMask_Cmd_Cmd(input logic [5:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_CMD, reg_data);
		reg_data[BITPOS_Cmd_Cmd_LSB +: 6] |= value;
		write(ADDR_CMD, reg_data);
	endtask

	// Multi-bit field: Cmd.Sink
	task Set_Cmd_Sink(input logic [1:0] value);
		SetField(ADDR_CMD, BITPOS_Cmd_Sink_MSB, BITPOS_Cmd_Sink_LSB, value);
	endtask

	task ClearMask_Cmd_Sink(input logic [1:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_CMD, reg_data);
		reg_data[BITPOS_Cmd_Sink_LSB +: 2] &= ~value;
		write(ADDR_CMD, reg_data);
	endtask

	task SetMask_Cmd_Sink(input logic [1:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_CMD, reg_data);
		reg_data[BITPOS_Cmd_Sink_LSB +: 2] |= value;
		write(ADDR_CMD, reg_data);
	endtask

	// Multi-bit field: Cmd.DirectData
	task Set_Cmd_DirectData(input logic [23:0] value);
		SetField(ADDR_CMD, BITPOS_Cmd_DirectData_MSB, BITPOS_Cmd_DirectData_LSB, value);
	endtask

	task ClearMask_Cmd_DirectData(input logic [23:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_CMD, reg_data);
		reg_data[BITPOS_Cmd_DirectData_LSB +: 24] &= ~value;
		write(ADDR_CMD, reg_data);
	endtask

	task SetMask_Cmd_DirectData(input logic [23:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_CMD, reg_data);
		reg_data[BITPOS_Cmd_DirectData_LSB +: 24] |= value;
		write(ADDR_CMD, reg_data);
	endtask

	// Register: trDfControl @ 0x5000
	task Write_trDfControl(input logic [WB_DATA_WIDTH-1:0] data);
		write(ADDR_TRDFCONTROL, data);
	endtask

	task Read_trDfControl(output logic [WB_DATA_WIDTH-1:0] data);
		read(ADDR_TRDFCONTROL, data);
	endtask

	// Single-bit field: trDfControl.Active
	task Set_trDfControl_Active(input logic value);
		SetBitField(ADDR_TRDFCONTROL, BITPOS_trDfControl_Active, value);
	endtask

	// Register: trDfImpl @ 0x5004
	task Write_trDfImpl(input logic [WB_DATA_WIDTH-1:0] data);
		write(ADDR_TRDFIMPL, data);
	endtask

	task Read_trDfImpl(output logic [WB_DATA_WIDTH-1:0] data);
		read(ADDR_TRDFIMPL, data);
	endtask

	// Multi-bit field: trDfImpl.VerMajor
	task Set_trDfImpl_VerMajor(input logic [3:0] value);
		SetField(ADDR_TRDFIMPL, BITPOS_trDfImpl_VerMajor_MSB, BITPOS_trDfImpl_VerMajor_LSB, value);
	endtask

	task ClearMask_trDfImpl_VerMajor(input logic [3:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_TRDFIMPL, reg_data);
		reg_data[BITPOS_trDfImpl_VerMajor_LSB +: 4] &= ~value;
		write(ADDR_TRDFIMPL, reg_data);
	endtask

	task SetMask_trDfImpl_VerMajor(input logic [3:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_TRDFIMPL, reg_data);
		reg_data[BITPOS_trDfImpl_VerMajor_LSB +: 4] |= value;
		write(ADDR_TRDFIMPL, reg_data);
	endtask

	// Multi-bit field: trDfImpl.VerMinor
	task Set_trDfImpl_VerMinor(input logic [3:0] value);
		SetField(ADDR_TRDFIMPL, BITPOS_trDfImpl_VerMinor_MSB, BITPOS_trDfImpl_VerMinor_LSB, value);
	endtask

	task ClearMask_trDfImpl_VerMinor(input logic [3:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_TRDFIMPL, reg_data);
		reg_data[BITPOS_trDfImpl_VerMinor_LSB +: 4] &= ~value;
		write(ADDR_TRDFIMPL, reg_data);
	endtask

	task SetMask_trDfImpl_VerMinor(input logic [3:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_TRDFIMPL, reg_data);
		reg_data[BITPOS_trDfImpl_VerMinor_LSB +: 4] |= value;
		write(ADDR_TRDFIMPL, reg_data);
	endtask

	// Multi-bit field: trDfImpl.CompType
	task Set_trDfImpl_CompType(input logic [3:0] value);
		SetField(ADDR_TRDFIMPL, BITPOS_trDfImpl_CompType_MSB, BITPOS_trDfImpl_CompType_LSB, value);
	endtask

	task ClearMask_trDfImpl_CompType(input logic [3:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_TRDFIMPL, reg_data);
		reg_data[BITPOS_trDfImpl_CompType_LSB +: 4] &= ~value;
		write(ADDR_TRDFIMPL, reg_data);
	endtask

	task SetMask_trDfImpl_CompType(input logic [3:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_TRDFIMPL, reg_data);
		reg_data[BITPOS_trDfImpl_CompType_LSB +: 4] |= value;
		write(ADDR_TRDFIMPL, reg_data);
	endtask

	// Register: Key0 @ 0x6000
	task Write_Key0(input logic [WB_DATA_WIDTH-1:0] data);
		write(ADDR_KEY0, data);
	endtask

	task Read_Key0(output logic [WB_DATA_WIDTH-1:0] data);
		read(ADDR_KEY0, data);
	endtask

	// Multi-bit field: Key0.Value
	task Set_Key0_Value(input logic [31:0] value);
		SetField(ADDR_KEY0, BITPOS_Key0_Value_MSB, BITPOS_Key0_Value_LSB, value);
	endtask

	task ClearMask_Key0_Value(input logic [31:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_KEY0, reg_data);
		reg_data[BITPOS_Key0_Value_LSB +: 32] &= ~value;
		write(ADDR_KEY0, reg_data);
	endtask

	task SetMask_Key0_Value(input logic [31:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_KEY0, reg_data);
		reg_data[BITPOS_Key0_Value_LSB +: 32] |= value;
		write(ADDR_KEY0, reg_data);
	endtask

	// Register: Key1 @ 0x6004
	task Write_Key1(input logic [WB_DATA_WIDTH-1:0] data);
		write(ADDR_KEY1, data);
	endtask

	task Read_Key1(output logic [WB_DATA_WIDTH-1:0] data);
		read(ADDR_KEY1, data);
	endtask

	// Multi-bit field: Key1.Value
	task Set_Key1_Value(input logic [31:0] value);
		SetField(ADDR_KEY1, BITPOS_Key1_Value_MSB, BITPOS_Key1_Value_LSB, value);
	endtask

	task ClearMask_Key1_Value(input logic [31:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_KEY1, reg_data);
		reg_data[BITPOS_Key1_Value_LSB +: 32] &= ~value;
		write(ADDR_KEY1, reg_data);
	endtask

	task SetMask_Key1_Value(input logic [31:0] value);
		logic [WB_DATA_WIDTH-1:0] reg_data;
		read(ADDR_KEY1, reg_data);
		reg_data[BITPOS_Key1_Value_LSB +: 32] |= value;
		write(ADDR_KEY1, reg_data);
	endtask

	// ========================================================================
	// Memory Access Tasks (external mem)
	// ========================================================================

	// Memory: Watchpoints_Memory_ACT_ST @ 0x4100
	task Write_Watchpoints_Memory_ACT_ST(input int index, input logic [63:0] data);
		for (int word_idx = 0; word_idx < 2; word_idx++) begin
			write(ADDR_WATCHPOINTS_MEMORY_ACT_ST + index * 8 + word_idx * (WB_DATA_WIDTH/8),
				data[word_idx * WB_DATA_WIDTH +: WB_DATA_WIDTH]);
		end
	endtask

	task Read_Watchpoints_Memory_ACT_ST(input int index, output logic [63:0] data);
		logic [WB_DATA_WIDTH-1:0] word_data;
		data = '0;
		for (int word_idx = 0; word_idx < 2; word_idx++) begin
			read(ADDR_WATCHPOINTS_MEMORY_ACT_ST + index * 8 + word_idx * (WB_DATA_WIDTH/8), word_data);
			data[word_idx * WB_DATA_WIDTH +: WB_DATA_WIDTH] = word_data;
		end
	endtask

	task ClearMask_Watchpoints_Memory_ACT_ST(input int index, input logic [63:0] mask);
		logic [63:0] entry;
		Read_Watchpoints_Memory_ACT_ST(index, entry);
		entry &= ~mask;
		Write_Watchpoints_Memory_ACT_ST(index, entry);
	endtask

	task SetMask_Watchpoints_Memory_ACT_ST(input int index, input logic [63:0] mask);
		logic [63:0] entry;
		Read_Watchpoints_Memory_ACT_ST(index, entry);
		entry |= mask;
		Write_Watchpoints_Memory_ACT_ST(index, entry);
	endtask

	// Memory: DF_RangeFilter_Memory @ 0x6000
	task Write_DF_RangeFilter_Memory(input int index, input logic [63:0] data);
		for (int word_idx = 0; word_idx < 2; word_idx++) begin
			write(ADDR_DF_RANGEFILTER_MEMORY + index * 8 + word_idx * (WB_DATA_WIDTH/8),
				data[word_idx * WB_DATA_WIDTH +: WB_DATA_WIDTH]);
		end
	endtask

	task Read_DF_RangeFilter_Memory(input int index, output logic [63:0] data);
		logic [WB_DATA_WIDTH-1:0] word_data;
		data = '0;
		for (int word_idx = 0; word_idx < 2; word_idx++) begin
			read(ADDR_DF_RANGEFILTER_MEMORY + index * 8 + word_idx * (WB_DATA_WIDTH/8), word_data);
			data[word_idx * WB_DATA_WIDTH +: WB_DATA_WIDTH] = word_data;
		end
	endtask

	task ClearMask_DF_RangeFilter_Memory(input int index, input logic [63:0] mask);
		logic [63:0] entry;
		Read_DF_RangeFilter_Memory(index, entry);
		entry &= ~mask;
		Write_DF_RangeFilter_Memory(index, entry);
	endtask

	task SetMask_DF_RangeFilter_Memory(input int index, input logic [63:0] mask);
		logic [63:0] entry;
		Read_DF_RangeFilter_Memory(index, entry);
		entry |= mask;
		Write_DF_RangeFilter_Memory(index, entry);
	endtask

endmodule
