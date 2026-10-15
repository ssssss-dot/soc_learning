/*
 * acc_demo 真实模型上板程序
 *
 * 网络流程：
 *   1×32×32 -> Conv1 -> Pool1 -> Conv2 -> Pool2 -> FC1 -> FC2 -> FC3
 *   输出数：    4704     1176     1600      400      96      64      10
 *
 * 图片、权重、偏置和量化参数使用 soc_export_int8 中的训练导出结果。
 * CPU 负责配置寄存器、DMA 搬运、结果校验和分类，计算由协处理器完成。
 *
 * 构建：build_cnn.py；链接脚本：linker_cnn.ld。
 * 日志：0x40000000 -> dbg_uart_txd，115200 baud，8N1。
 *
 * 建议先看 cnn_main() 理解整体流程，再看 run_conv/run_pool/run_fc。
 * 本文件中返回 int 的函数均约定：0 表示成功，1 表示失败。
 */

#include <stdint.h>

#include "model_layout.h"   /* 自动生成：模型地址、数据长度、MULT/SHIFT。 */
#include "cnn_reference.h"  /* 自动生成：各层 INT8 参考结果、模型校验值。 */


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
#define DMA_IRQ_EN     0x40004020u  /* DMA 中断使能，本程序配置为 0。 */
#define DMA_RD_OFFSET  0x40004024u  /* DDR -> BRAM 的 BRAM 字节偏移。 */
#define DMA_WR_OFFSET  0x40004028u  /* BRAM -> DDR 的 BRAM 字节偏移。 */

#define CONV_BASE      0x40005000u
#define POOL_BASE      0x40006000u
#define FC_BASE        0x40007000u

/* Conv、Pool、FC 的状态寄存器均位于各自基地址 + 0x04。 */
#define STATUS         4u
#define BUSY           1u          /* bit0：正在运行。 */
#define DONE           2u          /* bit1：运行完成，写 1 清除。 */
#define ERROR          4u          /* bit2：发生错误，写 1 清除。 */
#define TIMEOUT        5000000u    /* 最大轮询次数，不是时钟周期数。 */

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
//BRAM计算结果 → DMA → output_data（数组） → CPU逐个校验
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

/* 使用轮询等待完成，因此关闭 mstatus.MIE 和 mie 中的中断使能。 */
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

/* 同一块 DDR：CPU 从 0x80000000 访问，DMA 从 0x10000000 访问。 */
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
 * DMA_STATUS：bit0/1 为读/写 busy，bit2/3 为读/写 done，bit4/5 为错误。
 * 只在 done=1 且对应 busy=0 时返回，不要求先观察到 busy=1。
 * busy_mask/done_mask 决定本次等待的是 DDR -> BRAM，还是 BRAM -> DDR。
 */
