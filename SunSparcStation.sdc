derive_pll_clocks
derive_clock_uncertainty

# core specific constraints

# The framework's exclusive clock groups (sys/sys_top.sdc) find the core PLL
# as "*|pll|pll_inst|...", an instance named exactly "pll". This core's PLL
# is "i_pll" inside ss_core, so without this its clock (clk_sys) was related
# to every framework clock and every asynchronous crossing was timed as a
# synchronous path (-74 ns worst slack, 1.5 h of fitter effort on paths that
# cannot be met).
# The core clock (outclk_3: 60 MHz on the SS5, 55 MHz on the SS20) and the
# pixel clock (outclk_0, 65 MHz) come from the same PLL; the video side is
# asynchronous to the core (as it was on the SS20 at 50 MHz, whose core ran
# on FPGA_CLK2_50), so they are separate groups: timed together, their edge
# relationship of a nanosecond or so cannot be met.
set_clock_groups -asynchronous \
   -group [get_clocks {emu|ss_core|i_pll|pll_inst|altera_pll_i|*[0].*|divclk \
                       emu|ss_core|i_pll|pll_inst|altera_pll_i|*[1].*|divclk \
                       emu|ss_core|i_pll|pll_inst|altera_pll_i|*[2].*|divclk}] \
   -group [get_clocks {emu|ss_core|i_pll|pll_inst|altera_pll_i|*[3].*|divclk}] \
   -group [get_clocks {pll_hdmi|pll_hdmi_inst|altera_pll_i|*[0].*|divclk}] \
   -group [get_clocks {pll_audio|pll_audio_inst|altera_pll_i|*[0].*|divclk}] \
   -group [get_clocks {spi_sck}] \
   -group [get_clocks {hdmi_sck}] \
   -group [get_clocks {*|h2f_user0_clk}] \
   -group [get_clocks {FPGA_CLK1_50}] \
   -group [get_clocks {FPGA_CLK2_50}] \
   -group [get_clocks {FPGA_CLK3_50}]
