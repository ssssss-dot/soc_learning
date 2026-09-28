/*
 * Bare-metal Conv1/Conv2 + DMA board test.
 *
 * Data flow for each layer:
 *   CPU prepares input/weights/bias in DDR
 *   DMA copies the three regions from DDR to the shared accelerator BRAM
 *   Conv accelerator reads BRAM and writes its INT8 output at BRAM byte 0
 *   DMA copies the output from BRAM back to DDR
 *   CPU checks every output byte and reports the result through UART
 *
 * Conv1 uses a non-constant 32x32 input. Its original closed-form expected
 * calculation is checked against a literal oracle, with pre-DMA arithmetic
 * probes and deferred mismatch logging (see conv_dma_test_diagnostics.md).
 * Conv2 cannot consume a real pooled Conv1 output
 * yet, so it is run independently with a deterministic synthetic 6x14x14
 * input.  This still checks its six-input-channel accumulation path.
 */

#include <stdint.h>
#ifdef CONV_DIAG_HOST_TEST
#include <stdio.h>
#endif

#define USED       __attribute__((used))
#define NOINLINE   __attribute__((noinline))
#define ALIGNED4   __attribute__((aligned(4)))
#define ALIGNED64  __attribute__((aligned(64)))

#ifdef CONV_DIAG_HOST_TEST
#define BSS_SECTION(name)
#else
#define BSS_SECTION(name) __attribute__((section(name)))
#endif

#if defined(__clang__)
#define DIAG_NOOPT __attribute__((noinline, optnone))
#elif defined(__GNUC__)
#define DIAG_NOOPT __attribute__((noinline, optimize("O0")))
#else
#define DIAG_NOOPT NOINLINE
#endif

#define CPU_DDR_BASE  0x80000000u
#define DDR_PHYS_BASE 0x10000000u
#define UART_TX_ADDR  0x40000000u

/* DMA MMIO registers. */
#define DMA_SRC_ADDR            0x40004000u
#define DMA_DST_ADDR            0x40004004u
#define DMA_RDLEN_ADDR          0x40004008u
#define DMA_CONTROL_ADDR        0x4000400Cu
#define DMA_STATUS_ADDR         0x40004010u
#define DMA_IRQ_CLEAR_ADDR      0x40004014u
#define DMA_WRLEN_ADDR          0x40004018u
#define DMA_IRQ_ENABLE_ADDR     0x40004020u
#define DMA_RD_BYTE_OFFSET_ADDR 0x40004024u
#define DMA_WR_BYTE_OFFSET_ADDR 0x40004028u

#define DMA_CONTROL_RD_START (1u << 0)
#define DMA_CONTROL_WR_START (1u << 2)
#define DMA_STATUS_RD_BUSY   (1u << 0)
#define DMA_STATUS_WR_BUSY   (1u << 1)
#define DMA_STATUS_RD_DONE   (1u << 2)
#define DMA_STATUS_WR_DONE   (1u << 3)
#define DMA_STATUS_RD_ERROR  (1u << 4)
#define DMA_STATUS_WR_ERROR  (1u << 5)
#define DMA_IRQ_ALL_MASK     0x0Fu

/* Conv MMIO registers. */
#define CONV_CONTROL_ADDR     0x40005000u
#define CONV_STATUS_ADDR      0x40005004u
#define CONV_INPUT_SHAPE_ADDR 0x40005008u
#define CONV_CHANNELS_ADDR    0x4000500Cu
#define CONV_BIAS_BASE_ADDR   0x40005010u
#define CONV_QUANT_MULT_ADDR  0x40005014u
#define CONV_QUANT_SHIFT_ADDR 0x40005018u
#define CONV_INPUT_BASE_ADDR  0x4000501Cu
#define CONV_WEIGHT_BASE_ADDR 0x40005020u

#define CONV_CONTROL_START (1u << 0)
#define CONV_STATUS_BUSY   (1u << 0)
#define CONV_STATUS_DONE   (1u << 1)
#define CONV_STATUS_ERROR  (1u << 2)

/* Shared BRAM layout.  All offsets are byte offsets. */
#define BRAM_OUTPUT_OFFSET 0x0000u
#define BRAM_INPUT_OFFSET  0x2000u
#define BRAM_WEIGHT_OFFSET 0x4000u
#define BRAM_BIAS_OFFSET   0x6000u
#define BRAM_BIAS_WORD_ADDR (BRAM_BIAS_OFFSET >> 2)

