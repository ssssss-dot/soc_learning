# soc_learning

使用 SystemVerilog 实现的五级流水 RISC-V SoC 学习工程。当前主要通路为：CPU 配置 DMA，将 DDR 数据搬入共享 BRAM，Conv 完成卷积并写回 BRAM，再由 DMA 将结果搬回 DDR。

本文按当前工作区源码整理。**“已接入”表示顶层存在连接，不等于当前版本已经通过完整仿真、综合或上板验证。**预期结果与实际测试记录应分开保存。

## 1. 当前实现状态

| 部分 | 当前状态 |
| --- | --- |
| CPU | IF/ID/EX/MEM/WB 五级流水，含前递、暂停、分支冲刷、机器模式 CSR/外部中断，以及自定义 CMP/CMPU 译码 |
| ICache / DCache | 各为 2 路、32 组、每行一个 32 位字，通过 Bridge 访问 AXI |
| AXI / DDR | 顶层为 6 个主机入口、3 个从机出口，DDR 经过时钟转换器连接 MIG |
| UART | Loader 使用 `uart_rxd/uart_txd`；CPU MMIO 打印使用独立的 `dbg_uart_txd` |
| DMA | 读写描述符、状态和中断原因独立；AXI-Stream 两端连接共享 BRAM |
| 共享 BRAM | 16384×32 位，即 64 KiB，供 DMA 和 Conv 使用 |
| Conv | 已例化到 `soc_top`，含 5×5 im2col、16×25 PE 阵列、跨通道累加、bias、量化、输出打包 |
| FC | 已有地址宏和 router 内部路由；`fc_reg.sv` 是未完成框架，`fc_ctrl.sv` 为空，尚无完整计算模块及顶层接入 |
| Pool | 仅预留地址窗口，尚无计算模块、寄存器实现或 router 响应通路 |
| 测试 | 有 DMA 裸机测试、Conv 独立 TB、Conv+DMA 裸机诊断程序，不是完整 CNN 推理验收 |

当前 `soc_top` 的 router 实例只连接 DMA 和 Conv，尚未连接 FC 端口。**软件不要访问 Pool/FC 窗口**；不要假设未实现窗口会自动返回错误，当前 router 没有这类请求的默认完成响应。

## 2. 架构与数据流

```text
CPU：IF → ID → EX → MEM → WB

ICache / DCache / CPU UART / CPU MMIO ──┐
UART Loader ──────────────────────────┤
DMA AXI master ───────────────────────┴── AXI Crossbar（6入 / 3出）
                                           ├── AXI Clock Converter → MIG → DDR4
                                           ├── AXI-to-Native UART → dbg_uart_txd
                                           └── AXI-to-Native MMIO → mmio_router
                                                                      ├── dma_ctrl
                                                                      ├── conv_reg
                                                                      └── FC预留，顶层未接通

DDR → DMA读通道 → AXI-Stream → 共享BRAM（64 KiB）
                                    ↕
                                  Conv
                                    ↓
DDR ← DMA写通道 ← AXI-Stream ← 共享BRAM
```

Crossbar 输入编号依次为 ICache、DCache、Loader、CPU UART、CPU 通用 MMIO、DMA；输出依次为 DDR、UART、通用 MMIO。名称为 `taxi_axi_crossbar_3s` 的模块在顶层实际参数化为 6 入 3 出。

CPU/前端运行在 `clk` 域，DDR AXI 后端使用 MIG 的 `c0_ddr4_ui_clk`，两者之间有 AXI 时钟转换器。CPU 复位释放还受到 Loader 和 DDR 初始化完成状态控制。

### 一次 Conv 任务的顺序

1. CPU 在 DDR 中准备输入、重排后的权重和 INT32 bias。
2. 配置 DMA 读任务，把各区域分别搬入共享 BRAM 的指定偏移。
3. 等待搬运结束，再配置并启动 Conv。
4. Conv 读取共享 BRAM，在内部缓存/部分和 RAM 中计算，最终 INT8 输出写回共享 BRAM，从字节地址 0 开始。
5. 等待 Conv 完成，再启动 DMA 写任务，把输出搬回 DDR。
6. CPU 等待写任务完成，读取结果并校验，通过 UART 打印。

