# WF68K30L CPU Architecture Analysis

## Executive Summary

The WF68K30L is a **Motorola MC68030-compatible CISC processor** implemented in VHDL with an **optional 3-stage scalar pipeline architecture**. The current design is fundamentally **scalar** (single-instruction execution) with configurable pipelining that can be disabled via the `NO_PIPELINE` generic parameter. Converting this to a true superscalar architecture would require substantial restructuring of multiple components.

---

## 1. CPU Core Implementation Files

The WF68K30L core consists of 8 main VHDL modules totaling ~9,400 lines of code:

### A. Top-Level Module
- **File**: `wf68k30L_top.vhd` (1,199 lines)
- **Purpose**: Structural integration of all components
- **Key Features**:
  - Generic parameters: `NO_PIPELINE`, `NO_LOOP`, `VERSION`
  - Instantiates all 6 main functional units
  - Manages interconnect signals between components
  - Implements multiplexers for data routing

### B. Instruction Pipeline Stage 1: Opcode Decoder
- **File**: `wf68k30L_opcode_decoder.vhd` (1,332 lines)
- **Purpose**: Instruction fetch and decode stage
- **Key Components**:
  - **3-word Instruction FIFO** (pipeline stages D, C, B):
    ```
    type IPIPE_TYPE is record
        D : std_logic_vector(15 downto 0);  -- Newest instruction
        C : std_logic_vector(15 downto 0);  -- Middle instruction
        B : std_logic_vector(15 downto 0);  -- Oldest instruction
    end record;
    ```
  - **Handshake Signals**: `OW_REQ`, `OPD_ACK`, `EW_REQ`, `EW_ACK`
  - **Loop Mechanism**: DBcc loop support (68010-compatible)
  - **Breakpoint Support**: Can inject breakpoint opcodes
  - **State Variables**: `INSTR_LVL` (D, C, or B) tracks active instruction word
  - **Output**: Decoded opcode (`OP`), instruction words (`BIW_0`, `BIW_1`, `BIW_2`), extension words

---

## 2. Instruction Execution Pipeline

### A. Pipeline Architecture (3 Stages)

```
Stage 1: Opcode Decoder        Stage 2: Main Controller        Stage 3: ALU & Writeback
┌──────────────────────┐       ┌──────────────────────┐       ┌──────────────────────┐
│ Instruction Fetch    │       │ Instruction Decode   │       │ Execution & WB       │
│ (3-word FIFO)        │──────▶│ & Control Signals    │──────▶│ (Execute, Memory)    │
└──────────────────────┘       └──────────────────────┘       └──────────────────────┘
  - Prefetch opcodes           - Generates control              - ALU operations
  - Fault detection              signals                        - Memory read/write
  - PC management              - Hazard checking                - Register writeback
                               - Address calculation
```

### B. Stage 1: Opcode Decoder (Instruction Fetch)

**Components**:
- Asynchronous bus interface for instruction reads
- 3-word deep instruction queue/FIFO
- Opcode validity tracking per instruction
- Program counter management

**Handshake Mechanism**:
- Master (Control) requests: `OW_REQ` (opcode word)
- Slave (Decoder) acknowledges: `OPD_ACK`
- Data valid signal: `OW_VALID`

**Key Insight**: This stage prefetches instructions into a small FIFO, allowing the next instruction to be decoded while the current one executes.

---

## 3. Instruction Execution Pipeline - Stage 2: Main Control

### File
- **File**: `wf68k30L_control.vhd` (2,533 lines)
- **Purpose**: Central control unit managing instruction execution

### A. Dual State Machine Architecture

