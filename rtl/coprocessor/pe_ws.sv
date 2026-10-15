`include "define.sv"

//结果从左边输入右边输出，展开的25个数的特征图从上面输入
module pe_ws(
    input clk,
    input rst_n,

    input en_i,//始终拉高
    input valid_data_i,//表示输入数据有效
    output reg valid_data_o,//表示计算结果有效
    input signed [`ByteWidth] up,
    input signed [`DataBus] left,
    output reg signed [`DataBus] right,//输出数据
    output reg signed[`ByteWidth] down,

    input weight_loading_en_i,//本地装载使能，由pe_array比较目标列编号后产生
    input signed [`ByteWidth] weight_i,
    input valid_weight_i,
    output reg valid_weight_o,
    output reg signed [`ByteWidth] weight_o//转发寄存器，与本地weight_reg独立
);

reg signed [`ByteWidth] weight_reg;
wire signed [15:0] product;
wire signed [`DataBus] product_ext;//把乘法结果位数扩展到加法的位数

assign product = weight_reg * up;
assign product_ext = {
    {16{product[15]}},//把符号位重复16次
    product
};
// 只有目标编号匹配且权重有效时，才更新本地计算权重。
always @(posedge clk or negedge rst_n)begin
    if(!rst_n)begin
        weight_reg <= 'd0;
    end
    else if(weight_loading_en_i && valid_weight_i)begin
        weight_reg <= weight_i;
    end
end


always @(posedge clk or negedge rst_n)begin
    if(!rst_n)begin
        valid_weight_o <= 'd0;
        weight_o <= 'd0;
    end
    else begin
        // 不匹配本地编号的权重也必须继续传递，不能被本地装载使能截断。
        valid_weight_o <= valid_weight_i;
        if(valid_weight_i)
            weight_o <= weight_i;
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
