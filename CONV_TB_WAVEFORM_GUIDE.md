# Conv2 testbench 波形查看说明

对应文件：`testbench_conv.sv`。TB 中的注释按 1～20 编号，主测试流程分为 18.1～18.11。

## 1. 这个 TB 测什么

TB 例化 `conv_top dut`，用任务模拟 CPU 配置寄存器，用 `bram[]` 模拟共享 BRAM。它验证独立 Conv2 的输入缓存、权重加载、im2col、PE 计算、跨输入通道累加、bias、量化、ReLU 和结果写回。没有例化 CPU、DMA、DDR 或 Pool。

| 项目 | 本次配置 |
|---|---|
| 输入 | 6 个通道，每个 14×14，INT8 |
| 卷积核 | 5×5，stride=1，无 padding |
| 输出 | 16 个通道，每个 10×10，共 1600 字节 |
| 输入值 | `input_value(ic,y,x)`，范围 -8～8 |
| 权重值 | `weight_value(oc,ic,ky,kx)`，范围 -4～4 |
| bias | 通道0为 -20000，通道1为 20000，其余为 `(oc-8)*37` |
| 量化 | 乘3、右移5位，正数按半数向上舍入 |
| 激活与限幅 | 负数归零，超过127的正数限幅为127 |
| 时钟 | `t=100`，周期100ns，即10MHz |

这两套数据公式是可重复的测试数据生成规则，不是卷积公式，也不保证所有位置的数值互不重复。

对于输出通道 `oc`、输出坐标 `(y,x)`，参考计算是：

```text
sum = bias(oc)
    + Σ input(ic,y+ky,x+kx) × weight(oc,ic,ky,kx)
      ic=0..5，ky=0..4，kx=0..4

sum <= 0：output = 0
sum >  0：output = min(127, (sum*3 + 16) / 32)
```

正数除法丢掉小数部分。这里使用深度学习常见的不翻转卷积核的计算方式。

## 2. 打开正确的波形文件

原来的 FSDB 设置没有改动：

```systemverilog
if (!$value$plusargs("FSDB=%s", dump_file))
    dump_file = "./fsdb/RTL.fsdb";
$fsdbDumpfile(dump_file);
$fsdbDumpvars(0, testbench_conv);
$fsdbDumpMDA();
```

沿用原来的 VCS 编译流程，编译时保留 `+define+DUMP`，运行时保留 `+FSDB=fsdb/RTL.fsdb`。相对路径以运行仿真的工作目录为基准。修改 TB 后需重新编译、运行，再在 Verdi/nWave 打开本次生成的 FSDB。

在波形层级树中选择 `testbench_conv`，展开 `dut` 可看到卷积模块内部信号。例如：

```text
testbench_conv
  ├─ check_done
  ├─ test_pass
  ├─ bram[]
  ├─ golden_sum[]
  ├─ golden_data[]
  └─ dut
      ├─ accum_result
      ├─ quant_data
      └─ u_int32_int8
          ├─ result_q
          ├─ product
          └─ scale
```

如果提示找不到信号，先核对 FSDB 是否来自本次 TB，以及层级是否是 `testbench_conv.dut`。不要把 `conv_top` 模块名直接当作实例路径。数组查看需要本次波形包含 `$fsdbDumpMDA()` 的记录。

建议把单比特控制信号设为 Binary，地址和32位拼接字设为 Hex，计数器设为 Unsigned Decimal。像素、权重、`accum_result`、`product`、`scale` 设为 Signed Decimal。尤其 `accum_result` 的连线声明没有 signed，需要手动按有符号数显示，否则负数会显示成很大的正数。

## 3. 第一眼先看是否通过

在 `testbench_conv` 下添加这些信号，把时间轴移到仿真末尾：

| 信号 | 正常结束值 | 含义 |
|---|---:|---|
| `check_done` | 1 | 最终比较已执行完 |
| `test_pass` | 1 | 所有检查通过 |
| `timed_out` | 0 | 没有触发超时 |
| `accum_count` | 1600 | 收到1600个加bias后的INT32结果 |
| `accum_errors` | 0 | INT32结果与参考值一致 |
| `write_count` | 400 | 写回400个32位字 |
| `write_errors` | 0 | 写地址依次递增，strb正确 |
| `data_errors` | 0 | 最终1600个输出字节都正确 |
| `first_bad_index` | -1 | 没有最终字节不匹配；请按Signed Decimal显示 |

