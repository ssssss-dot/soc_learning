# 在五级流水 CPU 和 LLVM 中添加自定义 CMP 指令

本文说明如何在现有 RV32 五级流水 CPU 中加入自定义 `cmp`/`cmpu（cmp为有符号比较，cmpu为无符号比较）` 指令，并让 Linux 下自行编译的 LLVM 能够汇编和反汇编这两条指令。

串口端下载脚本参照：https://github.com/iammituraj/pequeno_riscv

## 1. 指令定义

本工程的 CMP是将两个寄存器rs1，rs2的数比较并将较大的数写入rd：

```text
cmp  rd, rs1, rs2    # 有符号比较：rd = max((int32_t)rs1, (int32_t)rs2)
cmpu rd, rs1, rs2    # 无符号比较：rd = max((uint32_t)rs1, (uint32_t)rs2)
```

它们采用标准 R 型格式，并使用 RISC-V 为用户自定义指令预留的 `custom-0` opcode。

```text
31          25 24      20 19      15 14   12 11       7 6       0
+--------------+----------+----------+-------+-----------+---------+
| funct7       | rs2      | rs1      |funct3 | rd        | opcode  |
+--------------+----------+----------+-------+-----------+---------+
| 0000000      | 5 bits   | 5 bits   |见下表  | 5 bits    | 0001011 |
+--------------+----------+----------+-------+-----------+---------+
```


| 指令   | funct7    | funct3 | opcode    | 语义         |
| ------ | --------- | ------ | --------- | ------------ |
| `cmp`  | `0000000` | `000`  | `0001011` | 有符号最大值 |
| `cmpu` | `0000000` | `001`  | `0001011` | 无符号最大值 |

例如 `cmp x3, x1, x2` 的机器码为 `0x0020818b`，`cmpu x3, x1, x2` 为 `0x0020918b`（小端内存中的字节顺序分别为 `8b 81 20 00` 和 `8b 91 20 00`）。

## 2. 修改链路概览（只展示需要修改的部分）

```text
C/汇编源文件
  -> LLVM/Clang 识别助记符或 intrinsic
  -> 编码为 32 位机器指令
  -> ID 按 opcode/funct3/funct7 译码
  -> EX 比较两个前递后的操作数并产生最大值
```

这两条指令无访存、无跳转，数据通路与普通 R 型 ALU 指令相同。现有前递和 load-use 冒险检测只要依据 `re1/re2/rd/reg_we` 工作，通常不需要新增 CMP 专用逻辑。

## 3. CPU RTL 修改

### 3.1 在 `define.v` 中定义编码和内部 ALU 操作

本工程已经使用以下定义：

```verilog
`define OP_CMP         7'b0001011
`define FUNCT3_CMP     3'b000
`define FUNCT3_CMPU    3'b001

