module machine_irq_sources_tb;
  reg clk;
  reg rst_n;
  reg msip_we_i;
  reg [31:0] msip_wdata_i;
  reg meip_we_i;
  reg [31:0] meip_wdata_i;
  reg mtime_lo_we_i;
  reg [31:0] mtime_lo_wdata_i;
  reg mtime_hi_we_i;
  reg [31:0] mtime_hi_wdata_i;
  reg mtimecmp_lo_we_i;
  reg [31:0] mtimecmp_lo_wdata_i;
  reg mtimecmp_hi_we_i;
  reg [31:0] mtimecmp_hi_wdata_i;
  reg ext_irq_line_i;
  reg global_mie_i;
  reg msie_en_i;
  reg mtie_en_i;
  reg meie_en_i;

  wire [31:0] msip_rdata_o;
  wire [31:0] meip_rdata_o;
  wire [31:0] mtime_lo_o;
  wire [31:0] mtime_hi_o;
  wire [31:0] mtimecmp_lo_o;
  wire [31:0] mtimecmp_hi_o;
  wire soft_irq_pending_o;
  wire timer_irq_pending_o;
  wire ext_irq_pending_o;
  wire irq_request_o;
  wire [31:0] irq_cause_o;

  integer failures;

  machine_irq_sources dut (
    .clk(clk),
    .rst_n(rst_n),
    .msip_we_i(msip_we_i),
    .msip_wdata_i(msip_wdata_i),
    .meip_we_i(meip_we_i),
    .meip_wdata_i(meip_wdata_i),
    .mtime_lo_we_i(mtime_lo_we_i),
    .mtime_lo_wdata_i(mtime_lo_wdata_i),
    .mtime_hi_we_i(mtime_hi_we_i),
    .mtime_hi_wdata_i(mtime_hi_wdata_i),
    .mtimecmp_lo_we_i(mtimecmp_lo_we_i),
    .mtimecmp_lo_wdata_i(mtimecmp_lo_wdata_i),
    .mtimecmp_hi_we_i(mtimecmp_hi_we_i),
    .mtimecmp_hi_wdata_i(mtimecmp_hi_wdata_i),
    .ext_irq_line_i(ext_irq_line_i),
    .global_mie_i(global_mie_i),
    .msie_en_i(msie_en_i),
    .mtie_en_i(mtie_en_i),
    .meie_en_i(meie_en_i),
    .msip_rdata_o(msip_rdata_o),
    .meip_rdata_o(meip_rdata_o),
    .mtime_lo_o(mtime_lo_o),
    .mtime_hi_o(mtime_hi_o),
    .mtimecmp_lo_o(mtimecmp_lo_o),
    .mtimecmp_hi_o(mtimecmp_hi_o),
    .soft_irq_pending_o(soft_irq_pending_o),
    .timer_irq_pending_o(timer_irq_pending_o),
    .ext_irq_pending_o(ext_irq_pending_o),
    .irq_request_o(irq_request_o),
    .irq_cause_o(irq_cause_o)
  );

  always #5 clk = ~clk;

  task clear_writes;
    begin
      msip_we_i = 1'b0;
      msip_wdata_i = 32'd0;
      meip_we_i = 1'b0;
      meip_wdata_i = 32'd0;
      mtime_lo_we_i = 1'b0;
      mtime_lo_wdata_i = 32'd0;
      mtime_hi_we_i = 1'b0;
      mtime_hi_wdata_i = 32'd0;
      mtimecmp_lo_we_i = 1'b0;
      mtimecmp_lo_wdata_i = 32'd0;
      mtimecmp_hi_we_i = 1'b0;
      mtimecmp_hi_wdata_i = 32'd0;
    end
  endtask

  task write_reg;
    input integer which;
    input [31:0] value;
    begin
      @(negedge clk);
      clear_writes();
      case (which)
        0: begin msip_we_i = 1'b1; msip_wdata_i = value; end
        1: begin meip_we_i = 1'b1; meip_wdata_i = value; end
        2: begin mtime_lo_we_i = 1'b1; mtime_lo_wdata_i = value; end
        3: begin mtime_hi_we_i = 1'b1; mtime_hi_wdata_i = value; end
        4: begin mtimecmp_lo_we_i = 1'b1; mtimecmp_lo_wdata_i = value; end
        5: begin mtimecmp_hi_we_i = 1'b1; mtimecmp_hi_wdata_i = value; end
      endcase
      @(negedge clk);
      clear_writes();
    end
  endtask

  task check_cond;
    input condition;
    input [255:0] msg;
    begin
      if (!condition) begin
        $display("FAIL: %0s", msg);
        failures = failures + 1;
      end
    end
  endtask

  initial begin
    clk = 1'b0;
    rst_n = 1'b0;
    ext_irq_line_i = 1'b0;
    global_mie_i = 1'b0;
    msie_en_i = 1'b0;
    mtie_en_i = 1'b0;
    meie_en_i = 1'b0;
    failures = 0;
    clear_writes();

    repeat (2) @(posedge clk);
    rst_n = 1'b1;
    #1;

    check_cond(msip_rdata_o == 32'd0, "reset msip");
    check_cond(meip_rdata_o == 32'd0, "reset meip");
    check_cond(timer_irq_pending_o == 1'b0, "reset timer pending");

    write_reg(0, 32'd1);
    #1;
    check_cond(soft_irq_pending_o == 1'b1, "msip pending set");
    global_mie_i = 1'b1;
    msie_en_i = 1'b1;
    #1;
    check_cond(irq_request_o == 1'b1 && irq_cause_o == 32'd3, "software interrupt request/cause");

    write_reg(1, 32'd1);
    meie_en_i = 1'b1;
    #1;
    check_cond(ext_irq_pending_o == 1'b1, "meip software pending set");
    check_cond(irq_request_o == 1'b1 && irq_cause_o == 32'd11, "external has priority over software");

    write_reg(1, 32'd0);
    ext_irq_line_i = 1'b1;
    #1;
    check_cond(ext_irq_pending_o == 1'b1, "external line pending");
    check_cond(irq_cause_o == 32'd11, "external line cause");
    ext_irq_line_i = 1'b0;

    write_reg(0, 32'd0);
    msie_en_i = 1'b0;
    #1;
    check_cond(irq_request_o == 1'b0, "no request after clearing software/external");

    write_reg(2, 32'd10);
    write_reg(3, 32'd0);
    write_reg(4, 32'd20);
    write_reg(5, 32'd0);
    mtie_en_i = 1'b1;
    #1;
    check_cond(timer_irq_pending_o == 1'b0, "timer not yet pending");
    repeat (8) @(posedge clk);
    #1;
    check_cond(timer_irq_pending_o == 1'b1, "timer pending after mtime reaches compare");
    check_cond(irq_request_o == 1'b1 && irq_cause_o == 32'd7, "timer interrupt request/cause");

    global_mie_i = 1'b0;
    #1;
    check_cond(irq_request_o == 1'b0, "global mie gates interrupts");

    if (failures != 0) begin
      $display("FAIL: machine_irq_sources_tb failures=%0d", failures);
      $finish(1);
    end

    $display("PASS: machine_irq_sources_tb");
    $finish;
  end
endmodule
