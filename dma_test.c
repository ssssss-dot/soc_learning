/*
 * DMA + shared BRAM store-and-forward board test.
 *
 * Data path:
 *   DDR source -> DMA read channel -> bram_for_acc
 *   bram_for_acc -> DMA write channel -> DDR destination
 *
 * The read transfer fills BRAM first.  Its completion interrupt starts the
 * write transfer, which drains BRAM into the destination.
 */

#include <stdint.h>

#define USED       __attribute__((used))
#define NOINLINE   __attribute__((noinline))

#define CPU_DDR_BASE        0x80000000u
#define DDR_PHYS_BASE       0x10000000u

#define UART_TX_ADDR        0x40000000u
#define DMA_SRC_ADDR        0x40004000u
#define DMA_DST_ADDR        0x40004004u
#define DMA_RDLEN_ADDR      0x40004008u
#define DMA_CONTROL_ADDR    0x4000400Cu
#define DMA_STATUS_ADDR     0x40004010u
#define DMA_IRQ_CLEAR_ADDR  0x40004014u
#define DMA_WRLEN_ADDR      0x40004018u
#define DMA_IRQ_STATUS_ADDR 0x4000401Cu
#define DMA_IRQ_ENABLE_ADDR 0x40004020u

#define DMA_CONTROL_RD_START (1u << 0)
#define DMA_CONTROL_IRQ_EN   (1u << 1)
#define DMA_CONTROL_WR_START (1u << 2)

#define DMA_STATUS_RD_DONE    (1u << 2)
#define DMA_STATUS_WR_DONE    (1u << 3)
#define DMA_STATUS_RD_ERROR   (1u << 4)
#define DMA_STATUS_WR_ERROR   (1u << 5)
#define DMA_STATUS_ERROR_MASK (DMA_STATUS_RD_ERROR | DMA_STATUS_WR_ERROR)
#define DMA_STATUS_DONE_MASK  (DMA_STATUS_RD_DONE | DMA_STATUS_WR_DONE)

#define DMA_IRQ_READ_DONE   (1u << 0)
#define DMA_IRQ_WRITE_DONE  (1u << 1)
#define DMA_IRQ_READ_ERROR  (1u << 2)
#define DMA_IRQ_WRITE_ERROR (1u << 3)
#define DMA_IRQ_DONE_MASK   (DMA_IRQ_READ_DONE | DMA_IRQ_WRITE_DONE)
#define DMA_IRQ_ERROR_MASK  (DMA_IRQ_READ_ERROR | DMA_IRQ_WRITE_ERROR)
#define DMA_IRQ_ALL_MASK    (DMA_IRQ_DONE_MASK | DMA_IRQ_ERROR_MASK)

#define MSTATUS_MIE_MASK (1u << 3)
#define MIE_MEIE_MASK    (1u << 11)

#define DMA_WORD_COUNT 16u
#define DMA_TIMEOUT    1000000u

#define DMA_PHASE_IDLE       0u
#define DMA_PHASE_WAIT_READ  1u
#define DMA_PHASE_WAIT_WRITE 2u
#define DMA_PHASE_DONE       3u
#define DMA_PHASE_ERROR      4u

#define DMA_DST_OLD_BASE 0xDEAD0000u
#define MMIO32(addr) (*(volatile uint32_t *)(uintptr_t)(addr))

static volatile uint32_t dma_src[DMA_WORD_COUNT]
    __attribute__((aligned(4), section(".data.dma_src"))) = {
        0x00000000u, 0x00000001u, 0x00000002u, 0x00000003u,
        0x00000010u, 0x00000020u, 0x00000030u, 0x00000040u,
        0x00000100u, 0x00000200u, 0x00000300u, 0x00000400u,
        0x12345678u, 0x7FFFFFFEu, 0x80000000u, 0xFFFFFFFEu
};

static volatile uint32_t dma_dst[DMA_WORD_COUNT]
    __attribute__((aligned(128), section(".bss.dma_dst")));

static volatile uint32_t dma_phase
    __attribute__((section(".data.dma_flag"))) = 0xA5A5A5A5u;
static volatile uint32_t dma_irq_count
    __attribute__((section(".data.dma_flag"))) = 0x5A5A5A5Au;
static volatile uint32_t dma_irq_seen
    __attribute__((section(".data.dma_flag"))) = 0x12345678u;

