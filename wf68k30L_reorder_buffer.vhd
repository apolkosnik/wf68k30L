------------------------------------------------------------------------
----                                                                ----
---- WF68K30L IP Core: Reorder Buffer (ROB) (Superscalar)           ----
----                                                                ----
---- Description:                                                   ----
---- This module implements the Reorder Buffer for the 2-issue      ----
---- superscalar WF68K30L CPU. The ROB tracks all in-flight         ----
---- instructions and ensures in-order retirement (commit) even     ----
---- when instructions execute out-of-order. It also handles        ----
---- precise exception semantics and branch misprediction recovery. ----
----                                                                ----
---- Features:                                                      ----
---- - 32-entry circular buffer                                     ----
---- - Dual-issue: Add up to 2 instructions per cycle               ----
---- - Dual-commit: Retire up to 2 instructions per cycle           ----
---- - Precise exception handling                                   ----
---- - Branch misprediction recovery via flush                      ----
---- - Tracks instruction PC, destination register, result value    ----
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
use ieee.std_logic_unsigned.all;

entity WF68K30L_REORDER_BUFFER is
    port (
        CLK   : in std_logic;
        RESET : in bit;

        -- Issue interface: Add instructions to ROB (tail)
        ISSUE_0         : in bit;                           -- Issue instruction 0
        ISSUE_0_OP      : in OP_68K;                        -- Instruction opcode
        ISSUE_0_PC      : in std_logic_vector(31 downto 0); -- Program counter
        ISSUE_0_DEST_ARCH : in integer range 0 to 15;       -- Dest architectural reg
        ISSUE_0_DEST_PHYS : in integer range 0 to 31;       -- Dest physical reg
        ISSUE_0_OLD_PHYS  : in integer range 0 to 31;       -- Old physical reg (for free list)
        ISSUE_0_ROB_IDX   : out integer range 0 to 31;      -- Assigned ROB index

        ISSUE_1         : in bit;                           -- Issue instruction 1
        ISSUE_1_OP      : in OP_68K;                        -- Instruction opcode
        ISSUE_1_PC      : in std_logic_vector(31 downto 0); -- Program counter
        ISSUE_1_DEST_ARCH : in integer range 0 to 15;       -- Dest architectural reg
        ISSUE_1_DEST_PHYS : in integer range 0 to 31;       -- Dest physical reg
        ISSUE_1_OLD_PHYS  : in integer range 0 to 31;       -- Old physical reg (for free list)
        ISSUE_1_ROB_IDX   : out integer range 0 to 31;      -- Assigned ROB index

        -- Execute complete interface: Mark results valid
        COMPLETE_0          : in bit;                       -- Instruction 0 completed
        COMPLETE_0_ROB_IDX  : in integer range 0 to 31;     -- ROB index
        COMPLETE_0_RESULT   : in std_logic_vector(63 downto 0); -- Result value
        COMPLETE_0_EXCEPT   : in bit;                       -- Exception occurred
        COMPLETE_0_EXCEPT_VEC : in std_logic_vector(7 downto 0); -- Exception vector

        COMPLETE_1          : in bit;                       -- Instruction 1 completed
        COMPLETE_1_ROB_IDX  : in integer range 0 to 31;     -- ROB index
        COMPLETE_1_RESULT   : in std_logic_vector(63 downto 0); -- Result value
        COMPLETE_1_EXCEPT   : in bit;                       -- Exception occurred
        COMPLETE_1_EXCEPT_VEC : in std_logic_vector(7 downto 0); -- Exception vector

        -- Commit interface: Retire instructions (head)
        COMMIT_0           : out bit;                       -- Instruction 0 ready to commit
        COMMIT_0_OP        : out OP_68K;                    -- Instruction opcode
        COMMIT_0_PC        : out std_logic_vector(31 downto 0); -- Program counter
        COMMIT_0_DEST_ARCH : out integer range 0 to 15;     -- Dest architectural reg
        COMMIT_0_DEST_PHYS : out integer range 0 to 31;     -- Dest physical reg
        COMMIT_0_OLD_PHYS  : out integer range 0 to 31;     -- Old physical reg (to free)
        COMMIT_0_RESULT    : out std_logic_vector(63 downto 0); -- Result value
        COMMIT_0_EXCEPT    : out bit;                       -- Exception occurred
        COMMIT_0_EXCEPT_VEC : out std_logic_vector(7 downto 0); -- Exception vector

        COMMIT_1           : out bit;                       -- Instruction 1 ready to commit
        COMMIT_1_OP        : out OP_68K;                    -- Instruction opcode
        COMMIT_1_PC        : out std_logic_vector(31 downto 0); -- Program counter
        COMMIT_1_DEST_ARCH : out integer range 0 to 15;     -- Dest architectural reg
        COMMIT_1_DEST_PHYS : out integer range 0 to 31;     -- Dest physical reg
        COMMIT_1_OLD_PHYS  : out integer range 0 to 31;     -- Old physical reg (to free)
        COMMIT_1_RESULT    : out std_logic_vector(63 downto 0); -- Result value
        COMMIT_1_EXCEPT    : out bit;                       -- Exception occurred
        COMMIT_1_EXCEPT_VEC : out std_logic_vector(7 downto 0); -- Exception vector

        COMMIT_ACK_0       : in bit;                        -- Acknowledge commit 0
        COMMIT_ACK_1       : in bit;                        -- Acknowledge commit 1

        -- Status
        ROB_FULL  : out bit;                                -- ROB is full
        ROB_EMPTY : out bit;                                -- ROB is empty
        ROB_COUNT : out integer range 0 to 32;              -- Number of entries in use
        ROB_SPACE : out integer range 0 to 32;              -- Number of free entries

        -- Flush (branch misprediction or exception recovery)
        FLUSH : in bit                                      -- Clear entire ROB
    );
