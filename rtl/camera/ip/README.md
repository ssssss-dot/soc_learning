# OV5645 RGB565 接收 IP

本目录的 IP 匹配当前 `../config/configuration_rom.sv`，使用 Vivado 2022.2 / MIPI CSI-2 RX Subsystem v5.2，器件为 `xczu5ev-sfvc784-2-e`。

| 项目 | 配置 |
| --- | --- |
| 摄像头 | OV5645，128×128 |
| 像素格式 | RGB565；启用 Video Format Bridge |
| 数据 lane | 2 |
| 每条 lane 速率 | 448 Mb/s，按原 ROM 基表指定的速率 |
| 每拍像素 | 1 |
| 视频输出 | TDATA 16 位，TDEST 10 位，TUSER 1 位 |
| 行缓冲 | 2048 |
| CSI-2 AXI-Lite 寄存器接口 | 关闭，固定配置 |
| D-PHY 寄存器接口 | 关闭 |
| 动态 lane 配置 | 关闭；最大 lane 数为 2，端口固定 `active_lanes=2'b01` |
| 接收使能 | 内部连接 `ctrl_core_en=1'b1` |
| 视频时钟 | 本次按 100 MHz 配置；实际时钟仍需顶层提供 |
| D-PHY 参考时钟 | 200 MHz |

ROM 的 XCLK 为 24 MHz，PLL 寄存器为 `3037=13、3036=70、3035=21`。原始配置表明确标注 448 Mb/s/lane；缩小输出尺寸不会自动降低该串行速率。对应差分时钟约 224 MHz，字节时钟约 56 MHz。硬件仍需核对实际 XCLK 和接收状态。

两条 lane 的 RGB565 峰值像素速率为 `448×2/16=56 Mpixel/s`，100 MHz、1 pixel/clock 满足接收核输出带宽要求；这不代表后级缩放器已经验证能接收任意突发。

## 文件和使用

- `create_mipi_rgb565.tcl`：可重复使用的 IP 生成脚本。
- `mipi_csi2_rx_subsystem_0/mipi_csi2_rx_subsystem_0.xci`：本次实际生成的配置，供 Vivado 导入。
- `mipi_csi2_rx_subsystem_0/mipi_csi2_rx_subsystem_0.veo`：同一次生成的例化模板。

在现有 Vivado 工程通过 Add Sources → Add or create design sources 加入上述 `.xci`，再 Generate Output Products。工程内只保留一个同名 `mipi_csi2_rx_subsystem_0`，使用此无 AXI-Lite 的 RGB565 版本替换之前的 RAW10 或带 AXI-Lite 版本。端口集合发生变化，不能继续使用旧例化模板。

也可以单独生成：

```powershell
vivado -mode batch -source create_mipi_rgb565.tcl
```

默认输出到脚本旁的 `generated/`。可通过 `MIPI_OUTPUT_DIR` 指定其他目录；脚本也可在打开的匹配器件工程中 `source`。为避免覆盖已有工程/IP，重复生成前应选择新的输出目录或手动管理原工程。

引脚沿用已核对的 P5B 参考设计：bank65，时钟 P/N 为 W8/Y8，lane0 P/N 为 R8/T8，lane1 P/N 为 U8/V8。脚本选择各对 P 端，由 IP 生成差分及 D-PHY 约束；顶层 MIPI 引脚仍需连接。

## 内部固定配置

本次关闭 `CSI_CONTROLLER_REG_IF` 和 `DPY_EN_REG_IF`。RGB565、lane 数、速率、VFB 和缓冲深度在生成 IP 时固定，不需要 CPU 或配置状态机写接收核寄存器。

`video_process_top` 内部直接连接：

```verilog
.ctrl_core_en(1'b1),
.active_lanes(2'b01), // 编码为lane数减1，01表示两条lane
```

`C_CSI_EN_ACTIVELANES=false`，接收核使用生成时确定的两条 lane；生成模板仍引出了 `active_lanes`，此处同样提供匹配的常量。固定配置后，接收核只需要正确的物理输入、200 MHz 参考时钟、视频时钟和视频复位，即可按既定模式接收；仍需满足 MIPI LP-11 初始化条件。

本系统的摄像头配置和像素通路为：

```text
ROM → CTRL → I2C → 摄像头内部寄存器
摄像头 → 固定配置的 MIPI 接收核 → AXI-Stream → 像素处理
```

摄像头芯片本身仍须通过现有 ROM → CTRL → I2C 配置；关闭 FPGA 接收核的 AXI-Lite 不会替代这部分。

当前顶层已删除 `mipi_cfg_*` 和 IP 不再提供的 `mipi_irq`，例化中也没有 `lite_aclk/lite_aresetn/csirxss_s_axi_*`。现有 `clk/rst_n` 继续供 DDR 写端等模块使用，并未删除。

接收核提供了下列替代状态输出，但本次没有使用方，因此在例化中留空：`ctrl_dis_in_prgs`、`errsotsynchs_intr`、`errsoths_intr`、`cl_stopstate_intr`、`dl0_stopstate_intr`、`dl1_stopstate_intr`、`crc_status_intr`、`ecc_status_intr`、`linebuffer_full`、`frame_rcvd_pulse_out`。需要 ILA 调试或错误处理时，可单独连接这些输出；本次未添加聚合中断或错误恢复逻辑。

现有 `camera_req_*` MMIO 和 `camera_irq` 仍用于 `axis2axiw` 的 DDR 写完成/错误状态，与 MIPI 接收核的 AXI-Lite 无关，保持原连接。

## 接口和验证边界

本次生成的 `.veo` 与当前 `video_process_top` 的 MIPI 例化端口和位宽一致。`TUSER[0]` 标记首像素，`TLAST` 标记行末；RGB565 在 VFB 输出上的分量排列应以该版本文档和颜色测试核对，不能仅凭 16 位宽假定直接等于旧 DVP 拼接值。

已完成 Vivado IP 输出产品生成、模板端口核对和视频顶层语法/例化检查（使用按新模板生成的接口 stub）；未进行真实摄像头接收仿真、整机综合布局布线或上板验证。Vivado 2022.2 对其内部 AXIS broadcaster 生成了 12 条总线参数元数据位宽告警，无 ERROR / CRITICAL WARNING；外部视频端口生成值为 16/10/1 位。

当前 MIPI 输出仍仅引出到顶层端口，尚未接灰度模块；旧 DVP 数据通路、SoC 接线和采集控制逻辑本次没有修改。

依据：

- [Espressif 原始 RGB565 配置表（含 448 Mb/s/lane 注释）](https://github.com/espressif/esp-video-components/blob/master/esp_cam_sensor/sensors/ov5645/private_include/ov5645_mipi_2lane_24Minput_1280x960_rgb565_le_30fps.h)
- [AMD PG232 配置项](https://docs.amd.com/r/5.1-English/pg232-mipi-csi2-rx/Configuration-Tab)
- [AMD PG232 接收核默认启用与编程顺序](https://docs.amd.com/r/5.1-English/pg232-mipi-csi2-rx/MIPI-CSI-2-RX-Controller-Core-Programming?contentId=BeTTK3MmERtWeXq~C5E6SA)
- [AMD PG232 视频时钟计算](https://docs.amd.com/r/5.1-English/pg232-mipi-csi2-rx/video_aclk-calculation?contentId=VU9k3LZrbspyNpgidukuTQ)
