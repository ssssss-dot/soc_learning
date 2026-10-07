`include "define.sv"

// FC独立顶层：共享BRAM同步读延迟为一拍，写口每拍接受写使能。
// 外部仲裁器需从fc_start到fc_done为FC保留访问权；运行期间配置保持稳定。
module fc_top (
    input  wire clk,
    input  wire rst_n,

    // CPU MMIO配置接口
    input  wire fc_req_valid,
    output wire fc_req_ready,
    output wire fc_rsp_valid,
    input  wire fc_rsp_ready,
    input  wire [`DataBus] fc_wdata,
    input  wire [`DataAddrBus] fc_addr,
    input  wire [3:0] fc_wstrb,
    input  wire fc_we,
    output wire [`DataBus] fc_rdata,
    output wire fc_irq,
    output wire fc_busy,
    output wire fc_start,
    output wire fc_done,

    // 对接bram_arbiter的FC端口，地址单位为32位字
    output wire acc_fc_rd_en,
    output wire [13:0] acc_fc_rd_addr,
    input  wire [`DataBus] acc_fc_rd_data,
    input  wire acc_fc_rd_valid,
    output wire acc_fc_wr_en,
    output wire [13:0] acc_fc_wr_addr,
    output wire [`DataBus] acc_fc_wr_data,
    output wire [3:0] acc_fc_wr_strb
);

wire [`DataBus] cfg_in_features, cfg_out_features;
wire [`DataBus] cfg_input_base, cfg_weight_base, cfg_bias_base;
wire [`DataBus] cfg_quant_mult;
wire [5:0] cfg_quant_shift;
wire relu_enable, error;

wire [`DataBus] in_features, out_features;
wire [`DataBus] input_base, input_end, weight_base, weight_end;
wire [`DataBus] group_bias_base, group_bias_end;
wire [`DataBus] quant_mult;
wire [5:0] quant_shift;
wire [4:0] group_bias_count;
wire [2:0] group_idx;
wire addr_init, group_start;
wire input_addr_begin, weight_addr_begin, bias_addr_begin;
wire input_loading, bias_loading, computing, draining;
wire rd_req;
wire [1:0] rd_sel;

wire input_data_valid, weight_data_valid, bias_data_valid;
wire input_loaded, bias_loaded, bias_valid;
wire drain_done, result_done;
wire features_req, features_valid, feature_last;
wire signed [`ByteWidth] features;
wire signed [`ByteWidth] weights [0:15];
wire [15:0] weight_valid;
wire weight_pe_en, pe_en, pe_clear;
wire signed [`DataBus] biases [0:15];
wire signed [`DataBus] pe_result [0:15];
wire pe_result_valid [0:15];
wire signed [`DataBus] accum_result;
wire accum_valid;

assign pe_clear = addr_init || group_start;
// 有效结果收齐后仍让PE流水线推进，排掉最后一组补零列中的残留valid。
// clear也必须在en=1时执行，pe_os的累加器才能清零。
assign pe_en = weight_pe_en || fc_busy || pe_clear;

fc_reg u_fc_reg (
    .clk(clk),
    .rst_n(rst_n),
    .fc_req_valid(fc_req_valid),
    .fc_req_ready(fc_req_ready),
    .fc_rsp_valid(fc_rsp_valid),
    .fc_rsp_ready(fc_rsp_ready),
    .fc_wdata(fc_wdata),
    .fc_addr(fc_addr),
    .fc_wstrb(fc_wstrb),
    .fc_we(fc_we),
    .fc_rdata(fc_rdata),
    .fc_irq(fc_irq),
    .fc_in_features(cfg_in_features),
    .fc_out_features(cfg_out_features),
    .fc_input_base_addr(cfg_input_base),
    .fc_weight_base_addr(cfg_weight_base),
    .fc_bias_base_addr(cfg_bias_base),
    .fc_quant_mult(cfg_quant_mult),
    .fc_quant_shift(cfg_quant_shift),
    .busy(fc_busy),
    .done(fc_done),
    .error(error),
    .fc_start(fc_start),
    .fc_relu_enable(relu_enable)
);

