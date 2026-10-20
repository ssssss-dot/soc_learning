`include "define.sv"

module mmio_router(
    input clk,
    input rst_n,

    //mmio_router native握手要的接口
    // MEM -> MMIO bridge
    input                     mmio_req_valid,
    output                    mmio_req_ready,
    input  [`DataAddrBus]     mmio_req_addr,
    input  [`DataBus]         mmio_req_wdata,
    input  [3:0]              mmio_req_wstrb,
    input                     mmio_req_write,

    // MMIO bridge -> MEM
    output                     mmio_rsp_valid,
    input                      mmio_rsp_ready,
    output  [`DataBus]         mmio_rsp_rdata,
    
    //dma所需的9个接口
    //握手信号
    input dma_req_ready,
    output dma_req_valid,
    input dma_rsp_valid,
    output dma_rsp_ready,

    //dmawe
    output [`DataBus] dma_wdata,
    output [`DataAddrBus] dma_addr,
    output [3:0] dma_wstrb,
    output dma_we,

    input  [`DataBus] dma_rdata,

    //conv配置信号
    input conv_req_ready,
    output conv_req_valid,
    input conv_rsp_valid,
    output conv_rsp_ready,

    //convwe
    output [`DataBus] conv_wdata,
    output [`DataAddrBus] conv_addr,
    output [3:0] conv_wstrb,
    output conv_we,

    input  [`DataBus] conv_rdata,

    //fc配置信号
    input fc_req_ready,
    output fc_req_valid,
    input fc_rsp_valid,
    output fc_rsp_ready,

    //fcwe
    output [`DataBus] fc_wdata,
    output [`DataAddrBus] fc_addr,
    output [3:0] fc_wstrb,
    output fc_we,

    input  [`DataBus] fc_rdata,

    //pool配置信号
    input pool_req_ready,
    output pool_req_valid,
    input pool_rsp_valid,
    output pool_rsp_ready,

    //poolwe
    output [`DataBus] pool_wdata,
    output [`DataAddrBus] pool_addr,
    output [3:0] pool_wstrb,
    output pool_we,

    input  [`DataBus] pool_rdata,

    //摄像头配置信号
    input camera_req_ready,
    output camera_req_valid,
    input camera_rsp_valid,
    output camera_rsp_ready,

    //写摄像头寄存器
    output [`DataBus] camera_wdata,
    output [`DataAddrBus] camera_addr,
    output [3:0] camera_wstrb,
    output camera_we,

    input  [`DataBus] camera_rdata

);

wire dma_hit  = (mmio_req_addr[31:12] == 20'h40004);
wire conv_hit = (mmio_req_addr[31:12] == 20'h40005);
wire pool_hit = (mmio_req_addr[31:12] == 20'h40006);
wire fc_hit   = (mmio_req_addr[31:12] == 20'h40007);
wire camera_hit = (mmio_req_addr[31:12] == 20'h40008);

localparam IDLE   = 2'd0;
localparam REQ_W  = 2'd1;
localparam RSP    = 2'd2;

reg [1:0] state;
reg [1:0] next_state;

//相关信号锁存
reg [`DataAddrBus] addr_q;
reg [`DataBus] wdata_q;
reg [3:0] wstrb_q;
reg we_q;

//锁存hit信号
reg dma_hit_q;
reg conv_hit_q;
reg pool_hit_q;
reg fc_hit_q;
reg camera_hit_q;

assign mmio_req_ready = (state == IDLE);
assign dma_req_valid  = (state == REQ_W) && dma_hit_q;
assign mmio_rsp_valid = (state == RSP) && 
                        ((dma_hit_q ? dma_rsp_valid : 'd0) 
                        || (conv_hit_q ? conv_rsp_valid : 'd0)
                        || (fc_hit_q ? fc_rsp_valid : 'd0)
                        || (pool_hit_q ? pool_rsp_valid : 'd0)
                        || (camera_hit_q ? camera_rsp_valid : 'd0));
assign dma_rsp_ready  = (state == RSP) && mmio_rsp_ready && dma_hit_q;
// 使用锁存的目标选择读响应，写请求返回零。
assign mmio_rsp_rdata = dma_hit_q  ? (we_q ? 32'd0 : dma_rdata)  :
                        conv_hit_q ? (we_q ? 32'd0 : conv_rdata) :
                        fc_hit_q   ? (we_q ? 32'd0 : fc_rdata)   :
                        pool_hit_q ? (we_q ? 32'd0 : pool_rdata) :
                        camera_hit_q ? (we_q ? 32'd0 : camera_rdata) :
                                    32'd0;
assign conv_req_valid = (state == REQ_W) && conv_hit_q;
assign conv_rsp_ready = (state == RSP) && mmio_rsp_ready && conv_hit_q;
// FC与Conv采用相同握手：仅选中的从机收到请求和响应ready。
assign fc_req_valid = (state == REQ_W) && fc_hit_q;
assign fc_rsp_ready = (state == RSP) && mmio_rsp_ready && fc_hit_q;
assign pool_req_valid = (state == REQ_W) && pool_hit_q;
assign pool_rsp_ready = (state == RSP) && mmio_rsp_ready && pool_hit_q;
assign camera_req_valid = (state == REQ_W) && camera_hit_q;
assign camera_rsp_ready = (state == RSP) && mmio_rsp_ready && camera_hit_q;

assign dma_addr = dma_hit_q ? addr_q : 'd0;
assign dma_we = dma_hit_q ? we_q : 'd0;
assign dma_wstrb =  dma_hit_q ? (we_q ? wstrb_q : 'd0) : 'd0;
assign dma_wdata =  dma_hit_q ? (we_q ? wdata_q : 'd0) : 'd0;

assign conv_addr = conv_hit_q ? addr_q : 'd0;
assign conv_we = conv_hit_q ? we_q : 'd0;
assign conv_wstrb =  conv_hit_q ? (we_q ? wstrb_q : 'd0) : 'd0;
assign conv_wdata =  conv_hit_q ? (we_q ? wdata_q : 'd0) : 'd0;

// FC请求使用已锁存的地址和写数据，等待握手期间保持稳定。
assign fc_addr = fc_hit_q ? addr_q : 'd0;
assign fc_we = fc_hit_q ? we_q : 'd0;
assign fc_wstrb = fc_hit_q ? (we_q ? wstrb_q : 'd0) : 'd0;
assign fc_wdata = fc_hit_q ? (we_q ? wdata_q : 'd0) : 'd0;

assign pool_addr = pool_hit_q ? addr_q : 'd0;
assign pool_we = pool_hit_q ? we_q : 'd0;
assign pool_wstrb = pool_hit_q ? (we_q ? wstrb_q : 'd0) : 'd0;
assign pool_wdata = pool_hit_q ? (we_q ? wdata_q : 'd0) : 'd0;

assign camera_addr = camera_hit_q ? addr_q : 'd0;
assign camera_we = camera_hit_q ? we_q : 'd0;
assign camera_wstrb = camera_hit_q ? (we_q ? wstrb_q : 'd0) : 'd0;
assign camera_wdata = camera_hit_q ? (we_q ? wdata_q : 'd0) : 'd0;

always @(posedge clk or negedge rst_n) begin 
    if(!rst_n)begin
        state <= IDLE;
    end
    else begin
        state <= next_state;
    end
end

always @(*) begin
    next_state = state;
    case(state)

        IDLE: begin
            if(mmio_req_valid && mmio_req_ready)begin
                next_state = REQ_W;
            end
        end

        REQ_W:begin
            if((dma_req_valid && dma_req_ready) ||
               (conv_req_valid && conv_req_ready) ||
               (fc_req_valid && fc_req_ready) ||
               (pool_req_valid && pool_req_ready) ||
               (camera_req_valid && camera_req_ready))begin
                next_state = RSP;
            end
        end

        RSP:begin
            if(((dma_rsp_valid && dma_rsp_ready) ||
                (conv_rsp_valid && conv_rsp_ready) ||
                (fc_rsp_valid && fc_rsp_ready) ||
                (pool_rsp_valid && pool_rsp_ready) ||
                (camera_rsp_valid && camera_rsp_ready)) && mmio_rsp_valid && mmio_rsp_ready) begin
                next_state = IDLE;
            end
        end
        
        default: begin
            next_state = IDLE;
        end
    endcase
end

always @(posedge clk or negedge rst_n)begin
    if(!rst_n)begin
        wdata_q <= 'd0;
        wstrb_q <= 'd0;
        addr_q <= 'd0;
        we_q <= 'd0;
        dma_hit_q <= 'd0;
        conv_hit_q <= 'd0;
        pool_hit_q <= 'd0;
        fc_hit_q <= 'd0;
        camera_hit_q <= 'd0;
    end
    else begin
        case(state)

            IDLE:begin
                if(mmio_req_valid && mmio_req_ready)begin
                    dma_hit_q <= dma_hit;
                    conv_hit_q <= conv_hit;
                    pool_hit_q <= pool_hit;
                    fc_hit_q <= fc_hit;
                    camera_hit_q <= camera_hit;
                    addr_q <= mmio_req_addr;
                    we_q <= mmio_req_write;
                    if(mmio_req_write)begin
                        wdata_q <= mmio_req_wdata;
                        wstrb_q <= mmio_req_wstrb;
                    end
                end
            end
        endcase
    end
end
endmodule
