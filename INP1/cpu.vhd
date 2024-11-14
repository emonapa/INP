-- cpu.vhd: Simple 8-bit CPU (BrainFuck interpreter)
-- Copyright (C) 2024 Brno University of Technology,
--                    Faculty of Information Technology
-- Author(s): Jmeno Prijmeni <xlogin.vutbr.cz>
--
library ieee;
use ieee.std_logic_1164.all;
use ieee.std_logic_arith.all;
use ieee.std_logic_unsigned.all;

-- ----------------------------------------------------------------------------
--                        Entity declaration
-- ----------------------------------------------------------------------------
entity cpu is
 port (
   CLK   : in std_logic;  -- hodinovy signal
   RESET : in std_logic;  -- asynchronni reset procesoru
   EN    : in std_logic;  -- povoleni cinnosti procesoru 
 
   -- synchronni pamet RAM
   DATA_ADDR  : out std_logic_vector(12 downto 0); -- adresa do pameti
   DATA_WDATA : out std_logic_vector(7 downto 0); -- mem[DATA_ADDR] <- DATA_WDATA pokud DATA_EN='1'
   DATA_RDATA : in std_logic_vector(7 downto 0);  -- DATA_RDATA <- ram[DATA_ADDR] pokud DATA_EN='1'
   DATA_RDWR  : out std_logic;                    -- cteni (1) / zapis (0)
   DATA_EN    : out std_logic;                    -- povoleni cinnosti
   
   -- vstupni port
   IN_DATA   : in std_logic_vector(7 downto 0);   -- IN_DATA <- stav klavesnice pokud IN_VLD='1' a IN_REQ='1'
   IN_VLD    : in std_logic;                      -- data platna
   IN_REQ    : out std_logic;                     -- pozadavek na vstup data
   
   -- vystupni port
   OUT_DATA : out  std_logic_vector(7 downto 0);  -- zapisovana data
   OUT_BUSY : in std_logic;                       -- LCD je zaneprazdnen (1), nelze zapisovat
   --OUT_INV  : out std_logic;                      -- pozadavek na aktivaci inverzniho zobrazeni (1) //NEPOVINNY UKOL
   OUT_WE   : out std_logic;                      -- LCD <- OUT_DATA pokud OUT_WE='1' a OUT_BUSY='0'

   -- stavove signaly
   READY    : out std_logic;                      -- hodnota 1 znamena, ze byl procesor inicializovan a zacina vykonavat program
   DONE     : out std_logic                       -- hodnota 1 znamena, ze procesor ukoncil vykonavani programu (narazil na instrukci halt)
 );
end cpu;


