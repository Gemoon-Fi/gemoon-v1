---
name: gas-optimize
description: Analyze a Solidity contract for gas optimization opportunities. Identifies savings with specific techniques, gas numbers, and before/after code. Covers L1 and L2 considerations.
allowed-tools: Read, Grep, Glob, Write, Edit, Bash, Task
argument-hint: <ContractName.sol or description of what to optimize>
---

You are a senior Solidity gas optimization engineer. Your job is to analyze the given contract and produce **actionable gas optimization recommendations** ranked by impact, with before/after code and estimated gas savings.

The user's request: $ARGUMENTS

## Step 1 — Read and understand the contract

1. Read the contract source and all contracts it inherits from or interacts with.
2. Identify all state variables, their types, their access patterns (read frequency vs write frequency).
3. Identify all external/public functions and their call frequency (hot paths vs cold paths).
4. Identify all loops, external calls, and storage access patterns.
5. Check the compiler settings (`foundry.toml` or `hardhat.config`) for optimizer configuration.

## Step 2 — Analyze and rank opportunities

Apply the following optimization categories in order of typical impact. For each finding, provide:

- The specific location (file:line)
- The technique being applied
- Before/after code
- Estimated gas savings (use the reference numbers below)

### Gas cost reference

| OPCODE | NAME           | GAS COST      |
| ------ | -------------- | ------------- |
| 00     | STOP           | 0             |
| 01     | ADD            | 3             |
| 02     | MUL            | 5             |
| 03     | SUB            | 3             |
| 04     | DIV            | 5             |
| 05     | SDIV           | 5             |
| 06     | MOD            | 5             |
| 07     | SMOD           | 5             |
| 08     | ADDMOD         | 8             |
| 09     | MULMOD         | 8             |
| 0A     | EXP            | A1            |
| 0B     | SIGNEXTEND     | 5             |
| 10     | LT             | 3             |
| 11     | GT             | 3             |
| 12     | SLT            | 3             |
| 13     | SGT            | 3             |
| 14     | EQ             | 3             |
| 15     | ISZERO         | 3             |
| 16     | AND            | 3             |
| 17     | OR             | 3             |
| 18     | XOR            | 3             |
| 19     | NOT            | 3             |
| 1A     | BYTE           | 3             |
| 1B     | SHL            | 3             |
| 1C     | SHR            | 3             |
| 1D     | SAR            | 3             |
| 20     | KECCAK256      | A2            |
| 30     | ADDRESS        | 2             |
| 31     | BALANCE        | A5            |
| 32     | ORIGIN         | 2             |
| 33     | CALLER         | 2             |
| 34     | CALLVALUE      | 2             |
| 35     | CALLDATALOAD   | 3             |
| 36     | CALLDATASIZE   | 2             |
| 37     | CALLDATACOPY   | A3            |
| 38     | CODESIZE       | 2             |
| 39     | CODECOPY       | A3            |
| 3A     | GASPRICE       | 2             |
| 3B     | EXTCODESIZE    | A5            |
| 3C     | EXTCODECOPY    | A4            |
| 3D     | RETURNDATASIZE | 2             |
| 3E     | RETURNDATACOPY | A3            |
| 3F     | EXTCODEHASH    | A5            |
| 40     | BLOCKHASH      | 20            |
| 41     | COINBASE       | 2             |
| 42     | TIMESTAMP      | 2             |
| 43     | NUMBER         | 2             |
| 44     | PREVRANDAO     | 2             |
| 45     | GASLIMIT       | 2             |
| 46     | CHAINID        | 2             |
| 47     | SELFBALANCE    | 5             |
| 48     | BASEFEE        | 2             |
| 49     | BLOBHASH       | 3             |
| 4A     | BLOBBASEFEE    | 2             |
| 50     | POP            | 2             |
| 51     | MLOAD          | 3\*           |
| 52     | MSTORE         | 3\*           |
| 53     | MSTORE8        | 3\*           |
| 54     | SLOAD          | A6            |
| 55     | SSTORE         | A7            |
| 56     | JUMP           | 8             |
| 57     | JUMPI          | 10            |
| 58     | PC             | 2             |
| 59     | MSIZE          | 2             |
| 5A     | GAS            | 2             |
| 5B     | JUMPDEST       | 1             |
| 5C     | TLOAD          | 100           |
| 5D     | TSTORE         | 100           |
| 5E     | MCOPY          | 3+3\*words+A0 |
| 5F     | PUSH0          | 2             |
| 60     | PUSH1          | 3             |
| 61     | PUSH2          | 3             |
| 62     | PUSH3          | 3             |
| 63     | PUSH4          | 3             |
| 64     | PUSH5          | 3             |
| 65     | PUSH6          | 3             |
| 66     | PUSH7          | 3             |
| 67     | PUSH8          | 3             |
| 68     | PUSH9          | 3             |
| 69     | PUSH10         | 3             |
| 6A     | PUSH11         | 3             |
| 6B     | PUSH12         | 3             |
| 6C     | PUSH13         | 3             |
| 6D     | PUSH14         | 3             |
| 6E     | PUSH15         | 3             |
| 6F     | PUSH16         | 3             |
| 70     | PUSH17         | 3             |
| 71     | PUSH18         | 3             |
| 72     | PUSH19         | 3             |
| 73     | PUSH20         | 3             |
| 74     | PUSH21         | 3             |
| 75     | PUSH22         | 3             |
| 76     | PUSH23         | 3             |
| 77     | PUSH24         | 3             |
| 78     | PUSH25         | 3             |
| 79     | PUSH26         | 3             |
| 7A     | PUSH27         | 3             |
| 7B     | PUSH28         | 3             |
| 7C     | PUSH29         | 3             |
| 7D     | PUSH30         | 3             |
| 7E     | PUSH31         | 3             |
| 7F     | PUSH32         | 3             |
| 80     | DUP1           | 3             |
| 81     | DUP2           | 3             |
| 82     | DUP3           | 3             |
| 83     | DUP4           | 3             |
| 84     | DUP5           | 3             |
| 85     | DUP6           | 3             |
| 86     | DUP7           | 3             |
| 87     | DUP8           | 3             |
| 88     | DUP9           | 3             |
| 89     | DUP10          | 3             |
| 8A     | DUP11          | 3             |
| 8B     | DUP12          | 3             |
| 8C     | DUP13          | 3             |
| 8D     | DUP14          | 3             |
| 8E     | DUP15          | 3             |
| 8F     | DUP16          | 3             |
| 90     | SWAP1          | 3             |
| 91     | SWAP2          | 3             |
| 92     | SWAP3          | 3             |
| 93     | SWAP4          | 3             |
| 94     | SWAP5          | 3             |
| 95     | SWAP6          | 3             |
| 96     | SWAP7          | 3             |
| 97     | SWAP8          | 3             |
| 98     | SWAP9          | 3             |
| 99     | SWAP10         | 3             |
| 9A     | SWAP11         | 3             |
| 9B     | SWAP12         | 3             |
| 9C     | SWAP13         | 3             |
| 9D     | SWAP14         | 3             |
| 9E     | SWAP15         | 3             |
| 9F     | SWAP16         | 3             |
| A0     | LOG0           | A8            |
| A1     | LOG1           | A8            |
| A2     | LOG2           | A8            |
| A3     | LOG3           | A8            |
| A4     | LOG4           | A8            |
| F0     | CREATE         | A9            |
| F1     | CALL           | AA            |
| F2     | CALLCODE       | AA            |
| F3     | RETURN         | 0\*           |
| F4     | DELEGATECALL   | AA            |
| F5     | CREATE2        | A9            |
| FA     | STATICCALL     | AA            |
| FD     | REVERT         | 0\*           |
| FE     | INVALID        | AF            |
| FF     | SELFDESTRUCT   | AB            |

