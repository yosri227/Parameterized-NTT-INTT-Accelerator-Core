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
// With PIPELINE=1 the wide Barrett reduction sits behind its own register
// stage instead of hanging combinationally off the multiplier, giving a
// balanced two-stage pipe:
//   stage A: operand select + multiply        -> regs (product, a, b, mode, valid)
//   stage B: Barrett reduction                -> regs (t, a, b, mode, valid)
//   stage C: final add/sub + output mux (combinational)
// Total latency is 2 cycles when pipelined, 0 when combinational;
// ntt_top matches its write-back address/valid delay to this.
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

  // ---- Stage A (combinational): operand select, mod-sub for GS path ----
  logic [W-1:0] amb;              // (a - b) mod Q, needed by GS
  logic [W-1:0] mul_operand;
  logic [MULW-1:0] product;

  mod_sub #(.Q(Q), .W(W)) u_amb (.a(a_in), .b(b_in), .diff(amb));

  always_comb begin
    mul_operand = (mode == ntt_pkg::MODE_FWD) ? b_in : amb;
    product     = mul_operand * w_in;
  end

  logic [MULW-1:0] sa_product;
  logic [W-1:0]    sa_a, sa_b;
  ntt_pkg::ntt_mode_e sa_mode;
  logic            sa_valid;

  generate
    if (PIPELINE) begin : g_reg_a
      always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
          sa_product <= '0;
          sa_a       <= '0;
          sa_b       <= '0;
          sa_mode    <= ntt_pkg::MODE_FWD;
          sa_valid   <= 1'b0;
        end else begin
          sa_product <= product;
          sa_a       <= a_in;
          sa_b       <= b_in;
          sa_mode    <= mode;
          sa_valid   <= valid_in;
        end
      end
    end else begin : g_comb_a
      always_comb begin
        sa_product = product;
        sa_a       = a_in;
        sa_b       = b_in;
        sa_mode    = mode;
        sa_valid   = valid_in;
      end
    end
  endgenerate

  // ---- Stage B: Barrett reduction of the registered product ----
  logic [W-1:0] sb_t;
  barrett_reduce #(.Q(Q), .W(W), .MULW(MULW), .MU(MU)) u_barrett (
    .in_val(sa_product),
    .out_val(sb_t)
  );

  logic [W-1:0] sb_t_r, sb_a, sb_b;
  ntt_pkg::ntt_mode_e sb_mode;
  logic         sb_valid;

  generate
    if (PIPELINE) begin : g_reg_b
      always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
          sb_t_r   <= '0;
          sb_a     <= '0;
          sb_b     <= '0;
          sb_mode  <= ntt_pkg::MODE_FWD;
          sb_valid <= 1'b0;
        end else begin
          sb_t_r   <= sb_t;
          sb_a     <= sa_a;
          sb_b     <= sa_b;
          sb_mode  <= sa_mode;
          sb_valid <= sa_valid;
        end
      end
    end else begin : g_comb_b
      always_comb begin
        sb_t_r   = sb_t;
        sb_a     = sa_a;
        sb_b     = sa_b;
        sb_mode  = sa_mode;
        sb_valid = sa_valid;
      end
    end
  endgenerate

  // ---- Stage C (combinational): final combine, mode-dependent output mux ----
  logic [W-1:0] apt, amt, apb;
  mod_add #(.Q(Q), .W(W)) u_apt (.a(sb_a), .b(sb_t_r), .sum(apt));
  mod_sub #(.Q(Q), .W(W)) u_amt (.a(sb_a), .b(sb_t_r), .diff(amt));
  mod_add #(.Q(Q), .W(W)) u_apb (.a(sb_a), .b(sb_b),   .sum(apb));

  always_comb begin
    if (sb_mode == ntt_pkg::MODE_FWD) begin
      y0_out = apt;
      y1_out = amt;
    end else begin
      y0_out = apb;
      y1_out = sb_t_r;
    end
  end

  assign valid_out = sb_valid;

endmodule : butterfly_unit
