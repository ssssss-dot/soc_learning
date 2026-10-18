module wr_ctrl #(
    parameter DATA_WIDTH = 37,
    parameter ADDR_WIDTH = 8,
    parameter DEPTH = 256
) (
    input wr_clk,
    input rst_n,
    output [ADDR_WIDTH-1:0] wr_addr,
    input [ADDR_WIDTH:0] r2w_ptr_gray,
    output reg [ADDR_WIDTH:0] w2r_ptr_gray,
    input wr_en,
    output full,
    output almost_full
);
    
reg [ADDR_WIDTH:0] wr_ptr;
(* ASYNC_REG = "TRUE" *) reg [ADDR_WIDTH:0] r2w_ptr_gray_d0;
(* ASYNC_REG = "TRUE" *) reg [ADDR_WIDTH:0] r2w_ptr_gray_d1;
reg [ADDR_WIDTH:0] rd_ptr_bin_sync;
wire [ADDR_WIDTH:0] wr_ptr_inc;
assign wr_ptr_inc = wr_ptr + 1;

wire [ADDR_WIDTH:0] used_words;
assign used_words = wr_ptr_inc - rd_ptr_bin_sync;

//格雷码转二进制
integer i;

always @(*) begin
    rd_ptr_bin_sync[ADDR_WIDTH] =
        r2w_ptr_gray_d1[ADDR_WIDTH];

    for (i = ADDR_WIDTH - 1; i >= 0; i = i - 1) begin
        rd_ptr_bin_sync[i] =
            rd_ptr_bin_sync[i+1] ^ r2w_ptr_gray_d1[i];
    end
end

assign almost_full = (used_words >= DEPTH - 4);

//二级寄存器同步
always @(posedge wr_clk or negedge rst_n) begin
    if (!rst_n) begin
        r2w_ptr_gray_d0 <= 'd0;
        r2w_ptr_gray_d1 <= 'd0;
    end 
    else begin
        r2w_ptr_gray_d0 <= r2w_ptr_gray;
        r2w_ptr_gray_d1 <= r2w_ptr_gray_d0;
    end
end

//格雷码输出和写指针同步
always @(posedge wr_clk or negedge rst_n) begin
    if (!rst_n) begin
        wr_ptr <= 'd0;
        w2r_ptr_gray <= 'd0;
    end 
    else if(wr_en && !full)begin
        wr_ptr <= wr_ptr_inc;
        w2r_ptr_gray <= wr_ptr_inc ^ (wr_ptr_inc >> 1);
    end
end

assign wr_addr = wr_ptr[ADDR_WIDTH - 1 : 0];
assign full = (~r2w_ptr_gray_d1[ADDR_WIDTH-1] == w2r_ptr_gray[ADDR_WIDTH-1]) && (~r2w_ptr_gray_d1[ADDR_WIDTH] == w2r_ptr_gray[ADDR_WIDTH]) && (r2w_ptr_gray_d1[ADDR_WIDTH-2 : 0] == w2r_ptr_gray[ADDR_WIDTH-2 : 0]);

endmodule