`include "define.sv"

//两个从机用地址区分，四个主机用id区分
module axi2native_mmio(
    input aclk,
    input arst_n,

    //mmio_router native握手要的接口
    // MEM -> MMIO bridge
    output                        mmio_req_valid,
    input                         mmio_req_ready,
    output reg [`DataAddrBus]     mmio_req_addr,
    output reg [`DataBus]         mmio_req_wdata,
    output reg [3:0]              mmio_req_wstrb,
    output reg                    mmio_req_write,

    // MMIO bridge -> MEM
    input                     mmio_rsp_valid,
    output                    mmio_rsp_ready,
    input  [`DataBus]         mmio_rsp_rdata,

    //axi（收数据，与左侧相反方向）
    //w
    input  [`DataBus] m_axi_wdata,
    input  [3:0]      m_axi_wstrb,
    input             m_axi_wlast,
    input             m_axi_wuser,
    input             m_axi_wvalid,
    output            m_axi_wready,

    //aw
    input  [`AXI_M_ID_WIDTH-1:0] m_axi_awid,
    input  [`DataAddrBus] m_axi_awaddr,
    input  [7:0]  m_axi_awlen,
    input  [2:0]  m_axi_awsize,
    input  [1:0]  m_axi_awburst,
    input         m_axi_awlock,
    input  [3:0]  m_axi_awcache,
    input  [2:0]  m_axi_awprot,
    input  [3:0]  m_axi_awqos,
    input  [3:0]  m_axi_awregion,
    input         m_axi_awuser,
    input         m_axi_awvalid,
    output        m_axi_awready,

    //b
    output [`AXI_M_ID_WIDTH-1:0] m_axi_bid,//从机侧BID为8位：高2位标识原始主机，低6位是主机原始ID
    output [1:0] m_axi_bresp,
    output       m_axi_buser,
    output       m_axi_bvalid,
    input        m_axi_bready,

    // ar
    input  [`AXI_M_ID_WIDTH-1:0] m_axi_arid,
    input  [`DataAddrBus]        m_axi_araddr,
    input  [7:0]                 m_axi_arlen,
    input  [2:0]                 m_axi_arsize,
    input  [1:0]                 m_axi_arburst,
    input                        m_axi_arlock,
    input  [3:0]                 m_axi_arcache,
    input  [2:0]                 m_axi_arprot,
    input  [3:0]                 m_axi_arqos,
    input  [3:0]                 m_axi_arregion,
    input                        m_axi_aruser,
    input                        m_axi_arvalid,
    output                       m_axi_arready,

    // r
    output [`AXI_M_ID_WIDTH-1:0] m_axi_rid,
    output [`DataBus]            m_axi_rdata,
    output [1:0]                 m_axi_rresp,
    output                       m_axi_rlast,
    output                       m_axi_ruser,
    output                       m_axi_rvalid,
    input                        m_axi_rready


);

localparam IDLE        = 3'd0;//接收并锁存w，aw，ar数据
localparam WAIT_W      = 3'd1;//与native侧握手，传地址和wdata
localparam DONE_W      = 3'd5;//传输完成后native侧给响应
localparam WAIT_AR     = 3'd2;//与native侧握手，传地址
localparam SEND_R      = 3'd3;//返回读数据
localparam SEND_B      = 3'd4;//返回写成功响应

reg [2:0] state;
reg [2:0] next_state;

//需要锁存的信号
reg [3:0] wstrb_q;
reg [`AXI_M_ID_WIDTH-1:0] awid_q;
reg [`DataAddrBus] awaddr_q;
reg [`DataBus] wdata_q;
reg [`DataBus] araddr_q;
reg [`AXI_M_ID_WIDTH-1:0] arid_q;
reg [`DataBus]            rdata_q;
reg w_done;
reg aw_done;
reg rsp_done;

//b
// 返回之前锁存的AWID
assign m_axi_bid   = awid_q;
// Native侧没有错误信号，暂时固定返回OKAY
assign m_axi_bresp = 2'b00;
// 不使用USER
assign m_axi_buser = 1'b0;


//r
// 返回之前锁存的ARID
assign m_axi_rid   = arid_q;
// 返回锁存的Native读数据
assign m_axi_rdata = rdata_q;
// Native侧没有错误信号，暂时固定返回OKAY
assign m_axi_rresp = 2'b00;
// MMIO只支持单拍访问，因此这一拍就是最后一拍
assign m_axi_rlast = 1'b1;
// 不使用USER
assign m_axi_ruser = 1'b0;

//读优先
wire select_read;

assign select_read =
    (state == IDLE) &&
    !aw_done &&
    !w_done &&
    m_axi_arvalid;

// 没有已接收一半的写请求时，才允许接收读请求
assign m_axi_arready =
    (state == IDLE) &&
    !aw_done &&
    !w_done;

// 本周期选择读请求时，禁止AW/W握手
assign m_axi_awready =
    (state == IDLE) &&
    !aw_done &&
    !select_read;

assign m_axi_wready =
    (state == IDLE) &&
    !w_done &&
    !select_read;
    
always @(posedge aclk or negedge arst_n) begin 
    if(!arst_n)begin
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
            if(m_axi_arvalid && m_axi_arready) begin
                next_state = WAIT_AR;
            end
            else if (((m_axi_awvalid && m_axi_awready) || aw_done) && (w_done || (m_axi_wvalid && m_axi_wready))) begin
                next_state = WAIT_W;
            end
        end

        WAIT_W: begin
            if(mmio_req_ready && mmio_req_valid)begin
                next_state = DONE_W;
            end
        end

        DONE_W: begin
            if(mmio_rsp_valid && mmio_rsp_ready) begin
                next_state = SEND_B;
            end
        end

        WAIT_AR: begin
            if(mmio_req_ready && mmio_req_valid)begin
                next_state = SEND_R;
            end
        end

        SEND_R: begin
            if(m_axi_rvalid && m_axi_rready) begin
                next_state = IDLE;
            end
        end

        SEND_B: begin
            if(m_axi_bvalid && m_axi_bready) begin
                next_state = IDLE;
            end
        end

        default: begin
            next_state = IDLE;
        end
    endcase
end

always @(posedge aclk or negedge arst_n) begin
    if(!arst_n)begin
    wstrb_q <= 'd0;
    awid_q <= 'd0;
    awaddr_q <= 'd0;
    wdata_q <= 'd0;
    araddr_q <= 'd0;
    arid_q <= 'd0;
    rdata_q <= 'd0;
    w_done <= 1'b0;
    aw_done <= 1'b0;
    rsp_done <= 1'b0;
    end
    else begin 
        case(state) 
            IDLE: begin 
                if(m_axi_arvalid && m_axi_arready) begin
                    arid_q <= m_axi_arid;
                    araddr_q <= m_axi_araddr;
                end
                else if (m_axi_awvalid && m_axi_awready)begin
                    awid_q <= m_axi_awid;
                    awaddr_q <= m_axi_awaddr;
                    aw_done <= 1'b1;
                end
                else if (m_axi_wvalid && m_axi_wready) begin
                    wstrb_q <= m_axi_wstrb;
                    wdata_q <= m_axi_wdata;
                    w_done <= 1'b1;
                end
                else begin
                    w_done <= 1'b0;
                    aw_done <= 1'b0;
                    wstrb_q <='d0;
                    wdata_q <= 'd0;
                    awid_q <= 'd0;
                    awaddr_q <= 'd0;
                    arid_q <= 'd0;
                    araddr_q <= 'd0;
                end
            end
        endcase

    end
end

endmodule