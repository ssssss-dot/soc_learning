`include "define.sv"

module fc_accumulation(
    input clk,
    input rst_n,

    input signed [`DataBus] result_i [0:15],
    input valid_i [0:15],

    input addr_init,
    input group_start,
    input [4:0] group_bias_count_i,

    input signed [`DataBus] bias_i [0:15],
    input bias_valid_i,

    // accumulation 已加 bias 的串行结果
    output reg signed [31:0] result_o,
    output reg               result_valid_o,

    output reg drain_done
);

reg [`DataBus] line [0:15];
reg [15:0] received;
reg [4:0] ptr;
reg line_done;
reg output_finished;//表示每组输出完成，ptr固定不变了，防止无效输出

reg all_received;
integer i;

always @(*) begin
    // 有效输出数量必须为1～16
    all_received = (group_bias_count_i >= 5'd1) &&
                   (group_bias_count_i <= 5'd16);

    for (i = 0; i < 16; i = i + 1) begin
        if (i < group_bias_count_i)
            all_received = all_received & received[i];
    end
end

//存入存储模块
genvar k;
generate
    for(k = 0 ; k <= 'd15 ; k++)begin
        always @(posedge clk or negedge rst_n)begin
            if(!rst_n || group_start || addr_init)begin
                line[k] <= 'd0;
                received[k] <= 'd0;
            end
            else if((k < group_bias_count_i) && !received[k] && bias_valid_i && valid_i[k])begin
                line[k] <= $signed(result_i[k]) + $signed(bias_i[k]);
                received[k] <= 1'b1;
            end
        end
    end
endgenerate

//收齐本组有效结果，保持完成标志直到下一组
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        line_done  <= 1'b0;
        drain_done <= 1'b0;
    end
    else if (group_start || addr_init) begin
        line_done  <= 1'b0;
        drain_done <= 1'b0;
    end
    else if (all_received) begin
        line_done  <= 1'b1;
        drain_done <= 1'b1;
    end
end

//每组串行输出
always @(posedge clk or negedge rst_n) begin
    if (!rst_n || group_start || addr_init) begin
        ptr             <= 5'd0;
        result_o        <= 32'd0;
        result_valid_o  <= 1'b0;
        output_finished <= 1'b0;
    end
    else begin
        result_valid_o <= 1'b0;

        if (line_done && !output_finished && (ptr < group_bias_count_i)) begin

            result_o       <= line[ptr[3:0]];
            result_valid_o <= 1'b1;
            ptr            <= ptr + 5'd1;

            // 发出最后一个结果后，禁止再次输出
            if (ptr == group_bias_count_i - 5'd1)
                output_finished <= 1'b1;
        end
    end
end

endmodule
