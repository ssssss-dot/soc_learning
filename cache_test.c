/*
 * Bare-metal cache test for this 5pipeline core.
 *
 * Cache geometry taken from if/icache.v and mem_stage/dcache.v:
 *   - 32 sets, 2 ways
 *   - one 32-bit word per cache line
 *   - addresses separated by 0x80 bytes map to the same set
 *   - D-cache is write-through and no-write-allocate
 *
 * Build for RV32I.  No C library or initialized DRAM data is required.
 * UART output uses the core's debug MMIO address 0x10000000.
 */

#include <stdint.h>

#define UART_TX (*(volatile uint8_t *)0x40000000u)

#define NOINLINE __attribute__((noinline))
#define USED     __attribute__((used))

/* 机器模式外部中断需要打开的两个使能位。 */
#define MIE_MEIE_MASK     (1u << 11) /* mie.MEIE：机器外部中断使能 */
#define MSTATUS_MIE_MASK  (1u << 3)  /* mstatus.MIE：全局中断使能 */

/*
 * Program-completion marker for ILA capture.
 * dcache_bridge maps CPU address 0x80001000 to DDR address 0x10001000.
 */
#define DONE_FLAG_ADDR 0x80001000u
#define DONE_MAGIC     0xD06ED06Eu
#define DONE_FLAG      (*(volatile uint32_t *)DONE_FLAG_ADDR)

typedef union {
    uint32_t w;
    uint16_t h[2];
    uint8_t  b[4];
} cache_word_t;

/*
 * 96 words = three tags for every one of the 32 set indices.
 * The 128-byte alignment makes element 0 use set 0.  Therefore:
 *   words[0], words[32], words[64] -> same set, different tags.
 *
 * It is intentionally in BSS.  The program initializes it with stores, so
 * the generated DMEM binary may contain no payload.  Because this D-cache is
 * no-write-allocate, initialization should not pre-fill any tested line.
 */
static volatile cache_word_t cache_words[96]//创建 96 个 32 位数据，分成32组，每组3个32位数据，对应cache的32组的两路（多一路做lru测试）
    __attribute__((aligned(128), section(".bss.cache_test")));

/* 记录CPU一共响应了多少次DMA外部中断。 */
static volatile uint32_t dma_irq_count;

//根据数组下标生成测试数据
static inline uint32_t initial_value(uint32_t index)
{
    return 0xA5000000u ^ index;
}

//避免编译器把读取移动到写入之前
static inline void compiler_barrier(void)
{
    /* 编译器内建的信号屏障，不产生额外汇编模板，也不需要运行库。 */
    __atomic_signal_fence(__ATOMIC_SEQ_CST);
}

static inline void uart_putc(uint8_t c)
{
    UART_TX = c;
}

/*
 * 机器模式外部中断处理函数。
 *
 * interrupt("machine")属性会让RISC-V编译器自动保存/恢复本函数用到的
 * 寄存器，并在函数返回处自动产生mret。因此这里不需要手写中断入口汇编。
 */
USED __attribute__((interrupt("machine"), aligned(4), section(".text.trap")))
void machine_external_irq_handler(void)
{
    ++dma_irq_count;

    /* 串口打印IRQ，便于在仿真波形和输出中确认进入过处理函数。 */
    uart_putc('I');
    uart_putc('R');
    uart_putc('Q');
    uart_putc('\r');
    uart_putc('\n');

    /*
     * 纯CPU仿真时，dma_irq_i由testbench产生，也由testbench拉低。
     * 等接入dma_ctrl后，应在这里写DMA_IRQ_CLEAR寄存器：
     * (*(volatile uint32_t *)0x40001014u) = 1u;
     */
}

/*
 * 配置机器模式外部中断。
 * 标准C不能直接访问CSR，而当前定制LLVM也没有提供可依赖的CSR C
 * builtin，因此把3条必要的CSR操作集中在同一个内联汇编块中。
 */
static inline void enable_machine_external_irq(void)
{
    uint32_t trap_entry = (uint32_t)(uintptr_t)machine_external_irq_handler;
    uint32_t meie_mask = MIE_MEIE_MASK;
    uint32_t global_mie_mask = MSTATUS_MIE_MASK;

    /*
     * 依次完成：
     *   mtvec       = 中断处理函数入口；
     *   mie.MEIE    = 1，允许机器外部中断；
     *   mstatus.MIE = 1，打开CPU全局中断。
     */
    __asm__ volatile (
        "csrw mtvec, %0\n"
        "csrs mie, %1\n"
        "csrs mstatus, %2\n"
        :
        : "r"(trap_entry), "r"(meie_mask), "r"(global_mie_mask)
        : "memory"
    );
}

static void uart_hex32(uint32_t value)
{
    uint32_t i;

    for (i = 0; i < 8u; ++i) {
        uint32_t digit = (value >> (28u - (i << 2))) & 0x0fu;
        uart_putc((uint8_t)(digit < 10u ? ('0' + digit)
                                           : ('A' + digit - 10u)));
    }
}

