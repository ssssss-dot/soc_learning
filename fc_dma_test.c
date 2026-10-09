/*
 * Bare-metal FC + DMA test for soc_top. Conv remains connected but is not run.
 * UART: byte writes to 0x40000000 -> dbg_uart_txd, 115200 baud, 8N1.
 * Link with linker.ld; load both instruction and data images via the Loader.
 * RV32I + machine CSRs; no libc, multiply/divide instructions or IRQ handler.
 * All mutable buffers are explicitly initialized (no CRT/BSS setup needed).
 *
 * DDR -> DMA -> shared BRAM -> FC -> BRAM -> DMA -> DDR -> CPU comparison.
 * Same dimensions as acc_demo.py: FC1 400->96, then FC2 96->64.
 * FC1's actual output is FC2's input. Synthetic deterministic data exercises
 * six/four PE groups, bias, ReLU, rounding, saturation and output guards.
 */
#include <stdint.h>

#define MMIO32(a) (*(volatile uint32_t *)(uintptr_t)(a))
#define ALIGN64 __attribute__((aligned(64)))
#define CPU_DDR_BASE  0x80000000u
#define DDR_PHYS_BASE 0x10000000u
#define UART_TX_ADDR  0x40000000u

#define DMA_SRC       0x40004000u
#define DMA_DST       0x40004004u
#define DMA_RD_LEN    0x40004008u
#define DMA_CONTROL   0x4000400Cu
#define DMA_STATUS    0x40004010u
#define DMA_IRQ_CLEAR 0x40004014u
#define DMA_WR_LEN    0x40004018u
#define DMA_IRQ_EN    0x40004020u
#define DMA_RD_OFFSET 0x40004024u
#define DMA_WR_OFFSET 0x40004028u
#define DMA_RD_START  (1u << 0)
#define DMA_WR_START  (1u << 2)
#define DMA_RD_BUSY   (1u << 0)
#define DMA_WR_BUSY   (1u << 1)
#define DMA_RD_DONE   (1u << 2)
#define DMA_WR_DONE   (1u << 3)
#define DMA_RD_ERROR  (1u << 4)
#define DMA_WR_ERROR  (1u << 5)

#define CONV_STATUS   0x40005004u
#define FC_CONTROL    0x40007000u
#define FC_STATUS     0x40007004u
#define FC_IN_COUNT   0x40007008u
#define FC_OUT_COUNT  0x4000700Cu
#define FC_INPUT_BASE 0x40007010u
#define FC_WEIGHT_BASE 0x40007014u
#define FC_BIAS_BASE  0x40007018u
#define FC_MULT       0x40007020u
#define FC_SHIFT      0x40007024u
#define FC_START      (1u << 0)
#define FC_RELU       (1u << 2)
#define FC_BUSY       (1u << 0)
#define FC_DONE       (1u << 1)
#define FC_ERROR      (1u << 2)

/* All FC BASE registers use BYTE offsets, including bias (unlike Conv). */
#define BRAM_INPUT   0x1000u
#define BRAM_WEIGHT  0x2000u
#define BRAM_BIAS    0xE000u
#define FC1_INPUTS   400u
#define FC1_OUTPUTS  96u
#define FC2_INPUTS   FC1_OUTPUTS
#define FC2_OUTPUTS  64u
#define MAX_WEIGHT_BYTES 38400u /* 6 groups * 400 features * 16 lanes */
#define GUARD_BYTES  16u
#define TIMEOUT      5000000u

static volatile int8_t input_data[FC1_INPUTS] ALIGN64;
static volatile int8_t weight_data[MAX_WEIGHT_BYTES] ALIGN64;
static volatile int32_t bias_data[FC1_OUTPUTS] ALIGN64;
static volatile uint8_t bram_seed[FC1_OUTPUTS + GUARD_BYTES] ALIGN64;
/* Two dedicated cache lines: result, BRAM guard and DDR destination guard. */
static volatile uint8_t output_data[128] ALIGN64;

