/*
 * acc_demo INT8模型：摄像头实时推理 / 导出图片自检。
 *
 * 网络流程：
 *   1×32×32 -> Conv1 -> Pool1 -> Conv2 -> Pool2 -> FC1 -> FC2 -> FC3
 *   输出数：    4704     1176     1600      400      96      64      10
 *
 * 默认流程：摄像头写DDR完成 -> ISR记录并清中断 -> 主循环DMA搬入BRAM -> 七层CNN。
 * ISR不启动DMA或计算，不打印串口，避免打断正在使用共享BRAM的推理。
 * 实时图片没有固定标签和逐层答案；CNN_CAMERA_INPUT=0恢复导出图片的8050项自检。
 * CNN_USE_INTERRUPTS=0使用轮询；CNN_CAMERA_MAX_FRAMES=0表示连续处理。
 * 摄像头只提供一个DDR帧缓冲。必须在下一次写入覆盖前搬完1024字节；
 * 软件可检测搬运期间的新完成/错误事件，但不能检测尚未完成的覆盖写入。
 *
 * 构建：build_cnn.py；链接脚本：linker_cnn.ld。
 * 日志：0x40000000 -> dbg_uart_txd，115200 baud，8N1。
 *
 * 建议先看 cnn_main() 理解整体流程，再看 run_conv/run_pool/run_fc。
 * 本文件中返回 int 的函数均约定：0 表示成功，1 表示失败。
 */

#include <stdint.h>

/* 从构建脚本的-I assets目录读取，避免源码旁的旧头文件遮蔽新生成的模型。 */
#include <model_layout.h>   /* 自动生成：模型地址、数据长度、MULT/SHIFT。 */
#include <cnn_reference.h>  /* 自动生成：各层 INT8 参考结果、模型校验值。 */

#ifndef CNN_CAMERA_INPUT
#define CNN_CAMERA_INPUT 1
#endif

#ifndef CNN_CAMERA_MAX_FRAMES
#define CNN_CAMERA_MAX_FRAMES 0u
#endif

/* Let camera AEC/AGC settle before copying the first inference input. */
#ifndef CNN_CAMERA_WARMUP_FRAMES
#define CNN_CAMERA_WARMUP_FRAMES 20u
#endif

/* Print camera input previews. Set to 0 for normal inference timing. */
#ifndef CNN_CAMERA_PREVIEW
#define CNN_CAMERA_PREVIEW 1
#endif

/* 20: frames 1,21,41,...; 1: every inference; 0: first input only. */
#ifndef CNN_CAMERA_PREVIEW_INTERVAL
#define CNN_CAMERA_PREVIEW_INTERVAL 20u
#endif

#if CNN_CAMERA_PREVIEW != 0 && CNN_CAMERA_PREVIEW != 1
#error "CNN_CAMERA_PREVIEW must be 0 or 1"
#endif

#if CNN_CAMERA_INPUT != 0 && CNN_CAMERA_INPUT != 1
#error "CNN_CAMERA_INPUT must be 0 or 1"
#endif

#ifndef CNN_USE_INTERRUPTS
#define CNN_USE_INTERRUPTS 1
#endif

#if CNN_USE_INTERRUPTS != 0 && CNN_USE_INTERRUPTS != 1
#error "CNN_USE_INTERRUPTS must be 0 or 1"
#endif

#define IRQ_ENABLE_BIT (CNN_USE_INTERRUPTS ? 2u : 0u)

/* 1. MMIO 寄存器与内存布局 */

/* volatile 保证每次访问都实际读写寄存器，不能被编译器省略。 */
//把数字地址 a 当作一个32位硬件寄存器来读写，(uintptr_t)(a)将地址无符号指针
#define MMIO32(a)      (*(volatile uint32_t *)(uintptr_t)(a))

#define UART_TX        0x40000000u  /* 调试串口发送寄存器。 */

/* DMA：RD 表示 DDR -> BRAM，WR 表示 BRAM -> DDR。 */
#define DMA_SRC        0x40004000u  /* DDR 读源地址。 */
#define DMA_DST        0x40004004u  /* DDR 写目标地址。 */
#define DMA_RD_LEN     0x40004008u  /* DDR -> BRAM 搬运字节数。 */
#define DMA_CONTROL    0x4000400Cu  /* bit0 启动读，bit2 启动写。 */
#define DMA_STATUS     0x40004010u  /* busy、done、error 状态。 */
#define DMA_CLEAR      0x40004014u  /* 写 1 清除对应的完成/错误标志。 */
#define DMA_WR_LEN     0x40004018u  /* BRAM -> DDR 搬运字节数。 */
#define DMA_IRQ_STATUS 0x4000401Cu  /* bit0/1：读/写完成；bit2/3：读/写错误。 */
#define DMA_IRQ_EN     0x40004020u  /* 与 CONTROL.bit1 一起控制 DMA 中断。 */
#define DMA_RD_OFFSET  0x40004024u  /* DDR -> BRAM 的 BRAM 字节偏移。 */
#define DMA_WR_OFFSET  0x40004028u  /* BRAM -> DDR 的 BRAM 字节偏移。 */
#define TIME_COUNTER   0x40004030u  /* 硬件保存的一次推理耗时，单位为 clk 周期。 */

#define CONV_BASE      0x40005000u
#define POOL_BASE      0x40006000u
#define FC_BASE        0x40007000u

/* 摄像头位定义与计算模块不同：[0]错误、[1]完成，CONTROL.bit0为中断使能。 */
#define CAMERA_CONTROL 0x40008000u
#define CAMERA_STATUS  0x40008004u
#define CAMERA_IRQ_EN  1u
#define CAMERA_ERROR   1u
#define CAMERA_DONE    2u
#define CAMERA_EVENTS  (CAMERA_ERROR | CAMERA_DONE)
#define CAMERA_DDR     0x10020000u  /* axis2axiw中固定的DDR/AXI地址。 */
#define CAMERA_BYTES   1024u       /* 32x32x1 INT8，视频通路已经完成灰度和量化。 */
#define CAMERA_TIMEOUT 20000000u   /* 等待循环上限，不表示固定毫秒数。 */

