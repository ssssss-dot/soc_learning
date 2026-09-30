`include "define.sv"

module bias_cache(
    input clk,
    input rst_n,

    input  signed [`DataBus]  bias_wr_data,
    input                     bias_data_valid,

    input addr_init,
    input bias_addr_begin,//每组要重置指针

    output  signed [`DataBus] bias_o [0:15],//features从左侧流入，重复逻辑在bias_cache里面
    output reg bias_valid_o,
    input [4:0] group_bias_count_i,

    output reg bias_done
);

reg signed [`DataBus] bias_cache [0:15];//bram占用率太高，这里直接用寄存器组
reg [3:0] wr_ptr;

//计数逻辑
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        wr_ptr       <= 4'd0;
        bias_done    <= 1'b0;
        bias_valid_o <= 1'b0;
    end
    else if (addr_init || bias_addr_begin) begin
        wr_ptr       <= 4'd0;
        bias_done    <= 1'b0;
        bias_valid_o <= 1'b0;
    end
    else begin
        // 完成通知只保持一拍
        bias_done <= 1'b0;
        if (bias_data_valid && !bias_done && !bias_addr_begin && !addr_init && !bias_valid_o) begin
            if ({1'b0, wr_ptr} == group_bias_count_i - 5'd1) begin
                wr_ptr       <= 4'd0;
                bias_done    <= 1'b1;
                bias_valid_o <= 1'b1;//本组偏置已加载完成，保持到下一组初始化
            end
            else begin
                wr_ptr <= wr_ptr + 4'd1;
            end
        end
    end
end

integer i;
always @(posedge clk or negedge rst_n) begin
    if(!rst_n)begin
        for(i = 0; i < 16; i = i + 1) begin
            bias_cache[i] <= 0;
        end
    end
    else if(addr_init || bias_addr_begin)begin
        for(i = 0; i < 16; i = i + 1) begin
            bias_cache[i] <= 0;
        end
    end
    else if (bias_data_valid && !bias_done && !bias_addr_begin && !addr_init && !bias_valid_o) begin
        bias_cache[wr_ptr] <= bias_wr_data;
    end
end

genvar g;
generate
    for (g = 0; g < 16; g = g + 1) begin : gen_bias_out
        assign bias_o[g] = bias_cache[g];
    end
endgenerate

endmodule