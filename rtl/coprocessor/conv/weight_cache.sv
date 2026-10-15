`include "define.sv"

module weight_cache(
    input  wire clk,
    input  wire rst_n,

    //每次开始读取一个输入通道的权重时把内部信号清零
    input  wire weight_addr_begin,

    //BRAM返回
    input  wire        weight_data_valid,
    input  wire [`DataBus] weight_data,

    //输出给PE阵列
    output reg signed [7:0] weight_vec [0:15],
    output reg              weight_vec_valid
);

//0-3计数器，记录每一次的权重拼接（每次读取4字节）
reg [1:0] cnt;

//ctrl内部的validweight控制信号由时序逻辑生成，会晚一拍拉高
//如果weight_vec又用来拼接，又用来输出会导致最后一个权重写入时，valid_weight是旧值
reg signed [7:0] assemble_vec [0:15];

integer i;

//一列16个权重做拼接
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        cnt              <= 2'd0;
        weight_vec_valid <= 1'b0;

        for (i = 0; i < 16; i = i + 1) begin
            assemble_vec[i] <= 8'sd0;
            weight_vec[i]   <= 8'sd0;
        end
    end
    else begin
        // 默认拉低，只产生一个周期的脉冲
        weight_vec_valid <= 1'b0;

        if (weight_addr_begin) begin
            cnt <= 2'd0;

            for (i = 0; i < 16; i = i + 1) begin
                assemble_vec[i] <= 8'sd0;
                weight_vec[i]   <= 8'sd0;
            end
        end
        else if (weight_data_valid) begin
            case (cnt)
                2'd0: begin
                    assemble_vec[0] <= weight_data[7:0];
                    assemble_vec[1] <= weight_data[15:8];
                    assemble_vec[2] <= weight_data[23:16];
                    assemble_vec[3] <= weight_data[31:24];

                    cnt <= 2'd1;
                end

                2'd1: begin
                    assemble_vec[4] <= weight_data[7:0];
                    assemble_vec[5] <= weight_data[15:8];
                    assemble_vec[6] <= weight_data[23:16];
                    assemble_vec[7] <= weight_data[31:24];

                    cnt <= 2'd2;
                end

                2'd2: begin
                    assemble_vec[8]  <= weight_data[7:0];
                    assemble_vec[9]  <= weight_data[15:8];
                    assemble_vec[10] <= weight_data[23:16];
                    assemble_vec[11] <= weight_data[31:24];

                    cnt <= 2'd3;
                end

                2'd3: begin
                    // 前12字节已经保存在assemble_vec中
                    for (i = 0; i < 12; i = i + 1)
                        weight_vec[i] <= assemble_vec[i];

                    // 当前周期返回的是最后4字节，直接写入输出
                    weight_vec[12] <= weight_data[7:0];
                    weight_vec[13] <= weight_data[15:8];
                    weight_vec[14] <= weight_data[23:16];
                    weight_vec[15] <= weight_data[31:24];

                    cnt              <= 2'd0;
                    weight_vec_valid <= 1'b1;
                end

                default: begin
                    cnt <= 2'd0;
                end
            endcase
        end
    end
end

endmodule