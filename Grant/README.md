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
npx hardhat ignition deploy ignition/modules/BuilderGrant.ts --network base --parameters ignition/test-params.json --verify --reset
npx hardhat ignition deploy ignition/modules/TipperGrant.ts --network base --parameters ignition/test-params.json --verify --reset
```

## Test Contracts

- BuilderGrant: https://basescan.org//address/0x3595fcB2e6BD4569b3e2D3bfDB5023d0621C9C4F#code
- TipperGrant: https://basescan.org//address/0x2b855235e5B28E8b1bF1d33e3db10c27E7C3ab32#code
