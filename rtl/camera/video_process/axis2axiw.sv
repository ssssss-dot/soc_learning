`include "define.sv"

module axis2axiw#(
  parameter DATA_WIDTH = 37,
  parameter ADDR_WIDTH = 8,
  parameter DEPTH = 256
) (
    input clk,
    input rst_n,

    input  [DATA_WIDTH-1:0] fifo_wr_data,
    input data_valid,
    output axis_ready,

    // AXI4 写地址通道：本模块 -> crossbar
    output logic [`AXI_S_ID_WIDTH-1:0] m_axi_awid,
    output logic [7:0]                 m_axi_awlen,
    output logic [2:0]                 m_axi_awsize,
    output logic [1:0]                 m_axi_awburst,
    output logic                       m_axi_awlock,
    output logic [3:0]                 m_axi_awcache,
    output logic [2:0]                 m_axi_awprot,
    output logic [3:0]                 m_axi_awqos,
    output logic [3:0]                 m_axi_awregion,
    output logic                       m_axi_awuser,

    output logic [`DataAddrBus]        m_axi_awaddr,
    output logic                       m_axi_awvalid,
    input  wire                        m_axi_awready,

    // AXI4 写数据通道：本模块 -> crossbar
    output logic [`DataBus]            m_axi_wdata,
    output logic [3:0]                 m_axi_wstrb,
    output logic                       m_axi_wlast,
    output logic                       m_axi_wuser,
    output logic                       m_axi_wvalid,
    input  wire                        m_axi_wready,

    // AXI4 写响应通道：crossbar -> 本模块
    input  wire [`AXI_S_ID_WIDTH-1:0]   m_axi_bid,
    input  wire [1:0]                  m_axi_bresp,
    input  wire                        m_axi_buser,
    input  wire                        m_axi_bvalid,
    output logic                       m_axi_bready
);

wire [`DataBus] axis_data;
wire [3:0] axis_keep;
wire axis_last;

assign axis_data = fifo_wr_data[36:5];
assign axis_keep = fifo_wr_data[4:1];
assign axis_last = fifo_wr_data[0];

// 固定 AXI 写属性；地址、突发长度、数据和握手由后续状态机驱动。
assign m_axi_awid     = '0;         // 当前写主端使用 ID 0，crossbar 添加来源编号。
assign m_axi_awsize   = 3'd2;       // 每拍 2^2 = 4 字节，对应 32 位数据。
assign m_axi_awburst  = 2'b01;      // INCR：突发内按每拍 4 字节递增地址。
assign m_axi_awlock   = 1'b0;       // 普通访问，不使用独占访问。
assign m_axi_awcache  = 4'b0011;    // 普通非缓存、允许缓冲的访存属性。
assign m_axi_awprot   = 3'b010;     // [2]数据访问，[1]非安全访问，[0]非特权访问。
assign m_axi_awqos    = 4'd0;       // 默认 QoS 等级，实际仲裁策略由互连决定。
assign m_axi_awregion = 4'd0;       // 默认区域编号，目标仍由地址译码决定。
assign m_axi_awuser   = 1'b0;       // 不携带自定义写地址附加信息。
assign m_axi_wuser    = 1'b0;       // 不携带自定义写数据附加信息。

endmodule