/* Literal independent answers: no CPU software MAC is needed to judge FC. */
static const int8_t expected_fc1[FC1_OUTPUTS] = {
    113, 26, 0, 0, 0, 0, 0, 27, 115, 28, 0, 0, 0, 0, 0, 29,
    117, 30, 0, 0, 0, 0, 0, 31, 119, 32, 0, 0, 0, 0, 0, 33,
    121, 34, 0, 0, 0, 0, 0, 35, 123, 36, 0, 0, 0, 0, 0, 37,
    125, 38, 0, 0, 0, 0, 0, 39, 127, 40, 0, 0, 0, 0, 0, 41,
    127, 42, 0, 0, 0, 0, 0, 43, 127, 44, 0, 0, 0, 0, 0, 45,
    127, 46, 0, 0, 0, 0, 0, 47, 127, 48, 0, 0, 0, 0, 0, 49
};
static const int8_t expected_fc2[FC2_OUTPUTS] = {
    0, 0, 54, 0, 17, 44, 0, 35, 0, 0, 54, 0, 17, 45, 0, 36,
    0, 0, 55, 0, 18, 45, 0, 36, 0, 0, 55, 0, 18, 46, 0, 37,
    0, 0, 56, 0, 19, 46, 0, 37, 0, 0, 56, 0, 19, 47, 0, 38,
    0, 1, 57, 0, 20, 47, 0, 38, 0, 1, 57, 0, 20, 48, 0, 39
};

static inline void memory_fence(void)
{
    __asm__ volatile ("fence rw, rw" ::: "memory");
}

static void uart_putc(char c)
{
    /* Existing AXI UART path applies backpressure until it accepts the byte. */
    *(volatile uint8_t *)(uintptr_t)UART_TX_ADDR = (uint8_t)c;
}

static void uart_puts(const char *s)
{
    while (*s) uart_putc(*s++);
}

static void uart_hex(uint32_t value)
{
    static const char digits[] = "0123456789ABCDEF";
    int shift;
    uart_puts("0x");
    for (shift = 28; shift >= 0; shift -= 4)
        uart_putc(digits[(value >> (uint32_t)shift) & 15u]);
}

/* Only for -999..999 (all indices and INT8 results fit).
 * Fixed comparisons avoid countable subtraction loops: LLVM can replace
 * those loops with division/remainder and emit __udivsi3/__mulsi3 on RV32I.
 */
__attribute__((noinline)) static void uart_small_int(int32_t value)
{
    uint32_t digit = 0u;
    uint32_t started = 0u;
    if (value < 0) {
        uart_putc('-');
        value = -value;
    }
    if (value >= 800) { value -= 800; digit += 8u; }
    if (value >= 400) { value -= 400; digit += 4u; }
    if (value >= 200) { value -= 200; digit += 2u; }
    if (value >= 100) { value -= 100; digit += 1u; }
    if (digit) { uart_putc((char)('0' + digit)); started = 1u; }
    digit = 0u;
    if (value >= 80) { value -= 80; digit += 8u; }
    if (value >= 40) { value -= 40; digit += 4u; }
    if (value >= 20) { value -= 20; digit += 2u; }
    if (value >= 10) { value -= 10; digit += 1u; }
    if (digit || started) uart_putc((char)('0' + digit));
    uart_putc((char)('0' + value));
}

static int fail(const char *stage, uint32_t status)
{
    uart_puts("FAIL: "); uart_puts(stage);
    uart_puts(" status="); uart_hex(status);
    uart_puts("\r\n");
    return 1;
}

static uint32_t dma_address(const volatile void *p)
{
    return (uint32_t)(uintptr_t)p - CPU_DDR_BASE + DDR_PHYS_BASE;
}

static int dma_wait(uint32_t busy, uint32_t done, const char *stage)
{
    uint32_t count, status = 0u;
    for (count = 0u; count < TIMEOUT; ++count) {
        status = MMIO32(DMA_STATUS);
        if (status & (DMA_RD_ERROR | DMA_WR_ERROR)) return fail(stage, status);
        if ((status & done) && !(status & busy)) {
            memory_fence();
            return 0;
        }
    }
    uart_puts("TIMEOUT: ");
    return fail(stage, status);
}

static int dma_load(const volatile void *src, uint32_t size,
                    uint32_t offset, const char *stage)
{
    MMIO32(DMA_IRQ_CLEAR) = 15u;
    MMIO32(DMA_SRC) = dma_address(src);
    MMIO32(DMA_RD_LEN) = size;
    MMIO32(DMA_RD_OFFSET) = offset;
    memory_fence();
    /* Write a fresh command, never read/modify/write DMA_CONTROL. */
    MMIO32(DMA_CONTROL) = DMA_RD_START;
    return dma_wait(DMA_RD_BUSY, DMA_RD_DONE, stage);
}

