module add(
    input clk,
    input rst_n,
    //axis输入接口
    input  [31:0]  data_i,
    input          last_i,
    input  [3:0]   keep_i,//字节有效信号，同wstrb
    output         ready_i,
    input          valid_i,

    //axis输出接口
    output  [31:0] data_o,
    output         last_o,
    output         valid_o,
    input          ready_o,
    output  [3:0]  keep_o

);

parameter IDLE = 2'b00;
parameter PROC = 2'b01;
parameter WAIT = 2'b10;

reg [1:0] state;
reg [1:0] next_state;

reg [31:0] store_data;
reg store_last;
reg [3:0] store_keep;
reg [31:0] proc_data;

assign data_o = proc_data;
assign ready_i = (state == IDLE);
assign valid_o = (state == WAIT);
assign last_o  = store_last;
assign keep_o  = store_keep;

always @(posedge clk or negedge rst_n) begin 
    if(!rst_n)begin
        state <= IDLE;
    end
    else begin
        state <= next_state;
    end
end

always @(*) begin  
    next_state = state;
    case(state) 
        IDLE: begin
            if(valid_i && ready_i) begin
                next_state = PROC;
            end
        end

        PROC: begin
            next_state = WAIT;
        end

        WAIT: begin
            if(valid_o && ready_o) begin
                next_state = IDLE;
            end
        end

        default: begin
            next_state = IDLE;
        end

    endcase
end

always @(posedge clk or negedge rst_n) begin 
    if(!rst_n)begin
        store_data <= 'd0;
        proc_data <= 'd0;
        store_last <= 'd0;
        store_keep <= 'd0;
    end
    else begin
        case(state) 
            IDLE: begin
                if(valid_i && ready_i) begin
                    store_data <= data_i;
                    store_last <= last_i;
                    store_keep <= keep_i;
                end
            end

            PROC: begin
                proc_data <= store_data + 1;
            end

        endcase
    end
end

endmodule