DMA 的“读”指 **DDR→BRAM**，“写”指 **BRAM→DDR**。两方向可以分别启动、分别报告完成，不必完成一次往返才发中断。方向独立不表示共享数据可以无条件并发读写；先使用上述串行调度。

顶层用 `conv_busy` 阻止 DMA 向共享 BRAM 写入，但这不是完整的多加速器仲裁，也不会替软件阻止所有有冲突的 DMA 读操作。计算期间不要启动冲突搬运。

## 3. 地址空间与单位

### CPU 与 AXI 地址

| 地址/范围 | 用途 |
| --- | --- |
| CPU 指令基址 `0x0000_0000` | 经 ICache Bridge 映射到 DDR 指令基址 `0x0000_0000` |
| CPU 数据基址 `0x8000_0000` | 经 DCache Bridge 映射到 DDR 数据基址 `0x1000_0000` |
| AXI `0x0000_0000～0x3FFF_FFFF` | Crossbar 的 DDR 译码窗口，不表示板卡实际安装了等量内存 |
| `0x4000_0000～0x4000_0FFF` | UART 窗口，软件发送地址为 `0x4000_0000` |
| `0x4000_4000～0x4000_4FFF` | DMA 寄存器 |
| `0x4000_5000～0x4000_5FFF` | Conv 寄存器 |
| `0x4000_6000～0x4000_6FFF` | Pool 预留，不可访问 |
| `0x4000_7000～0x4000_7FFF` | FC 预留，当前 SoC 不可访问 |

DMA 的 SRC/DST 使用 **DDR AXI 物理地址**，不是 CPU 数据指针。当前裸机测试的转换为：

```c
dma_phys_addr = cpu_data_addr - 0x80000000u + 0x10000000u;
```

该式仅适用于当前 CPU 数据映射，不能用来转换 UART、寄存器地址或任意地址。地址宏见 [define.sv](define.sv)，实际转换见 [dcache_bridge.sv](axi/bridge/dcache_bridge.sv)。

### 共享 BRAM 地址单位

| 接口/寄存器内容 | 单位 |
| --- | --- |
| DMA RD/WR BYTE OFFSET | BRAM 字节偏移，低 16 位有效 |
| Conv INPUT_BASE / WEIGHT_BASE | BRAM 字节偏移 |
| Conv BIAS_BASE | **BRAM 32 位字地址**，低 14 位有效 |
| Conv `acc_rd_addr/acc_wr_addr` | BRAM 32 位字地址，14 位 |
| FC 各 BASE 的规划 | BRAM 字节偏移，包含 bias；尚待 FC 实现 |

例如 bias 放在 BRAM 字节偏移 `0x6000`，应向 Conv BIAS_BASE 写入 `0x1800`。MMIO 地址是“访问哪个寄存器”，BASE 寄存器内容是“数据在 RAM 的哪里”，两者不能混淆。

DMA BRAM 偏移转换使用 `[15:2]`，软件应提供 4 字节对齐地址；长度单位为字节、描述符实际使用低 16 位。使用非零、合法范围内的长度，并保证 `offset + length <= 65536`。这些约束不能依赖当前硬件自动完整检查。

## 4. DMA 寄存器与中断

基址 `0x4000_4000`。当前寄存器写入要求 `wstrb=4'b1111`，软件使用对齐的 32 位写访问。

