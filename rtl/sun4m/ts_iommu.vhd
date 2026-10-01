--------------------------------------------------------------------------------
-- TEM : TS
-- IOMMU
--------------------------------------------------------------------------------
-- DO 9/2010
--------------------------------------------------------------------------------
-- IOMMU Sun4m
--------------------------------------------------------------------------------
 
--##############################################################################
--## This source file is copyrighted. Read the "lic.txt" file before use.     ##
--## Experimental version. No warranty of any sort. All rights reserved.      ##
--##############################################################################

-- 0000 : IOMMU Control Register
--        0 : ME : Enable
--        1 : DE : Diagnostic Enable
--      4:2 : RANGE
--    31:24 : IMPL / VER

-- 0004 : IOMMU Base Address Register
--    31:10 : IBA[35:14]
  
-- 0014 : IOMMU Flush all TLBs

-- 0018 : IOMMU Address Flush Register

-- 0100 : IOMMU Tags diagnostic access

-- 0200 : IOMMU Translation cache diagnostic access

-- 1000 : M-to-S Asynchronous Error Fault Status

-- 1004 : M-to-S Asynchronous Error Fault Address

-- 1008 : Arbiter Enable

-- 10ss : Sbus Slot N Configuration Register

-- 2000 : MID Register

-- 3018 : Virtual address Mask Register / Chip Mask ID

-- Le pipe W a 1 cycle de retard
-- Le pipe R est combinatoire.

-- PTE IOMMU
-- 31:8 : PPN : Page [35:12]
--    7 : Cacheable --> Ignoré. Pas de cache supplémentaire.
--    2 : Writeable --> Ignoré. Signalement d'erreurs ?
--    1 : Valid     --> Ignoré. Signalement d'erreurs ?
--    0 : Write as Zero --> Bof

LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;

LIBRARY work;
USE work.base_pack.ALL;
USE work.plomb_pack.ALL;
USE work.ts_pack.ALL;

ENTITY ts_iommu IS
  GENERIC (
    IOMMU_VER : uv8;
    SS20      : boolean := false);
  PORT (
    sel  : IN  std_logic;
    w    : IN  type_pvc_w;
    r    : OUT type_pvc_r;

    piw  : IN  type_plomb_w; -- Plomb, Côte SCSI/Ethernet, écriture/addresses
    pir  : OUT type_plomb_r; -- Plomb, Côte SCSI/Ethernet, lectures
    pow  : OUT type_plomb_w; -- Plomb, Côte Mémoire, écriture/addresses
    por  : IN  type_plomb_r; -- Plomb, Côte Mémoire, lectures

    mask_rev : IN uv8;
    -- MBus (SS20): the MSI arbiter enable for CPUs 3:1 (bit 0 reads 1),
    -- and the index of the CPU that owns the bus (the MID register)
    arb_cpu  : OUT uv4;
    bus_cpu  : IN  uv2 := "00";
    -- Global
    clk      : IN std_logic;
    reset_n  : IN std_logic
    );
END ENTITY ts_iommu;

--##############################################################################

