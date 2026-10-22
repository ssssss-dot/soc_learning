`include "define.sv"

// 视频处理、打包和FIFO写侧使用video_clk；FIFO读侧和AXI写主接口使用clk。
// 帧控制器每100ms请求采集一帧；AXI写接口由soc_top连接crossbar。
module video_process_top #(
    parameter WAIT_FRAME = 10
)(
    input wire       clk,
    input wire       rst_n,

    // MIPI RX配置固定于IP内部，不使用AXI-Lite；视频流内部连接axis2rgb888。
    input wire       clk_200m,       // D-PHY的200MHz参考时钟
    input wire       video_clk,      // 本次RGB565接收IP按100MHz配置
    input wire       video_rst_n,    // 视频域低有效复位，释放须同步于video_clk
    input wire       mipi_clk_p,
    input wire       mipi_clk_n,
    input wire [1:0] mipi_data_p,
    input wire [1:0] mipi_data_n,

    output wire      mipi_pll_lock,
    output wire      mipi_system_rst,

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
    output wire camera_write_done,

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

localparam [7:0] INPUT_X_LAST  = 8'd127;
localparam [6:0] INPUT_Y_LAST  = 7'd127;
localparam [4:0] OUTPUT_X_LAST = 5'd31;
localparam [4:0] OUTPUT_Y_LAST = 5'd31;
// Q4.14: 128/32 = 4 on both axes; 4 * 2^14 = 65536.
localparam [17:0] X_SCALE = 18'd65536;
localparam [17:0] Y_SCALE = 18'd65536;

wire [15:0] mipi_video_tdata;
wire [9:0]  mipi_video_tdest;
wire        mipi_video_tlast, mipi_video_tvalid, mipi_video_tready;
wire [0:0]  mipi_video_tuser;
wire        rgb888_ce, rgb888_vsync, rgb888_active;
wire [23:0] rgb888_data;
wire        gray_ce, gray_vsync, gray_active;
wire [7:0]  gray_data;
wire [7:0]  capture_data;
wire        capture_valid, video_ready, scaler_input_ready;
wire [7:0]  scaler_input_data;
wire        scaler_start, scaler_input_valid;
wire [7:0]  scaler_data;
wire        scaler_valid, next_data;
wire [36:0] fifo_wr_data, fifo_rd_data;
wire        pack_valid, pack_ready;
wire        fifo_full, fifo_almost_full, fifo_empty;
wire        fifo_rd_en, fifo_rd_valid;

wire write_done, write_error;
assign camera_write_done = write_done;
wire [7:0] quant_data;//输入的int8要根据cnn的要求做量化
wire [7:0] processed_gray;//将白纸黑字转换成mnist要求的黑纸白字
assign processed_gray = 8'd255 - scaler_data;
assign quant_data = {1'b0 , processed_gray[7:1]};

// FIFO 接收条件同时反馈给打包模块，保证双方使用同一个写入握手。
assign pack_ready = rst_n && !fifo_full;

// Xilinx MIPI CSI-2 RX v5.2：按camera/ip内重新生成的.veo例化。
// RGB565、2 lanes、448Mb/s/lane、1 pixel/clock、VFB、16位视频输出。
// CSI-2和D-PHY寄存器接口均关闭；使能和活动lane数固定。
mipi_csi2_rx_subsystem_0 u_mipi_csi2_rx_subsystem_0 (
    // 时钟与复位
    .dphy_clk_200M(clk_200m),              // 输入：D-PHY所需200MHz参考时钟
    .video_aclk(video_clk),                // 输入：视频输出及内部处理时钟
    .video_aresetn(video_rst_n),              // 输入：视频域低有效复位，由外部同步释放

    // 固定控制：active_lanes的编码是lane数量减1，01表示2 lanes。
    .ctrl_core_en(1'b1),
    .active_lanes(2'b01),

    // PHY状态
    .rxbyteclkhs(),                // 输出：高速接收字节时钟，不是video_aclk
    .clkoutphy_out(),              // 输出：内部PLL产生的PHY时钟，供共享逻辑使用
    .system_rst_out(mipi_system_rst),            // 输出：PHY/PLL复位指示，高有效
    .pll_lock_out(mipi_pll_lock),              // 输出：PHY内部PLL锁定指示

    // 寄存器接口关闭后提供的状态输出；尚无使用方，先留空。
    .ctrl_dis_in_prgs(),
    .errsotsynchs_intr(),
    .errsoths_intr(),
    .cl_stopstate_intr(),
    .dl0_stopstate_intr(),
    .dl1_stopstate_intr(),
    .crc_status_intr(),
    .ecc_status_intr(),
    .linebuffer_full(),
    .frame_rcvd_pulse_out(),

    // AXI-Stream视频输出：MIPI IP -> 后续视频适配模块
    .video_out_tdata(mipi_video_tdata),           // 输出[15:0]：像素数据，排列由IP配置决定
    .video_out_tdest(mipi_video_tdest),           // 输出[9:0]：[9:4]数据类型；[3:0]虚拟通道号
    .video_out_tlast(mipi_video_tlast),           // 输出：本拍为当前行最后一个像素，不是帧结束
    .video_out_tready(mipi_video_tready),          // 输入：下游能够接收本拍数据
    .video_out_tuser(mipi_video_tuser),           // 输出[0:0]：bit0标记一帧的首像素
    .video_out_tvalid(mipi_video_tvalid),          // 输出：本拍视频数据有效，与tready同时为1才传输

    // 摄像头MIPI物理输入：一对时钟差分线、两对数据差分线
    .mipi_phy_if_clk_p(mipi_clk_p),         // 输入：时钟通道P端，来自顶层MIPI引脚
    .mipi_phy_if_clk_n(mipi_clk_n),         // 输入：时钟通道N端
    .mipi_phy_if_data_p(mipi_data_p),        // 输入[1:0]：数据lane0/1的P端
    .mipi_phy_if_data_n(mipi_data_n)         // 输入[1:0]：数据lane0/1的N端
);

axis2rgb888 u_axis2rgb888 (
    .video_clk(video_clk),
    .rst_n(video_rst_n),
    .s_axis_tdata(mipi_video_tdata),
    .s_axis_tdest(mipi_video_tdest),
    .s_axis_tvalid(mipi_video_tvalid),
    .s_axis_tready(mipi_video_tready),
    .s_axis_tlast(mipi_video_tlast),
    .s_axis_tuser(mipi_video_tuser),
    .video_ready(video_ready),
    .vid_data(rgb888_data),
    .vid_ce(rgb888_ce),
    .vid_vsync(rgb888_vsync),
    .vid_active(rgb888_active)
);

gray_picture u_gray (
    .clk(video_clk),
    .rst_n(video_rst_n),
    .in_vid_ce(rgb888_ce),
    .in_vid_vsync(rgb888_vsync),
    .in_vid_active(rgb888_active),
    .in_vid_data(rgb888_data),
    .out_vid_ce(gray_ce),
    .out_vid_vsync(gray_vsync),
    .out_vid_active(gray_active),
    .out_vid_data(gray_data)
);

video_capture_ctrl u_video_capture_ctrl (
    .clk(clk),
    .cam_pclk(video_clk),
    .rst_n(rst_n),
    .gray_ce(gray_ce),
    .gray_vsync(gray_vsync),
    .gray_active(gray_active),
    .gray_data(gray_data),
    .scaler_start(scaler_start),
    .capture_active(), // 帧采集状态在ctrl内部使用。
    .scaler_data(capture_data),
    .capture_enable(capture_valid),
    .write_done(write_done),
    .write_error(write_error)
);

// 缓冲在途灰度像素，并通过video_ready提前暂停前级。
video_input_buffer #(
    .DATA_WIDTH(8),
    .DEPTH(8),
    .UPSTREAM_LATENCY(3)
) u_video_input_buffer (
    .clk(video_clk),
    .rst_n(video_rst_n),
    .data_i(capture_data),
    .data_valid_i(capture_valid),
    .video_ready(video_ready),
    .data_o(scaler_input_data),
    .data_valid_o(scaler_input_valid),
    // start当拍缩放器执行初始化，不能消耗缓冲中的像素。
    .data_ready_i(scaler_input_ready && !scaler_start)
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
    .clk(video_clk),
    .rst(!video_rst_n),
    .dIn(scaler_input_data),
    .dInValid(scaler_input_valid),
    .nextDin(scaler_input_ready),
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
    .cam_pclk(video_clk),
    .rst_n(video_rst_n),
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
    .wr_clk(video_clk),
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
