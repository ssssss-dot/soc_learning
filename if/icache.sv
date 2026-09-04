`include "define.sv"

//32组，两路，每路存一个字
//addr[1:0]  字节偏移
//addr[6:2]  组索引
//addr[31:7] Tag
module icache(
    input clk,
    input rst_n,

    //if给cache的取指信号
    input                  if_req_valid,
    output                 if_req_ready,//返回给if
    input  [`InstAddrBus]  if_req_addr,
    output                 if_rsp_valid,
    output     [`InstBus]  if_rsp_rdata,

    //miss时cache和mem的接口
    output                      icache_req_valid,
    input                       icache_req_ready,
    output      [`InstAddrBus]  icache_req_addr,
    input                       icache_rsp_valid,
    input   [`InstBus]          icache_rsp_rdata,

    //性能计数器
    output reg [31:0] miss_count_i, 
    output reg [31:0] hit_count_i,//记录命中的次数（性能判断）
    output reg [31:0] ddr_count_i //看访问ddr所需的时间，hit时cahche返回只要一个周期
);

//四个状态定义
localparam IC_IDLE     = 2'd0;//空闲，收到握手后进入lookup
localparam IC_LOOKUP   = 2'd1;//判断miss还是hit
localparam IC_RAM_WAIT = 2'd2;//等待ram返回数据
localparam IC_RESP     = 2'd3;//返回给if

reg [1:0] state;
reg [1:0] next_state;

reg [31:0] data_way0 [0:31];//32组的第一路
reg [31:0] data_way1 [0:31];//32组的第二路

reg valid_way0 [0:31];//每组的第一路是否有效
reg valid_way1 [0:31];//每组的第二路是否有效

reg [24:0] tag_way0 [0:31];
reg [24:0] tag_way1 [0:31];

//lru[index] = 0 → way0是最久未使用的，下次替换way0
//lru[index] = 1 → way1是最久未使用的，下次替换way1
reg lru[0:31];

reg [`InstAddrBus] store_addr;//读入地址的锁存
reg [`InstBus]     store_data;

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
assign miss = !hit_way0 && !hit_way1 && (state == IC_LOOKUP);

assign if_req_ready = (state == IC_IDLE);
assign if_rsp_valid = (state == IC_RESP);
assign if_rsp_rdata = store_data;

//未命中，要和ram进行交互
assign icache_req_valid = (state == IC_LOOKUP) && miss;
assign icache_req_addr  = store_addr;

//miss时选择替换的路
wire victim_way;
reg  victim_way_q;//锁存替换路
assign victim_way = !valid_way0[index] ? 1'b0 : !valid_way1[index] ? 1'b1 : lru[index];

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state <= IC_IDLE;
    end
    else begin
        state <= next_state;
    end
end

always @(*) begin
    next_state = state;
    case (state)
        IC_IDLE: begin
            if (if_req_valid && if_req_ready) begin
                next_state = IC_LOOKUP;
            end
        end
        IC_LOOKUP: begin
            if(hit_way0 || hit_way1) begin
                next_state = IC_RESP;
            end
            else if (icache_req_valid && icache_req_ready) begin
                next_state = IC_RAM_WAIT;
            end
        end
        IC_RAM_WAIT: begin
            if (icache_rsp_valid) begin
                next_state = IC_RESP;
            end
        end
        IC_RESP: begin
            next_state = IC_IDLE;
        end
        default: begin
            next_state = IC_IDLE;
        end
    endcase
end

integer i;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        store_addr <= 'd0;
        store_data <= 'd0;
        for (i = 0; i < 32; i = i + 1) begin
            valid_way0[i] <= 1'b0;
            valid_way1[i] <= 1'b0;
            lru[i]        <= 1'b0;
        end
        victim_way_q <= 'd0;
    end
    else begin
        case (state)
            IC_IDLE: begin
                if (if_req_valid && if_req_ready) begin
                    store_addr <= if_req_addr;
                end
            end

            IC_LOOKUP: begin
                if (miss && icache_req_valid && icache_req_ready) begin
                    victim_way_q <= victim_way;
                end
                else if(hit_way0 || hit_way1)begin
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

            IC_RAM_WAIT:begin
                if (icache_rsp_valid) begin
                    store_data <= icache_rsp_rdata;//从ram里面拿出来给if的，先锁存在storedata
                    if (victim_way_q) begin
                        data_way1[index] <= icache_rsp_rdata;
                        tag_way1[index]  <= tag;
                        valid_way1[index] <= 1'b1;
                        lru[index] <= 1'b0;// way1刚使用，下次替换way0
                    end
                    else begin
                        data_way0[index] <= icache_rsp_rdata;
                        tag_way0[index]  <= tag;
                        valid_way0[index] <= 1'b1;
                        lru[index] <= 1'b1;// way0刚使用，下次替换way1
                    end
                end
            end

        endcase
    end
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        hit_count_i <= 32'd0;
        ddr_count_i <= 32'd0;
        miss_count_i <= 32'd0;
    end
    else begin
        // 每次Cache hit只增加一次
        if ((state == IC_LOOKUP) && (hit_way0 || hit_way1)) begin
            hit_count_i <= hit_count_i + 32'd1;
        end
        
        if (miss && icache_req_valid && icache_req_ready) begin
            miss_count_i <= miss_count_i + 32'd1;
        end

        // DDR读请求被Bridge接收，开始计时
        if ((state == IC_LOOKUP) && miss && icache_req_valid && icache_req_ready) begin
            ddr_count_i <= 32'd0;
        end
        else if (state == IC_RAM_WAIT) begin
            // 每个等待周期都要增加，包括响应返回的周期
            ddr_count_i <= ddr_count_i + 32'd1;
        end
    end
end

endmodule