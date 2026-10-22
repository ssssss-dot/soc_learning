// 基于用户提供的 正点原子 i2c_dri 例程修改。
// Original notice: Copyright (C) 正点原子 2023-2033. All rights reserved.
// 单主机、7位设备地址、8/16位寄存器地址、单字节读写。
// 所有寄存器只使用 clk；SDA/SCL 仅拉低或释放，外部需要上拉。
module i2c_dri #(
    parameter [6:0] SLAVE_ADDR = 7'h3C,
    parameter integer CLK_FREQ = 100_000_000,
    parameter integer I2C_FREQ = 100_000,
    parameter integer TIMEOUT_US = 1_000
)(
    input  wire        clk,
    input  wire        rst_n,

    input  wire        i2c_exec,    // clk 域启动脉冲；busy 时不接受新请求
    input  wire        bit_ctrl,    // 1：16位寄存器地址；0：8位
    input  wire        i2c_rh_wl,   // 1：读；0：写
    input  wire [15:0] i2c_addr,
    input  wire [7:0]  i2c_data_w,
    output reg  [7:0]  i2c_data_r,
    output reg         i2c_done,    // 事务结束，clk 域单周期脉冲
    output reg         i2c_ack,     // 保留原命名：1表示NACK或总线等待超时
    output reg         busy,

    inout  wire        scl,
    inout  wire        sda
);

// 一个SCL周期分成4个阶段。向上取整，避免实际频率超过设定值。
// 对称时钟同时满足Standard/Fast-mode的最小低电平时间。
localparam integer RATE_QUARTER =
    (CLK_FREQ + 4 * I2C_FREQ - 1) / (4 * I2C_FREQ);
