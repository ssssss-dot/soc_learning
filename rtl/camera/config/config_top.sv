// Wiring only: ROM -> CTRL (power/reset/delays) -> I2C driver.
module config_top #(
    parameter [6:0] SLAVE_ADDR = 7'h3C,
    parameter integer CLK_FREQ = 100_000_000,
    parameter integer I2C_FREQ = 100_000,
    parameter integer TIMEOUT_US = 1_000
)(
    input  wire clk,
    input  wire rst_n,
    input  wire receiver_ready, // MIPI reset release completed in clk domain
    output wire cam_rst_n,
    output wire cam_pwdn,

    inout  wire sda,
    inout  wire scl,

    output wire config_done, // 整张ROM配置成功完成，保持到复位
    output wire write_done,  // 单次I2C事务结束，单周期脉冲
    output wire write_error, // 单次事务失败，与write_done同拍
    output wire busy ,      // 当前I2C事务忙，不包括CTRL的写后延时
    input wire start_enable
);

wire [9:0]  index;
wire [15:0] reg_addr;
wire [7:0]  reg_data;
wire [15:0] delay_ms;
wire        valid;

wire        write_start;
wire [15:0] write_addr;
wire [7:0]  write_data;
wire        transaction_done;
wire        transaction_error;

configuration_rom u_configuration_rom (
    .index(index),
    .reg_addr(reg_addr),
    .reg_data(reg_data),
    .delay_ms(delay_ms),
    .valid(valid)
);

ctrl #(
    .CLK_FREQ(CLK_FREQ)
) u_ctrl (
    .clk(clk),
    .rst_n(rst_n),
    .receiver_ready(receiver_ready),
    .cam_rst_n(cam_rst_n),
    .cam_pwdn(cam_pwdn),
    .delay_ms(delay_ms),
    .addr(reg_addr),
    .data(reg_data),
    .index(index),
    .write_start(write_start),
    .write_addr(write_addr),
    .write_data(write_data),
    .valid(valid),
    .write_done(write_done),
    .write_error(write_error),
    .config_done(config_done),
    .start_enable(start_enable)
);

i2c_dri #(
    .SLAVE_ADDR(SLAVE_ADDR),
    .CLK_FREQ(CLK_FREQ),
    .I2C_FREQ(I2C_FREQ),
    .TIMEOUT_US(TIMEOUT_US)
) u_i2c_dri (
    .clk(clk),
    .rst_n(rst_n),
    .i2c_exec(write_start),
    .bit_ctrl(1'b1),
    .i2c_rh_wl(1'b0),
    .i2c_addr(write_addr),
    .i2c_data_w(write_data),
    .i2c_data_r(),
    .i2c_done(transaction_done),
    .i2c_ack(transaction_error),
    .busy(busy),
    .scl(scl),
    .sda(sda)
);

assign write_done  = transaction_done;
assign write_error = transaction_done && transaction_error;

endmodule
