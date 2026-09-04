# CMP/CMPU：从 C 程序到 FPGA 烧录文件的完整示例

本例使用修改后的 LLVM，将 C 语言中的有符号和无符号最大值表达式自动选择为 `cmp` 和 `cmpu`，然后生成可交给 `peqflash.py` 的 IMEM/DMEM 文件。

## 1. C 测试程序

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

## 2. 链接脚本

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

## 3. PQR5 binary 转换脚本

`peqflash.py` 要求 IMEM 文件以 `C0C0C0C0` 开头，DMEM 文件以 `D0D0D0D0` 开头。原脚本固定写入 `C0C0C0C0`，因此需要增加 `-memtype` 参数。

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

    padded_data = data.ljust((len(data) + 3) & ~3, b"\x00")
    preamble = 0xC0C0C0C0 if memtype == "imem" else 0xD0D0D0D0

    with open(output_file, "wb") as output_stream:
        output_stream.write(struct.pack(">I", preamble))
        output_stream.write(struct.pack(">I", len(padded_data)))
        output_stream.write(struct.pack(">I", baseaddr))

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

## 4. 使用修改后的 LLVM 编译

以下命令假设当前位于 `llvm-project` 根目录，并且上述三个文件也在该目录中。

如果刚修改了 LLVM，先增量重新编译：

```bash
ninja -C build clang llc llvm-objdump llvm-objcopy llvm-readelf lld
```

编译 C 文件：

```bash
build/bin/clang --target=riscv32 -march=rv32i -mabi=ilp32 \
  -O2 -ffreestanding -fno-builtin -fno-stack-protector \
  -fno-pic -mno-relax -c cmp_test.c -o cmp_test.o
```

链接：

```bash
build/bin/ld.lld -m elf32lriscv --no-relax \
  -T cmp_test.ld cmp_test.o -o cmp_test.elf
```

检查最终 ELF 中是否含有 `cmp/cmpu`：

```bash
build/bin/llvm-objdump -d cmp_test.elf | grep -E "cmpu?"
```

若没有输出，检查优化后的 LLVM IR：

```bash
build/bin/clang --target=riscv32 -O2 -S -emit-llvm \
  -ffreestanding cmp_test.c -o cmp_test.ll
grep -E "smax|umax" cmp_test.ll
```

必须使用 `-O2`，并保留输入变量的 `volatile`，否则测试表达式可能在编译期被直接计算。

## 5. 提取并转换 IMEM/DMEM

查看 ELF 段信息：

```bash
build/bin/llvm-readelf -S cmp_test.elf
```

提取原始 `.text` 和 `.data`：

```bash
build/bin/llvm-objcopy -O binary --only-section=.text \
  cmp_test.elf cmp_test_iram_raw.bin

build/bin/llvm-objcopy -O binary --only-section=.data \
  cmp_test.elf cmp_test_dram_raw.bin
```

转换成 PQR5 格式：

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

虽然链接脚本中的 DMEM 地址是 `0x80000000`，但当前 CPU/loader 的 DMEM 包使用本地存储器偏移，所以这里使用 `-baseaddr 0x0`。

## 6. 下载到 FPGA

将生成的 `cmp_test_iram.bin` 和 `cmp_test_dram.bin` 复制到 Windows 工程目录，然后执行：

```powershell
py .\peqflash.py -serport COM4 -baud 115200 `
  -imembin .\cmp_test_iram.bin `
  -dmembin .\cmp_test_dram.bin
```

把 `COM4` 改为开发板实际串口号。运行后 UART 应依次输出 `3` 和 `2`。
