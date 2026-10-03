--------------------------------------------------------------------------------
-- TEM : TS
-- Sun Type 4 keyboard emulation
--------------------------------------------------------------------------------
-- DO 10/2012
--------------------------------------------------------------------------------

--##############################################################################
--## This source file is copyrighted. Read the "lic.txt" file before use.     ##
--## Experimental version. No warranty of any sort. All rights reserved.      ##
--##############################################################################

-- Commandes :
--  01 : RESET
--     -> FF 04 [held keys] 7F
--  02 : Bell ON
--  03 : Bell OFF
--  0A : Click ON
--  0B : Click OFF
--  0E <stat> : LED : 0=NumLock 1=Compose 2=Scroll 3=Caps
--  0F : Layout
--     -> FE <layout>

--------------------------------------------------------------------------------

LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;

LIBRARY work;
USE work.base_pack.ALL;
USE work.plomb_pack.ALL;

ENTITY ts_sunkb IS
  PORT (
    -- ESCC side
    si_data : OUT uv8;                  -- KB -> Serial port
    si_req  : OUT std_logic;
    si_rdy  : IN  std_logic;
    so_data : IN  uv8;                  -- Serial port -> KB
    so_req  : IN  std_logic;
    so_rdy  : OUT std_logic;

    -- Keyboard side : Receive only
    kb_data : IN  uv8;
    kb_req  : IN  std_logic;
    kb_rdy  : OUT std_logic;
    leds    : OUT uv4;
    ledsm   : OUT std_logic;

    layout  : IN  uv8;
    
    -- Global
    clk     : IN std_logic;
    reset_n : IN std_logic
    );
END ENTITY ts_sunkb;

--##############################################################################

ARCHITECTURE rtl OF ts_sunkb IS

  CONSTANT CMD_RESET  : uv8 := x"01";
  CONSTANT CMD_LED    : uv8 := x"0E";
  CONSTANT CMD_LAYOUT : uv8 := x"0F";

  TYPE enum_etat IS (sOISIF,sREC,sREC2,
                     sRESET,sRESET2,sRESETK,sRESET3,
                     sLED,sLAYOUT,sLAYOUT2);
  SIGNAL etat : enum_etat;
  
  CONSTANT MAX : natural := 1_000; --<_000;  -- Délai 20ms
  SIGNAL cpt : natural RANGE 0 TO MAX;
  
  -- Commands from the host, queued. A Sun keyboard is full duplex: it takes
  -- a command while it is still sending a reply. Taking commands only when
  -- idle made the ESCC hold the byte, so RR1 All Sent stayed 0 while the
  -- keyboard waited for the host to read its reply: the Sun OBP, which
  -- polls All Sent after each command (kbd_putc_boot), deadlocked. A
  -- command arriving in sREC or sLAYOUT2 was also dropped.
  -- The keys the PROM looks for in the reset reply, held down: Stop (L1),
  -- A, N, D, F (Stop-A, Stop-N: NVRAM defaults, Stop-D: diagnostics,
  -- Stop-F: Forth on ttya). A Sun keyboard lists every key held between
  -- its ID and 7F; these are the ones that mean something there.
  CONSTANT HELD_CODE : arr_uv8(0 TO 4) := (x"01",x"4D",x"69",x"4F",x"50");
  SIGNAL held : unsigned(0 TO 4);
  SIGNAL hk : natural RANGE 0 TO 5;

  TYPE arr_cmd IS ARRAY(0 TO 3) OF uv8;
  SIGNAL cmdq : arr_cmd;
  SIGNAL cmdq_n : natural RANGE 0 TO 4;
  
