`include "define.sv"

module bram_for_acc(
    input clk,
    input rst_n,
    //axis输入接口
    input  [`DataBus]  data_i,
    input          last_i,
    input  [3:0]   keep_i,//字节有效信号，同wstrb
    output         ready_i,
    input          valid_i,

    //axis输出接口
    output  reg [`DataBus] data_o,
    output         last_o,
    output  reg       valid_o,
    input          ready_o,
    output   [3:0]  keep_o,

    //dma寄存器告诉ram要搬运多少字节数据回ddr
    input [15:0] ram2ddr_len,
    // 写描述符完成握手后启动 RAM 到 DDR 的数据流
    input ctrl_wr_desc_valid,
    input ctrl_wr_desc_ready,

    //表示加速器正在读写ram，dma不能搬运
    input write_blocked

);

(*ram_style = "block" *) reg [`DataBus] bram [`RAM_SIZE];
reg [13:0] ptr_wr;
reg [15:0] rd_count;// 当前输出拍编号，同时作为BRAM读地址
reg [15:0] rd_len_reg;
wire [15:0] total_beats;
wire ram2ddr_start;// 写描述符握手产生的单周期启动信号

assign ram2ddr_start = ctrl_wr_desc_valid && ctrl_wr_desc_ready;
assign total_beats = ({1'b0, rd_len_reg} + 17'd3) >> 2;//dma一拍搬运一个字，len的单位是字节，除以4做转换，判断last什么时候拉高，同时扩展一位防止溢出
assign last_o = valid_o && (rd_count == total_beats - 16'd1);

assign keep_o =
    !last_o                  ? 4'b1111 :
    rd_len_reg[1:0] == 2'd0  ? 4'b1111 :
    rd_len_reg[1:0] == 2'd1  ? 4'b0001 :
    rd_len_reg[1:0] == 2'd2  ? 4'b0011 :
                               4'b0111;//只有最后一拍要做字节选择

//及时锁存len
always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        rd_len_reg <= '0;
    else if (ram2ddr_start)
        rd_len_reg <= ram2ddr_len;
end

assign ready_i = !write_blocked;

//bram不能放在有复位的always块中
//dma从ddr搬运数据到ram
always @(posedge clk or negedge rst_n)begin
    if(!rst_n)begin
        ptr_wr <= 'd0;
    end
    else if(valid_i && ready_i)begin
        if(last_i)begin
            ptr_wr <= 'd0;
        end
        else begin
            ptr_wr <= ptr_wr +1'b1;
        end
    end
end
always @(posedge clk) begin
    if(valid_i && ready_i)begin
        if(keep_i[0])begin
            bram[ptr_wr][7:0] <= data_i[7:0];
        end
        if(keep_i[1])begin
            bram[ptr_wr][15:8] <= data_i[15:8];
        end
        if(keep_i[2])begin
            bram[ptr_wr][23:16] <= data_i[23:16];
        end
        if(keep_i[3])begin
            bram[ptr_wr][31:24] <= data_i[31:24];
    end
    end
end

//dma把处理完的数据从ram搬回ddr
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        rd_count <= '0;
        valid_o  <= 1'b0;
    end
    else if (ram2ddr_start) begin
        //提前准备第一拍,防止握手时同时更新data_o导致采样出问题
        rd_count <= '0;
        valid_o  <= (ram2ddr_len != 16'd0);
    end
    else if (valid_o && ready_o) begin
        if (last_o) begin
            //当前最后一拍已经传给DMA
            rd_count <= '0;
            valid_o  <= 1'b0;
        end
        else begin
            //当前拍已经传完，准备下一拍，keep_o会告诉dma，由dma筛选有效字节
            rd_count <= rd_count + 16'd1;
        end
    end
end

always @(posedge clk) begin
    if (ram2ddr_start) begin
        data_o <= bram[14'd0];
    end
    else if (valid_o && ready_o && !last_o) begin
        data_o <= bram[rd_count[13:0] + 14'd1];
    end
end

endmodule
