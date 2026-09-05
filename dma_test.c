/*
 * DMA + AXIS +1 协处理器测试程序
 *
 * 数据流：
 *   1. dma_src[]位于.data段，生成DRAM镜像后由Loader在CPU启动前写入DDR；
 *   2. CPU通过MMIO配置DMA_SRC/DST/LEN/CONTROL；
 *   3. DMA从DDR读取dma_src[]，数据经过AXIS +1协处理器后写入dma_dst[]；
 *   4. 一次START并行启动读写任务，分两次机器外部中断打印读完成和写完成；
 *   5. CPU先在中断打印前保存读回快照，再处理两次中断并检查结果。
 *
 * 约束：
 *   - 链接脚本必须把.data/.bss放在CPU地址0x8000_0000开始的区域；
 *   - DMA描述符使用DDR物理地址，当前映射基址为0x1000_0000；
 *   - SRC、DST必须4字节对齐，LEN必须是4的整数倍且不能为0；
 *   - DMA完成后需要让DCache失效，或者保证CPU在DMA前从未读取dma_dst[]。
 *   - 两类事件共用一根IRQ，采用先读后写的中断使能，避免合并成一次通知；
 *   - 搬运和快照期间屏蔽IRQ；快照后再开放两次通知，验证失效不依赖IRQ。
 */

#include <stdint.h>

#define USED       __attribute__((used))
#define NOINLINE   __attribute__((noinline))

/* CPU访问DDR时使用的地址，以及DMA在AXI总线上使用的物理地址。 */
#define CPU_DDR_BASE       0x80000000u
#define DDR_PHYS_BASE      0x10000000u

/* UART和DMA控制寄存器的CPU MMIO地址。 */
#define UART_TX_ADDR       0x40000000u
#define DMA_SRC_ADDR       0x40004000u
#define DMA_DST_ADDR       0x40004004u
/* 修改：将原来的单一 DMA_LEN 寄存器拆分为读长度和写长度寄存器。 */
#define DMA_RDLEN_ADDR     0x40004008u
#define DMA_WRLEN_ADDR     0x40004018u
#define DMA_CONTROL_ADDR   0x4000400Cu
#define DMA_STATUS_ADDR    0x40004010u
#define DMA_IRQ_CLEAR_ADDR 0x40004014u
#define DMA_IRQ_STATUS_ADDR 0x4000401Cu
#define DMA_IRQ_ENABLE_ADDR 0x40004020u

#define DMA_CONTROL_START  (1u << 0)
#define DMA_CONTROL_IRQ_EN (1u << 1)

#define DMA_STATUS_BUSY    (1u << 0)
#define DMA_STATUS_DONE    (1u << 1)
#define DMA_STATUS_ERROR   (1u << 2)
#define DMA_STATUS_IRQ     (1u << 3)

/* IRQ_STATUS/IRQ_ENABLE/IRQ_CLEAR共用位定义，CLEAR为写1清除。 */
#define DMA_IRQ_READ_DONE  (1u << 0)
#define DMA_IRQ_WRITE_DONE (1u << 1)
#define DMA_IRQ_READ_ERROR (1u << 2)
#define DMA_IRQ_WRITE_ERROR (1u << 3)
#define DMA_IRQ_ERROR_MASK (DMA_IRQ_READ_ERROR | DMA_IRQ_WRITE_ERROR)
#define DMA_IRQ_DONE_MASK  (DMA_IRQ_READ_DONE | DMA_IRQ_WRITE_DONE)
#define DMA_IRQ_ALL_MASK   (DMA_IRQ_DONE_MASK | DMA_IRQ_ERROR_MASK)

#define MSTATUS_MIE_MASK   (1u << 3)
#define MIE_MEIE_MASK      (1u << 11)

#define DMA_WORD_COUNT     16u //dma处理16个字

#define MMIO32(addr) (*(volatile uint32_t *)(uintptr_t)(addr))

/* 用于判断CPU是否读到了DCache中的旧数据。 */
#define DMA_DST_OLD_BASE 0xDEAD0000u

static volatile uint32_t dma_src[DMA_WORD_COUNT]
    __attribute__((aligned(4), section(".data.dma_src"))) = {
        0x00000000u, 0x00000001u, 0x00000002u, 0x00000003u,
        0x00000010u, 0x00000020u, 0x00000030u, 0x00000040u,
        0x00000100u, 0x00000200u, 0x00000300u, 0x00000400u,
        0x12345678u, 0x7FFFFFFEu, 0x80000000u, 0xFFFFFFFEu
};

