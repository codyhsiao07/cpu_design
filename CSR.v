`timescale 1ns / 1ps

module csr_file (
    input   clk,
    input   rst_n,

    input   csr_en,
    input   [2:0]   csr_cmd,
    input   [11:0]  csr_addr,
    input   [31:0]  csr_wdata,
    output reg  [31:0]  csr_rdata,

    input   trap_enter,
    input   trap_is_interrupt,
    input   [31:0]  trap_pc,
    input   [31:0]  trap_cause,
    input   [31:0]  trap_tval,

    input   mret_exec,

    input   ext_irq_pending,
    input   timer_irq_pending,
    input   soft_irq_pending,

    output  [31:0]   mtvec_o,
    output  [31:0]   mepc_o,
    output  [31:0]   mcause_o,
    output  [31:0]   mstatus_o,
    output  [31:0]   mie_o,
    output  [31:0]   mip_o,
    output  [31:0]   mscratch_o,
    output  [1:0]    current_priv_o,

    output  global_mie_o,
    output  msie_en_o,
    output  mtie_en_o,
    output  meie_en_o
);

    // ------------------------------------------
    // CSR address map
    // ------------------------------------------
    localparam [11:0] CSR_MSTATUS  = 12'h300;
    localparam [11:0] CSR_MIE      = 12'h304;
    localparam [11:0] CSR_MTVEC    = 12'h305;
    localparam [11:0] CSR_MSCRATCH = 12'h340;
    localparam [11:0] CSR_MEPC     = 12'h341;
    localparam [11:0] CSR_MCAUSE   = 12'h342;
    localparam [11:0] CSR_MTVAL    = 12'h343;
    localparam [11:0] CSR_MIP      = 12'h344;
    localparam [11:0] CSR_MHARTID  = 12'hF14;

    // ------------------------------------------
    // CSR command encoding
    // 001 = CSRRW
    // 010 = CSRRS
    // 011 = CSRRC
    // ------------------------------------------
    localparam [2:0] CSR_CMD_NONE = 3'b000;
    localparam [2:0] CSR_CMD_W    = 3'b001;
    localparam [2:0] CSR_CMD_S    = 3'b010;
    localparam [2:0] CSR_CMD_C    = 3'b011;

    // ------------------------------------------
    // Internal CSR registers
    // ------------------------------------------
    reg [31:0] mstatus;
    reg [31:0] mie;
    reg [31:0] mtvec;
    reg [31:0] mscratch;
    reg [31:0] mepc;
    reg [31:0] mcause;
    reg [31:0] mtval;
    reg [31:0] mip_sw;
    reg [1:0]  priv_mode_q;

    wire [31:0] mip;

    reg  [31:0] csr_old;
    reg  [31:0] csr_new;

    reg  [31:0] mstatus_wr_value;
    reg  [31:0] mie_wr_value;
    reg  [31:0] mip_wr_value;
    reg  [31:0] mepc_wr_value;
    reg  [31:0] mcause_wr_value;

    localparam [1:0] PRIV_U = 2'b00;
    localparam [1:0] PRIV_S = 2'b01;
    localparam [1:0] PRIV_M = 2'b11;

    // ------------------------------------------
    // mip comes from external pending signals
    // bit 3  = MSIP
    // bit 7  = MTIP
    // bit 11 = MEIP
    // ------------------------------------------
    assign mip = {20'b0,
                  (mip_sw[11] | ext_irq_pending),
                  3'b000,
                  (mip_sw[7] | timer_irq_pending),
                  3'b000,
                  (mip_sw[3] | soft_irq_pending),
                  3'b000};

    // ------------------------------------------
    // CSR read mux
    // ------------------------------------------
    always @(*) begin
        case (csr_addr)
            CSR_MSTATUS:  csr_rdata = mstatus;
            CSR_MIE:      csr_rdata = mie;
            CSR_MTVEC:    csr_rdata = mtvec;
            CSR_MSCRATCH: csr_rdata = mscratch;
            CSR_MEPC:     csr_rdata = mepc;
            CSR_MCAUSE:   csr_rdata = mcause;
            CSR_MTVAL:    csr_rdata = mtval;
            CSR_MIP:      csr_rdata = mip;
            CSR_MHARTID:  csr_rdata = 32'b0;
            default:      csr_rdata = 32'b0;
        endcase
    end

    // ------------------------------------------
    // Old value for CSR RMW operation
    // ------------------------------------------
    always @(*) begin
        csr_old = csr_rdata;
    end

    // ------------------------------------------
    // CSR command result
    // ------------------------------------------
    always @(*) begin
        case (csr_cmd)
            CSR_CMD_W: csr_new = csr_wdata;
            CSR_CMD_S: csr_new = csr_old | csr_wdata;
            CSR_CMD_C: csr_new = csr_old & (~csr_wdata);
            default:   csr_new = csr_old;
        endcase
    end

    // ------------------------------------------
    // Writable-mask handling
    // mstatus: allow only MIE(3), MPIE(7), MPP(12:11)
    // mie    : allow only MSIE(3), MTIE(7), MEIE(11)
    // mepc   : bit[1:0] forced 0 (4-byte aligned in this simple design)
    // mcause : allow full write in this minimal model
    // ------------------------------------------
    always @(*) begin
        mstatus_wr_value = mstatus;
        mstatus_wr_value[3]    = csr_new[3];
        mstatus_wr_value[7]    = csr_new[7];
        mstatus_wr_value[12:11]= csr_new[12:11];
    end

    always @(*) begin
        mie_wr_value = mie;
        mie_wr_value[3]  = csr_new[3];
        mie_wr_value[7]  = csr_new[7];
        mie_wr_value[11] = csr_new[11];
    end

    always @(*) begin
        mip_wr_value = mip_sw;
        mip_wr_value[3]  = csr_new[3];
        mip_wr_value[7]  = csr_new[7];
        mip_wr_value[11] = csr_new[11];
    end

    always @(*) begin
        mepc_wr_value = csr_new;
        mepc_wr_value[1:0] = 2'b00;
    end

    always @(*) begin
        mcause_wr_value = csr_new;
    end

    // ------------------------------------------
    // Sequential update
    // Priority:
    // 1) reset
    // 2) trap_enter
    // 3) mret_exec
    // 4) normal CSR write
    // ------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mstatus  <= 32'b0;
            mie      <= 32'b0;
            mtvec    <= 32'b0;
            mscratch <= 32'b0;
            mepc     <= 32'b0;
            mcause   <= 32'b0;
            mtval    <= 32'b0;
            mip_sw   <= 32'b0;
            priv_mode_q <= PRIV_M;
        end else begin
            if (trap_enter) begin
                // Save trap information
                mepc   <= {trap_pc[31:2], 2'b00};
                mcause <= {trap_is_interrupt, trap_cause[30:0]};
                mtval  <= trap_is_interrupt ? 32'b0 : trap_tval;

                // mstatus update on trap
                // MPIE <= MIE
                mstatus[7] <= mstatus[3];

                // MIE <= 0
                mstatus[3] <= 1'b0;

                // MPP <= current privilege, then enter machine mode
                mstatus[12:11] <= priv_mode_q;
                priv_mode_q <= PRIV_M;
            end else if (mret_exec) begin
                // Restore interrupt enable
                mstatus[3] <= mstatus[7];

                // MPIE <= 1
                mstatus[7] <= 1'b1;

                // MPP <= 00
                mstatus[12:11] <= 2'b00;
                priv_mode_q <= mstatus[12:11];
            end else if (csr_en) begin
                case (csr_addr)
                    CSR_MSTATUS: begin
                        mstatus <= mstatus_wr_value;
                    end

                    CSR_MIE: begin
                        mie <= mie_wr_value;
                    end

                    CSR_MTVEC: begin
                        mtvec <= csr_new;
                    end

                    CSR_MSCRATCH: begin
                        mscratch <= csr_new;
                    end

                    CSR_MEPC: begin
                        mepc <= mepc_wr_value;
                    end

                    CSR_MCAUSE: begin
                        mcause <= mcause_wr_value;
                    end

                    CSR_MTVAL: begin
                        mtval <= csr_new;
                    end

                    CSR_MIP: begin
                        mip_sw <= mip_wr_value;
                    end

                    default: begin
                    end
                endcase
            end
        end
    end

    // ------------------------------------------
    // Outputs
    // ------------------------------------------
    assign mtvec_o      = mtvec;
    assign mepc_o       = mepc;
    assign mcause_o     = mcause;
    assign mstatus_o    = mstatus;
    assign mie_o        = mie;
    assign mip_o        = mip;
    assign mscratch_o   = mscratch;
    assign current_priv_o = priv_mode_q;

    assign global_mie_o = mstatus[3];
    assign msie_en_o    = mie[3];
    assign mtie_en_o    = mie[7];
    assign meie_en_o    = mie[11];

endmodule
