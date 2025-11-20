# 2-Issue Superscalar Architecture Design
## WF68K30L CPU Conversion Plan

**Target**: Convert current 3-stage scalar pipeline to 2-issue superscalar architecture
**Timeline**: 12-18 months
**Estimated LOC**: ~9,400 → ~18,000 lines

---

## 1. High-Level Architecture Overview

### Current Architecture (Scalar)
```
┌─────────────┐     ┌──────────────┐     ┌─────────────┐
│   Stage 1   │────▶│   Stage 2    │────▶│   Stage 3   │
│ Fetch/Decode│     │   Control    │     │  ALU/WB     │
│  (1 instr)  │     │  (1 instr)   │     │  (1 instr)  │
└─────────────┘     └──────────────┘     └─────────────┘
     1 FIFO            1 Decoder            1 ALU
```

### New Architecture (2-Issue Superscalar)
```
┌──────────────────┐     ┌────────────────────────┐     ┌──────────────────┐
│    Stage 1-2     │     │       Stage 3-4        │     │    Stage 5-6     │
│  Fetch/Decode    │────▶│   Issue/Rename/ROB     │────▶│   Execute/WB     │
│  (2 parallel)    │     │   (2 parallel)         │     │  (2 parallel)    │
└──────────────────┘     └────────────────────────┘     └──────────────────┘
   2 FIFOs/Decoders      Register Renaming               2 ALUs + Forwarding
                         Dependency Check
                         Reorder Buffer (32 entries)
```

### Pipeline Stages (6-stage)
1. **IF1** - Instruction Fetch (slot 0)
2. **IF2** - Instruction Fetch (slot 1) / Decode slot 0
3. **ID1** - Decode slot 1 / Dependency Check
4. **ID2** - Register Rename / Issue to ROB
5. **EX**  - Execute (dual ALUs with forwarding)
6. **WB**  - Writeback / ROB Commit

---

## 2. Component Architecture

### 2.1 Register Renaming Unit (NEW)
**File**: `wf68k30L_register_rename.vhd` (~800 lines)

**Purpose**: Map 16 architectural registers to 32 physical registers

**Components**:
```vhdl
-- Rename Table: Maps architectural to physical registers
type RENAME_TABLE is array(0 to 15) of integer range 0 to 31;
signal AR_RENAME : RENAME_TABLE;  -- Address register mapping (A0-A7)
signal DR_RENAME : RENAME_TABLE;  -- Data register mapping (D0-D7)

-- Free List: Available physical registers
type FREE_LIST is array(0 to 31) of std_logic;
signal PHYS_REG_FREE : FREE_LIST;

-- Rename operations
signal RENAME_REQ_0 : std_logic;  -- Request rename for instr 0
signal RENAME_REQ_1 : std_logic;  -- Request rename for instr 1
signal RENAME_SRC_0 : integer range 0 to 15;  -- Source arch reg
signal RENAME_DST_0 : integer range 0 to 31;  -- Dest phys reg
signal RENAME_SRC_1 : integer range 0 to 15;
signal RENAME_DST_1 : integer range 0 to 31;
```

**Key Features**:
- Maintains architectural → physical register mapping
- Allocates free physical registers on instruction issue
- Reclaims physical registers on instruction commit
- Handles both instruction slots simultaneously
- Resolves RAW/WAR/WAW hazards via renaming

---

### 2.2 Reorder Buffer (ROB) (NEW)
**File**: `wf68k30L_reorder_buffer.vhd` (~1,200 lines)

**Purpose**: Track in-flight instructions for in-order retirement

**Components**:
```vhdl
-- ROB Entry Structure
type ROB_ENTRY is record
    VALID        : std_logic;                      -- Entry is valid
    INSTR        : OP_68K;                         -- Instruction type
    PC           : std_logic_vector(31 downto 0);  -- Program counter
    DEST_ARCH    : integer range 0 to 15;          -- Dest architectural reg
    DEST_PHYS    : integer range 0 to 31;          -- Dest physical reg
    OLD_PHYS     : integer range 0 to 31;          -- Previous phys reg (for reclaim)
    RESULT       : std_logic_vector(63 downto 0);  -- Result value
    RESULT_VALID : std_logic;                      -- Result ready
    EXCEPTION    : std_logic;                      -- Exception occurred
    EXCEPT_VEC   : std_logic_vector(7 downto 0);   -- Exception vector
end record;

-- 32-entry circular buffer
type ROB_ARRAY is array(0 to 31) of ROB_ENTRY;
signal ROB : ROB_ARRAY;

-- Head/Tail pointers
signal ROB_HEAD : integer range 0 to 31;  -- Oldest instruction (commit point)
signal ROB_TAIL : integer range 0 to 31;  -- Newest instruction (issue point)
signal ROB_COUNT : integer range 0 to 32; -- Number of entries in use
```

