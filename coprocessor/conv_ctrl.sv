`include "define.sv"

module conv_ctrl(
    input clk,
    input rst_n,

    // MMIO router -> Conv：寄存器访问请求
    input conv_req_valid,
    output conv_req_ready,

    // Conv -> MMIO router：寄存器访问响应
    output conv_rsp_valid,
    input conv_rsp_ready,

    input [`DataBus] conv_wdata,
    input [`DataAddrBus] conv_addr,// CPU完整字节地址
    input [3:0] conv_wstrb,
    input conv_we,// 1：写寄存器；0：读寄存器

    output [`DataBus] conv_rdata
);

// Conv寄存器声明；复位、MMIO读写和执行控制逻辑后续实现
// CONTROL：[0]start写1自清；[1]irq_enable；其余位保留
reg [`DataBus] conv_control_reg;

// STATUS：[0]busy由硬件更新；[1]done、[2]error锁存并由软件写1清除
// 其余位保留
reg [`DataBus] conv_status_reg;

// INPUT_SHAPE：[15:0]输入宽度；[31:16]输入高度
reg [`DataBus] conv_input_shape_reg;

// CHANNELS：[15:0]输入通道数；[31:16]输出通道数
reg [`DataBus] conv_channels_reg;

// BIAS_BASE：[13:0]bias在BRAM中的字地址；[31:14]保留
// CONV_BIAS_BASE_ADDR是CPU访问本寄存器的字节地址，两者单位不同
reg [`DataBus] conv_bias_base_reg;

// QUANT_MULT：32位无符号整数乘数
reg [`DataBus] conv_quant_mult_reg;

// QUANT_SHIFT：[5:0]右移位数；[31:6]保留
reg [`DataBus] conv_quant_shift_reg;

endmodule
