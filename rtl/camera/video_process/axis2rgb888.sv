// Xilinx MIPI RX VFB -> RGB888 native视频接口。
// 当前IP的RGB565已按UG934重排为{R[4:0], B[4:0], G[5:0]}。
// 单项弹性缓存：下游暂停时保留像素；支持同拍出队、入队。
module axis2rgb888 #(
    parameter [3:0] VIRTUAL_CHANNEL = 4'd0,
    parameter integer FRAME_START_GAP_CYCLES = 4
)(
    input  wire        video_clk,
    input  wire        rst_n,

    // MIPI接收IP -> 本模块
    input  wire [15:0] s_axis_tdata,   // [15:11]R，[10:6]B，[5:0]G
    input  wire [9:0]  s_axis_tdest,   // [9:4]数据类型，[3:0]虚拟通道
    input  wire        s_axis_tvalid,
    output wire        s_axis_tready,
    input  wire        s_axis_tlast,   // 行末标记
    input  wire [0:0]  s_axis_tuser,   // bit0：帧首像素标记

    // 允许本拍把缓存像素送入gray_picture。
    // 后级流控必须为gray的三级流水线及其他在途数据预留空间。
    input  wire        video_ready,

    // 本模块 -> gray_picture
    output wire [23:0] vid_data,      // RGB888：{R[7:0], G[7:0], B[7:0]}
    output wire        vid_ce,        // 本拍送出一个有效像素
    output reg         vid_vsync,     // 一拍帧开始脉冲，提前于首像素输出
    output wire        vid_active     // 有效图像像素
);

    localparam integer START_GAP =
        (FRAME_START_GAP_CYCLES > 0) ? FRAME_START_GAP_CYCLES : 1;
    localparam integer GAP_WIDTH = $clog2(START_GAP + 1);

    reg [15:0] pixel_q;
    reg        pixel_valid_q;
    reg        pixel_sof_q;
    reg        pixel_last_q;
    reg        frame_seen;
    reg        line_gap;
    reg [GAP_WIDTH-1:0] gap_count;

    wire       selected_stream;
    wire       input_fire;
    wire       store_pixel;
    wire       output_fire;
    wire [4:0] red5;
    wire [5:0] green6;
    wire [4:0] blue5;

    // CSI-2数据类型0x22为RGB565；只输出指定虚拟通道。
    assign selected_stream = (s_axis_tdest[9:4] == 6'h22) &&
                             (s_axis_tdest[3:0] == VIRTUAL_CHANNEL);

    assign output_fire = rst_n && pixel_valid_q && !pixel_sof_q &&
                         (gap_count == 0) && !line_gap && video_ready;
    assign s_axis_tready = rst_n && (!pixel_valid_q || output_fire);
    assign input_fire = s_axis_tvalid && s_axis_tready;

    // 复位后丢弃帧中间的数据，等到选定通道的SOF才开始输出。
    // 不匹配的数据只被消费，不写入像素缓存，也不产生VSYNC。
    assign store_pixel = input_fire && selected_stream &&
                         (frame_seen || s_axis_tuser[0]);

    assign red5   = pixel_q[15:11];
    assign blue5  = pixel_q[10:6];
    assign green6 = pixel_q[5:0];

    // 高位复制到低位，使5/6位的最大值都扩展为8'hFF。
    assign vid_data = {red5, red5[4:2],
                       green6, green6[5:4],
                       blue5, blue5[4:2]};
    // native接口没有待接收的valid保持语义；ce高表示本拍实际送出。
    assign vid_ce     = output_fire;
    assign vid_active = output_fire;

    always @(posedge video_clk or negedge rst_n) begin
        if (!rst_n) begin
            pixel_q       <= 16'd0;
            pixel_valid_q <= 1'b0;
            pixel_sof_q   <= 1'b0;
            pixel_last_q  <= 1'b0;
            frame_seen    <= 1'b0;
            line_gap      <= 1'b0;
            gap_count     <= 'd0;
            vid_vsync     <= 1'b0;
        end
        else begin
            vid_vsync <= 1'b0;
            line_gap  <= 1'b0;

            if (gap_count != 0)
                gap_count <= gap_count - 1'b1;

            // SOF像素先留在缓存中，单独发出帧开始，再等待初始化。
            // 即使video_ready为0，帧开始也能送出，避免启动互相等待。
            if (pixel_valid_q && pixel_sof_q) begin
                pixel_sof_q <= 1'b0;
                gap_count   <= START_GAP;
                vid_vsync   <= 1'b1;
            end

            if (output_fire) begin
                pixel_valid_q <= 1'b0;
                // 行末之后留一拍无效间隔，不把TLAST当作帧结束。
                line_gap <= pixel_last_q;
            end

            // 放在出队逻辑之后，同拍出入队时保留新像素的valid。
            if (store_pixel) begin
                pixel_q       <= s_axis_tdata;
                pixel_valid_q <= 1'b1;
                pixel_sof_q   <= s_axis_tuser[0];
                pixel_last_q  <= s_axis_tlast;
                if (s_axis_tuser[0])
                    frame_seen <= 1'b1;
            end
        end
    end

endmodule
