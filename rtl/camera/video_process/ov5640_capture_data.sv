module ov5640_capture_data(
    input           rst_n,            //复位信号，低电平有效
                                       
    //摄像头接�?                       
    input           cam_pclk,         //Camera像素时钟
    input           cam_vsync,        //Camera场同步信�?
    input           cam_href,         //Camera行同步信�?
    input   [7:0]   cam_data,         //Camera数据
    output          cam_rst_n,        //Camera复位信号，低电平有效
    output          cam_pwdn,         //Camera电源休眠信号，高电平有效
                                       
    //Video接口                        
    output          vid_clk,          //Video时钟
    output          vid_ce,           //Video时钟使能信号，高电平有效
    output          vid_vsync,        //Video场同步信�?
    output          vid_active_video, //Video数据有效信号
    output  [23:0]  vid_data          //Video数据，RGB888格式
    );

//parameter define
parameter WAIT_FRAME = 10;            //等待摄像头输出的帧个�?

//reg define
reg            rst_n_d0 ;
reg            rst_n_sync ;
reg            cam_vsync_d0;
reg            cam_vsync_d1;
reg            cam_href_d0;
reg            cam_href_d1;
reg            byte_flag_d0;

reg  [5:0]     frame_cnt;      //对摄像头输出的帧进行计数   
reg            wait_done;      //等待摄像头输出的帧数完成
reg  [7:0]     cam_data_d0;
reg            byte_flag;
reg  [15:0]    rgb565_data;

//wire define
wire           pos_vsync;
wire [23:0]    rgb888_data;

//输入场同步信号的上升�?
assign pos_vsync = ~cam_vsync_d1 & cam_vsync_d0;

//摄像头复位信号，低电平有�?  1：不复位
assign cam_rst_n = 1'b1;

//电源休眠信号，高电平有效  0：电源不休眠
assign cam_pwdn = 1'b0;

assign vid_clk = cam_pclk;

//16位RGB565�?24位RGB888
assign rgb888_data = {rgb565_data[15:11],3'b0,rgb565_data[10:5],2'b0,rgb565_data[4:0],3'b0};
assign vid_data = wait_done ?  rgb888_data : 24'd0;

assign vid_vsync = wait_done ? cam_vsync_d1 : 1'd0;
assign vid_active_video = wait_done ? cam_href_d1 : 1'b0;

//在vid_active_video为高电平期间，数据有效时cmos_frame_ce = 1
//在vid_active_video为低电平期间，时钟需要一致保持有效，�?以cmos_frame_ce = 1
assign vid_ce = wait_done ? ((byte_flag_d0 & vid_active_video) || (!vid_active_video)) : 1'b0;

//对复位信号做异步复位，同步释放的处理
always @(posedge cam_pclk or negedge rst_n) begin
    if(!rst_n) begin
        rst_n_d0 <= 1'b0;
        rst_n_sync <= 1'b0;
    end
    else begin
        rst_n_d0 <= 1'b1;
        rst_n_sync <= rst_n_d0;
    end
end

//对行场同步信号进行打�?
always @(posedge cam_pclk or negedge rst_n_sync) begin
    if(!rst_n_sync) begin
        cam_vsync_d0 <= 1'b0;
        cam_vsync_d1 <= 1'b0;
        cam_href_d0 <= 1'b0;
        cam_href_d1 <= 1'b0;
    end
    else begin
        cam_vsync_d0 <= cam_vsync;
        cam_vsync_d1 <= cam_vsync_d0;
        cam_href_d0 <= cam_href;
        cam_href_d1 <= cam_href_d0;
    end
end

//统计摄像头输出的帧数
always @(posedge cam_pclk or negedge rst_n_sync) begin
    if(!rst_n_sync)
        frame_cnt <= 4'd0;
    else if(pos_vsync && (frame_cnt < WAIT_FRAME))
        frame_cnt <= frame_cnt + 4'd1;
end 

//摄像头输出的帧个数达到预设的参数，拉高等待完成信�?
always @(posedge cam_pclk or negedge rst_n_sync) begin
    if(!rst_n_sync)
        wait_done <= 1'b0;
    else if(pos_vsync && (frame_cnt == WAIT_FRAME))  
        wait_done <= 1'b1;
end    

//8位数据转16位RGB565数据
always @(posedge cam_pclk or negedge rst_n_sync) begin
    if(!rst_n_sync) begin
        cam_data_d0 <= 8'd0;
        rgb565_data <= 16'd0;
        byte_flag <= 1'b0;
    end
    else if(cam_href) begin
        byte_flag <= ~byte_flag;
        cam_data_d0 <= cam_data;
        if(byte_flag)
            rgb565_data <= {cam_data_d0,cam_data};
    end
    else begin
        byte_flag <= 1'b0;
        cam_data_d0 <= 8'd0;
        rgb565_data <= 16'd0;
    end
end    

//对byte_flag信号打拍，作为输出像素数据的有效信号
always @(posedge cam_pclk or negedge rst_n_sync) begin
    if(!rst_n_sync)
        byte_flag_d0 <= 1'b0;
    else
        byte_flag_d0 <= byte_flag;
end        
    
endmodule    
