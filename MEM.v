// mem_stage.v -- RV32I MEM stage (Verilog-2001)
// Supports LB/LH/LW/LBU/LHU and SB/SH/SW
// Handshake to data memory: req/we/addr/wdata/wstrb + ready/rvalid/rdata

module mem_stage (
  input         clk,
  input         rst_n,

  // From EX/MEM register
  input         mem_valid_i,
  input  [31:0] mem_alu_result_i,  // address (rs1 + imm)
  input  [31:0] mem_store_data_i,  // store data (rs2)
  input         mem_mem_read_i,    // 1: LOAD
  input         mem_mem_write_i,   // 1: STORE
  input  [2:0]  mem_size_i,        // funct3 for load/store size

  // To data memory (simple handshake)
  output        dmem_req_o,
  output        dmem_we_o,
  output [31:0] dmem_addr_o,
  output [31:0] dmem_wdata_o,
  output [3:0]  dmem_wstrb_o,
  input         dmem_ready_i,
  input         dmem_rvalid_i,
  input  [31:0] dmem_rdata_i,

  // To MEM/WB and upstream control
  output [31:0] mem_load_rdata_o,
  output        mem_stall_o
);

  // Convenience (current input view)
  wire [31:0] addr   = mem_alu_result_i;
  wire [1:0]  addr2  = addr[1:0];
  wire        is_load  = mem_valid_i & mem_mem_read_i;
  wire        is_store = mem_valid_i & mem_mem_write_i;

  // Size encodings (funct3)
  localparam [2:0] F3_LB  = 3'b000;
  localparam [2:0] F3_LH  = 3'b001;
  localparam [2:0] F3_LW  = 3'b010;
  localparam [2:0] F3_LBU = 3'b100;
  localparam [2:0] F3_LHU = 3'b101;
  localparam [2:0] F3_SB  = 3'b000;
  localparam [2:0] F3_SH  = 3'b001;
  localparam [2:0] F3_SW  = 3'b010;

  // ================= Transaction state =================
  reg        busy_q;         // 1 while a transaction is in-flight
  reg        txn_is_load_q;  // latched type
  reg [31:0] txn_addr_q;     // latched address (aligned)
  reg [1:0]  txn_addr2_q;    // latched byte offset
  reg [2:0]  txn_size_q;     // latched size/funct3
  reg [3:0]  txn_wstrb_q;    // latched store strobes
  reg [31:0] txn_wdata_q;    // latched store data (aligned)
  // Simple de-dup state for identical upstream request shapes
  reg        seen_q;
  reg        cap_is_load_q;
  reg        cap_is_store_q;
  reg [31:0] cap_addr_q;

  // Start condition (one-shot when not busy, and not seen same request shape)
  wire same_shape = (is_load == cap_is_load_q) && (is_store == cap_is_store_q) && (addr == cap_addr_q);
  wire seen_now   = seen_q & mem_valid_i & same_shape;
  wire start_txn  = (is_load | is_store) & ~busy_q & ~seen_now;

  // Compute store alignment for current inputs (used when start_txn)
  function [3:0] mk_wstrb;
    input [2:0] size_f3; input [1:0] ofs;
    begin
      case (size_f3)
        F3_SB: mk_wstrb = (4'b0001 << ofs);
        F3_SH: mk_wstrb = (ofs[1]) ? 4'b1100 : 4'b0011;
        default: mk_wstrb = 4'b1111; // SW
      endcase
    end
  endfunction

  function [31:0] align_store_data;
    input [2:0] size_f3; input [31:0] sd;
    begin
      case (size_f3)
        F3_SB: align_store_data = {4{sd[7:0]}};
        F3_SH: align_store_data = {2{sd[15:0]}};
        default: align_store_data = sd; // SW
      endcase
    end
  endfunction

  // Latch transaction metadata
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      busy_q         <= 1'b0;
      txn_is_load_q  <= 1'b0;
      txn_addr_q     <= 32'h0;
      txn_addr2_q    <= 2'b00;
      txn_size_q     <= 3'b010;
      txn_wstrb_q    <= 4'b0000;
      txn_wdata_q    <= 32'h0;
      seen_q         <= 1'b0;
      cap_is_load_q  <= 1'b0;
      cap_is_store_q <= 1'b0;
      cap_addr_q     <= 32'h0;
    end else begin
      // Start or continue
      if (start_txn) begin
        busy_q        <= 1'b1;
        txn_is_load_q <= is_load;
        txn_addr_q    <= addr;
        txn_addr2_q   <= addr2;
        txn_size_q    <= mem_size_i;
        txn_wstrb_q   <= mk_wstrb(mem_size_i, addr2);
        txn_wdata_q   <= align_store_data(mem_size_i, mem_store_data_i);
        // mark as seen for this shape
        seen_q        <= 1'b1;
        cap_is_load_q  <= is_load;
        cap_is_store_q <= is_store;
        cap_addr_q     <= addr;
      end

      // Completion clears busy
      if ((busy_q &&  txn_is_load_q && dmem_rvalid_i) ||
          (busy_q && !txn_is_load_q && dmem_ready_i)) begin
        busy_q <= 1'b0;
      end

      // Release de-dup marker when upstream changes or deasserts
      if (!mem_valid_i) begin
        seen_q <= 1'b0;
      end else if (!same_shape) begin
        seen_q <= 1'b0;
      end
    end
  end

  // Drive memory (issue in start cycle, hold while busy)
  assign dmem_req_o   = busy_q | start_txn;
  assign dmem_we_o    = start_txn ? is_store    : ~txn_is_load_q;
  assign dmem_addr_o  = start_txn ? addr        : txn_addr_q;
  assign dmem_wdata_o = start_txn ? align_store_data(mem_size_i, mem_store_data_i) : txn_wdata_q;
  assign dmem_wstrb_o = start_txn ? mk_wstrb(mem_size_i, addr2)                     : txn_wstrb_q;

  // Load data sign/zero-extend based on latched info
  wire [7:0]  rbyte = (txn_addr2_q==2'd0) ? dmem_rdata_i[7:0]   :
                      (txn_addr2_q==2'd1) ? dmem_rdata_i[15:8]  :
                      (txn_addr2_q==2'd2) ? dmem_rdata_i[23:16] : dmem_rdata_i[31:24];
  wire [15:0] rhalf = txn_addr2_q[1] ? dmem_rdata_i[31:16] : dmem_rdata_i[15:0];
  reg [31:0] load_ext;
  always @(*) begin
    case (txn_size_q)
      F3_LB : load_ext = {{24{rbyte[7]}},  rbyte};
      F3_LBU: load_ext = {24'b0,          rbyte};
      F3_LH : load_ext = {{16{rhalf[15]}}, rhalf};
      F3_LHU: load_ext = {16'b0,          rhalf};
      default: load_ext = dmem_rdata_i; // LW or default
    endcase
  end
  assign mem_load_rdata_o = load_ext;

  // Backpressure upstream：交易發起當拍與忙碌期間皆施壓
  assign mem_stall_o = busy_q | start_txn;

endmodule
