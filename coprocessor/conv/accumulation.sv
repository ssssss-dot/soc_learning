`include "define.sv"

module accumulation(
    input clk,
    input rst_n,

    //ctrl给的信号
    //重置信号
    input wire        addr_init_i,
    input wire        im2col_start_i,

    //计算每个输出通道有多少个像素
    input wire [15:0] input_width_i,
    input wire [15:0] input_height_i,

    //指定有效的输出通道数。Conv1 用前 6 个 bank，Conv2 用 16 个；也用于判断最后一个有效 PE 行和最后一个 bias
    input wire [15:0] output_channels_i,

    //当前是第几个输入通道。等于 0 时，PE 结果直接写 RAM；大于 0 时，先读旧部分和、相加再写回。Conv2 会依次是 0～5
    input wire [15:0] channel_cnt_i,

    input bias_addr_begin_i,//输入的bias地址开始增加

    //输出的结果
    input signed [`DataBus] result_i [0:15],
    input [15:0] valid_result_i,

    // BRAM 返回的 bias
    input wire signed [`DataBus] bias_data_i,
    input wire                   bias_data_valid_i,

    // 给 conv_ctrl
    output reg channel_done_o,
    output reg bias_loaded_done_o,

    output reg [`DataBus] result_o,//加了偏置的int32输出
    output reg        result_valid_o
);

wire [10:0] output_size;//一个通道的输出图像数量
assign output_size = (input_width_i - 4) * (input_height_i - 4);

wire signed [`DataBus] bank_rd_data [0:15];//接到ram块的读数据部分，一个数组接一个通道
//ram读出要一拍，所以要把这两个需要的打拍同步，从16个ram里面读数据的索引要打拍
reg [4:0] scan_bank_q;
reg       scan_valid_q;

//判断是不是最后一个pe的结果写入了ram，判断channeldone
wire [15:0] bank_last_write;

//存储bias的寄存器
reg signed [`DataBus] bias_reg [0:15];
reg [4:0] bias_idx;//偏置对应通道数的索引

reg       scan_active;      //表示现在是否正在从结果RAM逐个读取像素并输出(bias加载完成），读和加法加起来占一拍
reg [4:0] scan_bank;        //当前输出通道：0～15
reg [9:0] scan_pixel;       //当前通道的像素地址：0～783