static volatile uint32_t dma_dst[DMA_WORD_COUNT]
    __attribute__((aligned(128), section(".bss.dma_dst")));

/* 快照在任何中断处理/打印之前生成，后续只检查快照。 */
static volatile uint32_t dma_dst_snapshot[DMA_WORD_COUNT]
    __attribute__((aligned(128), section(".bss.dma_snapshot")));

//特殊初值保证变量进入.data段；测试开始时由main显式清零。
static volatile uint32_t dma_irq_done
    __attribute__((section(".data.dma_flag"))) = 0xA5A5A5A5u;

static volatile uint32_t dma_irq_count
    __attribute__((section(".data.dma_flag"))) = 0x5A5A5A5Au;

static volatile uint32_t dma_irq_seen
    __attribute__((section(".data.dma_flag"))) = 0x12345678u;

//屏障前后的内存访问不能随意交换顺序
static inline void compiler_barrier(void)
{
    __asm__ volatile ("" ::: "memory");
}

/* CPU虚拟/内部地址转换成DMA直接访问Crossbar时使用的DDR物理地址。 */
static uint32_t cpu_addr_to_dma_phys(const volatile void *cpu_ptr)
{
    uint32_t cpu_addr = (uint32_t)(uintptr_t)cpu_ptr;
    return cpu_addr - CPU_DDR_BASE + DDR_PHYS_BASE;
}

/* UART从机只需要CPU向固定MMIO地址写入一个字节。 */
static void uart_putc(char value)
{
    *(volatile uint8_t *)(uintptr_t)UART_TX_ADDR = (uint8_t)value;
}

static void uart_puts(const char *text)
{
    while (*text != '\0') {
        uart_putc(*text);
        ++text;
    }
}

//打印32位十六进制数，一个32位数一共有8个十六进制位，每个十六进制位对应4 bit，从最高的4bit开始一组一组取出
static void uart_put_hex32(uint32_t value)
{
    static const char hex_table[] = "0123456789ABCDEF";
    int shift;

    uart_puts("0x");
    for (shift = 28; shift >= 0; shift -= 4) {
        uart_putc(hex_table[(value >> (uint32_t)shift) & 0xFu]);
    }
}

//这个函数把一个32位无符号整数转换成十进制字符，并通过UART打印
static void uart_put_dec(uint32_t value)
{
    static const uint32_t decimal_place[10] = {
        1000000000u, 100000000u, 10000000u, 1000000u, 100000u,
        10000u, 1000u, 100u, 10u, 1u
    };
    uint32_t place_index;
    uint32_t digit;
    uint32_t started = 0u;

    /*
     * 只使用比较和减法，避免RV32I编译时引入__udivsi3/__umodsi3，
     * 因而不依赖M扩展或额外的compiler-rt运行库。
     */
    for (place_index = 0u; place_index < 10u; ++place_index) {
        digit = 0u;

        while (value >= decimal_place[place_index]) {
            value -= decimal_place[place_index];
            ++digit;
        }

        if ((digit != 0u) || (started != 0u) || (place_index == 9u)) {
            uart_putc((char)('0' + digit));
            started = 1u;
        }
    }
}

/*
 * IRQ_STATUS即使对应中断未使能也会记录事件。
 * 先只使能读完成，处理并打印后才使能写完成；DMA本身始终并行运行。
 * 若写完成提前到达，其挂起位保留，返回后会再次进入中断。
 * 只清本次实际处理的原因，不能在第一次中断中把写完成也清掉。
 * interrupt("machine")会让编译器生成必要的现场保护和最后的mret。
 */
