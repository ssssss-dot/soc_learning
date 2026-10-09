`include "define.sv"

//四级流水线做量化,锁存，乘法，右移，relu
module fc_int32_int8 (
    input  wire               clk,
    input  wire               rst_n,

    // accumulation 已加 bias 的串行结果
    input  wire signed [31:0] result_i,
    input  wire               result_valid_i,

    // 每层的量化参数，来自 conv_reg / conv_ctrl
    input  wire        [31:0] quant_mult_i,
    input  wire        [5:0]  quant_shift_i,

    input addr_init,
    
    //判断是否要relu
    input relu_enable,

    //写回完成信号
    output reg result_done,

    input [4:0] group_bias_count_i, // 当前组有效输出数：通常16，FC3为10
    input group_start,             // ctrl给出的新组开始脉冲

    output wire         acc_fc_wr_en,
    output wire  [13:0]  acc_fc_wr_addr,
    output reg  [`DataBus]  acc_fc_wr_data,
    output wire  [3:0]   acc_fc_wr_strb
);

//量化完成的结果，后面打包写回
reg  signed [7:0]  data_o;
reg                data_valid_o;
reg [1:0] ptr;
reg [13:0] addr_ptr;
reg [4:0] result_cnt;//判断写回了多少个int8数据，与输入的groupcnt比较

reg signed [63:0] product;//乘法结果
reg        [5:0] shift_d1;
reg        [5:0] shift_d2;//第三级流水线才用，打两拍
reg        [31:0] mult_q;
reg signed [31:0] result_q;
reg valid_d1;
reg valid_d2;
reg valid_d3;
reg relu_enable_d3;
reg relu_enable_d2;
reg relu_enable_d1;
reg signed [63:0] scale;

//product多扩展一位，方便右移
wire signed [64:0] product_ext = {product[63], product};

//右移shift_d2位相当于除以2^shift_d2；1左移shift_d2-1位得到除数的一半。
//算术右移向负无穷取整：非负数加半个除数，负数加半个除数减1，实现最近整数舍入，半值远离0。
//shift_d2 == 0时不需要舍入，偏移取0；负数舍入不依赖后续是否启用ReLU。
wire signed [64:0] round_bias = (shift_d2 == 0) ? 65'sd0 : ((65'sd1 <<< (shift_d2 - 6'd1)) - (product[63] ? 65'sd1 : 65'sd0));

//地址生成
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        ptr      <= '0;
        addr_ptr <= '0;
    end
    else if (addr_init) begin
        ptr      <= '0;
        addr_ptr <= '0;
    end
    else if (acc_fc_wr_en) begin
        if (ptr == 2'd3) begin
            ptr      <= 2'd0;
            addr_ptr <= addr_ptr + 14'd1;
        end
        else begin
            ptr <= ptr + 2'd1;
        end
    end
end

//锁存
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        result_q <= 32'sd0;
        mult_q   <= 32'd0;
        shift_d1  <= 6'd0;
        valid_d1  <= 1'b0;
        relu_enable_d1 <= 'd0;
    end
    else begin
        valid_d1 <= result_valid_i;
        relu_enable_d1 <= relu_enable;
        if (result_valid_i) begin
            result_q <= result_i;
            mult_q   <= quant_mult_i;
            shift_d1 <= quant_shift_i;
        end
    end
end

//乘法
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        product <= 64'd0;
        shift_d2 <= 6'd0;
        valid_d2 <= 1'b0;
        relu_enable_d2 <= 'd0;
    end
    else begin
        valid_d2 <= valid_d1;
        relu_enable_d2 <= relu_enable_d1;
        if(valid_d1)begin
            product <= result_q * $signed({1'b0, mult_q});//乘法要显式转成正的有符号 33 位数
            shift_d2 <= shift_d1;
        end
    end
end

//右移
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        scale <= 64'd0;
        valid_d3 <= 1'b0;
        relu_enable_d3 <= 'd0;
    end
    else begin
        valid_d3 <= valid_d2;
        relu_enable_d3 <= relu_enable_d2;
        if(valid_d2)begin
            scale <= (product_ext + round_bias) >>> shift_d2;//加上对应符号的舍入偏移，再算术右移
        end
    end
end

//relu+截断
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        data_o <= 8'd0;
        data_valid_o <= 1'b0;
    end
    else begin
        data_valid_o <= valid_d3;
        if (valid_d3) begin
            if (relu_enable_d3 && scale <= 65'sd0)begin
                data_o <= 8'sd0;
            end
            else if (scale >= 65'sd127)begin
                data_o <= 8'sd127;
            end
            else if (scale < -64'sd128)begin
                data_o <= 8'sh80; // -128
            end
            else begin
                data_o <= scale[7:0];
            end
        end
    end
end

//根据字内偏移写入
always @(*) begin
    acc_fc_wr_data = 32'd0;
    case (ptr)
        2'd0: acc_fc_wr_data[7:0]   = data_o;
        2'd1: acc_fc_wr_data[15:8]  = data_o;
        2'd2: acc_fc_wr_data[23:16] = data_o;
        2'd3: acc_fc_wr_data[31:24] = data_o;
        default: acc_fc_wr_data = 32'd0;
    endcase
end

assign acc_fc_wr_en = rst_n && !addr_init && !result_done && data_valid_o && !group_start;
assign acc_fc_wr_addr = addr_ptr;
//一个字节一个字节写入，strb一次只拉高一个
assign acc_fc_wr_strb = acc_fc_wr_en ? (4'b0001 << ptr) : 4'b0000;

//int8计数器计数
always @(posedge clk or negedge rst_n)begin
    if(!rst_n || addr_init || group_start)begin
        result_cnt <= 'd0;
        result_done <= 'd0;
    end
    else if (acc_fc_wr_en && !result_done && (group_bias_count_i != 5'd0)) begin
        if(result_cnt == group_bias_count_i - 1'b1)begin
            result_done <= 1'b1;            
        end
        else begin
            result_done <= 1'b0;
            result_cnt <= result_cnt + 1'b1;
        end
    end
end

endmodule
