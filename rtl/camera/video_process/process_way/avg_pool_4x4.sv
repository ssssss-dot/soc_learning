module avg_pool_4x4 #(
    parameter integer INPUT_WIDTH  = 128,
    parameter integer INPUT_HEIGHT = 128,
    parameter logic [7:0] THRESHOLD = 8'd128
)(
    input  logic       clk,          // video_clk
    input  logic       rst_n,        // 视频域低有效复位
    input  logic       start,        // 帧开始，清零计数和累加状态

    // 输入：8位灰度，范围0～255
    input  logic [7:0] data_i,
    input  logic       data_valid_i,
    output logic       data_ready_o,

    // 输出：暗色笔画127，亮色背景0
    output logic [7:0] data_o,
    output logic       data_valid_o,
    input  logic       data_ready_i
);

// 内部实现：4×4求平均，再进行阈值判断
reg [11:0] sum_reg [0:31];
reg [1:0] group_cnt;//组内计数器
reg [4:0] reg_cnt;//记录32个4像素的累加和
reg [1:0] row_cnt; // 当前是四行中的第0、1、2、3行
wire sum_valid;
wire [11:0] sum_next;
assign sum_valid = (row_cnt == 2'd3) && (group_cnt == 2'd3);
assign sum_next = ((row_cnt == 2'd0) && (group_cnt == 2'd0)) ? {4'b0, data_i} : sum_reg[reg_cnt] + {4'b0, data_i};

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        group_cnt <= 2'd0;
        reg_cnt   <= 5'd0;
        row_cnt   <= 2'd0;
    end
    else if (start) begin
        group_cnt <= 2'd0;
        reg_cnt   <= 5'd0;
        row_cnt   <= 2'd0;
    end
    else if (data_valid_i && data_ready_o) begin
        if (group_cnt < 2'd3) begin
            group_cnt <= group_cnt + 2'd1;
        end
        else begin
            // 接满4个像素，进入下一组
            group_cnt <= 2'd0;

            if (reg_cnt < 5'd31) begin
                reg_cnt <= reg_cnt + 5'd1;
            end
            else begin
                // 接满32组，即一整行128个像素
                reg_cnt <= 5'd0;

                if (row_cnt < 2'd3)
                    row_cnt <= row_cnt + 2'd1;
                else
                    row_cnt <= 2'd0;
            end
        end
    end
end

integer i;
always_ff @(posedge clk or negedge rst_n)begin
    if(!rst_n || start)begin
        for(i = 0; i < 32; i = i + 1)begin
            sum_reg[i] <= 'd0;
        end
    end
    else if(data_valid_i && data_ready_o)begin 
        sum_reg[reg_cnt] <= sum_next;
    end
end

always_ff @(posedge clk or negedge rst_n)begin
    if(!rst_n || start)begin
        data_o <= 'd0;
        data_valid_o <= 1'b0;
    end
    else if (!data_valid_o || data_ready_i) begin
        data_valid_o <= 1'b0;
        if (data_valid_i && data_ready_o && sum_valid) begin
            data_o <= (sum_next[11:4] < THRESHOLD) ? 8'd127 : 8'd0;
            data_valid_o <= 1'b1;
        end
    end
end

assign data_ready_o = rst_n && !start && (!data_valid_o || data_ready_i);

endmodule