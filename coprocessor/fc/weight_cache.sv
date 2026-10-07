`include "define.sv"

module weight_cache(
    input clk,
    input rst_n,

    input  signed [`DataBus ]  weight_wr_data,
    input                     weight_data_valid,

    input addr_init,
    input weight_addr_begin,//每组要重置指针
    output features_req_o,
    output en_o,//给pe的控制信号

    output reg signed [`ByteWidth] weight_o [0:15],//features从左侧流入，重复逻辑在bias_cache里面
    output reg [15:0] weight_valid_o,
    input [4:0] group_bias_count_i,

    input computing,
    input draining
);

reg signed [`ByteWidth] weight_cache [0:15];
reg [1:0] wr_ptr;
wire [3:0] idx;
assign idx = {wr_ptr, 2'b00};
always @(posedge clk) begin
    if (rst_n && !addr_init &&
        !weight_addr_begin && weight_data_valid) begin
        weight_cache[idx]        <= weight_wr_data[7:0];
        weight_cache[idx + 4'd1] <= weight_wr_data[15:8];
        weight_cache[idx + 4'd2] <= weight_wr_data[23:16];
        weight_cache[idx + 4'd3] <= weight_wr_data[31:24];
    end
end

reg weight_vec_valid;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        wr_ptr           <= 2'd0;
        weight_vec_valid <= 1'b0;
    end
    else if (addr_init || weight_addr_begin) begin
        wr_ptr           <= 2'd0;
        weight_vec_valid <= 1'b0;
    end
    else begin
        weight_vec_valid <= 1'b0;

        if (weight_data_valid) begin
            if (wr_ptr == 2'd3) begin
                wr_ptr           <= 2'd0;
                weight_vec_valid <= 1'b1;
            end
            else begin
                wr_ptr <= wr_ptr + 2'd1;
            end
        end
    end
end

genvar k;
generate 
    for (k = 0 ; k < 16 ; k++)begin : weight_for_each_pe
        if(k == 0)begin :first_col
            always @(posedge clk or negedge rst_n)begin
                if(!rst_n)begin
                    weight_o[0] <= 'd0;
                    weight_valid_o[0] <= 'd0;
                end
                else if(weight_addr_begin || addr_init)begin
                    weight_o[0] <= 'd0;
                    weight_valid_o[0] <= 'd0;                    
                end
                else if(weight_vec_valid)begin
                    weight_o[0] <= weight_cache[0];
                    weight_valid_o[0] <= 1'b1;
                end
                else begin
                    weight_valid_o[0] <= 'd0;
                end
            end
        end
        else begin : delayed_col
            reg [`ByteWidth] delay_data [0:k-1];
            reg delay_valid [0:k-1];
            integer d;
            always @(posedge clk or negedge rst_n)begin
                if(!rst_n)begin
                    weight_o[k] <= 'd0;
                    weight_valid_o[k] <= 'd0;
                    for(d = 0 ; d < k ; d++)begin
                        delay_data[d] <= 'd0;
                        delay_valid[d] <= 'd0;
                    end
                end
                else if (addr_init || weight_addr_begin) begin
                    weight_o[k]       <= '0;
                    weight_valid_o[k] <= 1'b0;

                    for (d = 0; d < k; d = d + 1) begin
                        delay_data[d]  <= '0;
                        delay_valid[d] <= 1'b0;
                    end
                end
                else begin
                    //放入delay寄存器的开始
                    delay_data[0]  <= weight_cache[k];
                    delay_valid[0] <= weight_vec_valid;//一组权重拼完了再拉高，然后错拍
                    //每拍向后移动一级
                    for (d = 1; d < k; d = d + 1) begin
                        delay_data[d]  <= delay_data[d-1];
                        delay_valid[d] <= delay_valid[d-1];
                    end
                    //最后一级模块输出
                    weight_o[k]       <= delay_data[k-1];
                    weight_valid_o[k] <= delay_valid[k-1];
                end
            end
        end
    end
endgenerate

assign features_req_o = weight_vec_valid;
assign en_o = computing || draining;

endmodule