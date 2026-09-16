`include "define.sv"

module addr_gen(
    input clk,
    input rst_n,

    //第一次的输出默认为0地址
    input [13:0] bias_base_addr,//特征图输入地址
    input [`DataBus] bias_end_addr,
    input [`DataBus] weight_base_addr,//权重输入地址
    input [`DataBus] weight_end_addr,//偏置输入地址
    input [`DataBus] input_base_addr,
    input [`DataBus] input_end_addr
);
endmodule
