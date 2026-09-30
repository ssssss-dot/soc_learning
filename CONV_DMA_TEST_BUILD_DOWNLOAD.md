# Conv DMA C 测试：Linux 编译、转换与 Windows 下载流程

本文说明如何把 `conv_test.c` 编译为 RV32I 程序，使用 `linker.ld` 完成链接，提取最初的 IMEM/DMEM 原始 bin，再通过 `pqr2bin.py` 进行 PQR5 下载格式重排，最后在 Windows 上通过 COM4 和 `peqflash.py` 下载到 FPGA。

## 1. 文件和地址要求

Linux 工程目录中需要有以下文件：

```text
/home/shenjiexiang/Desktop/rsicv/c_demo/conv_test/conv_test.c
/home/shenjiexiang/Desktop/rsicv/c_demo/conv_test/linker.ld
/home/shenjiexiang/Desktop/rsicv/c_demo/conv_test/pqr2bin.py
```

当前 Git 仓库已经包含 `conv_test.c` 和 `linker.ld`。如果 Linux 工程目录中还没有 `pqr2bin.py`，需要先把已有脚本复制到上述位置。

`linker.ld` 应满足以下内存布局：

```text
IMEM：CPU 地址 0x00000000，容量 128 KiB
DMEM：CPU 地址 0x80000000，容量 128 KiB
栈顶：0x80020000
.text：放入 IMEM
.rodata/.data/.sdata：合并到输出段 .data，放入 DMEM
.bss/.sbss：放入 DMEM，并标记 NOLOAD
```

测试程序在 `_start` 中把栈指针设置为 `0x80020000`，因此 `linker.ld` 的 DMEM 顶部必须与此一致。

## 2. 在 Linux 中指定所有工具路径

以下路径以 `/home/shenjiexiang` 为例。若 LLVM 实际安装位置不同，只修改这一组变量；不需要也不建议把 LLVM 临时加入系统 `PATH`。

```bash
export PROJECT_DIR=/home/shenjiexiang/Desktop/rsicv/c_demo/conv_test
export LLVM_BIN=/home/shenjiexiang/llvm-project/build/bin
export LINKER_SCRIPT=/home/shenjiexiang/Desktop/rsicv/c_demo/conv_test/linker.ld
export PQR2BIN=/home/shenjiexiang/Desktop/rsicv/c_demo/conv_test/pqr2bin.py
export BUILD_DIR=/home/shenjiexiang/Desktop/rsicv/c_demo/conv_test/build
```

创建构建目录：

```bash
mkdir -p "$BUILD_DIR"
```

检查源文件、链接脚本和转换脚本：

```bash
test -f "$PROJECT_DIR/conv_test.c"
test -f "$LINKER_SCRIPT"
test -f "$PQR2BIN"
```

检查所需 LLVM 工具：

```bash
test -x "$LLVM_BIN/clang"
test -x "$LLVM_BIN/ld.lld"
test -x "$LLVM_BIN/llvm-objcopy"
test -x "$LLVM_BIN/llvm-objdump"
test -x "$LLVM_BIN/llvm-readelf"
test -x "$LLVM_BIN/llvm-size"
```

如果 `clang` 存在，但 `llvm-readelf`、`llvm-objcopy`、`llvm-objdump` 或 `llvm-size` 不存在，说明 LLVM 构建目录只编译了部分目标。使用该 LLVM 工程的 Ninja 构建目录补齐工具：

```bash
ninja -C /home/shenjiexiang/llvm-project/build \
  llvm-readelf llvm-objcopy llvm-objdump llvm-size
```

完成后再次检查：

```bash
ls -l \
  "$LLVM_BIN/llvm-readelf" \
  "$LLVM_BIN/llvm-objcopy" \
  "$LLVM_BIN/llvm-objdump" \
  "$LLVM_BIN/llvm-size"
```

如果只需要立即查看 ELF 段表，也可以临时使用系统 GNU `readelf`：

```bash
/usr/bin/readelf -S "$BUILD_DIR/conv_test.elf"
```

但后续从 ELF 提取 IMEM/DMEM 原始 bin 仍然需要 `llvm-objcopy` 或支持 RISC-V ELF 的 GNU `objcopy`。

打印编译器版本，确认调用的是指定 LLVM：

```bash
"$LLVM_BIN/clang" --version
```

