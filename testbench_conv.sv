// 仿真时间单位为1ns，精度为1ps；define.sv 提供卷积寄存器的地址宏。
`timescale 1ns/1ps
`include "define.sv"

module testbench_conv;
    // 1. 时钟和存储布局：t=100 表示周期100ns，即10MHz仿真时钟。
    // 本TB测试独立Conv2，使用行为级BRAM，未例化CPU、DMA和DDR。
    parameter t = 100;

    localparam [31:0] INPUT_BASE  = 32'h0000_5000; // 输入图像在共享 BRAM 中的起始字节地址。
    localparam [31:0] WEIGHT_BASE = 32'h0000_7000; // 卷积权重在共享 BRAM 中的起始字节地址。
    localparam [13:0] BIAS_BASE   = 14'h1000;      // bias 的起始字地址；一个 INT32 bias 占一个 32 位字。

    // 2. 测试规模和量化参数：1600个INT8输出，4字节一组，共400次BRAM写入。
    // 参考量化中的16和32也对应shift=5；修改参数时要同时调整参考公式。
    localparam integer QUANT_MULT = 3;
    localparam integer QUANT_SHIFT = 5;
    localparam integer OUTPUT_BYTES = 16 * 10 * 10;

    // 3. golden是独立计算的正确答案，先生成，再与硬件实际结果比较。
    // 参考值按 [输出通道][输出行][输出列] 展平，index = oc*100 + y*10 + x。
    integer golden_sum [0:OUTPUT_BYTES-1];       // 卷积累加并加 bias，量化前的有符号值
    logic [7:0] golden_data [0:OUTPUT_BYTES-1];  // 量化、ReLU、限幅后的预期值
    // 三个计数来自参考模型：负累加值、量化值1～126、量化值超过127。
    // 它们用于确认测试数据覆盖这些情况，不是硬件实时输出计数。
    integer negative_count, normal_count, saturated_count;

    // 4. 检查结果：check_done表示检查结束，test_pass表示所有条件通过。
    // accum_count/errors：量化前收到的结果数/错误数。
    // write_count/errors：BRAM写入次数/地址或strb错误数。
    // data_errors：最终BRAM中与golden_data不符的字节数，结束时才统计。
    // first_bad_index=-1表示没有发现最终字节错误；出错时保存首个错误的索引和数值。
    // 仿真结束看这些信号即可，不使用 $display 输出日志。
    logic check_done, test_pass;
    integer accum_count, accum_errors;
    integer write_count, write_errors, data_errors;
    integer first_bad_index;
    logic [7:0] first_actual, first_expected;

    // 5. 公共控制：rst_n低有效；超时结束时timed_out会变成1。
    logic clk;
    logic rst_n;
    logic timed_out;

    // 6. 模拟CPU访问卷积寄存器的MMIO接口。
    // 请求在req_valid与req_ready同时为1的上升沿被接收。
    // 响应在rsp_valid与rsp_ready同时为1的上升沿被接收。
    // 本TB只写配置，conv_rdata未用于读取；conv_busy可用来观察运行阶段。
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
    wire         conv_busy;

    // 7. 卷积模块访问共享BRAM的接口：读写地址均为32位字的索引。
    // 16384个32位字共64KiB；strb每一位控制一个字节是否写入。
    wire         acc_rd_en;
    wire [13:0]  acc_rd_addr;
    logic [31:0] acc_rd_data;
    logic        acc_rd_valid;
    wire         acc_wr_en;
    wire [13:0]  acc_wr_addr;
    wire [31:0]  acc_wr_data;
    wire [3:0]   acc_wr_strb;
    logic [31:0] bram [0:16383];

    // 8. DUT（被测模块）：所有卷积子模块均在dut内部。
    // 波形中的层级根是testbench_conv.dut，例如dut.u_int32_int8。
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
        .conv_busy(conv_busy),
        .acc_rd_en(acc_rd_en),
        .acc_rd_addr(acc_rd_addr),
        .acc_rd_data(acc_rd_data),
        .acc_rd_valid(acc_rd_valid),
        .acc_wr_en(acc_wr_en),
        .acc_wr_addr(acc_wr_addr),
        .acc_wr_data(acc_wr_data),
        .acc_wr_strb(acc_wr_strb)
    );

    // 9. 独立产生时钟：每半个周期翻转一次，和下面的初始化流程并行运行。
    initial begin
        clk = 1'b0;
        forever #(t/2) clk = ~clk;
    end

    // 10. 同步BRAM模型：上升沿写入选中的字节，或者读取一个32位字。
    // 写优先，同拍读写请求都有时只执行写；NBA赋值在该上升沿之后更新。
    // 例如strb=0001只更新[7:0]，strb=1111更新整个字。
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

    // 11. 读返回有效信号与acc_rd_data同步打拍。
    // 有效读请求被上升沿采样后，数据和valid一起更新，供下游下一个上升沿采样。
    // 没有返回时valid=0，此时不要根据acc_rd_data的保留值判断数据是否重复。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) acc_rd_valid <= 1'b0;
        else        acc_rd_valid <= acc_rd_en && !acc_wr_en;
    end

    // 12. 寄存器写任务：每调用一次，完成一次完整的请求/响应握手。
    // 下降沿设置地址、数据和valid，避开DUT上升沿采样时刻。
    // 等ready后跨过一个上升沿，再撤销请求；等响应并接收后才能写下一项。
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

    // 13. 输入像素生成函数：ic为输入通道0～5，y/x为像素行列0～13。
    // %17取余得到0～16，再减8得到-8～8；公式只用于构造测试数据。
    // 数据随坐标变化，但允许数值重复；同一参数每次调用结果相同。
    // integer为32位有符号整数；给函数名赋值就是返回值。
    // automatic使每次调用的参数/局部变量独立；函数本身不等待时钟。
    function automatic integer input_value(input integer ic, y, x);
        input_value = (ic*7 + y*3 + x*5 + y*x) % 17 - 8; // -8～8
    endfunction

    // 14. 权重生成函数：oc为输出通道0～15，ic为输入通道0～5。
    // ky/kx为5×5核内部的行列0～4；%9减4得到-4～4，测试有符号乘法。
    function automatic integer weight_value(input integer oc, ic, ky, kx);
        weight_value = (oc*3 + ic*5 + ky*7 + kx*2 + oc*kx + ic*ky) % 9 - 4; // -4～4
    endfunction

    // 15. 每个输出通道一个INT32 bias，在6个输入通道累加完后只加一次。
    //加很大的偏置检查限幅
    function automatic integer bias_value(input integer oc);
        // ch0 保证负数归零，ch1 保证正数限幅，其余通道观察变化的输出。
        if (oc == 0)      bias_value = -20000;
        else if (oc == 1) bias_value =  20000;
        else             bias_value = (oc - 8) * 37;
    endfunction

    // 16. 初始化BRAM的辅助任务：一个INT8放进对应字节。
    // byte_addr/4选择32位字，byte_addr%4选择该字中的第0～3个字节。
    // [起点 +: 8]表示从起点向高位选8位；低地址对应一个字的低8位。
    // value[7:0]保留INT8补码，例如-8保存为8'hF8，读出后按signed解释。
    task automatic put_byte(input integer byte_addr, input integer value);
        bram[byte_addr / 4][(byte_addr % 4)*8 +: 8] = value[7:0];
    endtask

    // 17. 在线检查器：和主测试流程并行，不向DUT施加任何控制。
    // 同时检查量化前的结果，避免负数全部被 ReLU 清零后掩盖卷积错误。
    // 在上升沿采样：这里和接收数据的量化模块/BRAM看到的是同一拍。
    // accum_count更新前的值就是当前结果索引；只在valid=1时比较并加一。
    // 写地址应依次为0～399，且每次strb都应为1111；!==也能识别X/Z。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            accum_count  <= 0;
            accum_errors <= 0;
            write_count  <= 0;
            write_errors <= 0;
        end
        else begin
            if (dut.accum_result_valid) begin
                if (accum_count >= OUTPUT_BYTES)
                    accum_errors <= accum_errors + 1;
                else if (dut.accum_result !== golden_sum[accum_count])
                    accum_errors <= accum_errors + 1;
                accum_count <= accum_count + 1;
            end
            if (acc_wr_en) begin
                if ((acc_wr_addr !== write_count) || (acc_wr_strb !== 4'b1111))
                    write_errors <= write_errors + 1;
                write_count <= write_count + 1;
            end
        end
    end

    // 18. 主测试流程：初始化 -> 生成数据和golden -> 配置启动 -> 等done -> 检查。
    // 下面不带@或#的初始化for循环都在仿真时间0完成，不是一轮循环消耗一拍。
    initial begin : run_test
        integer byte_addr, index, sum, scaled;
        // 18.1 拉低复位，清空请求和检查状态；计数器由上面的时序块复位。
        rst_n = 1'b0;
        timed_out = 1'b0;
        conv_req_valid = 1'b0;
        conv_rsp_ready = 1'b0;
        conv_wdata = 32'd0;
        conv_addr = 32'd0;
        conv_wstrb = 4'd0;
        conv_we = 1'b0;
        acc_rd_data = 32'd0;
        check_done = 1'b0;
        test_pass = 1'b0;
        data_errors = 0;
        first_bad_index = -1;
        first_actual = 8'd0;
        first_expected = 8'd0;
        negative_count = 0;
        normal_count = 0;
        saturated_count = 0;

        // 18.2 清空BRAM并预填输出标记。
        // Conv2：6×14×14 输入，16×10×10 输出，stride=1，无 padding。
        for (integer i = 0; i < 16384; i = i + 1)
            bram[i] = 32'd0;
        // 输出先填非零标记，防止未写入的位置被误认为 ReLU 的正确零值。
        for (integer i = 0; i < OUTPUT_BYTES/4; i = i + 1)
            bram[i] = 32'hEEEE_EEEE;

        // 18.3 输入按[ic][y][x]排列，每通道196字节，共1176字节，放入ram
        for (integer ic = 0; ic < 6; ic = ic + 1)
            for (integer y = 0; y < 14; y = y + 1)
                for (integer x = 0; x < 14; x = x + 1) begin
                    byte_addr = INPUT_BASE + ic*196 + y*14 + x;//地址计算
                    put_byte(byte_addr, input_value(ic, y, x));
                end

        // 18.4 权重按[ic][ky][kx][oc]排列，匹配weight_cache每次拼16个权重，放入ram
        // 每个输入通道占400字节，每个核位置连续存16个输出通道的权重。
        for (integer ic = 0; ic < 6; ic = ic + 1)
            for (integer ky = 0; ky < 5; ky = ky + 1)
                for (integer kx = 0; kx < 5; kx = kx + 1)
                    for (integer oc = 0; oc < 16; oc = oc + 1) begin
                        byte_addr = WEIGHT_BASE + ic*400 + (ky*5+kx)*16 + oc;//地址计算
                        put_byte(byte_addr, weight_value(oc, ic, ky, kx));
                    end

        // 18.5 BIAS_BASE已是字地址，直接加oc；16个bias占16字/64字节。
        for (integer oc = 0; oc < 16; oc = oc + 1)
            bram[BIAS_BASE + oc] = bias_value(oc);

        // 18.6 独立参考卷积：直接按数学坐标计算，不使用DUT的中间结果。
        // 每个输出从bias开始，累加6×5×5=150个乘积，核不翻转。
        // (y,x)窗口从输入(y,x)覆盖到(y+4,x+4)。此时sum为有符号INT32。
        for (integer oc = 0; oc < 16; oc = oc + 1)
            for (integer y = 0; y < 10; y = y + 1)
                for (integer x = 0; x < 10; x = x + 1) begin
                    index = oc*100 + y*10 + x;
                    sum = bias_value(oc);
                    for (integer ic = 0; ic < 6; ic = ic + 1)
                        for (integer ky = 0; ky < 5; ky = ky + 1)
                            for (integer kx = 0; kx < 5; kx = kx + 1)
                                sum = sum + input_value(ic, y+ky, x+kx)
                                          * weight_value(oc, ic, ky, kx);
                    golden_sum[index] = sum;

                    // 18.7 生成最终golden：此测试固定mult=3、shift=5。
                    // 非正数经ReLU输出0；正数加16后除32，半数向上舍入。
                    // 大于127时钳位127，其余保留量化值；这些计算不占时钟。
                    if (sum <= 0) begin
                        golden_data[index] = 8'd0;
                        if (sum < 0) negative_count = negative_count + 1;
                    end
                    else begin
                        scaled = (sum * QUANT_MULT + 16) / 32;
                        if (scaled > 127) begin
                            golden_data[index] = 8'd127;
                            saturated_count = saturated_count + 1;
                        end
                        else begin
                            golden_data[index] = scaled[7:0];
                            if (scaled > 0 && scaled < 127)
                                normal_count = normal_count + 1;
                        end
                    end
                end

        // 18.8 结束初始化，释放复位，按寄存器地址依次写配置。
        repeat (4) @(negedge clk); // 保持复位 4 个时钟周期，让 DUT 内部寄存器完成复位。
        rst_n = 1'b1;              // 释放低有效复位，开始写配置寄存器。

        write_reg(`CONV_INPUT_SHAPE_ADDR, {16'd14, 16'd14}); // 高 16 位配置高度 14，低 16 位配置宽度 14。
        write_reg(`CONV_CHANNELS_ADDR,    {16'd16, 16'd6}); // 高 16 位配置输出通道数 16，低 16 位配置输入通道数 6。
        write_reg(`CONV_BIAS_BASE_ADDR,   {18'd0, BIAS_BASE}); // 写入 bias 的 BRAM 字地址，高 18 位为保留位。
        write_reg(`CONV_QUANT_MULT_ADDR,  QUANT_MULT);    // 使用非1乘数，测试量化乘法。
        write_reg(`CONV_QUANT_SHIFT_ADDR, QUANT_SHIFT);   // 右移5位，测试正数舍入。
        write_reg(`CONV_INPUT_BASE_ADDR,  INPUT_BASE);    // 写入输入图像的 BRAM 起始字节地址。
        write_reg(`CONV_WEIGHT_BASE_ADDR, WEIGHT_BASE);   // 写入权重的 BRAM 起始字节地址。
        write_reg(`CONV_CONTROL_ADDR,     32'd1);         // 控制寄存器写 1，启动一次卷积。

        // 18.9 done只表示硬件报告完成；计算是否正确还要看后面的逐字节比较。
        wait (dut.done);            // 等待卷积顶层报告全部计算与输出写回完成。
        repeat (5) @(negedge clk); // 再保留 5 个时钟周期，便于在波形末尾观察完成状态。
        // 18.10 逐字节检查全部1600个输出；!==也能把X/Z判为错误。
        // i/4对应BRAM字地址，(i%4)*8对应字节起始位，顺序与put_byte一致。
        for (integer i = 0; i < OUTPUT_BYTES; i = i + 1) begin
            if (bram[i/4][(i%4)*8 +: 8] !== golden_data[i]) begin
                if (first_bad_index == -1) begin
                    first_bad_index = i;
                    first_actual = bram[i/4][(i%4)*8 +: 8];
                    first_expected = golden_data[i];
                end
                data_errors = data_errors + 1;
            end
        end
        // 18.11 汇总判定：结果数、写次数、数据、地址、覆盖率和状态必须全部正确。
        // check_done=1但test_pass=0表示检查完成但失败；未完成时test_pass=0是正常的。
        check_done = 1'b1;
        test_pass = (accum_count == OUTPUT_BYTES) && (accum_errors == 0)
                 && (write_count == OUTPUT_BYTES/4) && (write_errors == 0)
                 && (data_errors == 0) && (dut.error === 1'b0)
                 && (negative_count > 0) && (normal_count > 0)
                 && (saturated_count > 0) && !timed_out;
        repeat (5) @(negedge clk); // 留出观察 check_done/test_pass 的波形时间。
        $finish;                   // 结束本次仿真。
    end

    // 19. 超时保护，与run_test并行：12000个上升沿内未正常结束就标记超时。
    // t=100ns时约1.2ms；超时路径不会设置check_done/test_pass为1。
    initial begin
        repeat (12000) @(posedge clk);
        timed_out = 1'b1;
        $finish;
    end

    // 20. FSDB波形输出：编译时定义DUMP才启用；路径设置保持原样。
    // 运行时+FSDB=...可覆盖默认路径；Dumpvars记录整个TB层级，DumpMDA记录数组。
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
