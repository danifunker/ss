----*-vhdl-*--------------------------------------------------------------------
-- PLOMB
--------------------------------------------------------------------------------
-- DO 1/2011
--------------------------------------------------------------------------------
--------------------------------------------------------------------------------

--##############################################################################
--## This source file is copyrighted. Read the "lic.txt" file before use.     ##
--## Experimental version. No warranty of any sort. All rights reserved.      ##
--##############################################################################

-- Initialisation RTC

LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;

LIBRARY work;
USE work.base_pack.ALL;
USE work.plomb_pack.ALL;

ENTITY iram_rtc IS
  GENERIC (
    MACHINE_TYPE : natural := 16#80#);  -- IDPROM type: 0x80 SS5, 0x72 SS20
  PORT (
    mem_w : IN  type_pvc_w;
    mem_r : OUT type_pvc_r;
    
    -- Global
    clk      : IN std_logic;
    reset_n  : IN std_logic
    );
END ENTITY iram_rtc;

ARCHITECTURE rtc OF iram_rtc IS

--------------------------------------------------------------------------------
  CONSTANT SIZE : natural := 2 ** 11;
  TYPE type_mem IS ARRAY(0 TO SIZE-1) OF uv8;
  
  SIGNAL wr : unsigned(0 TO 3);
  SIGNAL dr,dw : uv32;

  -- The image the NVRAM starts with (it is not saved yet, TOD-6):
  -- - zeros, so neither PROM sees diag-switch? set (byte 1 was 0x1A, which
  --   sent the real OBP into a diagnostic POST) and OpenBIOS, which finds
  --   no valid partitions, formats its own;
  -- - a valid IDPROM at 0x1FD8 (TOD-5): format 1, the build's machine type,
  --   Ethernet address 08:00:20:12:34:56, date 0, serial 0x123456 (hostid
  --   0x80123456 or 0x72123456), XOR checksum. The SS5 OBP rejects any type
  --   but 0x80; both builds had 0x72. OpenBIOS rewrites the IDPROM anyway.
  -- Byte n of the NVRAM is in lane n mod 4, word n / 4.
  FUNCTION nvram_init (CONSTANT lane : natural) RETURN type_mem IS
    TYPE arr_id IS ARRAY(0 TO 15) OF uv8;
    VARIABLE id : arr_id := (
      x"01", to_unsigned(MACHINE_TYPE,8), x"08", x"00", x"20", x"12", x"34",
      x"56", x"00", x"00", x"00", x"00", x"12", x"34", x"56", x"00");
    VARIABLE m : type_mem := (OTHERS => x"00");
    VARIABLE n : natural;
  BEGIN
    FOR i IN 0 TO 14 LOOP
      id(15) := id(15) XOR id(i);
    END LOOP;
    FOR i IN 0 TO 15 LOOP
      n := 16#1FD8# + i;
      IF n MOD 4 = lane THEN
        m(n / 4) := id(i);
      END IF;
    END LOOP;
    RETURN m;
  END FUNCTION nvram_init;
  
  SIGNAL mem0 : type_mem:=nvram_init(0);
  SIGNAL mem1 : type_mem:=nvram_init(1);
  SIGNAL mem2 : type_mem:=nvram_init(2);
  SIGNAL mem3 : type_mem:=nvram_init(3);
  ATTRIBUTE ramstyle : string;
  ATTRIBUTE ramstyle OF mem0 : SIGNAL IS "no_rw_check";
  ATTRIBUTE ramstyle OF mem1 : SIGNAL IS "no_rw_check";
  ATTRIBUTE ramstyle OF mem2 : SIGNAL IS "no_rw_check";
  ATTRIBUTE ramstyle OF mem3 : SIGNAL IS "no_rw_check";
  
--------------------------------------------------------------------------------
    
BEGIN

  wr<=mem_w.be WHEN mem_w.req='1' AND mem_w.wr='1' ELSE "0000";

  memproc:PROCESS  (clk)
  BEGIN
    IF rising_edge(clk) THEN
      dr(31 DOWNTO 24)<=mem0(to_integer(mem_w.a(12 DOWNTO 2)));
      IF wr(0)='1' THEN
        mem0(to_integer(mem_w.a(12 DOWNTO 2)))<=dw(31 DOWNTO 24);
      END IF;

      dr(23 DOWNTO 16)<=mem1(to_integer(mem_w.a(12 DOWNTO 2)));
      IF wr(1)='1' THEN
        mem1(to_integer(mem_w.a(12 DOWNTO 2)))<=dw(23 DOWNTO 16);
      END IF;
      
      dr(15 DOWNTO 8)<=mem2(to_integer(mem_w.a(12 DOWNTO 2)));
      IF wr(2)='1' THEN
        mem2(to_integer(mem_w.a(12 DOWNTO 2)))<=dw(15 DOWNTO 8);
      END IF;

      dr(7 DOWNTO 0)<=mem3(to_integer(mem_w.a(12 DOWNTO 2)));
      IF wr(3)='1' THEN
        mem3(to_integer(mem_w.a(12 DOWNTO 2)))<=dw(7 DOWNTO 0);
      END IF;
    END IF;
  END PROCESS memproc;

  mem_r.dr<=dr;
  dw<=mem_w.dw;
  
  mem_r.ack<='1';

END ARCHITECTURE rtc;