如果某条 `test` 命令没有输出但返回失败，可用下面的命令查看缺失路径：

```bash
ls -l "$PROJECT_DIR/conv_test.c" "$LINKER_SCRIPT" "$PQR2BIN"
ls -l "$LLVM_BIN/clang" "$LLVM_BIN/ld.lld" "$LLVM_BIN/llvm-objcopy"
```

## 3. 编译 C 文件

使用 RV32I 和 ILP32 ABI 编译。保持全局 `-O2`，这样常量乘法和数组索引会被优化成 RV32I 能执行的移位、加法等指令。当前源码只给 `check_conv1_output()` 添加了 `noinline, optnone`，用于避开校验循环的优化寄存器依赖并定位 CPU 流水线冒险；卷积计算、DMA 和其他测试代码仍使用 `-O2`。

```bash
"$LLVM_BIN/clang" \
  --target=riscv32 \
  -march=rv32i \
  -mabi=ilp32 \
  -O2 \
  -ffreestanding \
  -fno-builtin \
  -fno-stack-protector \
  -fno-pic \
  -mno-relax \
  -msmall-data-limit=0 \
  -ffunction-sections \
  -fdata-sections \
  -c "$PROJECT_DIR/conv_test.c" \
  -o "$BUILD_DIR/conv_test.o"
```

确认目标文件已经生成：

```bash
ls -lh "$BUILD_DIR/conv_test.o"
```

## 4. 使用 linker.ld 链接

```bash
"$LLVM_BIN/ld.lld" \
  -m elf32lriscv \
  --no-relax \
  --gc-sections \
  -T "$LINKER_SCRIPT" \
  -Map="$BUILD_DIR/conv_test.map" \
  "$BUILD_DIR/conv_test.o" \
  -o "$BUILD_DIR/conv_test.elf"
```

检查 ELF 文件和总体大小：

```bash
ls -lh "$BUILD_DIR/conv_test.elf" "$BUILD_DIR/conv_test.map"
"$LLVM_BIN/llvm-size" -A "$BUILD_DIR/conv_test.elf"
```

检查 ELF 段地址：

```bash
"$LLVM_BIN/llvm-readelf" -S "$BUILD_DIR/conv_test.elf"
```

应重点确认：

- `.text` 位于 `0x00000000` 开始的 IMEM 区域；
- `.data` 位于 `0x80000000` 开始的 DMEM 区域；
- `.bss` 位于 DMEM，且类型为 `NOBITS`；
- `.data + .bss` 的末地址小于 `0x80020000`，不会覆盖栈顶。

检查入口及反汇编：

```bash
"$LLVM_BIN/llvm-readelf" -h "$BUILD_DIR/conv_test.elf"
"$LLVM_BIN/llvm-objdump" -d "$BUILD_DIR/conv_test.elf" \
  > "$BUILD_DIR/conv_test.dis"
```

确认反汇编中没有 RV32M 的乘除法指令：

```bash
grep -E "[[:space:]](mul|mulh|mulhu|mulhsu|div|divu|rem|remu)[[:space:]]" \
  "$BUILD_DIR/conv_test.dis"
```

正常情况下这条 `grep` 不应输出任何内容。

## 5. 从 ELF 提取最初的原始 bin

先提取 IMEM 原始程序：

```bash
"$LLVM_BIN/llvm-objcopy" \
  -O binary \
  --only-section=.text \
  "$BUILD_DIR/conv_test.elf" \
  "$BUILD_DIR/conv_test_iram_raw.bin"
```

再提取 DMEM 原始数据。`linker.ld` 应将字符串、常量表、`.rodata`、`.srodata`、`.data` 和 `.sdata` 都合并到输出段 `.data`：

```bash
"$LLVM_BIN/llvm-objcopy" \
  -O binary \
  --only-section=.data \
  "$BUILD_DIR/conv_test.elf" \
  "$BUILD_DIR/conv_test_dram_raw.bin"
```

查看两个原始文件的大小：

```bash
wc -c \
  "$BUILD_DIR/conv_test_iram_raw.bin" \
  "$BUILD_DIR/conv_test_dram_raw.bin"
```

这里生成的 `*_raw.bin` 还不能直接交给 `peqflash.py`。它们没有 PQR5 前导、长度、基地址和结束标记，而且每个 32 位字尚未按照 loader 所需顺序重排。

## 6. 使用 pqr2bin.py 重排并封装

