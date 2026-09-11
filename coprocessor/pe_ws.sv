`include "define.sv"

//结果从左边输入右边输出，展开的25个数的特征图从上面输入
module pe_ws(
    input clk,
    input rst_n,

    input en_i,//cpu通过配置寄存器拉高使能信号
    output reg en_o,//让en信号跟随流水线流动
    input valid_data_i,//表示输入数据有效
    output reg valid_data_o,//表示计算结果有效
    input signed [`ByteWidth] up,
    input signed [`DataBus] left,
    output reg signed [`DataBus] right,//输出数据
    output reg signed[`ByteWidth] down,

    input signed [`ByteWidth] weight_i,
    input valid_weight
);

reg signed [`ByteWidth] weight_reg;
wire signed [15:0] product;
wire signed [`DataBus] product_ext;//把乘法结果位数扩展到加法的位数

assign product = weight_reg * up;
assign product_ext = {
    {16{product[15]}},//把符号位重复16次
    product
};

//加载权重
always @(posedge clk or negedge rst_n)begin
    if(!rst_n)begin
        weight_reg <= 'd0;
    end
    else if(valid_weight)begin
        weight_reg <= weight_i;
    end
end

//使能信号流水线
always @(posedge clk or negedge rst_n)begin
    if(!rst_n)begin
        en_o <= 'd0;
    end
    else begin
        en_o <= en_i;
    end
end

//开始计算
always @(posedge clk or negedge rst_n)begin
    if(!rst_n)begin
        right <= 'd0;
        down <= 'd0;
        valid_data_o <= 'd0;
    end
    else if (en_i)begin
        valid_data_o <= valid_data_i;
        if(valid_data_i)begin
            down <= up;
            right <= product_ext + left;
        end
    end
    else begin
        valid_data_o <= 'd0;
    end
end

endmodule