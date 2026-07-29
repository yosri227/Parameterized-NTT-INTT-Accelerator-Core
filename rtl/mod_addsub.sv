// =============================================================================
// mod_addsub.sv
// Single-cycle modular add and modular subtract, conditional-subtract style
// (operands are assumed already reduced, i.e. in [0, Q)).
// =============================================================================
module mod_add #(
  parameter int unsigned Q = ntt_pkg::Q,
  parameter int unsigned W = ntt_pkg::W
)(
  input  logic [W-1:0] a,
  input  logic [W-1:0] b,
  output logic [W-1:0] sum
);
  logic [W:0] s;
  logic [W:0] sum_full;
  always_comb begin
    s        = {1'b0, a} + {1'b0, b};
    sum_full = (s >= Q[W:0]) ? (s - Q[W:0]) : s;
    sum      = sum_full[W-1:0];
  end
endmodule : mod_add

module mod_sub #(
  parameter int unsigned Q = ntt_pkg::Q,
  parameter int unsigned W = ntt_pkg::W
)(
  input  logic [W-1:0] a,
  input  logic [W-1:0] b,
  output logic [W-1:0] diff
);
  logic signed [W:0] d;
  logic [W:0] d_full;
  always_comb begin
    d      = signed'({1'b0, a}) - signed'({1'b0, b});
    d_full = (d < 0) ? (d + Q[W:0]) : unsigned'(d);
    diff   = d_full[W-1:0];
  end
endmodule : mod_sub
