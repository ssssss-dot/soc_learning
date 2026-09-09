`include "define.sv"

module soc_top(
    input sys_clk_n,
    input sys_clk_p,
    input rst_n,

    //外部串口的线
    input uart_rxd,
    output uart_txd,

    //接另一个串口的tx，用来打印处理完的数据(mmio)
    output dbg_uart_txd,

    //外接ddr4
    output        c0_ddr4_bg,
    output        c0_ddr4_cke,
    output        c0_ddr4_odt,
    output        c0_ddr4_cs_n,
    output        c0_ddr4_ck_t,
    output        c0_ddr4_ck_c,

    output [16:0] c0_ddr4_adr,
    output [1:0]  c0_ddr4_ba,
    output        c0_ddr4_act_n,
    output        c0_ddr4_reset_n,

    inout  [1:0]  c0_ddr4_dm_dbi_n,
    inout  [15:0] c0_ddr4_dq,
    inout  [1:0]  c0_ddr4_dqs_c,
    inout  [1:0]  c0_ddr4_dqs_t
);

//给到外部的调试信号
wire ldr_init_done;
wire ldr_busy;
wire ldr_pgm_done;
wire ldr_err;
wire [4:0] ldr_err_code;
(* mark_debug = "true" *) wire [31:0] hit_count_i;//记录命中的次数（性能判断）
(* mark_debug = "true" *) wire [31:0] ddr_count_i;//看访问ddr所需的时间，hit时cahche返回只要一个周期  
(* mark_debug = "true" *) wire [31:0] hit_count_d;
(* mark_debug = "true" *) wire [31:0] ddr_count_d;
(* mark_debug = "true" *) wire [31:0] miss_count_i;
(* mark_debug = "true" *) wire [31:0] miss_count_d;

//外部给的中断
wire halt_cpu;
assign halt_cpu = 1'b0;

//ibufds得到的单口时钟
wire clk;
 
// Ctrl 相关信号
wire        if_req;
wire        id_req;
wire        ex_req;
wire        mem_req;
wire        redirect;
wire        except_i;
wire [5:0]  stall;

wire        flush_if_id;
wire        flush_id_ex;
wire        flush_ex_mem;
wire        flush_mem_wb;

// IF 级输出信号
wire [`InstBus]     if_inst;
wire [`InstAddrBus] if_pc;
wire [`InstAddrBus] if_pc_plus4;
wire                if_valid;

// EX 级算出来的跳转目标地址
wire [`InstAddrBus] redirect_pc;

//id输出信号
wire [`InstAddrBus] id_pc;
wire [`InstAddrBus] id_pc_plus4;
wire [`InstBus] id_inst;
wire id_valid;

wire [`RegAddrBus]  id_rs1;
wire [`RegAddrBus]  id_rs2;
wire [`RegAddrBus]  id_rd;
wire [`RegBus]      id_imm;

wire id_re1;
wire id_re2;
wire id_reg_we;

wire id_jump_flag;
wire id_branch_flag;
wire id_jalr_flag;

wire id_mem_re;
wire id_mem_we;
wire [`MemOpBus]    id_mem_op;
wire [`WbSelBus]    id_wb_sel;

wire id_fence;
wire [`AluOpBus]    id_aluop;
wire [`AluSrc1SelBus]   id_alu_src1_sel;
wire [`AluSrc2SelBus]   id_alu_src2_sel;

wire [`InstAddrBus] id_pc_to_ex;
wire [`InstAddrBus] id_pc_plus4_to_ex;

wire [`RegBus]          id_rs1_data;
wire [`RegBus]          id_rs2_data;

wire [`CsrAddrBus] id_csr_addr;
wire [`CsrCmdBus]  id_csr_cmd;
wire               id_csr_en;
wire               id_csr_mret;



//ex级接口
// 给 ID 级做 load-use 冒险检测
wire                ex_load_flag_for_id;
wire [`RegAddrBus]  ex_rd_for_id;
//接id_ex
wire [`RegAddrBus]  ex_rs1;
wire [`RegAddrBus]  ex_rs2;
wire [`RegAddrBus]  ex_rd;
wire [`RegBus]      ex_imm;

wire                ex_re1;
wire                ex_re2;
wire                ex_reg_we;
wire                ex_jump_flag;
wire                ex_branch_flag;
wire                ex_jalr_flag;

wire                ex_mem_re;
wire                ex_mem_we;
wire [`MemOpBus]    ex_mem_op;
wire [`WbSelBus]    ex_wb_sel;

wire                ex_fence;
wire [`AluOpBus]    ex_aluop;
wire [`AluSrc1SelBus] ex_alu_src1_sel;
wire [`AluSrc2SelBus] ex_alu_src2_sel;

wire [`InstAddrBus] ex_pc;
wire [`InstAddrBus] ex_pc_plus4;
wire [`RegBus]      ex_rs1_data;
wire [`RegBus]      ex_rs2_data;
wire               ex_valid;

wire [`CsrAddrBus] ex_csr_addr;
wire [`CsrCmdBus]  ex_csr_cmd;
wire               ex_csr_en;
wire               ex_csr_mret;
wire               ex_advance;

//ex_stage输出接口
wire                ex_stage_reg_we;
wire [`RegAddrBus]  ex_stage_rd;
wire [`WbSelBus]    ex_stage_wb_sel;
wire [`RegBus]      ex_stage_alu_result;
wire [`RegBus]      ex_stage_store_data;
wire                ex_stage_mem_re;
wire                ex_stage_mem_we;
wire [`MemOpBus]    ex_stage_mem_op;
wire [`InstAddrBus] ex_stage_pc_plus4;
wire                ex_stage_fence;
wire                ex_stage_load_flag;

wire                ex_stage_redirect;
wire [`InstAddrBus] ex_stage_redirect_pc;

wire               ex_stage_csr_we;
wire [`CsrAddrBus] ex_stage_csr_waddr;
wire [`CsrDataBus] ex_stage_csr_wdata;

//mem级接口
//ex_mem到ex的前递接口
wire                mem_reg_we_for_ex;//判断是否写回
wire [`RegAddrBus]  mem_rd_for_ex;//目的寄存器地址
wire [`RegBus]      mem_forward_result_for_ex;//最终前递的数据（ex_mem模块生成）
wire                mem_load_flag_for_ex;//判断是否是load指令（ex_mem阶段load指令不能数据前递，此时只有地址还没有数据，要等mem结束，从mem_wb里面拿数据）
//ex_mem打拍后的输出
wire                mem_reg_we;
wire [`RegAddrBus]  mem_rd;
wire [`WbSelBus]    mem_wb_sel;

wire [`RegBus]      mem_alu_result;
wire [`RegBus]      mem_store_data;

wire                mem_mem_re;
wire                mem_mem_we;
wire [`MemOpBus]    mem_mem_op;

wire [`InstAddrBus] mem_pc_plus4;
wire                mem_fence;

wire                mem_load_flag;
wire [`RegBus]      ex_mem_forward_result;

wire               mem_csr_we;
wire [`CsrAddrBus] mem_csr_waddr;
wire [`CsrDataBus] mem_csr_wdata;

//mem_stage输出，后面接mem_wb
wire [`RegBus]      mem_stage_mem_data;
wire [`RegBus]      mem_stage_alu_result;
wire [`InstAddrBus] mem_stage_pc_plus4;
wire [`RegAddrBus]  mem_stage_rd;
wire                mem_stage_reg_we;
wire [`WbSelBus]    mem_stage_wb_sel;
wire                mem_stage_load_flag;
wire                mem_stage_fence;

wire               mem_stage_csr_we;
wire [`CsrAddrBus] mem_stage_csr_waddr;
wire [`CsrDataBus] mem_stage_csr_wdata;

//wb级接口
wire wb_we;
wire [`RegAddrBus]   wb_waddr;
wire [`RegBus]       wb_wdata;

wire               csrfile_wb_we;
wire [`CsrAddrBus] csrfile_wb_waddr;
wire [`CsrDataBus] csrfile_wb_wdata;