**Key Operations**:
- **Issue**: Add 2 new instructions to ROB at tail (if space available)
- **Execute**: Mark results valid when ALU completes
- **Commit**: Retire up to 2 instructions from head (in-order)
- **Flush**: Clear entire ROB on branch misprediction or exception

---

### 2.3 Dual Instruction Decoders
**Files**:
- Modify `wf68k30L_opcode_decoder.vhd` (1,332 → ~2,400 lines)
- Create `wf68k30L_opcode_decoder_dual.vhd` wrapper (~400 lines)

**Architecture**:
```vhdl
-- Two independent instruction pipelines
signal IPIPE_0 : IPIPE_TYPE;  -- Instruction FIFO slot 0
signal IPIPE_1 : IPIPE_TYPE;  -- Instruction FIFO slot 1

-- Decoded instructions
signal OP_0 : OP_68K;         -- Instruction 0
signal OP_1 : OP_68K;         -- Instruction 1

-- Validity signals
signal OP_0_VALID : std_logic;
signal OP_1_VALID : std_logic;

-- Instruction alignment logic (variable-length CISC instructions)
signal FETCH_WIDTH : integer range 0 to 4;  -- Words fetched this cycle
signal ALIGN_OFFSET : integer range 0 to 3; -- Alignment offset
```

**Challenges**:
- Variable-length instructions (1-6 words per instruction)
- Proper alignment when instructions cross fetch boundaries
- Maintaining program counter consistency

**Solution**:
- Fetch 4 words (64 bits) per cycle from memory
- Instruction alignment unit extracts 2 valid instructions
- Track instruction boundaries for next cycle

---

### 2.4 Dual ALU Units
**Files**:
- Keep `wf68k30L_alu.vhd` as ALU_0 (1,264 lines)
- Create `wf68k30L_alu_1.vhd` as ALU_1 (copy, ~1,264 lines)
- Create `wf68k30L_alu_controller.vhd` for arbitration (~500 lines)

**Architecture**:
```vhdl
-- Two independent ALU instances
signal ALU_0_RESULT : std_logic_vector(63 downto 0);
signal ALU_0_VALID  : std_logic;
signal ALU_0_BSY    : std_logic;

signal ALU_1_RESULT : std_logic_vector(63 downto 0);
signal ALU_1_VALID  : std_logic;
signal ALU_1_BSY    : std_logic;

-- Result forwarding network
type FORWARD_BUS is array(0 to 1) of std_logic_vector(63 downto 0);
signal FWD_RESULTS : FORWARD_BUS;
signal FWD_VALID   : std_logic_vector(1 downto 0);
signal FWD_DEST    : array(0 to 1) of integer range 0 to 31;  -- Phys reg dest
```

**ALU Assignment Policy**:
- **ALU_0**: Integer ops, shifts, logical ops, loads/stores
- **ALU_1**: Integer ops, shifts, logical ops
- **Special**: Division/multiplication may require both ALUs (serialization)

**Result Forwarding**:
- Both ALUs broadcast results each cycle
- Dependent instructions can use forwarded results directly
- Bypasses physical register file read latency

---

### 2.5 Scoreboard (NEW)
**File**: `wf68k30L_scoreboard.vhd` (~600 lines)

**Purpose**: Track physical register readiness

```vhdl
-- Scoreboard: One bit per physical register
type SCOREBOARD is array(0 to 31) of std_logic;
signal REG_READY : SCOREBOARD;  -- '1' = ready, '0' = pending

-- Operations
signal SET_PENDING   : std_logic_vector(31 downto 0);  -- Mark reg as pending
signal SET_READY     : std_logic_vector(31 downto 0);  -- Mark reg as ready
signal QUERY_READY_0 : integer range 0 to 31;          -- Check if reg ready
signal QUERY_READY_1 : integer range 0 to 31;
signal IS_READY_0    : std_logic;                      -- Result of query
signal IS_READY_1    : std_logic;
```