static void report(uint8_t group, uint8_t number, uint32_t pass)
{
    uart_putc(group);
    uart_putc(number);
    uart_putc(':');
    uart_putc((uint8_t)(pass ? 'P' : 'F'));
    uart_putc('\r');
    uart_putc('\n');
}

static void initialize_test_memory(void)
{
    uint32_t i;

    /* 96 write-through stores; misses must not allocate D-cache lines. */
    for (i = 0; i < 96u; ++i)
        cache_words[i].w = initial_value(i);//给每个 word 写入不同的值

    compiler_barrier();
}

/* D0: one cold load followed by a hit to the exact same word. */
static NOINLINE uint32_t test_repeated_load(void)
{
    //连续load同一地址的数据
    uint32_t first  = cache_words[1].w;//第一次读取：D-Cache miss，从 DRAM 读取
    uint32_t second = cache_words[1].w;//第二次读取：D-Cache hit，直接从 Cache 读取

    return (first == initial_value(1u)) && (second == first);
}

/* D1: cover all 32 indices, then repeat the same sweep as hits. */
static NOINLINE uint32_t test_all_sets(void)
{
    //32 个 word 分别映射到 D-Cache 的 32 个组，正常情况下第一次都 miss
    //第二遍正常情况下应该全部 hit
    uint32_t i;
    uint32_t expected = 0u;
    uint32_t first_sum = 0u;
    uint32_t second_sum = 0u;

    for (i = 32u; i < 64u; ++i) {
        expected += initial_value(i);
        first_sum += cache_words[i].w;
    }

    compiler_barrier();

    for (i = 32u; i < 64u; ++i)
        second_sum += cache_words[i].w;

    return (first_sum == expected) && (second_sum == expected);
}

//在D1中32个组的一路被装过一个字了
/*
 * D2: exercise both ways and LRU in set 0.
 * A/B/C are 0x80 bytes apart, hence have the same index.
 * Expected read miss/hit sequence after D1 is: M H H M H M.
 */
static NOINLINE uint32_t test_two_way_lru(void)
{
    //测试两路和LRU
    uint32_t value;
    uint32_t pass = 1u;

    value = cache_words[0].w;   /* A: miss, fill the second way. */
    pass &= (value == initial_value(0u));
    value = cache_words[32].w;  /* B: hit.  D1的时候装过cache了，所以hit*/
    pass &= (value == initial_value(32u));
    value = cache_words[0].w;   /* A: hit; B becomes LRU. */
    pass &= (value == initial_value(0u));
    value = cache_words[64].w;  /* C: miss; replace B. */
    pass &= (value == initial_value(64u));
    value = cache_words[0].w;   /* A must still hit. */
    pass &= (value == initial_value(0u));
    value = cache_words[32].w;  /* B: miss and refill. */
    pass &= (value == initial_value(32u));

    return pass;
}

/* D3: a store hit must update both the cached word and DRAM. */
static NOINLINE uint32_t test_write_hit(void)
{
    uint32_t before = cache_words[2].w; /* First load fills the line. */

    cache_words[2].w = 0xCAFEBABEu;//store时命中了应该更新cache
    compiler_barrier();

    return (before == initial_value(2u)) &&
           (cache_words[2].w == 0xCAFEBABEu);
}

/*
 * D4: a store miss must write DRAM without allocating a cache line.
 * In a waveform, the expected downstream transaction order is W, R; the
 * second load must then hit and create no third downstream transaction.
 */
static NOINLINE uint32_t test_no_write_allocate(void)
{
    uint32_t first;
    uint32_t second;

    //D0D1把这组装满了，way0：cache_words[1] way1：cache_words[33]
    cache_words[65].w = 0x0BADC0DEu;//store miss，cache不变（store miss指的是tag不一样）
    compiler_barrier();
    first = cache_words[65].w;//load miss
    second = cache_words[65].w;//load hit

    return (first == 0x0BADC0DEu) && (second == first);
}

/*
 * D5: verify SB/SH byte enables, cache update on a write hit, and write-through.
 * The final two congruent loads evict word 66; reloading it checks DRAM data.
 */
//sb，sh指令测试
static NOINLINE uint32_t test_write_masks_and_write_through(void)
{
    uint32_t value;
    uint32_t pass = 1u;

    value = cache_words[66].w;
    pass &= (value == initial_value(66u));

    cache_words[66].b[1] = 0xAAu;
    pass &= (cache_words[66].w == 0xA500AA42u);

    cache_words[66].h[1] = 0xBEEFu;
    pass &= (cache_words[66].w == 0xBEEFAA42u);

    cache_words[66].h[0] = 0x1357u;
    pass &= (cache_words[66].w == 0xBEEF1357u);

    cache_words[66].b[3] = 0x24u;
    pass &= (cache_words[66].w == 0x24EF1357u);

    /* Touch the other two tags of set 2 to evict word 66. */
    value = cache_words[2].w;
    pass &= (value == 0xCAFEBABEu);
    value = cache_words[34].w;
    pass &= (value == initial_value(34u));

    /* This must miss and obtain the write-through result from DRAM. */
    value = cache_words[66].w;
    pass &= (value == 0x24EF1357u);

    return pass;
}

