------------------------------------------------------------------------
----                                                                ----
---- WF68K30L IP Core: Scoreboard Unit (Superscalar)                ----
----                                                                ----
---- Description:                                                   ----
---- This module implements a scoreboard for tracking physical      ----
---- register readiness in the 2-issue superscalar WF68K30L CPU.    ----
---- It maintains one bit per physical register indicating whether  ----
---- the register contains a valid value or is waiting for a        ----
---- pending operation to complete.                                 ----
----                                                                ----
---- Features:                                                      ----
---- - Tracks readiness of 32 physical registers                    ----
---- - Supports 4 simultaneous readiness queries per cycle          ----
---- - Handles 2 SET_PENDING operations per cycle (dual-issue)      ----
---- - Handles 2 SET_READY operations per cycle (dual-execute)      ----
---- - Flush support for pipeline recovery                          ----
----                                                                ----
---- Author(s):                                                     ----
---- - Claude (Anthropic AI) - Superscalar conversion               ----
---- - Based on WF68K30L by Wolfgang Foerster                       ----
----                                                                ----
------------------------------------------------------------------------
----                                                                ----
---- Copyright © 2025 - Superscalar Extension                       ----
---- Based on WF68K30L Copyright © 2014-2019 Wolfgang Foerster      ----
----                                                                ----
---- This documentation describes Open Hardware and is licensed     ----
---- under the CERN OHL v. 1.2.                                     ----
----                                                                ----
------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.std_logic_unsigned.all;

entity WF68K30L_SCOREBOARD is
    port (
        CLK   : in std_logic;
        RESET : in bit;

        -- Mark registers as pending (issue stage)
        -- Each bit corresponds to one physical register
        SET_PENDING_0 : in bit;                             -- Set physical reg as pending
        SET_PENDING_0_REG : in integer range 0 to 31;       -- Physical register number

        SET_PENDING_1 : in bit;                             -- Set physical reg as pending
        SET_PENDING_1_REG : in integer range 0 to 31;       -- Physical register number

        -- Mark registers as ready (execute complete)
        SET_READY_0 : in bit;                               -- Set physical reg as ready
        SET_READY_0_REG : in integer range 0 to 31;         -- Physical register number

        SET_READY_1 : in bit;                               -- Set physical reg as ready
        SET_READY_1_REG : in integer range 0 to 31;         -- Physical register number

        -- Query readiness (issue stage) - Combinatorial
        QUERY_0    : in integer range 0 to 31;              -- Physical reg to query
        IS_READY_0 : out bit;                               -- '1' if ready, '0' if pending

        QUERY_1    : in integer range 0 to 31;              -- Physical reg to query
        IS_READY_1 : out bit;                               -- '1' if ready, '0' if pending

        QUERY_2    : in integer range 0 to 31;              -- Physical reg to query
        IS_READY_2 : out bit;                               -- '1' if ready, '0' if pending

        QUERY_3    : in integer range 0 to 31;              -- Physical reg to query
        IS_READY_3 : out bit;                               -- '1' if ready, '0' if pending

        -- Flush (mark all ready for pipeline recovery)
        FLUSH : in bit;

        -- Debug/Status
        PENDING_COUNT : out integer range 0 to 32           -- Number of pending registers
    );
end entity WF68K30L_SCOREBOARD;

architecture BEHAVIOUR of WF68K30L_SCOREBOARD is
    -- Scoreboard: One bit per physical register
    -- '1' = ready (value is valid)
    -- '0' = pending (waiting for instruction to complete)
    type SCOREBOARD_TYPE is array(0 to 31) of bit;
    signal SCOREBOARD : SCOREBOARD_TYPE;

    -- Pending count
    signal PENDING_CNT : integer range 0 to 32;