**Functionality**:
- When instruction issues, mark destination physical register as pending
- When ALU completes, mark physical register as ready
- Issue logic queries scoreboard to check operand readiness

---

### 2.6 Dependency Checker (NEW)
**File**: `wf68k30L_dependency_checker.vhd` (~700 lines)

**Purpose**: Detect data dependencies between instructions in same cycle

```vhdl
-- Inter-instruction dependencies
signal INSTR_0_SRC_REGS : array(0 to 2) of integer range 0 to 31;  -- Source phys regs
signal INSTR_0_DST_REG  : integer range 0 to 31;                   -- Dest phys reg
signal INSTR_1_SRC_REGS : array(0 to 2) of integer range 0 to 31;
signal INSTR_1_DST_REG  : integer range 0 to 31;

-- Dependency flags
signal RAW_HAZARD : std_logic;  -- Read-After-Write (0→1 or 1→0)
signal WAW_HAZARD : std_logic;  -- Write-After-Write (both write same reg)
signal WAR_HAZARD : std_logic;  -- Write-After-Read (handled by renaming)

-- Issue decision
signal CAN_ISSUE_0 : std_logic;  -- Instr 0 can issue this cycle
signal CAN_ISSUE_1 : std_logic;  -- Instr 1 can issue this cycle
```

**Logic**:
- Check if instruction 1's sources depend on instruction 0's destination
- Check if both instructions write to same architectural register
- Determine if 0, 1, or 2 instructions can issue this cycle

---

### 2.7 Multi-Port Register File
**Files**:
- Modify `wf68k30L_address_registers.vhd` (678 → ~1,200 lines)
- Modify `wf68k30L_data_registers.vhd` (137 → ~600 lines)
- Create physical register files with 4 read ports, 2 write ports

**Architecture**:
```vhdl
-- Physical register file (32 registers)
type PHYS_REG_FILE is array(0 to 31) of std_logic_vector(31 downto 0);
signal PHYS_REGS : PHYS_REG_FILE;

-- Read ports (4 simultaneous reads)
signal RD_ADDR_0 : integer range 0 to 31;
signal RD_ADDR_1 : integer range 0 to 31;
signal RD_ADDR_2 : integer range 0 to 31;
signal RD_ADDR_3 : integer range 0 to 31;
signal RD_DATA_0 : std_logic_vector(31 downto 0);
signal RD_DATA_1 : std_logic_vector(31 downto 0);
signal RD_DATA_2 : std_logic_vector(31 downto 0);
signal RD_DATA_3 : std_logic_vector(31 downto 0);

-- Write ports (2 simultaneous writes)
signal WR_ADDR_0 : integer range 0 to 31;
signal WR_ADDR_1 : integer range 0 to 31;
signal WR_DATA_0 : std_logic_vector(31 downto 0);
signal WR_DATA_1 : std_logic_vector(31 downto 0);
signal WR_EN_0   : std_logic;
signal WR_EN_1   : std_logic;
```

**Read Priority**: Forwarding > Physical register file > Stall
**Write Conflicts**: If both writes target same register, ALU_0 takes priority

---

### 2.8 Modified Control Unit
**File**: `wf68k30L_control.vhd` (2,533 → ~5,000 lines)

**Major Changes**:
1. Dual FETCH state machines (FETCH_STATE_0, FETCH_STATE_1)
2. Dual EXEC state machines (EXEC_STATE_0, EXEC_STATE_1)
3. Issue logic integrating:
   - Scoreboard queries
   - Dependency checking
   - ROB space availability
   - ALU availability
4. ROB commit logic (up to 2 instructions per cycle)
5. Exception handling via ROB
6. Branch misprediction recovery

**Control Flow**:
```
For each cycle:
  1. Check ROB space (need 2 free entries)
  2. Fetch/decode up to 2 instructions
  3. Rename architectural registers → physical registers
  4. Check dependencies (intra-cycle and scoreboard)
  5. Issue 0, 1, or 2 instructions to ROB
  6. Assign ready instructions to available ALUs
  7. Execute and capture results
  8. Commit up to 2 completed instructions from ROB head
  9. Update rename table and free list on commit
```

---

## 3. Implementation Sequence

