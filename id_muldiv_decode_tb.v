module id_muldiv_decode_tb;
  localparam [3:0] ALU_ADD    = 4'b0000;
  localparam [3:0] ALU_MUL    = 4'b1000;
  localparam [3:0] ALU_MULH   = 4'b1001;
  localparam [3:0] ALU_MULHSU = 4'b1010;
  localparam [3:0] ALU_MULHU  = 4'b1011;
  localparam [3:0] ALU_DIV    = 4'b1100;
  localparam [3:0] ALU_DIVU   = 4'b1101;
  localparam [3:0] ALU_REM    = 4'b1110;
  localparam [3:0] ALU_REMU   = 4'b1111;

  reg clk;
  reg rst_n;
  reg [31:0] id_pc_i;
  reg [31:0] id_instr_i;
  reg id_valid_i;
  reg id_stall_i;
  reg wb_we_i;
  reg [4:0] wb_rd_i;
  reg [31:0] wb_wd_i;

  wire [31:0] rs1_val_o;
  wire [31:0] rs2_val_o;
  wire [31:0] imm_o;
  wire [4:0] rs1_o;
  wire [4:0] rs2_o;
  wire [4:0] rd_o;
  wire [3:0] alu_op_o;
  wire alu_src_imm_o;
  wire branch_o;
  wire jal_o;
  wire jalr_o;
  wire mem_read_o;
  wire mem_write_o;
  wire [1:0] wb_sel_o;
  wire reg_write_o;
  wire [2:0] br_funct3_o;
  wire [31:0] pc_o;
  wire id_ready_o;
  wire id_shift_right_o;
  wire id_shift_arith_o;
  wire id_is_auipc_o;
  wire id_is_lui_o;
  wire [2:0] id_mem_funct3_o;

  integer failures;

  id_stage dut (
    .clk(clk),
    .rst_n(rst_n),
    .id_pc_i(id_pc_i),
    .id_instr_i(id_instr_i),
    .id_valid_i(id_valid_i),
    .id_stall_i(id_stall_i),
    .wb_we_i(wb_we_i),
    .wb_rd_i(wb_rd_i),
    .wb_wd_i(wb_wd_i),
    .rs1_val_o(rs1_val_o),
    .rs2_val_o(rs2_val_o),
    .imm_o(imm_o),
    .rs1_o(rs1_o),
    .rs2_o(rs2_o),
    .rd_o(rd_o),
    .alu_op_o(alu_op_o),
    .alu_src_imm_o(alu_src_imm_o),
    .branch_o(branch_o),
    .jal_o(jal_o),
    .jalr_o(jalr_o),
    .mem_read_o(mem_read_o),
    .mem_write_o(mem_write_o),
    .wb_sel_o(wb_sel_o),
    .reg_write_o(reg_write_o),
    .br_funct3_o(br_funct3_o),
    .pc_o(pc_o),
    .id_ready_o(id_ready_o),
    .id_shift_right_o(id_shift_right_o),
    .id_shift_arith_o(id_shift_arith_o),
    .id_is_auipc_o(id_is_auipc_o),
    .id_is_lui_o(id_is_lui_o),
    .id_mem_funct3_o(id_mem_funct3_o)
  );

  always #5 clk = ~clk;

  function [31:0] r_type_instr;
    input [6:0] funct7;
    input [4:0] rs2;
    input [4:0] rs1;
    input [2:0] funct3;
    input [4:0] rd;
    input [6:0] opcode;
    begin
      r_type_instr = {funct7, rs2, rs1, funct3, rd, opcode};
    end
  endfunction

  task check_case;
    input [31:0] instr;
    input [3:0] expected_op;
    input integer case_id;
    begin
      id_instr_i = instr;
      #1;
      if (alu_op_o !== expected_op) begin
        $display("FAIL case=%0d instr=%h alu_op=%h exp=%h", case_id, instr, alu_op_o, expected_op);
        failures = failures + 1;
      end
      if (!reg_write_o || alu_src_imm_o || branch_o || jal_o || jalr_o || mem_read_o || mem_write_o) begin
        $display("FAIL case=%0d instr=%h control mismatch", case_id, instr);
        failures = failures + 1;
      end
    end
  endtask

  initial begin
    clk = 1'b0;
    rst_n = 1'b0;
    id_pc_i = 32'h8000_0000;
    id_instr_i = 32'h0000_0013;
    id_valid_i = 1'b1;
    id_stall_i = 1'b0;
    wb_we_i = 1'b0;
    wb_rd_i = 5'b0;
    wb_wd_i = 32'b0;
    failures = 0;

    repeat (2) @(posedge clk);
    rst_n = 1'b1;
    #1;

    check_case(r_type_instr(7'b0000001, 5'd3, 5'd2, 3'b000, 5'd1, 7'b0110011), ALU_MUL, 1);
    check_case(r_type_instr(7'b0000001, 5'd3, 5'd2, 3'b001, 5'd1, 7'b0110011), ALU_MULH, 2);
    check_case(r_type_instr(7'b0000001, 5'd3, 5'd2, 3'b010, 5'd1, 7'b0110011), ALU_MULHSU, 3);
    check_case(r_type_instr(7'b0000001, 5'd3, 5'd2, 3'b011, 5'd1, 7'b0110011), ALU_MULHU, 4);
    check_case(r_type_instr(7'b0000001, 5'd3, 5'd2, 3'b100, 5'd1, 7'b0110011), ALU_DIV, 5);
    check_case(r_type_instr(7'b0000001, 5'd3, 5'd2, 3'b101, 5'd1, 7'b0110011), ALU_DIVU, 6);
    check_case(r_type_instr(7'b0000001, 5'd3, 5'd2, 3'b110, 5'd1, 7'b0110011), ALU_REM, 7);
    check_case(r_type_instr(7'b0000001, 5'd3, 5'd2, 3'b111, 5'd1, 7'b0110011), ALU_REMU, 8);
    check_case(r_type_instr(7'b0000000, 5'd3, 5'd2, 3'b000, 5'd1, 7'b0110011), ALU_ADD, 9);

    if (failures != 0) begin
      $display("FAIL: id_muldiv_decode_tb failures=%0d", failures);
      $finish(1);
    end

    $display("PASS: id_muldiv_decode_tb");
    $finish;
  end

endmodule
