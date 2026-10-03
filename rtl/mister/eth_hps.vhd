--------------------------------------------------------------------------------
-- The LANCE's MAC, bridged to Main through a frame mailbox in DDR3
--------------------------------------------------------------------------------
-- The LANCE (ts_lance) keeps its descriptor rings and its DMA through the
-- IOMMU; this is the "wire" behind it. Frames go to Main (support/sun,
-- sun_enet.cpp) and come back from it through a mailbox in the DDR3 at
-- ARM physical address 0x1FF00000, outside the core's memory (the A2065 and
-- the NeXT core use the same window; one core runs at a time). Main moves
-- the frames to a raw socket or a tap interface.
--
-- The mailbox, 64-bit little-endian words (frame byte i is byte lane i mod 8
-- of word 1 + i / 8 of its slot):
--   +0x0000 MAGIC   "SSETH001", written last at start-up
--   +0x0008 GEN     a new value at every start-up (Main resynchronises)
--   +0x0010 TX_WPTR ours: frames posted
--   +0x0018 TX_RPTR Main's: frames taken
--   +0x0020 RX_WPTR Main's: frames posted
--   +0x0028 RX_RPTR ours: frames taken
--   +0x0030 MAC     ours: bit 63 valid, 47:40 the first byte ... 7:0 the last
--   +0x1000 TX ring, RING slots of 2048 bytes: header (10:0 length), frame
--   +0x5000 RX ring, RING slots of 2048 bytes: header (10:0 length with
--           the 4-byte FCS Main appends, 21:16 the LADRF index of the
--           destination address, which Main computes), frame
--
-- Transmit: the LANCE pushes the frame's 16-bit words (the first with stp);
-- 'busy' from the first word until the frame is in the mailbox stops it from
-- starting another. A frame is complete when its bytes reach 'len' with enp.
-- While the TX ring is full the LANCE waits (busy), as on a busy wire; the
-- frame is dropped when Main has taken nothing for TXWAIT cycles (it is
-- not running), when the network is off, or when it is longer than a slot.
-- Receive: with the buffer empty, RX_WPTR is polled every POLL cycles. A
-- frame is read into the buffer, and kept if its destination is ours: the
-- PADR, broadcast, a multicast group set in the LADRF, or anything in
-- promiscuous mode. The whole frame is then offered to the LANCE: fifordy
-- while words remain; deof with the last. No eof pulse: the LANCE latches
-- eof until it pops the last word, and a frame it never takes (receiver
-- off) is dropped after STALE cycles, or at the LANCE's INIT.
-- Loopback (MODE LOOP, which the Sun PROM's le driver tests at open): the
-- transmitted frame comes back as a received one at once, through the
-- filter, with the 4 FCS bytes counted; nothing goes to the mailbox, and
-- the network is not polled meanwhile.
--------------------------------------------------------------------------------

LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;

LIBRARY work;
USE work.base_pack.ALL;
USE work.ts_pack.ALL;

ENTITY eth_hps IS
  GENERIC (
    SYSFREQ : natural := 50_000_000;
    SIMU    : natural := 0);   -- 1: short timers (sim/)
  PORT (
    -- The LANCE
    mac_emi_w : IN  type_mac_emi_w;
    mac_emi_r : OUT type_mac_emi_r;
    mac_rec_w : IN  type_mac_rec_w;
    mac_rec_r : OUT type_mac_rec_r;

    ena       : IN  std_logic;      -- the OSD's Network is not Off

    -- Avalon-MM master on the DDR3: single beats, one at a time
    avl_waitrequest   : IN  std_logic;
    avl_address       : OUT std_logic_vector(28 DOWNTO 0);
    avl_read          : OUT std_logic;
    avl_write         : OUT std_logic;
    avl_writedata     : OUT std_logic_vector(63 DOWNTO 0);
    avl_byteenable    : OUT std_logic_vector(7 DOWNTO 0);
    avl_burstcount    : OUT std_logic_vector(7 DOWNTO 0);
    avl_readdata      : IN  std_logic_vector(63 DOWNTO 0);
    avl_readdatavalid : IN  std_logic;

    clk     : IN std_logic;
    reset_n : IN std_logic);
END ENTITY eth_hps;

--##############################################################################

ARCHITECTURE rtl OF eth_hps IS

  -- The mailbox, in 64-bit words
  CONSTANT BASE    : unsigned(28 DOWNTO 0) := to_unsigned(16#1FF00000# / 8, 29);
  CONSTANT W_MAGIC : natural := 0;
  CONSTANT W_GEN   : natural := 1;
  CONSTANT W_TXW   : natural := 2;
  CONSTANT W_TXR   : natural := 3;
  CONSTANT W_RXW   : natural := 4;
  CONSTANT W_RXR   : natural := 5;
  CONSTANT W_MAC   : natural := 6;
  CONSTANT W_TX    : natural := 16#1000# / 8;
  CONSTANT W_RX    : natural := 16#5000# / 8;
  CONSTANT MAGIC   : unsigned(63 DOWNTO 0) := x"5353455448303031"; -- SSETH001
  CONSTANT RING    : natural := 8;
  CONSTANT MAXLEN  : natural := 2048 - 8;   -- a slot's frame bytes

  CONSTANT POLL    : natural := mux(SIMU=1, 200, 1024);
  CONSTANT STALE   : natural := mux(SIMU=1, 20_000, SYSFREQ / 5);
  CONSTANT TXWAIT  : natural := mux(SIMU=1, 20_000, SYSFREQ / 20);

  -- The frame buffers: 256 words of 64 bits each (2 KB)
  TYPE arr_buf IS ARRAY (0 TO 255) OF unsigned(63 DOWNTO 0);
  SIGNAL txbuf, rxbuf : arr_buf;
  SIGNAL txbuf_q, rxbuf_q : unsigned(63 DOWNTO 0);
  SIGNAL txbuf_ra, txbuf_wa, rxbuf_ra, rxbuf_wa : unsigned(7 DOWNTO 0);
  SIGNAL txbuf_wr, rxbuf_wr : std_logic;
  SIGNAL txbuf_d, rxbuf_d : unsigned(63 DOWNTO 0);

  -- Transmit: words from the LANCE
  SIGNAL tx_acc   : unsigned(63 DOWNTO 0);  -- the word being filled
  SIGNAL tx_cnt   : unsigned(10 DOWNTO 0);  -- 16-bit words pushed
  SIGNAL tx_over  : std_logic;              -- longer than a slot
  SIGNAL tx_busy  : std_logic;              -- a frame is in progress
  SIGNAL tx_done  : std_logic;              -- complete, to be posted
  SIGNAL tx_len   : unsigned(11 DOWNTO 0);
  SIGNAL tx_flush : std_logic;              -- the last partial word
  SIGNAL tx_posted : std_logic;             -- the FSM has finished with it

  -- Receive: words to the LANCE
  SIGNAL rx_full  : std_logic;              -- a frame is offered
  SIGNAL rx_head  : unsigned(9 DOWNTO 0);   -- the next 16-bit word
  SIGNAL rx_next  : unsigned(9 DOWNTO 0);   -- rx_head after this cycle
  SIGNAL rx_last  : unsigned(9 DOWNTO 0);
  SIGNAL rx_len   : unsigned(11 DOWNTO 0);
  SIGNAL rx_sel   : unsigned(1 DOWNTO 0);   -- rxbuf_q's 16-bit lane
  SIGNAL rx_popped: std_logic;
  SIGNAL rx_stale : natural RANGE 0 TO STALE;
  SIGNAL rx_load  : std_logic;              -- the FSM offers a frame
  SIGNAL rx_ldlen : unsigned(11 DOWNTO 0);

  -- The mailbox FSM
  TYPE enum_state IS (sINIT, sIDLE,
                      sTX_RPTR, sTX_FETCH, sTX_DATA, sTX_WPTR,
                      sRX_WPTR, sRX_HDR, sRX_DATA, sRX_RPTR, sRX_OFFER,
                      sLOOP_RD, sLOOP_WR, sMAC);
  SIGNAL state    : enum_state;
  SIGNAL step     : unsigned(3 DOWNTO 0);
  SIGNAL acc_rd, acc_wr : std_logic;
  SIGNAL acc_wait : std_logic;              -- a read waits for its data
  SIGNAL acc_a    : unsigned(28 DOWNTO 0);
  SIGNAL acc_d    : unsigned(63 DOWNTO 0);
  SIGNAL gen      : unsigned(31 DOWNTO 0);
  SIGNAL tx_wptr, rx_rptr : unsigned(31 DOWNTO 0);
  SIGNAL k, nwords : unsigned(8 DOWNTO 0);
  SIGNAL poll_cpt : natural RANGE 0 TO POLL;
  SIGNAL txw_cpt  : natural RANGE 0 TO TXWAIT;  -- the frame has waited
  SIGNAL tx_retry : natural RANGE 0 TO 63;      -- the next TX_RPTR read
  SIGNAL mac_pub  : unsigned(47 DOWNTO 0);
  SIGNAL mac_ok   : std_logic;
  SIGNAL rx_hash  : unsigned(5 DOWNTO 0);
  SIGNAL rx_keep  : std_logic;
  SIGNAL rx_flen  : unsigned(11 DOWNTO 0);

  -- A 16-bit LANCE word (first byte in 15:8) in byte lanes 2l, 2l+1
  FUNCTION swap16 (CONSTANT v : unsigned(15 DOWNTO 0)) RETURN unsigned IS
  BEGIN
    RETURN v(7 DOWNTO 0) & v(15 DOWNTO 8);
  END FUNCTION;

BEGIN

  ------------------------------------------------------------------------------
  -- The buffers
  Bufs: PROCESS (clk)
  BEGIN
    IF rising_edge(clk) THEN
      IF txbuf_wr = '1' THEN
        txbuf(to_integer(txbuf_wa)) <= txbuf_d;
      END IF;
      txbuf_q <= txbuf(to_integer(txbuf_ra));
      IF rxbuf_wr = '1' THEN
        rxbuf(to_integer(rxbuf_wa)) <= rxbuf_d;
      END IF;
      rxbuf_q <= rxbuf(to_integer(rxbuf_ra));
    END IF;
  END PROCESS Bufs;

  ------------------------------------------------------------------------------
  -- Transmit: collect the LANCE's words into txbuf
  TxIn: PROCESS (clk)
    VARIABLE cnt_v : unsigned(10 DOWNTO 0);
    VARIABLE acc_v : unsigned(63 DOWNTO 0);
  BEGIN
    IF rising_edge(clk) THEN
      tx_flush <= '0';
      txbuf_wr <= '0';
      IF mac_emi_w.push = '1' AND tx_done = '0' THEN
        IF mac_emi_w.stp = '1' THEN
          cnt_v := (OTHERS => '0');
          tx_over <= '0';
          acc_v := (OTHERS => '0');
        ELSE
          cnt_v := tx_cnt;
          acc_v := tx_acc;
        END IF;
        tx_busy <= '1';
        CASE cnt_v(1 DOWNTO 0) IS
          WHEN "00"   => acc_v(15 DOWNTO 0)  := swap16(mac_emi_w.d);
          WHEN "01"   => acc_v(31 DOWNTO 16) := swap16(mac_emi_w.d);
          WHEN "10"   => acc_v(47 DOWNTO 32) := swap16(mac_emi_w.d);
          WHEN OTHERS => acc_v(63 DOWNTO 48) := swap16(mac_emi_w.d);
        END CASE;
        IF cnt_v(1 DOWNTO 0) = "11" THEN
          IF cnt_v(10 DOWNTO 2) < MAXLEN / 8 THEN
            txbuf_wr <= '1';
            txbuf_wa <= cnt_v(9 DOWNTO 2);
            txbuf_d  <= acc_v;
          ELSE
            tx_over <= '1';
          END IF;
          acc_v := (OTHERS => '0');
        END IF;
        tx_acc <= acc_v;
        tx_cnt <= cnt_v + 1;
      END IF;

      -- Complete: its bytes reached the length of its last buffer
      IF tx_busy = '1' AND tx_done = '0' AND mac_emi_w.push = '0' AND
         mac_emi_w.enp = '1' AND (tx_cnt & '0') >= mac_emi_w.len AND
         mac_emi_w.len /= 0 THEN
        tx_done <= '1';
        tx_flush <= '1';
        tx_len <= mac_emi_w.len;
        IF mac_emi_w.crcgen = '0' THEN    -- the FCS came with the frame
          tx_len <= mac_emi_w.len - 4;
        END IF;
      END IF;
      IF tx_flush = '1' AND tx_cnt(1 DOWNTO 0) /= "00" THEN
        IF tx_cnt(10 DOWNTO 2) < MAXLEN / 8 THEN
          txbuf_wr <= '1';
          txbuf_wa <= tx_cnt(9 DOWNTO 2);
          txbuf_d  <= tx_acc;
        END IF;
      END IF;

      IF tx_posted = '1' OR mac_emi_w.clr = '1' THEN
        tx_busy <= '0';
        tx_done <= '0';
      END IF;
      IF reset_n = '0' THEN
        tx_busy <= '0';
        tx_done <= '0';
        tx_cnt  <= (OTHERS => '0');
        tx_over <= '0';
      END IF;
    END IF;
  END PROCESS TxIn;

  mac_emi_r.fifordy <= '1';
  mac_emi_r.busy    <= tx_busy;

  ------------------------------------------------------------------------------
  -- Receive: offer the frame in rxbuf to the LANCE
  -- rxbuf_ra follows the head, one ahead on a pop (as the FIFO of the RMII
  -- MAC does), so rxbuf_q is always the head's word.
  rx_next  <= rx_head + 1 WHEN rx_full = '1' AND mac_rec_w.pop = '1' ELSE
              rx_head;
  rxbuf_ra <= rx_next(9 DOWNTO 2);

  RxOut: PROCESS (clk)
  BEGIN
    IF rising_edge(clk) THEN
      IF rx_full = '1' AND mac_rec_w.pop = '1' THEN
        rx_popped <= '1';
        IF rx_head = rx_last THEN
          rx_full <= '0';
        END IF;
      END IF;
      rx_head <= rx_next;
      rx_sel  <= rx_next(1 DOWNTO 0);

      IF rx_full = '1' AND rx_popped = '0' THEN
        IF rx_stale = STALE THEN
          rx_full <= '0';                 -- the receiver is off
        ELSE
          rx_stale <= rx_stale + 1;
        END IF;
      END IF;

      IF rx_load = '1' THEN
        rx_full   <= '1';
        rx_popped <= '0';
        rx_stale  <= 0;
        rx_head   <= (OTHERS => '0');
        rx_sel    <= "00";
        rx_len    <= rx_ldlen;
        rx_last   <= resize((rx_ldlen + 1) / 2 - 1, 10);
      END IF;
      IF mac_rec_w.clr = '1' OR reset_n = '0' THEN
        rx_full <= '0';
      END IF;
    END IF;
  END PROCESS RxOut;

  WITH rx_sel SELECT mac_rec_r.d <=
    swap16(rxbuf_q(15 DOWNTO 0))  WHEN "00",
    swap16(rxbuf_q(31 DOWNTO 16)) WHEN "01",
    swap16(rxbuf_q(47 DOWNTO 32)) WHEN "10",
    swap16(rxbuf_q(63 DOWNTO 48)) WHEN OTHERS;
  mac_rec_r.deof    <= rx_full AND to_std_logic(rx_head = rx_last);
  mac_rec_r.fifordy <= rx_full;
  mac_rec_r.len     <= rx_len;
  mac_rec_r.crcok   <= '1';
  mac_rec_r.eof     <= '0';

  ------------------------------------------------------------------------------
  -- The mailbox
  avl_address    <= std_logic_vector(acc_a);
  avl_read       <= acc_rd;
  avl_write      <= acc_wr;
  avl_writedata  <= std_logic_vector(acc_d);
  avl_byteenable <= x"FF";
  avl_burstcount <= x"01";

  Mbox: PROCESS (clk)
    VARIABLE dst_v : unsigned(47 DOWNTO 0);
    VARIABLE q_v   : unsigned(63 DOWNTO 0);
    VARIABLE bc_v  : boolean;
  BEGIN
    IF rising_edge(clk) THEN
      gen <= gen + 1;
      IF tx_done = '1' AND tx_posted = '0' THEN
        IF txw_cpt < TXWAIT THEN
          txw_cpt <= txw_cpt + 1;
        END IF;
      ELSE
        txw_cpt <= 0;
      END IF;
      tx_posted <= '0';
      rx_load   <= '0';
      rxbuf_wr  <= '0';

      -- The access in flight: the command until accepted, then a read's data
      IF (acc_rd = '1' OR acc_wr = '1') AND avl_waitrequest = '0' THEN
        acc_rd <= '0';
        acc_wr <= '0';
      END IF;
      IF acc_wait = '1' AND avl_readdatavalid = '1' THEN
        acc_wait <= '0';
      END IF;
      q_v := unsigned(avl_readdata);

      IF acc_rd = '0' AND acc_wr = '0' AND
         (acc_wait = '0' OR avl_readdatavalid = '1') THEN
        CASE state IS
          ------------------------------------------
          WHEN sINIT =>
            -- Zero everything, then the magic
            acc_wr <= '1';
            acc_d  <= (OTHERS => '0');
            acc_a  <= BASE + step;
            IF step = W_GEN THEN
              acc_d <= x"00000000" & gen;
            END IF;
            IF step = 7 THEN
              acc_a <= BASE + W_MAGIC;
              acc_d <= MAGIC;
              state <= sIDLE;
            END IF;
            step <= step + 1;
            tx_wptr <= (OTHERS => '0');
            rx_rptr <= (OTHERS => '0');
            mac_ok  <= '0';

          ------------------------------------------
          WHEN sIDLE =>
            IF poll_cpt < POLL THEN
              poll_cpt <= poll_cpt + 1;
            END IF;
            IF tx_retry /= 0 THEN
              tx_retry <= tx_retry - 1;
            END IF;
            IF tx_done = '1' AND tx_posted = '0' AND mac_rec_w.lpbk = '1' THEN
              IF tx_over = '1' OR tx_len < 14 THEN
                tx_posted <= '1';         -- dropped
              ELSIF rx_full = '0' THEN
                k        <= (OTHERS => '0');
                nwords   <= resize((tx_len + 4 + 7) / 8, 9);
                txbuf_ra <= (OTHERS => '0');
                rx_keep  <= '0';
                state    <= sLOOP_RD;
              END IF;                     -- else: once the LANCE took the last
            ELSIF tx_done = '1' AND tx_posted = '0' AND tx_retry = 0 THEN
              IF ena = '1' AND tx_over = '0' AND tx_len >= 14 AND
                 tx_len <= MAXLEN THEN
                acc_rd   <= '1';
                acc_wait <= '1';
                acc_a    <= BASE + W_TXR;
                state    <= sTX_RPTR;
              ELSE
                tx_posted <= '1';         -- dropped
              END IF;
            ELSIF mac_ok = '0' OR mac_pub /= mac_rec_w.padr THEN
              state <= sMAC;
            ELSIF rx_full = '0' AND ena = '1' AND poll_cpt = POLL AND
                  mac_rec_w.lpbk = '0' THEN
              poll_cpt <= 0;
              acc_rd   <= '1';
              acc_wait <= '1';
              acc_a    <= BASE + W_RXW;
              state    <= sRX_WPTR;
            END IF;

          ------------------------------------------
          -- Transmit
          WHEN sTX_RPTR =>
            IF tx_wptr - q_v(31 DOWNTO 0) < RING THEN
              -- the header: the length
              acc_wr <= '1';
              acc_a  <= BASE + W_TX + resize(tx_wptr(2 DOWNTO 0) & x"00", 29);
              acc_d  <= resize(tx_len, 64);
              k      <= (OTHERS => '0');
              nwords <= resize((tx_len + 7) / 8, 9);
              txbuf_ra <= (OTHERS => '0');
              state  <= sTX_FETCH;
            ELSIF txw_cpt = TXWAIT THEN
              tx_posted <= '1';           -- Main takes nothing: dropped
              state <= sIDLE;
            ELSE
              tx_retry <= 63;             -- full: the LANCE waits; again soon
              state <= sIDLE;
            END IF;

          WHEN sTX_FETCH =>
            -- txbuf_q is txbuf(k) from this cycle
            state <= sTX_DATA;

          WHEN sTX_DATA =>
            IF k = nwords THEN
              tx_wptr <= tx_wptr + 1;
              acc_wr <= '1';
              acc_a  <= BASE + W_TXW;
              acc_d  <= resize(tx_wptr + 1, 64);
              state  <= sTX_WPTR;
            ELSE
              acc_wr <= '1';
              acc_a  <= BASE + W_TX + resize(tx_wptr(2 DOWNTO 0) & x"00", 29) +
                        k + 1;
              acc_d  <= txbuf_q;
              k      <= k + 1;
              txbuf_ra <= k(7 DOWNTO 0) + 1;
              state  <= sTX_FETCH;
            END IF;

          WHEN sTX_WPTR =>
            tx_posted <= '1';
            state <= sIDLE;

          ------------------------------------------
          -- Receive
          WHEN sRX_WPTR =>
            IF q_v(31 DOWNTO 0) /= rx_rptr THEN
              acc_rd   <= '1';
              acc_wait <= '1';
              acc_a    <= BASE + W_RX + resize(rx_rptr(2 DOWNTO 0) & x"00", 29);
              state    <= sRX_HDR;
            ELSE
              state <= sIDLE;
            END IF;

          WHEN sRX_HDR =>
            rx_flen <= q_v(11 DOWNTO 0);
            rx_hash <= q_v(21 DOWNTO 16);
            rx_keep <= '0';
            IF q_v(11 DOWNTO 0) >= 18 AND q_v(11 DOWNTO 0) <= MAXLEN THEN
              k      <= (OTHERS => '0');
              nwords <= resize((q_v(11 DOWNTO 0) + 7) / 8, 9);
              acc_rd   <= '1';
              acc_wait <= '1';
              acc_a    <= BASE + W_RX + resize(rx_rptr(2 DOWNTO 0) & x"00", 29) + 1;
              state    <= sRX_DATA;
            ELSE
              state <= sRX_RPTR;          -- a bad length: skipped
            END IF;

          WHEN sRX_DATA =>
            rxbuf_wr <= '1';
            rxbuf_wa <= k(7 DOWNTO 0);
            rxbuf_d  <= q_v;
            IF k = 0 THEN
              -- The destination address: ours?
              FOR i IN 0 TO 5 LOOP
                dst_v(8 * i + 7 DOWNTO 8 * i) := q_v(8 * i + 7 DOWNTO 8 * i);
              END LOOP;
              bc_v := dst_v = x"FFFFFFFFFFFF";
              IF mac_rec_w.prom = '1' OR dst_v = mac_rec_w.padr OR bc_v OR
                 (dst_v(0) = '1' AND mac_rec_w.ladrf(to_integer(rx_hash)) = '1')
              THEN
                rx_keep <= '1';
              END IF;
            END IF;
            k <= k + 1;
            IF k + 1 = nwords THEN
              state <= sRX_RPTR;
            ELSE
              acc_rd   <= '1';
              acc_wait <= '1';
              acc_a    <= BASE + W_RX + resize(rx_rptr(2 DOWNTO 0) & x"00", 29) +
                          k + 2;
            END IF;

          WHEN sRX_RPTR =>
            rx_rptr <= rx_rptr + 1;
            acc_wr <= '1';
            acc_a  <= BASE + W_RXR;
            acc_d  <= resize(rx_rptr + 1, 64);
            state  <= sRX_OFFER;

          WHEN sRX_OFFER =>
            IF rx_keep = '1' AND mac_rec_w.clr = '0' THEN
              rx_load  <= '1';
              rx_ldlen <= rx_flen;
            END IF;
            state <= sIDLE;

          ------------------------------------------
          -- Loopback: txbuf to rxbuf, then offered
          WHEN sLOOP_RD =>
            state <= sLOOP_WR;            -- txbuf_q: txbuf(k) next cycle

          WHEN sLOOP_WR =>
            rxbuf_wr <= '1';
            rxbuf_wa <= k(7 DOWNTO 0);
            rxbuf_d  <= txbuf_q;
            IF k = 0 THEN
              FOR i IN 0 TO 5 LOOP
                dst_v(8 * i + 7 DOWNTO 8 * i) := txbuf_q(8 * i + 7 DOWNTO 8 * i);
              END LOOP;
              IF mac_rec_w.prom = '1' OR dst_v = mac_rec_w.padr OR
                 dst_v(0) = '1' THEN
                rx_keep <= '1';           -- ours, broadcast, multicast
              END IF;
            END IF;
            k <= k + 1;
            txbuf_ra <= k(7 DOWNTO 0) + 1;
            IF k + 1 = nwords THEN
              rx_flen   <= tx_len + 4;
              tx_posted <= '1';
              state     <= sRX_OFFER;
            ELSE
              state <= sLOOP_RD;
            END IF;

          ------------------------------------------
          WHEN sMAC =>
            mac_pub <= mac_rec_w.padr;
            mac_ok  <= '1';
            acc_wr  <= '1';
            acc_a   <= BASE + W_MAC;
            acc_d   <= (OTHERS => '0');
            IF mac_rec_w.padr /= 0 THEN
              acc_d(63) <= '1';
              FOR i IN 0 TO 5 LOOP
                acc_d(47 - 8 * i DOWNTO 40 - 8 * i) <=
                  mac_rec_w.padr(8 * i + 7 DOWNTO 8 * i);
              END LOOP;
            END IF;
            state <= sIDLE;
        END CASE;
      END IF;

      IF reset_n = '0' THEN
        state    <= sINIT;
        step     <= x"0";
        acc_rd   <= '0';
        acc_wr   <= '0';
        acc_wait <= '0';
        poll_cpt <= 0;
        tx_retry <= 0;
        mac_ok   <= '0';
      END IF;
    END IF;
  END PROCESS Mbox;

END ARCHITECTURE rtl;
