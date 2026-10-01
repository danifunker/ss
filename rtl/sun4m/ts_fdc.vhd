--------------------------------------------------------------------------------
-- TEM : TS
-- Intel 82077AA floppy disk controller, with no drive attached
--------------------------------------------------------------------------------
-- Every sun4m machine has one (SS5 pa 0x7140_0000, SS20 pa 0xF_F170_0000,
-- byte registers 0-7). The Sun OBP resets it at start-up and recalibrates
-- the drive to find out whether one is present ("fdc-init",
-- "drive-present?"); with no controller it polls the main status register
-- for RQM forever. OSes under the Sun OBP probe it too.
--
-- This model takes every command and answers as a controller whose drive
-- is missing: RECALIBRATE ends with Equipment Check (no track 0 signal),
-- SEEK ends normally, and every transfer ends at once with "missing
-- address mark". SPECIFY, CONFIGURE, PERPENDICULAR, LOCK, DUMPREG and
-- VERSION behave as on the 82077AA (the OBP's selftest reads them back).
-- The interrupt (level 11 on sun4m) is raised, while DOR.DMAGATE is set,
-- for the four polled-drive status changes after a reset, at the end of a
-- SEEK or RECALIBRATE (both cleared by SENSE INTERRUPT STATUS), and at the
-- result phase of a transfer (cleared by reading the first result byte).
--
-- Registers (offset): 0 SRA, 1 SRB (read 0), 2 DOR, 3 TDR, 4 MSR (read) /
-- DSR (write), 5 FIFO, 7 DIR (read, DSKCHG set) / CCR (write, ignored).
--------------------------------------------------------------------------------

LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;

LIBRARY work;
USE work.base_pack.ALL;
USE work.plomb_pack.ALL;

ENTITY ts_fdc IS
  PORT (
    sel     : IN  std_logic;
    w       : IN  type_pvc_w;
    r       : OUT type_pvc_r;
    int     : OUT std_logic;

    -- Global
    clk     : IN  std_logic;
    reset_n : IN  std_logic
    );
END ENTITY ts_fdc;

--##############################################################################

ARCHITECTURE rtl OF ts_fdc IS

  TYPE enum_phase IS (sCMD, sPARAM, sRESULT);
  SIGNAL phase : enum_phase;

  TYPE arr_byte IS ARRAY(natural RANGE <>) OF uv8;
  SIGNAL prm : arr_byte(0 TO 7);        -- parameter bytes received
  SIGNAL res : arr_byte(0 TO 9);        -- result bytes to send
  SIGNAL pcn : arr_byte(0 TO 3);        -- present cylinder, per drive
  SIGNAL cmd : uv8;
  SIGNAL np,ip : natural RANGE 0 TO 8;  -- parameters expected, received
  SIGNAL nr,ir : natural RANGE 0 TO 10; -- results to send, sent

  SIGNAL dor,tdr : uv8;
  SIGNAL spec1,spec2,perp,conf2,conf3 : uv8;
  SIGNAL lock : std_logic;

  SIGNAL rst_int  : natural RANGE 0 TO 4; -- polled-drive interrupts left
  SIGNAL seek_int : std_logic;            -- a SEEK or RECALIBRATE ended
  SIGNAL seek_st0 : uv8;
  SIGNAL xfer_int : std_logic;            -- result phase of a transfer

  SIGNAL rsel : std_logic;
  SIGNAL dr   : uv8;

  -- Parameter bytes of each command (opcode = bits 4:0)
  FUNCTION nparams(c : uv8) RETURN natural IS
  BEGIN
    CASE c(4 DOWNTO 0) IS
      WHEN "00010" | "00101" | "00110" | "01001" | "01100" |
           "10001" | "10110" | "11001" | "11101" =>
        RETURN 8;                       -- read/write/verify/scan
      WHEN "01101" => RETURN 5;         -- FORMAT TRACK
      WHEN "10011" => RETURN 3;         -- CONFIGURE
      WHEN "00011" | "01111" => RETURN 2; -- SPECIFY, (RELATIVE) SEEK
      WHEN "00100" | "00111" | "01010" | "10010" =>
        RETURN 1;                       -- SENSE DRIVE, RECALIBRATE, READ ID,
                                        -- PERPENDICULAR
      WHEN OTHERS => RETURN 0;          -- SENSE INT, DUMPREG, VERSION, LOCK,
                                        -- invalid
    END CASE;
  END FUNCTION nparams;

BEGIN

  rsel<=w.req AND sel;

  Sync:PROCESS(clk)
    VARIABLE b_v   : uv8;                -- the byte written
    VARIABLE ex_v  : boolean;            -- the command is complete
    VARIABLE c_v   : uv8;
    VARIABLE p_v   : arr_byte(0 TO 7);
    VARIABLE ds_v  : natural RANGE 0 TO 3;
    VARIABLE rst_v : boolean;
  BEGIN
    IF rising_edge(clk) THEN
      CASE w.a(1 DOWNTO 0) IS           -- big-endian byte lanes
        WHEN "00"   => b_v:=w.dw(31 DOWNTO 24);
        WHEN "01"   => b_v:=w.dw(23 DOWNTO 16);
        WHEN "10"   => b_v:=w.dw(15 DOWNTO 8);
        WHEN OTHERS => b_v:=w.dw(7 DOWNTO 0);
      END CASE;
      ex_v:=false;
      rst_v:=false;
      c_v:=cmd;
      p_v:=prm;
      dr<=x"00";

      IF rsel='1' THEN
        CASE w.a(2 DOWNTO 0) IS
          WHEN "010" =>                 -- DOR
            IF w.wr='1' THEN
              dor<=b_v;
              IF b_v(2)='0' THEN
                rst_v:=true;            -- held in reset
                rst_int<=0;
              ELSIF dor(2)='0' THEN
                rst_v:=true;            -- leaves reset
                rst_int<=4;
              END IF;
            END IF;
            dr<=dor;

          WHEN "011" =>                 -- TDR
            IF w.wr='1' THEN
              tdr<=b_v;
            END IF;
            dr<=tdr;

          WHEN "100" =>                 -- MSR / DSR
            IF w.wr='1' THEN
              IF b_v(7)='1' THEN        -- software reset
                rst_v:=true;
                rst_int<=4;
              END IF;
            END IF;
            IF dor(2)='0' THEN
              dr<=x"00";
            ELSIF phase=sCMD THEN
              dr<=x"80";                -- RQM
            ELSIF phase=sPARAM THEN
              dr<=x"90";                -- RQM, CB
            ELSE
              dr<=x"D0";                -- RQM, DIO, CB
            END IF;

          WHEN "101" =>                 -- FIFO
            IF w.wr='1' THEN
              IF phase=sCMD THEN
                c_v:=b_v;
                cmd<=b_v;
                np<=nparams(b_v);
                ip<=0;
                IF nparams(b_v)=0 THEN
                  ex_v:=true;
                ELSE
                  phase<=sPARAM;
                END IF;
              ELSIF phase=sPARAM THEN
                p_v(ip):=b_v;
                prm(ip)<=b_v;
                ip<=ip+1;
                IF ip+1=np THEN
                  ex_v:=true;
                END IF;
              END IF;
            ELSIF phase=sRESULT THEN
              dr<=res(ir);
              xfer_int<='0';
              IF ir+1=nr THEN
                phase<=sCMD;
              END IF;
              ir<=ir+1;
            END IF;

          WHEN "111" =>                 -- DIR / CCR
            dr<=x"80";                  -- DSKCHG: no diskette

          WHEN OTHERS =>                -- SRA, SRB
            dr<=x"00";
        END CASE;
      END IF;

      -- Execution: no drive, so every command ends at once
      IF ex_v THEN
        ds_v:=to_integer(p_v(0)(1 DOWNTO 0));
        res<=(OTHERS => x"00");
        ir<=0;
        nr<=0;
        phase<=sCMD;
        CASE c_v(4 DOWNTO 0) IS
          WHEN "00011" =>               -- SPECIFY
            spec1<=p_v(0);
            spec2<=p_v(1);

          WHEN "00100" =>               -- SENSE DRIVE STATUS: ST3, no T0/WP
            res(0)<=x"28" OR (p_v(0) AND x"07");
            nr<=1;
            phase<=sRESULT;

          WHEN "00111" =>               -- RECALIBRATE: no track 0 signal
            pcn(ds_v)<=x"00";
            seek_st0<=x"70" OR (p_v(0) AND x"03"); -- IC=01, SE, EC
            seek_int<='1';

          WHEN "01111" =>               -- SEEK, RELATIVE SEEK
            IF c_v(7)='0' THEN
              pcn(ds_v)<=p_v(1);
            ELSIF c_v(6)='1' THEN
              pcn(ds_v)<=pcn(ds_v) + p_v(1);
            ELSE
              pcn(ds_v)<=pcn(ds_v) - p_v(1);
            END IF;
            seek_st0<=x"20" OR (p_v(0) AND x"07"); -- SE
            seek_int<='1';

          WHEN "01000" =>               -- SENSE INTERRUPT STATUS
            IF rst_int/=0 THEN
              res(0)<=x"C0" OR to_unsigned(4-rst_int,8);
              res(1)<=pcn(4-rst_int);
              rst_int<=rst_int-1;
              nr<=2;
            ELSIF seek_int='1' THEN
              res(0)<=seek_st0;
              res(1)<=pcn(to_integer(seek_st0(1 DOWNTO 0)));
              seek_int<='0';
              nr<=2;
            ELSE
              res(0)<=x"80";            -- nothing pending: invalid
              nr<=1;
            END IF;
            phase<=sRESULT;

          WHEN "01110" =>               -- DUMPREG
            res(0)<=pcn(0);
            res(1)<=pcn(1);
            res(2)<=pcn(2);
            res(3)<=pcn(3);
            res(4)<=spec1;
            res(5)<=spec2;
            res(6)<=x"00";
            res(7)<=lock & '0' & perp(5 DOWNTO 0);
            res(8)<=conf2;
            res(9)<=conf3;
            nr<=10;
            phase<=sRESULT;

          WHEN "10000" =>               -- VERSION: 82077AA
            res(0)<=x"90";
            nr<=1;
            phase<=sRESULT;

          WHEN "10010" =>               -- PERPENDICULAR MODE
            perp<=p_v(0);

          WHEN "10011" =>               -- CONFIGURE
            conf2<=p_v(1);
            conf3<=p_v(2);

          WHEN "10100" =>               -- LOCK
            lock<=c_v(7);
            res(0)<="000" & c_v(7) & "0000";
            nr<=1;
            phase<=sRESULT;

          WHEN "00010" | "00101" | "00110" | "01001" | "01100" | "01010" |
               "01101" | "10001" | "10110" | "11001" | "11101" =>
            -- Transfers, READ ID, FORMAT: abnormal termination, missing
            -- address mark
            res(0)<=x"40" OR (p_v(0) AND x"07");
            res(1)<=x"01";
            res(2)<=x"00";
            IF c_v(4 DOWNTO 0)="01010" OR c_v(4 DOWNTO 0)="01101" THEN
              res(3)<=pcn(ds_v);
              res(4)<="0000000" & p_v(0)(2);
              res(5)<=x"01";
              res(6)<=p_v(1);
            ELSE
              res(3)<=p_v(1);
              res(4)<=p_v(2);
              res(5)<=p_v(3);
              res(6)<=p_v(4);
            END IF;
            nr<=7;
            xfer_int<='1';
            phase<=sRESULT;

          WHEN OTHERS =>                -- invalid command
            res(0)<=x"80";
            nr<=1;
            phase<=sRESULT;
        END CASE;
      END IF;

      IF rst_v THEN
        phase<=sCMD;
        seek_int<='0';
        xfer_int<='0';
        IF lock='0' THEN                -- CONFIGURE defaults, unless LOCKed
          conf2<=x"00";
          conf3<=x"00";
        END IF;
      END IF;

      IF reset_n='0' THEN
        phase<=sCMD;
        dor<=x"00";                     -- held in reset until the OS
        tdr<=x"00";                     -- or PROM releases it
        cmd<=x"00";
        np<=0;
        ip<=0;
        nr<=0;
        ir<=0;
        pcn<=(OTHERS => x"00");
        spec1<=x"00";
        spec2<=x"00";
        perp<=x"00";
        conf2<=x"00";
        conf3<=x"00";
        lock<='0';
        rst_int<=0;
        seek_int<='0';
        xfer_int<='0';
      END IF;
    END IF;
  END PROCESS Sync;

  int<=dor(3) AND dor(2) AND
        (to_std_logic(rst_int/=0) OR seek_int OR xfer_int);

  r.ack<=sel;
  r.dr<=dr & dr & dr & dr;

END ARCHITECTURE rtl;