```vhdl
type FETCH_STATES is (
    START_OP,           -- Wait for instruction ready
    CALC_AEFF,          -- Calculate effective address
    FETCH_DISPL,        -- Fetch displacement extension word
    FETCH_EXWORD_1,     -- Fetch extension word 1
    FETCH_D_LO,         -- Fetch 32-bit data (low word)
    FETCH_D_HI,         -- Fetch 32-bit data (high word)
    FETCH_OD_HI,        -- Fetch indexed offset (high)
    FETCH_OD_LO,        -- Fetch indexed offset (low)
    FETCH_ABS_HI,       -- Fetch absolute address (high)
    FETCH_ABS_LO,       -- Fetch absolute address (low)
    FETCH_IDATA_B2,     -- Fetch immediate data B2
    FETCH_IDATA_B1,     -- Fetch immediate data B1
    FETCH_MEMADR,       -- Fetch address from memory
    FETCH_OPERAND,      -- Fetch operand data
    INIT_EXEC_WB,       -- Initialize execution/writeback
    SLEEP,              -- Idle state for STOP instruction
    SWITCH_STATE        -- State for complex operations
);

type EXEC_WB_STATES is (
    IDLE,               -- Waiting for ALU
    EXECUTE,            -- ALU executing
    ADR_PIPELINE,       -- Address calculations in pipeline
    WRITEBACK,          -- Writing results
    WRITE_DEST          -- Writing to destination
);
```

### B. Key Control Flows

1. **Data Hazard Detection**:
   - `ADR_IN_USE`: Marks address registers in use
   - `DR_IN_USE`: Marks data registers in use
   - `UNMARK`: Clears register-in-use flags after writeback
   - Prevents RAW (Read-After-Write) hazards

2. **Request/Acknowledge Handshakes**:
   - `OW_REQ` / `OPD_ACK`: Opcode word
   - `EW_REQ` / `EW_ACK`: Extension word
   - `ALU_INIT` / `ALU_BSY` / `ALU_ACK`: ALU control
   - `DATA_RD` / `DATA_RDY`: Memory read
   - `DATA_WR` / `DATA_RDY`: Memory write

3. **Address Mode Support**:
   - Register direct (Dn, An)
   - Register indirect ((An))
   - Postincrement ((An)+)
   - Predecrement (-(An))
   - Displacement
   - Indexed
   - Absolute
   - PC-relative
   - Immediate

---

## 4. Instruction Execution Pipeline - Stage 3: ALU & Execution

### A. ALU Module
- **File**: `wf68k30L_alu.vhd` (1,264 lines)
- **Purpose**: Arithmetic/logical operations and result generation

**Supported Operations**:
- Arithmetic: ADD, SUB, MULS, MULU, DIVS, DIVU
- Logical: AND, OR, EOR, NOT
- Shift: ASL, ASR, LSL, LSR, ROL, ROR, ROXL, ROXR
- Bit Field: BFCHG, BFCLR, BFEXTS, BFEXTU, BFFFO, BFINS, BFSET, BFTST
- Bit Operations: BCHG, BCLR, BSET, BTST
- Condition Code Updates

**Hardware Implementation**:
```vhdl
-- Multiplication: Single-cycle hardware multiplier
signal RESULT_MUL : std_logic_vector(63 downto 0);

-- Division: State machine (32 cycles for 32-bit operand)
type DIV_STATES is (IDLE, INIT, CALC);
signal DIV_STATE : DIV_STATES;

-- Shift Operations: Standard shifter (up to 32 cycles)
type SHIFT_STATES is (IDLE, RUN);
signal SHIFT_STATE : SHIFT_STATES;

-- Bit Field Operations: Single-cycle hardware
signal RESULT_BITFIELD : std_logic_vector(39 downto 0);
```

**Operand Management**:
- Three 32-bit operand registers (OP1, OP2, OP3)
- Load signals: `LOAD_OP1`, `LOAD_OP2`, `LOAD_OP3`
- Stored in registers for multi-cycle operations

**Status Register (SR) Management**:
- Condition codes (X, N, Z, V, C)
- System bits (S, T, M, I)
- ALU updates CC at appropriate times

---

## 5. Memory Interface

### Bus Interface Module
- **File**: `wf68k30L_bus_interface.vhd` (875 lines)
- **Purpose**: MC68030-compatible asynchronous bus protocol

