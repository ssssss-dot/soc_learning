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
    
    //dma所需的8个接口
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

    input  [`DataBus] dma_rdata
);

wire dma_hit  = (mmio_req_addr[31:12] == 20'h40004);
wire conv_hit = (mmio_req_addr[31:12] == 20'h40005);
wire pool_hit = (mmio_req_addr[31:12] == 20'h40006);
wire fc_hit   = (mmio_req_addr[31:12] == 20'h40007);

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

assign mmio_req_ready = (state == IDLE);
assign dma_req_valid  = (state == REQ_W) && dma_hit_q;
assign mmio_rsp_valid = (state == RSP) && dma_rsp_valid && (dma_hit_q || conv_hit_q || fc_hit_q || pool_hit_q);
assign dma_rsp_ready  = (state == RSP) && mmio_rsp_ready && dma_hit_q;
assign mmio_rsp_rdata = dma_hit_q ? (we_q ? 'd0 : dma_rdata) : 'd0;

assign dma_addr = dma_hit_q ? addr_q : 'd0;
assign dma_we = dma_hit_q ? we_q : 'd0;
assign dma_wstrb =  dma_hit_q ? (we_q ? wstrb_q : 'd0) : 'd0;
assign dma_wdata =  dma_hit_q ? (we_q ? wdata_q : 'd0) : 'd0;

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
            if(dma_req_valid && dma_req_ready)begin
                next_state = RSP;
            end
        end

        RSP:begin
            if(dma_rsp_valid && dma_rsp_ready && mmio_rsp_valid && mmio_rsp_ready) begin
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
    end
    else begin
        case(state)

            IDLE:begin
                if(mmio_req_valid && mmio_req_ready)begin
                    dma_hit_q <= dma_hit;
                    conv_hit_q <= conv_hit;
                    pool_hit_q <= pool_hit;
                    fc_hit_q <= fc_hit;
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