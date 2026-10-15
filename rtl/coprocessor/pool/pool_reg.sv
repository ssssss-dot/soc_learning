`include "define.sv"

module pool_reg(
    input clk,
    input rst_n,

    // MMIO router -> pool：寄存器访问请求
    input pool_req_valid,
    output pool_req_ready,

    // fc -> MMIO router：寄存器访问响应
    output pool_rsp_valid,
    input pool_rsp_ready,

    input [`DataBus] pool_wdata,
    input [`DataAddrBus] pool_addr,// CPU完整字节地址
    input [3:0] pool_wstrb,
    input pool_we,// 1：写寄存器；0：读寄存器

    output reg [`DataBus] pool_rdata,

    output pool_irq,//给cpu的中断，由计算完成信号和使能信号组合产生

    output [15:0] pool_row,//图片宽
    output [15:0] pool_col,//图片高
    output [`DataBus] channels,//通道数

    input busy,
    input done,
    input error,

    output pool_start//ctrl寄存器给的
);

reg [`DataBus] pool_size_reg;
reg [`DataBus] pool_channels_reg;
reg [`DataBus] pool_ctrl_reg;
wire [`DataBus] pool_status_reg;

reg done_q;
reg error_q;

localparam IDLE = 2'd0;//更新配置寄存器或锁存读数据
localparam REQ  = 2'd1;//等待请求握手
localparam RSP  = 2'd2;//等待响应握手
localparam DONE = 2'd3;//返回空闲

reg [1:0] state;
reg [1:0] next_state;

assign pool_req_ready = rst_n && (state == REQ);
assign pool_rsp_valid = rst_n && (state == RSP);
assign pool_row = pool_size_reg[15:0];
assign pool_col = pool_size_reg[31:16];
assign channels = pool_channels_reg;
assign pool_start = rst_n && pool_ctrl_reg[0];
assign pool_irq = pool_ctrl_reg[1] && (done_q || error_q);

assign pool_status_reg = {
    29'd0,
    error_q,   // bit 2：错误状态，锁存
    done_q,    // bit 1：完成状态，锁存
    busy       // bit 0：当前是否忙
};

always @(posedge clk or negedge rst_n)begin 
    if(!rst_n)begin
        state <= IDLE;
    end
    else begin
        state <= next_state;
    end
end

always @(*)begin
    next_state = state;
    case(state) 
        IDLE:begin
            if (pool_req_valid) begin
                next_state = REQ;
            end
        end
        REQ:begin
            if (pool_req_valid && pool_req_ready) begin
                next_state = RSP;
            end
        end
        RSP:begin
            if (pool_rsp_valid && pool_rsp_ready) begin
                next_state = DONE;
            end
        end
        DONE:begin
            next_state = IDLE;
        end
        default:begin
            next_state = IDLE;
        end
    endcase
end

always @(posedge clk or negedge rst_n)begin
    if(!rst_n)begin
        pool_rdata <= 'd0;
        pool_size_reg <= 'd0;
        pool_channels_reg <= 'd0;
        pool_ctrl_reg <= 'd0;
        done_q <= 'd0;
        error_q <= 'd0;
    end
    else begin
        pool_ctrl_reg[0] <= 1'b0;//start默认清零，写1时拉高一个周期
        if (pool_ctrl_reg[0]) begin
            done_q  <= 1'b0;
            error_q <= 1'b0;
        end
        if(done)begin
            done_q <= done;
        end
        if(error)begin
            error_q <= error;
        end
        if(state == IDLE) begin 
            if(pool_req_valid && pool_we && !busy)begin
                case ({pool_addr[31:2], 2'b00})
                    `POOL_CONTROL_ADDR: begin
                        // bit0：启动脉冲；bit1：中断使能。
                        if (pool_wstrb[0]) begin
                            pool_ctrl_reg[0] <= pool_wdata[0] && !busy;
                            pool_ctrl_reg[1] <= pool_wdata[1];
                        end
                    end

                    `POOL_STATUS_ADDR: begin
                        // 写1清除done/error，同拍新事件优先保留。
                        if (pool_wstrb[0]) begin
                            if (pool_wdata[1] && !done)
                                done_q <= 1'b0;
                            if (pool_wdata[2] && !error)
                                error_q <= 1'b0;
                        end
                    end

                    `POOL_SIZE_ADDR: begin
                        // [15:0]输入宽度，[31:16]输入高度。
                        if (pool_wstrb[0])
                            pool_size_reg[7:0] <= pool_wdata[7:0];
                        if (pool_wstrb[1])
                            pool_size_reg[15:8] <= pool_wdata[15:8];
                        if (pool_wstrb[2])
                            pool_size_reg[23:16] <= pool_wdata[23:16];
                        if (pool_wstrb[3])
                            pool_size_reg[31:24] <= pool_wdata[31:24];
                    end

                    `POOL_CHANNELS_ADDR: begin
                        if (pool_wstrb[0])
                            pool_channels_reg[7:0] <= pool_wdata[7:0];
                        if (pool_wstrb[1])
                            pool_channels_reg[15:8] <= pool_wdata[15:8];
                        if (pool_wstrb[2])
                            pool_channels_reg[23:16] <= pool_wdata[23:16];
                        if (pool_wstrb[3])
                            pool_channels_reg[31:24] <= pool_wdata[31:24];
                    end

                    default: begin end
                endcase
            end
            if (pool_req_valid && !pool_we) begin
                // 锁存读数据，在响应握手完成前保持不变。
                case ({pool_addr[31:2], 2'b00})
                    `POOL_CONTROL_ADDR:  pool_rdata <= pool_ctrl_reg;
                    `POOL_STATUS_ADDR:   pool_rdata <= pool_status_reg;
                    `POOL_SIZE_ADDR:     pool_rdata <= pool_size_reg;
                    `POOL_CHANNELS_ADDR: pool_rdata <= pool_channels_reg;
                    default:             pool_rdata <= 32'd0;
                endcase
            end
        end
    end
end
endmodule