**Features**:
- Asynchronous bus cycles with DSACK handshake
- Synchronous bus support (STERM)
- Bus arbitration (3-wire and 2-wire modes)
- Read/Write/Opcode cycle differentiation
- Data size encoding (byte, word, long)
- Address error handling
- Exception signaling

**Request Types**:
- `RD_REQ`: Read data
- `WR_REQ`: Write data
- `OPCODE_REQ`: Read instruction

---

## 6. Register Files

### A. Address Register Module
- **File**: `wf68k30L_address_registers.vhd` (678 lines)
- **8 Address Registers** (A0-A7)
- **A7 Aliases**: USP (User Stack Pointer), ISP (Interrupt Stack Pointer), MSP (Master Stack Pointer)
- **Operations**: Read, Write, Increment, Decrement, Auto-increment/decrement modes
- **Addressing**: PC offset management for instruction fetches

### B. Data Register Module
- **File**: `wf68k30L_data_registers.vhd` (137 lines)
- **8 Data Registers** (D0-D7)
- **Operations**: Read, Write
- **Size Handling**: Byte, Word, Long operations with sign extension

---

## 7. Current Architecture: Scalar vs. Superscalar Analysis

### Current Implementation: SCALAR with Optional Pipelining

**Scalar Characteristics**:
1. **Single Instruction Issue**: Only ONE instruction per cycle can be in the main control stage
2. **Sequential Decode**: Instructions decoded in order (D, C, B priority in instruction queue)
3. **Unified ALU**: Single ALU shared by all instructions
4. **Single Register Write Port**: Only one destination can be written per cycle
5. **Single Memory Port**: Only one memory operation per cycle (read OR write)

**Pipelined Aspects**:
```
Cycle 1: Fetch Instr1  Decode Instr0  Execute Instr(-1)
Cycle 2: Fetch Instr2  Decode Instr1  Execute Instr0
Cycle 3: Fetch Instr3  Decode Instr2  Execute Instr1
```

**Optional NO_PIPELINE Mode**: 
- When `NO_PIPELINE = true`, CPU operates in fully scalar (sequential) mode
- Instructions wait for ALU to be idle before execution
- No overlapping of instruction stages

```vhdl
-- From wf68k30L_control.vhd
OW_REQ <= '1' when NO_PIPELINE = true and FETCH_STATE = START_OP and ALU_BSY = '0' else
          '1' when NO_PIPELINE = false and FETCH_STATE = START_OP else '0';
```

---

## 8. Key Limitations for Superscalar Conversion

### A. Structural Bottlenecks

| Component | Current | Superscalar Need |
|-----------|---------|------------------|
| **ALU** | 1 ALU unit | Multiple ALUs (2-4) |
| **Register Ports** | 2 read, 2 write per cycle | 4+ read, 2+ write |
| **Instruction Decode** | 1 decoder per cycle | Parallel decoders |
| **Memory Interface** | 1 read/write port | Multiple independent ports |
| **Control Paths** | Single main controller | Multiple parallel controllers |
| **Issue Width** | 1 instruction/cycle | 2-4 instructions/cycle |

### B. Data Dependency Tracking

**Current Approach**: 
- Register-in-use flags (`ADR_IN_USE`, `DR_IN_USE`)
- Stalls pipeline if register marked in use
- Works for scalar, but inadequate for superscalar

**Required for Superscalar**:
- Register rename tables (map logical to physical registers)
- Scoreboard or centralized issue logic
- Dependency checking across multiple instructions
- Reservation stations for out-of-order execution

### C. Control Flow Issues

**Current Branch Handling**:
- Branch flushes entire instruction pipeline
- PC update blocks instruction fetching
- Works sequentially

**Required for Superscalar**:
- Branch prediction with speculative execution
- Checkpoints for branch misprediction recovery
- Multiple instruction streams management
- Reorder buffer for in-order retirement

### D. State Machine Complexity

