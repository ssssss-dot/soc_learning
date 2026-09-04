`include "define.sv"

//读先rd，再r，响应跟在r后面
//写再send状态存addr和data，存完再wait等响应
module dcache_bridge(
    input aclk,
    input arst_n,

    //dcache接口
    input                      dcache_req_valid,
    output                     dcache_req_ready,
    input     [`DataAddrBus]   dcache_req_addr,//根据pc往mem里面找相应地址的数据
    input     [31:0]           dcache_req_wdata,
    input     [3:0]            dcache_req_wstrb,
    input                      dcache_req_write,// 0表示读，1表示写

    // 下游响应
    output reg                 dcache_rsp_valid,//表示这次读写事件完成
    output reg [`DataBus]      dcache_rsp_rdata,    

    //axi
    //w
    output reg [`DataBus] m_axi_wdata,
    output [3:0]  m_axi_wstrb,
    output        m_axi_wlast,
    output        m_axi_wuser,
    output        m_axi_wvalid,
    input         m_axi_wready,

    //aw
    output [`AXI_S_ID_WIDTH-1:0] m_axi_awid,
    output reg [`DataAddrBus] m_axi_awaddr,
    output [7:0]  m_axi_awlen,
    output [2:0]  m_axi_awsize,
    output [1:0]  m_axi_awburst,
    output        m_axi_awlock,
    output [3:0]  m_axi_awcache,
    output [2:0]  m_axi_awprot,
    output [3:0]  m_axi_awqos,
    output [3:0]  m_axi_awregion,
    output        m_axi_awuser,
    output        m_axi_awvalid,
    input         m_axi_awready,

    //b
    input  [`AXI_S_ID_WIDTH-1:0] m_axi_bid,
    input  [1:0] m_axi_bresp,
    input        m_axi_buser,
    input        m_axi_bvalid,
    output       m_axi_bready,

    //ar
    output [`AXI_S_ID_WIDTH-1:0] m_axi_arid,
    output reg [`InstAddrBus] m_axi_araddr,
    output [7:0]  m_axi_arlen,
    output [2:0]  m_axi_arsize,
    output [1:0]  m_axi_arburst,
    output        m_axi_arlock,
    output [3:0]  m_axi_arcache,
    output [2:0]  m_axi_arprot,
    output [3:0]  m_axi_arqos,
    output [3:0]  m_axi_arregion,
    output        m_axi_aruser,
    output        m_axi_arvalid,
    input         m_axi_arready,

    //r
    input  [`AXI_S_ID_WIDTH-1:0] m_axi_rid,
    input  [`InstBus] m_axi_rdata,
    input  [1:0]  m_axi_rresp,
    input         m_axi_rlast,
    input         m_axi_ruser,
    input         m_axi_rvalid,
    output        m_axi_rready
);

//状态机定义
localparam [2:0] IDLE      = 3'd0;//接收并锁存dcache读请求
localparam [2:0] SEND_AR   = 3'd1;//向 AXI 发送地址，保持 ARVALID=1，等待 ARREADY
localparam [2:0] WAIT_R    = 3'd2;//地址已经握手，拉高 RREADY，等待 AXI 返回数据
localparam [2:0] SEND_AW   = 3'd3;//向 AXI 发送地址和数据，保持 AWVALID=1，等待 AWREADY
localparam [2:0] WAIT_B    = 3'd4;//等写的响应（b通道）

reg [2:0] state;
reg [2:0] next_state;

reg [3:0] wstrb_q;//wstrb信号锁存，时序对应
reg w_done;//写数据握手完成（这拍要写的数据存进去了）
reg aw_done;//写地址通道握手完成（这拍要写的地址存进去了）

//固定参数的设置
// AW写地址通道固定属性
assign m_axi_awid     = `AXI_AWID_DEFAULT;
assign m_axi_awlen    = `AXI_AWLEN_SINGLE;
assign m_axi_awburst  = `AXI_AWBURST_INCR;
assign m_axi_awlock   = `AXI_AWLOCK_NORMAL;
assign m_axi_awcache  = `AXI_AWCACHE_NORMAL;
assign m_axi_awprot   = `AXI_AWPROT_NORMAL;
assign m_axi_awqos    = `AXI_AWQOS_DEFAULT;
assign m_axi_awregion = `AXI_AWREGION_DEFAULT;
assign m_axi_awuser   = `AXI_AWUSER_DEFAULT;
assign m_axi_awsize   = (wstrb_q == 4'b1111) ? `AXI_SIZE_4B : (((wstrb_q == 4'b0011) || (wstrb_q == 4'b1100)) ? `AXI_SIZE_2B : `AXI_SIZE_1B);

// W写数据通道固定属性
assign m_axi_wlast    = `AXI_WLAST_SINGLE;
assign m_axi_wuser    = `AXI_WUSER_DEFAULT;

assign m_axi_arid     = `AXI_ID_DEFAULT;
assign m_axi_arlen    = `AXI_LEN_SINGLE;
assign m_axi_arsize   = `AXI_SIZE_4B;
assign m_axi_arburst  = `AXI_BURST_INCR;
assign m_axi_arlock   = `AXI_LOCK_NORMAL;
assign m_axi_arcache  = `AXI_CACHE_NORMAL;
assign m_axi_arprot   = `AXI_PROT_NORMAL;
assign m_axi_arqos    = `AXI_QOS_DEFAULT;
assign m_axi_arregion = `AXI_REGION_DEFAULT;
assign m_axi_aruser   = `AXI_USER_DEFAULT;
assign m_axi_wvalid   = (state == SEND_AW) && !w_done;
assign m_axi_wstrb    = wstrb_q;

assign dcache_req_ready = (state == IDLE);//可以接收valid的请求，miss了就把dcache valid拉高
assign m_axi_arvalid    = (state == SEND_AR);//表示可以发送地址
assign m_axi_rready     = (state == WAIT_R);//拉高ready，等待ddr的数据过来握手
assign m_axi_awvalid    = (state == SEND_AW) && !aw_done;
assign m_axi_bready     = (state == WAIT_B);

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
            if(dcache_req_valid && dcache_req_ready && !dcache_req_write) begin
                next_state = SEND_AR;
            end
            else if(dcache_req_valid && dcache_req_ready && dcache_req_write) begin
                next_state = SEND_AW;
            end
        end

        SEND_AR: begin
            if(m_axi_arready && m_axi_arvalid) begin
                next_state = WAIT_R;
            end
        end

        SEND_AW: begin
             if((aw_done || (m_axi_awready && m_axi_awvalid))&& (w_done || (m_axi_wready && m_axi_wvalid))) begin//w有三个握手，aw,w要同时完成握手才进wait（可以同一周期完成，也可以不同周期完成）
                next_state = WAIT_B;
            end
        end

        WAIT_R: begin
            if(m_axi_rvalid && m_axi_rready) begin
                next_state = IDLE;
            end
        end

        WAIT_B: begin
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
        m_axi_araddr  <= 'd0;
        dcache_rsp_rdata <= 'd0;
        dcache_rsp_valid <= 1'b0;
        wstrb_q <= 'd0;
        w_done <= 1'b0;
        aw_done <= 1'b0;
    end
    else begin
        // 默认清零，让rsp_valid只保持一个周期
        dcache_rsp_valid <= 1'b0;

        case(state)

            IDLE: begin
                if(!dcache_req_write)begin
                    if (dcache_req_ready && dcache_req_valid)begin
                        m_axi_araddr <= `DDR_DATA_BASE + {dcache_req_addr[31:2],2'b00} - `CPU_DATA_BASE;//dcache有三种load，都按wsize为4B读，要把字节地址除以4
                    end
                end

                else if(dcache_req_write)begin
                    if (dcache_req_ready && dcache_req_valid)begin
                        m_axi_awaddr  <= `DDR_DATA_BASE + dcache_req_addr - `CPU_DATA_BASE;
                        wstrb_q <= dcache_req_wstrb;
                        m_axi_wdata <= dcache_req_wdata;
                        aw_done <= 1'b0;
                        w_done  <= 1'b0;
                    end
                end
            end

            SEND_AW: begin 
                if(m_axi_awready && m_axi_awvalid) begin
                    aw_done <= 1'b1;
                end
                if(m_axi_wready && m_axi_wvalid) begin
                    w_done <= 1'b1;
                end
            end

            WAIT_R: begin
                if (m_axi_rvalid && m_axi_rready)begin
                    dcache_rsp_rdata <= m_axi_rdata;
                    dcache_rsp_valid <= 1'b1;
                end
            end

            WAIT_B: begin
                if (m_axi_bvalid && m_axi_bready) begin
                    dcache_rsp_valid <= 1'b1;
                end
            end

        endcase 
    end

end


endmodule
