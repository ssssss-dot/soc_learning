// SPDX-FileCopyrightText: 2025 Espressif Systems (Shanghai) CO LTD
// SPDX-License-Identifier: Apache-2.0
// Adapted for this project: OV5645, 128x128, RGB565 (high byte first), MIPI 2 lanes.
// Reference: Espressif esp-video-components, esp_cam_sensor/sensors/ov5645/
// private_include/ov5645_mipi_2lane_24Minput_1280x960_rgb565_le_30fps.h
// Original reference SHA256: 8aa8b453528b2ebc53301f31bcdffde16eafd4cfecef79bc182a04c06fd81d87
// Changes: sequencing; centered square ISP crop; output size; RGB byte order.
// Brighter AEC target (64..72); 64-line startup exposure; automatic AEC/AGC retained.
// Input XCLK MUST be 24 MHz. Keep the reference PLL/HTS/VTS and MIPI timing.
// The 128x128 adaptation is register-reviewed, NOT verified on a physical camera.
// 0x5001[5] enables ISP scaling. Binned readout is 1312x972; offsets 176/6
// crop it to 960x960 before scaling to 128x128 (datasheet section 4.2).
// delay_ms is a POST-WRITE delay: wait after successful I2C completion.
// Before index 0: board power, XCLK, RESET/PWDN sequencing must already be ready.
// Controller: iterate until valid=0; old ctrl.sv INDEX_MAX=247 is insufficient.
// Camera output is CSI-2; the existing DVP capture module cannot receive it.
// See OV5645_CONFIGURATION.md and LICENSE.ov5645.txt in this directory.
module configuration_rom (
    input  logic [9:0]  index,
    output logic [15:0] reg_addr,
    output logic [7:0]  reg_data,
    output logic [15:0] delay_ms,
    output logic       valid
);
    localparam int unsigned CONFIG_COUNT = 300;
    logic [23:0] config_word;

    always_comb begin
        config_word = 24'h000000;
        delay_ms = 16'd0;
        valid = (index < CONFIG_COUNT);
        case (index)
            10'd0: config_word = 24'h310311;
            10'd1: begin config_word = 24'h300882; delay_ms = 16'd5; end // Software reset; wait 5 ms AFTER this write
            10'd2: config_word = 24'h300842; // Software standby during configuration
            10'd3: config_word = 24'h42020F; // Disable frame output during configuration
            10'd4: config_word = 24'h430061; // RGB565, high byte first (R[4:0],G[5:3]); then (G[2:0],B[4:0])
            10'd5: config_word = 24'h501F01; // ISP RGB output
            10'd6: config_word = 24'h500123; // ISP scale + color matrix + AWB enabled
            10'd7: config_word = 24'h310303;
            10'd8: config_word = 24'h350307; // Hold AEC/AGC manual while seeding exposure/gain
            10'd9: config_word = 24'h30021C;
            10'd10: config_word = 24'h3006C3;
            10'd11: config_word = 24'h300E45; // Two MIPI data lanes
            10'd12: config_word = 24'h480004; // Continuous clock; LP11 between packets; no line short packets
            10'd13: config_word = 24'h301740;
            10'd14: config_word = 24'h301800;
            10'd15: config_word = 24'h302E0B;
            10'd16: config_word = 24'h303713;
            10'd17: config_word = 24'h310801;
            10'd18: config_word = 24'h361106;
            10'd19: config_word = 24'h3612AB;
            10'd20: config_word = 24'h361450;
            10'd21: config_word = 24'h361804;
            10'd22: config_word = 24'h303418;
            10'd23: config_word = 24'h303521;
            10'd24: config_word = 24'h303670; // PLL multiplier 112; reference requires 24 MHz XCLK
            10'd25: config_word = 24'h350000; // Startup exposure: 0x00400 / 16 = 64 lines
            10'd26: config_word = 24'h350104; // Previously 16 lines; seed 64 lines before enabling AEC
            10'd27: config_word = 24'h350200;
            10'd28: config_word = 24'h350A00;
            10'd29: config_word = 24'h350B3F;
            10'd30: config_word = 24'h360009;
            10'd31: config_word = 24'h360143;
            10'd32: config_word = 24'h362033;
            10'd33: config_word = 24'h3621E0;
            10'd34: config_word = 24'h362201;
            10'd35: config_word = 24'h36302D;
            10'd36: config_word = 24'h363100;
            10'd37: config_word = 24'h363232;
            10'd38: config_word = 24'h363352;
            10'd39: config_word = 24'h363470;
            10'd40: config_word = 24'h363513;
            10'd41: config_word = 24'h363603;
            10'd42: config_word = 24'h37026E;
            10'd43: config_word = 24'h370352;
            10'd44: config_word = 24'h3704A0;
            10'd45: config_word = 24'h370533;
            10'd46: config_word = 24'h370866;
            10'd47: config_word = 24'h370912;
            10'd48: config_word = 24'h370B61;
            10'd49: config_word = 24'h370CC3;
            10'd50: config_word = 24'h370F10;
            10'd51: config_word = 24'h371508;
            10'd52: config_word = 24'h371701;
            10'd53: config_word = 24'h371B20;
            10'd54: config_word = 24'h373122;
            10'd55: config_word = 24'h373970;
            10'd56: config_word = 24'h39010A;
            10'd57: config_word = 24'h390502;
            10'd58: config_word = 24'h390610;
            10'd59: config_word = 24'h371986;
            10'd60: config_word = 24'h380000;
            10'd61: config_word = 24'h380100;
            10'd62: config_word = 24'h380200;
            10'd63: config_word = 24'h380306;
            10'd64: config_word = 24'h38040A;
            10'd65: config_word = 24'h38053F;
            10'd66: config_word = 24'h380607;
            10'd67: config_word = 24'h38079D;
            10'd68: config_word = 24'h380800; // Output width high
            10'd69: config_word = 24'h380980; // Output width low: 0x0080 = 128
            10'd70: config_word = 24'h380A00; // Output height high
            10'd71: config_word = 24'h380B80; // Output height low: 0x0080 = 128
            10'd72: config_word = 24'h380C07; // HTS high; total line length is NOT output width
            10'd73: config_word = 24'h380D68; // HTS low: 1896
            10'd74: config_word = 24'h380E03; // VTS high; total frame length is NOT output height
            10'd75: config_word = 24'h380FD8; // VTS low: 984
            10'd76: config_word = 24'h381000;
            10'd77: config_word = 24'h3811B0; // Center crop: 1312 - 2*176 = 960 columns
            10'd78: config_word = 24'h381200;
            10'd79: config_word = 24'h381306; // 972 - 2*6 = 960 rows before ISP scaling
            10'd80: config_word = 24'h381431;
            10'd81: config_word = 24'h381531;
            10'd82: config_word = 24'h382041;
            10'd83: config_word = 24'h382107;
            10'd84: config_word = 24'h382401;
            10'd85: config_word = 24'h382603;
            10'd86: config_word = 24'h382808;
            10'd87: config_word = 24'h3A0203;
            10'd88: config_word = 24'h3A03D8;
            10'd89: config_word = 24'h3A0801;
            10'd90: config_word = 24'h3A09F8;
            10'd91: config_word = 24'h3A0A01;
            10'd92: config_word = 24'h3A0BA4;
            10'd93: config_word = 24'h3A0E02;
            10'd94: config_word = 24'h3A0D02;
            10'd95: config_word = 24'h3A1403;
            10'd96: config_word = 24'h3A15D8;
            10'd97: config_word = 24'h3A1800;
            10'd98: config_word = 24'h3A19F8; // Keep reference AGC ceiling: 0x00F8 (15.5x)
            10'd99: config_word = 24'h3C0134;
            10'd100: config_word = 24'h3C0428;
            10'd101: config_word = 24'h3C0598;
            10'd102: config_word = 24'h3C0707;
            10'd103: config_word = 24'h3C09C2;
            10'd104: config_word = 24'h3C0A9C;
            10'd105: config_word = 24'h3C0B40;
            10'd106: config_word = 24'h3C0134;
            10'd107: config_word = 24'h400102;
            10'd108: config_word = 24'h400402;
            10'd109: config_word = 24'h400518;
            10'd110: config_word = 24'h40506E;
            10'd111: config_word = 24'h40518F;
            10'd112: config_word = 24'h4514BB;
            10'd113: config_word = 24'h4520B0;
            10'd114: config_word = 24'h460B37;
            10'd115: config_word = 24'h460C20;
            10'd116: config_word = 24'h481801;
            10'd117: config_word = 24'h481DF0;
            10'd118: config_word = 24'h481F50;
            10'd119: config_word = 24'h482370;
            10'd120: config_word = 24'h483114;
            10'd121: config_word = 24'h483710; // Reference MIPI global timing for the unchanged PLL
            10'd122: config_word = 24'h5000A7;
            10'd123: config_word = 24'h501D00;
            10'd124: config_word = 24'h503D00; // Real image output; color bar disabled
            10'd125: config_word = 24'h505C30;
            10'd126: config_word = 24'h518159;
            10'd127: config_word = 24'h518300;
            10'd128: config_word = 24'h5191F0;
            10'd129: config_word = 24'h519203;
            10'd130: config_word = 24'h568410;
            10'd131: config_word = 24'h5685A0;
            10'd132: config_word = 24'h56860C;
            10'd133: config_word = 24'h568778;
            10'd134: config_word = 24'h5A0008;
            10'd135: config_word = 24'h5A2100;
            10'd136: config_word = 24'h5A2400;
            10'd137: config_word = 24'h350300; // Enable automatic exposure and gain
            10'd138: config_word = 24'h5180FF;
            10'd139: config_word = 24'h5181F2;
            10'd140: config_word = 24'h518200;
            10'd141: config_word = 24'h518314;
            10'd142: config_word = 24'h518425;
            10'd143: config_word = 24'h518524;
            10'd144: config_word = 24'h518609;
            10'd145: config_word = 24'h518709;
            10'd146: config_word = 24'h51880A;
            10'd147: config_word = 24'h518975;
            10'd148: config_word = 24'h518A62;
            10'd149: config_word = 24'h518BEA;
            10'd150: config_word = 24'h518CA8;
            10'd151: config_word = 24'h518D42;
            10'd152: config_word = 24'h518E38;
            10'd153: config_word = 24'h518F56;
            10'd154: config_word = 24'h519042;
            10'd155: config_word = 24'h5191F8;
            10'd156: config_word = 24'h519204;
            10'd157: config_word = 24'h519370;
            10'd158: config_word = 24'h5194F0;
            10'd159: config_word = 24'h5195F0;
            10'd160: config_word = 24'h519603;
            10'd161: config_word = 24'h519701;
            10'd162: config_word = 24'h519804;
            10'd163: config_word = 24'h519912;
            10'd164: config_word = 24'h519A04;
            10'd165: config_word = 24'h519B00;
            10'd166: config_word = 24'h519C06;
            10'd167: config_word = 24'h519D82;
            10'd168: config_word = 24'h519E38;
            10'd169: config_word = 24'h53811E;
            10'd170: config_word = 24'h53825B;
            10'd171: config_word = 24'h538308;
            10'd172: config_word = 24'h53840B;
            10'd173: config_word = 24'h538584;
            10'd174: config_word = 24'h53868F;
            10'd175: config_word = 24'h538782;
            10'd176: config_word = 24'h538871;
            10'd177: config_word = 24'h538911;
            10'd178: config_word = 24'h538A01;
            10'd179: config_word = 24'h538B98;
            10'd180: config_word = 24'h530008;
            10'd181: config_word = 24'h53011E;
            10'd182: config_word = 24'h530210;
            10'd183: config_word = 24'h530300;
            10'd184: config_word = 24'h530408;
            10'd185: config_word = 24'h53051E;
            10'd186: config_word = 24'h530608;
            10'd187: config_word = 24'h530716;
            10'd188: config_word = 24'h530908;
            10'd189: config_word = 24'h530A1E;
            10'd190: config_word = 24'h530B04;
            10'd191: config_word = 24'h530C06;
            10'd192: config_word = 24'h548001;
            10'd193: config_word = 24'h54810E;
            10'd194: config_word = 24'h548218;
            10'd195: config_word = 24'h54832B;
            10'd196: config_word = 24'h548452;
            10'd197: config_word = 24'h548565;
            10'd198: config_word = 24'h548671;
            10'd199: config_word = 24'h54877D;
            10'd200: config_word = 24'h548887;
            10'd201: config_word = 24'h548991;
            10'd202: config_word = 24'h548A9A;
            10'd203: config_word = 24'h548BAA;
            10'd204: config_word = 24'h548CB8;
            10'd205: config_word = 24'h548DCD;
            10'd206: config_word = 24'h548EDD;
            10'd207: config_word = 24'h548FEA;
            10'd208: config_word = 24'h54901D;
            10'd209: config_word = 24'h558002;
            10'd210: config_word = 24'h558340;
            10'd211: config_word = 24'h558430;
            10'd212: config_word = 24'h558910;
            10'd213: config_word = 24'h558A00;
            10'd214: config_word = 24'h558BF8;
            10'd215: config_word = 24'h5780FC;
            10'd216: config_word = 24'h578113;
            10'd217: config_word = 24'h578203;
            10'd218: config_word = 24'h578620;
            10'd219: config_word = 24'h578740;
            10'd220: config_word = 24'h578808;
            10'd221: config_word = 24'h578908;
            10'd222: config_word = 24'h578A02;
            10'd223: config_word = 24'h578B01;
            10'd224: config_word = 24'h578C01;
            10'd225: config_word = 24'h578D0C;
            10'd226: config_word = 24'h578E02;
            10'd227: config_word = 24'h578F01;
            10'd228: config_word = 24'h579001;
            10'd229: config_word = 24'h58003F;
            10'd230: config_word = 24'h580116;
            10'd231: config_word = 24'h58020E;
            10'd232: config_word = 24'h58030D;
            10'd233: config_word = 24'h580417;
            10'd234: config_word = 24'h58053F;
            10'd235: config_word = 24'h58060B;
            10'd236: config_word = 24'h580706;
            10'd237: config_word = 24'h580804;
            10'd238: config_word = 24'h580904;
            10'd239: config_word = 24'h580A06;
            10'd240: config_word = 24'h580B0B;
            10'd241: config_word = 24'h580C09;
            10'd242: config_word = 24'h580D03;
            10'd243: config_word = 24'h580E00;
            10'd244: config_word = 24'h580F00;
            10'd245: config_word = 24'h581003;
            10'd246: config_word = 24'h581108;
            10'd247: config_word = 24'h58120A;
            10'd248: config_word = 24'h581303;
            10'd249: config_word = 24'h581400;
            10'd250: config_word = 24'h581500;
            10'd251: config_word = 24'h581604;
            10'd252: config_word = 24'h581709;
            10'd253: config_word = 24'h58180F;
            10'd254: config_word = 24'h581908;
            10'd255: config_word = 24'h581A06;
            10'd256: config_word = 24'h581B06;
            10'd257: config_word = 24'h581C08;
            10'd258: config_word = 24'h581D0C;
            10'd259: config_word = 24'h581E3F;
            10'd260: config_word = 24'h581F1E;
            10'd261: config_word = 24'h582012;
            10'd262: config_word = 24'h582113;
            10'd263: config_word = 24'h582221;
            10'd264: config_word = 24'h58233F;
            10'd265: config_word = 24'h582468;
            10'd266: config_word = 24'h582528;
            10'd267: config_word = 24'h58262C;
            10'd268: config_word = 24'h582728;
            10'd269: config_word = 24'h582808;
            10'd270: config_word = 24'h582948;
            10'd271: config_word = 24'h582A64;
            10'd272: config_word = 24'h582B62;
            10'd273: config_word = 24'h582C64;
            10'd274: config_word = 24'h582D28;
            10'd275: config_word = 24'h582E46;
            10'd276: config_word = 24'h582F62;
            10'd277: config_word = 24'h583060;
            10'd278: config_word = 24'h583162;
            10'd279: config_word = 24'h583226;
            10'd280: config_word = 24'h583348;
            10'd281: config_word = 24'h583466;
            10'd282: config_word = 24'h583544;
            10'd283: config_word = 24'h583664;
            10'd284: config_word = 24'h583728;
            10'd285: config_word = 24'h583866;
            10'd286: config_word = 24'h583948;
            10'd287: config_word = 24'h583A2C;
            10'd288: config_word = 24'h583B28;
            10'd289: config_word = 24'h583C26;
            10'd290: config_word = 24'h583DAE;
            10'd291: config_word = 24'h502500;
            10'd292: config_word = 24'h3A0F48; // AEC stable high: 72 (previously 56)
            10'd293: config_word = 24'h3A1040; // AEC stable low: 64 (previously 48)
            10'd294: config_word = 24'h3A1190; // Fast zone high: 144
            10'd295: config_word = 24'h3A1B48; // AEC stable exit high: 72
            10'd296: config_word = 24'h3A1E40; // AEC stable exit low: 64
            10'd297: config_word = 24'h3A1F20; // Fast zone low: 32
            10'd298: begin config_word = 24'h300802; delay_ms = 16'd5; end // Wake sensor; wait 5 ms before enabling frames
            10'd299: config_word = 24'h420200; // Enable frame output only after all settings are written
            default: valid = 1'b0;
        endcase
    end
    assign reg_addr = config_word[23:8];
    assign reg_data = config_word[7:0];
endmodule