#if MODEL_DDR_BASE + MODEL_SIZE_BYTES > CAMERA_DDR
#error "Packed model overlaps the camera frame buffer"
#endif

/* Conv、Pool、FC 的状态寄存器均位于各自基地址 + 0x04。 */
#define STATUS         4u
#define BUSY           1u          /* bit0：正在运行。 */
#define DONE           2u          /* bit1：运行完成，写 1 清除。 */
#define ERROR          4u          /* bit2：发生错误，写 1 清除。 */
#define TIMEOUT        5000000u    /* 最大等待循环次数，不是时钟周期数。 */

/*
 * 共享 BRAM 内部布局，下面三个地址都是字节偏移：
 *   0x0000：本层输出，所有计算模块默认从头写入。
 *   0x2000：Conv/FC 输入。
 *   0x4000：权重；最大的 FC1 权重占 38400 字节，结束地址为 0xD600。
 *   0xF000：INT32 偏置。
 *
 * 各区域互不重叠。Conv 的偏置配置寄存器使用字地址，配置时单独右移 2 位。
 */
#define BRAM_INPUT     0x2000u
#define BRAM_WEIGHT    0x4000u
#define BRAM_BIAS      0xF000u
#define OUTPUT_BYTES   4800u

/* DDR 工作缓冲：每层复用，容纳最大输出 Conv1 的 4704 字节和检查空间。 */
/* BRAM结果 -> DMA -> output_data；自检模式比较参考，摄像头模式读取分类分数。 */
static volatile uint8_t output_data[OUTPUT_BYTES] __attribute__((aligned(64)));


/* 2. 寄存器访问、地址转换与串口打印 */

static uint32_t reg_read(uint32_t address)
{
    return MMIO32(address);
}

static void reg_write(uint32_t address, uint32_t value)
{
    MMIO32(address) = value;
}

/* 保证内存访问顺序；在启动 DMA/协处理器前，以及读取完成结果前使用。 */
static void memory_fence(void)
{
    __asm__ volatile ("fence rw, rw" ::: "memory");
}

/* 初始化前和程序结束时关闭中断；安装好入口后才允许硬件中断。 */
static void disable_interrupts(void)
{
    uint32_t mask = 8u;

    __asm__ volatile ("csrc mstatus, %0\ncsrw mie, zero" :: "r"(mask) : "memory");
}

/* CPU 读取模型时使用 CPU 地址，而不是给 DMA 的 DDR/AXI 地址。 */
//CPU 读取指定地址的一个字节，转成指向一个字节的指针
static uint8_t model_byte(uint32_t address)
{
    return *(volatile const uint8_t *)(uintptr_t)address;
}

/* 同一块 DDR：CPU 从 0x80000000 访问（虚拟），DMA 从 0x10000000 访问（物理）。 */
//cpu地址转ddr地址
static uint32_t output_ddr_address(void)
{
    return (uint32_t)(uintptr_t)output_data - 0x80000000u + 0x10000000u;
}

//串口打印
static void uart_putc(char c)
{
    *(volatile uint8_t *)(uintptr_t)UART_TX = (uint8_t)c;
}

static void uart_puts(const char *s)
{
    while (*s)
    {
        uart_putc(*s++);
    }
}

/* 按高位到低位打印八个十六进制数字，用于观察寄存器和地址。 */
//十六进制数转字符串
static void uart_hex(uint32_t value)
{
    static const char digits[] = "0123456789ABCDEF";
    int shift;

    uart_puts("0x");//打印前缀

    //每次取出4位，转换成一个十六进制字符
    for (shift = 28; shift >= 0; shift -= 4)
    {
        uart_putc(digits[(value >> (uint32_t)shift) & 15u]);
    }
}

/*
 * 打印本程序需要的 -9999～9999，不使用除法、取余或软件乘法库。
 * steps 的每行分别对应千、百、十、个位；用减法确定该位的 8/4/2/1。
 */
__attribute__((noinline)) static void uart_number(int32_t value)
{
    static const uint16_t steps[4][4] = {
        {8000, 4000, 2000, 1000},
        { 800,  400,  200,  100},
        {  80,   40,   20,   10},
        {   8,    4,    2,    1}
    };

    uint32_t place;
    uint32_t digit;
    uint32_t started = 0u;

    if (value < 0)
    {
        uart_putc('-');
        value = -value;
    }

    for (place = 0u; place < 4u; ++place)
    {
        digit = 0u;

        if (value >= steps[place][0])
        {
            value -= steps[place][0];
            digit += 8u;
        }

        if (value >= steps[place][1])
        {
            value -= steps[place][1];
            digit += 4u;
        }

        if (value >= steps[place][2])
        {
            value -= steps[place][2];
            digit += 2u;
        }

        if (value >= steps[place][3])
        {
            value -= steps[place][3];
            digit += 1u;
        }

        /* 跳过前导零；即使数值为 0，也要打印最后一位。 */
        if (digit || started || place == 3u)
        {
            uart_putc((char)('0' + digit));
            started = 1u;
        }
    }
}


/*
 * 打印完整 UINT32 范围，不使用除法或取余，适用于没有 M 扩展的 RV32I。
 * fractional_digits=0 打印整数；100MHz 时取 5，按每毫秒 100000 周期
 * 插入小数点，直接输出毫秒数，保留五位小数。
 */
static void uart_u32_decimal(uint32_t value, uint32_t fractional_digits)
{
    static const uint32_t places[10] = {
        1000000000u, 100000000u, 10000000u, 1000000u, 100000u,
        10000u, 1000u, 100u, 10u, 1u
    };
    uint32_t place;
    uint32_t started = 0u;
    uint32_t integer_last = 9u - fractional_digits;

    for (place = 0u; place < 10u; ++place)
    {
        uint32_t digit = 0u;
        while (value >= places[place])
        {
            value -= places[place];
            ++digit;
        }

        if (digit || started || place == integer_last)
        {
            uart_putc((char)('0' + digit));
            started = 1u;
        }
        if (fractional_digits && place == integer_last)
        {
            uart_putc('.');
        }
    }
}


