module misalign_check_tb;
  reg is_ctrl_taken_i;
  reg [31:0] ctrl_target_i;
  reg mem_read_i;
  reg mem_write_i;
  reg [2:0] mem_funct3_i;
  reg [31:0] mem_addr_i;
  wire insn_addr_misaligned_o;
  wire load_addr_misaligned_o;
  wire store_addr_misaligned_o;
  integer failures;

  misalign_check dut (
    .is_ctrl_taken_i(is_ctrl_taken_i),
    .ctrl_target_i(ctrl_target_i),
    .mem_read_i(mem_read_i),
    .mem_write_i(mem_write_i),
    .mem_funct3_i(mem_funct3_i),
    .mem_addr_i(mem_addr_i),
    .insn_addr_misaligned_o(insn_addr_misaligned_o),
    .load_addr_misaligned_o(load_addr_misaligned_o),
    .store_addr_misaligned_o(store_addr_misaligned_o)
  );

  task check_cond;
    input cond;
    input [255:0] msg;
    begin
      if (!cond) begin
        $display("FAIL: %0s", msg);
        failures = failures + 1;
      end
    end
  endtask

  initial begin
    failures = 0;
    is_ctrl_taken_i = 1'b0;
    ctrl_target_i = 32'd0;
    mem_read_i = 1'b0;
    mem_write_i = 1'b0;
    mem_funct3_i = 3'b000;
    mem_addr_i = 32'd0;

    #1;
    check_cond(insn_addr_misaligned_o == 1'b0, "idle instruction aligned");

    is_ctrl_taken_i = 1'b1;
    ctrl_target_i = 32'h8000_1002;
    #1;
    check_cond(insn_addr_misaligned_o == 1'b1, "taken control to halfword boundary is misaligned");

    ctrl_target_i = 32'h8000_1000;
    #1;
    check_cond(insn_addr_misaligned_o == 1'b0, "taken control to word boundary is aligned");

    is_ctrl_taken_i = 1'b0;
    mem_read_i = 1'b1;
    mem_funct3_i = 3'b000;
    mem_addr_i = 32'h0000_0003;
    #1;
    check_cond(load_addr_misaligned_o == 1'b0, "byte load is always aligned");

    mem_funct3_i = 3'b001;
    mem_addr_i = 32'h0000_0003;
    #1;
    check_cond(load_addr_misaligned_o == 1'b1, "halfword load odd address misaligned");

    mem_funct3_i = 3'b101;
    mem_addr_i = 32'h0000_0002;
    #1;
    check_cond(load_addr_misaligned_o == 1'b0, "halfword unsigned load even address aligned");

    mem_funct3_i = 3'b010;
    mem_addr_i = 32'h0000_0002;
    #1;
    check_cond(load_addr_misaligned_o == 1'b1, "word load non-word-aligned misaligned");

    mem_read_i = 1'b0;
    mem_write_i = 1'b1;
    mem_funct3_i = 3'b001;
    mem_addr_i = 32'h0000_0001;
    #1;
    check_cond(store_addr_misaligned_o == 1'b1, "halfword store odd address misaligned");

    mem_funct3_i = 3'b010;
    mem_addr_i = 32'h0000_0004;
    #1;
    check_cond(store_addr_misaligned_o == 1'b0, "word store aligned");

    if (failures != 0) begin
      $display("FAIL: misalign_check_tb failures=%0d", failures);
      $finish(1);
    end

    $display("PASS: misalign_check_tb");
    $finish;
  end
endmodule
