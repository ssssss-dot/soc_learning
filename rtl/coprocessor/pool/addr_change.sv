`include "define.sv"

module addr_change(
    input clk,
    input rst_n,

    input [`DataBus] idx_left,
    input pool_start,
    input addr_init,
    input addr_valid,

    output reg [13:0] word_addr,
    output reg half_sel,//直接给cmp选半字，读要一拍，在cmp内打拍做对齐

    input wen,//判断写回是否要写bram
    output reg bram_rd_en,
    output addr_ready

);

always @(posedge clk or negedge rst_n)begin
    if(!rst_n || pool_start || addr_init)begin
        word_addr <= 14'd0;
        half_sel <= 1'b0;
        bram_rd_en <= 1'b0;
    end
    else if (!wen) begin
        // 本拍BRAM消费旧请求；
        // 下一拍是否还有请求，由addr_valid决定
        bram_rd_en <= addr_valid;

        if (addr_valid) begin
            word_addr <= idx_left[15:2];
            half_sel  <= idx_left[1];
        end
    end
end

assign addr_ready = rst_n && !pool_start && !addr_init && !wen;

endmodule