`define EX_CMP_OP      11'b00100110011
`define EX_CMPU_OP     11'b00100110101
```

`OP_CMP/FUNCT3_*` 是指令二进制编码；`EX_CMP*_OP` 只是 CPU 内部从 ID 传到 EX 的控制码，两类数值没有必要相同，但内部控制码必须保持唯一。EX_OP = {opcode[6:0], funct3[2:0], funct7标志位}。

### 3.2 ID 阶段译码

在 opcode 的 `case` 中加入 `OP_CMP`。以下写法把共同控制信号提到外层，并校验完整 `funct7`：

```verilog
`OP_CMP:begin
            case(funct3)
                `FUNCT3_CMP:begin
                    re1_o          = `ReadEnable;
                    re2_o          = `ReadEnable;
                    reg_we_o       = `WriteEnable;

                    imm_o          = `ZeroWord;
                    aluop_o        = `EX_CMP_OP;
                    alu_src1_sel_o = `ALU_SRC1_RS1;
                    alu_src2_sel_o = `ALU_SRC2_RS2;

                    mem_re_o       = 1'b0;
                    mem_we_o       = 1'b0;
                    mem_op_o       = `MEM_NONE;
                    wb_sel_o       = `WB_SEL_ALU;
                end
                `FUNCT3_CMPU:begin
                    re1_o          = `ReadEnable;
                    re2_o          = `ReadEnable;
                    reg_we_o       = `WriteEnable;
  
                    imm_o          = `ZeroWord;
                    aluop_o        = `EX_CMPU_OP;
                    alu_src1_sel_o = `ALU_SRC1_RS1;
                    alu_src2_sel_o = `ALU_SRC2_RS2;

                    mem_re_o       = 1'b0;
                    mem_we_o       = 1'b0;
                    mem_op_o       = `MEM_NONE;
                    wb_sel_o       = `WB_SEL_ALU;
                end
            endcase
        end`OP_CMP: begin
    if (funct7 == `FUNCT7_CMP) begin
        case (funct3)
            `FUNCT3_CMP:  aluop_o = `EX_CMP_OP;
            `FUNCT3_CMPU: aluop_o = `EX_CMPU_OP;
            default:      aluop_o = `EX_NOP_OP; // 或产生 illegal instruction
        endcase

        if (funct3 == `FUNCT3_CMP || funct3 == `FUNCT3_CMPU) begin
            re1_o          = `ReadEnable;
            re2_o          = `ReadEnable;
            reg_we_o       = `WriteEnable;
            imm_o          = `ZeroWord;
            alu_src1_sel_o = `ALU_SRC1_RS1;
            alu_src2_sel_o = `ALU_SRC2_RS2;
            mem_re_o       = 1'b0;
            mem_we_o       = 1'b0;
            mem_op_o       = `MEM_NONE;
            wb_sel_o       = `WB_SEL_ALU;
        end
    end
end
```

各控制信号的含义如下：


| 信号                   |     CMP 设置 | 原因                   |
| ---------------------- | -----------: | ---------------------- |
| `re1_o`、`re2_o`       |            1 | 两个源寄存器都参与比较 |
| `reg_we_o`             |            1 | 结果需要写回`rd`       |
| `alu_src1_sel_o`       |        `RS1` | ALU 左操作数来自`rs1`  |
| `alu_src2_sel_o`       |        `RS2` | ALU 右操作数来自`rs2`  |
| `mem_re_o`、`mem_we_o` |            0 | 不访问数据存储器       |
| `wb_sel_o`             | `WB_SEL_ALU` | 写回 EX 产生的最大值   |
| branch/jump/fence      |            0 | 不改变控制流           |

工程当前代码已经在 [`id/id.v`](./id/id.v) 的 `OP_CMP` 分支完成了主要译码。若 CPU 支持非法指令异常，未知 `funct3/funct7` 应进入 illegal-instruction 路径，而不是静默执行 NOP。

### 3.3 EX 阶段执行

在 [`ex_stage/ex.v`](./ex_stage/ex.v) 的 ALU `case` 中加入：

```verilog
`EX_CMP_OP:
    alu_result_o = ($signed(alu_src1) >= $signed(alu_src2))
                 ? alu_src1 : alu_src2;

`EX_CMPU_OP:
    alu_result_o = (alu_src1 >= alu_src2)
                 ? alu_src1 : alu_src2;
```

`cmp` 的两边都必须显式转换为 `$signed`。`cmpu` 保持 Verilog 默认的无符号比较。等值时选择哪一个源操作数对最终数值没有影响。

EX 应比较经过前递选择后的 `rs1_data_final`、`rs2_data_final`，而不是原始 ID/EX 数据。本工程先用最终前递值生成 `alu_src1/alu_src2`，所以 CMP 能正确处理：

```asm
addi a0, zero, 10
addi a1, zero, 20
cmp  a2, a0, a1       # 立即依赖前两条指令，期望 a2 = 20
```

### 3.5 MEM/WB 与冒险处理

无需修改，cmp和cmpu不涉及额外的数据冒险与控制冒险

## 4. 在 Linux LLVM 中加入汇编/反汇编支持

### 4.1 下载 LLVM 源码

把 LLVM 源代码下载到自己的用户目录。执行：

```bash
cd ~
git clone --depth 1 https://github.com/llvm/llvm-project.git
cd llvm-project
```

下载完成后的目录应类似：

```text
~/llvm-project/
├── clang/
├── lld/
├── llvm/
└── ...
```

后续修改和编译全部在 `~/llvm-project` 中完成，构建结果放在 `~/llvm-project/build`。不执行 `sudo apt`、`sudo make install` 或 `sudo ninja install`，编译完成后直接使用 `build/bin` 目录中的 LLVM 工具。

### 4.2 添加 CMP/CMPU 的 TableGen 定义

新建文件：

```text
llvm/lib/Target/RISCV/RISCVInstrInfoCMP.td
```

写入：

```tablegen
//===-- RISCVInstrInfoCMP.td - Custom CMP instructions -*- tablegen -*-===//

// 先在 llvm/lib/Target/RISCV 中搜索 OPC_CUSTOM_0。
// 如果当前版本已经定义了它，这里不能重复定义。
def OPC_CUSTOM_0 : RISCVOpcode<"CUSTOM_0", 0b0001011>;

let hasSideEffects = 0, mayLoad = 0, mayStore = 0 in {
  class CMP_rr<bits<3> funct3, string mnemonic>
      : RVInstR<0b0000000, funct3, OPC_CUSTOM_0,
                (outs GPR:$rd), (ins GPR:$rs1, GPR:$rs2),
                mnemonic, "$rd, $rs1, $rs2">,
        Sched<[WriteIALU, ReadIALU, ReadIALU]>;

  // funct7=0000000, funct3=000, opcode=0001011
  def CMP  : CMP_rr<0b000, "cmp">;

  // funct7=0000000, funct3=001, opcode=0001011
  def CMPU : CMP_rr<0b001, "cmpu">;
}

// LLVM 有符号最大值节点 -> cmp
def : Pat<(smax GPR:$rs1, GPR:$rs2),
          (CMP GPR:$rs1, GPR:$rs2)>;

// LLVM 无符号最大值节点 -> cmpu
def : Pat<(umax GPR:$rs1, GPR:$rs2),
          (CMPU GPR:$rs1, GPR:$rs2)>;
```

不同 LLVM 版本中的 `RVInstR` 参数或调度资源名称可能不同。出现 TableGen 参数错误时，应参考同一版本中 `ADD`、`MAX` 等 R 型指令的定义进行调整。

先检查 `OPC_CUSTOM_0` 是否已经存在：

```bash
grep -R "def OPC_CUSTOM_0" llvm/lib/Target/RISCV
```

如果搜索到了已有定义，就删除新文件中的这一行：

```tablegen
def OPC_CUSTOM_0 : RISCVOpcode<"CUSTOM_0", 0b0001011>;
```

然后打开：

```text
llvm/lib/Target/RISCV/RISCVInstrInfo.td
```

在文件末尾或其他指令定义的 include 附近加入：

```tablegen
include "RISCVInstrInfoCMP.td"
```

TableGen 会由这些定义自动生成汇编匹配、机器码编码和反汇编表，通常不需要手动修改 `RISCVAsmParser.cpp`、`RISCVMCCodeEmitter.cpp` 或 `RISCVDisassembler.cpp`。

### 4.3 在指令选择阶段启用 SMAX/UMAX

打开：

```text
llvm/lib/Target/RISCV/RISCVISelLowering.cpp
```

在 `RISCVTargetLowering` 构造函数中，紧接 `SELECT_CC` 设置的位置加入：

```cpp
setOperationAction(ISD::SELECT_CC, XLenVT, Expand);//已有

// 自定义 CMP/CMPU 支持最大值运算。
setOperationAction(ISD::SMAX, XLenVT, Legal);
setOperationAction(ISD::UMAX, XLenVT, Legal);
```

### 4.4 首次配置和编译 LLVM

在 `llvm-project` 根目录执行 CMake 配置：

```bash
cmake -S llvm -B build -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DLLVM_TARGETS_TO_BUILD=RISCV \
  -DLLVM_ENABLE_PROJECTS="clang;lld"
```

然后编译本实验需要的工具：

```bash
ninja -C build llvm-mc llvm-objdump llc clang lld
```

这些程序生成在：

```text
build/bin/llvm-mc
build/bin/llvm-objdump
build/bin/llc
build/bin/clang
build/bin/ld.lld
```

如果机器内存较小，可限制并行任务数，例如：

```bash
ninja -C build -j2 llvm-mc llvm-objdump llc clang lld
```

### 4.5 修改编译器后如何重新编译（每修改一次都要重新编译）

第一次已经执行过 CMake 配置后，修改 `.td`、`.cpp` 或 `.h` 文件不需要删除 `build`，也通常不需要再次执行 CMake。直接运行 Ninja 增量编译：

```bash
ninja -C build llvm-mc llvm-objdump llc clang
```

Ninja 会自动检测发生变化的源码，并重新运行 TableGen、编译受影响的 C++ 文件和重新链接工具。

可以根据修改内容缩小编译范围：

```bash
# 修改指令 .td 后，验证汇编和反汇编所需工具
ninja -C build llvm-mc llvm-objdump

# 修改指令选择规则或 RISCVISelLowering.cpp 后
ninja -C build llc

# 需要从 C/C++ 源码完整测试时
ninja -C build clang llc llvm-objdump
```

如果构建失败，不要首先删除整个 `build`。先查看报错；TableGen 报错通常是 `.td` 的类参数、重复定义或 include 位置不正确。

### 4.6 验证汇编和反汇编

新建 `cmp.s`：

```asm
.text
.globl _start
_start:
  cmp  x3, x1, x2
  cmpu x3, x1, x2
```

检查汇编器生成的字节：

```bash
build/bin/llvm-mc -triple=riscv32 -show-encoding cmp.s
```

期望编码为：

```text
cmp  x3, x1, x2   # encoding: [0x8b,0x81,0x20,0x00]
cmpu x3, x1, x2   # encoding: [0x8b,0x91,0x20,0x00]
```

再生成目标文件并反汇编：

```bash
build/bin/llvm-mc -triple=riscv32 -filetype=obj cmp.s -o cmp.o
build/bin/llvm-objdump -d cmp.o
```

反汇编结果应显示 `cmp` 和 `cmpu`，而不是 `.word` 或 `<unknown>`。

### 4.7 验证 C 代码能否自动生成 CMP

新建 `max.c`：

```c
int signed_max(int a, int b)
{
    return a > b ? a : b;
}

unsigned unsigned_max(unsigned a, unsigned b)
{
    return a > b ? a : b;
}
```

先生成 LLVM IR，确认优化器产生了最大值语义：

```bash
build/bin/clang --target=riscv32 -O2 -S -emit-llvm max.c -o max.ll
grep -E "smax|umax" max.ll
```

再生成 RISC-V 汇编：

```bash
build/bin/clang --target=riscv32 -march=rv32i -mabi=ilp32 \
  -O2 -S max.c -o max.s
grep -E "cmpu?|signed_max|unsigned_max" max.s
```

也可以绕过 Clang 前端，直接检查后端选择结果：

```bash
build/bin/llc -mtriple=riscv32 -mattr=-relax max.ll -o max-llc.s
grep -E "cmpu?" max-llc.s
```

如果手写 `cmp.s` 能正确汇编，但 C 代码没有生成 CMP，应检查 `max.ll` 中是否存在 `llvm.smax.i32`/`llvm.umax.i32`，以及 TableGen 中的 `smax/umax` 模式是否成功生成。不要在这种情况下继续修改 MC 汇编器代码。

## 5. 完整示例：从 C 程序生成可烧录文件

C 源码写出有符号和无符号最大值表达式，修改后的 LLVM 在 `-O2` 下把它们识别为 `smax/umax`，然后自动选择成 `cmp/cmpu`。

### 5.1 C 测试程序

新建 `cmp_test.c`：

```c
#include <stdint.h>

#define UART_TX (*(volatile uint8_t *)0x10000000u)

/* volatile 防止编译器在编译期间直接算出结果。 */
volatile int32_t signed_a = -5;
volatile int32_t signed_b = 3;
volatile uint32_t unsigned_a = 1u;
volatile uint32_t unsigned_b = 2u;

__attribute__((noreturn, section(".text.start")))
void _start(void)
{
    int32_t a = signed_a;
    int32_t b = signed_b;

    /* LLVM 应将这个表达式选择成 cmp。 */
    int32_t signed_result = (a >= b) ? a : b;
    UART_TX = (uint8_t)('0' + signed_result);
    UART_TX = '\r';
    UART_TX = '\n';

    uint32_t ua = unsigned_a;
    uint32_t ub = unsigned_b;

    /* LLVM 应将这个表达式选择成 cmpu。 */
    uint32_t unsigned_result = (ua >= ub) ? ua : ub;
    UART_TX = (uint8_t)('0' + unsigned_result);
    UART_TX = '\r';
    UART_TX = '\n';

    while (1) {
    }
}
```

程序预期通过 UART 输出：

```text
3
2
```

输入变量必须保留 `volatile`，否则编译器可能在编译期间直接得到常量结果，最终汇编中不会出现 `cmp/cmpu`。

### 5.2 链接脚本

新建 `cmp_test.ld`：

```ld
OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
    IMEM (rx)  : ORIGIN = 0x00000000, LENGTH = 512K
    DMEM (rwx) : ORIGIN = 0x80000000, LENGTH = 128K
}

