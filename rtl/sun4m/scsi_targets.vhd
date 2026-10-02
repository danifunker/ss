--------------------------------------------------------------------------------
-- SCSI targets: two disks and a CD-ROM on the ESP's record bus
--------------------------------------------------------------------------------
-- One engine serves every target (the record bus carries one nexus at a
-- time). It replaces the microcoded scsi_mist / scsi_mist_cdrom
-- (docs/design/scsi-hps.md, step S2, on the current Mac approach: no block
-- cache). Blocks move to and from hps_io in chunks of up to 32 (16 KB,
-- hps_io's sd_blk_cnt): Main writes an image O_SYNC, a few ms per call, so
-- an 8 KB write is one call instead of sixteen. Two 16 KB halves: the next
-- chunk is fetched (reads) or received (writes) while the other moves.
--
-- Slots: 0 HD0, 1 HD1, 2 CD, at the IDs on the ports (3, 1, 6 on a Sun).
-- A disk answers selection while its image is mounted; the CD answers
-- whenever it is enabled, NOT READY without a disc.
--
-- The record bus (ts_esp.vhd; design/scsi-hps.md 3.3):
--  - selection: the ESP drives did and samples sel one cycle later; sel
--    here is "a present target has this ID", registered;
--  - bsy is the initiator's: set at selection and by ICCS, cleared when
--    ICCS has taken status and message;
--  - a byte moves in a cycle where req (ours, registered) and ack (the
--    ESP's, combinational from req) are both high; req drops the next
--    cycle. On IN phases the ESP takes d in that cycle; on OUT phases its
--    data (DMA: a registered byte) is valid the cycle after, so the byte is
--    taken then (rx), and req goes up again only after that;
--  - ATN asks for MESSAGE OUT. OpenBIOS ends a command without data
--    (TEST UNIT READY) without ICCS, so the target stays in its STATUS
--    phase with bsy still set; its next selection with ATN finds the
--    target there: ATN in any phase but MESSAGE OUT starts MESSAGE OUT
--    (a new nexus). A change of did ends the nexus.
--
-- Behaviour follows SCSI-2 and QEMU's scsi-disk (where the test images
-- were installed): UNIT ATTENTION after a reset (29h) or a mount (28h),
-- fixed-format sense, bounds and write-protect checks, LUN 0 only, mode
-- pages 1, 4, 8 (disk) and 1, 8, 2Ah (CD), READ TOC formats 0 and 1, the
-- CD block size 2048 or 512 (OSD, or a MODE SELECT block descriptor).
--------------------------------------------------------------------------------
LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;

LIBRARY work;
USE work.base_pack.ALL;
USE work.ts_pack.ALL;

ENTITY scsi_targets IS
  PORT (
    scsi_w : IN  type_scsi_w;
    scsi_r : OUT type_scsi_r;

    -- The targets: slot 0 HD0, 1 HD1, 2 CD
    id0, id1, id2 : IN  unsigned(2 DOWNTO 0);
    ena           : IN  std_logic_vector(2 DOWNTO 0); -- slot in use (OSD)
    cd2048        : IN  std_logic;  -- CD block size after a reset: 2048/512

    -- The images (hps_io; img_mounted is held for the mount command)
    img_mounted   : IN  std_logic_vector(2 DOWNTO 0);
    img_size      : IN  std_logic_vector(63 DOWNTO 0);
    img_readonly  : IN  std_logic;

    -- Block requests, one slot at a time (ss_core's scsimux): raise rd/wr
    -- with lba and blk_cnt (blocks - 1) until ack; the words move while ack
    -- is high, hdb_adrs counting through the whole chunk.
    hd_lba   : OUT std_logic_vector(31 DOWNTO 0);
    hd_blk_cnt : OUT std_logic_vector(5 DOWNTO 0);
    hd_rd    : OUT std_logic_vector(2 DOWNTO 0);
    hd_wr    : OUT std_logic_vector(2 DOWNTO 0);
    hd_ack   : IN  std_logic_vector(2 DOWNTO 0);
    hdb_adrs : IN  std_logic_vector(12 DOWNTO 0);
    hdb_dw   : IN  std_logic_vector(15 DOWNTO 0);
    hdb_dr   : OUT std_logic_vector(15 DOWNTO 0);
    hdb_wr   : IN  std_logic_vector(2 DOWNTO 0);

    busy     : OUT std_logic;
    clk      : IN  std_logic;
    reset_n  : IN  std_logic);
END ENTITY scsi_targets;

--##############################################################################

ARCHITECTURE rtl OF scsi_targets IS

  -- Status bytes, sense keys
  CONSTANT ST_GOOD  : uv8 := x"00";
  CONSTANT ST_CHECK : uv8 := x"02";
  CONSTANT SK_NONE  : uv4 := x"0";
  CONSTANT SK_NREADY: uv4 := x"2";
  CONSTANT SK_ILLEG : uv4 := x"5";
  CONSTANT SK_UATT  : uv4 := x"6";
  CONSTANT SK_PROT  : uv4 := x"7";

  TYPE arr_uv3  IS ARRAY(0 TO 2) OF unsigned(2 DOWNTO 0);
  TYPE arr_t32  IS ARRAY(0 TO 2) OF uv32;
  TYPE arr_t8   IS ARRAY(0 TO 2) OF uv8;
  TYPE arr_t4   IS ARRAY(0 TO 2) OF uv4;

  -- The images
  SIGNAL mnt_d   : std_logic_vector(2 DOWNTO 0) := "000";
  SIGNAL blk512  : arr_t32 := (OTHERS => x"00000000"); -- 512-byte blocks
  SIGNAL ro      : std_logic_vector(2 DOWNTO 0) := "000";

  -- Per target state
  SIGNAL ua      : std_logic_vector(2 DOWNTO 0);       -- UNIT ATTENTION
  SIGNAL ua_asc  : arr_t8;
  SIGNAL s_key   : arr_t4;
  SIGNAL s_asc   : arr_t8;
  SIGNAL s_ascq  : arr_t8;
  SIGNAL s_info  : arr_t32;
  SIGNAL cd_bs2k : std_logic;                          -- CD: 2048-byte blocks

  -- The bus side
  TYPE enum_st IS (S_IDLE, S_SETTLE, S_MSGOUT, S_MSGIN_REPLY, S_CMD, S_EXEC,
                   S_TOCDIV, S_FILL, S_DIN, S_DOUT, S_DOUT_END, S_RD_WAIT,
                   S_STATUS, S_MSGIN, S_DONE);
  SIGNAL st      : enum_st;
  SIGNAL tgt     : natural RANGE 0 TO 2;
  SIGNAL lun     : unsigned(2 DOWNTO 0);
  SIGNAL ident   : std_logic;                          -- IDENTIFY received
  SIGNAL req_r   : std_logic;
  SIGNAL phase_r : unsigned(2 DOWNTO 0);
  SIGNAL d_r     : uv8;
  SIGNAL sel_r   : std_logic;
  SIGNAL settle  : natural RANGE 0 TO 7;
  SIGNAL dstep   : natural RANGE 0 TO 3;               -- DATA IN: a byte's steps
  SIGNAL got_msg : std_logic;                          -- MESSAGE OUT: a byte came
  SIGNAL rx_d    : std_logic;                          -- an OUT byte moved last cycle

  SIGNAL cdb     : arr_uv8(0 TO 11);
  SIGNAL cdb_i   : natural RANGE 0 TO 12;
  SIGNAL cdb_n   : natural RANGE 0 TO 12;

  -- Messages: an extended message, the reply
  SIGNAL ext_n, ext_i : natural RANGE 0 TO 255;
  SIGNAL ext_code     : uv8;
  SIGNAL ext_period   : uv8;
  SIGNAL in_ext       : std_logic;
  SIGNAL rep_kind     : natural RANGE 0 TO 2;          -- 0 none, 1 SDTR, 2 reject
  SIGNAL rep_i        : natural RANGE 0 TO 5;

  SIGNAL status  : uv8;

  -- Generated data (INQUIRY, sense, capacity, mode pages, TOC)
  TYPE enum_gen IS (G_INQ, G_INQ0, G_INQ80, G_SENSE, G_CAP, G_MSENSE, G_DEFECT,
                    G_TOC0, G_TOC1, G_TOCAA);
  SIGNAL gen     : enum_gen;
  SIGNAL gen_n   : natural RANGE 0 TO 255;             -- bytes to send
  SIGNAL gen_i   : natural RANGE 0 TO 255;
  SIGNAL resp_len: natural RANGE 0 TO 255;             -- the whole reply
  SIGNAL ms10    : std_logic;
  SIGNAL ms_dbd  : std_logic;
  SIGNAL ms_page : uv6;
  SIGNAL ms_pc   : uv2;
  SIGNAL msf     : std_logic;
  SIGNAL toc_m, toc_s, toc_f : uv8;                    -- lead-out, MSF
  SIGNAL toc_rem : unsigned(23 DOWNTO 0);
  SIGNAL sense_n : natural RANGE 0 TO 18;

  -- Block transfers
  SIGNAL xfer_wr   : std_logic;                        -- data out to the image
  SIGNAL xfer_disc : std_logic;                        -- data out, discarded
  CONSTANT CHUNK   : natural := 32;                    -- blocks per request
  TYPE arr_chn IS ARRAY(0 TO 1) OF natural RANGE 0 TO CHUNK;
  SIGNAL nbytes    : unsigned(13 DOWNTO 0);            -- byte in the half
  SIGNAL cur_last  : unsigned(13 DOWNTO 0);            -- its last byte
  SIGNAL cur_n     : natural RANGE 0 TO CHUNK;         -- its blocks
  SIGNAL ch_n      : arr_chn;                          -- blocks in each half
  SIGNAL tx_half   : std_logic;                        -- half on the bus side
  SIGNAL tx_left   : uv32;                             -- halves to move
  SIGNAL dout_n    : natural RANGE 0 TO 255;           -- MODE SELECT bytes
  SIGNAL dout_i    : natural RANGE 0 TO 255;
  SIGNAL msel_bl   : unsigned(23 DOWNTO 0);
  SIGNAL msel_bdl  : uv8;

  -- The hps side
  TYPE enum_hs IS (H_IDLE, H_REQ, H_XFER);
  SIGNAL hst       : enum_hs;
  SIGNAL h_lba     : uv32;
  SIGNAL h_left    : uv32;                             -- blocks to fetch/store
  SIGNAL h_half    : std_logic;
  SIGNAL h_cnt     : natural RANGE 0 TO CHUNK;         -- blocks in this request
  SIGNAL h_rd, h_wr: std_logic;
  SIGNAL h_wmode   : std_logic;
  SIGNAL full      : std_logic_vector(1 DOWNTO 0);

  -- The buffer: two halves of 16 KB; even and odd bytes apart, so
  -- hps_io's 16-bit words (byte 2w low, 2w+1 high) write both at once
  SHARED VARIABLE mem_e : arr_uv8(0 TO 16383);
  SHARED VARIABLE mem_o : arr_uv8(0 TO 16383);
  ATTRIBUTE ramstyle : string;
  ATTRIBUTE ramstyle OF mem_e, mem_o : VARIABLE IS "no_rw_check";
  SIGNAL a_adr   : unsigned(14 DOWNTO 0);              -- byte: half & 14 bits
  SIGNAL a_we    : std_logic;
  SIGNAL a_dw    : uv8;
  SIGNAL a_dre, a_dro : uv8;
  SIGNAL a_odd   : std_logic;
  SIGNAL b_adr   : unsigned(13 DOWNTO 0);              -- word: half & 13 bits
  SIGNAL b_we    : std_logic;
  SIGNAL b_dre, b_dro : uv8;

  ------------------------------------------------------------------------------
  FUNCTION ascii (CONSTANT s : string; CONSTANT i : natural) RETURN uv8 IS
  BEGIN
    RETURN to_unsigned(character'pos(s(s'low + i)), 8);
  END FUNCTION ascii;

  -- byte k (0: the low one) of a word; k is taken modulo 4
  FUNCTION b8 (CONSTANT v : uv32; CONSTANT k : integer) RETURN uv8 IS
  BEGIN
    CASE k MOD 4 IS
      WHEN 0      => RETURN v(7 DOWNTO 0);
      WHEN 1      => RETURN v(15 DOWNTO 8);
      WHEN 2      => RETURN v(23 DOWNTO 16);
      WHEN OTHERS => RETURN v(31 DOWNTO 24);
    END CASE;
  END FUNCTION b8;

  CONSTANT VENDOR  : string(1 TO 8)  := "MiSTer  ";
  CONSTANT PROD_HD : string(1 TO 16) := "SCSI Disk       ";
  CONSTANT PROD_CD : string(1 TO 16) := "SCSI CD-ROM     ";
  CONSTANT REV     : string(1 TO 4)  := "1.0 ";

  -- Mode pages: their total length (header included), by page code
  FUNCTION page_len (CONSTANT p : uv6) RETURN natural IS
  BEGIN
    CASE to_integer(p) IS
      WHEN 16#01# => RETURN 12;
      WHEN 16#04# => RETURN 24;
      WHEN 16#08# => RETURN 20;
      WHEN 16#2A# => RETURN 22;
      WHEN OTHERS => RETURN 0;
    END CASE;
  END FUNCTION page_len;

  -- Byte j of mode page p; pc: the page control (1: changeable, all 0)
  FUNCTION page_byte (CONSTANT p : uv6; CONSTANT j : natural;
                      CONSTANT pc : uv2; CONSTANT cd : boolean;
                      CONSTANT cyl : unsigned(23 DOWNTO 0)) RETURN uv8 IS
  BEGIN
    IF j = 0 THEN RETURN "00" & p; END IF;
    IF j = 1 THEN RETURN to_unsigned(page_len(p) - 2, 8); END IF;
    IF pc = "01" THEN RETURN x"00"; END IF;
    CASE to_integer(p) IS
      WHEN 16#01# =>                    -- read/write error recovery
        IF j = 2 THEN RETURN x"80"; END IF;          -- AWRE
        IF j = 3 AND cd THEN RETURN x"20"; END IF;   -- read retry count
      WHEN 16#04# =>                    -- rigid disk geometry
        CASE j IS
          WHEN 2 | 6 | 9  => RETURN cyl(23 DOWNTO 16);
          WHEN 3 | 7 | 10 => RETURN cyl(15 DOWNTO 8);
          WHEN 4 | 8 | 11 => RETURN cyl(7 DOWNTO 0);
          WHEN 5          => RETURN x"10";            -- 16 heads
          WHEN 13         => RETURN x"C8";            -- step rate 200 ns
          WHEN 14 | 15 | 16 => RETURN x"FF";          -- landing zone
          WHEN 20         => RETURN x"15";            -- 5400 rpm
          WHEN 21         => RETURN x"18";
          WHEN OTHERS     => NULL;
        END CASE;
      WHEN 16#2A# =>                    -- CD capabilities
        CASE j IS
          WHEN 2  => RETURN x"3B";
          WHEN 4  => RETURN x"7F";
          WHEN 5  => RETURN x"FF";
          WHEN 6  => RETURN x"2D";
          WHEN 8  => RETURN x"22";      -- 50x (8800 KB/s)
          WHEN 9  => RETURN x"60";
          WHEN 11 => RETURN x"02";      -- two volume levels
          WHEN 12 => RETURN x"08";      -- 2 MB buffer
          WHEN OTHERS => NULL;
        END CASE;
      WHEN OTHERS => NULL;
    END CASE;
    RETURN x"00";
  END FUNCTION page_byte;