/* 3. 错误报告与硬件完成等待 */

static int fail(const char *stage, uint32_t detail)
{
    uart_puts("FAIL: ");
    uart_puts(stage);
    uart_puts(" detail=");
    uart_hex(detail);
    uart_puts("\r\n");

    return 1;
}

/* 写后读回配置，检查寄存器地址、写入值和读回值是否一致。 */
static int configure(uint32_t address, uint32_t value)
{
    uint32_t actual;

    reg_write(address, value);
    actual = reg_read(address);

    if (actual == value)
    {
        return 0;
    }

    uart_puts("Configuration address=");
    uart_hex(address);
    uart_puts(" expected=");
    uart_hex(value);
    uart_puts("\r\n");

    return fail("register readback", actual);
}

/*
 * 当前软件一次只启动一个 DMA/计算任务；每次启动前清对应的软件事件。
 * ISR 先保存完成/错误状态，再 W1C 硬件中断源；主循环不再反复读 MMIO。
 * 外部中断为 DMA | Conv | Pool | FC | Camera，因此 ISR 检查所有来源。
 */
enum completion_slot {
    IRQ_DMA_RD, IRQ_DMA_WR, IRQ_CONV, IRQ_POOL, IRQ_FC, IRQ_CAMERA, IRQ_SLOT_COUNT
};

#if CNN_USE_INTERRUPTS
static volatile uint32_t irq_events[IRQ_SLOT_COUNT];
static volatile uint32_t irq_counts[IRQ_SLOT_COUNT];
static volatile uint32_t irq_fault;
#endif

#if CNN_CAMERA_INPUT
/* 主循环只读取事件序号；不清零它，避免与ISR写入发生竞争。 */
static volatile uint32_t camera_sequence;
static volatile uint32_t camera_error_count;

static void service_camera_status(void)
{
    uint32_t status = reg_read(CAMERA_STATUS) & CAMERA_EVENTS;

    if (!status)
        return;

    if (status & CAMERA_ERROR)
        ++camera_error_count;
    else if (status & CAMERA_DONE)
        ++camera_sequence;

#if CNN_USE_INTERRUPTS
    ++irq_counts[IRQ_CAMERA];
#endif
    /* 错误响应也会置done，错误帧不发布给主循环；两位都按W1C清除。 */
    reg_write(CAMERA_STATUS, status);
}
#endif

/* 可由后续摄像头应用覆盖。必须非阻塞，不能启动另一个共享 DMA/计算任务。 */
__attribute__((weak)) void cnn_background_work(void)
{
    __asm__ volatile ("nop");
}

#if CNN_USE_INTERRUPTS
static void service_external_irq(void)
{
    uint32_t pending = reg_read(DMA_IRQ_STATUS) & 15u;
    uint32_t status;

    if (pending)
    {
        status = reg_read(DMA_STATUS);
        /* DMA_STATUS 的其他方向可能有旧 done，必须按本次 pending 区分。 */
        if (pending & 5u)
        {
            irq_events[IRQ_DMA_RD] |= status & 0x14u;
            ++irq_counts[IRQ_DMA_RD];
        }
        if (pending & 10u)
        {
            irq_events[IRQ_DMA_WR] |= status & 0x28u;
            ++irq_counts[IRQ_DMA_WR];
        }
        reg_write(DMA_CLEAR, pending);
    }

    status = reg_read(CONV_BASE + STATUS) & (DONE | ERROR);
    if (status)
    {
        irq_events[IRQ_CONV] |= status;
        ++irq_counts[IRQ_CONV];
        reg_write(CONV_BASE + STATUS, status);
    }
    status = reg_read(POOL_BASE + STATUS) & (DONE | ERROR);
    if (status)
    {
        irq_events[IRQ_POOL] |= status;
        ++irq_counts[IRQ_POOL];
        reg_write(POOL_BASE + STATUS, status);
    }
    status = reg_read(FC_BASE + STATUS) & (DONE | ERROR);
    if (status)
    {
        irq_events[IRQ_FC] |= status;
        ++irq_counts[IRQ_FC];
        reg_write(FC_BASE + STATUS, status);
    }
#if CNN_CAMERA_INPUT
    service_camera_status();
#endif
    memory_fence();
}

/* 编译器保存/恢复被使用的寄存器并生成 mret；外部中断不修改 mepc。 */
__attribute__((interrupt("machine"), aligned(4)))
static void cnn_trap_entry(void)
{
    uint32_t cause;
    __asm__ volatile ("csrr %0, mcause" : "=r"(cause));
    if (cause != 0x8000000Bu)
    {
        irq_fault = cause ? cause : 0xFFFFFFFFu;
        __asm__ volatile ("csrw mie, zero" ::: "memory");
        return;
    }
    service_external_irq();
}

static void enable_interrupts(void)
{
    uint32_t i;
    uint32_t entry = (uint32_t)(uintptr_t)cnn_trap_entry;
    uint32_t external = 1u << 11;
    uint32_t global = 8u;

    disable_interrupts();
    reg_write(DMA_CLEAR, 15u);
    reg_write(CONV_BASE + STATUS, DONE | ERROR);
    reg_write(POOL_BASE + STATUS, DONE | ERROR);
    reg_write(FC_BASE + STATUS, DONE | ERROR);
    for (i = 0u; i < IRQ_SLOT_COUNT; ++i)
    {
        irq_events[i] = 0u;
        irq_counts[i] = 0u;
    }
    irq_fault = 0u;

    __asm__ volatile ("csrw mtvec, %0" :: "r"(entry) : "memory");
    reg_write(DMA_IRQ_EN, 15u);
    reg_write(DMA_CONTROL, IRQ_ENABLE_BIT);
    reg_write(CONV_BASE, IRQ_ENABLE_BIT);
    reg_write(POOL_BASE, IRQ_ENABLE_BIT);
    reg_write(FC_BASE, IRQ_ENABLE_BIT);
#if CNN_CAMERA_INPUT
    reg_write(CAMERA_CONTROL, CAMERA_IRQ_EN);
#endif
    memory_fence();
    __asm__ volatile ("csrw mie, %0\ncsrs mstatus, %1"
                      :: "r"(external), "r"(global) : "memory");
}
#endif

