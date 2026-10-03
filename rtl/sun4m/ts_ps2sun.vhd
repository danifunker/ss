--------------------------------------------------------------------------------
-- TEM : TS
-- Conversion PS/2 -> Sun
--------------------------------------------------------------------------------
-- DO 10/2012
--------------------------------------------------------------------------------
-- Interface PS2
-- FIFO réception
-- Sélection émul/registres
-- Transcodage caractères PS/2 -> Sun
--------------------------------------------------------------------------------

--##############################################################################
--## This source file is copyrighted. Read the "lic.txt" file before use.     ##
--## Experimental version. No warranty of any sort. All rights reserved.      ##
--##############################################################################

LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;

LIBRARY work;
USE work.base_pack.ALL;
USE work.plomb_pack.ALL;
USE work.ts_pack.ALL;

ENTITY ts_ps2sun IS
  GENERIC (
    SYSFREQ  : natural :=50_000_000);
  PORT (
    -- Externe GPIO
    ps2_i       : IN  uv4; -- Mouse clk | Mouse data | KBD clk | KBD data
    ps2_o       : OUT uv4;
    
    kbm_layout  : IN  uv8;
    
    -- UART Clavier
    di1_data : OUT uv8;
    di1_req  : OUT std_logic;
    di1_rdy  : IN  std_logic;
    do1_data : IN  uv8;
    do1_req  : IN  std_logic;
    do1_rdy  : OUT std_logic;
    
    -- UART Souris
    di2_data : OUT uv8;
    di2_req  : OUT std_logic;
    di2_rdy  : IN  std_logic;
    
    -- Sun keyboard LEDs for the MiSTer keyboard: 2 Scroll, 1 Num, 0 Caps
    kbd_leds : OUT unsigned(2 DOWNTO 0);
    do2_data : IN  uv8;
    do2_req  : IN  std_logic;
    do2_rdy  : OUT std_logic;
    
    -- Global
    clk        : IN  std_logic;
    reset_n    : IN  std_logic
    );
END ENTITY ts_ps2sun;

--##############################################################################

