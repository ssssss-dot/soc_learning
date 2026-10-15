`include "define.sv"

module dma_subsystem_top(
    input clk,
    input rst_n,

    // High while the accelerator owns the shared BRAM.
    input                     acc_bram_blocked,

    // Accelerator access to the shared BRAM.
    input                     acc_rd_en,
    input  [13:0]             acc_rd_addr,
    output [31:0]             acc_rd_data,
    output                    acc_rd_valid,
    input                     acc_wr_en,
    input  [13:0]             acc_wr_addr,
    input  [31:0]             acc_wr_data,
    input  [3:0]              acc_wr_strb,

    // MMIO router <-> DMA ctrl native request/response
    output                    dma_req_ready,
    input                     dma_req_valid,
    output                    dma_rsp_valid,
    input                     dma_rsp_ready,
    input  [`DataBus]         dma_wdata,
    input  [`DataAddrBus]     dma_addr,
    input  [3:0]              dma_wstrb,
    input                     dma_we,
    output [`DataBus]         dma_rdata,

    // DMA interrupt
    output                    dma_irq,
    // Independent cache invalidation event; not masked by IRQ_ENABLE.
    output                    dma_wr_done_pulse,

    // DMA AXI master interface to crossbar/DDR
    taxi_axi_if.wr_mst        m_axi_wr,
    taxi_axi_if.rd_mst        m_axi_rd,
    output [15:0] rd_bram_offset_active,
    output [15:0] wr_bram_offset_active
);

wire [`DataBus] ctrl_rd_desc_src_addr;
wire [15:0]     ctrl_rd_desc_len;
wire            ctrl_rd_desc_valid;
wire            ctrl_rd_desc_ready;
wire            ctrl_rd_desc_sts_valid;
wire [3:0]      ctrl_rd_desc_sts_error;

wire [`DataBus] ctrl_wr_desc_dst_addr;
wire [15:0]     ctrl_wr_desc_len;
wire            ctrl_wr_desc_valid;
wire            ctrl_wr_desc_ready;
wire            ctrl_wr_desc_sts_valid;
wire [3:0]      ctrl_wr_desc_sts_error;

// Descriptor channels between dma_ctrl and taxi_axi_dma
taxi_dma_desc_if #(
    .SRC_ADDR_W(32),
    .DST_ADDR_W(32),
    .LEN_W(16),
    .TAG_W(8)
) rd_desc_if();

taxi_dma_desc_if #(
    .SRC_ADDR_W(32),
    .DST_ADDR_W(32),
    .LEN_W(16),
    .TAG_W(8)
) wr_desc_if();

