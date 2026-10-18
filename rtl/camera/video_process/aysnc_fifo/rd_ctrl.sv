module rd_ctrl #(
    parameter DATA_WIDTH = 37,
    parameter ADDR_WIDTH = 8,
    parameter DEPTH = 256
) (
    input rd_clk,
    input rst_n,
    output [ADDR_WIDTH-1:0] rd_addr,
    input [ADDR_WIDTH:0] w2r_ptr_gray,//写指针的格雷码（未同步）
    output reg [ADDR_WIDTH:0] r2w_ptr_gray,
    input rd_en,
    output empty
);
    
reg [ADDR_WIDTH:0] rd_ptr;
(* ASYNC_REG = "TRUE" *) reg [ADDR_WIDTH:0] w2r_ptr_gray_d0;
(* ASYNC_REG = "TRUE" *) reg [ADDR_WIDTH:0] w2r_ptr_gray_d1;
wire [ADDR_WIDTH:0] rd_ptr_inc;

assign rd_ptr_inc = rd_ptr + 1'b1;   

//二级寄存器同步
always @(posedge rd_clk or negedge rst_n) begin
    if (!rst_n) begin
        w2r_ptr_gray_d0 <= 'd0;
        w2r_ptr_gray_d1 <= 'd0;
    end 
    else begin
        w2r_ptr_gray_d0 <= w2r_ptr_gray;
        w2r_ptr_gray_d1 <= w2r_ptr_gray_d0;
    end
end

//读指针增加和格雷码输出要同步
always @(posedge rd_clk or negedge rst_n) begin
    if (!rst_n) begin
        rd_ptr <= 'd0;
        r2w_ptr_gray <= 'd0;
    end 
    else if(rd_en && !empty)begin
        rd_ptr <= rd_ptr_inc;
        r2w_ptr_gray <= rd_ptr_inc ^ (rd_ptr_inc >> 1);
    end
end

assign rd_addr = rd_ptr[ADDR_WIDTH - 1 : 0];
assign empty = (r2w_ptr_gray == w2r_ptr_gray_d1);

endmodule