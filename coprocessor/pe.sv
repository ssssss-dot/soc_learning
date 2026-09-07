`include "define.sv"

module pe(
    input clk,
    input rst_n,

    input en,//cpu通过配置寄存器拉高使能信号
    input valid_i,//表示输入数据有效
    output reg valid_o,//表示计算结果有效
    input clear,//mac清除信号
    input signed [`ByteWidth] up,
    input signed [`ByteWidth] left,
    output reg signed [`ByteWidth] right,
    output reg signed[`ByteWidth] down,
    output signed  [`DataBus] acc_out//把一次mac算完的结果输出
);

reg signed [`DataBus] acc_reg;//os模式，把每个周期算的数保留下来
wire signed [15:0] product;//乘法结果
wire signed [`DataBus] product_ext;//把乘法结果位数扩展到加法的位数

assign product = up * left;
assign product_ext = {
    {16{product[15]}},//把符号位重复16次
    product
};
assign acc_out = acc_reg;

always @(posedge clk or negedge rst_n)begin
    if(!rst_n)begin
        acc_reg <= 'd0;
        right <= 'd0;
        down <= 'd0;
        valid_o <= 'd0;
    end
    else if (en)begin
        right <= left;
        down <= up;
        valid_o <= valid_i;
        if (clear) begin
            acc_reg <= valid_i ? product_ext : '0;
        end
        else if (valid_i) begin
            acc_reg <= acc_reg + product_ext;
        end
    end
    else begin
        valid_o <= 'd0;
    end
end

endmodule