end entity WF68K30L_REORDER_BUFFER;

architecture BEHAVIOUR of WF68K30L_REORDER_BUFFER is
    -- ROB Entry Structure
    type ROB_ENTRY is record
        VALID        : bit;                                 -- Entry is valid
        INSTR        : OP_68K;                              -- Instruction type
        PC           : std_logic_vector(31 downto 0);       -- Program counter
        DEST_ARCH    : integer range 0 to 15;               -- Dest architectural reg
        DEST_PHYS    : integer range 0 to 31;               -- Dest physical reg
        OLD_PHYS     : integer range 0 to 31;               -- Previous physical reg
        RESULT       : std_logic_vector(63 downto 0);       -- Result value
        RESULT_VALID : bit;                                 -- Result ready
        EXCEPTION    : bit;                                 -- Exception occurred
        EXCEPT_VEC   : std_logic_vector(7 downto 0);        -- Exception vector
    end record;

    -- Initialize ROB entry to default values
    constant ROB_ENTRY_INIT : ROB_ENTRY := (
        VALID => '0',
        INSTR => NOP,
        PC => (others => '0'),
        DEST_ARCH => 0,
        DEST_PHYS => 0,
        OLD_PHYS => 0,
        RESULT => (others => '0'),
        RESULT_VALID => '0',
        EXCEPTION => '0',
        EXCEPT_VEC => (others => '0')
    );

    -- 32-entry circular buffer
    type ROB_ARRAY is array(0 to 31) of ROB_ENTRY;
    signal ROB : ROB_ARRAY;

    -- Head/Tail pointers
    signal ROB_HEAD : integer range 0 to 31;  -- Oldest instruction (commit point)
    signal ROB_TAIL : integer range 0 to 31;  -- Newest instruction (issue point)

    -- Entry count
    signal ROB_CNT : integer range 0 to 32;

    -- Next head pointer (after commits)
    signal ROB_HEAD_NEXT : integer range 0 to 31;

