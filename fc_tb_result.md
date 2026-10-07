# FC 简单波形测试

## 1. 测试范围和运行结果

测试文件为 `testbench_fc.sv`，顶层为 `testbench_fc`，被测实例为 `dut`。
直接例化当前 `fc_top`，通过 MMIO 配置，使用一拍读延迟、写优先的行为级 BRAM。
不例化 CPU/DMA/DDR，不读取训练文件，不使用随机数，也不打印测试日志。
只增加 TB 和本说明，没有修改 FC RTL。

固定 4 个输入、18 个输出，因此有两组 PE：第一组16个输出，第二组2个输出。
连续执行三个任务，中间不复位 DUT，分别观察普通点积、ReLU、量化舍入和限幅。

2026-10-07 使用 Icarus Verilog 的实际检查结果：

- TB 和当前 FC RTL 编译成功；没有启用 FSDB，未验证 VCS/Verdi 的波形插件环境。
- 三次任务写回的18个字节均与下面的手算结果一致，写地址和字节使能也一致。
- 发现现有 RTL 在最后一个不足16路的组结束后，还额外输出14个内部累加结果。
- 因此严格检查结果为 `case_pass=3'b000`、`test_pass=0`，不能称为全部通过。具体原因见第7节。

## 2. BRAM 布局

| 内容 | 字节地址 | BRAM字地址 | 大小 |
|---|---|---|---|
| 输出 | `0x0000` | `0x0000` | 18 B |
| 输入 | `0x1000` | `0x0400` | 4 B |
| 权重 | `0x2000` | `0x0800` | 2×4×16 = 128 B |
| bias | `0x3000` | `0x0C00` | 18×4 = 72 B |

FC 的三个基地址寄存器全部写入**字节地址**，bias 也不例外。
BRAM 读写接口地址则是**32位字地址**。低地址字节位于一个字的 `[7:0]`。
当前 FC 没有可配置输出基地址，本 TB 按 RTL 固定从字节地址0写回。

权重排列为 `[输出组][输入特征][PE列]`，初始化地址公式：

```text
byte_addr = WEIGHT_BASE + (g*4+k)*16 + lane
oc = g*16 + lane
```

`oc>=18` 的权重补零；bias不补齐，第二组只读两个bias。
输出区域预填 `EE`，最后一个字的高两个字节应始终为 `EEEE`，以检查越界写回。

## 3. 三次测试及手算答案

下文 `n` 是全层输出编号0～17，`k` 是输入编号0～3。
所有测试的 bias 都是 `b[n]=n-9`。
参考值在 TB 中直接通过 `b[n]+sum(x[k]*W[n][k])` 计算，未使用 DUT 的计算结果。

### 测试1：正负点积，不启用ReLU

```text
case_id = 1
x = [1, 2, 3, 4]
W[n][k] = n+k-8
b[n] = n-9
MULT=1，SHIFT=0，RELU=0，CONTROL=3（启动+中断）
```

因为 `sum(x)=10`、`sum(k*x[k])=20`：

```text
golden_sum[n] = 10*(n-8)+20+(n-9) = 11*n-69
```

例如输出0：`1*(-8)+2*(-7)+3*(-6)+4*(-5)-9=-69`。
例如输出17：`1*9+2*10+3*11+4*12+8=118`。
本次没有缩放、ReLU或饱和，最终输出与加bias后的累加结果相同：

```text
[-69, -58, -47, -36, -25, -14, -3, 8, 19,
  30,  41,  52,  63,  74,  85, 96, 107, 118]
```

### 测试2：更换输入和权重，启用ReLU

```text
case_id = 2
x = [4, -3, 2, -1]
W[n][k] = 8-n-2*k
b[n] = n-9
MULT=1，SHIFT=0，RELU=1，CONTROL=7
```

因为 `sum(x)=2`、`sum(k*x[k])=-2`：

```text
golden_sum[n] = 2*(8-n)-2*(-2)+(n-9) = 11-n
golden_data[n] = max(0, 11-n)
```

