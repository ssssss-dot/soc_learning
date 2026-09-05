`include "define.sv"

//dma访问ddr要
module dma_ctrl(
    input clk,
    input rst_n,

    //握手信号
    output dma_req_ready,
    input dma_req_valid,
    output dma_rsp_valid,
    input dma_rsp_ready,

    //dmawe
    input [`DataBus] dma_wdata,
    input [`DataAddrBus] dma_addr,
    input [3:0] dma_wstrb,
    input dma_we,  

    //读status
    //status[0] : busy        DMA正在工作
    //status[1] : done        DMA本次传输完成
    //status[2] : error       DMA传输出错
    //status[3] : irq_pending DMA中断挂起
    //status[31:4] : 保留
    output  [`DataBus] dma_rdata,

    //dma中断产生信号
    output dma_irq,

    //读 descriptor 接口
    output [`DataBus] rd_desc_src_addr,
    output [15:0]     rd_desc_len,
    output            rd_desc_valid,
    input             rd_desc_ready,
    input             rd_desc_sts_valid,//dma读任务完成
    input  [3:0]      rd_desc_sts_error,

    //写 descriptor 接口
    output [`DataBus] wr_desc_dst_addr,
    output [15:0]     wr_desc_len,
    output            wr_desc_valid,
    input             wr_desc_ready,
    input             wr_desc_sts_valid,//dma写任务完成
    input  [3:0]      wr_desc_sts_error
);

localparam IDLE_M = 2'd0;//锁存，等握手
localparam REQ_M  = 2'd1;//握手
localparam WAIT_M = 2'd2;//返回rspvalid（读）
localparam DONE_M = 2'd3;

localparam IDLE_D = 2'd0;//等 CPU 写 DMA_CONTROL_ADDR 产生 start_pulse
localparam REQ_D  = 2'd1;//把寄存器里面的给dma并拉高valid，等待握手
localparam BACK_D = 2'd2;//看写端的stsvalid（说明写完ddr，可以发起中断）

reg [1:0] state_m;
reg [1:0] next_state_m;

reg [1:0] state_d;
reg [1:0] next_state_d;

//src和dst都要是ddr的物理地址
reg [`DataBus] dma_src;//从哪里开始读ddr
reg [`DataBus] dma_dst;//从哪里开始写ddr
reg [`DataBus] dma_len_rd;
reg [`DataBus] dma_len_wr;
//CTRL[0] start
//CTRL[1] irq_enable
reg [`DataBus] dma_ctrl;
wire [`DataBus] dma_status;
reg [`DataBus] irq_status;
reg [`DataBus] irq_enable;

//中断原因的掩码
wire [`DataBus] irq_set_mask;
assign irq_set_mask = {
    28'b0,
    wr_desc_sts_valid &&
        (wr_desc_sts_error != 4'b0000), // bit3 写错误

    rd_desc_sts_valid &&
        (rd_desc_sts_error != 4'b0000), // bit2 读错误

    wr_desc_sts_valid,                  // bit1 写完成
    rd_desc_sts_valid                   // bit0 读完成
};

reg busy;
reg done;
reg error;
wire irq_pending;
reg rd_error_seen;//是用来记住本次DMA任务的读端曾经发生过错误的内部标志
reg [`DataBus] dma_rdata_q;

//要两个都配置好才能进下一个状态，但不一定同一周期完成，所以加done信号
reg rd_desc_done;//记录dmactrl读部分的配置传输完毕
reg wr_desc_done;//记录dmactrl写部分的配置传输完毕

