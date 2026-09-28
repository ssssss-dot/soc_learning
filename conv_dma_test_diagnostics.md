# Conv1 expected 少 1：诊断测试

`conv_dma_test.c` 基于上传的 Conv1/Conv2 + DMA 裸机测试，保留输入、权重、bias、MMIO 地址、DMA 搬运顺序和原 expected 公式。使用原来的 RV32I/Zicsr 编译、链接和下载流程，入口仍为 `_start`，栈顶仍为 `0x80020000`。上板时不要定义 `CONV_DIAG_HOST_TEST`；这个宏仅用于主机测试。

## 新增检查

1. **PRE-DMA EXPECTED SELFTEST**：DMA 启动前，运行 12 组运行时读取的固定坐标，涵盖 `x<y` 的无符号回绕、换通道和最后一行。正确答案是字面常数，不依赖待检查公式。失败后仍继续 Conv1/Conv2，以收集更多信息；最终总 PASS 要求自检也通过。
2. **Conv1 全量校验**：逐个检查全部 4704 字节，同时比较实际值、原 expected 和独立正确值表。表内已经包含通道 bias，避免再次用同一条 `+channel` 计算正确值。
3. **延后打印**：循环内只保存各通道首像素及前 8 个错误点，全部扫描结束后再重算、打印。诊断输出均为十六进制，减少对原十进制打印算法的依赖。

## 先看计数

| 字段 | 意义 |
| --- | --- |
| `checked` | 应为 `0x1260`，即 4704 个像素 |
| `compare_errors` | `actual != original` 的个数 |
| `expected_errors` | 原 expected 与正确值表不符的个数 |
| `output_errors` | CPU 读到的 actual 与正确值表不符的个数 |
| `sum_errors` | actual 或 original 通道校验和与固定正确校验和不符的通道数 |

如果 `expected_errors != 0`、`output_errors == 0`，说明在这次扫描中实际输出匹配表，而原 expected 路径出错。

如果逐字节计数都是零，仅 `sum_errors != 0`，优先检查 checksum 累加及其变量读写，不要把 checksum 错误误认为每个像素的 expected 都错。

## 每条记录

- `idx/c/y/x`：发生比较时的输出下标、通道、行、列。
- `actual/original/gold`：当时读到的输出、原 expected 和正确值表结果。
- `actual_again`：扫描结束后重新读取同一输出地址。它仍经过 CPU 访存路径，不是绕过 Cache 的 DDR 真值。
- `replay: diff/phase/base/split`：扫描结束后根据记录的坐标重新计算 `x-y`、`&3`、`+36`、`+channel`，每步通过 volatile 字段保存。
- `add_form`：重算 `36 + ((x+y+(y<<1))&3) + channel`。
- `retry`：再次调用原 expected 公式。
- `tight`：明确指定的连续 `sub → andi → addi → add` RV32I 指令结果。
- `spaced`：相同算术指令之间各插入 4 个 NOP 后的结果。

PRE-DMA 自检没有 DMA 输出；它的 `actual` 字段表示正确值表读取结果，`gold` 是固定用例里的字面答案。

`replay` 是事后重算，不是原出错指令的真实中间值。`split` 额外经过存储/加载，所以它和连续寄存器计算不同，可以提供访存相关线索。

## 如何判断

| 现象 | 下一步排查 |
| --- | --- |
| PRE-DMA 也失败 | DMA 尚未运行，不能归因于本次 DMA 写回一致性；检查 CPU 指令、普通访存及打印路径 |
| `tight` 错而 `spaced` 对 | 优先看数据前递、指令依赖和暂停恢复；还需反汇编/波形确认 |
| `original` 错，`retry/tight/spaced` 对 | 原循环特有的寄存器依赖、变量更新、栈访问或暂停时序 |
| `actual` 对、`original` 少 1，记录的通道/坐标也错误 | 先检查循环变量更新；表查找也依赖坐标，因此还要人工核对 idx 对应的位置 |
| `actual` 错，expected 各版本正确 | 优先检查数据路径、输出布局、DMA 和 Cache 读回 |
| `actual` 与 `actual_again` 不同 | 没有再次启动 DMA 时数据读取仍变化，检查访存、地址、记录缓冲及是否存在其他写入 |

通道 0 前四行的正确值周期为：

```text
y=0: 36 37 38 39 ...
y=1: 39 36 37 38 ...
y=2: 38 39 36 37 ...
y=3: 37 38 39 36 ...
```

其他通道在此基础上加通道号。各通道正确校验和为 `29400, 30184, 30968, 31752, 32536, 33320`。

保存完整的 `PRE-DMA`、`Conv1 DIAG`、`CHANNEL FIRST PIXEL` 和 `MISMATCH` 日志用于定位。新增诊断会改变代码布局、寄存器分配及 Cache 状态；如果本版不再复现，不能据此认定 RTL 问题已经修复。正确值表和诊断记录仍由被测 CPU 读取，最终定因需要比对上板程序的反汇编与波形。