-- ----------------------------------------------------------------------------
--                      Architecture declaration
-- ----------------------------------------------------------------------------
architecture behavioral of cpu is
     -- TMP register, same length as WDATA
     signal TMP       : std_logic_vector(7 downto 0) := (others => '0');
     -- PC (program counter)
     signal PC       : std_logic_vector(12 downto 0) := (others => '0');
     signal PC_INC   : std_logic;
     signal PC_DEC   : std_logic;
     -- PTR (data memory pointer)
     signal PTR      : std_logic_vector(12 downto 0) := (others => '0');
     signal PTR_INC  : std_logic;
     signal PTR_DEC  : std_logic;
     -- CNT (cycle counter)
     signal CNT      : std_logic_vector(7 downto 0) := (others => '0');
     signal CNT_INC  : std_logic;
     signal CNT_DEC  : std_logic;
     signal CNT_LOAD : std_logic;
     -- Auxiliary signals
     signal MX1_1b  : std_logic;
     signal MX2_2b  : std_logic_vector(1 downto 0) := (others => '0');
     signal CNT_ZERO : std_logic;
   
     -- FSM (finite state machine)
     type t_state is (
        store_tmp_read, store_tmp_write, -- Stores the value in a temporary register
        load_tmp,                        -- Loads value from temporary register
        find_start_read, find_start_compare, -- Finding the '@' character to start execution
        idle, fetch, decode,             -- Idle, fetch, and decode stages
        inc_read, inc_write,             -- Increment operations
        dec_read, dec_write,             -- Decrement operations
        move_left, move_right,           -- Pointer left and right movement
        print_read, print_output,        -- Output operations
        read_await, read_write,          -- Input operations
        while_start_read, while_start_compare, while_start_jump, while_start_skip, while_start_count, -- Start of a while loop
        while_end_read, while_end_compare, while_end_jump, while_end_return, while_end_count, -- End of a while loop
        noop, halt                       -- No operation and halt
    );
     signal PSTATE                    : t_state := idle;
     signal NSTATE                    : t_state;
     attribute fsm_encoding           : string;
     attribute fsm_encoding of PSTATE : signal is "sequential";
     attribute fsm_encoding of NSTATE : signal is "sequential";
   begin
   
     -- PC (program counter)
     PROCESS_PC : process (CLK, RESET)
     begin
          if (RESET = '1') then
               PC <= (others => '0');
          elsif (rising_edge(CLK)) then
               if (PC_INC = '1') then
                    PC <= PC + 1;
               elsif (PC_DEC = '1') then
                    PC <= PC - 1;
               end if;
          end if;
     end process;
   
     -- PTR (data memory pointer with modulo 0x2000 arithmetic)
     PROCESS_PTR : process (CLK, RESET)
     begin
         if (RESET = '1') then
             PTR <= (others => '0');  -- Resets PTR to 0
         elsif (rising_edge(CLK)) then
             if (PTR_INC = '1') then
                 if PTR = X"1FFF" then
                     PTR <= (others => '0');  -- Wrap back to address 0 when reaching the end
                 else
                     PTR <= PTR + 1;
                 end if;
             elsif (PTR_DEC = '1') then
                 if PTR = x"0000" then
                     PTR <= (others => '1'); --x"1FFF";  -- Wrap to address 1FFF when decrementing from 0
                 else
                     PTR <= PTR - 1;
                 end if;
             end if;
         end if;
     end process;
   
     -- CNT (cycle counter)
     PROCESS_CNT : process (CLK, RESET)
     begin
          if (RESET = '1') then
               CNT <= (others => '0');
          elsif (rising_edge(CLK)) then
               if (CNT_LOAD = '1') then
                    CNT <= X"01";
               elsif (CNT_INC = '1') then
                    CNT <= CNT + 1;
               elsif (CNT_DEC = '1') then
                    CNT <= CNT - 1;
               end if;
          end if;
     end process;
   
     -- CNT_ZERO (check if CNT = 0)
     PROCESS_CNTZERO : process (CNT)
     begin
          if (CNT = X"00") then
               CNT_ZERO <= '1';
          else
               CNT_ZERO <= '0';
          end if;
     end process;
   
     -- MX1_1b (program (0) or data (1) memory address)
     MX1_P1b : process (PC, PTR, MX1_1b)
     begin
          case MX1_1b is
               when '0'    => DATA_ADDR <= PC;
               when '1'    => DATA_ADDR <= PTR;  
               when others => null;
          end case;
     end process;
   
     -- MX2_2b (value to write to memory)
     MX2_P2b : process (IN_DATA, DATA_RDATA, MX2_2b)
     begin
          case MX2_2b is
               when "00"   => DATA_WDATA <= IN_DATA;
               when "01"   => DATA_WDATA <= TMP;
               when "10"   => DATA_WDATA <= DATA_RDATA - 1;
               when "11"   => DATA_WDATA <= DATA_RDATA + 1;
               when others => null;
          end case;
     end process;
   
     -- FSM (Finite State Machine)
     -- Present state logic
     FSM_PSTATE : process (CLK, RESET)
     begin
          if (RESET = '1') then
               PSTATE <= idle;
          elsif (rising_edge(CLK)) then
               PSTATE <= NSTATE;
          end if;
     end process;
   
     -- Next state logic; output logic
     FSM_NSTATE : process (PSTATE, IN_VLD, OUT_BUSY, DATA_RDATA, CNT_ZERO, EN, RESET)
     begin
          -- Default state
          DATA_EN   <= '0';
          DATA_RDWR <= '1';
          IN_REQ    <= '0';
          OUT_WE    <= '0';
          OUT_DATA  <= X"00";
          PC_INC    <= '0';
          PC_DEC    <= '0';
          PTR_INC   <= '0';
          PTR_DEC   <= '0';
          CNT_INC   <= '0';
          CNT_DEC   <= '0';
          CNT_LOAD  <= '0';
          MX1_1b   <= '0';
          MX2_2b   <= "01";
          DONE      <= '0';
   
          case PSTATE is
             -- IDLE (processor's default state)
             when idle =>
                 if (EN = '1') then 
                       NSTATE <= find_start_read;  -- Transition to `find_start_read` if processor is enabled
                 else
                       READY     <= '0';
                       NSTATE <= idle;
                  end if;
             
             when find_start_read =>
                  DATA_EN   <= '1';        -- Enable memory
                  DATA_RDWR <= '1';        -- Read mode
                  MX1_1b   <= '1';        -- Use memory as address
                  NSTATE    <= find_start_compare;
   
             -- State `find_start_compare` to look for character '@'
             when find_start_compare =>
                  if DATA_RDATA = X"40" then  -- If `@` is found (ASCII value of `@` is 0x40)
                       PTR_INC <= '1';
                       READY <= '1';
                       NSTATE <= fetch;
                  else
                       PTR_INC <= '1';         -- Increment PC to find the next address
                       NSTATE <= find_start_read;  -- Stay in `find_start_compare` until `@` is found
                  end if;
   
             -- FETCH (load the next instruction from the processor)
             when fetch =>
                    if (EN = '1') then
                         NSTATE    <= decode;
                         MX1_1b   <= '0';  -- Program memory
                         DATA_RDWR <= '1';  -- Read from memory
                         DATA_EN   <= '1';  -- Enable memory
                    else
                         NSTATE <= idle;
                    end if;
   
             -- DECODE (decode instruction)
             when decode =>
                    case (DATA_RDATA) is
                         when X"3E"  => NSTATE <= move_right;         -- >
                         when X"3C"  => NSTATE <= move_left;         -- <
                         when X"2B"  => NSTATE <= inc_read;        -- +
                         when X"2D"  => NSTATE <= dec_read;        -- -
                         when X"5B"  => NSTATE <= while_start_read;   -- [
                         when X"5D"  => NSTATE <= while_end_read;   -- ]
                         when X"24"  => NSTATE <= store_tmp_read;    -- $
                         when X"21"  => NSTATE <= load_tmp;     -- !
                         when X"2E"  => NSTATE <= print_read;      -- .
                         when X"2C"  => NSTATE <= read_await;   -- ,
                         when X"40"  => NSTATE <= halt;            -- @
                         when others => NSTATE <= noop;
                    end case;
   
             -- NOOP (no operation)
             when noop =>
                    PC_INC <= '1';
                    NSTATE <= fetch;
   
             -- HALT (infinite loop, effectively stops the processor)
             when halt =>
                    DONE <= '1';  -- Setting DONE to 1 indicates end of execution
                    NSTATE <= halt;
   
             -- MOV operations for > and < (Pointer movements right and left)
             -- Move right: Increment pointer and fetch
             when move_right =>
                    PC_INC  <= '1';
                    PTR_INC <= '1';
                    NSTATE  <= fetch;
   
             -- Move left: Decrement pointer and fetch
             when move_left =>
                    PC_INC  <= '1';
                    PTR_DEC <= '1';
                    NSTATE  <= fetch;
   
             -- Increment operations (+)
             -- Cycle 1 - Read current cell value
             when inc_read =>
                    PC_INC    <= '1';
                    MX1_1b   <= '1';
                    DATA_RDWR <= '1';
                    DATA_EN   <= '1';
                    NSTATE    <= inc_write;
             -- Cycle 2 - Write incremented value to memory
             when inc_write =>
                    MX1_1b   <= '1';
                    MX2_2b   <= "11";
                    DATA_RDWR <= '0';
                    DATA_EN   <= '1';
                    NSTATE    <= fetch;
   
             -- Decrement operations (-)
             -- Cycle 1 - Read current cell value
             when dec_read =>
                    PC_INC    <= '1';
                    MX1_1b   <= '1';
                    DATA_RDWR <= '1';
                    DATA_EN   <= '1';
                    NSTATE    <= dec_write;
             -- Cycle 2 - Write decremented value to memory
             when dec_write =>
                    MX1_1b   <= '1';
                    MX2_2b   <= "10";
                    DATA_RDWR <= '0';
                    DATA_EN   <= '1';
                    NSTATE    <= fetch;
   
             -- PRINT (output value)
             -- Cycle 1 - Read current cell value
             when print_read =>
                    PC_INC    <= '1';
                    MX1_1b   <= '1';
                    DATA_RDWR <= '1';
                    DATA_EN   <= '1';
                    NSTATE    <= print_output;
             -- Cycle 2 - Wait for output enable and then output value
             when print_output =>
                    if (OUT_BUSY = '1') then
                         NSTATE <= print_output;
                    else
                         OUT_WE   <= '1';
                         OUT_DATA <= DATA_RDATA;
                         NSTATE   <= fetch;
                    end if;
   
             -- READ (input value into cell)
             -- Cycle 1 - Request input and wait for IN_VLD
             when read_await =>
                    IN_REQ <= '1';
                    if (IN_VLD = '1') then
                         NSTATE <= read_write;
                    else
                         NSTATE <= read_await;
                    end if;
             -- Cycle 2 - Write input value into cell
             when read_write =>
                    PC_INC    <= '1';
                    MX1_1b   <= '1';
                    MX2_2b   <= "00";
                    DATA_RDWR <= '0';
                    DATA_EN   <= '1';
                    NSTATE    <= fetch;
   
             -- Store to TMP ($)
             when store_tmp_read =>
                    DATA_EN   <= '1';
                    DATA_RDWR <= '1';
                    MX1_1b   <= '1';
                    NSTATE <= store_tmp_write;
             when store_tmp_write =>
                    PC_INC <= '1';
                    TMP <= DATA_RDATA;
                    NSTATE <= fetch;
   
             -- Load from TMP (!)
             when load_tmp =>
                    MX1_1b   <= '1';
                    MX2_2b   <= "01";
                    DATA_RDWR <= '0';
                    DATA_EN   <= '1';
                    PC_INC <= '1';
                    NSTATE <= fetch;
   
             -- WHILE loop start ([)
             -- Cycle 1 - Read current cell value
             when while_start_read =>
                    PC_INC    <= '1';
                    MX1_1b   <= '1';
                    DATA_RDWR <= '1';
                    DATA_EN   <= '1';
                    NSTATE    <= while_start_compare;
             -- Cycle 2 - Check if value is zero; if zero, skip loop
             when while_start_compare =>
                    if (DATA_RDATA = X"00") then
                         CNT_LOAD  <= '1';
                         NSTATE    <= while_start_jump;
                    else
                         NSTATE <= fetch;
                    end if;
             ---------------------------------------SKIP LOOP FROM BEGINNING---------------------------------------
             -- Cycle 3 - Read next instruction
             when while_start_jump =>
                    MX1_1b   <= '0';
                    DATA_RDWR <= '1';
                    DATA_EN   <= '1';
                    NSTATE    <= while_start_skip;
             -- Cycle 4 - Update loop counter (handle nested loops)
             when while_start_skip =>
                    if (DATA_RDATA = X"5B") then -- [
                         CNT_INC <= '1';
                    elsif (DATA_RDATA = X"5D") then -- ]
                         CNT_DEC <= '1';
                    end if;
                    NSTATE <= while_start_count;
             -- Cycle 5 - Move to next instruction and continue skipping if needed
             when while_start_count =>
                    PC_INC <= '1';
                    if (CNT_ZERO = '1') then
                         NSTATE <= fetch;
                    else
                         NSTATE <= while_start_jump;
                    end if;
             ---------------------------------------SKIP LOOP FROM BEGINNING---------------------------------------
   
             -- WHILE loop end (])
             -- Cycle 1 - Read current cell value
             when while_end_read =>
                    MX1_1b   <= '1';
                    DATA_RDWR <= '1';
                    DATA_EN   <= '1';
                    NSTATE    <= while_end_compare;
             -- Cycle 2 - Check if value is zero; if not zero, jump back to loop start
             when while_end_compare =>
                    if (DATA_RDATA = X"00") then
                         PC_INC <= '1';
                         NSTATE <= fetch;
                    else
                         CNT_LOAD <= '1';
                         PC_DEC   <= '1';
                         NSTATE   <= while_end_jump;
                    end if;
             ---------------------------------------SKIP LOOP FROM END---------------------------------------
             -- Cycle 3 - Read next instruction
             when while_end_jump =>
                    MX1_1b   <= '0';
                    DATA_RDWR <= '1';
                    DATA_EN   <= '1';
                    NSTATE    <= while_end_return;
             -- Cycle 4 - Update loop counter (handle nested loops)
             when while_end_return =>
                    if (DATA_RDATA = X"5D") then
                         CNT_INC <= '1';
                    elsif (DATA_RDATA = X"5B") then
                         CNT_DEC <= '1';
                    end if;
                    NSTATE <= while_end_count;
             -- Cycle 5 - Move to the next (or previous) instruction and continue skipping if needed
             when while_end_count =>
                    if (CNT_ZERO = '1') then
                         PC_INC <= '1';
                         NSTATE <= fetch;
                    else
                         PC_DEC <= '1';
                         NSTATE <= while_end_jump;
                    end if;
             ---------------------------------------SKIP LOOP FROM END---------------------------------------
   
             when others =>
                    NSTATE <= idle;
          end case;
     end process;
   end behavioral;
   
