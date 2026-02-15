// Larger C-origin program for pipeline stress.
// Focus: long branch-heavy loops + light DDR traffic.

#define OUTER_ROUNDS 512u
#define EXPECT_HASH  0xB08097A7u
#define PASS_SIG     0x2400C0DEu
#define FAIL_SIG     0xDEAD24FFu

#define ROL32(x, n) (((x) << (n)) | ((x) >> (32u - (n))))

static volatile unsigned int *const DDR = (volatile unsigned int *)0x80002000u;

int main(void) {
  unsigned int seed = DDR[0];
  unsigned int i;
  unsigned int x = 0x12345678u ^ seed;
  unsigned int y = 0x89ABCDEFu + (seed << 1);
  unsigned int z = 0x0F1E2D3Cu ^ (seed << 2);
  unsigned int h = 0x13579BDFu + seed;

  for (i = 0u; i < OUTER_ROUNDS; i++) {
    unsigned int k;

    if (x & 1u) {
      x = (x + 0x01020304u) ^ (y << 1);
    } else {
      x = (x ^ 0x55AA55AAu) + (y >> 1);
    }

    if (i & 1u) {
      y += (x + 0x11111111u);
    } else {
      y ^= (x + (i << 2));
    }

    k = i & 3u;
    if (k == 0u) {
      z ^= (x + y);
    } else if (k == 1u) {
      z += (x ^ (y >> 3));
    } else if (k == 2u) {
      z ^= ((x >> 2) + (y << 1));
    } else {
      z += ((z >> 1) ^ 0x3C3C3C3Cu);
    }

    h ^= (x + (y << 1) + (z >> 1) + i);
    if (h & 1u) {
      h = ROL32(h, 1u);
    } else {
      h ^= (h >> 3);
    }
  }

  DDR[0] = x ^ h;
  DDR[1] = y ^ z;
  h ^= DDR[0] + (DDR[1] << 1);

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