static int dma_read_output(uint32_t output_count)
{
    MMIO32(DMA_IRQ_CLEAR) = 15u;
    MMIO32(DMA_DST) = dma_address(output_data);
    MMIO32(DMA_WR_LEN) = output_count + GUARD_BYTES;
    MMIO32(DMA_WR_OFFSET) = 0u;
    memory_fence();
    MMIO32(DMA_CONTROL) = DMA_WR_START;
    /* The SoC invalidates DCache on DMA write completion independently of IRQ. */
    return dma_wait(DMA_WR_BUSY, DMA_WR_DONE, "output BRAM -> DDR");
}

static void prepare_data(uint32_t layer, uint32_t input_count, uint32_t output_count)
{
    uint32_t i, group, k, lane, oc, ptr = 0u;
    for (i = 0u; i < input_count; ++i) {
        /* Save FC1 results before reinitializing the DMA destination below. */
        input_data[i] = layer == 0u
            ? (int8_t)((int32_t)(i & 15u) - 8) : (int8_t)output_data[i];
    }
    for (i = 0u; i < output_count; ++i) {
        /* Multiply the unsigned index before subtracting to avoid signed shifts. */
        bias_data[i] = layer == 0u ? (int32_t)(i << 2) - 192
                                  : (int32_t)(i << 3) - 256;
    }
    for (group = 0u; group < ((output_count + 15u) >> 4); ++group) {
        for (k = 0u; k < input_count; ++k) {
            for (lane = 0u; lane < 16u; ++lane) {
                int32_t weight = 0;
                oc = (group << 4) + lane;
                if (oc < output_count) {
                    uint32_t phase = layer == 0u ? oc : oc + (oc << 1);
                    weight = (int32_t)((k + phase) & 7u) - 3;
                }
                /* FC hardware order: [output group][input feature][PE lane]. */
                weight_data[ptr++] = (int8_t)weight;
            }
        }
    }
    for (i = 0u; i < sizeof(bram_seed); ++i) bram_seed[i] = 0xEEu;
    for (i = 0u; i < sizeof(output_data); ++i) output_data[i] = 0xA5u;
    memory_fence();
}

static int fc_config(uint32_t addr, uint32_t value)
{
    uint32_t actual;
    MMIO32(addr) = value;
    actual = MMIO32(addr);
    if (actual == value) return 0;
    uart_puts("FC register readback addr="); uart_hex(addr);
    uart_puts(" expected="); uart_hex(value); uart_puts("\r\n");
    return fail("FC configuration", actual);
}

static int run_fc(uint32_t layer, uint32_t input_count, uint32_t output_count)
{
    uint32_t count, status = 0u;
    MMIO32(FC_STATUS) = FC_DONE | FC_ERROR; /* W1C: remove previous completion. */
    if (fc_config(FC_IN_COUNT, input_count) ||
        fc_config(FC_OUT_COUNT, output_count) ||
        fc_config(FC_INPUT_BASE, BRAM_INPUT) ||
        fc_config(FC_WEIGHT_BASE, BRAM_WEIGHT) ||
        fc_config(FC_BIAS_BASE, BRAM_BIAS) ||
        fc_config(FC_MULT, 1u) ||
        fc_config(FC_SHIFT, layer == 0u ? 4u : 7u)) return 1;
    memory_fence();
    /* IRQ enable (bit1) stays zero: completion is polled, no trap needed. */
    MMIO32(FC_CONTROL) = FC_START | FC_RELU;
    for (count = 0u; count < TIMEOUT; ++count) {
        status = MMIO32(FC_STATUS);
        if (status & FC_ERROR) return fail("FC compute", status);
        /* A short job may finish before the first poll; do not require busy. */
        if ((status & FC_DONE) && !(status & FC_BUSY)) {
            memory_fence();
            return 0;
        }
    }
    uart_puts("TIMEOUT: ");
    return fail("FC compute", status);
}