//mem_wb到ex的前递接口（load指令也可以，因为此时load已经完成，读出了数据）
wire                wb_reg_we_for_ex;
wire [`RegAddrBus]  wb_rd_for_ex;
wire [`RegBus]      wb_forward_result_for_ex;
//mem_wb打拍后的输出，后面接wb_stage和前递
wire [`RegBus]      wb_mem_data;
wire [`RegBus]      wb_alu_result;
wire [`InstAddrBus] wb_pc_plus4;
wire [`RegAddrBus]  wb_rd;
wire                wb_reg_we;
wire [`WbSelBus]    wb_wb_sel;
wire                wb_load_flag;
wire                wb_fence;

wire               wb_csr_we;
wire [`CsrAddrBus] wb_csr_waddr;
wire [`CsrDataBus] wb_csr_wdata;

//外部loader给的stall和reset
wire ldr_cpu_stall;
wire ldr_cpu_reset;

//cpu处理器复位
wire cpu_rst_n;

//IF阶段的ICache miss请求/响应直接接到bridge_top，替代原来的内部IRAM连线。
wire                    icache_req_valid;
wire                    icache_req_ready;
wire [`InstAddrBus]      icache_req_addr;
wire                    icache_rsp_valid;
wire [`InstBus]          icache_rsp_rdata;

//MEM阶段的DCache下游请求/响应直接接到bridge_top，替代原来的内部DRAM连线。
wire                    dcache_req_valid;
wire                    dcache_req_ready;
wire [`DataAddrBus]      dcache_req_addr;
wire [`DataBus]          dcache_req_wdata;
wire [3:0]              dcache_req_wstrb;
wire                    dcache_req_write;
wire                    dcache_rsp_valid;
wire [`DataBus]          dcache_rsp_rdata;

//Loader使用请求/完成响应握手访问loader_bridge，不再直接控制IRAM/DRAM。
wire                    ldr_req_valid;
wire                    ldr_req_ready;
wire [`DataAddrBus]     ldr_req_addr;
wire [`DataBus]         ldr_req_wdata;
wire [3:0]              ldr_req_wstrb;
wire                    ldr_rsp_valid;
wire                    ldr_rsp_ready;
wire                    ldr_rsp_error;

//mem2bridge
wire [`ByteWidth] dbg_uart_tx_data;
wire dbg_uart_tx_valid;
wire dbg_uart_tx_ready;
wire dbg_rsp_error;
wire dbg_rsp_valid;
wire dbg_rsp_ready;
wire [`ByteWidth] uart_tx_data;
wire uart_tx_ready;
wire uart_tx_valid;

//mig的初始化信号是300mhz时钟域下的，要做时钟域同步
reg calib_sync_ff1;
reg calib_sync_ff2;
wire calib_done_100m;

//mig端口信号声明
// MIG状态、时钟和复位
wire c0_init_calib_complete;
wire c0_ddr4_ui_clk;
wire c0_ddr4_ui_clk_sync_rst;
wire c0_ddr4_aresetn;

assign c0_ddr4_aresetn = ~c0_ddr4_ui_clk_sync_rst;

// AW通道
wire [7:0]  c0_ddr4_s_axi_awid;
wire [29:0] c0_ddr4_s_axi_awaddr;
wire [7:0]  c0_ddr4_s_axi_awlen;
wire [2:0]  c0_ddr4_s_axi_awsize;
wire [1:0]  c0_ddr4_s_axi_awburst;
wire [0:0]  c0_ddr4_s_axi_awlock;
wire [3:0]  c0_ddr4_s_axi_awcache;
wire [2:0]  c0_ddr4_s_axi_awprot;
wire [3:0]  c0_ddr4_s_axi_awqos;
wire        c0_ddr4_s_axi_awvalid;
wire        c0_ddr4_s_axi_awready;

// W通道
wire [31:0] c0_ddr4_s_axi_wdata;
wire [3:0]  c0_ddr4_s_axi_wstrb;
wire        c0_ddr4_s_axi_wlast;
wire        c0_ddr4_s_axi_wvalid;
wire        c0_ddr4_s_axi_wready;

// B通道
wire [7:0]  c0_ddr4_s_axi_bid;
wire [1:0]  c0_ddr4_s_axi_bresp;
wire        c0_ddr4_s_axi_bvalid;
wire        c0_ddr4_s_axi_bready;

// AR通道
wire [7:0]  c0_ddr4_s_axi_arid;
wire [29:0] c0_ddr4_s_axi_araddr;
wire [7:0]  c0_ddr4_s_axi_arlen;
wire [2:0]  c0_ddr4_s_axi_arsize;
wire [1:0]  c0_ddr4_s_axi_arburst;
wire [0:0]  c0_ddr4_s_axi_arlock;
wire [3:0]  c0_ddr4_s_axi_arcache;
wire [2:0]  c0_ddr4_s_axi_arprot;
wire [3:0]  c0_ddr4_s_axi_arqos;
wire        c0_ddr4_s_axi_arvalid;
wire        c0_ddr4_s_axi_arready;

// R通道
wire [7:0]  c0_ddr4_s_axi_rid;
wire [31:0] c0_ddr4_s_axi_rdata;
wire [1:0]  c0_ddr4_s_axi_rresp;
wire        c0_ddr4_s_axi_rlast;
wire        c0_ddr4_s_axi_rvalid;
wire        c0_ddr4_s_axi_rready;

//中断控制相关信号
wire [`InstAddrBus] csr_mtvec;
wire [`InstAddrBus] csr_mepc;
wire                csr_irq_request;

wire trap_enter;//cpu允许进入中断
wire [`InstAddrBus] trap_pc;//中断开始前被flush的pc

// CPU MEM -> MMIO master bridge
wire mmio_req_valid;
wire mmio_req_ready;
wire [`DataAddrBus] mmio_req_addr;
wire [`DataBus] mmio_req_wdata;
wire [3:0] mmio_req_wstrb;
wire mmio_req_write;
wire mmio_rsp_valid;
wire mmio_rsp_ready;
wire [`DataBus] mmio_rsp_rdata;

// AXI MMIO target bridge -> native router
wire router_req_valid;
wire router_req_ready;
wire [`DataAddrBus] router_req_addr;
wire [`DataBus] router_req_wdata;
wire [3:0] router_req_wstrb;
wire router_req_write;
wire router_rsp_valid;
wire router_rsp_ready;
wire [`DataBus] router_rsp_rdata;

// MMIO router -> DMA configuration registers
wire dma_req_ready;
wire dma_req_valid;
wire  dma_rsp_valid;
wire dma_rsp_ready;
wire [`DataBus] dma_wdata;
wire [`DataAddrBus] dma_addr;
wire [3:0] dma_wstrb;
wire dma_we;
wire [`DataBus] dma_rdata;
wire dma_irq;//dma中断拉高信号
wire dma_wr_done_pulse;//只给DCache失效使用，不受CPU/DMA中断屏蔽影响
wire [15:0] rd_bram_offset_active;
wire [15:0] wr_bram_offset_active;
// 加速器尚未接入；BRAM回环测试阶段由DMA独占共享BRAM。
wire acc_bram_blocked;
assign acc_bram_blocked = 1'b0;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        calib_sync_ff1 <= 1'b0;
        calib_sync_ff2 <= 1'b0;
    end
    else begin
        calib_sync_ff1 <= c0_init_calib_complete;
        calib_sync_ff2 <= calib_sync_ff1;
    end
end

assign calib_done_100m = calib_sync_ff2;

//loader时就要用bridge，因此bridge不能用cpu的rst复位
wire axi_front_aresetn;
wire axi_front_rst;

assign axi_front_aresetn = rst_n && calib_done_100m;
assign axi_front_rst     = ~axi_front_aresetn;

// 0=ICache、1=DCache、2=Loader、3=UART打印、4=CPU MMIO、5=DMA
// 当前输入ID为5位，Crossbar追加3位源编号，输出ID为8位。
localparam AXI_S_COUNT = 6;
localparam AXI_M_COUNT = 3;
taxi_axi_if #(
    .DATA_W (32),
    .ADDR_W (32),
    .ID_W   (`AXI_S_ID_WIDTH)
) s_axi [AXI_S_COUNT] ();

// 0=DDR、1=UART、2=MMIO。保留完整32位地址，不能在MMIO译码前截成30位。
taxi_axi_if #(
    .DATA_W (32),
    .ADDR_W (32),
    .ID_W   (`AXI_M_ID_WIDTH)
) m_axi [AXI_M_COUNT] ();

