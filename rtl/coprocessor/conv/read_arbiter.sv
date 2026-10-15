module read_arbiter(
    input clk,
    input rst_n,

    //BRAM读请求及其数据来源
    input       acc_rd_en,
    input [1:0] rd_sel,

    //BRAM同步读返回有效
    input acc_rd_valid,

    //返回数据对应的接收模块
    output input_data_valid,
    output weight_data_valid,
    output bias_data_valid
);

localparam RD_INPUT  = 2'd0;
localparam RD_WEIGHT = 2'd1;
localparam RD_BIAS   = 2'd2;

//BRAM读取延迟为一拍，请求类型也延迟一拍与返回数据对齐。
reg [1:0] rd_sel_d;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        rd_sel_d <= RD_INPUT;
    end
    else if (acc_rd_en) begin
        rd_sel_d <= rd_sel;
    end
end

assign input_data_valid =
    acc_rd_valid && (rd_sel_d == RD_INPUT);

assign weight_data_valid =
    acc_rd_valid && (rd_sel_d == RD_WEIGHT);

assign bias_data_valid =
    acc_rd_valid && (rd_sel_d == RD_BIAS);

endmodule
