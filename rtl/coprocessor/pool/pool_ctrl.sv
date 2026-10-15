`include "define.sv"

module pool_ctrl(
    input clk,
    input rst_n,

    input pool_start,
    input [15:0] row,
    input [15:0] col,
    input [`DataBus] channels,
    input write_done,

    output reg busy,
    output reg done,
    output reg error,

    output reg cmp_start,
    output reg addr_init
);

localparam IDLE = 2'd0;
localparam START = 2'd1;
localparam CMP = 2'd2;
localparam DONE = 2'd3;

reg [1:0] state;
reg [1:0] next_state;

always @(posedge clk or negedge rst_n)begin
    if(!rst_n)begin
        state <= IDLE;
    end
    else begin
        state <= next_state;
    end
end

always @(*)begin 
    next_state = state;
    case(state) 
        IDLE:begin
            if (pool_start) begin
                next_state = START;
            end
        end
        START:begin
            next_state = CMP;
        end
        CMP:begin
            if (write_done) begin
                next_state = DONE;
            end
        end
        DONE:begin
            next_state = IDLE;
        end
    endcase
end

always @(posedge clk or negedge rst_n)begin 
    if(!rst_n)begin
        cmp_start <= 1'b0;
        addr_init <= 1'b0;
        busy <= 1'b0;
        done <= 1'b0;
        error <= 1'b0;
    end
    else begin
        cmp_start <= 1'b0;
        addr_init <= 1'b0;
        done <= 1'b0;
        case(state) 
            IDLE:begin
                if(pool_start)begin
                    busy <= 1'b1;
                    addr_init <= 1'b1;
                    error <= 1'b0;
                end
            end
            START:begin
                cmp_start <= 1'b1;
            end
            CMP:begin
                if (write_done) begin
                    done <= 1'b1;
                    busy <= 1'b0;
                end
            end
        endcase
    end
end

endmodule