先查看脚本参数，确认当前脚本支持 `-binfile`、`-outfile`、`-baseaddr` 和 `-memtype`：

```bash
python3 "$PQR2BIN" --help
```

转换 IMEM 文件：

```bash
python3 "$PQR2BIN" \
  -binfile "$BUILD_DIR/conv_test_iram_raw.bin" \
  -outfile "$BUILD_DIR/conv_test_iram.bin" \
  -baseaddr 0x0 \
  -memtype imem
```

转换 DMEM 文件：

```bash
python3 "$PQR2BIN" \
  -binfile "$BUILD_DIR/conv_test_dram_raw.bin" \
  -outfile "$BUILD_DIR/conv_test_dram.bin" \
  -baseaddr 0x0 \
  -memtype dmem
```

虽然 ELF 中 `.data` 的 CPU 地址从 `0x80000000` 开始，但 downloader 的 DMEM 基地址必须填写本地偏移 `0x0`。硬件 loader 会自动将它转换成 DDR 物理地址 `0x10000000 + offset`。

检查最终文件：

```bash
ls -lh \
  "$BUILD_DIR/conv_test_iram.bin" \
  "$BUILD_DIR/conv_test_dram.bin"
```

检查前 16 字节：

```bash
xxd -g 1 -l 16 "$BUILD_DIR/conv_test_iram.bin"
xxd -g 1 -l 16 "$BUILD_DIR/conv_test_dram.bin"
```

IMEM 文件应以 `c0 c0 c0 c0` 开始，DMEM 文件应以 `d0 d0 d0 d0` 开始。检查最后四字节：

```bash
tail -c 4 "$BUILD_DIR/conv_test_iram.bin" | xxd -g 1
tail -c 4 "$BUILD_DIR/conv_test_dram.bin" | xxd -g 1
```

两个文件都应以 `e0 e0 e0 e0` 结束。

## 7. 将最终文件复制到 Windows

在 Windows PowerShell 中执行。下面假设 Linux 主机名为 `142out`，Windows 工程目录为 `E:\sb\rsicv\5pipeline`：

```powershell
Set-Location E:\sb\rsicv\5pipeline
```

```powershell
scp 142out:/home/shenjiexiang/Desktop/rsicv/c_demo/conv_test/build/conv_test_iram.bin `
  .\conv_test_iram.bin
```

```powershell
scp 142out:/home/shenjiexiang/Desktop/rsicv/c_demo/conv_test/build/conv_test_dram.bin `
  .\conv_test_dram.bin
```

确认文件存在：

```powershell
Get-Item `
  .\conv_test_iram.bin, `
  .\conv_test_dram.bin
```

## 8. Windows 使用 COM4 下载

如果尚未安装 PySerial：

```powershell
py -m pip install pyserial
```

进入包含 `peqflash.py` 的工程目录：

```powershell
Set-Location E:\sb\rsicv\5pipeline
```

使用 COM4、115200 波特率下载 IMEM 和 DMEM，并在下载完成后启动 CPU：

```powershell
py E:\sb\rsicv\5pipeline\peqflash.py `
  -serport COM4 `
  -baud 115200 `
  -imembin E:\sb\rsicv\5pipeline\conv_test_iram.bin `
  -dmembin E:\sb\rsicv\5pipeline\conv_test_dram.bin
```

下载脚本应依次报告设备签名正确、IMEM 下载成功、DMEM 下载成功和 CPU boot 成功。

当前 `peqflash.py` 在 CPU boot 后会关闭 COM4。下载脚本退出后，可用下面的命令重新打开串口观察测试输出：

```powershell
py -m serial.tools.miniterm COM4 115200
```

如果打开终端太晚而漏掉开头输出，需要重新复位 CPU，或者以后在 `peqflash.py` 中加入 boot 后持续读取串口的监视模式。

## 9. Loader 阶段实际写入的内容

Loader 需要下载：

- `conv_test_iram.bin`：测试程序的机器指令；
- `conv_test_dram.bin`：UART 字符串、十进制表、十六进制表以及其他 `.data/.rodata` 内容。

Loader 暂时不需要下载真实 LeNet 图片、权重或 bias。`conv_test.c` 把测试输入、测试权重、测试 bias 和输出缓冲区放在 `.bss`，CPU 启动后会自行填充它们，再由 DMA 从 DDR 搬到共享 BRAM。
