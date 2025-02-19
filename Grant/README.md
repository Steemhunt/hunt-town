# Hunt Grant

An experimental grant DAO project in the form of tipping, utilizing the Farcaster community.

## 🧪 Run Unit Tests

```sh
npx hardhat test
```

## 🔍 Community Audit

- Announcement: [COMMUNITY_AUDIT.md](./COMMUNITY_AUDIT.md)
- Results: https://github.com/Steemhunt/hunt-town/issues/11

## 🚀 Deploy

```sh
npx hardhat ignition deploy ignition/modules/BuilderGrant.ts --network base --parameters ignition/prod-params.json --verify --reset
npx hardhat ignition deploy ignition/modules/TipperGrant.ts --network base --parameters ignition/prod-params.json --verify

# BuilderGrantV2 deployment
npx hardhat ignition deploy ignition/modules/BuilderGrantV2.ts --network base --parameters ignition/prod-params.json --verify --reset
```

## 🔵 Deployed Contracts on Base

- BuilderGrant: https://basescan.org//address/0x266bdC0c52B3F2DE94EBe34be270e2615bFb594F#code
- TipperGrant: https://basescan.org//address/0x2eF7f539271E3457DBbBDDe78E14DF434D887a69#code
- BuilderGrantV2: https://basescan.org//address/0x9B63FE4AE7522d89B67f216070F420F19d4f5D34#code
