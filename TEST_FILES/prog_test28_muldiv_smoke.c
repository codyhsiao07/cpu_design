// test28: RV32M smoke test for mul/div decode + execute + writeback

#define PASS_SIG 0x2800C0DEu
#define FAIL_SIG 0xDEAD28FFu

static __attribute__((noinline)) unsigned do_mul(unsigned a, unsigned b)
{
  unsigned r;
  asm volatile("mul %0, %1, %2" : "=r"(r) : "r"(a), "r"(b));
  return r;
}

static __attribute__((noinline)) unsigned do_mulh(int a, int b)
{
  unsigned r;
  asm volatile("mulh %0, %1, %2" : "=r"(r) : "r"(a), "r"(b));
  return r;
}

static __attribute__((noinline)) unsigned do_mulhsu(int a, unsigned b)
{
  unsigned r;
  asm volatile("mulhsu %0, %1, %2" : "=r"(r) : "r"(a), "r"(b));
  return r;
}

static __attribute__((noinline)) unsigned do_mulhu(unsigned a, unsigned b)
{
  unsigned r;
  asm volatile("mulhu %0, %1, %2" : "=r"(r) : "r"(a), "r"(b));
  return r;
}

static __attribute__((noinline)) int do_div(int a, int b)
{
  int r;
  asm volatile("div %0, %1, %2" : "=r"(r) : "r"(a), "r"(b));
  return r;
}

static __attribute__((noinline)) unsigned do_divu(unsigned a, unsigned b)
{
  unsigned r;
  asm volatile("divu %0, %1, %2" : "=r"(r) : "r"(a), "r"(b));
  return r;
}

static __attribute__((noinline)) int do_rem(int a, int b)
{
  int r;
  asm volatile("rem %0, %1, %2" : "=r"(r) : "r"(a), "r"(b));
  return r;
}

static __attribute__((noinline)) unsigned do_remu(unsigned a, unsigned b)
{
  unsigned r;
  asm volatile("remu %0, %1, %2" : "=r"(r) : "r"(a), "r"(b));
  return r;
}

int main(void)
{
  volatile unsigned a = 0x12345678u;
  volatile unsigned b = 0x00001111u;
  volatile int sa = (int)0xFFFF8000u;

  unsigned sig = 0u;

  sig ^= do_mul(a, b);
  sig ^= do_mulh((int)a, (int)b);
  sig ^= do_mulhsu(sa, b);
  sig ^= do_mulhu(a, 0xFEDCBA98u);
  sig ^= (unsigned)do_div(-123456789, 321);
  sig ^= do_divu(0xFEDCBA98u, 0x1234u);
  sig ^= (unsigned)do_rem(-123456789, 321);
  sig ^= do_remu(0xFEDCBA98u, 0x1234u);

  if (sig == 0x140AA3A0u) {
    return (int)PASS_SIG;
  }
  return (int)FAIL_SIG;
}