static int wait_dma(uint32_t busy_mask, uint32_t done_mask)
{
    uint32_t i;
    uint32_t status = 0u;

    for (i = 0u; i < TIMEOUT; ++i)
    {
        status = reg_read(DMA_STATUS);

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
    reg_write(DMA_CLEAR, 15u);             /* 清除上次完成/错误状态。 */
    reg_write(DMA_SRC, ddr_address);
    reg_write(DMA_RD_LEN, bytes);
    reg_write(DMA_RD_OFFSET, bram_offset);
    memory_fence();

    reg_write(DMA_CONTROL, 1u);           /* 启动 DDR -> BRAM。 */

    return wait_dma(1u, 4u);
}

/* Conv、Pool、FC 的状态位定义一致，因此共用同一个等待函数。 */
static int wait_accelerator(uint32_t base)
{
    uint32_t i;
    uint32_t status = 0u;

    for (i = 0u; i < TIMEOUT; ++i)
    {
        status = reg_read(base + STATUS);

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
 * 计算结果先从 BRAM 地址 0 搬到 output_data，校验后再供下一层使用。
 * DMA 长度向上对齐到 4 字节：FC3 的 10 字节搬运为 12 字节，只比较前 10 字节。
 */
static int finish_layer(const char *name, uint32_t count,
                        const int8_t *expected, uint32_t base)
{
    uint32_t i;
    uint32_t mismatches = 0u;
    uint32_t transfer = (count + 3u) & ~3u;

    /* 预填 A5，便于发现 DMA 未覆盖结果区或写出了规定范围。 */
    for (i = 0u; i < OUTPUT_BYTES; ++i)
    {
        output_data[i] = 0xA5u;
    }

    memory_fence();
    reg_write(DMA_CLEAR, 15u);
    reg_write(DMA_DST, output_ddr_address());
    reg_write(DMA_WR_LEN, transfer);
    reg_write(DMA_WR_OFFSET, 0u);
    memory_fence();

    reg_write(DMA_CONTROL, 4u);           /* 启动 BRAM -> DDR。 */

    if (wait_dma(2u, 8u))
    {
        return 1;
    }

    /*
     * soc_top 在 DMA 写 DDR 完成时使 DCache 失效，CPU 随后读取新结果。
     * 必须转为 int8_t 后比较，否则负数会被当成 128～255 的无符号数。
     */
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

    /* 搬运区域后面的 16 字节应保持 A5，用于检查 DMA 越界写入。 */
    for (i = transfer; i < transfer + 16u; ++i)
    {
        if (output_data[i] != 0xA5u)
        {
            return fail("DMA destination guard", i);
        }
    }

    if (mismatches)
    {
        return fail(name, mismatches);
    }

    /* 状态采用写 1 清除；读回确认后再进行下一层。 */
    reg_write(base + STATUS, DONE | ERROR);

    if (reg_read(base + STATUS) & (BUSY | DONE | ERROR))
    {
        return fail("completion clear", base);
    }

    uart_puts(name);
    uart_puts(" OK, outputs=");
    uart_number((int32_t)count);
    uart_puts("\r\n");

    return 0;
}


/* 5. Conv、Pool、FC 的逐层调度 */

/*
 * second=0：Conv1，输入 1×32×32，输出 6×28×28。
 * second=1：Conv2，输入 6×14×14，输出 16×10×10。
 * input_ddr 是输入数据的 DDR/AXI 地址，两个卷积层均使用 5×5 卷积核。
 */
static int run_conv(uint32_t second, uint32_t input_ddr)
{
    const char *name = second ? "Conv2" : "Conv1";

    uart_puts("Start ");
    uart_puts(name);
    uart_puts("\r\n");

    /* 依次装载输入、权重和偏置，全部完成后才启动卷积。 */
    if (dma_to_bram(input_ddr, second ? 1176u : 1024u, BRAM_INPUT) ||
        dma_to_bram(second ? MODEL_CONV2_WEIGHT_DDR_ADDR : MODEL_CONV1_WEIGHT_DDR_ADDR,
                    second ? MODEL_CONV2_WEIGHT_BYTES : MODEL_CONV1_WEIGHT_BYTES,
                    BRAM_WEIGHT) ||
        dma_to_bram(second ? MODEL_CONV2_BIAS_DDR_ADDR : MODEL_CONV1_BIAS_DDR_ADDR,
                    second ? MODEL_CONV2_BIAS_BYTES : MODEL_CONV1_BIAS_BYTES,
                    BRAM_BIAS))
    {
        return 1;
    }

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
    reg_write(CONV_BASE, 1u);             /* 启动卷积，中断使能保持 0。 */

    if (wait_accelerator(CONV_BASE))
    {
        return 1;
    }

    return finish_layer(name, second ? 1600u : 4704u,
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
    const char *name = second ? "Pool2" : "Pool1";

    uart_puts("Start ");
    uart_puts(name);
    uart_puts("\r\n");

    /* Conv 输出仍在 BRAM 字节地址 0，无需从 DDR 重新装载。 */
    reg_write(POOL_BASE + STATUS, DONE | ERROR);

    /* 0x08 配置输入高/宽，0x0C 配置通道数。 */
    if (configure(POOL_BASE + 0x08u, second ? 0x000A000Au : 0x001C001Cu) ||
        configure(POOL_BASE + 0x0Cu, second ? 16u : 6u))
    {
        return 1;
    }

    memory_fence();
    reg_write(POOL_BASE, 1u);

    if (wait_accelerator(POOL_BASE))
    {
        return 1;
    }

    return finish_layer(name, second ? 400u : 1176u,
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

    uart_puts("Start ");
    uart_puts(name);
    uart_puts("\r\n");

    /* Pool2 按 CHW 顺序连续存储，400 个输出可直接作为 FC1 的展平输入。 */
    if (dma_to_bram(output_ddr_address(), inputs, BRAM_INPUT) ||
        dma_to_bram(weights, weight_bytes, BRAM_WEIGHT) ||
        dma_to_bram(biases, bias_bytes, BRAM_BIAS))
    {
        return 1;
    }

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
    reg_write(FC_BASE, layer == 2u ? 1u : 5u);

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
 * 这是快速一致性检查；计算结果还会在每层结束后做精确比较。
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

int cnn_main(void)
{
    uint32_t i;
    uint32_t status;
    uint32_t prediction = 0u;
    uint32_t label;

    /* 第一步：采用轮询模式，检查 DMA 和三个协处理器是否空闲。 */
    disable_interrupts();
    uart_puts("\r\nacc_demo trained INT8 model\r\n");

    status = reg_read(DMA_STATUS);

    if (status & 0x33u)
    {
        return fail("DMA not idle/clean", status);
    }

    if ((reg_read(CONV_BASE + STATUS) |
         reg_read(POOL_BASE + STATUS) |
         reg_read(FC_BASE + STATUS)) & BUSY)
    {
        return fail("accelerator already busy", 1u);
    }

    /* 清理 DMA 状态，并关闭 DMA、Conv、Pool、FC 的中断使能。 */
    reg_write(DMA_CONTROL, 0u);
    reg_write(DMA_IRQ_EN, 0u);
    reg_write(DMA_CLEAR, 15u);
    reg_write(CONV_BASE, 0u);
    reg_write(POOL_BASE, 0u);
    reg_write(FC_BASE, 0u);

    /* 第二步：确认下载的图片、权重、偏置和量化参数与本次构建一致。 */
    if (check_model())
    {
        return 1;
    }

    /*
     * 第三步：按网络顺序执行七层，每层完成后回读和校验。
     * || 从左到右执行，某层返回 1 后停止，不继续启动后面的层。
     * Conv1 读取模型区的图片；其他 Conv/FC 读取上一层的实际输出。
     */
    if (run_conv(0u, MODEL_TEST_IMAGES_DDR_ADDR) ||
        run_pool(0u) ||
        run_conv(1u, output_ddr_address()) ||
        run_pool(1u) ||
        run_fc(0u) ||
        run_fc(1u) ||
        run_fc(2u))
    {
        uart_puts("CNN INFERENCE FAIL\r\n");
        return 1;
    }

    /* 第四步：按有符号 INT8 比较十个分类分数，最大值对应预测类别。 */
    uart_puts("\r\nFinal INT8 scores:\r\n");

    for (i = 0u; i < 10u; ++i)
    {
        uart_puts("  class ");
        uart_number((int32_t)i);
        uart_puts(": ");
        uart_number((int8_t)output_data[i]);
        uart_puts("\r\n");

        if ((int8_t)output_data[i] > (int8_t)output_data[prediction])
        {
            prediction = i;
        }
    }

    /* 标签用于判断分类是否正确；它与硬件是否匹配整数参考是两项检查。 */
    label = model_byte(MODEL_TEST_LABELS_CPU_ADDR);

    uart_puts("Prediction=");
    uart_number((int32_t)prediction);
    uart_puts(" label=");
    uart_number((int32_t)label);
    uart_puts("\r\n");
    uart_puts("CNN REFERENCE MATCH: all 8050 layer outputs\r\n");
    uart_puts(prediction == label ? "Classification correct\r\n"
                                 : "Classification differs from label\r\n");

    return 0;
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

        /* 执行一次完整推理；结束后停在此处，等待下次重新启动。 */
        "2: call cnn_main\n"
        "3: j 3b\n"
        ".option pop\n"
    );
}
#endif
