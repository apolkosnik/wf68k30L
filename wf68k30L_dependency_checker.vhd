------------------------------------------------------------------------
----                                                                ----
---- WF68K30L IP Core: Dependency Checker (Superscalar)             ----
----                                                                ----
---- Description:                                                   ----
---- This module checks for data dependencies between instructions  ----
---- being issued in the same cycle for the 2-issue superscalar     ----
---- WF68K30L CPU. It detects RAW (Read-After-Write), WAW          ----
---- (Write-After-Write), and WAR (Write-After-Read) hazards.      ----
----                                                                ----
---- Features:                                                      ----
---- - Checks intra-cycle dependencies between 2 instructions       ----
---- - Queries scoreboard for operand readiness                     ----
---- - Determines issue decision (0, 1, or 2 instructions)          ----
---- - Handles multi-source instructions (up to 3 sources)          ----
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

library work;
use work.WF68K30L_PKG.all;

library ieee;
use ieee.std_logic_1164.all;

entity WF68K30L_DEPENDENCY_CHECKER is
    port (
        -- Instruction 0 register information
        INSTR_0_VALID     : in bit;                         -- Instruction 0 is valid
        INSTR_0_SRC_0     : in integer range 0 to 31;       -- Source physical reg 0
        INSTR_0_SRC_1     : in integer range 0 to 31;       -- Source physical reg 1
        INSTR_0_SRC_2     : in integer range 0 to 31;       -- Source physical reg 2
        INSTR_0_SRC_COUNT : in integer range 0 to 3;        -- Number of source regs
        INSTR_0_DST       : in integer range 0 to 31;       -- Dest physical reg
        INSTR_0_HAS_DST   : in bit;                         -- Has destination register

        -- Instruction 1 register information
        INSTR_1_VALID     : in bit;                         -- Instruction 1 is valid
        INSTR_1_SRC_0     : in integer range 0 to 31;       -- Source physical reg 0
        INSTR_1_SRC_1     : in integer range 0 to 31;       -- Source physical reg 1
        INSTR_1_SRC_2     : in integer range 0 to 31;       -- Source physical reg 2
        INSTR_1_SRC_COUNT : in integer range 0 to 3;        -- Number of source regs
        INSTR_1_DST       : in integer range 0 to 31;       -- Dest physical reg
        INSTR_1_HAS_DST   : in bit;                         -- Has destination register

        -- Scoreboard readiness
        SRC_0_READY_0     : in bit;                         -- Instr 0, source 0 ready
        SRC_1_READY_0     : in bit;                         -- Instr 0, source 1 ready
        SRC_2_READY_0     : in bit;                         -- Instr 0, source 2 ready

        SRC_0_READY_1     : in bit;                         -- Instr 1, source 0 ready
        SRC_1_READY_1     : in bit;                         -- Instr 1, source 1 ready
        SRC_2_READY_1     : in bit;                         -- Instr 1, source 2 ready

        -- Resource availability
        ROB_FULL          : in bit;                         -- Reorder buffer full
        RENAME_STALL      : in bit;                         -- Register rename stall

        -- Dependency flags
        RAW_HAZARD        : out bit;                        -- Read-After-Write hazard
        WAW_HAZARD        : out bit;                        -- Write-After-Write hazard
        WAR_HAZARD        : out bit;                        -- Write-After-Read hazard
        STRUCT_HAZARD     : out bit;                        -- Structural hazard

        -- Issue decision
        CAN_ISSUE_0       : out bit;                        -- Instruction 0 can issue
        CAN_ISSUE_1       : out bit;                        -- Instruction 1 can issue
        ISSUE_COUNT       : out integer range 0 to 2        -- Number of instructions to issue
    );
end entity WF68K30L_DEPENDENCY_CHECKER;

architecture BEHAVIOUR of WF68K30L_DEPENDENCY_CHECKER is
    signal RAW_0_TO_1 : bit;    -- Instr 1 reads from instr 0's destination
    signal WAW_0_TO_1 : bit;    -- Both write to same physical register
    signal WAR_0_TO_1 : bit;    -- Instr 1 writes to instr 0's source (handled by renaming)

    signal INSTR_0_READY : bit; -- All sources for instr 0 are ready
    signal INSTR_1_READY : bit; -- All sources for instr 1 are ready

