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

    function automatic integer input_value(input integer id, k);
        if (id == 2)
            input_value = (k % 2 == 0) ? (4-k) : -(4-k); // 4,-3,2,-1
        else
            input_value = k + 1; // 1,2,3,4
    endfunction

    function automatic integer weight_value(input integer id, oc, k);
        if (id == 2) weight_value = 8 - oc - 2*k;
        else         weight_value = oc + k - 8;
    endfunction

    task automatic put_byte(input integer byte_addr, input integer value);
        bram[byte_addr/4][(byte_addr%4)*8 +: 8] = value[7:0];
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

    task automatic run_case(input integer id);
        integer oc, k, g, lane, sum, scaled, mult, shift, relu;
        begin
            @(negedge clk);
            monitor_enable = 1'b0;
            case_id = id;
            data_errors = 0;
            mult = (id == 3) ? 3 : 1;
            shift = (id == 3) ? 1 : 0;
            relu = (id == 2) ? 1 : 0;

            // 每次只重填数据，不复位DUT，检查能否连续启动不同任务。
            // 最后一个字的高两字节应保留EE，便于检查越界写入。
            for (k = 0; k < 5; k = k + 1)
                bram[k] = 32'hEEEE_EEEE;
            for (k = 0; k < IN_COUNT; k = k + 1)
                put_byte(INPUT_BASE + k, input_value(id, k));

            // [输出组][输入特征][PE列]；第二组只有两列有效，其余补0。
            for (g = 0; g < 2; g = g + 1)
                for (k = 0; k < IN_COUNT; k = k + 1)
                    for (lane = 0; lane < 16; lane = lane + 1) begin
                        oc = g*16 + lane;
                        put_byte(WEIGHT_BASE + (g*IN_COUNT+k)*16 + lane,
                                 (oc < OUT_COUNT) ? weight_value(id, oc, k) : 0);
                    end

            for (oc = 0; oc < OUT_COUNT; oc = oc + 1) begin
                bram[BIAS_BASE/4 + oc] = oc - 9;
                // 直接按点积求参考答案，不引用任何DUT内部结果。
                sum = oc - 9;
                for (k = 0; k < IN_COUNT; k = k + 1)
                    sum = sum + input_value(id, k) * weight_value(id, oc, k);
                golden_sum[oc] = sum;
                // 最近整数舍入，半值远离0；随后可选ReLU和INT8限幅。
                scaled = sum * mult;
                if (shift != 0) begin
                    if (scaled >= 0) scaled = (scaled + (1 << (shift-1))) / (1 << shift);
                    else scaled = -((-scaled + (1 << (shift-1))) / (1 << shift));
                end
                if (relu && scaled < 0) scaled = 0;
                if (scaled > 127) scaled = 127;
                if (scaled < -128) scaled = -128;
                golden_data[oc] = scaled;
                actual_sum[oc] = 32'hEEEE_EEEE;
                actual_data[oc] = 8'hEE;
            end

            write_reg(`FC_IN_FEATURES_ADDR, IN_COUNT);
            write_reg(`FC_OUT_FEATURES_ADDR, OUT_COUNT);
            write_reg(`FC_INPUT_BASE_ADDR, INPUT_BASE);
            write_reg(`FC_WEIGHT_BASE_ADDR, WEIGHT_BASE);
            write_reg(`FC_BIAS_BASE_ADDR, BIAS_BASE);
            write_reg(`FC_QUANT_MULT_ADDR, mult);
            write_reg(`FC_QUANT_SHIFT_ADDR, shift);
            monitor_enable = 1'b1;
            write_reg(`FC_CONTROL_ADDR, relu ? 32'd7 : 32'd3);

            wait (fc_done);
            // 完成后继续观察，不能把done之后多出的结果掩盖掉。
            repeat (20) @(negedge clk);
            for (oc = 0; oc < OUT_COUNT; oc = oc + 1) begin
                actual_data[oc] = bram[oc/4][(oc%4)*8 +: 8];
                if (actual_data[oc] !== golden_data[oc])
                    data_errors = data_errors + 1;
            end
            if (bram[4][31:16] !== 16'hEEEE) data_errors = data_errors + 1;
            case_pass[id-1] = (accum_count == OUT_COUNT) && (accum_errors == 0)
                           && (write_count == OUT_COUNT) && (write_errors == 0)
                           && (data_errors == 0) && (dut.error === 1'b0)
                           && (fc_busy === 1'b0) && (fc_irq === 1'b1);
            repeat (5) @(negedge clk);
        end
    endtask

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
        for (integer i = 0; i < 16384; i = i + 1) bram[i] = 0;
        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        run_case(1);
        run_case(2);
        run_case(3);
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
