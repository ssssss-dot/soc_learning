`include "define.sv"

//dma访问ddr要
module dma_ctrl(
    input clk,
    input rst_n,

    //握手信号
    output dma_req_ready,
    input dma_req_valid,
    output dma_rsp_valid,

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
    input             rd_desc_sts_valid,
    input  [3:0]      rd_desc_sts_error,

    //写 descriptor 接口
    output [`DataBus] wr_desc_dst_addr,
    output [15:0]     wr_desc_len,
    output            wr_desc_valid,
    input             wr_desc_ready,
    input             wr_desc_sts_valid,
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
reg [`DataBus] dma_clear;

reg busy;
reg done;
reg error;
reg irq_pending;
reg dma_we_d0;

//要两个都配置好才能进下一个状态，但不一定同一周期完成，所以加done信号
reg rd_desc_done;//记录dmactrl读部分的配置传输完毕
reg wr_desc_done;//记录dmactrl写部分的配置传输完毕

assign dma_rdata = dma_status;
assign dma_status = {28'b0, irq_pending, error, done, busy};
assign dma_irq    = irq_pending;

//读写配置有效信号，完成信号记录好了就拉低valid，防止重复赋值
assign rd_desc_valid = (state_d == REQ_D) && !rd_desc_done;
assign wr_desc_valid = (state_d == REQ_D) && !wr_desc_done;

//在valid期间，相关配置接口要一直拉高
assign rd_desc_src_addr = dma_src;
assign wr_desc_dst_addr = dma_dst;
assign rd_desc_len      = dma_len_rd[15:0];
assign wr_desc_len      = dma_len_wr[15:0];

assign dma_req_ready = (state_m == IDLE_M);
assign dma_rsp_valid = (state_m == WAIT_M) && !dma_we_d0;

//start信号是单个脉冲，不能看dmactrl的最低位（最低位会拉高多个周期）
wire start_pulse;
assign start_pulse = (state_m == IDLE_M) &&
                     dma_req_valid &&
                     dma_req_ready &&
                     dma_we &&
                     dma_wstrb == 4'b1111 &&
                     dma_addr == `DMA_CONTROL_ADDR &&
                     dma_wdata[0];

//用来判断dma中断信号是否要清楚的脉冲信号，通过dma_clear寄存器控制
wire irq_clear_pulse;
assign irq_clear_pulse = (state_m == IDLE_M) &&
                         dma_req_valid &&
                         dma_req_ready &&
                         dma_we &&
                         dma_wstrb == 4'b1111 &&
                         dma_addr == `DMA_IRQ_CLEAR_ADDR &&
                         dma_wdata[0];

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
            if(!dma_we_d0)begin
                next_state_m = WAIT_M;
            end
            else if(dma_we_d0)begin
                next_state_m = DONE_M;
            end
        end
        WAIT_M:begin
            if(dma_rsp_valid)begin
                next_state_m = DONE_M;
            end
        end
        DONE_M:begin
            next_state_m = IDLE_M;
        end
    endcase
end

always@(posedge clk or negedge rst_n)begin
    if(!rst_n)begin
        busy <= 'd0;
        done <= 'd0;
        error <= 'd0;
        irq_pending <= 'd0;

        wr_desc_done <= 'd0;
        rd_desc_done <= 'd0;
    end
    else begin
        //先判断中断信号是不是要清零
        if(irq_clear_pulse) begin
            irq_pending <= 1'b0;
        end
        case(state_d)
            //开始时更新状态寄存器
            IDLE_D:begin
                if(start_pulse)begin
                    busy <= 1'b1;
                    done <= 'd0;
                    error <= 'd0;
                    irq_pending <= 'd0;

                    rd_desc_done <= 'd0;
                    wr_desc_done <= 'd0;
                end
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
                if(wr_desc_sts_valid) begin
                    busy <= 1'b0;
                    done <= (wr_desc_sts_error == 4'b0000);
                    error <= (wr_desc_sts_error != 4'b0000);

                    if(dma_ctrl[1]) begin//dma_ctrl[1]是en使能位
                        irq_pending <= 1'b1;
                    end
                end
            end
        endcase
    end
end

always @(posedge clk or negedge rst_n)begin
    if(!rst_n)begin
        dma_clear <= 'd0;
        dma_src <= 'd0;
        dma_len_rd <= 'd0;
        dma_len_wr <= 'd0;
        dma_dst <= 'd0;
        dma_ctrl <= 'd0;

        dma_we_d0 <= 'd0;

    end
    else begin
        case (state_m)
            IDLE_M:begin
                if(dma_req_ready && dma_req_valid)begin
                    dma_we_d0 <= dma_we;

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
                            `DMA_IRQ_CLEAR_ADDR: begin
                                dma_clear <= dma_wdata;
                            end
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
