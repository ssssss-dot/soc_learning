// 灰度流水线与缩放器之间的小缓冲，全部工作在video_clk域。
// 上游停止发送后，gray_picture中仍有3拍像素到达，因此提前预留3个位置。
module video_input_buffer #(
    parameter integer DATA_WIDTH = 8,
    parameter integer DEPTH = 8,
    parameter integer UPSTREAM_LATENCY = 3
)(
    input  wire                  clk,
    input  wire                  rst_n,

    // 采集控制器放行的灰度像素；data_valid_i表示本拍到达一个像素。
    input  wire [DATA_WIDTH-1:0] data_i,
    input  wire                  data_valid_i,
    // 反馈到axis2rgb888，控制新像素是否进入灰度流水线。
    output wire                  video_ready,

    // 缩放器输入：valid和ready同时为1才取走一个像素。
    output wire [DATA_WIDTH-1:0] data_o,
    output wire                  data_valid_o,
    input  wire                  data_ready_i
);

localparam integer PTR_WIDTH = (DEPTH > 1) ? $clog2(DEPTH) : 1;
localparam integer COUNT_WIDTH = $clog2(DEPTH + 1);
localparam integer READY_LIMIT = DEPTH - UPSTREAM_LATENCY;

reg [DATA_WIDTH-1:0] pixel_mem [0:DEPTH-1];
reg [PTR_WIDTH-1:0] write_ptr;
reg [PTR_WIDTH-1:0] read_ptr;
reg [COUNT_WIDTH-1:0] used_count;

wire pop = data_valid_o && data_ready_i;
wire push = rst_n && data_valid_i && ((used_count < DEPTH) || pop);

assign video_ready = rst_n && (used_count < READY_LIMIT);
assign data_valid_o = rst_n && (used_count != 0);
assign data_o = data_valid_o ? pixel_mem[read_ptr] : {DATA_WIDTH{1'b0}};

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        write_ptr <= 'd0;
        read_ptr  <= 'd0;
        used_count <= 'd0;
    end
    else begin
        if (push) begin
            pixel_mem[write_ptr] <= data_i;
            write_ptr <= (write_ptr == DEPTH - 1) ? 'd0 : write_ptr + 1'b1;
        end

        if (pop)
            read_ptr <= (read_ptr == DEPTH - 1) ? 'd0 : read_ptr + 1'b1;

        case ({push, pop})
            2'b10: used_count <= used_count + 1'b1;
            2'b01: used_count <= used_count - 1'b1;
            default: ;
        endcase
    end
end

endmodule
