--------------------------------------------------------------------------------
-- tb_kbd: the keyboard translator (ts_ps2sun + ts_sunkb) from PS/2 bytes to
-- the Sun codes the ESCC receives: plain keys, the L-keys and Help (Right
-- Alt + F1..F11), AltGraph, Pause, Print Screen, and the reset reply with
-- held keys (Stop, A). Run by rtl/sun4m/tb/run.sh (GHDL).
--------------------------------------------------------------------------------

LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;

LIBRARY work;
USE work.base_pack.ALL;

ENTITY tb_kbd IS
END ENTITY tb_kbd;

ARCHITECTURE tb OF tb_kbd IS
  CONSTANT FREQ : natural := 4_000_000;
  SIGNAL clk : std_logic := '0';
  SIGNAL reset_n : std_logic := '0';
  SIGNAL ps2_i, ps2_o : uv4;
  SIGNAL kdat, kclk : std_logic := '1';
  SIGNAL di1_data : uv8;
  SIGNAL di1_req, di1_rdy : std_logic;
  SIGNAL do1_data : uv8 := x"00";
  SIGNAL do1_req : std_logic := '0';
  SIGNAL do1_rdy : std_logic;
  SIGNAL di2_req : std_logic;
  SIGNAL di2_data : uv8;
  SIGNAL kbd_leds : unsigned(2 DOWNTO 0);
  SIGNAL done : boolean := false;

  -- what the ESCC received
  TYPE arr_rx IS ARRAY(0 TO 255) OF uv8;
  SIGNAL rx : arr_rx;
  SIGNAL nrx : natural := 0;
  SIGNAL pend : std_logic := '0';
  SIGNAL rdy : std_logic := '0';
