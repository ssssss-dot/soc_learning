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

(*ram_style = "block" *) reg [`DataBus] bram [`RAM_SIZE];
reg [14:0] ptr_wr;
reg [14:0] ptr_rd;

//dma从ddr搬运数据到ram
always @(posedge clk or negedge rst_n)begin
    if(!rst_n)begin
        ptr_wr <= 'd0;
    end
    else if(valid_i && ready_i)begin
        if(keep_i[0])begin
            bram[ptr_wr][7:0] = data_i[7:0];
        end
        if(keep_i[1])begin
            bram[ptr_wr][15:8] = data_i[15:8];
        end
        if(keep_i[2])begin
            bram[ptr_Wr][23:16] = data_i[23:16];
        end
        if(keep_i[3])begin
            bram[ptr_wr][31:24] = data_i[31:24];
        end
        if(last_i)begin
            ptr_wr <= 'd0;
        end
        else begin
            ptr_wr <= ptr_wr +1'b1;
        end
    end
end

endmodule