wire        debug_load_start;
wire [31:0] debug_read_word;

//把ex阶段得到的ex_rd和load指令的标志信号给到id_stage，判断是否要做数据冒险进一步给id_req判断
assign ex_load_flag_for_id = ex_mem_re;
assign ex_rd_for_id        = ex_rd;
//系统复位加loader复位给到cpu

assign cpu_rst_n = rst_n && ldr_cpu_reset && calib_done_100m;//加入mig初始化完成信号控制cpu的复位

//把ex阶段的redirect信号和redirect_pc接到ctrl里面去，如果是中断触发，也要跳转pc，把中刷掉的pc执行
assign redirect = trap_enter || ex_stage_redirect;
assign redirect_pc = trap_enter ? csr_mtvec : ex_stage_redirect_pc;

// 当前方案进入中断时会flush EX/MEM，
// 因此mepc保存当前EX指令地址，返回后重新执行
//例：WB ：PC=0x000001F8
//MEM：PC=0x000001FC
//EX ：PC=0x00000200
//ID ：PC=0x00000204
//IF ：PC=0x00000208
//0x1F8、0x1FC：老指令允许完成
//0x200：被flush，尚未完成
//0x204、0x208：被flush
assign trap_pc = ex_pc;

assign except_i = trap_enter;//表示接受了一个中断，要flushex以及之后的指令
// 等MEM操作和CSR写回完成后再接受中断
assign trap_enter = csr_irq_request && ex_valid && !mem_req && !ex_req && !ldr_cpu_stall && !mem_csr_we && !wb_csr_we;

// EX/MEM可以接收且当前EX指令没有被冲刷时，本条EX指令只提交一次
assign ex_advance =
    !ldr_cpu_stall &&
    !mem_req        &&
    !ex_req         &&
    !trap_enter;//cpu启动且后面的流水线没请求stall，也没有发生中断

//ex_mem给ex的前递（打拍后的信号给到ex），要将上一条指令中的数据和现有的指令对比，所以要打拍之后的数据
assign mem_reg_we_for_ex       = mem_reg_we;
assign mem_rd_for_ex           = mem_rd;
assign mem_forward_result_for_ex = ex_mem_forward_result;
assign mem_load_flag_for_ex    = mem_load_flag;

