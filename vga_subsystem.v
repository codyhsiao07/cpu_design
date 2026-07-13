`timescale 1ns/1ps

module vga_subsystem #(
    parameter [31:0] FB_BASE_ADDR = 32'h5000_0000,
    parameter integer FB_WORDS = 8192
) (
    input              cpu_clk,
    input              rst_n,
    input              vga_mclk,
    input              cpu_req_valid,
    input              cpu_req_we,
    input      [31:0]  cpu_req_addr,
    input      [31:0]  cpu_req_wdata,
    input      [3:0]   cpu_req_wstrb,
    output             cpu_req_ready,
    output             cpu_rsp_valid,
    output     [31:0]  cpu_rsp_rdata,
    output             cpu_rsp_err,
    output             hsync_o,
    output             vsync_o,
    output     [3:0]   red_o,
    output     [3:0]   green_o,
    output     [3:0]   blue_o
);
    localparam [31:0] FB_LAST_ADDR    = FB_BASE_ADDR + 32'h0000_7FFF;
    localparam [31:0] FB_CTRL_ADDR    = FB_BASE_ADDR + 32'h0000_7FFC;
    localparam [12:0] FB_BUFFER_WORDS = 13'd4096;

    // Two 16-bit banks map cleanly onto byte-write true dual-port BRAMs.
    // CPU port A accesses both banks as one 32-bit word; VGA port B selects
    // the required 16-bit pixel pair after the synchronous read.
    (* ram_style = "block" *) reg [15:0] fb_lo_mem [0:FB_WORDS-1];
    (* ram_style = "block" *) reg [15:0] fb_hi_mem [0:FB_WORDS-1];

    reg        cpu_rsp_valid_q = 1'b0;
    reg [31:0] cpu_rsp_rdata_q = 32'd0;
    reg        cpu_rsp_err_q   = 1'b0;
    reg        cpu_read_pending_q = 1'b0;
    reg [15:0] cpu_fb_lo_q;
    reg [15:0] cpu_fb_hi_q;
    reg        front_buf_sel_cpu_q = 1'b0;
    reg        front_buf_sel_seen_meta_q = 1'b0;
    reg        front_buf_sel_seen_q = 1'b0;
    reg        front_buf_sel_vga_meta_q = 1'b0;
    reg        front_buf_sel_vga_req_q = 1'b0;
    reg        front_buf_sel_vga_q = 1'b0;
    wire       cpu_addr_hit;
    wire       cpu_ctrl_sel;
    wire [31:0] cpu_byte_offset;
    wire [12:0] cpu_word_addr;

    wire       clk25;
    wire       vidon;
    wire [9:0] hc;
    wire [9:0] vc;
    wire [12:0] vga_word_addr;
    wire [12:0] vga_mem_word_addr;
    reg  [15:0] vga_lo_q;
    reg  [15:0] vga_hi_q;
    reg         vga_half_sel_q = 1'b0;
    wire [15:0] vga_word_data;

    assign cpu_addr_hit = (cpu_req_addr >= FB_BASE_ADDR) && (cpu_req_addr <= FB_LAST_ADDR);
    assign cpu_ctrl_sel = (cpu_req_addr[31:2] == FB_CTRL_ADDR[31:2]);
    assign cpu_byte_offset = cpu_req_addr - FB_BASE_ADDR;
    assign cpu_word_addr = cpu_byte_offset[14:2];
    assign cpu_req_ready = cpu_req_valid && !cpu_read_pending_q && !cpu_rsp_valid_q;
    assign cpu_rsp_valid = cpu_rsp_valid_q;
    assign cpu_rsp_rdata = cpu_rsp_rdata_q;
    assign cpu_rsp_err   = cpu_rsp_err_q;
    assign vga_mem_word_addr =
        (front_buf_sel_vga_q ? FB_BUFFER_WORDS : 13'd0) + {1'b0, vga_word_addr[12:1]};

    // CPU-side RAM port and buffer-control register share one process.  This
    // avoids multiple drivers and matches a standard true dual-port BRAM shape.
    always @(posedge cpu_clk) begin
        if (!rst_n) begin
            cpu_rsp_valid_q <= 1'b0;
            cpu_rsp_rdata_q <= 32'd0;
            cpu_rsp_err_q   <= 1'b0;
            cpu_read_pending_q <= 1'b0;
            front_buf_sel_cpu_q <= 1'b0;
            front_buf_sel_seen_meta_q <= 1'b0;
            front_buf_sel_seen_q <= 1'b0;
        end else begin
            front_buf_sel_seen_meta_q <= front_buf_sel_vga_q;
            front_buf_sel_seen_q <= front_buf_sel_seen_meta_q;
            cpu_rsp_valid_q <= 1'b0;

            if (cpu_read_pending_q) begin
                cpu_rsp_valid_q <= 1'b1;
                cpu_rsp_err_q   <= 1'b0;
                cpu_rsp_rdata_q <= {cpu_fb_hi_q, cpu_fb_lo_q};
                cpu_read_pending_q <= 1'b0;
            end

            if (cpu_req_ready && cpu_addr_hit && cpu_req_we) begin
                if (cpu_ctrl_sel) begin
                    if (cpu_req_wstrb != 4'd0)
                        front_buf_sel_cpu_q <= cpu_req_wdata[0];
                end else begin
                    if (cpu_req_wstrb[0]) fb_lo_mem[cpu_word_addr][7:0]  <= cpu_req_wdata[7:0];
                    if (cpu_req_wstrb[1]) fb_lo_mem[cpu_word_addr][15:8] <= cpu_req_wdata[15:8];
                    if (cpu_req_wstrb[2]) fb_hi_mem[cpu_word_addr][7:0]  <= cpu_req_wdata[23:16];
                    if (cpu_req_wstrb[3]) fb_hi_mem[cpu_word_addr][15:8] <= cpu_req_wdata[31:24];
                end
            end

            if (cpu_req_ready) begin
                if (cpu_addr_hit && !cpu_ctrl_sel && !cpu_req_we) begin
                    // Dedicated output registers are required for BRAM
                    // inference with byte write enables.
                    cpu_fb_lo_q <= fb_lo_mem[cpu_word_addr];
                    cpu_fb_hi_q <= fb_hi_mem[cpu_word_addr];
                    cpu_read_pending_q <= 1'b1;
                end else begin
                    cpu_rsp_valid_q <= 1'b1;
                    cpu_rsp_err_q   <= ~cpu_addr_hit;
                    cpu_rsp_rdata_q <= (cpu_addr_hit && cpu_ctrl_sel) ?
                                        {30'd0, front_buf_sel_cpu_q, front_buf_sel_seen_q} : 32'd0;
                end
            end
        end
    end

    always @(posedge clk25) begin
        if (!rst_n) begin
            front_buf_sel_vga_meta_q <= 1'b0;
            front_buf_sel_vga_req_q  <= 1'b0;
            front_buf_sel_vga_q      <= 1'b0;
        end else begin
            front_buf_sel_vga_meta_q <= front_buf_sel_cpu_q;
            front_buf_sel_vga_req_q <= front_buf_sel_vga_meta_q;
            if ((hc == 10'd0) && (vc == 10'd0)) begin
                // Switch only at the top of a frame after the requested buffer
                // selection has been synchronized into the pixel clock domain.
                front_buf_sel_vga_q <= front_buf_sel_vga_req_q;
            end
        end
    end

    clkdiv u_clkdiv (
        .mclk (vga_mclk),
        .clr  (~rst_n),
        .clk25(clk25)
    );

    vga_640x480 u_vga_timing (
        .clk   (clk25),
        .clr   (~rst_n),
        .hsync (hsync_o),
        .vsync (vsync_o),
        .hc    (hc),
        .vc    (vc),
        .vidon (vidon)
    );

    always @(posedge clk25) begin
        if (!rst_n) begin
            vga_lo_q <= 16'd0;
            vga_hi_q <= 16'd0;
            vga_half_sel_q <= 1'b0;
        end else begin
            vga_lo_q <= fb_lo_mem[vga_mem_word_addr];
            vga_hi_q <= fb_hi_mem[vga_mem_word_addr];
            vga_half_sel_q <= vga_word_addr[0];
        end
    end

    assign vga_word_data = vga_half_sel_q ? vga_hi_q : vga_lo_q;

    vga_initials u_vga_render (
        .vidon    (vidon),
        .hc       (hc),
        .vc       (vc),
        .M        (vga_word_data),
        .sw       (8'h00),
        .rom_addr (vga_word_addr),
        .red      (red_o),
        .green    (green_o),
        .blue     (blue_o)
    );
endmodule
