# Hunt Town
Hunt Town is a web3 builders' guild where builders come together to contribute to the expansion of web3 culture and products.

## 📄 Contracts
- Building.sol: A NFT with ERC721 interface, that can only be minted by locking-up 1,000 HUNT tokens on the TownHall contract for 1 year.
  - Locked-up tokens are returned when the NFT gets burned after the lock-up period
  - Building NFT is a membership pass required to enter the Hunt Town Discord group
  - Members with verified Building NFTs will receive BUILD points in the Hunt Town Discord group everyday
- TownHall.sol: A front facing contract that mints / burns Building NFTs.

## 🧪 Test
```bash
npx hardhat test
```

## ⚙️ Deploy
```bash
npx hardhat run scripts/deploy.js
```

## ⛽️ Gas Consumption
```
·---------------------------------------|---------------------------|---------------|-----------------------------·
|         Solc version: 0.8.17          ·  Optimizer enabled: true  ·  Runs: 20000  ·  Block limit: 30000000 gas  │
········································|···························|···············|······························
|  Methods                              ·                20 gwei/gas                ·       1197.50 usd/eth       │
··················|·····················|·············|·············|···············|···············|··············
|  Contract       ·  Method             ·  Min        ·  Max        ·  Avg          ·  # calls      ·  usd (avg)  │
··················|·····················|·············|·············|···············|···············|··············
|  Building       ·  approve            ·      48607  ·      48619  ·        48613  ·            2  ·       1.16  │
··················|·····················|·············|·············|···············|···············|··············
|  Building       ·  burn               ·      45720  ·      50129  ·        46602  ·            5  ·       1.12  │
··················|·····················|·············|·············|···············|···············|··············
|  Building       ·  safeMint           ·     124729  ·     152729  ·       126596  ·           15  ·       3.03  │
··················|·····················|·············|·············|···············|···············|··············
|  Building       ·  setTownHall        ·          -  ·          -  ·        46231  ·           21  ·       1.11  │
··················|·····················|·············|·············|···············|···············|··············
|  Building       ·  transferFrom       ·          -  ·          -  ·        65287  ·            2  ·       1.56  │
··················|·····················|·············|·············|···············|···············|··············
|  ERC20          ·  approve            ·          -  ·          -  ·        48585  ·            4  ·       1.16  │
··················|·····················|·············|·············|···············|···············|··············
|  HuntTokenMock  ·  approve            ·      46248  ·      46260  ·        46251  ·           24  ·       1.11  │
··················|·····················|·············|·············|···············|···············|··············
|  HuntTokenMock  ·  transfer           ·      51495  ·      51507  ·        51498  ·           28  ·       1.23  │
··················|·····················|·············|·············|···············|···············|··············
|  TownHall       ·  burn               ·      68846  ·      86936  ·        71107  ·            8  ·       1.70  │
··················|·····················|·············|·············|···············|···············|··············
|  TownHall       ·  mint               ·     192720  ·     208720  ·       195889  ·           23  ·       4.69  │
··················|·····················|·············|·············|···············|···············|··············
|  TownHallZap    ·  convertAndMint     ·     327132  ·    1660878  ·       660569  ·            4  ·      15.82  │
··················|·····················|·············|·············|···············|···············|··············
|  TownHallZap    ·  convertETHAndMint  ·     320603  ·     329560  ·       324186  ·            5  ·       7.76  │
··················|·····················|·············|·············|···············|···············|··············
|  TownHallZap    ·  mintBulk           ·          -  ·          -  ·      1535836  ·            5  ·      36.78  │
··················|·····················|·············|·············|···············|···············|··············
|  Deployments                          ·                                           ·  % of limit   ·             │
········································|·············|·············|···············|···············|··············
|  Building                             ·          -  ·          -  ·      2253552  ·        7.5 %  ·      53.97  │
········································|·············|·············|···············|···············|··············
|  HuntTokenMock                        ·          -  ·          -  ·      1140679  ·        3.8 %  ·      27.32  │
········································|·············|·············|···············|···············|··············
|  TownHall                             ·     730247  ·     730271  ·       730250  ·        2.4 %  ·      17.49  │
········································|·············|·············|···············|···············|··············
|  TownHallZap                          ·          -  ·          -  ·      1190684  ·          4 %  ·      28.52  │
·---------------------------------------|-------------|-------------|---------------|---------------|-------------·
```
