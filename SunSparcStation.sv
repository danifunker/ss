//============================================================================
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//
//============================================================================

module emu
(
	`include "sys/emu_ports.vh"
);

///////// Default values for ports not used in this core /////////

assign ADC_BUS  = 'Z;

assign {UART_RTS, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
assign {SDRAM_DQ, SDRAM_A, SDRAM_BA, SDRAM_CLK, SDRAM_CKE, SDRAM_DQML, SDRAM_DQMH, SDRAM_nWE, SDRAM_nCAS, SDRAM_nRAS, SDRAM_nCS} = 'Z;

// USER_IO is open-drain in the stock framework (0 = low, 1 = released):
// the RMII Ethernet PHY option, which needed push-pull 50 MHz outputs,
// cannot work and is gone. See docs/REWORK.md, phase 3.
assign USER_OUT = '1;

assign VGA_SL = 0;
assign VGA_F1 = 0;
assign VGA_SCALER = 1;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

assign AUDIO_S = 1;
assign AUDIO_MIX = 0;

assign BUTTONS = 0;

`ifdef MISTER_FB
assign FB_FORMAT = 5'b00011; // 8bpp
assign FB_WIDTH = 1024;
assign FB_HEIGHT = 768;
assign FB_BASE = 32'h3E400000;
assign FB_STRIDE = 1024;
assign FB_FORCE_BLANK = 0;
`endif

assign LED_POWER[1]=0;
assign LED_DISK[1]=0;

//////////////////////////////////////////////////////////////////

wire clk_sys;


/* 0         1         2         3          4         5         6   
   01234567890123456789012345678901 23456789012345678901234567890123
   0123456789ABCDEFGHIJKLMNOPQRSTUV 0123456789ABCDEFGHIJKLMNOPQRSTUV
    XXXXXX XXXXXX  XXXXXX X
*/

`include "build_id.v" 

localparam CONF_STR = {
    "SunSparcStation;;" ,
    "-;" ,
    "O1,SCSI disks,HD0,HD0+HD1;" ,
    "SC0,VHDIMGHDARAW,HD;" ,
    "SC1,VHDIMGHDARAW,HD2;" ,
    "O45,CDROM,OFF,2048,512;" ,
    "SC2,ISO,CDROM;" ,
    "O67,Aspect ratio,4:3,Full Screen,[ARC1],[ARC2];" ,
    "O8,AutoBoot,ON,OFF;" ,
    "O9,Boot,Video,Serial;" ,
    "OA,Video,TCX,CG3;" ,
    "OB,Video,Internal,Scaler framebuffer;" ,
    "OCD,Keyboard,US,FR,DE,ES;" ,
    "-;" ,
    "R0,RESET;" ,
    "-;" ,
    "OG,Cachena,ON,OFF;" ,
    "OH,L2TLB,OFF,ON;" ,
`ifdef SS20
    "OI,WB,OFF,ON;" ,
    "OJ,AOW,OFF,ON;" ,
`endif
    "OKL,IOMMU rev,26 (Default),11 (Next),23,30;" ,
    "F,ROM,BIOS;" ,
    "-;" ,
    "V,v",`BUILD_DATE 
};

wire forced_scandoubler;

wire [127:0] status;
wire  [2:0]  img_mounted;
wire  img_readonly;
wire  [63:0] img_size;
wire  [31:0] sd_lba0,sd_lba1,sd_lba2;
wire  [2:0] sd_rd;
wire  [2:0] sd_wr;
wire  [2:0] sd_ack;
wire  [7:0] sd_buff_addr;
wire  [15:0] sd_buff_dout;
wire  [15:0] sd_buff_din0,sd_buff_din1,sd_buff_din2;
wire  sd_buff_wr;
wire  ioctl_download;
wire [15:0] ioctl_index;
wire  ioctl_wr;
wire  [26:0] ioctl_addr;
wire  [15:0] ioctl_dout;
wire  ioctl_wait;
wire  [64:0] RTC;
wire  ps2_kbd_clk_out,ps2_kbd_data_out,ps2_kbd_clk_in,ps2_kbd_data_in;
wire  [2:0] ps2_kbd_led_status,ps2_kbd_led_use;
wire  ps2_mouse_clk_out,ps2_mouse_data_out,ps2_mouse_clk_in,ps2_mouse_data_in;
  
hps_io #(
    .CONF_STR(CONF_STR),
    .PS2DIV(1000),
    .WIDE(1),
    .VDNUM(3),
    .PS2WE(0))
hps_io
 (
  .clk_sys(clk_sys),
  .HPS_BUS(HPS_BUS),
  .ps2_kbd_clk_out(ps2_kbd_clk_out),
  .ps2_kbd_data_out(ps2_kbd_data_out),
  .ps2_kbd_clk_in(ps2_kbd_clk_in),
  .ps2_kbd_data_in(ps2_kbd_data_in),
  .ps2_kbd_led_status(ps2_kbd_led_status),
  .ps2_kbd_led_use(ps2_kbd_led_use),
  .ps2_mouse_clk_out(ps2_mouse_clk_out),
  .ps2_mouse_data_out(ps2_mouse_data_out),
  .ps2_mouse_clk_in(ps2_mouse_clk_in),
  .ps2_mouse_data_in(ps2_mouse_data_in),

  .status(status),
  .status_in(status),

  .img_mounted(img_mounted),
  .img_readonly(img_readonly),
  .img_size(img_size),

  .sd_lba('{sd_lba0, sd_lba1, sd_lba2}),
  .sd_blk_cnt('{0, 0, 0}),
  .sd_rd(sd_rd),
  .sd_wr(sd_wr),
  .sd_ack(sd_ack),

  .sd_buff_addr(sd_buff_addr),
  .sd_buff_dout(sd_buff_dout),
  .sd_buff_din('{sd_buff_din0,sd_buff_din1,sd_buff_din2}),
  .sd_buff_wr(sd_buff_wr),

  .ioctl_download(ioctl_download),
  .ioctl_index(ioctl_index),
  .ioctl_wr(ioctl_wr),
  .ioctl_addr(ioctl_addr),
  .ioctl_dout(ioctl_dout),
  .ioctl_wait(ioctl_wait),
  .RTC(RTC)

);

// ss_core's scsi_conf: 0 image, 1 direct SD, 2 image+image, 3 SD+image,
// 4 image+SD. The stock framework has no SDIO pins, so only the image
// modes remain (status[3:2] stay free, so old configs do not map an SD
// mode onto a new option). The upstream top declared both of these as
// 1-bit wires, so only the low bit of each OSD field reached the core.
wire [2:0] scsi_conf   = status[1] ? 3'd2 : 3'd0;
wire [1:0] scsi_cdconf = status[5:4];

wire [1:0] ar = status[7:6];

assign VIDEO_ARX = (!ar) ? 12'd4 : (ar - 1'd1);
assign VIDEO_ARY = (!ar) ? 12'd3 : 12'd0;

wire autoboot  = ~status[8];
wire viboot    = ~status[9];
wire tcx       = ~status[10];
`ifdef MISTER_FB
assign FB_EN = status[11];
`endif
wire vga_on  = 1;

/* PS2 to Sun keyboard layout
  "Layouts for Type 4, 5, and 5c Keyboards"
  "https://docs.oracle.com/cd/E19253-01/817-2521/new-311/index.html"
  21 : USA,    QWERTY, ANSI layout
  23 : France, AZERTY, ISO  layout
  25 : Germany, QWERTZ
  2A : Spain
*/
wire [7:0] kbm_layout = (status[13:12]==0)?8'h21:
                        (status[13:12]==1)?8'h23:
                        (status[13:12]==2)?8'h25:8'h2A;

wire cachena   = !status[16];
wire l2tlbena  = status[17];
wire wback     = status[18];
wire aow       = status[19];

wire [7:0] reset_mask_rev = (status[21:20]==0)?8'h26:
                            (status[21:20]==1)?8'h11:
                            (status[21:20]==2)?8'h23:8'h30;
                            
///////////////////////   CLOCKS   ///////////////////////////////

wire sd_sck;
wire [3:0] sd_dat;
wire sd_cmd;
wire sd_cd;

wire [1:0] rmii_txd;
wire rmii_txen;

wire fb_pal_clk, fb_pal_wr;
wire [23:0] fb_pal_d;
wire [7:0] fb_pal_a;
`ifdef MISTER_FB_PALETTE
assign FB_PAL_CLK  = fb_pal_clk;
assign FB_PAL_DOUT = fb_pal_d;
assign FB_PAL_ADDR = fb_pal_a;
assign FB_PAL_WR   = fb_pal_wr;
`endif

// ss_core has two DDR3 ports (video; CPU + BIOS download); the stock
// framework has one. ddram_arb merges them, video first.
wire        vram_clk, dram_clk;
wire        vram_wait, dram_wait;
wire  [7:0] vram_bc, dram_bc;
wire [28:0] vram_addr, dram_addr;
wire [63:0] vram_rdata, dram_rdata, vram_wdata, dram_wdata;
wire        vram_rvalid, dram_rvalid;
wire        vram_rd, dram_rd, vram_wr, dram_wr;
wire  [7:0] vram_be, dram_be;

assign DDRAM_CLK = clk_sys;

ddram_arb ddram_arb
(
	.clk(clk_sys),
	.reset(RESET),

	.m0_waitrequest(vram_wait),
	.m0_burstcount(vram_bc),
	.m0_address(vram_addr),
	.m0_read(vram_rd),
	.m0_write(vram_wr),
	.m0_writedata(vram_wdata),
	.m0_byteenable(vram_be),
	.m0_readdata(vram_rdata),
	.m0_readdatavalid(vram_rvalid),

	.m1_waitrequest(dram_wait),
	.m1_burstcount(dram_bc),
	.m1_address(dram_addr),
	.m1_read(dram_rd),
	.m1_write(dram_wr),
	.m1_writedata(dram_wdata),
	.m1_byteenable(dram_be),
	.m1_readdata(dram_rdata),
	.m1_readdatavalid(dram_rvalid),

	.s_waitrequest(DDRAM_BUSY),
	.s_burstcount(DDRAM_BURSTCNT),
	.s_address(DDRAM_ADDR),
	.s_read(DDRAM_RD),
	.s_write(DDRAM_WE),
	.s_writedata(DDRAM_DIN),
	.s_byteenable(DDRAM_BE),
	.s_readdata(DDRAM_DOUT),
	.s_readdatavalid(DDRAM_DOUT_READY)
);

// the "Direct SD" pins: not available in the stock framework
wire [3:0] sd_dat_nc;
wire       sd_cmd_nc, sd_sck_nc;
   
wire reset = RESET | status[0];

   
ss_core 
#(
`ifndef SS20
  .SYSFREQ(60000000),
  .SS20(0),
  .NCPUS(1),
  .TRACE(1),
`else
  .SYSFREQ(55000000),
  .SS20(1),
  .NCPUS(3),
  .TRACE(1),
`endif  
  .FPU_MULTI(0),
  .TCX_ACCEL(1)
  )
ss_core
(
 .clk_50m(CLK_50M),
 .clk_sys(clk_sys),
 .reset(reset),
 .vga_r(VGA_R),
 .vga_g(VGA_G),
 .vga_b(VGA_B),
 .vga_hs(VGA_HS),
 .vga_vs(VGA_VS),
 .vga_de(VGA_DE),
 .vga_ce(CE_PIXEL),
 .vga_clk(CLK_VIDEO),
 
 .audio_l(AUDIO_L),
 .audio_r(AUDIO_R),

 .fb_pal_clk(fb_pal_clk),
 .fb_pal_d(fb_pal_d),
 .fb_pal_a(fb_pal_a),
 .fb_pal_wr(fb_pal_wr),
    
 .led_disk(LED_DISK[0]),
 .led_user(LED_USER),
 .led_power(LED_POWER[0]),
    
 .sd_sck(sd_sck_nc),
 .sd_dat(sd_dat_nc),
 .sd_cmd(sd_cmd_nc),
 .ddram_clk(vram_clk),
 .ddram_waitrequest(vram_wait),
 .ddram_burstcount(vram_bc),
 .ddram_address(vram_addr),
 .ddram_readdata(vram_rdata),
 .ddram_readdatavalid(vram_rvalid),
 .ddram_read(vram_rd),
 .ddram_writedata(vram_wdata),
 .ddram_byteenable(vram_be),
 .ddram_write(vram_wr),

 .ddram2_clk(dram_clk),
 .ddram2_waitrequest(dram_wait),
 .ddram2_burstcount(dram_bc),
 .ddram2_address(dram_addr),
 .ddram2_readdata(dram_rdata),
 .ddram2_readdatavalid(dram_rvalid),
 .ddram2_read(dram_rd),
 .ddram2_writedata(dram_wdata),
 .ddram2_byteenable(dram_be),
 .ddram2_write(dram_wr),

 .reset_mask_rev(reset_mask_rev),
 .kbm_layout(kbm_layout),
 .wback(wback),
 .aow(aow),
 .cachena(cachena),
 .l2tlbena(l2tlbena),
 
 .vga_on(vga_on),
 .scsi_conf(scsi_conf),
 .scsi_cdconf(scsi_cdconf),
 .tcx(tcx),
 .autoboot(autoboot),
 .viboot(viboot),
 
 .img_mounted(img_mounted),
 .img_readonly(img_readonly),
 .img_size(img_size),
 .sd_lba0(sd_lba0),
 .sd_lba1(sd_lba1),
 .sd_lba2(sd_lba2),
 .sd_rd(sd_rd),
 .sd_wr(sd_wr),
 .sd_ack(sd_ack),
 .sd_buff_addr(sd_buff_addr),
 .sd_buff_dout(sd_buff_dout),
 .sd_buff_din0(sd_buff_din0),
 .sd_buff_din1(sd_buff_din1),
 .sd_buff_din2(sd_buff_din2),
 .sd_buff_wr(sd_buff_wr),
 .ioctl_download(ioctl_download),
 .ioctl_index(ioctl_index[7:0]),
 .ioctl_wr(ioctl_wr),
 .ioctl_addr(ioctl_addr[24:0]),
 .ioctl_dout(ioctl_dout),
 .ioctl_wait(ioctl_wait),
 .rtc(RTC),
 .ps2_kbd_clk_out(ps2_kbd_clk_out),
 .ps2_kbd_data_out(ps2_kbd_data_out),
 .ps2_kbd_clk_in(ps2_kbd_clk_in),
 .ps2_kbd_data_in(ps2_kbd_data_in),
 .ps2_kbd_led_status(ps2_kbd_led_status),
 .ps2_kbd_led_use(ps2_kbd_led_use),
 .ps2_mouse_clk_out(ps2_mouse_clk_out),
 .ps2_mouse_data_out(ps2_mouse_data_out),
 .ps2_mouse_clk_in(ps2_mouse_clk_in),
 .ps2_mouse_data_in(ps2_mouse_data_in),
 .rmii_rxd(2'b00),
 .rmii_txd(rmii_txd),
 .rmii_txen(rmii_txen),
 .rmii_clk(1'b0),
 .uart_txd(UART_TXD),
 .uart_rxd(UART_RXD)

);

endmodule
