--------------------------------------------------------------------------------
-- Simulation stand-in for the framework PLL (sys/pll_q17.qip) that ss_core
-- instantiates. Every output is the reference clock, so the whole machine,
-- video included, runs from the one clock the harness drives.
--------------------------------------------------------------------------------
LIBRARY ieee;
USE ieee.std_logic_1164.ALL;

ENTITY pll IS
  GENERIC (
    CORE_MHZ : string := "60.000000 MHz");
  PORT (
    refclk   : IN  std_logic;
    rst      : IN  std_logic;
    outclk_0 : OUT std_logic;
    outclk_1 : OUT std_logic;
    outclk_2 : OUT std_logic;
    outclk_3 : OUT std_logic;
    locked   : OUT std_logic);
END ENTITY pll;

ARCHITECTURE sim OF pll IS
BEGIN
  outclk_0 <= refclk;
  outclk_1 <= refclk;
  outclk_2 <= refclk;
  outclk_3 <= refclk;
  locked   <= '1';
END ARCHITECTURE sim;
