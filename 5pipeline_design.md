# 从带访存单周期 CPU 到 5 级流水线 CPU

这份文档给后续 `5pipeline` 目录的实现做路线说明。

建议不要一开始就直接写 5 级流水线。更稳的路线是：

```text
第一步：先用 IF/ID/EX/MEM/WB 这 5 个 stage 模块搭出“带访存的单周期 CPU”
第二步：在这 5 个 stage 之间插入 4 组流水寄存器
第三步：补 forwarding / stall / flush，形成真正可运行的 5 级流水线 CPU
```

这样做的好处是：单周期 CPU 没有数据冒险和控制冒险，但模块边界已经按流水线的 5 个 stage 划好。先把指令译码、ALU、load/store、写回通路跑通；之后切流水线时，只是在正确的 stage 之间加时序边界。

## 目录建议

单周期阶段也建议直接使用 5 个 stage 模块，只是不插流水寄存器、不启用 hazard：

```text
5pipeline/
  define.v
  cpu_top.v

  if_stage.v
  id_stage.v
  ex_stage.v
  mem_stage.v
  wb_stage.v

  inst_mem.v
  data_mem.v
  reg_file.v
  tb.sv
```

5 级流水线阶段在上面基础上新增：

```text
5pipeline/
  if_id_reg.v
  id_ex_reg.v
  ex_mem_reg.v
  mem_wb_reg.v

  hazard_unit.v        // 推荐单独写，也可以先合进 id/ex stage
```

# Part 1：先实现带访存的单周期 CPU

## 1. 单周期总体数据通路

带访存单周期 CPU 的一条指令在一个周期内走完：

```text
PC
  -> inst_mem
  -> ctrl_id / imm_gen
  -> reg_file read
  -> ALU
  -> data_mem
  -> wb_mux
  -> reg_file write
```

PC 更新通路：

```text
pc + 4
pc + imm       // branch / jal
rs1 + imm      // jalr
```

单周期版顶层也按 5 个 stage 分模块：

```text
cpu_top
  if_stage
  id_stage
  ex_stage
  mem_stage
  wb_stage
```

注意：这里的“单周期”只是 stage 之间没有流水寄存器。一条指令仍然在一个周期内从 IF 组合走到 WB；`if_stage` 内部保存 PC，其余 stage 尽量保持组合逻辑或普通存储器访问逻辑。

## 2. define.v

### 功能

保存全局宏定义。

已有内容可以继续保留：

```text
1. 数据宽度
2. 寄存器地址宽度
3. opcode
4. funct3
5. funct7
6. ALU op
7. ALU 输入选择
```

建议新增：

```verilog
`define WbSelBus 1:0
`define WB_SEL_ALU  2'b00
`define WB_SEL_MEM  2'b01
`define WB_SEL_PC4  2'b10
`define WB_SEL_NONE 2'b11

`define MemOpBus 2:0
`define MEM_NONE 3'b000
`define MEM_LB   3'b001
`define MEM_LH   3'b010
`define MEM_LW   3'b011
`define MEM_LBU  3'b100
`define MEM_LHU  3'b101
`define MEM_SB   3'b110
`define MEM_SH   3'b111
```

如果第一版只做 `lw/sw`，可以先简化：

```verilog
`define MemOpBus 1:0
`define MEM_NONE 2'b00
`define MEM_LW   2'b01
`define MEM_SW   2'b10
```

建议加 NOP：

```verilog
`define NOP_INST 32'h00000013  // addi x0, x0, 0
```

## 3. pc_reg.v

### 功能

保存当前 PC。

### 建议端口

```verilog
module pc_reg(
    input  wire             clk,
    input  wire             rst_n,
    input  wire [`RegBus]   next_pc_i,
    output reg  [`RegBus]   pc_o
);
```

### 实现行为

```text
reset:
  pc_o = 0

normal:
  pc_o = next_pc_i
