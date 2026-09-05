`timescale 1ns/1ps

module testbench_cpu_top;

localparam integer CLK_HALF_PERIOD = 5;          // 100 MHz
localparam integer MEM_BYTES       = 256 * 1024;
localparam integer MEM_WORDS       = MEM_BYTES / 4;
localparam integer MAX_BIN_SIZE    = MEM_BYTES;

localparam logic [31:0] DATA_BASE = 32'h8000_0000;
localparam logic [31:0] DATA_END  = DATA_BASE + MEM_BYTES;

// 测试程序结束时向这个地址写入固定值。
localparam logic [31:0] DONE_ADDR  = 32'h8000_1000;
localparam logic [31:0] DONE_MAGIC = 32'hD06E_D06E;

logic clk;
logic rst_n;
logic dma_irq_i;

// ICache下游接口。
wire         icache_req_valid;
logic        icache_req_ready;
wire [31:0]  icache_req_addr;
logic        icache_rsp_valid;
logic [31:0] icache_rsp_rdata;

// DCache下游接口。
wire         dcache_req_valid;
logic        dcache_req_ready;
wire [31:0]  dcache_req_addr;
wire [31:0]  dcache_req_wdata;
wire [3:0]   dcache_req_wstrb;
wire         dcache_req_write;
logic        dcache_rsp_valid;
logic [31:0] dcache_rsp_rdata;

// 中断和PC跳转观察信号。
wire         trap_enter;
wire [31:0]  trap_pc;
wire [31:0]  mtvec;
wire [31:0]  mepc;
wire         irq_request;
wire         redirect;
wire [31:0]  redirect_pc;
wire         flush_if_id;
wire         flush_id_ex;
wire         flush_ex_mem;

wire [7:0] dbg_uart_tx_data;
wire       dbg_uart_tx_valid;

// 行为级指令存储器和数据存储器。
logic [31:0] imem [0:MEM_WORDS-1];
logic [31:0] dmem [0:MEM_WORDS-1];
byte unsigned raw_bytes [0:MAX_BIN_SIZE-1];

string iram_file = "interrupt_test_raw_iram.bin";
string dram_file = "interrupt_test_raw_dram.bin";

integer trap_count;
logic   interrupt_entered;
logic   mret_return_seen;
logic   mret_flush_ok;


/* ============================== CPU ============================== */

cpu_tb_top dut (
    .clk                    (clk),
    .rst_n                  (rst_n),
    .dma_irq_i              (dma_irq_i),

    .icache_req_valid       (icache_req_valid),
    .icache_req_ready       (icache_req_ready),
    .icache_req_addr        (icache_req_addr),
    .icache_rsp_valid       (icache_rsp_valid),
    .icache_rsp_rdata       (icache_rsp_rdata),

    .dcache_req_valid       (dcache_req_valid),
    .dcache_req_ready       (dcache_req_ready),
    .dcache_req_addr        (dcache_req_addr),
    .dcache_req_wdata       (dcache_req_wdata),
    .dcache_req_wstrb       (dcache_req_wstrb),
    .dcache_req_write       (dcache_req_write),
    .dcache_rsp_valid       (dcache_rsp_valid),
    .dcache_rsp_rdata       (dcache_rsp_rdata),

    .trap_enter_o           (trap_enter),
    .trap_pc_o              (trap_pc),
    .mtvec_o                (mtvec),
    .mepc_o                 (mepc),
    .irq_request_o          (irq_request),
    .redirect_o             (redirect),
    .redirect_pc_o          (redirect_pc),

    .flush_if_id_o          (flush_if_id),
    .flush_id_ex_o          (flush_id_ex),
    .flush_ex_mem_o         (flush_ex_mem),

    // 这些调试输出本测试不使用，保持悬空即可。
    .stall_o                (),
    .flush_mem_wb_o         (),
    .wb_we_o                (),
    .wb_waddr_o             (),
    .wb_wdata_o             (),
    .ex_pc_o                (),
    .ex_valid_o             (),

    .dbg_uart_tx_data_o     (dbg_uart_tx_data),
    .dbg_uart_tx_valid_o    (dbg_uart_tx_valid)
);


/* ========================== 时钟和文件加载 ======================== */

initial begin
    clk = 1'b0;
    forever #CLK_HALF_PERIOD clk = ~clk;
end

// 把raw二进制文件按RISC-V小端序装入32位存储器。
task automatic load_raw_bin(input string file_name, input bit to_imem);
    integer fd;
    integer size;
    integer i;
    logic [31:0] word_data;
    begin
        fd = $fopen(file_name, "rb");
        if (fd == 0)
            $fatal(1, "无法打开文件：%s", file_name);

        size = $fread(raw_bytes, fd);
        $fclose(fd);

        if ((size > MAX_BIN_SIZE) || ((size & 3) != 0))
            $fatal(1, "文件过大或长度未按4字节对齐：%s", file_name);

        for (i = 0; i < size; i = i + 4) begin
            // raw中的37 01 02 80在存储器中组合成32'h80020137。
            word_data = {raw_bytes[i+3], raw_bytes[i+2],
                         raw_bytes[i+1], raw_bytes[i]};
            if (to_imem)
                imem[i >> 2] = word_data;
            else
                dmem[i >> 2] = word_data;
        end

        $display("[%0t] 加载%s：%s，共%0d字节",
                 $time, to_imem ? "IRAM" : "DRAM", file_name, size);
    end
endtask


/* ========================= ICache行为模型 ========================= */

assign icache_req_ready = rst_n;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        icache_rsp_valid <= 1'b0;
        icache_rsp_rdata <= 32'h0000_0013; // NOP
    end
    else begin
        icache_rsp_valid <= 1'b0;

        if (icache_req_valid && icache_req_ready) begin
            if ((icache_req_addr[1:0] != 2'b00) ||
                ((icache_req_addr >> 2) >= MEM_WORDS))
                $fatal(1, "ICache地址越界或未对齐：0x%08h",
                       icache_req_addr);

            icache_rsp_rdata <= imem[icache_req_addr >> 2];
            icache_rsp_valid <= 1'b1;
        end
    end
end


/* ========================= DCache行为模型 ========================= */

assign dcache_req_ready = rst_n;

integer dmem_index;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        dcache_rsp_valid <= 1'b0;
        dcache_rsp_rdata <= 32'd0;
    end
    else begin
        dcache_rsp_valid <= 1'b0;

        if (dcache_req_valid && dcache_req_ready) begin
            if ((dcache_req_addr < DATA_BASE) ||
                (dcache_req_addr >= DATA_END))
                $fatal(1, "DCache地址越界：0x%08h", dcache_req_addr);

            dmem_index = (dcache_req_addr - DATA_BASE) >> 2;

            if (dcache_req_write) begin
                // wstrb的每一位控制一个有效字节。
                if (dcache_req_wstrb[0])
                    dmem[dmem_index][7:0] <= dcache_req_wdata[7:0];
                if (dcache_req_wstrb[1])
                    dmem[dmem_index][15:8] <= dcache_req_wdata[15:8];
                if (dcache_req_wstrb[2])
                    dmem[dmem_index][23:16] <= dcache_req_wdata[23:16];
                if (dcache_req_wstrb[3])
                    dmem[dmem_index][31:24] <= dcache_req_wdata[31:24];
                dcache_rsp_rdata <= 32'd0;
            end
            else begin
                dcache_rsp_rdata <= dmem[dmem_index];
            end

            dcache_rsp_valid <= 1'b1;
        end
    end
end


/* =========================== 结果观察 ============================= */

// 直接显示CPU通过MMIO UART打印的字符。
always @(posedge clk) begin
    if (rst_n && dbg_uart_tx_valid)
        $write("%c", dbg_uart_tx_data);
end

// 记录进入中断，以及随后跳回mepc的mret行为。
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        trap_count        <= 0;
        interrupt_entered <= 1'b0;
        mret_return_seen  <= 1'b0;
        mret_flush_ok     <= 1'b0;
    end
    else begin
        if (trap_enter) begin
            trap_count        <= trap_count + 1;
            interrupt_entered <= 1'b1;
            $display("\n[%0t] 进入中断：trap_pc=%08h mtvec=%08h",
                     $time, trap_pc, mtvec);
        end

        // mret在EX执行时会产生redirect，并把目标PC设为mepc。
        if (interrupt_entered && !trap_enter &&
            redirect && (redirect_pc == mepc)) begin
            mret_return_seen <= 1'b1;
            mret_flush_ok    <= flush_if_id && flush_id_ex &&
                                !flush_ex_mem;
            $display("[%0t] mret返回：PC=%08h", $time, mepc);
        end
    end
end

// C程序用这个写请求通知TB：整个测试程序已经运行结束。
wire done_write = dcache_req_valid && dcache_req_ready &&
                  dcache_req_write &&
                  (dcache_req_addr  == DONE_ADDR) &&
                  (dcache_req_wdata == DONE_MAGIC) &&
                  (dcache_req_wstrb == 4'b1111);


/* =========================== 主测试流程 =========================== */

integer init_index;
logic [31:0] saved_trap_pc;

initial begin
    void'($value$plusargs("IRAM_BIN=%s", iram_file));
    void'($value$plusargs("DRAM_BIN=%s", dram_file));

    rst_n     = 1'b0;
    dma_irq_i = 1'b0;

    // 未加载的指令填NOP，数据存储器清零。
    for (init_index = 0; init_index < MEM_WORDS;
         init_index = init_index + 1) begin
        imem[init_index] = 32'h0000_0013;
        dmem[init_index] = 32'd0;
    end

    load_raw_bin(iram_file, 1'b1);
    load_raw_bin(dram_file, 1'b0);

    repeat (10) @(posedge clk);
    @(negedge clk);
    rst_n = 1'b1;

    // 先保持IRQ；程序写好mtvec、mie、mstatus后才会真正响应。
    dma_irq_i = 1'b1;
    wait (irq_request === 1'b1);

    /*
     * trap_enter可能在一个上升沿的NBA阶段才变高。
     * 必须继续等到它在后续上升沿仍为高，才表示CPU和CSRFile
     * 真正采样并接受了这次中断。
     */
    @(posedge clk);
    while (trap_enter !== 1'b1)
        @(posedge clk);

    // 必须在ID/EX被冲刷更新之前保存当前EX指令的PC。
    saved_trap_pc = trap_pc;

    // 进入中断必须跳到mtvec，并冲刷IF/ID、ID/EX、EX/MEM。
    if (!redirect || (redirect_pc != mtvec) ||
        !flush_if_id || !flush_id_ex || !flush_ex_mem)
        $error("进入中断时PC跳转或流水线冲刷错误");

    /*
     * 等待当前上升沿的非阻塞赋值完成。此时CSRFile应当已经
     * 保存mepc并关闭mstatus.MIE，然后TB再模拟IRQ_CLEAR。
     */
    #1;
    dma_irq_i = 1'b0;

    // trap_enter的时钟沿后，CSRFile应该把trap_pc写入mepc。
    if (mepc != {saved_trap_pc[31:2], 2'b00})
        $error("mepc保存错误：mepc=%08h trap_pc=%08h",
               mepc, saved_trap_pc);

    wait (done_write === 1'b1);
    repeat (10) @(posedge clk);

    if ((trap_count == 1) && mret_return_seen && mret_flush_ok)
        $display("\n中断测试通过：进入1次，并通过mret正确返回");
    else
        $error("中断测试失败：trap_count=%0d mret_seen=%0b mret_flush_ok=%0b",
               trap_count, mret_return_seen, mret_flush_ok);

    $finish;
end


// 防止CPU、Cache或中断逻辑卡死。
initial begin
    #50_000_000;
    $fatal(1, "仿真超时");
end


`ifdef VCD_ON
initial begin
    $dumpfile("vcd_cpu_top.vcd");
    $dumpvars(0, testbench_cpu_top);
end
`endif

`ifdef DUMP
string fsdb_file;
initial begin
    if (!$value$plusargs("FSDB=%s", fsdb_file))
        fsdb_file = "fsdb/RTL.fsdb";
    $fsdbDumpfile(fsdb_file);
    $fsdbDumpvars(0, testbench_cpu_top, "+all");
    $fsdbDumpMDA();
end
`endif

endmodule
