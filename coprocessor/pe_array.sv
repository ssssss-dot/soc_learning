`include "define.sv"

module pe_array(
    input clk,
    input rst_n,

    //输入的特征图数据
    input signed [`ByteWidth] data_i [0:24],
    input [24:0] valid_data_i,

    //16个数据同时输入，输入25次，每次给一列编个号，从0-24
    input signed [`ByteWidth] weight_i [0:15],
    input [4:0] weight_target_i,//目标列0~24；25~31不更新任何PE
    input weight_loading_en_i,
    input valid_weight,

    //输出的结果
    output signed [`DataBus] result_o [0:15],
    output [15:0] valid_result_o
);

// 竖向连线：第0行接外部输入，第row+1行接第row行PE的down。
wire signed [`ByteWidth] data_link [0:16][0:24];
wire valid_link [0:16][0:24];

// 横向连线：第0列接0，第col+1列接第col列PE的right。
wire signed [`DataBus] sum_link [0:15][0:25];

// 每行的第0项接外部权重，后续各项接前一个PE的转发寄存器。weight从16侧加载
wire signed [`ByteWidth] weight_link [0:15][0:25];
wire weight_valid_link [0:15][0:25];

//保存每行的编号和有效信号
wire [4:0] target_link [0:25];
wire loading_link [0:25];
assign target_link[0] = weight_target_i;
assign loading_link[0] = weight_loading_en_i;

// generate展开为400个并行PE实例，寄存器和乘加逻辑在pe_ws内部。
genvar row, col;//专门给后面的generate用的信号
generate//两个并列的for循环
    //生成编号的装载状态的for循环
    for (col = 0; col < 25; col = col + 1) begin : gen_top_input//代码块的名字
        //16个数据并行进25列，每列一拍，所以要把编号做延时（在pe寄存器内部没有编号相关的寄存器）
        reg [4:0] target_q;
        reg loading_q;

        //加载初始值，把外部特征图接进来
        assign data_link[0][col] = data_i[col];
        assign valid_link[0][col] = valid_data_i[col];

        always @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin
                target_q <= 'd0;
                loading_q <= 1'b0;
            end
            else begin
                target_q <= target_link[col];
                loading_q <= loading_link[col];
            end
        end
        //打拍以后的编号给后一级
        assign target_link[col+1] = target_q;
        assign loading_link[col+1] = loading_q;
    end

    //16行的for循环
    for (row = 0; row < 16; row = row + 1) begin : gen_row
        //把外部的权重数据和valid信号给第一层
        assign weight_link[row][0] = weight_i[row];
        assign weight_valid_link[row][0] = valid_weight;
        //和初始化
        assign sum_link[row][0] = 'd0;

        //每行最后的输出（每个通道的输出）接到最后一个sum
        assign result_o[row] = sum_link[row][25];
        assign valid_result_o[row] = valid_link[row+1][24];
        //与上一个for其实是一样的硬件
        for (col = 0; col < 25; col = col + 1) begin : gen_col
            localparam [4:0] COL_ID = col;

            pe_ws u_pe_ws(
                .clk(clk),
                .rst_n(rst_n),
                // 流水线持续推进，空拍通过valid=0传递。
                // 后级必须及时接收有效结果，或在外部设置输出缓存。
                .en_i(1'b1),
                .valid_data_i(valid_link[row][col]),
                .valid_data_o(valid_link[row+1][col]),
                .up(data_link[row][col]),
                .left(sum_link[row][col]),
                .right(sum_link[row][col+1]),
                .down(data_link[row+1][col]),
                // 编号比较在阵列中完成，PE只接收本地保存使能。
                .weight_loading_en_i(loading_link[col] && (target_link[col] == COL_ID)),
                .weight_i(weight_link[row][col]),
                .weight_o(weight_link[row][col+1]),
                .valid_weight_i(weight_valid_link[row][col]),
                .valid_weight_o(weight_valid_link[row][col+1])
            );
        end
    end
endgenerate

endmodule