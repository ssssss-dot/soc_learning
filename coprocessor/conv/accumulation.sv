`include "define.sv"

module accumulation(
    input clk,
    input rst_n,

    //输出的结果
    input signed [`DataBus] result_i [0:15],
    input [15:0] valid_result_i,

    output [`DataBus] result_o
);

endmodule
