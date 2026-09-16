module result_ram_bank #(
    parameter integer DEPTH = 784,
    parameter integer ADDR_W = 10
)(
    input clk,

    input wr_en,
    input [ADDR_W-1:0] wr_addr,
    input signed [31:0] wr_data,

    input rd_en,
    input [ADDR_W-1:0] rd_addr,
    output reg signed [31:0] rd_data
);

    (* ram_style = "block" *)
    reg signed [31:0] mem [0:DEPTH-1];

    always @(posedge clk) begin
        if (wr_en)
            mem[wr_addr] <= wr_data;

        if (rd_en)
            rd_data <= mem[rd_addr]; // 同步读：时钟沿后得到数据
    end

endmodule