begin

    -- Check if instruction 0's sources are ready
    INSTR_0_READY_LOGIC: process(INSTR_0_VALID, INSTR_0_SRC_COUNT,
                                  SRC_0_READY_0, SRC_1_READY_0, SRC_2_READY_0)
    begin
        if INSTR_0_VALID = '0' then
            INSTR_0_READY <= '0';
        elsif INSTR_0_SRC_COUNT = 0 then
            INSTR_0_READY <= '1';  -- No sources needed
        elsif INSTR_0_SRC_COUNT = 1 then
            INSTR_0_READY <= SRC_0_READY_0;
        elsif INSTR_0_SRC_COUNT = 2 then
            if SRC_0_READY_0 = '1' and SRC_1_READY_0 = '1' then
                INSTR_0_READY <= '1';
            else
                INSTR_0_READY <= '0';
            end if;
        else -- INSTR_0_SRC_COUNT = 3
            if SRC_0_READY_0 = '1' and SRC_1_READY_0 = '1' and SRC_2_READY_0 = '1' then
                INSTR_0_READY <= '1';
            else
                INSTR_0_READY <= '0';
            end if;
        end if;
    end process INSTR_0_READY_LOGIC;

    -- Check if instruction 1's sources are ready
    INSTR_1_READY_LOGIC: process(INSTR_1_VALID, INSTR_1_SRC_COUNT,
                                  SRC_0_READY_1, SRC_1_READY_1, SRC_2_READY_1)
    begin
        if INSTR_1_VALID = '0' then
            INSTR_1_READY <= '0';
        elsif INSTR_1_SRC_COUNT = 0 then
            INSTR_1_READY <= '1';  -- No sources needed
        elsif INSTR_1_SRC_COUNT = 1 then
            INSTR_1_READY <= SRC_0_READY_1;
        elsif INSTR_1_SRC_COUNT = 2 then
            if SRC_0_READY_1 = '1' and SRC_1_READY_1 = '1' then
                INSTR_1_READY <= '1';
            else
                INSTR_1_READY <= '0';
            end if;
        else -- INSTR_1_SRC_COUNT = 3
            if SRC_0_READY_1 = '1' and SRC_1_READY_1 = '1' and SRC_2_READY_1 = '1' then
                INSTR_1_READY <= '1';
            else
                INSTR_1_READY <= '0';
            end if;
        end if;
    end process INSTR_1_READY_LOGIC;

    -- Check for RAW hazard (instruction 1 reads from instruction 0's destination)
    RAW_CHECK: process(INSTR_0_VALID, INSTR_0_HAS_DST, INSTR_0_DST,
                       INSTR_1_VALID, INSTR_1_SRC_COUNT,
                       INSTR_1_SRC_0, INSTR_1_SRC_1, INSTR_1_SRC_2)
    begin
        RAW_0_TO_1 <= '0';

        if INSTR_0_VALID = '1' and INSTR_0_HAS_DST = '1' and INSTR_1_VALID = '1' then
            -- Check if any of instruction 1's sources match instruction 0's destination
            if INSTR_1_SRC_COUNT >= 1 and INSTR_1_SRC_0 = INSTR_0_DST then
                RAW_0_TO_1 <= '1';
            elsif INSTR_1_SRC_COUNT >= 2 and INSTR_1_SRC_1 = INSTR_0_DST then
                RAW_0_TO_1 <= '1';
            elsif INSTR_1_SRC_COUNT >= 3 and INSTR_1_SRC_2 = INSTR_0_DST then
                RAW_0_TO_1 <= '1';
            end if;
        end if;
    end process RAW_CHECK;

    RAW_HAZARD <= RAW_0_TO_1;

    -- Check for WAW hazard (both instructions write to same physical register)
    -- NOTE: This should be prevented by register renaming, but we check anyway
    WAW_CHECK: process(INSTR_0_VALID, INSTR_0_HAS_DST, INSTR_0_DST,
                       INSTR_1_VALID, INSTR_1_HAS_DST, INSTR_1_DST)
    begin
        if INSTR_0_VALID = '1' and INSTR_0_HAS_DST = '1' and
           INSTR_1_VALID = '1' and INSTR_1_HAS_DST = '1' and
           INSTR_0_DST = INSTR_1_DST then
            WAW_0_TO_1 <= '1';
        else
            WAW_0_TO_1 <= '0';
        end if;
    end process WAW_CHECK;

    WAW_HAZARD <= WAW_0_TO_1;

    -- WAR hazard (Write-After-Read) is eliminated by register renaming
    -- We set this to 0, but it's here for completeness
    WAR_0_TO_1 <= '0';
    WAR_HAZARD <= '0';

    -- Check for structural hazards
    STRUCT_HAZARD_LOGIC: process(ROB_FULL, RENAME_STALL)
    begin
        if ROB_FULL = '1' or RENAME_STALL = '1' then
            STRUCT_HAZARD <= '1';
        else
            STRUCT_HAZARD <= '0';
        end if;
    end process STRUCT_HAZARD_LOGIC;

    -- Issue decision logic
    ISSUE_DECISION: process(INSTR_0_VALID, INSTR_0_READY,
                           INSTR_1_VALID, INSTR_1_READY,
                           RAW_0_TO_1, WAW_0_TO_1,
                           ROB_FULL, RENAME_STALL)
        variable can_issue_0_v : bit;
        variable can_issue_1_v : bit;
        variable issue_count_v : integer range 0 to 2;
    begin
        can_issue_0_v := '0';
        can_issue_1_v := '0';
        issue_count_v := 0;

        -- Check if we can issue instruction 0
        if INSTR_0_VALID = '1' and INSTR_0_READY = '1' and
           ROB_FULL = '0' and RENAME_STALL = '0' then
            can_issue_0_v := '1';
            issue_count_v := 1;
        end if;

        -- Check if we can issue instruction 1
        -- Requirements:
        -- 1. Instruction 1 is valid and ready
        -- 2. No RAW or WAW hazard with instruction 0
        -- 3. ROB has space for at least 2 instructions
        -- 4. No rename stall
        if INSTR_1_VALID = '1' and INSTR_1_READY = '1' and
           RAW_0_TO_1 = '0' and WAW_0_TO_1 = '0' and
           ROB_FULL = '0' and RENAME_STALL = '0' and
           can_issue_0_v = '1' then
            can_issue_1_v := '1';
            issue_count_v := 2;
        end if;

        -- Output issue decisions
        CAN_ISSUE_0 <= can_issue_0_v;
        CAN_ISSUE_1 <= can_issue_1_v;
        ISSUE_COUNT <= issue_count_v;
    end process ISSUE_DECISION;

end architecture BEHAVIOUR;
