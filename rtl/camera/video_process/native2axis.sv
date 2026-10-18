`include "define.sv"

module native2axis(
    input cam_pclk,
    input rst_n,

    //native侧
    input [`ByteWidth] data_i,
    input data_valid_i,

    output next_data,

    //fifo侧
    output [36:0] fifo_in,
    input axis_ready,
    output reg axis_valid,
    input almost_full
);

assign next_data = rst_n && !almost_full;

reg [`DataBus] axis_data;
wire axis_last;
reg [3:0] axis_keep;

reg [1:0] ptr;
reg [7:0] word_cnt;
reg [23:0] pack_data; 

assign axis_last = (word_cnt == 8'd255);

always @(posedge cam_pclk or negedge rst_n)begin
    if(!rst_n)begin
        ptr <= 'd0;
        axis_valid <= 'd0;
        axis_keep <= 'd0;
    end
    else begin
        if(axis_valid && axis_ready)begin
            axis_valid <= 1'b0;
            axis_keep <= 'd0;
        end
        if(data_valid_i)begin
            if(ptr < 2'd3)begin
                ptr <= ptr + 1'b1;
            end
            else if(ptr == 2'd3)begin
                ptr <= 'd0;
                axis_valid <= 1'b1;
                axis_keep <= 4'b1111;
            end
        end
    end
end

always @(posedge cam_pclk or negedge rst_n) begin
    if (!rst_n)
        word_cnt <= 8'd0;
    else if (axis_valid && axis_ready)
        word_cnt <= word_cnt + 1'b1;
end

always @(posedge cam_pclk or negedge rst_n)begin
    if(!rst_n)begin
        axis_data <= 'd0;
    end
    else if((ptr == 2'd3) && data_valid_i)begin
        axis_data <= {data_i , pack_data};
    end
end

always @(posedge cam_pclk or negedge rst_n)begin
    if(!rst_n)begin
        pack_data <= 'd0;
    end
    else if(data_valid_i)begin
        case(ptr)
            2'd0:begin
                pack_data[7:0] <= data_i;
            end
            2'd1:begin
                pack_data[15:8] <= data_i;
            end
            2'd2:begin
                pack_data[23:16] <= data_i;
            end
            default: pack_data <= pack_data;
    endcase
    end
end

assign fifo_in = {axis_data, axis_keep, axis_last};

endmodule