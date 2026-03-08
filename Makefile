# Build a single C bare-metal RV32I program into ELF/BIN/MEM for this repo.
# Usage:
#   make
#   make SRC=OS/my_os.c OUT_NAME=my_os MEM_OUT=TEST_FILES/mem_my_os.mem
#   make disasm
#   make run-sim
#   make clean

CC_PREFIX       ?= C:/riscv/xpack-riscv-none-elf-gcc/bin/riscv64-unknown-elf-
BINUTILS_PREFIX ?= C:/riscv/xpack-riscv-none-elf-gcc/bin/riscv-none-elf-
CC       := $(CC_PREFIX)gcc
OBJCOPY  := $(BINUTILS_PREFIX)objcopy
OBJDUMP  := $(BINUTILS_PREFIX)objdump
PYTHON   ?= python

GAME_DIR ?= game
SRC      ?= $(GAME_DIR)/game.c
EXTRA_SRCS ?=
CRT0     ?= tools/crt0.S
LDSCRIPT ?= tools/link_ddr.ld

BUILD_DIR ?= build_os
OUT_NAME  ?= game
MEM_OUT   ?= TEST_FILES/mem_game.mem

SIM_EXE       ?= icache_pipeline_tb.out
SIM_MAXCYCLES ?= 500000
SIM_EXPECT_RD ?= 8
SIM_EXPECT_VAL ?= 00000011
GAMES_MENU_EXTRA_SRCS := $(GAME_DIR)/games_shared_ui.c $(GAME_DIR)/game_tictactoe_menu.c $(GAME_DIR)/game_tictactoe_core.c $(GAME_DIR)/game_tetris_menu.c $(GAME_DIR)/game_tetris_core.c

APP_DEFINES ?= -DGAME_USE_UART
CFLAGS  ?= -march=rv32i -mabi=ilp32 -ffreestanding -nostdlib -O2 -Wall -Wextra $(APP_DEFINES)
LDFLAGS ?= -march=rv32i -mabi=ilp32 -nostdlib -Wl,-T,$(LDSCRIPT) -Wl,-Map,$(BUILD_DIR)/$(OUT_NAME).map

SRC_BASE := $(notdir $(basename $(SRC)))
CRT0_OBJ := $(BUILD_DIR)/crt0.o
SRC_OBJ  := $(BUILD_DIR)/$(SRC_BASE).o
EXTRA_SRCS_STRIPPED := $(strip $(EXTRA_SRCS))
EXTRA_OBJS := $(foreach src,$(EXTRA_SRCS_STRIPPED),$(BUILD_DIR)/$(notdir $(basename $(src))).o)
ELF      := $(BUILD_DIR)/$(OUT_NAME).elf
BIN      := $(BUILD_DIR)/$(OUT_NAME).bin
DISASM   := $(BUILD_DIR)/$(OUT_NAME).dis

.PHONY: help all check-tools print-config elf bin mem games-menu disasm run-sim uart-mmio-tb clean

.DEFAULT_GOAL := all

help:
	@echo "Targets:"
	@echo "  make / make all   : build MEM image ($(MEM_OUT))"
	@echo "  make elf          : build ELF ($(ELF))"
	@echo "  make bin          : build BIN ($(BIN))"
	@echo "  make mem          : build MEM ($(MEM_OUT))"
	@echo "  make games-menu   : build TEST_FILES/mem_games_menu.mem"
	@echo "  make disasm       : generate disassembly ($(DISASM))"
	@echo "  make run-sim      : run main TB with +MEMFILE=$(MEM_OUT)"
	@echo "  make uart-mmio-tb : run dedicated UART MMIO regression TB"
	@echo "  make clean        : remove build outputs"
	@echo ""
	@echo "Common overrides:"
	@echo "  GAME_DIR=game"
	@echo "  SRC=$(GAME_DIR)/game.c"
	@echo "  EXTRA_SRCS="
	@echo "  OUT_NAME=game"
	@echo "  MEM_OUT=TEST_FILES/mem_game.mem"
	@echo "  APP_DEFINES=-DGAME_USE_UART"
	@echo "  CC_PREFIX=C:/riscv/xpack-riscv-none-elf-gcc/bin/riscv64-unknown-elf-"
	@echo "  BINUTILS_PREFIX=C:/riscv/xpack-riscv-none-elf-gcc/bin/riscv-none-elf-"
	@echo "  PYTHON=python"

all: mem

