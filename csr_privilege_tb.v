module csr_privilege_tb;
  localparam [2:0] CSR_CMD_NONE = 3'b000;
  localparam [2:0] CSR_CMD_W    = 3'b001;
  localparam [11:0] CSR_MSTATUS = 12'h300;

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
  reg [31:0] trap_tval;
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
  integer mpp;

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
    .trap_tval(trap_tval),
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
      csr_addr = 12'd0;
      csr_wdata = 32'd0;
      trap_enter = 1'b0;
      trap_is_interrupt = 1'b0;
      trap_pc = 32'd0;
      trap_cause = 32'd0;
      trap_tval = 32'd0;
      mret_exec = 1'b0;
      ext_irq_pending = 1'b0;
      timer_irq_pending = 1'b0;
      soft_irq_pending = 1'b0;
    end
  endtask

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
    clk = 1'b0;
    rst_n = 1'b0;
    failures = 0;
    clear_inputs();

    repeat (2) @(posedge clk);
    rst_n = 1'b1;
    #1;

    check_cond(current_priv_o == 2'b11, "reset current privilege is M");

    @(negedge clk);
    csr_en = 1'b1;
    csr_cmd = CSR_CMD_W;
    csr_addr = CSR_MSTATUS;
    csr_wdata = 32'h0000_0080; // MPP=00, MPIE=1, MIE=0
    @(negedge clk);
    clear_inputs();
    #1;
    check_cond(mstatus_o[12:11] == 2'b00, "mstatus write sets MPP to U");

    @(negedge clk);
    mret_exec = 1'b1;
    @(negedge clk);
    clear_inputs();
    #1;
    check_cond(current_priv_o == 2'b00, "mret returns to U privilege");

    @(negedge clk);
    trap_pc = 32'h8000_0123;
    trap_cause = 32'd8;
    trap_enter = 1'b1;
    @(negedge clk);
    clear_inputs();
    #1;
    check_cond(current_priv_o == 2'b11, "trap enters machine mode");
    check_cond(mstatus_o[12:11] == 2'b00, "trap saves previous U mode into MPP");

    // Only U and M are implemented. WARL writes must never create S or the
    // reserved privilege level, including after MRET.
    for (mpp = 0; mpp < 4; mpp = mpp + 1) begin
      @(negedge clk);
      csr_en = 1'b1;
      csr_cmd = CSR_CMD_W;
      csr_addr = CSR_MSTATUS;
      csr_wdata = mpp << 11;
      @(negedge clk);
      clear_inputs();
      #1;
      check_cond((mstatus_o[12:11] == 2'b00) || (mstatus_o[12:11] == 2'b11),
                 "MPP must be implemented U or M");
      @(negedge clk);
      mret_exec = 1'b1;
      @(negedge clk);
      clear_inputs();
      #1;
      check_cond((current_priv_o == 2'b00) || (current_priv_o == 2'b11),
                 "MRET must enter implemented mode");
      check_cond(global_mie_o == ((current_priv_o != 2'b11) || mstatus_o[3]),
                 "U mode must enable machine IRQs");
      @(negedge clk);
      trap_enter = 1'b1;
      @(negedge clk);
      clear_inputs();
    end

    if (failures != 0) begin
      $display("FAIL: csr_privilege_tb failures=%0d", failures);
      $fatal(1, "privilege regression failed");
    end

    $display("PASS: csr_privilege_tb");
    $finish;
  end
endmodule
