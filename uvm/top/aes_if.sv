`timescale 1ns / 1ps
//============================================================================
// Interface: aes_if.sv
// Description:
//   SystemVerilog interface wrapping AES-128 direct-mode signals.
//   Used by UVM driver and monitor to interact with the DUT.
//============================================================================

interface aes_if (input logic clk, input logic rst_n);

    // Direct interface signals
    logic [127:0] plaintext;
    logic [127:0] key;
    logic         start;
    logic [127:0] ciphertext;
    logic         valid;
    logic         busy;

    //------------------------------------------------------------------------
    // Clocking blocks for synchronous access
    //------------------------------------------------------------------------
    clocking drv_cb @(posedge clk);
        default input #1step output #1;
        output plaintext, key, start;
        input  ciphertext, valid, busy;
    endclocking

    clocking mon_cb @(posedge clk);
        default input #1step;
        input plaintext, key, start, ciphertext, valid, busy;
    endclocking

    //------------------------------------------------------------------------
    // Modports
    //------------------------------------------------------------------------
    modport driver  (clocking drv_cb, input clk, rst_n);
    modport monitor (clocking mon_cb, input clk, rst_n);

endinterface
