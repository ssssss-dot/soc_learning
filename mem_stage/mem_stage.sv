`include "define.sv"

module mem_stage(
    input clk,
    input rst_n,
    
    input                reg_we_i,//写回寄存器使能信号，直接给wb
    input [`RegAddrBus]  rd_i,//写回寄存器地址
    input [`WbSelBus]    wb_sel_i,//写回数据源选择

    input [`RegBus]      alu_result_i,//alu计算出的数据结果或地址,
    input [`RegBus]      store_data_i,//要存入mem的数据

    input                mem_re_i,//读存储器使能
    input                mem_we_i,//写存储器使能
    input [`MemOpBus]    mem_op_i,//判断是对存储器做声明操作

    input [`InstAddrBus] pc_plus4_i,//pc+4的地址
    input                fence_i,

    // CSR写回信息在MEM阶段不处理，直接传给MEM/WB
    input                csr_we_i,
    input [`CsrAddrBus]  csr_waddr_i,
    input [`CsrDataBus]  csr_wdata_i,

    //是否是load指令标志
    input                load_flag_i,

    //ex得到的计算数据/地址直接给wb
    output [`RegBus]      alu_result_o,
    output [`InstAddrBus] pc_plus4_o,
    output [`RegAddrBus]  rd_o,
    output reg_we_o,

    //读出的数据
    output  [`DataBus] mem_data_o,

    //写回数据源选择
    output [`WbSelBus] wb_sel_o,

    //load指令标志
    output load_flag_o,

    output fence_o,

    output               csr_we_o,
    output [`CsrAddrBus] csr_waddr_o,
    output [`CsrDataBus] csr_wdata_o,

    //当前整条load/store指令的MEM阶段结果，可以被MEM/WB接收，并且EX/MEM可以向前更新
    input mem_accept_i,

    output mem_req_o,

    //给tx端串口打印结果
    output [`ByteWidth] dbg_uart_tx_data,
    output dbg_uart_tx_valid,
    input  dbg_uart_tx_ready,

    output debug_load_start,
    output [`DataBus] debug_read_word,

    // DCache到bridge_top的请求/响应接口，替代内部DRAM接口。
    output                    dcache_req_valid,
    input                     dcache_req_ready,
    output     [`DataAddrBus] dcache_req_addr,//根据pc往mem里面找相应地址的数据
    output     [31:0]         dcache_req_wdata,
    output     [3:0]          dcache_req_wstrb,
    output                    dcache_req_write,// 0表示读，1表示写

    // 读信号
    input                     dcache_rsp_valid,
    input   [`DataBus]        dcache_rsp_rdata,

    output [31:0] hit_count_d,
    output [31:0] ddr_count_d,
    output [31:0] miss_count_d,

    //axi b通道响应
    input  dbg_rsp_valid,
    output dbg_rsp_ready,
    input  dbg_rsp_error,

    // MEM -> MMIO bridge
    output                    mmio_req_valid,
    input                     mmio_req_ready,
    output [`DataAddrBus]     mmio_req_addr,
    output [`DataBus]         mmio_req_wdata,
    output [3:0]              mmio_req_wstrb,
    output                    mmio_req_write,

    // MMIO bridge -> MEM
    input                     mmio_rsp_valid,
    output                    mmio_rsp_ready,
    input  [`DataBus]         mmio_rsp_rdata,

    input                     dma_irq

);


wire                 mem_req_valid;
wire                 mem_req_ready;
wire   [`DataAddrBus] mem_req_addr;//根据pc往mem（ddr）里面找相应地址的数据
wire   [31:0]         mem_req_wdata;
wire   [3:0]          mem_req_wstrb;
wire                  mem_req_write;// 0表示读ram，1表示写ram
wire              mem_rsp_valid;
wire   [`DataBus] mem_rsp_rdata;

assign csr_we_o    = csr_we_i;
assign csr_waddr_o = csr_waddr_i;
assign csr_wdata_o = csr_wdata_i;

mem u_mem(
    .clk(clk),
    .rst_n(rst_n),
    .mem_re_i(mem_re_i),
    .mem_we_i(mem_we_i),
    .mem_op_i(mem_op_i),
    .alu_result_i(alu_result_i),
    .pc_plus4_i(pc_plus4_i),
    .alu_result_o(alu_result_o),
    .pc_plus4_o(pc_plus4_o),
    .store_data_i(store_data_i),
    .mem_data_o(mem_data_o),
    .reg_we_i(reg_we_i),
    .reg_we_o(reg_we_o),
    .rd_i(rd_i),
    .rd_o(rd_o),
    .wb_sel_i(wb_sel_i),
    .wb_sel_o(wb_sel_o),
    .load_flag_i(load_flag_i),
    .load_flag_o(load_flag_o),
    .mem_accept_i(mem_accept_i),
    .dbg_uart_tx_data(dbg_uart_tx_data),
    .dbg_uart_tx_valid(dbg_uart_tx_valid),
    .dbg_uart_tx_ready(dbg_uart_tx_ready),
    .debug_load_start(debug_load_start),
    .debug_read_word(debug_read_word),
    .mem_req_o(mem_req_o),
    .fence_o(fence_o),
    .fence_i(fence_i),
    .mem_req_valid(mem_req_valid),
    .mem_req_ready(mem_req_ready),
    .mem_req_addr(mem_req_addr),
    .mem_req_wdata(mem_req_wdata),
    .mem_req_wstrb(mem_req_wstrb),
    .mem_req_write(mem_req_write),
    .mem_rsp_valid(mem_rsp_valid),
    .mem_rsp_rdata(mem_rsp_rdata),
    .dbg_rsp_valid (dbg_rsp_valid),
    .dbg_rsp_ready (dbg_rsp_ready),
    .dbg_rsp_error (dbg_rsp_error),

    // 通用MMIO接口直接透传到mem_stage顶层
    .mmio_req_valid (mmio_req_valid),
    .mmio_req_ready (mmio_req_ready),
    .mmio_req_addr  (mmio_req_addr),
    .mmio_req_wdata (mmio_req_wdata),
    .mmio_req_wstrb (mmio_req_wstrb),
    .mmio_req_write (mmio_req_write),
    .mmio_rsp_valid (mmio_rsp_valid),
    .mmio_rsp_ready (mmio_rsp_ready),
    .mmio_rsp_rdata (mmio_rsp_rdata)

);

dcache u_dcache(
    .clk(clk),
    .rst_n(rst_n),
    .mem_req_valid(mem_req_valid),
    .mem_req_ready(mem_req_ready),
    .mem_req_addr(mem_req_addr),
    .mem_req_wdata(mem_req_wdata),
    .mem_req_wstrb(mem_req_wstrb),
    .mem_req_write(mem_req_write),
    .mem_rsp_valid(mem_rsp_valid),
    .mem_rsp_rdata(mem_rsp_rdata),
    .dcache_req_valid(dcache_req_valid),
    .dcache_req_ready(dcache_req_ready),
    .dcache_req_addr(dcache_req_addr),
    .dcache_req_wdata(dcache_req_wdata),
    .dcache_req_wstrb(dcache_req_wstrb),
    .dcache_req_write(dcache_req_write),
    .dcache_rsp_valid(dcache_rsp_valid),
    .dcache_rsp_rdata(dcache_rsp_rdata),
    .hit_count_d(hit_count_d),
    .ddr_count_d(ddr_count_d),
    .miss_count_d(miss_count_d),
    .dma_irq(dma_irq)

);

endmodule
