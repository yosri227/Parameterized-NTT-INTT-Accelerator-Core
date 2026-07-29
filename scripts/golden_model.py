import random

Q = 3329
N = 128
LOGN = N.bit_length() - 1

def modpow(a, e, m):
    return pow(a, e, m)

def find_primitive_2nth_root(q, n):
    order = 2 * n
    for g in range(2, q):
        if modpow(g, order, q) == 1 and modpow(g, order // 2, q) != 1:
            return g
    return None

psi = find_primitive_2nth_root(Q, N)
omega = (psi * psi) % Q
omega_inv = modpow(omega, Q - 2, Q)
n_inv = modpow(N, Q - 2, Q)

def bitrev(x, bits):
    r = 0
    for _ in range(bits):
        r = (r << 1) | (x & 1)
        x >>= 1
    return r

def ntt_ct(a):
    A = [a[bitrev(i, LOGN)] for i in range(N)]
    length = 2
    while length <= N:
        half = length // 2
        w_len = modpow(omega, N // length, Q)
        for i in range(0, N, length):
            w = 1
            for j in range(half):
                u = A[i + j]
                v = (A[i + j + half] * w) % Q
                A[i + j] = (u + v) % Q
                A[i + j + half] = (u - v) % Q
                w = (w * w_len) % Q
        length *= 2
    return A

def intt_gs(a):
    A = a[:]
    length = N
    while length >= 2:
        half = length // 2
        w_len = modpow(omega_inv, N // length, Q)
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
    A = [(x * n_inv) % Q for x in A]
    return A

if __name__ == "__main__":
    random.seed(1)
    a = [random.randrange(Q) for _ in range(N)]
    A = ntt_ct(a)
    a2 = intt_gs(A)
    assert a2 == a, "round trip failed"
    print("Q =", Q, " N =", N)
    print("psi =", psi, " omega =", omega, " omega_inv =", omega_inv, " n_inv =", n_inv)
    print("round-trip OK")
    print("sample a[0:8] =", a[0:8])
    print("sample A[0:8] =", A[0:8])
