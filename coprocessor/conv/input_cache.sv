`include "define.sv"
module input_cache#(
    parameter integer DEPTH = 256,
    parameter integer WORD_ADDR_W  = 8,
    parameter integer PIXEL_ADDR_W = 10
)(
    input clk,
    input rst_n,

    // 开始缓存新的输入通道
    input wire input_addr_begin,

    input wr_en,
    input signed [`DataBus] wr_data,

    // im2col发出的像素读取请求
    input wire                    pixel_req,
    input wire [PIXEL_ADDR_W-1:0] pixel_addr,//需要的内部mem的编号
    input [7:0] input_last_word_addr_i,//写缓存最后一个字地址

    // 返回一个INT8像素
    output reg signed [`ByteWidth] pixel_data,
    output reg              pixel_valid,
    output reg  input_cache_loaded_done_o

);

(* ram_style = "block" *) reg signed [`DataBus] mem [0:DEPTH-1];

//内部指针声明
reg [WORD_ADDR_W-1:0] cache_wr_ptr;//写用字指针
wire [WORD_ADDR_W-1:0] cache_rd_ptr;//32b的mem的索引

reg [`DataBus] rd_word;
reg [1:0] byte_sel_q;//选择读取字节

assign cache_rd_ptr = pixel_addr[PIXEL_ADDR_W-1:2];

//ram读写
always @(posedge clk) begin
    if (wr_en && !input_cache_loaded_done_o) begin
        mem[cache_wr_ptr] <= wr_data;
    end
    else if (pixel_req) begin
        rd_word <= mem[cache_rd_ptr];
    end
end

always @(*) begin
    pixel_data = 'd0;
    case(byte_sel_q)
        2'd0:pixel_data = rd_word[7:0];
        2'd1:pixel_data = rd_word[15:8];
        2'd2:pixel_data = rd_word[23:16];
        2'd3:pixel_data = rd_word[31:24];
    endcase
end

//valid脉冲信号产生
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        byte_sel_q <= 2'd0;
        pixel_valid <= 1'b0;
    end
    else begin
        pixel_valid <= pixel_req && !wr_en;

        if (pixel_req && !wr_en)
            byte_sel_q <= pixel_addr[1:0];
    end
end

//指针计数以及最后done信号产生
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        cache_wr_ptr <= 'd0;
        input_cache_loaded_done_o <= 'd0;
    end
    else if (input_addr_begin) begin
        cache_wr_ptr <= 'd0;
        input_cache_loaded_done_o <= 'd0;
    end
    else begin
        if (wr_en && !input_cache_loaded_done_o) begin
            input_cache_loaded_done_o <= 'd0;
            if (cache_wr_ptr != input_last_word_addr_i)begin
                cache_wr_ptr <= cache_wr_ptr + 1'b1;
                input_cache_loaded_done_o <= 'd0;
            end
            else begin
                input_cache_loaded_done_o <= 'd1;
                cache_wr_ptr <= 'd0;
            end
        end
    end
end

endmodule