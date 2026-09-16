`include "define.sv"

module conv_reg(
    input clk,
    input rst_n,

    // MMIO router -> Conv：寄存器访问请求
    input conv_req_valid,
    output conv_req_ready,

    // Conv -> MMIO router：寄存器访问响应
    output conv_rsp_valid,
    input conv_rsp_ready,

    input [`DataBus] conv_wdata,
    input [`DataAddrBus] conv_addr,// CPU完整字节地址
    input [3:0] conv_wstrb,
    input conv_we,// 1：写寄存器；0：读寄存器

    output reg [`DataBus] conv_rdata,

    output conv_irq,//给cpu的中断，由计算完成信号和使能信号组合产生

    // 给int32到int8的量化模块
    output [5:0] conv_quant_shift,//右移缩放：对宽位数乘积右移的位数
    output [`DataBus] conv_quant_mult,//乘法缩放：32位无符号整数乘数

    // 给输入地址生成模块和im2col：遍历像素、判断换行和窗口有效
    // 同时给输出地址生成模块，用于推导卷积输出宽度和高度
    output [15:0] conv_input_width,//输入特征图宽度，对应INPUT_SHAPE[15:0]
    output [15:0] conv_input_height,//输入特征图高度，对应INPUT_SHAPE[31:16]

    // 给输入/权重地址生成模块和跨输入通道累加控制模块
    output [15:0] conv_input_channels,//输入通道总数，用于通道遍历及判断何时完成累加

    // 给权重/bias/输出地址生成模块和PE输出通道分组控制模块
    output [15:0] conv_output_channels,//输出通道总数，用于分组及判断当前组哪些PE行有效

    // 给bias地址生成模块；读出的bias数据再送给bias加法模块
    output [13:0] conv_bias_base,//BRAM字地址，每个int32 bias占一个32位字，地址加1

    // 给地址生成模块；寄存器内容为BRAM字节基地址
    output [`DataBus] conv_input_base,
    output [`DataBus] conv_weight_base,

    //卷积状态信号
    input done,
    input busy,
    input error,

    //根据ctrl寄存器输出脉冲信号
    output conv_start
);

localparam IDLE = 2'd0;//更新配置寄存器或锁存读数据
localparam REQ  = 2'd1;//等待请求握手
localparam RSP  = 2'd2;//等待响应握手
localparam DONE = 2'd3;//返回空闲

reg [1:0] state;
reg [1:0] next_state;
assign conv_req_ready = rst_n && (state == REQ);
assign conv_rsp_valid = rst_n && (state == RSP);

// Conv配置寄存器；计算任务的执行控制和硬件状态更新后续实现
// CONTROL：[0]start写1自清；[1]irq_enable；其余位保留
reg [`DataBus] conv_control_reg;

// STATUS：[0]busy由硬件更新；[1]done、[2]error锁存并由软件写1清除
// 其余位保留
wire [`DataBus] conv_status_reg;

// INPUT_SHAPE：[15:0]输入宽度；[31:16]输入高度
reg [`DataBus] conv_input_shape_reg;

// CHANNELS：[15:0]输入通道数；[31:16]输出通道数
reg [`DataBus] conv_channels_reg;

// BIAS_BASE：[13:0]bias在BRAM中的字地址；[31:14]保留
// CONV_BIAS_BASE_ADDR是CPU访问本寄存器的字节地址，两者单位不同
reg [`DataBus] conv_bias_base_reg;

//int32到int8的量化寄存器
// QUANT_MULT：32位无符号整数乘数
reg [`DataBus] conv_quant_mult_reg;

// QUANT_SHIFT：[5:0]右移位数；[31:6]保留
reg [`DataBus] conv_quant_shift_reg;

// 输入特征图和权重在BRAM中的字节基地址
reg [`DataBus] conv_input_base_reg;
reg [`DataBus] conv_weight_base_reg;

//状态锁存信号
reg done_q;
reg error_q;

// 将配置寄存器字段接到各模块；同一个配置输出可以连接多个模块。
// 任务执行期间配置应保持稳定；启动、valid和暂停控制由后续状态机实现。
assign conv_quant_shift = conv_quant_shift_reg[5:0];
assign conv_quant_mult = conv_quant_mult_reg;
assign conv_input_width = conv_input_shape_reg[15:0];
assign conv_input_height = conv_input_shape_reg[31:16];
assign conv_input_channels = conv_channels_reg[15:0];
assign conv_output_channels = conv_channels_reg[31:16];
assign conv_bias_base = conv_bias_base_reg[13:0];
assign conv_input_base = conv_input_base_reg;
assign conv_weight_base = conv_weight_base_reg;
assign conv_start = conv_control_reg[0];

assign conv_irq = conv_control_reg[1]
               && (conv_status_reg[1] || conv_status_reg[2]);

assign conv_status_reg = {
        29'd0,
        error_q,
        done_q,
        busy
};

// 第一段：状态寄存器
always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        state <= IDLE;
    else
        state <= next_state;
end

// 第二段：组合逻辑，决定下一状态
always @(*) begin
    next_state = state;
    case (state)
        IDLE: begin
            if (conv_req_valid)
                next_state = REQ;
        end
        REQ: begin
            if (conv_req_valid && conv_req_ready)
                next_state = RSP;
        end
        RSP: begin
            if (conv_rsp_valid && conv_rsp_ready)
                next_state = DONE;
        end
        DONE: next_state = IDLE;
        default: next_state = IDLE;
    endcase
end

