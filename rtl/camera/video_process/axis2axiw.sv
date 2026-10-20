`include "define.sv"

//一帧1024字节，一次传256拍，正好是axiburst的最大
module axis2axiw#(
  parameter DATA_WIDTH = 37,
  parameter ADDR_WIDTH = 8,
  parameter DEPTH = 256
) (
    input clk,
    input rst_n,

    input  [DATA_WIDTH-1:0] fifo_wr_data,
    input data_valid,
    output wire fifo_rd_en,
    input  wire fifo_empty,

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
    input  wire [`AXI_S_ID_WIDTH-1:0]  m_axi_bid,
    input  wire [1:0]                  m_axi_bresp,
    input  wire                        m_axi_buser,
    input  wire                        m_axi_bvalid,
    output logic                       m_axi_bready,

    output write_done,
    output write_error,

    //摄像头配置信号
    output camera_req_ready,
    input camera_req_valid,
    output camera_rsp_valid,
    input camera_rsp_ready,

    //写摄像头寄存器
    input [`DataBus] camera_wdata,
    input [`DataAddrBus] camera_addr,
    input [3:0] camera_wstrb,
    input camera_we,

    output reg [`DataBus] camera_rdata,

    output camera_irq
);

localparam [31:0] CAM_DDR_BASE = 32'h1002_0000;

localparam IDLE = 2'd0;
localparam WAIT_DATA = 2'd1;
localparam SEND = 2'd2;
localparam BACK = 2'd3;

reg [1:0] state;
reg [1:0] next_state;
reg [8:0] cnt;

reg [`DataBus] camera_status;//记录中断和异常的寄存器，接在mmio
reg  [`DataBus] camera_control;

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

// W 通道固定属性：当前每拍打包 4 个灰度像素，没有不足 4 字节的尾拍。
assign m_axi_wuser    = 1'b0;       // 不携带自定义写数据附加信息。
// WDATA、WVALID、WLAST 由后续发送逻辑驱动；WLAST 标记每个突发的最后一拍。

assign m_axi_awlen   = 8'd255; 
assign m_axi_awaddr  = CAM_DDR_BASE;

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        cnt <= 9'd0;
    else if ((state == BACK) && m_axi_bvalid && m_axi_bready)
        cnt <= 9'd0;             // 本帧响应结束，清零
    else if (m_axi_wvalid && m_axi_wready)
        cnt <= cnt + 9'd1;       // 只有数据握手成功才加一
end

always_ff@(posedge clk or negedge rst_n)begin
  if(!rst_n)begin
    state <= 'd0;
  end
  else begin
    state <= next_state;
  end
end

assign fifo_rd_en = rst_n && !fifo_empty && (state == IDLE);

always_comb begin
  next_state = state;
  case(state)
    IDLE:begin
      if(fifo_rd_en)begin
        next_state = WAIT_DATA;
      end
    end
    WAIT_DATA:begin
      if(data_valid)begin
        next_state = SEND;
      end
    end 
    SEND:begin
      if(m_axi_wvalid && m_axi_wready)begin
        if(cnt == 'd255)begin
          next_state = BACK;
        end
        else begin
          next_state = IDLE;
        end
      end
    end
    BACK:begin
      if(m_axi_bvalid && m_axi_bready)begin
        next_state = IDLE;
      end
    end
  endcase
end

always_ff@(posedge clk or negedge rst_n)begin
  if(!rst_n)begin
    m_axi_wdata <= 'd0;
    m_axi_wlast <= 'd0;
    m_axi_wstrb <= 'd0;
    m_axi_wvalid <= 'd0;
  end
  else begin
    case(state)
      WAIT_DATA:begin
        if(data_valid)begin
          m_axi_wdata <= axis_data;
          m_axi_wlast <= axis_last;
          m_axi_wstrb <= axis_keep;
          m_axi_wvalid <= 1'b1;
        end
      end
      SEND:begin
        if (m_axi_wvalid && m_axi_wready)begin
          m_axi_wvalid <= 1'b0;
        end
      end
    endcase
  end
end

assign m_axi_bready = rst_n && (state == BACK);

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        m_axi_awvalid <= 1'b0;
    else if (fifo_rd_en && (cnt == 9'd0))
        m_axi_awvalid <= 1'b1;   // 每帧第一次读取时启动地址发送
    else if (m_axi_awvalid && m_axi_awready)
        m_axi_awvalid <= 1'b0;
end

assign write_done = rst_n && (state == BACK) && m_axi_bvalid && m_axi_bready;
assign write_error = write_done && (m_axi_bresp != 2'b00);

//读写寄存器状态机
localparam [1:0] IDLE_REG = 2'd0;
localparam [1:0] REQ_REG = 2'd1;
localparam [1:0] RSP_REG = 2'd2;
localparam [1:0] DONE_REG = 2'd3;

reg [1:0] reg_state;
reg [1:0] reg_next_state;

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        reg_state <= IDLE_REG;
    end
    else begin
        reg_state <= reg_next_state;
    end
end

always_comb begin 
    reg_next_state = reg_state;
    case (reg_state) 
        IDLE_REG: begin
            reg_next_state = REQ_REG;
        end
        REQ_REG: begin
            if(camera_req_valid && camera_req_ready)begin
                reg_next_state = RSP_REG;
            end
        end
        RSP_REG: begin
            if(camera_rsp_valid && camera_rsp_ready)begin
                reg_next_state = DONE_REG;
            end
        end
        DONE_REG: begin
            reg_next_state = IDLE_REG;
        end
    endcase
end

always_ff @(posedge clk or negedge rst_n)begin
    if(!rst_n)begin
        camera_control <= 'd0;
        camera_rdata <= 'd0;
    end
    else begin
        if(camera_req_valid && camera_req_ready)begin
            if (camera_we) begin
                case (camera_addr)
                    `CAMERA_CONTROL_ADDR: begin
                        case (camera_wstrb[0])
                            1'b1: camera_control[7:0] <= camera_wdata[7:0];
                            default: ;
                        endcase

                        case (camera_wstrb[1])
                            1'b1: camera_control[15:8] <= camera_wdata[15:8];
                            default: ;
                        endcase

                        case (camera_wstrb[2])
                            1'b1: camera_control[23:16] <= camera_wdata[23:16];
                            default: ;
                        endcase

                        case (camera_wstrb[3])
                            1'b1: camera_control[31:24] <= camera_wdata[31:24];
                            default: ;
                        endcase
                    end
                endcase
            end
            else begin
                case (camera_addr)
                    `CAMERA_STATUS_ADDR: begin
                        camera_rdata <= camera_status;
                    end

                    `CAMERA_CONTROL_ADDR: begin
                        camera_rdata <= camera_control;
                    end
                endcase
            end
        end
    end
end

assign camera_irq = camera_control[0] && (|camera_status[1:0]);
assign camera_req_ready = rst_n && (reg_state == REQ_REG);
assign camera_rsp_valid = rst_n && (reg_state == RSP_REG);

//加入对第一位写一清零同时保存状态
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        camera_status <= 32'd0;
    end
    else begin
        // 软件写1清除：[0]错误，[1]完成
        if (camera_req_valid && camera_req_ready &&
            camera_we &&
            (camera_addr == `CAMERA_STATUS_ADDR) &&
            camera_wstrb[0]) begin
            if (camera_wdata[0])
                camera_status[0] <= 1'b0;

            if (camera_wdata[1])
                camera_status[1] <= 1'b0;
        end

        // 没有新事件时保持；新事件优先于软件清除
        if (write_done)
            camera_status[1] <= 1'b1;

        if (write_error)
            camera_status[0] <= 1'b1;
    end
end

endmodule
