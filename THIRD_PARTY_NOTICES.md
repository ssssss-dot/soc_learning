# 第三方组件与许可说明

本清单按当前工作区源码的文件头整理。工程整体沿用 [CERN-OHL-S-2.0](LICENSE)，第三方文件保留各自的版权和授权；集成到 `soc_learning` 不会覆盖原文件声明。

## 1. FPGA Ninja Taxi

上游：[fpganinja/taxi](https://github.com/fpganinja/taxi)。当前副本文件头署名为 **FPGA Ninja, LLC**，作者为 **Alex Forencich**。Crossbar/DMA 核文件标注 2018–2025，arbiter/penc 文件标注 2014–2025，MIT 接口与 tie 文件标注 2025。本仓库未记录对应上游提交号，应以当前副本的文件级标识为准。

### CERN-OHL-S-2.0 文件

以下 14 个文件保留其 `SPDX-License-Identifier: CERN-OHL-S-2.0` 声明，标准条款见 [LICENSE](LICENSE)：

```text
rtl/axi/axi_crossbar/taxi_axi_crossbar_3s.sv
rtl/axi/axi_crossbar/rd/taxi_arbiter.sv
rtl/axi/axi_crossbar/rd/taxi_axi_crossbar_addr.sv
rtl/axi/axi_crossbar/rd/taxi_axi_crossbar_rd.sv
rtl/axi/axi_crossbar/rd/taxi_axi_register_rd.sv
rtl/axi/axi_crossbar/rd/taxi_penc.sv
rtl/axi/axi_crossbar/wr/taxi_arbiter.sv
rtl/axi/axi_crossbar/wr/taxi_axi_crossbar_addr.sv
rtl/axi/axi_crossbar/wr/taxi_axi_crossbar_wr.sv
rtl/axi/axi_crossbar/wr/taxi_axi_register_wr.sv
rtl/axi/axi_crossbar/wr/taxi_penc.sv
rtl/axi/dma/taxi_axi_dma.sv
rtl/axi/dma/taxi_axi_dma_rd.sv
rtl/axi/dma/taxi_axi_dma_wr.sv
```

### MIT 文件

以下 7 个文件保留其 `SPDX-License-Identifier: MIT` 声明。完整许可文本见 [LICENSES/MIT-FPGA-Ninja.txt](LICENSES/MIT-FPGA-Ninja.txt)：

```text
rtl/axi/dma/3interface/axi.sv
rtl/axi/dma/3interface/axis.sv
rtl/axi/dma/3interface/taxi_dma_desc_if.sv
rtl/axi/axi_crossbar/rd/taxi_axi_if.sv
rtl/axi/axi_crossbar/rd/taxi_axi_tie_rd.sv
rtl/axi/axi_crossbar/wr/taxi_axi_if.sv
rtl/axi/axi_crossbar/wr/taxi_axi_tie_wr.sv
```

`rd/`、`wr/` 中存在同名公共定义副本，是源文件布局问题；是否加入某次编译不改变保留在仓库内副本的版权和许可。

## 2. peqFlash 下载工具

[download/peqflash.py](download/peqflash.py) 的原始文件头标明：

- 工具：peqFlash / Pequeno Flasher。
- 开发者：Mitu Raj，Chipmunk Logic。
- 文件头版本记录：August-2024。
- 原始用途：通过 UART 下载 PQR5 指令和数据包，并启动系统。

来源项目参见 [iammituraj/pequeno_riscv](https://github.com/iammituraj/pequeno_riscv) 及其 [上游 LICENSE](https://github.com/iammituraj/pequeno_riscv/blob/main/LICENSE)。当前本地文件头只写了 `Open-source license`，未记录具体 SPDX 标识或上游提交号；这里保留来源信息，不将该第三方工具重新声明为本工程的 CERN 许可。需要确认历史版本授权时，应对应原始分发版本核对。

## 3. 外部工具、IP 和数据

Vivado、MIG DDR4、AXI Clock Converter、ILA 等工具及生成 IP 的授权由 AMD/Xilinx 提供；它们没有因被 `soc_top` 例化而转为本工程原创内容。板级 XDC 和 MIG 参数也必须来自实际使用的板卡工程。

PyTorch、torchvision、d2l、NumPy、pyserial 等作为外部依赖使用，保留各自授权。示例输入图片和标签来自 MNIST；数据来源及其原有条款不由本工程许可证替代。模型导出、校验和 C 调度代码的工程级许可范围见 [LICENSE](LICENSE)。

## 4. 工程许可原文

本次整理保留原有 CERN-OHL-S-2.0 标准正文，仅在 [LICENSE](LICENSE) 开头补充工程适用范围和第三方归属。标准文本的官方入口为 [CERN Open Hardware Licence](https://cern-ohl.web.cern.ch/)。
