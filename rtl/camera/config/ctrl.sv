// OV5645 hardware power-up and register configuration controller.
// Datasheet v2.01, section 2.7: PWDNB is active LOW (internal pulldown).
// Assumes module supplies and its 24 MHz oscillator are powered with the board.
// After reset: hold both controls low 5 ms, release PWDNB, wait 1 ms,
// release RESETB, wait 20 ms, then wait for MIPI RX before starting SCCB.
module ctrl #(
    parameter integer CLK_FREQ = 100_000_000
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        receiver_ready,
    input  wire [15:0] delay_ms,
    input  wire [15:0] addr,
    input  wire [7:0]  data,
    input  wire        valid,
    output reg  [9:0]  index,
    output reg         write_start,
    output reg  [15:0] write_addr,
    output reg  [7:0]  write_data,
    input  wire        write_done,
    input  wire        write_error,
    output reg         config_done,
    output reg         cam_rst_n,
    output reg         cam_pwdn,
    input  start_enable //表示允许摄像头启动
);
    // Round upward so all waits are at least the requested duration.
    localparam integer CYCLES_PER_MS = (CLK_FREQ + 999) / 1000;
    localparam integer COUNT_W = $clog2(64'd65535 * CYCLES_PER_MS + 1);
    localparam [COUNT_W-1:0] POWER_WAIT_CYCLES = 64'd5 * CYCLES_PER_MS;
    localparam [COUNT_W-1:0] RESET_WAIT_CYCLES = CYCLES_PER_MS;
    localparam [COUNT_W-1:0] SCCB_WAIT_CYCLES  = 64'd20 * CYCLES_PER_MS;

    localparam [3:0] POWER_WAIT = 4'd0,
                     RESET_WAIT = 4'd1,
                     SCCB_WAIT = 4'd2,
                     RX_WAIT = 4'd3,
                     LOAD_REG = 4'd4,
                     WRITE_WAIT = 4'd5,
                     DELAY_WAIT = 4'd6,
                     FINISHED = 4'd7,
                     FAILED = 4'd8;
    reg [3:0] state;
    reg [COUNT_W-1:0] clk_cnt;
    reg [COUNT_W-1:0] write_delay_cycles;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= POWER_WAIT;
            clk_cnt <= 'd0;
            write_delay_cycles <= 'd0;
            index <= 10'd0;
            write_start <= 1'b0;
            write_addr <= 16'd0;
            write_data <= 8'd0;
            config_done <= 1'b0;
            cam_rst_n <= 1'b0;
            cam_pwdn <= 1'b0;
        end else begin
            write_start <= 1'b0;
            case (state)
                POWER_WAIT: begin
                    if (!start_enable) begin
                        clk_cnt <= 'd0;
                    end
                    else if (clk_cnt == POWER_WAIT_CYCLES - 1'b1) begin
                        cam_pwdn <= 1'b1;
                        clk_cnt <= 'd0;
                        state <= RESET_WAIT;
                    end
                    else begin
                        clk_cnt <= clk_cnt + 1'b1;
                    end
                end
                RESET_WAIT: begin
                    if (clk_cnt == RESET_WAIT_CYCLES - 1'b1) begin
                        cam_rst_n <= 1'b1;
                        clk_cnt <= 'd0;
                        state <= SCCB_WAIT;
                    end else clk_cnt <= clk_cnt + 1'b1;
                end
                SCCB_WAIT: begin
                    if (clk_cnt == SCCB_WAIT_CYCLES - 1'b1) begin
                        clk_cnt <= 'd0;
                        state <= RX_WAIT;
                    end else clk_cnt <= clk_cnt + 1'b1;
                end
                RX_WAIT: begin
                    // Give the receiver LP-11 initialization time before streaming.
                    // This is the receiver's external reset-ready, NOT its PHY lock.
                    if (receiver_ready) state <= LOAD_REG;
                end
                LOAD_REG: begin
                    if (!valid) begin
                        config_done <= 1'b1;
                        state <= FINISHED;
                    end else begin
                        write_addr <= addr;
                        write_data <= data;
                        write_delay_cycles <= 64'd1 * delay_ms * CYCLES_PER_MS;
                        write_start <= 1'b1;
                        state <= WRITE_WAIT;
                    end
                end
                WRITE_WAIT: begin
                    if (write_error) begin
                        state <= FAILED;
                    end else if (write_done) begin
                        if (write_delay_cycles == 0) begin
                            index <= index + 10'd1;
                            state <= LOAD_REG;
                        end else begin
                            clk_cnt <= 'd0;
                            state <= DELAY_WAIT;
                        end
                    end
                end
                DELAY_WAIT: begin
                    if (clk_cnt == write_delay_cycles - 1'b1) begin
                        clk_cnt <= 'd0;
                        index <= index + 10'd1;
                        state <= LOAD_REG;
                    end else clk_cnt <= clk_cnt + 1'b1;
                end
                FINISHED: begin
                    // Keep RESETB/PWDNB high and do not restart without reset.
                end
                FAILED: begin
                    // Stop on NACK/timeout; leave config_done low until reset.
                end
                default: begin
                    state <= POWER_WAIT;
                    clk_cnt <= 'd0;
                    index <= 10'd0;
                    config_done <= 1'b0;
                    cam_rst_n <= 1'b0;
                    cam_pwdn <= 1'b0;
                end
            endcase
        end
    end
endmodule
