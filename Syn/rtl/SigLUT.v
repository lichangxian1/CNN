`timescale 1ns / 1ps

module sigmoid_lut (
    input  wire                 clk,
    input  wire                 en,
    input  wire signed [7:0]    fc_int8_in,  // 输入定点值 (-128 ~ 127)
    output reg  [31:0]          sigmoid_out  // FP32 标准浮点
);

    // 将有符号的 INT8 转为 0~255 的无符号索引
    wire [7:0] index = fc_int8_in;
    
    // 纯组合逻辑查找表
    reg [31:0] lut_val;

    always @(*) begin
        case (index)
            8'd128: lut_val = 32'h364e5111; // x = -128, f(x) = 0.000003
            8'd129: lut_val = 32'h3663d2d3; // x = -127, f(x) = 0.000003
            8'd130: lut_val = 32'h367b9283; // x = -126, f(x) = 0.000004
            8'd131: lut_val = 32'h368ae5fa; // x = -125, f(x) = 0.000004
            8'd132: lut_val = 32'h3699609c; // x = -124, f(x) = 0.000005
            8'd133: lut_val = 32'h36a95d9f; // x = -123, f(x) = 0.000005
            8'd134: lut_val = 32'h36bb054d; // x = -122, f(x) = 0.000006
            8'd135: lut_val = 32'h36ce841d; // x = -121, f(x) = 0.000006
            8'd136: lut_val = 32'h36e40b2c; // x = -120, f(x) = 0.000007
            8'd137: lut_val = 32'h36fbd0b6; // x = -119, f(x) = 0.000008
            8'd138: lut_val = 32'h370b084e; // x = -118, f(x) = 0.000008
            8'd139: lut_val = 32'h3719867f; // x = -117, f(x) = 0.000009
            8'd140: lut_val = 32'h37298771; // x = -116, f(x) = 0.000010
            8'd141: lut_val = 32'h373b3373; // x = -115, f(x) = 0.000011
            8'd142: lut_val = 32'h374eb70b; // x = -114, f(x) = 0.000012
            8'd143: lut_val = 32'h37644360; // x = -113, f(x) = 0.000014
            8'd144: lut_val = 32'h377c0eba; // x = -112, f(x) = 0.000015
            8'd145: lut_val = 32'h378b2a84; // x = -111, f(x) = 0.000017
            8'd146: lut_val = 32'h3799ac3e; // x = -110, f(x) = 0.000018
            8'd147: lut_val = 32'h37a9b114; // x = -109, f(x) = 0.000020
            8'd148: lut_val = 32'h37bb6161; // x = -108, f(x) = 0.000022
            8'd149: lut_val = 32'h37cee9b2; // x = -107, f(x) = 0.000025
            8'd150: lut_val = 32'h37e47b3c; // x = -106, f(x) = 0.000027
            8'd151: lut_val = 32'h37fc4c50; // x = -105, f(x) = 0.000030
            8'd152: lut_val = 32'h380b4c77; // x = -104, f(x) = 0.000033
            8'd153: lut_val = 32'h3819d1a9; // x = -103, f(x) = 0.000037
            8'd154: lut_val = 32'h3829da50; // x = -102, f(x) = 0.000040
            8'd155: lut_val = 32'h383b8ed0; // x = -101, f(x) = 0.000045
            8'd156: lut_val = 32'h384f1bbe; // x = -100, f(x) = 0.000049
            8'd157: lut_val = 32'h3864b258; // x = -99, f(x) = 0.000055
            8'd158: lut_val = 32'h387c88fd; // x = -98, f(x) = 0.000060
            8'd159: lut_val = 32'h388b6dda; // x = -97, f(x) = 0.000066
            8'd160: lut_val = 32'h3899f664; // x = -96, f(x) = 0.000073
            8'd161: lut_val = 32'h38aa02b5; // x = -95, f(x) = 0.000081
            8'd162: lut_val = 32'h38bbbb36; // x = -94, f(x) = 0.000090
            8'd163: lut_val = 32'h38cf4c85; // x = -93, f(x) = 0.000099
            8'd164: lut_val = 32'h38e4e7e8; // x = -92, f(x) = 0.000109
            8'd165: lut_val = 32'h38fcc3c3; // x = -91, f(x) = 0.000121
            8'd166: lut_val = 32'h390b8e14; // x = -90, f(x) = 0.000133
            8'd167: lut_val = 32'h391a19b4; // x = -89, f(x) = 0.000147
            8'd168: lut_val = 32'h392a295d; // x = -88, f(x) = 0.000162
            8'd169: lut_val = 32'h393be57e; // x = -87, f(x) = 0.000179
            8'd170: lut_val = 32'h394f7ab6; // x = -86, f(x) = 0.000198
            8'd171: lut_val = 32'h39651a4e; // x = -85, f(x) = 0.000218
            8'd172: lut_val = 32'h397cfaae; // x = -84, f(x) = 0.000241
            8'd173: lut_val = 32'h398babf3; // x = -83, f(x) = 0.000266
            8'd174: lut_val = 32'h399a3a23; // x = -82, f(x) = 0.000294
            8'd175: lut_val = 32'h39aa4c83; // x = -81, f(x) = 0.000325
            8'd176: lut_val = 32'h39bc0b7c; // x = -80, f(x) = 0.000359
            8'd177: lut_val = 32'h39cfa3ac; // x = -79, f(x) = 0.000396
            8'd178: lut_val = 32'h39e54652; // x = -78, f(x) = 0.000437
            8'd179: lut_val = 32'h39fd29cd; // x = -77, f(x) = 0.000483
            8'd180: lut_val = 32'h3a0bc510; // x = -76, f(x) = 0.000533
            8'd181: lut_val = 32'h3a1a54c5; // x = -75, f(x) = 0.000589
            8'd182: lut_val = 32'h3a2a6895; // x = -74, f(x) = 0.000650
            8'd183: lut_val = 32'h3a3c28d9; // x = -73, f(x) = 0.000718
            8'd184: lut_val = 32'h3a4fc21a; // x = -72, f(x) = 0.000793
            8'd185: lut_val = 32'h3a65657f; // x = -71, f(x) = 0.000875
            8'd186: lut_val = 32'h3a7d4944; // x = -70, f(x) = 0.000966
            8'd187: lut_val = 32'h3a8bd4a2; // x = -69, f(x) = 0.001067
            8'd188: lut_val = 32'h3a9a63c3; // x = -68, f(x) = 0.001178
            8'd189: lut_val = 32'h3aaa7674; // x = -67, f(x) = 0.001301
            8'd190: lut_val = 32'h3abc34e6; // x = -66, f(x) = 0.001436
            8'd191: lut_val = 32'h3acfcb6e; // x = -65, f(x) = 0.001585
            8'd192: lut_val = 32'h3ae56af1; // x = -64, f(x) = 0.001750
            8'd193: lut_val = 32'h3afd495d; // x = -63, f(x) = 0.001932
            8'd194: lut_val = 32'h3b0bd114; // x = -62, f(x) = 0.002133
            8'd195: lut_val = 32'h3b1a5b72; // x = -61, f(x) = 0.002355
            8'd196: lut_val = 32'h3b2a67ec; // x = -60, f(x) = 0.002600
            8'd197: lut_val = 32'h3b3c1e54; // x = -59, f(x) = 0.002870
            8'd198: lut_val = 32'h3b4faa8f; // x = -58, f(x) = 0.003169
            8'd199: lut_val = 32'h3b653cf7; // x = -57, f(x) = 0.003498
            8'd200: lut_val = 32'h3b7d0ace; // x = -56, f(x) = 0.003861
            8'd201: lut_val = 32'h3b8ba75c; // x = -55, f(x) = 0.004262
            8'd202: lut_val = 32'h3b9a24a3; // x = -54, f(x) = 0.004704
            8'd203: lut_val = 32'h3baa20c0; // x = -53, f(x) = 0.005192
            8'd204: lut_val = 32'h3bbbc2c7; // x = -52, f(x) = 0.005730
            8'd205: lut_val = 32'h3bcf35b0; // x = -51, f(x) = 0.006324
            8'd206: lut_val = 32'h3be4a8b6; // x = -50, f(x) = 0.006978
            8'd207: lut_val = 32'h3bfc4fbb; // x = -49, f(x) = 0.007700
            8'd208: lut_val = 32'h3c0b31dc; // x = -48, f(x) = 0.008496
            8'd209: lut_val = 32'h3c19919a; // x = -47, f(x) = 0.009373
            8'd210: lut_val = 32'h3c29695f; // x = -46, f(x) = 0.010340
            8'd211: lut_val = 32'h3c3adebc; // x = -45, f(x) = 0.011406
            8'd212: lut_val = 32'h3c4e1ad3; // x = -44, f(x) = 0.012580
            8'd213: lut_val = 32'h3c634aa5; // x = -43, f(x) = 0.013873
            8'd214: lut_val = 32'h3c7a9f60; // x = -42, f(x) = 0.015297
            8'd215: lut_val = 32'h3c8a275b; // x = -41, f(x) = 0.016864
            8'd216: lut_val = 32'h3c984998; // x = -40, f(x) = 0.018590
            8'd217: lut_val = 32'h3ca7d649; // x = -39, f(x) = 0.020488
            8'd218: lut_val = 32'h3cb8f014; // x = -38, f(x) = 0.022575
            8'd219: lut_val = 32'h3ccbbc98; // x = -37, f(x) = 0.024870
            8'd220: lut_val = 32'h3ce06499; // x = -36, f(x) = 0.027392
            8'd221: lut_val = 32'h3cf71426; // x = -35, f(x) = 0.030161
            8'd222: lut_val = 32'h3d07fd65; // x = -34, f(x) = 0.033201
            8'd223: lut_val = 32'h3d15a5d7; // x = -33, f(x) = 0.036535
            8'd224: lut_val = 32'h3d249ed9; // x = -32, f(x) = 0.040191
            8'd225: lut_val = 32'h3d3505c4; // x = -31, f(x) = 0.044195
            8'd226: lut_val = 32'h3d46f9df; // x = -30, f(x) = 0.048578
            8'd227: lut_val = 32'h3d5a9c5c; // x = -29, f(x) = 0.053372
            8'd228: lut_val = 32'h3d70104c; // x = -28, f(x) = 0.058609
            8'd229: lut_val = 32'h3d83bd47; // x = -27, f(x) = 0.064326
            8'd230: lut_val = 32'h3d9080d3; // x = -26, f(x) = 0.070558
            8'd231: lut_val = 32'h3d9e66ca; // x = -25, f(x) = 0.077344
            8'd232: lut_val = 32'h3dad83c3; // x = -24, f(x) = 0.084724
            8'd233: lut_val = 32'h3dbdecc5; // x = -23, f(x) = 0.092737
            8'd234: lut_val = 32'h3dcfb711; // x = -22, f(x) = 0.101423
            8'd235: lut_val = 32'h3de2f7da; // x = -21, f(x) = 0.110824
            8'd236: lut_val = 32'h3df7c3fb; // x = -20, f(x) = 0.120979
            8'd237: lut_val = 32'h3e0717ca; // x = -19, f(x) = 0.131927
            8'd238: lut_val = 32'h3e1326d3; // x = -18, f(x) = 0.143703
            8'd239: lut_val = 32'h3e2017c9; // x = -17, f(x) = 0.156341
            8'd240: lut_val = 32'h3e2df24f; // x = -16, f(x) = 0.169870
            8'd241: lut_val = 32'h3e3cbcae; // x = -15, f(x) = 0.184314
            8'd242: lut_val = 32'h3e4c7b8e; // x = -14, f(x) = 0.199690
            8'd243: lut_val = 32'h3e5d31a9; // x = -13, f(x) = 0.216010
            8'd244: lut_val = 32'h3e6edf7c; // x = -12, f(x) = 0.233274
            8'd245: lut_val = 32'h3e80c180; // x = -11, f(x) = 0.251476
            8'd246: lut_val = 32'h3e8a8bb8; // x = -10, f(x) = 0.270597
            8'd247: lut_val = 32'h3e94ca83; // x = -9, f(x) = 0.290608
            8'd248: lut_val = 32'h3e9f7870; // x = -8, f(x) = 0.311466
            8'd249: lut_val = 32'h3eaa8e72; // x = -7, f(x) = 0.333118
            8'd250: lut_val = 32'h3eb603e1; // x = -6, f(x) = 0.355498
            8'd251: lut_val = 32'h3ec1ce88; // x = -5, f(x) = 0.378529
            8'd252: lut_val = 32'h3ecde2ba; // x = -4, f(x) = 0.402120
            8'd253: lut_val = 32'h3eda337b; // x = -3, f(x) = 0.426174
            8'd254: lut_val = 32'h3ee6b2b3; // x = -2, f(x) = 0.450582
            8'd255: lut_val = 32'h3ef35167; // x = -1, f(x) = 0.475230
            8'd0: lut_val = 32'h3f000000; // x = 0, f(x) = 0.500000
            8'd1: lut_val = 32'h3f06574c; // x = 1, f(x) = 0.524770
            8'd2: lut_val = 32'h3f0ca6a6; // x = 2, f(x) = 0.549418
            8'd3: lut_val = 32'h3f12e642; // x = 3, f(x) = 0.573826
            8'd4: lut_val = 32'h3f190ea3; // x = 4, f(x) = 0.597880
            8'd5: lut_val = 32'h3f1f18bc; // x = 5, f(x) = 0.621471
            8'd6: lut_val = 32'h3f24fe0f; // x = 6, f(x) = 0.644502
            8'd7: lut_val = 32'h3f2ab8c7; // x = 7, f(x) = 0.666882
            8'd8: lut_val = 32'h3f3043c8; // x = 8, f(x) = 0.688534
            8'd9: lut_val = 32'h3f359abe; // x = 9, f(x) = 0.709392
            8'd10: lut_val = 32'h3f3aba24; // x = 10, f(x) = 0.729403
            8'd11: lut_val = 32'h3f3f9f40; // x = 11, f(x) = 0.748524
            8'd12: lut_val = 32'h3f444821; // x = 12, f(x) = 0.766726
            8'd13: lut_val = 32'h3f48b396; // x = 13, f(x) = 0.783990
            8'd14: lut_val = 32'h3f4ce11c; // x = 14, f(x) = 0.800310
            8'd15: lut_val = 32'h3f50d0d5; // x = 15, f(x) = 0.815686
            8'd16: lut_val = 32'h3f54836c; // x = 16, f(x) = 0.830130
            8'd17: lut_val = 32'h3f57fa0e; // x = 17, f(x) = 0.843659
            8'd18: lut_val = 32'h3f5b364b; // x = 18, f(x) = 0.856297
            8'd19: lut_val = 32'h3f5e3a0e; // x = 19, f(x) = 0.868073
            8'd20: lut_val = 32'h3f610781; // x = 20, f(x) = 0.879021
            8'd21: lut_val = 32'h3f63a105; // x = 21, f(x) = 0.889176
            8'd22: lut_val = 32'h3f66091e; // x = 22, f(x) = 0.898577
            8'd23: lut_val = 32'h3f684267; // x = 23, f(x) = 0.907263
            8'd24: lut_val = 32'h3f6a4f88; // x = 24, f(x) = 0.915276
            8'd25: lut_val = 32'h3f6c3327; // x = 25, f(x) = 0.922656
            8'd26: lut_val = 32'h3f6defe6; // x = 26, f(x) = 0.929442
            8'd27: lut_val = 32'h3f6f8857; // x = 27, f(x) = 0.935674
            8'd28: lut_val = 32'h3f70fefb; // x = 28, f(x) = 0.941391
            8'd29: lut_val = 32'h3f72563a; // x = 29, f(x) = 0.946628
            8'd30: lut_val = 32'h3f739062; // x = 30, f(x) = 0.951422
            8'd31: lut_val = 32'h3f74afa4; // x = 31, f(x) = 0.955805
            8'd32: lut_val = 32'h3f75b612; // x = 32, f(x) = 0.959809
            8'd33: lut_val = 32'h3f76a5a3; // x = 33, f(x) = 0.963465
            8'd34: lut_val = 32'h3f77802a; // x = 34, f(x) = 0.966799
            8'd35: lut_val = 32'h3f78475f; // x = 35, f(x) = 0.969839
            8'd36: lut_val = 32'h3f78fcdb; // x = 36, f(x) = 0.972608
            8'd37: lut_val = 32'h3f79a21b; // x = 37, f(x) = 0.975130
            8'd38: lut_val = 32'h3f7a387f; // x = 38, f(x) = 0.977425
            8'd39: lut_val = 32'h3f7ac14e; // x = 39, f(x) = 0.979512
            8'd40: lut_val = 32'h3f7b3db3; // x = 40, f(x) = 0.981410
            8'd41: lut_val = 32'h3f7baec5; // x = 41, f(x) = 0.983136
            8'd42: lut_val = 32'h3f7c1583; // x = 42, f(x) = 0.984703
            8'd43: lut_val = 32'h3f7c72d5; // x = 43, f(x) = 0.986127
            8'd44: lut_val = 32'h3f7cc795; // x = 44, f(x) = 0.987420
            8'd45: lut_val = 32'h3f7d1485; // x = 45, f(x) = 0.988594
            8'd46: lut_val = 32'h3f7d5a5b; // x = 46, f(x) = 0.989660
            8'd47: lut_val = 32'h3f7d99ba; // x = 47, f(x) = 0.990627
            8'd48: lut_val = 32'h3f7dd339; // x = 48, f(x) = 0.991504
            8'd49: lut_val = 32'h3f7e0761; // x = 49, f(x) = 0.992300
            8'd50: lut_val = 32'h3f7e36af; // x = 50, f(x) = 0.993022
            8'd51: lut_val = 32'h3f7e6195; // x = 51, f(x) = 0.993676
            8'd52: lut_val = 32'h3f7e887a; // x = 52, f(x) = 0.994270
            8'd53: lut_val = 32'h3f7eabbe; // x = 53, f(x) = 0.994808
            8'd54: lut_val = 32'h3f7ecbb7; // x = 54, f(x) = 0.995296
            8'd55: lut_val = 32'h3f7ee8b1; // x = 55, f(x) = 0.995738
            8'd56: lut_val = 32'h3f7f02f5; // x = 56, f(x) = 0.996139
            8'd57: lut_val = 32'h3f7f1ac3; // x = 57, f(x) = 0.996502
            8'd58: lut_val = 32'h3f7f3055; // x = 58, f(x) = 0.996831
            8'd59: lut_val = 32'h3f7f43e2; // x = 59, f(x) = 0.997130
            8'd60: lut_val = 32'h3f7f5598; // x = 60, f(x) = 0.997400
            8'd61: lut_val = 32'h3f7f65a5; // x = 61, f(x) = 0.997645
            8'd62: lut_val = 32'h3f7f742f; // x = 62, f(x) = 0.997867
            8'd63: lut_val = 32'h3f7f815b; // x = 63, f(x) = 0.998068
            8'd64: lut_val = 32'h3f7f8d4b; // x = 64, f(x) = 0.998250
            8'd65: lut_val = 32'h3f7f981a; // x = 65, f(x) = 0.998415
            8'd66: lut_val = 32'h3f7fa1e6; // x = 66, f(x) = 0.998564
            8'd67: lut_val = 32'h3f7faac5; // x = 67, f(x) = 0.998699
            8'd68: lut_val = 32'h3f7fb2ce; // x = 68, f(x) = 0.998822
            8'd69: lut_val = 32'h3f7fba16; // x = 69, f(x) = 0.998933
            8'd70: lut_val = 32'h3f7fc0ae; // x = 70, f(x) = 0.999034
            8'd71: lut_val = 32'h3f7fc6a7; // x = 71, f(x) = 0.999125
            8'd72: lut_val = 32'h3f7fcc0f; // x = 72, f(x) = 0.999207
            8'd73: lut_val = 32'h3f7fd0f6; // x = 73, f(x) = 0.999282
            8'd74: lut_val = 32'h3f7fd566; // x = 74, f(x) = 0.999350
            8'd75: lut_val = 32'h3f7fd96b; // x = 75, f(x) = 0.999411
            8'd76: lut_val = 32'h3f7fdd0f; // x = 76, f(x) = 0.999467
            8'd77: lut_val = 32'h3f7fe05b; // x = 77, f(x) = 0.999517
            8'd78: lut_val = 32'h3f7fe357; // x = 78, f(x) = 0.999563
            8'd79: lut_val = 32'h3f7fe60c; // x = 79, f(x) = 0.999604
            8'd80: lut_val = 32'h3f7fe87f; // x = 80, f(x) = 0.999641
            8'd81: lut_val = 32'h3f7feab6; // x = 81, f(x) = 0.999675
            8'd82: lut_val = 32'h3f7fecb9; // x = 82, f(x) = 0.999706
            8'd83: lut_val = 32'h3f7fee8b; // x = 83, f(x) = 0.999734
            8'd84: lut_val = 32'h3f7ff030; // x = 84, f(x) = 0.999759
            8'd85: lut_val = 32'h3f7ff1ae; // x = 85, f(x) = 0.999782
            8'd86: lut_val = 32'h3f7ff308; // x = 86, f(x) = 0.999802
            8'd87: lut_val = 32'h3f7ff442; // x = 87, f(x) = 0.999821
            8'd88: lut_val = 32'h3f7ff55d; // x = 88, f(x) = 0.999838
            8'd89: lut_val = 32'h3f7ff65e; // x = 89, f(x) = 0.999853
            8'd90: lut_val = 32'h3f7ff747; // x = 90, f(x) = 0.999867
            8'd91: lut_val = 32'h3f7ff81a; // x = 91, f(x) = 0.999879
            8'd92: lut_val = 32'h3f7ff8d9; // x = 92, f(x) = 0.999891
            8'd93: lut_val = 32'h3f7ff986; // x = 93, f(x) = 0.999901
            8'd94: lut_val = 32'h3f7ffa22; // x = 94, f(x) = 0.999910
            8'd95: lut_val = 32'h3f7ffab0; // x = 95, f(x) = 0.999919
            8'd96: lut_val = 32'h3f7ffb30; // x = 96, f(x) = 0.999927
            8'd97: lut_val = 32'h3f7ffba5; // x = 97, f(x) = 0.999934
            8'd98: lut_val = 32'h3f7ffc0e; // x = 98, f(x) = 0.999940
            8'd99: lut_val = 32'h3f7ffc6d; // x = 99, f(x) = 0.999945
            8'd100: lut_val = 32'h3f7ffcc4; // x = 100, f(x) = 0.999951
            8'd101: lut_val = 32'h3f7ffd12; // x = 101, f(x) = 0.999955
            8'd102: lut_val = 32'h3f7ffd59; // x = 102, f(x) = 0.999960
            8'd103: lut_val = 32'h3f7ffd99; // x = 103, f(x) = 0.999963
            8'd104: lut_val = 32'h3f7ffdd3; // x = 104, f(x) = 0.999967
            8'd105: lut_val = 32'h3f7ffe07; // x = 105, f(x) = 0.999970
            8'd106: lut_val = 32'h3f7ffe37; // x = 106, f(x) = 0.999973
            8'd107: lut_val = 32'h3f7ffe62; // x = 107, f(x) = 0.999975
            8'd108: lut_val = 32'h3f7ffe89; // x = 108, f(x) = 0.999978
            8'd109: lut_val = 32'h3f7ffead; // x = 109, f(x) = 0.999980
            8'd110: lut_val = 32'h3f7ffecd; // x = 110, f(x) = 0.999982
            8'd111: lut_val = 32'h3f7ffeea; // x = 111, f(x) = 0.999983
            8'd112: lut_val = 32'h3f7fff04; // x = 112, f(x) = 0.999985
            8'd113: lut_val = 32'h3f7fff1c; // x = 113, f(x) = 0.999986
            8'd114: lut_val = 32'h3f7fff31; // x = 114, f(x) = 0.999988
            8'd115: lut_val = 32'h3f7fff45; // x = 115, f(x) = 0.999989
            8'd116: lut_val = 32'h3f7fff56; // x = 116, f(x) = 0.999990
            8'd117: lut_val = 32'h3f7fff66; // x = 117, f(x) = 0.999991
            8'd118: lut_val = 32'h3f7fff75; // x = 118, f(x) = 0.999992
            8'd119: lut_val = 32'h3f7fff82; // x = 119, f(x) = 0.999992
            8'd120: lut_val = 32'h3f7fff8e; // x = 120, f(x) = 0.999993
            8'd121: lut_val = 32'h3f7fff99; // x = 121, f(x) = 0.999994
            8'd122: lut_val = 32'h3f7fffa2; // x = 122, f(x) = 0.999994
            8'd123: lut_val = 32'h3f7fffab; // x = 123, f(x) = 0.999995
            8'd124: lut_val = 32'h3f7fffb3; // x = 124, f(x) = 0.999995
            8'd125: lut_val = 32'h3f7fffbb; // x = 125, f(x) = 0.999996
            8'd126: lut_val = 32'h3f7fffc1; // x = 126, f(x) = 0.999996
            8'd127: lut_val = 32'h3f7fffc7; // x = 127, f(x) = 0.999997
            default: lut_val = 32'h00000000;
        endcase
    end

    // 打一拍输出 (与之前顶层 cnn_top 里的时序完美匹配)
    always @(posedge clk) begin
        if (en) begin
            sigmoid_out <= lut_val;
        end
    end

endmodule