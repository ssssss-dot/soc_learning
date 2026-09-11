`include "define.sv"

//数据从左边输入
module pe_os(
    input clk,
    input rst_n,

    input last_i,//通过全局计数器产生的最后一次计算信号，计算完成后把reg复位
    output reg last_o,//last信号跟随流水线流动
    input en_i,//cpu通过配置寄存器拉高使能信号
    output reg en_o,//让en信号跟随流水线流动
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
        en_o <= 'd0;
        last_o <= 'd0;
    end
    else if(valid_i) begin
        en_o <= en_i;
        last_o <= last_i;
    end
end

always @(posedge clk or negedge rst_n)begin
    if(!rst_n)begin
        acc_reg <= 'd0;
        right <= 'd0;
        down <= 'd0;
        valid_o <= 'd0;
    end
    else if (en_i)begin
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