check-tools:
	@$(CC) --version
	@$(OBJCOPY) --version
	@$(OBJDUMP) --version
	@$(PYTHON) --version

print-config:
	@echo "SRC=$(SRC)"
	@echo "EXTRA_SRCS=$(EXTRA_SRCS)"
	@echo "CRT0=$(CRT0)"
	@echo "LDSCRIPT=$(LDSCRIPT)"
	@echo "BUILD_DIR=$(BUILD_DIR)"
	@echo "OUT_NAME=$(OUT_NAME)"
	@echo "MEM_OUT=$(MEM_OUT)"
	@echo "APP_DEFINES=$(APP_DEFINES)"
	@echo "CC_PREFIX=$(CC_PREFIX)"
	@echo "BINUTILS_PREFIX=$(BINUTILS_PREFIX)"
	@echo "SIM_EXE=$(SIM_EXE)"
	@echo "SIM_EXPECT_RD=$(SIM_EXPECT_RD)"
	@echo "SIM_EXPECT_VAL=$(SIM_EXPECT_VAL)"

$(BUILD_DIR):
	$(PYTHON) -c "import os; os.makedirs(r'$(BUILD_DIR)', exist_ok=True)"

$(CRT0_OBJ): $(CRT0) | $(BUILD_DIR)
	$(PYTHON) -c "import os; os.makedirs(r'$(BUILD_DIR)', exist_ok=True)"
	$(CC) $(CFLAGS) -c $< -o $@

$(SRC_OBJ): $(SRC) | $(BUILD_DIR)
	$(PYTHON) -c "import os; os.makedirs(r'$(BUILD_DIR)', exist_ok=True)"
	$(CC) $(CFLAGS) -c $< -o $@

define EXTRA_COMPILE_RULE
$(BUILD_DIR)/$(notdir $(basename $(1))).o: $(1) | $(BUILD_DIR)
	$(PYTHON) -c "import os; os.makedirs(r'$(BUILD_DIR)', exist_ok=True)"
	$(CC) $(CFLAGS) -c $$< -o $$@
endef

$(foreach src,$(EXTRA_SRCS_STRIPPED),$(eval $(call EXTRA_COMPILE_RULE,$(src))))

$(ELF): check-tools $(CRT0_OBJ) $(SRC_OBJ) $(EXTRA_OBJS) $(LDSCRIPT)
	$(PYTHON) -c "import os; os.makedirs(r'$(BUILD_DIR)', exist_ok=True)"
	$(CC) $(LDFLAGS) -o $@ $(CRT0_OBJ) $(SRC_OBJ) $(EXTRA_OBJS)

elf: $(ELF)
	@echo "Built: $(ELF)"

$(BIN): $(ELF)
	$(OBJCOPY) -O binary $< $@

bin: $(BIN)
	@echo "Built: $(BIN)"

$(MEM_OUT): $(BIN)
	$(PYTHON) tools/bin_to_mem.py $< $@

mem: $(MEM_OUT)
	@echo "Built: $(MEM_OUT)"

games-menu:
	$(MAKE) GAME_DIR=$(GAME_DIR) SRC=$(GAME_DIR)/games_menu.c EXTRA_SRCS="$(GAMES_MENU_EXTRA_SRCS)" OUT_NAME=games_menu MEM_OUT=TEST_FILES/mem_games_menu.mem mem

$(DISASM): $(ELF)
	$(OBJDUMP) -D $< > $@

disasm: $(DISASM)
	@echo "Built: $(DISASM)"

run-sim: $(MEM_OUT)
	vvp $(SIM_EXE) +TEST=0 +MEMFILE=$(MEM_OUT) +ASSERT_EN=1 +MAXCYCLES=$(SIM_MAXCYCLES) +EXPECT_RD=$(SIM_EXPECT_RD) +EXPECT_VAL=$(SIM_EXPECT_VAL)

uart-mmio-tb: | $(BUILD_DIR)
	iverilog -g2005-sv -DFAST_SIM -i -o $(BUILD_DIR)/uart_mmio_tb.out -s uart_mmio_tb *.v
	vvp $(BUILD_DIR)/uart_mmio_tb.out

clean:
	$(PYTHON) -c "import shutil; shutil.rmtree(r'$(BUILD_DIR)', ignore_errors=True)"
	$(PYTHON) -c "import os; p=r'$(MEM_OUT)'; os.remove(p) if os.path.exists(p) else None"
	@echo "Cleaned build outputs."
