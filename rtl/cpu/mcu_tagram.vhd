--------------------------------------------------------------------------------
-- TEM : MCU
-- Cache tag RAM in MLABs (SS5 timing)
--------------------------------------------------------------------------------
-- 32 bits, 2^N bytes, the same ports and behaviour as iram (the address is
-- sampled by the clock, the data is valid in the next cycle), but held in
-- MLABs: the lookup is asynchronous and dr is an ordinary register, so a
-- tag compare starts from a flip-flop output instead of a block RAM's late
-- output (about 3.5 ns after the edge on a Cyclone V M10K, 2.5 ns of it
-- the block's own clock insertion). For the cache tags only: 128 x 32 bits
-- per way and side, 8 MLABs each. No initialisation file.
--------------------------------------------------------------------------------

LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;

LIBRARY work;
USE work.base_pack.ALL;
USE work.plomb_pack.ALL;

ENTITY mcu_tagram IS
  GENERIC (
    N    : uint8   :=9);                -- 2^N octets
  PORT (
    mem_w : IN  type_pvc_w;
    mem_r : OUT type_pvc_r;
    clk   : IN  std_logic
    );
END ENTITY mcu_tagram;

--##############################################################################

ARCHITECTURE rtl OF mcu_tagram IS

  CONSTANT SIZE : natural := 2 ** (N-2);

  TYPE type_mem IS ARRAY(0 TO SIZE-1) OF uv8;

  SIGNAL wr : unsigned(0 TO 3);
  SIGNAL dr : uv32;

  SHARED VARIABLE mem0 : type_mem:=(OTHERS => x"00");
  SHARED VARIABLE mem1 : type_mem:=(OTHERS => x"00");
  SHARED VARIABLE mem2 : type_mem:=(OTHERS => x"00");
  SHARED VARIABLE mem3 : type_mem:=(OTHERS => x"00");

  ATTRIBUTE ramstyle : string;
  ATTRIBUTE ramstyle OF mem0 : VARIABLE IS "MLAB, no_rw_check";
  ATTRIBUTE ramstyle OF mem1 : VARIABLE IS "MLAB, no_rw_check";
  ATTRIBUTE ramstyle OF mem2 : VARIABLE IS "MLAB, no_rw_check";
  ATTRIBUTE ramstyle OF mem3 : VARIABLE IS "MLAB, no_rw_check";

BEGIN

  wr<=mem_w.be WHEN mem_w.req='1' AND mem_w.wr='1' ELSE "0000";

  memproc:PROCESS (clk)
  BEGIN
    IF rising_edge(clk) THEN
      dr(31 DOWNTO 24)<=mem0(to_integer(mem_w.a(N-1 DOWNTO 2)));
      IF wr(0)='1' THEN
        mem0(to_integer(mem_w.a(N-1 DOWNTO 2))):=mem_w.dw(31 DOWNTO 24);
      END IF;

      dr(23 DOWNTO 16)<=mem1(to_integer(mem_w.a(N-1 DOWNTO 2)));
      IF wr(1)='1' THEN
        mem1(to_integer(mem_w.a(N-1 DOWNTO 2))):=mem_w.dw(23 DOWNTO 16);
      END IF;

      dr(15 DOWNTO 8)<=mem2(to_integer(mem_w.a(N-1 DOWNTO 2)));
      IF wr(2)='1' THEN
        mem2(to_integer(mem_w.a(N-1 DOWNTO 2))):=mem_w.dw(15 DOWNTO 8);
      END IF;

      dr(7 DOWNTO 0)<=mem3(to_integer(mem_w.a(N-1 DOWNTO 2)));
      IF wr(3)='1' THEN
        mem3(to_integer(mem_w.a(N-1 DOWNTO 2))):=mem_w.dw(7 DOWNTO 0);
      END IF;
    END IF;
  END PROCESS memproc;

  mem_r.dr<=dr;
  mem_r.ack<='1';

END ARCHITECTURE rtl;
