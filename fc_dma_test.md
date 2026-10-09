# FC 两层裸机测试

程序：[fc_dma_test.c](fc_dma_test.c)。按当前 [acc_demo.py](acc_demo.py) 中前两个 FC 层的尺寸运行：

| 层 | 输入数 | 输出数 | PE 分组 | 权重大小 | bias 大小 | MULT / SHIFT / ReLU |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| FC1 | 400 | 96 | 6 | 38400 B | 384 B | 1 / 4 / 开启 |
| FC2 | 96 | 64 | 4 | 6144 B | 256 B | 1 / 7 / 开启 |

Conv 保持在 SoC 中，程序只读一次它的 busy 状态，确认共享 BRAM 空闲，**不写 Conv 启动寄存器**。不运行 Pool 或 FC3。测试数据为可复现的人工数据，并非训练后的模型参数；尺寸与当前模型一致。

## 执行流程

1. 关闭 CPU 全局中断，轮询 DMA/FC 完成状态，不需要中断处理程序。
2. 在 DDR 中生成输入、权重和 bias，并通过 DMA 分别搬入共享 BRAM。
3. 读回 FC 配置寄存器检查配置，然后启动 FC1。
4. 等 FC1 完成，DMA 把 96 个输出和 16 个保护字节搬回 DDR，CPU 逐项核对。
5. 保存 **FC1 的实际输出**作为 FC2 输入，重新装载 FC2 权重、bias，运行 FC2。
6. 核对 FC2 的全部 64 个结果。任一步骤失败就停止，不在超时后继续启动可能冲突的任务。

每层检查输出区后面的 16 个 BRAM 保护字节仍为 `0xEE`，以及 DDR 接收长度之外的保护字节仍为 `0xA5`。DMA 完成后沿用 SoC 的 DCache 失效机制；程序在启动搬运和读取结果前后执行 `fence rw,rw`。

## BRAM 布局

所有地址都是 BRAM **字节偏移**，FC 的 bias 地址也使用字节单位。

| 内容 | 起始地址 | FC1 占用范围 | FC2 占用范围 |
| --- | --- | --- | --- |
| 输出及保护区 | `0x0000` | `0x0000–0x006F` | `0x0000–0x004F` |
| 输入 | `0x1000` | `0x1000–0x118F` | `0x1000–0x105F` |
| 权重 | `0x2000` | `0x2000–0xB5FF` | `0x2000–0x37FF` |
| bias | `0xE000` | `0xE000–0xE17F` | `0xE000–0xE0FF` |

权重按当前 FC RTL 的 `[输出组][输入特征][16 个 PE 列]` 排列，不能直接把普通 `[输出][输入]` 矩阵按行送入。CPU 缓冲区由链接脚本放在 `0x80000000` 数据区；DMA 使用 `CPU地址 - 0x80000000 + 0x10000000` 转换后的 DDR AXI 地址。

## 测试数据与参考答案

下标从 0 开始，`k` 为输入编号，`n` 为输出编号：

```text
FC1:
  x[k] = (k & 15) - 8
  W[n][k] = ((k+n) & 7) - 3
  bias[n] = 4*n - 192
  y[n] = clamp(round((sum(x[k]*W[n][k])+bias[n])/16), 0, 127)

FC2:
  x[k] = FC1 实际输出[k]
  W[n][k] = ((k+3*n) & 7) - 3
  bias[n] = 8*n - 256
  y[n] = clamp(round((sum(x[k]*W[n][k])+bias[n])/128), 0, 127)
```

舍入到最近整数，半值远离零。代码保存了独立的完整预期值表，板上无需软件矩阵乘法，也不依赖 RV32M 乘除法扩展。

## 串口与预期打印

日志调用原 Conv 测试同样的 MMIO 打印地址 `0x40000000`，对应 **`dbg_uart_txd`**。连接这个引脚的 USB-UART 接收端，串口工具设为 **115200、8N1**；Loader 的 `uart_rxd/uart_txd` 用于下载程序。