begin

    -- Sequential logic: Update scoreboard state
    SCOREBOARD_UPDATE: process(CLK)
    begin
        if CLK'event and CLK = '1' then
            if RESET = '1' then
                -- Initially, all architectural registers (0-15) are ready
                -- All extra physical registers (16-31) are also ready (unused)
                for i in 0 to 31 loop
                    SCOREBOARD(i) <= '1';  -- All ready
                end loop;
                PENDING_CNT <= 0;

            elsif FLUSH = '1' then
                -- On flush, mark all registers as ready
                -- (Conservative approach - actual implementation might be more sophisticated)
                for i in 0 to 31 loop
                    SCOREBOARD(i) <= '1';
                end loop;
                PENDING_CNT <= 0;

            else
                -- Priority: SET_READY has priority over SET_PENDING
                -- (An instruction completing has priority over new issue)

                -- Step 1: Handle SET_READY operations
                if SET_READY_0 = '1' then
                    SCOREBOARD(SET_READY_0_REG) <= '1';
                end if;

                if SET_READY_1 = '1' then
                    SCOREBOARD(SET_READY_1_REG) <= '1';
                end if;

                -- Step 2: Handle SET_PENDING operations (if not overridden by ready)
                if SET_PENDING_0 = '1' then
                    -- Only set pending if not being set ready in same cycle
                    if not ((SET_READY_0 = '1' and SET_READY_0_REG = SET_PENDING_0_REG) or
                            (SET_READY_1 = '1' and SET_READY_1_REG = SET_PENDING_0_REG)) then
                        SCOREBOARD(SET_PENDING_0_REG) <= '0';
                    end if;
                end if;

                if SET_PENDING_1 = '1' then
                    -- Only set pending if not being set ready in same cycle
                    if not ((SET_READY_0 = '1' and SET_READY_0_REG = SET_PENDING_1_REG) or
                            (SET_READY_1 = '1' and SET_READY_1_REG = SET_PENDING_1_REG)) then
                        SCOREBOARD(SET_PENDING_1_REG) <= '0';
                    end if;
                end if;

                -- Update pending count
                PENDING_CNT <= 0;
                for i in 0 to 31 loop
                    if SCOREBOARD(i) = '0' then
                        PENDING_CNT <= PENDING_CNT + 1;
                    end if;
                end loop;
            end if;
        end if;
    end process SCOREBOARD_UPDATE;

    -- Combinatorial logic: Query readiness
    -- This considers not just current state, but also pending updates this cycle
    QUERY_LOGIC: process(SCOREBOARD,
                         QUERY_0, QUERY_1, QUERY_2, QUERY_3,
                         SET_READY_0, SET_READY_0_REG,
                         SET_READY_1, SET_READY_1_REG,
                         SET_PENDING_0, SET_PENDING_0_REG,
                         SET_PENDING_1, SET_PENDING_1_REG)
        variable ready_0, ready_1, ready_2, ready_3 : bit;
    begin
        -- Query 0
        ready_0 := SCOREBOARD(QUERY_0);

        -- Check if being set ready this cycle
        if SET_READY_0 = '1' and SET_READY_0_REG = QUERY_0 then
            ready_0 := '1';
        elsif SET_READY_1 = '1' and SET_READY_1_REG = QUERY_0 then
            ready_0 := '1';
        end if;

        -- Check if being set pending this cycle
        if SET_PENDING_0 = '1' and SET_PENDING_0_REG = QUERY_0 then
            ready_0 := '0';
        elsif SET_PENDING_1 = '1' and SET_PENDING_1_REG = QUERY_0 then
            ready_0 := '0';
        end if;

        IS_READY_0 <= ready_0;

        -- Query 1
        ready_1 := SCOREBOARD(QUERY_1);

        if SET_READY_0 = '1' and SET_READY_0_REG = QUERY_1 then
            ready_1 := '1';
        elsif SET_READY_1 = '1' and SET_READY_1_REG = QUERY_1 then
            ready_1 := '1';
        end if;

        if SET_PENDING_0 = '1' and SET_PENDING_0_REG = QUERY_1 then
            ready_1 := '0';
        elsif SET_PENDING_1 = '1' and SET_PENDING_1_REG = QUERY_1 then
            ready_1 := '0';
        end if;

        IS_READY_1 <= ready_1;

        -- Query 2
        ready_2 := SCOREBOARD(QUERY_2);

        if SET_READY_0 = '1' and SET_READY_0_REG = QUERY_2 then
            ready_2 := '1';
        elsif SET_READY_1 = '1' and SET_READY_1_REG = QUERY_2 then
            ready_2 := '1';
        end if;

        if SET_PENDING_0 = '1' and SET_PENDING_0_REG = QUERY_2 then
            ready_2 := '0';
        elsif SET_PENDING_1 = '1' and SET_PENDING_1_REG = QUERY_2 then
            ready_2 := '0';
        end if;

        IS_READY_2 <= ready_2;

        -- Query 3
        ready_3 := SCOREBOARD(QUERY_3);

        if SET_READY_0 = '1' and SET_READY_0_REG = QUERY_3 then
            ready_3 := '1';
        elsif SET_READY_1 = '1' and SET_READY_1_REG = QUERY_3 then
            ready_3 := '1';
        end if;

        if SET_PENDING_0 = '1' and SET_PENDING_0_REG = QUERY_3 then
            ready_3 := '0';
        elsif SET_PENDING_1 = '1' and SET_PENDING_1_REG = QUERY_3 then
            ready_3 := '0';
        end if;

        IS_READY_3 <= ready_3;
    end process QUERY_LOGIC;

    -- Output pending count
    PENDING_COUNT <= PENDING_CNT;

end architecture BEHAVIOUR;