begin

    -- Main ROB logic
    ROB_LOGIC: process(CLK)
        variable next_tail : integer range 0 to 31;
        variable next_head : integer range 0 to 31;
        variable entries_to_add : integer range 0 to 2;
        variable entries_to_remove : integer range 0 to 2;
    begin
        if CLK'event and CLK = '1' then
            if RESET = '1' then
                -- Initialize ROB
                for i in 0 to 31 loop
                    ROB(i) <= ROB_ENTRY_INIT;
                end loop;

                ROB_HEAD <= 0;
                ROB_TAIL <= 0;
                ROB_CNT <= 0;

            elsif FLUSH = '1' then
                -- Clear entire ROB
                for i in 0 to 31 loop
                    ROB(i).VALID <= '0';
                end loop;

                ROB_HEAD <= 0;
                ROB_TAIL <= 0;
                ROB_CNT <= 0;

            else
                -- Step 1: Handle instruction issue (add to tail)
                next_tail := ROB_TAIL;
                entries_to_add := 0;

                if ISSUE_0 = '1' and ROB_CNT < 32 then
                    ROB(next_tail).VALID <= '1';
                    ROB(next_tail).INSTR <= ISSUE_0_OP;
                    ROB(next_tail).PC <= ISSUE_0_PC;
                    ROB(next_tail).DEST_ARCH <= ISSUE_0_DEST_ARCH;
                    ROB(next_tail).DEST_PHYS <= ISSUE_0_DEST_PHYS;
                    ROB(next_tail).OLD_PHYS <= ISSUE_0_OLD_PHYS;
                    ROB(next_tail).RESULT <= (others => '0');
                    ROB(next_tail).RESULT_VALID <= '0';
                    ROB(next_tail).EXCEPTION <= '0';
                    ROB(next_tail).EXCEPT_VEC <= (others => '0');

                    entries_to_add := entries_to_add + 1;
                    next_tail := (next_tail + 1) mod 32;
                end if;

                if ISSUE_1 = '1' and (ROB_CNT + entries_to_add) < 32 then
                    ROB(next_tail).VALID <= '1';
                    ROB(next_tail).INSTR <= ISSUE_1_OP;
                    ROB(next_tail).PC <= ISSUE_1_PC;
                    ROB(next_tail).DEST_ARCH <= ISSUE_1_DEST_ARCH;
                    ROB(next_tail).DEST_PHYS <= ISSUE_1_DEST_PHYS;
                    ROB(next_tail).OLD_PHYS <= ISSUE_1_OLD_PHYS;
                    ROB(next_tail).RESULT <= (others => '0');
                    ROB(next_tail).RESULT_VALID <= '0';
                    ROB(next_tail).EXCEPTION <= '0';
                    ROB(next_tail).EXCEPT_VEC <= (others => '0');

                    entries_to_add := entries_to_add + 1;
                    next_tail := (next_tail + 1) mod 32;
                end if;

                ROB_TAIL <= next_tail;

                -- Step 2: Handle execution complete (mark results valid)
                if COMPLETE_0 = '1' then
                    ROB(COMPLETE_0_ROB_IDX).RESULT <= COMPLETE_0_RESULT;
                    ROB(COMPLETE_0_ROB_IDX).RESULT_VALID <= '1';
                    ROB(COMPLETE_0_ROB_IDX).EXCEPTION <= COMPLETE_0_EXCEPT;
                    ROB(COMPLETE_0_ROB_IDX).EXCEPT_VEC <= COMPLETE_0_EXCEPT_VEC;
                end if;

                if COMPLETE_1 = '1' then
                    ROB(COMPLETE_1_ROB_IDX).RESULT <= COMPLETE_1_RESULT;
                    ROB(COMPLETE_1_ROB_IDX).RESULT_VALID <= '1';
                    ROB(COMPLETE_1_ROB_IDX).EXCEPTION <= COMPLETE_1_EXCEPT;
                    ROB(COMPLETE_1_ROB_IDX).EXCEPT_VEC <= COMPLETE_1_EXCEPT_VEC;
                end if;

                -- Step 3: Handle commit acknowledgments (remove from head)
                next_head := ROB_HEAD;
                entries_to_remove := 0;

                if COMMIT_ACK_0 = '1' and ROB(ROB_HEAD).VALID = '1' then
                    ROB(next_head).VALID <= '0';
                    entries_to_remove := entries_to_remove + 1;
                    next_head := (next_head + 1) mod 32;
                end if;

                if COMMIT_ACK_1 = '1' and entries_to_remove > 0 and ROB(next_head).VALID = '1' then
                    ROB(next_head).VALID <= '0';
                    entries_to_remove := entries_to_remove + 1;
                    next_head := (next_head + 1) mod 32;
                elsif COMMIT_ACK_1 = '1' and entries_to_remove = 0 and
                      ROB_HEAD /= ROB_TAIL and ROB(ROB_HEAD).VALID = '1' then
                    -- If only COMMIT_ACK_1 without COMMIT_ACK_0
                    ROB(ROB_HEAD).VALID <= '0';
                    entries_to_remove := 1;
                    next_head := (ROB_HEAD + 1) mod 32;
                end if;

                ROB_HEAD <= next_head;

                -- Update entry count
                ROB_CNT <= ROB_CNT + entries_to_add - entries_to_remove;
            end if;
        end if;
    end process ROB_LOGIC;

    -- Combinatorial commit logic: Present instructions at head for commit
    COMMIT_LOGIC: process(ROB, ROB_HEAD, ROB_CNT)
        variable head_idx : integer range 0 to 31;
        variable next_idx : integer range 0 to 31;
    begin
        head_idx := ROB_HEAD;
        next_idx := (ROB_HEAD + 1) mod 32;

        -- Commit 0: Head of ROB
        if ROB_CNT > 0 and ROB(head_idx).VALID = '1' and ROB(head_idx).RESULT_VALID = '1' then
            COMMIT_0 <= '1';
            COMMIT_0_OP <= ROB(head_idx).INSTR;
            COMMIT_0_PC <= ROB(head_idx).PC;
            COMMIT_0_DEST_ARCH <= ROB(head_idx).DEST_ARCH;
            COMMIT_0_DEST_PHYS <= ROB(head_idx).DEST_PHYS;
            COMMIT_0_OLD_PHYS <= ROB(head_idx).OLD_PHYS;
            COMMIT_0_RESULT <= ROB(head_idx).RESULT;
            COMMIT_0_EXCEPT <= ROB(head_idx).EXCEPTION;
            COMMIT_0_EXCEPT_VEC <= ROB(head_idx).EXCEPT_VEC;
        else
            COMMIT_0 <= '0';
            COMMIT_0_OP <= NOP;
            COMMIT_0_PC <= (others => '0');
            COMMIT_0_DEST_ARCH <= 0;
            COMMIT_0_DEST_PHYS <= 0;
            COMMIT_0_OLD_PHYS <= 0;
            COMMIT_0_RESULT <= (others => '0');
            COMMIT_0_EXCEPT <= '0';
            COMMIT_0_EXCEPT_VEC <= (others => '0');
        end if;

        -- Commit 1: Next entry after head
        if ROB_CNT > 1 and ROB(next_idx).VALID = '1' and ROB(next_idx).RESULT_VALID = '1' and
           COMMIT_0 = '1' then
            COMMIT_1 <= '1';
            COMMIT_1_OP <= ROB(next_idx).INSTR;
            COMMIT_1_PC <= ROB(next_idx).PC;
            COMMIT_1_DEST_ARCH <= ROB(next_idx).DEST_ARCH;
            COMMIT_1_DEST_PHYS <= ROB(next_idx).DEST_PHYS;
            COMMIT_1_OLD_PHYS <= ROB(next_idx).OLD_PHYS;
            COMMIT_1_RESULT <= ROB(next_idx).RESULT;
            COMMIT_1_EXCEPT <= ROB(next_idx).EXCEPTION;
            COMMIT_1_EXCEPT_VEC <= ROB(next_idx).EXCEPT_VEC;
        else
            COMMIT_1 <= '0';
            COMMIT_1_OP <= NOP;
            COMMIT_1_PC <= (others => '0');
            COMMIT_1_DEST_ARCH <= 0;
            COMMIT_1_DEST_PHYS <= 0;
            COMMIT_1_OLD_PHYS <= 0;
            COMMIT_1_RESULT <= (others => '0');
            COMMIT_1_EXCEPT <= '0';
            COMMIT_1_EXCEPT_VEC <= (others => '0');
        end if;
    end process COMMIT_LOGIC;

    -- Issue index assignment (combinatorial)
    ISSUE_IDX_LOGIC: process(ROB_TAIL, ISSUE_0, ISSUE_1)
    begin
        if ISSUE_0 = '1' then
            ISSUE_0_ROB_IDX <= ROB_TAIL;
        else
            ISSUE_0_ROB_IDX <= 0;
        end if;

        if ISSUE_1 = '1' then
            if ISSUE_0 = '1' then
                ISSUE_1_ROB_IDX <= (ROB_TAIL + 1) mod 32;
            else
                ISSUE_1_ROB_IDX <= ROB_TAIL;
            end if;
        else
            ISSUE_1_ROB_IDX <= 0;
        end if;
    end process ISSUE_IDX_LOGIC;

    -- Status outputs
    ROB_COUNT <= ROB_CNT;
    ROB_SPACE <= 32 - ROB_CNT;

    ROB_FULL_LOGIC: process(ROB_CNT)
    begin
        if ROB_CNT >= 30 then  -- Conservative: consider full at 30
            ROB_FULL <= '1';
        else
            ROB_FULL <= '0';
        end if;
    end process ROB_FULL_LOGIC;

    ROB_EMPTY_LOGIC: process(ROB_CNT)
    begin
        if ROB_CNT = 0 then
            ROB_EMPTY <= '1';
        else
            ROB_EMPTY <= '0';
        end if;
    end process ROB_EMPTY_LOGIC;

end architecture BEHAVIOUR;
