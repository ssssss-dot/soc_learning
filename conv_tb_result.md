# Conv 模块准确性验证说明

本文依据 `testbench_conv.sv` 编写，与本次提供的 TB 附件一致。下文数值是参考模型的预期结果，不是已经取得的 RTL 仿真通过记录。本次未运行 RTL 仿真，仅检查代码并用独立脚本复算了参考公式。

## 1. 这个 TB 验证什么

被测对象为 `testbench_conv.dut`，即 `conv_top`，包含配置、地址生成、输入/权重缓存、im2col、PE 阵列、跨输入通道累加、bias、量化和输出打包。

TB 直接模拟 CPU 写配置，用行为级 BRAM 提供输入和接收输出，没有例化 CPU、DMA、DDR，也不执行 C 程序。因此可以绕开 CPU 前递和 C 程序 expected 计算路径，独立判断当前 Conv2 用例的卷积结果是否正确。

本次固定配置如下：

| 项目 | 配置 |
| --- | --- |
| 输入 | 6 通道，每通道 14×14，共 1176 个有符号 INT8 |
| 卷积核 | 16 个输出通道，每个覆盖 6×5×5，共 2400 个有符号 INT8 权重 |
| 步长 / padding | 1 / 0，核不翻转 |
| bias | 每个输出通道一个 INT32，共 16 个 |
| 输出 | 16×10×10，共 1600 字节 |
| 量化 | 乘 3，舍入后右移 5 位，ReLU，限幅至 127 |
| 时钟 | `t=100ns`，周期 100ns，即 10MHz |

注意：这里的“准确性”指固定点硬件输出与整数参考模型逐项一致，不是 MNIST 分类准确率，也不代表 FPGA 的 100MHz 时序已经通过。

## 2. 测试流程

```text
复位、初始化行为级 BRAM
  → 填入输入、权重和 bias，输出区预填 0xEE
  → 独立生成 golden_sum 和 golden_data
  → 通过 MMIO 请求/响应握手写配置并启动
  → 运行期间检查累加结果和 BRAM 写事务
  → 等待 dut.done，再等 5 个周期
  → 比较 BRAM 中全部 1600 个输出字节
  → 汇总 check_done / test_pass，再等 5 个周期结束
```

初始化和参考计算中的普通 `for` 循环没有时钟等待，在仿真时间 0 完成，不是每个循环执行一个硬件周期。复位保持到第 4 个下降沿，随后释放。

`write_reg` 在下降沿设置请求，等待请求握手，再等待并接收响应后，才进行下一次寄存器写入。配置顺序是：输入尺寸、通道数、bias 地址、量化乘数、量化移位、输入地址、权重地址、CONTROL=1。

`CONTROL=1` 只启动，本用例没有使能中断，也不以 `conv_irq` 作为成功条件。TB 等待的是内部 `dut.done`，没有通过 MMIO 读取状态寄存器。

## 3. BRAM 地址和数据排列

BRAM 为 `bram[0:16383]`，每项 32 位，共 64KiB。外部 `acc_rd_addr/acc_wr_addr` 是字地址，而输入和权重配置使用字节地址。

| 内容 | 字节地址范围（含末地址） | BRAM 字地址范围 | 排列 |
| --- | --- | --- | --- |
| 输出 | `0x0000`～`0x063F` | 0～399 | `[oc][y][x]` |
| bias | `0x4000`～`0x403F` | `0x1000`～`0x100F` | 每通道一个完整 32 位字 |
| 输入 | `0x5000`～`0x5497` | `0x1400`～`0x1525` | `[ic][y][x]` |
| 权重 | `0x7000`～`0x795F` | `0x1C00`～`0x1E57` | `[ic][ky][kx][oc]` |

具体地址公式：

```text
输入字节地址 = 0x5000 + ic*196 + y*14 + x
权重字节地址 = 0x7000 + ic*400 + (ky*5+kx)*16 + oc
bias 字地址  = 0x1000 + oc
输出字节索引 = oc*100 + y*10 + x
```

权重不是直接按 `[oc][ic][ky][kx]` 存放；同一个核位置的 16 个输出通道权重连续排列，以匹配 weight_cache。

INT8 按小端字节顺序放入 BRAM：

```text
字节索引 i → bram[i/4][(i%4)*8 +: 8]
一个字的 [7:0]、[15:8]、[23:16]、[31:24] 对应连续四个低到高地址
```

