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
USE work.ts_pack.ALL;

ENTITY iram_rtc IS
  GENERIC (
    MACHINE_TYPE : natural := 16#80#;   -- IDPROM type: 0x80 SS5, 0x72 SS20
    -- NVRAM byte 1 (diag-switch?) starts at 0xFF, so the Sun OBP runs its
    -- POST. Only `sim/build.sh --diag` sets it (sim/gen_verilog.sh).
    DIAG         : boolean := false);
  PORT (
    mem_w : IN  type_pvc_w;
    mem_r : OUT type_pvc_r;

    -- Second port: the image on the SD card (rtl/mister/nvram_sd.vhd)
    nv_w  : IN  type_nvram_w;
    nv_dr : OUT uv16;
    
    -- Global
    clk      : IN std_logic;
    reset_n  : IN std_logic
    );
END ENTITY iram_rtc;

ARCHITECTURE rtc OF iram_rtc IS

--------------------------------------------------------------------------------
  CONSTANT SIZE : natural := 2 ** 11;
  TYPE type_mem IS ARRAY(0 TO SIZE-1) OF uv8;
  TYPE arr_id IS ARRAY(0 TO 15) OF uv8;
  
  SIGNAL wr : unsigned(0 TO 3);
  SIGNAL dr,dw : uv32;

  -- The IDPROM (TOD-5): format 1, the build's machine type, Ethernet
  -- address 08:00:20:12:34:56, date 0, serial 0x123456 (hostid 0x80123456
  -- or 0x72123456), XOR checksum. The SS5 OBP rejects any type but 0x80.
  -- A blank image gets it with a serial of its own (below); the serial is
  -- in the checksum twice (Ethernet address, hostid), so it cancels out.
  FUNCTION idprom RETURN arr_id IS
    VARIABLE id : arr_id := (
      x"01", to_unsigned(MACHINE_TYPE,8), x"08", x"00", x"20", x"12", x"34",
      x"56", x"00", x"00", x"00", x"00", x"12", x"34", x"56", x"00");
  BEGIN
    FOR i IN 0 TO 14 LOOP
      id(15) := id(15) XOR id(i);
    END LOOP;
    RETURN id;
  END FUNCTION idprom;
  CONSTANT ID : arr_id := idprom;
  CONSTANT ID_HW : natural := 16#1FD8# / 2;   -- its first halfword

  -- The image the NVRAM starts with when no image file is mounted (TOD-6):
  -- - zeros, so neither PROM sees diag-switch? set (byte 1 was 0x1A, which
  --   sent the real OBP into a diagnostic POST) and OpenBIOS, which finds
  --   no valid partitions, formats its own;
  -- - the IDPROM at 0x1FD8. OpenBIOS rewrites it anyway.
  -- Byte n of the NVRAM is in lane n mod 4, word n / 4.
  FUNCTION nvram_init (CONSTANT lane : natural) RETURN type_mem IS
    VARIABLE m : type_mem := (OTHERS => x"00");
    VARIABLE n : natural;
  BEGIN
    FOR i IN 0 TO 15 LOOP
      n := 16#1FD8# + i;
      IF n MOD 4 = lane THEN
        m(n / 4) := ID(i);
      END IF;
    END LOOP;
    IF DIAG AND lane = 1 THEN
      m(0) := x"FF";
    END IF;
    RETURN m;
  END FUNCTION nvram_init;
  
  -- True dual-port: port A is the CPU's (32 bits), port B the SD image's
  -- (16 bits: lanes 0-1 or 2-3).
  SHARED VARIABLE mem0 : type_mem:=nvram_init(0);
  SHARED VARIABLE mem1 : type_mem:=nvram_init(1);
  SHARED VARIABLE mem2 : type_mem:=nvram_init(2);
  SHARED VARIABLE mem3 : type_mem:=nvram_init(3);
  ATTRIBUTE ramstyle : string;
  ATTRIBUTE ramstyle OF mem0,mem1,mem2,mem3 : VARIABLE IS "no_rw_check";

  SIGNAL b_a : unsigned(10 DOWNTO 0);
  SIGNAL b_dw : uv16;
  SIGNAL b_wlo,b_whi : std_logic;   -- write lanes 0-1, lanes 2-3
  SIGNAL b_dr0,b_dr1,b_dr2,b_dr3 : uv8;
  SIGNAL b_hi_d : std_logic;
  SIGNAL idblank : std_logic := '0';
  SIGNAL rnd, serial : unsigned(23 DOWNTO 0) := x"123456";
  
--------------------------------------------------------------------------------
    
