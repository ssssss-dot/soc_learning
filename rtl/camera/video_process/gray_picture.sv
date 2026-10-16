module gray_picture(
    input clk,
    input rst_n,

    //输入的经过capture_data模块采集的数据
    input               in_vid_ce,
    input               in_vid_vsync,
    input               in_vid_active,//调试用的场同步信号
    input      [23:0]   in_vid_data,

    //输出经过边缘检测算法的视频流数据
    output              out_vid_ce,
    output              out_vid_vsync,//调试用的场同步信号
    output              out_vid_active,
    output     [7:0]   out_vid_data//输出灰度图像，如果后续要做sobel算子处理，就变成8位输出一个gray
);
wire [7:0] r0;//存红色信号数据
wire [7:0] g0;//存绿色信号数据
wire [7:0] b0;//存蓝色信号数据

//*后的值
reg [15:0] r1;//存红色信号数据
reg [15:0] g1;//存绿色信号数据
reg [15:0] b1;//存蓝色信号数据

//红绿蓝按比例拼在一起，形成灰度
reg [15:0] gray_sum;//存灰度(亮度）加权求和的中间结果 77*R + 150*G + 29*B（会超过8位，所以要先存为16位的数字）
reg [7:0] gray;//把gray_sum/256，变成8位的最终灰度输出，最后用同一个灰度值把三个8位灰度数值变成24位的

//rgb888分开放
assign r0 = in_vid_data[23:16];
assign g0 = in_vid_data[15:8];
assign b0 = in_vid_data[7:0];

//延迟像素有效，场同步，激活信号
reg in_vid_ce_d1 , in_vid_vsync_d1 , in_vid_active_d1;
reg in_vid_ce_d2 , in_vid_vsync_d2 , in_vid_active_d2;
reg in_vid_ce_d3 , in_vid_vsync_d3 , in_vid_active_d3;

//像素有效，场同步，激活信号打拍延迟
always@(posedge clk or negedge rst_n)begin
    if(!rst_n) begin
        in_vid_ce_d1 <= 1'b0;
        in_vid_vsync_d1 <= 1'b0;
        in_vid_active_d1 <= 1'b0;

        in_vid_ce_d2 <= 1'b0;
        in_vid_vsync_d2 <= 1'b0;
        in_vid_active_d2 <= 1'b0;

        in_vid_ce_d3 <= 1'b0;
        in_vid_vsync_d3 <= 1'b0;
        in_vid_active_d3 <= 1'b0;
    end
    else begin
        in_vid_ce_d1 <= in_vid_ce;
        in_vid_ce_d2 <= in_vid_ce_d1;
        in_vid_ce_d3 <= in_vid_ce_d2;

        in_vid_vsync_d1 <= in_vid_vsync;
        in_vid_vsync_d2 <= in_vid_vsync_d1;
        in_vid_vsync_d3 <= in_vid_vsync_d2;

        in_vid_active_d1 <= in_vid_active;
        in_vid_active_d2 <= in_vid_active_d1;
        in_vid_active_d3 <= in_vid_active_d2;
    end
end

//灰度（亮度）计算，为了时序正确，分开每一步
//*
always@(posedge clk or negedge rst_n)begin
    if(!rst_n)begin
        r1 <= 'd0;
        g1 <= 'd0;
        b1 <= 'd0;
    end
    else begin
        r1 <= 'd77 * r0;
        g1 <= 'd150 * g0;
        b1 <= 'd29 * b0;
    end
end

//+
always@(posedge clk or negedge rst_n)begin
    if(!rst_n)begin
        gray_sum <= 'd0;
    end
    else begin
        gray_sum <= r1+g1+b1;
    end
end

//求平均
always@(posedge clk or negedge rst_n)begin
    if(!rst_n)begin
        gray <= 'd0;
    end
    else begin
        gray <= gray_sum[15:8];
    end
end

//输出相关信号
assign out_vid_ce = in_vid_ce_d3;
assign out_vid_vsync = in_vid_vsync_d3;
assign out_vid_active = in_vid_active_d3;
assign out_vid_data = gray;

endmodule