例如输入 -8 保存为 `8'hF8`，计算时必须按有符号 INT8 解释。输出区预填 `0xEE`，这样未写入的字节不会碰巧被当成正确的 ReLU 零值。

## 4. expected / golden 是怎么得到的

### 4.1 测试数据

TB 使用确定的公式生成数据，不依赖随机种子：

```text
input(ic,y,x) = (ic*7 + y*3 + x*5 + y*x) % 17 - 8
weight(oc,ic,ky,kx) = (oc*3 + ic*5 + ky*7 + kx*2 + oc*kx + ic*ky) % 9 - 4

bias(0) = -20000
bias(1) =  20000
bias(oc) = (oc-8)*37，oc=2～15
```

输入范围为 -8～8，权重范围为 -4～4。ch0 的大负 bias 保证输出归零，ch1 的大正 bias 保证输出限幅，其他通道提供变化的正常结果。

### 4.2 量化前参考值 golden_sum

对每个输出 `(oc,y,x)`，执行独立的直接卷积：

```text
sum = bias(oc)
for ic = 0..5
    for ky = 0..4
        for kx = 0..4
            sum += input(ic,y+ky,x+kx) * weight(oc,ic,ky,kx)

golden_sum[oc*100+y*10+x] = sum
```

每个输出累计 150 个乘积，bias 只加一次。参考值来自数学坐标计算，不读取 DUT 的 PE 结果、缓存内容或累加结果作为答案。

这一组数据的单个乘积绝对值不超过 32，150 项绝对值之和不超过 4800，加 bias 后也远小于 INT32 范围，参考计算不会发生 INT32 溢出。

### 4.3 最终参考值 golden_data

```text
sum <= 0：输出 0
sum > 0 ：scaled = floor((sum*3 + 16) / 32)
          输出 min(scaled, 127)
```

`+16` 是除以 32 前加半个除数，对正数做半数向上舍入。例如 `sum=42`：

```text
42*3 = 126
(126+16)/32 = 4（整数除法）
最终输出 = 4
```

这里不能只做 `126 >> 5`，否则得到 3，少了舍入。TB 参考式中的 16 和 32 是写死的；修改 `QUANT_SHIFT` 时必须同步修改参考式，不能只改配置参数。

### 4.4 可以在波形中直接核对的样本

下表由独立脚本复算 TB 公式得到；累加值请使用有符号十进制显示。

| index | `(oc,y,x)` | golden_sum | golden_data（十进制） |
| --- | --- | ---: | ---: |
| 0 | (0,0,0) | -20071 | 0 |
| 1 | (0,0,1) | -19733 | 0 |
| 100 | (1,0,0) | 20280 | 127 |
| 400 | (4,0,0) | 42 | 4 |
| 700 | (7,0,0) | 36 | 3 |
| 800 | (8,0,0) | -17 | 0 |
| 801 | (8,0,1) | 67 | 6 |
| 802 | (8,0,2) | 151 | 14 |
| 803 | (8,0,3) | -3 | 0 |
| 1599 | (15,9,9) | 135 | 13 |

因此最终 `bram[200]` 对应索引 800～803，应为 `32'h000E_0600`。还可以检查：`bram[0:24]` 全部为零，`bram[25:49]` 全部为 `32'h7F7F_7F7F`。

当前数据的参考覆盖计数应为：

| 信号 | 预期值 | 定义 |
| --- | ---: | --- |
| negative_count | 750 | `sum < 0` 的输出数 |
| normal_count | 733 | 正数路径量化后为 1～126 的输出数 |
| saturated_count | 100 | 正数路径量化后超过 127 的输出数 |

三个计数不是完整分类，总和不必是 1600：例如 `sum=0`、正数舍入成 0、量化值恰好为 127 都不属于这三个类别的全部覆盖范围。它们来自参考模型，不是对硬件实际输出的计数。当前最终参考输出为零的字节共 767 个。

## 5. 三层检查为什么都需要

### 第一层：量化前逐项比较

在每个上升沿，若 `dut.accum_result_valid=1`，比较：

```text
dut.accum_result 与 golden_sum[accum_count]
```

比较后 `accum_count` 加一，不是每个时钟都加一。应收到恰好 1600 个结果，并且 `accum_errors=0`。顺序必须是先 x、再 y、最后 oc。

这一步很重要：两个不同的负数都可能被 ReLU 变成 0，两个不同的大正数都可能限幅成 127。只检查最终 INT8，可能漏掉卷积和 bias 的错误；检查 golden_sum 能发现这类被量化掩盖的错误。

### 第二层：BRAM 写事务检查

