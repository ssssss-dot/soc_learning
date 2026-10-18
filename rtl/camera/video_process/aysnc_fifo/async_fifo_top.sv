module async_fifo #(
  parameter DATA_WIDTH = 37,
  parameter ADDR_WIDTH = 8,
  parameter DEPTH = 256
) (
    input rd_clk,
    input wr_clk,
    input rst_n,
    input  [DATA_WIDTH-1:0] wr_data,
    output [DATA_WIDTH-1:0] rd_data,
    input wr_en,
    input rd_en,
    output empty,
    output full,
    output almost_full,
    output rd_valid

);
    
wire [ADDR_WIDTH-1 : 0] wr_addr;
wire [ADDR_WIDTH-1 : 0] rd_addr;
wire [ADDR_WIDTH:0] r2w_ptr_gray;
wire [ADDR_WIDTH:0] w2r_ptr_gray;

ram #(
    .DATA_WIDTH(DATA_WIDTH),
    .ADDR_WIDTH(ADDR_WIDTH),
    .DEPTH(DEPTH)
) ram_inst(
    .rst_n(rst_n),
    .wr_clk(wr_clk),
    .wr_en(wr_en),
    .wr_addr(wr_addr),
    .wr_data(wr_data),
    .rd_clk(rd_clk),
    .rd_en(rd_en),
    .rd_addr(rd_addr),
    .rd_data(rd_data),
    .full(full),
    .empty(empty),
    .rd_valid(rd_valid)
);

wr_ctrl #(
    .DATA_WIDTH(DATA_WIDTH),
    .ADDR_WIDTH(ADDR_WIDTH),
    .DEPTH(DEPTH)
) wr_ctrl_inst(
    .wr_clk(wr_clk),
    .rst_n(rst_n),
    .wr_addr(wr_addr),
    .r2w_ptr_gray(r2w_ptr_gray),
    .w2r_ptr_gray(w2r_ptr_gray),
    .wr_en(wr_en),
    .full(full),
    .almost_full(almost_full)
);

rd_ctrl #(
    .DATA_WIDTH(DATA_WIDTH),
    .ADDR_WIDTH(ADDR_WIDTH),
    .DEPTH(DEPTH)
) rd_ctrl_inst(
    .rd_clk(rd_clk),
    .rst_n(rst_n),
    .rd_addr(rd_addr),
    .w2r_ptr_gray(w2r_ptr_gray),
    .r2w_ptr_gray(r2w_ptr_gray),
    .rd_en(rd_en),
    .empty(empty)
);

endmodule