```

单周期阶段暂时不需要 `stall`，后面流水线 IF 阶段再加。

### simple 代码复用

当前 `rtl/pc_reg.v` 的 PC 寄存器逻辑可以复用到 `if_stage` 里。`ce` 信号可以保留，也可以先简化成 `stall_i`。

## 4. inst_mem.v

### 功能

根据 PC 读取指令。

### 建议端口

```verilog
module inst_mem(
    input  wire [`RegBus]   pc_i,
    output reg  [`InstBus]  inst_o
);
```

### 实现要点

```text
1. 使用 $readmemh 加载 inst.data
2. 指令地址用 pc_i[InstMemNumLog2+1:2]
3. 因为 RISC-V 指令 4 字节对齐，所以低 2 位不用
```

### simple 代码复用

当前 `rtl/inst_mem.v` 可以复用到 `if_stage` 里。

建议把路径改得更稳定，例如：

```verilog
$readmemh("inst.data", inst_mem);
```

或者用 plusarg：

```verilog
if (!$value$plusargs("INST=%s", inst_file)) begin
    inst_file = "inst.data";
end
$readmemh(inst_file, inst_mem);
```

## 5. ctrl_id.v

### 功能

译码模块。单周期和流水线都很依赖它。

### 输入

```verilog
input wire [`InstBus] inst_i
```

### 建议输出

```verilog
output wire [`RegAddrBus] rs1_o,
output wire [`RegAddrBus] rs2_o,
output wire [`RegAddrBus] rd_o,
output reg  [`RegBus]     imm_o,

output reg                re1_o,
output reg                re2_o,
output reg                reg_we_o,

output reg                mem_re_o,
output reg                mem_we_o,
output reg [`MemOpBus]    mem_op_o,
output reg [`WbSelBus]    wb_sel_o,

output reg                branch_flag_o,
output reg                jump_flag_o,
output reg                jalr_flag_o,

output reg [`AluOpBus]    aluop_o,
output reg [`AluSrc1SelBus] alu_src1_sel_o,
output reg [`AluSrc2SelBus] alu_src2_sel_o
```

### 需要译码的控制信号

```text
re1_o / re2_o:
  当前指令是否需要读 rs1/rs2

reg_we_o:
  是否写 rd

mem_re_o:
  load 指令读 data memory

mem_we_o:
  store 指令写 data memory

mem_op_o:
  区分 lb/lh/lw/lbu/lhu/sb/sh/sw

wb_sel_o:
  WB_SEL_ALU: ALU 结果写回
  WB_SEL_MEM: data memory 读出的数据写回
  WB_SEL_PC4: jal/jalr 写回 pc+4
  WB_SEL_NONE: 不写回

branch_flag_o:
  beq/bne/blt/bge/bltu/bgeu

jump_flag_o:
  jal

jalr_flag_o:
  jalr

aluop_o:
  ALU 运算或 branch 比较类型
