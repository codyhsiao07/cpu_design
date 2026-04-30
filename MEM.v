`timescale 1ns/1ps
// MEM.v -- mem_stage with data alignment inside MEM (Verilog-2001)
// - dmem_wdata_o / dmem_wstrb_o are ALREADY ALIGNED here.
// - dmem_req_o is level-valid during an active transaction.
// - Store completes on dmem_ready_i; Load completes on dmem_rvalid_i.

module mem_stage (
  input              clk,
  input              rst_n,

  input              mem_valid_i,
  input      [31:0]  mem_alu_result_i,   // byte address
  input      [31:0]  mem_store_data_i,
  input              mem_mem_read_i,
  input              mem_mem_write_i,
  input      [2:0]   mem_size_i,         // funct3

  // D$ / memory request side
  output             dmem_req_o,
  output             dmem_we_o,
  output     [31:0]  dmem_addr_o,
  output     [31:0]  dmem_wdata_o,
  output     [3:0]   dmem_wstrb_o,
  input              dmem_ready_i,

  // D$ / memory response side
  input              dmem_rvalid_i,
  input      [31:0]  dmem_rdata_i,
  input              store_done_i,

  // Back to pipeline
  output     [31:0]  mem_load_rdata_o,
  output             mem_stall_o,
  output             mem_load_valid_o,
  output             mem_load_active_o
);

  // -------------------- txn latches --------------------
  reg        busy_q;
  reg        we_q;             // 1=store, 0=load
  reg [31:0] addr_q;           // byte address
  reg [31:0] wdata_q;          // store data (source from EX)
  reg [2:0]  size_f3_q;        // funct3 (signedness + size)
  reg        done_q;           // one-cycle suppress to avoid re-issuing held EX/MEM op
  reg [31:0] load_data_q;      // latched load data
  reg        load_active_q;    // active load awaiting response
  reg        req_pending_q;    // request waiting for downstream accept

  wire mem_op_active = mem_mem_read_i | mem_mem_write_i;
  wire new_req = mem_valid_i & mem_op_active & ~busy_q & ~done_q;
  wire new_load_req = new_req & ~mem_mem_write_i; // pulse when accepting a load

  wire [1:0] size2_q = size_f3_q[1:0];   // 00=byte,01=half,10=word
  wire       sz_byte = (size2_q == 2'b00);
  wire       sz_half = (size2_q == 2'b01);
  wire       load_signed = (size_f3_q == 3'b000) | (size_f3_q == 3'b001); // LB,LH

  reg [31:0] load_aligned;
  always @* begin
    if (sz_byte) begin
      case (addr_q[1:0])
        2'b00: load_aligned = {24'h0, dmem_rdata_i[7:0]};
        2'b01: load_aligned = {24'h0, dmem_rdata_i[15:8]};
        2'b10: load_aligned = {24'h0, dmem_rdata_i[23:16]};
        default: load_aligned = {24'h0, dmem_rdata_i[31:24]};
      endcase
    end else if (sz_half) begin
      load_aligned = addr_q[1] ? {16'h0, dmem_rdata_i[31:16]} : {16'h0, dmem_rdata_i[15:0]};
    end else begin
      load_aligned = dmem_rdata_i;
    end
  end

  wire sign_bit = sz_byte ?
                  ((addr_q[1:0]==2'b00) ? dmem_rdata_i[7]  :
                   (addr_q[1:0]==2'b01) ? dmem_rdata_i[15] :
                   (addr_q[1:0]==2'b10) ? dmem_rdata_i[23] : dmem_rdata_i[31]) :
                  (sz_half ? (addr_q[1] ? dmem_rdata_i[31] : dmem_rdata_i[15]) :
                             dmem_rdata_i[31]);
  wire [31:0] load_result =
      load_signed ?
        (sz_byte ? {{24{sign_bit}}, load_aligned[7:0]} :
         sz_half ? {{16{sign_bit}}, load_aligned[15:0]} :
                   load_aligned) :
        load_aligned;


  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      busy_q         <= 1'b0;
      we_q           <= 1'b0;
      addr_q         <= 32'h0;
      wdata_q        <= 32'h0;
      size_f3_q      <= 3'b010; // default LW
      done_q         <= 1'b0;
      load_data_q    <= 32'h0;
      load_active_q  <= 1'b0;
    end else begin
      // done_q is intentionally a one-cycle pulse used to suppress exactly
      // one re-issue cycle while EX/MEM is still holding the completed op.
      if (done_q) begin
        done_q <= 1'b0;
      end

      // Complete current transaction
      if (busy_q) begin
        if (we_q) begin
          if (store_done_i) begin
            busy_q         <= 1'b0;
            done_q         <= 1'b1;
          end
        end else begin
          if (dmem_rvalid_i) begin
            busy_q        <= 1'b0;
            done_q        <= 1'b1;
            load_data_q   <= load_result;
            load_active_q <= 1'b0;
          end
        end
      end

      // Start new transaction when allowed
      if (new_req) begin
        busy_q    <= 1'b1;
        we_q      <= mem_mem_write_i;
        addr_q    <= mem_alu_result_i;
        wdata_q   <= mem_store_data_i;
        size_f3_q <= mem_size_i;
        done_q    <= 1'b0;
        load_active_q  <= ~mem_mem_write_i;
      end
    end
  end

  // Track whether the latched request still needs to hand-shake with downstream
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      req_pending_q <= 1'b0;
    end else begin
      if (req_pending_q && dmem_ready_i) begin
        req_pending_q <= 1'b0;
      end else if (new_req) begin
        req_pending_q <= 1'b1;
      end
    end
  end

  // -------------------- request outputs --------------------
`ifdef PIPE_TRACE
  always @(posedge clk) begin
    if (mem_valid_i) begin
      $display("[%0t] MEM_STAGE INPUT mem_read=%0d mem_write=%0d addr=0x%08x stall=%0d",
               $time, mem_mem_read_i, mem_mem_write_i, mem_alu_result_i, mem_stall_o);
    end
  end
