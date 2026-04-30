module id_csr_decode_tb;
  localparam [2:0] CSR_CMD_NONE = 3'b000;
  localparam [2:0] CSR_CMD_W    = 3'b001;
  localparam [2:0] CSR_CMD_S    = 3'b010;
  localparam [2:0] CSR_CMD_C    = 3'b011;

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

  function [31:0] csr_instr;
    input [11:0] csr_addr;
    input [4:0] rs1;
    input [2:0] funct3;
    input [4:0] rd;
    begin
      csr_instr = {csr_addr, rs1, funct3, rd, 7'b1110011};
    end
  endfunction

  task check_case;
    input [31:0] instr;
    input expected_csr_en;
    input [2:0] expected_csr_cmd;
    input [11:0] expected_csr_addr;
    input expected_reg_write;
    input integer case_id;
    begin
      id_instr_i = instr;
      #1;
      if (id_csr_en_o !== expected_csr_en) begin
        $display("FAIL case=%0d csr_en got=%0d exp=%0d", case_id, id_csr_en_o, expected_csr_en);
        failures = failures + 1;
      end
      if (id_csr_cmd_o !== expected_csr_cmd) begin
        $display("FAIL case=%0d csr_cmd got=%0b exp=%0b", case_id, id_csr_cmd_o, expected_csr_cmd);
        failures = failures + 1;
      end
      if (id_csr_addr_o !== expected_csr_addr) begin
        $display("FAIL case=%0d csr_addr got=%03h exp=%03h", case_id, id_csr_addr_o, expected_csr_addr);
        failures = failures + 1;
      end
      if (reg_write_o !== expected_reg_write) begin
        $display("FAIL case=%0d reg_write got=%0d exp=%0d", case_id, reg_write_o, expected_reg_write);
        failures = failures + 1;
      end
      if (id_ecall_o || id_ebreak_o || id_mret_o || id_illegal_o) begin
        $display("FAIL case=%0d unexpected system-exception decode", case_id);
        failures = failures + 1;
      end
      if (branch_o || jal_o || jalr_o || mem_read_o || mem_write_o) begin
        $display("FAIL case=%0d unexpected side-effect controls", case_id);
        failures = failures + 1;
      end
    end
  endtask

  task check_sys_case;
    input [31:0] instr;
    input expected_ecall;
    input expected_ebreak;
    input expected_mret;
    input integer case_id;
    begin
      id_instr_i = instr;
      #1;
      if (id_csr_en_o !== 1'b0 || id_csr_cmd_o !== CSR_CMD_NONE || reg_write_o !== 1'b0 || id_illegal_o !== 1'b0) begin
        $display("FAIL case=%0d system decode should not look like CSR RMW", case_id);
        failures = failures + 1;
      end
      if (id_ecall_o !== expected_ecall) begin
        $display("FAIL case=%0d ecall got=%0d exp=%0d", case_id, id_ecall_o, expected_ecall);
        failures = failures + 1;
      end
      if (id_ebreak_o !== expected_ebreak) begin
        $display("FAIL case=%0d ebreak got=%0d exp=%0d", case_id, id_ebreak_o, expected_ebreak);
        failures = failures + 1;
      end
      if (id_mret_o !== expected_mret) begin
        $display("FAIL case=%0d mret got=%0d exp=%0d", case_id, id_mret_o, expected_mret);
        failures = failures + 1;
      end
    end
  endtask

  task check_illegal_case;
    input [31:0] instr;
    input integer case_id;
    begin
      id_instr_i = instr;
      #1;
      if (id_illegal_o !== 1'b1) begin
        $display("FAIL case=%0d illegal got=%0d exp=1", case_id, id_illegal_o);
        failures = failures + 1;
      end
      if (id_csr_en_o || reg_write_o || id_ecall_o || id_ebreak_o || id_mret_o) begin
        $display("FAIL case=%0d illegal decode still has side effects", case_id);
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
    current_priv_i = 2'b11;
    wb_we_i = 1'b0;
    wb_rd_i = 5'b0;
    wb_wd_i = 32'b0;
    failures = 0;

    repeat (2) @(posedge clk);
    rst_n = 1'b1;
    #1;

    check_case(csr_instr(12'h300, 5'd2, 3'b001, 5'd1), 1'b1, CSR_CMD_W, 12'h300, 1'b1, 1);
    check_case(csr_instr(12'h304, 5'd3, 3'b010, 5'd4), 1'b1, CSR_CMD_S, 12'h304, 1'b1, 2);
    check_case(csr_instr(12'h305, 5'd5, 3'b011, 5'd6), 1'b1, CSR_CMD_C, 12'h305, 1'b1, 3);
    check_case(csr_instr(12'h341, 5'd0, 3'b101, 5'd7), 1'b1, CSR_CMD_W, 12'h341, 1'b1, 4);
    check_case(csr_instr(12'h300, 5'd8, 3'b111, 5'd0), 1'b1, CSR_CMD_C, 12'h300, 1'b1, 11);
    check_case(32'h0000_0013, 1'b0, CSR_CMD_NONE, 12'h000, 1'b1, 5);
    check_sys_case(32'h0000_0073, 1'b1, 1'b0, 1'b0, 6);
    check_sys_case(32'h0010_0073, 1'b0, 1'b1, 1'b0, 7);
    check_sys_case(32'h3020_0073, 1'b0, 1'b0, 1'b1, 8);
    current_priv_i = 2'b00;
    check_illegal_case(csr_instr(12'h300, 5'd2, 3'b001, 5'd1), 9);
    check_illegal_case(32'h3020_0073, 10);
    current_priv_i = 2'b11;
    check_illegal_case(csr_instr(12'hF14, 5'd1, 3'b101, 5'd1), 12);

    if (failures != 0) begin
      $display("FAIL: id_csr_decode_tb failures=%0d", failures);
      $finish(1);
    end

    $display("PASS: id_csr_decode_tb");
    $finish;
  end
endmodule