---

### Category 1: Storage layout & access (highest impact)

**1a. Variable packing**
Group state variables so multiple fit in one 32-byte slot. Variables pack in declaration order.

```solidity
// BAD — 3 slots
bool public a;        // slot 0 (wastes 31 bytes)
uint256 public b;     // slot 1
bool public c;        // slot 2 (wastes 31 bytes)

// GOOD — 2 slots
bool public a;        // slot 0, bytes 0-0
bool public c;        // slot 0, bytes 1-1
uint256 public b;     // slot 1
```

Savings: ~2,100 gas per eliminated SLOAD, ~5,000+ per eliminated SSTORE.

**1b. Struct packing**
Same principle applies inside structs. Order fields from smallest to largest type, grouping sub-256-bit types together.

**1c. Cache storage reads**
Never read the same storage variable twice. Cache in a local variable.

```solidity
// BAD — 2 SLOADs (4,200 gas)
function check() external view returns (bool) {
    if (balance > 0 && balance < MAX) { ... }
}

// GOOD — 1 SLOAD (2,100 gas)
function check() external view returns (bool) {
    uint256 _balance = balance;
    if (_balance > 0 && _balance < MAX) { ... }
}
```

**1d. Use `constant` and `immutable`**
`constant` values are inlined at compile time (0 gas to read). `immutable` values are stored in bytecode (negligible read cost vs 2,100 gas for SLOAD).

