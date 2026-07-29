// =============================================================================
// ntt_pkg.sv
// Parameter package for the unified NTT/INTT accelerator.
//
// Supports Kyber (ML-KEM), Dilithium (ML-DSA) and Falcon by parameter choice.
// Only Q and N are scheme-specific; every other quantity (W, MULW, Barrett mu,
// primitive root, LOGN, ...) is derived so the datapath is fully generic.
//
// IMPORTANT NUMBER-THEORETIC CONSTRAINT
// A full (complete) radix-2 N-point NTT requires a primitive 2N-th root of
// unity mod Q, i.e. 2N | (Q-1).
//   - Kyber      : Q = 3329,    Q-1 = 3328 = 2^8 * 13   -> max complete N = 128
//                  (this is why the real ML-KEM spec itself only performs a
//                   128-point/7-stage NTT and finishes pairs of coefficients
//                   with a base multiplication step - this core reproduces
//                   that exactly for SCHEME=KYBER, N=128).
//   - Dilithium  : Q = 8380417, Q-1 = 8380416 = 2^13*1021 -> complete N=256 OK
//   - Falcon     : Q = 12289,   Q-1 = 12288   = 2^12*3    -> complete N up to 2048
//
// ZETA (2N-th root) values below are the standard constants used by each
// scheme's reference specification (Kyber zeta=17, Dilithium zeta=1753,
// Falcon zeta=7 for q=12289 with N=512/1024 splits accordingly).
// =============================================================================
package ntt_pkg;

  typedef enum int unsigned {
    KYBER,        // ML-KEM     : Q=3329,    N=128 (7-stage complete NTT)
    DILITHIUM,    // ML-DSA     : Q=8380417, N=256
    FALCON_512,   // FN-DSA-512 : Q=12289,   N=512
    FALCON_1024   // FN-DSA-1024: Q=12289,   N=1024
  } scheme_e;

  // ---------------------------------------------------------------------
  // >>> Select target scheme here (single point of configuration) <<<
  // ---------------------------------------------------------------------
  parameter scheme_e SCHEME = KYBER;

  parameter int unsigned Q = (SCHEME == KYBER)      ? 3329    :
                             (SCHEME == DILITHIUM)  ? 8380417 :
                             /* FALCON_512/1024 */    12289;

  parameter int unsigned N = (SCHEME == KYBER)      ? 128  :
                             (SCHEME == DILITHIUM)  ? 256  :
                             (SCHEME == FALCON_512) ? 512  :
                             /* FALCON_1024 */         1024;

  // Primitive 2N-th root of unity mod Q (standard constant per scheme)
  parameter int unsigned ZETA = (SCHEME == KYBER)     ? 17   :
                                (SCHEME == DILITHIUM) ? 1753 :
                                /* FALCON */             7;

  parameter int unsigned LOGN = $clog2(N);

  // Coefficient width: ceil(log2(Q)) + 1 guard bit for intermediate adds
  parameter int unsigned W    = $clog2(Q) + 1;
  parameter int unsigned MULW = 2 * W;

  // Barrett constant mu = floor(2^MULW / Q), compile-time constant
  parameter longint unsigned BARRETT_MU = (longint'(1) << MULW) / longint'(Q);

  // Modular inverse of N mod Q, needed to scale INTT output (computed off-line
  // in the twiddle-generation script and dropped in here as a constant)
  parameter int unsigned N_INV = n_inv_lut();

  function automatic int unsigned n_inv_lut();
    // Extended-Euclid style modinv via Fermat (Q is prime for all 3 schemes)
    longint unsigned base, result, e;
    base   = N % Q;
    result = 1;
    e      = Q - 2;
    while (e != 0) begin
      if (e[0]) result = (result * base) % Q;
      base = (base * base) % Q;
      e = e >> 1;
    end
    return result[31:0];
  endfunction

  // Mode encoding used throughout the core
  typedef enum logic {
    MODE_FWD = 1'b0,   // forward NTT  - Cooley-Tukey  (CT), decimation in time
    MODE_INV = 1'b1    // inverse NTT  - Gentleman-Sande (GS), decimation in freq
  } ntt_mode_e;

endpackage : ntt_pkg
