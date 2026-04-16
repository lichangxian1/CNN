`timescale 1ns / 1ps

module weight_rom (
    input  wire         clk,
    input  wire [11:0]  addr,    
    output reg  [2463:0] dout    
);

    // ROM 本体阵列
    reg [2463:0] rom_memory [0:1023];

    always @(posedge clk) begin
        dout <= rom_memory[addr];
    end

endmodule