例如输出0：`4*8+(-3)*6+2*4+(-1)*2-9=11`。
输出17量化前为 `-6`，ReLU之后应为0。

```text
量化前：[11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0, -1, -2, -3, -4, -5, -6]
最终值：[11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0,  0,  0,  0,  0,  0,  0]
```

### 测试3：同测试1的数据，观察量化

```text
case_id = 3
x、W、bias与测试1相同
MULT=3，SHIFT=1，RELU=0，CONTROL=3
```

先求 `S=11*n-69`，再求 `S*3/2` 的最近整数，恰好半整数时远离0，最后限幅到 `[-128,127]`。

```text
S=-69：-69*3/2=-103.5 → -104
S= -3： -3*3/2=  -4.5 →   -5
S= 19： 19*3/2=  28.5 →   29
S= 85： 85*3/2= 127.5 → 128 → 限幅为127
```

最终输出：

```text
[-104, -87, -71, -54, -38, -21, -5, 12, 29,
   45,  62,  78,  95, 111, 127, 127, 127, 127]
```

## 4. 最直接的BRAM波形核对

在每次 `fc_done` 后查看 `bram[0]`～`bram[4]`，设置为十六进制：

| BRAM字地址 | 测试1 | 测试2 | 测试3 |
|---|---|---|---|
| 0 | `DCD1C6BB` | `08090A0B` | `CAB9A998` |
| 1 | `08FDF2E7` | `04050607` | `0CFBEBDA` |
| 2 | `34291E13` | `00010203` | `4E3E2D1D` |
| 3 | `60554A3F` | `00000000` | `7F7F6F5F` |
| 4 | `EEEE766B` | `EEEE0000` | `EEEE7F7F` |

不要把十六进制显示顺序当成神经元顺序：每个字先取低8位，再依次取高位。
例如测试1的 `bram[0]=DCD1C6BB` 对应 `[-69,-58,-47,-36]`。

当前 RTL 是**一个输出字节一次写入**，每次任务应有18次写请求，而不是5次：

```text
acc_fc_wr_addr：0,0,0,0,1,1,1,1,...,4,4
acc_fc_wr_strb：1,2,4,8,1,2,4,8,...,1,2
```

## 5. 推荐加入波形的信号

所有相对路径的根都是 `testbench_fc`。

| 信号 | 怎么看 |
|---|---|
| `case_id` | 1、2、3区分三次任务 |
| `golden_sum[n]` / `actual_sum[n]` | 有符号十进制，比较加bias后的INT32；actual在有效结果到来时更新 |
| `golden_data[n]` / `actual_data[n]` | 有符号十进制，比较最终INT8；actual在每次任务结束检查时从BRAM提取 |
| `dut.features`, `dut.features_valid`, `dut.feature_last` | 只在valid有效时看特征，每组都应重新输出4个输入，最后一个伴随last |
| `dut.weights[n]`, `dut.weight_valid[n]` | 每列权重和该列特征相配，列号越大到达越晚 |
| `dut.pe_result[n]`, `dut.pe_result_valid[n]` | 每组各PE最终MAC结果，尚未加bias |
| `dut.accum_result`, `dut.accum_valid` | 加bias后的串行结果，与golden_sum按有效输出顺序比较 |
| `dut.u_int32_int8.data_o`, `dut.u_int32_int8.data_valid_o` | 量化/ReLU/限幅后的INT8，与golden_data比较 |
| `acc_fc_wr_en/addr/data/strb` | 实际BRAM写回，只看使能有效时被strb选中的字节 |
| `dut.group_idx`, `dut.group_bias_count` | 计算期间第一组为0/16，第二组为1/2 |
| `dut.u_fc_ctrl.state`, `fc_busy`, `fc_start`, `fc_done`, `fc_irq` | 观察阶段、启动、完成和中断 |

顺序为：初始化 → 装输入 → 装第一组bias → 计算/排空/写回 → 装第二组bias → 计算/排空/写回 → 完成。
第二组不重新装载输入，只重播 input_cache；权重继续读取后一组。
时钟周期为100ns，与提供的示例一致。