localparam integer MIN_QUARTER = (I2C_FREQ <= 100_000)
    ? ((64'd47 * CLK_FREQ + 19_999_999) / 20_000_000)
    : ((64'd13 * CLK_FREQ + 19_999_999) / 20_000_000);
localparam integer QUARTER_CYCLES =
    (RATE_QUARTER > MIN_QUARTER) ? RATE_QUARTER : MIN_QUARTER;
localparam integer DIV_WIDTH = (QUARTER_CYCLES > 1)
    ? $clog2(QUARTER_CYCLES) : 1;
localparam integer TIMEOUT_CYCLES_RAW =
    (64'd1 * CLK_FREQ * TIMEOUT_US + 999_999) / 1_000_000;
localparam integer TIMEOUT_CYCLES =
    (TIMEOUT_CYCLES_RAW > 0) ? TIMEOUT_CYCLES_RAW : 1;
localparam integer TIMEOUT_WIDTH = (TIMEOUT_CYCLES > 1)
    ? $clog2(TIMEOUT_CYCLES) : 1;

localparam [3:0] IDLE       = 4'd0;
localparam [3:0] START      = 4'd1;
localparam [3:0] SEND_BYTE  = 4'd2;
localparam [3:0] READ_ACK   = 4'd3;
localparam [3:0] RESTART    = 4'd4;
localparam [3:0] READ_BYTE  = 4'd5;
localparam [3:0] SEND_NACK  = 4'd6;
localparam [3:0] STOP       = 4'd7;
localparam [3:0] BUS_FREE   = 4'd8;

localparam [2:0] DEVICE_WRITE = 3'd0;
localparam [2:0] REGISTER_HI  = 3'd1;
localparam [2:0] REGISTER_LO  = 3'd2;
localparam [2:0] DATA_WRITE   = 3'd3;
localparam [2:0] DEVICE_READ  = 3'd4;

reg [3:0] state;
reg [2:0] byte_stage;
reg [1:0] phase;
reg [2:0] bit_index;
reg [7:0] tx_byte;
reg [7:0] rx_byte;
reg [15:0] addr_q;
reg [7:0] data_q;
reg addr16_q;
reg read_q;
reg exec_q;
reg scl_release;
reg sda_release;
reg [DIV_WIDTH-1:0] div_count;
reg [TIMEOUT_WIDTH-1:0] timeout_count;

(* ASYNC_REG = "TRUE" *) reg [1:0] scl_sync;
(* ASYNC_REG = "TRUE" *) reg [1:0] sda_sync;

wire phase_tick = (div_count == QUARTER_CYCLES - 1);
wire accept_request = i2c_exec && !exec_q && !busy;
wire wait_scl = busy && scl_release && !scl_sync[1];
wire wait_bus = busy && (state == START) && (phase == 2'd0)
                && !sda_sync[1];
wire wait_pin = wait_scl || wait_bus;

assign scl = scl_release ? 1'bz : 1'b0;
assign sda = sda_release ? 1'bz : 1'b0;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        scl_sync <= 2'b11;
        sda_sync <= 2'b11;
    end
    else begin
        scl_sync <= {scl_sync[0], scl};
        sda_sync <= {sda_sync[0], sda};
    end
end

// 这里只生成时钟使能，不生成供内部逻辑使用的新时钟。
always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        div_count <= 'd0;
    else if (accept_request || phase_tick || wait_pin)
        div_count <= 'd0;
    else
        div_count <= div_count + 1'b1;
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state         <= IDLE;
        byte_stage    <= DEVICE_WRITE;
        phase         <= 2'd0;
        bit_index     <= 3'd7;
        tx_byte       <= 8'd0;
        rx_byte       <= 8'd0;
        addr_q        <= 16'd0;
        data_q        <= 8'd0;
        addr16_q      <= 1'b0;
        read_q        <= 1'b0;
        exec_q        <= 1'b0;
        scl_release   <= 1'b1;
        sda_release   <= 1'b1;
        timeout_count <= 'd0;
        i2c_data_r    <= 8'd0;
        i2c_done      <= 1'b0;
        i2c_ack       <= 1'b0;
        busy          <= 1'b0;
    end
    else begin
        exec_q   <= i2c_exec;
        i2c_done <= 1'b0;

        if (wait_pin)
            timeout_count <= timeout_count + 1'b1;
        else
            timeout_count <= 'd0;

        // 在系统时钟上立即锁存请求，不需要等phase_tick，单拍启动不会丢失。
        if (accept_request) begin
            addr_q        <= i2c_addr;
            data_q        <= i2c_data_w;
            addr16_q      <= bit_ctrl;
            read_q        <= i2c_rh_wl;
            state         <= START;
            byte_stage    <= DEVICE_WRITE;
            phase         <= 2'd0;
            bit_index     <= 3'd7;
            rx_byte       <= 8'd0;
            i2c_ack       <= 1'b0;
            busy          <= 1'b1;
            timeout_count <= 'd0;
        end
        else if (wait_pin && (timeout_count == TIMEOUT_CYCLES - 1)) begin
            // 对方持续拉低SCL/SDA时无法保证产生STOP；释放总线并报告失败。
            scl_release   <= 1'b1;
            sda_release   <= 1'b1;
            state         <= IDLE;
            phase         <= 2'd0;
            busy          <= 1'b0;
            i2c_ack       <= 1'b1;
            i2c_done      <= 1'b1;
            timeout_count <= 'd0;
        end
        else if (phase_tick && !wait_pin) begin
            case (state)
                IDLE: begin
                    scl_release <= 1'b1;
                    sda_release <= 1'b1;
                    phase       <= 2'd0;
                end

                START: begin
                    case (phase)
                        2'd0: begin
                            scl_release <= 1'b1;
                            sda_release <= 1'b1;
                            phase       <= 2'd1;
                        end
                        2'd1: begin
                            sda_release <= 1'b0; // SCL高时，SDA由高变低
                            phase       <= 2'd2;
                        end
                        2'd2: phase <= 2'd3;
                        2'd3: begin
                            scl_release <= 1'b0;
                            tx_byte     <= {SLAVE_ADDR, (byte_stage == DEVICE_READ)};
                            bit_index   <= 3'd7;
                            phase       <= 2'd0;
                            state       <= SEND_BYTE;
                        end
                    endcase
                end

                SEND_BYTE: begin
                    case (phase)
                        2'd0: begin
                            scl_release <= 1'b0;
                            sda_release <= tx_byte[bit_index];
                            phase       <= 2'd1;
                        end
                        2'd1: begin
                            scl_release <= 1'b1;
                            phase       <= 2'd2;
                        end
                        2'd2: phase <= 2'd3;
                        2'd3: begin
                            scl_release <= 1'b0;
                            phase       <= 2'd0;
                            if (bit_index == 3'd0)
                                state <= READ_ACK;
                            else
                                bit_index <= bit_index - 1'b1;
                        end
                    endcase
                end

                READ_ACK: begin
                    case (phase)
                        2'd0: begin
                            sda_release <= 1'b1; // 第9个时钟由从机驱动SDA
                            phase       <= 2'd1;
                        end
                        2'd1: begin
                            scl_release <= 1'b1;
                            phase       <= 2'd2;
                        end
                        2'd2: begin
                            if (sda_sync[1])//sda传回1，说明对方没有ACK
                                i2c_ack <= 1'b1;
                            phase <= 2'd3;
                        end
                        2'd3: begin
                            scl_release <= 1'b0;
                            bit_index   <= 3'd7;
                            phase       <= 2'd0;
                            state       <= SEND_BYTE;
                            if (i2c_ack)
                                state <= STOP; // NACK后停止，不发送剩余字节
                            else begin
                                case (byte_stage)//判断是写设备还是地址还是数据
                                    DEVICE_WRITE: begin
                                        if (addr16_q) begin
                                            tx_byte    <= addr_q[15:8];
                                            byte_stage <= REGISTER_HI;
                                        end
                                        else begin
                                            tx_byte    <= addr_q[7:0];
                                            byte_stage <= REGISTER_LO;
                                        end
                                    end
                                    REGISTER_HI: begin
                                        tx_byte    <= addr_q[7:0];
                                        byte_stage <= REGISTER_LO;
                                    end
                                    REGISTER_LO: begin
                                        if (read_q)
                                            state <= RESTART;
                                        else begin
                                            tx_byte    <= data_q;
                                            byte_stage <= DATA_WRITE;
                                        end
                                    end
                                    DATA_WRITE: state <= STOP;
                                    DEVICE_READ: state <= READ_BYTE;
                                    default: begin
                                        i2c_ack <= 1'b1;
                                        state   <= STOP;
                                    end
                                endcase
                            end
                        end
                    endcase
                end

                RESTART: begin
                    case (phase)
                        2'd0: begin
                            sda_release <= 1'b1;
                            phase       <= 2'd1;
                        end
                        2'd1: begin
                            scl_release <= 1'b1;
                            phase       <= 2'd2;
                        end
                        2'd2: phase <= 2'd3;
                        2'd3: begin
                            sda_release <= 1'b0;
                            byte_stage  <= DEVICE_READ;
                            phase       <= 2'd2;
                            state       <= START;
                        end
                    endcase
                end

                READ_BYTE: begin
                    case (phase)
                        2'd0: begin
                            sda_release <= 1'b1;
                            phase       <= 2'd1;
                        end
                        2'd1: begin
                            scl_release <= 1'b1;
                            phase       <= 2'd2;
                        end
                        2'd2: begin
                            rx_byte[bit_index] <= sda_sync[1];
                            phase              <= 2'd3;
                        end
                        2'd3: begin
                            scl_release <= 1'b0;
                            phase       <= 2'd0;
                            if (bit_index == 3'd0) begin
                                i2c_data_r <= rx_byte;
                                state      <= SEND_NACK;
                            end
                            else
                                bit_index <= bit_index - 1'b1;
                        end
                    endcase
                end

                SEND_NACK: begin
                    case (phase)
                        2'd0: begin
                            sda_release <= 1'b1; // 单字节读结束，主机发送NACK
                            phase       <= 2'd1;
                        end
                        2'd1: begin
                            scl_release <= 1'b1;
                            phase       <= 2'd2;
                        end
                        2'd2: phase <= 2'd3;
                        2'd3: begin
                            scl_release <= 1'b0;
                            phase       <= 2'd0;
                            state       <= STOP;
                        end
                    endcase
                end

                STOP: begin
                    case (phase)
                        2'd0: begin
                            sda_release <= 1'b0;
                            phase       <= 2'd1;
                        end
                        2'd1: begin
                            scl_release <= 1'b1;
                            phase       <= 2'd2;
                        end
                        2'd2: phase <= 2'd3;
                        2'd3: begin
                            sda_release <= 1'b1; // SCL高时，SDA由低变高
                            phase       <= 2'd0;
                            state       <= BUS_FREE;
                        end
                    endcase
                end

                BUS_FREE: begin
                    // STOP后保留两个阶段的空闲时间，再返回完成。
                    if (phase == 2'd1) begin
                        busy     <= 1'b0;
                        i2c_done <= 1'b1;
                        phase    <= 2'd0;
                        state    <= IDLE;
                    end
                    else
                        phase <= 2'd1;
                end

                default: begin
                    scl_release <= 1'b1;
                    sda_release <= 1'b1;
                    state       <= IDLE;
                    phase       <= 2'd0;
                    busy        <= 1'b0;
                    i2c_ack     <= 1'b1;
                    i2c_done    <= 1'b1;
                end
            endcase
        end
    end
end

endmodule
