`include "define.sv"

module bram_arbiter(
    input clk,
    input rst_n,

    //bram接口
    output reg          acc_rd_en,
    output reg  [13:0]  acc_rd_addr,
    input       [`DataBus]  acc_rd_data,
    input               acc_rd_valid,

    output reg          acc_wr_en,
    output reg  [13:0]  acc_wr_addr,
    output reg  [`DataBus]  acc_wr_data,
    output reg  [3:0]   acc_wr_strb,

    //conv接口
    input wire         acc_conv_rd_en,
    input wire  [13:0]  acc_conv_rd_addr,
    output reg  [`DataBus]  acc_conv_rd_data,
    output reg         acc_conv_rd_valid,
    input wire         acc_conv_wr_en,
    input wire  [13:0]  acc_conv_wr_addr,
    input wire  [`DataBus]  acc_conv_wr_data,
    input wire  [3:0]   acc_conv_wr_strb,

    //fc接口
    input wire         acc_fc_rd_en,
    input wire  [13:0]  acc_fc_rd_addr,
    output reg  [`DataBus]  acc_fc_rd_data,
    output reg         acc_fc_rd_valid,
    input wire         acc_fc_wr_en,
    input wire  [13:0]  acc_fc_wr_addr,
    input wire  [`DataBus]  acc_fc_wr_data,
    input wire  [3:0]   acc_fc_wr_strb,

    //脉冲启动信号
    input conv_start,
    input fc_start,

    //脉冲结束信号
    input conv_done,
    input fc_done
);

//锁存启动信号
reg conv_flag;
reg fc_flag;

always @(posedge clk or negedge rst_n)begin
    if(!rst_n)begin
        conv_flag <= 'd0;
        fc_flag <= 'd0;
    end
    else begin
        if(conv_start)begin
            conv_flag <= 1'b1;
        end
        if(conv_done)begin
            conv_flag <= 'd0;
        end
        if(fc_start)begin
            fc_flag <= 1'b1;
        end
        if(fc_done)begin
            fc_flag <= 'd0;
        end
    end
end

always @(*)begin
    // 默认不访问BRAM
    acc_rd_en   = 1'b0;
    acc_rd_addr = 'd0;
    acc_wr_en   = 1'b0;
    acc_wr_addr = 'd0;
    acc_wr_data = 'd0;
    acc_wr_strb = 'd0;

    // 默认不给任何模块返回有效数据
    acc_conv_rd_data  = 'd0;
    acc_conv_rd_valid = 1'b0;
    acc_fc_rd_data    = 'd0;
    acc_fc_rd_valid   = 1'b0;

    if(conv_flag)begin
        acc_rd_en = acc_conv_rd_en;
        acc_rd_addr = acc_conv_rd_addr;
        acc_conv_rd_data = acc_rd_data;
        acc_conv_rd_valid = acc_rd_valid;
        acc_wr_en = acc_conv_wr_en;
        acc_wr_addr = acc_conv_wr_addr;
        acc_wr_data = acc_conv_wr_data;
        acc_wr_strb = acc_conv_wr_strb;
    end

    else if(fc_flag)begin
        acc_rd_en = acc_fc_rd_en;
        acc_rd_addr = acc_fc_rd_addr;
        acc_fc_rd_data = acc_rd_data;
        acc_fc_rd_valid = acc_rd_valid;
        acc_wr_en = acc_fc_wr_en;
        acc_wr_addr = acc_fc_wr_addr;
        acc_wr_data = acc_fc_wr_data;
        acc_wr_strb = acc_fc_wr_strb;
    end
end

endmodule