static void prepare_completion(uint32_t slot)
{
#if CNN_USE_INTERRUPTS
    irq_events[slot] = 0u;
    memory_fence();
#else
    (void)slot;
#endif
}

/*
 * DMA_STATUS：bit0/1 为读/写 busy，bit2/3 为读/写 done，bit4/5 为错误。
 * 轮询模式读硬件状态；中断模式读 ISR 保存的软件完成事件。
 * ISR 仅保存 done/error 位，等待期间可以执行非阻塞后台任务。
 * busy_mask/done_mask 决定本次等待的是 DDR -> BRAM，还是 BRAM -> DDR。
 */
static int wait_dma(uint32_t busy_mask, uint32_t done_mask)
{
    uint32_t i;
    uint32_t status = 0u;

    for (i = 0u; i < TIMEOUT; ++i)
    {
#if CNN_USE_INTERRUPTS
        if (irq_fault)
            return fail("unexpected trap", irq_fault);
        status = irq_events[busy_mask == 1u ? IRQ_DMA_RD : IRQ_DMA_WR];
        if (!status)
        {
            cnn_background_work();
            continue;
        }
#else
        status = reg_read(DMA_STATUS);
#endif

        if (status & 0x30u)
        {
            return fail("DMA error", status);
        }

        if ((status & done_mask) && !(status & busy_mask))
        {
            memory_fence();
            return 0;
        }
    }

    return fail("DMA timeout", status);
}

/* 将 DDR 中的输入、权重或偏置搬到共享 BRAM，长度和偏移均以字节为单位。 */
static int dma_to_bram(uint32_t ddr_address, uint32_t bytes, uint32_t bram_offset)
{
    prepare_completion(IRQ_DMA_RD);
    reg_write(DMA_CLEAR, 15u);             /* 清除上次完成/错误状态。 */
    reg_write(DMA_SRC, ddr_address);
    reg_write(DMA_RD_LEN, bytes);
    reg_write(DMA_RD_OFFSET, bram_offset);
    memory_fence();

    reg_write(DMA_CONTROL, 1u | IRQ_ENABLE_BIT); /* 启动读，保持中断总使能。 */

    return wait_dma(1u, 4u);
}

/* Conv、Pool、FC 的状态位定义一致，因此共用同一个等待函数。 */
static int wait_accelerator(uint32_t base)
{
    uint32_t i;
    uint32_t status = 0u;

    for (i = 0u; i < TIMEOUT; ++i)
    {
#if CNN_USE_INTERRUPTS
        if (irq_fault)
            return fail("unexpected trap", irq_fault);
        status = irq_events[base == CONV_BASE ? IRQ_CONV :
                            base == POOL_BASE ? IRQ_POOL : IRQ_FC];
        if (!status)
        {
            cnn_background_work();
            continue;
        }
#else
        status = reg_read(base + STATUS);
#endif

        if (status & ERROR)
        {
            return fail("accelerator error", status);
        }

        if ((status & DONE) && !(status & BUSY))
        {
            memory_fence();
            return 0;
        }
    }

    uart_puts("Accelerator base=");
    uart_hex(base);
    uart_puts("\r\n");

    return fail("accelerator timeout", status);
}


/* 4. 每层结束后的结果回读与校验 */

/*
 * name：层名；count：有效 INT8 输出个数；expected：本层参考结果。
 * base：本层使用的协处理器 MMIO 基地址，用于清除完成状态。
 *
 * 计算结果先从 BRAM 地址 0 搬到 output_data，再供下一层使用。
 * 两种模式都检查DMA边界；只有导出图片自检模式比较固定参考结果。
 * DMA 长度向上对齐到 4 字节：FC3 的 10 字节搬运为 12 字节，只比较前 10 字节。
 */
static int finish_layer(const char *name, uint32_t count,
                        const int8_t *expected, uint32_t base)
{
    uint32_t i;
#if !CNN_CAMERA_INPUT
    uint32_t mismatches = 0u;
#else
    (void)name;
    (void)expected;
#endif
    uint32_t transfer = (count + 3u) & ~3u;

    /* 预填 A5，便于发现 DMA 未覆盖结果区或写出了规定范围。 */
    for (i = 0u; i < OUTPUT_BYTES; ++i)
    {
        output_data[i] = 0xA5u;
    }

    memory_fence();
    prepare_completion(IRQ_DMA_WR);
    reg_write(DMA_CLEAR, 15u);
    reg_write(DMA_DST, output_ddr_address());
    reg_write(DMA_WR_LEN, transfer);
    reg_write(DMA_WR_OFFSET, 0u);
    memory_fence();

    reg_write(DMA_CONTROL, 4u | IRQ_ENABLE_BIT); /* 启动写，保持中断总使能。 */

    if (wait_dma(2u, 8u))
    {
        return 1;
    }

    /*
     * soc_top 在 DMA 写 DDR 完成时使 DCache 失效，CPU 随后读取新结果。
     * 必须转为 int8_t 后比较，否则负数会被当成 128～255 的无符号数。
     */
#if !CNN_CAMERA_INPUT
    for (i = 0u; i < count; ++i)
    {
        int32_t actual = (int8_t)output_data[i];

        if (actual != expected[i])
        {
            /* 只打印前 8 个错误，避免大量串口输出掩盖首次出错位置。 */
            if (mismatches < 8u)
            {
                uart_puts("  index=");
                uart_number((int32_t)i);
                uart_puts(" actual=");
                uart_number(actual);
                uart_puts(" expected=");
                uart_number(expected[i]);
                uart_puts("\r\n");
            }

            ++mismatches;
        }
    }
#endif

    /* 搬运区域后面的 16 字节应保持 A5，用于检查 DMA 越界写入。 */
    for (i = transfer; i < transfer + 16u; ++i)
    {
        if (output_data[i] != 0xA5u)
        {
            return fail("DMA destination guard", i);
        }
    }

#if !CNN_CAMERA_INPUT
    if (mismatches)
    {
        return fail(name, mismatches);
    }
#endif

    /* 状态采用写 1 清除；读回确认后再进行下一层。 */
    reg_write(base + STATUS, DONE | ERROR);

    if (reg_read(base + STATUS) & (BUSY | DONE | ERROR))
    {
        return fail("completion clear", base);
    }

#if !CNN_CAMERA_INPUT
    uart_puts(name);
    uart_puts(" OK, outputs=");
    uart_number((int32_t)count);
    uart_puts("\r\n");
#endif

    return 0;
}