`test_pass` 在运行过程中一直为0，只有 `check_done=1` 时才用它判断成功与否。`dut.done` 是硬件的完成信号，不能代替正确性检查。`data_errors` 在最后扫描BRAM时才更新，运行中为0并不代表已经验证完。

当前数据的参考覆盖计数为：

| 信号 | 值 | 含义 |
|---|---:|---|
| `negative_count` | 750 | 加bias后小于0的结果数量 |
| `normal_count` | 733 | 量化后为1～126的结果数量 |
| `saturated_count` | 100 | 量化后超过127、需要限幅的数量 |

这些计数在时间0由参考模型生成，不会随硬件运行逐个增加。三项不是全部结果的穷尽分类，例如正数量化成0就不在这三类中。当前版本已在本地 ModelSim 跑通上述检查；仿真约在407.6µs结束。定位时优先看信号，不依赖固定时间。

## 4. 看整个运行过程

在 `testbench_conv` 下添加 `clk`、`rst_n`、`conv_busy`；在 `testbench_conv.dut` 下添加：

```text
start
done
error
channel_cnt
weight_addr_begin
input_addr_begin
input_cache_loaded_done
im2col_start
channel_done
bias_addr_begin
bias_loaded_done
```

正常过程为：

1. `rst_n=0` 保持4个周期，然后释放。
2. TB 写输入尺寸、通道数、bias地址、量化参数、输入地址、权重地址，最后启动。
3. `channel_cnt` 依次为0～5，每轮加载该输入通道的权重和图像，再启动im2col。
4. 每一轮所有有效PE结果写入累加RAM后，`channel_done` 发出脉冲。它表示一个输入通道完成，不是整层卷积完成。
5. 六轮完成后读取bias，`bias_loaded_done` 表示bias已经接收完。
6. 逐个输出加bias的INT32结果，量化后写回BRAM，最终 `dut.done` 有效。
7. TB 再等待5个下降沿，检查最终BRAM，拉高 `check_done`，通过时同时拉高 `test_pass`。

寄存器请求可在TB根层看 `conv_req_valid`、`conv_req_ready`、`conv_addr`、`conv_wdata`。只有valid与ready同时为1的上升沿才算请求被接收，不要把每一拍valid高都算作一次配置。

## 5. 检查 ReLU、量化和限幅

先添加下面四个信号：

```text
testbench_conv.dut.accum_result_valid
testbench_conv.dut.accum_result
testbench_conv.dut.quant_valid
testbench_conv.dut.quant_data
```

需要看中间步骤时，展开 `testbench_conv.dut.u_int32_int8` 添加：

```text
result_q    valid_d1
product     valid_d2
scale       valid_d3
data_o      data_valid_o
```

`data_o/data_valid_o` 就是顶层 `quant_data/quant_valid` 所连接的信号。数据必须配合对应valid看，valid为0时寄存器可能保留上一次数据。

同一个数据经过四级流水线，按上升沿更新后的值看：

| 上升沿 | 本次数据所在位置 |
|---|---|
| E0：输入valid被采样 | `result_q`更新，`valid_d1=1` |
| E1 | `product=result_q*3`，`valid_d2=1` |
| E2 | `scale`更新，`valid_d3=1` |
| E3 | `data_o`更新，`data_valid_o=1` |

因此不要直接把同一时刻的 `accum_result` 与 `quant_data` 当作同一个像素。连续输入时，不同级同时处理不同的像素。

本次数据有几个可以明确对照的例子：

| 输出索引 | 通道/行/列 | `accum_result` | `product` | `scale` | 最终INT8 |
|---:|---|---:|---:|---:|---:|
| 0 | 0/0/0 | -20071 | -60213 | -1882 | 0 |
| 100 | 1/0/0 | 20280 | 60840 | 1901 | 127 |
| 801 | 8/0/1 | 67 | 201 | 6 | 6 |
| 802 | 8/0/2 | 151 | 453 | 14 | 14 |

索引0验证负数经过ReLU变成0；索引100验证大正数被限幅；索引801和802验证正常正数保留。负乘积使用算术右移，此处不加舍入偏置，之后ReLU归零。

整个通道0的100个输出都应为0，通道1的100个输出都应为127。不过仍需看 `accum_errors=0`，因为错误的负累加值也可能经ReLU得到0，仅看最终0无法证明卷积正确。

## 6. 看输出写回BRAM

在TB根层添加：

```text
acc_wr_en
acc_wr_addr
acc_wr_data
acc_wr_strb
write_count
```

