// Simple RV32I C test program for icache_pipeline_tb.
// Expected final signature: x8 (written from a local variable) = 0x55.

static volatile unsigned int *const DDR0 = (volatile unsigned int *)0x80001000u;

static int signed_cmp(int a, int b) {
  return (a < b) ? 1 : 0;
}

static int unsigned_cmp(unsigned int a, unsigned int b) {
  return (a < b) ? 1 : 0;
}

int main(void) {
  int a = 5;
  int b = 7;
  unsigned int sig = 0x50u;

  if (signed_cmp(a, b)) {
    sig += 1u;
  }
  if (b >= a) {
    sig += 1u;
  }
  if (unsigned_cmp((unsigned int)a, (unsigned int)b)) {
    sig += 1u;
  }
  if ((unsigned int)b >= (unsigned int)a) {
    sig += 1u;
  }
  if ((a + b) == 12) {
    sig += 1u;
  }

  // Memory touch to exercise data path in a C-origin program.
  DDR0[0] = sig;
  {
    volatile unsigned int r = DDR0[0];
    if (r == sig) {
      sig = 0x55u;
    }
  }

  // Keep an observable value in caller-saved path.
  asm volatile("" : : "r"(sig));
  return (int)sig;
}

