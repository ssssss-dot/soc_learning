/*
 * DMA + AXIS +1 协处理器测试程序
 *
 * 数据流：
 *   1. dma_src[]位于.data段，生成DRAM镜像后由Loader在CPU启动前写入DDR；
 *   2. CPU通过MMIO配置DMA_SRC/DST/LEN/CONTROL；
 *   3. DMA从DDR读取dma_src[]，数据经过AXIS +1协处理器后写入dma_dst[]；
 *   4. DMA完成后产生机器外部中断；
 *   5. CPU逐字读取dma_dst[]，并通过UART MMIO打印结果。
 *
 * 约束：
 *   - 链接脚本必须把.data/.bss放在CPU地址0x8000_0000开始的区域；
 *   - DMA描述符使用DDR物理地址，当前映射基址为0x1000_0000；
 *   - SRC、DST必须4字节对齐，LEN必须是4的整数倍且不能为0；
 *   - DMA完成后需要让DCache失效，或者保证CPU在DMA前从未读取dma_dst[]。
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

#define DMA_CONTROL_START  (1u << 0)
#define DMA_CONTROL_IRQ_EN (1u << 1)

#define DMA_STATUS_BUSY    (1u << 0)
#define DMA_STATUS_DONE    (1u << 1)
#define DMA_STATUS_ERROR   (1u << 2)
#define DMA_STATUS_IRQ     (1u << 3)

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
    __attribute__((aligned(4), section(".bss.dma_dst")));

//这两个特殊初值不参与正常测试逻辑，赋值为了保证.data的链接段，程序开始时会自动清零
static volatile uint32_t dma_irq_done
    __attribute__((section(".data.dma_flag"))) = 0xA5A5A5A5u;

static volatile uint32_t dma_irq_count
    __attribute__((section(".data.dma_flag"))) = 0x5A5A5A5Au;

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
 * DMA完成后dma_irq保持为高，必须写IRQ_CLEAR清除，再执行mret。
 * interrupt("machine")会让编译器生成必要的现场保护和最后的mret。
 */
USED __attribute__((interrupt("machine"), aligned(4), section(".text.trap")))
void machine_external_irq_handler(void)
{
    uint32_t status = MMIO32(DMA_STATUS_ADDR);

    MMIO32(DMA_IRQ_CLEAR_ADDR) = 1u;
    compiler_barrier();

    dma_irq_count += 1u;
    dma_irq_done = (status & (DMA_STATUS_DONE | DMA_STATUS_ERROR));
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
 * DCache一致性测试准备：
 *
 * 1. CPU先向dma_dst写入确定的旧值；
 * 2. CPU再读取dma_dst，让这些旧值进入DCache；
 * 3. 随后DMA绕过DCache，直接把新值写入DDR。
 *
 * 如果DMA完成后没有清除DCache valid位，CPU会继续读到这些旧值。
 */
static uint32_t prepare_dcache_coherency_test(void)
{
    uint32_t index;
    uint32_t errors = 0u;

    uart_puts("Prepare DCache old data\r\n");

    /*
     * 先通过CPU向目的区域写入旧值。
     * 当前DCache的store最终会写入DDR，但是是writethrough，所以store时cache不会有东西
     */
    for (index = 0u; index < DMA_WORD_COUNT; ++index) {
        dma_dst[index] = DMA_DST_OLD_BASE + index;
    }

    compiler_barrier();

    /*
     * 再通过CPU读取目的区域。
     * 读取后，旧数据会被保存到DCache中。
     */
    for (index = 0u; index < DMA_WORD_COUNT; ++index) {
        uint32_t actual = dma_dst[index];
        uint32_t expected = DMA_DST_OLD_BASE + index;

        if (actual != expected) {
            uart_puts("Prepare error at [");
            uart_put_dec(index);
            uart_puts("], actual=");
            uart_put_hex32(actual);
            uart_puts(", expected=");
            uart_put_hex32(expected);
            uart_puts("\r\n");

            ++errors;
        }
    }

    compiler_barrier();

    return errors;
}

static void dma_start(void)
{
    uint32_t src_phys = cpu_addr_to_dma_phys(dma_src);
    uint32_t dst_phys = cpu_addr_to_dma_phys(dma_dst);
    uint32_t byte_len = (uint32_t)sizeof(dma_src);

    /* 先清除上一次可能残留的中断，再写入本次描述符。 */
    MMIO32(DMA_IRQ_CLEAR_ADDR) = 1u;
    MMIO32(DMA_SRC_ADDR) = src_phys;
    MMIO32(DMA_DST_ADDR) = dst_phys;
    /* 修改：分别配置 DMA 从 DDR 读取和向 DDR 写回的字节数。 */
    MMIO32(DMA_RDLEN_ADDR) = byte_len;
    MMIO32(DMA_WRLEN_ADDR) = byte_len;

    compiler_barrier();

    /* bit0=START，bit1=IRQ_EN。 */
    MMIO32(DMA_CONTROL_ADDR) = DMA_CONTROL_START | DMA_CONTROL_IRQ_EN;
}

static uint32_t check_and_print_result(void)
{
    uint32_t index;
    uint32_t errors = 0u;

    uart_puts("DMA result:\r\n");

    for (index = 0u; index < DMA_WORD_COUNT; ++index) {
        /*
         * 这一句从dma_dst[]取值，编译后会产生从DDR/DCache读取的lw。
         * 读取出的值再由uart_putc()产生对UART MMIO从机的sb写操作。
         */
        uint32_t actual = dma_dst[index];
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

/*
 * DMA完成后，在任何UART打印之前立即读取dma_dst。
 *
 * 如果读到DMA启动前写入的0xDEADxxxx，
 * 说明CPU仍然命中了没有被清除的DCache旧数据。
 */
static uint32_t detect_stale_dcache_data(void)
{
    uint32_t index;
    uint32_t stale_count = 0u;

    for (index = 0u; index < DMA_WORD_COUNT; ++index) {
        uint32_t actual = dma_dst[index];
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
    uint32_t prepare_errors;
    uint32_t stale_count;

    dma_irq_done = 0u;
    dma_irq_count = 0u;

    uart_puts("DMA test start\r\n");

    enable_dma_external_interrupt();

    /*
    * 必须在dma_start()之前执行：
    * 故意让DCache保存dma_dst的旧值。
    */
    prepare_errors = prepare_dcache_coherency_test();

    if (prepare_errors != 0u) {
        uart_puts("DCACHE PREPARE TEST FAIL\r\n");
        return 3;
    }

    /* DMA绕过DCache，直接更新DDR中的dma_dst。 */
    dma_start();

    /* DMA与CPU并行运行，CPU在这里等待DMA完成中断。 */
    while (dma_irq_done == 0u) {
        compiler_barrier();
    }

    status = MMIO32(DMA_STATUS_ADDR);
    if ((status & DMA_STATUS_ERROR) != 0u) {
        uart_puts("DMA AXI error, status=");
        uart_put_hex32(status);
        uart_puts("\r\n");
        return 1;
    }

    if ((status & DMA_STATUS_DONE) == 0u) {
        uart_puts("DMA completed without DONE flag, status=");
        uart_put_hex32(status);
        uart_puts("\r\n");
        return 2;
    }

    compiler_barrier();
    /*
    * 必须先检查一致性，再进行任何UART结果打印。
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
        uart_puts("DMA + DCACHE COHERENCY TEST PASS\r\n");
        return 0;
    }
    else {
        uart_puts("DMA + DCACHE COHERENCY TEST FAIL\r\n");

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
