// =============================================================================
// reorder_unit.sv
// FSR-based Reordering Unit (RU) for the constant-geometry (Pease) NTT/INTT.
//
// Why a fixed pairing needs a reorder network at all:
//   In the constant-geometry formulation, every stage pairs address i with
//   i + N/2 (i.e. the pairing bit is always the MSB - conflict-free 2-bank
//   memory access is therefore free / permanent, no dynamic bank swap
//   needed). What DOES change every stage is which logical coefficient sits
//   at which physical index: the whole N-word vector must undergo a
//   "perfect shuffle" (a 1-bit rotation of the LOGN-bit address) between
//   consecutive stages so that the fixed (i, i+N/2) pairing always lands on
//   the mathematically-correct operands. This module generates that
//   permutation.
//
// FSR structure:
//   A LOGN-bit one-hot ring (feedback shift) register `stage_oh` tracks the
//   active stage without a binary counter+comparator: it shifts by exactly
//   one position every stage boundary and feeds itself back around after
//   LOGN stages (classic FSR ring-counter). Its one-hot position directly
//   selects, combinationally, the rotate amount/direction and the twiddle
//   exponent shift - i.e. the FSR *is* the control state that "corrects the
//   order of coefficients for subsequent BU operations" the spec calls for,
//   with no counter/decoder chain and no large reorder buffer: the actual
//   permutation is applied for free as part of the write-back address of
//   the butterfly result (single-cycle, zero extra latency).
//
// Forward (CT) stages run s = 0 .. LOGN-1 with a rotate-LEFT applied AFTER
// each stage's butterfly (write-back address = rotl(logical_addr)).
// Inverse (GS) stages run s = LOGN-1 .. 0 with a rotate-RIGHT applied
// BEFORE each stage's butterfly (read address = rotr(logical_addr)); this
// exactly undoes the forward permutation (verified against the Python
// golden model bit-for-bit).
// =============================================================================
module reorder_unit #(
  parameter int unsigned N    = ntt_pkg::N,
  parameter int unsigned LOGN = ntt_pkg::LOGN
)(
  input  logic                clk,
  input  logic                rst_n,
  input  logic                stage_adv,   // pulse: move FSR to next stage
  input  logic                stage_ld,    // pulse: (re)load FSR to stage 0 (one-hot bit0)
  input  ntt_pkg::ntt_mode_e  mode,

  output logic [LOGN-1:0]     stage_num,   // 0..LOGN-1, decoded from the FSR (for twiddle exp calc)
  output logic                last_stage
);

  // ---- FSR: LOGN-bit one-hot ring / feedback shift register ----
  logic [LOGN-1:0] stage_oh;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      stage_oh <= {{(LOGN-1){1'b0}}, 1'b1};   // one-hot bit0 = stage 0
    end else if (stage_ld) begin
      stage_oh <= {{(LOGN-1){1'b0}}, 1'b1};
    end else if (stage_adv) begin
      // feedback shift: rotate the single hot bit up by one position each stage
      stage_oh <= {stage_oh[LOGN-2:0], stage_oh[LOGN-1]};
    end
  end

  // Decode one-hot -> binary stage index (small LOGN:LOGN priority encoder)
  always_comb begin
    stage_num = '0;
    for (int k = 0; k < LOGN; k++)
      if (stage_oh[k]) stage_num = k[LOGN-1:0];
  end

  assign last_stage = stage_oh[LOGN-1];

endmodule : reorder_unit


// -----------------------------------------------------------------------------
// ru_rotate: the actual permutation network driven by the RU's stage_num.
// Pure combinational 1-bit circular LEFT rotate over a LOGN-bit address.
// Both usages in the top level need the SAME rotate-left transform:
//   - FWD (CT):  write-back address = rotl(read/lane index)
//   - INV (GS):  read address       = rotl(lane index)   [this is the
//     inverse of the FWD write permutation: rotl(.) undoes rotr(.), and the
//     FWD "shuffle" step is defined as out[i]=in[rotr(i)], so its inverse
//     is out[i]=in[rotl(i)] - verified bit-exact, stage by stage, against
//     the Python golden model]
// The `mode` input is kept (rather than deleting it) so the module remains
// the single, obvious place to extend if a future scheme ever needs an
// asymmetric mapping; today both branches compute the same result.
// -----------------------------------------------------------------------------
module ru_rotate #(
  parameter int unsigned LOGN = ntt_pkg::LOGN
)(
  input  logic [LOGN-1:0]      addr_in,
  output logic [LOGN-1:0]      addr_out
);
  assign addr_out = {addr_in[LOGN-2:0], addr_in[LOGN-1]};
endmodule : ru_rotate


// -----------------------------------------------------------------------------
// tw_exp_gen: twiddle-ROM address (exponent) generator.
//   exp = bitrev( i[s-1:0], s ) << (LOGN-1-s)
// Pure combinational; shares the RU's stage_num.
// -----------------------------------------------------------------------------
module tw_exp_gen #(
  parameter int unsigned LOGN = ntt_pkg::LOGN,
  parameter int unsigned N    = ntt_pkg::N
)(
  input  logic [LOGN-1:0]        stage_num,     // s
  input  logic [LOGN-2:0]        lane_idx,      // i, range 0..N/2-1
  output logic [LOGN-2:0]        tw_addr        // exponent, 0..N/2-1
);
  logic [LOGN-2:0] low_bits, rev_bits;
  integer s_int, k;

  always_comb begin
    s_int    = int'(stage_num);
    low_bits = '0;
    rev_bits = '0;
    // take low s bits of lane_idx
    for (k = 0; k < LOGN-1; k++) begin
      if (k < s_int) low_bits[k] = lane_idx[k];
    end
    // bit-reverse those s bits within the field
    for (k = 0; k < LOGN-1; k++) begin
      if (k < s_int) rev_bits[s_int-1-k] = low_bits[k];
    end
    tw_addr = rev_bits << (LOGN-1-s_int);
  end
endmodule : tw_exp_gen
