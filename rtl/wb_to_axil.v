`timescale 1ns / 1ps
//============================================================================
// Module:  wb_to_axil.v
// Project: AES-128 Core - NEORV32 integration glue
// Author:  Mohammed Hajjar
// Date:    June 2026
//
// Description:
//   Wishbone-b4 (classic) SLAVE  ->  AXI4-Lite MASTER bridge for single
//   32-bit transfers. It lets NEORV32's external bus (XBUS, a classic
//   Wishbone interface) drive the AXI4-Lite slave AES coprocessor
//   (aes_coproc.v) with ordinary CPU load/store instructions - so the AES
//   block stays byte-for-byte unchanged and the CPU sees it as plain MMIO.
//
//   One outstanding transaction at a time (matches NEORV32 classic XBUS):
//     write : drive AW+W together, wait B, then pulse Wishbone ACK.
//     read  : drive AR, wait R (capture RDATA), then pulse Wishbone ACK.
//
//   The AES coprocessor asserts AWREADY and WREADY together (it waits for
//   both AWVALID and WVALID), so the bridge drives both at once and the
//   simultaneous-handshake path is the common case.
//
//   Address: only the low AXI_ADDR_W bits of the Wishbone address reach the
//   slave, i.e. the register offset inside the coprocessor's MMIO window.
//   The window base (e.g. 0x9000_0000) is decoded upstream by XBUS.
//============================================================================

module wb_to_axil #(
    parameter ADDR_W     = 32,   // Wishbone address width (byte address)
    parameter AXI_ADDR_W = 7     // AXI4-Lite slave address width (reg window)
)(
    input  wire                  clk,
    input  wire                  rst_n,

    // ---- Wishbone-b4 classic slave (from NEORV32 XBUS) ---------------------
    input  wire                  wb_cyc_i,
    input  wire                  wb_stb_i,
    input  wire                  wb_we_i,
    input  wire [ADDR_W-1:0]     wb_adr_i,
    input  wire [31:0]           wb_dat_i,
    input  wire [3:0]            wb_sel_i,
    output reg  [31:0]           wb_dat_o,
    output reg                   wb_ack_o,
    output wire                  wb_err_o,

    // ---- AXI4-Lite master (to aes_coproc) ----------------------------------
    output reg  [AXI_ADDR_W-1:0] m_axi_awaddr,
    output wire [2:0]            m_axi_awprot,
    output reg                   m_axi_awvalid,
    input  wire                  m_axi_awready,
    output reg  [31:0]           m_axi_wdata,
    output reg  [3:0]            m_axi_wstrb,
    output reg                   m_axi_wvalid,
    input  wire                  m_axi_wready,
    input  wire [1:0]            m_axi_bresp,
    input  wire                  m_axi_bvalid,
    output reg                   m_axi_bready,
    output reg  [AXI_ADDR_W-1:0] m_axi_araddr,
    output wire [2:0]            m_axi_arprot,
    output reg                   m_axi_arvalid,
    input  wire                  m_axi_arready,
    input  wire [31:0]           m_axi_rdata,
    input  wire [1:0]            m_axi_rresp,
    input  wire                  m_axi_rvalid,
    output reg                   m_axi_rready
);

    assign wb_err_o   = 1'b0;     // coprocessor never errors; all writes OKAY
    assign m_axi_awprot = 3'b000;
    assign m_axi_arprot = 3'b000;

    localparam [2:0] S_IDLE = 3'd0,
                     S_AW   = 3'd1,   // write address+data outstanding
                     S_B    = 3'd2,   // write response outstanding
                     S_AR   = 3'd3,   // read address outstanding
                     S_R    = 3'd4;   // read data outstanding

    reg [2:0] state;
    reg       aw_done, w_done;

    // `armed` gates acceptance of a new request. After a transfer completes we
    // disarm and only re-arm once the master has dropped cyc/stb, so a strobe
    // held high for several cycles past ACK (a compliant classic-Wishbone
    // master may do this) cannot be mistaken for a second transfer.
    reg  armed;

    // A fresh access is cyc&stb while idle, armed, and not in the ACK cycle.
    wire wb_req = wb_cyc_i & wb_stb_i & ~wb_ack_o & armed;

    always @(posedge clk) begin
        if (!rst_n) begin
            state         <= S_IDLE;
            m_axi_awvalid <= 1'b0;
            m_axi_wvalid  <= 1'b0;
            m_axi_bready  <= 1'b0;
            m_axi_arvalid <= 1'b0;
            m_axi_rready  <= 1'b0;
            m_axi_awaddr  <= {AXI_ADDR_W{1'b0}};
            m_axi_araddr  <= {AXI_ADDR_W{1'b0}};
            m_axi_wdata   <= 32'd0;
            m_axi_wstrb   <= 4'd0;
            wb_dat_o      <= 32'd0;
            wb_ack_o      <= 1'b0;
            aw_done       <= 1'b0;
            w_done        <= 1'b0;
            armed         <= 1'b1;
        end else begin
            wb_ack_o <= 1'b0;     // ACK is a single-cycle pulse

            case (state)
                //------------------------------------------------------------
                S_IDLE: begin
                    if (!armed) begin
                        // re-arm only after the master releases the strobe
                        if (!(wb_cyc_i && wb_stb_i)) armed <= 1'b1;
                    end else if (wb_req) begin
                        if (wb_we_i) begin
                            m_axi_awaddr  <= wb_adr_i[AXI_ADDR_W-1:0];
                            m_axi_awvalid <= 1'b1;
                            m_axi_wdata   <= wb_dat_i;
                            m_axi_wstrb   <= wb_sel_i;
                            m_axi_wvalid  <= 1'b1;
                            aw_done       <= 1'b0;
                            w_done        <= 1'b0;
                            state         <= S_AW;
                        end else begin
                            m_axi_araddr  <= wb_adr_i[AXI_ADDR_W-1:0];
                            m_axi_arvalid <= 1'b1;
                            state         <= S_AR;
                        end
                    end
                end

                //------------------------------------------------------------
                // Write: independently retire AW and W, then expect B.
                S_AW: begin
                    if (m_axi_awvalid && m_axi_awready) begin
                        m_axi_awvalid <= 1'b0;
                        aw_done       <= 1'b1;
                    end
                    if (m_axi_wvalid && m_axi_wready) begin
                        m_axi_wvalid <= 1'b0;
                        w_done       <= 1'b1;
                    end
                    if ((aw_done || (m_axi_awvalid && m_axi_awready)) &&
                        (w_done  || (m_axi_wvalid  && m_axi_wready))) begin
                        m_axi_bready <= 1'b1;
                        state        <= S_B;
                    end
                end

                S_B: begin
                    if (m_axi_bvalid && m_axi_bready) begin
                        m_axi_bready <= 1'b0;
                        wb_ack_o     <= 1'b1;   // tell Wishbone the write landed
                        armed        <= 1'b0;   // wait for strobe release before next
                        state        <= S_IDLE;
                    end
                end

                //------------------------------------------------------------
                // Read: retire AR, then capture R.
                S_AR: begin
                    if (m_axi_arvalid && m_axi_arready) begin
                        m_axi_arvalid <= 1'b0;
                        m_axi_rready  <= 1'b1;
                        state         <= S_R;
                    end
                end

                S_R: begin
                    if (m_axi_rvalid && m_axi_rready) begin
                        m_axi_rready <= 1'b0;
                        wb_dat_o     <= m_axi_rdata;
                        wb_ack_o     <= 1'b1;   // tell Wishbone read data is valid
                        armed        <= 1'b0;   // wait for strobe release before next
                        state        <= S_IDLE;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
