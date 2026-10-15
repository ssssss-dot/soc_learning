`include "define.sv"

//32个32位的寄存器，三个地址都在0-31之间，根据地址选择寄存器
module reg_file(
    input wire clk,
	input wire rst_n,

	//w
	input wire				we,
	input wire[`RegAddrBus] waddr, //译码得到
	input wire[`RegBus]	 	wdata,//alu模块计算后需要写回的数据

	//r1
	input wire				re1,
	input wire[`RegAddrBus] raddr1,//译码得到
	output reg[`RegBus]		rdata1,

	//r2
	input wire				re2,
	input wire[`RegAddrBus] raddr2,//译码得到
	output reg[`RegBus]	 	rdata2
);

reg [`RegBus] regs[(1 << `RegAddrWidth) - 1 : 0];

//仿真时把0x的reg赋值为0
initial begin
	regs[0] = `RegWidth'h0;
end

//低电平复位
//写寄存器
always @ (posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        regs[0] <= `ZeroWord;
    end 
    else begin
        if (we && waddr != `RegAddrWidth'h0)
            regs[waddr] <= wdata;
    end
end

//读端口1
always @(*) begin
    if (!rst_n || !re1 || (raddr1 == 5'd0)) begin
        rdata1 = `ZeroWord;
    end
    else if (we && (raddr1 == waddr)) begin
        rdata1 = wdata;
    end
    else begin
        rdata1 = regs[raddr1];
    end
end

//读端口2
always @(*) begin
    if (!rst_n || !re2 || (raddr2 == 5'd0)) begin
        rdata2 = `ZeroWord;
    end
    else if (we && (raddr2 == waddr)) begin
        rdata2 = wdata;
    end
    else begin
        rdata2 = regs[raddr2];
    end
end

endmodule