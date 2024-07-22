# HUNT Grant - Community Contract Audit

HUNT Grant Season 1 is wrapping up, and we’ve set up a community audit for the grant distribution contracts.
Join us in this community effort!

## How? 👀

1. **Review the Code:** Check out [this PR](https://github.com/Steemhunt/hunt-town/pull/7) and give the code a thorough review.
2. **Submit Your Findings:** If you spot any issues or have suggestions, add comments or submit a review through the GitHub interface.

All contributions submitted by **July 25, 2024** will be counted.

## Bounty Details 💰

We have 1000 [Mini Building NFTs](https://mint.club/nft/base/MINIBD) (worth ~$3,100 in total) to distribute proportionally based on your contributions.
On July 26, I’ll create a GitHub issue ([similar to this](https://github.com/Steemhunt/mint.club-v2-contract/issues/72)) to announce the bounty distribution. Leave your wallet address (Base) in the comments on that issue.

## Basic Code Structure

### [BuilderGrant](./contracts/BuilderGrant.sol): Grant for Builders (Tip receivers)

- The top 3 builders will claim bounties of 10K, 6K, and 4K HUNT each, in the form of Mini Building NFTs (100 HUNT locked on each NFT).
- The top 3 builders have 3 options to choose from:
  - Option 1: Claim 100% for themselves.
  - Option 2: Claim 50% for themselves and donate 50% to those ranked 4th and below.
  - Option 3: Donate 100% to those ranked 4th and below.
- All data is stored on the contract, so `setSeasonData` requires the owners to add at least up to the 103rd rank to cover all donations.
- Donation receivers will be able to claim their rewards once the top 3 finish their decisions or after 1 week has passed.

### [TipperGrant](./contracts/TipperGrant.sol): Grant for Voters (Tip givers)

- All voters (tipping participants) can claim some liquid HUNT based on their total tipping amount.
- The reward wallet and amount will be validated via MerkleProof, with only the Merkle root stored on the contract due to the potentially large number of tippers.
