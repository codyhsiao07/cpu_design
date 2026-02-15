#!/usr/bin/env python3
import argparse
import re
import sys


BASE_ADDR = 0x80000000
MEM_BYTES = 1 << 20  # 1 MiB, match simplified MIG model


TEST_CFG = {
    24: {"mem": "TEST_FILES/mem_test24_from_c.mem", "expect_rd": 8, "expect_val": 0x2400C0DE},
    25: {"mem": "TEST_FILES/mem_test25_all_instr_stress.mem", "expect_rd": 10, "expect_val": 0xDEAD25FF},
    26: {"mem": "TEST_FILES/mem_test26_mixed_stress.mem", "expect_rd": 10, "expect_val": 0x2600C0DE},
    27: {"mem": "TEST_FILES/mem_test27_full_system_stress.mem", "expect_rd": 10, "expect_val": 0x2700C0DE},
}


def sext(v, bits):
    sign = 1 << (bits - 1)
    mask = (1 << bits) - 1
    v &= mask
    return (v ^ sign) - sign


def u32(v):
    return v & 0xFFFFFFFF


def s32(v):
    return sext(v, 32)


def parse_mem(path):
    mem = bytearray(MEM_BYTES)
    # default word = 0x00000013 (NOP)
    for i in range(0, MEM_BYTES, 4):
        mem[i + 0] = 0x13
        mem[i + 1] = 0x00
        mem[i + 2] = 0x00
        mem[i + 3] = 0x00

    line_idx = 0
    with open(path, "r", encoding="utf-8", errors="ignore") as f:
        for raw in f:
            s = raw.strip()
            if not s:
                continue
            if s.startswith("#") or s.startswith("//"):
                continue
            if s.startswith("@"):
                # unsupported in current flow; keep simple by rejecting
                raise ValueError(f"{path}: '@' address directive not supported: {s}")
            m = re.match(r"^([0-9a-fA-F]{1,8})$", s)
            if not m:
                continue
            w = int(m.group(1), 16) & 0xFFFFFFFF
            off = line_idx * 4
            if off + 3 < MEM_BYTES:
                mem[off + 0] = (w >> 0) & 0xFF
                mem[off + 1] = (w >> 8) & 0xFF
                mem[off + 2] = (w >> 16) & 0xFF
                mem[off + 3] = (w >> 24) & 0xFF
            line_idx += 1
    return mem