/*
 * These three leaf functions start on 128-byte boundaries.  Their first
 * instruction therefore maps to the same I-cache set but carries a different
 * tag.  The empty asm prevents the optimizer from replacing the calls with
 * constants while producing no instruction itself.
 */
static NOINLINE USED __attribute__((aligned(128), section(".text.icache_a")))//aligned(128) 表示函数起始地址必须是 128 字节对齐
//addi a0, a0, 0x11
uint32_t icache_a(uint32_t value)
{
    /* volatile局部变量防止编译器把跨函数调用的结果提前折叠。 */
    volatile uint32_t stable_value = value;
    return stable_value + 0x11u;
}
//addi a0, a0, 0x22
static NOINLINE USED __attribute__((aligned(128), section(".text.icache_b")))
uint32_t icache_b(uint32_t value)
{
    volatile uint32_t stable_value = value;
    return stable_value + 0x22u;
}
//addi a0, a0, 0x33
static NOINLINE USED __attribute__((aligned(128), section(".text.icache_c")))
uint32_t icache_c(uint32_t value)
{
    volatile uint32_t stable_value = value;
    return stable_value + 0x33u;
}

/* I0: two-way I-cache fill, hit and LRU replacement sequence A B A C A B. */
static NOINLINE uint32_t test_icache_two_way_lru(void)
{
    uint32_t value = 1u;

    value = icache_a(value);//miss
    value = icache_b(value);//miss
    value = icache_a(value);//hit
    value = icache_c(value);//miss lru
    value = icache_a(value);//hit
    value = icache_b(value);//miss lru

    //初始：0x01
    //A：   0x01 + 0x11 = 0x12
    //B：   0x12 + 0x22 = 0x34
    //A：   0x34 + 0x11 = 0x45
    //C：   0x45 + 0x33 = 0x78
    //A：   0x78 + 0x11 = 0x89
    //B：   0x89 + 0x22 = 0xAB
    return value == 0xABu;
}

/* Called by the naked reset entry after SP has been initialized. */
// /调用三个位于不同地址、但映射到同一 I-Cache 组的函数，测试 I-Cache 的两路和 LRU 替换
USED __attribute__((noreturn))
void cache_test_main(void)
{
    uint32_t failures = 0u;
    uint32_t pass;

    uart_putc('C');
    uart_putc('S');
    uart_putc('\r');
    uart_putc('\n');

    /*
     * 当前启动代码没有统一清零BSS，所以先显式清零中断计数器。
     * 完成这一步以后，testbench就可以在程序运行中拉高dma_irq_i。
     */
    dma_irq_count = 0u;
    enable_machine_external_irq();

    initialize_test_memory();

    pass = test_repeated_load();
    failures += !pass;
    report('D', '0', pass);

    pass = test_all_sets();
    failures += !pass;
    report('D', '1', pass);

    pass = test_two_way_lru();
    failures += !pass;
    report('D', '2', pass);

    pass = test_write_hit();
    failures += !pass;
    report('D', '3', pass);

    pass = test_no_write_allocate();
    failures += !pass;
    report('D', '4', pass);

    pass = test_write_masks_and_write_through();
    failures += !pass;
    report('D', '5', pass);

    pass = test_icache_two_way_lru();
    failures += !pass;
    report('I', '0', pass);

    uart_putc('A');
    uart_putc(':');
    uart_putc((uint8_t)(failures == 0u ? 'P' : 'F'));
    uart_putc(':');
    uart_hex32(failures);
    uart_putc('\r');
    uart_putc('\n');

    /* 输出DMA中断响应次数，例如一次中断应打印Q:00000001。 */
    uart_putc('Q');
    uart_putc(':');
    uart_hex32(dma_irq_count);
    uart_putc('\r');
    uart_putc('\n');

    /* Mark the end of the cache test before entering the terminal loop. */
    compiler_barrier();
    DONE_FLAG = DONE_MAGIC;
    compiler_barrier();

    for (;;)
        compiler_barrier();
}

/*
 * 裸机复位入口。
 * CPU复位时没有硬件自动设置sp，因此这里必须先把栈顶设置为
 * 0x80020000，之后才能安全调用会使用栈的C函数。
 */
USED __attribute__((naked, noreturn, section(".text.start")))
void _start(void)
{
    __asm__ volatile (
        "li sp, 0x80020000\n"
        "call cache_test_main\n"
        "1: j 1b\n"
    );
}