USED __attribute__((interrupt("machine"), aligned(4), section(".text.trap")))
void machine_external_irq_handler(void)
{
    uint32_t pending = MMIO32(DMA_IRQ_STATUS_ADDR);
    uint32_t enabled = MMIO32(DMA_IRQ_ENABLE_ADDR);
    uint32_t active = pending & enabled & DMA_IRQ_ALL_MASK;
    uint32_t next_enable = 0u;

    /* 打印期间暂时屏蔽通知，不清除尚未处理的挂起事件。 */
    MMIO32(DMA_IRQ_ENABLE_ADDR) = 0u;
    MMIO32(DMA_IRQ_CLEAR_ADDR) = active;
    compiler_barrier();

    dma_irq_count += 1u;
    dma_irq_seen |= active;

    if ((active & DMA_IRQ_ERROR_MASK) != 0u) {
        dma_irq_done = DMA_STATUS_ERROR;
    }
    else if ((active & DMA_IRQ_WRITE_DONE) != 0u) {
        dma_irq_done = DMA_STATUS_DONE;
    }
    else if ((active & DMA_IRQ_READ_DONE) != 0u) {
        /* 读完成不表示DDR结果已经写好，不设置dma_irq_done。 */
        next_enable = DMA_IRQ_WRITE_DONE | DMA_IRQ_ERROR_MASK;
    }
    else {
        /* 异常中断也打印，并结束等待，避免软件无期限空转。 */
        dma_irq_done = DMA_STATUS_ERROR;
    }

    uart_puts("DMA IRQ #");
    uart_put_dec(dma_irq_count);
    uart_puts(": ");
    if ((active & DMA_IRQ_READ_DONE) != 0u)
        uart_puts("READ_DONE ");
    if ((active & DMA_IRQ_WRITE_DONE) != 0u)
        uart_puts("WRITE_DONE ");
    if ((active & DMA_IRQ_READ_ERROR) != 0u)
        uart_puts("READ_ERROR ");
    if ((active & DMA_IRQ_WRITE_ERROR) != 0u)
        uart_puts("WRITE_ERROR ");
    if (active == 0u)
        uart_puts("UNEXPECTED ");
    uart_puts("active=");
    uart_put_hex32(active);
    uart_puts(", pending=");
    uart_put_hex32(pending);
    uart_puts("\r\n");

    /* 正常第一次中断后开放写完成；第二次或错误后保持屏蔽。 */
    compiler_barrier();
    MMIO32(DMA_IRQ_ENABLE_ADDR) = next_enable;
    compiler_barrier();
}

static void enable_dma_external_interrupt(void)
{
    uintptr_t trap_entry = (uintptr_t)&machine_external_irq_handler;
    uint32_t meie_mask = MIE_MEIE_MASK;
    uint32_t global_mie_mask = MSTATUS_MIE_MASK;

    __asm__ volatile (
        "csrw mtvec, %0\n"
        "csrs mie, %1\n"
        "csrs mstatus, %2\n"
        :
        : "r"(trap_entry), "r"(meie_mask), "r"(global_mie_mask)
        : "memory"
    );
}

/*
 * 关键区用一个内联汇编块：预热之后不允许编译器插入栈读取、
 * 函数调用或常量表读取，以免无失效时也因为替换缓存而假通过。
 * 当前DCache每行1个字、32组、写穿透且写不分配；
 * 128字节对齐的16个目标字占不同组，快照store不会分配/替换缓存行。
 * 返回0成功，1预热失败，2 DMA错误，3轮询超时。
 * 仅本函数写一次START。IRQ保持关闭，写完成脉冲必须独立使缓存失效。
 */
static uint32_t dma_run_coherency_test(uint32_t *status_out)
{
    uint32_t result;
    uint32_t status;

    __asm__ volatile (
        "li %[result], 0\n"
        "li %[status], 0\n"
        "mv t0, %[dst]\n"
        "li t1, %[count]\n"
        "li t2, %[old]\n"
        "1:\n"
        "sw t2, 0(t0)\n"
        "addi t0, t0, 4\n"
        "addi t2, t2, 1\n"
        "addi t1, t1, -1\n"
        "bnez t1, 1b\n"
        "mv t0, %[dst]\n"
        "li t1, %[count]\n"
        "li t2, %[old]\n"
        "2:\n"
        "lw t3, 0(t0)\n"
        "bne t3, t2, 6f\n"
        "addi t0, t0, 4\n"
        "addi t2, t2, 1\n"
        "addi t1, t1, -1\n"
        "bnez t1, 2b\n"
        "li t0, %[control]\n"
        "li t1, %[start]\n"
        "sw t1, 0(t0)\n"
        "li t0, %[status_addr]\n"
        "li t1, 1000000\n"
        "li t4, %[irq_status]\n"
        "3:\n"
        "lw %[status], 0(t0)\n"
        "lw t2, 0(t4)\n"
        "andi t2, t2, %[irq_errors]\n"
        "bnez t2, 7f\n"
        "andi t2, %[status], %[busy_done]\n"
        "li t3, %[done]\n"
        "beq t2, t3, 4f\n"
        "addi t1, t1, -1\n"
        "bnez t1, 3b\n"
        "li %[result], 3\n"
        "j 9f\n"
        "4:\n"
        "mv t0, %[dst]\n"
        "mv t1, %[snapshot]\n"
        "li t2, %[count]\n"
        "5:\n"
        "lw t3, 0(t0)\n"
        "sw t3, 0(t1)\n"
        "addi t0, t0, 4\n"
        "addi t1, t1, 4\n"
        "addi t2, t2, -1\n"
        "bnez t2, 5b\n"
        "j 9f\n"
        "6: li %[result], 1\n"
        "j 9f\n"
        "7: li %[result], 2\n"
        "9:\n"
        : [result] "=&r"(result), [status] "=&r"(status)
        : [dst] "r"(dma_dst), [snapshot] "r"(dma_dst_snapshot),
          [count] "i"(DMA_WORD_COUNT), [old] "i"(DMA_DST_OLD_BASE),
          [control] "i"(DMA_CONTROL_ADDR), [start] "i"(DMA_CONTROL_START),
          [status_addr] "i"(DMA_STATUS_ADDR), [irq_status] "i"(DMA_IRQ_STATUS_ADDR),
          [irq_errors] "i"(DMA_IRQ_ERROR_MASK),
          [busy_done] "i"(DMA_STATUS_BUSY | DMA_STATUS_DONE),
          [done] "i"(DMA_STATUS_DONE)
        : "t0", "t1", "t2", "t3", "t4", "memory"
    );

    *status_out = status;
    return result;
}

