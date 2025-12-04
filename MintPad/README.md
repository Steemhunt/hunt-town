# Mintpad

A platform where HUNT holders can use their daily Mint Power (MP) to mint HUNT-backed assets on the Mint Club V2 Bond contract.

## 🧪 Running Tests

```sh
npx hardhat test
```

## 🚀 Deploy

```sh
npx hardhat keystore set BASE_PRIVATE_KEY
npx hardhat ignition deploy ignition/modules/Mintpad.ts --network base --verify --reset

# if verification failed
npx hardhat ignition verify chain-8453 --network base
```

## 🔵 Deployed Contracts on Base

- Mintpad: [0xfb51D2120c27bB56D91221042cb2dd2866a647fE](https://basescan.org/address/0xfb51D2120c27bB56D91221042cb2dd2866a647fE#code)
