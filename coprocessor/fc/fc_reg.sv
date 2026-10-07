`include "define.sv"

// 输出起始地址固定为共享BRAM字节地址0，不提供输出基地址寄存器。
module fc_reg(
    input clk,
    input rst_n,

    // MMIO router -> fc：寄存器访问请求
    input fc_req_valid,
    output fc_req_ready,

    // fc -> MMIO router：寄存器访问响应
    output fc_rsp_valid,
    input fc_rsp_ready,

    input [`DataBus] fc_wdata,
    input [`DataAddrBus] fc_addr,// CPU完整字节地址
    input [3:0] fc_wstrb,
    input fc_we,// 1：写寄存器；0：读寄存器

    output reg [`DataBus] fc_rdata,

    output fc_irq,//给cpu的中断，由计算完成信号和使能信号组合产生

    output [`DataBus] fc_in_features,//输入特征数量
    output [`DataBus] fc_out_features,//输出特征数量
    output reg [`DataBus] fc_input_base_addr,//输入特征图基地址
    output reg [`DataBus] fc_weight_base_addr,//输入权重基地址
    output reg [`DataBus] fc_bias_base_addr,//输入偏置基地址
    //量化数据
    output [`DataBus] fc_quant_mult,
    output [5:0] fc_quant_shift,

    input busy,
    input done,
    input error,

    output fc_start,//ctrl寄存器给的
    output fc_relu_enable

);

localparam IDLE = 2'd0;//更新配置寄存器或锁存读数据
localparam REQ  = 2'd1;//等待请求握手
localparam RSP  = 2'd2;//等待响应握手
localparam DONE = 2'd3;//返回空闲

reg [1:0] state;
reg [1:0] next_state;

//状态锁存信号
reg done_q;
reg error_q;

