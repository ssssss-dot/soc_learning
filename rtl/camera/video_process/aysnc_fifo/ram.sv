module ram #(
  parameter DATA_WIDTH = 37,
  parameter ADDR_WIDTH = 8,
  parameter DEPTH = 256
)(
  // 写端口 (Write Port)
  input                   wr_clk,
  input                   wr_en,
  input  [ADDR_WIDTH-1:0] wr_addr,
  input  [DATA_WIDTH-1:0] wr_data,

  // 读端口 (Read Port)
  input  rd_clk,
  input  rst_n,
  input                   rd_en,
  input  [ADDR_WIDTH-1:0] rd_addr,
  output reg [DATA_WIDTH-1:0] rd_data,
  output reg rd_valid,

  input full,
  input empty
);

(* ram_style = "block" *) reg [DATA_WIDTH - 1 : 0] mem [0:DEPTH-1];


//写逻辑
always @(posedge wr_clk) begin
    if (wr_en && !full) begin
        mem[wr_addr] <= wr_data;
    end
end

//读逻辑
always @(posedge rd_clk) begin
    if (rd_en && !empty) begin
        rd_data <= mem[rd_addr];
    end
end

always @(posedge rd_clk or negedge rst_n) begin
    if (!rst_n)
        rd_valid <= 1'b0;
    else
        rd_valid <= rd_en && !empty;
end

endmodule