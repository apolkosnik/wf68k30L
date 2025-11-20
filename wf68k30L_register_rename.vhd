------------------------------------------------------------------------
----                                                                ----
---- WF68K30L IP Core: Register Renaming Unit (Superscalar)         ----
----                                                                ----
---- Description:                                                   ----
---- This module implements register renaming for the 2-issue       ----
---- superscalar version of the WF68K30L CPU. It maps 16            ----
---- architectural registers (8 address + 8 data) to 32 physical    ----
---- registers, enabling out-of-order execution and eliminating     ----
---- false dependencies (WAR/WAW hazards).                          ----
----                                                                ----
---- Features:                                                      ----
---- - Maps 16 architectural registers to 32 physical registers     ----
---- - Handles 2 rename requests per cycle (dual-issue)             ----
---- - Maintains free list of available physical registers          ----
---- - Supports 2 commits per cycle (retirement)                    ----
---- - Flush support for branch misprediction recovery              ----
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
use ieee.std_logic_arith.all;

entity WF68K30L_REGISTER_RENAME is
    port (
        CLK          : in std_logic;
        RESET        : in bit;

        -- Rename requests (issue stage) - Instruction 0
        RENAME_0_REQ    : in bit;                           -- Request rename
        RENAME_0_ARCH   : in integer range 0 to 15;         -- Architectural register number
        RENAME_0_IS_DST : in bit;                           -- '1' if destination, '0' if source
        RENAME_0_PHYS   : out integer range 0 to 31;        -- Physical register number

        -- Rename requests (issue stage) - Instruction 1
        RENAME_1_REQ    : in bit;                           -- Request rename
        RENAME_1_ARCH   : in integer range 0 to 15;         -- Architectural register number
        RENAME_1_IS_DST : in bit;                           -- '1' if destination, '0' if source
        RENAME_1_PHYS   : out integer range 0 to 31;        -- Physical register number

        -- Additional source operand lookups (for multi-source instructions)
        RENAME_2_REQ    : in bit;                           -- Request rename
        RENAME_2_ARCH   : in integer range 0 to 15;         -- Architectural register number
        RENAME_2_PHYS   : out integer range 0 to 31;        -- Physical register number (source only)

        RENAME_3_REQ    : in bit;                           -- Request rename
        RENAME_3_ARCH   : in integer range 0 to 15;         -- Architectural register number
        RENAME_3_PHYS   : out integer range 0 to 31;        -- Physical register number (source only)

        -- Commit (update rename table and free list) - Instruction 0
        COMMIT_0       : in bit;                            -- Commit instruction 0
        COMMIT_0_ARCH  : in integer range 0 to 15;          -- Architectural register
        COMMIT_0_PHYS  : in integer range 0 to 31;          -- New physical register
        COMMIT_0_OLD   : in integer range 0 to 31;          -- Old physical register (to free)

        -- Commit (update rename table and free list) - Instruction 1
        COMMIT_1       : in bit;                            -- Commit instruction 1
        COMMIT_1_ARCH  : in integer range 0 to 15;          -- Architectural register
        COMMIT_1_PHYS  : in integer range 0 to 31;          -- New physical register
        COMMIT_1_OLD   : in integer range 0 to 31;          -- Old physical register (to free)

        -- Flush (branch misprediction or exception)
        FLUSH          : in bit;                            -- Flush rename state

        -- Status
        FREE_COUNT     : out integer range 0 to 32;         -- Number of free physical registers
        STALL          : out bit                            -- '1' if no free registers available
    );
end entity WF68K30L_REGISTER_RENAME;

architecture BEHAVIOUR of WF68K30L_REGISTER_RENAME is
    -- Rename table: Maps architectural registers to physical registers
    -- Registers 0-7: Address registers (A0-A7)
    -- Registers 8-15: Data registers (D0-D7)
    type RENAME_TABLE_TYPE is array(0 to 15) of integer range 0 to 31;
    signal RENAME_TABLE : RENAME_TABLE_TYPE;
    signal RENAME_TABLE_SHADOW : RENAME_TABLE_TYPE; -- Shadow for checkpoint/recovery

    -- Free list: Tracks which physical registers are available
    -- '1' = free, '0' = in use
    type FREE_LIST_TYPE is array(0 to 31) of bit;
    signal FREE_LIST : FREE_LIST_TYPE;
    signal FREE_LIST_SHADOW : FREE_LIST_TYPE; -- Shadow for checkpoint/recovery

    -- Free register count
    signal FREE_CNT : integer range 0 to 32;

    -- Allocation signals
    signal ALLOC_0_VALID : bit;
    signal ALLOC_0_PHYS  : integer range 0 to 31;
    signal ALLOC_1_VALID : bit;
    signal ALLOC_1_PHYS  : integer range 0 to 31;

    -- Temporary rename table for intra-cycle dependencies
    signal RENAME_TABLE_TEMP : RENAME_TABLE_TYPE;