//程序运行结束标志
wire done_flag_write;
assign done_flag_write = dcache_req_valid && dcache_req_ready && dcache_req_write && (dcache_req_addr  == 32'h8000_1000) && (dcache_req_wdata == 32'hD06E_D06E) && (dcache_req_wstrb == 4'b1111);

//ctrl模块例化
Ctrl u_Ctrl(
    .rst_n(cpu_rst_n),

    .if_req(if_req),
    .id_req(id_req),
    .ex_req(ex_req),
    .mem_req(mem_req),

    .redirect_i(redirect),
    .except_i(except_i),

    .stall(stall),
    .flush_if_id(flush_if_id),
    .flush_id_ex(flush_id_ex),
    .flush_ex_mem(flush_ex_mem),
    .flush_mem_wb(flush_mem_wb),

    .i_loader_stall(ldr_cpu_stall)
);


//if_stage例化
if_stage u_if_stage(
    .clk(clk),
    .rst_n(cpu_rst_n),

    .stall_i(stall[0]),
    .inst_o(if_inst),
    .redirect_i(redirect),
    .redirect_pc_i(redirect_pc),
    .pc_o(if_pc),
    .pc_plus4_o(if_pc_plus4),
    .if_valid_o(if_valid),
    .if_req_o(if_req),

    // 程序下载完成后允许取指；MIG接入时再与DDR校准完成信号共同门控。
    .fetch_enable(ldr_cpu_reset),

    //连接IF阶段导出的ICache miss握手接口。
    .icache_req_valid(icache_req_valid),
    .icache_req_ready(icache_req_ready),
    .icache_req_addr(icache_req_addr),
    .icache_rsp_valid(icache_rsp_valid),
    .icache_rsp_rdata(icache_rsp_rdata),

    .hit_count_i(hit_count_i),
    .ddr_count_i(ddr_count_i),
    .miss_count_i(miss_count_i)
);

//if_id例化
if_id u_if_id(
    .clk(clk),
    .rst_n(cpu_rst_n),
    .stall_i(stall[1]),
    .flush_i(flush_if_id),
    .if_pc_i(if_pc),
    .if_pc_plus4_i(if_pc_plus4),
    .if_inst_i(if_inst),
    .if_valid_i(if_valid),

    .id_pc_o(id_pc),
    .id_pc_plus4_o(id_pc_plus4),
    .id_inst_o(id_inst),
    .id_valid_o(id_valid)
);

//id_stage 例化
id_stage u_id_stage(
    .clk(clk),
    .rst_n(cpu_rst_n),

    .inst_i(id_inst),
    .pc_i(id_pc),
    .pc_plus4_i(id_pc_plus4),

    // 来自 WB 级，给 regfile 写回
    .wb_we_i(wb_we),
    .wb_waddr_i(wb_waddr),
    .wb_wdata_i(wb_wdata),

    // 输出到后级
    .rs1_o(id_rs1),
    .rs2_o(id_rs2),
    .rd_o(id_rd),

    .imm_o(id_imm),

    .re1_o(id_re1),
    .re2_o(id_re2),
    .reg_we_o(id_reg_we),

    .jump_flag_o(id_jump_flag),
    .branch_flag_o(id_branch_flag),
    .jalr_flag_o(id_jalr_flag),

    .mem_re_o(id_mem_re),
    .mem_we_o(id_mem_we),
    .mem_op_o(id_mem_op),
    .wb_sel_o(id_wb_sel),

    .fence_o(id_fence),

    .aluop_o(id_aluop),
    .alu_src1_sel_o(id_alu_src1_sel),
    .alu_src2_sel_o(id_alu_src2_sel),

    .pc_o(id_pc_to_ex),
    .pc_plus4_o(id_pc_plus4_to_ex),
    .rs1_data_o(id_rs1_data),
    .rs2_data_o(id_rs2_data),

    // 给 load-use 冒险检测用
    .ex_mem_re_i(ex_load_flag_for_id),
    .ex_rd_i(ex_rd_for_id),

    .id_req_o(id_req),

    .csr_addr_o(id_csr_addr),
    .csr_cmd_o(id_csr_cmd),
    .csr_en_o(id_csr_en),
    .mret_o(id_csr_mret),

    //判断是否有mret冒险的信号
    .ex_csr_we_i(ex_stage_csr_we),
    .mem_csr_we_i(mem_csr_we),
    .wb_csr_we_i(wb_csr_we)
);

//id_ex模块例化
id_ex u_id_ex(
    .clk(clk),
    .rst_n(cpu_rst_n),

    .id_valid_i(id_valid),

    .id_rs1_i(id_rs1),
    .id_rs2_i(id_rs2),
    .id_rd_i(id_rd),
    .id_imm_i(id_imm),

    .id_re1_i(id_re1),
    .id_re2_i(id_re2),
    .id_reg_we_i(id_reg_we),

    .id_jump_flag_i(id_jump_flag),
    .id_branch_flag_i(id_branch_flag),
    .id_jalr_flag_i(id_jalr_flag),

    .pc_i(id_pc_to_ex),
    .pc_plus4_i(id_pc_plus4_to_ex),

    .rs1_data_i(id_rs1_data),
    .rs2_data_i(id_rs2_data),

    .id_mem_re_i(id_mem_re),
    .id_mem_we_i(id_mem_we),
    .id_mem_op_i(id_mem_op),
    .id_wb_sel_i(id_wb_sel),

    .id_fence_i(id_fence),

    .id_csr_addr_i(id_csr_addr),
    .id_csr_en_i(id_csr_en),
    .id_csr_cmd_i(id_csr_cmd),
    .id_csr_mret_i(id_csr_mret),

    .id_aluop_i(id_aluop),
    .id_alu_src1_sel_i(id_alu_src1_sel),
    .id_alu_src2_sel_i(id_alu_src2_sel),

    .flush_i(flush_id_ex),
    .stall_i(stall[2]),

    .ex_rs1_o(ex_rs1),
    .ex_rs2_o(ex_rs2),
    .ex_rd_o(ex_rd),
    .ex_imm_o(ex_imm),

    .ex_re1_o(ex_re1),
    .ex_re2_o(ex_re2),
    .ex_reg_we_o(ex_reg_we),

    .ex_jump_flag_o(ex_jump_flag),
    .ex_branch_flag_o(ex_branch_flag),
    .ex_jalr_flag_o(ex_jalr_flag),

    .ex_mem_re_o(ex_mem_re),
    .ex_mem_we_o(ex_mem_we),
    .ex_mem_op_o(ex_mem_op),
    .ex_wb_sel_o(ex_wb_sel),

    .ex_fence_o(ex_fence),

    .ex_aluop_o(ex_aluop),
    .ex_alu_src1_sel_o(ex_alu_src1_sel),
    .ex_alu_src2_sel_o(ex_alu_src2_sel),

    .pc_o(ex_pc),
    .pc_plus4_o(ex_pc_plus4),
    .rs1_data_o(ex_rs1_data),
    .rs2_data_o(ex_rs2_data),

    .ex_valid_o(ex_valid),
    .ex_csr_addr_o(ex_csr_addr),
    .ex_csr_en_o(ex_csr_en),
    .ex_csr_cmd_o(ex_csr_cmd),
    .ex_csr_mret_o(ex_csr_mret)
);

//ex_stage例化
ex_stage u_ex_stage(
    .clk(clk),
    .rst_n(cpu_rst_n),

    .ex_valid_i(ex_valid),
    .ex_advance_i(ex_advance),

    .rs1_i(ex_rs1),
    .rs2_i(ex_rs2),
    .rd_i(ex_rd),
    .imm_i(ex_imm),

    .re1_i(ex_re1),
    .re2_i(ex_re2),
    .reg_we_i(ex_reg_we),

    .jump_flag_i(ex_jump_flag),
    .branch_flag_i(ex_branch_flag),
    .jalr_flag_i(ex_jalr_flag),

    .pc_i(ex_pc),
    .pc_plus4_i(ex_pc_plus4),

    .rs1_data_i(ex_rs1_data),
    .rs2_data_i(ex_rs2_data),

    .mem_re_i(ex_mem_re),
    .mem_we_i(ex_mem_we),
    .mem_op_i(ex_mem_op),
    .wb_sel_i(ex_wb_sel),

    .fence_i(ex_fence),

    .aluop_i(ex_aluop),
    .alu_src1_sel_i(ex_alu_src1_sel),
    .alu_src2_sel_i(ex_alu_src2_sel),

    .redirect_o(ex_stage_redirect),
    .redirect_pc_o(ex_stage_redirect_pc),

    .rd_o(ex_stage_rd),
    .reg_we_o(ex_stage_reg_we),
    .wb_sel_o(ex_stage_wb_sel),

    .alu_result_o(ex_stage_alu_result),
    .store_data_o(ex_stage_store_data),

    .mem_re_o(ex_stage_mem_re),
    .mem_we_o(ex_stage_mem_we),
    .mem_op_o(ex_stage_mem_op),

    .pc_plus4_o(ex_stage_pc_plus4),
    .fence_o(ex_stage_fence),

    // 来自 ex_mem 的前递
    .ex_mem_reg_we_i(mem_reg_we_for_ex),
    .ex_mem_rd_i(mem_rd_for_ex),
    .ex_mem_forward_result_i(mem_forward_result_for_ex),

    // 来自 mem_wb 的前递
    .mem_wb_reg_we_i(wb_reg_we_for_ex),
    .mem_wb_rd_i(wb_rd_for_ex),
    .mem_wb_forward_result_i(wb_forward_result_for_ex),

    .load_flag_o(ex_stage_load_flag),
    .ex_mem_load_flag_i(mem_load_flag_for_ex),

    .ex_req_o(ex_req),

    .dma_irq_i(dma_irq),
    .trap_enter_i(trap_enter),
    .trap_pc_i(trap_pc),

    .wb_csr_we_i(csrfile_wb_we),
    .wb_csr_waddr_i(csrfile_wb_waddr),
    .wb_csr_wdata_i(csrfile_wb_wdata),

    .mtvec_o(csr_mtvec),
    .mepc_o(csr_mepc),
    .irq_request_o(csr_irq_request),

    .csr_addr_i(ex_csr_addr),
    .csr_cmd_i(ex_csr_cmd),
    .csr_en_i(ex_csr_en),
    .csr_mret_i(ex_csr_mret),

    .csr_we_o(ex_stage_csr_we),
    .csr_waddr_o(ex_stage_csr_waddr),
    .csr_wdata_o(ex_stage_csr_wdata),

    // EX/MEM CSR结果前递回EX
    .ex_mem_csr_we_i(mem_csr_we),
    .ex_mem_csr_waddr_i(mem_csr_waddr),
    .ex_mem_csr_wdata_i(mem_csr_wdata)
);

//ex_mem例化
ex_mem u_ex_mem(
    .clk(clk),
    .rst_n(cpu_rst_n),

    .stall_i(stall[3]),
    .flush_i(flush_ex_mem),

    // 来自 EX 级
    .ex_reg_we_i(ex_stage_reg_we),
    .ex_rd_i(ex_stage_rd),
    .ex_wb_sel_i(ex_stage_wb_sel),

    .ex_alu_result_i(ex_stage_alu_result),
    .ex_store_data_i(ex_stage_store_data),

    .ex_mem_re_i(ex_stage_mem_re),
    .ex_mem_we_i(ex_stage_mem_we),
    .ex_mem_op_i(ex_stage_mem_op),

    .ex_pc_plus4_i(ex_stage_pc_plus4),
    .ex_fence_i(ex_stage_fence),

    .ex_csr_we_i(ex_stage_csr_we),
    .ex_csr_waddr_i(ex_stage_csr_waddr),
    .ex_csr_wdata_i(ex_stage_csr_wdata),

    .ex_load_flag_i(ex_stage_load_flag),

    // 打拍后送到 MEM 级
    .mem_reg_we_o(mem_reg_we),
    .mem_rd_o(mem_rd),
    .mem_wb_sel_o(mem_wb_sel),

    .mem_alu_result_o(mem_alu_result),
    .mem_store_data_o(mem_store_data),

    .mem_mem_re_o(mem_mem_re),
    .mem_mem_we_o(mem_mem_we),
    .mem_mem_op_o(mem_mem_op),

    .mem_pc_plus4_o(mem_pc_plus4),
    .mem_fence_o(mem_fence),

    .mem_load_flag_o(mem_load_flag),

    .mem_csr_we_o(mem_csr_we),
    .mem_csr_waddr_o(mem_csr_waddr),
    .mem_csr_wdata_o(mem_csr_wdata),

    .forward_result_o(ex_mem_forward_result)
);

//mem_stage例化
mem_stage u_mem_stage(
    .clk(clk),
    .rst_n(cpu_rst_n),

    // 来自 EX/MEM 流水寄存器
    .reg_we_i(mem_reg_we),
    .rd_i(mem_rd),
    .wb_sel_i(mem_wb_sel),

    .alu_result_i(mem_alu_result),
    .store_data_i(mem_store_data),

    .mem_re_i(mem_mem_re),
    .mem_we_i(mem_mem_we),
    .mem_op_i(mem_mem_op),

    .pc_plus4_i(mem_pc_plus4),
    .fence_i(mem_fence),

    .csr_we_i(mem_csr_we),
    .csr_waddr_i(mem_csr_waddr),
    .csr_wdata_i(mem_csr_wdata),

    .load_flag_i(mem_load_flag),

    // 输出到 MEM/WB 流水寄存器
    .alu_result_o(mem_stage_alu_result),
    .pc_plus4_o(mem_stage_pc_plus4),
    .rd_o(mem_stage_rd),
    .reg_we_o(mem_stage_reg_we),

    .mem_data_o(mem_stage_mem_data),

    .wb_sel_o(mem_stage_wb_sel),
    .load_flag_o(mem_stage_load_flag),
    .fence_o(mem_stage_fence),

    .csr_we_o(mem_stage_csr_we),
    .csr_waddr_o(mem_stage_csr_waddr),
    .csr_wdata_o(mem_stage_csr_wdata),

    // 给 Ctrl 的 MEM 级暂停请求
    .mem_req_o(mem_req),

    // 连接MEM阶段导出的DCache下游握手接口，替代旧DRAM直连端口。
    .dcache_req_valid(dcache_req_valid),
    .dcache_req_ready(dcache_req_ready),
    .dcache_req_addr(dcache_req_addr),
    .dcache_req_wdata(dcache_req_wdata),
    .dcache_req_wstrb(dcache_req_wstrb),
    .dcache_req_write(dcache_req_write),
    .dcache_rsp_valid(dcache_rsp_valid),
    .dcache_rsp_rdata(dcache_rsp_rdata),

    .dbg_uart_tx_data(dbg_uart_tx_data),
    .dbg_uart_tx_ready(dbg_uart_tx_ready),
    .dbg_uart_tx_valid(dbg_uart_tx_valid),

    .debug_load_start(debug_load_start),
    .debug_read_word(debug_read_word),
    .mem_accept_i(!stall[4]),

    .hit_count_d(hit_count_d),
    .ddr_count_d(ddr_count_d),
    .miss_count_d(miss_count_d),

    .dbg_rsp_valid (dbg_rsp_valid),
    .dbg_rsp_ready (dbg_rsp_ready),
    .dbg_rsp_error (dbg_rsp_error),

    .mmio_req_valid(mmio_req_valid),
    .mmio_req_ready(mmio_req_ready),
    .mmio_req_addr(mmio_req_addr),
    .mmio_req_wdata(mmio_req_wdata),
    .mmio_req_wstrb(mmio_req_wstrb),
    .mmio_req_write(mmio_req_write),
    .mmio_rsp_valid(mmio_rsp_valid),
    .mmio_rsp_ready(mmio_rsp_ready),
    .mmio_rsp_rdata(mmio_rsp_rdata),

    // 保留mem_stage的旧端口名；该输入仅传给DCache，不是CPU中断输入。
    .dma_irq(dma_wr_done_pulse)


);

//mem_wb例化
mem_wb u_mem_wb(
    .clk(clk),
    .rst_n(cpu_rst_n),

    .stall_i(stall[4]),
    .flush_i(flush_mem_wb),

    // 来自 MEM 阶段，也就是 mem_stage 的输出
    .mem_alu_result_i(mem_stage_alu_result),
    .mem_pc_plus4_i(mem_stage_pc_plus4),
    .mem_rd_i(mem_stage_rd),
    .mem_reg_we_i(mem_stage_reg_we),

    // load 从 data_mem 读出的数据
    .mem_mem_data_i(mem_stage_mem_data),

    // 写回选择信号，决定 WB 阶段写 alu/mem/pc+4
    .mem_wb_sel_i(mem_stage_wb_sel),

    // 继续向后传的辅助标志
    .mem_load_flag_i(mem_stage_load_flag),
    .mem_fence_i(mem_stage_fence),

    .mem_csr_we_i(mem_stage_csr_we),
    .mem_csr_waddr_i(mem_stage_csr_waddr),
    .mem_csr_wdata_i(mem_stage_csr_wdata),

    // 打拍后输出到 WB 阶段
    .wb_alu_result_o(wb_alu_result),
    .wb_pc_plus4_o(wb_pc_plus4),
    .wb_rd_o(wb_rd),
    .wb_reg_we_o(wb_reg_we),

    .wb_mem_data_o(wb_mem_data),
    .wb_wb_sel_o(wb_wb_sel),
    .wb_load_flag_o(wb_load_flag),
    .wb_fence_o(wb_fence),

    .wb_csr_we_o(wb_csr_we),
    .wb_csr_waddr_o(wb_csr_waddr),
    .wb_csr_wdata_o(wb_csr_wdata)
);

//wb_stage例化
wb_stage u_wb_stage(
    // 来自 MEM/WB 流水寄存器
    .mem_data_i(wb_mem_data),
    .alu_result_i(wb_alu_result),
    .pc_plus4_i(wb_pc_plus4),
    .rd_i(wb_rd),
    .reg_we_i(wb_reg_we),
    .wb_sel_i(wb_wb_sel),

    // 写回 reg_file，接回 id_stage
    .wb_we_o(wb_we),
    .wb_waddr_o(wb_waddr),
    .wb_wdata_o(wb_wdata),

    // 给 EX 阶段做 MEM/WB -> EX 前递
    .wb_reg_we_for_ex_o(wb_reg_we_for_ex),
    .wb_rd_for_ex_o(wb_rd_for_ex),
    .wb_forward_result_for_ex_o(wb_forward_result_for_ex),

    .csr_we_i(wb_csr_we),
    .csr_waddr_i(wb_csr_waddr),
    .csr_wdata_i(wb_csr_wdata),

    .wb_csr_we_o(csrfile_wb_we),
    .wb_csr_waddr_o(csrfile_wb_waddr),
    .wb_csr_wdata_o(csrfile_wb_wdata)
);

wire ldr_ram_sel_debug;

//外部loader的例化
loader u_loader(
    .clk (clk),
    .rst_n (rst_n),
    .i_halt_cpu(halt_cpu),
    .o_ldr_cpu_stall(ldr_cpu_stall),
    .o_ldr_cpu_reset(ldr_cpu_reset),

    .i_uart_rx(uart_rxd),
    .o_uart_tx(uart_txd),

    // Loader通过loader_bridge写DDR，并等待AXI B通道完成响应。
    .ldr_req_valid(ldr_req_valid),
    .ldr_req_ready(ldr_req_ready),
    .ldr_req_addr(ldr_req_addr),
    .ldr_req_wdata(ldr_req_wdata),
    .ldr_req_wstrb(ldr_req_wstrb),
    .ldr_rsp_valid(ldr_rsp_valid),
    .ldr_rsp_ready(ldr_rsp_ready),
    .ldr_rsp_error(ldr_rsp_error),

    //调试信号
    .o_init_done(ldr_init_done),
    .o_busy(ldr_busy),
    .o_pgm_done(ldr_pgm_done),
    .o_err(ldr_err),
    .o_err_code(ldr_err_code),
    .o_debug_ram_sel(ldr_ram_sel_debug)
);

// Bridge总封装：Cache、Loader、UART及通用MMIO，统一使用前端clk时钟域。
bridge_top u_bridge_top (
    .aclk               (clk),
    .arst_n             (axi_front_aresetn),

    .icache_req_valid   (icache_req_valid),
    .icache_req_ready   (icache_req_ready),
    .icache_req_addr    (icache_req_addr),
    .icache_rsp_valid   (icache_rsp_valid),
    .icache_rsp_rdata   (icache_rsp_rdata),

    .dcache_req_valid   (dcache_req_valid),
    .dcache_req_ready   (dcache_req_ready),
    .dcache_req_addr    (dcache_req_addr),
    .dcache_req_wdata   (dcache_req_wdata),
    .dcache_req_wstrb   (dcache_req_wstrb),
    .dcache_req_write   (dcache_req_write),
    .dcache_rsp_valid   (dcache_rsp_valid),
    .dcache_rsp_rdata   (dcache_rsp_rdata),

    .ldr_req_valid      (ldr_req_valid),
    .ldr_req_ready      (ldr_req_ready),
    .ldr_req_addr       (ldr_req_addr),
    .ldr_req_wdata      (ldr_req_wdata),
    .ldr_req_wstrb      (ldr_req_wstrb),
    .ldr_rsp_valid      (ldr_rsp_valid),
    .ldr_rsp_ready      (ldr_rsp_ready),
    .ldr_rsp_error      (ldr_rsp_error),

    .dbg_uart_tx_data    (dbg_uart_tx_data),
    .dbg_uart_tx_ready   (dbg_uart_tx_ready),
    .dbg_uart_tx_valid   (dbg_uart_tx_valid),
    .dbg_rsp_error      (dbg_rsp_error),
    .dbg_rsp_valid      (dbg_rsp_valid),
    .dbg_rsp_ready      (dbg_rsp_ready),

    .mmio_req_valid     (mmio_req_valid),
    .mmio_req_ready     (mmio_req_ready),
    .mmio_req_addr      (mmio_req_addr),
    .mmio_req_wdata     (mmio_req_wdata),
    .mmio_req_wstrb     (mmio_req_wstrb),
    .mmio_req_write     (mmio_req_write),
    .mmio_rsp_valid     (mmio_rsp_valid),
    .mmio_rsp_ready     (mmio_rsp_ready),
    .mmio_rsp_rdata     (mmio_rsp_rdata),

    .router_req_valid   (router_req_valid),
    .router_req_ready   (router_req_ready),
    .router_req_addr    (router_req_addr),
    .router_req_wdata   (router_req_wdata),
    .router_req_wstrb   (router_req_wstrb),
    .router_req_write   (router_req_write),
    .router_rsp_valid   (router_rsp_valid),
    .router_rsp_ready   (router_rsp_ready),
    .router_rsp_rdata   (router_rsp_rdata),

    .m_axi_rd           (s_axi[0]),
    .dcache_axi_rd      (s_axi[1]),
    .dcache_axi_wr      (s_axi[1]),
    .loader_axi_wr      (s_axi[2]),
    .uart_axi_wr        (s_axi[3]),
    .mmio_axi_rd        (s_axi[4]),
    .mmio_axi_wr        (s_axi[4]),
    .mmio_target_axi_rd (m_axi[2]),
    .mmio_target_axi_wr (m_axi[2])
);

mmio_router u_mmio_router (
    .clk               (clk),
    .rst_n             (axi_front_aresetn),

    .mmio_req_valid    (router_req_valid),
    .mmio_req_ready    (router_req_ready),
    .mmio_req_addr     (router_req_addr),
    .mmio_req_wdata    (router_req_wdata),
    .mmio_req_wstrb    (router_req_wstrb),
    .mmio_req_write    (router_req_write),
    .mmio_rsp_valid    (router_rsp_valid),
    .mmio_rsp_ready    (router_rsp_ready),
    .mmio_rsp_rdata    (router_rsp_rdata),

    .dma_req_valid     (dma_req_valid),
    .dma_req_ready     (dma_req_ready),
    .dma_rsp_valid     (dma_rsp_valid),
    .dma_rsp_ready     (dma_rsp_ready),
    .dma_addr          (dma_addr),
    .dma_wdata         (dma_wdata),
    .dma_wstrb         (dma_wstrb),
    .dma_we            (dma_we),
    .dma_rdata         (dma_rdata)
);

// 关闭s_axi[0]未使用的写通道；ICache只会发起AXI读事务。
// 将全部主机输出固定为0，避免仿真时未使用信号传播X。
assign s_axi[0].awid     = '0;
assign s_axi[0].awaddr   = '0;
assign s_axi[0].awlen    = '0;
assign s_axi[0].awsize   = '0;
assign s_axi[0].awburst  = '0;
assign s_axi[0].awlock   = '0;
assign s_axi[0].awcache  = '0;
assign s_axi[0].awprot   = '0;
assign s_axi[0].awqos    = '0;
assign s_axi[0].awregion = '0;
assign s_axi[0].awuser   = '0;
assign s_axi[0].awvalid  = 1'b0;
assign s_axi[0].wdata    = '0;
assign s_axi[0].wstrb    = '0;
assign s_axi[0].wlast    = 1'b0;
assign s_axi[0].wuser    = '0;
assign s_axi[0].wvalid   = 1'b0;
assign s_axi[0].bready   = 1'b0;

// 关闭s_axi[2]未使用的读通道；Loader只会发起AXI写事务。
// 将全部主机输出固定为0，避免仿真时未使用信号传播X。
assign s_axi[2].arid     = '0;
assign s_axi[2].araddr   = '0;
assign s_axi[2].arlen    = '0;
assign s_axi[2].arsize   = '0;
assign s_axi[2].arburst  = '0;
assign s_axi[2].arlock   = '0;
assign s_axi[2].arcache  = '0;
assign s_axi[2].arprot   = '0;
assign s_axi[2].arqos    = '0;
assign s_axi[2].arregion = '0;
assign s_axi[2].aruser   = '0;
assign s_axi[2].arvalid  = 1'b0;
assign s_axi[2].rready   = 1'b0;

assign s_axi[3].arid     = '0;
assign s_axi[3].araddr   = '0;
assign s_axi[3].arlen    = '0;
assign s_axi[3].arsize   = '0;
assign s_axi[3].arburst  = '0;
assign s_axi[3].arlock   = '0;
assign s_axi[3].arcache  = '0;
assign s_axi[3].arprot   = '0;
assign s_axi[3].arqos    = '0;
assign s_axi[3].arregion = '0;
assign s_axi[3].aruser   = '0;
assign s_axi[3].arvalid  = 1'b0;
assign s_axi[3].rready   = 1'b0;

assign m_axi[1].arready = 1'b0;
assign m_axi[1].rid     = '0;
assign m_axi[1].rdata   = '0;
assign m_axi[1].rresp   = 2'b11;
assign m_axi[1].rlast   = 1'b0;
assign m_axi[1].ruser   = '0;
assign m_axi[1].rvalid  = 1'b0;

// 6输入3输出：DDR、UART、DMA及后续加速器共享的MMIO配置窗口。
taxi_axi_crossbar_3s #(
    .S_COUNT     (AXI_S_COUNT),
    .M_COUNT     (AXI_M_COUNT),
    .ADDR_W      (32),
    .M_REGIONS   (1),
    .M_BASE_ADDR ({
        32'h4000_4000,
        32'h4000_0000,
        32'h0000_0000
    }),
    .M_ADDR_W ({
        32'd14,
        32'd12,
        32'd30
    })
) u_axi_crossbar (
    .clk      (clk),
    .rst      (axi_front_rst),
    .s_axi_wr (s_axi),
    .s_axi_rd (s_axi),
    .m_axi_wr (m_axi),
    .m_axi_rd (m_axi)
);

