`include "define.sv"

module weight_cache(
    input clk,
    input rst_n,

    input  signed [`DataBus]  bias_wr_data,
    input                     bias_data_valid,

    input addr_init,
    input bias_addr_begin,//每组要重置指针
    output features_req_o,

    output  signed [`DataBus] bias_o [0:15],//features从左侧流入，重复逻辑在bias_cache里面
    output reg bias_valid_o,
    input [4:0] group_bias_count_i,

    output reg bias_done
);

endmodule