`include "define.sv"

// 打包和 FIFO 写侧使用 cam_pclk，FIFO 读侧和 AXI 写主接口使用 clk。
// 帧控制器每100ms请求采集一帧；AXI写接口由soc_top连接crossbar。
module video_process_top #(
    parameter WAIT_FRAME = 10
)(
    input wire       cam_pclk,
    input wire       clk,
    input wire       rst_n,
    input wire       cam_vsync,
    input wire       cam_href,
    input wire [7:0] cam_data,

    // 摄像头 MMIO：clk 时钟域，直接连接内部 axis2axiw。
    output wire                camera_req_ready,
    input  wire                camera_req_valid,
    output wire                camera_rsp_valid,
    input  wire                camera_rsp_ready,
    input  wire [`DataBus]      camera_wdata,
    input  wire [`DataAddrBus]  camera_addr,
    input  wire [3:0]           camera_wstrb,
    input  wire                camera_we,
    output wire [`DataBus]      camera_rdata,
    output camera_irq,

    // AXI4 写地址通道：video_process_top -> soc_top。
    output wire [`AXI_S_ID_WIDTH-1:0] m_axi_awid,
    output wire [7:0]                 m_axi_awlen,
    output wire [2:0]                 m_axi_awsize,
    output wire [1:0]                 m_axi_awburst,
    output wire                       m_axi_awlock,
    output wire [3:0]                 m_axi_awcache,
    output wire [2:0]                 m_axi_awprot,
    output wire [3:0]                 m_axi_awqos,
    output wire [3:0]                 m_axi_awregion,
    output wire                       m_axi_awuser,
    output wire [`DataAddrBus]        m_axi_awaddr,
    output wire                       m_axi_awvalid,
    input  wire                       m_axi_awready,

    // AXI4 写数据通道：video_process_top -> soc_top。
    output wire [`DataBus]            m_axi_wdata,
    output wire [3:0]                 m_axi_wstrb,
    output wire                       m_axi_wlast,
    output wire                       m_axi_wuser,
    output wire                       m_axi_wvalid,
    input  wire                       m_axi_wready,

    // AXI4 写响应通道：soc_top -> video_process_top。
    input  wire [`AXI_S_ID_WIDTH-1:0] m_axi_bid,
    input  wire [1:0]                 m_axi_bresp,
    input  wire                       m_axi_buser,
    input  wire                       m_axi_bvalid,
    output wire                       m_axi_bready
);

localparam [7:0] INPUT_X_LAST  = 8'd159;
localparam [6:0] INPUT_Y_LAST  = 7'd119;
localparam [4:0] OUTPUT_X_LAST = 5'd31;
localparam [4:0] OUTPUT_Y_LAST = 5'd31;
// Q4.14：160/32 = 5，120/32 = 3.75。
localparam [17:0] X_SCALE = 18'd81920;
localparam [17:0] Y_SCALE = 18'd61440;

wire        capture_ce, capture_vsync, capture_active;
wire [23:0] capture_data;
wire        gray_ce, gray_vsync, gray_active;
wire [7:0]  gray_data;
wire [7:0]  scaler_input_data;
wire        scaler_start, scaler_input_valid;
wire [7:0]  scaler_data;
wire        scaler_valid, next_data;
wire [36:0] fifo_wr_data, fifo_rd_data;
wire        pack_valid, pack_ready;
wire        fifo_full, fifo_almost_full, fifo_empty;
wire        fifo_rd_en, fifo_rd_valid;

wire write_done, write_error;
wire [7:0] quant_data;//输入的int8要根据cnn的要求做量化
wire [7:0] processed_gray;//将白纸黑字转换成mnist要求的黑纸白字
assign processed_gray = 8'd255 - scaler_data;
assign quant_data = {1'b0 , processed_gray[7:1]};

// FIFO 接收条件同时反馈给打包模块，保证双方使用同一个写入握手。
assign pack_ready = rst_n && !fifo_full;

ov5640_capture_data #(
    .WAIT_FRAME(WAIT_FRAME)
) u_capture (
    .rst_n(rst_n),
    .cam_pclk(cam_pclk),
    .cam_vsync(cam_vsync),
    .cam_href(cam_href),
    .cam_data(cam_data),
    .cam_rst_n(),
    .cam_pwdn(),
    .vid_clk(),
    .vid_ce(capture_ce),
    .vid_vsync(capture_vsync),
    .vid_active_video(capture_active),
    .vid_data(capture_data)
);

gray_picture u_gray (
    .clk(cam_pclk),
    .rst_n(rst_n),
    .in_vid_ce(capture_ce),
    .in_vid_vsync(capture_vsync),
    .in_vid_active(capture_active),
    .in_vid_data(capture_data),
    .out_vid_ce(gray_ce),
    .out_vid_vsync(gray_vsync),
    .out_vid_active(gray_active),
    .out_vid_data(gray_data)
);