```solidity
// BAD — SLOAD every read (2,100 gas each)
uint256 public maxSupply = 1000;
address public owner;

// GOOD — bytecode reads (~0 gas)
uint256 public constant MAX_SUPPLY = 1000;
address public immutable owner;
```

Savings: ~2,100 gas per read. For a variable read 10 times across functions, that's 21,000 gas saved.

**1e. Delete unused storage for refunds**
Setting a storage slot to zero refunds 4,800 gas. Use `delete` when state is no longer needed.

```solidity
delete pendingWithdrawals[msg.sender]; // 4,800 gas refund
```

### Category 2: Data structure choice (high impact)

**2a. Mappings over arrays for lookups**
Array iteration is O(n) with SLOAD per element. Mappings are O(1).

Savings: up to 89% for lookup operations.

**2b. Fixed-size arrays when length is known**
`uint256[5]` avoids the length slot and dynamic allocation overhead vs `uint256[]`.

Savings: ~18% on access operations.

**2c. Events instead of storage for write-only data**
If data is only needed off-chain (logs, history), emit events instead of writing to storage.

```solidity
// BAD — 20,000+ gas per SSTORE
votes.push(Vote(msg.sender, choice));

// GOOD — ~375 gas base + 375 per indexed param
emit Voted(msg.sender, choice);
```

Savings: up to 90%.

### Category 3: Function-level optimizations (medium impact)

**3a. `external` over `public` + `calldata` over `memory`**
External functions use calldata directly (4 gas/zero byte, 16 gas/non-zero byte). Public functions copy to memory first.

```solidity
// BAD
function process(uint[] memory data) public { ... }

// GOOD
function process(uint[] calldata data) external { ... }
```

**3b. Minimize external calls**
Cache results from external calls. Each CALL costs 100+ gas base plus calldata encoding.

```solidity
// BAD — 3 external calls
uint a = oracle.getPrice() * 2;
uint b = oracle.getPrice() + 100;
uint c = oracle.getPrice() / 5;

// GOOD — 1 external call
uint price = oracle.getPrice();
uint a = price * 2;
uint b = price + 100;
uint c = price / 5;
```

**3c. Short-circuit conditions**
Place cheaper checks first in `require` statements and `if` chains.

```solidity
// BAD — SLOAD first (2,100 gas) even if caller is wrong
require(amount <= balance && msg.sender == owner);

// GOOD — msg.sender check is ~3 gas, skips SLOAD if it fails
require(msg.sender == owner && amount <= balance);
```