成功时串口将包含：

```text
FC + DMA test start (Conv connected, not started)

[FC1] 400 -> 96, ReLU, SHIFT=4
  BRAM load done
  FC compute done
  Output DMA done
  out[0]=113 expected=113 OK
  ...
FC1 PASS

[FC2] 96 -> 64, ReLU, SHIFT=7
  ...
  out[2]=54 expected=54 OK
  ...
FC2 PASS

FC + DMA TEST PASS
```

超时打印失败阶段与状态寄存器；数值不符打印 `MISMATCH`。超时计数以 MMIO 轮询次数为单位。如果总线访问本身没有响应、CPU 被永久阻塞，软件计数也无法继续。

## 编译与下载

本程序自带 `_start`，沿用仓库的 [linker.ld](linker.ld)，不要和 `conv_dma_test.c`、`dma_test.c` 同时链接。如果已有自己的启动代码，可定义 `FC_TEST_NO_START`，在初始化栈后调用 `fc_dma_test_main()`。

下面是支持 `rv32i_zicsr` 的 GNU RISC-V 工具链命令示例，工具前缀按本机安装替换：

```sh
riscv32-unknown-elf-gcc -std=c11 -march=rv32i_zicsr -mabi=ilp32 -O1 -Wall -Wextra -Werror -ffreestanding -fno-builtin -fno-pic -msmall-data-limit=0 -mno-relax -nostdlib -nostartfiles -Wl,--no-relax,-T,linker.ld,-Map,fc_dma_test.map fc_dma_test.c -o fc_dma_test.elf
riscv32-unknown-elf-objcopy -O binary --only-section=.text fc_dma_test.elf fc_test_imem.raw
riscv32-unknown-elf-objcopy -O binary --only-section=.data fc_dma_test.elf fc_test_dmem.raw
```

`.data` 包含字符串和参考答案，必须与 `.text` 一起下载。所有运行时数组在使用前显式初始化，`.bss` 不需要写入下载文件。程序使用链接脚本的 `__stack_top`，结束后停在循环中。

将两个 raw 文件沿用现有流程封装成 Loader 所需的 PQR5 IMEM/DMEM 文件，再交给 `peqflash.py`；不要把 raw 文件直接作为 `-imembin/-dmembin`。封装格式和转换脚本示例见 [CMP_BUILD_FLASH_EXAMPLE.md](CMP_BUILD_FLASH_EXAMPLE.md) 的第 3 节。

## 本次验证范围

### LLVM 链接出现 `__udivsi3` / `__mulsi3`

早期版本的十进制打印函数使用重复减法循环，LLVM 优化可能把它改写成除法和乘法。RV32I 不含 M 扩展，直接用 `ld.lld` 链接又没有软件算术库，因此出现未定义符号。当前源码已将打印改为固定比较和减法，并禁止该函数内联。

服务器上若仍使用旧版 `fc_test.c`，可先将编译选项 `-O1` 改为 `-O0`，重新生成 `.o` 后再链接。不要只重复链接旧 `.o`，也不要为了消除报错改成当前 CPU 不支持的 `rv32im`。

更新源码后可重新使用 `-O1`；服务器文件名若为 `fc_test.c`，上传时注意重命名。你的 Clang 14 已报告不支持单独命名的 `zicsr`，该工具链使用 `-march=rv32i`。

### 检查记录

- C 源码通过 Clang 严格语法检查（`-Wall -Wextra -Werror`）。
- 从本程序提取实际数据生成函数，在主机运行并独立核对两层全部 160 个参考值和权重布局。
- 使用同一批数据验证 SoC 的 MMIO、FC 和仲裁器通路，两层全部 160 个输出及保护区均通过，Conv 全程空闲；该仿真使用行为级 BRAM，不执行 CPU 裸机程序或 DDR/DMA 搬运。
- 本机现有编译器较旧，未完成 RISC-V ELF 交叉链接；上面的命令为编译示例，尚未上板执行。
