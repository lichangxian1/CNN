`timescale 1ns / 1ps

module tb_cnn_top;

    // ----------------------------------------------------
    // Signal Declaration
    // ----------------------------------------------------
    reg                 clk;
    reg                 rst_n;
    reg                 start;
    reg  [255:0]        ext_act_in;
    reg                 ext_act_valid;

    wire                done;
    wire [31:0]         fc_result;
    wire                fc_valid;

    // ----------------------------------------------------
    // Instantiate the Unit Under Test (UUT)
    // ----------------------------------------------------
    cnn_top uut (
        .clk            (clk),
        .rst_n          (rst_n),
        .start          (start),
        .ext_act_in     (ext_act_in),
        .ext_act_valid  (ext_act_valid),
        .done           (done),
        .fc_result      (fc_result),
        .fc_valid       (fc_valid)
    );

    // ----------------------------------------------------
    // Clock Generation (100MHz)
    // ----------------------------------------------------
    initial begin
        clk = 0;
        forever #5 clk = ~clk; 
    end

    // ----------------------------------------------------
    // Custom Function: Convert FP32 to Real (for iverilog compatibility)
    // ----------------------------------------------------
    function real fp32_to_real;
        input [31:0] fp32;
        reg        sign;
        reg [7:0]  exp;
        reg [22:0] frac;
        reg [10:0] exp64;
        reg [63:0] fp64;
        begin
            sign = fp32[31];
            exp  = fp32[30:23];
            frac = fp32[22:0];

            if (exp == 8'h00) begin
                exp64 = 11'h000; // Zero or Subnormal
            end else if (exp == 8'hFF) begin
                exp64 = 11'h7FF; // Inf or NaN
            end else begin
                exp64 = exp - 127 + 1023; // Normalized
            end

            fp64 = {sign, exp64, frac, 29'd0};
            fp32_to_real = $bitstoreal(fp64);
        end
    endfunction

    // ----------------------------------------------------
    // Stimulus & SRAM Backdoor Loading
    // ----------------------------------------------------
    integer file, r;
    integer val;
    integer pixel_cnt, addr_cnt;
    reg [255:0] sram_data;
    integer out_cnt;

    initial begin
        // Initialize Inputs
        rst_n = 0;
        start = 0;
        ext_act_in = 0;       
        ext_act_valid = 0;
        out_cnt = 0;

        // Generate waveform file
        $dumpfile("cnn_waveform.vcd");
        $dumpvars(0, tb_cnn_top);

        // 1. Read Test/Input.txt and load into Ping SRAM via backdoor
        file = $fopen("data/Test/Input.txt", "r");
        if (file == 0) begin
            $display("[ERROR] Cannot open file data/Test/Input.txt");
            $finish;
        end else begin
            $display("[SUCCESS] Opened data/Test/Input.txt, assembling data and writing to Ping SRAM...");
        end

        pixel_cnt = 0;
        addr_cnt = 0;
        sram_data = 256'd0;

        // Read decimal values (including negatives) one by one
        while (!$feof(file)) begin
            r = $fscanf(file, "%d", val);
            if (r == 1) begin
                // Convert signed integer to 8-bit two's complement by truncation
                sram_data[pixel_cnt*8 +: 8] = val[7:0];
                pixel_cnt = pixel_cnt + 1;
                
                // When 32 bytes (256-bit) are collected, write to SRAM memory array
                if (pixel_cnt == 32) begin
                    uut.u_sram_ping.u_sram_low.mem_array[addr_cnt]  = sram_data[127:0];
                    uut.u_sram_ping.u_sram_high.mem_array[addr_cnt] = sram_data[255:128];
                    addr_cnt = addr_cnt + 1;
                    pixel_cnt = 0;
                    sram_data = 256'd0;
                end
            end
        end
        // Handle remaining bytes
        if (pixel_cnt > 0) begin
            uut.u_sram_ping.u_sram_low.mem_array[addr_cnt]  = sram_data[127:0];
            uut.u_sram_ping.u_sram_high.mem_array[addr_cnt] = sram_data[255:128];
        end
        $fclose(file);
        $display("[SUCCESS] SRAM data loaded. Total lines written: %0d (256-bit/line).\n", addr_cnt + (pixel_cnt>0));

        // 2. Release Reset
        #100;
        rst_n = 1;
        #20;

        // 3. Start CNN State Machine
        $display("[STATUS] CNN_Controller Start...");
        start = 1;
        #10;
        start = 0;

        // Safety timeout
        #500000;
        $display("[TIMEOUT] Simulation forced to stop!");
        $finish;
    end

    // ----------------------------------------------------
    // Output Monitoring & Float Conversion
    // ----------------------------------------------------
    // ----------------------------------------------------
    // Output Monitoring & Float Conversion
    // ----------------------------------------------------
    always @(posedge clk) begin
        if (fc_valid) begin
            out_cnt = out_cnt + 1;
            // Use our custom fp32_to_real function instead of $bitstoshortreal
            $display("[Time: %0t ns] ---> FC_Result[%0d] : FP32 = %f (Hex = %x)",
                     $time, out_cnt, fp32_to_real(fc_result), fc_result);
        end
    end

    // ----------------------------------------------------
    // Simulation Termination (Independent Thread)
    // ----------------------------------------------------
    initial begin
        // Wait until the hardware asserts the done signal
        wait(done == 1'b1);
        
        $display("\n[Time: %0t ns] [STATUS] CNN top issued done signal.", $time);
        
        // Wait another 200ns to allow the 5-stage pipeline to flush the final FC results
        #200; 
        
        $display("[COMPLETE] Simulation finished successfully.");
        $finish;
    end

endmodule