| 偏移 | 地址宏 | 含义 |
| --- | --- | --- |
| `0x00` | `DMA_SRC_BASE` | DDR 读源物理地址 |
| `0x04` | `DMA_DST_BASE` | DDR 写目的物理地址 |
| `0x08` | `DMA_RDLEN_BASE` | DDR→BRAM 字节数，低 16 位参与描述符 |
| `0x0C` | `DMA_CONTROL_ADDR` | bit0 启动读；bit1 全局中断使能；bit2 启动写 |
| `0x10` | `DMA_STATUS_ADDR` | 只读状态，位定义见下文 |
| `0x14` | `DMA_IRQ_CLEAR_ADDR` | 低 4 位写 1 清除相应中断原因 |
| `0x18` | `DMA_WRLEN_BASE` | BRAM→DDR 字节数，低 16 位参与描述符 |
| `0x1C` | `DMA_IRQ_STATUS_ADDR` | 低 4 位记录中断原因，只读 |
| `0x20` | `DMA_IRQ_ENABLE_ADDR` | 各中断原因的使能掩码，使用低 4 位 |
| `0x24` | `DMA_RD_BYTE_OFFSET_ADDR` | DDR→BRAM 的 BRAM 目标字节偏移 |
| `0x28` | `DMA_WR_BYTE_OFFSET_ADDR` | BRAM→DDR 的 BRAM 源字节偏移 |

`STATUS[6:0]` 从低到高是：`rd_busy、wr_busy、rd_done、wr_done、rd_error、wr_error、irq_pending`。done 表示对应描述符成功结束，error 表示描述符报告错误；启动对应方向的新任务会清掉该方向旧 done/error。

IRQ STATUS / ENABLE / CLEAR 共用以下位定义：

| 位 | 原因 |
| --- | --- |
| 0 | 读描述符结束 |
| 1 | 写描述符结束 |
| 2 | 读描述符错误 |
| 3 | 写描述符错误 |

当前 IRQ bit0/1 在描述符状态 valid 时置位，即使发生错误也会置位；出错时还同时置 bit2/3。因此不能只看“结束位”就认定成功。

```text
dma_irq = CONTROL[1] && 非零(IRQ_STATUS & IRQ_ENABLE)
STATUS.irq_pending = 非零(IRQ_STATUS)，不受使能掩码影响
```

清 IRQ 原因不等于清 STATUS 中的 rd_done/wr_done/rd_error/wr_error。清除与新事件同拍时，新事件优先保留。

### CONTROL 不支持软件读改写（RMW）

当前 `dma_ctrl` 保存整个写入值，START 位读回时可能仍为 1，但实际启动事件由 CONTROL 写握手产生。软件不得对 CONTROL 使用 `|=`、`&=` 或“读出后原样写回”，否则可能在方向空闲时再次启动任务。

下面假设 `MMIO32(addr)` 是 volatile 32 位 MMIO 访问宏：

```c
/* 完整值写入，不读取旧CONTROL；两次启动应放在各自任务就绪时执行。 */
MMIO32(0x40004020u) = 0x0Fu;       /* 使能四种中断原因 */
MMIO32(0x40004014u) = 0x0Fu;       /* 清除旧中断原因 */
MMIO32(0x4000400Cu) = (1u << 1) | (1u << 0); /* 启动DDR→BRAM */
/* 等待读任务、计算及其他必要操作完成，配置写目的地址和长度后： */
MMIO32(0x4000400Cu) = (1u << 1) | (1u << 2); /* 启动BRAM→DDR */
```

任务执行时保持相关源/目的地址和长度配置不变。BRAM 偏移在启动时锁存，但并非所有 DMA 配置都由独立活动副本保存。

## 5. Conv 数据布局与寄存器

基址 `0x4000_5000`：