static inline void compiler_barrier(void)
{
    __asm__ volatile ("" ::: "memory");
}

static uint32_t cpu_addr_to_dma_phys(const volatile void *cpu_ptr)
{
    uint32_t cpu_addr = (uint32_t)(uintptr_t)cpu_ptr;
    return cpu_addr - CPU_DDR_BASE + DDR_PHYS_BASE;
}

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

static void uart_put_hex32(uint32_t value)
{
    static const char hex_table[] = "0123456789ABCDEF";
    int shift;

    uart_puts("0x");
    for (shift = 28; shift >= 0; shift -= 4) {
        uart_putc(hex_table[(value >> (uint32_t)shift) & 0xFu]);
    }
}

static void uart_put_dec(uint32_t value)
{
    static const uint32_t decimal_place[10] = {
        1000000000u, 100000000u, 10000000u, 1000000u, 100000u,
        10000u, 1000u, 100u, 10u, 1u
    };
    uint32_t place_index;
    uint32_t digit;
    uint32_t started = 0u;

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
 * READ_DONE starts BRAM -> DDR.  WRITE_DONE means the full round trip ended.
 * The handler does not print, so UART latency cannot disturb DMA sequencing.
 */
USED __attribute__((interrupt("machine"), aligned(4), section(".text.trap")))
void machine_external_irq_handler(void)
{
    uint32_t pending = MMIO32(DMA_IRQ_STATUS_ADDR);
    uint32_t enabled = MMIO32(DMA_IRQ_ENABLE_ADDR);
    uint32_t active = pending & enabled & DMA_IRQ_ALL_MASK;

    dma_irq_count += 1u;
    dma_irq_seen |= active;

    if ((active & DMA_IRQ_ERROR_MASK) != 0u) {
        MMIO32(DMA_IRQ_CLEAR_ADDR) = active;
        MMIO32(DMA_IRQ_ENABLE_ADDR) = 0u;
        dma_phase = DMA_PHASE_ERROR;
    }
    else if (((active & DMA_IRQ_READ_DONE) != 0u) &&
             (dma_phase == DMA_PHASE_WAIT_READ)) {
        MMIO32(DMA_IRQ_CLEAR_ADDR) = DMA_IRQ_READ_DONE;
        dma_phase = DMA_PHASE_WAIT_WRITE;
        compiler_barrier();

        MMIO32(DMA_CONTROL_ADDR) =
            DMA_CONTROL_IRQ_EN | DMA_CONTROL_WR_START;
    }
    else if (((active & DMA_IRQ_WRITE_DONE) != 0u) &&
             (dma_phase == DMA_PHASE_WAIT_WRITE)) {
        MMIO32(DMA_IRQ_CLEAR_ADDR) = DMA_IRQ_WRITE_DONE;
        MMIO32(DMA_IRQ_ENABLE_ADDR) = 0u;
        dma_phase = DMA_PHASE_DONE;
    }
    else {
        MMIO32(DMA_IRQ_CLEAR_ADDR) = active;
        MMIO32(DMA_IRQ_ENABLE_ADDR) = 0u;
        dma_phase = DMA_PHASE_ERROR;
    }

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

static uint32_t prepare_and_warm_destination(void)
{
    uint32_t index;

    for (index = 0u; index < DMA_WORD_COUNT; ++index) {
        dma_dst[index] = DMA_DST_OLD_BASE + index;
    }
    compiler_barrier();

    for (index = 0u; index < DMA_WORD_COUNT; ++index) {
        if (dma_dst[index] != DMA_DST_OLD_BASE + index) {
            return 1u;
        }
    }
    return 0u;
}

static void configure_dma(void)
{
    uint32_t byte_len = (uint32_t)sizeof(dma_src);

    MMIO32(DMA_CONTROL_ADDR) = 0u;
    MMIO32(DMA_IRQ_ENABLE_ADDR) = 0u;
    MMIO32(DMA_IRQ_CLEAR_ADDR) = DMA_IRQ_ALL_MASK;

    MMIO32(DMA_SRC_ADDR) = cpu_addr_to_dma_phys(dma_src);
    MMIO32(DMA_DST_ADDR) = cpu_addr_to_dma_phys(dma_dst);
    MMIO32(DMA_RDLEN_ADDR) = byte_len;
    MMIO32(DMA_WRLEN_ADDR) = byte_len;
}

static uint32_t check_and_print_result(void)
{
    uint32_t index;
    uint32_t errors = 0u;

    uart_puts("BRAM DMA result:\r\n");
    for (index = 0u; index < DMA_WORD_COUNT; ++index) {
        uint32_t actual = dma_dst[index];
        uint32_t expected = dma_src[index];

        uart_putc('[');
        uart_put_dec(index);
        uart_puts("] actual=");
        uart_put_hex32(actual);
        uart_puts(" expected=");
        uart_put_hex32(expected);

        if (actual != expected) {
            uart_puts("  ERROR");
            ++errors;
        }
        uart_puts("\r\n");
    }

    return errors;
}

NOINLINE int dma_test_main(void)
{
    uint32_t global_mie_mask = MSTATUS_MIE_MASK;
    uint32_t timeout = DMA_TIMEOUT;
    uint32_t status;
    uint32_t errors;

    __asm__ volatile ("csrc mstatus, %0" :: "r"(global_mie_mask) : "memory");

    uart_puts("DDR -> BRAM -> DDR DMA test start\r\n");

    dma_phase = DMA_PHASE_IDLE;
    dma_irq_count = 0u;
    dma_irq_seen = 0u;

    if (prepare_and_warm_destination() != 0u) {
        uart_puts("Destination preload failed\r\n");
        return 1;
    }

    configure_dma();
    MMIO32(DMA_IRQ_ENABLE_ADDR) = DMA_IRQ_ALL_MASK;
    dma_phase = DMA_PHASE_WAIT_READ;
    compiler_barrier();
    enable_dma_external_interrupt();

    uart_puts("Step 1: DDR -> BRAM\r\n");
    MMIO32(DMA_CONTROL_ADDR) =
        DMA_CONTROL_IRQ_EN | DMA_CONTROL_RD_START;

    while ((dma_phase != DMA_PHASE_DONE) &&
           (dma_phase != DMA_PHASE_ERROR) &&
           (timeout != 0u)) {
        --timeout;
        compiler_barrier();
    }

    status = MMIO32(DMA_STATUS_ADDR);
    MMIO32(DMA_IRQ_ENABLE_ADDR) = 0u;

    if (timeout == 0u) {
        uart_puts("DMA timeout, phase=");
        uart_put_dec(dma_phase);
        uart_puts(", status=");
        uart_put_hex32(status);
        uart_puts("\r\n");
        return 2;
    }

    if ((dma_phase == DMA_PHASE_ERROR) ||
        ((status & DMA_STATUS_ERROR_MASK) != 0u)) {
        uart_puts("DMA error, irq_status=");
        uart_put_hex32(MMIO32(DMA_IRQ_STATUS_ADDR));
        uart_puts(", status=");
        uart_put_hex32(status);
        uart_puts("\r\n");
        return 3;
    }

    if ((status & DMA_STATUS_DONE_MASK) != DMA_STATUS_DONE_MASK) {
        uart_puts("DMA DONE flags missing, status=");
        uart_put_hex32(status);
        uart_puts("\r\n");
        return 4;
    }

    if (((dma_irq_seen & DMA_IRQ_DONE_MASK) != DMA_IRQ_DONE_MASK) ||
        (dma_irq_count != 2u)) {
        uart_puts("Unexpected IRQ sequence, count=");
        uart_put_dec(dma_irq_count);
        uart_puts(", seen=");
        uart_put_hex32(dma_irq_seen);
        uart_puts("\r\n");
        return 5;
    }

    uart_puts("Step 2: BRAM -> DDR complete\r\n");
    errors = check_and_print_result();

    uart_puts("IRQ count=");
    uart_put_dec(dma_irq_count);
    uart_puts(", final status=");
    uart_put_hex32(status);
    uart_puts("\r\n");

    if (errors == 0u) {
        uart_puts("DDR -> BRAM -> DDR DMA TEST PASS\r\n");
        return 0;
    }

    uart_puts("DDR -> BRAM -> DDR DMA TEST FAIL, errors=");
    uart_put_dec(errors);
    uart_puts("\r\n");
    return 6;
}

USED __attribute__((naked, noreturn, section(".text.start")))
void _start(void)
{
    __asm__ volatile (
        "li sp, 0x80020000\n"
        "call dma_test_main\n"
        "1: j 1b\n"
    );
}