static int check_output(uint32_t layer, uint32_t output_count)
{
    uint32_t i, errors = 0u;
    const int8_t *reference = layer == 0u ? expected_fc1 : expected_fc2;
    for (i = 0u; i < output_count; ++i) {
        int32_t actual = (int8_t)output_data[i];
        int32_t golden = reference[i];
        uart_puts("  out["); uart_small_int((int32_t)i);
        uart_puts("]="); uart_small_int(actual);
        uart_puts(" expected="); uart_small_int(golden);
        if (actual == golden) uart_puts(" OK\r\n");
        else { uart_puts(" MISMATCH\r\n"); ++errors; }
    }
    for (i = output_count; i < output_count + GUARD_BYTES; ++i) {
        if (output_data[i] != 0xEEu) {
            fail("BRAM output guard byte", i);
            ++errors;
        }
    }
    for (i = output_count + GUARD_BYTES; i < sizeof(output_data); ++i) {
        if (output_data[i] != 0xA5u) {
            fail("DDR DMA destination guard byte", i);
            ++errors;
        }
    }
    return errors != 0u;
}

__attribute__((noinline)) int fc_dma_test_main(void)
{
    uint32_t layer, status;
    uint32_t global_mie = 1u << 3;
    __asm__ volatile ("csrc mstatus, %0" :: "r"(global_mie) : "memory");
    uart_puts("\r\nFC + DMA test start (Conv connected, not started)\r\n");
    /* Do not touch shared BRAM if either engine or DMA is already running. */
    status = MMIO32(CONV_STATUS);
    if (status & 1u) return fail("Conv already busy; reset before test", status);
    status = MMIO32(FC_STATUS);
    if (status & FC_BUSY) return fail("FC already busy; reset before test", status);
    status = MMIO32(DMA_STATUS);
    if (status & (DMA_RD_BUSY | DMA_WR_BUSY | DMA_RD_ERROR | DMA_WR_ERROR))
        return fail("DMA not clean; reset before test", status);
    MMIO32(FC_CONTROL) = 0u;
    MMIO32(DMA_CONTROL) = 0u;
    MMIO32(DMA_IRQ_EN) = 0u;
    MMIO32(DMA_IRQ_CLEAR) = 15u;

    for (layer = 0u; layer < 2u; ++layer) {
        uint32_t inputs = layer == 0u ? FC1_INPUTS : FC2_INPUTS;
        uint32_t outputs = layer == 0u ? FC1_OUTPUTS : FC2_OUTPUTS;
        uint32_t weight_bytes = layer == 0u ? MAX_WEIGHT_BYTES : 6144u;
        uart_puts(layer == 0u ? "\r\n[FC1] 400 -> 96, ReLU, SHIFT=4\r\n"
                             : "\r\n[FC2] 96 -> 64, ReLU, SHIFT=7\r\n");
        prepare_data(layer, inputs, outputs);
        if (dma_load(bram_seed, outputs + GUARD_BYTES, 0u, "output guard DDR -> BRAM") ||
            dma_load(input_data, inputs, BRAM_INPUT, "input DDR -> BRAM") ||
            dma_load(weight_data, weight_bytes, BRAM_WEIGHT, "weights DDR -> BRAM") ||
            dma_load(bias_data, outputs << 2, BRAM_BIAS, "bias DDR -> BRAM"))
            goto failed;
        uart_puts("  BRAM load done\r\n");
        if (run_fc(layer, inputs, outputs)) goto failed;
        uart_puts("  FC compute done\r\n");
        if (dma_read_output(outputs)) goto failed;
        uart_puts("  Output DMA done\r\n");
        if (check_output(layer, outputs)) goto failed;
        MMIO32(FC_STATUS) = FC_DONE | FC_ERROR;
        status = MMIO32(FC_STATUS);
        if (status & (FC_DONE | FC_ERROR | FC_BUSY)) {
            fail("FC status clear", status);
            goto failed;
        }
        uart_puts("FC"); uart_small_int((int32_t)layer + 1);
        uart_puts(" PASS\r\n");
    }
    uart_puts("\r\nFC + DMA TEST PASS\r\n");
    return 0;

failed:
    uart_puts("DMA status="); uart_hex(MMIO32(DMA_STATUS));
    uart_puts(" FC status="); uart_hex(MMIO32(FC_STATUS));
    uart_puts("\r\nFC + DMA TEST FAIL\r\n");
    /* Do not start another DMA/FC job after timeout: ownership may be held. */
    return 1;
}

#ifndef FC_TEST_NO_START
__attribute__((used, naked, noreturn, section(".text.start")))
void _start(void)
{
    __asm__ volatile (
        "la sp, __stack_top\n"
        "call fc_dma_test_main\n"
        "1: j 1b\n"
    );
}
#endif
