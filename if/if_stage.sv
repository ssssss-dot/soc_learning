`include "define.sv"

//if取指令的顶层文件
module if_stage(
    input clk,
    input rst_n,
    input stall_i,//停止信号
    input redirect_i,//拉高标志着需要跳转
    input [`InstAddrBus] redirect_pc_i,//在ex中计算完成的跳转地址，直接给到nextpc

    output [`InstBus] inst_o,//输出给id的指令

    //后面的分支跳转会用到pc和pc+4
    output [`InstAddrBus] pc_o,//给出当前指令的pc地址
    output [`InstAddrBus] pc_plus4_o,

    output if_valid_o,                 // IF输出是否有效

    // 给流水线Ctrl的暂停请求
    output wire         if_req_o,

    //顶层根据ddr_init_done和ldr_pgm_done信号生成，表示可以取指令
    input fetch_enable,

    //miss时cache和mem的接口
    output                      icache_req_valid,
    input                       icache_req_ready,
    output      [`InstAddrBus]  icache_req_addr,
    input                       icache_rsp_valid,
    input   [`InstBus]          icache_rsp_rdata,

    output [31:0] miss_count_i,
    output [31:0] hit_count_i,//记录命中的次数（性能判断）
    output [31:0] ddr_count_i //看访问ddr所需的时间，hit时cahche返回只要一个周期      
);

//内部信号声明
wire [`InstAddrBus] curr_pc_d1;
wire [`InstAddrBus] next_pc;
wire if_valid;
wire cpu_read_en;
wire [`InstAddrBus] curr_pc;

assign if_valid_o = if_valid;

//给pc地址赋值
assign pc_o = curr_pc_d1;
assign pc_plus4_o = curr_pc_d1 + 'd4;

//前端发起取指的使能
assign cpu_read_en = !stall_i & !redirect_i;

//取指控制模块到ICache的请求/响应接口。
wire                if_req_valid;
wire                if_req_ready;
wire [`InstAddrBus] if_req_addr;
wire                if_rsp_valid;
wire [`InstBus]     if_rsp_rdata;

//取指请求控制模块例化；实际存储器访问由ICache和Bridge完成。
inst_ram u_inst_ram
(   
    .clk(clk),
    .rst_n(rst_n),
    .curr_pc_d1(curr_pc_d1),
    .curr_pc(curr_pc),
    .inst_o(inst_o),
    .inst_valid_o(if_valid),
    .cpu_read_en(cpu_read_en),
    .redirect_i(redirect_i),
    .if_req_o(if_req_o),
    .if_req_valid(if_req_valid),
    .if_req_ready(if_req_ready),
    .if_req_addr(if_req_addr),
    .if_rsp_valid(if_rsp_valid),
    .if_rsp_rdata(if_rsp_rdata),
    .fetch_enable_i(fetch_enable)//顶层根据ddr_init_done和ldr_pgm_done信号生成，表示可以取指令

);

//pc选择器例化
mux_pc u_mux_pc
(
    .stall_i(stall_i),
    .redirect_i(redirect_i),
    .redirect_pc_i(redirect_pc_i),
    .curr_pc(curr_pc),
    .next_pc(next_pc)
);

//pc_reg例化
pc_reg u_pc_reg
(
    .clk(clk),
    .rst_n(rst_n),
    .curr_pc(curr_pc),
    .next_pc(next_pc)
);

//icache例化
icache u_icache
(
    .clk(clk),
    .rst_n(rst_n),
    .if_req_valid(if_req_valid),
    .if_req_ready(if_req_ready),
    .if_req_addr(if_req_addr),
    .if_rsp_valid(if_rsp_valid),
    .if_rsp_rdata(if_rsp_rdata), 
    .icache_req_valid(icache_req_valid),
    .icache_req_ready(icache_req_ready),
    .icache_req_addr(icache_req_addr),
    .icache_rsp_valid(icache_rsp_valid),
    .icache_rsp_rdata(icache_rsp_rdata),
    .hit_count_i(hit_count_i),
    .ddr_count_i(ddr_count_i),
    .miss_count_i(miss_count_i)
);

endmodule
