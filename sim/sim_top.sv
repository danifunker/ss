// sim_top - the machine as the Verilator harness sees it.
//
// ss_core (lowered from VHDL by sim/gen_verilog.sh) plus the DDR3 arbiter
// from the real top, with the MiSTer side flattened to plain ports: one
// Avalon DDR slave, the hps_io ioctl and SD-block interfaces, the UART and
// the video signals. sim_main.cpp models everything on the far side of
// those ports. The OSD options are ports too, decoded as in
// SunSparcStation.sv.

module sim_top
(
	input         clk,
	input         reset,

	// DDR3 (after ddram_arb), 64-bit words
	input         ddr_busy,
	output  [7:0] ddr_burstcnt,
	output [28:0] ddr_addr,
	output        ddr_rd,
	output        ddr_we,
	output [63:0] ddr_din,
	output  [7:0] ddr_be,
	input  [63:0] ddr_dout,
	input         ddr_dout_ready,

	// hps_io: ROM download
	input         ioctl_download,
	input   [7:0] ioctl_index,
	input         ioctl_wr,
	input  [24:0] ioctl_addr,
	input  [15:0] ioctl_dout,
	output        ioctl_wait,

	// hps_io: SD blocks, slots 0 (HD0), 1 (HD1), 2 (CD)
	input   [3:0] img_mounted,
	input         img_readonly,
	input  [63:0] img_size,
	output [31:0] sd_lba0,
	output [31:0] sd_lba1,
	output [31:0] sd_lba2,
	output [31:0] sd_lba3,
	output  [3:0] sd_rd,
	output  [3:0] sd_wr,
	input   [3:0] sd_ack,
	output  [5:0] sd_blk_cnt,
	input  [12:0] sd_buff_addr,
	input  [15:0] sd_buff_dout,
	output [15:0] sd_buff_din0,
	output [15:0] sd_buff_din1,
	output [15:0] sd_buff_din2,
	output [15:0] sd_buff_din3,
	input         sd_buff_wr,

	input  [64:0] rtc,

	// ttya
	output        uart_txd,
	input         uart_rxd,

	// OSD options
	input         opt_disks2,     // O[1]: HD0+HD1
	input   [1:0] opt_cdrom,      // O[5:4]
	input         opt_noautoboot, // O[8]
	input         opt_serial,     // O[9]: console on ttya
	input         opt_cg3,        // O[10]
	input         opt_nocache,    // O[16]
	input         opt_l2tlb,      // O[17]
	input         opt_wb,         // O[18]
	input         opt_aow,        // O[19]
	input   [1:0] opt_iommu,      // O[21:20]

	// video
	output  [7:0] vga_r,
	output  [7:0] vga_g,
	output  [7:0] vga_b,
	output        vga_hs,
	output        vga_vs,
	output        vga_de,

	output        led_disk,
	output        led_user
);

wire        vram_clk, dram_clk;
wire        vram_wait, dram_wait;
wire  [7:0] vram_bc, dram_bc;
wire [28:0] vram_addr, dram_addr;
wire [63:0] vram_rdata, dram_rdata, vram_wdata, dram_wdata;
wire        vram_rvalid, dram_rvalid;
wire        vram_rd, dram_rd, vram_wr, dram_wr;
wire  [7:0] vram_be, dram_be;

ddram_arb ddram_arb
(
	.clk(clk),
	.reset(reset),

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

	.s_waitrequest(ddr_busy),
	.s_burstcount(ddr_burstcnt),
	.s_address(ddr_addr),
	.s_read(ddr_rd),
	.s_write(ddr_we),
	.s_writedata(ddr_din),
	.s_byteenable(ddr_be),
	.s_readdata(ddr_dout),
	.s_readdatavalid(ddr_dout_ready)
);

wire [2:0] scsi_conf   = opt_disks2 ? 3'd2 : 3'd0;
wire [7:0] reset_mask_rev = (opt_iommu==0) ? 8'h26 :
                            (opt_iommu==1) ? 8'h11 :
                            (opt_iommu==2) ? 8'h23 : 8'h30;

wire       clk_sys, vga_ce, vga_clk;
wire [15:0] audio_l, audio_r;
wire        fb_pal_clk, fb_pal_wr;
wire [23:0] fb_pal_d;
wire  [7:0] fb_pal_a;
wire        led_power;
wire        ps2_kbd_clk_in, ps2_kbd_data_in, ps2_mouse_clk_in, ps2_mouse_data_in;
wire  [2:0] ps2_kbd_led_status, ps2_kbd_led_use;
wire  [1:0] rmii_txd;
wire        rmii_txen;

ss_core ss_core
(
	.clk_50m(clk),
	.clk_sys(clk_sys),
	.reset(reset),
	.vga_r(vga_r),
	.vga_g(vga_g),
	.vga_b(vga_b),
	.vga_hs(vga_hs),
	.vga_vs(vga_vs),
	.vga_de(vga_de),
	.vga_ce(vga_ce),
	.vga_clk(vga_clk),
	.audio_l(audio_l),
	.audio_r(audio_r),
	.fb_pal_clk(fb_pal_clk),
	.fb_pal_d(fb_pal_d),
	.fb_pal_a(fb_pal_a),
	.fb_pal_wr(fb_pal_wr),
	.led_disk(led_disk),
	.led_user(led_user),
	.led_power(led_power),

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
	.kbm_layout(8'h21),
	.wback(opt_wb),
	.aow(opt_aow),
	.cachena(~opt_nocache),
	.l2tlbena(opt_l2tlb),

	.vga_on(1'b1),
	.scsi_conf(scsi_conf),
	.scsi_cdconf(opt_cdrom),
	.tcx(~opt_cg3),
	.autoboot(~opt_noautoboot),
	.viboot(~opt_serial),

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
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wait(ioctl_wait),
	.rtc(rtc),

	// no PS/2 devices: the lines idle high
	.ps2_kbd_clk_out(1'b1),
	.ps2_kbd_data_out(1'b1),
	.ps2_kbd_clk_in(ps2_kbd_clk_in),
	.ps2_kbd_data_in(ps2_kbd_data_in),
	.ps2_kbd_led_status(ps2_kbd_led_status),
	.ps2_kbd_led_use(ps2_kbd_led_use),
	.ps2_mouse_clk_out(1'b1),
	.ps2_mouse_data_out(1'b1),
	.ps2_mouse_clk_in(ps2_mouse_clk_in),
	.ps2_mouse_data_in(ps2_mouse_data_in),

	.rmii_rxd(2'b00),
	.rmii_txd(rmii_txd),
	.rmii_txen(rmii_txen),
	.rmii_clk(1'b0),
	.uart_txd(uart_txd),
	.uart_rxd(uart_rxd)
);

endmodule