//m_axi[0]是Crossbar输出，后续在此连接AXI Clock Converter和MIG。
// MIG的DDR4物理端口继续保留在cpu_top端口列表中，本次不添加或修改MIG例化。

debug_uart_tx u_debug_uart_tx(
    .clk (clk),
    .rst_n (rst_n),
    .uart_tx_data(uart_tx_data),
    .uart_tx_valid(uart_tx_valid),
    .uart_tx_ready(uart_tx_ready),
    .uart_txd(dbg_uart_txd)
);

ila_0 u_ila (
    .clk(clk),
    .probe0(hit_count_i),  // 32位
    .probe1(hit_count_d),  // 32位
    .probe2(ddr_count_i),  // 32位
    .probe3(ddr_count_d),  // 32位
    .probe4(done_flag_write),
    .probe5(miss_count_d),
    .probe6(miss_count_i)
);

//把差分时钟转为单口时钟
IBUFDS u_ibufds_sys_clk (
    .I (sys_clk_p),
    .IB(sys_clk_n),
    .O (clk)
);

//mig例化
ddr4_0 u_ddr4_0 (
  .c0_init_calib_complete(c0_init_calib_complete),    // output wire c0_init_calib_complete
  .dbg_clk(),                                  // output wire dbg_clk
  .c0_sys_clk_i(clk),                                 // input wire c0_sys_clk_i
  .dbg_bus(),                                  // output wire [511 : 0] dbg_bus
  .c0_ddr4_adr(c0_ddr4_adr),                          // output wire [16 : 0] c0_ddr4_adr
  .c0_ddr4_ba(c0_ddr4_ba),                            // output wire [1 : 0] c0_ddr4_ba
  .c0_ddr4_cke(c0_ddr4_cke),                          // output wire [0 : 0] c0_ddr4_cke
  .c0_ddr4_cs_n(c0_ddr4_cs_n),                        // output wire [0 : 0] c0_ddr4_cs_n
  .c0_ddr4_dm_dbi_n(c0_ddr4_dm_dbi_n),                // inout wire [1 : 0] c0_ddr4_dm_dbi_n
  .c0_ddr4_dq(c0_ddr4_dq),                            // inout wire [15 : 0] c0_ddr4_dq
  .c0_ddr4_dqs_c(c0_ddr4_dqs_c),                      // inout wire [1 : 0] c0_ddr4_dqs_c
  .c0_ddr4_dqs_t(c0_ddr4_dqs_t),                      // inout wire [1 : 0] c0_ddr4_dqs_t
  .c0_ddr4_odt(c0_ddr4_odt),                          // output wire [0 : 0] c0_ddr4_odt
  .c0_ddr4_bg(c0_ddr4_bg),                            // output wire [0 : 0] c0_ddr4_bg
  .c0_ddr4_reset_n(c0_ddr4_reset_n),                  // output wire c0_ddr4_reset_n
  .c0_ddr4_act_n(c0_ddr4_act_n),                      // output wire c0_ddr4_act_n
  .c0_ddr4_ck_c(c0_ddr4_ck_c),                        // output wire [0 : 0] c0_ddr4_ck_c
  .c0_ddr4_ck_t(c0_ddr4_ck_t),                        // output wire [0 : 0] c0_ddr4_ck_t
  .c0_ddr4_ui_clk(c0_ddr4_ui_clk),                    // output wire c0_ddr4_ui_clk
  .c0_ddr4_ui_clk_sync_rst(c0_ddr4_ui_clk_sync_rst),  // output wire c0_ddr4_ui_clk_sync_rst
  .c0_ddr4_aresetn(c0_ddr4_aresetn),                  // input wire c0_ddr4_aresetn
  .c0_ddr4_s_axi_awid(c0_ddr4_s_axi_awid),            // input wire [7 : 0] c0_ddr4_s_axi_awid
  .c0_ddr4_s_axi_awaddr(c0_ddr4_s_axi_awaddr),        // input wire [29 : 0] c0_ddr4_s_axi_awaddr
  .c0_ddr4_s_axi_awlen(c0_ddr4_s_axi_awlen),          // input wire [7 : 0] c0_ddr4_s_axi_awlen
  .c0_ddr4_s_axi_awsize(c0_ddr4_s_axi_awsize),        // input wire [2 : 0] c0_ddr4_s_axi_awsize
  .c0_ddr4_s_axi_awburst(c0_ddr4_s_axi_awburst),      // input wire [1 : 0] c0_ddr4_s_axi_awburst
  .c0_ddr4_s_axi_awlock(c0_ddr4_s_axi_awlock),        // input wire [0 : 0] c0_ddr4_s_axi_awlock
  .c0_ddr4_s_axi_awcache(c0_ddr4_s_axi_awcache),      // input wire [3 : 0] c0_ddr4_s_axi_awcache
  .c0_ddr4_s_axi_awprot(c0_ddr4_s_axi_awprot),        // input wire [2 : 0] c0_ddr4_s_axi_awprot
  .c0_ddr4_s_axi_awqos(c0_ddr4_s_axi_awqos),          // input wire [3 : 0] c0_ddr4_s_axi_awqos
  .c0_ddr4_s_axi_awvalid(c0_ddr4_s_axi_awvalid),      // input wire c0_ddr4_s_axi_awvalid
  .c0_ddr4_s_axi_awready(c0_ddr4_s_axi_awready),      // output wire c0_ddr4_s_axi_awready
  .c0_ddr4_s_axi_wdata(c0_ddr4_s_axi_wdata),          // input wire [31 : 0] c0_ddr4_s_axi_wdata
  .c0_ddr4_s_axi_wstrb(c0_ddr4_s_axi_wstrb),          // input wire [3 : 0] c0_ddr4_s_axi_wstrb
  .c0_ddr4_s_axi_wlast(c0_ddr4_s_axi_wlast),          // input wire c0_ddr4_s_axi_wlast
  .c0_ddr4_s_axi_wvalid(c0_ddr4_s_axi_wvalid),        // input wire c0_ddr4_s_axi_wvalid
  .c0_ddr4_s_axi_wready(c0_ddr4_s_axi_wready),        // output wire c0_ddr4_s_axi_wready
  .c0_ddr4_s_axi_bready(c0_ddr4_s_axi_bready),        // input wire c0_ddr4_s_axi_bready
  .c0_ddr4_s_axi_bid(c0_ddr4_s_axi_bid),              // output wire [7 : 0] c0_ddr4_s_axi_bid
  .c0_ddr4_s_axi_bresp(c0_ddr4_s_axi_bresp),          // output wire [1 : 0] c0_ddr4_s_axi_bresp
  .c0_ddr4_s_axi_bvalid(c0_ddr4_s_axi_bvalid),        // output wire c0_ddr4_s_axi_bvalid
  .c0_ddr4_s_axi_arid(c0_ddr4_s_axi_arid),            // input wire [7 : 0] c0_ddr4_s_axi_arid
  .c0_ddr4_s_axi_araddr(c0_ddr4_s_axi_araddr),        // input wire [29 : 0] c0_ddr4_s_axi_araddr
  .c0_ddr4_s_axi_arlen(c0_ddr4_s_axi_arlen),          // input wire [7 : 0] c0_ddr4_s_axi_arlen
  .c0_ddr4_s_axi_arsize(c0_ddr4_s_axi_arsize),        // input wire [2 : 0] c0_ddr4_s_axi_arsize
  .c0_ddr4_s_axi_arburst(c0_ddr4_s_axi_arburst),      // input wire [1 : 0] c0_ddr4_s_axi_arburst
  .c0_ddr4_s_axi_arlock(c0_ddr4_s_axi_arlock),        // input wire [0 : 0] c0_ddr4_s_axi_arlock
  .c0_ddr4_s_axi_arcache(c0_ddr4_s_axi_arcache),      // input wire [3 : 0] c0_ddr4_s_axi_arcache
  .c0_ddr4_s_axi_arprot(c0_ddr4_s_axi_arprot),        // input wire [2 : 0] c0_ddr4_s_axi_arprot
  .c0_ddr4_s_axi_arqos(c0_ddr4_s_axi_arqos),          // input wire [3 : 0] c0_ddr4_s_axi_arqos
  .c0_ddr4_s_axi_arvalid(c0_ddr4_s_axi_arvalid),      // input wire c0_ddr4_s_axi_arvalid
  .c0_ddr4_s_axi_arready(c0_ddr4_s_axi_arready),      // output wire c0_ddr4_s_axi_arready
  .c0_ddr4_s_axi_rready(c0_ddr4_s_axi_rready),        // input wire c0_ddr4_s_axi_rready
  .c0_ddr4_s_axi_rlast(c0_ddr4_s_axi_rlast),          // output wire c0_ddr4_s_axi_rlast
  .c0_ddr4_s_axi_rvalid(c0_ddr4_s_axi_rvalid),        // output wire c0_ddr4_s_axi_rvalid
  .c0_ddr4_s_axi_rresp(c0_ddr4_s_axi_rresp),          // output wire [1 : 0] c0_ddr4_s_axi_rresp
  .c0_ddr4_s_axi_rid(c0_ddr4_s_axi_rid),              // output wire [7 : 0] c0_ddr4_s_axi_rid
  .c0_ddr4_s_axi_rdata(c0_ddr4_s_axi_rdata),          // output wire [31 : 0] c0_ddr4_s_axi_rdata
  .sys_rst(~rst_n)                                    // input wire sys_rst
);