**Current FETCH_STATES** (17 states):
- Sequential progression through instruction operand fetching
- 1 main instruction in FETCH phase at a time

**Superscalar Requirements**:
- Multiple independent FETCH state machines
- Parallel operand fetching
- Inter-instruction synchronization

---

## 9. What Would Need to Change for Superscalar

### Phase 1: Instruction Fetch & Decode (HIGH EFFORT)

1. **Parallel Opcode Decoders**:
   ```vhdl
   -- Current: Single decoder
   signal OP : OP_68K;
   
   -- Superscalar (2-way example):
   signal OP_1 : OP_68K;
   signal OP_2 : OP_68K;
   ```
   - Replicate instruction queue management for each decoder
   - Track dependencies between consecutive fetches
   - Implement variable-length instruction alignment

2. **Fetch Width**: Increase from 1 to N instructions per cycle
   - Current: 1 instruction from IPIPE per cycle
   - Required: 2-4 instructions from separate IPIPEs

### Phase 2: Instruction Decode & Issue (HIGH EFFORT)

3. **Dynamic Issue Logic**:
   - **Current**: Sequential issue when conditions met
   - **Required**: Parallel issue logic checking all pending instructions
   - **New Signals**: Issue queue, priority encoder, dispatch logic

4. **Register Renaming** (MANDATORY):
   ```vhdl
   -- Architectural registers (68K standard)
   signal AR : array_of_registers;  -- A0-A7
   signal DR : array_of_registers;  -- D0-D7
   
   -- Physical registers (superscalar addition)
   signal PR : array_of_physical_registers;  -- 2x or more
   signal RENAME_MAP : array_of_rename_tables;  -- Map AR/DR to PR
   ```

5. **Centralized Dependency Tracking**:
   - **Reservation Stations**: Buffer instructions until operands ready
   - **Scoreboards**: Track which physical registers are pending
   - **Common Data Bus**: Broadcast results to all pending instructions

### Phase 3: Execution (MEDIUM EFFORT)

6. **Multiple ALUs**:
   - Create 2-4 independent ALU instances
   - Add ALU arbitration/scheduling logic
   - May require specialized ALUs (integer, multiplier, shifter)

7. **Out-of-Order Execution**:
   - Decouple issue from execution order
   - Independent state machines for each execution unit
   - Result forwarding network (bypass logic)

### Phase 4: Memory Subsystem (MEDIUM EFFORT)

8. **Multiple Memory Ports**:
   - Current: Single read/write port
   - Required: Separate read and write ports, or multiple ports
   - Load/store queue for memory ordering
   - Conflict detection between memory operations

9. **Cache Management**:
   - Current: No cache
   - Superscalar: Almost mandatory
   - L1 I-cache and D-cache
   - Cache coherency protocol if multi-core

### Phase 5: Writeback & Retirement (HIGH EFFORT)

10. **Reorder Buffer (ROB)**:
    - Track instruction order for in-order retirement
    - Temporary storage for results until instruction commits
    - Exception handling based on committed state
    - Rollback capability for mispredictions

11. **Exception Handling Redesign**:
    - Current: Exceptions handled sequentially
    - Required: Speculative state tracking
    - Precise exception reporting with reorder buffer

---

## 10. Complexity Estimates

### Lines of Code Changes

| Component | Current | Superscalar | Effort |
|-----------|---------|-------------|--------|
| Control | 2,533 | 5,000-8,000 | Very High |
| Decoders | 1,332 | 2,664-3,996 | High |
| ALU | 1,264 | 2,000-3,000 | High |
| Register Files | 815 | 2,000-3,000 | High |
| Bus Interface | 875 | 1,500-2,500 | Medium |
| **Total** | **~9,400** | **~20,000-30,000** | **3-4x increase** |

### Critical Path Analysis

**Current Critical Paths**:
1. Instruction decode → Control signals generation (~2-3 FFs)
2. Operand fetch → ALU result (~3-4 FFs)
3. Memory address → Data valid (~4-5 FFs)