ARCHITECTURE rtl OF ts_iommu IS
  -- Registres
  SIGNAL me : std_logic;                -- IOMMU Enable
  SIGNAL de : std_logic;                -- IOMMU Diagnostic Enable
  SIGNAL rag : unsigned(2 DOWNTO 0);    -- IOMMU Range
  SIGNAL iba : unsigned(35 DOWNTO 14);  -- IOMMU Base address
  SIGNAL arb_en  : unsigned(3 DOWNTO 1); -- SS20 arbiter: MBus masters 9-B
  SIGNAL arb_sbus : unsigned(4 DOWNTO 0); -- SS20 arbiter: SBus slots 0-3, F
  SIGNAL arb_sbw : std_logic;            -- SS20 arbiter: S-to-M async writes
  SIGNAL sbae    : unsigned(5 DOWNTO 0); -- SS5 MID register: SBus arb enables
  SIGNAL dr : uv32;
  SIGNAL rsel : std_logic;
  
  --------------------------------------
  CONSTANT ZERO : uv32 := x"00000000";

  TYPE type_iotlb IS RECORD
    ppn : unsigned(35 DOWNTO 12); -- PTE[31:8] Physical Page Number
    c   : std_logic;              -- PTE[7] : Cacheable
    w   : std_logic;              -- PTE[2] : Writeable
    v   : std_logic;              -- Valid PTE
    tag : unsigned(30 DOWNTO 12); -- TLB tag
  END RECORD;
  
  TYPE arr_iotlb IS ARRAY(natural RANGE <>) OF type_iotlb;
  
  CONSTANT N_IOTLB : natural := 2; -- Nombre de TLBs
  
  SIGNAL iotlb : arr_iotlb(0 TO N_IOTLB-1);
  SIGNAL iotlb_cpt : natural RANGE 0 TO N_IOTLB-1;  -- Compteur de remplacement
  SIGNAL iotlb_maj_c : std_logic;
  SIGNAL iotlb_c : type_iotlb;
  
  SIGNAL flush,flushpend : std_logic;

  SIGNAL paw,paw_c : type_plomb_w;
  SIGNAL par       : type_plomb_r;
  
  SIGNAL pirr_ack_c : std_logic;
  
  SIGNAL ct : natural RANGE 0 TO 7;
  
  TYPE enum_etat IS (sTRANS,sPRE,sPURGE,sTLBA,sTLBD,sPOST);
  SIGNAL etat_c,etat : enum_etat;
  
  --------------------------------------
  -- Calcul adresses PTE
  FUNCTION pteadrs (
    CONSTANT va  : IN uv32;
    CONSTANT iba : IN unsigned(35 DOWNTO 14);
    CONSTANT rag : unsigned(2 DOWNTO 0))
    RETURN unsigned IS
    VARIABLE v : unsigned(35 DOWNTO 0);
  BEGIN
    CASE rag IS
      WHEN "000"  => v:=iba(35 DOWNTO 14) & va(23 DOWNTO 12) & "00";
      WHEN "001"  => v:=iba(35 DOWNTO 15) & va(24 DOWNTO 12) & "00";
      WHEN "010"  => v:=iba(35 DOWNTO 16) & va(25 DOWNTO 12) & "00";
      WHEN "011"  => v:=iba(35 DOWNTO 17) & va(26 DOWNTO 12) & "00";
      WHEN "100"  => v:=iba(35 DOWNTO 18) & va(27 DOWNTO 12) & "00";
      WHEN "101"  => v:=iba(35 DOWNTO 19) & va(28 DOWNTO 12) & "00";
      WHEN "110"  => v:=iba(35 DOWNTO 20) & va(29 DOWNTO 12) & "00";
      WHEN OTHERS => v:=iba(35 DOWNTO 21) & va(30 DOWNTO 12) & "00";
    END CASE;
    RETURN v;
  END FUNCTION pteadrs;
  
  --------------------------------------
  -- Calcul TLB
  PROCEDURE tlbcalc (
    VARIABLE hit   : OUT std_logic;
    VARIABLE pa    : OUT unsigned(35 DOWNTO 0);
    CONSTANT me    : IN  std_logic;
    CONSTANT iotlb : IN  arr_iotlb(0 TO N_IOTLB-1);
    CONSTANT va    : IN  uv32) IS
  BEGIN
    IF me='1' AND va(31)='1' THEN
      -- IOMMU Enable
      hit:='0';
      FOR I IN 0 TO N_IOTLB-1 LOOP
        IF iotlb(I).v='1' AND va(30 DOWNTO 12)=iotlb(I).tag THEN
          hit:='1';
          pa:=iotlb(I).ppn & va(11 DOWNTO 0);
        END IF;
      END LOOP;
    ELSE
      -- IOMMU désactivé ou accès direct
      -- <AVOIR> Accès direct. Pour quels périphériques ???
      hit:='1';
      pa:=x"0" & va;
    END IF;
  END tlbcalc;

  --------------------------------------
