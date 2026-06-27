`timescale 1ns / 1ps
//============================================================================
// Interface: aes_pipe_if.sv
// Description:
//   SystemVerilog interface for the pipelined AES core (aes_pipeline_top.v).
//   Streaming protocol: key_load/key_ready for the fixed key, then a beat is
//   accepted whenever (en & in_valid & key_ready); a result appears whenever
//   (en & out_valid), 10 cycles later.
//============================================================================

interface aes_pipe_if (input logic clk, input logic rst_n);

    logic [127:0] key;
    logic         key_load;
    logic         key_ready;
    logic         en;
    logic         in_valid;
    logic [127:0] in_data;
    logic         out_valid;
    logic [127:0] out_data;

    clocking drv_cb @(posedge clk);
        default input #1step output #1;
        output key, key_load, en, in_valid, in_data;
        input  key_ready, out_valid, out_data;
    endclocking

    clocking mon_cb @(posedge clk);
        default input #1step;
        input key, key_load, key_ready, en, in_valid, in_data, out_valid, out_data;
    endclocking

    modport driver  (clocking drv_cb,  input clk, rst_n);
    modport monitor (clocking mon_cb,  input clk, rst_n);

endinterface
