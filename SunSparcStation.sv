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

// The OSD (status bits in brackets; setopt.sh names them):
//  - the model (text), the images: HD0 at SCSI target 3, HD1 at 1, the CD
//    at 6, the NVRAM. A disk is there while its image is mounted, and an
//    image can be mounted at any time (the targets report the change);
//  - Video: graphics card (TCX/CG3) [10], output (the core's video or
//    the MiSTer framebuffer) [11], aspect ratio [7:6], scale [15:14];
//  - System: console (screen or ttya) [9], auto boot [8], keyboard
//    layout [13:12], CD-ROM block size [4], memory (SS20) [23:22];
//  - Advanced (developer tuning): cache [16], L2TLB [17], write-back [18],
//    AOW [19], IOMMU revision [21:20].
// [1] (two disks) and [5] (CD off) are retired.
localparam CONF_STR = {
    "SunSparcStation;;" ,
`ifdef SS20
    "-,SPARCstation 20 3xCPU 55MHz;" ,
`else
    "-,SPARCstation 5 60MHz;" ,
`endif
    "-;" ,
    "SC0,VHDIMGHDARAW,Disk 0 (SCSI 3);" ,
    "SC1,VHDIMGHDARAW,Disk 1 (SCSI 1);" ,
    "SC2,ISO,CD-ROM (SCSI 6);" ,
    "SC3,NVR,NVRAM;" ,
    "-;" ,
    "P1,Video;" ,
    "P1-;" ,
    "P1OA,Graphics card,TCX,CG3;" ,
    "P1OB,Output,Core video,MiSTer framebuffer;" ,
    "P1O67,Aspect ratio,4:3,Full Screen,[ARC1],[ARC2];" ,
    "P1OEF,Scale,Normal,V-Integer,Narrower HV-Integer,Wider HV-Integer;" ,
    "P2,System;" ,
    "P2-;" ,
    "P2O9,Console,Screen+keyboard,Serial (ttya);" ,
    "P2O8,Auto boot,On,Off;" ,
    "P2OCD,Keyboard,US,FR,DE,ES;" ,
    "P2O4,CD-ROM block size,2048,512;" ,
`ifdef SS20
    "P2OMN,Memory,464 MB,256 MB,128 MB,64 MB;" ,
`endif
    "P2OOQ,Network,Off,eth0,eth1,macvlan,tap0;" ,
    "P3,Advanced;" ,
    "P3-;" ,
    "P3OG,Cache,On,Off;" ,
    "P3OH,L2TLB,Off,On;" ,
`ifdef SS20
    "P3OI,Write-back cache,Off,On;" ,
    "P3OJ,AOW,Off,On;" ,
`endif
    "P3OKL,IOMMU rev,26 (Default),11 (Next),23,30;" ,
    "-;" ,
    "F,ROM,Load boot ROM;" ,
    "R0,Reset;" ,
    "-;" ,
    "V,v",`BUILD_DATE 
};

wire forced_scandoubler;

wire [127:0] status;
wire  [3:0]  img_mounted;
wire  img_readonly;
wire  [63:0] img_size;
wire  [31:0] sd_lba0,sd_lba1,sd_lba2,sd_lba3;
wire  [3:0] sd_rd;
wire  [3:0] sd_wr;
wire  [3:0] sd_ack;
wire  [12:0] sd_buff_addr;
wire  [5:0] sd_blk_cnt;                 // the SCSI request's blocks - 1
wire  [15:0] sd_buff_dout;
wire  [15:0] sd_buff_din0,sd_buff_din1,sd_buff_din2,sd_buff_din3;
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
    .VDNUM(4),
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

  .sd_lba('{sd_lba0, sd_lba1, sd_lba2, sd_lba3}),
  .sd_blk_cnt('{sd_blk_cnt, sd_blk_cnt, sd_blk_cnt, 6'd0}),
  .sd_rd(sd_rd),
  .sd_wr(sd_wr),
  .sd_ack(sd_ack),

  .sd_buff_addr(sd_buff_addr),
  .sd_buff_dout(sd_buff_dout),
  .sd_buff_din('{sd_buff_din0,sd_buff_din1,sd_buff_din2,sd_buff_din3}),
  .sd_buff_wr(sd_buff_wr),

  .ioctl_download(ioctl_download),
  .ioctl_index(ioctl_index),
  .ioctl_wr(ioctl_wr),
  .ioctl_addr(ioctl_addr),
  .ioctl_dout(ioctl_dout),
  .ioctl_wait(ioctl_wait),
  .RTC(RTC)

);

// ss_core's scsi_conf 2: both disks (each answers while its image is
// mounted); scsi_cdconf: the CD, 1 with 2048-byte blocks, 2 with 512.
wire [2:0] scsi_conf   = 3'd2;
wire [1:0] scsi_cdconf = status[4] ? 2'd2 : 2'd1;