**Superscalar Additions**:
1. Issue logic (dependency checking): +2-3 FFs
2. Register rename logic: +1-2 FFs
3. Result forwarding: +1-2 FFs
4. Reorder buffer management: +2-3 FFs

**Impact**: Clock frequency would likely decrease 20-40% due to increased complexity

---

## 11. Implementation Strategy Recommendations

### Option A: Modest Enhancement (2-issue)
- **Effort**: 12-18 months
- **Increase**: 2x instruction issue
- **Complexity**: Dual decoders, dual ALUs
- **Clock**: ~10-15% reduction
- **Area**: ~2-2.5x increase

### Option B: Full 4-issue Superscalar
- **Effort**: 24-36 months
- **Increase**: 4x instruction issue
- **Complexity**: Full dependency matrix, reorder buffer
- **Clock**: ~20-30% reduction
- **Area**: ~3-4x increase

### Option C: Incremental Pipeline (Lower Risk)
- **Current**: 3-stage pipeline
- **Enhancement**: 5-7 stage pipeline
- **Effort**: 6-9 months
- **Increase**: Better clock rate (20-30% higher)
- **Complexity**: Moderate (hazard detection more complex)
- **Area**: ~1.2-1.5x increase
- **Benefit**: Easier than superscalar, simpler cache integration

---

## 12. Key Data Hazard Resolution Mechanisms

### Current Implementation

```vhdl
-- Register-in-use tracking (from wf68k30L_control.vhd)
signal ADR_MARK_USED : bit;      -- Mark AR as in use
signal ADR_IN_USE : bit;          -- AR is in use (feedback)
signal DR_MARK_USED : bit;        -- Mark DR as in use  
signal DR_IN_USE : bit;           -- DR is in use (feedback)

-- Stall on hazard
if ADR_IN_USE = '1' then
    -- Do not start new operation using this AR
    FETCH_STATE <= NEXT_FETCH_STATE;  -- Stall
else
    -- Can proceed with operation
    FETCH_STATE <= INIT_EXEC_WB;  -- Execute
end if;
```

### Superscalar Requirement

```vhdl
-- Dependency matrix for N instructions
signal INST_DEPS : array(0 to N-1, 0 to N-1) of boolean;
-- True if instruction I depends on instruction J

-- Register file physical locations
signal REG_RENAME : array(0 to 15) of integer;  -- AR/DR to physical reg

-- Scoreboard for register readiness
signal REG_READY : array(0 to 31) of std_logic;  -- Physical reg ready
```

---

## 13. Summary: Current Architecture Strengths & Weaknesses

### Strengths
1. **Clean 3-stage pipeline design**: Modular and relatively understandable
2. **Comprehensive hazard detection**: Register-in-use flags prevent most data hazards
3. **Rich addressing modes**: Full MC68030 instruction set support
4. **Well-documented code**: Extensive revision history and comments
5. **Scalable**: NO_PIPELINE switch allows falling back to scalar mode

### Weaknesses (for Superscalar Conversion)
1. **Single-issue bottleneck**: Fundamental architecture is 1-instruction-per-cycle
2. **Monolithic control structure**: Main controller tightly couples all stages
3. **Limited parallelism**: Register file and memory interface serial
4. **No speculative execution**: Branch handling requires pipeline flush
5. **No out-of-order capability**: Instruction order strictly maintained

---

## Conclusion

The WF68K30L is a well-designed scalar CISC processor with optional pipelining. Converting it to superscalar would require:

1. **Massive restructuring** of the control unit (currently 2,533 lines)
2. **Multiplication** of functional units (ALUs, decoders)
3. **New mechanisms** for register renaming, scoreboarding, and reorder buffers
4. **Significant testing** due to increased complexity

**Realistic Effort**: 18-36 months for a 2-4 issue superscalar design, with 3-4x code growth and 20-40% clock frequency reduction. An incremental approach (deeper pipeline rather than superscalar) would be more practical and provide better risk/reward ratio.