```

### simple 代码复用

当前 `rtl/ctrl_id.v` 可以作为 `id_stage` 的核心基础。

可直接复用：

```text
1. opcode/funct3/funct7 字段切分
2. rs1/rs2/rd 字段切分
3. I/S/B/U/J 立即数生成
4. lui/jal/bne/add/addi 的控制信号
```

需要补充：

```text
1. load/store 控制信号
2. wb_sel_o
3. mem_op_o
4. jalr_flag_o
5. beq/blt/bge/bltu/bgeu
6. sub/and/or/xor/sll/srl/sra/slt/sltu
7. andi/ori/xori/slli/srli/srai/slti/sltiu
8. auipc
```

## 6. reg_file.v

### 功能

32 个通用寄存器，两个读端口，一个写端口。

### 建议端口

```verilog
module reg_file(
    input  wire              clk,
    input  wire              rst_n,

    input  wire              we_i,
    input  wire [`RegAddrBus] waddr_i,
    input  wire [`RegBus]    wdata_i,

    input  wire              re1_i,
    input  wire [`RegAddrBus] raddr1_i,
    output reg  [`RegBus]    rdata1_o,

    input  wire              re2_i,
    input  wire [`RegAddrBus] raddr2_i,
    output reg  [`RegBus]    rdata2_o
);
```

### 实现要点

```text
1. x0 恒为 0
2. 写寄存器在时钟上升沿
3. 读寄存器可以做组合读
4. 同周期写读同一个寄存器时，建议读出 wdata_i
```

推荐加入写读旁路：

```verilog
if (re1_i && we_i && (waddr_i != `NOPRegAddr) && (waddr_i == raddr1_i)) begin
    rdata1_o = wdata_i;
end else if (re1_i) begin
    rdata1_o = regs[raddr1_i];
end else begin
    rdata1_o = `ZeroWord;
end
```

`rdata2_o` 同理。

### simple 代码复用

当前 `rtl/reg_file.v` 可以复用到 `id_stage` 里。建议把组合读 always 里的非阻塞赋值 `<=` 改成阻塞赋值 `=`，更符合组合逻辑写法。

## 7. alu.v

### 功能

执行算术、逻辑、移位和比较。

建议把当前 `mux_alu.v` 拆得更清楚：

```text
alu_src 选择 + alu 运算
```

也可以先继续用一个模块。

### 建议端口

```verilog
module alu(
    input  wire [`RegBus]    pc_i,
    input  wire [`RegBus]    rs1_data_i,
    input  wire [`RegBus]    rs2_data_i,
    input  wire [`RegBus]    imm_i,

    input  wire [`AluSrc1SelBus] alu_src1_sel_i,
    input  wire [`AluSrc2SelBus] alu_src2_sel_i,
    input  wire [`AluOpBus]      aluop_i,

    output reg  [`RegBus]    result_o,
    output reg               branch_taken_o
);
```

### ALU 输入选择

```text
src1:
  ALU_SRC1_RS1  -> rs1_data
  ALU_SRC1_PC   -> pc
  ALU_SRC1_ZERO -> 0

src2:
  ALU_SRC2_RS2  -> rs2_data
  ALU_SRC2_IMM  -> imm
  ALU_SRC2_FOUR -> 4
```

### branch 判断

建议不要只输出 `zero_o`，而是直接输出 `branch_taken_o`：

```text
BEQ : rs1 == rs2
BNE : rs1 != rs2
BLT : signed(rs1) < signed(rs2)
BGE : signed(rs1) >= signed(rs2)
BLTU: rs1 < rs2
BGEU: rs1 >= rs2
```

### simple 代码复用

当前 `rtl/mux_alu.v` 可以复用到 `ex_stage` 里：

```text
1. src1/src2 选择
2. ADD 运算
3. BNE 比较思路
4. JAL 目标地址计算思路
```

需要补全更多 `aluop`。

## 8. data_mem.v

### 功能

数据存储器，支持 load/store。

第一版建议先实现：

```text
lw
sw
```

之后再扩展：

```text
lb/lh/lbu/lhu
sb/sh
```

### 简化版端口

只支持 `lw/sw` 时：

```verilog
module data_mem(
    input  wire              clk,
    input  wire              rst_n,

    input  wire              mem_re_i,
    input  wire              mem_we_i,
    input  wire [`RegBus]    addr_i,
    input  wire [`RegBus]    wdata_i,

    output reg  [`RegBus]    rdata_o
);
```

### 完整版端口

支持字节/半字访问时：

```verilog
module data_mem(
    input  wire              clk,
    input  wire              rst_n,

    input  wire              mem_re_i,
    input  wire              mem_we_i,
    input  wire [`MemOpBus]  mem_op_i,
    input  wire [`RegBus]    addr_i,
    input  wire [`RegBus]    wdata_i,

    output reg  [`RegBus]    rdata_o
);
```

### 实现要点

```text
1. addr_i 来自 ALU result
2. store 写入的数据来自 rs2_data
3. load 读出的数据送到 wb_mux
4. sw/lw 使用 word 对齐地址 addr_i[DataMemNumLog2+1:2]
```

## 9. wb_mux.v

### 功能

选择最终写回寄存器的数据。

### 建议端口

```verilog
module wb_mux(
    input  wire [`RegBus]   alu_result_i,
    input  wire [`RegBus]   mem_data_i,
    input  wire [`RegBus]   pc_plus4_i,
    input  wire [`WbSelBus] wb_sel_i,
    output reg  [`RegBus]   wb_data_o
);
```

### 选择逻辑

```text
WB_SEL_ALU:
  add/addi/lui/auipc 等写 ALU result

WB_SEL_MEM:
  load 指令写 data memory 读出数据

WB_SEL_PC4:
  jal/jalr 写 pc + 4

WB_SEL_NONE:
  默认 0，不写回
```

## 10. mux_pc.v

### 功能

选择下一条 PC。

### 建议端口

```verilog
module mux_pc(
    input  wire [`RegBus] pc_i,
    input  wire [`RegBus] imm_i,
    input  wire [`RegBus] rs1_data_i,

    input  wire           branch_flag_i,
    input  wire           branch_taken_i,
    input  wire           jump_flag_i,
    input  wire           jalr_flag_i,

    output reg  [`RegBus] next_pc_o
);
```

### 选择逻辑

```text
jalr:
  next_pc = (rs1_data + imm) & 32'hffff_fffe

jal:
  next_pc = pc + imm

branch && branch_taken:
  next_pc = pc + imm

default:
  next_pc = pc + 4
```

### simple 代码复用

当前 `rtl/mux_pc.v` 的思想可以复用，但建议拆成两部分：`ex_stage` 负责算 redirect 条件和目标 PC，`if_stage` 负责选择下一拍 PC。同时需要补 `jalr`，并且 branch 不应该只写死成 `bne` 的 `~zero`。

## 11. 单周期 cpu_top.v 连接

单周期顶层按 5 个 stage 直接串起来，中间不放流水寄存器：

```text
if_stage.pc_o       -> id_stage.pc_i
if_stage.pc_plus4_o -> id_stage.pc_plus4_i
if_stage.inst_o     -> id_stage.inst_i

id_stage.pc_o       -> ex_stage.pc_i
id_stage.pc_plus4_o -> ex_stage.pc_plus4_i
id_stage.rs1/rs2/rd -> ex_stage.rs1/rs2/rd
id_stage.rs1_data   -> ex_stage.rs1_data_i
id_stage.rs2_data   -> ex_stage.rs2_data_i
id_stage.imm        -> ex_stage.imm_i
id_stage.control    -> ex_stage.control_i

ex_stage.alu_result -> mem_stage.alu_result_i
ex_stage.store_data -> mem_stage.store_data_i
ex_stage.pc_plus4   -> mem_stage.pc_plus4_i
ex_stage.rd/control -> mem_stage.rd/control_i

mem_stage.mem_data   -> wb_stage.mem_data_i
mem_stage.alu_result -> wb_stage.alu_result_i
mem_stage.pc_plus4   -> wb_stage.pc_plus4_i
mem_stage.rd/control -> wb_stage.rd/control_i

wb_stage.wb_reg_we/wb_rd/wb_data
  -> id_stage 写回端口

ex_stage.redirect/redirect_pc
  -> if_stage redirect 输入
```

单周期阶段可以把 `valid_i` 固定为 1，把 forwarding 输入接 0，把 `stall_i` 固定为 0。由于没有流水重叠，暂时不需要 IF/ID、ID/EX、EX/MEM、MEM/WB 寄存器，也不需要 hazard_unit。

## 12. 单周期最小实现顺序

建议按这个顺序写：

```text
1. 先搭好 5 个 stage 的空壳和 cpu_top 直连：
   if_stage/id_stage/ex_stage/mem_stage/wb_stage

2. 先跑通无访存：
   lui/addi/add/bne/jal

3. 在 wb_stage 里接 wb_mux：
   把 jal 写回 pc+4、普通指令写回 alu_result 统一管理

4. 在 mem_stage 里接 data_mem：
   先支持 lw/sw

5. 修改 id_stage/ctrl_id：
   增加 mem_re/mem_we/mem_op/wb_sel

6. 修改 ex_stage 的跳转目标计算：
   支持 jalr 和更多 branch

7. 补全更多 ALU 指令和 branch 指令
```

先完成带访存单周期后，CPU 已经有完整数据通路：

```text
取指 -> 译码 -> 执行 -> 访存 -> 写回
```

这正好对应后面的 5 级流水线。

# Part 2：在单周期基础上实现 5 级流水线

## 13. 从单周期切流水线的核心思路

单周期 CPU 已经用 5 个 stage 模块实现了完整数据通路：

```text
IF -> ID -> EX -> MEM -> WB
```

5 级流水线不是重写一套逻辑，而是在 stage 之间插入流水寄存器：

```text
IF:
  pc_reg + inst_mem + pc_plus4

IF/ID:
  保存 pc / pc_plus4 / inst

ID:
  ctrl_id + reg_file read

ID/EX:
  保存译码结果、寄存器数据、立即数、控制信号

EX:
  alu + branch/jump target + forwarding mux

EX/MEM:
  保存 alu_result、store_data、rd、MEM/WB 控制信号

MEM:
  data_mem

MEM/WB:
  保存 mem_data、alu_result、pc_plus4、rd、WB 控制信号

WB:
  wb_mux
```

## 14. 5 个 stage 模块

## if_stage.v

### 来源

从单周期的这些模块来：

```text
pc_reg.v
inst_mem.v
pc + 4 加法器
mux_pc 的 redirect 选择部分
```

### 功能

```text
1. 保存/更新 PC
2. 读取 instruction memory
3. 计算 pc_plus4
4. 接收 EX 阶段 redirect_pc
5. 支持 stall_pc
```

### 建议端口

```verilog
module if_stage(
    input  wire            clk,
    input  wire            rst_n,
    input  wire            stall_i,

    input  wire            redirect_i,
    input  wire [`RegBus]  redirect_pc_i,

    output wire [`RegBus]  pc_o,
    output wire [`RegBus]  pc_plus4_o,
    output wire [`InstBus] inst_o
);
```

流水线中 IF 不再自己判断 branch 条件，只接收 EX 给出的 `redirect_i/redirect_pc_i`。

## id_stage.v

### 来源

从单周期的这些模块来：

```text
ctrl_id.v
reg_file.v
imm_gen
```

### 功能

```text
1. 译码
2. 生成立即数
3. 读寄存器
4. 产生控制信号
5. 接收 WB 阶段写回
6. 可以放 load-use hazard 检测
```

### 建议端口

```verilog
module id_stage(
    input  wire              clk,
    input  wire              rst_n,

    input  wire [`RegBus]    pc_i,
    input  wire [`RegBus]    pc_plus4_i,
    input  wire [`InstBus]   inst_i,
    input  wire              valid_i,

    input  wire              wb_reg_we_i,
    input  wire [`RegAddrBus] wb_rd_i,
    input  wire [`RegBus]    wb_data_i,

    output wire [`RegBus]    pc_o,
    output wire [`RegBus]    pc_plus4_o,
    output wire [`RegAddrBus] rs1_addr_o,
    output wire [`RegAddrBus] rs2_addr_o,
    output wire [`RegAddrBus] rd_addr_o,
    output wire [`RegBus]    rs1_data_o,
    output wire [`RegBus]    rs2_data_o,
    output wire [`RegBus]    imm_o,

    output wire              reg_we_o,
    output wire              mem_re_o,
    output wire              mem_we_o,
    output wire [`MemOpBus]  mem_op_o,
    output wire [`WbSelBus]  wb_sel_o,
    output wire              branch_flag_o,
    output wire              jump_flag_o,
    output wire              jalr_flag_o,
    output wire [`AluOpBus]  aluop_o,
    output wire [`AluSrc1SelBus] alu_src1_sel_o,
    output wire [`AluSrc2SelBus] alu_src2_sel_o,
    output wire              valid_o
);
```

## ex_stage.v

### 来源

从单周期的这些模块来：

```text
alu.v
mux_pc 中 pc+imm / jalr target 的计算
branch 判断逻辑
```

### 功能

```text
1. forwarding 选择 rs1/rs2 最新值
2. ALU 运算
3. branch 条件判断
4. 计算 branch/jal/jalr 目标地址
5. 输出 redirect 给 if_stage
6. 输出 store_data 给 mem_stage
```

### 建议端口

```verilog
module ex_stage(
    input  wire [`RegBus]    pc_i,
    input  wire [`RegBus]    pc_plus4_i,
    input  wire [`RegAddrBus] rs1_addr_i,
    input  wire [`RegAddrBus] rs2_addr_i,
    input  wire [`RegAddrBus] rd_addr_i,
    input  wire [`RegBus]    rs1_data_i,
    input  wire [`RegBus]    rs2_data_i,
    input  wire [`RegBus]    imm_i,

    input  wire              reg_we_i,
    input  wire              mem_re_i,
    input  wire              mem_we_i,
    input  wire [`MemOpBus]  mem_op_i,
    input  wire [`WbSelBus]  wb_sel_i,
    input  wire              branch_flag_i,
    input  wire              jump_flag_i,
    input  wire              jalr_flag_i,
    input  wire [`AluOpBus]  aluop_i,
    input  wire [`AluSrc1SelBus] alu_src1_sel_i,
    input  wire [`AluSrc2SelBus] alu_src2_sel_i,
    input  wire              valid_i,

    input  wire              ex_mem_reg_we_i,
    input  wire [`RegAddrBus] ex_mem_rd_i,
    input  wire [`RegBus]    ex_mem_wb_data_i,

    input  wire              mem_wb_reg_we_i,
    input  wire [`RegAddrBus] mem_wb_rd_i,
    input  wire [`RegBus]    mem_wb_wb_data_i,

    output wire [`RegBus]    alu_result_o,
    output wire [`RegBus]    store_data_o,
    output wire [`RegBus]    pc_plus4_o,
    output wire [`RegAddrBus] rd_addr_o,
    output wire              reg_we_o,
    output wire              mem_re_o,
    output wire              mem_we_o,
    output wire [`MemOpBus]  mem_op_o,
    output wire [`WbSelBus]  wb_sel_o,
    output wire              valid_o,

    output wire              redirect_o,
    output wire [`RegBus]    redirect_pc_o
);
```

## mem_stage.v

### 来源

从单周期的 `data_mem.v` 来。

### 功能

```text
1. load 读数据存储器
2. store 写数据存储器
3. load 数据扩展
4. 透传 alu_result / pc_plus4 / rd / wb 控制信号
```

### 建议端口

```verilog
module mem_stage(
    input  wire              clk,
    input  wire              rst_n,

    input  wire [`RegBus]    alu_result_i,
    input  wire [`RegBus]    store_data_i,
    input  wire [`RegBus]    pc_plus4_i,
    input  wire [`RegAddrBus] rd_addr_i,
    input  wire              reg_we_i,
    input  wire              mem_re_i,
    input  wire              mem_we_i,
    input  wire [`MemOpBus]  mem_op_i,
    input  wire [`WbSelBus]  wb_sel_i,
    input  wire              valid_i,

    output wire [`RegBus]    mem_data_o,
    output wire [`RegBus]    alu_result_o,
    output wire [`RegBus]    pc_plus4_o,
    output wire [`RegAddrBus] rd_addr_o,
    output wire              reg_we_o,
    output wire [`WbSelBus]  wb_sel_o,
    output wire              valid_o
);
```

## wb_stage.v

### 来源

从单周期的 `wb_mux.v` 来。

### 功能

```text
1. 根据 wb_sel 选择写回数据
2. 输出 wb_reg_we / wb_rd / wb_data
3. 将写回信号反馈给 id_stage 的 reg_file
```

### 建议端口

```verilog
module wb_stage(
    input  wire [`RegBus]     mem_data_i,
    input  wire [`RegBus]     alu_result_i,
    input  wire [`RegBus]     pc_plus4_i,
    input  wire [`RegAddrBus] rd_addr_i,
    input  wire               reg_we_i,
    input  wire [`WbSelBus]   wb_sel_i,
    input  wire               valid_i,

    output wire               wb_reg_we_o,
    output wire [`RegAddrBus] wb_rd_addr_o,
    output reg  [`RegBus]     wb_data_o
);
```

## 15. 4 个流水寄存器模块

## if_id_reg.v

保存：

```text
pc
pc_plus4
inst
valid
```

控制：

```text
stall_i:
  保持原值

flush_i:
  写入 NOP，valid = 0
```

## id_ex_reg.v

保存：

```text
pc
pc_plus4
rs1_addr
rs2_addr
rd_addr
rs1_data
rs2_data
imm
reg_we
mem_re
mem_we
mem_op
wb_sel
branch_flag
jump_flag
jalr_flag
aluop
alu_src1_sel
alu_src2_sel
valid
```

当 `flush_i` 有效时，插入 NOP：

```text
reg_we = 0
mem_re = 0
mem_we = 0
branch_flag = 0
jump_flag = 0
jalr_flag = 0
aluop = EX_NOP_OP
rd = x0
valid = 0
```

## ex_mem_reg.v

保存：

```text
alu_result
store_data
pc_plus4
rd_addr
reg_we
mem_re
mem_we
mem_op
wb_sel
valid
```

## mem_wb_reg.v

保存：

```text
mem_data
alu_result
pc_plus4
rd_addr
reg_we
wb_sel
valid
```

## 16. 流水线新增的 hazard 处理

单周期 CPU 不需要 hazard，因为一条指令一个周期完成。

流水线 CPU 必须处理：

```text
1. 数据相关：forwarding
2. load-use：stall
3. branch/jump：flush
```

## forwarding

解决 ALU 指令之间的数据相关：

```asm
addi x1, x0, 5
add  x2, x1, x1
```

EX 阶段需要比较：

```text
id_ex.rs1 / id_ex.rs2
ex_mem.rd
mem_wb.rd
```

规则：

```text
如果 ex_mem_reg_we && ex_mem_rd != x0 && ex_mem_rd == id_ex_rs1:
  rs1 使用 ex_mem_wb_data

如果 mem_wb_reg_we && mem_wb_rd != x0 && mem_wb_rd == id_ex_rs1:
  rs1 使用 mem_wb_wb_data

rs2 同理
```

## load-use stall

解决：

```asm
lw  x1, 0(x2)
add x3, x1, x4
```

因为 `lw` 的数据到 MEM 阶段才出来，下一条指令 EX 阶段来不及用 forwarding。

检测：

```text
如果 ID/EX 是 load:
  id_ex_mem_re == 1

并且 IF/ID 当前指令使用这个 rd:
  id_ex_rd == if_id_rs1 或 id_ex_rd == if_id_rs2
```

处理：

```text
stall_pc = 1
stall_if_id = 1
flush_id_ex = 1
```

含义：

```text
PC 保持
IF/ID 保持
ID/EX 插入 NOP
```

## branch/jump flush

如果 branch/jump 在 EX 阶段决定：

```text
EX 输出 redirect_o = 1
IF 使用 redirect_pc_i 更新 PC
IF/ID flush
ID/EX flush
```

这样可以清掉错误路径上已经取到/译码的指令。

## 17. 从 simple 项目复用代码的对应关系

```text
rtl/define.v
  -> 复制到 5pipeline/define.v
  -> 从单周期阶段开始补 wb_sel/mem_op/valid/nop

rtl/pc_reg.v
  -> 单周期阶段就合入 if_stage
  -> 流水线阶段打开 stall/redirect

rtl/inst_mem.v
  -> 单周期阶段就放进 if_stage

rtl/ctrl_id.v
  -> 单周期阶段就在 id_stage 里扩展成完整译码

rtl/reg_file.v
  -> 单周期阶段就放进 id_stage，建议加写读旁路
  -> 流水线阶段继续由 WB 写回反馈到 ID

rtl/mux_alu.v
  -> 单周期阶段就在 ex_stage 里改造成 alu.v
  -> 流水线阶段在 ex_stage 前面加 forwarding mux

rtl/mux_pc.v
  -> 单周期阶段就拆成 ex_stage 的 redirect 计算 + if_stage 的 PC 选择
  -> 同时补 jalr/branch 类型

rtl/cpu_top.v
  -> 单周期阶段负责直连 5 个 stage
  -> 流水线阶段在 stage 之间插入 4 个流水寄存器

rtl/tb.sv
  -> 修正端口后继续作为仿真入口
```

## 18. 推荐最终实现顺序

## 阶段 A：带访存单周期 CPU

```text
1. 整理 define.v
2. 新建 if_stage/id_stage/ex_stage/mem_stage/wb_stage
3. 把 pc_reg/inst_mem 放进 if_stage
4. 把 ctrl_id/reg_file 放进 id_stage
5. 把 mux_alu 改造成 alu.v，并放进 ex_stage
6. 把 data_mem 放进 mem_stage
7. 把 wb_mux 放进 wb_stage
8. 在 cpu_top 里直连 5 个 stage，不插流水寄存器
9. 修正 tb.sv
10. 先跑通 lui/addi/add/bne/jal
11. 再跑通 lw/sw
```

## 阶段 B：切成 5 级流水线骨架

```text
1. 新建 if_id_reg/id_ex_reg/ex_mem_reg/mem_wb_reg
2. 把 4 个流水寄存器插到 5 个 stage 之间
3. cpu_top 只负责连线和 hazard 控制信号分发
4. 暂时用 NOP 程序验证流水线推进
```

## 阶段 C：补 hazard

```text
1. 加 EX/MEM -> EX forwarding
2. 加 MEM/WB -> EX forwarding
3. 加 branch/jump flush
4. 加 load-use stall
5. 用无 NOP 的程序验证结果
```

## 阶段 D：扩展 RV32I 指令

建议顺序：

```text
1. add/sub/addi/lui/auipc
2. and/or/xor/andi/ori/xori
3. sll/srl/sra/slli/srli/srai
4. slt/sltu/slti/sltiu
5. beq/bne/blt/bge/bltu/bgeu
6. jal/jalr
7. lw/sw
8. lb/lh/lbu/lhu/sb/sh
```

## 19. 最小可验证目标

### 单周期最小目标

```text
支持指令:
  lui
  addi
  add
  bne
  jal
  lw
  sw

不要求:
  hazard
  forwarding
  stall
  flush
```

### 5 级流水线最小目标

```text
支持指令:
  lui
  addi
  add
  bne
  jal
  lw
  sw

必须支持:
  EX/MEM -> EX forwarding
  MEM/WB -> EX forwarding
  branch/jump flush
  load-use stall
```

## 20. 关键理解

单周期 CPU 阶段就使用功能完整的 5 个 stage 模块：

```text
取指、译码、执行、访存、写回
```

5 级流水线 CPU 不是换一套功能模块，而是在这 5 个 stage 之间插入流水寄存器：

```text
IF  = 单周期的 PC + inst_mem
ID  = 单周期的 ctrl_id + reg_file read
EX  = 单周期的 alu + branch/jump target
MEM = 单周期的 data_mem
WB  = 单周期的 wb_mux
```

所以最推荐的实现路线是：

```text
先用 5 个 stage 跑通单周期带访存版本
再插流水寄存器
最后处理 hazard
```
