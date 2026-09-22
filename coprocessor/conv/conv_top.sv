`include "define.sv"

module conv_top (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        conv_req_valid,
    output wire        conv_req_ready,
    output wire        conv_rsp_valid,
    input  wire        conv_rsp_ready,
    input  wire [31:0] conv_wdata,
    input  wire [31:0] conv_addr,
    input  wire [3:0]  conv_wstrb,
    input  wire        conv_we,
    output wire [31:0] conv_rdata,
    output wire        conv_irq,

    output wire        acc_rd_en,
    output wire [13:0] acc_rd_addr,
    input  wire [31:0] acc_rd_data,
    input  wire        acc_rd_valid,
    output wire        acc_wr_en,
    output wire [13:0] acc_wr_addr,
    output wire [31:0] acc_wr_data,
    output wire [3:0]  acc_wr_strb
);

wire [5:0]  cfg_quant_shift, quant_shift;
wire [31:0] cfg_quant_mult, quant_mult;
wire [15:0] cfg_input_width, cfg_input_height;
wire [15:0] cfg_input_channels, cfg_output_channels;
wire [13:0] cfg_bias_base;
wire [31:0] cfg_input_base, cfg_weight_base;
wire [15:0] input_width, input_height;
wire [15:0] input_channels, output_channels;
wire [13:0] bias_base;
wire [31:0] bias_end, input_base, input_end;
wire [31:0] weight_base, weight_end, output_end;
wire [7:0]  input_last_word_addr;

wire start, done, busy, error;
wire [4:0] weight_target;
wire weight_loading_en, valid_weight;
wire rd_req, addr_init;
wire [1:0] rd_sel;
wire [15:0] channel_cnt;
wire weight_addr_begin, input_addr_begin, bias_addr_begin;
wire im2col_start;
wire weight_done, input_done, bias_done;
wire channel_done, output_done;
wire input_cache_loaded_done, weight_vec_valid;
wire input_data_valid, weight_data_valid, bias_data_valid;

wire signed [7:0] weight_vec [0:15];
wire signed [7:0] pixel_data;
wire pixel_valid, pixel_req;
wire [15:0] pixel_addr;
wire signed [7:0] pe_data [0:24];
wire [24:0] pe_data_valid;
wire signed [31:0] pe_result [0:15];
wire [15:0] pe_result_valid;
wire [31:0] accum_result;
wire accum_result_valid, bias_loaded_done;
wire signed [7:0] quant_data;
wire quant_valid;

conv_reg u_conv_reg (
    .clk(clk),
    .rst_n(rst_n),
    .conv_req_valid(conv_req_valid),
    .conv_req_ready(conv_req_ready),
    .conv_rsp_valid(conv_rsp_valid),
    .conv_rsp_ready(conv_rsp_ready),
    .conv_wdata(conv_wdata),
    .conv_addr(conv_addr),
    .conv_wstrb(conv_wstrb),
    .conv_we(conv_we),
    .conv_rdata(conv_rdata),
    .conv_irq(conv_irq),
    .conv_quant_shift(cfg_quant_shift),
    .conv_quant_mult(cfg_quant_mult),
    .conv_input_width(cfg_input_width),
    .conv_input_height(cfg_input_height),
    .conv_input_channels(cfg_input_channels),
    .conv_output_channels(cfg_output_channels),
    .conv_bias_base(cfg_bias_base),
    .conv_input_base(cfg_input_base),
    .conv_weight_base(cfg_weight_base),
    .done(done),
    .busy(busy),
    .error(error),
    .conv_start(start)
);

conv_ctrl u_conv_ctrl (
    .clk(clk),
    .rst_n(rst_n),
    .current_quant_shift_i(cfg_quant_shift),
    .current_quant_mult_i(cfg_quant_mult),
    .current_input_width_i(cfg_input_width),
    .current_input_height_i(cfg_input_height),
    .current_input_channels_i(cfg_input_channels),
    .current_output_channels_i(cfg_output_channels),
    .current_bias_base_i(cfg_bias_base),
    .current_input_base_i(cfg_input_base),
    .current_weight_base_i(cfg_weight_base),
    .current_quant_shift_o(quant_shift),
    .current_quant_mult_o(quant_mult),
    .current_input_width_o(input_width),
    .current_input_height_o(input_height),
    .current_input_channels_o(input_channels),
    .current_output_channels_o(output_channels),
    .current_bias_base_o(bias_base),
    .current_bias_end_o(bias_end),
    .current_input_base_o(input_base),
    .current_weight_base_o(weight_base),
    .current_input_end_o(input_end),
    .current_weight_end_o(weight_end),
    .current_output_end_o(output_end),
    .input_last_word_addr_o(input_last_word_addr),
    .weight_done_i(weight_done),
    .input_cache_loaded_done_i(input_cache_loaded_done),
    .input_done_i(input_done),
    .bias_done_i(bias_done),
    .channel_done_i(channel_done),
    .output_done_i(output_done),
    .weight_vec_valid_i(weight_vec_valid),
    .done(done),
    .busy(busy),
    .error(error),
    .start(start),
    .weight_target(weight_target),
    .weight_loading_en(weight_loading_en),
    .valid_weight(valid_weight),
    .rd_req(rd_req),
    .rd_sel(rd_sel),
    .addr_init(addr_init),
    .channel_cnt(channel_cnt),
    .weight_addr_begin(weight_addr_begin),
    .input_addr_begin(input_addr_begin),
    .bias_addr_begin(bias_addr_begin),
    .im2col_start(im2col_start)
);

addr_gen u_addr_gen (
    .clk(clk),
    .rst_n(rst_n),
    .addr_init(addr_init),
    .weight_addr_begin(weight_addr_begin),
    .input_addr_begin(input_addr_begin),
    .bias_addr_begin(bias_addr_begin),
    .rd_sel(rd_sel),
    .rd_req(rd_req),
    .bias_base_addr(bias_base),
    .bias_end_addr(bias_end),
    .weight_base_addr(weight_base),
    .weight_end_addr(weight_end),
    .input_base_addr(input_base),
    .input_end_addr(input_end),
    .input_width(input_width),
    .input_height(input_height),
    .input_channels(input_channels),
    .output_channels(output_channels),
    .channel_cnt(channel_cnt),
    .bram_rd_en(acc_rd_en),
    .bram_rd_addr(acc_rd_addr),
    .input_done(input_done),
    .weight_done(weight_done),
    .bias_done(bias_done)
);

read_arbiter u_read_arbiter (
    .clk(clk),
    .rst_n(rst_n),
    .acc_rd_en(acc_rd_en),
    .rd_sel(rd_sel),
    .acc_rd_valid(acc_rd_valid),
    .input_data_valid(input_data_valid),
    .weight_data_valid(weight_data_valid),
    .bias_data_valid(bias_data_valid)
);

weight_cache u_weight_cache (
    .clk(clk),
    .rst_n(rst_n),
    .weight_addr_begin(weight_addr_begin),
    .weight_data_valid(weight_data_valid),
    .weight_data(acc_rd_data),
    .weight_vec(weight_vec),
    .weight_vec_valid(weight_vec_valid)
);

input_cache u_input_cache (
    .clk(clk),
    .rst_n(rst_n),
    .input_addr_begin(input_addr_begin),
    .wr_en(input_data_valid),
    .wr_data(acc_rd_data),
    .pixel_req(pixel_req),
    .pixel_addr(pixel_addr[9:0]),
    .input_last_word_addr_i(input_last_word_addr),
    .pixel_data(pixel_data),
    .pixel_valid(pixel_valid),
    .input_cache_loaded_done_o(input_cache_loaded_done)
);

im2col u_im2col (
    .clk(clk),
    .rst_n(rst_n),
    .im2col_start_i(im2col_start),
    .data_o(pe_data),
    .valid_data_i(pe_data_valid),
    .input_width_i(input_width),
    .input_height_i(input_height),
    .pixel_data_i(pixel_data),
    .pixel_valid_i(pixel_valid),
    .pixel_addr_o(pixel_addr),
    .pixel_req_o(pixel_req)
);

pe_array u_pe_array (
    .clk(clk),
    .rst_n(rst_n),
    .data_i(pe_data),
    .valid_data_i(pe_data_valid),
    .weight_i(weight_vec),
    .weight_target_i(weight_target),
    .weight_loading_en_i(weight_loading_en),
    .valid_weight(valid_weight),
    .result_o(pe_result),
    .valid_result_o(pe_result_valid)
);

accumulation u_accumulation (
    .clk(clk),
    .rst_n(rst_n),
    .addr_init_i(addr_init),
    .im2col_start_i(im2col_start),
    .input_width_i(input_width),
    .input_height_i(input_height),
    .output_channels_i(output_channels),
    .channel_cnt_i(channel_cnt),
    .bias_addr_begin_i(bias_addr_begin),
    .result_i(pe_result),
    .valid_result_i(pe_result_valid),
    .bias_data_i(acc_rd_data),
    .bias_data_valid_i(bias_data_valid),
    .channel_done_o(channel_done),
    .bias_loaded_done_o(bias_loaded_done),
    .result_o(accum_result),
    .result_valid_o(accum_result_valid)
);

int32_int8 u_int32_int8 (
    .clk(clk),
    .rst_n(rst_n),
    .result_i(accum_result),
    .result_valid_i(accum_result_valid),
    .quant_mult_i(quant_mult),
    .quant_shift_i(quant_shift),
    .data_o(quant_data),
    .data_valid_o(quant_valid)
);

output_cache u_output_cache (
    .clk(clk),
    .rst_n(rst_n),
    .acc_wr_en(acc_wr_en),
    .acc_wr_addr(acc_wr_addr),
    .acc_wr_data(acc_wr_data),
    .acc_wr_strb(acc_wr_strb),
    .data_i(quant_data),
    .data_valid_i(quant_valid),
    .addr_init(addr_init),
    .output_end_i(output_end),
    .output_done_o(output_done)
);

endmodule