ARCHITECTURE rtl OF ts_ps2sun IS
  
  -----------------------------------------------
  CONSTANT ZZ : uv8 := x"00";
  CONSTANT Mapping : arr_uv8(0 TO 511) :=(
    -- Direct
    ZZ   ,          -- x00
    x"12",          -- x01 : F9
    ZZ   ,          -- x02 : 
    x"0C",          -- x03 : F5
    x"08",          -- x04 : F3
    x"05",          -- x05 : F1
    x"06",          -- x06 : F2
    x"0B",          -- x07 : F12
    ZZ   ,          -- x08 : 
    x"07",          -- x09 : F10
    x"11",          -- x0A : F8
    x"0E",          -- x0B : F6
    x"0A",          -- x0C : F4
    x"35",          -- x0D : TAB
    x"2A",          -- x0E : ²
    ZZ   ,          -- x0F
    ZZ   ,          -- x10
    x"13",          -- x11 : L alt
    x"63",          -- x12 : L shift
    ZZ   ,          -- x13 : 
    x"4C",          -- x14 : L ctrl
    x"36",          -- x15 : A
    x"1E",          -- x16 : &1
    ZZ   ,          -- x17
    ZZ   ,          -- x18
    ZZ   ,          -- x19
    x"64",          -- x1A : W
    x"4E",          -- x1B : S
    x"4D",          -- x1C : Q
    x"37",          -- x1D : Z
    x"1F",          -- x1E : é2
    ZZ   ,          -- x1F
    ZZ   ,          -- x20
    x"66",          -- x21 : C
    x"65",          -- x22 : X
    x"4F",          -- x23 : D
    x"38",          -- x24 : E
    x"21",          -- x25 : '4
    x"20",          -- x26 : "3
    ZZ   ,          -- x27
    ZZ   ,          -- x28
    x"79",          -- x29 : SPACE
    x"67",          -- x2A : V
    x"50",          -- x2B : F
    x"3A",          -- x2C : T
    x"39",          -- x2D : R
    x"22",          -- x2E : (5
    ZZ   ,          -- x2F
    ZZ   ,          -- x30
    x"69",          -- x31 : N
    x"68",          -- x32 : B
    x"52",          -- x33 : H
    x"51",          -- x34 : G
    x"3B",          -- x35 : Y
    x"23",          -- x36 : -6
    ZZ   ,          -- x37
    ZZ   ,          -- x38
    ZZ   ,          -- x39
    x"6A",          -- x3A : ,?
    x"53",          -- x3B : J
    x"3C",          -- x3C : U
    x"24",          -- x3D : è7
    x"25",          -- x3E : _8
    ZZ   ,          -- x3F
    ZZ   ,          -- x40
    x"6B",          -- x41 : ;.
    x"54",          -- x42 : K
    x"3D",          -- x43 : I
    x"3E",          -- x44 : O
    x"27",          -- x45 : à0
    x"26",          -- x46 : ç9
    ZZ   ,          -- x47
    ZZ   ,          -- x48
    x"6C",          -- x49 : :/
    x"6D",          -- x4A : !§
    x"55",          -- x4B : L
    x"56",          -- x4C : M
    x"3F",          -- x4D : P
    x"28",          -- x4E : )°
    ZZ   ,          -- x4F
    ZZ   ,          -- x50
    ZZ   ,          -- x51
    x"57",          -- x52 : ù%
    ZZ   ,          -- x53
    x"40",          -- x54 : ^"
    x"29",          -- x55 : =+
    ZZ   ,          -- x56
    ZZ   ,          -- x57
    x"77",          -- x58 : VerrMaj
    x"6E",          -- x59 : R shift
    x"59",          -- x5A : Enter
    x"41",          -- x5B : $£
    ZZ   ,          -- x5C
    x"58",          -- x5D : *µ
    ZZ   ,          -- x5E
    ZZ   ,          -- x5F
    ZZ   ,          -- x60
    x"7C",          -- x61 : <>
    ZZ   ,          -- x62
    ZZ   ,          -- x63
    ZZ   ,          -- x64
    ZZ   ,          -- x65
    x"2B",          -- x66 : BackSpace
    ZZ   ,          -- x67
    ZZ   ,          -- x68
    x"70",          -- x69 : num : 1
    ZZ   ,          -- x6A
    x"5B",          -- x6B : num : 4
    x"44",          -- x6C : num : 7
    ZZ   ,          -- x6D
    ZZ   ,          -- x6E
    ZZ   ,          -- x6F
    x"5E",          -- x70 : num : 0
    x"32",          -- x71 : num : .
    x"71",          -- x72 : num : 2
    x"5C",          -- x73 : num : 5
    x"5D",          -- x74 : num : 6
    x"45",          -- x75 : num : 8
    x"1D",          -- x76 : ESC
    x"62",          -- x77 : num : NumLock
    x"09",          -- x78 : F11
    x"7D",          -- x79 : num : +
    x"72",          -- x7A : num : 3
    x"47",          -- x7B : num : -
    x"2F",          -- x7C : num : *
    x"46",          -- x7D : num : 9
    x"17",          -- x7E : SCROLL
    ZZ   ,          -- x7F
    ZZ   ,          -- x80
    ZZ   ,          -- x81
    ZZ   ,          -- x82
    x"10",          -- x83 : F7
    ZZ   ,          -- x84
    ZZ   ,          -- x85
    ZZ   ,          -- x86
    ZZ   ,          -- x87
    ZZ   ,          -- x88
    ZZ   ,          -- x89
    ZZ   ,          -- x8A
    ZZ   ,          -- x8B
    ZZ   ,          -- x8C
    ZZ   ,          -- x8D
    ZZ   ,          -- x8E
    ZZ   ,          -- x8F
    ZZ   ,          -- x90
    ZZ   ,          -- x91
    ZZ   ,          -- x92
    ZZ   ,          -- x93
    ZZ   ,          -- x94
    ZZ   ,          -- x95
    ZZ   ,          -- x96
    ZZ   ,          -- x97
    ZZ   ,          -- x98
    ZZ   ,          -- x99
    ZZ   ,          -- x9A
    ZZ   ,          -- x9B
    ZZ   ,          -- x9C
    ZZ   ,          -- x9D
    ZZ   ,          -- x9E
    ZZ   ,          -- x9F
    ZZ   ,          -- xA0
    ZZ   ,          -- xA1
    ZZ   ,          -- xA2
    ZZ   ,          -- xA3
    ZZ   ,          -- xA4
    ZZ   ,          -- xA5
    ZZ   ,          -- xA6
    ZZ   ,          -- xA7
    ZZ   ,          -- xA8
    ZZ   ,          -- xA9
    ZZ   ,          -- xAA
    ZZ   ,          -- xAB
    ZZ   ,          -- xAC
    ZZ   ,          -- xAD
    ZZ   ,          -- xAE
    ZZ   ,          -- xAF
    ZZ   ,          -- xB0
    ZZ   ,          -- xB1
    ZZ   ,          -- xB2
    ZZ   ,          -- xB3
    ZZ   ,          -- xB4
    ZZ   ,          -- xB5
    ZZ   ,          -- xB6
    ZZ   ,          -- xB7
    ZZ   ,          -- xB8
    ZZ   ,          -- xB9
    ZZ   ,          -- xBA
    ZZ   ,          -- xBB
    ZZ   ,          -- xBC
    ZZ   ,          -- xBD
    ZZ   ,          -- xBE
    ZZ   ,          -- xBF
    ZZ   ,          -- xC0
    ZZ   ,          -- xC1
    ZZ   ,          -- xC2
    ZZ   ,          -- xC3
    ZZ   ,          -- xC4
    ZZ   ,          -- xC5
    ZZ   ,          -- xC6
    ZZ   ,          -- xC7
    ZZ   ,          -- xC8
    ZZ   ,          -- xC9
    ZZ   ,          -- xCA
    ZZ   ,          -- xCB
    ZZ   ,          -- xCC
    ZZ   ,          -- xCD
    ZZ   ,          -- xCE
    ZZ   ,          -- xCF
    ZZ   ,          -- xD0
    ZZ   ,          -- xD1
    ZZ   ,          -- xD2
    ZZ   ,          -- xD3
    ZZ   ,          -- xD4
    ZZ   ,          -- xD5
    ZZ   ,          -- xD6
    ZZ   ,          -- xD7
    ZZ   ,          -- xD8
    ZZ   ,          -- xD9
    ZZ   ,          -- xDA
    ZZ   ,          -- xDB
    ZZ   ,          -- xDC
    ZZ   ,          -- xDD
    ZZ   ,          -- xDE
    ZZ   ,          -- xDF
    ZZ   ,          -- xE0 -- Préfixe code étendus
    ZZ   ,          -- xE1
    ZZ   ,          -- xE2
    ZZ   ,          -- xE3
    ZZ   ,          -- xE4
    ZZ   ,          -- xE5
    ZZ   ,          -- xE6
    ZZ   ,          -- xE7
    ZZ   ,          -- xE8
    ZZ   ,          -- xE9
    ZZ   ,          -- xEA
    ZZ   ,          -- xEB
    ZZ   ,          -- xEC
    ZZ   ,          -- xED
    ZZ   ,          -- xEE
    ZZ   ,          -- xEF
    ZZ   ,          -- xF0 -- Préfixe KeyUp
    ZZ   ,          -- xF1
    ZZ   ,          -- xF2
    ZZ   ,          -- xF3
    ZZ   ,          -- xF4
    ZZ   ,          -- xF5
    ZZ   ,          -- xF6
    ZZ   ,          -- xF7
    ZZ   ,          -- xF8
    ZZ   ,          -- xF9
    ZZ   ,          -- xFA
    ZZ   ,          -- xFB
    ZZ   ,          -- xFC
    ZZ   ,          -- xFD
    ZZ   ,          -- xFE
    ZZ   ,          -- xFF
    -- E0 PREFIX
    ZZ   ,          -- x00
    ZZ   ,          -- x01
    ZZ   ,          -- x02
    ZZ   ,          -- x03
    ZZ   ,          -- x04
    ZZ   ,          -- x05
    ZZ   ,          -- x06
    ZZ   ,          -- x07
    ZZ   ,          -- x08
    ZZ   ,          -- x09
    ZZ   ,          -- x0A
    ZZ   ,          -- x0B
    ZZ   ,          -- x0C
    ZZ   ,          -- x0D
    ZZ   ,          -- x0E
    ZZ   ,          -- x0F
    ZZ   ,          -- x10
    x"0D",          -- x11 : R alt (handled in KBDConv: L-keys, AltGraph)
    ZZ   ,          -- x12 : PRTSCR (1)
    ZZ   ,          -- x13
    x"4C",          -- x14 : R ctrl : Control unique
    ZZ   ,          -- x15
    ZZ   ,          -- x16
    ZZ   ,          -- x17
    ZZ   ,          -- x18
    ZZ   ,          -- x19
    ZZ   ,          -- x1A
    ZZ   ,          -- x1B
    ZZ   ,          -- x1C
    ZZ   ,          -- x1D
    ZZ   ,          -- x1E
    x"78",          -- x1F : L win -> L <>
    ZZ   ,          -- x20
    ZZ   ,          -- x21
    ZZ   ,          -- x22
    ZZ   ,          -- x23
    ZZ   ,          -- x24
    ZZ   ,          -- x25
    ZZ   ,          -- x26
    x"7A",          -- x27 : R win -> R <>
    ZZ   ,          -- x28
    ZZ   ,          -- x29
    ZZ   ,          -- x2A
    ZZ   ,          -- x2B
    ZZ   ,          -- x2C
    ZZ   ,          -- x2D
    ZZ   ,          -- x2E
    x"43",          -- x2F : Win Menu -> Compose
    ZZ   ,          -- x30
    ZZ   ,          -- x31
    ZZ   ,          -- x32
    ZZ   ,          -- x33
    ZZ   ,          -- x34
    ZZ   ,          -- x35
    ZZ   ,          -- x36
    ZZ   ,          -- x37
    ZZ   ,          -- x38
    ZZ   ,          -- x39
    ZZ   ,          -- x3A
    ZZ   ,          -- x3B
    ZZ   ,          -- x3C
    ZZ   ,          -- x3D
    ZZ   ,          -- x3E
    ZZ   ,          -- x3F
    ZZ   ,          -- x40
    ZZ   ,          -- x41
    ZZ   ,          -- x42
    ZZ   ,          -- x43
    ZZ   ,          -- x44
    ZZ   ,          -- x45
    ZZ   ,          -- x46
    ZZ   ,          -- x47
    ZZ   ,          -- x48
    ZZ   ,          -- x49
    x"2E",          -- x4A : num : /
    ZZ   ,          -- x4B
    ZZ   ,          -- x4C
    ZZ   ,          -- x4D
    ZZ   ,          -- x4E
    ZZ   ,          -- x4F
    ZZ   ,          -- x50
    ZZ   ,          -- x51
    ZZ   ,          -- x52
    ZZ   ,          -- x53
    ZZ   ,          -- x54
    ZZ   ,          -- x55
    ZZ   ,          -- x56
    ZZ   ,          -- x57
    ZZ   ,          -- x58
    ZZ   ,          -- x59
    x"5A",          -- x5A : num : Enter
    ZZ   ,          -- x5B
    ZZ   ,          -- x5C
    ZZ   ,          -- x5D
    ZZ   ,          -- x5E
    ZZ   ,          -- x5F
    ZZ   ,          -- x60
    ZZ   ,          -- x61
    ZZ   ,          -- x62
    ZZ   ,          -- x63
    ZZ   ,          -- x64
    ZZ   ,          -- x65
    ZZ   ,          -- x66
    ZZ   ,          -- x67
    ZZ   ,          -- x68
    x"4A",          -- x69 : End
    ZZ   ,          -- x6A
    x"18",          -- x6B : Left
    x"34",          -- x6C : Home
    ZZ   ,          -- x6D
    ZZ   ,          -- x6E
    ZZ   ,          -- x6F
    x"2C",          -- x70 : Insert
    x"42",          -- x71 : Del
    x"1B",          -- x72 : Down
    ZZ   ,          -- x73
    x"1C",          -- x74 : Right
    x"14",          -- x75 : Up
    ZZ   ,          -- x76
    ZZ   ,          -- x77
    ZZ   ,          -- x78
    ZZ   ,          -- x79
    x"7B",          -- x7A : PageDown
    ZZ   ,          -- x7B
    x"16",          -- x7C : PRTSCR (2) : Print Screen (R2)
    x"60",          -- x7D : PageUp
    ZZ   ,          -- x7E
    ZZ   ,          -- x7F
    ZZ   ,          -- x80
    ZZ   ,          -- x81
    ZZ   ,          -- x82
    ZZ   ,          -- x83
    ZZ   ,          -- x84
    ZZ   ,          -- x85
    ZZ   ,          -- x86
    ZZ   ,          -- x87
    ZZ   ,          -- x88
    ZZ   ,          -- x89
    ZZ   ,          -- x8A
    ZZ   ,          -- x8B
    ZZ   ,          -- x8C
    ZZ   ,          -- x8D
    ZZ   ,          -- x8E
    ZZ   ,          -- x8F
    ZZ   ,          -- x90
    ZZ   ,          -- x91
    ZZ   ,          -- x92
    ZZ   ,          -- x93
    ZZ   ,          -- x94
    ZZ   ,          -- x95
    ZZ   ,          -- x96
    ZZ   ,          -- x97
    ZZ   ,          -- x98
    ZZ   ,          -- x99
    ZZ   ,          -- x9A
    ZZ   ,          -- x9B
    ZZ   ,          -- x9C
    ZZ   ,          -- x9D
    ZZ   ,          -- x9E
    ZZ   ,          -- x9F
    ZZ   ,          -- xA0
    ZZ   ,          -- xA1
    ZZ   ,          -- xA2
    ZZ   ,          -- xA3
    ZZ   ,          -- xA4
    ZZ   ,          -- xA5
    ZZ   ,          -- xA6
    ZZ   ,          -- xA7
    ZZ   ,          -- xA8
    ZZ   ,          -- xA9
    ZZ   ,          -- xAA
    ZZ   ,          -- xAB
    ZZ   ,          -- xAC
    ZZ   ,          -- xAD
    ZZ   ,          -- xAE
    ZZ   ,          -- xAF
    ZZ   ,          -- xB0
    ZZ   ,          -- xB1
    ZZ   ,          -- xB2
    ZZ   ,          -- xB3
    ZZ   ,          -- xB4
    ZZ   ,          -- xB5
    ZZ   ,          -- xB6
    ZZ   ,          -- xB7
    ZZ   ,          -- xB8
    ZZ   ,          -- xB9
    ZZ   ,          -- xBA
    ZZ   ,          -- xBB
    ZZ   ,          -- xBC
    ZZ   ,          -- xBD
    ZZ   ,          -- xBE
    ZZ   ,          -- xBF
    ZZ   ,          -- xC0
    ZZ   ,          -- xC1
    ZZ   ,          -- xC2
    ZZ   ,          -- xC3
    ZZ   ,          -- xC4
    ZZ   ,          -- xC5
    ZZ   ,          -- xC6
    ZZ   ,          -- xC7
    ZZ   ,          -- xC8
    ZZ   ,          -- xC9
    ZZ   ,          -- xCA
    ZZ   ,          -- xCB
    ZZ   ,          -- xCC
    ZZ   ,          -- xCD
    ZZ   ,          -- xCE
    ZZ   ,          -- xCF
    ZZ   ,          -- xD0
    ZZ   ,          -- xD1
    ZZ   ,          -- xD2
    ZZ   ,          -- xD3
    ZZ   ,          -- xD4
    ZZ   ,          -- xD5
    ZZ   ,          -- xD6
    ZZ   ,          -- xD7
    ZZ   ,          -- xD8
    ZZ   ,          -- xD9
    ZZ   ,          -- xDA
    ZZ   ,          -- xDB
    ZZ   ,          -- xDC
    ZZ   ,          -- xDD
    ZZ   ,          -- xDE
    ZZ   ,          -- xDF
    ZZ   ,          -- xE0
    ZZ   ,          -- xE1
    ZZ   ,          -- xE2
    ZZ   ,          -- xE3
    ZZ   ,          -- xE4
    ZZ   ,          -- xE5
    ZZ   ,          -- xE6
    ZZ   ,          -- xE7
    ZZ   ,          -- xE8
    ZZ   ,          -- xE9
    ZZ   ,          -- xEA
    ZZ   ,          -- xEB
    ZZ   ,          -- xEC
    ZZ   ,          -- xED
    ZZ   ,          -- xEE
    ZZ   ,          -- xEF
    ZZ   ,          -- xF0
    ZZ   ,          -- xF1
    ZZ   ,          -- xF2
    ZZ   ,          -- xF3
    ZZ   ,          -- xF4
    ZZ   ,          -- xF5
    ZZ   ,          -- xF6
    ZZ   ,          -- xF7
    ZZ   ,          -- xF8
    ZZ   ,          -- xF9
    ZZ   ,          -- xFA
    ZZ   ,          -- xFB
    ZZ   ,          -- xFC
    ZZ   ,          -- xFD
    ZZ   ,          -- xFE
    ZZ   );         -- xFF
  
  -- PrintScreen : E0 12 E0 7C
  -- Pause : E1 14 77 E1 F0 14 F0 77

  -- Commande LEDs : ED + code 0:Scroll, 1:Num, 2=Caps

  -- PS2 :
  -- 1:  YV XV Y8 X8 1 M R L
  -- 2:  X[7:0]
  -- 3:  Y[7:0]
  -- XV,YV : Overflow
  
  -- Sun (Mouse Systems) :
  -- 1: 1 0 0 0 0 L M R
  -- 2: X[7:0]
  -- 3: Y[7:0]
  -- 4: X'[7:0]
  -- 5: Y'[7:0]
  
  SIGNAL k_tx_data,k_rx_data : uv8;
  SIGNAL k_tx_req,k_tx_ack,k_rx_err,k_rx_val : std_logic;
  SIGNAL m_tx_data,m_rx_data : uv8;
  SIGNAL m_tx_req,m_tx_ack,m_rx_err,m_rx_val : std_logic;


  CONSTANT PROF : natural := 16;
  SIGNAL m_fifo_d,k_fifo_d : arr_uv8(0 TO PROF-1);
  SIGNAL m_fifo_e,k_fifo_e : unsigned(0 TO PROF-1);
  SIGNAL m_lev,k_lev : natural RANGE 0 TO PROF;
  SIGNAL m_vv,m_vv2,k_vv,k_vv2 : std_logic;
  SIGNAL mfid : uv8;
  
  SIGNAL kb_data : uv8;
  SIGNAL kb_req,kb_rdy : std_logic;
  SIGNAL kfid,mad : uv8;
  SIGNAL xE0,xF0 : std_logic;

  -- The Sun keys a PC keyboard lacks (as in the Sun-2 core): Right Alt +
  -- F1..F10 are L1 (Stop) .. L10, Right Alt + F11 is Help. Right Alt alone
  -- sends nothing; with any other key it is AltGraph (0x0D), which goes
  -- down before that key and up with Right Alt. An F-key keeps the meaning
  -- it went down with, so letting go of Right Alt first leaves no L-key
  -- held; while an L-key is held, Right Alt is not AltGraph (Stop-A:
  -- Right Alt + F1, then A). Pause (E1 14 77 E1 F0 14 F0 77, make only)
  -- is the Sun Pause key; Print Screen is R2 (0x16).
  SIGNAL ralt,altg : std_logic;
  SIGNAL f_down,f_as_l : unsigned(0 TO 10);
  SIGNAL e1_cnt : natural RANGE 0 TO 7;
  -- The F-key a PS/2 code (not E0) is, 0..10 for F1..F11, 15 for none
  FUNCTION fkey (CONSTANT c : uv8) RETURN natural IS
  BEGIN
    CASE c IS
      WHEN x"05" => RETURN 0;  WHEN x"06" => RETURN 1;
      WHEN x"04" => RETURN 2;  WHEN x"0C" => RETURN 3;
      WHEN x"03" => RETURN 4;  WHEN x"0B" => RETURN 5;
      WHEN x"83" => RETURN 6;  WHEN x"0A" => RETURN 7;
      WHEN x"01" => RETURN 8;  WHEN x"09" => RETURN 9;
      WHEN x"78" => RETURN 10;
      WHEN OTHERS => RETURN 15;
    END CASE;
  END FUNCTION fkey;
  -- L1 Stop, L2 Again, L3 Props, L4 Undo, L5 Front, L6 Copy, L7 Open,
  -- L8 Paste, L9 Find, L10 Cut, Help
  CONSTANT LKEY : arr_uv8(0 TO 10) :=(
    x"01",x"03",x"19",x"1A",x"31",x"33",x"48",x"49",x"5F",x"61",x"76");

  SIGNAL leds : uv4;
  SIGNAL ledsm,ledsm_mem : std_logic;

  TYPE enum_k_stat IS (sOISIF,sRD,sTRANS,sTRANS2,sWRLED,sWRLED2,sWRLED3,sWRLED4);
  SIGNAL k_stat : enum_k_stat;

  TYPE enum_m_stat IS (sOISIF,sRD,sRDT,sPREP,sMO,sMO2);
  SIGNAL cmo : natural RANGE 0 TO 6;
  -- Mouse Systems output: motion accumulated from the PS/2 packets, sent
  -- as two halves per axis, each clamped to +/-48 so that no delta byte
  -- looks like a sync byte (NetBSD resyncs on (c AND 0xB0)=0x80).
  SIGNAL cse : natural RANGE 0 TO 5;
  SIGNAL acc_x,acc_y : signed(11 DOWNTO 0);
  SIGNAL m_btn : unsigned(2 DOWNTO 0);   -- M R L, active high
  SIGNAL m_x1,m_y1,m_x2,m_y2 : uv8;
  FUNCTION clamp48 (CONSTANT v : integer) RETURN integer IS
  BEGIN
    IF v>48 THEN
      RETURN 48;
    ELSIF v<-48 THEN
      RETURN -48;
    ELSE
      RETURN v;
    END IF;
  END FUNCTION clamp48;
  SIGNAL m_stat : enum_m_stat;
  SIGNAL dmou : unsigned(23 DOWNTO 0);
  