| 偏移 | 地址宏 | 含义 |
| --- | --- | --- |
| `0x00` | `CONV_CONTROL_ADDR` | bit0 START，写 1 自清；bit1 中断使能 |
| `0x04` | `CONV_STATUS_ADDR` | bit0 busy 只读；bit1 done、bit2 error 保持并写 1 清除 |
| `0x08` | `CONV_INPUT_SHAPE_ADDR` | `[15:0]` 宽度，`[31:16]` 高度 |
| `0x0C` | `CONV_CHANNELS_ADDR` | `[15:0]` 输入通道数，`[31:16]` 输出通道数 |
| `0x10` | `CONV_BIAS_BASE_ADDR` | bias 的 BRAM 字地址，低 14 位有效 |
| `0x14` | `CONV_QUANT_MULT_ADDR` | 32 位无符号量化乘数 |
| `0x18` | `CONV_QUANT_SHIFT_ADDR` | 量化右移位数，低 6 位有效 |
| `0x1C` | `CONV_INPUT_BASE_ADDR` | 输入的 BRAM 字节基址 |
| `0x20` | `CONV_WEIGHT_BASE_ADDR` | 权重的 BRAM 字节基址 |

配置支持按字节 strobe 更新。STATUS 低字节有效写入 `2` 清 done、`4` 清 error、`6` 清两者，写 0 保持；新 done/error 事件优先于同拍软件清除。启动新任务也会清旧状态。

当前 `conv_reg` 仍在 IDLE 看到 valid 时执行读写，随后在 REQ 状态完成请求握手；不是“IDLE 锁存请求、REQ 才提交访问”的改写版本。上游必须保持 valid 和请求内容到握手完成。响应 valid 和锁存读数据在 RSP 等待期间保持。

软件在 busy 期间不要修改配置或重复启动。当前配置输出有直接连线，硬件没有完整的忙时写保护或非法配置检查；`error=0` 不能替代参数和地址校验。

### 数据格式与量化

- 输入：有符号 INT8，按 `[输入通道][行][列]` 排列。
- 权重：有符号 INT8，按 `[输入通道][核行][核列][16个PE行]` 排列；不足 16 个输出通道时，其余 PE 行权重补零。每输入通道占 `25×16=400B`。
- bias：每个有效输出通道一个 INT32，与输入×权重的累加结果具有相同尺度。
- 输出：按 `[输出通道][输出行][输出列]` 排列，四个 INT8 按低地址到低字节打包成一个 32 位字。

当前结构面向 5×5、stride=1、无 padding；输出尺寸为 `(H-4)×(W-4)`。主要测试配置是 Conv1 `1×32×32 → 6×28×28` 和 Conv2 `6×14×14 → 16×10×10`，不能据此宣称支持任意形状。

量化路径为 INT32 累加加 bias → 乘 MULT → 舍入右移 SHIFT → ReLU → 限幅至 127。正数且 SHIFT>0 时：

```text
output = min(127, (sum*MULT + 2^(SHIFT-1)) >> SHIFT)
```

SHIFT=0 时不加舍入偏置；非正结果输出零。`int32_int8` 是四级寄存流水线，最终结果看 `dut.quant_data/quant_valid`，参考答案看 `golden_data`，不能与同拍累加输入直接比较。

输出固定从 BRAM 字节地址 0 开始，没有 Conv OUTPUT_BASE 寄存器。输入、权重、bias 与输出应分区，避免提前覆盖仍需读取的数据。当前 output_cache 按四字节完整字输出，现有测试长度均为 4 的倍数；不足四字节的尾部不是已验证功能。

## 6. FC / Pool 开发边界

FC 基址 `0x4000_7000`，当前定义的寄存器偏移为：

| 偏移 | 地址宏 | 规划用途 |
| --- | --- | --- |
| `0x00` | `FC_CONTROL_ADDR` | 启动、中断、输出处理控制 |
| `0x04` | `FC_STATUS_ADDR` | busy/done/error |
| `0x08` | `FC_IN_FEATURES_ADDR` | 输入元素数量 |
| `0x0C` | `FC_OUT_FEATURES_ADDR` | 输出元素数量，不是固定字节数 |
| `0x10` | `FC_INPUT_BASE_ADDR` | 输入字节基址 |
| `0x14` | `FC_WEIGHT_BASE_ADDR` | `[输出][输入]` 权重字节基址 |
| `0x18` | `FC_BIAS_BASE_ADDR` | INT32 bias 字节基址，与 Conv 的字地址约定不同 |
| `0x1C` | 保留 | 读返回0、写忽略；整层输出固定从共享BRAM字节地址0开始，各组连续存放 |
| `0x20` | `FC_QUANT_MULT_ADDR` | 量化乘数 |
| `0x24` | `FC_QUANT_SHIFT_ADDR` | 量化右移位数 |

