`include "define.sv"

module wb(
    input clk,
    input rst_n,

    input [`ByteWidth] data_i,
    input data_valid_i,

    input [15:0] row,
    input [15:0] col,
    input [`DataBus] channels,

    input addr_init,
    input pool_start,

    //写端口
    output wen,
    output reg [3:0] wstrb,
    output reg [`DataBus] wdata,
    output reg [13:0] waddr,

    output reg write_done
);

//输出总数
wire [`DataBus] output_count;
assign output_count = (row >> 1) * (col >> 1) * channels;
reg finished;//保存最后一次写入完成信号

reg [1:0] ptr;

always@(posedge clk or negedge rst_n)begin
    if(!rst_n || addr_init || pool_start)begin
        ptr <= 'd0;
        waddr <= 'd0;
        write_done <= 'd0;
    end
    else if(wen && {16'd0 , waddr , ptr} == output_count - 1'b1)begin
        write_done <= 1'b1;
    end
    else if(wen)begin
        write_done <= 'd0;
        if(ptr == 2'd3)begin
            ptr <= 'd0;
            waddr <= waddr + 14'd1;
        end
        else begin
            ptr <= ptr + 2'd1;
        end
    end
    else begin
        write_done <= 'd0;
    end
end

always @(*)begin
    wdata = 'd0;
    wstrb = 'd0;
    case(ptr)
        2'd0: begin
            wdata[7:0] = data_i;
            wstrb[0] = 1'b1;
        end
        2'd1: begin
            wdata[15:8] = data_i;
            wstrb[1] = 1'b1;
        end
        2'd2: begin
            wdata[23:16] = data_i;
            wstrb[2] = 1'b1;
        end
        2'd3: begin
            wdata[31:24] = data_i;
            wstrb[3] = 1'b1;
        end
        default: wdata = 'd0;
    endcase
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        finished <= 1'b0;
    else if (addr_init || pool_start)
        finished <= 1'b0;
    else
        finished <= finished | write_done;
end

assign wen = rst_n && !addr_init && !pool_start
             && data_valid_i
             && !write_done && !finished;

endmodule