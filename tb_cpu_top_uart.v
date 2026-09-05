`timescale 1ns/1ps

module tb_cpu_top_uart;

reg sys_clk_p;
reg sys_clk_n;
reg rst_n;
reg uart_rxd;
reg halt_cpu;

wire uart_txd;
wire dbg_uart_txd;
wire ldr_init_done;
wire ldr_busy;
wire ldr_pgm_done;
wire ldr_err;
wire [4:0] ldr_err_code;

// 115200 baud: 1 bit ~= 8680 ns.
localparam integer UART_BIT_TIME = 8680;

cpu_top u_cpu_top (
    .sys_clk_n     (sys_clk_n),
    .sys_clk_p     (sys_clk_p),
    .rst_n         (rst_n),
    .uart_rxd      (uart_rxd),
    .uart_txd      (uart_txd),
    .halt_cpu      (halt_cpu),
    .dbg_uart_txd  (dbg_uart_txd),
    .ldr_init_done (ldr_init_done),
    .ldr_busy      (ldr_busy),
    .ldr_pgm_done  (ldr_pgm_done),
    .ldr_err       (ldr_err),
    .ldr_err_code  (ldr_err_code)
);

// 100 MHz differential clock.
initial begin
    sys_clk_p = 1'b0;
    sys_clk_n = 1'b1;
    forever begin
        #5;
        sys_clk_p = ~sys_clk_p;
        sys_clk_n = ~sys_clk_n;
    end
end

// Send one UART byte on uart_rxd.
task uart_send_byte;
    input [7:0] data;
    integer i;
    begin
        uart_rxd = 1'b0;              // Start bit.
        #(UART_BIT_TIME);

        for (i = 0; i < 8; i = i + 1) begin
            uart_rxd = data[i];       // UART sends LSB first inside one byte.
            #(UART_BIT_TIME);
        end

        uart_rxd = 1'b1;              // Stop bit.
        #(UART_BIT_TIME);
    end
endtask

// Send one 32-bit word in big-endian byte order.
// The loader shifts received bytes into a 32-bit word as big endian.
task uart_send_word_be;
    input [31:0] word_data;
    begin
        uart_send_byte(word_data[31:24]);
        uart_send_byte(word_data[23:16]);
        uart_send_byte(word_data[15:8]);
        uart_send_byte(word_data[7:0]);
    end
endtask

// Receive one byte from dbg_uart_txd and print it in the simulator console.
task dbg_uart_recv_byte;
    output [7:0] data;
    integer i;
    begin
        @(negedge dbg_uart_txd);              // Start bit.
        #(UART_BIT_TIME + UART_BIT_TIME / 2); // Center of bit0.

        for (i = 0; i < 8; i = i + 1) begin
            data[i] = dbg_uart_txd;
            #(UART_BIT_TIME);
        end

        #(UART_BIT_TIME);                     // Stop bit time.
    end
endtask

// Send an IMEM package that contains RAW hazards and a load-use hazard.
task send_hazard_imem_program;
    begin
        // IMEM preamble: loader selects instruction RAM.
        uart_send_byte(8'hC0);
        uart_send_byte(8'hC0);
        uart_send_byte(8'hC0);
        uart_send_byte(8'hC0);

        // program_size = 11 instructions * 4 bytes = 44 bytes.
        uart_send_word_be(32'h0000_002C);

        // base_addr = 0, write from inst_mem[0].
        uart_send_word_be(32'h0000_0000);

        // 1. addi x1, x0, 5
        // x1 = 5.
        uart_send_word_be(32'h0050_0093);

        // 2. addi x2, x1, 3
        // x2 = x1 + 3 = 8.
        // RAW hazard: uses x1 immediately after it is produced, should be solved by forwarding.
        uart_send_word_be(32'h0030_8113);

        // 3. add x3, x2, x1
        // x3 = x2 + x1 = 13.
        // RAW hazard: uses x2 immediately after it is produced.
        uart_send_word_be(32'h0011_01B3);

        // 4. sw x3, 0(x0)
        // data_mem[0] = x3 = 13.
        // Store-data hazard: store uses the newly produced x3.
        uart_send_word_be(32'h0030_2023);

        // 5. lw x4, 0(x0)
        // x4 = data_mem[0] = 13.
        uart_send_word_be(32'h0000_2203);

        // 6. add x5, x4, x3
        // x5 = x4 + x3 = 26.
        // Load-use hazard: uses x4 right after lw, should stall one cycle.
        uart_send_word_be(32'h0032_02B3);

        // 7. addi x6, x5, 1
        // x6 = x5 + 1 = 27.
        // RAW hazard: uses x5 immediately after it is produced.
        uart_send_word_be(32'h0012_8313);

        // 8. addi x7, x0, 65
        // x7 = 65 = ASCII 'A'.
        uart_send_word_be(32'h0410_0393);

        // 9. lui x10, 0x10000
        // x10 = 0x1000_0000, the debug UART MMIO address.
        uart_send_word_be(32'h1000_0537);

        // 10. sb x7, 0(x10)
        // Write 8'h41 ('A') to 0x1000_0000, triggering debug_uart_tx.
        uart_send_word_be(32'h0075_0023);

        // 11. jal x0, 0
        // Infinite loop.
        uart_send_word_be(32'h0000_006F);

        // Postamble: end of IMEM package.
        uart_send_byte(8'hE0);
        uart_send_byte(8'hE0);
        uart_send_byte(8'hE0);
        uart_send_byte(8'hE0);
    end
endtask

// Send a legal empty DMEM package.
task send_empty_dmem_program;
    begin
        // DMEM preamble: loader selects data RAM.
        uart_send_byte(8'hD0);
        uart_send_byte(8'hD0);
        uart_send_byte(8'hD0);
        uart_send_byte(8'hD0);

        // program_size = 0.
        uart_send_word_be(32'h0000_0000);

        // base_addr = 0.
        uart_send_word_be(32'h0000_0000);

        // Postamble: end of DMEM package.
        uart_send_byte(8'hE0);
        uart_send_byte(8'hE0);
        uart_send_byte(8'hE0);
        uart_send_byte(8'hE0);
    end
endtask

reg [7:0] dbg_rx_data;

// 一直监听debug_uart，如果cpu通过其打印字符，就显示
initial begin
    forever begin
        dbg_uart_recv_byte(dbg_rx_data);
        $display("[%0t ns] dbg_uart_txd received: 0x%02h (%c)",
                 $time, dbg_rx_data, dbg_rx_data);
    end
end
    //复位系统
    //等 loader 准备好
    //通过 uart_rxd 下载 IMEM 程序
    //通过 uart_rxd 下载空 DMEM
    //等 CPU 执行
    //如果 CPU 打印 A，就在控制台显示 0x41 (A)
    //停止仿真
initial begin
    rst_n = 1'b0;
    uart_rxd = 1'b1;   // UART idle level.
    halt_cpu = 1'b0;

    #1000;
    rst_n = 1'b1;

    // Wait for loader initialization.
    wait (ldr_init_done == 1'b1);
    #(UART_BIT_TIME * 20);

    $display("[%0t ns] Start sending IMEM package.", $time);
    send_hazard_imem_program();

    // Wait for loader ACK byte after IMEM package.
    #(UART_BIT_TIME * 40);

    $display("[%0t ns] Start sending empty DMEM package.", $time);
    send_empty_dmem_program();

    // Wait for loader ACK and CPU execution.
    #(UART_BIT_TIME * 2000);

    if (ldr_err) begin
        $display("[%0t ns] Loader error, err_code = 0x%02h", $time, ldr_err_code);
    end

    $display("[%0t ns] Simulation finished.", $time);
    $stop;
end

endmodule