以上是地址规划，不是可用外设承诺。后续需补全寄存器功能、FC 计算通路、顶层端口、中断接入，以及与 Conv/Pool 的共享 RAM 访问选择。

当前需要同步的设计差异：

- 已讨论的 FC 方案是固定加 bias，保留 ReLU 开关和 INT32 输出选择；`define.sv` 的 CONTROL 注释仍列有 bit3 bias_enable，需在实现时统一为保留位或最终约定。本次只整理 README，未修改该宏注释或 RTL。
- `acc_demo.py` 当前网络为 `400→96→64→10`，FC 地址宏注释仍举旧的 `400→120→84→10` 为例。实际配置应跟随本次导出的模型，不要照抄旧示例。
- 最后一层分类分数不能强制 ReLU；若选 INT8 输出，应保留有符号结果并验证量化误差；若选 INT32 输出，10 个分数只需 40B。
- Pool 暂仅预留 `0x4000_6000`，尚未定义完整寄存器表和实现。

RAM 规划优先复用已有 64 KiB 共享 RAM，不为每个加速器复制整层缓存。新增模块的物理 BRAM、DSP 和时序余量必须以实际器件的综合/实现报告为准，不能只根据逻辑字节数或旧版本百分比判断。

## 7. 中断与 Cache 一致性

顶层将 `dma_irq | conv_irq` 接到 CPU 的机器外部中断输入，没有独立 PLIC。软件在中断处理中分别读取 DMA/Conv 状态、确认来源并清除挂起原因；CPU 的 `mstatus.MIE`、`mie.MEIE` 和 `mtvec` 也需正确配置。

DCache 存储通路采用写穿方式。DMA 绕过 CPU Cache 写 DDR 后，顶层用独立的 `dma_wr_done_pulse` 通知 DCache 失效；该事件来自写描述符状态 valid，不受 DMA 中断使能屏蔽。DCache 忙时先记录待失效事件，回到空闲后清除有效位。

因此轮询模式下关闭中断不等于关闭 Cache 失效。软件仍需等待 DMA 真正结束后再读目的数据；不能把普通 `fence` 当成通用 Cache 清空指令，也不能在 DMA 尚未结束时据 CPU 读值判断结果。

## 8. 验证入口

### 独立 Conv 仿真

顶层为 [testbench_conv.sv](testbench_conv.sv) 的 `testbench_conv`。添加 `coprocessor/conv/` 下模块、`coprocessor/pe_ws.sv` 和根目录 include 路径，按 SystemVerilog 编译。该 TB 不需要 CPU、DMA 或 MIG。

TB 使用 Conv2 `6×14×14 → 16×10×10`，MULT=3、SHIFT=5；直接数学卷积产生 golden，不依赖被测 CPU。检查结束后要求：

```text
check_done=1，test_pass=1，timed_out=0
accum_count=1600，accum_errors=0
write_count=400，write_errors=0，data_errors=0
dut.error=0，三个参考覆盖计数均大于0
```

`done` 只表示硬件完成，不代表数据正确。TB 默认不打印 PASS；支持 FSDB 的环境可编译定义 `DUMP`，运行时用 `+FSDB=路径` 指定文件，并准备好输出目录及 FSDB 支持。其他环境使用自身波形记录功能。

完整的 golden 公式、布局、波形对齐与错误定位见 [conv_tb_result.md](conv_tb_result.md)。其中样本值是预期值，不是上板验收记录。

### 裸机程序

