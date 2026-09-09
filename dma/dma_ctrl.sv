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
    //status[0] : rd_busy     读DMA正在工作
    //status[1] : wr_busy     写DMA正在工作
    //status[2] : rd_done     读DMA完成
    //status[3] : wr_done     写DMA完成
    //status[4] : rd_error    读DMA出错
    //status[5] : wr_error    写DMA出错
    //status[6] : irq_pending 至少有一个中断原因挂起
    //status[31:7] : 保留
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
    input  [3:0]      wr_desc_sts_error,

    output dma_wr_done_pulse,//给dcache做一致性复位

    //给ram的offset配置数据
    output reg [15:0] rd_bram_offset_active,
    output reg [15:0] wr_bram_offset_active
);

localparam IDLE_M = 2'd0;//锁存，等握手
localparam REQ_M  = 2'd1;//握手
localparam WAIT_M = 2'd2;//返回rspvalid（读）
localparam DONE_M = 2'd3;

localparam RD_IDLE = 2'd0;//等 CPU 写 DMA_CONTROL_ADDR 产生 start_pulse
localparam RD_REQ  = 2'd1;//把寄存器里面的给dma并拉高valid，等待握手
localparam RD_BACK = 2'd2;//等待读端sts_valid，表示DDR读取任务结束

localparam WR_IDLE = 2'd0;//等 CPU 写 DMA_CONTROL_ADDR 产生 start_pulse
localparam WR_REQ  = 2'd1;//把寄存器里面的给dma并拉高valid，等待握手
localparam WR_BACK = 2'd2;//等待写端sts_valid，表示DDR写回任务结束

reg [1:0] state_m;
reg [1:0] next_state_m;

reg [1:0] state_rd;
reg [1:0] next_state_rd;

reg [1:0] state_wr;
reg [1:0] next_state_wr;

//src和dst都要是ddr的物理地址
reg [`DataBus] dma_src;//从哪里开始读ddr
reg [`DataBus] dma_dst;//从哪里开始写ddr
reg [`DataBus] dma_len_rd;
reg [`DataBus] dma_len_wr;
//CTRL[0] start_rd
//CTRL[1] irq_enable
//CTRL[2] start_wr
reg [`DataBus] dma_ctrl;
//STATUS[0] = rd_busy
//STATUS[1] = wr_busy
//STATUS[2] = rd_done
//STATUS[3] = wr_done
//STATUS[4] = rd_error
//STATUS[5] = wr_error
//STATUS[6] = irq_pending
wire [`DataBus] dma_status;
reg [`DataBus] irq_status;
reg [`DataBus] irq_enable;
reg [`DataBus] dma_byte_offset_rd;//只用低16位，ram为64KB，表示偏移字节数，后续如果ram每位存一个字要做地址转换
reg [`DataBus] dma_byte_offset_wr;

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

