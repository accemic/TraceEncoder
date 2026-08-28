# SPDX-FileCopyrightText: 2026 Accemic Technologies GmbH
# SPDX-License-Identifier: ISC
#
# Constraints for the AXIS watchpoint testbed (tgc5b2_kv260_top, KV260).
#
# Documented empty until T2 (no-pin case). Since T2 the top exposes the PIB
# parallel trace port -- pinout taken VERBATIM from the pattern already used
# in this repository's duo example (examples/kv260/duo/fpga/duo_pib_pmod.xdc,
# itself migrated from the predecessor repository's duo_pib_pmod.xdc; KV260 carrier PMOD J2,
# positionally compatible with the KR260 reference adapter, derivation +
# Digilent position table there):
#   pib_clk     TRC_CLK      HDA11    H12
#   pib_data[0] TRC_DATA[0]  HDA12    E10
#   pib_data[1] TRC_DATA[1]  HDA15    B10
#   pib_data[2] TRC_DATA[2]  HDA16_CC E12
#   pib_data[3] TRC_DATA[3]  HDA17    D11
#
# Remaining points unchanged:
#   - Clock constraint: pl_clk0 = 75 MHz comes from the PS XCI
#     (ct_soc_kv260_ps, gen_ip.tcl) -- nothing to duplicate here.
#   - One clock domain, no CDC constraints needed; the encoder's module-local
#     CDC XDCs are not part of this project flow (abc_filelist.py only
#     resolves .sv sources).

set_property PACKAGE_PIN H12 [get_ports pib_clk]
set_property PACKAGE_PIN E10 [get_ports {pib_data[0]}]
set_property PACKAGE_PIN B10 [get_ports {pib_data[1]}]
set_property PACKAGE_PIN E12 [get_ports {pib_data[2]}]
set_property PACKAGE_PIN D11 [get_ports {pib_data[3]}]

set_property IOSTANDARD LVCMOS33 [get_ports {pib_clk pib_data[*]}]
set_property SLEW FAST [get_ports {pib_clk pib_data[*]}]
set_property DRIVE 8 [get_ports {pib_clk pib_data[*]}]

# pib_clk is a divided register output (max clk/4 = 18.75 MHz), data toggles
# on the opposite half period -> no forwarded-clock analysis needed; keep the
# ports out of default timing analysis (duo pattern).
set_false_path -to [get_ports {pib_clk pib_data[*]}]
