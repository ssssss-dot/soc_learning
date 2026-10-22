# SoC 内部 MIPI 参考时钟与复位

soc_top 使用 Xilinx UltraScale+ 官方 PLLE4_BASE 原语和 BUFG，在 FPGA 内将板载 100 MHz 转为 200 MHz。clk_200m 已改成内部连线，不再是顶层输入，不需要为它分配 PACKAGE_PIN，也不需要另外生成 Clocking Wizard XCI。

PLL 参数：CLKIN_PERIOD=10 ns、DIVCLK_DIVIDE=1、CLKFBOUT_MULT=12、CLKOUT0_DIVIDE=6，即 VCO=1200 MHz，输出=200 MHz。反馈采用内部补偿的直接反馈，CLKOUT0 经 BUFG 后接 video_process_top.clk_200m，再接 MIPI.dphy_clk_200M。参考时钟不受 AXI 或视频复位门控。

PLL 仅由板级 rst_n 复位，不使用自己的 LOCKED 或 MIPI system_rst_out 反馈复位 PLL，避免启动循环。原有 100 MHz 系统时钟连接保持一致。输入时钟变化或参考 PLL 失锁后，应按官方要求重新执行板级复位以重新锁定。

## MIPI 视频复位

新的 mipi_video_rst_n 由 AXI 前端就绪与参考 PLL 的 LOCKED 共同控制：条件失效时异步拉低，释放先经过 100 MHz 域两级同步，再保持 32 个 100 MHz 周期。320 ns 的额外保持时间超过 PG232 要求的 40 个 200 MHz 周期（200 ns）。PLL 失锁、板级复位或 AXI 前端复位都会重新启动此过程。

MIPI 的 video_aclk 仍为系统 100 MHz；视频复位改为 mipi_video_rst_n。DDR 写主机和总线侧复位仍使用 axi_front_aresetn。没有使用 MIPI 接收器输出的 pll_lock_out/system_rst_out 作为参考 PLL 的复位条件。

## cam_config_rst_n 接系统复位

当前 soc_top 的板级系统复位名为 rst_n。cam_config_rst_n 已改成内部信号，由 rst_n 经 100 MHz 域两级复位同步器产生：rst_n 拉低时异步拉低配置复位；rst_n 拉高后，经过两个时钟上升沿同步释放。ROM、CTRL、I2C 继续连接 cam_config_rst_n。

不再为 cam_config_rst_n 保留顶层输入，也无需为它添加 XDC 管脚约束。此配置复位不使用 cpu_rst_n，因此 Loader 对 CPU 的复位不会单独重启摄像头配置。

摄像头硬件控制现由 ctrl.sv 负责：系统复位使 RESETB/PWDNB 均为低；等待 5 ms 后拉高 PWDNB，再等 1 ms 拉高 RESETB，再等 20 ms，并等待 receiver_ready 后才开始 ROM/I2C 配置。config_top 与 soc_top 只传递 cam_rst_n、cam_pwdn 和 receiver_ready；SoC 的 receiver_ready 连接 mipi_video_rst_n。模块供电与自带 24 MHz 振荡器仍由板卡硬件提供。正常采集时两根控制输出保持高，I2C 写后等待仍按 ROM 配置执行。

## 约束与验证范围

现有 sys_clk_p 的 10 ns 输入时钟约束应保留。Vivado 会根据官方 PLL 原语和此输入时钟自动派生 5 ns 的 200 MHz 时钟，不应对内部 clk_200m 再添加独立 create_clock。

已通过 Vivado 2022.2：完整候选 soc_top 的 xvlog 语法检查；使用真实 UNISIM PLL 模型测量 5 ns 输出周期；检查启动、AXI 复位、参考锁定信号故障注入、系统复位下的复位行为。对从 soc_top 提取的同一 PLL/复位代码在 xczu5ev-sfvc784-2-e 上综合，并确认派生时钟为 5.000 ns、PLL DRC 无错误。

上述验证针对本次时钟/复位改动，不代表整个 SoC 已重新布局布线或摄像头已上板验证。

## 官方依据

- UG974，Vivado 2022.2，PLLE4_BASE：
  https://docs.amd.com/r/2022.2-English/ug974-vivado-ultrascale-libraries/PLLE4_BASE
- PG202，Clocking：200 MHz free-running，来自板载振荡器或单级 MMCM/PLL，不使用级联 MMCM：
  https://docs.amd.com/r/en-US/pg202-mipi-dphy/Clocking
- PG232，Resets：video_aresetn 至少保持 40 个 dphy_clk_200M 周期：
  https://docs.amd.com/r/5.3-English/pg232-mipi-csi2-rx/Resets
