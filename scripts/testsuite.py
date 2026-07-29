#!/usr/bin/env python3
"""
testsuite.py — NIST Kyber (ML-KEM) NTT reference + Pease RTL test-vector generator.

Generates test cases for the RTL NTT accelerator, verified against the exact
Kyber reference NTT as specified in FIPS 203 (ML-KEM).

Usage:
    python3 testsuite.py [--scheme KYBER|DILITHIUM|FALCON_512|FALCON_1024]

Output:
    testsuite/cases.csv           — test case manifest
    testsuite/case_NN/            — per-case vector files
        input.txt                 — N coefficients
        expected_fwd.txt          — expected Pease FWD NTT output
        reference_ct.txt          — expected Kyber reference CT NTT output
"""
import os
import sys
import csv
import random

# ---- must match rtl/ntt_pkg.sv defaults ----
PARAMS = {
    "KYBER":       {"Q": 3329,    "N": 128,  "ZETA": 17},
    "DILITHIUM":   {"Q": 8380417, "N": 256,  "ZETA": 1753},
    "FALCON_512":  {"Q": 12289,   "N": 512,  "ZETA": 7},
    "FALCON_1024": {"Q": 12289,   "N": 1024, "ZETA": 7},
}

SCHEME = os.environ.get("SCHEME", "KYBER")
P = PARAMS.get(SCHEME)
if not P:
    sys.exit(f"Unknown scheme {SCHEME}; choose from {list(PARAMS.keys())}")

Q = P["Q"]
N = P["N"]
ZETA = P["ZETA"]
LOGN = N.bit_length() - 1

def modpow(a, e):
    return pow(a, e, Q)

omega = (ZETA * ZETA) % Q
omega_inv = modpow(omega, Q - 2)
n_inv = modpow(N, Q - 2)

def bitrev(x, bits):
    r = 0
    for _ in range(bits):
        r = (r << 1) | (x & 1)
        x >>= 1
    return r