// Memory (SS20): 464 MB (all of it), 256, 128 or 64 MB
`ifdef SS20
wire [1:0] ram_sel = status[23:22];
`else
wire [1:0] ram_sel = 2'd0;
`endif

wire [1:0] ar = status[7:6];

// VIDEO_ARX/ARY and VGA_DE come from the framework's video_freak (below):
// the aspect ratio and the OSD's Scale (V-Integer keeps every line an
// integer number of output lines).
wire core_de;

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


wire fb_pal_clk, fb_pal_wr;
wire [23:0] fb_pal_d;
wire [7:0] fb_pal_a;
`ifdef MISTER_FB_PALETTE
assign FB_PAL_CLK  = fb_pal_clk;
assign FB_PAL_DOUT = fb_pal_d;
assign FB_PAL_ADDR = fb_pal_a;
assign FB_PAL_WR   = fb_pal_wr;
`endif

// ss_core has three DDR3 masters (video; CPU + BIOS download; the Ethernet
// mailbox); the stock framework has one port. One ddram_arb merges the
// Ethernet mailbox (single beats, rare) into the CPU's, a second merges that
// with video, video first.
wire        vram_clk, dram_clk;
wire        vram_wait, dram_wait;
wire  [7:0] vram_bc, dram_bc;
wire [28:0] vram_addr, dram_addr;
wire [63:0] vram_rdata, dram_rdata, vram_wdata, dram_wdata;
wire        vram_rvalid, dram_rvalid;
wire        vram_rd, dram_rd, vram_wr, dram_wr;
wire  [7:0] vram_be, dram_be;
wire        eth_wait, cpu_wait;
wire  [7:0] eth_bc, cpu_bc;
wire [28:0] eth_addr, cpu_addr;
wire [63:0] eth_rdata, cpu_rdata, eth_wdata, cpu_wdata;
wire        eth_rvalid, cpu_rvalid;
wire        eth_rd, cpu_rd, eth_wr, cpu_wr;
wire  [7:0] eth_be, cpu_be;

assign DDRAM_CLK = clk_sys;

ddram_arb ddram_arb_eth
(
	.clk(clk_sys),
	.reset(RESET),

	.m0_waitrequest(eth_wait),
	.m0_burstcount(eth_bc),
	.m0_address(eth_addr),
	.m0_read(eth_rd),
	.m0_write(eth_wr),
	.m0_writedata(eth_wdata),
	.m0_byteenable(eth_be),
	.m0_readdata(eth_rdata),
	.m0_readdatavalid(eth_rvalid),

	.m1_waitrequest(cpu_wait),
	.m1_burstcount(cpu_bc),
	.m1_address(cpu_addr),
	.m1_read(cpu_rd),
	.m1_write(cpu_wr),
	.m1_writedata(cpu_wdata),
	.m1_byteenable(cpu_be),
	.m1_readdata(cpu_rdata),
	.m1_readdatavalid(cpu_rvalid),

	.s_waitrequest(dram_wait),
	.s_burstcount(dram_bc),
	.s_address(dram_addr),
	.s_read(dram_rd),
	.s_write(dram_wr),
	.s_writedata(dram_wdata),
	.s_byteenable(dram_be),
	.s_readdata(dram_rdata),
	.s_readdatavalid(dram_rvalid)
);

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
 .vga_de(core_de),
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
 .ddram2_waitrequest(cpu_wait),
 .ddram2_burstcount(cpu_bc),
 .ddram2_address(cpu_addr),
 .ddram2_readdata(cpu_rdata),
 .ddram2_readdatavalid(cpu_rvalid),
 .ddram2_read(cpu_rd),
 .ddram2_writedata(cpu_wdata),
 .ddram2_byteenable(cpu_be),
 .ddram2_write(cpu_wr),

 .reset_mask_rev(reset_mask_rev),
 .kbm_layout(kbm_layout),
 .wback(wback),
 .aow(aow),
 .cachena(cachena),
 .l2tlbena(l2tlbena),
 
 .vga_on(vga_on),
 .scsi_conf(scsi_conf),
 .scsi_cdconf(scsi_cdconf),
 .ram_sel(ram_sel),
 .tcx(tcx),
 .autoboot(autoboot),
 .viboot(viboot),
 
 .img_mounted(img_mounted),
 .img_readonly(img_readonly),
 .img_size(img_size),
 .sd_lba0(sd_lba0),
 .sd_lba1(sd_lba1),
 .sd_lba2(sd_lba2),
 .sd_lba3(sd_lba3),
 .sd_rd(sd_rd),
 .sd_wr(sd_wr),
 .sd_ack(sd_ack),
 .sd_blk_cnt(sd_blk_cnt),
 .sd_buff_addr(sd_buff_addr),
 .sd_buff_dout(sd_buff_dout),
 .sd_buff_din0(sd_buff_din0),
 .sd_buff_din1(sd_buff_din1),
 .sd_buff_din2(sd_buff_din2),
 .sd_buff_din3(sd_buff_din3),
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
 .ddram3_waitrequest(eth_wait),
 .ddram3_burstcount(eth_bc),
 .ddram3_address(eth_addr),
 .ddram3_readdata(eth_rdata),
 .ddram3_readdatavalid(eth_rvalid),
 .ddram3_read(eth_rd),
 .ddram3_writedata(eth_wdata),
 .ddram3_byteenable(eth_be),
 .ddram3_write(eth_wr),
 .eth_ena(|status[26:24]),
 .uart_txd(UART_TXD),
 .uart_rxd(UART_RXD)

);

video_freak video_freak
(
	.CLK_VIDEO(CLK_VIDEO),
	.CE_PIXEL(CE_PIXEL),
	.VGA_VS(VGA_VS),
	.HDMI_WIDTH(HDMI_WIDTH),
	.HDMI_HEIGHT(HDMI_HEIGHT),
	.VGA_DE(VGA_DE),
	.VIDEO_ARX(VIDEO_ARX),
	.VIDEO_ARY(VIDEO_ARY),
	.VGA_DE_IN(core_de),
	.ARX((!ar) ? 12'd4 : (ar - 1'd1)),
	.ARY((!ar) ? 12'd3 : 12'd0),
	.CROP_SIZE(12'd0),
	.CROP_OFF(5'd0),
	.SCALE({1'b0, status[15:14]})
);

endmodule