static void dma_configure(void)
{
    uint32_t src_phys = cpu_addr_to_dma_phys(dma_src);
    uint32_t dst_phys = cpu_addr_to_dma_phys(dma_dst);
    uint32_t byte_len = (uint32_t)sizeof(dma_src);

    /* 配置前屏蔽通知并清除全部旧原因；本测试不在BUSY期间修改描述符。 */
    MMIO32(DMA_IRQ_ENABLE_ADDR) = 0u;
    MMIO32(DMA_IRQ_CLEAR_ADDR) = DMA_IRQ_ALL_MASK;
    MMIO32(DMA_SRC_ADDR) = src_phys;
    MMIO32(DMA_DST_ADDR) = dst_phys;
    /* 修改：分别配置 DMA 从 DDR 读取和向 DDR 写回的字节数。 */
    MMIO32(DMA_RDLEN_ADDR) = byte_len;
    MMIO32(DMA_WRLEN_ADDR) = byte_len;

    /* 配置阶段不启动、不开放IRQ；START留给无缓存污染的关键区。 */
    MMIO32(DMA_CONTROL_ADDR) = 0u;
    compiler_barrier();
}

static uint32_t check_and_print_result(void)
{
    uint32_t index;
    uint32_t errors = 0u;

    uart_puts("DMA result:\r\n");

    for (index = 0u; index < DMA_WORD_COUNT; ++index) {
        /* 使用中断打印之前的快照，不重新读取可能已被替换的目标缓存。 */
        uint32_t actual = dma_dst_snapshot[index];
        uint32_t expected = dma_src[index] + 1u;

        uart_putc('[');
        uart_put_dec(index);
        uart_puts("] ");
        uart_put_hex32(actual);

        if (actual != expected) {
            uint32_t old_value = DMA_DST_OLD_BASE + index;

            /*
            * 如果实际值刚好等于DMA启动前写入的旧值，
            * 基本可以判断CPU命中了没有失效的DCache。
            */
            if (actual == old_value) {
                uart_puts("  DCACHE STALE DATA");
            }
            else {
                uart_puts("  DATA ERROR");
            }

            uart_puts(", expected=");
            uart_put_hex32(expected);
            ++errors;
        }

        uart_puts("\r\n");
    }

    return errors;
}

