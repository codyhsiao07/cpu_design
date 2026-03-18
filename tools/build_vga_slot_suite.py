import argparse
import os
import re
import subprocess
from pathlib import Path


BASE_ADDR = 0x80000000
MENU_REGION_LENGTH = 0x00080000
GAME_REGION_LENGTH = 0x00020000
ARCH = "rv32im"
IMAGE_ARCH_OVERRIDES = {
    "menu": "rv32i",
    "chess": "rv32i",
}

IMAGES = [
    ("menu", 0x80000000, MENU_REGION_LENGTH, "tools/crt0.S", None,
     ["game/vga_games_menu.c", "game/launcher_menu_return.S", "game/games_shared_ui.c", "game/vga_fb.c", "game/launcher_jump.c"]),
    ("gomoku", 0x80080000, GAME_REGION_LENGTH, "tools/crt0.S", None,
     [("game/Gomoku_vga.c", ["-Dmain=gomoku_vga_slot_entry"]),
      "game/gomoku_slot_wrapper.c",
      "game/games_shared_ui.c",
      "game/vga_fb.c",
      "game/launcher_jump.c"]),
    ("tetris", 0x800A0000, GAME_REGION_LENGTH, "tools/launcher_slot_crt0.S", "UI_INPUT_POLICY_IGNORE_Q",
     ["game/Tetris_vga.c", "game/games_shared_ui.c", "game/vga_fb.c", "game/launcher_jump.c", "game/launcher_slot_boot.c"]),
    ("breakout", 0x800C0000, GAME_REGION_LENGTH, "tools/launcher_slot_crt0.S", "UI_INPUT_POLICY_IGNORE_Q",
     ["game/Breakout_vga.c", "game/games_shared_ui.c", "game/vga_fb.c", "game/launcher_jump.c", "game/launcher_slot_boot.c"]),
    ("snake", 0x800E0000, GAME_REGION_LENGTH, "tools/launcher_slot_crt0.S", "UI_INPUT_POLICY_IGNORE_Q",
     ["game/Snake_vga.c", "game/games_shared_ui.c", "game/vga_fb.c", "game/launcher_jump.c", "game/launcher_slot_boot.c"]),
    ("mines", 0x80100000, GAME_REGION_LENGTH, "tools/launcher_slot_crt0.S", "UI_INPUT_POLICY_IGNORE_Q",
     ["game/Mines_vga.c", "game/games_shared_ui.c", "game/vga_fb.c", "game/launcher_jump.c", "game/launcher_slot_boot.c"]),
    ("bomber", 0x80120000, GAME_REGION_LENGTH, "tools/launcher_slot_crt0.S", "UI_INPUT_POLICY_IGNORE_Q",
     ["game/Bomber_vga.c", "game/games_shared_ui.c", "game/vga_fb.c", "game/launcher_jump.c", "game/launcher_slot_boot.c"]),
    ("sokoban", 0x80140000, GAME_REGION_LENGTH, "tools/launcher_slot_crt0.S", "UI_INPUT_POLICY_IGNORE_Q",
     ["game/Sokoban_vga.c", "game/games_shared_ui.c", "game/vga_fb.c", "game/launcher_jump.c", "game/launcher_slot_boot.c"]),
    ("pacman", 0x80160000, GAME_REGION_LENGTH, "tools/launcher_slot_crt0.S", "UI_INPUT_POLICY_IGNORE_Q",
     ["game/Pacman_vga.c", "game/games_shared_ui.c", "game/vga_fb.c", "game/launcher_jump.c", "game/launcher_slot_boot.c"]),
    ("chess", 0x80180000, GAME_REGION_LENGTH, "tools/launcher_slot_crt0.S", "UI_INPUT_POLICY_IGNORE_Q",
     ["game/Chess_vga.c", "game/games_shared_ui.c", "game/vga_fb.c", "game/launcher_jump.c", "game/launcher_slot_boot.c"]),
]


def write_linker_script(path: Path, origin: int, length: int) -> None:
    path.write_text(
        f"""ENTRY(_start)

MEMORY
{{
  DDR (rwx) : ORIGIN = 0x{origin:08X}, LENGTH = 0x{length:08X}
}}

SECTIONS
{{
  . = ORIGIN(DDR);

  .text : {{
    *(.text.start)
    *(.text*)
    *(.rodata*)
  }} > DDR

  .data : {{
    __global_pointer$ = . + 0x800;
    *(.sdata*)
    *(.data*)
  }} > DDR

  .bss : {{
    . = ALIGN(4);
    __bss_start = .;
    *(.sbss*)
    *(.bss*)
    *(COMMON)
    . = ALIGN(4);
    __bss_end = .;
  }} > DDR

  . = ALIGN(16);
  __stack_top = ORIGIN(DDR) + LENGTH(DDR) - 4;
}}
""",
        encoding="ascii",
    )


def run(cmd, cwd: Path) -> None:
    subprocess.run(cmd, cwd=str(cwd), check=True)


def source_desc(src):
    if isinstance(src, tuple):
        return src[0], list(src[1])
    return src, []


def validate_images(images) -> None:
    previous_end = BASE_ADDR

    for name, origin, length, *_rest in images:
        if origin < BASE_ADDR:
            raise RuntimeError(f"{name} image origin 0x{origin:08X} is below DDR base")
        if length <= 0:
            raise RuntimeError(f"{name} image length must be positive")
        if origin < previous_end:
            raise RuntimeError(
                f"{name} image origin 0x{origin:08X} overlaps previous image ending at 0x{previous_end:08X}"
            )
        previous_end = origin + length


