# 5pipeline 测试程序说明

这个文档对应当前目录下的 `inst_test_*.data` 文件。

测试方法：

1. 选择一个测试文件，比如 `inst_test_01_addi.data`。
2. 把它的内容复制到 `inst.data`。
3. 在 Vivado 里重新运行 Behavioral Simulation。
4. 看 Tcl Console 里 `testbench_cpu.sv` 打印出来的寄存器结果。

建议加入波形的信号：

```text
/testbench_cpu/clk
/testbench_cpu/rst_n
/testbench_cpu/u_cpu/u_if_stage/u_pc_reg/curr_pc
/testbench_cpu/u_cpu/u_if_stage/u_inst_mem/inst_o
/testbench_cpu/u_cpu/stall
/testbench_cpu/u_cpu/flush_if_id
/testbench_cpu/u_cpu/flush_id_ex
/testbench_cpu/u_cpu/redirect
/testbench_cpu/u_cpu/redirect_pc
/testbench_cpu/u_cpu/u_wb_stage/wb_we_o
/testbench_cpu/u_cpu/u_wb_stage/wb_waddr_o
/testbench_cpu/u_cpu/u_wb_stage/wb_wdata_o
```

## inst_test_01_addi.data

测试目的：检查 `addi`、立即数符号扩展、普通写回。

期望最终寄存器：

```text
x1  = 00000005
x2  = ffffffff
x3  = 000007ff
x4  = fffff800
x5  = 00000006
```

波形大概现象：

```text
PC 每个周期加 4。
inst_o 依次出现 00500093、fff00113、7ff00193、80000213、00108293。
wb_we_o 在写回时拉高。
wb_waddr_o 依次写 x1、x2、x3、x4、x5。
wb_wdata_o 依次是 5、-1、2047、-2048、6。
stall 和 redirect 应该一直为 0。
```

## inst_test_02_alu_forward.data

测试目的：检查 R 型 ALU 指令，以及相邻指令之间的数据前递。

期望最终寄存器：

```text
x1  = 00000005
x2  = 0000000c
x3  = 00000011
x4  = 0000000c
x5  = 00000008
x6  = 0000000d
x7  = 00000001
x8  = 00000030
x9  = 00000018
x10 = 0000000c
```

波形大概现象：

```text
PC 基本每拍加 4，不应该出现停顿。
流水线填满后，WB 阶段几乎每拍都有写回。
wb_waddr_o 会依次写 x1 到 x10。
wb_wdata_o 每拍变化，对应上面的期望值。
stall 应该保持 0。
因为很多指令马上使用上一条结果，所以这里主要在测 forwarding 是否正确。
```

## inst_test_03_sw_lw_loaduse.data

测试目的：检查 `sw`、`lw`，以及 load-use 冒险停顿。

期望最终寄存器：

```text
x1  = 12345000
x2  = 00000040
x3  = 12345000
x4  = 12345001
x5  = 2468a001
```

波形大概现象：

```text
程序先把 x1 写入数据内存地址 0x40。
随后 lw 从 0x40 读回到 x3。
lw 后面紧跟 addi 使用 x3，所以应该出现一次 load-use stall。
stall 应该有一拍拉高，PC 和 IF/ID 保持一拍。
flush_id_ex 应该拉高一拍，用来插入 bubble。
WB 最后应看到 x3=12345000，x4=12345001，x5=2468a001。
```

## inst_test_04_lb_lbu.data

测试目的：检查字节读取的符号扩展和零扩展，即 `lb` 和 `lbu`。

期望最终寄存器：

```text
x1  = ffffff80
x2  = 00000050
x3  = ffffff80
x4  = 00000080
```

波形大概现象：

```text
x1 先被写成 -128，也就是 0xffffff80。
sb 把低 8 位 0x80 写到数据内存地址 0x50。
lb 读出后写 x3，结果应该是 ffffff80。
lbu 读出后写 x4，结果应该是 00000080。
观察 wb_wdata_o，x3 和 x4 的区别就是符号扩展和零扩展。
```

## inst_test_05_lh_lhu.data

测试目的：检查半字读取的符号扩展和零扩展，即 `lh` 和 `lhu`。

期望最终寄存器：

```text
x1  = ffffffff
x2  = 00000054
x3  = ffffffff
x4  = 0000ffff
```

波形大概现象：

```text
x1 先被写成 -1，也就是 0xffffffff。
sh 把低 16 位 0xffff 写到数据内存地址 0x54。
lh 读出后写 x3，结果应该是 ffffffff。
lhu 读出后写 x4，结果应该是 0000ffff。
观察 wb_wdata_o，x3 和 x4 的区别就是符号扩展和零扩展。
```

## inst_test_06_beq.data

测试目的：检查 `beq` 跳转成立和不成立两种情况。

期望最终寄存器：

```text
x1  = 00000001
x2  = 00000001
x3  = 00000003
x4  = 00000004
x5  = 00000005
```

波形大概现象：

```text
第一条 beq 条件成立，所以 redirect 应该拉高一次。
flush_if_id 和 flush_id_ex 应该跟着拉高，用来冲刷流水线里的错误指令。
被跳过的指令本来会写 x3=99，但最终 x3 必须是 3。
第二条 beq 条件不成立，所以 PC 正常继续走，x4 和 x5 正常写回。
```

## inst_test_07_bne.data

测试目的：检查 `bne` 跳转成立和不成立两种情况。

期望最终寄存器：

```text
x1  = 00000001
x2  = 00000002
x3  = 00000003
x4  = 00000004
x5  = 00000005
```

波形大概现象：

```text
第一条 bne 条件成立，所以 redirect 应该拉高一次。
flush_if_id 和 flush_id_ex 应该拉高，用来冲刷流水线。
被跳过的指令本来会写 x3=99，但最终 x3 必须是 3。
第二条 bne 比较 x1 和 x1，条件不成立，所以 PC 正常继续走。
x4 和 x5 应该正常写回。
```

## inst_test_08_jal.data

测试目的：检查 `jal` 跳转，以及 PC+4 写回 rd。

期望最终寄存器：

```text
x1  = 00000001
x2  = 00000002
x3  = 00000003
x5  = 00000008
```

波形大概现象：

```text
执行 jal 时，redirect 应该拉高。
redirect_pc 应该变成 jal 的目标地址。
flush_if_id 和 flush_id_ex 应该拉高，用来清掉错误路径上的指令。
被跳过的指令本来会写 x2=99，但最终 x2 必须是 2。
jal 会把 PC+4 写入 x5，所以 x5 应该是 00000008。
```

## inst_test_09_jalr.data

测试目的：检查 `jalr` 跳转，以及 PC+4 写回 rd。

期望最终寄存器：

```text
x1  = 00000010
x2  = 00000002
x3  = 00000003
x5  = 00000008
```

波形大概现象：

```text
x1 先被写成 0x10。
jalr 使用 x1+0 作为跳转目标，所以 redirect_pc 应该变成 00000010。
flush_if_id 和 flush_id_ex 应该拉高。
被跳过的指令本来会写 x2=99 和 x3=99，但最终 x2=2，x3=3。
jalr 会把 PC+4 写入 x5，所以 x5 应该是 00000008。
```