always @(posedge clk or negedge rst_n)begin
    if(!rst_n)begin
        scan_active <= 'd0;
    end
    else if(bias_loaded_done_o)begin
        scan_active <= 1'b1;
    end
    //用计数器判断所有通道的每个像素都输出完成
    else if (scan_active &&
            ({11'd0, scan_bank} + 16'd1 == output_channels_i) &&
            ({1'b0, scan_pixel} + 11'd1 == output_size)) begin
        scan_active <= 1'b0;
    end
end

//像素，通道计数器计数逻辑
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        scan_bank  <= 'd0;
        scan_pixel <= 'd0;
    end
    else if (addr_init_i || bias_loaded_done_o) begin
        scan_bank  <= 'd0;
        scan_pixel <= 'd0;
    end
    else if (scan_active) begin
        if ({1'b0, scan_pixel} + 11'd1 == output_size) begin
            scan_pixel <= 'd0;
            if ({11'd0, scan_bank} + 16'd1 < output_channels_i)
                scan_bank <= scan_bank + 5'd1;
        end
        else begin
            scan_pixel <= scan_pixel + 10'd1;
        end
    end
end

//bias存入逻辑
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        bias_idx <= '0;
        bias_loaded_done_o <= 1'b0;
    end else begin
        bias_loaded_done_o <= 1'b0;  // 默认拉低，完成时只脉冲一拍

        if (bias_addr_begin_i) begin
            bias_idx <= '0;
        end 
        else if (bias_data_valid_i && bias_idx < output_channels_i) begin
            bias_reg[bias_idx] <= bias_data_i;
            bias_idx <= bias_idx + 5'd1;

            if (bias_idx + 16'd1 == output_channels_i)
                bias_loaded_done_o <= 1'b1;
        end
    end
end

//每个PE行对应一个输出通道的结果存储 bank。
genvar bank_idx;
generate
    for (bank_idx = 0; bank_idx < 16; bank_idx = bank_idx + 1) begin : gen_result_bank
        reg [10:0] wr_idx;//每个ram块的地址索引
        //输入通道为0的时候不用累加，直接存入ram
        wire row_valid = (bank_idx < output_channels_i) && valid_result_i[bank_idx];
        wire first_channel = (channel_cnt_i == 16'd0);

        //把valid打拍，与后面的写新数据同步
        reg rmw_valid_q;
        always @(posedge clk or negedge rst_n) begin
            if (!rst_n)begin
                rmw_valid_q <= 1'b0;
            end
            else if (addr_init_i || im2col_start_i)begin
                rmw_valid_q <= 1'b0;
            end
            else begin
                rmw_valid_q <= !first_channel && row_valid;
            end
        end

        wire bank_wr_en = first_channel ? row_valid : rmw_valid_q;
        wire scan_hit;//表示当前扫描到当前通道
        assign scan_hit = scan_active && (scan_bank == bank_idx);

        // 每收到本行一个有效PE结果，进入下一个像素地址
        always @(posedge clk or negedge rst_n) begin
            if (!rst_n)
                wr_idx <= 'd0;
            else if (addr_init_i || im2col_start_i)
                wr_idx <= 'd0;
            else if (row_valid)
                wr_idx <= wr_idx + 11'd1;
        end

        wire signed [`DataBus] wr_result;//根据写入通道是第几个判断写数据是直接写还是累加
        wire signed [`DataBus] ram_old_data;//ram内部的旧数据
        reg signed [`DataBus] wr_pending_result;//新输入的result_i锁存
        reg [9:0] wr_pending_addr;
        always @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin
                wr_pending_result <= '0;
                wr_pending_addr   <= '0;
            end
            else if (!first_channel && row_valid) begin
                wr_pending_result <= result_i[bank_idx];
                wr_pending_addr   <= wr_idx[9:0];
            end
        end

        //锁存新进入的result_i，读olddata要一拍，resultdata锁存一拍对齐，wrresult直接写
        assign wr_result = first_channel ? result_i[bank_idx]
                                : wr_pending_result + ram_old_data;

        wire [9:0] bank_wr_addr;//写入地址的判断，根据通道数判断
        assign bank_wr_addr = first_channel ? wr_idx[9:0] : wr_pending_addr;
        //通道数和像素总数都到底
        assign bank_last_write[bank_idx] = bank_wr_en &&
                        (bank_idx + 1 == output_channels_i) &&
                        ({1'b0, bank_wr_addr} + 11'd1 == output_size);

        result_ram_bank u_result_ram_bank (
            .clk     (clk),
            .wr_en   (bank_wr_en),
            .wr_addr (bank_wr_addr),//通道0不用读取，直接写，后续通道因为要读旧数据，所以地址打拍做对齐
            .wr_data (wr_result),
            .rd_en   (scan_hit || (!first_channel && row_valid)),//给后续模块输出或者0之后的通道写要读取ram
            .rd_addr (scan_hit ? scan_pixel : wr_idx[9:0]),//判断是输出给量化模块还是内部自增
            .rd_data (ram_old_data)
        );
        assign bank_rd_data[bank_idx] = ram_old_data;//输出给量化模块
    end
endgenerate

//result_o输出，和bias相加，从ram里面读要一拍，相关信号要同步打拍输出
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        scan_bank_q   <= 'd0;
        scan_valid_q  <= 1'b0;
        result_o      <= 'd0;
        result_valid_o <= 1'b0;
    end 
    else if (addr_init_i || im2col_start_i) begin
        scan_bank_q    <= 'd0;
        scan_valid_q   <= 1'b0;
        result_o       <= 'd0;
        result_valid_o <= 1'b0;
    end
    else begin
        scan_bank_q    <= scan_bank;
        scan_valid_q   <= scan_active;
        result_valid_o <= scan_valid_q;

        if (scan_valid_q)
            result_o <= bank_rd_data[scan_bank_q] + bias_reg[scan_bank_q];
    end
end

//channeldone的脉冲生成
always @(posedge clk or negedge rst_n) begin
    if (!rst_n || addr_init_i || im2col_start_i)
        channel_done_o <= 1'b0;
    else
        channel_done_o <= |bank_last_write;
end

endmodule