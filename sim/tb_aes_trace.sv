`timescale 1ns/1ps
//============================================================================
// tb_aes_trace.sv - one full aes_enc through XBUS(Wishbone) -> wb_to_axil ->
//                   AXI4-Lite -> aes_coproc, for waveform inspection.
//
// A small Wishbone master stands in for the NEORV32 CPU's load/store traffic
// and performs exactly the sequence the firmware does: load key, push a block,
// wait, read the ciphertext. Open the resulting waveform to watch the bus
// handshakes, the key-expansion FSM, and the 10-stage pipeline.
//============================================================================
module tb_aes_trace;

    localparam [127:0] NIST_KEY = 128'h000102030405060708090a0b0c0d0e0f;
    localparam [127:0] NIST_PT  = 128'h00112233445566778899aabbccddeeff;
    localparam [127:0] NIST_CT  = 128'h69c4e0d86a7b0430d8cdb78070b4c55a;

    // register offsets
    localparam [31:0] CTRL=32'h00, STATUS=32'h04, KEY0=32'h10, DIN0=32'h20, DOUT0=32'h30;
    localparam [31:0] PUSH=32'h1, POP=32'h2, KEYLOAD=32'h4;

    reg clk=0, rst_n=0;
    always #5 clk=~clk;

    // ---- Wishbone (XBUS) master signals ----
    reg         wb_cyc, wb_stb, wb_we;
    reg  [31:0] wb_adr, wb_dat_w;
    reg  [3:0]  wb_sel;
    wire [31:0] wb_dat_r;
    wire        wb_ack, wb_err;

    // ---- AXI4-Lite between bridge and coproc ----
    wire [6:0]  awaddr, araddr;
    wire [2:0]  awprot, arprot;
    wire        awvalid, awready, wvalid, wready, bvalid, bready;
    wire        arvalid, arready, rvalid, rready;
    wire [31:0] wdata, rdata;
    wire [3:0]  wstrb;
    wire [1:0]  bresp, rresp;
    wire        irq;

    wb_to_axil bridge (
        .clk(clk), .rst_n(rst_n),
        .wb_cyc_i(wb_cyc), .wb_stb_i(wb_stb), .wb_we_i(wb_we),
        .wb_adr_i(wb_adr), .wb_dat_i(wb_dat_w), .wb_sel_i(wb_sel),
        .wb_dat_o(wb_dat_r), .wb_ack_o(wb_ack), .wb_err_o(wb_err),
        .m_axi_awaddr(awaddr), .m_axi_awprot(awprot), .m_axi_awvalid(awvalid), .m_axi_awready(awready),
        .m_axi_wdata(wdata), .m_axi_wstrb(wstrb), .m_axi_wvalid(wvalid), .m_axi_wready(wready),
        .m_axi_bresp(bresp), .m_axi_bvalid(bvalid), .m_axi_bready(bready),
        .m_axi_araddr(araddr), .m_axi_arprot(arprot), .m_axi_arvalid(arvalid), .m_axi_arready(arready),
        .m_axi_rdata(rdata), .m_axi_rresp(rresp), .m_axi_rvalid(rvalid), .m_axi_rready(rready)
    );

    aes_coproc coproc (
        .clk(clk), .rst_n(rst_n),
        .s_axi_awaddr(awaddr), .s_axi_awprot(awprot), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
        .s_axi_wdata(wdata), .s_axi_wstrb(wstrb), .s_axi_wvalid(wvalid), .s_axi_wready(wready),
        .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
        .s_axi_araddr(araddr), .s_axi_arprot(arprot), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
        .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rvalid(rvalid), .s_axi_rready(rready),
        .irq(irq)
    );

    // ---- Wishbone master tasks (classic single transfer) ----
    task automatic wbw(input [31:0] a, input [31:0] d);
        begin
            @(negedge clk);
            wb_cyc=1; wb_stb=1; wb_we=1; wb_adr=a; wb_dat_w=d; wb_sel=4'hf;
            forever begin @(posedge clk); if (wb_ack) break; end
            @(negedge clk); wb_cyc=0; wb_stb=0; wb_we=0;
        end
    endtask

    task automatic wbr(input [31:0] a, output [31:0] d);
        begin
            @(negedge clk);
            wb_cyc=1; wb_stb=1; wb_we=0; wb_adr=a; wb_sel=4'hf;
            forever begin @(posedge clk); if (wb_ack) break; end
            d = wb_dat_r;
            @(negedge clk); wb_cyc=0; wb_stb=0;
        end
    endtask

    reg [31:0] st, c0,c1,c2,c3;
    reg [127:0] ct;

    initial begin
        wb_cyc=0; wb_stb=0; wb_we=0; wb_adr=0; wb_dat_w=0; wb_sel=0;
        repeat (4) @(posedge clk); rst_n=1; @(posedge clk);

        // ---- KEY LOAD ----
        wbw(KEY0+0, NIST_KEY[127:96]);
        wbw(KEY0+4, NIST_KEY[95:64]);
        wbw(KEY0+8, NIST_KEY[63:32]);
        wbw(KEY0+12,NIST_KEY[31:0]);
        wbw(CTRL, KEYLOAD);
        do wbr(STATUS, st); while (!st[4]);        // wait key_ready (bit4)

        // ---- PUSH a plaintext block ----
        wbw(DIN0+0, NIST_PT[127:96]);
        wbw(DIN0+4, NIST_PT[95:64]);
        wbw(DIN0+8, NIST_PT[63:32]);
        wbw(DIN0+12,NIST_PT[31:0]);
        wbw(CTRL, PUSH);

        // ---- WAIT for result ----
        do wbr(STATUS, st); while (st[3]);         // wait out not empty (bit3)

        // ---- READ ciphertext + POP ----
        wbr(DOUT0+0, c0); wbr(DOUT0+4, c1); wbr(DOUT0+8, c2); wbr(DOUT0+12, c3);
        ct = {c0,c1,c2,c3};
        wbw(CTRL, POP);

        $display("=====================================================");
        if (ct === NIST_CT) $display("  TRACE aes_enc PASS  CT=%032h", ct);
        else                $display("  TRACE aes_enc FAIL  exp=%032h got=%032h", NIST_CT, ct);
        $display("=====================================================");
        repeat (5) @(posedge clk);
        $finish;
    end

    initial begin #50000; $display("timeout"); $finish; end
endmodule
