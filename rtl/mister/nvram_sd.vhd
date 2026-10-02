--------------------------------------------------------------------------------
-- The NVRAM (M48T08, 8 KB) saved to an image file on the SD card (TOD-6)
--------------------------------------------------------------------------------
-- One hps_io block device: the OSD's "NVRAM" slot, an 8192-byte file. Main
-- remembers the file and mounts it again at every core load, before it
-- downloads boot.rom; it serves our sector requests once the download is
-- over. So:
--  - on a mount of an 8192-byte image, its 16 sectors are read into the
--    NVRAM (ts_rtc's RAM, through its second port). A mount of any other
--    size (an unmount reports 0) disconnects the image: nothing is read
--    from it or written to it;
--  - 'ready' holds the machine in reset (ss_core) until that load is over,
--    so the PROM never reads the NVRAM before it. Main sends no mount for
--    an empty slot: then 'ready' rises TIMEOUT after power-up. The DRAM
--    clear after the ROM download takes about as long;
--  - a CPU write to the RAM makes its sector dirty; QUIET after the last
--    one, the dirty sectors are written back to the image, one by one.
--    Read-only images are never written.
-- The image is a plain byte image: file byte n = NVRAM byte n (the IDPROM
-- at 0x1FD8, the clock registers at 0x1FF8). A blank file (IDPROM format
-- byte 0) gets the built-in IDPROM with a serial of its own (iram_rtc),
-- and that sector is written back after the load, so the machine keeps
-- its Ethernet address and hostid from then on.
--------------------------------------------------------------------------------

LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;

LIBRARY work;
USE work.base_pack.ALL;
USE work.ts_pack.ALL;

ENTITY nvram_sd IS
  GENERIC (
    SYSFREQ : natural := 50_000_000;
    SIMU    : natural := 0);   -- 1: short timers (sim/)
  PORT (
    -- hps_io, this image's slot
    img_mounted  : IN  std_logic;
    img_readonly : IN  std_logic;
    img_size     : IN  std_logic_vector(63 DOWNTO 0);
    sd_lba       : OUT std_logic_vector(31 DOWNTO 0);
    sd_rd        : OUT std_logic;
    sd_wr        : OUT std_logic;
    sd_ack       : IN  std_logic;
    sd_buff_addr : IN  std_logic_vector(7 DOWNTO 0);
    sd_buff_dout : IN  std_logic_vector(15 DOWNTO 0);
    sd_buff_din  : OUT std_logic_vector(15 DOWNTO 0);
    sd_buff_wr   : IN  std_logic;

    -- The NVRAM (ts_rtc)
    nv_w         : OUT type_nvram_w;
    nv_r         : IN  type_nvram_r;

    ready        : OUT std_logic;  -- the NVRAM holds the image, or none came

    clk          : IN  std_logic);
END ENTITY nvram_sd;

--##############################################################################

ARCHITECTURE rtl OF nvram_sd IS

  CONSTANT TIMEOUT : natural := mux(SIMU=1, 2_000, SYSFREQ * 3);
  CONSTANT LOADMAX : natural := mux(SIMU=1, 200_000, SYSFREQ * 6);
  CONSTANT QUIET   : natural := mux(SIMU=1, 20_000, SYSFREQ / 2);

  TYPE enum_state IS (sIDLE, sREQ, sXFER);
  SIGNAL state : enum_state := sIDLE;

  SIGNAL ena, ro      : std_logic := '0';  -- an image is connected; read-only
  SIGNAL loading      : std_logic := '0';  -- the transfers are reads
  SIGNAL load_pending : std_logic := '0';
  SIGNAL ready_i      : std_logic := '0';
  SIGNAL sec          : unsigned(3 DOWNTO 0) := x"0";
  SIGNAL dirty        : unsigned(15 DOWNTO 0) := x"0000";
  SIGNAL mnt_d        : std_logic := '0';
  SIGNAL ack_d        : std_logic := '0';
  SIGNAL rd_i, wr_i   : std_logic := '0';
  SIGNAL pon          : natural RANGE 0 TO LOADMAX := 0;
  SIGNAL quiet_cnt    : natural RANGE 0 TO QUIET := 0;
  SIGNAL idgen        : std_logic := '0';  -- the image's IDPROM was blank

  -- The halfword of the IDPROM format byte (0x1FD8): sector 15, 0xEC
  CONSTANT ID_SEC : unsigned(3 DOWNTO 0) := x"F";
  CONSTANT ID_HW  : std_logic_vector(7 DOWNTO 0) := x"EC";

  -- The lowest dirty sector
  FUNCTION first (CONSTANT v : unsigned(15 DOWNTO 0)) RETURN unsigned IS
  BEGIN
    FOR i IN 0 TO 15 LOOP
      IF v(i)='1' THEN
        RETURN to_unsigned(i,4);
      END IF;
    END LOOP;
    RETURN x"0";
  END FUNCTION first;

BEGIN

  Sync:PROCESS (clk)
    VARIABLE s : unsigned(3 DOWNTO 0);
  BEGIN
    IF rising_edge(clk) THEN
      mnt_d<=img_mounted;
      ack_d<=sd_ack;

      -- No image after TIMEOUT: run with the NVRAM as it is. A load that
      -- has not finished by LOADMAX is given up on.
      IF pon<LOADMAX THEN
        pon<=pon+1;
      END IF;
      IF (pon>=TIMEOUT AND ena='0' AND load_pending='0') OR pon=LOADMAX THEN
        ready_i<='1';
      END IF;

      CASE state IS
        WHEN sIDLE =>
          IF load_pending='1' THEN
            load_pending<='0';
            loading<='1';
            sec<=x"0";
            rd_i<='1';
            state<=sREQ;
          ELSIF ena='1' AND ro='0' AND dirty/=x"0000" AND quiet_cnt=0 THEN
            -- Cleared first: a write during the transfer marks it again.
            s:=first(dirty);
            dirty(to_integer(s))<='0';
            loading<='0';
            sec<=s;
            wr_i<='1';
            state<=sREQ;
          END IF;

        WHEN sREQ =>
          IF sd_ack='1' THEN
            rd_i<='0';
            wr_i<='0';
            state<=sXFER;
          END IF;

        WHEN sXFER =>
          IF ack_d='1' AND sd_ack='0' THEN
            state<=sIDLE;
            IF loading='1' THEN
              IF sec=x"F" THEN
                loading<='0';
                ready_i<='1';
                IF idgen='1' THEN
                  dirty(to_integer(ID_SEC))<='1';
                END IF;
              ELSE
                sec<=sec+1;
                rd_i<='1';
                state<=sREQ;
              END IF;
            END IF;
          END IF;
      END CASE;

      IF loading='1' AND sd_ack='1' AND sd_buff_wr='1' AND sec=ID_SEC
        AND sd_buff_addr=ID_HW THEN
        idgen<=to_std_logic(sd_buff_dout(7 DOWNTO 0)=x"00");
      END IF;

      -- CPU writes (after the CASE: a mark wins over the clear above)
      IF nv_r.chg='1' AND ena='1' THEN
        dirty(to_integer(nv_r.sec))<='1';
        quiet_cnt<=QUIET;
      ELSIF quiet_cnt>0 THEN
        quiet_cnt<=quiet_cnt-1;
      END IF;

      -- A mount (hps_io holds img_mounted for the whole command)
      IF img_mounted='1' AND mnt_d='0' THEN
        IF unsigned(img_size)=8192 THEN
          ena<='1';
          ro<=img_readonly;
          load_pending<='1';
        ELSE
          ena<='0';
          ready_i<='1';
        END IF;
        dirty<=x"0000";
      END IF;
    END IF;
  END PROCESS Sync;

  sd_lba<=x"0000000" & std_logic_vector(sec);
  sd_rd<=rd_i;
  sd_wr<=wr_i;
  ready<=ready_i;

  -- The sector buffer is the NVRAM itself.
  nv_w.a<=sec & unsigned(sd_buff_addr);
  nv_w.we<=loading AND sd_ack AND sd_buff_wr;
  nv_w.dw<=unsigned(sd_buff_dout);
  sd_buff_din<=std_logic_vector(nv_r.dr);

END ARCHITECTURE rtl;