class RV32I:
    def __init__(self, mem):
        self.mem = mem
        self.x = [0] * 32
        self.pc = BASE_ADDR
        self.commit_idx = 0
        self.trace = []

    def _addr_to_off(self, addr):
        off = addr - BASE_ADDR
        if 0 <= off < MEM_BYTES:
            return off
        return None

    def load_u8(self, addr):
        off = self._addr_to_off(addr)
        if off is None:
            return 0
        return self.mem[off]

    def load_u16(self, addr):
        b0 = self.load_u8(addr)
        b1 = self.load_u8(addr + 1)
        return b0 | (b1 << 8)

    def load_u32(self, addr):
        b0 = self.load_u8(addr)
        b1 = self.load_u8(addr + 1)
        b2 = self.load_u8(addr + 2)
        b3 = self.load_u8(addr + 3)
        return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)

    def store_u8(self, addr, v):
        off = self._addr_to_off(addr)
        if off is None:
            return
        self.mem[off] = v & 0xFF

    def store_u16(self, addr, v):
        self.store_u8(addr, v & 0xFF)
        self.store_u8(addr + 1, (v >> 8) & 0xFF)

    def store_u32(self, addr, v):
        self.store_u8(addr, v & 0xFF)
        self.store_u8(addr + 1, (v >> 8) & 0xFF)
        self.store_u8(addr + 2, (v >> 16) & 0xFF)
        self.store_u8(addr + 3, (v >> 24) & 0xFF)

    def write_rd(self, rd, val):
        if rd != 0:
            v = u32(val)
            self.x[rd] = v
            self.trace.append((self.commit_idx, rd, v))
            self.commit_idx += 1
        self.x[0] = 0

    def step(self):
        pc = self.pc
        insn = self.load_u32(pc)
        opcode = insn & 0x7F
        rd = (insn >> 7) & 0x1F
        funct3 = (insn >> 12) & 0x7
        rs1 = (insn >> 15) & 0x1F
        rs2 = (insn >> 20) & 0x1F
        funct7 = (insn >> 25) & 0x7F
        next_pc = u32(pc + 4)

        if opcode == 0x37:  # LUI
            imm = insn & 0xFFFFF000
            self.write_rd(rd, imm)
        elif opcode == 0x17:  # AUIPC
            imm = insn & 0xFFFFF000
            self.write_rd(rd, u32(pc + imm))
        elif opcode == 0x6F:  # JAL
            imm = (
                (((insn >> 31) & 0x1) << 20)
                | (((insn >> 12) & 0xFF) << 12)
                | (((insn >> 20) & 0x1) << 11)
                | (((insn >> 21) & 0x3FF) << 1)
            )
            imm = sext(imm, 21)
            self.write_rd(rd, next_pc)
            next_pc = u32(pc + imm)
        elif opcode == 0x67:  # JALR
            imm = sext((insn >> 20) & 0xFFF, 12)
            t = u32((self.x[rs1] + imm) & ~1)
            self.write_rd(rd, next_pc)
            next_pc = t
        elif opcode == 0x63:  # BRANCH
            imm = (
                (((insn >> 31) & 0x1) << 12)
                | (((insn >> 7) & 0x1) << 11)
                | (((insn >> 25) & 0x3F) << 5)
                | (((insn >> 8) & 0xF) << 1)
            )
            imm = sext(imm, 13)
            a = self.x[rs1]
            b = self.x[rs2]
            take = False
            if funct3 == 0x0:  # BEQ
                take = a == b
            elif funct3 == 0x1:  # BNE
                take = a != b
            elif funct3 == 0x4:  # BLT
                take = s32(a) < s32(b)
            elif funct3 == 0x5:  # BGE
                take = s32(a) >= s32(b)
            elif funct3 == 0x6:  # BLTU
                take = a < b
            elif funct3 == 0x7:  # BGEU
                take = a >= b
            else:
                raise RuntimeError(f"Unsupported BRANCH funct3={funct3} at pc=0x{pc:08x}")
            if take:
                next_pc = u32(pc + imm)
        elif opcode == 0x03:  # LOAD
            imm = sext((insn >> 20) & 0xFFF, 12)
            addr = u32(self.x[rs1] + imm)
            if funct3 == 0x0:  # LB
                v = sext(self.load_u8(addr), 8)
            elif funct3 == 0x1:  # LH
                v = sext(self.load_u16(addr), 16)
            elif funct3 == 0x2:  # LW
                v = self.load_u32(addr)
            elif funct3 == 0x4:  # LBU
                v = self.load_u8(addr)
            elif funct3 == 0x5:  # LHU
                v = self.load_u16(addr)
            else:
                raise RuntimeError(f"Unsupported LOAD funct3={funct3} at pc=0x{pc:08x}")
            self.write_rd(rd, v)
        elif opcode == 0x23:  # STORE
            imm = (((insn >> 25) & 0x7F) << 5) | ((insn >> 7) & 0x1F)
            imm = sext(imm, 12)
            addr = u32(self.x[rs1] + imm)
            v = self.x[rs2]
            if funct3 == 0x0:  # SB
                self.store_u8(addr, v)
            elif funct3 == 0x1:  # SH
                self.store_u16(addr, v)
            elif funct3 == 0x2:  # SW
                self.store_u32(addr, v)
            else:
                raise RuntimeError(f"Unsupported STORE funct3={funct3} at pc=0x{pc:08x}")
        elif opcode == 0x13:  # OP-IMM
            imm = sext((insn >> 20) & 0xFFF, 12)
            a = self.x[rs1]
            if funct3 == 0x0:  # ADDI
                v = a + imm
            elif funct3 == 0x2:  # SLTI
                v = 1 if s32(a) < imm else 0
            elif funct3 == 0x3:  # SLTIU
                v = 1 if a < u32(imm) else 0
            elif funct3 == 0x4:  # XORI
                v = a ^ u32(imm)
            elif funct3 == 0x6:  # ORI
                v = a | u32(imm)
            elif funct3 == 0x7:  # ANDI
                v = a & u32(imm)
            elif funct3 == 0x1:  # SLLI
                shamt = (insn >> 20) & 0x1F
                v = u32(a << shamt)
            elif funct3 == 0x5:
                shamt = (insn >> 20) & 0x1F
                if funct7 == 0x00:  # SRLI
                    v = a >> shamt
                elif funct7 == 0x20:  # SRAI
                    v = u32(s32(a) >> shamt)
                else:
                    raise RuntimeError(f"Unsupported shift-imm funct7={funct7} at pc=0x{pc:08x}")
            else:
                raise RuntimeError(f"Unsupported OP-IMM funct3={funct3} at pc=0x{pc:08x}")
            self.write_rd(rd, v)
        elif opcode == 0x33:  # OP
            a = self.x[rs1]
            b = self.x[rs2]
            if funct3 == 0x0:
                if funct7 == 0x00:  # ADD
                    v = a + b
                elif funct7 == 0x20:  # SUB
                    v = a - b
                else:
                    raise RuntimeError(f"Unsupported OP add/sub funct7={funct7} at pc=0x{pc:08x}")
            elif funct3 == 0x1 and funct7 == 0x00:  # SLL
                v = u32(a << (b & 0x1F))
            elif funct3 == 0x2 and funct7 == 0x00:  # SLT
                v = 1 if s32(a) < s32(b) else 0
            elif funct3 == 0x3 and funct7 == 0x00:  # SLTU
                v = 1 if a < b else 0
            elif funct3 == 0x4 and funct7 == 0x00:  # XOR
                v = a ^ b
            elif funct3 == 0x5:
                shamt = b & 0x1F
                if funct7 == 0x00:  # SRL
                    v = a >> shamt
                elif funct7 == 0x20:  # SRA
                    v = u32(s32(a) >> shamt)
                else:
                    raise RuntimeError(f"Unsupported OP shift funct7={funct7} at pc=0x{pc:08x}")
            elif funct3 == 0x6 and funct7 == 0x00:  # OR
                v = a | b
            elif funct3 == 0x7 and funct7 == 0x00:  # AND
                v = a & b
            else:
                raise RuntimeError(
                    f"Unsupported OP funct3={funct3} funct7={funct7} at pc=0x{pc:08x}"
                )
            self.write_rd(rd, v)
        elif opcode == 0x0F:  # FENCE / FENCE.I
            pass
        elif opcode == 0x73:  # SYSTEM
            # Keep ISS behavior aligned with simple core decode path: treat as no-op.
            pass
        else:
            raise RuntimeError(f"Unsupported opcode=0x{opcode:02x} at pc=0x{pc:08x}, insn=0x{insn:08x}")

        self.pc = next_pc
        self.x[0] = 0
        return True


