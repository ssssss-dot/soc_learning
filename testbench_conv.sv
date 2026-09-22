`timescale 1ns/1ps
`include "define.sv"

module testbench_conv;
    parameter t = 100;

    localparam [31:0] INPUT_BASE  = 32'h0000_5000; // 输入图像在共享 BRAM 中的起始字节地址。
    localparam [31:0] WEIGHT_BASE = 32'h0000_7000; // 卷积权重在共享 BRAM 中的起始字节地址。
    localparam [13:0] BIAS_BASE   = 14'h1000;      // bias 的起始字地址；一个 INT32 bias 占一个 32 位字。

    logic clk;
    logic rst_n;
    logic timed_out;

    // CPU MMIO interface
    logic        conv_req_valid;
    wire         conv_req_ready;
    wire         conv_rsp_valid;
    logic        conv_rsp_ready;
    logic [31:0] conv_wdata;
    logic [31:0] conv_addr;
    logic [3:0]  conv_wstrb;
    logic        conv_we;
    wire [31:0]  conv_rdata;
    wire         conv_irq;

    // Shared BRAM interface
    wire         acc_rd_en;
    wire [13:0]  acc_rd_addr;
    logic [31:0] acc_rd_data;
    logic        acc_rd_valid;
    wire         acc_wr_en;
    wire [13:0]  acc_wr_addr;
    wire [31:0]  acc_wr_data;
    wire [3:0]   acc_wr_strb;
    logic [31:0] bram [0:16383];

    conv_top dut (
        .clk(clk),
        .rst_n(rst_n),
        .conv_req_valid(conv_req_valid),
        .conv_req_ready(conv_req_ready),
        .conv_rsp_valid(conv_rsp_valid),
        .conv_rsp_ready(conv_rsp_ready),
        .conv_wdata(conv_wdata),
        .conv_addr(conv_addr),
        .conv_wstrb(conv_wstrb),
        .conv_we(conv_we),
        .conv_rdata(conv_rdata),
        .conv_irq(conv_irq),
        .acc_rd_en(acc_rd_en),
        .acc_rd_addr(acc_rd_addr),
        .acc_rd_data(acc_rd_data),
        .acc_rd_valid(acc_rd_valid),
        .acc_wr_en(acc_wr_en),
        .acc_wr_addr(acc_wr_addr),
        .acc_wr_data(acc_wr_data),
        .acc_wr_strb(acc_wr_strb)
    );

    initial begin
        clk = 1'b0;
        forever #(t/2) clk = ~clk;
    end

    // BRAM 模型：时钟沿上写入选中的字节，或者读取一个 32 位字。
    always @(posedge clk) begin
        if (acc_wr_en) begin
            if (acc_wr_strb[0]) bram[acc_wr_addr][7:0]   <= acc_wr_data[7:0];
            if (acc_wr_strb[1]) bram[acc_wr_addr][15:8]  <= acc_wr_data[15:8];
            if (acc_wr_strb[2]) bram[acc_wr_addr][23:16] <= acc_wr_data[23:16];
            if (acc_wr_strb[3]) bram[acc_wr_addr][31:24] <= acc_wr_data[31:24];
        end
        else if (acc_rd_en) begin
            acc_rd_data <= bram[acc_rd_addr];
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) acc_rd_valid <= 1'b0;
        else        acc_rd_valid <= acc_rd_en && !acc_wr_en;
    end

    // Hold a register request until the MMIO handshake completes.
    task automatic write_reg(input logic [31:0] addr, input logic [31:0] data);
        begin
            @(negedge clk);
            conv_addr      = addr;
            conv_wdata     = data;
            conv_we        = 1'b1;
            conv_wstrb     = 4'hf;
            conv_req_valid = 1'b1;
            wait (conv_req_ready);
            @(posedge clk);
            @(negedge clk);
            conv_req_valid = 1'b0;
            wait (conv_rsp_valid);
            conv_rsp_ready = 1'b1;
            @(posedge clk);
            @(negedge clk);
            conv_rsp_ready = 1'b0;
        end
    endtask

    initial begin
        rst_n = 1'b0;
        timed_out = 1'b0;
        conv_req_valid = 1'b0;
        conv_rsp_ready = 1'b0;
        conv_wdata = 32'd0;
        conv_addr = 32'd0;
        conv_wstrb = 4'd0;
        conv_we = 1'b0;

        // Conv2 使用 6 个 14×14 输入通道、16 个 5×5 卷积核，因此每个输出通道是 10×10。
        // 每个窗口有 6×5×5=150 次乘加：像素和权重均为 1、bias 为 0，所以累加结果为 150。
        // 量化乘数为 1、右移量为 8：正数舍入后 (150+128)>>8 = 1；ReLU 后仍为 1。
        for (integer i = 0; i < 16384; i = i + 1) // 遍历整个 16384 字的 BRAM，先清空旧数据。
            bram[i] = 32'd0;                        // 所有字置零；bias 区域因此也是 0。
        for (integer i = 0; i < 6*14*14/4; i = i + 1) // 6 张图共 1176 个 INT8 像素，按 4 字节/字写入 294 字。
            bram[(INPUT_BASE >> 2) + i] = 32'h0101_0101; // 字节地址右移 2 位转为 BRAM 字索引；每个字放 4 个数值 1。
        for (integer i = 0; i < 6*16*25/4; i = i + 1) // 6 个输入通道×16 个输出通道×25 个权重，共 2400 字节、600 字。
            bram[(WEIGHT_BASE >> 2) + i] = 32'h0101_0101; // 从权重起始字索引写入，每字的 4 个 INT8 权重都为 1。

        repeat (4) @(negedge clk); // 保持复位 4 个时钟周期，让 DUT 内部寄存器完成复位。
        rst_n = 1'b1;              // 释放低有效复位，开始写配置寄存器。

        write_reg(`CONV_INPUT_SHAPE_ADDR, {16'd14, 16'd14}); // 高 16 位配置高度 14，低 16 位配置宽度 14。
        write_reg(`CONV_CHANNELS_ADDR,    {16'd16, 16'd6}); // 高 16 位配置输出通道数 16，低 16 位配置输入通道数 6。
        write_reg(`CONV_BIAS_BASE_ADDR,   {18'd0, BIAS_BASE}); // 写入 bias 的 BRAM 字地址，高 18 位为保留位。
        write_reg(`CONV_QUANT_MULT_ADDR,  32'd1);         // 量化乘数设为 1，保持累加值的大小。
        write_reg(`CONV_QUANT_SHIFT_ADDR, 32'd8);         // 量化时算术右移 8 位，并按量化模块的规则舍入。
        write_reg(`CONV_INPUT_BASE_ADDR,  INPUT_BASE);    // 写入输入图像的 BRAM 起始字节地址。
        write_reg(`CONV_WEIGHT_BASE_ADDR, WEIGHT_BASE);   // 写入权重的 BRAM 起始字节地址。
        write_reg(`CONV_CONTROL_ADDR,     32'd1);         // 控制寄存器写 1，启动一次卷积。

        wait (dut.done);            // 等待卷积顶层报告全部计算与输出写回完成。
        repeat (5) @(negedge clk); // 再保留 5 个时钟周期，便于在波形末尾观察完成状态。
        $finish;                   // 结束本次仿真。
    end

    // If done never arrives, use timed_out and the internal signals in the waveform.
    initial begin
        repeat (12000) @(posedge clk);
        timed_out = 1'b1;
        $finish;
    end

    // VCS: +define+DUMP +FSDB=fsdb/RTL.fsdb
`ifdef DUMP
    string dump_file;
    initial begin
        if (!$value$plusargs("FSDB=%s", dump_file))
            dump_file = "./fsdb/RTL.fsdb";
        $fsdbDumpfile(dump_file);
        $fsdbDumpvars(0, testbench_conv);
        $fsdbDumpMDA();
    end
`endif
endmodule
