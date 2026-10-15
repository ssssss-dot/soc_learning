`include "define.sv"

//四级流水线做量化,锁存，乘法，右移，relu
module int32_int8 (
    input  wire               clk,
    input  wire               rst_n,

    // accumulation 已加 bias 的串行结果
    input  wire signed [31:0] result_i,
    input  wire               result_valid_i,

    // 每层的量化参数，来自 conv_reg / conv_ctrl
    input  wire        [31:0] quant_mult_i,
    input  wire        [5:0]  quant_shift_i,

    // 送往 output_cache
    output reg  signed [7:0]  data_o,
    output reg                data_valid_o
);

reg signed [63:0] product;//乘法结果
reg        [5:0] shift_d1;
reg        [5:0] shift_d2;//第三级流水线才用，打两拍
reg        [31:0] mult_q;
reg signed [31:0] result_q;
reg valid_d1;
reg valid_d2;
reg valid_d3;
reg signed [63:0] scale;

//product多扩展一位，方便右移
wire signed [64:0] product_ext = {product[63], product};

//65'sd1 <<< (shift_d2 - 6'd1)相当于是除数左移shift-1，等价于除数除以2
//product[63] == 1：64 位有符号乘积是负数。第四级会用 ReLU 把它变成 0，因此这里跳过舍入
//shift_d2 == 0：不右移、也就没有被丢掉的小数位，无需舍入；同时避免计算 shift_d2 - 1
wire signed [64:0] round_bias = (product[63] || shift_d2 == 0) ? 65'sd0 : (65'sd1 <<< (shift_d2 - 6'd1));

//锁存
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        result_q <= 32'sd0;
        mult_q   <= 32'd0;
        shift_d1  <= 6'd0;
        valid_d1  <= 1'b0;
    end
    else begin
        valid_d1 <= result_valid_i;
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
    end
    else begin
        valid_d2 <= valid_d1;
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
    end
    else begin
        valid_d3 <= valid_d2;
        if(valid_d2)begin
            scale <= (product_ext + round_bias) >>> shift_d2;//有符号数右移用>>>，同时加上除数的一半，做舍入
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
            if (scale <= 65'sd0)begin
                data_o <= 8'sd0;
            end
            else if (scale >= 65'sd127)begin
                data_o <= 8'sd127;
            end
            else begin
                data_o <= $signed(scale[7:0]);
            end
        end
    end
end

endmodule