/* 5. Conv、Pool、FC 的逐层调度 */

/*
 * second=0：Conv1，输入 1×32×32，输出 6×28×28。
 * second=1：Conv2，输入 6×14×14，输出 16×10×10。
 * 输入必须已搬入BRAM_INPUT；两个卷积层均使用5x5卷积核。
 */
static int run_conv(uint32_t second)
{
#if !CNN_CAMERA_INPUT
    const char *name = second ? "Conv2" : "Conv1";

    uart_puts("Start ");
    uart_puts(name);
    uart_puts("\r\n");
#endif

    /* 输入已经快照到BRAM；随后装载权重和偏置，不再读取摄像头DDR。 */
    if (dma_to_bram(second ? MODEL_CONV2_WEIGHT_DDR_ADDR : MODEL_CONV1_WEIGHT_DDR_ADDR,
                    second ? MODEL_CONV2_WEIGHT_BYTES : MODEL_CONV1_WEIGHT_BYTES,
                    BRAM_WEIGHT) ||
        dma_to_bram(second ? MODEL_CONV2_BIAS_DDR_ADDR : MODEL_CONV1_BIAS_DDR_ADDR,
                    second ? MODEL_CONV2_BIAS_BYTES : MODEL_CONV1_BIAS_BYTES,
                    BRAM_BIAS))
    {
        return 1;
    }

    prepare_completion(IRQ_CONV);
    reg_write(CONV_BASE + STATUS, DONE | ERROR);

    /*
     * 0x08：输入高/宽，分别占高/低 16 位。
     * 0x0C：输出/输入通道数，分别占高/低 16 位。
     * 0x10：偏置基地址，Conv 使用 BRAM 字地址，所以字节地址右移 2 位。
     * 0x14/0x18：训练导出的量化乘数和移位量。
     * 0x1C/0x20：输入和权重的 BRAM 字节地址。
     */
    if (configure(CONV_BASE + 0x08u, second ? 0x000E000Eu : 0x00200020u) ||
        configure(CONV_BASE + 0x0Cu, second ? 0x00100006u : 0x00060001u) ||
        configure(CONV_BASE + 0x10u, BRAM_BIAS >> 2) ||
        configure(CONV_BASE + 0x14u,
                  second ? MODEL_CONV2_QUANT_MULT : MODEL_CONV1_QUANT_MULT) ||
        configure(CONV_BASE + 0x18u,
                  second ? MODEL_CONV2_QUANT_SHIFT : MODEL_CONV1_QUANT_SHIFT) ||
        configure(CONV_BASE + 0x1Cu, BRAM_INPUT) ||
        configure(CONV_BASE + 0x20u, BRAM_WEIGHT))
    {
        return 1;
    }

    memory_fence();
    reg_write(CONV_BASE, 1u | IRQ_ENABLE_BIT); /* 启动卷积。 */

    if (wait_accelerator(CONV_BASE))
    {
        return 1;
    }

    return finish_layer(second ? "Conv2" : "Conv1", second ? 1600u : 4704u,
                        second ? cnn_expected_conv2 : cnn_expected_conv1,
                        CONV_BASE);
}

/*
 * second=0：Pool1，6×28×28 -> 6×14×14。
 * second=1：Pool2，16×10×10 -> 16×5×5。
 * Pool 固定 2×2 窗口、stride=2，直接读取 BRAM 中上一层 Conv 的结果。
 */
static int run_pool(uint32_t second)
{
#if !CNN_CAMERA_INPUT
    const char *name = second ? "Pool2" : "Pool1";

    uart_puts("Start ");
    uart_puts(name);
    uart_puts("\r\n");
#endif

    /* Conv 输出仍在 BRAM 字节地址 0，无需从 DDR 重新装载。 */
    prepare_completion(IRQ_POOL);
    reg_write(POOL_BASE + STATUS, DONE | ERROR);

    /* 0x08 配置输入高/宽，0x0C 配置通道数。 */
    if (configure(POOL_BASE + 0x08u, second ? 0x000A000Au : 0x001C001Cu) ||
        configure(POOL_BASE + 0x0Cu, second ? 16u : 6u))
    {
        return 1;
    }

    memory_fence();
    reg_write(POOL_BASE, 1u | IRQ_ENABLE_BIT);

    if (wait_accelerator(POOL_BASE))
    {
        return 1;
    }

    return finish_layer(second ? "Pool2" : "Pool1", second ? 400u : 1176u,
                        second ? cnn_expected_pool2 : cnn_expected_pool1,
                        POOL_BASE);
}

