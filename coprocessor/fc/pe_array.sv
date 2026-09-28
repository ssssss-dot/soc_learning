`include "define.sv"

module fc_pe_array(
    input clk,
    input rst_n,

    input signed [`ByteWidth] weight_i [0:15],
    input last_i,
    input weight_valid_i [0:15],
    input signed [`ByteWidth] features_i,//features从左侧流入，重复逻辑在input_cache里面
    input features_valid_i,
    input en_i,
    input [`DataBus] fc_in_features,
    input [`DataBus] fc_out_features,
    input clear,
    output signed [`DataBus] result_o[0:15],
    output reg valid_o [0:15]

);

//pe阵列中间的连线
wire last_link [0:16];
wire signed [`ByteWidth] features_link [0:16];
wire valid_link [0:16];
wire [`DataBus] result_link [0:16];

//多个pe生成
genvar col;
generate
    for (col = 0 ; col <= 15 ; col++)begin : pe_block

        pe_os u_pe_us(
            .clk(clk),
            .rst_n(rst_n),

            .en_i(en_i),
            .en_o(),
            .last_i(((col == 0) ? last_i : last_link[col])),
            .last_o(last_link[col+1]),
            .valid_i(((col == 0) ? features_valid_i : valid_link[col])),
            .valid_o(valid_link[col+1]),
            .clear(clear),
            .up(weight_i[col]),
            .left((col == 0) ? features_i : features_link[col]),
            .right(features_link[col+1]),
            .down(),
            .acc_out(result_link[col])

        );

        assign result_o[col] = result_link[col];
        always @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin
                valid_o[col] <= 1'b0;
            end
            else if (clear) begin
                valid_o[col] <= 1'b0;
            end
            else begin
                valid_o[col] <= en_i
                            && ((col == 0)
                                ? features_valid_i
                                : valid_link[col])
                            && ((col == 0)
                                ? last_i
                                : last_link[col]);
            end
        end

    end
endgenerate

endmodule