BEGIN

  wr<=mem_w.be WHEN mem_w.req='1' AND mem_w.wr='1' ELSE "0000";
  dw<=mem_w.dw;

  PortA0:PROCESS (clk)
  BEGIN
    IF rising_edge(clk) THEN
      dr(31 DOWNTO 24)<=mem0(to_integer(mem_w.a(12 DOWNTO 2)));
      IF wr(0)='1' THEN
        mem0(to_integer(mem_w.a(12 DOWNTO 2))):=dw(31 DOWNTO 24);
      END IF;
    END IF;
  END PROCESS PortA0;

  PortA1:PROCESS (clk)
  BEGIN
    IF rising_edge(clk) THEN
      dr(23 DOWNTO 16)<=mem1(to_integer(mem_w.a(12 DOWNTO 2)));
      IF wr(1)='1' THEN
        mem1(to_integer(mem_w.a(12 DOWNTO 2))):=dw(23 DOWNTO 16);
      END IF;
    END IF;
  END PROCESS PortA1;

  PortA2:PROCESS (clk)
  BEGIN
    IF rising_edge(clk) THEN
      dr(15 DOWNTO 8)<=mem2(to_integer(mem_w.a(12 DOWNTO 2)));
      IF wr(2)='1' THEN
        mem2(to_integer(mem_w.a(12 DOWNTO 2))):=dw(15 DOWNTO 8);
      END IF;
    END IF;
  END PROCESS PortA2;

  PortA3:PROCESS (clk)
  BEGIN
    IF rising_edge(clk) THEN
      dr(7 DOWNTO 0)<=mem3(to_integer(mem_w.a(12 DOWNTO 2)));
      IF wr(3)='1' THEN
        mem3(to_integer(mem_w.a(12 DOWNTO 2))):=dw(7 DOWNTO 0);
      END IF;
    END IF;
  END PROCESS PortA3;

  mem_r.dr<=dr;
  mem_r.ack<='1';

  ------------------------------------------------------------------------------
  -- Port B. Halfword a = NVRAM bytes 2a (low) and 2a+1 (high): word a/2,
  -- lanes 0 and 1 for an even a, 2 and 3 for an odd one.
  -- An image whose IDPROM format byte (0x1FD8) is 0, a blank file, gets
  -- the built-in IDPROM: its eight halfwords are replaced as they arrive
  -- (the format byte comes first). Its serial (Ethernet address bytes 3-5
  -- and hostid bytes 1-3) is a free-running counter sampled when the
  -- format byte arrives, so each blank image gets its own identity, which
  -- nvram_sd then writes back to the file.
  BWrite:PROCESS (nv_w,idblank,serial)
    VARIABLE blank : boolean;
    VARIABLE k : natural RANGE 0 TO 7;
    VARIABLE id_v : arr_id;
  BEGIN
    id_v:=ID;
    id_v(5):=serial(23 DOWNTO 16);
    id_v(6):=serial(15 DOWNTO 8);
    id_v(7):=serial(7 DOWNTO 0);
    id_v(12):=serial(23 DOWNTO 16);
    id_v(13):=serial(15 DOWNTO 8);
    id_v(14):=serial(7 DOWNTO 0);
    b_a<=nv_w.a(11 DOWNTO 1);
    b_dw<=nv_w.dw;
    IF nv_w.a=ID_HW THEN
      blank:=(nv_w.dw(7 DOWNTO 0)=x"00");
    ELSE
      blank:=(idblank='1');
    END IF;
    IF nv_w.a>=ID_HW AND nv_w.a<ID_HW+8 AND blank THEN
      k:=to_integer(nv_w.a-ID_HW);
      b_dw<=id_v(2*k+1) & id_v(2*k);
    END IF;
    b_wlo<=nv_w.we AND NOT nv_w.a(0);
    b_whi<=nv_w.we AND nv_w.a(0);
  END PROCESS BWrite;

  BBlank:PROCESS (clk)
  BEGIN
    IF rising_edge(clk) THEN
      rnd<=rnd+1;
      IF nv_w.we='1' AND nv_w.a=ID_HW THEN
        idblank<=to_std_logic(nv_w.dw(7 DOWNTO 0)=x"00");
        serial<=rnd;
      END IF;
      b_hi_d<=nv_w.a(0);
    END IF;
  END PROCESS BBlank;

  PortB0:PROCESS (clk)
  BEGIN
    IF rising_edge(clk) THEN
      b_dr0<=mem0(to_integer(b_a));
      IF b_wlo='1' THEN
        mem0(to_integer(b_a)):=b_dw(7 DOWNTO 0);
      END IF;
    END IF;
  END PROCESS PortB0;

  PortB1:PROCESS (clk)
  BEGIN
    IF rising_edge(clk) THEN
      b_dr1<=mem1(to_integer(b_a));
      IF b_wlo='1' THEN
        mem1(to_integer(b_a)):=b_dw(15 DOWNTO 8);
      END IF;
    END IF;
  END PROCESS PortB1;

  PortB2:PROCESS (clk)
  BEGIN
    IF rising_edge(clk) THEN
      b_dr2<=mem2(to_integer(b_a));
      IF b_whi='1' THEN
        mem2(to_integer(b_a)):=b_dw(7 DOWNTO 0);
      END IF;
    END IF;
  END PROCESS PortB2;

  PortB3:PROCESS (clk)
  BEGIN
    IF rising_edge(clk) THEN
      b_dr3<=mem3(to_integer(b_a));
      IF b_whi='1' THEN
        mem3(to_integer(b_a)):=b_dw(15 DOWNTO 8);
      END IF;
    END IF;
  END PROCESS PortB3;

  nv_dr<=b_dr3 & b_dr2 WHEN b_hi_d='1' ELSE b_dr1 & b_dr0;

END ARCHITECTURE rtc;
