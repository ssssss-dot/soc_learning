`include "define.sv"

module fc_input_cache(
    input clk,
    input rst_n,

    input  signed [`DataBus]  input_wr_data,
    input              input_data_valid,

    input addr_init,
    input group_start,//每组要重置指针

    output reg signed [`ByteWidth] features_o,//features从左侧流入，重复逻辑在input_cache里面
    output reg features_valid_o,
    input features_req_i,//拼好权重后指针才开始增加
    input [`DataBus] features_in_i,//输入总特征数

    output reg input_done,
    output feature_last//給pe的是最后一个特征
);


(*ram_style = "block" *) reg signed [`DataBus] input_cache [0:99];

reg signed [`DataBus] rd_data;
reg [6:0] wr_ptr;
reg [6:0] rd_ptr;
reg [1:0] offset;//读出时一拍只能读一个int8
reg [1:0] offset_q;//offset锁存一拍对齐
reg [6:0] rd_ptr_q;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        rd_ptr_q <= 7'd0;
    else if (addr_init || group_start)
        rd_ptr_q <= 7'd0;
    else if (!input_data_valid && features_req_i &&
             ({rd_ptr, offset} < features_in_i))
        rd_ptr_q <= rd_ptr;
end

always @(posedge clk or negedge rst_n)begin
    if(!rst_n)begin
        wr_ptr <= 'd0;
        input_done <= 'd0;
    end
    else if (addr_init) begin
        wr_ptr     <= 7'd0;
        input_done <= 1'b0;
    end
    else if (input_data_valid && !group_start) begin
        if(wr_ptr >= ((features_in_i - 32'd1) >> 2))begin
            wr_ptr <= 'd0;
            input_done <= 1'b1;
        end
        else begin
            wr_ptr <= wr_ptr + 1'b1;
            input_done <= 'd0;
        end
    end
    else begin
        input_done <= 'd0;
    end
end

//bram读写
always @(posedge clk) begin
    if (rst_n && !addr_init && !group_start) begin
        if (input_data_valid) begin
            input_cache[wr_ptr] <= input_wr_data;
        end
        else if (features_req_i && ({rd_ptr, offset} < features_in_i))begin
            rd_data <= input_cache[rd_ptr];
        end
    end
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        rd_ptr <= 7'd0;
        offset <= 2'd0;
        features_valid_o <= 1'b0;
    end
    else if (addr_init || group_start) begin
        rd_ptr <= 7'd0;
        offset <= 2'd0;
        features_valid_o <= 1'b0;
    end
    else if (!input_data_valid && features_req_i && ({rd_ptr, offset} < features_in_i)) begin
        features_valid_o <= 1'b1;
        if (offset == 2'd3) begin
            offset <= 2'd0;
            rd_ptr <= rd_ptr + 1'b1;
        end
        else begin
            offset <= offset + 1'b1;
        end
    end
    else begin
        features_valid_o <= 'd0;
    end
end

//offset延迟一拍
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        offset_q <= 2'd0;
    end
    else if (addr_init || group_start) begin
        offset_q <= 2'd0;
    end
    else if (!input_data_valid &&
             features_req_i &&
             ({rd_ptr, offset} < features_in_i)) begin
        offset_q <= offset;
    end
end

always @(*)begin
    features_o = 'd0;
    case (offset_q)
        2'b00:begin
            features_o = rd_data[7:0];
        end
        2'b01:begin
            features_o = rd_data[15:8];
        end
        2'b10:begin
            features_o = rd_data[23:16];
        end
        2'b11:begin
            features_o = rd_data[31:24];
        end
    endcase
end

assign feature_last = features_valid_o && ({rd_ptr_q, offset_q} == features_in_i - 1'b1);

endmodule
