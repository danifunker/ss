//============================================================================
//  Two Avalon-MM masters onto the one DDRAM port of the stock MiSTer
//  framework. ss_core has two DDR3 ports (video; CPU + BIOS download), which
//  the core's old, modified sys_top provided; Template_MiSTer provides one.
//
//  Each master is a plomb_avalon64 bridge with at most one burst in flight,
//  so a master is granted for a whole transaction - a read until its last
//  readdatavalid beat, a write until its last beat is accepted - and read
//  data needs no routing FIFO. Master 0 wins a tie (video must not
//  underrun). A grant costs one cycle.
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//============================================================================

module ddram_arb #(parameter AW = 29)
(
	input             clk,
	input             reset,

	// master 0 (priority)
	output            m0_waitrequest,
	input       [7:0] m0_burstcount,
	input    [AW-1:0] m0_address,
	input             m0_read,
	input             m0_write,
	input      [63:0] m0_writedata,
	input       [7:0] m0_byteenable,
	output     [63:0] m0_readdata,
	output            m0_readdatavalid,

	// master 1
	output            m1_waitrequest,
	input       [7:0] m1_burstcount,
	input    [AW-1:0] m1_address,
	input             m1_read,
	input             m1_write,
	input      [63:0] m1_writedata,
	input       [7:0] m1_byteenable,
	output     [63:0] m1_readdata,
	output            m1_readdatavalid,

	// slave (DDRAM_*)
	input             s_waitrequest,
	output      [7:0] s_burstcount,
	output   [AW-1:0] s_address,
	output            s_read,
	output            s_write,
	output     [63:0] s_writedata,
	output      [7:0] s_byteenable,
	input      [63:0] s_readdata,
	input             s_readdatavalid
);

localparam IDLE = 2'd0, CMD = 2'd1, WDATA = 2'd2, RDATA = 2'd3;

reg  [1:0] state = IDLE;
reg        sel   = 0;        // granted master
reg  [7:0] cnt;              // beats left

wire       g_read  = sel ? m1_read  : m0_read;
wire       g_write = sel ? m1_write : m0_write;
wire [7:0] g_bc    = sel ? m1_burstcount : m0_burstcount;
wire       pass    = (state == CMD) || (state == WDATA);

assign s_burstcount = g_bc;
assign s_address    = sel ? m1_address    : m0_address;
assign s_writedata  = sel ? m1_writedata  : m0_writedata;
assign s_byteenable = sel ? m1_byteenable : m0_byteenable;
assign s_read       = (state == CMD) & g_read;
assign s_write      = pass & g_write;

assign m0_waitrequest = (pass & ~sel) ? s_waitrequest : 1'b1;
assign m1_waitrequest = (pass &  sel) ? s_waitrequest : 1'b1;

assign m0_readdata      = s_readdata;
assign m1_readdata      = s_readdata;
assign m0_readdatavalid = (state == RDATA) & ~sel & s_readdatavalid;
assign m1_readdatavalid = (state == RDATA) &  sel & s_readdatavalid;

always @(posedge clk) begin
	case (state)
		IDLE:
			if (m0_read | m0_write) begin
				sel   <= 0;
				state <= CMD;
			end
			else if (m1_read | m1_write) begin
				sel   <= 1;
				state <= CMD;
			end

		CMD:
			if (!s_waitrequest) begin
				if (g_read) begin
					cnt   <= g_bc;
					state <= RDATA;
				end
				else if (g_write) begin
					cnt   <= g_bc - 8'd1;
					state <= (g_bc <= 8'd1) ? IDLE : WDATA;
				end
				else state <= IDLE;              // request withdrawn
			end

		WDATA:
			if (g_write & ~s_waitrequest) begin
				cnt <= cnt - 8'd1;
				if (cnt == 8'd1) state <= IDLE;
			end

		RDATA:
			if (s_readdatavalid) begin
				cnt <= cnt - 8'd1;
				if (cnt == 8'd1) state <= IDLE;
			end
	endcase

	if (reset) begin
		state <= IDLE;
		sel   <= 0;
	end
end

endmodule