#define CONV1_INPUT_W  32u
#define CONV1_INPUT_H  32u
#define CONV1_INPUT_C  1u
#define CONV1_OUTPUT_W 28u
#define CONV1_OUTPUT_H 28u
#define CONV1_OUTPUT_C 6u
#define CONV1_INPUT_BYTES  1024u
#define CONV1_WEIGHT_BYTES 400u  /* 1 input channel x 16 PE rows x 5 x 5 */
#define CONV1_BIAS_BYTES   24u
#define CONV1_OUTPUT_BYTES 4704u /* 6 x 28 x 28 */

#define CONV2_INPUT_W  14u
#define CONV2_INPUT_H  14u
#define CONV2_INPUT_C  6u
#define CONV2_OUTPUT_W 10u
#define CONV2_OUTPUT_H 10u
#define CONV2_OUTPUT_C 16u
#define CONV2_INPUT_BYTES  1176u /* 6 x 14 x 14 */
#define CONV2_WEIGHT_BYTES 2400u /* 6 input channels x 16 PE rows x 5 x 5 */
#define CONV2_BIAS_BYTES   64u
#define CONV2_OUTPUT_BYTES 1600u /* 16 x 10 x 10 */

#define DMA_TIMEOUT  5000000u
#define CONV_TIMEOUT 5000000u
#define MAX_PRINTED_MISMATCHES 8u

#define MMIO32(addr) (*(volatile uint32_t *)(uintptr_t)(addr))

/* BSS is explicitly initialized by this program; no C runtime is required. */
static volatile uint8_t conv1_input[CONV1_INPUT_BYTES]
    ALIGNED64 BSS_SECTION(".bss.conv1_input");
static volatile uint8_t conv1_weights[CONV1_WEIGHT_BYTES]
    ALIGNED4 BSS_SECTION(".bss.conv1_weights");
static volatile int32_t conv1_bias[CONV1_OUTPUT_C]
    ALIGNED4 BSS_SECTION(".bss.conv1_bias");
static volatile uint8_t conv1_output[CONV1_OUTPUT_BYTES]
    ALIGNED64 BSS_SECTION(".bss.conv1_output");

static volatile uint8_t conv2_input[CONV2_INPUT_BYTES]
    ALIGNED64 BSS_SECTION(".bss.conv2_input");
static volatile uint8_t conv2_weights[CONV2_WEIGHT_BYTES]
    ALIGNED4 BSS_SECTION(".bss.conv2_weights");
static volatile int32_t conv2_bias[CONV2_OUTPUT_C]
    ALIGNED4 BSS_SECTION(".bss.conv2_bias");
static volatile uint8_t conv2_output[CONV2_OUTPUT_BYTES]
    ALIGNED64 BSS_SECTION(".bss.conv2_output");

static inline void memory_fence(void)
{
#ifndef CONV_DIAG_HOST_TEST
    __asm__ volatile ("fence rw, rw" ::: "memory");
#endif
}

static uint32_t cpu_addr_to_dma_phys(const volatile void *cpu_ptr)
{
    uint32_t cpu_addr = (uint32_t)(uintptr_t)cpu_ptr;
    return cpu_addr - CPU_DDR_BASE + DDR_PHYS_BASE;
}

static void uart_putc(char value)
{
#ifdef CONV_DIAG_HOST_TEST
    putchar((unsigned char)value);
#else
    *(volatile uint8_t *)(uintptr_t)UART_TX_ADDR = (uint8_t)value;
#endif
}

