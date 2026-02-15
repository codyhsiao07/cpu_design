// test26: deeper mixed stress for pipeline + I$/D$/L2 path
// - Branch-heavy control flow
// - Byte/half/word load-store mix
// - Signed/unsigned compare mix
// - Function pointer call path (jalr)
//
// Build flow:
//   powershell -ExecutionPolicy Bypass -File tools/build_mem_from_c.ps1 `
//     -Source TEST_FILES/prog_test26_deep_mix_stress.c `
//     -OutMem TEST_FILES/mem_test26_deep_mix_stress.mem

#define PASS_SIG     0x2600C0DEu
#define EXPECT_HASH  0x00000000u
#define OUTER_ROUNDS 24u
#define INNER_ROUNDS 8u

static __attribute__((noinline)) unsigned mix_u32(unsigned a, unsigned b, unsigned c) {
  unsigned x = a ^ (b + 0x9E3779B9u) ^ (c << 1);
  x ^= (x >> 13);
  x += (x << 7);
  x ^= (x >> 9);
  x += 0x7F4A7C15u;
  x ^= (x >> 16);
  return x;
}

static __attribute__((noinline)) unsigned branch_kernel(unsigned x, unsigned y, unsigned i) {
  unsigned r = x ^ (y + i);
  int sx = (int)x;
  int sy = (int)y;

  if ((i & 1u) == 0u) {
    r += (x << 1);
  } else {
    r ^= (y >> 3);
  }

  if (sx < sy) {
    r ^= 0x13579BDFu;
  } else if (sx > sy) {
    r += 0x2468ACE1u;
  } else {
    r ^= 0x11111111u;
  }

  if (x < y) {
    r += 0x01010101u;
  } else {
    r ^= 0x80808080u;
  }

  if ((r & 3u) == 0u) {
    r ^= (r << 5);
  } else if ((r & 3u) == 1u) {
    r += (r >> 7);
  } else if ((r & 3u) == 2u) {
    r ^= (r >> 11);
  } else {
    r += (r << 9);
  }

  return r;
}

static __attribute__((noinline)) unsigned mem_kernel(
    volatile unsigned int *w,
    volatile unsigned short *h16,
    volatile unsigned char *b8,
    unsigned idx,
    unsigned v) {
  unsigned p = (idx * 13u) & 63u;
  unsigned q = (idx * 7u) & 127u;
  unsigned r = (idx * 11u) & 255u;
  unsigned a;
  unsigned b;
  int sb;
  int sh;
  unsigned ub;
  unsigned uh;

  w[p] = v ^ w[(p ^ 9u) & 63u];
  h16[q] = (unsigned short)(v ^ (v >> 16));
  b8[r] = (unsigned char)(v ^ (idx * 29u));

  a = w[(p + 17u) & 63u];
  b = w[(p + 3u) & 63u];
  sb = (signed char)b8[(r ^ 5u) & 255u];
  ub = (unsigned char)b8[(r + 3u) & 255u];
  sh = (signed short)h16[(q ^ 11u) & 127u];
  uh = (unsigned short)h16[(q + 7u) & 127u];

  return (a ^ (b << 1) ^ (unsigned)sb ^ (ub << 8) ^ (unsigned)sh ^ (uh << 16));
}

int main(void) {
  volatile unsigned int   *m32 = (volatile unsigned int *)0x80003000u;
  volatile unsigned short *m16 = (volatile unsigned short *)0x80003800u;
  volatile unsigned char  *m8  = (volatile unsigned char *)0x80003C00u;
  unsigned i;
  unsigned j;
  unsigned s = 0x12345678u;
  unsigned t = 0x9ABCDEF0u;
  unsigned acc = 0xA5A5A5A5u;
  unsigned (*fn_mix)(unsigned, unsigned, unsigned) = mix_u32;

  for (i = 0u; i < 64u; i++) {
    m32[i] = (0x10010001u * i) ^ 0x55AA00FFu;
  }
  for (i = 0u; i < 128u; i++) {
    m16[i] = (unsigned short)((i * 257u) ^ 0xA55Au);
  }
  for (i = 0u; i < 256u; i++) {
    m8[i] = (unsigned char)((i * 37u) ^ 0x5Au);
  }

  for (i = 0u; i < OUTER_ROUNDS; i++) {
    unsigned u = fn_mix(s, t, i);
    unsigned v = branch_kernel(u, acc, i);
    unsigned m = mem_kernel(m32, m16, m8, i, v ^ t);

    if ((int)(u ^ m) < 0) {
      acc ^= (u + m + (i << 2));
    } else {
      acc += (v ^ m ^ (i << 1));
    }

    if ((acc & 1u) != 0u) {
      s = (s << 3) | (s >> 29);
      t ^= (acc >> 5);
    } else {
      s = (s >> 2) | (s << 30);
      t += (acc << 1);
    }

    for (j = 0u; j < INNER_ROUNDS; j++) {
      unsigned k = (i * 33u + j * 17u) & 63u;
      unsigned wv = m32[k];
      unsigned hv = (unsigned)m16[(k * 3u) & 127u];
      unsigned bv = (unsigned)m8[(k * 5u) & 255u];

      if (((j ^ i) & 3u) == 0u) {
        acc ^= (wv + (hv << 1) + (bv << 2));
      } else if (((j ^ i) & 3u) == 1u) {
        acc += (wv ^ (hv << 9) ^ (bv << 17));
      } else if (((j ^ i) & 3u) == 2u) {
        acc ^= (acc >> 11);
      } else {
        acc += (acc << 7);
      }

      if ((int)acc < 0) {
        m32[(k + 7u) & 63u] = acc ^ t;
      } else {
        m32[(k + 19u) & 63u] = acc + s;
      }
    }
  }

  for (i = 0u; i < 64u; i++) {
    acc ^= m32[i];
    acc += (acc << 5);
    acc ^= (acc >> 13);
  }
  for (i = 0u; i < 128u; i += 3u) {
    acc ^= (unsigned)m16[i];
    acc += (acc << 3);
    acc ^= (acc >> 7);
  }
  for (i = 0u; i < 256u; i += 5u) {
    acc ^= (unsigned)m8[i];
    acc += (acc << 1);
    acc ^= (acc >> 9);
  }

  acc ^= (acc >> 16);
  acc += (acc << 9);
  acc ^= (acc >> 11);
  acc += (acc << 3);
  acc ^= (acc >> 7);

  if (acc == EXPECT_HASH) {
    return (int)PASS_SIG;
  }
  // Phase-1 bring-up: return hash so TB log can capture expected value.
  return (int)acc;
}