`endif
  assign dmem_req_o  = req_pending_q;
  assign dmem_we_o   = we_q;
  assign dmem_addr_o = addr_q;       // byte address (downstream word-aligns)

  // wstrb from size + addr
  function [3:0] mk_wstrb;
    input [2:0] size_f3;
    input [1:0] a_lo;
    reg [3:0] st;
    begin
      case (size_f3[1:0])
        2'b00: st = (4'b0001 << a_lo);           // SB
        2'b01: st = a_lo[1] ? 4'b1100 : 4'b0011; // SH
        default: st = 4'b1111;                   // SW
      endcase
      mk_wstrb = st;
    end
  endfunction

  // align store data into correct lane/halfword
  function [31:0] align_store_data;
    input [31:0] sd;
    input [2:0]  size_f3;
    input [1:0]  a_lo;
    reg   [31:0] v;
    begin
      case (size_f3[1:0])
        2'b00: begin
          // SB: take sd[7:0], place into lane by a_lo
          v = {24'h0, sd[7:0]} << (a_lo * 8);
        end
        2'b01: begin
          // SH: ALWAYS take sd[15:0] as the halfword value,
          // place to high/low half by addr[1]
          v = a_lo[1] ? {sd[15:0], 16'h0000} : {16'h0000, sd[15:0]};
        end
        default: begin
          // SW: pass-through
          v = sd;
        end
      endcase
      align_store_data = v;
    end
  endfunction

  assign dmem_wstrb_o = we_q ? mk_wstrb(size_f3_q, addr_q[1:0]) : 4'b0000;
  assign dmem_wdata_o = align_store_data(wdata_q, size_f3_q, addr_q[1:0]);

  // -------------------- load data align/extend --------------------
  wire load_resp_fire = (~we_q) & busy_q & dmem_rvalid_i;

  assign mem_load_rdata_o  = load_resp_fire ? load_result : load_data_q;
  assign mem_load_valid_o  = load_resp_fire;
  assign mem_load_active_o = load_active_q | new_load_req | load_resp_fire;

  // -------------------- stall --------------------
  assign mem_stall_o = busy_q | new_req;

`ifdef PIPE_TRACE
  // Debug prints to trace MEM transactions and responses during simulation
  always @(posedge clk) begin
    if (new_req) begin
      $display("[%0t] MEM_STAGE REQ we=%0d addr=0x%08x size=%0d",
               $time, mem_mem_write_i, mem_alu_result_i, mem_size_i);
      if (mem_mem_write_i) begin
        $display("         store_data=0x%08x wstrb=%b",
                 mem_store_data_i, mk_wstrb(mem_size_i, mem_alu_result_i[1:0]));
      end
    end
    if (load_resp_fire) begin
      $display("[%0t] MEM_STAGE LOAD_RSP addr=0x%08x data=0x%08x",
               $time, addr_q, load_result);
    end
  end
`endif

endmodule
