// Larger pure-C stress program for RV32I pipeline/cache validation.
// Mixes ALU, branches, signed/unsigned compares, and byte/half/word memory ops.

#define OUTER_ROUNDS 128u
#define PASS_SIG     0x2500C0DEu
#define FAIL_SIG     0xDEAD25FFu
#define EXPECT_HASH  0x00000000u

#define ROL1(x) (((x) << 1) | ((x) >> 31))

static __attribute__((noinline)) unsigned mix_step(unsigned s, unsigned t, unsigned i) {
  unsigned x = s ^ (t + (i << 1));
  if (x & 1u) {
    x = (x << 3) | (x >> 29);
  } else {
    x = (x >> 2) | (x << 30);
  }

  if (i & 1u) {
    x ^= 0x9E3779B9u;
  } else {
    x += 0x7F4A7C15u;
  }

  if ((i & 3u) == 0u) {
    x ^= (x >> 5);
  } else if ((i & 3u) == 1u) {
    x += (x << 2);
  } else if ((i & 3u) == 2u) {
    x ^= (x << 7);
  } else {
    x += (x >> 3);
  }
  return x;
}

static __attribute__((noinline)) unsigned cmp_pack(int a, unsigned b) {
  unsigned r = 0u;
  if (a < 0)      r ^= 0x00000001u;
  if (a >= 17)    r ^= 0x00000002u;
  if (b < 100u)   r ^= 0x00000004u;
  if (b >= 33u)   r ^= 0x00000008u;
  if (a == 7)     r ^= 0x00000010u;
  if (b != 55u)   r ^= 0x00000020u;
  return r;
}

int main(void) {
  volatile unsigned int   *m32 = (volatile unsigned int *)0x80002000u;
  volatile unsigned short *m16 = (volatile unsigned short *)0x80002400u;
  volatile unsigned char  *m8  = (volatile unsigned char *)0x80002600u;
  unsigned i;
  unsigned s = 0x31415926u;
  unsigned t = 0x27182818u;
  unsigned h = 0x1234ABCDu;

  // One-shot byte/half/word memory path coverage.
  m8[0] = 0x80u;
  m8[1] = 0x7Fu;
  m16[1] = 0x80F0u;
  m32[1] = 0x11223344u;
  h ^= (unsigned)(unsigned char)m8[1];
  h ^= (unsigned)(signed char)m8[0];
  h ^= (unsigned)(unsigned short)m16[1];
  h ^= (unsigned)(signed short)m16[1];
  h ^= m32[1];

  for (i = 0u; i < OUTER_ROUNDS; i++) {
    unsigned c;
    unsigned r;

    s = mix_step(s, t, i);
    c = cmp_pack((int)(s ^ (i << 16)), t ^ i);
    r = m32[(i ^ 7u) & 15u];
    m32[i & 15u] = s ^ c;

    if (i & 1u) {
      t += (r ^ (s >> 3));
    } else {
      t ^= (r + (s << 1));
    }

    if ((i & 3u) == 0u) {
      h ^= (s + t + c);
    } else if ((i & 3u) == 1u) {
      h += (s ^ t ^ c);
    } else if ((i & 3u) == 2u) {
      h ^= (h >> 7);
    } else {
      h += (h << 3);
    }

    if (h & 1u) {
      h = ROL1(h);
    } else {
      h ^= (h >> 5);
    }
  }

  for (i = 0u; i < 16u; i++) {
    unsigned v = m32[i];
    if (i & 1u) {
      h += v;
    } else {
      h ^= v;
    }
    h ^= (h >> 13);
    h += (h << 7);
  }

  h ^= (h >> 16);
  h += (h << 5);
  h ^= (h >> 7);
  h += (h << 9);
  h ^= (h >> 11);

  if (h == EXPECT_HASH) {
    return (int)PASS_SIG;
  }
  return (int)FAIL_SIG;
}