### Phase 1: Infrastructure (Weeks 1-8)
- [ ] Create register renaming unit
- [ ] Create reorder buffer
- [ ] Create scoreboard
- [ ] Create dependency checker
- [ ] Unit test each component independently

### Phase 2: Register Files (Weeks 9-12)
- [ ] Modify address registers for 32 physical regs + 4R/2W ports
- [ ] Modify data registers for 32 physical regs + 4R/2W ports
- [ ] Add result forwarding logic
- [ ] Integration test with renaming unit

### Phase 3: Dual Decoders (Weeks 13-18)
- [ ] Create dual instruction FIFO
- [ ] Implement instruction alignment logic
- [ ] Replicate opcode decoder
- [ ] Test variable-length instruction handling

### Phase 4: Dual ALUs (Weeks 19-24)
- [ ] Duplicate ALU module (ALU_1)
- [ ] Create ALU controller/arbiter
- [ ] Implement result forwarding network
- [ ] Test parallel execution

### Phase 5: Control Integration (Weeks 25-36)
- [ ] Modify control unit with dual state machines
- [ ] Integrate all new components
- [ ] Implement issue logic
- [ ] Implement commit logic
- [ ] Add branch misprediction handling

### Phase 6: Testing (Weeks 37-48)
- [ ] Unit tests for each module
- [ ] Integration tests for component pairs
- [ ] Full system tests with instruction traces
- [ ] Performance benchmarking
- [ ] Timing closure and synthesis

---

## 4. Key Design Decisions

### 4.1 ROB Size: 32 entries
**Rationale**: Balances instruction window size with circuit complexity. 32 entries allows ~16 cycles of latency hiding with 2-issue.

### 4.2 Physical Registers: 32
**Rationale**: 2x architectural registers (16). Allows ~16 in-flight instructions with renaming.

### 4.3 Issue Width: 2
**Rationale**: Best complexity/performance tradeoff. Most MC68K code has ILP of 1.5-2.5.

### 4.4 ALU Configuration: 2 symmetric
**Rationale**: Simplifies scheduling. Any instruction can go to either ALU (except memory ops to ALU_0 only).

### 4.5 Memory Operations: Serialize
**Rationale**: Keep single memory port initially. Dual issue for compute, serialize for memory.

---

## 5. Interface Specifications

### 5.1 Register Renaming Interface
```vhdl
entity wf68k30L_register_rename is
    port (
        CLK          : in std_logic;
        RESET        : in std_logic;

        -- Rename requests (issue stage)
        RENAME_0_REQ    : in std_logic;
        RENAME_0_ARCH   : in integer range 0 to 15;
        RENAME_0_IS_DST : in std_logic;
        RENAME_0_PHYS   : out integer range 0 to 31;

        RENAME_1_REQ    : in std_logic;
        RENAME_1_ARCH   : in integer range 0 to 15;
        RENAME_1_IS_DST : in std_logic;
        RENAME_1_PHYS   : out integer range 0 to 31;

        -- Commit (update rename table and free list)
        COMMIT_0       : in std_logic;
        COMMIT_0_ARCH  : in integer range 0 to 15;
        COMMIT_0_PHYS  : in integer range 0 to 31;
        COMMIT_0_OLD   : in integer range 0 to 31;

        COMMIT_1       : in std_logic;
        COMMIT_1_ARCH  : in integer range 0 to 15;
        COMMIT_1_PHYS  : in integer range 0 to 31;
        COMMIT_1_OLD   : in integer range 0 to 31;

        -- Flush (branch misprediction)
        FLUSH          : in std_logic
    );
end entity;
```

