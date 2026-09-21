`include "define.sv"

module addr_gen(
    input clk,
    input rst_n,

    input addr_init,

    //控制信号
    input  weight_addr_begin,
    input  input_addr_begin,
    input  bias_addr_begin, 

    input [1:0] rd_sel,
    input rd_req,

    //每次的输出默认起始地址为0
    input [13:0] bias_base_addr,//特征图输入地址
    input [`DataBus] bias_end_addr,
    input [`DataBus] weight_base_addr,//权重输入地址
    input [`DataBus] weight_end_addr,//偏置输入地址
    input [`DataBus] input_base_addr,
    input [`DataBus] input_end_addr,

    //卷积层尺寸配置
    input [15:0] input_width,
    input [15:0] input_height,
    input [15:0] input_channels,
    input [15:0] output_channels,

    input [15:0] channel_cnt,

    output  reg        bram_rd_en,
    output  reg [13:0]  bram_rd_addr,

    //当前通道对应的数据地址读取完成
    output reg input_done,
    output reg weight_done,
    output reg bias_done
);

//三个计数器，一次读bram加一次
reg [`DataBus] bias_cnt;
reg [`DataBus] weight_cnt;
reg [`DataBus] input_cnt;

reg [`DataBus] input_addr;
reg [`DataBus] weight_addr;
reg [13:0] bias_addr;

localparam RD_INPUT = 2'd0;
localparam RD_WEIGHT = 2'd1;
localparam RD_BIAS = 2'd2;

localparam integer KERNEL_ELEMENTS = 25;
localparam integer PE_ROWS         = 16;
localparam integer WEIGHT_BYTES    = 1;

localparam [`DataBus] WEIGHT_BYTES_PER_INPUT_CHANNEL =
    KERNEL_ELEMENTS * PE_ROWS * WEIGHT_BYTES;

//权重按通道数，按每个通道不同的地址进行读取
wire [`DataBus] current_weight_base;
wire [`DataBus] current_weight_end;
//按照通道数生成每次权重通道计数的起始地址
assign current_weight_base =
    weight_base_addr +
    ({16'd0, channel_cnt} * WEIGHT_BYTES_PER_INPUT_CHANNEL);
assign current_weight_end =
    current_weight_base + WEIGHT_BYTES_PER_INPUT_CHANNEL;

//输入特征图按通道数，按每个通道不同的地址进行读取
wire [`DataBus] input_bytes_per_channel;
wire [`DataBus] current_input_base;
wire [`DataBus] current_input_end;
assign input_bytes_per_channel =
    {16'd0, input_width} * {16'd0, input_height};
assign current_input_base =
    input_base_addr +
    ({16'd0, channel_cnt} * input_bytes_per_channel);
assign current_input_end =
    current_input_base + input_bytes_per_channel;

//bias地址生成逻辑
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        bias_addr <= '0;
        bias_cnt  <= '0;
        bias_done <= 1'b0;
    end
    else if (addr_init || bias_addr_begin) begin
        bias_addr <= bias_base_addr;
        bias_cnt  <= '0;
        bias_done <= ({18'd0, bias_base_addr} >= bias_end_addr);
    end
    else if (bram_rd_en && (rd_sel == RD_BIAS) && !bias_done) begin
        bias_cnt <= bias_cnt + 32'd1;

        if (({18'd0, bias_addr} + 32'd1) >= bias_end_addr) begin
            bias_done <= 1'b1;
        end
        else begin
            bias_addr <= bias_addr + 14'd1;
        end
    end
end

//weight地址生成逻辑
//一个通道5*5*16（conv1自动补0），按照channel_cnt改基地址
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        weight_addr <= '0;
        weight_cnt  <= '0;
        weight_done <= 1'b0;
    end
    else if (addr_init) begin
        weight_addr <= weight_base_addr;
        weight_cnt  <= '0;
        weight_done <= 1'b0;
    end
    else if (weight_addr_begin) begin
        // 每次进入READ_WEIGHT，根据当前输入通道重新定位
        weight_addr <= current_weight_base;
        weight_cnt  <= '0;

        // 防止channel_cnt越界
        weight_done <= (current_weight_base >= weight_end_addr);
    end
    else if (bram_rd_en &&
             (rd_sel == RD_WEIGHT) &&
             !weight_done) begin

        // 记录已发出的32位BRAM读取次数
        weight_cnt <= weight_cnt + 32'd1;

        // current_weight_end是当前输入通道的结束地址
        if ((weight_addr + 32'd4) >= current_weight_end) begin
            // 当前通道最后一个权重读取请求已经发出
            weight_done <= 1'b1;
        end
        else begin
            weight_addr <= weight_addr + 32'd4;
        end
    end
end

//input地址生成逻辑
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        input_addr <= '0;
        input_cnt  <= '0;
        input_done <= 1'b0;
    end
    else if (addr_init || input_addr_begin) begin
        input_addr <= current_input_base;
        input_cnt  <= '0;
        input_done <= (current_input_base >= current_input_end);
    end
    else if (bram_rd_en && (rd_sel == RD_INPUT) && !input_done) begin
        // 当前input_addr对应的读请求已经发出
        input_cnt <= input_cnt + 32'd1;

        // 当前是不是最后一个32位字
        if ((input_addr + 32'd4) >= current_input_end) begin
            input_done <= 1'b1;
        end
        else begin
            input_addr <= input_addr + 32'd4;
        end
    end
end

//根据sel给bram地址和使能
always @(*) begin
    bram_rd_en   = 1'b0;
    bram_rd_addr = 14'd0;

    case (rd_sel)
        RD_INPUT: begin
            bram_rd_en   = rd_req && !input_done;
            bram_rd_addr = input_addr[15:2];
        end

        RD_WEIGHT: begin
            bram_rd_en   = rd_req && !weight_done;
            bram_rd_addr = weight_addr[15:2];
        end

        RD_BIAS: begin
            bram_rd_en   = rd_req && !bias_done;
            bram_rd_addr = bias_addr;
        end
    endcase
end


endmodule