SECTIONS
{
    .text :
    {
        . = ALIGN(4);
        KEEP(*(.text.start))
        KEEP(*(.text._start))
        *(.text*)
        . = ALIGN(4);
    } > IMEM

    .data :
    {
        . = ALIGN(4);
        *(.rodata*)
        *(.srodata*)
        *(.data*)
        *(.sdata*)
        . = ALIGN(4);
    } > DMEM

    .bss (NOLOAD) :
    {
        . = ALIGN(4);
        __bss_start = .;
        *(.bss*)
        *(.sbss*)
        *(COMMON)
        . = ALIGN(4);
        __bss_end = .;
    } > DMEM

    __stack_top = ORIGIN(DMEM) + LENGTH(DMEM);

    /DISCARD/ :
    {
        *(.comment)
        *(.note*)
        *(.eh_frame*)
        *(.riscv.attributes)
    }
}
```

`.text` 位于从 `0x00000000` 开始的 IMEM，初始化全局变量位于从 `0x80000000` 开始的 DMEM。`.bss` 使用 `NOLOAD`，不会出现在原始 DMEM 文件中；如果程序使用未初始化全局变量，启动代码还需要清零 `.bss`。

### 5.3 PQR5 binary 转换脚本

`peqflash.py` 要求 IMEM 文件以 `C0C0C0C0` 开头，DMEM 文件以 `D0D0D0D0` 开头。原脚本固定写入 `C0C0C0C0`，只能生成 IMEM 包，因此下面增加 `-memtype imem|dmem` 参数。

新建 `bin2pqr5bin.py`：

```python
import argparse
import os
import struct
import sys


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("-binfile", required=True)
    parser.add_argument("-outfile", required=True)
    parser.add_argument(
        "-baseaddr", required=True, type=lambda value: int(value, 0)
    )
    parser.add_argument(
        "-memtype", required=True, choices=("imem", "dmem")
    )
    return parser.parse_args()