只有在上升沿 `acc_wr_en=1` 时，检查当前写地址和字节使能：

```text
第 0～399 次写入的 acc_wr_addr 应依次为 0～399
每次 acc_wr_strb 都应为 4'b1111
```

最终应为 `write_count=400`、`write_errors=0`。本用例 1600 字节能被 4 整除，不涉及最后一个不足四字节的写入。

`acc_wr_en=0` 时，打包过程中的 strb 可能为 0001、0011 或 0111，这不是错误。也不能用完成后保持的地址判断最后一次写地址：output_cache 在最后一次有效写后会把地址归零，应看写入采样沿。

### 第三层：最终 BRAM 逐字节比较

等待 `dut.done` 后再等 5 个下降沿，比较所有 1600 字节与 `golden_data`，累计 `data_errors`。

若发现错误，保存第一个错误的：

- `first_bad_index`：展平索引。
- `first_actual`：BRAM 实际字节。
- `first_expected`：参考字节。

无最终字节错误时，`first_bad_index=-1`；此时 first_actual/first_expected 保持初始化值，不代表额外的有效样本。比较使用 `!==`，数据中的 X/Z 也会被判为不匹配。

## 6. 怎么运行和看结果

### 6.1 仿真工程设置

1. 把仓库根目录设为 include 搜索路径，使工具能找到 `define.sv`。
2. 添加 `testbench_conv.sv`、`coprocessor/conv/` 下全部 `.sv`，以及 `coprocessor/pe_ws.sv`，按 SystemVerilog 编译。
3. 仿真顶层选择 `testbench_conv`，不是 `conv_top`，不要同时启用其他 TB 顶层。
4. 在运行前记录下面列出的信号；观察 BRAM/golden 数组时，确认仿真工具保留并记录这些数组。
5. 运行到 `$finish`，不是只运行 GUI 默认的一小段时间。

本地未检测到可用的 Icarus、Verilator、VCS 或 XSim，本次没有执行编译和 RTL 仿真。以上为使用现有仿真工程的设置说明。

### 6.2 波形记录

TB 没有 `$display`，正常情况下终端不会打印 PASS。进程正常退出、看到 `$finish` 或看到 done，都不能单独证明通过。

若使用支持 FSDB 的仿真环境：编译时定义 `DUMP`，并按环境配置 FSDB/Verdi 支持；运行时用 `+FSDB=路径` 指定文件。默认路径为 `./fsdb/RTL.fsdb`，需事先创建目录。`$fsdbDumpMDA()` 用于记录数组。

若环境不支持 FSDB，不定义 `DUMP`，使用仿真器自身的波形记录功能。本 TB 不会自动生成 VCD。

建议至少观察：

```text
testbench_conv.check_done / test_pass / timed_out
testbench_conv.accum_count / accum_errors
testbench_conv.write_count / write_errors / data_errors
testbench_conv.first_bad_index / first_actual / first_expected
testbench_conv.negative_count / normal_count / saturated_count
testbench_conv.conv_busy
testbench_conv.dut.done / error
testbench_conv.dut.accum_result_valid / accum_result
testbench_conv.dut.quant_valid / quant_data
testbench_conv.acc_wr_en / acc_wr_addr / acc_wr_strb / acc_wr_data
```

需要定位单个输出时，再加 `golden_sum`、`golden_data`、`bram` 对应元素及内部模块信号。累加结果和 golden_sum 用有符号十进制，地址用十六进制或无符号十进制，字节用十六进制方便核对。

### 6.3 最终通过条件

在检查完成后的稳定时刻（最后几个周期）查看，不要在时间 0 或仿真尚未结束时把初始 `test_pass=0` 当成失败。

| 信号 | 必须满足 |
| --- | --- |
| check_done | 1 |
| test_pass | 1，不能是 X |
| timed_out | 0 |
| accum_count / accum_errors | 1600 / 0 |
| write_count / write_errors | 400 / 0 |
| data_errors | 0 |
| first_bad_index | -1 |
| dut.error | 明确为 0 |
| 三个覆盖计数 | 都大于 0；当前固定数据应等于上表数值 |

TB 中 `test_pass` 包含结果数、错误数、覆盖条件和内部 error 状态，但没有独立检查 IRQ、MMIO 状态读回或最终 busy。done 是等待条件，可能是脉冲，不要求仿真最后一拍仍为 1。