//axi跨时钟域同步模块例化
axi_clock_converter_0 u_axi_clock_converter_0 (
    // Crossbar侧：100MHz
    .s_axi_aclk       (clk),
    .s_axi_aresetn    (axi_front_aresetn),

    // S_AXI AW：Crossbar -> Converter
    .s_axi_awid       (m_axi[0].awid),
    .s_axi_awaddr     (m_axi[0].awaddr[29:0]), // DDR已由Crossbar译码，适配现有30位IP
    .s_axi_awlen      (m_axi[0].awlen),
    .s_axi_awsize     (m_axi[0].awsize),
    .s_axi_awburst    (m_axi[0].awburst),
    .s_axi_awlock     (m_axi[0].awlock),
    .s_axi_awcache    (m_axi[0].awcache),
    .s_axi_awprot     (m_axi[0].awprot),
    .s_axi_awregion   (m_axi[0].awregion),
    .s_axi_awqos      (m_axi[0].awqos),
    .s_axi_awvalid    (m_axi[0].awvalid),
    .s_axi_awready    (m_axi[0].awready),

    // S_AXI W
    .s_axi_wdata      (m_axi[0].wdata),
    .s_axi_wstrb      (m_axi[0].wstrb),
    .s_axi_wlast      (m_axi[0].wlast),
    .s_axi_wvalid     (m_axi[0].wvalid),
    .s_axi_wready     (m_axi[0].wready),

    // S_AXI B
    .s_axi_bid        (m_axi[0].bid),
    .s_axi_bresp      (m_axi[0].bresp),
    .s_axi_bvalid     (m_axi[0].bvalid),
    .s_axi_bready     (m_axi[0].bready),

    // S_AXI AR
    .s_axi_arid       (m_axi[0].arid),
    .s_axi_araddr     (m_axi[0].araddr[29:0]),
    .s_axi_arlen      (m_axi[0].arlen),
    .s_axi_arsize     (m_axi[0].arsize),
    .s_axi_arburst    (m_axi[0].arburst),
    .s_axi_arlock     (m_axi[0].arlock),
    .s_axi_arcache    (m_axi[0].arcache),
    .s_axi_arprot     (m_axi[0].arprot),
    .s_axi_arregion   (m_axi[0].arregion),
    .s_axi_arqos      (m_axi[0].arqos),
    .s_axi_arvalid    (m_axi[0].arvalid),
    .s_axi_arready    (m_axi[0].arready),

    // S_AXI R
    .s_axi_rid        (m_axi[0].rid),
    .s_axi_rdata      (m_axi[0].rdata),
    .s_axi_rresp      (m_axi[0].rresp),
    .s_axi_rlast      (m_axi[0].rlast),
    .s_axi_rvalid     (m_axi[0].rvalid),
    .s_axi_rready     (m_axi[0].rready),

    // MIG侧：使用MIG产生的UI时钟
    .m_axi_aclk       (c0_ddr4_ui_clk),
    .m_axi_aresetn    (c0_ddr4_aresetn),

    // M_AXI AW：Converter -> MIG
    .m_axi_awid       (c0_ddr4_s_axi_awid),
    .m_axi_awaddr     (c0_ddr4_s_axi_awaddr),
    .m_axi_awlen      (c0_ddr4_s_axi_awlen),
    .m_axi_awsize     (c0_ddr4_s_axi_awsize),
    .m_axi_awburst    (c0_ddr4_s_axi_awburst),
    .m_axi_awlock     (c0_ddr4_s_axi_awlock),
    .m_axi_awcache    (c0_ddr4_s_axi_awcache),
    .m_axi_awprot     (c0_ddr4_s_axi_awprot),
    .m_axi_awregion   (), // MIG没有AWREGION
    .m_axi_awqos      (c0_ddr4_s_axi_awqos),
    .m_axi_awvalid    (c0_ddr4_s_axi_awvalid),
    .m_axi_awready    (c0_ddr4_s_axi_awready),

    // M_AXI W
    .m_axi_wdata      (c0_ddr4_s_axi_wdata),
    .m_axi_wstrb      (c0_ddr4_s_axi_wstrb),
    .m_axi_wlast      (c0_ddr4_s_axi_wlast),
    .m_axi_wvalid     (c0_ddr4_s_axi_wvalid),
    .m_axi_wready     (c0_ddr4_s_axi_wready),

    // M_AXI B
    .m_axi_bid        (c0_ddr4_s_axi_bid),
    .m_axi_bresp      (c0_ddr4_s_axi_bresp),
    .m_axi_bvalid     (c0_ddr4_s_axi_bvalid),
    .m_axi_bready     (c0_ddr4_s_axi_bready),

    // M_AXI AR
    .m_axi_arid       (c0_ddr4_s_axi_arid),
    .m_axi_araddr     (c0_ddr4_s_axi_araddr),
    .m_axi_arlen      (c0_ddr4_s_axi_arlen),
    .m_axi_arsize     (c0_ddr4_s_axi_arsize),
    .m_axi_arburst    (c0_ddr4_s_axi_arburst),
    .m_axi_arlock     (c0_ddr4_s_axi_arlock),
    .m_axi_arcache    (c0_ddr4_s_axi_arcache),
    .m_axi_arprot     (c0_ddr4_s_axi_arprot),
    .m_axi_arregion   (), // MIG没有ARREGION
    .m_axi_arqos      (c0_ddr4_s_axi_arqos),
    .m_axi_arvalid    (c0_ddr4_s_axi_arvalid),
    .m_axi_arready    (c0_ddr4_s_axi_arready),

    // M_AXI R
    .m_axi_rid        (c0_ddr4_s_axi_rid),
    .m_axi_rdata      (c0_ddr4_s_axi_rdata),
    .m_axi_rresp      (c0_ddr4_s_axi_rresp),
    .m_axi_rlast      (c0_ddr4_s_axi_rlast),
    .m_axi_rvalid     (c0_ddr4_s_axi_rvalid),
    .m_axi_rready     (c0_ddr4_s_axi_rready)
);