static void uart_puts(const char *text)
{
    while (*text != '\0') {
        uart_putc(*text);
        ++text;
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

static void uart_put_hex8(uint8_t value)
{
    static const char hex_table[] = "0123456789ABCDEF";
    uart_putc(hex_table[(value >> 4) & 0x0Fu]);
    uart_putc(hex_table[value & 0x0Fu]);
}

static void uart_put_hex32(uint32_t value)
{
    static const char hex_table[] = "0123456789ABCDEF";
    int shift;

    uart_puts("0x");
    for (shift = 28; shift >= 0; shift -= 4)
        uart_putc(hex_table[(value >> (uint32_t)shift) & 0x0Fu]);
}

static void print_status_error(const char *stage, uint32_t status)
{
    uart_puts(stage);
    uart_puts(" failed, status=");
    uart_put_hex32(status);
    uart_puts("\r\n");
}

static uint32_t dma_wait(uint32_t busy_mask,
                         uint32_t done_mask,
                         uint32_t error_mask)
{
    uint32_t timeout = DMA_TIMEOUT;
    uint32_t status = 0u;

    while (timeout != 0u) {
        status = MMIO32(DMA_STATUS_ADDR);
        if ((status & error_mask) != 0u)
            return status;
        if (((status & done_mask) != 0u) && ((status & busy_mask) == 0u))
            return 0u;
        --timeout;
    }

    return status | 0x80000000u;
}

/* Copy one DDR buffer into a selected byte region of the shared BRAM. */
static uint32_t dma_ddr_to_bram(const volatile void *source,
                                uint32_t byte_count,
                                uint32_t bram_byte_offset)
{
    uint32_t status;

    MMIO32(DMA_IRQ_CLEAR_ADDR) = DMA_IRQ_ALL_MASK;
    MMIO32(DMA_SRC_ADDR) = cpu_addr_to_dma_phys(source);
    MMIO32(DMA_RDLEN_ADDR) = byte_count;
    MMIO32(DMA_RD_BYTE_OFFSET_ADDR) = bram_byte_offset;
    memory_fence();
    MMIO32(DMA_CONTROL_ADDR) = DMA_CONTROL_RD_START;

    status = dma_wait(DMA_STATUS_RD_BUSY,
                      DMA_STATUS_RD_DONE,
                      DMA_STATUS_RD_ERROR);
    memory_fence();
    return status;
}

/* Copy one byte region of the shared BRAM back to a DDR buffer. */
static uint32_t dma_bram_to_ddr(volatile void *destination,
                                uint32_t byte_count,
                                uint32_t bram_byte_offset)
{
    uint32_t status;

    MMIO32(DMA_IRQ_CLEAR_ADDR) = DMA_IRQ_ALL_MASK;
    MMIO32(DMA_DST_ADDR) = cpu_addr_to_dma_phys(destination);
    MMIO32(DMA_WRLEN_ADDR) = byte_count;
    MMIO32(DMA_WR_BYTE_OFFSET_ADDR) = bram_byte_offset;
    memory_fence();
    MMIO32(DMA_CONTROL_ADDR) = DMA_CONTROL_WR_START;

    status = dma_wait(DMA_STATUS_WR_BUSY,
                      DMA_STATUS_WR_DONE,
                      DMA_STATUS_WR_ERROR);
    memory_fence();
    return status;
}

static uint32_t load_layer_to_bram(const volatile void *input,
                                   uint32_t input_bytes,
                                   const volatile void *weights,
                                   uint32_t weight_bytes,
                                   const volatile void *bias,
                                   uint32_t bias_bytes)
{
    uint32_t status;

    status = dma_ddr_to_bram(input, input_bytes, BRAM_INPUT_OFFSET);
    if (status != 0u) {
        print_status_error("DMA input load", status);
        return 1u;
    }

    status = dma_ddr_to_bram(weights, weight_bytes, BRAM_WEIGHT_OFFSET);
    if (status != 0u) {
        print_status_error("DMA weight load", status);
        return 2u;
    }

    status = dma_ddr_to_bram(bias, bias_bytes, BRAM_BIAS_OFFSET);
    if (status != 0u) {
        print_status_error("DMA bias load", status);
        return 3u;
    }

    return 0u;
}

static uint32_t run_conv(uint32_t input_width,
                         uint32_t input_height,
                         uint32_t input_channels,
                         uint32_t output_channels,
                         uint32_t quant_mult,
                         uint32_t quant_shift)
{
    uint32_t timeout = CONV_TIMEOUT;
    uint32_t status;
    uint32_t saw_busy = 0u;

    MMIO32(CONV_INPUT_SHAPE_ADDR) =
        ((input_height & 0xFFFFu) << 16) | (input_width & 0xFFFFu);
    MMIO32(CONV_CHANNELS_ADDR) =
        ((output_channels & 0xFFFFu) << 16) |
        (input_channels & 0xFFFFu);
    MMIO32(CONV_BIAS_BASE_ADDR) = BRAM_BIAS_WORD_ADDR;
    MMIO32(CONV_QUANT_MULT_ADDR) = quant_mult;
    MMIO32(CONV_QUANT_SHIFT_ADDR) = quant_shift;
    MMIO32(CONV_INPUT_BASE_ADDR) = BRAM_INPUT_OFFSET;
    MMIO32(CONV_WEIGHT_BASE_ADDR) = BRAM_WEIGHT_OFFSET;
    memory_fence();
    MMIO32(CONV_CONTROL_ADDR) = CONV_CONTROL_START;

    while (timeout != 0u) {
        status = MMIO32(CONV_STATUS_ADDR);
        if ((status & CONV_STATUS_ERROR) != 0u)
            return status;
        if ((status & CONV_STATUS_BUSY) != 0u)
            saw_busy = 1u;
        if ((saw_busy != 0u) &&
            ((status & CONV_STATUS_DONE) != 0u) &&
            ((status & CONV_STATUS_BUSY) == 0u)) {
            memory_fence();
            return 0u;
        }
        --timeout;
    }

    return status | 0x80000000u;
}

static uint8_t quantize_positive(uint32_t value, uint32_t shift)
{
    if (shift != 0u)
        value += 1u << (shift - 1u);
    value >>= shift;
    if (value > 127u)
        value = 127u;
    return (uint8_t)value;
}

static void prepare_conv1_data(void)
{
    uint32_t x;
    uint32_t y;
    uint32_t i;

    /* The spatial pattern makes wrong pixel order/window addressing visible. */
    for (y = 0u; y < CONV1_INPUT_H; ++y) {
        for (x = 0u; x < CONV1_INPUT_W; ++x) {
            conv1_input[(y << 5) + x] =
                (uint8_t)((x + y + (y << 1)) & 3u);
        }
    }

    for (i = 0u; i < CONV1_WEIGHT_BYTES; ++i)
        conv1_weights[i] = 1u;

    for (i = 0u; i < CONV1_OUTPUT_C; ++i)
        conv1_bias[i] = (int32_t)i;

    for (i = 0u; i < CONV1_OUTPUT_BYTES; ++i)
        conv1_output[i] = 0xEEu;

    memory_fence();
}

static uint8_t conv1_expected(uint32_t output_channel,
                              uint32_t output_y,
                              uint32_t output_x)
{
    uint32_t sum = 36u + ((output_x - output_y) & 3u)
                         + output_channel;

    return quantize_positive(sum, 0u);
}

/* Independent literal oracle: [channel][(y mod 4)*4 + (x mod 4)].
 * Volatile forces runtime loads, so this cannot become the original formula.
 * It applies ONLY to prepare_conv1_data(): all-one weights, bias=channel.
 */
static const volatile uint8_t conv1_golden_table[6][16] = {
    { 36u, 37u, 38u, 39u, 39u, 36u, 37u, 38u, 38u, 39u, 36u, 37u, 37u, 38u, 39u, 36u },
    { 37u, 38u, 39u, 40u, 40u, 37u, 38u, 39u, 39u, 40u, 37u, 38u, 38u, 39u, 40u, 37u },
    { 38u, 39u, 40u, 41u, 41u, 38u, 39u, 40u, 40u, 41u, 38u, 39u, 39u, 40u, 41u, 38u },
    { 39u, 40u, 41u, 42u, 42u, 39u, 40u, 41u, 41u, 42u, 39u, 40u, 40u, 41u, 42u, 39u },
    { 40u, 41u, 42u, 43u, 43u, 40u, 41u, 42u, 42u, 43u, 40u, 41u, 41u, 42u, 43u, 40u },
    { 41u, 42u, 43u, 44u, 44u, 41u, 42u, 43u, 43u, 44u, 41u, 42u, 42u, 43u, 44u, 41u }
};
static const volatile uint32_t conv1_golden_checksums[6] = {
    29400u, 30184u, 30968u, 31752u, 32536u, 33320u
};

static uint8_t conv1_golden(uint32_t channel, uint32_t y, uint32_t x)
{
    return conv1_golden_table[channel][((y & 3u) << 2) | (x & 3u)];
}

typedef struct {
    uint32_t index, channel, y, x;
    uint32_t actual, original, golden, actual_again;
    uint32_t diff, phase, base, split, add_form, retry, tight, spaced;
} conv1_diag_record;

static volatile conv1_diag_record conv1_bad[MAX_PRINTED_MISMATCHES];
static volatile conv1_diag_record conv1_first[CONV1_OUTPUT_C];
static volatile uint32_t conv1_actual_sums[CONV1_OUTPUT_C];
static volatile uint32_t conv1_original_sums[CONV1_OUTPUT_C];

/* Exact RV32I arithmetic sequences. Both must produce the SAME answer.
 * Four NOPs separate dependent operations in the spaced probe.
 * These probes help localize hazards; they do not prove a particular RTL bug.
 */
#define DIAG_GAP "nop\n\tnop\n\tnop\n\tnop\n\t"

static NOINLINE uint32_t conv1_asm_probe(uint32_t channel, uint32_t y,
                                       uint32_t x, uint32_t spaced)
{
#ifdef CONV_DIAG_HOST_TEST
    (void)spaced;
    return 36u + ((x - y) & 3u) + channel;
#else
    uint32_t result;
    if (spaced != 0u) {
        __asm__ volatile (
            "sub %[r], %[x], %[y]\n\t"
            DIAG_GAP
            "andi %[r], %[r], 3\n\t"
            DIAG_GAP
            "addi %[r], %[r], 36\n\t"
            DIAG_GAP
            "add %[r], %[r], %[c]\n\t"
            : [r] "=&r" (result)
            : [x] "r" (x), [y] "r" (y), [c] "r" (channel)
        );
    } else {
        __asm__ volatile (
            "sub %[r], %[x], %[y]\n\t"
            "andi %[r], %[r], 3\n\t"
            "addi %[r], %[r], 36\n\t"
            "add %[r], %[r], %[c]\n\t"
            : [r] "=&r" (result)
            : [x] "r" (x), [y] "r" (y), [c] "r" (channel)
        );
    }
    return result;
#endif
}

/* Compute these AFTER the original scan. They are replays, not a trace of
 * the original ALU intermediates. Volatile fields also exercise store/load.
 */
static DIAG_NOOPT void conv1_diag_replay(volatile conv1_diag_record *r)
{
    uint32_t c = r->channel;
    uint32_t y = r->y;
    uint32_t x = r->x;

    r->diff = x - y;
    r->phase = r->diff & 3u;
    r->base = 36u + r->phase;
    r->split = r->base + c;
    r->add_form = 36u + ((x + y + (y << 1)) & 3u) + c;
    r->retry = conv1_expected(c, y, x);
    r->tight = conv1_asm_probe(c, y, x, 0u);
    r->spaced = conv1_asm_probe(c, y, x, 1u);
}

static void diag_hex(const char *name, uint32_t value)
{
    uart_puts(name);
    uart_put_hex32(value);
}

static void conv1_print_diag(const volatile conv1_diag_record *r)
{
    diag_hex(" idx=", r->index);
    diag_hex(" c=", r->channel);
    diag_hex(" y=", r->y);
    diag_hex(" x=", r->x);
    uart_puts("\r\n");
    diag_hex(" actual=", r->actual);
    diag_hex(" original=", r->original);
    diag_hex(" gold=", r->golden);
    diag_hex(" actual_again=", r->actual_again);
    uart_puts("\r\n");
    diag_hex(" replay: diff=", r->diff);
    diag_hex(" phase=", r->phase);
    diag_hex(" base=", r->base);
    diag_hex(" split=", r->split);
    uart_puts("\r\n");
    diag_hex(" add_form=", r->add_form);
    diag_hex(" retry=", r->retry);
    diag_hex(" tight=", r->tight);
    diag_hex(" spaced=", r->spaced);
    uart_puts("\r\n");
}

/* Literal cases include underflow, channel changes and last-row positions.
 * The input coordinates are volatile too, to prevent constant folding.
 */
static const volatile uint32_t conv1_self_cases[][4] = {
    {0u, 0u, 0u, 36u}, {0u, 0u, 1u, 37u},
    {0u, 0u, 2u, 38u}, {0u, 0u, 3u, 39u},
    {0u, 1u, 0u, 39u}, {0u, 1u, 1u, 36u},
    {0u, 27u, 27u, 36u}, {1u, 0u, 0u, 37u},
    {1u, 0u, 1u, 38u}, {5u, 0u, 0u, 41u},
    {5u, 27u, 0u, 42u}, {5u, 27u, 27u, 41u}
};
#define CONV1_SELF_COUNT (sizeof(conv1_self_cases) / sizeof(conv1_self_cases[0]))
static volatile conv1_diag_record conv1_self[CONV1_SELF_COUNT];

static DIAG_NOOPT uint32_t conv1_expected_selftest(void)
{
    uint32_t i, errors = 0u;

    /* No UART calls until every record has been captured. No DMA starts. */
    for (i = 0u; i < CONV1_SELF_COUNT; ++i) {
        volatile conv1_diag_record *r = &conv1_self[i];
        uint32_t c = conv1_self_cases[i][0];
        uint32_t y = conv1_self_cases[i][1];
        uint32_t x = conv1_self_cases[i][2];
        uint32_t gold = conv1_self_cases[i][3];

        r->index = i;
        r->channel = c;
        r->y = y;
        r->x = x;
        r->golden = gold;
        r->actual = conv1_golden(c, y, x); /* table lookup, not DMA data */
        r->actual_again = r->actual;
        r->original = conv1_expected(c, y, x);
        conv1_diag_replay(r);
        if (r->actual != gold || r->original != gold ||
            r->split != gold || r->add_form != gold ||
            r->retry != gold || r->tight != gold || r->spaced != gold)
            ++errors;
    }

    uart_puts("PRE-DMA EXPECTED SELFTEST (actual=table lookup):\r\n");
    for (i = 0u; i < CONV1_SELF_COUNT; ++i)
        conv1_print_diag(&conv1_self[i]);
    diag_hex("PRE-DMA errors=", errors);
    uart_puts(errors == 0u ? " PASS\r\n" : " FAIL\r\n");
    return errors;
}

static void conv1_capture(volatile conv1_diag_record *r,
                          uint32_t index, uint32_t c, uint32_t y, uint32_t x,
                          uint32_t actual, uint32_t original, uint32_t gold)
{
    r->index = index;
    r->channel = c;
    r->y = y;
    r->x = x;
    r->actual = actual;
    r->original = original;
    r->golden = gold;
}

/* Retain the uploaded checker's unoptimized-loop attribute. */
static DIAG_NOOPT uint32_t check_conv1_output(void)
{
    uint32_t channel, y, x;
    uint32_t index = 0u;
    uint32_t compare_errors = 0u;
    uint32_t expected_errors = 0u;
    uint32_t output_errors = 0u;
    uint32_t sum_errors = 0u;
    uint32_t saved = 0u;
    uint32_t errors;

    /* Keep original formula and loop order. No UART inside this scan.
     * original!=gold detects checker errors even if actual==original.
     */
    for (channel = 0u; channel < CONV1_OUTPUT_C; ++channel) {
        uint32_t checksum = 0u;
        uint32_t expected_checksum = 0u;
        for (y = 0u; y < CONV1_OUTPUT_H; ++y) {
            for (x = 0u; x < CONV1_OUTPUT_W; ++x) {
                uint8_t actual = conv1_output[index];
                uint8_t expected = conv1_expected(channel, y, x);
                uint8_t gold = conv1_golden(channel, y, x);

                checksum += actual;
                expected_checksum += expected;
                if (actual != expected)
                    ++compare_errors;
                if (expected != gold)
                    ++expected_errors;
                if (actual != gold)
                    ++output_errors;

                if (y == 0u && x == 0u)
                    conv1_capture(&conv1_first[channel], index, channel,
                                  y, x, actual, expected, gold);

                if ((actual != expected || expected != gold || actual != gold)
                    && saved < MAX_PRINTED_MISMATCHES) {
                    conv1_capture(&conv1_bad[saved], index, channel,
                                  y, x, actual, expected, gold);
                    ++saved;
                }
                ++index;
            }
        }
        conv1_actual_sums[channel] = checksum;
        conv1_original_sums[channel] = expected_checksum;
    }

    /* Separately detect a bad checksum accumulator even when bytes match. */
    for (channel = 0u; channel < CONV1_OUTPUT_C; ++channel) {
        if (conv1_actual_sums[channel] != conv1_golden_checksums[channel] ||
            conv1_original_sums[channel] != conv1_golden_checksums[channel])
            ++sum_errors;
    }

    /* Replay BEFORE UART, using saved coordinates. actual_again is a CPU
     * reread, not an uncached read or independent observation of DDR.
     */
    for (channel = 0u; channel < CONV1_OUTPUT_C; ++channel) {
        conv1_first[channel].actual_again =
            conv1_output[conv1_first[channel].index];
        conv1_diag_replay(&conv1_first[channel]);
    }
    for (x = 0u; x < saved; ++x) {
        conv1_bad[x].actual_again = conv1_output[conv1_bad[x].index];
        conv1_diag_replay(&conv1_bad[x]);
    }

    uart_puts("Conv1 DIAG (all fields hex):\r\n");
    diag_hex("checked=", index);
    diag_hex(" compare_errors=", compare_errors);
    diag_hex(" expected_errors=", expected_errors);
    diag_hex(" output_errors=", output_errors);
    diag_hex(" sum_errors=", sum_errors);
    uart_puts("\r\n");
    for (channel = 0u; channel < CONV1_OUTPUT_C; ++channel) {
        uart_puts("CHANNEL FIRST PIXEL:");
        conv1_print_diag(&conv1_first[channel]);
        diag_hex(" actual_sum=", conv1_actual_sums[channel]);
        diag_hex(" original_sum=", conv1_original_sums[channel]);
        diag_hex(" gold_sum=", conv1_golden_checksums[channel]);
        uart_puts("\r\n");
        uart_puts(" first8=");
        for (x = 0u; x < 8u; ++x) {
            uart_put_hex8(conv1_output[conv1_first[channel].index + x]);
            uart_putc(x == 7u ? ' ' : ',');
        }
        uart_puts("\r\n");
    }
    for (x = 0u; x < saved; ++x) {
        uart_puts("MISMATCH:");
        conv1_print_diag(&conv1_bad[x]);
    }

    errors = compare_errors | expected_errors | output_errors | sum_errors;
    if (index != CONV1_OUTPUT_BYTES)
        errors |= 1u;
    return errors;
}

static void prepare_conv2_data(void)
{
    uint32_t channel;
    uint32_t pixel;
    uint32_t index = 0u;

    /* Pool bypass: each synthetic input channel has a distinct constant. */
    for (channel = 0u; channel < CONV2_INPUT_C; ++channel) {
        for (pixel = 0u; pixel < 196u; ++pixel)
            conv2_input[index++] = (uint8_t)(channel + 1u);
    }

    for (index = 0u; index < CONV2_WEIGHT_BYTES; ++index)
        conv2_weights[index] = 1u;

    for (channel = 0u; channel < CONV2_OUTPUT_C; ++channel)
        conv2_bias[channel] = (int32_t)channel;

    for (index = 0u; index < CONV2_OUTPUT_BYTES; ++index)
        conv2_output[index] = 0xEEu;

    memory_fence();
}

static uint32_t check_conv2_output(void)
{
    uint32_t channel;
    uint32_t pixel;
    uint32_t index = 0u;
    uint32_t errors = 0u;

    uart_puts("Conv2 DMA output check (synthetic input, pool bypass):\r\n");

    for (channel = 0u; channel < CONV2_OUTPUT_C; ++channel) {
        uint32_t checksum = 0u;
        uint32_t channel_base = index;
        uint8_t expected = quantize_positive(525u + channel, 3u);

        for (pixel = 0u; pixel < 100u; ++pixel) {
            uint8_t actual = conv2_output[index];

            checksum += actual;
            if (actual != expected) {
                if (errors < MAX_PRINTED_MISMATCHES) {
                    uart_puts("  mismatch index=");
                    uart_put_dec(index);
                    uart_puts(" actual=");
                    uart_put_dec(actual);
                    uart_puts(" expected=");
                    uart_put_dec(expected);
                    uart_puts("\r\n");
                }
                ++errors;
            }
            ++index;
        }

        uart_puts("  ch");
        uart_put_dec(channel);
        uart_puts(" value=");
        uart_put_dec(conv2_output[channel_base]);
        uart_puts(" checksum=");
        uart_put_dec(checksum);
        uart_puts(" expected_value=");
        uart_put_dec(expected);
        uart_puts("\r\n");
    }

    uart_puts("Conv2 checked bytes=");
    uart_put_dec(CONV2_OUTPUT_BYTES);
    uart_puts(", errors=");
    uart_put_dec(errors);
    uart_puts("\r\n");
    return errors;
}

static uint32_t test_conv1(void)
{
    uint32_t status;

    uart_puts("\r\n[Conv1] 32x32x1 -> 28x28x6\r\n");
    prepare_conv1_data();

    status = load_layer_to_bram(conv1_input, CONV1_INPUT_BYTES,
                                conv1_weights, CONV1_WEIGHT_BYTES,
                                conv1_bias, CONV1_BIAS_BYTES);
    if (status != 0u) {
        uart_puts("Conv1 stage: BRAM load failed\r\n");
        return 1u;
    }
    uart_puts("Conv1 stage: BRAM load done\r\n");

    status = run_conv(CONV1_INPUT_W, CONV1_INPUT_H,
                      CONV1_INPUT_C, CONV1_OUTPUT_C, 1u, 0u);
    if (status != 0u) {
        print_status_error("Conv1", status);
        return 2u;
    }
    uart_puts("Conv1 stage: convolution done\r\n");

    status = dma_bram_to_ddr(conv1_output, CONV1_OUTPUT_BYTES,
                             BRAM_OUTPUT_OFFSET);
    if (status != 0u) {
        print_status_error("Conv1 output DMA", status);
        return 3u;
    }
    uart_puts("Conv1 stage: output DMA done\r\n");

    return check_conv1_output();
}

static uint32_t test_conv2_without_pool(void)
{
    uint32_t status;

    uart_puts("\r\n[Conv2] 14x14x6 -> 10x10x16, pool bypass\r\n");
    prepare_conv2_data();

    status = load_layer_to_bram(conv2_input, CONV2_INPUT_BYTES,
                                conv2_weights, CONV2_WEIGHT_BYTES,
                                conv2_bias, CONV2_BIAS_BYTES);
    if (status != 0u)
        return 1u;

    status = run_conv(CONV2_INPUT_W, CONV2_INPUT_H,
                      CONV2_INPUT_C, CONV2_OUTPUT_C, 1u, 3u);
    if (status != 0u) {
        print_status_error("Conv2", status);
        return 2u;
    }

    status = dma_bram_to_ddr(conv2_output, CONV2_OUTPUT_BYTES,
                             BRAM_OUTPUT_OFFSET);
    if (status != 0u) {
        print_status_error("Conv2 output DMA", status);
        return 3u;
    }

    return check_conv2_output();
}

#ifndef CONV_DIAG_HOST_TEST
NOINLINE int conv_dma_test_main(void)
{
    uint32_t global_mie_mask = 1u << 3;
    uint32_t conv1_errors;
    uint32_t conv2_errors;
    uint32_t selftest_errors;

    /* This test polls status registers, so accelerator interrupts stay off. */
    __asm__ volatile ("csrc mstatus, %0" :: "r"(global_mie_mask) : "memory");
    MMIO32(DMA_CONTROL_ADDR) = 0u;
    MMIO32(DMA_IRQ_ENABLE_ADDR) = 0u;
    MMIO32(DMA_IRQ_CLEAR_ADDR) = DMA_IRQ_ALL_MASK;

    uart_puts("Conv + DMA test start\r\n");
    selftest_errors = conv1_expected_selftest();
    /* Continue after a failed selftest to collect the hardware comparison. */
    conv1_errors = test_conv1();
    uart_puts("Conv1 return code=");
    uart_put_dec(conv1_errors);
    uart_puts(", DMA status=");
    uart_put_hex32(MMIO32(DMA_STATUS_ADDR));
    uart_puts(", Conv status=");
    uart_put_hex32(MMIO32(CONV_STATUS_ADDR));
    uart_puts("\r\n");

    if (conv1_errors == 0u)
        uart_puts("CONV1 PASS\r\n");
    else
        uart_puts("CONV1 FAIL\r\n");

    conv2_errors = test_conv2_without_pool();
    if (conv2_errors == 0u)
        uart_puts("CONV2 PASS (POOL BYPASSED)\r\n");
    else
        uart_puts("CONV2 FAIL (POOL BYPASSED)\r\n");

    if ((selftest_errors == 0u) && (conv1_errors == 0u) && (conv2_errors == 0u)) {
        uart_puts("\r\nCONV + DMA TEST PASS\r\n");
        return 0;
    }

    uart_puts("\r\nCONV + DMA TEST FAIL\r\n");
    return 1;
}

USED __attribute__((naked, noreturn, section(".text.start")))
void _start(void)
{
    __asm__ volatile (
        "li sp, 0x80020000\n"
        "call conv_dma_test_main\n"
        "1: j 1b\n"
    );
}
#endif /* !CONV_DIAG_HOST_TEST */
