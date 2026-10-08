`timescale 1ns/1ps
`include "define.sv"

// 独立FC测试：4个输入、18个输出，包含16+2两个输出组。
// 不例化CPU/DMA，不读取训练文件，不打印日志；结果直接看波形。
module testbench_fc;
    parameter t = 100;
    localparam integer IN_COUNT = 4;
    localparam integer OUT_COUNT = 18;
    // FC三个基地址均为字节地址；输出固定写回字节地址0。
    localparam [31:0] INPUT_BASE  = 32'h0000_1000;
    localparam [31:0] WEIGHT_BASE = 32'h0000_2000;
    localparam [31:0] BIAS_BASE   = 32'h0000_3000;

    reg clk, rst_n;
    reg fc_req_valid, fc_rsp_ready, fc_we;
    reg [31:0] fc_addr, fc_wdata;
    reg [3:0] fc_wstrb;
    wire fc_req_ready, fc_rsp_valid, fc_irq, fc_busy, fc_start, fc_done;
    wire [31:0] fc_rdata;

    wire acc_fc_rd_en, acc_fc_wr_en;
    wire [13:0] acc_fc_rd_addr, acc_fc_wr_addr;
    reg [31:0] acc_fc_rd_data;
    reg acc_fc_rd_valid;
    wire [31:0] acc_fc_wr_data;
    wire [3:0] acc_fc_wr_strb;
    reg [31:0] bram [0:16383];

    // case_id=1/2/3对应文档中的三次测试；数组下标都是全层输出编号。
    integer case_id;
    integer golden_sum [0:OUT_COUNT-1];
    integer actual_sum [0:OUT_COUNT-1];
    reg signed [7:0] golden_data [0:OUT_COUNT-1];
    reg signed [7:0] actual_data [0:OUT_COUNT-1];
    integer accum_count, accum_errors, write_count, write_errors, data_errors;
    reg monitor_enable, check_done, test_pass, timed_out;
    reg [2:0] case_pass;

    // 测试数据直接放在数组里，既用于预填BRAM，也用于计算参考答案。
    integer inputs [0:IN_COUNT-1];
    integer weights [0:OUT_COUNT-1][0:IN_COUNT-1];
    integer biases [0:OUT_COUNT-1];
    integer test_no, oc, k, g, lane;
    integer byte_addr, word_addr, byte_offset;
    integer sum, scaled, mult, shift, relu;
    reg case_ok;

    fc_top dut (
        .clk(clk), .rst_n(rst_n),
        .fc_req_valid(fc_req_valid), .fc_req_ready(fc_req_ready),
        .fc_rsp_valid(fc_rsp_valid), .fc_rsp_ready(fc_rsp_ready),
        .fc_wdata(fc_wdata), .fc_addr(fc_addr),
        .fc_wstrb(fc_wstrb), .fc_we(fc_we), .fc_rdata(fc_rdata),
        .fc_irq(fc_irq), .fc_busy(fc_busy), .fc_start(fc_start), .fc_done(fc_done),
        .acc_fc_rd_en(acc_fc_rd_en), .acc_fc_rd_addr(acc_fc_rd_addr),
        .acc_fc_rd_data(acc_fc_rd_data), .acc_fc_rd_valid(acc_fc_rd_valid),
        .acc_fc_wr_en(acc_fc_wr_en), .acc_fc_wr_addr(acc_fc_wr_addr),
        .acc_fc_wr_data(acc_fc_wr_data), .acc_fc_wr_strb(acc_fc_wr_strb)
    );

    initial begin
        clk = 1'b0;
        forever #(t/2) clk = ~clk;
    end

    // 与示例一致：同步读一拍，写优先，strb控制每个字节。
    always @(posedge clk) begin
        if (rst_n) begin
            if (acc_fc_wr_en) begin
                if (acc_fc_wr_strb[0]) bram[acc_fc_wr_addr][7:0]   <= acc_fc_wr_data[7:0];
                if (acc_fc_wr_strb[1]) bram[acc_fc_wr_addr][15:8]  <= acc_fc_wr_data[15:8];
                if (acc_fc_wr_strb[2]) bram[acc_fc_wr_addr][23:16] <= acc_fc_wr_data[23:16];
                if (acc_fc_wr_strb[3]) bram[acc_fc_wr_addr][31:24] <= acc_fc_wr_data[31:24];
            end
            else if (acc_fc_rd_en)
                acc_fc_rd_data <= bram[acc_fc_rd_addr];
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) acc_fc_rd_valid <= 1'b0;
        else acc_fc_rd_valid <= acc_fc_rd_en && !acc_fc_wr_en;
    end

    // 按示例通过MMIO写配置，下降沿改变请求，避免与DUT采样竞争。
    task automatic write_reg(input [31:0] addr, input [31:0] data);
        begin
            @(negedge clk);
            fc_addr = addr;
            fc_wdata = data;
            fc_we = 1'b1;
            fc_wstrb = 4'hf;
            fc_req_valid = 1'b1;
            wait (fc_req_ready);
            @(posedge clk);
            @(negedge clk);
            fc_req_valid = 1'b0;
            wait (fc_rsp_valid);
            fc_rsp_ready = 1'b1;
            @(posedge clk);
            @(negedge clk);
            fc_rsp_ready = 1'b0;
        end
    endtask

    // 仅观察，不干预DUT。当前FC是一字节一次写，不是四字节一次写。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            accum_count <= 0;
            accum_errors <= 0;
            write_count <= 0;
            write_errors <= 0;
        end
        else if (!monitor_enable) begin
            accum_count <= 0;
            accum_errors <= 0;
            write_count <= 0;
            write_errors <= 0;
        end
        else begin
            if (dut.accum_valid) begin
                if (accum_count < OUT_COUNT) begin
                    actual_sum[accum_count] <= dut.accum_result;
                    if (dut.accum_result !== golden_sum[accum_count])
                        accum_errors <= accum_errors + 1;
                end
                else accum_errors <= accum_errors + 1;
                accum_count <= accum_count + 1;
            end
            if (acc_fc_wr_en) begin
                if ((write_count >= OUT_COUNT) ||
                    (acc_fc_wr_addr !== (write_count / 4)) ||
                    (acc_fc_wr_strb !== (4'b0001 << (write_count % 4))))
                    write_errors <= write_errors + 1;
                write_count <= write_count + 1;
            end
        end
    end

    // 主流程从上往下看即可：复位 -> 三次测试 -> 总结检查结果。
    // 只保留write_reg任务，用来重复完成寄存器握手。
    initial begin
        rst_n = 1'b0;
        fc_req_valid = 1'b0;
        fc_rsp_ready = 1'b0;
        fc_we = 1'b0;
        fc_addr = 0;
        fc_wdata = 0;
        fc_wstrb = 0;
        acc_fc_rd_data = 0;
        case_id = 0;
        monitor_enable = 1'b0;
        check_done = 1'b0;
        test_pass = 1'b0;
        timed_out = 1'b0;
        case_pass = 3'b000;
        data_errors = 0;
        for (k = 0; k < 16384; k = k + 1)
            bram[k] = 0;
        repeat (4) @(negedge clk);
        rst_n = 1'b1;

        // 中间不复位FC，检查三次任务能否连续执行。
        for (test_no = 1; test_no <= 3; test_no = test_no + 1) begin
            @(negedge clk);
            monitor_enable = 1'b0;
            case_id = test_no;
            data_errors = 0;

            // 第1步：选择输入和量化参数。
            // 测试1：普通点积；测试2：正负输入+ReLU；测试3：舍入+限幅。
            inputs[0] = 1;
            inputs[1] = 2;
            inputs[2] = 3;
            inputs[3] = 4;
            mult = 1;
            shift = 0;
            relu = 0;
            if (case_id == 2) begin
                inputs[0] = 4;
                inputs[1] = -3;
                inputs[2] = 2;
                inputs[3] = -1;
                relu = 1;
            end
            if (case_id == 3) begin
                mult = 3;
                shift = 1;
            end

            // 第2步：生成18个输出各自的4个权重和1个偏置。
            for (oc = 0; oc < OUT_COUNT; oc = oc + 1) begin
                biases[oc] = oc - 9;
                for (k = 0; k < IN_COUNT; k = k + 1) begin
                    if (case_id == 2)
                        weights[oc][k] = 8 - oc - 2*k;
                    else
                        weights[oc][k] = oc + k - 8;
                end
            end

            // 第3步：把输入、权重、偏置放入模拟BRAM。
            // 最后一个字的高两字节应保留EE，便于检查越界写入。
            for (k = 0; k < 5; k = k + 1)
                bram[k] = 32'hEEEE_EEEE;

            // 本测试只有4个INT8输入，刚好一个字；输入0放最低字节。
            bram[INPUT_BASE/4] = {inputs[3][7:0], inputs[2][7:0],
                                  inputs[1][7:0], inputs[0][7:0]};

            // [输出组][输入特征][PE列]；第二组只有两列有效，其余补0。
            for (g = 0; g < 2; g = g + 1) begin
                for (k = 0; k < IN_COUNT; k = k + 1) begin
                    for (lane = 0; lane < 16; lane = lane + 1) begin
                        oc = g*16 + lane;
                        byte_addr = WEIGHT_BASE + (g*IN_COUNT+k)*16 + lane;
                        word_addr = byte_addr / 4;
                        byte_offset = byte_addr % 4;
                        // +: 8表示从指定起始位向高位取8位。
                        if (oc < OUT_COUNT)
                            bram[word_addr][byte_offset*8 +: 8] = weights[oc][k][7:0];
                        else
                            bram[word_addr][byte_offset*8 +: 8] = 8'd0;
                    end
                end
            end

            for (oc = 0; oc < OUT_COUNT; oc = oc + 1)
                bram[BIAS_BASE/4 + oc] = biases[oc];

            // 第4步：独立算参考答案，不能用DUT输出代替。
            for (oc = 0; oc < OUT_COUNT; oc = oc + 1) begin
                sum = biases[oc];
                for (k = 0; k < IN_COUNT; k = k + 1)
                    sum = sum + inputs[k] * weights[oc][k];
                golden_sum[oc] = sum;

                scaled = sum * mult;
                // 本TB只用shift=0或1；测试3除以2，半值向远离0方向舍入。
                if (shift == 1) begin
                    if (scaled >= 0)
                        scaled = (scaled + 1) / 2;
                    else
                        scaled = -((-scaled + 1) / 2);
                end
                if (relu && scaled < 0) scaled = 0;
                if (scaled > 127) scaled = 127;
                if (scaled < -128) scaled = -128;
                golden_data[oc] = scaled;
                actual_sum[oc] = 32'hEEEE_EEEE;
                actual_data[oc] = 8'hEE;
            end

            // 第5步：写配置寄存器，然后启动FC。
            write_reg(`FC_IN_FEATURES_ADDR, IN_COUNT);
            write_reg(`FC_OUT_FEATURES_ADDR, OUT_COUNT);
            write_reg(`FC_INPUT_BASE_ADDR, INPUT_BASE);
            write_reg(`FC_WEIGHT_BASE_ADDR, WEIGHT_BASE);
            write_reg(`FC_BIAS_BASE_ADDR, BIAS_BASE);
            write_reg(`FC_QUANT_MULT_ADDR, mult);
            write_reg(`FC_QUANT_SHIFT_ADDR, shift);
            monitor_enable = 1'b1;
            if (relu)
                write_reg(`FC_CONTROL_ADDR, 32'd7); // start+中断+ReLU
            else
                write_reg(`FC_CONTROL_ADDR, 32'd3); // start+中断

            // 第6步：等完成，再多观察20拍，检查是否还在错误地输出结果。
            wait (fc_done);
            repeat (20) @(negedge clk);
            for (oc = 0; oc < OUT_COUNT; oc = oc + 1) begin
                word_addr = oc / 4;
                byte_offset = oc % 4;
                actual_data[oc] = bram[word_addr][byte_offset*8 +: 8];
                if (actual_data[oc] !== golden_data[oc])
                    data_errors = data_errors + 1;
            end
            if (bram[4][31:16] !== 16'hEEEE) data_errors = data_errors + 1;
            // 先假定通过，任何一项不符合要求就记为失败。
            case_ok = 1'b1;
            if (accum_count != OUT_COUNT) case_ok = 1'b0;
            if (accum_errors != 0)        case_ok = 1'b0;
            if (write_count != OUT_COUNT) case_ok = 1'b0;
            if (write_errors != 0)        case_ok = 1'b0;
            if (data_errors != 0)         case_ok = 1'b0;
            if (dut.error !== 1'b0)       case_ok = 1'b0;
            if (fc_busy !== 1'b0)         case_ok = 1'b0;
            if (fc_irq !== 1'b1)          case_ok = 1'b0;
            case_pass[case_id-1] = case_ok;
            repeat (5) @(negedge clk);
        end
        check_done = 1'b1;
        test_pass = (case_pass === 3'b111) && !timed_out;
        repeat (5) @(negedge clk);
        $finish;
    end

    initial begin
        repeat (5000) @(posedge clk);
        timed_out = 1'b1;
        $finish;
    end

    // 保留用户示例的FSDB路径和开关，只将层级根改为本TB。
`ifdef DUMP
    string dump_file;
    initial begin
        if (!$value$plusargs("FSDB=%s", dump_file))
            dump_file = "./fsdb/RTL.fsdb";
        $fsdbDumpfile(dump_file);
        $fsdbDumpvars(0, testbench_fc);
        $fsdbDumpMDA();
    end
`endif
endmodule
