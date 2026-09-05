`include "define.sv"

//load可以从cache读数据，更快
//store没必要，直接访存
module dcache(
    input clk,
    input rst_n,

    //dcache给mem的信号
    // 写信号
    input                  mem_req_valid,
    output                 mem_req_ready,
    input   [`DataAddrBus] mem_req_addr,//根据pc往mem（ddr）里面找相应地址的数据
    input   [31:0]         mem_req_wdata,
    input   [3:0]          mem_req_wstrb,
    input                  mem_req_write,// 0表示读ram，1表示写ram

    // 读信号
    output              mem_rsp_valid,
    output   [`DataBus] mem_rsp_rdata,

    //给dram的信号
    output                    dcache_req_valid,
    input                     dcache_req_ready,
    output     [`DataAddrBus] dcache_req_addr,//根据pc往mem里面找相应地址的数据
    output     [31:0]         dcache_req_wdata,
    output     [3:0]          dcache_req_wstrb,
    output                    dcache_req_write,// 0表示读，1表示写

    // 读信号
    input                     dcache_rsp_valid,
    input   [`DataBus]        dcache_rsp_rdata,

    //dcache的两个计数器
    output reg [31:0] hit_count_d,
    output reg [31:0] ddr_count_d,
    output reg [31:0] miss_count_d,

    //dma_irq信号，用来做一致性处理
    input             dma_irq
);


//四个状态定义
localparam DC_IDLE     = 2'd0;//空闲，收到握手后进入lookup
localparam DC_LOOKUP   = 2'd1;//判断miss还是hit
localparam DC_RAM_WAIT = 2'd2;//等待ram返回数据
localparam DC_RESP     = 2'd3;//返回给if

reg [1:0] state;
reg [1:0] next_state;

//将一直拉高的dma_irq变为脉冲信号（防止多次重置）
reg dma_irq_d;
wire dma_irq_pulse;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        dma_irq_d <= 1'b0;
    end
    else begin
        dma_irq_d <= dma_irq;
    end
end

assign dma_irq_pulse = dma_irq && !dma_irq_d;

reg invalidate_pending;//脉冲信号到来时如果不是空闲状态就等dcache本次操作完成后重置，拉高该信号一直到下一个idle才开始清零
wire invalidate_now;

// DCache空闲，并且有待处理的失效请求
assign invalidate_now =
    (state == DC_IDLE) &&
    (invalidate_pending || dma_irq_pulse);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        invalidate_pending <= 1'b0;
    end
    else if (invalidate_now) begin
        //在这个周期已经把valid重置了
        invalidate_pending <= 1'b0;
    end
    else if (dma_irq_pulse) begin
        // DCache忙，先保存请求
        invalidate_pending <= 1'b1;
    end
end

reg [31:0] data_way0 [0:31];//32组的第一路
reg [31:0] data_way1 [0:31];//32组的第二路

reg valid_way0 [0:31];//每组的第一路是否有效
reg valid_way1 [0:31];//每组的第二路是否有效

reg [24:0] tag_way0 [0:31];
reg [24:0] tag_way1 [0:31];

//lru[index] = 0 → way0是最久未使用的，下次替换way0
//lru[index] = 1 → way1是最久未使用的，下次替换way1
reg lru[0:31];

//写flag信号和字节有效信号锁存
reg store_write;
reg [3:0] store_wstrb;

reg [`DataAddrBus] store_addr;//读入地址的锁存
reg [`DataBus]     store_data;

//拆锁存的地址
wire [4:0]  index;
wire [24:0] tag;
assign index = store_addr[6:2];
assign tag   = store_addr[31:7];

//分别判断命中
wire hit_way0;
wire hit_way1;

assign hit_way0 = valid_way0[index] && (tag_way0[index] == tag);
assign hit_way1 = valid_way1[index] && (tag_way1[index] == tag);

//未命中信号
wire miss;
assign miss = !hit_way0 && !hit_way1 && (state == DC_LOOKUP);

assign mem_req_ready = (state == DC_IDLE) && !invalidate_now;
assign mem_rsp_valid = (state == DC_RESP);

//未命中，要和ram进行交互
assign dcache_req_valid = (state == DC_LOOKUP) && (store_write || miss);
assign dcache_req_addr  = store_addr;

//miss时选择替换的路
wire victim_way;
reg  victim_way_q;//锁存替换路
assign victim_way = !valid_way0[index] ? 1'b0 : !valid_way1[index] ? 1'b1 : lru[index];

//把所存的信号接出去
assign dcache_req_wdata = store_write ? store_data : 'd0;
assign mem_rsp_rdata    = store_write ? 'd0 : store_data;
assign dcache_req_wstrb = store_write ? store_wstrb : 4'b0000;
assign dcache_req_write = store_write;

always @(posedge clk or negedge rst_n) begin
    if(!rst_n)begin
        ddr_count_d <= 'd0;
        hit_count_d <= 'd0;
        miss_count_d <= 'd0;
    end
    else begin
        // 每次Cache hit只增加一次
        if ((state == DC_LOOKUP) && (hit_way0 || hit_way1)) begin
            hit_count_d <= hit_count_d + 32'd1;
        end

        if (miss && dcache_req_valid && dcache_req_ready)begin
            miss_count_d <= miss_count_d + 32'd1;
        end

        // DDR读请求被Bridge接收，开始计时
        if ((state == DC_LOOKUP) && miss && dcache_req_valid && dcache_req_ready && !store_write) begin
            ddr_count_d <= 32'd0;
        end
        else if (state == DC_RAM_WAIT && !store_write) begin
            // 每个等待周期都要增加，包括响应返回的周期
            ddr_count_d <= ddr_count_d + 32'd1;
        end
    end
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state <= DC_IDLE;
    end
    else begin
        state <= next_state;
    end
end

always @(*) begin
    next_state = state;
    case (state)
        DC_IDLE: begin
            if (mem_req_valid && mem_req_ready) begin
                next_state = DC_LOOKUP;
            end
        end
        DC_LOOKUP: begin
            if(!store_write && (hit_way0 || hit_way1)) begin
                next_state = DC_RESP;
            end
            else if (dcache_req_valid && dcache_req_ready) begin
                next_state = DC_RAM_WAIT;
            end
        end
        DC_RAM_WAIT: begin
            if (dcache_rsp_valid) begin
                next_state = DC_RESP;
            end
        end
        DC_RESP: begin
            next_state = DC_IDLE;
        end
        default: begin
            next_state = DC_IDLE;
        end
    endcase
end

integer i;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        store_addr  <= 'd0;
        store_data  <= 'd0;
        store_write <= 'd0;
        store_wstrb <= 'd0;
        for (i = 0; i < 32; i = i + 1) begin
            valid_way0[i] <= 1'b0;
            valid_way1[i] <= 1'b0;
            lru[i]        <= 1'b0;
        end
        victim_way_q <= 'd0;
    end
    //清除dcache（valid都拉低）
    else if(invalidate_now)begin
        for (i = 0; i < 32; i = i + 1) begin
            valid_way0[i] <= 1'b0;
            valid_way1[i] <= 1'b0;
            lru[i]        <= 1'b0;
        end
    end
    else begin
        case (state)
            DC_IDLE: begin
                if (mem_req_valid && mem_req_ready) begin
                    store_addr  <= mem_req_addr;
                    store_write <= mem_req_write;
                    store_wstrb <= mem_req_wstrb;

                    // Store时，store_data先保存写数据
                    if (mem_req_write)begin
                        store_data <= mem_req_wdata;
                    end
                end
            end

            DC_LOOKUP: begin
                if (!store_write && miss && dcache_req_valid && dcache_req_ready) begin
                    victim_way_q <= victim_way;
                end
                else if(hit_way0 || hit_way1)begin
                    if (!store_write)begin
                        store_data <= hit_way0 ? data_way0[index] : data_way1[index];
                        if (hit_way0) begin
                            // way0刚使用，下次替换way1
                            lru[index] <= 1'b1;
                        end
                        else if (hit_way1) begin
                            // way1刚使用，下次替换way0
                            lru[index] <= 1'b0;
                        end
                    end
                end
            end

            DC_RAM_WAIT:begin
                if (dcache_rsp_valid) begin
                    if(!store_write)begin
                        store_data <= dcache_rsp_rdata;//从ram里面拿出来给if的，先锁存在storedata
                        if (victim_way_q) begin
                            data_way1[index] <= dcache_rsp_rdata;
                            tag_way1[index]  <= tag;
                            valid_way1[index] <= 1'b1;
                            lru[index] <= 1'b0;// way1刚使用，下次替换way0
                        end
                        else begin
                            data_way0[index] <= dcache_rsp_rdata;
                            tag_way0[index]  <= tag;
                            valid_way0[index] <= 1'b1;
                            lru[index] <= 1'b1;// way0刚使用，下次替换way1
                        end
                    end

                    else begin
                        // Store hit：更新命中的Cache行
                        if (hit_way0) begin
                            if (store_wstrb[0])
                                data_way0[index][7:0] <= store_data[7:0];

                            if (store_wstrb[1])
                                data_way0[index][15:8] <= store_data[15:8];

                            if (store_wstrb[2])
                                data_way0[index][23:16] <= store_data[23:16];

                            if (store_wstrb[3])
                                data_way0[index][31:24] <= store_data[31:24];

                            lru[index] <= 1'b1;
                        end
                        else if (hit_way1) begin
                            if (store_wstrb[0])
                                data_way1[index][7:0] <= store_data[7:0];

                            if (store_wstrb[1])
                                data_way1[index][15:8] <= store_data[15:8];

                            if (store_wstrb[2])
                                data_way1[index][23:16] <= store_data[23:16];

                            if (store_wstrb[3])
                                data_way1[index][31:24] <= store_data[31:24];

                            lru[index] <= 1'b0;
                        end

                        // 两路均未命中时不操作Cache，只写DRAM
                    end
                end
            end

        endcase
    end
end

endmodule
