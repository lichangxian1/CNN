module Relu(
    input wire signed [7:0] data_in,
    output wire signed [7:0] data_out
    );
    
    assign data_out = data_in > 0 ? data_in : 0;
endmodule