--------------------------------------------------------------------------------
  
BEGIN


  ------------------------------------------------------------------------------
  -- KBD
  -- 0 : PS2 : KBD DATA
  -- 1 : PS2 : KBD CLK
  i_ps2_kbd: ENTITY work.ps2
    GENERIC MAP (
      SYSFREQ => SYSFREQ)
    PORT MAP (
      di       => ps2_i(0),
      do       => ps2_o(0),
      cki      => ps2_i(1),
      cko      => ps2_o(1),
      tx_data  => k_tx_data,
      tx_req   => k_tx_req,
      tx_ack   => k_tx_ack,
      rx_data  => k_rx_data,
      rx_err   => k_rx_err,
      rx_val   => k_rx_val,
      clk      => clk,
      reset_n  => reset_n);
  
  i_ts_sunkb: ENTITY work.ts_sunkb
    PORT MAP (
      si_data  => di1_data,
      si_req   => di1_req,
      si_rdy   => di1_rdy,
      so_data  => do1_data,
      so_req   => do1_req,
      so_rdy   => do1_rdy,
      kb_data  => kb_data,
      kb_req   => kb_req,
      kb_rdy   => kb_rdy,
      leds     => leds,
      ledsm    => ledsm,
      layout   => kbm_layout,
      clk      => clk,
      reset_n  => reset_n);
  
  KBDConv: PROCESS (clk)
    VARIABLE dd_v,do : uv8;
    VARIABLE do_w,di_r : std_logic;
    VARIABLE fk_v : natural RANGE 0 TO 15;
    VARIABLE l_v : std_logic;
  BEGIN
    IF rising_edge(clk) THEN
      
      -------------------------------------------
      IF ledsm='1' THEN
        ledsm_mem<='1';
      ELSIF k_stat=sWRLED THEN
        ledsm_mem<='0';
      END IF;
      
      -------------------------------------------
      kfid<=k_fifo_d(k_lev);
      mad<=Mapping(to_integer(xE0 & kfid));
      mad(7)<='0';
      k_vv2<=k_vv;
      -------------------------------------------
      -- Clavier
      di_r:='0';
      do_w:='0';
      kb_req<='0';
      
      CASE k_stat IS
        WHEN sOISIF =>
          -- The LEDs go to Main through ps2_kbd_led_* (kbd_leds). Sending
          -- ED + value to the emulated PS/2 keyboard made ps2.vhd count
          -- hps_io's clocks as its own and drop incoming bytes for about
          -- 40 ms: a lost F0 left a key stuck down (kms A.6).
          IF k_vv2='1' THEN
            k_stat<=sRD;
          END IF;
          
        WHEN sRD =>
          fk_v:=fkey(kfid);
          IF e1_cnt/=0 THEN
            -- The rest of Pause's sequence: its make went with the E1, its
            -- break goes with the last byte
            di_r:='1';
            e1_cnt<=e1_cnt-1;
            IF e1_cnt=1 THEN
              kb_data<=x"95";
              kb_req<='1';
              k_stat<=sTRANS;
            ELSE
              k_stat<=sTRANS2;
            END IF;
          ELSIF kfid=x"E1" THEN
            di_r:='1';
            e1_cnt<=7;
            kb_data<=x"15";
            kb_req<='1';
            k_stat<=sTRANS;
          ELSIF kfid=x"E0" THEN
            xE0<='1';
            di_r:='1';
            k_stat<=sTRANS2;
          ELSIF kfid=x"F0" THEN
            xF0<='1';
            di_r:='1';
            k_stat<=sTRANS2;
          ELSIF xE0='1' AND kfid=x"11" THEN
            -- Right Alt: AltGraph comes up with it if it went down
            di_r:='1';
            ralt<=NOT xF0;
            IF xF0='1' AND altg='1' THEN
              kb_data<=x"8D";
              kb_req<='1';
              altg<='0';
              k_stat<=sTRANS;
            ELSE
              k_stat<=sTRANS2;
            END IF;
            xE0<='0';
            xF0<='0';
          ELSIF xE0='0' AND fk_v/=15 THEN
            -- F1..F11, or L1..L10 and Help with Right Alt
            di_r:='1';
            l_v:=f_as_l(fk_v);
            IF xF0='0' AND f_down(fk_v)='0' THEN
              l_v:=ralt;
              f_as_l(fk_v)<=ralt;
            END IF;
            f_down(fk_v)<=NOT xF0;
            IF l_v='1' THEN
              kb_data<=LKEY(fk_v);
            ELSE
              kb_data<=mad;
            END IF;
            kb_data(7)<=xF0;
            kb_req<='1';
            k_stat<=sTRANS;
            xF0<='0';
          ELSIF ralt='1' AND altg='0' AND xF0='0' AND mad/=x"00" AND
            (f_down AND f_as_l)=(f_down'range => '0') THEN
            -- A key with Right Alt held: AltGraph goes down first, and
            -- this byte is taken again on the next pass. Not while an
            -- L-key is held: Stop-A is Stop then A, with nothing between
            kb_data<=x"0D";
            kb_req<='1';
            altg<='1';
            k_stat<=sTRANS;
          ELSE
            di_r:='1';
            kb_data<=mad;
            kb_data(7)<=xF0;
            IF mad/=x"00" THEN
              kb_req<='1';
              k_stat<=sTRANS;
            ELSE
              k_stat<=sTRANS2;
            END IF;
            xE0<='0';
            xF0<='0';
          END IF;

        WHEN sTRANS =>
          IF kb_rdy='1' THEN
            k_stat<=sOISIF;
          END IF;
          
        WHEN sTRANS2 =>
          k_stat<=sOISIF;
          
        WHEN sWRLED =>
          do:=x"ED";
          do_w:='1';
          k_stat<=sWRLED2;
          
        WHEN sWRLED2 =>
          k_stat<=sWRLED3;
          
        WHEN sWRLED3 =>
          IF k_tx_req='0' THEN
            k_stat<=sWRLED4;
          END IF;
          
        WHEN sWRLED4 =>
          do(7 DOWNTO 3):="00000";
          do(0):=leds(2);  -- 0 : Scroll Lock
          do(1):=leds(0);  -- 1 :    Num Lock
          do(2):=leds(3);  -- 2 :   Caps Lock
          do_w:='1';
          k_stat<=sOISIF;
          
      END CASE;
      
      ------------------------------------------
      -- Traitement Emission
      IF do_w='1' THEN
        k_tx_data<=do(7 DOWNTO 0);
        k_tx_req<='1';
      END IF;
      IF k_tx_ack='1' THEN
        k_tx_req<='0';
      END IF;

      ------------------------------------------
      IF k_rx_val='1' THEN
        -- Empile
        k_fifo_d<=k_rx_data & k_fifo_d(0 TO PROF-2);
        k_fifo_e<=k_rx_err  & k_fifo_e(0 TO PROF-2);
        IF k_vv='1' AND k_lev<PROF-1 THEN
          k_lev<=k_lev+1;
        END IF;
        k_vv<='1';
      ELSIF di_r='1' THEN
        -- Dépile
        IF k_lev>0 THEN
          k_lev<=k_lev-1;
        ELSE
          k_vv<='0';
        END IF;
      END IF;

      ------------------------------------------
      IF reset_n='0' THEN
        k_lev<=0;
        k_vv<='0';
        k_stat<=sOISIF;
        k_tx_req<='0';
        xE0<='0';
        xF0<='0';
        ralt<='0';
        altg<='0';
        f_down<=(OTHERS => '0');
        f_as_l<=(OTHERS => '0');
        e1_cnt<=0;
      END IF;
    END IF;
  END PROCESS KBDConv;
  
  ------------------------------------------------------------------------------
  -- MOUSE
  
  -- 2 : PS2 : Mouse DATA
  -- 3 : PS2 : Mouse CLK
  i_ps2_mou: ENTITY work.ps2
    GENERIC MAP (
      SYSFREQ => SYSFREQ)
    PORT MAP (
      di       => ps2_i(2),
      do       => ps2_o(2),
      cki      => ps2_i(3),
      cko      => ps2_o(3),
      tx_data  => m_tx_data,
      tx_req   => m_tx_req,
      tx_ack   => m_tx_ack,
      rx_data  => m_rx_data,
      rx_err   => m_rx_err,
      rx_val   => m_rx_val,
      clk      => clk,
      reset_n  => reset_n);

  m_tx_req<='0';
  
  -----------------------------------------------
  
  MOUConv: PROCESS (clk)
    VARIABLE dd_v,do : uv8;
    VARIABLE di_r : std_logic;
    VARIABLE dx_v,dy_v : integer RANGE -256 TO 255;
    VARIABLE ax_v,ay_v : integer RANGE -2048 TO 2047;
    VARIABLE x1_v,y1_v,x2_v,y2_v : integer RANGE -48 TO 48;
  BEGIN
    IF rising_edge(clk) THEN
      m_vv2<=m_vv;
      mfid<=m_fifo_d(m_lev);
      -- Pop the FIFO only in the cycle a byte is taken (it was never
      -- cleared, so the FIFO emptied itself after the first byte).
      di_r:='0';
      
      -------------------------------------------
      -- Souris
      di2_req<='0';
      
      CASE m_stat IS
        WHEN sOISIF =>
          IF m_vv2='1' THEN
            m_stat<=sRD;
          ELSIF acc_x/=0 OR acc_y/=0 THEN
            -- Motion left over from the previous packet
            m_stat<=sPREP;
          END IF;
          
        WHEN sRD =>
          dmou<=dmou(15 DOWNTO 0) & mfid;
          di_r:='1';
          cmo<=cmo+1;
          IF cmo=0 AND mfid(3)='0' THEN
            -- Resynchro
            cmo<=0;
          END IF;
          m_stat<=sRDT;
          
        WHEN sRDT =>
          IF cmo/=3 THEN
            m_stat<=sOISIF;
          ELSE
            -- PS/2: YV XV YS XS 1 M R L | X[7:0] | Y[7:0]. Signed 9-bit
            -- deltas, saturated on overflow (a flick past 127 counts used
            -- to reverse direction), added to the pending motion.
            IF dmou(22)='1' THEN
              IF dmou(20)='1' THEN dx_v:=-256; ELSE dx_v:=255; END IF;
            ELSE
              dx_v:=to_integer(signed(dmou(20) & dmou(15 DOWNTO 8)));
            END IF;
            IF dmou(23)='1' THEN
              IF dmou(21)='1' THEN dy_v:=-256; ELSE dy_v:=255; END IF;
            ELSE
              dy_v:=to_integer(signed(dmou(21) & dmou(7 DOWNTO 0)));
            END IF;
            ax_v:=to_integer(acc_x)+dx_v;
            ay_v:=to_integer(acc_y)+dy_v;
            IF ax_v>1023 THEN ax_v:=1023; ELSIF ax_v<-1024 THEN ax_v:=-1024; END IF;
            IF ay_v>1023 THEN ay_v:=1023; ELSIF ay_v<-1024 THEN ay_v:=-1024; END IF;
            acc_x<=to_signed(ax_v,12);
            acc_y<=to_signed(ay_v,12);
            m_btn<=dmou(18 DOWNTO 16);
            cmo<=0;
            m_stat<=sPREP;
          END IF;
          
        WHEN sPREP =>
          ax_v:=to_integer(acc_x);
          ay_v:=to_integer(acc_y);
          x1_v:=clamp48(ax_v);
          x2_v:=clamp48(ax_v-x1_v);
          y1_v:=clamp48(ay_v);
          y2_v:=clamp48(ay_v-y1_v);
          acc_x<=to_signed(ax_v-x1_v-x2_v,12);
          acc_y<=to_signed(ay_v-y1_v-y2_v,12);
          m_x1<=unsigned(to_signed(x1_v,8));
          m_x2<=unsigned(to_signed(x2_v,8));
          m_y1<=unsigned(to_signed(y1_v,8));
          m_y2<=unsigned(to_signed(y2_v,8));
          cse<=0;
          m_stat<=sMO;
          
          -- Mouse Systems: 1 0 0 0 0 ~L ~M ~R | dX1 | dY1 | dX2 | dY2
        WHEN sMO =>
          di2_req<='1';
          CASE cse IS
            WHEN 0 =>
              di2_data<="10000" & NOT m_btn(0) & NOT m_btn(2) & NOT m_btn(1);
            WHEN 1 =>
              di2_data<=m_x1;
            WHEN 2 =>
              di2_data<=m_y1;
            WHEN 3 =>
              di2_data<=m_x2;
            WHEN OTHERS =>
              di2_data<=m_y2;
          END CASE;
          m_stat<=sMO2;
          
        WHEN sMO2 =>
          IF di2_rdy='1' THEN
            IF cse=4 THEN
              m_stat<=sOISIF;
            ELSE
              cse<=cse+1;
              m_stat<=sMO;
            END IF;
          END IF;
          
      END CASE;
      
      ------------------------------------------
      IF m_rx_val='1' THEN
        -- Empile
        m_fifo_d<=m_rx_data & m_fifo_d(0 TO PROF-2);
        m_fifo_e<=m_rx_err  & m_fifo_e(0 TO PROF-2);
        IF m_vv='1' AND m_lev<PROF-1 THEN
          m_lev<=m_lev+1;
        END IF;
        m_vv<='1';
      ELSIF di_r='1' THEN
        -- Dépile
        IF m_lev>0 THEN
          m_lev<=m_lev-1;
        ELSE
          m_vv<='0';
        END IF;
      END IF;

      ------------------------------------------
      IF reset_n='0' THEN
        m_lev<=0;
        m_vv<='0';
        m_stat<=sOISIF;
        cmo<=0;
        acc_x<=(OTHERS => '0');
        acc_y<=(OTHERS => '0');
        m_btn<="000";
      END IF;

    END IF;
  END PROCESS MOUConv;
  
  -- Sun LED byte: 0 Num Lock, 1 Compose, 2 Scroll Lock, 3 Caps Lock
  kbd_leds<=leds(2) & leds(0) & leds(3);
  
  -- Souris
  do2_rdy<='1';
  
END ARCHITECTURE rtl;