| 文件 | 测试内容 |
| --- | --- |
| [dma_test.c](dma_test.c) | 16 个 32 位字的 DDR→BRAM→DDR 原样搬运；读完成中断再启动写，验证两次完成及数据一致性，不再经过 add 模块 |
| [conv_dma_test.c](conv_dma_test.c) | 轮询 DMA/Conv，分别运行 Conv1 和人工构造的 Conv2 输入，检查全部输出 |
| [cache_test.c](cache_test.c) | CPU Cache/访存测试，需结合当前地址映射和构建流程使用 |

Conv 裸机测试不是 Conv1→Pool→Conv2 的完整网络：Pool 尚未接入，Conv2 使用独立合成输入。诊断版包含 PRE-DMA 算术自检、独立 golden 表及 tight/spaced 指令探针，详见 [conv_dma_test_diagnostics.md](conv_dma_test_diagnostics.md)。上板编译不要定义 `CONV_DIAG_HOST_TEST`；它不是通用 SoC 主机仿真开关。

裸机测试 BRAM 布局与独立 TB 不同，但两者各自自洽：

| 内容 | Conv 裸机测试字节偏移 | 独立 Conv TB 字节偏移 |
| --- | --- | --- |
| 输出 | `0x0000` | `0x0000` |
| 输入 | `0x2000` | `0x5000` |
| 权重 | `0x4000` | `0x7000` |
| bias | `0x6000`（配置字地址 `0x1800`） | `0x4000`（配置字地址 `0x1000`） |

### CPU 仿真与历史资料

当前工作区已移除旧 `testbench_cpu.sv` 和 `testbench_cpu_top.sv`。保留的 [cpu_tb_top.sv](cpu_tb_top.sv) 是 CPU 仿真包装模块，不能把它本身当成带有程序加载、时钟和通过判定的完整 testbench。CPU 单独验证需补齐匹配的驱动、存储器模型和测试程序。

[TEST_PROGRAMS.md](TEST_PROGRAMS.md) 保留早期 `cpu_top/inst.data` 测试方式，不是当前 `soc_top` 的开箱即用入口。不要将所有 TB 同时设为仿真顶层；历史文档与当前 RTL 不一致时，以当前实现为准。

## 9. 获取、构建与下载

```bash
git clone https://github.com/ssssss-dot/soc_learning.git
cd soc_learning
```

私有仓库需要访问权限。工作区中新建而尚未提交的测试、文档或 FC 文件，其他设备 clone 后不会自动获得；共享版本前需确认所需文件已经入库。

### Vivado 硬件构建

使用 [build_5pipeline_p5b.tcl](build_5pipeline_p5b.tcl)，顶层 `soc_top`、约束 [5pipeline_p5b.xdc](5pipeline_p5b.xdc)。默认器件为 `xczu2eg-sfvc784-2-e`；不要与旧 `5pipeline.tcl` 中的器件配置混用。

准备步骤：

1. 安装支持实际器件的 Vivado，核对板卡、引脚、时钟和 DDR 参数。
2. 提供匹配板卡的 MIG 配置 `ip/ddr4_0/ddr4_0.xci`；仓库当前没有 `.xci` 文件，脚本不会自动猜测 DDR 参数。
3. 可提供现有 `axi_clock_converter_0` 和 `ila_0` XCI；未提供时脚本会按当前参数生成。
4. 检查输出目录。脚本使用 `create_project -force`，已有工程请使用独立 BUILD_DIR。

```bash
vivado -mode batch -source build_5pipeline_p5b.tcl
```

环境变量 `FPGA_PART`、`JOBS`、`BUILD_DIR`、`IP_ROOT` 可覆盖器件、并行数、构建目录和 IP 目录。更换器件不等于自动适配板卡，XDC 和 MIG 也必须一致。

默认输出：

```text
vivado_p5b_build/5pipeline_p5b.runs/impl_1/soc_top.bit
vivado_p5b_build/reports/utilization_synth.rpt
vivado_p5b_build/reports/utilization_impl.rpt
vivado_p5b_build/reports/timing_impl.rpt
```