BEGIN

  Machine: PROCESS (clk)
    VARIABLE pop : boolean;
    VARIABLE n : natural RANGE 0 TO 4;
  BEGIN
    IF rising_edge(clk) THEN
      kb_rdy<='0';
      si_req<='0';
      ledsm<='0';
      pop:=false;
      
      CASE etat IS
          --------------------------------------
        WHEN sOISIF =>
          cpt<=0;
          si_data<=kb_data;
          IF kb_req='1' THEN
            etat<=sREC;
            si_req<='1';
          ELSIF cmdq_n>0 THEN
            pop:=true;
            IF cmdq(0)=CMD_RESET THEN
              etat<=sRESET;
            ELSIF cmdq(0)=CMD_LED THEN
              etat<=sLED;
            ELSIF cmdq(0)=CMD_LAYOUT THEN
              etat<=sLAYOUT;
            END IF;
          END IF;
          
          --------------------------------------
        WHEN sREC =>
          si_data<=kb_data;
          IF si_rdy='1' THEN
            etat<=sREC2;
            kb_rdy<='1';
          ELSE
            si_req<='1';
          END IF;
          
        WHEN sREC2 =>
          si_data<=kb_data;
          etat<=sOISIF;
          
          --------------------------------------
        WHEN sRESET =>
          si_data<=x"FF";
          IF cpt/=MAX THEN
            cpt<=cpt+1;
          ELSE
            si_req<='1';
          END IF;
          IF si_rdy='1'  THEN
            etat<=sRESET2;
            si_req<='0';
            cpt<=0;
          END IF;

        WHEN sRESET2 =>
          si_data<=x"04";
          IF cpt/=MAX THEN
            cpt<=cpt+1;
          ELSE
            si_req<='1';
          END IF;
          IF si_rdy='1' THEN
            etat<=sRESETK;
            si_req<='0';
            cpt<=0;
            hk<=0;
          END IF;
          
        WHEN sRESETK =>
          -- The held keys of HELD_CODE, one make code each
          IF hk=5 THEN
            etat<=sRESET3;
          ELSIF held(hk)='0' THEN
            hk<=hk+1;
          ELSE
            si_data<=HELD_CODE(hk);
            IF cpt/=MAX THEN
              cpt<=cpt+1;
            ELSE
              si_req<='1';
            END IF;
            IF si_rdy='1' THEN
              hk<=hk+1;
              si_req<='0';
              cpt<=0;
            END IF;
          END IF;
          
        WHEN sRESET3 =>
          si_data<=x"7F";
          IF cpt/=MAX THEN
            cpt<=cpt+1;
          ELSE
            si_req<='1';
          END IF;
          IF si_rdy='1' THEN
            etat<=sOISIF;
            si_req<='0';
            cpt<=0;
          END IF;
          
          --------------------------------------
        WHEN sLED =>
          si_data<=layout;
          si_req<='0';
          IF cmdq_n>0 THEN
            pop:=true;
            etat<=sOISIF;
            leds<=cmdq(0)(3 DOWNTO 0);
            ledsm<='1';
          END IF;
          
          --------------------------------------
        WHEN sLAYOUT =>
          si_data<=x"FE";
          IF cpt/=MAX THEN
            cpt<=cpt+1;
          ELSE
            si_req<='1';
          END IF;
          IF si_rdy='1'  THEN
            etat<=sLAYOUT2;
            si_req<='0';
            cpt<=0;
          END IF;

        WHEN sLAYOUT2 =>
          si_data<=layout;
          IF cpt/=MAX THEN
            cpt<=cpt+1;
          ELSE
            si_req<='1';
          END IF;
          IF si_rdy='1'  THEN
            etat<=sOISIF;
            si_req<='0';
            cpt<=0;
          END IF;
          
          --------------------------------------
      END CASE;
      
      -- The keys of HELD_CODE that are down, from the codes going out
      IF etat=sOISIF AND kb_req='1' THEN
        FOR i IN 0 TO 4 LOOP
          IF kb_data(6 DOWNTO 0)=HELD_CODE(i)(6 DOWNTO 0) THEN
            held(i)<=NOT kb_data(7);
          END IF;
        END LOOP;
      END IF;
      
      -- Command queue: pop what the machine took, push what the ESCC sends
      n:=cmdq_n;
      IF pop THEN
        cmdq(0 TO 2)<=cmdq(1 TO 3);
        n:=n-1;
      END IF;
      IF so_req='1' AND n<4 THEN
        cmdq(n)<=so_data;
        n:=n+1;
      END IF;
      cmdq_n<=n;
      -- Ready while there is room, with a slot of margin for a request
      -- already on its way
      IF n<3 THEN
        so_rdy<='1';
      ELSE
        so_rdy<='0';
      END IF;
      
      IF reset_n='0' THEN
        etat<=sOISIF;
        cmdq_n<=0;
        held<=(OTHERS => '0');
      END IF;

    END IF;
  END PROCESS Machine;
  
END ARCHITECTURE rtl;

