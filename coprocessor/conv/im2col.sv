`include "define.sv"

module im2col(
    input clk,
    input rst_n,

    // conv_ctrl给出的启动信号
    input wire im2col_start_i,

    //给pearray的输入和valid
    output reg signed [`ByteWidth] data_o [0:24],
    output reg [24:0] valid_data_i,

    //输入的图像大小
    input wire [15:0] input_width_i,
    input wire [15:0] input_height_i,

    //inputcache给im2col的输入
    input wire signed [`ByteWidth] pixel_data_i,
    input wire                     pixel_valid_i,

    //im2col给inpurcache的地址
    //取窗口的时候按列读取了，这里地址顺序增加
    output reg [15:0] pixel_addr_o,
    output reg pixel_req_o
);

wire [9:0] addr_end;
assign addr_end = (input_height_i * input_width_i) - 1;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n)begin
        pixel_addr_o <= 'd0;
        pixel_req_o <= 1'b0;
    end
    else if (im2col_start_i)begin
        pixel_addr_o <= 'd0;
        pixel_req_o <= 1'b1;
    end
    else if (pixel_req_o)begin//用req不用valid，valid比req慢一拍，会多加一个0
        if (pixel_addr_o == addr_end)begin
            pixel_req_o <= 1'b0;
            pixel_addr_o <= 'd0;
        end
        else begin
            pixel_req_o <= 1'b1;
            pixel_addr_o <= pixel_addr_o + 1'b1;
        end
    end
end

reg [10:0] pixel_x;
reg [10:0] pixel_y;
reg window_valid;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        window_valid <= 1'b0;
    else if (im2col_start_i)
        window_valid <= 1'b0;
    else
        window_valid <= pixel_valid_i &&
                        (pixel_x >= 11'd4) &&
                        (pixel_y >= 11'd4);
end

// 保存前4行；最大图像宽度为32
reg signed [7:0] line0 [0:31];
reg signed [7:0] line1 [0:31];
reg signed [7:0] line2 [0:31];
reg signed [7:0] line3 [0:31];

// 保存5行各自最近的5列
reg signed [7:0] window [0:4][0:4];

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        pixel_x <= 'd0;
        pixel_y <= 'd0;
    end
    else begin
        if (im2col_start_i) begin
            pixel_x <= 'd0;
            pixel_y <= 'd0;
        end
        else if (pixel_valid_i) begin
            pixel_x <= pixel_x + 1'b1;
            if (pixel_x == input_width_i - 1) begin
                pixel_x <= 'd0;
                if (pixel_y == input_height_i - 1) begin
                    pixel_y <= 'd0;
                end
                else begin
                    pixel_y <= pixel_y + 1'b1;
                end
            end
        end
    end
end

integer i, r, c;

//line缓存和window生成
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        for (i = 0; i < 32; i = i + 1) begin
            line0[i] <= 8'sd0;
            line1[i] <= 8'sd0;
            line2[i] <= 8'sd0;
            line3[i] <= 8'sd0;
        end

        for (r = 0; r < 5; r = r + 1)
            for (c = 0; c < 5; c = c + 1)
                window[r][c] <= 8'sd0;
    end
    else if (pixel_valid_i) begin
        // 每行窗口向左移动一格，腾出最右边的位置
        for (r = 0; r < 5; r = r + 1)
            for (c = 0; c < 4; c = c + 1)
                window[r][c] <= window[r][c+1];

        // 同一列的5个像素，进入窗口最右边
        window[0][4] <= line3[pixel_x];
        window[1][4] <= line2[pixel_x];
        window[2][4] <= line1[pixel_x];
        window[3][4] <= line0[pixel_x];
        window[4][4] <= pixel_data_i;

        // 更新行缓存，留给下一行使用
        line3[pixel_x] <= line2[pixel_x];
        line2[pixel_x] <= line1[pixel_x];
        line1[pixel_x] <= line0[pixel_x];
        line0[pixel_x] <= pixel_data_i;
    end
end

//平行四边形拼接，后一列数据比前一列晚一拍
// 第k列比第0列晚k拍；数据和valid必须经过相同长度的延迟链。
//每个generate块独立并行
genvar k;
generate
    for (k = 0; k < 25; k = k + 1) begin : gen_pe_skew
        localparam integer WINDOW_ROW = k / 5;
        localparam integer WINDOW_COL = k % 5;

        //低0列不用延迟
        if (k == 0) begin : gen_first_column
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n || im2col_start_i) begin
                    data_o[k]       <= 8'sd0;
                    valid_data_i[k] <= 1'b0;
                end
                else begin
                    data_o[k]       <= window[WINDOW_ROW][WINDOW_COL];
                    valid_data_i[k] <= window_valid;
                end
            end
        end

        else begin : gen_delayed_column
            reg signed [7:0] data_delay [0:k-1];
            reg              valid_delay [0:k-1];
            integer d;

            always @(posedge clk or negedge rst_n) begin
                if (!rst_n || im2col_start_i) begin
                    data_o[k]       <= 8'sd0;
                    valid_data_i[k] <= 1'b0;
                    for (d = 0; d < k; d = d + 1) begin
                        data_delay[d]  <= 8'sd0;
                        valid_delay[d] <= 1'b0;
                    end
                end
                else begin
                    //放入delay寄存器的开始
                    data_delay[0]  <= window[WINDOW_ROW][WINDOW_COL];
                    valid_delay[0] <= window_valid;
                    //每拍向后移动一级
                    for (d = 1; d < k; d = d + 1) begin
                        data_delay[d]  <= data_delay[d-1];
                        valid_delay[d] <= valid_delay[d-1];
                    end
                    //最后一级模块输出
                    data_o[k]       <= data_delay[k-1];
                    valid_data_i[k] <= valid_delay[k-1];
                end
            end
        end
    end
endgenerate

endmodule
