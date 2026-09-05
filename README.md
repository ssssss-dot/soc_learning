# soc_learning

一个使用 SystemVerilog 编写的五级流水 RISC-V SoC 学习工程。工程包含 CPU、Cache、AXI4 Crossbar、UART Loader、DMA 以及用于验证数据通路的 AXI-Stream 协处理器。

> 当前仓库是开发快照。DMA 通路、通用 MMIO Bridge 和 MMIO Router 正在集成中，部分模块尚未完成仿真或上板验证。

## 架构概览

CPU 采用五级流水结构：

```text
IF -> ID -> EX -> MEM -> WB
```

SoC 的主要数据通路：

```text
CPU ICache/DCache ----+
UART Loader ----------+--> AXI4 Crossbar --> MIG/DDR
CPU UART Bridge ------+                   --> UART
CPU MMIO Bridge ------+                   --> AXI-to-Native MMIO
DMA AXI Full Master --+                              |
                                                     +--> DMA/加速器寄存器

DDR --> DMA Read --> AXI-Stream 协处理器 --> DMA Write --> DDR
```

## 当前地址规划

| 地址范围 | 设备 | 说明 |
| --- | --- | --- |
| `0x0000_0000-0x3FFF_FFFF` | DDR/MIG | AXI 侧物理地址窗口 |
| `0x4000_0000-0x4000_0FFF` | UART | CPU 串口输出 MMIO |
| `0x4000_4000-0x4000_7FFF` | 通用 MMIO | DMA 和后续加速器寄存器窗口 |

DMA 当前寄存器：

| 地址 | 寄存器 |
| --- | --- |
| `0x4000_4000` | DMA source address |
| `0x4000_4004` | DMA destination address |
| `0x4000_4008` | DMA read length |
| `0x4000_400C` | DMA control |
| `0x4000_4010` | DMA status |
| `0x4000_4014` | DMA IRQ clear |
| `0x4000_4018` | DMA write length |
| `0x4000_401C` | DMA IRQ status |
| `0x4000_4020` | DMA IRQ enable |

地址宏以 [`define.sv`](define.sv) 为准。

### DMA CONTROL 软件约束

当前 `DMA_CONTROL_ADDR` 不支持读改写（Read-Modify-Write，RMW）。`CONTROL[0]` 是 `START` 位，写入 `1` 会产生一次启动请求；该位当前会保存在寄存器中，因此软件读回旧值并原样写回，可能意外再次启动 DMA。

软件必须直接写入完整的目标值，不得使用 `|=`、`&=` 等读改写操作。例如：

```c
/* 错误：读回的 START 位可能仍为 1，重新写入会再次启动 DMA。 */
MMIO32(DMA_CONTROL_ADDR) |= DMA_CONTROL_IRQ_EN;

/* 正确：显式写入完整控制值。 */
MMIO32(DMA_CONTROL_ADDR) = DMA_CONTROL_IRQ_EN;
MMIO32(DMA_CONTROL_ADDR) = DMA_CONTROL_START | DMA_CONTROL_IRQ_EN;
```

如果以后将 `START` 改成只写脉冲位或硬件自清零位，可再解除这一软件限制。

## 目录说明

```text
axi/                 AXI Crossbar 和协议转换 Bridge
coprocessor/         AXI-Stream 测试协处理器与加速器相关模块
dma/                 DMA 控制器、AXI Full 和 AXI-Stream 数据通路
ex_stage/            EX 阶段及 CSR
id/                  ID 阶段和寄存器堆
if/                  IF 阶段、ICache 和指令 RAM
loader/              UART Loader
mem_stage/           MEM 阶段和 DCache
wb_stage/            WB 阶段
soc_top.sv            SoC 顶层
define.sv             全局参数、地址和总线宏
build_5pipeline_p5b.tcl Vivado 构建脚本
*.xdc                 FPGA 约束
*_test.c              裸机测试程序
```

## 获取工程

```bash
git clone https://github.com/ssssss-dot/soc_learning.git
cd soc_learning
```

仓库为私有仓库时，需要先在新设备上登录有访问权限的 GitHub 账号。

## Vivado 构建

安装支持目标 FPGA 的 Vivado，然后在工程目录执行：

```tcl
vivado -mode batch -source build_5pipeline_p5b.tcl
```

构建前应检查 Tcl 源文件清单是否包含正在使用的 Crossbar、MMIO Bridge、DMA 和顶层文件。工程处于重构阶段时，旧版与新版模块可能同时保留在目录中。

## DMA 测试

`dma_test.c` 的预期流程：

1. CPU 通过 MMIO 写入 DMA 源地址、目的地址和长度。
2. DMA 通过 AXI Full 从 DDR 读取数据。
3. 数据经过 AXI-Stream 测试协处理器处理。
4. DMA 将结果通过 AXI Full 写回 DDR。
5. DMA 产生完成中断，CPU 检查结果并通过 UART 输出。

生成的 `*.bin` 文件不纳入版本控制，应在目标设备上根据对应测试程序重新构建。

## 开发注意事项

- AXI 的 AW 和 W 通道彼此独立，Bridge 必须分别握手和锁存。
- Crossbar 后端从机必须原样返回事务 ID，保证响应能路由回原始主机。
- MMIO 当前按单拍事务设计，`AWLEN/ARLEN` 应为 0，读写响应必须遵守 valid/ready 规则。
- DMA 绕过 CPU DCache 直接访问 DDR，DMA 完成后需要处理缓存一致性。
- 修改地址规划时，需要同步检查软件地址宏、Crossbar 解码参数和设备内部寄存器译码。

## License

本项目新增的开放硬件设计源文件采用 `CERN-OHL-S-2.0`。第三方模块保留各自文件中的原始版权和许可证声明，详见 [`LICENSE`](LICENSE) 以及对应源文件头部。