当前实现每4个32位权重读返回组成一组16路权重向量，特征有效信号通常间隔4拍。
PE和权重错拍链在运行期间按时钟推进，无效拍是气泡，不要把每个时钟都当成一次有效MAC。
当前 `weight_cache` 第j列比第0列晚j个时钟对齐，不是等j次新权重向量。

量化流水线中，若INT32结果在上升沿T0被采样，T0锁存、T1乘法、T2舍入移位、T3更新INT8输出。
对应字节在T4上升沿写入BRAM。按valid配对，不能拿同一时刻的INT32和INT8直接比较。

## 6. 检查标志与FSDB

理想情况下，每次任务结束检查时：

```text
accum_count=18，accum_errors=0
write_count=18，write_errors=0，data_errors=0
```

全部三次结束后：`check_done=1`、`case_pass=111`、`test_pass=1`、`timed_out=0`。
其中 `case_pass[0]` 对应测试1，依此类推。
计数器在下一次任务开始时清零；golden/actual数组也会更新，所以查看旧任务时需要移动波形光标。
5000个时钟仍未完成时 `timed_out=1` 并结束仿真；此时不能视为通过。

FSDB设置沿用示例，默认路径没有改变：

```verilog
`ifdef DUMP
    string dump_file;
    initial begin
        if (!$value$plusargs("FSDB=%s", dump_file))
            dump_file = "./fsdb/RTL.fsdb";
        $fsdbDumpfile(dump_file);
        $fsdbDumpvars(0, testbench_fc);
        $fsdbDumpMDA();
    end
`endif
```

继续使用原来的 VCS/Verdi FSDB 插件设置，编译时加 `+define+DUMP`；运行参数仍可用 `+FSDB=fsdb/RTL.fsdb`。
运行前确保原有 `fsdb` 目录存在；不改路径、不新增VCD或结果文本输出。

需要编译的文件（顶层指定 `testbench_fc`，SystemVerilog模式，include路径包含仓库根目录）：

```text
testbench_fc.sv
coprocessor/pe_os.sv
coprocessor/fc/fc_top.sv
coprocessor/fc/fc_reg.sv
coprocessor/fc/fc_ctrl.sv
coprocessor/fc/addr_gen.sv
coprocessor/fc/read_arbiter.sv
coprocessor/fc/input_cache.sv
coprocessor/fc/weight_cache.sv
coprocessor/fc/bias_cache.sv
coprocessor/fc/pe_array.sv
coprocessor/fc/accumulation.sv
coprocessor/fc/int32_int8.sv
```

不要同时把conv文件夹整体编进这次独立仿真，两个文件夹存在同名模块。

## 7. 当前RTL实际暴露的问题

三次任务在 `fc_done` 时，18个有效结果和18次写回都正确。
但 `fc_ctrl` 在最后一组的 WAIT_RESULT 中提前把 `group_cnt` 清零，使 `group_bias_count` 从2变回16。
此时 `accumulation` 的 `line_done` 仍为1、`ptr` 已到2，没有新组初始化来清除它们。
因此其串行输出条件 `ptr < group_bias_count_i` 又成立，继续发出第2～15槽的14个零值。
这些槽不是本层新增输出，不能被算作有效结果。

`int32_int8.result_done` 已经保持为1，当前写口把后续结果拦住了，所以最终BRAM字节仍然正确。
TB故意在完成后继续观察20拍，捕获这些额外有效结果，而不是在done时立即停止检查。

当前每次检查时实际为：

```text
accum_count=32，accum_errors=14
write_count=18，write_errors=0，data_errors=0
```

整个TB在约53.7us结束，`check_done=1`、`case_pass=000`、`test_pass=0`、`timed_out=0`。
这是“最终数值正确，但内部有效结果数量错误”，不是参考公式算错，也不是需要把预期数量改成32。
相关RTL本次未修改，文档中的正确预期仍是每层18个结果。
