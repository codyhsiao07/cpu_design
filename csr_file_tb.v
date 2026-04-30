module csr_file_tb;
  localparam [2:0] CSR_CMD_NONE = 3'b000;
  localparam [2:0] CSR_CMD_W    = 3'b001;
  localparam [2:0] CSR_CMD_S    = 3'b010;
  localparam [2:0] CSR_CMD_C    = 3'b011;

  localparam [11:0] CSR_MSTATUS  = 12'h300;
  localparam [11:0] CSR_MIE      = 12'h304;
  localparam [11:0] CSR_MTVEC    = 12'h305;
  localparam [11:0] CSR_MSCRATCH = 12'h340;
  localparam [11:0] CSR_MEPC     = 12'h341;
  localparam [11:0] CSR_MCAUSE   = 12'h342;
  localparam [11:0] CSR_MIP      = 12'h344;

  reg clk;
  reg rst_n;
  reg csr_en;
  reg [2:0] csr_cmd;
  reg [11:0] csr_addr;
  reg [31:0] csr_wdata;
  wire [31:0] csr_rdata;

  reg trap_enter;
  reg trap_is_interrupt;
  reg [31:0] trap_pc;
  reg [31:0] trap_cause;
  reg mret_exec;
  reg ext_irq_pending;
  reg timer_irq_pending;
  reg soft_irq_pending;

  wire [31:0] mtvec_o;
  wire [31:0] mepc_o;
  wire [31:0] mcause_o;
  wire [31:0] mstatus_o;
  wire [31:0] mie_o;
  wire [31:0] mip_o;
  wire [31:0] mscratch_o;
  wire [1:0] current_priv_o;
  wire global_mie_o;
  wire msie_en_o;
  wire mtie_en_o;
  wire meie_en_o;

  integer failures;

  csr_file dut (
    .clk(clk),
    .rst_n(rst_n),
    .csr_en(csr_en),
    .csr_cmd(csr_cmd),
    .csr_addr(csr_addr),
    .csr_wdata(csr_wdata),
    .csr_rdata(csr_rdata),
    .trap_enter(trap_enter),
    .trap_is_interrupt(trap_is_interrupt),
    .trap_pc(trap_pc),
    .trap_cause(trap_cause),
    .mret_exec(mret_exec),
    .ext_irq_pending(ext_irq_pending),
    .timer_irq_pending(timer_irq_pending),
    .soft_irq_pending(soft_irq_pending),
    .mtvec_o(mtvec_o),
    .mepc_o(mepc_o),
    .mcause_o(mcause_o),
    .mstatus_o(mstatus_o),
    .mie_o(mie_o),
    .mip_o(mip_o),
    .mscratch_o(mscratch_o),
    .current_priv_o(current_priv_o),
    .global_mie_o(global_mie_o),
    .msie_en_o(msie_en_o),
    .mtie_en_o(mtie_en_o),
    .meie_en_o(meie_en_o)
  );

  always #5 clk = ~clk;

  task clear_inputs;
    begin
      csr_en = 1'b0;
      csr_cmd = CSR_CMD_NONE;
      csr_addr = 12'b0;
      csr_wdata = 32'b0;
      trap_enter = 1'b0;
      trap_is_interrupt = 1'b0;
      trap_pc = 32'b0;
      trap_cause = 32'b0;
      mret_exec = 1'b0;
      ext_irq_pending = 1'b0;
      timer_irq_pending = 1'b0;
      soft_irq_pending = 1'b0;
    end
  endtask

  task check_read;
    input [11:0] addr;
    input [31:0] expected;
    input integer case_id;
    begin
      csr_addr = addr;
      #1;
      if (csr_rdata !== expected) begin
        $display("FAIL case=%0d read csr=%03h got=%08h exp=%08h", case_id, addr, csr_rdata, expected);
        failures = failures + 1;
      end
    end
  endtask

  task apply_write;
    input [11:0] addr;
    input [2:0] cmd;
    input [31:0] wdata;
    input [31:0] expected_old;
    input integer case_id;
    begin
      @(negedge clk);
      csr_addr = addr;
      csr_cmd = cmd;
      csr_wdata = wdata;
      csr_en = 1'b1;
      #1;
      if (csr_rdata !== expected_old) begin
        $display("FAIL case=%0d old csr=%03h got=%08h exp=%08h", case_id, addr, csr_rdata, expected_old);
        failures = failures + 1;
      end
      @(negedge clk);
      csr_en = 1'b0;
      csr_cmd = CSR_CMD_NONE;
      csr_wdata = 32'b0;
    end
  endtask

  initial begin
    clk = 1'b0;
    rst_n = 1'b0;
    failures = 0;
    clear_inputs();

    repeat (2) @(posedge clk);
    rst_n = 1'b1;
    #1;

    check_read(CSR_MSTATUS, 32'h0000_0000, 1);
    check_read(CSR_MIE,     32'h0000_0000, 2);
    check_read(CSR_MTVEC,   32'h0000_0000, 3);

    apply_write(CSR_MTVEC, CSR_CMD_W, 32'h8000_0100, 32'h0000_0000, 4);
    check_read(CSR_MTVEC, 32'h8000_0100, 5);

    apply_write(CSR_MSCRATCH, CSR_CMD_W, 32'h1234_5678, 32'h0000_0000, 6);
    check_read(CSR_MSCRATCH, 32'h1234_5678, 7);

    apply_write(CSR_MIE, CSR_CMD_W, 32'hFFFF_FFFF, 32'h0000_0000, 8);
    check_read(CSR_MIE, 32'h0000_0888, 9);
    if (!msie_en_o || !mtie_en_o || !meie_en_o) begin
      $display("FAIL case=10 mie decoded enables incorrect");
      failures = failures + 1;
    end

    apply_write(CSR_MIE, CSR_CMD_C, 32'h0000_0080, 32'h0000_0888, 11);
    check_read(CSR_MIE, 32'h0000_0808, 12);

    apply_write(CSR_MSTATUS, CSR_CMD_W, 32'hFFFF_FFFF, 32'h0000_0000, 13);
    check_read(CSR_MSTATUS, 32'h0000_1888, 14);
    if (!global_mie_o) begin
      $display("FAIL case=15 global_mie_o should be set");
      failures = failures + 1;
    end

    apply_write(CSR_MSTATUS, CSR_CMD_C, 32'h0000_0008, 32'h0000_1888, 16);
    check_read(CSR_MSTATUS, 32'h0000_1880, 17);

    apply_write(CSR_MEPC, CSR_CMD_W, 32'h8000_0123, 32'h0000_0000, 18);
    check_read(CSR_MEPC, 32'h8000_0120, 19);

    apply_write(CSR_MCAUSE, CSR_CMD_W, 32'h0000_000B, 32'h0000_0000, 20);
    check_read(CSR_MCAUSE, 32'h0000_000B, 21);

    soft_irq_pending = 1'b1;
    timer_irq_pending = 1'b1;
    ext_irq_pending = 1'b1;
    #1;
    check_read(CSR_MIP, 32'h0000_0888, 22);
    apply_write(CSR_MIP, CSR_CMD_W, 32'h0000_0000, 32'h0000_0888, 23);
    check_read(CSR_MIP, 32'h0000_0888, 24);
    soft_irq_pending = 1'b0;
    timer_irq_pending = 1'b0;
    ext_irq_pending = 1'b0;
    #1;
    check_read(CSR_MIP, 32'h0000_0000, 25);
    apply_write(CSR_MIP, CSR_CMD_W, 32'h0000_0888, 32'h0000_0000, 26);
    check_read(CSR_MIP, 32'h0000_0888, 27);

    @(negedge clk);
    trap_pc = 32'h8000_0456;
    trap_cause = 32'd11;
    trap_enter = 1'b1;
    @(negedge clk);
    trap_enter = 1'b0;
    check_read(CSR_MEPC, 32'h8000_0454, 28);
    check_read(CSR_MCAUSE, 32'h0000_000B, 29);
    check_read(CSR_MSTATUS, 32'h0000_1800, 30);

    @(negedge clk);
    mret_exec = 1'b1;
    @(negedge clk);
    mret_exec = 1'b0;
    check_read(CSR_MSTATUS, 32'h0000_0080, 31);

    @(negedge clk);
    trap_pc = 32'h8000_0500;
    trap_cause = 32'd7;
    trap_is_interrupt = 1'b1;
    trap_enter = 1'b1;
    @(negedge clk);
    trap_enter = 1'b0;
    trap_is_interrupt = 1'b0;
    check_read(CSR_MEPC, 32'h8000_0500, 32);
    check_read(CSR_MCAUSE, 32'h8000_0007, 33);
    check_read(CSR_MSTATUS, 32'h0000_1800, 34);

    if (failures != 0) begin
      $display("FAIL: csr_file_tb failures=%0d", failures);
      $finish(1);
    end

    $display("PASS: csr_file_tb");
    $finish;
  end
endmodule