def symbol_addr_from_map(map_path: Path, symbol: str) -> int:
    pattern = re.compile(r"^\s*0x([0-9A-Fa-f]+)\s+" + re.escape(symbol) + r"(?:\s|$).*")
    for line in map_path.read_text(encoding="ascii", errors="ignore").splitlines():
        match = pattern.match(line)
        if match is not None:
            return int(match.group(1), 16)
    raise RuntimeError(f"symbol {symbol} not found in {map_path}")


def main() -> None:
    ap = argparse.ArgumentParser(description="Build slot-based VGA game suite")
    ap.add_argument("--build-dir", default="build_os/vga_slot_suite")
    ap.add_argument("--out-mem", default="TEST_FILES/mem_vga_games_menu.mem")
    ap.add_argument("--out-bin", default="build_os/vga_slot_suite/vga_games_menu_slots.bin")
    ap.add_argument("--objcopy", default="C:/riscv/xpack-riscv-none-elf-gcc/bin/riscv-none-elf-objcopy")
    ap.add_argument("--gcc", default="C:/riscv/xpack-riscv-none-elf-gcc/bin/riscv64-unknown-elf-gcc")
    ap.add_argument("--python", default="python")
    args = ap.parse_args()

    repo = Path(__file__).resolve().parent.parent
    build_dir = repo / args.build_dir
    out_bin = repo / args.out_bin
    out_mem = repo / args.out_mem
    build_dir.mkdir(parents=True, exist_ok=True)
    out_bin.parent.mkdir(parents=True, exist_ok=True)
    out_mem.parent.mkdir(parents=True, exist_ok=True)
    validate_images(IMAGES)

    combined = bytearray()
    combined_end = 0

    common_flags = [
        f"-march={ARCH}",
        "-mabi=ilp32",
        "-ffreestanding",
        "-nostdlib",
        "-O2",
        "-Wall",
        "-Wextra",
        "-DGAME_USE_UART",
    ]
    link_flags = [
        f"-march={ARCH}",
        "-mabi=ilp32",
        "-nostdlib",
    ]

    menu_return_addr = None
    menu_soft_reset_addr = None
    for name, origin, length, crt0, policy, srcs in IMAGES:
        ld_path = build_dir / f"{name}.ld"
        elf_path = build_dir / f"{name}.elf"
        bin_path = build_dir / f"{name}.bin"
        map_path = build_dir / f"{name}.map"
        crt0_obj = build_dir / f"{name}__crt0.o"
        obj_paths = []

        write_linker_script(ld_path, origin, length)

        image_arch = IMAGE_ARCH_OVERRIDES.get(name, ARCH)
        image_flags = [
            f"-march={image_arch}",
            "-mabi=ilp32",
            "-ffreestanding",
            "-nostdlib",
            "-O2",
            "-Wall",
            "-Wextra",
            "-DGAME_USE_UART",
        ]
        image_link_flags = [
            f"-march={image_arch}",
            "-mabi=ilp32",
            "-nostdlib",
        ]
        image_link_libs = []
        if image_arch != ARCH:
            image_link_libs.append("-lgcc")

        if policy is not None:
            image_flags.append(f"-DLAUNCHER_INPUT_POLICY={policy}")
        if name != "menu":
            image_flags.append("-DLAUNCHER_SOFT_MENU_BUTTON=1")
        if name in {"gomoku"}:
            image_flags.append("-DLAUNCHER_DIRECT_MENU_JUMP=1")
        if name != "menu" and menu_return_addr is not None:
            image_flags.append(f"-DLAUNCHER_MENU_RETURN_ADDR=0x{menu_return_addr:08X}")
        if name != "menu" and menu_soft_reset_addr is not None:
            image_flags.append(f"-DLAUNCHER_MENU_SOFT_RESET_ADDR=0x{menu_soft_reset_addr:08X}")

        run([
            args.gcc,
            *image_flags,
            "-c",
            crt0,
            "-o",
            str(crt0_obj),
        ], repo)

        for index, src in enumerate(srcs):
            src_path, extra_flags = source_desc(src)
            obj_path = build_dir / f"{name}__{index}_{Path(src_path).stem}.o"
            run([
                args.gcc,
                *image_flags,
                *extra_flags,
                "-c",
                src_path,
                "-o",
                str(obj_path),
            ], repo)
            obj_paths.append(obj_path)

        run([
            args.gcc,
            *image_link_flags,
            f"-Wl,-T,{ld_path}",
            f"-Wl,-Map,{map_path}",
            "-o",
            str(elf_path),
            str(crt0_obj),
            *[str(path) for path in obj_paths],
            *image_link_libs,
        ], repo)

        if name == "menu":
            menu_return_addr = symbol_addr_from_map(map_path, "launcher_menu_return_entry")
            menu_soft_reset_addr = symbol_addr_from_map(map_path, "launcher_menu_soft_reset_entry")

        run([args.objcopy, "-O", "binary", str(elf_path), str(bin_path)], repo)

        image = bin_path.read_bytes()
        if len(image) > length:
            raise RuntimeError(f"{name} image too large: {len(image)} bytes > region {length} bytes")

        offset = origin - BASE_ADDR
        end = offset + len(image)
        if end > len(combined):
            combined.extend(b"\x00" * (end - len(combined)))
        combined[offset:end] = image
        if end > combined_end:
            combined_end = end

    out_bin.write_bytes(combined[:combined_end])
    run([args.python, "tools/bin_to_mem.py", str(out_bin), str(out_mem)], repo)


if __name__ == "__main__":
    main()
