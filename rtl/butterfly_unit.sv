// =============================================================================
// butterfly_unit.sv
// Unified radix-2 Butterfly Unit (BU).
//
//   CT (Cooley-Tukey, decimation-in-time)  -> used for forward NTT
//       t  = (b * w) mod Q
//       y0 = (a + t) mod Q
//       y1 = (a - t) mod Q
//
//   GS (Gentleman-Sande, decimation-in-freq) -> used for inverse NTT
//       y0 = (a + b) mod Q
//       t  = ((a - b) * w) mod Q
//       y1 = t
//
// A single multiplier + Barrett reducer + adder/subtractor is time-shared
// between both structures by muxing the multiplier operand and the final
// output selection on `mode`:
//
//       mul_operand = (mode==FWD) ? b        : (a - b) mod Q
//       t           = (mul_operand * w) mod Q
//       y0          = (mode==FWD) ? (a + t)  : (a + b)
//       y1          = (mode==FWD) ? (a - t)  : t
//
// One pipeline register is inserted between the multiply/Barrett stage and
// the final add/sub stage (PIPELINE=1, default) for timing closure; set
// PIPELINE=0 for a fully combinational (single-cycle) unit.
// =============================================================================
module butterfly_unit #(
  parameter int unsigned Q        = ntt_pkg::Q,
  parameter int unsigned W        = ntt_pkg::W,
  parameter int unsigned MULW     = ntt_pkg::MULW,
  parameter longint unsigned MU   = ntt_pkg::BARRETT_MU,
  parameter bit          PIPELINE = 1'b1
)(
  input  logic                    clk,
  input  logic                    rst_n,
  input  logic                    valid_in,
  input  ntt_pkg::ntt_mode_e      mode,       // MODE_FWD = CT, MODE_INV = GS
  input  logic [W-1:0]            a_in,
  input  logic [W-1:0]            b_in,
  input  logic [W-1:0]            w_in,       // twiddle factor
  output logic [W-1:0]            y0_out,
  output logic [W-1:0]            y1_out,
  output logic                    valid_out
);

  // ---- Stage 0 (combinational): operand select, mod-sub for GS path ----
  logic [W-1:0] amb;              // (a - b) mod Q, needed by GS
  logic [W-1:0] mul_operand;
  logic [MULW-1:0] product;

  mod_sub #(.Q(Q), .W(W)) u_amb (.a(a_in), .b(b_in), .diff(amb));

  always_comb begin
    mul_operand = (mode == ntt_pkg::MODE_FWD) ? b_in : amb;
    product     = mul_operand * w_in;
  end

  logic [MULW-1:0] product_r;
  logic [W-1:0]    a_r, b_r;
  ntt_pkg::ntt_mode_e mode_r;
  logic             valid_r;

  generate
    if (PIPELINE) begin : g_pipe
      always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
          product_r <= '0;
          a_r       <= '0;
          b_r       <= '0;
          mode_r    <= ntt_pkg::MODE_FWD;
          valid_r   <= 1'b0;
        end else begin
          product_r <= product;
          a_r       <= a_in;
          b_r       <= b_in;
          mode_r    <= mode;
          valid_r   <= valid_in;
        end
      end
    end else begin : g_nopipe
      always_comb begin
        product_r = product;
        a_r       = a_in;
        b_r       = b_in;
        mode_r    = mode;
        valid_r   = valid_in;
      end
    end
  endgenerate

  // ---- Stage 1: Barrett reduction of the product ----
  logic [W-1:0] t_val;
  barrett_reduce #(.Q(Q), .W(W), .MULW(MULW), .MU(MU)) u_barrett (
    .in_val(product_r),
    .out_val(t_val)
  );

  // ---- Stage 2 (combinational): final combine, mode-dependent output mux ----
  logic [W-1:0] apt, amt, apb;
  mod_add #(.Q(Q), .W(W)) u_apt (.a(a_r), .b(t_val), .sum(apt));
  mod_sub #(.Q(Q), .W(W)) u_amt (.a(a_r), .b(t_val), .diff(amt));
  mod_add #(.Q(Q), .W(W)) u_apb (.a(a_r), .b(b_r),   .sum(apb));

  always_comb begin
    if (mode_r == ntt_pkg::MODE_FWD) begin
      y0_out = apt;
      y1_out = amt;
    end else begin
      y0_out = apb;
      y1_out = t_val;
    end
  end

  assign valid_out = valid_r;

endmodule : butterfly_unit