fc_ctrl u_fc_ctrl (
    .clk(clk),
    .rst_n(rst_n),
    .fc_in_features_i(cfg_in_features),
    .fc_out_features_i(cfg_out_features),
    .fc_input_base_addr_i(cfg_input_base),
    .fc_weight_base_addr_i(cfg_weight_base),
    .fc_bias_base_addr_i(cfg_bias_base),
    .fc_quant_mult_i(cfg_quant_mult),
    .fc_quant_shift_i(cfg_quant_shift),
    .fc_in_features_o(in_features),
    .fc_out_features_o(out_features),
    .fc_input_base_addr_o(input_base),
    .fc_weight_base_addr_o(weight_base),
    .group_bias_base_addr(group_bias_base),
    .fc_weight_end_addr(weight_end),
    .fc_input_end_addr(input_end),
    .group_bias_end_addr(group_bias_end),
    .group_bias_count(group_bias_count),
    .fc_quant_mult_o(quant_mult),
    .fc_quant_shift_o(quant_shift),
    // 等缓存实际接收完数据，而不是仅等最后一次读请求发出。
    .input_loading_done(input_loaded),
    .bias_loading_done(bias_loaded),
    .computing_done(feature_last),
    .drain_done(drain_done),
    .result_done(result_done),
    .input_loading(input_loading),
    .bias_loading(bias_loading),
    .computing(computing),
    .draining(draining),
    .busy(fc_busy),
    .done(fc_done),
    .error(error),
    .fc_start(fc_start),
    .addr_init(addr_init),
    .weight_addr_begin(weight_addr_begin),
    .input_addr_begin(input_addr_begin),
    .bias_addr_begin(bias_addr_begin),
    .rd_req(rd_req),
    .rd_sel(rd_sel),
    .group_idx_o(group_idx),
    .group_start(group_start)
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
    .group_bias_base_addr(group_bias_base),
    .group_bias_end_addr(group_bias_end),
    .weight_base_addr(weight_base),
    .weight_end_addr(weight_end),
    .input_base_addr(input_base),
    .input_end_addr(input_end),
    .bram_rd_en(acc_fc_rd_en),
    .bram_rd_addr(acc_fc_rd_addr),
    .input_loading(input_loading),
    .bias_loading(bias_loading),
    .computing(computing),
    .group_start(group_start),
    .features_i(in_features)
);

read_arbiter u_read_arbiter (
    .clk(clk),
    .rst_n(rst_n),
    .acc_rd_en(acc_fc_rd_en),
    .rd_sel(rd_sel),
    .acc_rd_valid(acc_fc_rd_valid),
    .input_data_valid(input_data_valid),
    .weight_data_valid(weight_data_valid),
    .bias_data_valid(bias_data_valid)
);

input_cache u_input_cache (
    .clk(clk),
    .rst_n(rst_n),
    .input_wr_data(acc_fc_rd_data),
    .input_data_valid(input_data_valid),
    .addr_init(addr_init),
    .group_start(group_start),
    .features_o(features),
    .features_valid_o(features_valid),
    .features_req_i(features_req),
    .features_in_i(in_features),
    .input_done(input_loaded),
    .feature_last(feature_last)
);

weight_cache u_weight_cache (
    .clk(clk),
    .rst_n(rst_n),
    .weight_wr_data(acc_fc_rd_data),
    .weight_data_valid(weight_data_valid),
    .addr_init(addr_init),
    .weight_addr_begin(weight_addr_begin),
    .features_req_o(features_req),
    .en_o(weight_pe_en),
    .weight_o(weights),
    .weight_valid_o(weight_valid),
    .group_bias_count_i(group_bias_count),
    .computing(computing),
    .draining(draining)
);

bias_cache u_bias_cache (
    .clk(clk),
    .rst_n(rst_n),
    .bias_wr_data(acc_fc_rd_data),
    .bias_data_valid(bias_data_valid),
    .addr_init(addr_init),
    .bias_addr_begin(bias_addr_begin),
    .bias_o(biases),
    .bias_valid_o(bias_valid),
    .group_bias_count_i(group_bias_count),
    .bias_done(bias_loaded)
);

fc_pe_array u_pe_array (
    .clk(clk),
    .rst_n(rst_n),
    .weight_i(weights),
    .last_i(feature_last),
    .weight_valid_i(weight_valid),
    .features_i(features),
    .features_valid_i(features_valid),
    .en_i(pe_en),
    .fc_in_features(in_features),
    .fc_out_features(out_features),
    .clear(pe_clear),
    .result_o(pe_result),
    .valid_o(pe_result_valid)
);

accumulation u_accumulation (
    .clk(clk),
    .rst_n(rst_n),
    .result_i(pe_result),
    .valid_i(pe_result_valid),
    .addr_init(addr_init),
    .group_start(group_start),
    .group_bias_count_i(group_bias_count),
    .bias_i(biases),
    .bias_valid_i(bias_valid),
    .result_o(accum_result),
    .result_valid_o(accum_valid),
    .drain_done(drain_done)
);

int32_int8 u_int32_int8 (
    .clk(clk),
    .rst_n(rst_n),
    .result_i(accum_result),
    .result_valid_i(accum_valid),
    .quant_mult_i(quant_mult),
    .quant_shift_i(quant_shift),
    .addr_init(addr_init),
    .relu_enable(relu_enable),
    .result_done(result_done),
    .group_bias_count_i(group_bias_count),
    .group_start(group_start),
    .acc_fc_wr_en(acc_fc_wr_en),
    .acc_fc_wr_addr(acc_fc_wr_addr),
    .acc_fc_wr_data(acc_fc_wr_data),
    .acc_fc_wr_strb(acc_fc_wr_strb)
);

endmodule
