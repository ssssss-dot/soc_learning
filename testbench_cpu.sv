`timescale 1ns/1ps

module testbench_cpu;

    reg clk;
    reg rst_n;

    cpu_top u_cpu (
        .clk   (clk),
        .rst_n (rst_n)
    );

    // 100MHz clock: 10ns period
    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    // reset
    initial begin
        rst_n = 1'b0;
        #20;
        rst_n = 1'b1;
    end

    // dump waveform
    initial begin
        $dumpfile("cpu.vcd");
        $dumpvars(0, testbench_cpu);
    end

    // observe write back
    always @(posedge clk) begin
        if (rst_n && u_cpu.wb_we && u_cpu.wb_waddr != 5'd0) begin
            $display("[%0t] WB: x%0d <= 0x%08h",
                     $time,
                     u_cpu.wb_waddr,
                     u_cpu.wb_wdata);
        end
    end

    // finish and print registers
    initial begin
        #1500;

        $display("-------- register file --------");
        $display("x1  = %08h", u_cpu.u_id_stage.u_reg_file.regs[1]);
        $display("x2  = %08h", u_cpu.u_id_stage.u_reg_file.regs[2]);
        $display("x3  = %08h", u_cpu.u_id_stage.u_reg_file.regs[3]);
        $display("x4  = %08h", u_cpu.u_id_stage.u_reg_file.regs[4]);
        $display("x5  = %08h", u_cpu.u_id_stage.u_reg_file.regs[5]);
        $display("x6  = %08h", u_cpu.u_id_stage.u_reg_file.regs[6]);
        $display("x7  = %08h", u_cpu.u_id_stage.u_reg_file.regs[7]);
        $display("x8  = %08h", u_cpu.u_id_stage.u_reg_file.regs[8]);
        $display("x9  = %08h", u_cpu.u_id_stage.u_reg_file.regs[9]);
        $display("x10 = %08h", u_cpu.u_id_stage.u_reg_file.regs[10]);

        $finish;
    end

endmodule
