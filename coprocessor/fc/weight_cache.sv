`include "define.sv"

module weight_cache(
    input clk,
    input rst_n,

    input  signed [`ByteWidth]  weight_wr_data,
    input                     weight_data_valid,

    input addr_init,
    input weight_addr_begin,//每组要重置指针
    output features_req_o,

    output  signed [`ByteWidth] weight_o [0:15],//features从左侧流入，重复逻辑在bias_cache里面
    output reg [15:0] weight_valid_o,
    input [4:0] group_bias_count_i
);

(*ram_style = "block"*) reg signed [`ByteWidth] weight_cache [0:15];
reg wr_ptr;

always @(posedge clk or negedge rst_n)begin
    if(!rst_n)begin
        wr_ptr <= 'd0;
    end
    else if(!addr_init && !weight_addr_begin && weight_data_valid)begin
        if(wr_ptr == 'd15)begin
            wr_ptr <= 'd0;
        end
        else begin
            wr_ptr <= wr_ptr + 1'b1;
        end
    end
end

always @(posedge clk)begin
    if(!addr_init && !weight_addr_begin && weight_data_valid)begin
        weight_cache[] <= weight_wr_data;
    end
end

genvar k;
generate 
    for (k = 0 ; k < 16 ; k++)begin : weight_for_each_pe
        if(k == 0)begin :first_col
            always @(posedge clk or negedge rst_n)begin
                if(!rst_n)begin

                end
                else begin
                    
                end
            end
        end
        else begin : delayed_col
            reg [`ByteWidth] delay_data [0:k-1];
            reg delay_valid [0:k-1];
        end
    end
endgenerate

assign features_req_o = &weight_valid_o;

endmodule