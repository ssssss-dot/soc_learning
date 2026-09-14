`include "define.sv"

//输出地址从0开始，每次覆盖
module conv_ctrl(
    input clk,
    input rst_n,

    // 给int32到int8的量化模块
    input [5:0] current_quant_shift_i,//右移缩放：对宽位数乘积右移的位数
    input [`DataBus] current_quant_mult_i,//乘法缩放：32位无符号整数乘数

    // 给输入地址生成模块和im2col：遍历像素、判断换行和窗口有效
    // 同时给输出地址生成模块，用于推导卷积输出宽度和高度
    input [15:0] current_input_width_i,//输入特征图宽度，对应INPUT_SHAPE[15:0]
    input [15:0] current_input_height_i,//输入特征图高度，对应INPUT_SHAPE[31:16]

    // 给输入/权重地址生成模块和跨输入通道累加控制模块
    input [15:0] current_input_channels_i,//输入通道总数，用于通道遍历及判断何时完成累加

    // 给权重/bias/输出地址生成模块和PE输出通道分组控制模块
    input [15:0] current_output_channels_i,//输出通道总数，用于分组及判断当前组哪些PE行有效

    // 给bias地址生成模块；读出的bias数据再送给bias加法模块
    input [13:0] current_bias_base_i,//BRAM字地址，每个int32 bias占一个32位字，地址加1

    // 输入特征图和权重在BRAM中的字节基地址
    input [`DataBus] current_input_base_i,
    input [`DataBus] current_weight_base_i,

    // 直接输出给int32到int8量化模块
    output [5:0] current_quant_shift_o,
    output [`DataBus] current_quant_mult_o,

    // 直接输出给输入地址生成、im2col和输出地址生成模块
    output [15:0] current_input_width_o,
    output [15:0] current_input_height_o,

    // 直接输出给输入/权重地址生成和跨输入通道累加控制模块
    output [15:0] current_input_channels_o,

    // 直接输出给权重/bias/输出地址生成和PE输出通道分组控制模块
    output [15:0] current_output_channels_o,

    // 直接输出给bias地址生成模块
    output reg [13:0] current_bias_base_o,
    output reg [`DataBus] current_bias_end_o,

    // 直接输出给输入和权重地址生成模块
    output reg [`DataBus] current_input_base_o,
    output reg [`DataBus] current_weight_base_o,
    output reg [`DataBus] current_input_end_o,
    output reg [`DataBus] current_weight_end_o,

    //卷积状态
    output done,
    output busy,
    output error,

    input start,//启动脉冲

    //给pearray的信号
    output [4:0] weight_target,
    output weight_loading_en,
    output valid_weight
);

assign current_quant_shift_o = current_quant_shift_i;
assign current_quant_mult_o = current_quant_mult_i;
assign current_input_width_o = current_input_width_i;
assign current_input_height_o = current_input_height_i;
assign current_input_channels_o = current_input_channels_i;
assign current_output_channels_o = current_output_channels_i;
// 三个end均表示对应数据最后一个地址的下一个地址，即有效范围为[base, end)。
// 输入和权重按int8计算，地址单位为字节；bias地址单位为32位字。
wire [`DataBus] input_size_calc;
wire [`DataBus] weight_size_calc;
wire [`DataBus] input_end_calc;
wire [`DataBus] weight_end_calc;
wire [`DataBus] bias_end_calc;

assign input_size_calc =
       {16'd0, current_input_width_i}
     * {16'd0, current_input_height_i}
     * {16'd0, current_input_channels_i};

assign weight_size_calc =
       {16'd0, current_input_channels_i}
     * {16'd0, current_output_channels_i}
     * 32'd25;

assign input_end_calc = current_input_base_i + input_size_calc;
assign weight_end_calc = current_weight_base_i + weight_size_calc;
assign bias_end_calc =
       {18'd0, current_bias_base_i}
     + {16'd0, current_output_channels_i};

// start到来的时钟沿锁存本次卷积的结束地址，之后保持到下一次start。
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        current_input_base_o <= 'd0;
        current_weight_base_o <= 'd0;
        current_bias_base_o <= 'd0;
        current_input_end_o <= 'd0;
        current_weight_end_o <= 'd0;
        current_bias_end_o <= 'd0;
    end
    else if (start) begin
        current_input_base_o <= current_input_base_i;
        current_weight_base_o <= current_weight_base_i;
        current_bias_base_o <= current_bias_base_i;
        current_input_end_o <= input_end_calc;
        current_weight_end_o <= weight_end_calc;
        current_bias_end_o <= bias_end_calc;
    end
end


endmodule
