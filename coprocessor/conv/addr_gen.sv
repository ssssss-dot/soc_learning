`include "define.sv"

module addr_gen(
    input clk,
    input rst_n,

    input addr_init,
    output addr_init_done,

    //控制信号
    input  weight_addr_begin,
    input  input_addr_begin,
    input  bias_addr_begin, 

    input [1:0] rd_sel;

    //bram读请求
    input bram_req_bias,
    input bram_req_input,
    input bram_req_weight,

    //每次的输出默认起始地址为0
    input [13:0] bias_base_addr,//特征图输入地址
    input [`DataBus] bias_end_addr,
    input [`DataBus] weight_base_addr,//权重输入地址
    input [`DataBus] weight_end_addr,//偏置输入地址
    input [`DataBus] input_base_addr,
    input [`DataBus] input_end_addr
);

//三个地址计数器
reg [`DataBus] bias_cnt;
reg [`DataBus] weight_cnt;
reg [`DataBus] input_cnt;

localparam RD_INPUT = 2'd0;
localparam RD_WEIGHT = 2'd1;
localparam RD_BIAS = 2'd2;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        input_addr  <= '0;
        weight_addr <= '0;
        bias_addr   <= '0;
    end
    else if (addr_init) begin
        input_addr  <= input_base_addr;
        weight_addr <= weight_base_addr;
        bias_addr   <= bias_base_addr;
    end
    else begin
        if (rd_fire && rd_sel == RD_INPUT)
            input_addr <= input_addr + 32'd4;

        if (rd_fire && rd_sel == RD_WEIGHT)
            weight_addr <= weight_addr + 32'd4;

        if (rd_fire && rd_sel == RD_BIAS)
            bias_addr <= bias_addr + 14'd1;
    end
end
endmodule