axi2native_uart u_axi2native_uart(
    .aclk(clk),
    .arst_n(axi_front_aresetn),
    .uart_tx_data(uart_tx_data),
    .uart_tx_valid(uart_tx_valid),
    .uart_tx_ready(uart_tx_ready),

    // AXI W通道
    .m_axi_wdata     (m_axi[1].wdata),
    .m_axi_wstrb     (m_axi[1].wstrb),
    .m_axi_wlast     (m_axi[1].wlast),
    .m_axi_wuser     (m_axi[1].wuser),
    .m_axi_wvalid    (m_axi[1].wvalid),
    .m_axi_wready    (m_axi[1].wready),

    // AXI AW通道
    .m_axi_awid      (m_axi[1].awid),
    .m_axi_awaddr    (m_axi[1].awaddr[29:0]), // 保持现有UART从机的30位端口
    .m_axi_awlen     (m_axi[1].awlen),
    .m_axi_awsize    (m_axi[1].awsize),
    .m_axi_awburst   (m_axi[1].awburst),
    .m_axi_awlock    (m_axi[1].awlock),
    .m_axi_awcache   (m_axi[1].awcache),
    .m_axi_awprot    (m_axi[1].awprot),
    .m_axi_awqos     (m_axi[1].awqos),
    .m_axi_awregion  (m_axi[1].awregion),
    .m_axi_awuser    (m_axi[1].awuser),
    .m_axi_awvalid   (m_axi[1].awvalid),
    .m_axi_awready   (m_axi[1].awready),

    // AXI B通道
    .m_axi_bid       (m_axi[1].bid),
    .m_axi_bresp     (m_axi[1].bresp),
    .m_axi_buser     (m_axi[1].buser),
    .m_axi_bvalid    (m_axi[1].bvalid),
    .m_axi_bready    (m_axi[1].bready)

);

//axi clk convert没有user信号
assign m_axi[0].buser = '0;
assign m_axi[0].ruser = '0;

//dma子系统例化
dma_subsystem_top u_dma_subsystem_top(
    .clk(clk),
    .rst_n(cpu_rst_n),

    .acc_bram_blocked(acc_bram_blocked),

    // MMIO router <-> DMA ctrl
    .dma_req_ready(dma_req_ready),
    .dma_req_valid(dma_req_valid),
    .dma_rsp_valid(dma_rsp_valid),
    .dma_rsp_ready(dma_rsp_ready),

    .dma_wdata(dma_wdata),
    .dma_addr(dma_addr),
    .dma_wstrb(dma_wstrb),
    .dma_we(dma_we),
    .dma_rdata(dma_rdata),

    // DMA中断
    .dma_irq(dma_irq),
    .dma_wr_done_pulse(dma_wr_done_pulse),

    // 当前DMA任务锁存的BRAM字节偏移
    .rd_bram_offset_active(rd_bram_offset_active),
    .wr_bram_offset_active(wr_bram_offset_active),

    // DMA作为AXI master接入crossbar
    .m_axi_wr(s_axi[5]),
    .m_axi_rd(s_axi[5])
);

endmodule
