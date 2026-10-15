`include "define.sv"

module cmp(
    input clk,
    input rst_n,

    input pool_start,
    input addr_init,
    input [15:0] row,
    input [15:0] col,
    input [`DataBus] channels,

    output reg [`DataBus] idx_left,
    output reg addr_valid,
    input addr_ready,//表示不写入，可以读取地址，bram读优先

    input half_sel,//addrgen给的半字选择，要打拍和输入数据同步
    input [`DataBus] data_in,
    input data_valid,

    output reg signed [`ByteWidth] data_o,
    output reg data_valid_o
);

reg half_sel_q;
reg [15:0] pixel_x;//列计数器
reg row_flag;//0表示偶数行，1表示奇数行
reg signed [`ByteWidth] cmp_result_top;
reg result_flag;//0表示上方返回，1表示下方返回

wire signed [`ByteWidth] pixel0;
wire signed [`ByteWidth] pixel1;
wire signed [`ByteWidth] pair_max;

//比较并保存最大数
assign pixel0 = half_sel_q ? data_in[23:16] : data_in[7:0];
assign pixel1 = half_sel_q ? data_in[31:24] : data_in[15:8];

assign pair_max = (pixel0 >= pixel1) ? pixel0 : pixel1;

always @(posedge clk or negedge rst_n)begin
    if(!rst_n)begin
        half_sel_q <= 1'b0;
    end
    else begin
        half_sel_q <= half_sel;
    end
end

always @(posedge clk or negedge rst_n)begin
    if(!rst_n || addr_init)begin
        idx_left <= 16'd0;
        addr_valid <= 1'b0;
        pixel_x <= 16'd0;
        row_flag <= 1'b0;
    end
    else if (pool_start) begin
        idx_left  <= 32'd0;
        addr_valid <= 1'b1;
        pixel_x   <= 16'd0;
        row_flag  <= 1'b0;
    end
    else if(addr_valid && addr_ready)begin
        if(row_flag && (idx_left == ((row*col*channels) - 32'd2)))begin
            idx_left <= 16'd0;
            addr_valid <= 1'b0;
            pixel_x <= 16'd0;
            row_flag <= 1'b0;
        end
        else if(!row_flag)begin
            row_flag <= ~row_flag;
            if(idx_left == ((pixel_x * row) + row - 16'd2))begin
                pixel_x <= pixel_x + 16'd1;
                idx_left <= idx_left + row;
            end
            else begin
                idx_left <= idx_left + row;
            end
        end
        else begin
            row_flag <= ~row_flag;
            if (idx_left == ((pixel_x * row) + row - 32'd2)) begin
                idx_left <= idx_left + 16'd2;
                pixel_x <= pixel_x + 16'd1;
            end
            else begin
                idx_left <= idx_left - row + 16'd2;
            end
        end
    end
end

always @(posedge clk or negedge rst_n)begin
    if(!rst_n || pool_start || addr_init)begin
        result_flag <= 1'b0;
        cmp_result_top <= 8'd0;
        data_valid_o <= 1'b0;
        data_o <= 8'd0;
    end
    else if(data_valid)begin
        data_valid_o <= 1'b0;
        result_flag <= ~result_flag;
        if(!result_flag)begin
            cmp_result_top <= pair_max;
        end
        else begin
            data_valid_o <= 1'b1;
            data_o <= (cmp_result_top >= pair_max) ? cmp_result_top : pair_max;
        end
    end
    else begin
        data_valid_o <= 1'b0;
    end
end

endmodule