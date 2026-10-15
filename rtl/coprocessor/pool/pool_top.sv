`include "define.sv"

// 固定2x2窗口、stride=2的最大池化顶层。
// 配置使用正偶数宽高、非零通道，输入总量不超过共享BRAM容量。
// 外部仲裁器从pool_start到pool_done为Pool保留访问权。
// BRAM同步读延迟为一拍，读写共用端口时写入优先。
module pool_top (
    input wire clk,
    input wire rst_n,

    // CPU MMIO配置接口
    input wire pool_req_valid,
    output wire pool_req_ready,
    output wire pool_rsp_valid,
    input wire pool_rsp_ready,
    input wire [`DataBus] pool_wdata,
    input wire [`DataAddrBus] pool_addr,
    input wire [3:0] pool_wstrb,
    input wire pool_we,
    output wire [`DataBus] pool_rdata,
    output wire pool_irq,
    output wire pool_busy,
    output wire pool_start,
    output wire pool_done,

    // 对接bram_arbiter的Pool端口，读写地址均为32位字地址
    output wire acc_pool_rd_en,
    output wire [13:0] acc_pool_rd_addr,
    input wire [`DataBus] acc_pool_rd_data,
    input wire acc_pool_rd_valid,
    output wire acc_pool_wr_en,
    output wire [13:0] acc_pool_wr_addr,
    output wire [`DataBus] acc_pool_wr_data,
    output wire [3:0] acc_pool_wr_strb
);

wire [15:0] row, col;
wire [`DataBus] channels;
wire error;
wire cmp_start, addr_init, write_done;
wire [`DataBus] idx_left;
wire addr_valid, addr_ready, half_sel;
wire signed [`ByteWidth] pooled_data;
wire pooled_valid;

// 1. 寄存器保存配置并产生启动脉冲，锁存完成/错误状态供CPU读取。
pool_reg u_pool_reg (
    .clk(clk), .rst_n(rst_n),
    .pool_req_valid(pool_req_valid), .pool_req_ready(pool_req_ready),
    .pool_rsp_valid(pool_rsp_valid), .pool_rsp_ready(pool_rsp_ready),
    .pool_wdata(pool_wdata), .pool_addr(pool_addr),
    .pool_wstrb(pool_wstrb), .pool_we(pool_we), .pool_rdata(pool_rdata),
    .pool_irq(pool_irq), .pool_row(row), .pool_col(col), .channels(channels),
    .busy(pool_busy), .done(pool_done), .error(error), .pool_start(pool_start)
);

// 2. 先初始化地址，再启动比较；最后一个字节实际写入后通知完成。
pool_ctrl u_pool_ctrl (
    .clk(clk), .rst_n(rst_n), .pool_start(pool_start),
    .row(row), .col(col), .channels(channels), .write_done(write_done),
    .busy(pool_busy), .done(pool_done), .error(error),
    .cmp_start(cmp_start), .addr_init(addr_init)
);

// 3. 请求窗口上下两对像素，按返回有效信号比较并输出最大值。
cmp u_cmp (
    .clk(clk), .rst_n(rst_n), .pool_start(cmp_start), .addr_init(addr_init),
    .row(row), .col(col), .channels(channels),
    .idx_left(idx_left), .addr_valid(addr_valid), .addr_ready(addr_ready),
    .half_sel(half_sel), .data_in(acc_pool_rd_data),
    .data_valid(acc_pool_rd_valid),
    .data_o(pooled_data), .data_valid_o(pooled_valid)
);

// 4. 字节索引转换成字地址；写回占用BRAM时，保持待读请求。
addr_change u_addr_change (
    .clk(clk), .rst_n(rst_n), .idx_left(idx_left),
    .pool_start(cmp_start), .addr_init(addr_init), .addr_valid(addr_valid),
    .word_addr(acc_pool_rd_addr), .half_sel(half_sel),
    .wen(acc_pool_wr_en), .bram_rd_en(acc_pool_rd_en), .addr_ready(addr_ready)
);

// 5. 结果从字节地址0逐字节写回，写使能同时用于暂停新读取。
wb u_wb (
    .clk(clk), .rst_n(rst_n), .data_i(pooled_data), .data_valid_i(pooled_valid),
    .row(row), .col(col), .channels(channels),
    .addr_init(addr_init), .pool_start(cmp_start),
    .wen(acc_pool_wr_en), .wstrb(acc_pool_wr_strb),
    .wdata(acc_pool_wr_data), .waddr(acc_pool_wr_addr), .write_done(write_done)
);

endmodule