/* layer=0/1/2 分别对应 FC1/FC2/FC3，输入来自上一层的 DDR 工作缓冲。 */
static int run_fc(uint32_t layer)
{
    const char *name;
    const int8_t *expected;

    uint32_t inputs;
    uint32_t outputs;
    uint32_t weights;
    uint32_t weight_bytes;
    uint32_t biases;
    uint32_t bias_bytes;
    uint32_t mult;
    uint32_t shift;

    /* 选择本层的维度、DDR 参数地址、量化参数和参考结果。 */
    if (layer == 0u)
    {
        name         = "FC1";
        inputs       = 400u;
        outputs      = 96u;
        expected     = cnn_expected_fc1;
        weights      = MODEL_FC1_WEIGHT_DDR_ADDR;
        weight_bytes = MODEL_FC1_WEIGHT_BYTES;
        biases       = MODEL_FC1_BIAS_DDR_ADDR;
        bias_bytes   = MODEL_FC1_BIAS_BYTES;
        mult         = MODEL_FC1_QUANT_MULT;
        shift        = MODEL_FC1_QUANT_SHIFT;
    }
    else if (layer == 1u)
    {
        name         = "FC2";
        inputs       = 96u;
        outputs      = 64u;
        expected     = cnn_expected_fc2;
        weights      = MODEL_FC2_WEIGHT_DDR_ADDR;
        weight_bytes = MODEL_FC2_WEIGHT_BYTES;
        biases       = MODEL_FC2_BIAS_DDR_ADDR;
        bias_bytes   = MODEL_FC2_BIAS_BYTES;
        mult         = MODEL_FC2_QUANT_MULT;
        shift        = MODEL_FC2_QUANT_SHIFT;
    }
    else
    {
        name         = "FC3";
        inputs       = 64u;
        outputs      = 10u;
        expected     = cnn_expected_fc3;
        weights      = MODEL_FC3_WEIGHT_DDR_ADDR;
        weight_bytes = MODEL_FC3_WEIGHT_BYTES;
        biases       = MODEL_FC3_BIAS_DDR_ADDR;
        bias_bytes   = MODEL_FC3_BIAS_BYTES;
        mult         = MODEL_FC3_QUANT_MULT;
        shift        = MODEL_FC3_QUANT_SHIFT;
    }

#if !CNN_CAMERA_INPUT
    uart_puts("Start ");
    uart_puts(name);
    uart_puts("\r\n");
#endif

    /* Pool2 按 CHW 顺序连续存储，400 个输出可直接作为 FC1 的展平输入。 */
    if (dma_to_bram(output_ddr_address(), inputs, BRAM_INPUT) ||
        dma_to_bram(weights, weight_bytes, BRAM_WEIGHT) ||
        dma_to_bram(biases, bias_bytes, BRAM_BIAS))
    {
        return 1;
    }

    prepare_completion(IRQ_FC);
    reg_write(FC_BASE + STATUS, DONE | ERROR);

    /*
     * 0x08/0x0C：输入/输出特征数。
     * 0x10/0x14/0x18：输入、权重、偏置的 BRAM 字节地址。
     * 0x20/0x24：本层量化 MULT/SHIFT。
     * 注意：FC 的偏置寄存器使用字节地址，这里不能像 Conv 一样右移 2 位。
     */
    if (configure(FC_BASE + 0x08u, inputs) ||
        configure(FC_BASE + 0x0Cu, outputs) ||
        configure(FC_BASE + 0x10u, BRAM_INPUT) ||
        configure(FC_BASE + 0x14u, BRAM_WEIGHT) ||
        configure(FC_BASE + 0x18u, BRAM_BIAS) ||
        configure(FC_BASE + 0x20u, mult) ||
        configure(FC_BASE + 0x24u, shift))
    {
        return 1;
    }

    memory_fence();

    /* bit0 为启动，bit2 为 ReLU：FC1/2 写 5，FC3 写 1，保留负数分类分数。 */
    reg_write(FC_BASE, (layer == 2u ? 1u : 5u) | IRQ_ENABLE_BIT);

    if (wait_accelerator(FC_BASE))
    {
        return 1;
    }

    return finish_layer(name, outputs, expected, FC_BASE);
}


/* 6. 模型下载检查与完整网络执行 */

/*
 * 对 DDR 模型区逐字节计算校验值，检查是否漏下载或混用了其他导出文件。
 * 算法必须与 prepare_cnn.py 的 checksum() 一致：循环左移、异或、相加。
 * 这是模型包一致性检查；导出图片自检模式还会逐层做精确比较。
 */
static int check_model(void)
{
    uint32_t i;
    uint32_t hash = 0x13579BDFu;

    for (i = 0u; i < MODEL_SIZE_BYTES; ++i)
    {
        hash = (hash << 5) | (hash >> 27);
        hash = (hash ^ model_byte(MODEL_CPU_BASE + i)) + 0x9E3779B9u;
    }

    if (hash != CNN_MODEL_CHECKSUM)
    {
        return fail("model download/checksum", hash);
    }

    uart_puts("Model DDR image OK\r\n");

    return 0;
}

/* Conv1输入已在BRAM_INPUT中；Pool直接使用上一层BRAM输出。 */
static int run_network(void)
{
    if (run_conv(0u) ||
        run_pool(0u) ||
        dma_to_bram(output_ddr_address(), 1176u, BRAM_INPUT) ||
        run_conv(1u) ||
        run_pool(1u) ||
        run_fc(0u) ||
        run_fc(1u) ||
        run_fc(2u))
    {
        uart_puts("CNN INFERENCE FAIL\r\n");
        return 1;
    }
    return 0;
}

/* 当前DMA计时器复位后只测一次：首次DMA读开始，到第七次DMA写完成。 */
static void print_first_inference_time(void)
{
#if CNN_CAMERA_INPUT && CNN_CAMERA_PREVIEW
    /* The extra preview DMA write changes the hardware's seven-write timer. */
    uart_puts("Inference timing skipped: camera preview adds a DMA write\r\n");
#else
    uint32_t cycles = reg_read(TIME_COUNTER);

    uart_puts("First inference cycles since reset: ");
    uart_u32_decimal(cycles, 0u);
    uart_puts("\r\nFirst inference time (100 MHz): ");
    uart_u32_decimal(cycles, 5u);
    uart_puts(" ms\r\n");
#endif
}

static void print_irq_counts(void)
{
#if CNN_USE_INTERRUPTS
    uint32_t i;
    uart_puts("IRQ counts RD/WR/Conv/Pool/FC/Camera:");
    for (i = 0u; i < IRQ_SLOT_COUNT; ++i)
    {
        uart_putc(' ');
        uart_u32_decimal(irq_counts[i], 0u);
    }
    uart_puts("\r\n");
#endif
}