def validate_args(args):
    if not os.path.isfile(args.binfile):
        print(f"Error: file '{args.binfile}' not found.", file=sys.stderr)
        sys.exit(1)
    if args.baseaddr % 4 != 0:
        print("Error: base address is not 4-byte aligned.", file=sys.stderr)
        sys.exit(1)


def process_bin_file(input_file, baseaddr, memtype, output_file):
    with open(input_file, "rb") as input_stream:
        data = input_stream.read()

    # PQR5 按 32 位字传输，不足 4 字节时在结尾补零。
    padded_data = data.ljust((len(data) + 3) & ~3, b"\x00")
    preamble = 0xC0C0C0C0 if memtype == "imem" else 0xD0D0D0D0

    with open(output_file, "wb") as output_stream:
        output_stream.write(struct.pack(">I", preamble))
        output_stream.write(struct.pack(">I", len(padded_data)))
        output_stream.write(struct.pack(">I", baseaddr))

        # 将原始小端 RISC-V binary 中的每个 32 位字反转。
        for offset in range(0, len(padded_data), 4):
            chunk = padded_data[offset:offset + 4]
            output_stream.write(chunk[::-1])

        output_stream.write(struct.pack(">I", 0xE0E0E0E0))


if __name__ == "__main__":
    arguments = parse_args()
    validate_args(arguments)
    process_bin_file(
        arguments.binfile,
        arguments.baseaddr,
        arguments.memtype,
        arguments.outfile,
    )
    print(f"Created PQR5-compatible binary: {arguments.outfile}")
