// SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-Accemic-Commercial

// ============================================================================
// Auto-generated SystemVerilog types package
// Rebuilds the enum + struct typedefs of ispresent=false registers that
// PeakRDL-regblock drops from ct_cs_cpuif_pkg.sv. Generated from the same
// RDL source — keep in sync by rerunning .gitutils/generate_wb_pkg.py.
// DO NOT EDIT MANUALLY - Changes will be overwritten!
// ============================================================================

package ct_cs_cpuif_types_pkg;

    // Enumerations
    // ========================================================================
    typedef enum logic [3:0] {
        ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_NONE = 'h0,
        ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_DAQ_PC_CURR = 'h1,
        ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_DAQ_PC_CURR_LAST = 'h2,
        ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_DAQ_DIRECT_DATA = 'h3,
        ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_DAQ_DATA = 'h4,
        ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_DAQ_DADDR = 'h5,
        ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_DAQ_DATA_DADDR = 'h6,
        ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_DAQ_IFETCH_TH = 'h8,
        ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_DAQ_DATA_RD_TH = 'h9,
        ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_DAQ_DATA_WR = 'ha,
        ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_DAQ_DATA_RD = 'hb,
        ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_CF_SYNC = 'hc,
        ct_cs_cpuif__trActCapStCmd_e__ACT_CAP_ST_TE = 'hd
    } ct_cs_cpuif__trActCapStCmd_e_e;

    typedef enum logic [1:0] {
        ct_cs_cpuif__trActCapStSink_e__ACT_CAP_ST_SINK_NEXUS = 'h0,
        ct_cs_cpuif__trActCapStSink_e__ACT_CAP_ST_SINK_AXIS = 'h1,
        ct_cs_cpuif__trActCapStSink_e__ACT_CAP_ST_SINK_AXIS_NEXUS = 'h2,
        ct_cs_cpuif__trActCapStSink_e__ACT_CAP_ST_SINK_TE = 'h3
    } ct_cs_cpuif__trActCapStSink_e_e;

    // Field sub-structs and composite register structs
    // ========================================================================
    typedef struct {
        logic [5:0] value;
    } ct_cs_cpuif__trActCapStCmd__Cmd__out_t;

    typedef struct {
        logic [1:0] value;
    } ct_cs_cpuif__trActCapStCmd__Sink__out_t;

    typedef struct {
        logic [23:0] value;
    } ct_cs_cpuif__trActCapStCmd__DirectData__out_t;

    typedef struct {
        ct_cs_cpuif__trActCapStCmd__Cmd__out_t Cmd;
        ct_cs_cpuif__trActCapStCmd__Sink__out_t Sink;
        ct_cs_cpuif__trActCapStCmd__DirectData__out_t DirectData;
    } ct_cs_cpuif__trActCapStCmd__out_t;

endpackage
