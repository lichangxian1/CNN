module sram_256x80 (
    input  wire         CLK,
    input  wire         CEN,
    input  wire         WEN,
    input  wire [9:0]   A,  // 外部传入，高位补0即可
    input  wire [255:0] D,
    output wire [255:0] Q
);

    // 官方 128位宽 x 80深度 SRAM (处理低 128 位)
    S018V3EBCDSP_X20Y4D128_PR u_sram_low (
        .CLK(CLK), .CEN(CEN), .WEN(WEN), .A(A[6:0]), .D(D[127:0]), .Q(Q[127:0])
    );

    // 官方 128位宽 x 80深度 SRAM (处理高 128 位)
    S018V3EBCDSP_X20Y4D128_PR u_sram_high (
        .CLK(CLK), .CEN(CEN), .WEN(WEN), .A(A[6:0]), .D(D[255:128]), .Q(Q[255:128])
    );

endmodule