begin

    -- Main rename logic
    RENAME_LOGIC: process(CLK)
        variable free_search_start : integer range 0 to 31;
        variable found_free : boolean;
        variable temp_rename : RENAME_TABLE_TYPE;
    begin
        if CLK'event and CLK = '1' then
            if RESET = '1' then
                -- Initialize: Map architectural regs 0-15 to physical regs 0-15
                -- Physical regs 16-31 are initially free
                for i in 0 to 15 loop
                    RENAME_TABLE(i) <= i;
                    RENAME_TABLE_SHADOW(i) <= i;
                    FREE_LIST(i) <= '0';  -- In use
                    FREE_LIST_SHADOW(i) <= '0';
                end loop;

                for i in 16 to 31 loop
                    FREE_LIST(i) <= '1';  -- Free
                    FREE_LIST_SHADOW(i) <= '1';
                end loop;

                FREE_CNT <= 16;
                ALLOC_0_VALID <= '0';
                ALLOC_1_VALID <= '0';
                ALLOC_0_PHYS <= 16;
                ALLOC_1_PHYS <= 17;

            elsif FLUSH = '1' then
                -- Restore from shadow (checkpoint)
                RENAME_TABLE <= RENAME_TABLE_SHADOW;
                FREE_LIST <= FREE_LIST_SHADOW;
                FREE_CNT <= 16;  -- Conservative: assume we free everything
                ALLOC_0_VALID <= '0';
                ALLOC_1_VALID <= '0';

            else
                -- Step 1: Handle commits (free old physical registers)
                if COMMIT_0 = '1' then
                    FREE_LIST(COMMIT_0_OLD) <= '1';  -- Free old physical register
                    RENAME_TABLE_SHADOW(COMMIT_0_ARCH) <= COMMIT_0_PHYS;  -- Update shadow
                    FREE_LIST_SHADOW(COMMIT_0_OLD) <= '1';
                end if;

                if COMMIT_1 = '1' then
                    FREE_LIST(COMMIT_1_OLD) <= '1';  -- Free old physical register
                    RENAME_TABLE_SHADOW(COMMIT_1_ARCH) <= COMMIT_1_PHYS;  -- Update shadow
                    FREE_LIST_SHADOW(COMMIT_1_OLD) <= '1';
                end if;

                -- Step 2: Allocate new physical registers for destination operands
                free_search_start := 16;  -- Start searching from physical reg 16
                ALLOC_0_VALID <= '0';
                ALLOC_1_VALID <= '0';

                -- Allocate for instruction 0
                if RENAME_0_REQ = '1' and RENAME_0_IS_DST = '1' then
                    found_free := false;
                    for i in 16 to 31 loop
                        if not found_free and FREE_LIST(i) = '1' then
                            ALLOC_0_PHYS <= i;
                            FREE_LIST(i) <= '0';  -- Mark as in use
                            RENAME_TABLE(RENAME_0_ARCH) <= i;  -- Update rename table
                            ALLOC_0_VALID <= '1';
                            found_free := true;
                            free_search_start := i + 1;  -- Next allocation starts after this
                        end if;
                    end loop;
                end if;

                -- Allocate for instruction 1 (considering instruction 0's allocation)
                if RENAME_1_REQ = '1' and RENAME_1_IS_DST = '1' then
                    found_free := false;
                    for i in 16 to 31 loop
                        if not found_free and FREE_LIST(i) = '1' then
                            -- Make sure we don't allocate the same register as instruction 0
                            if ALLOC_0_VALID = '0' or i /= ALLOC_0_PHYS then
                                ALLOC_1_PHYS <= i;
                                FREE_LIST(i) <= '0';  -- Mark as in use
                                RENAME_TABLE(RENAME_1_ARCH) <= i;  -- Update rename table
                                ALLOC_1_VALID <= '1';
                                found_free := true;
                            end if;
                        end if;
                    end loop;
                end if;

                -- Update free count
                FREE_CNT <= 0;
                for i in 0 to 31 loop
                    if FREE_LIST(i) = '1' then
                        FREE_CNT <= FREE_CNT + 1;
                    end if;
                end loop;
            end if;
        end if;
    end process RENAME_LOGIC;

    -- Combinatorial rename lookups (for source operands and immediate use)
    RENAME_LOOKUP: process(RENAME_TABLE, RENAME_TABLE_TEMP,
                           RENAME_0_REQ, RENAME_0_ARCH, RENAME_0_IS_DST,
                           RENAME_1_REQ, RENAME_1_ARCH, RENAME_1_IS_DST,
                           RENAME_2_REQ, RENAME_2_ARCH,
                           RENAME_3_REQ, RENAME_3_ARCH,
                           ALLOC_0_VALID, ALLOC_0_PHYS,
                           ALLOC_1_VALID, ALLOC_1_PHYS)
    begin
        -- Create temporary rename table considering in-flight allocations
        RENAME_TABLE_TEMP <= RENAME_TABLE;

        -- If instruction 0 is allocating a register, update temp table
        if RENAME_0_REQ = '1' and RENAME_0_IS_DST = '1' and ALLOC_0_VALID = '1' then
            RENAME_TABLE_TEMP(RENAME_0_ARCH) <= ALLOC_0_PHYS;
        end if;

        -- If instruction 1 is allocating a register, update temp table
        if RENAME_1_REQ = '1' and RENAME_1_IS_DST = '1' and ALLOC_1_VALID = '1' then
            RENAME_TABLE_TEMP(RENAME_1_ARCH) <= ALLOC_1_PHYS;
        end if;

        -- Rename lookups
        if RENAME_0_REQ = '1' then
            if RENAME_0_IS_DST = '1' then
                -- Destination: Return newly allocated physical register
                if ALLOC_0_VALID = '1' then
                    RENAME_0_PHYS <= ALLOC_0_PHYS;
                else
                    RENAME_0_PHYS <= RENAME_TABLE(RENAME_0_ARCH);  -- Stall case
                end if;
            else
                -- Source: Return current mapping
                RENAME_0_PHYS <= RENAME_TABLE(RENAME_0_ARCH);
            end if;
        else
            RENAME_0_PHYS <= 0;
        end if;

        if RENAME_1_REQ = '1' then
            if RENAME_1_IS_DST = '1' then
                -- Destination: Return newly allocated physical register
                if ALLOC_1_VALID = '1' then
                    RENAME_1_PHYS <= ALLOC_1_PHYS;
                else
                    RENAME_1_PHYS <= RENAME_TABLE(RENAME_1_ARCH);  -- Stall case
                end if;
            else
                -- Source: Check if instruction 0 writes this register
                if RENAME_0_REQ = '1' and RENAME_0_IS_DST = '1' and
                   RENAME_0_ARCH = RENAME_1_ARCH and ALLOC_0_VALID = '1' then
                    -- RAW hazard: Use newly allocated physical register from instr 0
                    RENAME_1_PHYS <= ALLOC_0_PHYS;
                else
                    -- No hazard: Use current mapping
                    RENAME_1_PHYS <= RENAME_TABLE(RENAME_1_ARCH);
                end if;
            end if;
        else
            RENAME_1_PHYS <= 0;
        end if;

        -- Additional source lookups (always sources, check dependencies)
        if RENAME_2_REQ = '1' then
            if RENAME_0_REQ = '1' and RENAME_0_IS_DST = '1' and
               RENAME_0_ARCH = RENAME_2_ARCH and ALLOC_0_VALID = '1' then
                RENAME_2_PHYS <= ALLOC_0_PHYS;
            elsif RENAME_1_REQ = '1' and RENAME_1_IS_DST = '1' and
                  RENAME_1_ARCH = RENAME_2_ARCH and ALLOC_1_VALID = '1' then
                RENAME_2_PHYS <= ALLOC_1_PHYS;
            else
                RENAME_2_PHYS <= RENAME_TABLE(RENAME_2_ARCH);
            end if;
        else
            RENAME_2_PHYS <= 0;
        end if;

        if RENAME_3_REQ = '1' then
            if RENAME_0_REQ = '1' and RENAME_0_IS_DST = '1' and
               RENAME_0_ARCH = RENAME_3_ARCH and ALLOC_0_VALID = '1' then
                RENAME_3_PHYS <= ALLOC_0_PHYS;
            elsif RENAME_1_REQ = '1' and RENAME_1_IS_DST = '1' and
                  RENAME_1_ARCH = RENAME_3_ARCH and ALLOC_1_VALID = '1' then
                RENAME_3_PHYS <= ALLOC_1_PHYS;
            else
                RENAME_3_PHYS <= RENAME_TABLE(RENAME_3_ARCH);
            end if;
        else
            RENAME_3_PHYS <= 0;
        end if;
    end process RENAME_LOOKUP;

    -- Status outputs
    FREE_COUNT <= FREE_CNT;

    -- Stall if we need to allocate but don't have enough free registers
    STALL_LOGIC: process(FREE_CNT, RENAME_0_REQ, RENAME_0_IS_DST,
                         RENAME_1_REQ, RENAME_1_IS_DST)
        variable regs_needed : integer range 0 to 2;
    begin
        regs_needed := 0;

        if RENAME_0_REQ = '1' and RENAME_0_IS_DST = '1' then
            regs_needed := regs_needed + 1;
        end if;

        if RENAME_1_REQ = '1' and RENAME_1_IS_DST = '1' then
            regs_needed := regs_needed + 1;
        end if;

        if FREE_CNT < regs_needed then
            STALL <= '1';
        else
            STALL <= '0';
        end if;
    end process STALL_LOGIC;

end architecture BEHAVIOUR;
