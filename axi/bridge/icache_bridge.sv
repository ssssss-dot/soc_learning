`include "define.sv"

module icache_bridge(
    input aclk,
    input arst_n,

    //icache与mem的接口
    input                        icache_req_valid,
    output                       icache_req_ready,
    input      [`InstAddrBus]    icache_req_addr,
    output reg                   icache_rsp_valid,
    output reg [`InstBus]        icache_rsp_rdata,

    //转成axi的r和ar接口
    //r读数据，s2m
    input      [`AXI_S_ID_WIDTH-1:0] m_axi_rid,
    input      [`InstBus]       m_axi_rdata,
    input      [1:0]            m_axi_rresp,//本次读访问是否成功
    input                       m_axi_rlast,
    input                       m_axi_ruser,
    input                       m_axi_rvalid,
    output                      m_axi_rready,

    
    //ar读地址，m2s
    output reg [`InstAddrBus]  m_axi_araddr,//读起始地址
    output     [7:0]           m_axi_arlen,//突发传输长度（这次不用）
    output     [2:0]           m_axi_arsize,//突发传输一拍的数据长s度，传输字节数为2^ARSIZE，这里固定为2
    output     [1:0]           m_axi_arburst,//突发类型：FIXED、INCR、WRAP,
    output                     m_axi_arvalid,//主机表示地址信息有效
    input                      m_axi_arready,//从机表示可以接收地址
    output     [`AXI_S_ID_WIDTH-1:0] m_axi_arid,//读事务ID
    output                     m_axi_arlock,//原子/独占访问属性
    output     [3:0]           m_axi_arcache,//Cache 属性
    output     [2:0]           m_axi_arprot,//保护属性    
    output     [3:0]           m_axi_arqos,
    output     [3:0]           m_axi_arregion,
    output                     m_axi_aruser


);

//状态机定义
localparam IDLE = 2'd0;//接收并锁存icache读请求
localparam SEND = 2'd1;//向 AXI 发送地址，保持 ARVALID=1，等待 ARREADY
localparam WAIT = 2'd2;//地址已经握手，拉高 RREADY，等待 AXI 返回数据

reg [1:0] state;
reg [1:0] next_state;

//固定参数的设置
assign m_axi_arid     = `AXI_ID_DEFAULT;
assign m_axi_arlen    = `AXI_LEN_SINGLE;
assign m_axi_arsize   = `AXI_SIZE_4B;
assign m_axi_arburst  = `AXI_BURST_INCR;
assign m_axi_arlock   = `AXI_LOCK_NORMAL;
assign m_axi_arcache  = `AXI_CACHE_NORMAL;
assign m_axi_arprot   = `AXI_PROT_INSTRUCTION;
assign m_axi_arqos    = `AXI_QOS_DEFAULT;
assign m_axi_arregion = `AXI_REGION_DEFAULT;
assign m_axi_aruser   = `AXI_USER_DEFAULT;

assign icache_req_ready = (state == IDLE);//可以接收valid的请求，miss了就把icachevalid拉高
assign m_axi_arvalid    = (state == SEND);//表示可以发送地址
assign m_axi_rready     = (state == WAIT);//拉高ready，等待ddr的数据过来握手

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
            if(icache_req_valid && icache_req_ready) begin
                next_state = SEND;
            end
        end

        SEND: begin
            if(m_axi_arready && m_axi_arvalid) begin
                next_state = WAIT;
            end
        end

        WAIT: begin
            if(m_axi_rvalid && m_axi_rready) begin
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
        icache_rsp_rdata <= 'd0;
        icache_rsp_valid <= 1'b0;
    end
    else begin
        // 默认清零，让rsp_valid只保持一个周期
        icache_rsp_valid <= 1'b0;

        case(state)

            IDLE: begin
                if (icache_req_ready && icache_req_valid)begin
                    m_axi_araddr  <=  `DDR_INST_BASE + icache_req_addr - `CPU_INST_BASE;
                end
            end

            WAIT: begin
                if (m_axi_rvalid && m_axi_rready)begin
                    icache_rsp_rdata <= m_axi_rdata;
                    icache_rsp_valid <= 1'b1;
                end
            end

        endcase 
    end

end


endmodule
