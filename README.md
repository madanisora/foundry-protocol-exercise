# foundry-protocol-exercise

An educational Solidity project for studying proxy storage, upgrades, collateralized borrowing, repayment, liquidation, and simple interest accounting. **It is not audited, is not production-ready, and must never be used with real funds.** The simplified model has no price oracle, token collateral, interest-rate model, governance, or production-grade risk controls.

## Project structure

```text
foundry-protocol-exercise/
├── src/
│   ├── TransparentProxy.sol   # Minimal EIP-1967 transparent proxy for study
│   ├── LendingPool.sol        # V1 implementation
│   └── LendingPoolV2.sol      # V2 implementation with simple interest
├── test/
│   └── LendingProtocol.t.sol  # Unit, upgrade, accounting, and fuzz tests
├── script/
│   └── Deploy.s.sol           # Local/deployment script examples
├── foundry.toml
└── .gitignore
```

## Free local setup

Install Foundry from its official installation instructions, then in this repository:

```bash
forge install foundry-rs/forge-std --no-commit
forge build
forge test -vvv
```

Run selected tests:

```bash
forge test --match-test test_V2PartialInterestPaymentIsRetained -vvv
forge test --match-test test_V2LiquidationClearsPrincipalAccounting -vvv
forge test --match-test testFuzz -vvv --fuzz-runs 1000
forge test --gas-report
```

The repository does not vendor `forge-std`; the setup command obtains it as a development dependency. Record the Foundry, solc, and dependency versions when publishing a test result.

## Storage layout

V1 and V2 must preserve the declaration order and types of every V1 state variable.

| Slot | V1 / V2 storage |
|---|---|
| 0 | `owner` and `paused` (packed) |
| 1 | `totalDeposits` |
| 2 | `totalBorrows` |
| 3 | `version` |
| 4 | `deposits` mapping anchor |
| 5 | `borrows` mapping anchor |

V2 appends its own variables without moving V1 storage:

| Slot | V2 addition |
|---|---|
| 6 | `lastUpdateTimestamp` |
| 7 | `accumulatedInterest` (interest actually paid or settled) |
| 8 | `borrowTimestamps` mapping anchor |
| 9 | `accruedInterest` mapping anchor |

A mapping's entries are stored at hash-derived locations; the mapping's declared slot is its anchor, not the storage slot of each user value.

## Model assumptions and limitations

- Collateral and debt are both denominated in ETH. The project has no oracle; tests that alter storage do so only to simulate a changed state.
- V1 tracks principal only and does not charge interest.
- V2 `totalBorrows` tracks outstanding **principal**, not principal plus unpaid interest. `totalOwed(user)` includes principal and that user's interest.
- V1 borrowers have no interest timestamp. After upgrading, each legacy borrower must call `syncBorrow()` to start accruing V2 interest. The migration intentionally does not backdate interest.
- V2 applies simple 10% APR interest, not compounding interest. Partial repayment pays interest first, then principal; unpaid interest is carried forward.
- Liquidation uses a fixed 5% collateral bonus and an oversimplified health factor. It is a teaching model, not an economic design recommendation.
- The proxy is a minimal exercise implementation. Production systems should use a widely reviewed proxy implementation, audited upgrade controls, storage-layout validation, and comprehensive invariant testing.

## What the tests cover

- Proxy storage isolation and EIP-1967 slots.
- V1 storage mapping anchors and transparent-admin fallback restriction.
- Deposit, withdrawal, borrowing, LTV, repayment/refund, pause, and liquidation accounting.
- V1-to-V2 storage preservation and migration.
- V2 interest accrual, partial interest repayment, additional borrowing, legacy borrow synchronization, and liquidation accounting.
- Fuzz checks for deposit and LTV boundaries.

A passing local test suite would only establish that these test cases pass under the recorded toolchain; it would not establish protocol security.
