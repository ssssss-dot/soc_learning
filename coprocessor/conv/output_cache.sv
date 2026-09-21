`include "define.sv"

module output_cache(
    input clk,
    input rst_n,

    //bram的写端口
    output                 acc_wr_en,
    output   reg   [13:0]  acc_wr_addr,
    output   reg   [31:0]  acc_wr_data,
    output   reg   [3:0]   acc_wr_strb,

    //输入的输出地址和数据
    input  signed [7:0]  data_i,
    input                data_valid_i,

    input                addr_init,//ctrl的信号，用来重置计数器

    input         [31:0] output_end_i,//结束的字节地址（要做字地址的转化）
    output reg         output_done_o//最后一个数据写回ram了
);

//2b计数器，把四个输入拼成一个字输出
reg [1:0] cnt;
reg valid_word;//每收到 4 个有效 INT8，就产生一个周期的“完整字有效”

assign acc_wr_en = valid_word;

always @(posedge clk or negedge rst_n)begin
    if(!rst_n)begin
        cnt <= 'd0;
        valid_word <= 'd0;
    end
    else if(addr_init)begin
        cnt <= 'd0;
        valid_word <= 'd0;
    end
    else begin
        valid_word <= 'd0;
        if(data_valid_i)begin
            if(cnt == 2'd3)begin
                valid_word <= 1'b1;
                cnt <= 'd0;
            end
            else begin
                cnt <= cnt + 1'b1;
            end
        end
    end
end

//数据拼接
always @(posedge clk or negedge rst_n)begin
    if(!rst_n)begin
        acc_wr_data <= 'd0;
        acc_wr_strb <= 'd0;
    end
    else if(addr_init)begin
        acc_wr_data <= 'd0;
        acc_wr_strb <= 'd0;
    end
    else if(data_valid_i)begin
        case(cnt)
        2'd0:begin
            acc_wr_data[7:0] <= data_i;
            acc_wr_strb <= 4'b0001;
        end
        2'd1:begin
            acc_wr_data[15:8] <= data_i;
            acc_wr_strb <= 4'b0011;
        end
        2'd2:begin
            acc_wr_data[23:16] <= data_i;
            acc_wr_strb <= 4'b0111;
        end
        2'd3:begin
            acc_wr_data[31:24] <= data_i;
            acc_wr_strb <= 4'b1111;
        end
        endcase
    end
end

//地址累增加
always @(posedge clk or negedge rst_n) begin
    if (!rst_n)begin
        acc_wr_addr <= 14'd0;
        output_done_o <= 1'b0;
    end
    else if (addr_init)begin
        acc_wr_addr <= 14'd0;
        output_done_o <= 1'b0;
    end
    else begin
        output_done_o <= 1'b0;
        if (acc_wr_en && ({18'd0, acc_wr_addr} + 32'd1 == (output_end_i >> 2)))begin
            output_done_o <= 1'b1;
            acc_wr_addr <= 14'd0;
        end
        else if (acc_wr_en && ({18'd0, acc_wr_addr} + 32'd1 <= (output_end_i >> 2))) begin
            output_done_o <= 1'b0;
            acc_wr_addr <= acc_wr_addr + 1'b1;
        end
    end
end

endmodule
