module video_capture_ctrl(
    input wire clk,
    input wire cam_pclk,
    input wire rst_n,

    input wire       gray_ce,
    input wire       gray_vsync,
    input wire       gray_active,
    input wire [7:0] gray_data,

    output reg        scaler_start,
    output reg        capture_active,
    output wire [7:0] scaler_data,
    output wire       capture_enable
);

localparam [23:0] TIMER_MAX = 24'd9_999_999;

localparam [1:0] IDLE       = 2'd0;
localparam [1:0] WAIT_FRAME = 2'd1;
localparam [1:0] CAPTURE    = 2'd2;

reg [23:0] timer_cnt;
reg        capture_req; // 翻转位，不再是单周期脉冲

(* ASYNC_REG = "TRUE" *) reg capture_req_d0;
(* ASYNC_REG = "TRUE" *) reg capture_req_d1;
reg capture_req_d2;

reg        gray_vsync_d;
reg [1:0]  state;
reg [14:0] pixel_cnt;

// 检测同步后的请求翻转，恢复成cam_pclk域的一周期脉冲
wire capture_req_pulse =
    capture_req_d1 ^ capture_req_d2;

// 假设VSYNC上升沿位于下一帧有效像素之前
wire frame_begin = gray_vsync && !gray_vsync_d;

// 数据直接传递，通过有效信号选择是否接收
assign scaler_data = gray_data;

assign capture_enable =
    rst_n && capture_active && gray_ce && gray_active;

//--------------------------------------------------
// 100MHz域：每100ms翻转一次请求
//--------------------------------------------------
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        timer_cnt   <= 24'd0;
        capture_req <= 1'b0;
    end
    else if (timer_cnt == TIMER_MAX) begin
        timer_cnt   <= 24'd0;
        capture_req <= ~capture_req;
    end
    else begin
        timer_cnt <= timer_cnt + 1'b1;
    end
end

//--------------------------------------------------
// cam_pclk域：请求同步、VSYNC边沿检测
//--------------------------------------------------
always @(posedge cam_pclk or negedge rst_n) begin
    if (!rst_n) begin
        capture_req_d0 <= 1'b0;
        capture_req_d1 <= 1'b0;
        capture_req_d2 <= 1'b0;
        gray_vsync_d   <= 1'b0;
    end
    else begin
        capture_req_d0 <= capture_req;
        capture_req_d1 <= capture_req_d0;
        capture_req_d2 <= capture_req_d1;
        gray_vsync_d   <= gray_vsync;
    end
end

//--------------------------------------------------
// cam_pclk域：选择并接收一帧
//--------------------------------------------------
always @(posedge cam_pclk or negedge rst_n) begin
    if (!rst_n) begin
        state          <= IDLE;
        scaler_start   <= 1'b0;
        capture_active <= 1'b0;
        pixel_cnt      <= 15'd0;
    end
    else begin
        // 默认拉低，保证start只持续一个周期
        scaler_start <= 1'b0;

        case (state)
            IDLE: begin
                capture_active <= 1'b0;

                // 收到请求，进入等待帧边界状态
                if (capture_req_pulse)
                    state <= WAIT_FRAME;
            end

            WAIT_FRAME: begin
                // 没有帧边界，就一直保持WAIT_FRAME
                if (frame_begin) begin
                    state          <= CAPTURE;
                    scaler_start   <= 1'b1;
                    capture_active <= 1'b1;
                    pixel_cnt      <= 15'd0;
                end
            end

            CAPTURE: begin
                // 仅统计实际放行的有效灰度像素
                if (capture_enable) begin
                    if (pixel_cnt == 15'd19199) begin
                        // 本次放行第19200个像素，然后关闭
                        capture_active <= 1'b0;
                        state          <= IDLE;
                    end
                    else begin
                        pixel_cnt <= pixel_cnt + 1'b1;
                    end
                end
            end

            default: begin
                state          <= IDLE;
                capture_active <= 1'b0;
                pixel_cnt      <= 15'd0;
            end
        endcase
    end
end

endmodule