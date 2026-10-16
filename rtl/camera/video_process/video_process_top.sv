`default_nettype none

// 半成品：只保留输入接口、已有数据连接和三个模块的基础例化。
// 三个处理模块均使用 cam_pclk，clk 留待后续 CDC/DDR 部分使用。
module video_process_top #(
    parameter WAIT_FRAME = 10
)(
    input wire       cam_pclk,
    input wire       clk,
    input wire       rst_n,
    input wire       cam_vsync,
    input wire       cam_href,
    input wire [7:0] cam_data
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
wire        gray_ce, gray_active;
wire [7:0]  gray_data;

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
    .out_vid_vsync(),
    .out_vid_active(gray_active),
    .out_vid_data(gray_data)
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
    .dIn(gray_data),
    .dInValid(gray_ce && gray_active),
    .nextDin(),
    .start(),       // TODO：后续连接帧启动控制。
    .dOut(),
    .dOutValid(),
    .nextDout(),    // TODO：后续连接下游取数控制。
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

endmodule

`default_nettype wire
