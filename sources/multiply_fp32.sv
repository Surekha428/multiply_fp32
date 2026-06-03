`timescale 1ns / 1ps

module fmultiplier(
    input  wire        clk,
    input  wire        rst,
    input  wire        valid,      // 1-cycle start pulse
    input  wire [31:0] a,
    input  wire [31:0] b,
    output reg  [31:0] z,
    output reg         out_valid   // 1-cycle pulse when z is updated
);

    // internal logic.

    

endmodule