`include "define.sv"

// 整层输出从共享BRAM字节地址0开始，各组结果依次连续存放。
module fc_ctrl(
    input clk,
    input rst_n,

    input [`DataBus] fc_in_features_i,//输入特征数量
    input [`DataBus] fc_out_features_i,//输出特征数量
    input [`DataBus] fc_input_base_addr_i,//输入特征图基地址
    input [`DataBus] fc_weight_base_addr_i,//输入权重基地址
    input [`DataBus] fc_bias_base_addr_i,//输入偏置基地址
    //量化数据
    input [`DataBus] fc_quant_mult_i,
    input [5:0] fc_quant_shift_i,

    output [`DataBus] fc_in_features_o,//输入特征数量
    output [`DataBus] fc_out_features_o,//输出特征数量
    output [`DataBus] fc_input_base_addr_o,//输入特征图基地址
    output [`DataBus] fc_weight_base_addr_o,//输入权重基地址
    output [`DataBus] group_bias_base_addr,//输入偏置基地址
    output [`DataBus] fc_weight_end_addr,
    output [`DataBus] fc_input_end_addr,
    output [`DataBus] group_bias_end_addr,
    output [4:0] group_bias_count,//组内的bias个数

    //量化数据
    output [`DataBus] fc_quant_mult_o,
    output [5:0] fc_quant_shift_o, 

    input input_loading_done,
    input bias_loading_done,
    input computing_done,
    input drain_done,
    input result_done,

    output input_loading,
    output bias_loading,
    output computing,
    output draining,

    output reg busy,
    output reg done,
    output reg error,

    input fc_start,
    output reg addr_init,

    //表示当前哪个地址可以开始增加
    output reg weight_addr_begin,
    output reg input_addr_begin,//看输入通道增加缓存地址
    output reg bias_addr_begin,

    output reg rd_req,
    output reg [1:0] rd_sel,

    output [2:0] group_idx_o,
    output reg group_start//表示新的一组开始的启动脉冲

);

localparam IDLE = 3'd1;
localparam ADDR_INIT = 3'd2;
localparam INPUT_LOADING = 3'd3;//400B
localparam BIAS_LOADING = 3'd4;//存一组64B
localparam COMPUTING = 3'd5;//权重拼接和计算应该并行
localparam DRAIN = 3'd6;//排空阵列，结果陆续进入后处理
localparam WAIT_RESULT =3'd0;//等当前组全部结果写回完成
localparam DONE = 3'd7;//所有组都计算完成之后返回done

//数据源编码
localparam RD_INPUT = 2'd0;
localparam RD_WEIGHT = 2'd1;
localparam RD_BIAS = 2'd2;

reg [2:0] group_cnt;//每层的时候记录组数

reg [2:0] state;
reg [2:0] next_state;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        state <= IDLE;
    else
        state <= next_state;
end

