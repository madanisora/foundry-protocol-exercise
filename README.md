# foundry-protocol-exercise

> **Lending Protocol** — Transparent Proxy pattern, inspired by Aave V2

---

## Struktur Project

```
foundry-protocol-exercise/
├── src/
│   ├── TransparentProxy.sol   ← EIP-1967 proxy (delegatecall)
│   ├── LendingPool.sol        ← Implementation V1
│   └── LendingPoolV2.sol      ← Implementation V2 (+ interest)
├── test/
│   └── LendingProtocol.t.sol  ← Full test suite
└── script/
    └── Deploy.s.sol           ← Deploy + Upgrade scripts
```

---

## Setup

```bash
forge init --no-commit  # jika belum ada
forge install foundry-rs/forge-std --no-commit
forge test -vvv
```

---

## Konsep yang Dipelajari

### 1. Transparent Proxy (EIP-1967)

```
User ──► Proxy ──delegatecall──► LendingPool (logic)
              ↑                        │
         stores state          runs code only
         (deposits, borrows)
```

**Key insight:** Kode dari `LendingPool` berjalan, tapi storage yang berubah adalah milik `Proxy`.

```solidity
// Di Proxy fallback():
assembly {
    delegatecall(gas(), implementation, ...)
}
```

### 2. Storage Layout — Aturan Wajib Upgrade

```
Slot 0: owner          ← V1 ✓  V2 ✓  (jangan pindah!)
Slot 1: paused         ← V1 ✓  V2 ✓
Slot 2: totalDeposits  ← V1 ✓  V2 ✓
...
NEW → Slot 5: lastUpdateTimestamp  ← V2 tambah di bawah ✓
```

**JANGAN PERNAH** reorder variable saat upgrade → storage korup!

### 3. Protocol Logic

```
Deposit 4 ETH
    │
    └── maxBorrow = 4 ETH × 75% = 3 ETH
              │
              └── healthFactor = (deposit × 80%) / borrow
                                = (4 × 80) / 3 = 106 ✓ (aman)

Jika harga turun → deposit efektif < threshold:
    healthFactor < 100 → bisa dilikuidasi!
```

---

## Test Cases

| Test | Yang Diuji |
|------|-----------|
| `test_ProxyStorageIsolation` | State impl selalu kosong |
| `test_EIP1967Slots` | Impl + admin di slot yang benar |
| `test_OnlyAdminCanUpgrade` | Access control upgrade |
| `test_BorrowWithinLTV` | Borrow max 75% collateral |
| `test_Liquidation` | Posisi unhealthy bisa dilikuidasi |
| `test_UpgradePreservesState` | State V1 tetap ada setelah upgrade |
| `test_V2InterestAccrues` | 10% APR dihitung per detik |
| `testFuzz_BorrowNeverExceedsLTV` | Fuzz: LTV tidak pernah dilanggar |

---

## Jalankan Test

```bash
# Semua test
forge test -vvv

# Test spesifik
forge test --match-test test_UpgradePreservesState -vvv

# Fuzz dengan lebih banyak runs
forge test --match-test testFuzz -vvv --fuzz-runs 1000

# Gas report
forge test --gas-report
```

---

## TODOs untuk Latihan Lanjutan

- [ ] Tambah `ProxyAdmin` contract (pisah admin dari deployer)
- [ ] Implementasi price oracle (mock Chainlink)
- [ ] Tambah ERC20 token sebagai collateral (bukan hanya ETH)