def main():
    ap = argparse.ArgumentParser(description="Generate reference commit trace from RV32I .mem")
    ap.add_argument("--test", type=int, required=True, help="test id (24/25/26/27)")
    ap.add_argument("--memfile", default="", help="override memfile path")
    ap.add_argument("--out", required=True, help="output trace file")
    ap.add_argument("--max-steps", type=int, default=10_000_000, help="ISS max instruction steps")
    ap.add_argument("--allow-miss", action="store_true", help="dump partial trace even if expected write not reached")
    args = ap.parse_args()

    if args.test not in TEST_CFG:
        raise SystemExit(f"Unsupported test={args.test}. Supported: {sorted(TEST_CFG.keys())}")

    cfg = TEST_CFG[args.test]
    memfile = args.memfile if args.memfile else cfg["mem"]
    expect_rd = cfg["expect_rd"]
    expect_val = cfg["expect_val"] & 0xFFFFFFFF

    mem = parse_mem(memfile)
    iss = RV32I(mem)

    hit = False
    for _ in range(args.max_steps):
        ok = iss.step()
        if not ok:
            break
        if iss.trace:
            _, rd, val = iss.trace[-1]
            if rd == expect_rd and val == expect_val:
                hit = True
                break

    if (not hit) and (not args.allow_miss):
        raise SystemExit(
            f"Reference ISS did not reach expect write: test={args.test} rd=x{expect_rd} val=0x{expect_val:08x}"
        )

    with open(args.out, "w", encoding="utf-8") as f:
        f.write("# cycle rd wdata\n")
        for cyc, rd, val in iss.trace:
            f.write(f"{cyc} {rd} {val:08x}\n")

    if hit:
        print(f"REF_TRACE_OK test={args.test} commits={len(iss.trace)} out={args.out}")
    else:
        print(
            f"REF_TRACE_MISS test={args.test} commits={len(iss.trace)} out={args.out} "
            f"expect=x{expect_rd}:0x{expect_val:08x}"
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
