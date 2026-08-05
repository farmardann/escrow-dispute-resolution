# 🔐 Escrow Dispute Resolution

**A secure, transparent smart contract escrow system with built-in dispute resolution — built on Foundry.**

This project provides a decentralized escrow mechanism where funds are held safely until both parties fulfill their obligations. When disagreements arise, a structured dispute resolution process ensures fair and verifiable outcomes — all on-chain, all trustless.

> ⚠️ **Status: Masih dalam pengembangan (Work in Progress)** — Proyek ini masih aktif dikembangkan. Fitur, kontrak, dan dokumentasi dapat berubah sewaktu-waktu.

---

## ✨ Features

- **Trustless Escrow** — Funds are locked in a smart contract, not held by any intermediary.
- **Dispute Resolution** — A clear, on-chain process for handling disagreements between parties.
- **Transparent & Auditable** — Every transaction and resolution is recorded on the blockchain.
- **Built with Foundry** — Blazing-fast development, testing, and deployment toolkit for Ethereum.

---

## 🚀 Getting Started

### Prerequisites

Make sure you have [Foundry](https://book.getfoundry.sh/) installed:

```shell
$ curl -L https://foundry.paradigm.xyz | bash
$ foundryup
```

Then install the project dependencies:

```shell
$ forge install
```

---

## 🛠️ Usage

### Build

Compile the smart contracts:

```shell
$ forge build
```

### Test

Run the test suite:

```shell
$ forge test
```

### Format

Format the Solidity source code:

```shell
$ forge fmt
```

### Gas Snapshots

Generate gas usage snapshots:

```shell
$ forge snapshot
```

### Anvil

Spin up a local Ethereum node for development:

```shell
$ anvil
```

### Deploy

Deploy the contract to a network:

```shell
$ forge script script/Counter.s.sol:CounterScript --rpc-url <your_rpc_url> --private-key <your_private_key>
```

### Cast

Interact with EVM smart contracts, send transactions, and fetch chain data:

```shell
$ cast <subcommand>
```

### Help

Get help for any of the Foundry tools:

```shell
$ forge --help
$ anvil --help
$ cast --help
```

---

## 📁 Project Structure

```
├── src/          # Smart contract source code
├── test/         # Test suite
├── script/       # Deployment scripts
└── lib/          # Dependencies (e.g., forge-std)
```

---

## 📚 Documentation

For full documentation on Foundry, visit: https://book.getfoundry.sh/