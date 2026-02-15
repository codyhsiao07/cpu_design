// test27: bounded full-system mixed stress
// - branch-heavy + load/store mixed
// - designed to finish under current cache/memory model timing
//
// Calibration flow:
// 1) Set EXPECT_HASH=0, rebuild mem, run TEST=27 with EXPECT wildcard.
// 2) Capture final hash in x10, set EXPECT_HASH to that value.
// 3) Rebuild and rerun; program emits PASS_SIG on hash match.

#define PASS_SIG     0x2700C0DEu
#define FAIL_SIG     0xDEAD27FFu
#define EXPECT_HASH  0xC62137DAu

#define ROUNDS 40u

#define ROL32(x, n)  (((x) << (n)) | ((x) >> (32u - (n))))
#define ROR32(x, n)  (((x) >> (n)) | ((x) << (32u - (n))))

int main(void) {
  volatile unsigned int   *m32 = (volatile unsigned int *)0x80006000u;
  volatile unsigned short *m16 = (volatile unsigned short *)0x80006800u;
  volatile unsigned char  *m8  = (volatile unsigned char *)0x80006C00u;
  unsigned i;
  unsigned h = 0x13579BDFu;
  unsigned a = 0x2468ACE1u;
  unsigned b = 0x89ABCDEFu;
  unsigned c = 0x10203040u;
  unsigned result;

  // Init (limited footprint, still crosses many lines)
  for (i = 0u; i < 32u; i++) {
    m32[i] = (0x01010101u * i) ^ 0x55AA00FFu;
  }
  for (i = 0u; i < 64u; i++) {
    m16[i] = (unsigned short)((i * 131u) ^ 0xA55Au);
  }
  for (i = 0u; i < 128u; i++) {
    m8[i] = (unsigned char)((i * 17u) ^ 0x5Au);
  }

  // Main stress loop
  for (i = 0u; i < ROUNDS; i++) {
    unsigned wi = (i * 7u + (a & 7u)) & 31u;
    unsigned hi = (i * 5u + (b & 3u)) & 63u;
    unsigned bi = (i * 9u + (c & 15u)) & 127u;
    unsigned v0 = m32[wi];
    unsigned v1 = m32[(wi ^ 13u) & 31u];
    int sb = (signed char)m8[(bi + 1u) & 127u];
    unsigned ub = (unsigned char)m8[(bi + 3u) & 127u];
    int sh = (signed short)m16[(hi + 5u) & 63u];
    unsigned uh = (unsigned short)m16[(hi + 7u) & 63u];

    if ((int)(v0 ^ a) < (int)(v1 ^ b)) {
      a = ROL32(a + v0 + (unsigned)sh, 3u) ^ 0x9E3779B9u;
      c ^= (unsigned)sb + ub;
    } else {
      a = ROR32(a ^ v1 ^ (unsigned)uh, 2u) + 0x7F4A7C15u;
      c += (unsigned)sb ^ ub;
    }

    if (a < b) {
      b ^= (a + c);
      m32[wi] = v0 ^ a ^ c;
      m16[hi] = (unsigned short)(b ^ (b >> 16));
      m8[bi]  = (unsigned char)(a ^ b ^ c);
    } else {
      b += (a ^ c);
      m32[(wi + 3u) & 31u] = v1 + a + c;
      m16[(hi + 11u) & 63u] = (unsigned short)(a + b + c);
      m8[(bi + 13u) & 127u] = (unsigned char)(a + (b >> 3));
    }

    h ^= a + (b << 1) + (c >> 1) + i;
    h ^= (h >> 13);
    h += (h << 7);
    h ^= (h >> 9);
  }

  // Fold memory image into signature
  for (i = 0u; i < 32u; i++) {
    h ^= m32[i];
    h += (h << 5);
    h ^= (h >> 11);
  }
  for (i = 0u; i < 64u; i += 2u) {
    h ^= (unsigned)m16[i];
    h += (h << 3);
    h ^= (h >> 7);
  }
  for (i = 0u; i < 128u; i += 4u) {
    h ^= (unsigned)m8[i];
    h += (h << 1);
    h ^= (h >> 9);
  }

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