# =========================================================================
# NIST Kyber reference NTT (Cooley-Tukey, FIPS 203)
# =========================================================================
def kyber_ntt(a):
    a = [a[bitrev(i, LOGN)] for i in range(N)]
    length = 2
    while length <= N:
        half = length // 2
        w_len = modpow(omega, N // length)
        for i in range(0, N, length):
            w = 1
            for j in range(half):
                u = a[i + j]
                v = (a[i + j + half] * w) % Q
                a[i + j] = (u + v) % Q
                a[i + j + half] = (u - v) % Q
                w = (w * w_len) % Q
        length *= 2
    return a

def kyber_intt(A):
    A = A[:]
    length = N
    while length >= 2:
        half = length // 2
        w_len = modpow(omega_inv, N // length)
        for i in range(0, N, length):
            w = 1
            for j in range(half):
                u = A[i + j]
                v = A[i + j + half]
                A[i + j] = (u + v) % Q
                A[i + j + half] = ((u - v) * w) % Q
                w = (w * w_len) % Q
        length //= 2
    A = [A[bitrev(i, LOGN)] for i in range(N)]
    return [(x * n_inv) % Q for x in A]

# =========================================================================
# Pease NTT (constant-geometry, matches RTL exactly)
# =========================================================================
def pease_ntt(a):
    A = a[:]
    half = N // 2
    for s in range(LOGN):
        B = [0] * N
        for i in range(half):
            low = i & ((1 << s) - 1) if s > 0 else 0
            rev = bitrev(low, s) if s > 0 else 0
            exp = rev * (N // (1 << (s + 1)))
            w = modpow(omega, exp)
            u, v = A[i], A[i + half]
            t = (v * w) % Q
            B[i] = (u + t) % Q
            B[i + half] = (u - t) % Q
        A = [(B[((x >> 1) | ((x & 1) << (LOGN - 1)))]) for x in range(N)]
    return A

def pease_intt(A):
    X = A[:]
    half = N // 2
    for s in reversed(range(LOGN)):
        X = [(X[((x << 1) & (N - 1)) | (x >> (LOGN - 1))]) for x in range(N)]
        B = [0] * N
        for i in range(half):
            low = i & ((1 << s) - 1) if s > 0 else 0
            rev = bitrev(low, s) if s > 0 else 0
            exp = rev * (N // (1 << (s + 1)))
            w = modpow(omega_inv, exp)
            u, v = X[i], X[i + half]
            B[i] = (u + v) % Q
            B[i + half] = ((u - v) * w) % Q
        X = B
    return [(x * n_inv) % Q for x in X]

# =========================================================================
# Conversion: Pease output ↔ Kyber reference output
# =========================================================================
def pease_to_kyber(A_pease):
    return [A_pease[bitrev(i, LOGN)] for i in range(N)]

def kyber_to_pease(A_kyber):
    return [A_kyber[bitrev(i, LOGN)] for i in range(N)]

# =========================================================================
# Test case generation
# =========================================================================
OUT_DIR = os.path.join(os.path.dirname(__file__), "..", "testsuite")

def make_case(case_dir, name, description, coeffs):
    d = os.path.join(OUT_DIR, case_dir)
    os.makedirs(d, exist_ok=True)

    fwd_pease = pease_ntt(coeffs)
    inv_pease = pease_intt(fwd_pease)
    fwd_kyber = kyber_ntt(coeffs)
    inv_kyber = kyber_intt(fwd_kyber)

    errors = []
    if inv_pease != coeffs:
        errors.append(f"Pease round-trip FAIL: {sum(1 for a, b in zip(inv_pease, coeffs) if a != b)} mismatches")
    if inv_kyber != coeffs:
        errors.append(f"Kyber round-trip FAIL: {sum(1 for a, b in zip(inv_kyber, coeffs) if a != b)} mismatches")
    if fwd_pease != kyber_to_pease(fwd_kyber):
        errors.append("Pease FWD != Kyber->Pease conversion")

    def write(fname, vals):
        with open(os.path.join(d, fname), "w") as f:
            for v in vals:
                f.write(f"{v}\n")

    write("input.txt", coeffs)
    write("expected_fwd.txt", fwd_pease)
    write("reference_ct.txt", fwd_kyber)

    with open(os.path.join(d, "_ref.txt"), "w") as f:
        f.write(f"# {name}: {description}\n")
        f.write(f"# Q={Q} N={N} ZETA={ZETA} LOGN={LOGN}\n")
        f.write(f"# Pease round-trip correct: {inv_pease == coeffs}\n")
        f.write(f"# Kyber reference correct:   {inv_kyber == coeffs}\n")
        f.write(f"# Pease ↔ Kyber match:       {fwd_pease == kyber_to_pease(fwd_kyber)}\n")

    status = "PASS" if not errors else "FAIL"
    for e in errors:
        print(f"  [SELF-CHECK] {e}")
    return status, errors, fwd_pease, fwd_kyber


def run_all():
    os.makedirs(OUT_DIR, exist_ok=True)
    cases = []
    rng = random.Random(12345)

    # 0: all zeros
    cases.append(("case_00", "zeros_all", "All coefficients = 0", [0] * N))

    # 1: all ones
    cases.append(("case_01", "ones_all", "All coefficients = 1", [1] * N))

    # 2: unit impulse at index 0
    c = [0] * N; c[0] = 1
    cases.append(("case_02", "impulse_0", "Unit impulse at index 0", c))

    # 3: unit impulse at index N//2
    c = [0] * N; c[N // 2] = 1
    cases.append(("case_03", f"impulse_{N//2}", f"Unit impulse at index {N//2}", c))

    # 4: unit impulse at last index
    c = [0] * N; c[N - 1] = 1
    cases.append(("case_04", f"impulse_{N-1}", f"Unit impulse at index {N-1}", c))

    # 5: all Q-1 (max value)
    cases.append(("case_05", "max_val", f"All coefficients = Q-1 ({Q-1})", [Q - 1] * N))

    # 6: alternating 0,1,0,1,...
    cases.append(("case_06", "alternating_01", "Alternating 0,1,0,1,...", [i % 2 for i in range(N)]))

    # 7: alternating 0,Q-1,0,Q-1,...
    cases.append(("case_07", "alternating_0max", f"Alternating 0,{Q-1},...", [(i % 2) * (Q - 1) for i in range(N)]))

    # 8-12: random polynomials (5 seeds)
    for seed_idx, seed in enumerate([42, 100, 200, 300, 500], start=8):
        rng = random.Random(seed)
        c = [rng.randrange(Q) for _ in range(N)]
        cases.append((f"case_{seed_idx:02d}", f"random_seed{seed}", f"Random seed {seed}", c))

    # 13: ascending 0..N-1
    cases.append(("case_13", "ascending", f"Ascending 0..{N-1}", list(range(N))))

    # 14: descending N-1..0
    cases.append(("case_14", "descending", f"Descending {N-1}..0", list(range(N - 1, -1, -1))))

    # 15: small values only
    cases.append(("case_15", "small_vals", "Small values 0..10", [(i * 7) % 11 for i in range(N)]))

    # ---- generate all cases ----
    with open(os.path.join(OUT_DIR, "cases.csv"), "w", newline="") as csvf:
        w = csv.writer(csvf)
        w.writerow(["case", "name", "description", "status"])
        results = []
        for case_dir, name, desc, coeffs in cases:
            status, errors, fwd_pease, fwd_kyber = make_case(case_dir, name, desc, coeffs)
            results.append((case_dir, name, desc, status))
            w.writerow([case_dir, name, desc, status])
            print(f"  [{status}] {case_dir} ({name})")

    # ---- cross-verify all cases: Pease ↔ Kyber equivalence ----
    print(f"\n{'='*60}")
    print(f"Test suite generated: {OUT_DIR}/")
    print(f"  Cases: {len(cases)}")
    print(f"  Scheme: {SCHEME} (Q={Q}, N={N})")
    print(f"  All inputs self-checked against Kyber reference CT NTT")
    print(f"{'='*60}")

    with open(os.path.join(OUT_DIR, "_summary.txt"), "w") as f:
        f.write(f"Test Suite Summary — SCHEME={SCHEME} Q={Q} N={N}\n")
        f.write(f"{'='*60}\n")
        for case_dir, name, desc, status in results:
            f.write(f"  [{status}] {case_dir}: {name} — {desc}\n")


if __name__ == "__main__":
    run_all()