BEGIN
  clk <= NOT clk AFTER 125 ns WHEN NOT done;

  ps2_i <= "11" & kclk & kdat;

  dut: ENTITY work.ts_ps2sun
    GENERIC MAP (SYSFREQ => FREQ)
    PORT MAP (
      ps2_i => ps2_i, ps2_o => ps2_o, kbm_layout => x"21",
      di1_data => di1_data, di1_req => di1_req, di1_rdy => di1_rdy,
      do1_data => do1_data, do1_req => do1_req, do1_rdy => do1_rdy,
      di2_data => di2_data, di2_req => di2_req, di2_rdy => '0',
      kbd_leds => kbd_leds,
      do2_data => x"00", do2_req => '0', do2_rdy => OPEN,
      clk => clk, reset_n => reset_n);

  -- The ESCC's receiver: takes the byte while req is up, acknowledges it
  -- (rdy pulse) a cycle later, as ts_sport does
  Escc: PROCESS (clk)
  BEGIN
    IF rising_edge(clk) THEN
      rdy <= '0';
      IF pend = '1' THEN
        rdy <= '1';
        pend <= '0';
      ELSIF di1_req = '1' AND rdy = '0' THEN
        rx(nrx) <= di1_data;
        nrx <= nrx + 1;
        pend <= '1';
      END IF;
    END IF;
  END PROCESS Escc;
  di1_rdy <= rdy;

  Stim: PROCESS
    VARIABLE fails : natural := 0;
    VARIABLE base : natural := 0;

    -- one byte from the keyboard: start, 8 data bits LSB first, odd parity,
    -- stop; data changes while the clock is high, read on its falling edge
    PROCEDURE ps2_byte (CONSTANT b : uv8) IS
      VARIABLE f : unsigned(10 DOWNTO 0);
    BEGIN
      f := '1' & NOT (b(0) XOR b(1) XOR b(2) XOR b(3) XOR b(4) XOR b(5) XOR
                      b(6) XOR b(7)) & b & '0';
      FOR i IN 0 TO 10 LOOP
        kdat <= f(i);
        WAIT FOR 10 us;
        kclk <= '0';
        WAIT FOR 20 us;
        kclk <= '1';
        WAIT FOR 10 us;
      END LOOP;
      kdat <= '1';
      WAIT FOR 200 us;
    END PROCEDURE;

    TYPE arr_b IS ARRAY(natural RANGE <>) OF uv8;
    PROCEDURE keys (CONSTANT s : arr_b) IS
    BEGIN
      FOR i IN s'range LOOP
        ps2_byte(s(i));
      END LOOP;
      WAIT FOR 500 us;
    END PROCEDURE;

    PROCEDURE expect (CONSTANT name : string; CONSTANT e : arr_b) IS
      VARIABLE ok : boolean;
    BEGIN
      ok := nrx - base = e'length;
      IF ok THEN
        FOR i IN 0 TO e'length - 1 LOOP
          IF rx(base + i) /= e(e'low + i) THEN
            ok := false;
          END IF;
        END LOOP;
      END IF;
      IF ok THEN
        REPORT "PASS " & name SEVERITY note;
      ELSE
        fails := fails + 1;
        REPORT "FAIL " & name & ": got " & integer'image(nrx - base) &
          " bytes, expected " & integer'image(e'length) SEVERITY error;
        FOR i IN base TO nrx - 1 LOOP
          REPORT "  got " & integer'image(to_integer(rx(i))) SEVERITY note;
        END LOOP;
      END IF;
      base := nrx;
    END PROCEDURE;

    PROCEDURE command (CONSTANT c : uv8) IS
    BEGIN
      WAIT UNTIL rising_edge(clk);
      do1_data <= c;
      do1_req <= '1';
      WAIT UNTIL rising_edge(clk);
      do1_req <= '0';
      WAIT FOR 4 ms;
    END PROCEDURE;
  BEGIN
    WAIT FOR 2 us;
    reset_n <= '1';
    WAIT FOR 100 us;

    keys((x"1C", x"F0", x"1C"));                        -- A
    expect("a plain key", (x"4D", x"CD"));
    keys((x"05", x"F0", x"05"));                        -- F1
    expect("F1", (x"05", x"85"));
    -- Right Alt + F1, Right Alt up, A, F1 up: Stop-A
    keys((x"E0", x"11", x"05", x"E0", x"F0", x"11", x"1C", x"F0", x"1C",
          x"F0", x"05"));
    expect("Stop-A, Right Alt up first", (x"01", x"4D", x"CD", x"81"));
    -- the same with Right Alt held: no AltGraph between Stop and A
    keys((x"E0", x"11", x"05", x"1C", x"F0", x"1C", x"F0", x"05",
          x"E0", x"F0", x"11"));
    expect("Stop-A, Right Alt held", (x"01", x"4D", x"CD", x"81"));
    -- Right Alt + Q: AltGraph down first, up with Right Alt
    keys((x"E0", x"11", x"15", x"F0", x"15", x"E0", x"F0", x"11"));
    expect("AltGraph", (x"0D", x"36", x"B6", x"8D"));
    -- an L-key released after Right Alt stays an L-key
    keys((x"E0", x"11", x"06", x"E0", x"F0", x"11", x"F0", x"06"));
    expect("L2 kept", (x"03", x"83"));
    keys((x"E0", x"11", x"78", x"F0", x"78", x"E0", x"F0", x"11"));
    expect("Help", (x"76", x"F6"));
    keys((x"E0", x"11", x"09", x"F0", x"09", x"E0", x"F0", x"11"));
    expect("L10", (x"61", x"E1"));
    keys((x"E1", x"14", x"77", x"E1", x"F0", x"14", x"F0", x"77"));
    expect("Pause", (x"15", x"95"));
    keys((x"E0", x"12", x"E0", x"7C"));
    keys((x"E0", x"F0", x"7C", x"E0", x"F0", x"12"));
    expect("Print Screen", (x"16", x"96"));
    -- the reset reply: nothing held, then Stop and A held
    command(x"01");
    expect("reset", (x"FF", x"04", x"7F"));
    keys((x"E0", x"11", x"05", x"1C"));
    expect("Stop-A down", (x"01", x"4D"));
    command(x"01");
    expect("reset, Stop and A held", (x"FF", x"04", x"01", x"4D", x"7F"));
    keys((x"F0", x"1C", x"F0", x"05", x"E0", x"F0", x"11"));
    expect("Stop-A up", (x"CD", x"81"));

    IF fails = 0 THEN
      REPORT "tb_kbd: all passed" SEVERITY note;
    ELSE
      REPORT "tb_kbd: " & integer'image(fails) & " failed" SEVERITY error;
    END IF;
    done <= true;
    WAIT;
  END PROCESS Stim;
END ARCHITECTURE tb;