BEGIN

  rsel<=w.req AND sel;  
  
  -- Accès registres
  Sync_Regs: PROCESS (clk)    
  BEGIN
    IF rising_edge(clk) THEN
      dr<=x"00000000"; -- Tous les autres registres.
      
      -- 0000 : IOMMU Control Register
      IF rsel='1' AND w.a(13 DOWNTO 2)="000000000000" THEN
        IF w.be="1111" AND w.wr='1' THEN
          me<=w.dw(0);
          de<=w.dw(1);
          rag<=w.dw(4 DOWNTO 2);
        END IF;
        IF SS20 THEN
          dr<=IOMMU_VER & ZERO(23 DOWNTO 5) & rag & de & me;
        ELSE
          -- microSPARC-II: DE (bit 1) and bits 23:5 are not implemented
          -- and read 0 [MS2 5.7.1]; the SS5 POST checks it (IOM-3)
          dr<=IOMMU_VER & ZERO(23 DOWNTO 5) & rag & '0' & me;
        END IF;
      END IF;

      -- 0004 : IOMMU Base Address Register
      IF rsel='1' AND w.a(13 DOWNTO 2)="000000000001" THEN
        IF w.be="1111" AND w.wr='1' THEN
          iba<=w.dw(31 DOWNTO 10);
        END IF;
        IF SS20 THEN
          dr<=iba & ZERO(9 DOWNTO 0);
        ELSE
          -- microSPARC-II: IBA[30:14] in bits 26:10; 31:27 read 0 (IOM-3)
          dr<="00000" & iba(30 DOWNTO 14) & ZERO(9 DOWNTO 0);
        END IF;
      END IF;

      flush<='0';
      -- 0014 : IOMMU Flush all TLBs
      IF rsel='1' AND w.a(13 DOWNTO 2)="000000000101" THEN
        IF w.be="1111" AND w.wr='1' THEN
          -- On purge tout
          flush<='1';
        END IF;
      END IF;
      
      -- 0018 : IOMMU Address Flush Register
      IF rsel='1' AND w.a(13 DOWNTO 2)="000000000110" THEN
        IF w.be="1111" AND w.wr='1' THEN
          -- On purge tout, bêtement. <AFAIRE> Améliorer conditions de flush
          flush<='1';
        END IF;
      END IF;
      
      -- 0100 : IOMMU Tags diagnostic access
      
      -- 0200 : IOMMU Translation cache diagonstic access

      -- 3018 : Virtual address Mask Register / Chip Mask ID
      IF rsel='1' AND w.a(13 DOWNTO 2)="110000000110" THEN
        dr<=mask_rev & ZERO(23 DOWNTO 0);
      END IF;

      -- 1008 : SS20 MSI Arbiter Enable Register [S4M 5.1.2]. Bit 0 (MBus
      -- master 8) reads 1; bits 3:1 enable masters 9-B, 20:16 the SBus
      -- slots and on-board devices, 31 SBW. The OBP parks and releases
      -- CPUs with bits 3:1 (ts_core withholds a disabled CPU's requests).
      IF SS20 AND rsel='1' AND w.a(13 DOWNTO 2)="010000000010" THEN
        IF w.be="1111" AND w.wr='1' THEN
          arb_en<=w.dw(3 DOWNTO 1);
          arb_sbus<=w.dw(20 DOWNTO 16);
          arb_sbw<=w.dw(31);
        END IF;
        dr<=arb_sbw & ZERO(30 DOWNTO 21) & arb_sbus & ZERO(15 DOWNTO 4) &
             arb_en & '1';
      END IF;

      -- 2000 : MID Register. SS20 MSI [S4M 5.4.3]: the MBus ID of the
      -- master doing the access, 8 + the CPU index. SS5 [MS2 5.7.10]:
      -- the constant 8, and SBAE[5:0] in bits 21:16.
      IF rsel='1' AND w.a(13 DOWNTO 2)="100000000000" THEN
        IF SS20 THEN
          dr<=ZERO(31 DOWNTO 4) & "10" & bus_cpu;
        ELSE
          IF w.be="1111" AND w.wr='1' THEN
            sbae<=w.dw(21 DOWNTO 16);
          END IF;
          dr<=ZERO(31 DOWNTO 22) & sbae & ZERO(15 DOWNTO 4) & x"8";
        END IF;
      END IF;

      IF reset_n='0' THEN
        me<='0';
        de<='0';
        rag<="000";
        flush<='0';
        iba<=(OTHERS => '0');
        -- The MSI enables only CPUs 8 and 9 at power-on; all of them here,
        -- because OpenBIOS starts every CPU from reset and never writes
        -- the arbiter (the Sun OBP enables 9-B in its first instructions).
        arb_en<="111";
        arb_sbus<="00000";
        arb_sbw<='0';
        sbae<="000000";
      END IF;

    END IF;
  END PROCESS Sync_Regs;

  -- Relectures registres
  R_Gen:PROCESS(dr,sel)
  BEGIN
    r.ack<=sel;
    r.dr<=dr;
  END PROCESS R_Gen;

  arb_cpu<=arb_en & '1' WHEN SS20 ELSE "1111";
  
  ------------------------------------------------------------------------------
  -- Manipulations Pipe
  Comb_Pipo:PROCESS(etat,me,iba,rag,iotlb,piw,par,ct)
    VARIABLE hit_v : std_logic;
    VARIABLE pa_v  : unsigned(35 DOWNTO 0);
  BEGIN
    etat_c<=etat;
    paw_c<=piw;
    tlbcalc (hit_v,pa_v,me,iotlb,piw.a);
    pa_v(35 DOWNTO 30):="000000"; -- RAM area < 1GB
    paw_c.a<=pa_v(31 DOWNTO 0);
    paw_c.ah<=pa_v(35 DOWNTO 32);
    iotlb_maj_c<='0';
    
    CASE etat IS
      WHEN sTRANS =>
        IF hit_v='1' THEN
          -- TLB HIT. Translation d'adresses.
          pirr_ack_c<=par.ack;
        ELSIF piw.req='1' THEN  -- Si nouvel accès
          etat_c<=sPRE;
          paw_c.req<='0';
          pirr_ack_c<='0';
        ELSE
          pirr_ack_c<='0';
        END IF;

      WHEN sPRE =>
        etat_c<=sPURGE;
        paw_c.req<='0';
        pirr_ack_c<='0';
        
      WHEN sPURGE =>
        IF ct=0 THEN
          etat_c<=sTLBA;
        END IF;
        paw_c.req<='0';
        pirr_ack_c<='0';
        
      WHEN sTLBA =>
        pa_v:=pteadrs (piw.a,iba,rag);
        paw_c.a <=pa_v(31 DOWNTO 0);
        paw_c.ah<=pa_v(35 DOWNTO 32);
        paw_c.be<="1111";
        paw_c.mode<=PB_MODE_RD;
        paw_c.burst<=PB_SINGLE;
        paw_c.cache<='1';
        paw_c.lock<='0';
        paw_c.req<='1';
        paw_c.dack<='1';
        pirr_ack_c<='0';
        IF par.ack='1' THEN
          etat_c<=sTLBD;
        END IF;
        
      WHEN sTLBD =>
        paw_c.req<='0';
        paw_c.dack<='1';
        pirr_ack_c<='0';
        IF par.dreq='1' THEN
          iotlb_maj_c<='1';
          etat_c<=sPOST;
        END IF;

      WHEN sPOST =>
        paw_c.req<='0';
        paw_c.dack<='1';
        pirr_ack_c<='0';
        etat_c<=sTRANS;
    END CASE;
    
    -- Mise à jour du TLB d'après les données lues.
    iotlb_c.ppn<=par.d(31 DOWNTO 8);
    iotlb_c.c  <=par.d(7);
    iotlb_c.w  <=par.d(2);
    iotlb_c.v  <='1';
    iotlb_c.tag<=piw.a(30 DOWNTO 12);
  END PROCESS Comb_Pipo;
  
  ------------------------------------------------------------------------------
  Sync_Pipo:PROCESS(clk)
    VARIABLE trouve : std_logic;
    VARIABLE push,pop : std_logic;
  BEGIN
    IF rising_edge(clk) THEN
      --------------------------------------
      -- Mise à jour du TLB
      IF iotlb_maj_c='1' THEN
        trouve:='0';
        FOR I IN 0 TO N_IOTLB-1 LOOP
          IF iotlb(I).v='0' THEN
            trouve:='1';
            iotlb(I)<=iotlb_c;
          END IF;
        END LOOP;
        IF trouve='0' THEN
          iotlb(iotlb_cpt)<=iotlb_c;
          IF iotlb_cpt/=N_IOTLB-1 THEN
            iotlb_cpt<=iotlb_cpt+1;
          ELSE
            iotlb_cpt<=0;
          END IF;
        END IF;
      END IF;
      
      -- Purge de tous les TLB
      IF flush='1' THEN
        flushpend<='1';
      END IF;
      IF flushpend='1' AND piw.req='0' THEN
        -- <AFAIRE> flushs autorisé entre bursts
        flushpend<='0';
        FOR I IN 0 TO N_IOTLB-1 LOOP
          iotlb(I).v<='0';
        END LOOP;        
      END IF;
      
      --------------------------------------
      -- Compteur de transactions
      push:=paw_c.req AND par.ack AND paw_c.mode(1);
      pop :=par.dreq AND paw_c.dack;
      IF push='1' AND pop='0' THEN
        ct<=ct+1;
      ELSIF pop='1' AND push='0' THEN
        ct<=ct-1;
      END IF;
      --------------------------------------
      etat<=etat_c;

      --------------------------------------
      IF reset_n='0' THEN
        FOR I IN 0 TO N_IOTLB-1 LOOP
          iotlb(I).v<='0';
        END LOOP;
        etat<=sTRANS;
        ct<=0;
        iotlb_cpt<=0;
        flushpend<='0';
      END IF;

    END IF;
  END PROCESS Sync_Pipo;
  
  ------------------------------------------------------------------------------
  Combino: PROCESS (etat,paw_c,par,pirr_ack_c)
  BEGIN
    paw<=paw_c;

    pir<=par;
    pir.ack<=pirr_ack_c;
    IF etat=sTRANS OR etat=sPRE OR etat=sPURGE THEN
      pir.dreq<=par.dreq;
    ELSE
      pir.dreq<='0';
    END IF;
    
  END PROCESS Combino;

  ------------------------------------------------------------------------------
  i_plomb_fifo: ENTITY work.plomb_fifo
    GENERIC MAP (
      PROF_W => 2,
      PROF_R => 2,
      MODE_W => SYNC,
      MODE_R => DIRECT)
    PORT MAP (
      i_w     => paw,
      i_r     => par,
      o_w     => pow,
      o_r     => por,
      clk     => clk,
      reset_n => reset_n);
  
END ARCHITECTURE rtl;
