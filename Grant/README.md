# Hunt Grant

An experimental grant DAO project in the form of tipping, utilizing the Farcaster community.

## Run Unit Tests

```sh
npx hardhat test
```

## Community Audit

[COMMUNITY_AUDIT.md](./COMMUNITY_AUDIT.md)

## Deploy

The test version is deployed on the Base mainnet, with the following test token and Mini Building NFT:

- Test Token: https://mint.club/token/base/FREE (CS: 0xC435B542aCB241185c72D3653447E070994Da59f)
- Test Building - https://mint.club/nft/base/TBUILDING (CS: 0x2bff5CA9c87309AB3fC0145A2c9617eFa2Cc5D7b)

```sh
npx hardhat ignition deploy ignition/modules/BuilderGrant.ts --network base --parameters ignition/test-params.json --verify
npx hardhat ignition deploy ignition/modules/TipperGrant.ts --network base --parameters ignition/test-params.json --verify
```

## Test Contracts

- BuilderGrant: https://basescan.org/address/0x6d1f4ecd17ddA7fb39C56Da566b66d63f06671d9#code
- TipperGrant: https://basescan.org//address/0x50d73a2e3Da38F6598368512A751F4AF8f4a6b54#code