BEGIN

  ------------------------------------------------------------------------------
  -- The buffer. Port A: the bus side, bytes. Port B: hps_io, words.
  PortA:PROCESS (clk)
  BEGIN
    IF rising_edge(clk) THEN
      IF a_we = '1' AND a_adr(0) = '0' THEN
        mem_e(to_integer(a_adr(14 DOWNTO 1))) := a_dw;
      END IF;
      IF a_we = '1' AND a_adr(0) = '1' THEN
        mem_o(to_integer(a_adr(14 DOWNTO 1))) := a_dw;
      END IF;
      a_dre <= mem_e(to_integer(a_adr(14 DOWNTO 1)));
      a_dro <= mem_o(to_integer(a_adr(14 DOWNTO 1)));
      a_odd <= a_adr(0);
    END IF;
  END PROCESS PortA;

  b_adr <= h_half & unsigned(hdb_adrs);
  b_we  <= (hdb_wr(0) OR hdb_wr(1) OR hdb_wr(2)) AND NOT h_wmode;

  PortB:PROCESS (clk)
  BEGIN
    IF rising_edge(clk) THEN
      IF b_we = '1' THEN
        mem_e(to_integer(b_adr)) := unsigned(hdb_dw(7 DOWNTO 0));
        mem_o(to_integer(b_adr)) := unsigned(hdb_dw(15 DOWNTO 8));
      END IF;
      b_dre <= mem_e(to_integer(b_adr));
      b_dro <= mem_o(to_integer(b_adr));
    END IF;
  END PROCESS PortB;

  hdb_dr <= std_logic_vector(b_dro) & std_logic_vector(b_dre);

  ------------------------------------------------------------------------------
  Sync:PROCESS (clk)
    VARIABLE match_v : std_logic_vector(2 DOWNTO 0);
    VARIABLE ids_v   : arr_uv3;
    VARIABLE xfer_v  : boolean;
    VARIABLE rx_v    : boolean;
    VARIABLE set_v, clr_v : std_logic_vector(1 DOWNTO 0);
    VARIABLE op_v    : uv8;
    VARIABLE lba_v, n_v, last_v, cnt_v : uv32;
    VARIABLE blocks_v: uv32;
    VARIABLE iscd_v  : boolean;
    VARIABLE noMed_v : boolean;
    VARIABLE alloc_v : natural RANGE 0 TO 65535;
    VARIABLE len_v   : natural RANGE 0 TO 255;
    VARIABLE stat_v  : uv8;
    VARIABLE key_v   : uv4;
    VARIABLE asc_v   : uv8;
    VARIABLE gen_v   : boolean;
    VARIABLE b_v     : uv8;
    VARIABLE j_v, k_v: natural RANGE 0 TO 255;
    VARIABLE hdr_v, bd_v : natural RANGE 0 TO 15;
    VARIABLE pg_v    : uv6;
    VARIABLE cyl_v   : unsigned(23 DOWNTO 0);
    VARIABLE bs_v    : unsigned(23 DOWNTO 0);
    VARIABLE bd_blk_v: unsigned(23 DOWNTO 0);
    VARIABLE trk_v   : uv8;
    VARIABLE acked_v : boolean;
    VARIABLE p1_v, p2_v, p3_v : natural RANGE 0 TO 255;

    -- the bus side's view of a target
    PROCEDURE check (CONSTANT k : uv4; CONSTANT a : uv8) IS
    BEGIN
      stat_v := ST_CHECK; key_v := k; asc_v := a;
    END PROCEDURE check;

  BEGIN
    IF rising_edge(clk) THEN
      ------------------------------------------------------------------------
      -- Mounts (no reset: they outlive the machine's resets, as the slots)
      mnt_d <= img_mounted;
      FOR n IN 0 TO 2 LOOP
        IF img_mounted(n) = '1' AND mnt_d(n) = '0' THEN
          blk512(n) <= unsigned(img_size(40 DOWNTO 9));
          ro(n)     <= img_readonly OR to_std_logic(n = 2);
          ua(n)     <= '1';
          ua_asc(n) <= x"28";                        -- medium changed
        END IF;
      END LOOP;

      ids_v := (id0, id1, id2);
      FOR n IN 0 TO 2 LOOP
        match_v(n) := ena(n) AND to_std_logic(scsi_w.did = ids_v(n)) AND
                      (to_std_logic(n = 2) OR to_std_logic(blk512(n) /= 0));
      END LOOP;
      sel_r <= match_v(0) OR match_v(1) OR match_v(2);

      xfer_v := req_r = '1' AND scsi_w.ack = '1';
      IF xfer_v THEN
        req_r <= '0';
      END IF;
      -- an OUT phase's byte (IO = 0), valid now on scsi_w.d
      rx_v := rx_d = '1';
      rx_d <= to_std_logic(xfer_v AND phase_r(0) = '0');
      a_we  <= '0';
      set_v := "00";
      clr_v := "00";
      gen_v := false;

      ------------------------------------------------------------------------
      -- The bus side
      CASE st IS
        WHEN S_IDLE =>
          req_r <= '0';
          ident <= '0';
          lun   <= "000";
          IF scsi_w.bsy = '1' AND (match_v(0) OR match_v(1) OR match_v(2)) = '1'
          THEN
            IF match_v(0) = '1' THEN tgt <= 0;
            ELSIF match_v(1) = '1' THEN tgt <= 1;
            ELSE tgt <= 2;
            END IF;
            settle <= 4;
            st <= S_SETTLE;
          END IF;

        WHEN S_SETTLE =>
          -- ATN comes a cycle or two after bsy when bsy was left set
          IF settle > 0 THEN
            settle <= settle - 1;
          ELSIF scsi_w.atn = '1' THEN
            phase_r <= SCSI_MSG_OUT;
            in_ext  <= '0';
            got_msg <= '0';
            st <= S_MSGOUT;
          ELSE
            phase_r <= SCSI_COMMAND;
            cdb_i <= 0;
            cdb_n <= 6;
            st <= S_CMD;
          END IF;

        WHEN S_MSGOUT =>
          IF rx_v THEN
            got_msg <= '1';
            b_v := scsi_w.d;
            IF in_ext = '1' THEN
              IF ext_n = 0 THEN                       -- the length byte
                ext_n <= to_integer(b_v);
                ext_i <= 0;
                IF b_v = 0 THEN in_ext <= '0'; rep_kind <= 2; END IF;
              ELSE
                IF ext_i = 0 THEN ext_code <= b_v; END IF;
                IF ext_i = 1 THEN ext_period <= b_v; END IF;
                IF ext_i + 1 = ext_n THEN
                  in_ext <= '0';
                  -- SDTR: answered asynchronous (offset 0); the rest rejected
                  IF ext_code = x"01" OR (ext_i = 0 AND b_v = x"01") THEN
                    rep_kind <= 1;
                  ELSE
                    rep_kind <= 2;
                  END IF;
                END IF;
                ext_i <= ext_i + 1;
              END IF;
            ELSIF b_v(7) = '1' THEN                   -- IDENTIFY
              lun   <= b_v(2 DOWNTO 0);
              ident <= '1';
            ELSIF b_v = x"01" THEN                    -- extended message
              in_ext <= '1';
              ext_n  <= 0;
            ELSIF b_v = x"06" OR b_v = x"0C" THEN     -- ABORT, BUS DEVICE RESET
              IF b_v = x"0C" THEN
                ua(tgt) <= '1';
                ua_asc(tgt) <= x"29";
              END IF;
              st <= S_DONE;
            ELSIF b_v /= x"07" AND b_v /= x"08" THEN  -- not REJECT, NOP
              rep_kind <= 2;
            END IF;
          ELSIF xfer_v THEN
            NULL;                                     -- the byte comes next
          ELSIF req_r = '0' THEN
            -- Decided before req goes up again, so that no byte of the next
            -- phase is taken here: the message is complete and ATN is off
            -- (the ESP drops ATN with the last message byte)
            IF got_msg = '1' AND in_ext = '0' AND scsi_w.atn = '0' THEN
              IF rep_kind /= 0 THEN
                phase_r <= SCSI_MSG_IN;
                rep_i <= 0;
                st <= S_MSGIN_REPLY;
              ELSE
                phase_r <= SCSI_COMMAND;
                cdb_i <= 0;
                cdb_n <= 6;
                st <= S_CMD;
              END IF;
            ELSE
              req_r <= '1';
            END IF;
          END IF;

        WHEN S_MSGIN_REPLY =>
          -- SDTR: 01 03 01 period 00 (asynchronous); else MESSAGE REJECT
          IF rep_kind = 1 THEN
            CASE rep_i IS
              WHEN 0 => d_r <= x"01";
              WHEN 1 => d_r <= x"03";
              WHEN 2 => d_r <= x"01";
              WHEN 3 => d_r <= ext_period;
              WHEN OTHERS => d_r <= x"00";
            END CASE;
          ELSE
            d_r <= x"07";
          END IF;
          IF req_r = '0' AND NOT xfer_v THEN
            req_r <= '1';
          END IF;
          IF xfer_v THEN
            IF (rep_kind = 1 AND rep_i = 4) OR rep_kind = 2 THEN
              rep_kind <= 0;
              IF scsi_w.atn = '1' THEN
                phase_r <= SCSI_MSG_OUT;
                in_ext  <= '0';
                got_msg <= '0';
                st <= S_MSGOUT;
              ELSE
                phase_r <= SCSI_COMMAND;
                cdb_i <= 0;
                cdb_n <= 6;
                st <= S_CMD;
              END IF;
            ELSE
              rep_i <= rep_i + 1;
            END IF;
          END IF;

        WHEN S_CMD =>
          IF req_r = '0' AND NOT xfer_v AND NOT rx_v AND cdb_i < cdb_n THEN
            req_r <= '1';
          END IF;
          IF rx_v THEN
            cdb(cdb_i) <= scsi_w.d;
            IF cdb_i = 0 THEN
              CASE scsi_w.d(7 DOWNTO 5) IS
                WHEN "001" | "010" => cdb_n <= 10;
                WHEN "101"         => cdb_n <= 12;
                WHEN OTHERS        => cdb_n <= 6;
              END CASE;
            END IF;
            cdb_i <= cdb_i + 1;
          ELSIF cdb_i = cdb_n AND req_r = '0' AND NOT xfer_v THEN
            st <= S_EXEC;
          END IF;

        ------------------------------------------------------------------------
        WHEN S_EXEC =>
         IF hst = H_IDLE THEN
          op_v    := cdb(0);
          iscd_v  := tgt = 2;
          IF iscd_v AND cd_bs2k = '1' THEN
            blocks_v := "00" & blk512(tgt)(31 DOWNTO 2);
          ELSE
            blocks_v := blk512(tgt);
          END IF;
          noMed_v := blk512(tgt) = 0;
          stat_v  := ST_GOOD;
          key_v   := SK_NONE;
          asc_v   := x"00";
          IF ident = '0' THEN
            lun <= cdb(1)(7 DOWNTO 5);               -- SCSI-1: LUN in the CDB
          END IF;
          xfer_wr   <= '0';
          xfer_disc <= '0';
          tx_left   <= x"00000000";
          ms10      <= '0';

          -- The data a command moves: gen_v (generated, gen/len_v), or
          -- blocks (lba_v, n_v) in or out
          gen_v := false;
          len_v := 0;
          n_v   := x"00000000";
          lba_v := x"00000000";
          alloc_v := 0;

          IF (ident = '1' AND lun /= "000") OR
             (ident = '0' AND cdb(1)(7 DOWNTO 5) /= "000") THEN
            -- LUN 0 only
            IF op_v = x"12" THEN                      -- INQUIRY: qualifier 3
              gen <= G_INQ; gen_v := true; len_v := 36;
              alloc_v := to_integer(cdb(4));
            ELSIF op_v = x"03" THEN                   -- REQUEST SENSE
              s_key(tgt) <= SK_ILLEG;
              s_asc(tgt) <= x"25";
              s_ascq(tgt) <= x"00";
              gen <= G_SENSE; gen_v := true; len_v := 18;
              alloc_v := to_integer(cdb(4));
              IF alloc_v = 0 THEN alloc_v := 4; END IF;
            ELSE
              check(SK_ILLEG, x"25");
            END IF;

          ELSIF ua(tgt) = '1' AND op_v /= x"12" AND op_v /= x"03" THEN
            -- UNIT ATTENTION, reported once
            ua(tgt) <= '0';
            check(SK_UATT, ua_asc(tgt));

          ELSE
            CASE op_v IS
              WHEN x"00" | x"01" | x"1B" | x"1E" | x"16" | x"17" | x"35" =>
                -- TEST UNIT READY, REZERO, START STOP, PREVENT ALLOW,
                -- RESERVE, RELEASE, SYNCHRONIZE CACHE
                IF noMed_v AND (op_v = x"00" OR op_v = x"01") THEN
                  check(SK_NREADY, x"3A");
                END IF;

              WHEN x"03" =>                           -- REQUEST SENSE
                gen <= G_SENSE; gen_v := true; len_v := 18;
                alloc_v := to_integer(cdb(4));
                IF alloc_v = 0 THEN alloc_v := 4; END IF;
                IF ua(tgt) = '1' THEN
                  ua(tgt) <= '0';
                  s_key(tgt) <= SK_UATT;
                  s_asc(tgt) <= ua_asc(tgt);
                  s_ascq(tgt) <= x"00";
                END IF;

              WHEN x"04" =>                           -- FORMAT UNIT
                IF iscd_v THEN
                  check(SK_ILLEG, x"20");
                ELSIF cdb(1)(4) = '1' THEN            -- with a parameter list
                  check(SK_ILLEG, x"24");
                END IF;

              WHEN x"12" =>                           -- INQUIRY
                alloc_v := to_integer(cdb(4));
                IF cdb(1)(0) = '1' THEN               -- EVPD
                  IF cdb(2) = x"00" THEN
                    gen <= G_INQ0; gen_v := true; len_v := 6;
                  ELSIF cdb(2) = x"80" THEN
                    gen <= G_INQ80; gen_v := true; len_v := 12;
                  ELSE
                    check(SK_ILLEG, x"24");
                  END IF;
                ELSIF cdb(2) /= x"00" THEN
                  check(SK_ILLEG, x"24");
                ELSE
                  gen <= G_INQ; gen_v := true; len_v := 36;
                END IF;

              WHEN x"08" | x"0A" | x"0B" | x"28" | x"2A" | x"2B" | x"2F" |
                   x"A8" | x"AA" =>
                -- READ, WRITE, SEEK, VERIFY (6, 10, 12)
                IF op_v(7 DOWNTO 5) = "000" THEN
                  lba_v := x"00" & "000" & cdb(1)(4 DOWNTO 0) & cdb(2) & cdb(3);
                  n_v   := x"000000" & cdb(4);
                  IF cdb(4) = 0 AND op_v /= x"0B" THEN
                    n_v := x"00000100";
                  END IF;
                ELSIF op_v(7 DOWNTO 5) = "001" THEN
                  lba_v := cdb(2) & cdb(3) & cdb(4) & cdb(5);
                  n_v   := x"0000" & cdb(7) & cdb(8);
                ELSE
                  lba_v := cdb(2) & cdb(3) & cdb(4) & cdb(5);
                  n_v   := cdb(6) & cdb(7) & cdb(8) & cdb(9);
                END IF;
                IF op_v = x"0B" OR op_v = x"2B" THEN
                  n_v := x"00000000";                 -- SEEK: no data
                END IF;
                last_v := lba_v + n_v;
                IF noMed_v THEN
                  check(SK_NREADY, x"3A");
                ELSIF (op_v = x"0A" OR op_v = x"2A" OR op_v = x"AA") AND iscd_v
                THEN
                  check(SK_ILLEG, x"20");
                ELSIF (op_v = x"0A" OR op_v = x"2A" OR op_v = x"AA") AND
                      ro(tgt) = '1' THEN
                  check(SK_PROT, x"27");
                ELSIF op_v = x"2F" AND cdb(1)(1) = '1' THEN
                  check(SK_ILLEG, x"24");             -- VERIFY with BYTCHK
                ELSIF lba_v >= blocks_v OR last_v > blocks_v OR last_v < lba_v
                THEN
                  IF NOT (n_v = 0 AND lba_v <= blocks_v) THEN
                    check(SK_ILLEG, x"21");
                  END IF;
                ELSIF op_v = x"2F" THEN
                  NULL;                               -- VERIFY: nothing to do
                ELSIF n_v /= 0 THEN
                  -- in 512-byte blocks for hps_io
                  IF iscd_v AND cd_bs2k = '1' THEN
                    lba_v := lba_v(29 DOWNTO 0) & "00";
                    n_v   := n_v(29 DOWNTO 0) & "00";
                  END IF;
                  tx_left <= n_v;
                  h_lba   <= lba_v;
                  h_left  <= n_v;
                  -- the first chunk to receive (writes)
                  IF n_v > CHUNK THEN
                    cur_n <= CHUNK;
                    cur_last <= to_unsigned(CHUNK * 512 - 1, 14);
                    ch_n(0) <= CHUNK;
                  ELSE
                    cur_n <= to_integer(n_v(5 DOWNTO 0));
                    cur_last <= (n_v(4 DOWNTO 0) & "000000000") - 1;
                    ch_n(0) <= to_integer(n_v(5 DOWNTO 0));
                  END IF;
                  IF op_v = x"0A" OR op_v = x"2A" OR op_v = x"AA" THEN
                    xfer_wr <= '1';
                    h_wmode <= '1';
                  ELSE
                    h_wmode <= '0';
                  END IF;
                END IF;
                s_info(tgt) <= lba_v;

              WHEN x"25" =>                           -- READ CAPACITY
                IF noMed_v THEN
                  check(SK_NREADY, x"3A");
                ELSE
                  gen <= G_CAP; gen_v := true; len_v := 8; alloc_v := 8;
                END IF;

              WHEN x"1A" | x"5A" =>                   -- MODE SENSE (6, 10)
                ms_dbd  <= cdb(1)(3);
                ms_page <= cdb(2)(5 DOWNTO 0);
                ms_pc   <= cdb(2)(7 DOWNTO 6);
                pg_v    := cdb(2)(5 DOWNTO 0);
                IF op_v = x"1A" THEN
                  ms10 <= '0'; hdr_v := 4;
                  alloc_v := to_integer(cdb(4));
                ELSE
                  ms10 <= '1'; hdr_v := 8;
                  alloc_v := to_integer(cdb(7) & cdb(8));
                END IF;
                IF cdb(1)(3) = '1' THEN bd_v := 0; ELSE bd_v := 8; END IF;
                IF iscd_v THEN
                  p1_v := 12; p2_v := 20; p3_v := 22;   -- pages 1, 8, 2A
                ELSE
                  p1_v := 12; p2_v := 24; p3_v := 20;   -- pages 1, 4, 8
                END IF;
                IF cdb(2)(7 DOWNTO 6) = "11" THEN
                  check(SK_ILLEG, x"39");               -- saved values
                ELSIF pg_v = "111111" THEN
                  len_v := hdr_v + bd_v + p1_v + p2_v + p3_v;
                ELSIF pg_v = "000000" THEN
                  len_v := hdr_v + bd_v;
                ELSIF pg_v = "000001" OR pg_v = "001000" OR
                      (pg_v = "000100" AND NOT iscd_v) OR
                      (pg_v = "101010" AND iscd_v) THEN
                  len_v := hdr_v + bd_v + page_len(pg_v);
                ELSE
                  check(SK_ILLEG, x"24");
                END IF;
                IF stat_v = ST_GOOD THEN
                  gen <= G_MSENSE; gen_v := true;
                END IF;

              WHEN x"15" | x"55" =>                   -- MODE SELECT (6, 10)
                IF op_v = x"15" THEN
                  alloc_v := to_integer(cdb(4));
                ELSE
                  alloc_v := to_integer(cdb(7) & cdb(8));
                END IF;
                ms10 <= op_v(6);
                IF alloc_v > 255 THEN
                  check(SK_ILLEG, x"24");
                ELSIF alloc_v > 0 THEN
                  dout_n    <= alloc_v;
                  dout_i    <= 0;
                  xfer_disc <= '1';
                  msel_bl   <= (OTHERS => '0');
                  msel_bdl  <= x"00";
                END IF;

              WHEN x"37" =>                           -- READ DEFECT DATA
                IF iscd_v THEN
                  check(SK_ILLEG, x"20");
                ELSE
                  gen <= G_DEFECT; gen_v := true; len_v := 4;
                  alloc_v := to_integer(cdb(7) & cdb(8));
                END IF;

              WHEN x"1D" =>                           -- SEND DIAGNOSTIC
                IF cdb(3) /= 0 OR cdb(4) /= 0 THEN
                  check(SK_ILLEG, x"24");
                END IF;

              WHEN x"43" =>                           -- READ TOC
                msf     <= cdb(1)(1);
                alloc_v := to_integer(cdb(7) & cdb(8));
                trk_v   := cdb(6);
                IF NOT iscd_v THEN
                  check(SK_ILLEG, x"20");
                ELSIF noMed_v THEN
                  check(SK_NREADY, x"3A");
                ELSIF cdb(2)(3 DOWNTO 0) = x"1" OR cdb(9)(7 DOWNTO 6) = "01" THEN
                  gen <= G_TOC1; gen_v := true; len_v := 12;
                ELSIF cdb(2)(3 DOWNTO 0) /= x"0" OR
                      (trk_v > 1 AND trk_v /= x"AA") THEN
                  check(SK_ILLEG, x"24");
                ELSIF trk_v = x"AA" THEN
                  gen <= G_TOCAA; gen_v := true; len_v := 12;
                ELSE
                  gen <= G_TOC0; gen_v := true; len_v := 20;
                END IF;
                -- lead-out = the disc's blocks of 2048 bytes, plus 150
                -- frames for MSF
                toc_rem <= blk512(2)(25 DOWNTO 2) + 150;
                toc_m <= x"00";
                toc_s <= x"00";

              WHEN OTHERS =>
                check(SK_ILLEG, x"20");               -- invalid command
            END CASE;
          END IF;

          -- Sense: kept from the last CHECK until the next command
          IF op_v /= x"03" THEN
            s_key(tgt)  <= key_v;
            s_asc(tgt)  <= asc_v;
            s_ascq(tgt) <= x"00";
          END IF;
          status <= stat_v;
          resp_len <= len_v;
          IF alloc_v < len_v THEN
            gen_n <= alloc_v;
          ELSE
            gen_n <= len_v;
          END IF;
          gen_i <= 0;
          nbytes  <= (OTHERS => '0');
          tx_half <= '0';
          h_half  <= '0';
          full    <= "00";

          IF stat_v /= ST_GOOD THEN
            phase_r <= SCSI_STATUS;
            st <= S_STATUS;
          ELSIF gen_v AND (alloc_v /= 0 AND len_v /= 0) THEN
            IF op_v = x"43" THEN
              st <= S_TOCDIV;
            ELSE
              st <= S_FILL;
            END IF;
          ELSIF (op_v = x"15" OR op_v = x"55") AND alloc_v > 0 THEN
            phase_r <= SCSI_DATA_OUT;
            st <= S_DOUT;
          ELSIF n_v /= 0 AND (op_v = x"0A" OR op_v = x"2A" OR op_v = x"AA") THEN
            phase_r <= SCSI_DATA_OUT;
            st <= S_DOUT;
          ELSIF n_v /= 0 AND op_v /= x"2F" THEN
            phase_r <= SCSI_DATA_IN;
            st <= S_RD_WAIT;
          ELSE
            phase_r <= SCSI_STATUS;
            st <= S_STATUS;
          END IF;
         END IF;

        ------------------------------------------------------------------------
        WHEN S_TOCDIV =>
          -- lead-out MSF: minutes, seconds, frames from frames
          IF toc_rem >= 4500 THEN
            toc_rem <= toc_rem - 4500;
            toc_m <= toc_m + 1;
          ELSIF toc_rem >= 75 THEN
            toc_rem <= toc_rem - 75;
            toc_s <= toc_s + 1;
          ELSE
            toc_f <= toc_rem(7 DOWNTO 0);
            st <= S_FILL;
          END IF;

        WHEN S_FILL =>
          -- the generated reply into half 0, one byte a cycle
          b_v := x"00";
          j_v := gen_i;
          bs_v := to_unsigned(512, 24);
          IF tgt = 2 AND cd_bs2k = '1' THEN
            bs_v := to_unsigned(2048, 24);
          END IF;
          IF tgt = 2 AND cd_bs2k = '1' THEN
            blocks_v := "00" & blk512(tgt)(31 DOWNTO 2);
          ELSE
            blocks_v := blk512(tgt);
          END IF;
          CASE gen IS
            WHEN G_INQ =>
              CASE j_v IS
                WHEN 0 =>
                  IF lun /= "000" THEN b_v := x"7F";
                  ELSIF tgt = 2 THEN b_v := x"05";
                  END IF;
                WHEN 1 => IF tgt = 2 THEN b_v := x"80"; END IF;  -- RMB
                WHEN 2 => b_v := x"02";               -- SCSI-2
                WHEN 3 => b_v := x"02";
                WHEN 4 => b_v := x"1F";               -- 36 bytes
                WHEN 8 TO 15  => b_v := ascii(VENDOR, j_v - 8);
                WHEN 16 TO 31 =>
                  IF tgt = 2 THEN b_v := ascii(PROD_CD, j_v - 16);
                  ELSE b_v := ascii(PROD_HD, j_v - 16);
                  END IF;
                WHEN 32 TO 35 => b_v := ascii(REV, j_v - 32);
                WHEN OTHERS => NULL;
              END CASE;
            WHEN G_INQ0 =>                            -- supported VPD pages
              CASE j_v IS
                WHEN 0 => IF tgt = 2 THEN b_v := x"05"; END IF;
                WHEN 3 => b_v := x"02";
                WHEN 5 => b_v := x"80";
                WHEN OTHERS => NULL;
              END CASE;
            WHEN G_INQ80 =>                           -- unit serial number
              CASE j_v IS
                WHEN 0 => IF tgt = 2 THEN b_v := x"05"; END IF;
                WHEN 1 => b_v := x"80";
                WHEN 3 => b_v := x"08";
                WHEN 4 TO 10 => b_v := ascii("MISTER0", j_v - 4);
                WHEN 11 => b_v := to_unsigned(16#30# + tgt, 8);
                WHEN OTHERS => NULL;
              END CASE;
            WHEN G_SENSE =>
              CASE j_v IS
                WHEN 0 => b_v := x"70";
                WHEN 2 => b_v := "0000" & s_key(tgt);
                WHEN 3 TO 6 => b_v := b8(s_info(tgt), 6 - j_v);
                WHEN 7 => b_v := x"0A";
                WHEN 12 => b_v := s_asc(tgt);
                WHEN 13 => b_v := s_ascq(tgt);
                WHEN OTHERS => NULL;
              END CASE;
            WHEN G_CAP =>
              last_v := blocks_v - 1;
              IF j_v < 4 THEN
                b_v := b8(last_v, 3 - j_v);
              ELSE
                b_v := b8(x"00" & bs_v, 7 - j_v);
              END IF;
            WHEN G_DEFECT =>
              IF j_v = 1 THEN b_v := "000" & cdb(2)(4 DOWNTO 0); END IF;
            WHEN G_MSENSE =>
              IF ms10 = '1' THEN hdr_v := 8; ELSE hdr_v := 4; END IF;
              IF ms_dbd = '1' THEN bd_v := 0; ELSE bd_v := 8; END IF;
              IF blocks_v(31 DOWNTO 24) /= 0 THEN
                bd_blk_v := x"FFFFFF";
              ELSE
                bd_blk_v := blocks_v(23 DOWNTO 0);
              END IF;
              cyl_v := "0000000000" & blk512(tgt)(23 DOWNTO 10);
              IF blk512(tgt)(31 DOWNTO 24) /= 0 THEN cyl_v := x"FFFFFF"; END IF;
              IF j_v < hdr_v THEN                     -- header
                IF ms10 = '0' THEN
                  IF j_v = 0 THEN b_v := to_unsigned(resp_len - 1, 8); END IF;
                  IF j_v = 2 AND ro(tgt) = '1' THEN b_v := x"80"; END IF;
                  IF j_v = 3 THEN b_v := to_unsigned(bd_v, 8); END IF;
                ELSE
                  IF j_v = 1 THEN b_v := to_unsigned(resp_len - 2, 8); END IF;
                  IF j_v = 3 AND ro(tgt) = '1' THEN b_v := x"80"; END IF;
                  IF j_v = 7 THEN b_v := to_unsigned(bd_v, 8); END IF;
                END IF;
              ELSIF j_v < hdr_v + bd_v THEN           -- block descriptor
                k_v := j_v - hdr_v;
                CASE k_v IS
                  WHEN 1 => b_v := bd_blk_v(23 DOWNTO 16);
                  WHEN 2 => b_v := bd_blk_v(15 DOWNTO 8);
                  WHEN 3 => b_v := bd_blk_v(7 DOWNTO 0);
                  WHEN 5 => b_v := bs_v(23 DOWNTO 16);
                  WHEN 6 => b_v := bs_v(15 DOWNTO 8);
                  WHEN 7 => b_v := bs_v(7 DOWNTO 0);
                  WHEN OTHERS => NULL;
                END CASE;
              ELSE                                    -- pages
                k_v := j_v - hdr_v - bd_v;
                IF ms_page = "111111" THEN
                  IF tgt = 2 THEN
                    IF k_v < 12 THEN
                      b_v := page_byte("000001", k_v, ms_pc, true, cyl_v);
                    ELSIF k_v < 32 THEN
                      b_v := page_byte("001000", k_v - 12, ms_pc, true, cyl_v);
                    ELSE
                      b_v := page_byte("101010", k_v - 32, ms_pc, true, cyl_v);
                    END IF;
                  ELSE
                    IF k_v < 12 THEN
                      b_v := page_byte("000001", k_v, ms_pc, false, cyl_v);
                    ELSIF k_v < 36 THEN
                      b_v := page_byte("000100", k_v - 12, ms_pc, false, cyl_v);
                    ELSE
                      b_v := page_byte("001000", k_v - 36, ms_pc, false, cyl_v);
                    END IF;
                  END IF;
                ELSE
                  b_v := page_byte(ms_page, k_v, ms_pc, tgt = 2, cyl_v);
                END IF;
              END IF;
            WHEN G_TOC0 | G_TOCAA | G_TOC1 =>
              -- header: data length, first, last; then 8-byte descriptors
              IF j_v = 1 THEN
                IF gen = G_TOC0 THEN b_v := x"12"; ELSE b_v := x"0A"; END IF;
              ELSIF j_v = 2 OR j_v = 3 THEN
                b_v := x"01";
              ELSIF j_v >= 4 THEN
                k_v := (j_v - 4) MOD 8;
                IF gen = G_TOCAA OR (gen = G_TOC0 AND j_v >= 12) THEN
                  -- the lead-out
                  CASE k_v IS
                    WHEN 1 => b_v := x"14";
                    WHEN 2 => b_v := x"AA";
                    WHEN 4 TO 7 =>
                      IF msf = '1' THEN
                        CASE k_v IS
                          WHEN 5 => b_v := toc_m;
                          WHEN 6 => b_v := toc_s;
                          WHEN 7 => b_v := toc_f;
                          WHEN OTHERS => NULL;
                        END CASE;
                      ELSE
                        b_v := b8("00" & blk512(2)(31 DOWNTO 2), 7 - k_v);
                      END IF;
                    WHEN OTHERS => NULL;
                  END CASE;
                ELSE
                  -- track 1 (format 0) or the first session's (format 1)
                  CASE k_v IS
                    WHEN 1 => b_v := x"14";
                    WHEN 2 => b_v := x"01";
                    WHEN 6 => IF msf = '1' THEN b_v := x"02"; END IF;
                    WHEN OTHERS => NULL;
                  END CASE;
                END IF;
              END IF;
          END CASE;
          a_adr <= to_unsigned(gen_i, 15);
          a_dw  <= b_v;
          a_we  <= '1';
          IF gen_i + 1 >= gen_n THEN
            gen_i <= 0;
            IF gen = G_SENSE THEN                     -- reported: cleared
              s_key(tgt)  <= SK_NONE;
              s_asc(tgt)  <= x"00";
              s_ascq(tgt) <= x"00";
            END IF;
            nbytes <= (OTHERS => '0');
            phase_r <= SCSI_DATA_IN;
            dstep <= 0;
            st <= S_DIN;
          ELSE
            gen_i <= gen_i + 1;
          END IF;

        ------------------------------------------------------------------------
        WHEN S_RD_WAIT =>
          -- a block from the image: wait until its half is full
          IF full(to_integer(unsigned'("" & tx_half))) = '1' THEN
            nbytes <= (OTHERS => '0');
            cur_n <= ch_n(to_integer(unsigned'("" & tx_half)));
            cur_last <= to_unsigned(
              ch_n(to_integer(unsigned'("" & tx_half))) * 512 - 1, 14);
            dstep <= 0;
            st <= S_DIN;
          END IF;

        WHEN S_DIN =>
          -- bytes out of the buffer: the address (step 0), the RAM's cycle
          -- (1), data and req (2), the handshake (3)
          CASE dstep IS
            WHEN 0 =>
              IF tx_left = 0 THEN
                a_adr <= '0' & nbytes;                -- generated data
              ELSE
                a_adr <= tx_half & nbytes;
              END IF;
              dstep <= 1;
            WHEN 1 =>
              dstep <= 2;
            WHEN 2 =>
              IF a_odd = '1' THEN d_r <= a_dro; ELSE d_r <= a_dre; END IF;
              req_r <= '1';
              dstep <= 3;
            WHEN 3 =>
              NULL;
          END CASE;
          IF xfer_v THEN
            dstep <= 0;
            IF tx_left = 0 THEN
              -- generated data
              IF to_integer(nbytes) + 1 >= gen_n THEN
                phase_r <= SCSI_STATUS;
                st <= S_STATUS;
              ELSE
                nbytes <= nbytes + 1;
              END IF;
            ELSIF nbytes = cur_last THEN
              -- a chunk is out: free its half
              clr_v(to_integer(unsigned'("" & tx_half))) := '1';
              tx_half <= NOT tx_half;
              nbytes <= (OTHERS => '0');
              IF tx_left = to_unsigned(cur_n, 32) THEN
                tx_left <= x"00000000";
                phase_r <= SCSI_STATUS;
                st <= S_STATUS;
              ELSE
                tx_left <= tx_left - cur_n;
                st <= S_RD_WAIT;
              END IF;
            ELSE
              nbytes <= nbytes + 1;
            END IF;
          END IF;

        WHEN S_DOUT =>
          -- bytes into the buffer: to the image (WRITE) or for MODE SELECT
          IF xfer_disc = '0' AND full(to_integer(unsigned'("" & tx_half))) = '1'
          THEN
            NULL;                                     -- the half is still busy
          ELSIF req_r = '0' AND NOT xfer_v AND NOT rx_v THEN
            req_r <= '1';
          END IF;
          IF rx_v THEN
            IF xfer_disc = '1' THEN
              -- MODE SELECT: the block descriptor's block length
              IF ms10 = '0' THEN
                IF dout_i = 3 THEN msel_bdl <= scsi_w.d; END IF;
                IF dout_i = 9 THEN msel_bl(23 DOWNTO 16) <= scsi_w.d; END IF;
                IF dout_i = 10 THEN msel_bl(15 DOWNTO 8) <= scsi_w.d; END IF;
                IF dout_i = 11 THEN msel_bl(7 DOWNTO 0) <= scsi_w.d; END IF;
              ELSE
                IF dout_i = 7 THEN msel_bdl <= scsi_w.d; END IF;
                IF dout_i = 13 THEN msel_bl(23 DOWNTO 16) <= scsi_w.d; END IF;
                IF dout_i = 14 THEN msel_bl(15 DOWNTO 8) <= scsi_w.d; END IF;
                IF dout_i = 15 THEN msel_bl(7 DOWNTO 0) <= scsi_w.d; END IF;
              END IF;
              IF dout_i + 1 >= dout_n THEN
                st <= S_DOUT_END;
              ELSE
                dout_i <= dout_i + 1;
              END IF;
            ELSE
              a_adr <= tx_half & nbytes;
              a_dw  <= scsi_w.d;
              a_we  <= '1';
              IF nbytes = cur_last THEN
                set_v(to_integer(unsigned'("" & tx_half))) := '1';
                tx_half <= NOT tx_half;
                nbytes <= (OTHERS => '0');
                cnt_v := tx_left - cur_n;
                tx_left <= cnt_v;
                IF cnt_v = 0 THEN
                  st <= S_DOUT_END;
                ELSIF cnt_v > CHUNK THEN
                  cur_n <= CHUNK;
                  cur_last <= to_unsigned(CHUNK * 512 - 1, 14);
                  ch_n(to_integer(unsigned'("" & NOT tx_half))) <= CHUNK;
                ELSE
                  cur_n <= to_integer(cnt_v(5 DOWNTO 0));
                  cur_last <= (cnt_v(4 DOWNTO 0) & "000000000") - 1;
                  ch_n(to_integer(unsigned'("" & NOT tx_half))) <=
                    to_integer(cnt_v(5 DOWNTO 0));
                END IF;
              ELSE
                nbytes <= nbytes + 1;
              END IF;
            END IF;
          END IF;

        WHEN S_DOUT_END =>
          -- MODE SELECT: a CD block size; WRITE: every block on the image
          IF xfer_disc = '1' THEN
            IF tgt = 2 AND msel_bdl >= 8 THEN
              IF msel_bl = 2048 THEN cd_bs2k <= '1'; END IF;
              IF msel_bl = 512 THEN cd_bs2k <= '0'; END IF;
            END IF;
            xfer_disc <= '0';
            phase_r <= SCSI_STATUS;
            st <= S_STATUS;
          ELSIF full = "00" AND h_left = 0 AND hst = H_IDLE THEN
            phase_r <= SCSI_STATUS;
            st <= S_STATUS;
          END IF;

        ------------------------------------------------------------------------
        WHEN S_STATUS =>
          d_r <= status;
          IF req_r = '0' AND NOT xfer_v THEN
            req_r <= '1';
          END IF;
          IF xfer_v THEN
            phase_r <= SCSI_MSG_IN;
            st <= S_MSGIN;
          END IF;

        WHEN S_MSGIN =>
          d_r <= x"00";                               -- COMMAND COMPLETE
          IF req_r = '0' AND NOT xfer_v THEN
            req_r <= '1';
          END IF;
          IF xfer_v THEN
            st <= S_DONE;
          END IF;

        WHEN S_DONE =>
          req_r <= '0';
          IF scsi_w.bsy = '0' THEN
            st <= S_IDLE;
          END IF;
      END CASE;

      ------------------------------------------------------------------------
      -- A new nexus, an abort: ATN outside MESSAGE OUT, did elsewhere
      IF st /= S_IDLE AND st /= S_SETTLE AND st /= S_MSGOUT AND
         st /= S_EXEC AND st /= S_FILL AND st /= S_TOCDIV AND
         st /= S_DOUT_END AND scsi_w.atn = '1' AND NOT xfer_v AND NOT rx_v THEN
        req_r   <= '0';
        phase_r <= SCSI_MSG_OUT;
        in_ext  <= '0';
        got_msg <= '0';
        rep_kind <= 0;
        h_left  <= x"00000000";                       -- no more blocks
        st <= S_MSGOUT;
      END IF;
      IF st /= S_IDLE AND scsi_w.did /= ids_v(tgt) THEN
        req_r <= '0';
        h_left <= x"00000000";
        st <= S_IDLE;
      END IF;

      ------------------------------------------------------------------------
      -- The hps side: fetch blocks into empty halves (reads), store full
      -- halves (writes)
      CASE hst IS
        WHEN H_IDLE =>
          IF h_left /= 0 AND
             ((h_wmode = '0' AND full(to_integer(unsigned'("" & h_half))) = '0')
              OR
              (h_wmode = '1' AND full(to_integer(unsigned'("" & h_half))) = '1'))
          THEN
            IF h_wmode = '1' THEN
              h_wr  <= '1';
              h_cnt <= ch_n(to_integer(unsigned'("" & h_half)));
            ELSE
              h_rd  <= '1';
              IF h_left > CHUNK THEN
                h_cnt <= CHUNK;
                ch_n(to_integer(unsigned'("" & h_half))) <= CHUNK;
              ELSE
                h_cnt <= to_integer(h_left(5 DOWNTO 0));
                ch_n(to_integer(unsigned'("" & h_half))) <=
                  to_integer(h_left(5 DOWNTO 0));
              END IF;
            END IF;
            hst <= H_REQ;
          END IF;
        WHEN H_REQ =>
          IF hd_ack(tgt) = '1' THEN
            h_rd <= '0';
            h_wr <= '0';
            hst <= H_XFER;
          END IF;
        WHEN H_XFER =>
          IF hd_ack(tgt) = '0' THEN
            IF h_wmode = '1' THEN
              clr_v(to_integer(unsigned'("" & h_half))) := '1';
            ELSE
              set_v(to_integer(unsigned'("" & h_half))) := '1';
            END IF;
            h_half <= NOT h_half;
            h_lba  <= h_lba + h_cnt;
            h_left <= h_left - h_cnt;
            hst <= H_IDLE;
          END IF;
      END CASE;

      IF st = S_EXEC THEN
        NULL;                                         -- full set by S_EXEC
      ELSE
        full <= (full OR set_v) AND NOT clr_v;
      END IF;

      ------------------------------------------------------------------------
      IF scsi_w.rst = '1' OR reset_n = '0' THEN
        st      <= S_IDLE;
        req_r   <= '0';
        ua      <= "111";
        ua_asc  <= (x"29", x"29", x"29");
        rep_kind <= 0;
        xfer_disc <= '0';
        h_left  <= x"00000000";
        dstep   <= 0;
      END IF;
      IF reset_n = '0' THEN
        cd_bs2k <= cd2048;
        s_key   <= (SK_NONE, SK_NONE, SK_NONE);
        hst     <= H_IDLE;
        h_rd    <= '0';
        h_wr    <= '0';
        full    <= "00";
      END IF;
    END IF;
  END PROCESS Sync;

  hd_lba <= std_logic_vector(h_lba);
  hd_blk_cnt <= std_logic_vector(to_unsigned(h_cnt - 1, 6)) WHEN h_cnt /= 0
                ELSE "000000";
  hd_rd  <= (h_rd AND to_std_logic(tgt = 2)) &
            (h_rd AND to_std_logic(tgt = 1)) &
            (h_rd AND to_std_logic(tgt = 0));
  hd_wr  <= (h_wr AND to_std_logic(tgt = 2)) &
            (h_wr AND to_std_logic(tgt = 1)) &
            (h_wr AND to_std_logic(tgt = 0));

  scsi_r.d     <= d_r;
  scsi_r.req   <= req_r;
  scsi_r.phase <= phase_r;
  scsi_r.sel   <= sel_r;
  scsi_r.d_pc  <= to_unsigned(enum_st'pos(st), 10);
  busy <= to_std_logic(st /= S_IDLE) OR h_rd OR h_wr;

END ARCHITECTURE rtl;