/* ISR不打印；只有主循环读取FC3的十个有符号INT8分数并取最大值。 */
static void report_prediction(uint32_t frame)
{
    uint32_t i;
    uint32_t prediction = 0u;

    for (i = 1u; i < 10u; ++i)
    {
        if ((int8_t)output_data[i] > (int8_t)output_data[prediction])
            prediction = i;
    }

#if CNN_CAMERA_INPUT
    uart_puts("Frame ");
    uart_u32_decimal(frame, 0u);
    uart_puts(" prediction=");
    uart_number((int32_t)prediction);
    uart_puts(" scores:");
    for (i = 0u; i < 10u; ++i)
    {
        uart_putc(' ');
        uart_number((int8_t)output_data[i]);
    }
    uart_puts("\r\n");
#else
    uint32_t label = model_byte(MODEL_TEST_LABELS_CPU_ADDR);
    (void)frame;
    uart_puts("\r\nFinal INT8 scores:\r\n");
    for (i = 0u; i < 10u; ++i)
    {
        uart_puts("  class ");
        uart_number((int32_t)i);
        uart_puts(": ");
        uart_number((int8_t)output_data[i]);
        uart_puts("\r\n");
    }
    uart_puts("Prediction=");
    uart_number((int32_t)prediction);
    uart_puts(" label=");
    uart_number((int32_t)label);
    uart_puts("\r\nCNN REFERENCE MATCH: all 8050 layer outputs\r\n");
    uart_puts(prediction == label ? "Classification correct\r\n"
                                 : "Classification differs from label\r\n");
#endif
}

#if CNN_CAMERA_INPUT
static void poll_camera_if_needed(void)
{
#if !CNN_USE_INTERRUPTS
    service_camera_status();
#endif
}

static int wait_camera_frame(uint32_t previous, uint32_t *sequence)
{
    uint32_t i;
    uint32_t logged_errors = camera_error_count;

    for (i = 0u; i < CAMERA_TIMEOUT; ++i)
    {
        poll_camera_if_needed();
#if CNN_USE_INTERRUPTS
        if (irq_fault)
            return fail("unexpected trap", irq_fault);
#endif
        *sequence = camera_sequence;
        if (*sequence != previous)
        {
            memory_fence();
            return 0;
        }
        if (camera_error_count != logged_errors)
        {
            logged_errors = camera_error_count;
            uart_puts("Camera write error; waiting for a valid frame\r\n");
        }
        cnn_background_work();
    }
    return fail("camera frame timeout; check sensor/MIPI/DDR", camera_error_count);
}

/* Discard completed camera frames without starting DMA or inference. */
static int warmup_camera(uint32_t *previous)
{
#if CNN_CAMERA_WARMUP_FRAMES > 0
    uint32_t i;
    uint32_t sequence;

    uart_puts("Camera warmup: skipping ");
    uart_u32_decimal(CNN_CAMERA_WARMUP_FRAMES, 0u);
    uart_puts(" completed frames for AEC/AGC\r\n");
    for (i = 0u; i < CNN_CAMERA_WARMUP_FRAMES; ++i)
    {
        if (wait_camera_frame(*previous, &sequence))
            return 1;
        *previous = sequence;
    }
    uart_puts("Camera warmup done; next frame is inference frame 1\r\n");
#else
    (void)previous;
#endif
    return 0;
}

/*
 * 优先搬图，再装载权重，缩短CPU响应帧完成到输入快照之间的时间。
 * 推理期间只保留最新完成事件，不为每个中断排队启动一个共享DMA任务。
 * 事件序号变化只能检测已完成的覆盖，不能替代硬件双缓冲/读写所有权。
 */
static int snapshot_camera_frame(uint32_t *previous)
{
    uint32_t attempt;
    uint32_t sequence;
    uint32_t errors;

    for (attempt = 0u; attempt < 3u; ++attempt)
    {
        if (wait_camera_frame(*previous, &sequence))
            return 1;
        errors = camera_error_count;

        /* 只由DMA读取CAMERA_DDR，CPU不经DCache直接读取这个地址。 */
        if (dma_to_bram(CAMERA_DDR, CAMERA_BYTES, BRAM_INPUT))
            return 1;

        poll_camera_if_needed();
        *previous = sequence;
        if (camera_sequence == sequence && camera_error_count == errors)
            return 0;
    }
    return fail("camera changed repeatedly during input DMA", camera_sequence);
}

#if CNN_CAMERA_PREVIEW
/* Read the saved BRAM input, not the camera DDR buffer that keeps changing. */
static int preview_camera_input(uint32_t frame)
{
    static const char levels[] = " .:-+*#@";
    uint32_t i;
    uint32_t row;
    uint32_t column;
    uint32_t minimum = 255u;
    uint32_t maximum = 0u;
    uint32_t invalid = 0u;
    int dma_result;

    for (i = 0u; i < CAMERA_BYTES + 16u; ++i)
        output_data[i] = 0xA5u;
    memory_fence();

    prepare_completion(IRQ_DMA_WR);
    reg_write(DMA_CLEAR, 15u);
    reg_write(DMA_DST, output_ddr_address());
    reg_write(DMA_WR_LEN, CAMERA_BYTES);
    reg_write(DMA_WR_OFFSET, BRAM_INPUT);
    memory_fence();
    reg_write(DMA_CONTROL, 4u | IRQ_ENABLE_BIT);
    dma_result = wait_dma(2u, 8u);
    reg_write(DMA_WR_OFFSET, 0u);
    memory_fence();
    if (dma_result)
        return 1;

    for (i = CAMERA_BYTES; i < CAMERA_BYTES + 16u; ++i)
    {
        if (output_data[i] != 0xA5u)
            return fail("camera preview DMA destination guard", i);
    }
    for (i = 0u; i < CAMERA_BYTES; ++i)
    {
        uint32_t pixel = output_data[i];
        if (pixel < minimum)
            minimum = pixel;
        if (pixel > maximum)
            maximum = pixel;
        if (pixel > 127u)
            ++invalid;
    }

    uart_puts("\r\nCAMERA_INPUT_BEGIN frame=");
    uart_u32_decimal(frame, 0u);
    uart_puts(" size=32x32 chars_per_pixel=2\r\n");
    uart_puts("INT8 expected=0..127 min=");
    uart_number((int32_t)minimum);
    uart_puts(" max=");
    uart_number((int32_t)maximum);
    uart_puts(" out_of_range=");
    uart_number((int32_t)invalid);
    uart_puts("\r\nLevels low->high: [ .:-+*#@]; ? = outside 0..127\r\n");
    uart_puts("+----------------------------------------------------------------+\r\n");
    for (row = 0u; row < 32u; ++row)
    {
        uart_putc('|');
        for (column = 0u; column < 32u; ++column)
        {
            uint32_t pixel = output_data[(row << 5) + column];
            char level = pixel > 127u ? '?' : levels[pixel >> 4];
            uart_putc(level);
            uart_putc(level);
        }
        uart_puts("|\r\n");
    }
    uart_puts("+----------------------------------------------------------------+\r\nCAMERA_INPUT_END\r\n");
    return 0;
}
#endif
#endif