```

### 5.4 使用修改后的 LLVM 编译和链接

以下命令假设当前位于 `llvm-project` 根目录，并且上述三个文件也在该目录中。修改 LLVM 后先增量编译：

```bash
ninja -C build clang llc llvm-objdump llvm-objcopy llvm-readelf lld
```

编译 C 文件：

```bash
build/bin/clang --target=riscv32 -march=rv32i -mabi=ilp32 \
  -O2 -ffreestanding -fno-builtin -fno-stack-protector \
  -fno-pic -mno-relax -c cmp_test.c -o cmp_test.o
```

链接 ELF：

```bash
build/bin/ld.lld -m elf32lriscv --no-relax \
  -T cmp_test.ld cmp_test.o -o cmp_test.elf
```

反汇编并确认已经生成 `cmp/cmpu`：

```bash
build/bin/llvm-objdump -d cmp_test.elf | grep -E "cmpu?"
```

预期至少能看到一条 `cmp` 和一条 `cmpu`。如果没有，检查优化后的 LLVM IR：

```bash
build/bin/clang --target=riscv32 -O2 -S -emit-llvm \
  -ffreestanding cmp_test.c -o cmp_test.ll
grep -E "smax|umax" cmp_test.ll
```

### 5.5 提取 IMEM 和 DMEM 原始文件

查看 ELF 的段地址和大小：

```bash
build/bin/llvm-readelf -S cmp_test.elf
```

分别提取 `.text` 和 `.data`：

```bash
build/bin/llvm-objcopy -O binary --only-section=.text \
  cmp_test.elf cmp_test_iram_raw.bin

