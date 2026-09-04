`include "define.sv"

module add(
    input clk,
    input rst_n,
    //axis输入接口
    input  [31:0]  data_i,
    input          last_i,
    input  [3:0]   keep_i,//字节有效信号，同wstrb
    output         ready_i,
    input          valid_i,

    //axis输出接口
    output  [31:0] data_o,
    output         last_o,
    output         valid_o,
    input          ready_o,
    output  [3:0]  keep_o

);
endmodule