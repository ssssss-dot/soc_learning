`include "define.sv"

module bram_for_acc(
    input clk,
    input rst_n,
    //axis输入接口
    input  [`DataBus]  data_i_dma,
    input          last_i_dma,
    input  [3:0]   keep_i_dma,//字节有效信号，同wstrb
    output         ready_i_dma,
    input          valid_i_dma,

    //axis输出接口
    output  reg [`DataBus] data_o_dma,
    output         last_o_dma,
    output  reg       valid_o_dma,
    input          ready_o_dma,
    output   [3:0]  keep_o_dma,

    //dma寄存器告诉ram要搬运多少字节数据回ddr
    input [15:0] ram2ddr_len_dma,
    // 写描述符完成握手后启动 RAM 到 DDR 的数据流
    input ctrl_wr_desc_valid_dma,
    input ctrl_wr_desc_ready_dma,
    input ctrl_rd_desc_valid_dma,
    input ctrl_rd_desc_ready_dma,
    //表示加速器正在读写ram，dma不能搬运
    input write_blocked_dma,

    //DMA配置的偏移量
    input [15:0] rd_bram_offset_dma,
    input [15:0] wr_bram_offset_dma,

    //加速器读BRAM
    input              acc_rd_en,
    input      [13:0]  acc_rd_addr,
    output reg [31:0]  acc_rd_data,
    output reg         acc_rd_valid,

    //加速器写BRAM
    input              acc_wr_en,
    input      [13:0]  acc_wr_addr,
    input      [31:0]  acc_wr_data,
    input      [3:0]   acc_wr_strb
);

(*ram_style = "block" *) reg [`DataBus] bram [`RAM_SIZE];
reg [13:0] ptr_wr_dma;
reg [15:0] rd_count_dma;// 当前输出拍编号，同时作为BRAM读地址
reg [15:0] rd_len_reg_dma;
wire [15:0] total_beats_dma;
wire ram2ddr_start_dma;// 写描述符握手产生的单周期启动信号
wire ddr2ram_start_dma;
wire        bram_rd_en_dma;
wire [13:0] bram_rd_addr_dma;

//双扣ram，每个端口读写的always块内部只能有一个地址
// A口：DMA
wire        dma_write;
wire        port_a_en;
wire [13:0] port_a_addr;
wire [3:0]  port_a_we;

assign dma_write  = valid_i_dma && ready_i_dma;
assign port_a_en  = dma_write || bram_rd_en_dma;
assign port_a_addr = dma_write ? ptr_wr_dma : bram_rd_addr_dma;
assign port_a_we  = dma_write ? keep_i_dma : 4'b0000;

// B口：ACC，即仲裁后的 Conv/FC
wire        port_b_en;
wire [13:0] port_b_addr;
wire [3:0]  port_b_we;

assign port_b_en   = acc_wr_en || acc_rd_en;
assign port_b_addr = acc_wr_en ? acc_wr_addr : acc_rd_addr;
assign port_b_we   = acc_wr_en ? acc_wr_strb : 4'b0000;

assign bram_rd_en_dma =
    ram2ddr_start_dma ||
    (valid_o_dma && ready_o_dma && !last_o_dma);

assign bram_rd_addr_dma =
    ram2ddr_start_dma
        ?  wr_bram_offset_dma[15:2]
        : rd_count_dma[13:0] + 14'd1;

assign ram2ddr_start_dma = ctrl_wr_desc_valid_dma && ctrl_wr_desc_ready_dma;
assign ddr2ram_start_dma = ctrl_rd_desc_valid_dma && ctrl_rd_desc_ready_dma;

assign total_beats_dma = ({1'b0, rd_len_reg_dma} + 17'd3) >> 2;//dma一拍搬运一个字，len的单位是字节，除以4做转换，判断last什么时候拉高，同时扩展一位防止溢出
assign last_o_dma = valid_o_dma && (total_beats_dma != 16'd0) &&
    (
        {1'b0, rd_count_dma} ==
        (
            {3'b000, wr_bram_offset_dma[15:2]} +
            {1'b0, total_beats_dma} -
            17'd1
        )
    );//last_o_dma以绝对地址判断，总拍数（加了多少次）再加上初始偏移

assign keep_o_dma =
    !last_o_dma                  ? 4'b1111 :
    rd_len_reg_dma[1:0] == 2'd0  ? 4'b1111 :
    rd_len_reg_dma[1:0] == 2'd1  ? 4'b0001 :
    rd_len_reg_dma[1:0] == 2'd2  ? 4'b0011 :
                               4'b0111;//只有最后一拍要做字节选择

//及时锁存len
always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        rd_len_reg_dma <= '0;
    else if (ram2ddr_start_dma)
        rd_len_reg_dma <= ram2ddr_len_dma;
end

assign ready_i_dma = !write_blocked_dma && !bram_rd_en_dma;

//bram不能放在有复位的always块中
//dma从ddr搬运数据到ram
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        ptr_wr_dma <= 14'd0;
    end
    else if (ddr2ram_start_dma) begin
        // DMA读DDR、写BRAM，使用rd方向的BRAM目标偏移
        // offset单位是字节，BRAM地址单位是32位字
        ptr_wr_dma <= rd_bram_offset_dma[15:2];
    end
    else if (valid_i_dma && ready_i_dma) begin
        if (last_i_dma)
            ptr_wr_dma <= 14'd0;
        else
            ptr_wr_dma <= ptr_wr_dma + 14'd1;
    end
end

// BRAM A口：DMA读写，共用port_a_addr
always @(posedge clk) begin
    if (port_a_en) begin
        if (port_a_we[0])
            bram[port_a_addr][7:0] <= data_i_dma[7:0];

        if (port_a_we[1])
            bram[port_a_addr][15:8] <= data_i_dma[15:8];

        if (port_a_we[2])
            bram[port_a_addr][23:16] <= data_i_dma[23:16];

        if (port_a_we[3])
            bram[port_a_addr][31:24] <= data_i_dma[31:24];

        data_o_dma <= bram[port_a_addr];
    end
end

//dma把处理完的数据从ram搬回ddr
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        rd_count_dma <= '0;
        valid_o_dma  <= 1'b0;
    end
    else if (ram2ddr_start_dma) begin
        //提前准备第一拍,防止握手时同时更新data_o_dma导致采样出问题
        rd_count_dma <= {2'b00 , wr_bram_offset_dma[15:2]};
        valid_o_dma  <= (ram2ddr_len_dma != 16'd0);
    end
    else if (valid_o_dma && ready_o_dma) begin
        if (last_o_dma) begin
            //当前最后一拍已经传给DMA
            rd_count_dma <= '0;
            valid_o_dma  <= 1'b0;
        end
        else begin
            //当前拍已经传完，准备下一拍，keep_o_dma会告诉dma，由dma筛选有效字节
            rd_count_dma <= rd_count_dma + 16'd1;
        end
    end
end

//acc读写ram,注意读写互斥
// BRAM B口：ACC读写，共用port_b_addr
always @(posedge clk) begin
    if (port_b_en) begin
        if (port_b_we[0])
            bram[port_b_addr][7:0] <= acc_wr_data[7:0];

        if (port_b_we[1])
            bram[port_b_addr][15:8] <= acc_wr_data[15:8];

        if (port_b_we[2])
            bram[port_b_addr][23:16] <= acc_wr_data[23:16];

        if (port_b_we[3])
            bram[port_b_addr][31:24] <= acc_wr_data[31:24];

        acc_rd_data <= bram[port_b_addr];
    end
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        acc_rd_valid <= 1'b0;
    else
        acc_rd_valid <= acc_rd_en && !acc_wr_en;
end

endmodule
