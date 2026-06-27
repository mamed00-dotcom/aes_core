`timescale 1ns / 1ps
// ===========================================================================
// tb_neorv32_aes.sv - top-level testbench for the NEORV32 + AES SoC
// Project: AES-128 Core - real RISC-V integration (NEORV32)
// Author:  Mohammed Hajjar
//
// Clocks/resets the SoC and lets the compiled firmware run on the real RISC-V
// core. The firmware drives the AES coprocessor over the XBUS->AXI4-Lite path,
// checks the hardware ciphertext against the FIPS-197 C.1 known answer, and
// writes a PASS/FAIL sentinel to GPIO. This TB simply observes that sentinel.
//
// PASS here means: a real RV32 core executing compiled instructions performed
// MMIO loads/stores to the AES hardware and got the NIST-correct ciphertext.
// ===========================================================================

module tb_neorv32_aes;

    logic        clk  = 1'b0;
    logic        rstn = 1'b0;
    logic [31:0] gpio;
    logic        aes_irq;

    localparam logic [31:0] SENTINEL_PASS = 32'h600DC0DE;
    localparam logic [31:0] SENTINEL_FAIL = 32'hBAD00000;

    // VHDL SoC top (mixed-language instantiation; default CLOCK_HZ = 100 MHz)
    neorv32_aes_soc dut (
        .clk_i     (clk),
        .rstn_i    (rstn),
        .gpio_o    (gpio),
        .aes_irq_o (aes_irq)
    );

    // 100 MHz
    always #5 clk = ~clk;

    integer cyc = 0;
    always @(posedge clk) cyc = cyc + 1;

    initial begin
        // hold reset a few cycles, then release
        rstn = 1'b0;
        repeat (20) @(posedge clk);
        rstn = 1'b1;

        // wait for the firmware to report, with a generous cycle budget
        // (key expansion + bus round-trips + pipeline latency are all small,
        //  but CPU boot/crt0 takes a few thousand cycles)
        while ((gpio !== SENTINEL_PASS) && (gpio !== SENTINEL_FAIL) &&
               (cyc < 2000000)) begin
            @(posedge clk);
        end

        $display("========================================================");
        if (gpio === SENTINEL_PASS) begin
            $display("  NEORV32 drove the AES coprocessor over XBUS->AXI4-Lite");
            $display("  ciphertext matches FIPS-197 C.1 known answer");
            $display("  *** PASS *** (finished at cycle %0d)", cyc);
        end else if (gpio === SENTINEL_FAIL) begin
            $display("  *** FAIL: firmware reported a ciphertext mismatch ***");
        end else begin
            $display("  *** TIMEOUT: no sentinel after %0d cycles (gpio=%08x) ***",
                     cyc, gpio);
        end
        $display("========================================================");
        $finish;
    end

endmodule