reg [`DataBus] fc_ctrl_reg;
wire [`DataBus] fc_status_reg;
reg [`DataBus] fc_in_features_reg;
reg [`DataBus] fc_out_features_reg;
reg [`DataBus] fc_input_base_addr_reg;
reg [`DataBus] fc_quant_mult_reg;
reg [`DataBus] fc_quant_shift_reg;

assign fc_in_features     = fc_in_features_reg;
assign fc_out_features    = fc_out_features_reg;
assign fc_input_base_addr = fc_input_base_addr_reg;

assign fc_quant_mult      = fc_quant_mult_reg;
assign fc_quant_shift     = fc_quant_shift_reg[5:0];

assign fc_start           = fc_ctrl_reg[0];
assign fc_relu_enable     = fc_ctrl_reg[2];

assign fc_req_ready = rst_n && (state == REQ);
assign fc_rsp_valid = rst_n && (state == RSP);

//中断信号赋值
assign fc_status_reg = {
    29'd0,
    error_q,   // bit 2：错误状态，锁存
    done_q,    // bit 1：完成状态，锁存
    busy       // bit 0：当前是否忙
};

assign fc_irq = fc_ctrl_reg[1] && (done_q || error_q);

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
            if (fc_req_valid)
                next_state = REQ;
        end
        REQ: begin
            if (fc_req_valid && fc_req_ready)
                next_state = RSP;
        end
        RSP: begin
            if (fc_rsp_valid && fc_rsp_ready)
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
        fc_rdata <= 'd0;
        fc_ctrl_reg <= 'd0;
        fc_in_features_reg <= 'd0;
        fc_out_features_reg <= 'd0;
        fc_input_base_addr_reg <= 'd0;
        fc_weight_base_addr <= 'd0;
        fc_bias_base_addr <= 'd0;
        fc_quant_mult_reg <= 'd0;
        fc_quant_shift_reg <= 'd0;
        done_q <= 1'b0;
        error_q <= 1'b0;
    end
    else begin
        fc_ctrl_reg[0] <= 1'b0;//start默认清零，写1时拉高一个周期
        if (fc_ctrl_reg[0]) begin
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
                if (fc_req_valid && fc_we) begin
                    case ({fc_addr[31:2], 2'b00})
                        `FC_STATUS_ADDR: begin
                            // 低字节写1清除状态，同拍新事件优先保留。
                            if (fc_wstrb[0]) begin
                                if (fc_wdata[1] && !done)
                                    done_q <= 1'b0;
                                if (fc_wdata[2] && !error)
                                    error_q <= 1'b0;
                            end
                        end
                        `FC_CONTROL_ADDR: begin
                            // [0]start、[1]irq_enable、[2]relu_enable。
                            if (fc_wstrb[0])
                                fc_ctrl_reg[2:0] <= fc_wdata[2:0];
                        end
                        `FC_IN_FEATURES_ADDR: begin
                            if (fc_wstrb[0])
                                fc_in_features_reg[7:0] <= fc_wdata[7:0];
                            if (fc_wstrb[1])
                                fc_in_features_reg[15:8] <= fc_wdata[15:8];
                            if (fc_wstrb[2])
                                fc_in_features_reg[23:16] <= fc_wdata[23:16];
                            if (fc_wstrb[3])
                                fc_in_features_reg[31:24] <= fc_wdata[31:24];
                        end
                        `FC_OUT_FEATURES_ADDR: begin
                            if (fc_wstrb[0])
                                fc_out_features_reg[7:0] <= fc_wdata[7:0];
                            if (fc_wstrb[1])
                                fc_out_features_reg[15:8] <= fc_wdata[15:8];
                            if (fc_wstrb[2])
                                fc_out_features_reg[23:16] <= fc_wdata[23:16];
                            if (fc_wstrb[3])
                                fc_out_features_reg[31:24] <= fc_wdata[31:24];
                        end
                        `FC_INPUT_BASE_ADDR: begin
                            if (fc_wstrb[0])
                                fc_input_base_addr_reg[7:0] <= fc_wdata[7:0];
                            if (fc_wstrb[1])
                                fc_input_base_addr_reg[15:8] <= fc_wdata[15:8];
                            if (fc_wstrb[2])
                                fc_input_base_addr_reg[23:16] <= fc_wdata[23:16];
                            if (fc_wstrb[3])
                                fc_input_base_addr_reg[31:24] <= fc_wdata[31:24];
                        end
                        `FC_WEIGHT_BASE_ADDR: begin
                            if (fc_wstrb[0])
                                fc_weight_base_addr[7:0] <= fc_wdata[7:0];
                            if (fc_wstrb[1])
                                fc_weight_base_addr[15:8] <= fc_wdata[15:8];
                            if (fc_wstrb[2])
                                fc_weight_base_addr[23:16] <= fc_wdata[23:16];
                            if (fc_wstrb[3])
                                fc_weight_base_addr[31:24] <= fc_wdata[31:24];
                        end
                        `FC_BIAS_BASE_ADDR: begin
                            if (fc_wstrb[0])
                                fc_bias_base_addr[7:0] <= fc_wdata[7:0];
                            if (fc_wstrb[1])
                                fc_bias_base_addr[15:8] <= fc_wdata[15:8];
                            if (fc_wstrb[2])
                                fc_bias_base_addr[23:16] <= fc_wdata[23:16];
                            if (fc_wstrb[3])
                                fc_bias_base_addr[31:24] <= fc_wdata[31:24];
                        end
                        `FC_QUANT_MULT_ADDR: begin
                            if (fc_wstrb[0])
                                fc_quant_mult_reg[7:0] <= fc_wdata[7:0];
                            if (fc_wstrb[1])
                                fc_quant_mult_reg[15:8] <= fc_wdata[15:8];
                            if (fc_wstrb[2])
                                fc_quant_mult_reg[23:16] <= fc_wdata[23:16];
                            if (fc_wstrb[3])
                                fc_quant_mult_reg[31:24] <= fc_wdata[31:24];
                        end
                        `FC_QUANT_SHIFT_ADDR: begin
                            if (fc_wstrb[0])
                                fc_quant_shift_reg[5:0] <= fc_wdata[5:0];
                            fc_quant_shift_reg[31:6] <= 'd0;//保留位保持0
                        end
                        default: begin end
                    endcase
                end
                // 读数据锁存后保持，直到后续读请求更新。
                else if (fc_req_valid && !fc_we) begin
                    case ({fc_addr[31:2], 2'b00})
                        `FC_CONTROL_ADDR:       fc_rdata <= fc_ctrl_reg;
                        `FC_STATUS_ADDR:        fc_rdata <= fc_status_reg;
                        `FC_IN_FEATURES_ADDR:   fc_rdata <= fc_in_features_reg;
                        `FC_OUT_FEATURES_ADDR:  fc_rdata <= fc_out_features_reg;
                        `FC_INPUT_BASE_ADDR:    fc_rdata <= fc_input_base_addr_reg;
                        `FC_WEIGHT_BASE_ADDR:   fc_rdata <= fc_weight_base_addr;
                        `FC_BIAS_BASE_ADDR:     fc_rdata <= fc_bias_base_addr;
                        `FC_QUANT_MULT_ADDR:    fc_rdata <= fc_quant_mult_reg;
                        `FC_QUANT_SHIFT_ADDR:   fc_rdata <= fc_quant_shift_reg;
                        default: fc_rdata <= 'd0;
                    endcase
                end
            end
            default: begin end
        endcase
    end
end

endmodule
