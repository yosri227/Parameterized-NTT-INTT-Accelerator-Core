// =============================================================================
// twiddle_rom.sv
// Twiddle-factor storage for the constant-geometry (Pease) NTT/INTT engine.
//
// Because the Pease butterfly at stage s only ever needs the twiddle
// omega^e where e = bitrev(i[s-1:0], s) * 2^(LOGN-1-s), the full twiddle
// requirement collapses to exactly N/2 *distinct* values across all stages
// (proven by exhaustive check against the Kyber parameter set: N/2 = 64
// distinct exponents, exactly filling the addresses 0..N/2-1). So a single
// compact ROM of depth N/2 covers every stage - no per-stage tables and no
// large N-deep ROM are needed.
//
// Two logical planes are stored:
//   - FWD plane : omega^e     mod Q   (used by the CT / forward NTT)
//   - INV plane : omega^{-e}  mod Q   (used by the GS / inverse NTT)
// The INV plane is the numeric "recomputation" of the FWD plane requested
// in the spec: rather than doing a runtime modular-inverse multiply (which
// would need an extra multiplier and Fermat-exponentiation hardware), the
// precomputed inverse values are stored at the *same address* as their
// forward counterpart, so the control unit's stage-index address generator
// (see ru_addr_gen.sv) drives both planes identically and only the mode
// signal (FWD/INV) selects which plane is read. This keeps the address
// generator itself the "recomputation" logic while avoiding a runtime
// inverter.
//
// The ROM is duplicated into two *dedicated* read ports (rd_a / rd_b) that
// share the same underlying constant table, so both dual Butterfly Units can
// fetch a twiddle in the same cycle with no port conflict.
// =============================================================================
module twiddle_rom #(
  parameter int unsigned Q     = ntt_pkg::Q,
  parameter int unsigned W     = ntt_pkg::W,
  parameter int unsigned N     = ntt_pkg::N,
  parameter int unsigned DEPTH = N/2,
  parameter int unsigned AW    = $clog2(DEPTH),
  parameter string       FWD_HEX = "twiddle_fwd.hex",
  parameter string       INV_HEX = "twiddle_inv.hex"
)(
  input  logic                 clk,
  input  ntt_pkg::ntt_mode_e   mode,

  input  logic [AW-1:0]        addr_a,
  output logic [W-1:0]         tw_a,

  input  logic [AW-1:0]        addr_b,
  output logic [W-1:0]         tw_b
);

  logic [W-1:0] fwd_mem [0:DEPTH-1];
  logic [W-1:0] inv_mem [0:DEPTH-1];

  initial begin
    $readmemh(FWD_HEX, fwd_mem);
    $readmemh(INV_HEX, inv_mem);
  end

  always_comb begin
    tw_a = (mode == ntt_pkg::MODE_FWD) ? fwd_mem[addr_a] : inv_mem[addr_a];
    tw_b = (mode == ntt_pkg::MODE_FWD) ? fwd_mem[addr_b] : inv_mem[addr_b];
  end

endmodule : twiddle_rom