video_capture_ctrl u_video_capture_ctrl (
    .clk(clk),
    .cam_pclk(cam_pclk),
    .rst_n(rst_n),
    .gray_ce(gray_ce),
    .gray_vsync(gray_vsync),
    .gray_active(gray_active),
    .gray_data(gray_data),
    .scaler_start(scaler_start),
    .capture_active(), // 帧采集状态在ctrl内部使用。
    .scaler_data(scaler_input_data),
    .capture_enable(scaler_input_valid),
    .write_done(write_done),
    .write_error(write_error)
);

streamScaler #(
    .DATA_WIDTH(8),
    .CHANNELS(1),
    .DISCARD_CNT_WIDTH(8),
    .INPUT_X_RES_WIDTH(8),
    .INPUT_Y_RES_WIDTH(7),
    .OUTPUT_X_RES_WIDTH(5),
    .OUTPUT_Y_RES_WIDTH(5),
    .SCALE_INT_BITS(4),
    .SCALE_FRAC_BITS(14),
    .BUFFER_SIZE(4)
) u_scaler (
    .clk(cam_pclk),
    .rst(!rst_n),
    .dIn(scaler_input_data),
    .dInValid(scaler_input_valid),
    .nextDin(),
    .start(scaler_start),
    .dOut(scaler_data),
    .dOutValid(scaler_valid),
    .nextDout(next_data),
    .inputDiscardCnt(8'd0),
    .inputXRes(INPUT_X_LAST),
    .inputYRes(INPUT_Y_LAST),
    .outputXRes(OUTPUT_X_LAST),
    .outputYRes(OUTPUT_Y_LAST),
    .xScale(X_SCALE),
    .yScale(Y_SCALE),
    .leftOffset(19'd0),
    .topFracOffset(14'd0),
    .nearestNeighbor(1'b0)
);

// 每四个 INT8 像素打包成一个 32 位字，并携带 keep、last。
native2axis u_native2axis (
    .cam_pclk(cam_pclk),
    .rst_n(rst_n),
    .data_i(quant_data),
    .data_valid_i(scaler_valid),
    .next_data(next_data),
    .fifo_in(fifo_wr_data),
    .axis_ready(pack_ready),
    .axis_valid(pack_valid),
    .almost_full(fifo_almost_full)
);

async_fifo #(
    .DATA_WIDTH(37),
    .ADDR_WIDTH(8),
    .DEPTH(256)
) u_async_fifo (
    .rd_clk(clk),
    .wr_clk(cam_pclk),
    .rst_n(rst_n),
    .wr_data(fifo_wr_data),
    .rd_data(fifo_rd_data),
    .wr_en(pack_valid && pack_ready),
    .rd_en(fifo_rd_en),
    .empty(fifo_empty),
    .full(fifo_full),
    .almost_full(fifo_almost_full),
    .rd_valid(fifo_rd_valid)
);

axis2axiw #(
    .DATA_WIDTH(37),
    .ADDR_WIDTH(8),
    .DEPTH(256)
) u_axis2axiw (
    .clk(clk),
    .rst_n(rst_n),
    .fifo_wr_data(fifo_rd_data), // 转换模块输入来自 FIFO 的读侧。
    .data_valid(fifo_rd_valid),
    .fifo_rd_en(fifo_rd_en),
    .fifo_empty(fifo_empty),

    .m_axi_awid(m_axi_awid),
    .m_axi_awlen(m_axi_awlen),
    .m_axi_awsize(m_axi_awsize),
    .m_axi_awburst(m_axi_awburst),
    .m_axi_awlock(m_axi_awlock),
    .m_axi_awcache(m_axi_awcache),
    .m_axi_awprot(m_axi_awprot),
    .m_axi_awqos(m_axi_awqos),
    .m_axi_awregion(m_axi_awregion),
    .m_axi_awuser(m_axi_awuser),
    .m_axi_awaddr(m_axi_awaddr),
    .m_axi_awvalid(m_axi_awvalid),
    .m_axi_awready(m_axi_awready),

    .m_axi_wdata(m_axi_wdata),
    .m_axi_wstrb(m_axi_wstrb),
    .m_axi_wlast(m_axi_wlast),
    .m_axi_wuser(m_axi_wuser),
    .m_axi_wvalid(m_axi_wvalid),
    .m_axi_wready(m_axi_wready),

    .m_axi_bid(m_axi_bid),
    .m_axi_bresp(m_axi_bresp),
    .m_axi_buser(m_axi_buser),
    .m_axi_bvalid(m_axi_bvalid),
    .m_axi_bready(m_axi_bready),
    .write_done(write_done),
    .write_error(write_error),

    .camera_req_ready(camera_req_ready),
    .camera_req_valid(camera_req_valid),
    .camera_rsp_valid(camera_rsp_valid),
    .camera_rsp_ready(camera_rsp_ready),
    .camera_wdata(camera_wdata),
    .camera_addr(camera_addr),
    .camera_wstrb(camera_wstrb),
    .camera_we(camera_we),
    .camera_rdata(camera_rdata),
    .camera_irq(camera_irq)

);


endmodule