assign dma_rdata = dma_rdata_q;
assign dma_status = {28'b0, irq_pending, error, done, busy};
assign dma_irq =
    dma_ctrl[1] &&
    (|(irq_status & irq_enable));//考虑中断是否使能，dma_ctrl[1]是全局的中断使能
assign irq_pending = |irq_status;//每一位取或，只要有一个中断原因挂起就说明有中断

//读写配置有效信号，完成信号记录好了就拉低valid，防止重复赋值
assign rd_desc_valid = (state_d == REQ_D) && !rd_desc_done;
assign wr_desc_valid = (state_d == REQ_D) && !wr_desc_done;

//在valid期间，相关配置接口要一直拉高
assign rd_desc_src_addr = dma_src;
assign wr_desc_dst_addr = dma_dst;
assign rd_desc_len      = dma_len_rd[15:0];
assign wr_desc_len      = dma_len_wr[15:0];

assign dma_req_ready = (state_m == IDLE_M);
assign dma_rsp_valid = (state_m == WAIT_M);

//start信号是单个脉冲，不能看dmactrl的最低位（最低位会拉高多个周期）
wire start_pulse;
assign start_pulse = (state_m == IDLE_M) &&
                     dma_req_valid &&
                     dma_req_ready &&
                     dma_we &&
                     dma_wstrb == 4'b1111 &&
                     dma_addr == `DMA_CONTROL_ADDR &&
                     dma_wdata[0] &&
                     !busy;

//中断清除，直接在写时候清除，不用寄存器
wire irq_clear_write;//判断是不是写clear，如果是说明可能要清除
assign irq_clear_write = (state_m == IDLE_M) &&
                         dma_req_valid &&
                         dma_req_ready &&
                         dma_we &&
                         dma_wstrb == 4'b1111 &&
                         dma_addr == `DMA_IRQ_CLEAR_ADDR;
//irq_clear_mask[0]：清除读完成状态
//irq_clear_mask[1]：清除写完成状态
//irq_clear_mask[2]：清除读错误状态
//irq_clear_mask[3]：清除写错误状态
wire [`DataBus] irq_clear_mask;
assign irq_clear_mask = irq_clear_write ? {28'b0, dma_wdata[3:0]} : 32'b0;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        irq_status <= 32'b0;
    end else begin
        irq_status <=
            (irq_status & ~irq_clear_mask) |
            irq_set_mask;
    end
end

always @(posedge clk or negedge rst_n)begin
    if(!rst_n)begin
        state_m <= IDLE_M;
    end
    else begin
        state_m <= next_state_m;
    end
end


always @(posedge clk or negedge rst_n)begin
    if(!rst_n)begin
        state_d <= IDLE_D;
    end
    else begin
        state_d <= next_state_d;
    end
end

always @(*) begin
    next_state_d = state_d;
    case (state_d)
        IDLE_D:begin
            if(start_pulse)begin
                next_state_d = REQ_D;
            end
        end
        REQ_D:begin
            if((wr_desc_done || (wr_desc_valid && wr_desc_ready)) && (rd_desc_done || (rd_desc_valid && rd_desc_ready)))begin
                next_state_d = BACK_D;
            end
        end
        BACK_D:begin
            if(wr_desc_sts_valid)begin//响应握手成功表示写完ddr
                next_state_d = IDLE_D;
            end
        end
        default: begin
            next_state_d = IDLE_D;
        end
    endcase
end

always @(*) begin
    next_state_m = state_m;
    case (state_m)
        IDLE_M:begin
            if(dma_req_ready && dma_req_valid)begin
                next_state_m = REQ_M;
            end
        end
        REQ_M:begin
            next_state_m = WAIT_M;
        end
        WAIT_M:begin
            if(dma_rsp_valid && dma_rsp_ready)begin
                next_state_m = DONE_M;
            end
        end
        DONE_M:begin
            next_state_m = IDLE_M;
        end
        default: begin
            next_state_m = IDLE_M;
        end
    endcase
end

always@(posedge clk or negedge rst_n)begin
    if(!rst_n)begin
        busy <= 'd0;
        done <= 'd0;
        error <= 'd0;
        rd_error_seen <= 1'b0;

        wr_desc_done <= 'd0;
        rd_desc_done <= 'd0;
    end
    else begin
        case(state_d)
            //开始时更新状态寄存器
            IDLE_D:begin
                if(start_pulse)begin
                    busy <= 1'b1;
                    done <= 'd0;
                    error <= 'd0;
                    rd_error_seen <= 1'b0;

                    rd_desc_done <= 'd0;
                    wr_desc_done <= 'd0;
                end
                else if (busy && rd_desc_sts_valid && |rd_desc_sts_error)
                    rd_error_seen <= 1'b1;
            end

            //req阶段对done信号的生成
            REQ_D:begin
                if(rd_desc_valid && rd_desc_ready) begin
                    rd_desc_done <= 1'b1;
                end

                if(wr_desc_valid && wr_desc_ready) begin
                    wr_desc_done <= 1'b1;
                end
            end

            //结束时更新状态寄存器并拉高中断信号
            BACK_D: begin
                if (wr_desc_sts_valid) begin
                    busy <= 1'b0;

                    error <= rd_error_seen ||
                            irq_set_mask[2] ||
                            irq_set_mask[3];

                    done <= !(rd_error_seen ||
                            irq_set_mask[2] ||
                            irq_set_mask[3]);
                end
            end
        endcase
    end
end

always @(posedge clk or negedge rst_n)begin
    if(!rst_n)begin
        dma_src <= 'd0;
        dma_len_rd <= 'd0;
        dma_len_wr <= 'd0;
        dma_dst <= 'd0;
        dma_ctrl <= 'd0;
        irq_enable <= 'd0;
        dma_rdata_q <= 'd0;

    end
    else begin
        case (state_m)
            IDLE_M:begin
                if(dma_req_ready && dma_req_valid)begin
                    if (dma_we && dma_wstrb == 4'b1111) begin
                        case(dma_addr)
                            `DMA_SRC_BASE: begin
                                dma_src <= dma_wdata;
                            end
                            `DMA_DST_BASE: begin
                                dma_dst <= dma_wdata;
                            end
                            `DMA_RDLEN_BASE: begin
                                dma_len_rd <= dma_wdata;
                            end
                            `DMA_WRLEN_BASE: begin
                                dma_len_wr <= dma_wdata;
                            end
                            `DMA_CONTROL_ADDR: begin
                                dma_ctrl <= dma_wdata;
                            end
                            `DMA_IRQ_ENABLE_ADDR:begin
                                irq_enable <= dma_wdata;
                            end
                        endcase
                    end
                    else if(!dma_we)begin
                        case (dma_addr)
                            `DMA_SRC_BASE:
                                dma_rdata_q <= dma_src;

                            `DMA_DST_BASE:
                                dma_rdata_q <= dma_dst;

                            `DMA_RDLEN_BASE:
                                dma_rdata_q <= dma_len_rd;

                            `DMA_WRLEN_BASE:
                                dma_rdata_q <= dma_len_wr;

                            `DMA_CONTROL_ADDR:
                                dma_rdata_q <= dma_ctrl;

                            `DMA_STATUS_ADDR:
                                dma_rdata_q <= dma_status;

                            `DMA_IRQ_STATUS_ADDR:
                                dma_rdata_q <= irq_status;

                            `DMA_IRQ_ENABLE_ADDR:
                                dma_rdata_q <= irq_enable;

                            default:
                                dma_rdata_q <= 32'b0;
                        endcase
                    end
                end
            end
            default: begin
            end
        endcase
    end
end


endmodule
