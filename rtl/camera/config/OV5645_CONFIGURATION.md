# OV5645 ROM：128×128 RGB565 / MIPI CSI-2

当前 `configuration_rom.sv` 为 OV5645 配置表，接口保持不变。

## 配置前提与输出

- 传感器输入时钟 XCLK：24 MHz；不是 FPGA 的 CTRL/I2C 工作时钟。
- 输出：128×128、RGB565 高字节在前（0x4300=0x61），ISP RGB 路径（0x501F=0x01）。
- 双数据通道 MIPI（0x300E=0x45）；0x4800=0x04，连续时钟、不发送行短包。
- 0x5001=0x23，使能缩放、颜色矩阵与自动白平衡。
- Retain the reference sensor readout, 2x binning, PLL, HTS=1896 and VTS=984.
- Set ISP horizontal offset to 176 (`0x3810/11=0x00B0`), vertical offset stays 6 (`0x3812/13=0x0006`).
  The binned readout is 1312x972. The centered pre-scaling window is
  `(1312 - 2*176) x (972 - 2*6) = 960x960`; ISP then scales it uniformly to 128x128.
- 0x3808/09=0x0080，0x380A/0B=0x0080。只改变有效图像尺寸，不把 HTS/VTS 改成 128/128。
- PLL 与 MIPI 时序沿用参考表；不能因分辨率变小就假定 MIPI lane rate 随之降低。
- RGB565 的字节顺序与原采集模块一致，但 CSI-2 解包后的字节/像素排列仍需核对；原 DVP 模块不能直接接 MIPI 引脚。

## 表执行约定

- 共 300 条有效写入，索引 0～299；index>=300 时 valid=0。
- 0x3008=0x82 软件复位之后等待 5 ms；最终 0x3008=0x02 唤醒之后等待 5 ms，再写 0x4202=0x00 开启帧输出。
- `delay_ms` 是本条写事务成功完成后的等待时间。
- 首条写入前，外部必须完成模块供电、XCLK 和硬件 RESET/PWDN 时序；ROM 本身不驱动这些引脚。
- CTRL 应锁存表项、启动单次 I2C、等待 write_done/error、等待本条 delay_ms，然后推进索引；以 valid=0 判定结束。

当前 ctrl.sv 在系统时钟上发出单拍 write_start，等待 write_done/write_error，执行写后延时，再推进索引；valid=0 时结束。i2c_config.sv 通过 i2c_dri.sv 完成寄存器写入。摄像头供电、XCLK、RESET/PWDN时序以及MIPI接收器仍需由顶层提供。

## I2C驱动连接

`i2c_dri.sv` 基于用户提供的 正点原子 `i2c_dri` 例程修改，保留原始作者说明。`i2c_config.sv` 是供现有 `ctrl.sv` 使用的写接口封装；两者需要一起加入工程。

```verilog
// 所有配置逻辑使用同一个100MHz系统时钟。
// write_start/write_addr/write_data来自ctrl；完成和错误信号反馈给ctrl。
i2c_config #(
    .SLAVE_ADDR(7'h3C),
    .CLK_FREQ(100_000_000),
    .I2C_FREQ(100_000)
) u_i2c_config (
    .clk(clk),
    .rst_n(rst_n),
    .write_start(write_start),
    .write_addr(write_addr),
    .write_data(write_data),
    .sda(cam_sda),
    .scl(cam_scl),
    .write_done(write_done),
    .write_error(write_error),
    .busy()
);
```

- 7位设备地址为0x3C，线上写地址字节为0x78、读地址字节为0x79。
- `write_start`为系统时钟域的一拍脉冲。驱动立即锁存地址、数据和操作类型；busy期间的新请求不接受。
- 不再输出或使用`dri_clk`。内部通过时钟使能推进协议，`ctrl.sv`的100MHz毫秒延时设置保持适用。
- SDA和SCL均为开漏形式的`inout`引脚，只拉低或释放；需要板级上拉，上拉电压按原理图。FPGA复位会释放两根总线。
- 正常事务完成和NACK终止均在STOP及总线空闲间隔后输出一拍`write_done`；NACK时同拍`write_error=1`。
- 支持SCL时钟拉伸。SCL或启动前SDA持续被拉低达到`TIMEOUT_US`（默认1000us）时，驱动释放总线，输出完成及错误；总线被外部拉低时无法保证实际产生STOP。
- 底层`i2c_dri`保留8/16位寄存器地址、单字节读写：`bit_ctrl=1`选择16位地址，`i2c_rh_wl=1`选择读。读事务使用重复起始，最后由主机发送NACK。原命名`i2c_ack=1`表示NACK或超时，不表示成功。
- `I2C_FREQ`作为速率上限使用，分频向上取整并满足Standard/Fast-mode的低电平时间；实际速率可能略低于参数。默认100MHz/100kHz，验证过100kHz、250kHz及400kHz参数配置。

Vivado 2022.2引脚级仿真已验证：单系统周期启动、输入锁存、忙时请求、8/16位地址读写、逐字节NACK中止及下一次重试、时钟拉伸、总线超时、复位释放。另用当前ROM和CTRL完成300条顺序配置及两处5ms写后等待，确认NACK会使CTRL停止推进。这些是模拟从机验证，尚未上板。

## 配置依据

寄存器基表来自 Espressif 的 OV5645 24MHz、双通道、1280×960 RGB565 驱动，采用 Apache-2.0 许可（见 LICENSE.ov5645.txt）：

