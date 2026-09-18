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
    output reg [`DataBus] current_output_end_o,//量化后INT8输出的结束字节地址，起始地址固定为0

    //每个地址读取完成信号（到end了）
    input weight_done_i,
    input input_done_i,
    input bias_done_i,
    input channel_done_i,//一个通道的特征图卷积完成
    input output_done_i,
    input weight_vec_valid_i,//表示一列的16个权重拼接好了，可以送到pe阵列里面

    //卷积状态
    output done,
    output busy,
    output error,

    //启动脉冲
    input start,

    //给pearray的信号
    output reg [4:0] weight_target,//当前权重组的目标PE列编号：0～24
    output reg weight_loading_en,
    output reg valid_weight,

    //缓存给ctrl的req信号
    input input_req,
    input weight_req,
    input bias_req,

    //给addr_gen的信号
    output reg rd_req,
    output reg [1:0] rd_sel,
    output reg addr_init,//地址初始化脉冲

    output reg [2:0] channel_cnt,//记录当前是第几个通道在计算

);

//状态编码
localparam IDLE        = 3'd0;
localparam ADDR_INIT   = 3'd1;//给addr_gen一个初始化的脉冲信号
localparam READ_WEIGHT = 3'd2;//把权重给pe
localparam READ_INPUT  = 3'd3;//把输入给im2col
localparam WAIT_CHANNEL = 3'd6;//pe_array到最后一个数据写完的过程
localparam READ_BIAS   = 3'd4;//把bias给bias缓存
localparam WAIT_OUTPUT  = 3'd7;//写回完成，可以拉高中断
localparam FINISH      = 3'd5;

reg [2:0] state;
reg [2:0] next_state;
wire last_channel;//标志最后一个通道的卷积
assign last_channel = (channel_cnt + 16'd1 == current_input_channels_i);

//ctrl 每次进入 READ_WEIGHT 时产生的一拍脉冲，用于清零列计数器和 weight_all_sent
wire weight_load_start;
assign weight_load_start = (state != READ_WEIGHT) && (next_state == READ_WEIGHT);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        state <= IDLE;
    else
        state <= next_state;
end

always @(*)begin
    next_state = state;
    case(state)
        IDLE:begin
            if(start)begin
                next_state = ADDR_INIT;
            end
        end
        ADDR_INIT:begin
            next_state = READ_WEIGHT;
        end
        READ_WEIGHT:begin
            if(weight_done_i)begin
                next_state = READ_INPUT;
            end
        end
        READ_INPUT:begin
            if(input_done_i)begin
                next_state = WAIT_CHANNEL;
            end
        end
        WAIT_CHANNEL: begin
            if (channel_done_i) begin//pearray计算完毕且部分和写入完成
                if (last_channel)
                    next_state = READ_BIAS;
                else
                    next_state = READ_WEIGHT;
            end
        end
        READ_BIAS:begin
            if(bias_done_i)begin
                next_state = WAIT_OUTPUT;
            end
        end
        WAIT_OUTPUT:begin
            if(output_done_i)begin
                next_state = FINISH;
            end
        end
        FINISH:begin
            next_state = IDLE;
        end
    endcase
end

always @(posedge clk or negedge rst_n)begin
    if(!rst_n)begin
        busy <= 'd0;
        done <= 'd0;
        error <= 'd0;
        rd_req <= 'd0;
        rd_sel <= 'd0;
        addr_init <= 'd0;
        weight_loding_en <= 'd0;

    end
    else begin
        case(state)
        endcase
    end
end

//数据源编码
localparam RD_INPUT = 2'd0;
localparam RD_WEIGHT = 2'd1;
localparam RD_BIAS = 2'd2;

assign current_quant_shift_o = current_quant_shift_i;
assign current_quant_mult_o = current_quant_mult_i;
assign current_input_width_o = current_input_width_i;
assign current_input_height_o = current_input_height_i;
assign current_input_channels_o = current_input_channels_i;
assign current_output_channels_o = current_output_channels_i;

// 各end均表示最后一个有效地址的下一个地址，即有效范围为[base, end)。
// 输入、权重和量化后的卷积输出按INT8计算，地址单位为字节；bias地址单位为32位字。
wire [`DataBus] input_size_calc;
wire [`DataBus] weight_size_calc;
wire [`DataBus] input_end_calc;
wire [`DataBus] weight_end_calc;
wire [`DataBus] bias_end_calc;
wire [15:0] output_width_calc;
wire [15:0] output_height_calc;
wire [`DataBus] output_end_calc;

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

// 每次start传入的是本层卷积的输入尺寸：Conv1为32x32，Conv2为池化后的14x14。
// 固定5x5、stride=1、padding=0，故卷积输出宽高均为本层输入减4。
assign output_width_calc = (current_input_width_i >= 16'd5)
                         ? current_input_width_i - 16'd4 : 16'd0;
assign output_height_calc = (current_input_height_i >= 16'd5)
                          ? current_input_height_i - 16'd4 : 16'd0;
// 输出基地址固定为0；每个量化后的输出像素占1字节。
assign output_end_calc =
       {16'd0, output_width_calc}
     * {16'd0, output_height_calc}
     * {16'd0, current_output_channels_i};

//start到来的时钟沿锁存本次卷积的结束地址，之后保持到下一次start。
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        current_input_base_o <= 'd0;
        current_weight_base_o <= 'd0;
        current_bias_base_o <= 'd0;
        current_input_end_o <= 'd0;
        current_weight_end_o <= 'd0;
        current_bias_end_o <= 'd0;
        current_output_end_o <= 'd0;
    end
    else if (start) begin
        current_input_base_o <= current_input_base_i;
        current_weight_base_o <= current_weight_base_i;
        current_bias_base_o <= current_bias_base_i;
        current_input_end_o <= input_end_calc;
        current_weight_end_o <= weight_end_calc;
        current_bias_end_o <= bias_end_calc;
        current_output_end_o <= output_end_calc;
    end
end


endmodule