/* 在保存好的快照中检查旧值，打印不会改变这份测试证据。 */
static uint32_t detect_stale_dcache_data(void)
{
    uint32_t index;
    uint32_t stale_count = 0u;

    for (index = 0u; index < DMA_WORD_COUNT; ++index) {
        uint32_t actual = dma_dst_snapshot[index];
        uint32_t old_value = DMA_DST_OLD_BASE + index;

        if (actual == old_value) {
            ++stale_count;
        }
    }

    compiler_barrier();

    return stale_count;
}
NOINLINE int dma_test_main(void)
{
    uint32_t status;
    uint32_t errors;
    uint32_t test_result;
    uint32_t irq_timeout = 1000000u;
    uint32_t global_mie_mask = MSTATUS_MIE_MASK;
    uint32_t stale_count;

    __asm__ volatile ("csrc mstatus, %0" :: "r"(global_mie_mask) : "memory");
    dma_irq_done = 0u;
    dma_irq_count = 0u;
    dma_irq_seen = 0u;

    /* 开放CPU外部中断前，先关闭DMA通知并清除旧挂起位。 */
    MMIO32(DMA_CONTROL_ADDR) = 0u;
    MMIO32(DMA_IRQ_ENABLE_ADDR) = 0u;
    MMIO32(DMA_IRQ_CLEAR_ADDR) = DMA_IRQ_ALL_MASK;

    uart_puts("DMA test start\r\n");

    uart_puts("Coherency: IRQ masked, snapshot before ISR printing\r\n");
    dma_configure();
    test_result = dma_run_coherency_test(&status);
    if (test_result != 0u) {
        uart_puts("DMA coherency setup/transfer FAIL, code=");
        uart_put_dec(test_result);
        uart_puts(" (1=preload, 2=AXI error, 3=timeout), status=");
        uart_put_hex32(status);
        uart_puts("\r\n");
        return 3;
    }

    /*
     * 搬运已完成、快照已保存。只开放通知，不再次START。
     * sticky状态保留两类完成；ISR先处理读，再开放写，产生两次打印。
     */
    MMIO32(DMA_IRQ_ENABLE_ADDR) = DMA_IRQ_READ_DONE | DMA_IRQ_ERROR_MASK;
    MMIO32(DMA_CONTROL_ADDR) = DMA_CONTROL_IRQ_EN;
    compiler_barrier();
    enable_dma_external_interrupt();

    while ((dma_irq_done == 0u) && (irq_timeout != 0u)) {
        --irq_timeout;
        compiler_barrier();
    }
    if (dma_irq_done == 0u) {
        MMIO32(DMA_IRQ_ENABLE_ADDR) = 0u;
        uart_puts("DMA interrupt timeout\r\n");
        return 6;
    }

    status = MMIO32(DMA_STATUS_ADDR);
    if (((dma_irq_done | status) & DMA_STATUS_ERROR) != 0u) {
        uart_puts("DMA AXI error, status=");
        uart_put_hex32(status);
        uart_puts(", irq_seen=");
        uart_put_hex32(dma_irq_seen);
        uart_puts("\r\n");
        return 1;
    }

    if ((status & DMA_STATUS_DONE) == 0u) {
        uart_puts("DMA completed without DONE flag, status=");
        uart_put_hex32(status);
        uart_puts("\r\n");
        return 2;
    }

    if (((dma_irq_seen & DMA_IRQ_DONE_MASK) != DMA_IRQ_DONE_MASK) ||
        (dma_irq_count != 2u)) {
        uart_puts("DMA two-interrupt test FAIL, count=");
        uart_put_dec(dma_irq_count);
        uart_puts(", irq_seen=");
        uart_put_hex32(dma_irq_seen);
        uart_puts("\r\n");
        return 5;
    }

    compiler_barrier();
    /*
    * 扫描中断前快照，再打印结果；不受中断内缓存访问影响。
    */
    stale_count = detect_stale_dcache_data();

    /*
    * 一致性扫描结束后，再打印DMA的详细结果。
    */
    errors = check_and_print_result();

    if (stale_count != 0u) {
        uart_puts("DCache stale line count: ");
        uart_put_dec(stale_count);
        uart_puts("\r\n");
    }

    uart_puts("IRQ count: ");
    uart_put_dec(dma_irq_count);
    uart_puts("\r\n");

    if ((errors == 0u) && (stale_count == 0u)) {
        uart_puts("DMA TWO-IRQ + DCACHE COHERENCY TEST PASS\r\n");
        return 0;
    }
    else {
        uart_puts("DMA TWO-IRQ + DCACHE COHERENCY TEST FAIL\r\n");

        uart_puts("Data errors: ");
        uart_put_dec(errors);
        uart_puts("\r\n");

        uart_puts("Stale cache lines: ");
        uart_put_dec(stale_count);
        uart_puts("\r\n");

        return 4;
    }
}

/*
 * 裸机复位入口。CPU复位后没有硬件自动设置sp，所以必须先设置栈顶。
 * 0x8002_0000必须位于链接脚本分配的数据存储区范围内。
 */
USED __attribute__((naked, noreturn, section(".text.start")))
void _start(void)
{
    __asm__ volatile (
        "li sp, 0x80020000\n"
        "call dma_test_main\n"
        "1: j 1b\n"
    );
}
