`include "define.sv"

module uart_bridge(
    input aclk,
    input arst_n,

    //给tx端串口打印结果
    input [`ByteWidth] dbg_uart_tx_data,
    input   dbg_uart_tx_valid,
    output  dbg_uart_tx_ready,

    // mem_bridge -> mem：写完成响应（b）
    output         dbg_rsp_valid,
    input          dbg_rsp_ready,
    output         dbg_rsp_error,

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
    output [`DataAddrBus] m_axi_awaddr,
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
    output       m_axi_bready
);

//状态机定义
localparam IDLE = 2'd0;//接收并锁存icache读请求
localparam SEND = 2'd1;//向 AXI 发送地址和数据，等aw，w都握手完成，进入响应
localparam WAIT = 2'd2;//地址已经握手，拉高 RREADY，等待 AXI 返回数据

reg [1:0] state;
reg [1:0] next_state;

reg w_done;//写数据握手完成（这拍要写的数据存进去了）
reg aw_done;//写地址通道握手完成（这拍要写的地址存进去了）

//固定参数的设置
// AW写地址通道固定属性
assign m_axi_awid     = `AXI_AWID_DEFAULT;
assign m_axi_awlen    = `AXI_AWLEN_SINGLE;
assign m_axi_awburst  = `AXI_AWBURST_INCR;
assign m_axi_awlock   = `AXI_AWLOCK_NORMAL;
assign m_axi_awcache  = 4'b0000;            // MMIO，不缓存
assign m_axi_awprot   = `AXI_AWPROT_NORMAL;
assign m_axi_awqos    = `AXI_AWQOS_DEFAULT;
assign m_axi_awregion = `AXI_AWREGION_DEFAULT;
assign m_axi_awuser   = `AXI_AWUSER_DEFAULT;
assign m_axi_awsize   = `AXI_SIZE_1B;
assign m_axi_awaddr   = `UART_TX_ADDR;

// W写数据通道固定属性
assign m_axi_wstrb    = 4'b0001;            // 只写低8位（一个字节）
assign m_axi_wlast    = `AXI_WLAST_SINGLE;
assign m_axi_wuser    = `AXI_WUSER_DEFAULT;

assign dbg_uart_tx_ready = (state == IDLE);

assign m_axi_awvalid = (state == SEND) && !aw_done;
assign m_axi_wvalid  = (state == SEND) && !w_done;

assign dbg_rsp_valid = (state == WAIT) && m_axi_bvalid;
assign dbg_rsp_error = (m_axi_bresp != 2'b00);
assign m_axi_bready  = (state == WAIT) && dbg_rsp_ready;

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
            if(dbg_uart_tx_valid && dbg_uart_tx_ready) begin
                next_state = SEND;
            end
        end

        SEND: begin
             if((aw_done || (m_axi_awready && m_axi_awvalid))&& (w_done || (m_axi_wready && m_axi_wvalid))) begin//w有三个握手，aw,w要同时完成握手才进wait（可以同一周期完成，也可以不同周期完成）
                next_state = WAIT;
            end
        end

        WAIT: begin
            if(dbg_rsp_valid && dbg_rsp_ready) begin
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
        m_axi_wdata  <= 32'd0;
        w_done <= 1'b0;
        aw_done <= 1'b0;
    end
    else begin

        case(state)

            IDLE: begin
                if (dbg_uart_tx_ready && dbg_uart_tx_valid)begin
                        m_axi_wdata <= dbg_uart_tx_data;
                        aw_done <= 1'b0;
                        w_done  <= 1'b0;
                end
            end

            SEND: begin 
                if(m_axi_awready && m_axi_awvalid) begin
                    aw_done <= 1'b1;
                end
                if(m_axi_wready && m_axi_wvalid) begin
                    w_done <= 1'b1;
                end
            end

        endcase 
    end

end
endmodule