https://github.com/espressif/esp-video-components/blob/master/esp_cam_sensor/sensors/ov5645/private_include/ov5645_mipi_2lane_24Minput_1280x960_rgb565_le_30fps.h

复位与启停参考同目录 ov5645_settings.h。原始基表文件 SHA256 记录在 ROM 文件头，方便核对来源。

本项目在该基表上修改了居中正方形裁剪、输出宽高、RGB565 字节顺序，并增加复位、待机、帧关闭/开启及写后延时。输出尺寸和缩放依据本地 OV5645_CSP3_DS_2.01_.pdf 的 image windowing、scaling、format control 和 ISP control 寄存器定义。

厂商 i2c_ov5645_rgb565_cfg.v 文件名虽然带 RGB565，实际例程表配置 1080p RAW10，因此没有直接照搬该表。

## 验证范围

Vivado 2022.2 的 xvlog、xelab、xsim 检查通过：遍历全部 1024 个索引，确认 300 条有效项、无未知输出、无效项清零、最终尺寸/格式/MIPI/总时序寄存器值、复位等待字段及最后开启帧输出的顺序。

这仅验证 ROM 的 RTL 和表内一致性，不模拟 OV5645 内部 ISP，不等同于传感器出图验证。128×128 改动尚未上板验证；需在 MIPI 接收器上检查帧高、行有效负载、像素颜色和实际帧率。

## Exposure tuning for a dark live camera image

- Keep automatic exposure and gain enabled (`0x3503=0x00` at the end of setup).
- Seed exposure at 64 whole lines (`0x3500/01/02=00/04/00`), up from 16 lines.
  The low four bits remain zero; this is a startup seed, not a fixed exposure.
- Raise the AEC stable target from 48..56 to 64..72:
  `0x3A0F=0x48`, `0x3A10=0x40`, `0x3A1B=0x48`, `0x3A1E=0x40`.
  Fast-zone thresholds are `0x3A11=0x90` and `0x3A1F=0x20`.
- Retain the existing AGC ceiling (`0x3A18/19=00/F8`, approximately 15.5x),
  maximum exposure, PLL, HTS/VTS, 128x128 RGB565 format and MIPI timing.
- `cnn_inference.c` skips 20 completed camera frames before taking its first
  input snapshot/preview (`CNN_CAMERA_WARMUP_FRAMES`, set 0 to disable).
  These are camera completion events, not 20 executions of the CNN.
- Rebuild/program the bitstream for ROM changes and rebuild/download both C
  Loader images for the warmup change. Sensor image quality still needs a
  physical-board check; register-table tests cannot establish exposure quality.
- Register definitions were checked against the local OV5645 datasheet
  version 2.01, sections 4.5, 4.6 and tables 4-4, 4-5 and 7-7.

## 128x128 sensor output -> 32x32 CNN input

- Sensor readout bounds remain X=0..2623, Y=6..1949. With 2x binning this
  yields 1312x972 samples. Section 4.2 of OV5645 datasheet v2.01 defines
  pre-scaling width/height as ISP input size minus twice the corresponding
  offset. Offsets 176 and 6 produce a centered 960x960 square.
- Output registers are `0x3808/09=0x0080`, `0x380A/0B=0x0080`.
  Do not change HTS/VTS to the output dimensions.
- `video_capture_ctrl.sv` accepts exactly 16384 valid pixels, ending at
  counter value 16383.
- `video_process_top.sv` uses input last indices 127/127 and Q4.14 scaling
  factors 65536/65536 (4.0/4.0), retaining the existing bilinear scaler.
  Output remains 32x32 INT8: 1024 bytes, one 256-beat 32-bit AXI burst.
- The current scaler starts sampling at coordinate (0,0). With integer
  scale 4, output (x,y) samples input (4*x,4*y); this is not a 4x4 block
  average. No new filtering or software input format is introduced.
- The 7-bit row index covers 0..127. Existing line RAM widths are retained.
- Both soc/rtl/camera and 5pipeline_tcl/src/camera are updated together.
- Hardware changes require rebuilding and programming soc_top.bit. The
  CNN software still receives 32x32 input, so no C/binary change is needed
  for this resolution update.
- RTL checks use a behavioral MIPI AXIS source and an AXI write sink. They
  do not model the sensor ISP or MIPI PHY. Verify 128 pixels/line, 128 lines,
  focus and actual crop on the physical board.

## Validation of the 128x128 update

Vivado 2022.2 xvlog/xelab/xsim passed with the Tcl project source files:

- ROM: all 1024 indices checked, 300 valid writes, reset/wakeup delays and
  output-enable ordering checked, pre-scaling crop calculated as 960x960.
- Static comparison against the prior ROM: only output width (index 69),
  output height (index 71), and horizontal offset (index 77) values changed.
- Video path: two successive 128x128 frames through the actual RGB
  conversion, grayscale, capture, scaler, packer, asynchronous FIFO and AXI
  writer. Every one of the 2048 output bytes matched independently computed
  expected pixels, with exactly 16384 accepted pixels per source frame.
- Tested a digit-shaped pattern and its inverse, white then black frames,
  and a two-frame RGB ramp with prolonged/periodic AXI stalls and different
  video/AXI clock periods. WDATA/WSTRB/WLAST remained stable while stalled.
- Sensor cropping is checked from the register geometry formula; this
  test does not emulate the OV5645 ISP or establish physical image quality.

Temporary test sources and logs for this update:
`C:/Users/jacks/AppData/Local/Temp/camera_128_sz83brx9/sim/`.
The baseline file backups and SHA256 manifest are in its parent directory.