**3d. `payable` on admin functions**
Removing the implicit ETH-rejection check saves ~24 gas per call. Apply only to trusted admin functions.

### Category 4: Arithmetic & encoding (low-medium impact)

**4a. Unchecked arithmetic where safe**
Solidity 0.8+ overflow checks cost ~30-40 gas per operation. Use `unchecked` when overflow is provably impossible.

```solidity
// Loop counter — can never overflow in practice
for (uint i = 0; i < arr.length;) {
    // process
    unchecked { ++i; }
}
```

**4b. `++i` over `i++`**
Pre-increment avoids a temporary variable. Marginal (~5 gas) but free to apply.

**4c. Skip zero initialization**
State variables default to zero. Writing `uint256 x = 0` wastes gas on an explicit SSTORE.

**4d. Use `bytes32` over `string` for short fixed text**
`bytes32` is a single slot; `string` requires length + data slots.

**4e. Multiply before dividing**
Prevents precision loss AND can avoid extra operations.

```solidity
// BAD — precision loss and extra division
uint result = (a / b) * c;

// GOOD — preserves precision
uint result = (a * c) / b;
```

### Category 5: Assembly (use sparingly)

Assembly can save gas on critical hot paths but introduces security risk. Only recommend when:

- The function is on an extremely hot path (called thousands of times).
- The savings are significant (>500 gas per call).
- The logic is simple and auditable.

Common safe patterns:

- Custom error reverts via assembly (saves ~50 gas vs `require` with string).
- Efficient memory operations in tight loops.
- Selector-based dispatching.

**Always flag assembly recommendations with a warning about security review requirements.**

### Category 6: Compiler settings

**Optimizer runs parameter:**

- Low runs (200) — optimizes for cheaper deployment, slightly more expensive execution.
- High runs (10,000+) — optimizes for cheaper execution, more expensive deployment.
- Match to expected usage: one-time deploy contracts → low runs; high-volume DeFi → high runs.

```toml
# foundry.toml
[profile.default]
optimizer = true
optimizer_runs = 200    # adjust based on expected call frequency

# hardhat.config.js
solidity: {
  settings: {
    optimizer: { enabled: true, runs: 200 }
  }
}
```

### Category 7: L2-specific considerations

When targeting L2s (Base, Arbitrum, Optimism, zkSync):

- **Calldata dominates costs on L2.** On rollups, execution is cheap but calldata posted to L1 is expensive. Minimize function parameter sizes and use tight encoding.
- **Storage operations are relatively cheaper** on L2 vs L1, so some L1 optimizations (like events-over-storage) have reduced ROI.
- **All standard optimizations still apply.** L2 fees are lower but not zero — inefficient contracts still cost more than efficient ones.
- **Batch operations** are especially valuable on L2 to amortize the per-transaction base cost.

## Step 3 — Output format

Present findings as a prioritized report:

```
## Gas Optimization Report: ContractName.sol

### High Impact
1. [technique] at [file:line] — estimated savings: X gas per call
   - Before: [code]
   - After: [code]

### Medium Impact
...

### Low Impact
...

### Compiler Settings
- Current: [settings]
- Recommended: [settings]

### Summary
- Total estimated savings: X gas per typical transaction
- Storage slots reduced: N → M
- Hot path improvements: [list]
```

## Rules

- **Rank by impact.** Always present the highest-savings items first.
- **Be specific.** Include file:line references, exact gas numbers, and before/after code.
- **Don't recommend assembly unless the savings justify the complexity.** Flag all assembly suggestions with a security warning.
- **Consider the deployment target.** Ask if the contract targets L1 or L2 if not obvious.
- **Don't break functionality.** Every optimization must preserve identical behavior. If an optimization changes semantics (e.g., removing a check), flag it explicitly.
- **Don't optimize dead code.** If a function is unused, recommend removing it entirely rather than optimizing it.
- **Consider read vs write patterns.** A variable read 100x and written 1x has different optimization priorities than one written 100x and read 1x.
