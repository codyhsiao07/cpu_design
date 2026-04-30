module id_illegal_decode_tb;
  reg clk;
  reg rst_n;
  reg [31:0] id_pc_i;
  reg [31:0] id_instr_i;
  reg id_valid_i;
  reg id_stall_i;
  reg [1:0] current_priv_i;
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
  wire id_csr_en_o;
  wire [2:0] id_csr_cmd_o;
  wire [11:0] id_csr_addr_o;
  wire id_ecall_o;
  wire id_ebreak_o;
  wire id_mret_o;
  wire id_illegal_o;

  integer failures;

  id_stage dut (
    .clk(clk),
    .rst_n(rst_n),
    .id_pc_i(id_pc_i),
    .id_instr_i(id_instr_i),
    .id_valid_i(id_valid_i),
    .id_stall_i(id_stall_i),
    .current_priv_i(current_priv_i),
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
    .id_mem_funct3_o(id_mem_funct3_o),
    .id_csr_en_o(id_csr_en_o),
    .id_csr_cmd_o(id_csr_cmd_o),
    .id_csr_addr_o(id_csr_addr_o),
    .id_ecall_o(id_ecall_o),
    .id_ebreak_o(id_ebreak_o),
    .id_mret_o(id_mret_o),
    .id_illegal_o(id_illegal_o)
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

  function [31:0] i_type_instr;
    input [11:0] imm12;
    input [4:0] rs1;
    input [2:0] funct3;
    input [4:0] rd;
    input [6:0] opcode;
    begin
      i_type_instr = {imm12, rs1, funct3, rd, opcode};
    end
  endfunction

  function [31:0] s_type_instr;
    input [6:0] imm_hi;
    input [4:0] rs2;
    input [4:0] rs1;
    input [2:0] funct3;
    input [4:0] imm_lo;
    input [6:0] opcode;
    begin
      s_type_instr = {imm_hi, rs2, rs1, funct3, imm_lo, opcode};
    end
  endfunction

  task check_illegal;
    input [31:0] instr;
    input expected_illegal;
    input integer case_id;
    begin
      id_instr_i = instr;
      #1;
      if (id_illegal_o !== expected_illegal) begin
        $display("FAIL case=%0d illegal got=%0d exp=%0d instr=%08h", case_id, id_illegal_o, expected_illegal, instr);
        failures = failures + 1;
      end
      if (expected_illegal) begin
        if (reg_write_o || mem_read_o || mem_write_o || branch_o || jal_o || jalr_o || id_csr_en_o ||
            id_ecall_o || id_ebreak_o || id_mret_o) begin
          $display("FAIL case=%0d illegal instruction still has side effects", case_id);
          failures = failures + 1;
        end
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
    current_priv_i = 2'b11;
    wb_we_i = 1'b0;
    wb_rd_i = 5'd0;
    wb_wd_i = 32'b0;
    failures = 0;

    repeat (2) @(posedge clk);
    rst_n = 1'b1;
    #1;

    check_illegal(i_type_instr(12'h300, 5'd2, 3'b001, 5'd1, 7'b1110011), 1'b0, 1); // legal CSRRW mstatus
    check_illegal(i_type_instr(12'hC00, 5'd2, 3'b001, 5'd1, 7'b1110011), 1'b1, 2); // unsupported CSR
    check_illegal(i_type_instr(12'h300, 5'd2, 3'b101, 5'd1, 7'b1110011), 1'b0, 3); // legal CSRRWI mstatus
    check_illegal(i_type_instr(12'h004, 5'd2, 3'b001, 5'd1, 7'b1100111), 1'b1, 4); // JALR with bad funct3
    check_illegal(r_type_instr(7'b0000000, 5'd3, 5'd2, 3'b010, 5'd1, 7'b1100011), 1'b1, 5); // invalid branch funct3
    check_illegal(i_type_instr(12'h004, 5'd2, 3'b011, 5'd1, 7'b0000011), 1'b1, 6); // invalid load funct3
    check_illegal(s_type_instr(7'b0000000, 5'd3, 5'd2, 3'b011, 5'd4, 7'b0100011), 1'b1, 7); // invalid store funct3
    check_illegal(i_type_instr(12'b0100000_00001, 5'd2, 3'b001, 5'd1, 7'b0010011), 1'b1, 8); // bad SLLI encoding
    check_illegal(r_type_instr(7'b0000001, 5'd3, 5'd2, 3'b000, 5'd1, 7'b0110011), 1'b0, 9); // legal MUL
    check_illegal(r_type_instr(7'b0010000, 5'd3, 5'd2, 3'b000, 5'd1, 7'b0110011), 1'b1, 10); // bad OP funct7
    check_illegal(32'h0000_000F, 1'b0, 11); // legal FENCE decoded as NOP
    check_illegal(32'hFFFF_FFFF, 1'b1, 12); // unknown opcode
    current_priv_i = 2'b00;
    check_illegal(32'h3020_0073, 1'b1, 13); // mret illegal outside M-mode
    check_illegal(i_type_instr(12'h300, 5'd2, 3'b001, 5'd1, 7'b1110011), 1'b1, 14); // machine CSR illegal in U-mode

    if (failures != 0) begin
      $display("FAIL: id_illegal_decode_tb failures=%0d", failures);
      $finish(1);
    end

    $display("PASS: id_illegal_decode_tb");
    $finish;
  end
endmodule