### 5.2 Reorder Buffer Interface
```vhdl
entity wf68k30L_reorder_buffer is
    port (
        CLK   : in std_logic;
        RESET : in std_logic;

        -- Issue (add instructions)
        ISSUE_0         : in std_logic;
        ISSUE_0_DATA    : in ROB_ENTRY;
        ISSUE_0_ROB_IDX : out integer range 0 to 31;

        ISSUE_1         : in std_logic;
        ISSUE_1_DATA    : in ROB_ENTRY;
        ISSUE_1_ROB_IDX : out integer range 0 to 31;

        -- Execute complete (mark result valid)
        COMPLETE_0          : in std_logic;
        COMPLETE_0_ROB_IDX  : in integer range 0 to 31;
        COMPLETE_0_RESULT   : in std_logic_vector(63 downto 0);
        COMPLETE_0_EXCEPT   : in std_logic;

        COMPLETE_1          : in std_logic;
        COMPLETE_1_ROB_IDX  : in integer range 0 to 31;
        COMPLETE_1_RESULT   : in std_logic_vector(63 downto 0);
        COMPLETE_1_EXCEPT   : in std_logic;

        -- Commit (retire instructions)
        COMMIT_0      : out std_logic;
        COMMIT_0_DATA : out ROB_ENTRY;

        COMMIT_1      : out std_logic;
        COMMIT_1_DATA : out ROB_ENTRY;

        -- Status
        ROB_FULL  : out std_logic;
        ROB_EMPTY : out std_logic;
        ROB_COUNT : out integer range 0 to 32;

        -- Flush
        FLUSH : in std_logic
    );
end entity;
```

### 5.3 Scoreboard Interface
```vhdl
entity wf68k30L_scoreboard is
    port (
        CLK   : in std_logic;
        RESET : in std_logic;

        -- Mark registers as pending (issue stage)
        SET_PENDING : in std_logic_vector(31 downto 0);

        -- Mark registers as ready (execute complete)
        SET_READY : in std_logic_vector(31 downto 0);

        -- Query readiness (issue stage)
        QUERY_0    : in integer range 0 to 31;
        IS_READY_0 : out std_logic;

        QUERY_1    : in integer range 0 to 31;
        IS_READY_1 : out std_logic;

        QUERY_2    : in integer range 0 to 31;
        IS_READY_2 : out std_logic;

        QUERY_3    : in integer range 0 to 31;
        IS_READY_3 : out std_logic;

        -- Flush (mark all ready)
        FLUSH : in std_logic
    );
end entity;
```

---

## 6. Expected Performance

### IPC (Instructions Per Cycle)
- **Current**: 0.8-1.0 (scalar with pipeline stalls)
- **Target**: 1.4-1.7 (2-issue with good ILP utilization)

### Clock Frequency Impact
- **Current**: Baseline (assume 50 MHz)
- **Target**: 42-45 MHz (10-15% reduction due to longer critical paths)

### Net Performance
- **Current**: 0.8 IPC × 50 MHz = 40 MIPS
- **Target**: 1.5 IPC × 43 MHz = 64.5 MIPS (~1.6x speedup)

---

## 7. Risk Mitigation

### High-Risk Items
1. **Register renaming correctness** → Extensive unit tests, formal verification
2. **ROB exception handling** → Shadow state tracking, golden model comparison
3. **Timing closure** → Early synthesis, iterative optimization
4. **Dependency checking combinatorial explosion** → Pipeline dependency stage

### Testing Strategy
1. Unit test each component in isolation
2. Integration test component pairs
3. Directed tests for corner cases (dependencies, exceptions, branches)
4. Random instruction sequences
5. Real MC68K programs (GCC, BASIC, OS)

---

## 8. Files to Create/Modify

### New Files (6)
1. `wf68k30L_register_rename.vhd` (~800 lines)
2. `wf68k30L_reorder_buffer.vhd` (~1,200 lines)
3. `wf68k30L_scoreboard.vhd` (~600 lines)
4. `wf68k30L_dependency_checker.vhd` (~700 lines)
5. `wf68k30L_alu_1.vhd` (~1,264 lines, copy of ALU_0)
6. `wf68k30L_alu_controller.vhd` (~500 lines)

### Modified Files (5)
1. `wf68k30L_top.vhd` (1,199 → ~1,800 lines)
2. `wf68k30L_control.vhd` (2,533 → ~5,000 lines)
3. `wf68k30L_opcode_decoder.vhd` (1,332 → ~2,400 lines)
4. `wf68k30L_address_registers.vhd` (678 → ~1,200 lines)
5. `wf68k30L_data_registers.vhd` (137 → ~600 lines)

### Total LOC
- Current: 9,398 lines
- New files: 5,064 lines
- Modified files growth: ~4,153 lines
- **Total: ~18,615 lines (1.98x growth)**

---

## Next Steps

1. Review and approve this design document
2. Begin Phase 1: Implement infrastructure components
3. Set up testbenches for new components
4. Create integration plan for merging into main codebase

---

**Document Version**: 1.0
**Date**: 2025-11-20
**Status**: Initial Design - Awaiting Approval
