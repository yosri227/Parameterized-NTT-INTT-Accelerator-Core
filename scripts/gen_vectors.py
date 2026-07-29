#!/usr/bin/env python3
"""
gen_vectors.py
Regenerates every golden-model test vector and twiddle-ROM .hex file used by
the testbenches in ../tb and ../rtl. Run this whenever ntt_pkg.sv's Q/N/ZETA
are changed, and keep the Q/N/ZETA constants below in sync with ntt_pkg.sv.

Usage:
    python3 gen_vectors.py
"""
import random

# ---- must match rtl/ntt_pkg.sv (SCHEME=KYBER default) ----
Q = 3329
N = 128
ZETA = 17          # primitive 2N-th root of unity mod Q
# ------------------------------------------------------------

LOGN = N.bit_length() - 1

def modpow(a, e, m):
    return pow(a, e, m)

omega     = (ZETA * ZETA) % Q
omega_inv = modpow(omega, Q - 2, Q)
n_inv     = modpow(N, Q - 2, Q)

def bitrev(x, bits):
    r = 0
    for _ in range(bits):
        r = (r << 1) | (x & 1)
        x >>= 1
    return r

def exp_val(s, i):
    low = i & ((1 << s) - 1) if s > 0 else 0
    rev = bitrev(low, s) if s > 0 else 0
    return rev * (N // (1 << (s + 1)))

def rotl(x):
    return ((x << 1) | (x >> (LOGN - 1))) & (N - 1)

def rotr(x):
    return ((x >> 1) | ((x & 1) << (LOGN - 1))) & (N - 1)

def perfect_shuffle(a):       # out[i] = a[rotr(i)]   (applied after each FWD stage)
    return [a[rotr(i)] for i in range(N)]

def perfect_shuffle_inv(a):   # out[i] = a[rotl(i)]   (applied before each INV stage)
    return [a[rotl(i)] for i in range(N)]

def pease_ntt(a):
    """Forward NTT (Cooley-Tukey, constant-geometry/Pease).
       Input: natural order. Output: bit-reversed order."""
    A = a[:]
    half = N // 2
    for s in range(LOGN):
        B = [0] * N
        for i in range(half):
            w = modpow(omega, exp_val(s, i), Q)
            u, v = A[i], A[i + half]
            t = (v * w) % Q
            B[i]        = (u + t) % Q
            B[i + half] = (u - t) % Q
        A = perfect_shuffle(B)
    return A

def pease_intt_reverse(A):
    """Inverse NTT (Gentleman-Sande, constant-geometry/Pease, reverse stage order).
       Input: bit-reversed order (i.e. a pease_ntt output). Output: natural order."""
    X = A[:]
    half = N // 2
    for s in reversed(range(LOGN)):
        X = perfect_shuffle_inv(X)
        B = [0] * N
        for i in range(half):
            w = modpow(omega_inv, exp_val(s, i), Q)
            u, v = X[i], X[i + half]
            B[i]        = (u + v) % Q
            B[i + half] = ((u - v) * w) % Q
        X = B
    return [(x * n_inv) % Q for x in X]


def write_vec(fname, vals):
    with open(fname, "w") as f:
        for v in vals:
            f.write(f"{v}\n")


if __name__ == "__main__":
    # ---- twiddle ROM content (rtl/) ----
    NUM = N // 2
    fwd_tbl = [None] * NUM
    inv_tbl = [None] * NUM
    for s in range(LOGN):
        for i in range(N // 2):
            e = exp_val(s, i)
            fwd_tbl[e] = modpow(omega, e, Q)
            inv_tbl[e] = modpow(omega_inv, e, Q)
    with open("../rtl/twiddle_fwd.hex", "w") as f:
        for v in fwd_tbl: f.write(f"{v:04x}\n")
    with open("../rtl/twiddle_inv.hex", "w") as f:
        for v in inv_tbl: f.write(f"{v:04x}\n")
    print(f"wrote twiddle_fwd.hex / twiddle_inv.hex ({NUM} entries each)")

    # ---- barrett_reduce vectors ----
    random.seed(5)
    with open("../tb/barrett_vecs.txt", "w") as f:
        for _ in range(200):
            a, b = random.randrange(Q), random.randrange(Q)
            f.write(f"{a*b} {(a*b) % Q}\n")

    # ---- butterfly_unit vectors (CT + GS) ----
    random.seed(7)
    lines = []
    for _ in range(100):
        a, b, w = (random.randrange(Q) for _ in range(3))
        t = (b * w) % Q
        lines.append(f"0 {a} {b} {w} {(a+t)%Q} {(a-t)%Q}")
    for _ in range(100):
        a, b, w = (random.randrange(Q) for _ in range(3))
        t = ((a - b) * w) % Q
        lines.append(f"1 {a} {b} {w} {(a+b)%Q} {t}")
    write_vec("../tb/bu_vecs.txt", lines)

    # ---- tw_exp_gen vectors ----
    lines = []
    for s in range(LOGN):
        for i in range(N // 2):
            lines.append(f"{s} {i} {exp_val(s,i)}")
    write_vec("../tb/tw_exp_vecs.txt", lines)

    # ---- ru_rotate vectors ----
    lines = []
    for a in range(N):
        lines.append(f"0 {a} {rotl(a)}")
        lines.append(f"1 {a} {rotl(a)}")   # both modes now use rotate-left, see reorder_unit.sv
    write_vec("../tb/rotate_vecs.txt", lines)

    # ---- full-chip round-trip vectors ----
    random.seed(42)
    a = [random.randrange(Q) for _ in range(N)]
    A = pease_ntt(a)
    back = pease_intt_reverse(A)
    assert back == a, "golden model self-check failed!"
    write_vec("../tb/input_coeffs.txt", a)
    write_vec("../tb/expected_fwd.txt", A)
    write_vec("../tb/expected_roundtrip.txt", back)

    print("All vectors regenerated and self-check passed (round trip == identity).")