超时保护在第 12000 个上升沿触发，当前时钟下约为 1.2ms，计时从仿真开始算，包含复位、配置和结束观察阶段。必须同时确认 `timed_out=0`；超时进程本身只置 timed_out 并结束仿真，不会执行最终数据检查。

## 7. 失败后怎么定位

| 现象 | 优先检查 |
| --- | --- |
| timed_out=1，尚未 check_done | MMIO 请求/响应是否完成、是否产生 start、控制状态机卡在哪里、BRAM 读返回、各阶段 done |
| accum_count 少于/多于 1600 | 是否漏 valid、重复 valid、输出遍历提前结束或未停止 |
| accum_errors>0 | 输入/权重地址排列、INT8 符号扩展、im2col 窗口、PE 数据对齐、6 通道累加、bias 是否只加一次 |
| accum_errors=0，但 data_errors>0 | 量化乘法/舍入/移位、量化 valid 对齐、四字节打包顺序和最终写回 |
| write_errors>0 或 write_count!=400 | 写地址递增、输出打包、strb、重复写/漏写和结束判断 |
| 累加有错但最终字节全对 | 错误可能被 ReLU、舍入或饱和掩盖；仍然是 FAIL |
| dut.error=1 | 查看配置是否合法和控制器报错条件，不能只看输出数据 |

以上是排查方向，不是仅凭一个计数就能定案。

### 7.1 用 first_bad_index 找到出错位置

```text
oc = first_bad_index / 100
y  = (first_bad_index % 100) / 10
x  = first_bad_index % 10
BRAM 字地址 = first_bad_index / 4
字节 lane   = first_bad_index % 4
```

例如 `first_bad_index=801`，就是输出 `(oc=8,y=0,x=1)`，对应 `bram[200][15:8]`，预期值 6，量化前应为 67。

1. 找到 `accum_result_valid=1` 且采样前 `accum_count=801` 的上升沿，检查 accum_result 是否为 67。
2. 若已错误，向前追踪 accumulation、PE、输入和权重；若正确，再追踪量化。
3. 量化是四级寄存流水线。若第一级在上升沿 N 接收该结果，quant_data/quant_valid 在 N+3 上升沿之后更新，output_cache 在 N+4 上升沿采样它；不要拿同一拍的 accum_result 与 quant_data 直接一一比较。
4. 确认量化值 6 被放到正确 lane，最终写 `acc_wr_addr=200` 时完整字应为 `32'h000E_0600`。

TB 只保存“最终字节”的首个错误，没有保存“量化前结果”的首个错误索引。定位累加错误时，要在波形中找 accum_errors 第一次增加的采样沿，用更新前的 accum_count 定位；NBA 更新后的计数已经加了 1。

## 8. PASS 能说明什么，不能说明什么

全部通过说明：本次固定 Conv2 配置下，1600 个量化前结果、写地址/strb/写入数量以及最终 1600 个字节都与参考模型一致。

尚未覆盖的内容包括：

- Conv1 的 1×32×32 → 6×28×28 配置，以及其他尺寸/通道组合。
- 换一组输入/权重、极值 INT8、累加器边界、其他量化参数和专门的舍入边界用例。
- 连续启动两次、忙时配置、运行中复位、非法配置和中断/状态寄存器完整行为。
- MMIO 不同背压时序、BRAM 可变读延迟以及其他存储接口约束。
- CPU、DMA、DDR、cache、软件数据布局和真正上板后的系统级路径。
- FPGA 综合实现的资源、时序收敛和实际运行频率。

本 TB 的 BRAM 是固定同步读延迟、写优先模型；读写同时请求时只执行写。它不模拟任意读延迟或完整总线系统。数据比较能识别 X/Z，但控制信号没有全面的未知值断言，不能把当前 TB 当成完整协议验证。

若这个 TB PASS 而 SoC 的 C 测试仍 FAIL，应继续核对 SoC 测试是否使用相同配置和数据，以及 CPU expected、数据搬运、cache 和寄存器配置，而不是直接认定 Conv 模块在所有情况下都正确。

## 9. 实际仿真记录（运行后填写）

| 项目 | 实测记录 |
| --- | --- |
| 仿真工具 / 版本 | 待填写 |
| RTL / TB 版本 | 待填写 |
| check_done / test_pass / timed_out | 待填写 |
| accum_count / accum_errors | 待填写 |
| write_count / write_errors / data_errors | 待填写 |
| first_bad_index / first_actual / first_expected | 待填写 |
| dut.error | 待填写 |
| 三个覆盖计数 | 待填写 |
| 结论 / 波形文件位置 | 待填写 |