assign dma_wr_done_pulse = wr_desc_sts_valid;
reg rd_busy;
reg wr_busy;
reg rd_done;
reg wr_done;
reg rd_error;
reg wr_error;
wire irq_pending;
reg [`DataBus] dma_rdata_q;

assign dma_rdata = dma_rdata_q;
assign dma_status = {
    25'b0,
    irq_pending,
    wr_error,
    rd_error,
    wr_done,
    rd_done,
    wr_busy,
    rd_busy
};
assign dma_irq =
    dma_ctrl[1] &&
    (|(irq_status & irq_enable));//考虑中断是否使能，dma_ctrl[1]是全局的中断使能
assign irq_pending = |irq_status;//每一位取或，只要有一个中断原因挂起就说明有中断

//读写配置有效信号，完成信号记录好了就拉低valid，防止重复赋值
assign rd_desc_valid = (state_rd == RD_REQ);
assign wr_desc_valid = (state_wr == WR_REQ);

//在valid期间，相关配置接口要一直拉高
assign rd_desc_src_addr = dma_src;
assign wr_desc_dst_addr = dma_dst;
assign rd_desc_len      = dma_len_rd[15:0];
assign wr_desc_len      = dma_len_wr[15:0];

assign dma_req_ready = (state_m == IDLE_M);
assign dma_rsp_valid = (state_m == WAIT_M);

//start信号是单个脉冲，不能看dmactrl的最低位（最低位会拉高多个周期）
//读开始信号
wire start_pulse_rd;
assign start_pulse_rd = (state_m == IDLE_M) &&
                     dma_req_valid &&
                     dma_req_ready &&
                     dma_we &&
                     dma_wstrb == 4'b1111 &&
                     dma_addr == `DMA_CONTROL_ADDR &&
                     dma_wdata[0] &&
                     !rd_busy;

//写开始信号
wire start_pulse_wr;
assign start_pulse_wr = (state_m == IDLE_M) &&
                     dma_req_valid &&
                     dma_req_ready &&
                     dma_we &&
                     dma_wstrb == 4'b1111 &&
                     dma_addr == `DMA_CONTROL_ADDR &&
                     dma_wdata[2] &&
                     !wr_busy;

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

//给偏移量
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        rd_bram_offset_active  <= 16'd0;
        wr_bram_offset_active  <= 16'd0;
    end
    else begin
        if (start_pulse_rd)
            rd_bram_offset_active <= dma_byte_offset_rd[15:0];

        if (start_pulse_wr)
            wr_bram_offset_active <= dma_byte_offset_wr[15:0];
    end
end

wire [`DataBus] irq_clear_mask;
assign irq_clear_mask = irq_clear_write ? {28'b0, dma_wdata[3:0]} : 32'b0;
//中断原因寄存器更新
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
        state_rd <= RD_IDLE;
        state_wr <= WR_IDLE;
    end
    else begin
        state_rd <= next_state_rd;
        state_wr <= next_state_wr;
    end
end

always @(*) begin
    next_state_wr = state_wr;
    case (state_wr)
        WR_IDLE:begin
            if(start_pulse_wr)begin
                next_state_wr = WR_REQ;
            end
        end
        WR_REQ:begin
            if(wr_desc_valid && wr_desc_ready) begin
                next_state_wr = WR_BACK;
            end
        end
        WR_BACK:begin
            if(wr_desc_sts_valid)begin//写DMA返回任务状态
                next_state_wr = WR_IDLE;
            end
        end
        default: begin
            next_state_wr = WR_IDLE;
        end
    endcase
end

always @(*) begin
    next_state_rd = state_rd;
    case (state_rd)
        RD_IDLE:begin
            if(start_pulse_rd)begin
                next_state_rd = RD_REQ;
            end
        end
        RD_REQ:begin
            if(rd_desc_valid && rd_desc_ready) begin
                next_state_rd = RD_BACK;
            end
        end
        RD_BACK:begin
            if(rd_desc_sts_valid)begin//读DMA返回任务状态
                next_state_rd = RD_IDLE;
            end
        end
        default: begin
            next_state_rd = RD_IDLE;
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

//dma读侧更新
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        rd_busy  <= 1'b0;
        rd_done  <= 1'b0;
        rd_error <= 1'b0;
    end
    else begin
        if (start_pulse_rd) begin
            rd_busy  <= 1'b1;
            rd_done  <= 1'b0;
            rd_error <= 1'b0;
        end

        if (rd_desc_sts_valid) begin
            rd_busy  <= 1'b0;
            rd_done  <= (rd_desc_sts_error == 4'b0000);
            rd_error <= (rd_desc_sts_error != 4'b0000);
        end
    end
end

//dma写侧更新
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        wr_busy  <= 1'b0;
        wr_done  <= 1'b0;
        wr_error <= 1'b0;
    end
    else begin
        if (start_pulse_wr) begin
            wr_busy  <= 1'b1;
            wr_done  <= 1'b0;
            wr_error <= 1'b0;
        end

        if (wr_desc_sts_valid) begin
            wr_busy  <= 1'b0;
            wr_done  <= (wr_desc_sts_error == 4'b0000);
            wr_error <= (wr_desc_sts_error != 4'b0000);
        end
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
        dma_byte_offset_rd <= 32'd0;
        dma_byte_offset_wr <= 32'd0;
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
                            `DMA_RD_BYTE_OFFSET_ADDR: begin
                                dma_byte_offset_rd <= {16'd0, dma_wdata[15:0]};
                            end
                            `DMA_WR_BYTE_OFFSET_ADDR: begin
                                dma_byte_offset_wr <= {16'd0, dma_wdata[15:0]};
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

                            `DMA_RD_BYTE_OFFSET_ADDR:
                                dma_rdata_q <= dma_byte_offset_rd;

                            `DMA_WR_BYTE_OFFSET_ADDR:
                                dma_rdata_q <= dma_byte_offset_wr;
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