// 第三段：时序逻辑，更新配置寄存器或按地址锁存读数据
// 按当前流程，在IDLE看到valid时读写，下一拍在REQ完成请求握手。
// router必须将valid、地址和写数据保持到请求握手完成。
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        conv_rdata <= 'd0;
        conv_control_reg <= 'd0;
        conv_input_shape_reg <= 'd0;
        conv_channels_reg <= 'd0;
        conv_bias_base_reg <= 'd0;
        conv_quant_mult_reg <= 'd0;
        conv_quant_shift_reg <= 'd0;
        conv_input_base_reg <= 'd0;
        conv_weight_base_reg <= 'd0;
        done_q <= 1'b0;
        error_q <= 1'b0;
    end
    else begin
        conv_control_reg[0] <= 1'b0;//start默认清零，写1时拉高一个周期
        if (conv_control_reg[0]) begin
            done_q  <= 1'b0;
            error_q <= 1'b0;
        end
        if(done)begin
            done_q <= done;
        end
        if(error)begin
            error_q <= error;
        end
        case (state)
            IDLE: begin
                if (conv_req_valid && conv_we) begin
                    case ({conv_addr[31:2], 2'b00})
                        `CONV_CONTROL_ADDR: begin
                            if (conv_wstrb[0])
                                conv_control_reg[1:0] <= conv_wdata[1:0];
                                // 启动时清零状态
                        end
                        `CONV_INPUT_SHAPE_ADDR: begin
                            if (conv_wstrb[0])
                                conv_input_shape_reg[7:0] <= conv_wdata[7:0];
                            if (conv_wstrb[1])
                                conv_input_shape_reg[15:8] <= conv_wdata[15:8];
                            if (conv_wstrb[2])
                                conv_input_shape_reg[23:16] <= conv_wdata[23:16];
                            if (conv_wstrb[3])
                                conv_input_shape_reg[31:24] <= conv_wdata[31:24];
                        end
                        `CONV_CHANNELS_ADDR: begin
                            if (conv_wstrb[0])
                                conv_channels_reg[7:0] <= conv_wdata[7:0];
                            if (conv_wstrb[1])
                                conv_channels_reg[15:8] <= conv_wdata[15:8];
                            if (conv_wstrb[2])
                                conv_channels_reg[23:16] <= conv_wdata[23:16];
                            if (conv_wstrb[3])
                                conv_channels_reg[31:24] <= conv_wdata[31:24];
                        end
                        `CONV_BIAS_BASE_ADDR: begin
                            if (conv_wstrb[0])
                                conv_bias_base_reg[7:0] <= conv_wdata[7:0];
                            if (conv_wstrb[1])
                                conv_bias_base_reg[13:8] <= conv_wdata[13:8];
                            conv_bias_base_reg[31:14] <= 'd0;//保留位保持0
                        end
                        `CONV_QUANT_MULT_ADDR: begin
                            if (conv_wstrb[0])
                                conv_quant_mult_reg[7:0] <= conv_wdata[7:0];
                            if (conv_wstrb[1])
                                conv_quant_mult_reg[15:8] <= conv_wdata[15:8];
                            if (conv_wstrb[2])
                                conv_quant_mult_reg[23:16] <= conv_wdata[23:16];
                            if (conv_wstrb[3])
                                conv_quant_mult_reg[31:24] <= conv_wdata[31:24];
                        end
                        `CONV_QUANT_SHIFT_ADDR: begin
                            if (conv_wstrb[0])
                                conv_quant_shift_reg[5:0] <= conv_wdata[5:0];
                            conv_quant_shift_reg[31:6] <= 'd0;//保留位保持0
                        end
                        `CONV_INPUT_BASE_ADDR: begin
                            if (conv_wstrb[0])
                                conv_input_base_reg[7:0] <= conv_wdata[7:0];
                            if (conv_wstrb[1])
                                conv_input_base_reg[15:8] <= conv_wdata[15:8];
                            if (conv_wstrb[2])
                                conv_input_base_reg[23:16] <= conv_wdata[23:16];
                            if (conv_wstrb[3])
                                conv_input_base_reg[31:24] <= conv_wdata[31:24];
                        end
                        `CONV_WEIGHT_BASE_ADDR: begin
                            if (conv_wstrb[0])
                                conv_weight_base_reg[7:0] <= conv_wdata[7:0];
                            if (conv_wstrb[1])
                                conv_weight_base_reg[15:8] <= conv_wdata[15:8];
                            if (conv_wstrb[2])
                                conv_weight_base_reg[23:16] <= conv_wdata[23:16];
                            if (conv_wstrb[3])
                                conv_weight_base_reg[31:24] <= conv_wdata[31:24];
                        end
                        default: begin end
                    endcase
                end

                //读逻辑
                else if(conv_req_valid && !conv_we)begin
                    // 读数据锁存后保持，直到后续读请求更新。
                    case ({conv_addr[31:2], 2'b00})
                        `CONV_CONTROL_ADDR:     conv_rdata <= conv_control_reg;
                        `CONV_STATUS_ADDR:      conv_rdata <= conv_status_reg;
                        `CONV_INPUT_SHAPE_ADDR: conv_rdata <= conv_input_shape_reg;
                        `CONV_CHANNELS_ADDR:    conv_rdata <= conv_channels_reg;
                        `CONV_BIAS_BASE_ADDR:   conv_rdata <= conv_bias_base_reg;
                        `CONV_QUANT_MULT_ADDR:  conv_rdata <= conv_quant_mult_reg;
                        `CONV_QUANT_SHIFT_ADDR: conv_rdata <= conv_quant_shift_reg;
                        `CONV_INPUT_BASE_ADDR:  conv_rdata <= conv_input_base_reg;
                        `CONV_WEIGHT_BASE_ADDR: conv_rdata <= conv_weight_base_reg;
                        default:                conv_rdata <= 'd0;
                    endcase
                end
            end
            default: begin end
        endcase
    end
end

endmodule