// AXIS streams on both sides of the shared accelerator BRAM.
taxi_axis_if #(
    .DATA_W(32),
    .KEEP_W(4),
    .KEEP_EN(1'b1),
    .LAST_EN(1'b1),
    .STRB_EN(1'b0),
    .ID_EN(1'b0),
    .DEST_EN(1'b0),
    .USER_EN(1'b0)
) rd_axis_if();

taxi_axis_if #(
    .DATA_W(32),
    .KEEP_W(4),
    .KEEP_EN(1'b1),
    .LAST_EN(1'b1),
    .STRB_EN(1'b0),
    .ID_EN(1'b0),
    .DEST_EN(1'b0),
    .USER_EN(1'b0)
) wr_axis_if();

// dma_ctrl drives descriptor request information
assign rd_desc_if.req_src_addr  = ctrl_rd_desc_src_addr;
assign rd_desc_if.req_src_sel   = '0;
assign rd_desc_if.req_src_asid  = '0;
assign rd_desc_if.req_dst_addr  = '0;
assign rd_desc_if.req_dst_sel   = '0;
assign rd_desc_if.req_dst_asid  = '0;
assign rd_desc_if.req_imm       = '0;
assign rd_desc_if.req_imm_en    = 1'b0;
assign rd_desc_if.req_len       = ctrl_rd_desc_len;
assign rd_desc_if.req_tag       = '0;
assign rd_desc_if.req_id        = '0;
assign rd_desc_if.req_dest      = '0;
assign rd_desc_if.req_user      = '0;
assign rd_desc_if.req_valid     = ctrl_rd_desc_valid;
assign ctrl_rd_desc_ready       = rd_desc_if.req_ready;
assign ctrl_rd_desc_sts_valid   = rd_desc_if.sts_valid;
assign ctrl_rd_desc_sts_error   = rd_desc_if.sts_error;

assign wr_desc_if.req_src_addr  = '0;
assign wr_desc_if.req_src_sel   = '0;
assign wr_desc_if.req_src_asid  = '0;
assign wr_desc_if.req_dst_addr  = ctrl_wr_desc_dst_addr;
assign wr_desc_if.req_dst_sel   = '0;
assign wr_desc_if.req_dst_asid  = '0;
assign wr_desc_if.req_imm       = '0;
assign wr_desc_if.req_imm_en    = 1'b0;
assign wr_desc_if.req_len       = ctrl_wr_desc_len;
assign wr_desc_if.req_tag       = '0;
assign wr_desc_if.req_id        = '0;
assign wr_desc_if.req_dest      = '0;
assign wr_desc_if.req_user      = '0;
assign wr_desc_if.req_valid     = ctrl_wr_desc_valid;
assign ctrl_wr_desc_ready       = wr_desc_if.req_ready;
assign ctrl_wr_desc_sts_valid   = wr_desc_if.sts_valid;
assign ctrl_wr_desc_sts_error   = wr_desc_if.sts_error;

// Unused AXIS sideband signals for the BRAM datapath
assign wr_axis_if.tstrb = wr_axis_if.tkeep;
assign wr_axis_if.tid   = '0;
assign wr_axis_if.tdest = '0;
assign wr_axis_if.tuser = '0;

dma_ctrl dma_ctrl_inst(
    .clk(clk),
    .rst_n(rst_n),

    .dma_req_ready(dma_req_ready),
    .dma_req_valid(dma_req_valid),
    .dma_rsp_valid(dma_rsp_valid),
    .dma_rsp_ready(dma_rsp_ready),

    .dma_wdata(dma_wdata),
    .dma_addr(dma_addr),
    .dma_wstrb(dma_wstrb),
    .dma_we(dma_we),
    .dma_rdata(dma_rdata),

    .dma_irq(dma_irq),
    .dma_wr_done_pulse(dma_wr_done_pulse),

    .rd_desc_src_addr(ctrl_rd_desc_src_addr),
    .rd_desc_len(ctrl_rd_desc_len),
    .rd_desc_valid(ctrl_rd_desc_valid),
    .rd_desc_ready(ctrl_rd_desc_ready),
    .rd_desc_sts_valid(ctrl_rd_desc_sts_valid),
    .rd_desc_sts_error(ctrl_rd_desc_sts_error),

    .wr_desc_dst_addr(ctrl_wr_desc_dst_addr),
    .wr_desc_len(ctrl_wr_desc_len),
    .wr_desc_valid(ctrl_wr_desc_valid),
    .wr_desc_ready(ctrl_wr_desc_ready),
    .wr_desc_sts_valid(ctrl_wr_desc_sts_valid),
    .wr_desc_sts_error(ctrl_wr_desc_sts_error),
    .rd_bram_offset_active (rd_bram_offset_active),
    .wr_bram_offset_active (wr_bram_offset_active)
);

taxi_axi_dma #(
    .AXI_MAX_BURST_LEN(16),
    .UNALIGNED_EN(1'b1)
) taxi_axi_dma_inst(
    .clk(clk),
    .rst(!rst_n),

    .rd_desc_req(rd_desc_if),
    .rd_desc_sts(rd_desc_if),
    .wr_desc_req(wr_desc_if),
    .wr_desc_sts(wr_desc_if),

    .m_axis_rd_data(rd_axis_if),
    .s_axis_wr_data(wr_axis_if),

    .m_axi_wr(m_axi_wr),
    .m_axi_rd(m_axi_rd),

    .read_enable(1'b1),
    .write_enable(1'b1),
    .write_abort(1'b0)
);

bram_for_acc bram_for_acc_inst(
    .clk(clk),
    .rst_n(rst_n),

    .data_i_dma(rd_axis_if.tdata),
    .last_i_dma(rd_axis_if.tlast),
    .keep_i_dma(rd_axis_if.tkeep),
    .ready_i_dma(rd_axis_if.tready),
    .valid_i_dma(rd_axis_if.tvalid),

    .data_o_dma(wr_axis_if.tdata),
    .last_o_dma(wr_axis_if.tlast),
    .valid_o_dma(wr_axis_if.tvalid),
    .ready_o_dma(wr_axis_if.tready),
    .keep_o_dma(wr_axis_if.tkeep),

    .ram2ddr_len_dma(ctrl_wr_desc_len),
    .ctrl_wr_desc_valid_dma(ctrl_wr_desc_valid),
    .ctrl_wr_desc_ready_dma(ctrl_wr_desc_ready),

    .ctrl_rd_desc_valid_dma(ctrl_rd_desc_valid),
    .ctrl_rd_desc_ready_dma(ctrl_rd_desc_ready),

    .write_blocked_dma(acc_bram_blocked),

    .rd_bram_offset_dma(rd_bram_offset_active),
    .wr_bram_offset_dma(wr_bram_offset_active),

    .acc_rd_en(acc_rd_en),
    .acc_rd_addr(acc_rd_addr),
    .acc_rd_data(acc_rd_data),
    .acc_rd_valid(acc_rd_valid),
    .acc_wr_en(acc_wr_en),
    .acc_wr_addr(acc_wr_addr),
    .acc_wr_data(acc_wr_data),
    .acc_wr_strb(acc_wr_strb)
);

endmodule
