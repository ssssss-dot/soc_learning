`include "define.sv"

module addr_gen(
    input clk,
    input rst_n,

    input addr_init,

    //控制信号
    input  weight_addr_begin,
    input  input_addr_begin,
    input  bias_addr_begin, 

    input [1:0] rd_sel,
    input rd_req,

    //每次的输出默认起始地址为0
    input [`DataBus] group_bias_base_addr,//特征图输入地址
    input [`DataBus] group_bias_end_addr,
    input [`DataBus] weight_base_addr,//权重输入地址
    input [`DataBus] weight_end_addr,//偏置输入地址
    input [`DataBus] input_base_addr,
    input [`DataBus] input_end_addr,

    //bram读控制和地址
    output  reg        bram_rd_en,
    output  reg [13:0]  bram_rd_addr,

    input input_loading,
    input bias_loading,
    input weight_loading,

    //当前通道对应的数据地址读取完成
    output reg input_done,
    output reg weight_done,
    output reg bias_done
);

//内部地址寄存器
reg [`DataBus] input_addr;
reg [`DataBus] weight_addr;
reg [`DataBus] bias_addr;

localparam RD_INPUT = 2'd0;
localparam RD_WEIGHT = 2'd1;
localparam RD_BIAS = 2'd2;

//bias地址生成
always @(posedge clk or negedge rst_n) begin 
    if(!rst_n)begin
        bias_addr <= '0;
        bias_done <= 1'b0;
    end
    else if (addr_init || bias_addr_begin) begin
        bias_addr <= group_bias_base_addr;
        bias_done <= 1'b0;
    end
    else if (bias_loading && bram_rd_en && (rd_sel == RD_BIAS) && !bias_done) begin

        if ((bias_addr + 32'd4) >= group_bias_end_addr) begin
            bias_done <= 1'b1;
        end
        else begin
            bias_addr <= bias_addr + 32'd4;
        end
    end
end

//weight地址生成
always @(posedge clk or negedge rst_n) begin 
    if (!rst_n) begin
        weight_addr <= '0;
        weight_done <= 1'b0;
    end
    //只有初始化时，重新定位，每组返回重新取bias的时候不用重新定位
    else if (addr_init) begin
        weight_addr <= weight_base_addr;
        weight_done <= 1'b0;
    end
    else if (bram_rd_en &&
             (rd_sel == RD_WEIGHT) &&
             !weight_done) begin
        if ((weight_addr + 32'd4) >= weight_end_addr) begin
            weight_done <= 1'b1;
        end
        else begin
            weight_addr <= weight_addr + 32'd4;
        end
    end
end

//input地址生成
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        input_addr <= '0;
        input_done <= 1'b0;
    end
    else if (addr_init || input_addr_begin) begin
        input_addr <= input_base_addr;
        input_done <= (input_base_addr >= input_end_addr);
    end
    else if (bram_rd_en && (rd_sel == RD_INPUT) && !input_done) begin
        // 当前是不是最后一个32位字
        if ((input_addr + 32'd4) >= input_end_addr) begin
            input_done <= 1'b1;
        end
        else begin
            input_addr <= input_addr + 32'd4;
        end
    end
end

//地址选择
always @(*) begin
    bram_rd_en   = 1'b0;
    bram_rd_addr = 14'd0;

    case (rd_sel)
        RD_INPUT: begin
            bram_rd_en = rd_req && !input_done && input_loading
                               && !addr_init && !input_addr_begin;
            bram_rd_addr = input_addr[15:2];
        end

        RD_WEIGHT: begin
            bram_rd_en = rd_req && !weight_done && weight_loading
                               && !addr_init && !weight_addr_begin;
            bram_rd_addr = weight_addr[15:2];
        end

        RD_BIAS: begin
            bram_rd_en = rd_req && !bias_done && bias_loading
                               && !addr_init && !bias_addr_begin;
            bram_rd_addr = bias_addr[15:2];
        end
    endcase
end

endmodule
