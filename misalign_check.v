`timescale 1ns / 1ps

module misalign_check (
    input         is_ctrl_taken_i,
    input  [31:0] ctrl_target_i,
    input         mem_read_i,
    input         mem_write_i,
    input  [2:0]  mem_funct3_i,
    input  [31:0] mem_addr_i,
    output        insn_addr_misaligned_o,
    output        load_addr_misaligned_o,
    output        store_addr_misaligned_o
);

    wire load_half_misaligned =
        ((mem_funct3_i == 3'b001) || (mem_funct3_i == 3'b101)) && mem_addr_i[0];
    wire load_word_misaligned =
        (mem_funct3_i == 3'b010) && (mem_addr_i[1:0] != 2'b00);
    wire store_half_misaligned =
        (mem_funct3_i == 3'b001) && mem_addr_i[0];
    wire store_word_misaligned =
        (mem_funct3_i == 3'b010) && (mem_addr_i[1:0] != 2'b00);

    assign insn_addr_misaligned_o  = is_ctrl_taken_i && (ctrl_target_i[1:0] != 2'b00);
    assign load_addr_misaligned_o  = mem_read_i  && (load_half_misaligned  || load_word_misaligned);
    assign store_addr_misaligned_o = mem_write_i && (store_half_misaligned || store_word_misaligned);

endmodule