每个 `acc_wr_en=1` 的上升沿完成一次写入：

- 地址是字地址，应为0、1、2……399，总计400次。
- `acc_wr_strb` 应为 `4'b1111`。
- `acc_wr_data` 每个字包含4个连续INT8输出。
- 最早的字节在 `[7:0]`，之后依次是 `[15:8]`、`[23:16]`、`[31:24]`。

输出字地址 `a` 对应 `golden_data[4*a]` 到 `golden_data[4*a+3]`：

```text
acc_wr_data = {golden_data[4*a+3], golden_data[4*a+2],
               golden_data[4*a+1], golden_data[4*a]}
```

完成后可直接展开BRAM数组观察：

| BRAM字地址 | 正确内容 |
|---|---|
| `bram[0]`～`bram[24]` | 全部为 `32'h00000000`，输出通道0 |
| `bram[25]`～`bram[49]` | 全部为 `32'h7F7F7F7F`，输出通道1 |
| `bram[200]` | `32'h000E0600`，通道8开头四字节为0、6、14、0 |

初始化时输出区域是 `32'hEEEEEEEE`，未被正确写入的字节会被最终检查发现。写使能无效时，总线上残留的数据无需与参考值比较。

## 7. 出错后按什么顺序看

### `timed_out=1`、`check_done=0`

检查 `rst_n` 是否释放、寄存器握手是否完成、`dut.start` 是否出现。然后看 `channel_cnt` 停在几，当前是在读权重、读输入、等待PE结果还是等待bias。超时上限为12000个上升沿，约1.2ms。

### `accum_errors>0`

错误已经出现在量化前。定位 `accum_errors` 首次增加的上升沿，对照 `dut.accum_result` 和对应的 `golden_sum[index]`。

检查器使用上升沿前的 `accum_count` 作为索引，该沿之后计数器会加1。例如计数从801变为802时，刚检查的是索引801。注意波形游标显示的是沿前值还是更新后的值。

再向前追踪 `dut.pe_result[]`/`pe_result_valid`、`channel_cnt`、权重加载和输入窗口。不要先修改参考答案来适配错误输出。

### `accum_errors=0`，但 `data_errors>0`

先看 `first_bad_index`、`first_actual`、`first_expected`。这些只记录最终BRAM字节的第一个错误，不记录第一个INT32累加错误。

```text
oc = first_bad_index / 100
y  = (first_bad_index % 100) / 10
x  = first_bad_index % 10
BRAM字地址 = first_bad_index / 4
字内字节编号 = first_bad_index % 4
```

若量化前正确、`quant_data`错误，检查量化流水线的signed、乘数、shift、舍入和valid对齐。若 `quant_data`正确而最终BRAM错误，检查 `output_cache` 拼接顺序、写地址、strb和使能。

### `write_errors>0` 或 `write_count!=400`

查看 `acc_wr_en` 有效的上升沿，确认地址是否跳过、重复、越界，strb是否为1111。`write_count` 统计实际发生的写事务，即使地址重复也会增加，因此不能只看次数。

### `test_pass=0`，但各错误数均为0

先确认 `check_done=1`，再检查 `accum_count==1600`、`write_count==400`、`dut.error==0`、`timed_out==0`，以及三类覆盖计数均大于0。收到的数据不足也会使测试失败，即使已收到的部分全部正确。

## 8. BRAM布局与signed显示速查

| 区域 | 字节起始地址 | BRAM字索引 | 长度 |
|---|---|---|---|
| 输出 | `0x0000` | `0x0000` | 1600字节 |
| bias | `0x4000` | `0x1000` | 16个INT32，64字节 |
| 输入 | `0x5000` | `0x1400` | 1176字节 |
| 权重 | `0x7000` | `0x1C00` | 2400字节 |

输入按 `[ic][y][x]` 连续存放；权重按 `[ic][ky][kx][oc]` 连续存放，每个核位置包含16个输出通道权重。bias基地址参数本身是字地址，输入和权重基地址参数是字节地址。

INT8负数在BRAM里以补码存储，例如 `8'hF8=-8`、`8'hFC=-4`。把整个32位拼接字显示为Signed Decimal不能看到四个独立像素；查看对应的8位切片，或在 `dut.pixel_data`、`dut.weight_vec[]` 上按Signed Decimal看。

本TB主要覆盖当前这组有符号Conv2数据。`test_pass=1`说明这次用例通过，不代表所有输入范围、所有量化参数、连续多次启动或整个SoC都已经验证。
