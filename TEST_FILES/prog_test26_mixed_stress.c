// test26: calibrated mixed stress for pipeline + I$/D$/L2 path.
// Flow:
// 1) Set EXPECT_HASH=0 and build/run once to get hash (x8 writeback).
// 2) Fill EXPECT_HASH with that value and rebuild.
// 3) Program returns PASS_SIG on match, FAIL_SIG otherwise.

#define PASS_SIG     0x2600C0DEu
#define FAIL_SIG     0xDEAD26FFu
#define EXPECT_HASH  0x8DF9EB51u

#define OUTER_ROUNDS 192u
#define ROL32(x, n)  (((x) << (n)) | ((x) >> (32u - (n))))
#define ROR32(x, n)  (((x) >> (n)) | ((x) << (32u - (n))))

static __attribute__((noinline)) unsigned mix_step(unsigned a, unsigned b, unsigned c) {
  unsigned x = a ^ (b + 0x9E3779B9u) ^ (c << 1);
  x ^= (x >> 13);
  x += (x << 7);
  x ^= (x >> 9);
  x += 0x7F4A7C15u;
  x ^= (x >> 16);
  return x;
}

static __attribute__((noinline)) unsigned branch_mix(int sx, int sy, unsigned ux, unsigned uy, unsigned i) {
  unsigned r = ux ^ (uy + i);
  if ((i & 1u) == 0u) r += (ux << 1);
  else                r ^= (uy >> 3);

  if (sx < sy)        r ^= 0x13579BDFu;
  else if (sx > sy)   r += 0x2468ACE1u;
  else                r ^= 0x11111111u;

  if (ux < uy)        r += 0x01010101u;
  else                r ^= 0x80808080u;

  if ((r & 3u) == 0u)       r ^= (r << 5);
  else if ((r & 3u) == 1u)  r += (r >> 7);
  else if ((r & 3u) == 2u)  r ^= (r >> 11);
  else                      r += (r << 9);

  return r;
}

static __attribute__((noinline)) unsigned mem_mix(
    volatile unsigned int *w,
    volatile unsigned short *h16,
    volatile unsigned char *b8,
    unsigned idx,
    unsigned v) {
  unsigned wi = (idx * 13u) & 63u;
  unsigned hi = (idx * 9u) & 127u;
  unsigned bi = (idx * 7u) & 255u;
  unsigned a;
  unsigned b;
  int sb;
  int sh;
  unsigned ub;
  unsigned uh;

  w[wi] = v ^ w[(wi ^ 9u) & 63u];
  h16[hi] = (unsigned short)(v ^ (v >> 16));
  b8[bi] = (unsigned char)(v ^ (idx * 29u));

  a = w[(wi + 17u) & 63u];
  b = w[(wi + 3u) & 63u];
  sb = (signed char)b8[(bi ^ 5u) & 255u];
  ub = (unsigned char)b8[(bi + 3u) & 255u];
  sh = (signed short)h16[(hi ^ 11u) & 127u];
  uh = (unsigned short)h16[(hi + 7u) & 127u];

  return a ^ (b << 1) ^ (unsigned)sb ^ (ub << 8) ^ (unsigned)sh ^ (uh << 16);
}

int main(void) {
  volatile unsigned int   *m32 = (volatile unsigned int *)0x80002800u;
  volatile unsigned short *m16 = (volatile unsigned short *)0x80002C00u;
  volatile unsigned char  *m8  = (volatile unsigned char *)0x80002E00u;
  unsigned i;
  unsigned s = 0x12345678u;
  unsigned t = 0x9ABCDEF0u;
  unsigned h = 0xA5A5A5A5u;

  for (i = 0u; i < 64u; i++) {
    m32[i] = (0x01010101u * i) ^ 0x55AA00FFu;
  }
  for (i = 0u; i < 128u; i++) {
    m16[i] = (unsigned short)((i * 131u) ^ 0xA55Au);
  }
  for (i = 0u; i < 256u; i++) {
    m8[i] = (unsigned char)((i * 17u) ^ 0x5Au);
  }

  for (i = 0u; i < OUTER_ROUNDS; i++) {
    unsigned a = m32[(i * 5u) & 63u];
    unsigned b = m32[(i * 9u + 3u) & 63u];
    unsigned c = branch_mix((int)(a ^ s), (int)(b ^ t), a ^ s, b ^ t, i);
    unsigned d = mem_mix(m32, m16, m8, i, c ^ t);

    h ^= mix_step(c, d, i);
    if (h & 1u) s = ROL32(s + c, 3u);
    else        s = ROR32(s ^ c, 2u);
    t += d ^ (i * 0x10201u);

    if ((i & 7u) == 0u) {
      if ((signed char)m8[(i * 7u) & 255u] < 0) h ^= 0x89ABCDEFu;
      else                                       h += 0x01234567u;
    }
  }

  for (i = 0u; i < 64u; i++) {
    h ^= m32[i];
    h += (h << 5);
    h ^= (h >> 13);
  }
  for (i = 0u; i < 128u; i += 3u) {
    h ^= (unsigned)m16[i];
    h += (h << 3);
    h ^= (h >> 7);
  }
  for (i = 0u; i < 256u; i += 5u) {
    h ^= (unsigned)m8[i];
    h += (h << 1);
    h ^= (h >> 9);
  }

  h ^= (h >> 16);
  h += (h << 9);
  h ^= (h >> 11);
  h += (h << 3);
  h ^= (h >> 7);

  {
    unsigned result;
    if (EXPECT_HASH == 0u) {
      result = h;
    } else if (h == EXPECT_HASH) {
      result = PASS_SIG;
    } else {
      result = FAIL_SIG;
    }
    asm volatile("mv a0, %0" :: "r"(result) : "a0");
    for (;;) { }
  }
}