static void stop_interrupt_sources(void)
{
    disable_interrupts();
    reg_write(CAMERA_CONTROL, 0u);
    reg_write(DMA_IRQ_EN, 0u);
    reg_write(DMA_CONTROL, 0u);
    reg_write(CONV_BASE, 0u);
    reg_write(POOL_BASE, 0u);
    reg_write(FC_BASE, 0u);
    memory_fence();
}

int cnn_main(void)
{
    uint32_t status;
    int result = 1;

    stop_interrupt_sources();//先关闭 CPU 全局中断和各外设中断使能
    uart_puts("\r\nacc_demo trained INT8 model\r\n");
    status = reg_read(DMA_STATUS);
    if (status & 3u)
        return fail("DMA already busy", status);
    if ((reg_read(CONV_BASE + STATUS) |
         reg_read(POOL_BASE + STATUS) |
         reg_read(FC_BASE + STATUS)) & BUSY)
        return fail("accelerator already busy", 1u);

    //清除旧事件
    reg_write(DMA_CLEAR, 15u);
    reg_write(CONV_BASE + STATUS, DONE | ERROR);
    reg_write(POOL_BASE + STATUS, DONE | ERROR);
    reg_write(FC_BASE + STATUS, DONE | ERROR);
    reg_write(CAMERA_STATUS, CAMERA_EVENTS);

//初始化两个软件计数器
#if CNN_CAMERA_INPUT
    camera_sequence = 0u;
    camera_error_count = 0u;
#endif
    if (check_model())
        return 1;

//选择中断模式或轮询模式
#if CNN_USE_INTERRUPTS
    enable_interrupts();
    uart_puts("Completion mode: machine external interrupts\r\n");
#else
    uart_puts("Completion mode: MMIO polling\r\n");
#endif

//等待并取得输入图片
#if CNN_CAMERA_INPUT
    {
        uint32_t previous = 0u;
        uint32_t frames = 0u;
#if CNN_CAMERA_PREVIEW
        uint32_t preview_countdown = 0u;
#endif

        uart_puts("Camera: 32x32 INT8, DDR=");
        uart_hex(CAMERA_DDR);
        uart_puts("\r\nWaiting for camera frames...\r\n");

        //一直循环输出
        for (;;)
        {
            //预热，传previou的地址改外面的参数，frame=0只用预热一次
            if (frames == 0u && warmup_camera(&previous))
                break;
            if (snapshot_camera_frame(&previous))
                break;
#if CNN_CAMERA_PREVIEW
            if (preview_countdown == 0u)
            {
                if (preview_camera_input(frames + 1u))
                    break;
#if CNN_CAMERA_PREVIEW_INTERVAL > 0
                preview_countdown = CNN_CAMERA_PREVIEW_INTERVAL;
#else
                preview_countdown = 1u;
#endif
            }
#if CNN_CAMERA_PREVIEW_INTERVAL > 0
            --preview_countdown;
#endif
#endif 
            //运行 CNN，打印预测，判断是否结束
            //函数内部负责配置 DMA、配置计算模块、启动任务、等待完成及搬运结果。任何一层失败，都退出循环
            if (run_network())
                break;
            //整张图片成功计算后，推理数量加一，再打印结果
            ++frames;
            report_prediction(frames);
            if (frames == 1u)
                print_first_inference_time();
#if CNN_CAMERA_MAX_FRAMES > 0
            if (frames >= CNN_CAMERA_MAX_FRAMES)
            {
                result = 0;
                break;
            }
#endif
        }
    }
#else
    /* 导出图片模式保留逐层精确比较，独立于摄像头输入。 */
    if (!dma_to_bram(MODEL_TEST_IMAGES_DDR_ADDR, 1024u, BRAM_INPUT) && !run_network())
    {
        report_prediction(1u);
        print_first_inference_time();
        result = 0;
    }
#endif

    stop_interrupt_sources();
    print_irq_counts();
    return result;
}


/* 7. 裸机启动入口 */

#ifndef CNN_NO_START
/*
 * Loader 启动 CPU 后首先执行 _start，不依赖标准 C 运行库。
 * naked 禁止编译器在栈尚未初始化前自动生成函数入栈代码。
 * __stack_top、__bss_start、__bss_end 均由 linker_cnn.ld 提供。
 */
__attribute__((used, naked, noreturn, section(".text.start")))
void _start(void)
{
    __asm__ volatile (
        /* 关闭地址松弛，初始化栈指针，不依赖尚未设置的 gp 寄存器。 */
        ".option push\n"
        ".option norelax\n"
        "la sp, __stack_top\n"

        /* 按 32 位字清零 .bss，确保无初值全局变量从 0 开始。 */
        "la t0, __bss_start\n"
        "la t1, __bss_end\n"
        "1: bgeu t0, t1, 2f\n"
        "sw zero, 0(t0)\n"
        "addi t0, t0, 4\n"
        "j 1b\n"

        /* 摄像头模式连续运行；自检、指定帧数结束或失败后停在此处。 */
        "2: call cnn_main\n"
        "3: j 3b\n"
        ".option pop\n"
    );
}
#endif
