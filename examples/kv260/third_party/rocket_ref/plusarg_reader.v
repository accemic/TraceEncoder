// SPDX-FileCopyrightText: 2016-2017 SiFive, Inc.
// SPDX-License-Identifier: Apache-2.0
//
// Vendored, unmodified, from the pinned `vivado-risc-v`/rocket-chip source
// tree (see ../ROCKET_PIN.md for the exact commit pins and generation
// recipe) -- the sole FIRRTL blackbox the RocketSystem generat needs.
// Third-party upstream code, NOT Accemic IP: see LICENSE.SiFive in this
// pinned tree (Apache License 2.0) for the full license text, referenced
// by the original file header below. Migrated from
// an internal predecessor repository (2026-08-17) -- required build input for both
// examples/kv260/rocket_linux/ and examples/kv260/rocket2/, hence vendored
// here rather than duplicated into either example's own tree (see
// ROCKET_PIN.md's note on this file's shared-dependency status).

// See LICENSE.SiFive for license details.

//VCS coverage exclude_file

// No default parameter values are intended, nor does IEEE 1800-2012 require them (clause A.2.4 param_assignment),
// but Incisive demands them. These default values should never be used.
module plusarg_reader #(
   parameter FORMAT="borked=%d",
   parameter WIDTH=1,
   parameter [WIDTH-1:0] DEFAULT=0
) (
   output [WIDTH-1:0] out
);

`ifdef SYNTHESIS
assign out = DEFAULT;
`else
reg [WIDTH-1:0] myplus;
assign out = myplus;

initial begin
   if (!$value$plusargs(FORMAT, myplus)) myplus = DEFAULT;
end
`endif

endmodule