always @(*)begin
    next_state = state;
    case(state)
        IDLE:begin
            if(fc_start)begin
                next_state = ADDR_INIT;
            end
        end
        ADDR_INIT:begin
            next_state = INPUT_LOADING;
        end
        INPUT_LOADING:begin
            if(input_loading_done && !input_addr_begin)begin//防止刚进入时，done信号是没被清除的旧值
                next_state = BIAS_LOADING;
            end
        end
        BIAS_LOADING:begin
            if(bias_loading_done && !bias_addr_begin)begin
                next_state = COMPUTING;
            end            
        end
        COMPUTING:begin
            if(computing_done && !group_start)begin
                next_state = DRAIN;
            end
        end
        DRAIN:begin
            if(drain_done)begin
                next_state = WAIT_RESULT;
            end
        end
        WAIT_RESULT:begin
            if(result_done)begin
                if(group_cnt == ((fc_out_features_i - 1'b1) >> $clog2(`FC_PE_NUMBER)))begin
                    next_state = DONE;
                end
                else begin
                    next_state = BIAS_LOADING;
                end
            end
        end      
        DONE: begin
            next_state = IDLE;
        end  
    endcase
end

always @(posedge clk or negedge rst_n)begin
    if(!rst_n)begin
        group_cnt <= 'd0;
        busy <= 'd0;
        done <= 'd0;
        error <= 'd0;
        addr_init <= 'd0;
        rd_req <= 'd0;
        rd_sel <= 'd0;
    end
    else begin
        done <= 'd0;
        error <= 'd0;
        addr_init <= 'd0;
        case(state)
            IDLE:begin
                if(fc_start)begin
                    group_cnt <= 'd0;
                    busy <= 'd0;
                    done <= 'd0;
                    error <= 'd0;
                    addr_init <= 'd0;
                    rd_req <= 'd0;
                    rd_sel <= 'd0;
                end
            end
            ADDR_INIT:begin
                addr_init <= 1'b1;
                busy <= 1'b1;
            end
            INPUT_LOADING:begin
                rd_req <= 1'b1;
                rd_sel <= RD_INPUT;
            end
            BIAS_LOADING:begin
                rd_req <= 1'b1;
                rd_sel <= RD_BIAS;
            end
            COMPUTING:begin
                rd_req <= 1'b1;
                rd_sel <= RD_WEIGHT;
            end
            DRAIN:begin
                rd_req <= 1'b0;
            end
            WAIT_RESULT:begin
                if(result_done)begin
                    if(group_cnt < ((fc_out_features_i - 1'b1) >> $clog2(`FC_PE_NUMBER)))begin
                        group_cnt <= group_cnt + 1'b1;
                    end
                end
            end
            DONE:begin
                done <= 1'b1;
                error <= 'd0;
                busy <= 'd0;
            end
            
        endcase
    end
end

assign input_loading = rst_n && (state == INPUT_LOADING);
assign bias_loading  = rst_n && (state == BIAS_LOADING);
assign computing     = rst_n && (state == COMPUTING);
assign draining      = rst_n && (state == DRAIN);

assign fc_in_features_o = fc_in_features_i;
assign fc_out_features_o = fc_out_features_i;
assign fc_input_base_addr_o = fc_input_base_addr_i;
assign fc_weight_base_addr_o = fc_weight_base_addr_i;
assign fc_quant_mult_o = fc_quant_mult_i;
assign fc_quant_shift_o = fc_quant_shift_i;
assign group_idx_o = group_cnt;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        weight_addr_begin <= 'd0;
        input_addr_begin <= 'd0;
        bias_addr_begin <= 'd0;
        group_start <= 'd0;
    end
    else begin
        // 默认清零
        weight_addr_begin <= 'd0;
        input_addr_begin <= 'd0;
        bias_addr_begin <= 'd0;
        group_start <= 'd0;

        // 进入INPUT_LOADING时拉高一拍
        if ((state != INPUT_LOADING) &&
            (next_state == INPUT_LOADING)) begin
            input_addr_begin <= 1'b1;
        end
        if ((state != BIAS_LOADING) &&
            (next_state == BIAS_LOADING)) begin
            bias_addr_begin <= 1'b1;
        end
        if ((state != COMPUTING) &&
            (next_state == COMPUTING)) begin
            weight_addr_begin <= 1'b1;
            group_start <= 1'b1;//每次刚进computing的时候拉高一拍
        end
    end
end

wire last_group;

//判断是不是最后一组
assign last_group = (group_cnt == ((fc_out_features_i - 32'd1) >> 4));
assign group_bias_count = (last_group && (fc_out_features_i[3:0] != 4'd0)) ? {1'b0 , fc_out_features_i[3:0]} : 5'd16;
//结束地址计算
assign fc_input_end_addr = fc_input_base_addr_i + fc_in_features_i;
//向上补齐到16的倍数，后面自动补0了
assign fc_weight_end_addr = fc_weight_base_addr_i + (((fc_out_features_i + 32'd15) >> 4) << 4) * fc_in_features_i;
assign group_bias_end_addr = fc_bias_base_addr_i + ({29'd0, group_cnt} << 6) + ({27'd0, group_bias_count} << 2);
assign group_bias_base_addr = fc_bias_base_addr_i + (group_cnt << 6);//bias一个32位，要多*4

endmodule