build/bin/llvm-objcopy -O binary --only-section=.data \
  cmp_test.elf cmp_test_dram_raw.bin
```

这里得到的是普通小端 raw binary，不能直接交给 `peqflash.py`。

### 5.6 转换为 peqflash 格式

```bash
python3 bin2pqr5bin.py \
  -binfile cmp_test_iram_raw.bin \
  -outfile cmp_test_iram.bin \
  -baseaddr 0x0 -memtype imem

python3 bin2pqr5bin.py \
  -binfile cmp_test_dram_raw.bin \
  -outfile cmp_test_dram.bin \
  -baseaddr 0x0 -memtype dmem
```

链接脚本中的 DMEM 地址是 `0x80000000`，但当前 CPU/loader 的 DMEM 包使用本地存储器偏移，所以与工程已有 `cmp_test_dram.bin` 一样使用 `-baseaddr 0x0`。

转换后的文件格式为：

```text
4 字节 preamble：IMEM=C0C0C0C0，DMEM=D0D0D0D0
4 字节数据长度：大端
4 字节本地基地址：大端
N 字节程序数据：每个 32 位字由小端转换为大端排列
4 字节 postamble：E0E0E0E0
```

### 5.7 下载到 FPGA

把生成的 `cmp_test_iram.bin` 和 `cmp_test_dram.bin` 下载到 Windows 工程目录，执行：

```powershell
py .\peqflash.py -serport COM4 -baud 115200 `
  -imembin .\cmp_test_iram.bin `
  -dmembin .\cmp_test_dram.bin
```

将 `COM4` 替换为开发板实际串口号。下载并启动后，调试 UART 应依次输出 `3` 和 `2`。

注：编译为两个.bin文件的过程在linux服务器上实现（包括bin2pqr5bin.py脚本的使用），用改好的llvm服务器，串口烧录在windows系统上用peqflash脚本完成
