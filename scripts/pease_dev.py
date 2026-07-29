from golden_model import Q, N, LOGN, omega, omega_inv, n_inv, bitrev

def direct_ntt(a):
    return [sum((a[j]*pow(omega, (j*k) % N, Q)) % Q for j in range(N)) % Q for k in range(N)]

def direct_intt(A):
    x = [sum((A[k]*pow(omega_inv, (j*k) % N, Q)) % Q for k in range(N)) % Q for j in range(N)]
    return [(v * n_inv) % Q for v in x]

def perfect_shuffle(a):
    # rotate address bits left by 1 (over LOGN bits): new[rotl(i)] = a[i]  <=> new[i] = a[rotr(i)]
    n = len(a)
    out = [0]*n
    for i in range(n):
        # rotate-right i by 1 over LOGN bits to find source index
        src = ((i >> 1) | ((i & 1) << (LOGN-1)))
        out[i] = a[src]
    return out

def pease_ntt(a):
    A = a[:]
    for s in range(LOGN):
        B = [0]*N
        half = N//2
        for i in range(half):
            # twiddle exponent: bit-reversal of i's top (s+1) bits pattern, standard Pease formula
            # w = omega^( bitrev(i mod 2^s, s) * (N/2^(s+1)) )  -- try common formula
            bits = LOGN
            # take low s bits of i, bit-reverse them, that forms exponent multiplier
            low = i & ((1<<s)-1) if s>0 else 0
            rev = bitrev(low, s) if s>0 else 0
            exp = rev * (N // (1<<(s+1)))
            w = pow(omega, exp, Q)
            u = A[i]
            v = A[i+half]
            t = (v*w) % Q
            B[i] = (u+t) % Q
            B[i+half] = (u-t) % Q
        A = perfect_shuffle(B)
    return A

if __name__ == "__main__":
    import random
    random.seed(2)
    a = [random.randrange(Q) for _ in range(N)]
    ref = direct_ntt(a)
    out = pease_ntt(a)
    print("match natural order:", out == ref)
    # try bit-reversed output compare
    rev_ref = [ref[bitrev(i,LOGN)] for i in range(N)]
    print("match bitrev(ref):", out == rev_ref)
    rev_out = [out[bitrev(i,LOGN)] for i in range(N)]
    print("bitrev(match) vs ref:", rev_out == ref)

def pease_intt_variant(a, shuffle_first):
    A = a[:]
    for s in range(LOGN):
        if shuffle_first:
            A = perfect_shuffle(A)
        B = [0]*N
        half = N//2
        for i in range(half):
            low = i & ((1<<s)-1) if s>0 else 0
            rev = bitrev(low, s) if s>0 else 0
            exp = rev * (N // (1<<(s+1)))
            w = pow(omega_inv, exp, Q)
            u = A[i]
            v = A[i+half]
            B[i] = (u+v) % Q
            B[i+half] = ((u-v)*w) % Q
        A = B
        if not shuffle_first:
            A = perfect_shuffle(A)
    A = [(x*n_inv) % Q for x in A]
    return A

if __name__ == "__main__":
    import random
    random.seed(3)
    A = [random.randrange(Q) for _ in range(N)]
    ref = direct_intt(A)
    for sf in (True, False):
        out = pease_intt_variant(A, sf)
        rev_ref = [ref[bitrev(i,LOGN)] for i in range(N)]
        print("shuffle_first=",sf," natural match:", out==ref, " bitrev match:", out==rev_ref)

def perfect_shuffle_inv(a):
    n = len(a)
    out = [0]*n
    for i in range(n):
        src = ((i << 1) & (n-1)) | (i >> (LOGN-1))
        out[i] = a[src]
    return out

def pease_intt_reverse(A):
    X = A[:]
    for s in reversed(range(LOGN)):
        X = perfect_shuffle_inv(X)
        half = N//2
        B = [0]*N
        for i in range(half):
            low = i & ((1<<s)-1) if s>0 else 0
            rev = bitrev(low, s) if s>0 else 0
            exp = rev * (N // (1<<(s+1)))
            w = pow(omega_inv, exp, Q)
            u = X[i]
            v = X[i+half]
            B[i] = (u+v) % Q
            B[i+half] = ((u-v)*w) % Q
        X = B
    return [(x*n_inv) % Q for x in X]

if __name__ == "__main__":
    import random
    random.seed(4)
    a = [random.randrange(Q) for _ in range(N)]
    fwd = pease_ntt(a)   # bit-reversed-order spectrum
    back = pease_intt_reverse(fwd)
    print("round trip pease fwd/inv match original:", back == a)
