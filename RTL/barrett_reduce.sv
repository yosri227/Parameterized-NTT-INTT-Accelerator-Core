// =============================================================================
// barrett_reduce.sv
// Combinational Barrett modular reduction: out = in_val mod Q, for
// 0 <= in_val < Q^2 (i.e. in_val is the W-bit x W-bit product of a butterfly
// multiply).
//
//   q_est = floor( (in_val * mu) / 2^MULW )        mu = floor(2^MULW / Q)
//   r     = in_val - q_est * Q
//   r     = (r >= Q) ? r - Q : r        (this mu has >=2 guard bits, so at
//   r     = (r >= Q) ? r - Q : r         most two trial subtractions suffice)
//
// All intermediate arithmetic is kept at full (un-truncated) precision until
// the final result is known to be small, which is what makes Barrett
// reduction correct -- truncating operands before the subtraction is a
// classic implementation bug and is deliberately avoided here.
// =============================================================================
module barrett_reduce #(
  parameter int unsigned Q      = ntt_pkg::Q,
  parameter int unsigned W      = ntt_pkg::W,
  parameter int unsigned MULW   = ntt_pkg::MULW,
  parameter longint unsigned MU = ntt_pkg::BARRETT_MU
)(
  input  logic [MULW-1:0] in_val,   // product to be reduced (< Q^2)
  output logic [W-1:0]    out_val   // result in [0, Q)
);

  localparam int unsigned MU_W   = MULW + 2;              // width needed for mu
  localparam int unsigned PRODW  = MULW + MU_W;            // in_val*mu, full width
  localparam int unsigned QXQW   = (MULW + 2) + W;         // q_est*Q, full width
  localparam int unsigned SUBW   = QXQW + 1;                // safe subtraction width

  logic [PRODW-1:0] mu_prod;
  logic [MULW+1:0]  q_est;
  logic [QXQW-1:0]  q_est_x_q;
  logic [SUBW-1:0]  in_ext, qxq_ext, r0;
  logic [W:0]       r1;
  logic [W-1:0]     r2;

  always_comb begin
    mu_prod   = in_val * MU;                 // full-precision product
    q_est     = mu_prod >> MULW;             // floor divide by 2^MULW
    q_est_x_q = q_est * Q;                   // full-precision product

    in_ext  = {{(SUBW-MULW){1'b0}}, in_val};
    qxq_ext = {{(SUBW-QXQW){1'b0}}, q_est_x_q};
    r0      = in_ext - qxq_ext;              // guaranteed small & non-negative

    r1 = r0[W:0];
    if (r1 >= Q[W:0]) r1 = r1 - Q[W:0];
    r2 = r1[W-1:0];
    if (r2 >= Q[W-1:0]) r2 = r2 - Q[W-1:0];

    out_val = r2;
  end

endmodule : barrett_reduce
