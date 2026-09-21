`include "define.sv"

module accumulation(
    input clk,
    input rst_n,

    //ctrl给的信号
    //重置信号
    input wire        addr_init_i,
    input wire        im2col_start_i,

    //计算每个输出通道有多少个像素
    input wire [15:0] input_width_i,
    input wire [15:0] input_height_i,

    //指定有效的输出通道数。Conv1 用前 6 个 bank，Conv2 用 16 个；也用于判断最后一个有效 PE 行和最后一个 bias
    input wire [15:0] output_channels_i,

    //当前是第几个输入通道。等于 0 时，PE 结果直接写 RAM；大于 0 时，先读旧部分和、相加再写回。Conv2 会依次是 0～5
    input wire [15:0] channel_cnt_i,

    input bias_addr_begin_i,//

    //输出的结果
    input signed [`DataBus] result_i [0:15],
    input [15:0] valid_result_i,

    // BRAM 返回的 bias
    input wire signed [`DataBus] bias_data_i,
    input wire                   bias_data_valid_i,

    // 给 conv_ctrl
    output reg channel_done_o,
    output reg bias_loaded_done_o,

    output [`DataBus] result_o,//加了偏置的int32输出
    output reg                   result_valid_o
);

// 每个 PE 行对应一个输出通道的结果存储 bank。
// 读写控制尚未实现，暂时关闭读写使能。
genvar bank_idx;
generate
    for (bank_idx = 0; bank_idx < 16; bank_idx = bank_idx + 1) begin : gen_result_bank
        result_ram_bank u_result_ram_bank (
            .clk     (clk),
            .wr_en   (1'b0),
            .wr_addr (10'd0),
            .wr_data (32'sd0),
            .rd_en   (1'b0),
            .rd_addr (10'd0),
            .rd_data ()
        );
    end
endgenerate

endmodule