脚本已列入 Conv 源码，未列入未完成的 FC。Taxi 的 rd/wr 目录有重复公共模块，沿用脚本去重文件清单，不要无差别递归加入所有 `.sv`。本次 README 整理未执行 Vivado 构建，不能保证当前开发快照无编译或时序问题。

### 裸机编译与串口下载

当前没有统一的 C 构建脚本或现成链接脚本文件。需要 RISC-V 交叉工具链、匹配 CPU 指令集的编译参数、正确的代码/数据地址和启动栈；不能假设 CPU 支持 M/C 等扩展。自定义 CMP/CMPU 需要配套编译器支持。

软件流程为：编译链接 ELF → 提取原始指令/数据 → 转换为 Loader 接受的 PQR5 封装 → 下载 FPGA bitstream → 串口加载程序。`peqflash.py` 依赖 Python 3 和 pyserial；封装后的程序文件不是任意 raw bin，也不是 FPGA bitstream。

```bash
python3 peqflash.py -serport /dev/ttyUSB0 -baud 115200 \
  -imembin program_iram.bin -dmembin program_dram.bin
```

串口名、波特率和文件名替换为实际值。协议下载使用 Loader 串口，程序打印观察 `dbg_uart_txd`，两者不是同一个发送端口。

[CMP_BUILD_FLASH_EXAMPLE.md](CMP_BUILD_FLASH_EXAMPLE.md) 提供编译、链接和封装的历史示例，但其中 UART 地址 `0x10000000` 已不适用于当前 MMIO；当前为 `0x40000000`。示例中的链接/转换脚本是文档片段，不能假设同名文件已经存在。

## 10. 训练与模型导出

[acc_demo.py](acc_demo.py) 当前训练网络：

```text
1×32×32 → Conv1(6,5×5) → ReLU → MaxPool2×2
        → Conv2(16,5×5) → ReLU → MaxPool2×2
        → Flatten(400) → FC1(96) → ReLU → FC2(64) → ReLU → FC3(10)
```

脚本依赖 torch、torchvision、d2l、numpy，会下载 MNIST 并训练；运行前检查运行环境和数据目录。设备按 CUDA、MPS、CPU 的可用性选择，默认导出目录为 `soc_export_int8`。

导出包含 INT8 权重、INT32 小端 bias、第一张测试图片和标签，以及 `scales.json` 中每层的 MULT/SHIFT。Conv 权重已重排并填充到 16 个 PE 行，bias 按输入尺度×权重尺度量化。当前激活尺度由一个测试批次估计，不能代替量化后全测试集精度验证。

模型文件准备好不等于硬件全网络已完成；Pool、FC 和层间调度仍需实现与验证。

## 11. 目录与后续工作

```text
soc_top.sv                 SoC硬件顶层
define.sv                  总线、指令、地址宏
mmio_router.sv             DMA / Conv / FC请求响应路由
if/ id/ ex_stage/          CPU前端、译码、执行与CSR
mem_stage/ wb_stage/       CPU访存、DCache与写回
axi/                      AXI互连、协议和地址转换
loader/                   串口程序加载
dma/                      DMA控制、描述符和AXI/AXIS通路
coprocessor/bram_for_acc.sv 共享加速器BRAM
coprocessor/conv/          Conv计算与控制
coprocessor/pe_ws.sv       当前Conv使用的weight-stationary PE
coprocessor/pe_os.sv       保留的output-stationary PE，当前Conv未使用
coprocessor/fc/            开发中的FC框架
```

近期需要完成：FC 寄存器/计算/输出模式、Pool、共享 RAM 访问控制、顶层与中断连接、未实现 MMIO 窗口的错误响应，以及各层单元测试到整网验证。改变参数、地址、数据布局或流水线后，应同步更新 RTL、软件和参考模型，并记录实际使用的源码版本与 bitstream。

## License

仓库包含 [CERN-OHL-S-2.0 许可证](LICENSE)。第三方源文件保留各自版权和许可证声明，使用和分发时请同时检查相应文件头部。
