`include "define.sv"

//两个从机用地址区分，四个主机用id区分
module axi2native_uart(
    input aclk,
    input arst_n,

    //uart native握手要的接口
    output [`ByteWidth]     uart_tx_data,//接收到的txdata
    output                  uart_tx_valid,
    input                   uart_tx_ready,

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
    input  [29:0] m_axi_awaddr,
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
    input        m_axi_bready


);

//状态机定义
localparam IDLE = 2'd0;//接收并锁存主机写入的数据
localparam SEND = 2'd1;//向UART从机发送数据
localparam WAIT = 2'd2;//等待b通道返回响应

reg [1:0] state;
reg [1:0] next_state;

reg w_done;//写数据握手完成（这拍要写的数据存进去了）
reg aw_done;//写地址通道握手完成（这拍要写的地址存进去了）
reg [`ByteWidth] store_wdata;//锁存wdata
reg [`AXI_M_ID_WIDTH-1:0] awid_q;//waid的锁存，返回给crossbar，通过 BID 判断这个写响应应该返回给 ICache、DCache、Loader 还是 UART 主机

//固定参数
assign m_axi_bresp  = 2'b00;
assign m_axi_buser  = 1'b0;

assign m_axi_wready  = (state == IDLE) && !w_done;
assign m_axi_awready = (state == IDLE) && !aw_done;
assign m_axi_bvalid  = (state == WAIT);
assign uart_tx_valid = (state == SEND);
assign uart_tx_data = store_wdata;
assign m_axi_bid = awid_q;

always @(posedge aclk or negedge arst_n) begin
    if (!arst_n)
        state <= IDLE;
    else
        state <= next_state;
end

always @(*) begin  
    next_state = state;
    case(state)

        IDLE: begin
            if((aw_done || (m_axi_awready && m_axi_awvalid))&& (w_done || (m_axi_wready && m_axi_wvalid))) begin
                next_state = SEND;
            end
        end

        SEND: begin
             if(uart_tx_valid && uart_tx_ready) begin
                next_state = WAIT;
            end
        end

        WAIT: begin
            if(m_axi_bready && m_axi_bvalid) begin
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
        store_wdata <= 'd0;
        w_done <= 1'b0;
        aw_done <= 1'b0;
        awid_q <= 'd0;
    end
    else begin

        case(state)

            IDLE: begin
                if(m_axi_awready && m_axi_awvalid) begin
                    aw_done <= 1'b1;
                    awid_q <= m_axi_awid;
                end
                if(m_axi_wready && m_axi_wvalid) begin
                    w_done <= 1'b1;
                    store_wdata <= m_axi_wdata[7:0];
                end
            end

            SEND: begin
                if(uart_tx_ready && uart_tx_valid) begin
                    aw_done <= 1'b0;
                    w_done <= 1'b0;
                end
            end

        endcase 
    end

end
endmodule