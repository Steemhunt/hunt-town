# FactoryNFT

HUNT-backed ERC1155 units for the Hunt Town Web3 product factory. `FactoryNFT` holds
the collateral itself; `FactoryZapRouter` buys the HUNT needed to mint through
Uniswap V4. `BuildingMigrator` exchanges legacy Buildings and fulfills operator-verified
Base migrations using prefunded HUNT. All three contracts are non-upgradeable.

## Toolchain

Stable releases checked on September 23, 2026:

| Component | Version |
| --- | --- |
| Solidity, project contracts | 0.8.37 |
| Foundry | 1.8.3 |
| OpenZeppelin Contracts | 5.7.0 |
| forge-std | 1.16.2 |
| Uniswap v4-core | 1.0.2, commit `59d3ecf53afa9264a16bba0e38f4c5d2231f80bc` |

Uniswap's latest published npm package is newer than its GitHub `v4.0.0` release.
The local PoolManager test artifact retains Uniswap's required Solidity 0.8.26;
the project contracts and tests use 0.8.37. Compiler optimization follows the
lptoken-fun project: Cancun EVM, IR pipeline, 20,000 runs, and no metadata hash.
Dynamic test linking is disabled so constructor funding tests use real CREATE
addresses instead of substituted test deployment addresses.

Dependencies are pinned in `foundry.lock` and installed locally under ignored
`lib/`. From this directory, with Foundry 1.8.3 available:

```sh
forge install --no-git OpenZeppelin/openzeppelin-contracts@v5.7.0 Uniswap/v4-core@59d3ecf53afa9264a16bba0e38f4c5d2231f80bc foundry-rs/forge-std@v1.16.2
forge build
forge test
forge fmt --check
```

The implementation workspace also includes a verified project-local Foundry
1.8.3 installation in ignored `.tools/`; use `./.tools/forge` if the globally
installed version differs. Solmate is an upstream V4 test dependency, pinned by
V4's submodule revision, rather than an additional production dependency.

## Collateral and supply

There is one token ID, `0`, with integer quantities and unlimited issuance.
HUNT uses 18 decimals. Let `V` be the contract's HUNT balance, `N` its total NFT
supply, and `q` the quantity in a transaction:

| Operation | Calculation |
| --- | --- |
| Initial seed | 1 NFT funded with 1,000 HUNT |
| `navPerNFT()` | `floor(V / N)` in HUNT base units |
| `quoteMint(q)` | `ceil(V * q / N)` |
| `quoteBurn(q)` | `floor(floor(V * q / N) * 9500 / 10000)` |

The frontend can display the NAV multiplier as `navPerNFT() / INITIAL_NAV()`.
Both values use HUNT base units. To retain 18 decimal places with integer
arithmetic, calculate `navPerNFT * 10n ** 18n / initialNav` using JavaScript
`bigint`; use `quoteMint` and `quoteBurn` for actual transaction amounts.

Calculations use full-precision multiplication and division. Mint rounding
protects existing collateral; redemption rounding leaves dust in the contract.
The 5% redemption fee remains as HUNT collateral for all remaining units.

The constructor pulls the seed's 1,000 HUNT from the deployer before issuing the
seed to `seedOwner`. Preapprove the predicted contract address. This is a normal
NFT unit, and the team is expected to retain it. The enforced rule is a global
minimum supply of one, not a special permanently locked token or account.

Every unit in one burn uses the same starting NAV. Separate burns may return
more because subsequent burns share previously retained fees. For example,
with 3,000 HUNT backing 3 units, redeeming 2 together returns 1,900 HUNT; redeeming
them separately returns 950 + 973.75 HUNT.

Product revenue is converted to HUNT externally and added through
`deposit(amount, expectedSupply)`. The call reverts with `SupplyChanged` when
the total supply at execution differs from `expectedSupply`. It checks the
current net supply, not the intervening mint/burn history: offsetting mints and
burns can restore the expected value and let the deposit execute with newly
minted units included. The guard therefore does not prevent every front-running
sequence. A plain HUNT transfer to the contract also raises NAV but carries no
supply check, so team deposits always go through `deposit`. Incoming HUNT
immediately raises NAV; there is no reward checkpoint, claim function, or
holding-period restriction.

Operating rules for deposits:

- Submit deposits through a private relay so the transaction is not visible in
  the public mempool. A public deposit can be blocked repeatedly by a one-unit
  mint that costs the attacker only gas.
- When a deposit reverts with `SupplyChanged`, look at what changed the supply
  before retrying with the new value. Retrying blindly after a front-running
  mint hands that minter a share of the deposit.
- The guard does not cover a holder who minted well before a predictable
  deposit or a sequence that restores the expected supply. Keep deposit timing
  irregular and each deposit small relative to the backing. For a single mint,
  deposit and redemption with no other supply changes, the deposit must exceed
  roughly 5.26% of the backing after the mint to cover the 5% redemption fee,
  before gas costs; this threshold does not apply to sequences involving other
  holders' redemptions.

## Core API and permissions

```solidity
quoteMint(uint256 amount) returns (uint256 huntIn)
quoteBurn(uint256 amount) returns (uint256 huntOut)
mint(uint256 amount, uint256 maxHuntIn, address receiver) returns (uint256 huntIn)
burn(uint256 amount, uint256 minHuntOut) returns (uint256 huntOut)
deposit(uint256 amount, uint256 expectedSupply)
```

Mint pulls HUNT from the caller and issues units directly to `receiver`.
Burn redeems only the caller's units and pays that caller. ERC1155 operator
approval does not authorize redemption on a holder's behalf. Deposit pulls HUNT
from any caller and is permissionless. Mint, burn and deposit reject reentrancy.
Transfers use OpenZeppelin's standard implementation, which updates all balances
before calling the receiver. Transfer callbacks can forward received units or
call mint, burn and deposit against the settled state. During a mint callback,
forwarding is allowed but the outer mint's guard still blocks mint, burn and
deposit reentry. Contract recipients must accept ERC1155 safe-mint/transfer
callbacks.

The owner can change the metadata URI and `royaltyOperator`, and transfer
ownership through OpenZeppelin's two-step process. The royalty
rate is fixed at 3%; the redemption fee is fixed at 5%. The owner has no
collateral withdrawal, unbacked mint, arbitrary-call or upgrade function.
FactoryNFT assumes the canonical, exact-transfer HUNT token and does not support
fee-on-transfer or rebasing collateral.

## Marketplace royalties

OpenZeppelin's ERC2981 reports a 3% royalty payable to `royaltyOperator`, initially
`0xdd15e36BEf873Ca3ceC9411c98878734576aDfb2`. The operator receives marketplace
currencies, buys HUNT externally, and deposits that HUNT into FactoryNFT.

The royalty is reported, not enforced. FactoryNFT integrates no transfer
validator and restricts no transfer: holders, approved operators, and contracts
that hold units move them under plain ERC1155 rules, and each marketplace
decides whether to honor the ERC2981 figure. Units always mint at NAV and
redeem at 95% of NAV, so secondary prices stay inside that band and enforcement
machinery would have guarded only part of a 5% spread.

References: [OpenZeppelin ERC2981](https://docs.openzeppelin.com/contracts/5.x/api/token/common).

## V4 minting zap

```solidity
zapMint(
    uint256 quantity,
    address inputToken,
    uint256 maxAmountIn,
    PoolKey[] calldata route,
    address receiver,
    uint256 deadline
) payable returns (uint256 amountIn, uint256 huntIn)
```

The caller chooses an exact NFT quantity and a maximum input amount. The client
supplies a forward route, such as USDC -> native ETH -> HUNT. Each `PoolKey`
specifies the sorted currency pair, fee, tick spacing, and zero hook address.
The first pool must contain the input currency, consecutive pools must connect,
and the final output must be HUNT. Routes contain one to three initialized,
hookless, static-fee pools and cannot revisit a currency.

The router quotes current HUNT mint cost, executes V4 exact-output swaps in
reverse order inside one unlock, settles the initial input, and takes the exact
HUNT output. Intermediate ETH stays within V4's accounting. It then approves
FactoryNFT for the exact HUNT payment and mints directly to `receiver`.

- Native ETH: `inputToken = address(0)` and `msg.value = maxAmountIn`.
- ERC20, including USDC, USDT and DAI: approve `maxAmountIn` to the zap and send
  no ETH. Tokens must transfer exact amounts; non-returning ERC20s are supported.
- Direct HUNT: pass an empty route. Users may also call FactoryNFT directly.
- Unused input is refunded to the payer in its original currency; the NFT goes
  to `receiver`. HUNT approval to FactoryNFT is cleared after minting.
- Route failure, insufficient output, exceeded maximum, rejected mint, failed
  refund, or expired deadline reverts the entire operation.

The zap preserves preexisting HUNT, input-token and ETH balances and never
refunds another caller's dust. It has no owner or arbitrary-call function.
Prices and routes are chosen off-chain; `maxAmountIn` bounds the user's payment.

## Building migration

`src/BuildingMigrator.sol` connects the existing Ethereum Building ERC721 and
FactoryNFT contracts. It does not burn Buildings or withdraw their TownHall backing.
Every Building is eligible, including newly minted units and units still in their
one-year lock. Transferred Buildings retain their original unlock times; the team
provides the liquidity until it can redeem that backing through TownHall.

```solidity
quoteMigration(uint256 buildingCount)
    returns (uint256 mintingCount, uint256 additionalHunt, uint256 huntIn)
migrate(uint256[] ids, uint256 maxAdditionalHunt)
    returns (uint256 mintingCount, uint256 additionalHunt)
migrateByOperator(uint256 mintingCount, address receiver, bytes32 requestId, uint256 maxHuntIn)
    returns (uint256 huntIn)
```

For Main Buildings, credit is `ids.length * 1,000 HUNT`, and the Factory quantity is
`ceil(credit / FactoryNFT.quoteMint(1))`. The actual cost is `FactoryNFT.quoteMint(quantity)`;
the user pays `max(actualCost - credit, 0)`. For example, 10 Buildings at a
1,200 HUNT mint price produce 9 Factory NFTs and require 800 additional HUNT.
Batch minting rounds once, so the actual top-up may be a few wei below a frontend
estimate obtained by multiplying the one-unit quote. If batch rounding places the
cost just below credit, the top-up is zero; there is no separate dust refund.
Use `quoteMigration` for the authoritative transaction quote.

The holder approves their Buildings and only the required additional HUNT to the
migrator, then calls `migrate`. The fixed custody wallet
`MIGRATION_RECEIVER = 0x25bE2785504c36016aDEC2585F9e120eF6B2f64D` receives both the
Buildings and the top-up directly. The migrator spends the **entire** Factory mint
cost from its prefunded HUNT balance and mints directly to the caller. The user
cannot nominate another Building owner, even with that owner's approval. Each
Building ID is accepted only once, including if custody later transfers it back.

Quantity and top-up are recalculated at execution. `maxAdditionalHunt` caps the
additional payment, not the Factory quantity; NAV changes across a rounding
boundary can change the number of NFTs received. Missing approval, insufficient
user or treasury HUNT, a rejected safe transfer/mint, or a changed mint quote
reverts the entire transaction, including all custody transfers and ID flags.

For Mini Buildings, the Base transfer, quote, and pending record live outside this
contract. A separate worker verifies the Base receipt and calls `migrateByOperator`
from the configured operator wallet. There is no extra signature payload: the
Ethereum transaction authenticates the operator. The quoted Factory quantity and
recipient come from the pending record, and `maxHuntIn` bounds the team's current
mint expenditure. No HUNT or NFT is pulled from the Ethereum recipient.

The worker must derive one stable `requestId` per accepted Base receipt, for example
`keccak256(abi.encode(uint256(8453), baseTransactionHash, uint256(baseLogIndex)))`,
and reuse it for every retry. A successful request is recorded in `processedRequests`
and cannot mint twice, even with a changed recipient or quantity. Failed requests
remain retryable. After a worker restart or an uncertain RPC response, check the
mapping and `OperatorMigrated` receipt before resubmitting. The contract trusts the
operator to verify the Base payment and quoted quantity; it is not a cross-chain
proof verifier. Base collection, DB processing, confirmation policy, and status UI
are a separate integration step; this contract does not guarantee a delivery time.

The two-step owner can rotate `operator` with `setOperator`; zero disables operator
fulfillment while leaving Main Building migration available. `withdrawHunt(amount)`
returns unused team funding only to `MIGRATION_RECEIVER`. Funding uses ordinary
HUNT transfers. The canonical HUNT token is assumed to transfer exact amounts.
Asset-moving entrypoints reject reentry, and Factory allowances are exact and
cleared after minting. Contract recipients must accept ERC1155 safe mint callbacks.

## Deployment

`script/DeployFactory.s.sol` targets Ethereum and uses:

- HUNT: `0x9AAb071B4129B083B01cB5A0Cb513Ce7ecA26fa5`
- V4 PoolManager: `0x000000000004444c5dc75cB358380D2e3dE08A90`
- The royalty operator described above.

Provide `DEPLOYER`, `FACTORY_OWNER`, `SEED_OWNER`, `FACTORY_URI`, and
`MAINNET_RPC_URL`. The deployer needs at least 1,000 HUNT plus transaction gas.
Simulate before broadcasting:

```sh
forge script script/DeployFactory.s.sol:DeployFactory --rpc-url "$MAINNET_RPC_URL" --sender "$DEPLOYER"
```

The sequence is an exact seed approval, FactoryNFT CREATE, then FactoryZapRouter
CREATE. The script accounts for the approval transaction's nonce. Use the same
deployer without interleaved transactions. To broadcast after review, use your
Foundry signing account and add `--broadcast --slow`; the script never loads a
private key. Ownership and seed recipient are explicit inputs.

### BuildingMigrator

`script/DeployBuildingMigrator.s.sol` deploys only the new migrator, pointing at:

- FactoryNFT: `0x961eA6C51c185958b1A11ad8335046988D1B5734`
- Building: `0x0c9Bb1ffF512a5B4F01aCA6ad964Ec6D7fC60c96`

Set `DEPLOYER`, `MIGRATOR_OWNER`, `MIGRATOR_OPERATOR`, and `MAINNET_RPC_URL`.
Use a zero operator to enable only Main Building migration initially. Simulate:

```sh
./.tools/forge script script/DeployBuildingMigrator.s.sol:DeployBuildingMigrator \
  --rpc-url "$MAINNET_RPC_URL" --sender "$DEPLOYER"
```

For an interactive deployment, add `--interactive --broadcast --slow` yourself.
The script neither reads a private key nor funds the contract. After deployment,
transfer enough HUNT to the migrator to cover the full current mint cost of pending
migrations, then configure its address in the frontend and operator worker.

## Verification

Unit and fuzz tests cover backing arithmetic, rounding, revenue deposits,
bulk/sequential redemption, reserve conservation, owner permissions, royalties,
callbacks and transaction rollback. Stateful invariants cover
mint, redeem, deposit, donate and transfer sequences. Zap tests deploy the actual V4
PoolManager code locally and include the real FactoryNFT implementation.

Real-mainnet fork tests run when `MAINNET_RPC_URL` points to an Ethereum archive
RPC endpoint:

```sh
export MAINNET_RPC_URL=https://eth.drpc.org
MAINNET_FORK_BLOCK=26039501 forge test --match-contract 'Factory(NFT|ZapRouter)ForkTest' -vv
```

`FactoryZapRouterForkTest` pins block **26,039,501** and checks the deployed
PoolManager, token contracts, pool IDs, initialization and active liquidity.
Its nine tests exercise ETH, USDC, USDT, DAI and direct HUNT payments, refunds to
the payer, exact mint funding, allowance cleanup, preservation of donated token
and forced ETH balances, and complete rollback when ETH or USDC input limits
are too low. USDT exercises the real token's non-returning transfers. The DAI
route uses all three permitted hops.

| Verified V4 pool | Fee | Tick spacing |
| --- | --- | --- |
| Native ETH / HUNT | 1% | 200 |
| Native ETH / USDC | 0.05% | 10 |
| Native ETH / USDT | 0.05% | 10 |
| DAI / USDC | 0.01% | 1 |

At this pinned block, the hookless native ETH/HUNT 0.3% pool with tick spacing
60 is uninitialized. Tests use the live 1% pool. Routes are ETH -> HUNT,
USDC/USDT -> native ETH -> HUNT, and DAI -> USDC -> native ETH -> HUNT. Pool IDs
are asserted in the test fixture; the client still supplies production routes.

Only test funding is supplied with cheatcodes; the zap fork tests never replace
token code or pool state. They mint two units at a donated NAV of 1,123.323 HUNT,
requiring exactly 2,246.646 HUNT. The three separate `FactoryNFTForkTest` cases
cover real HUNT seed funding, mint/burn and interface metadata; their block can
be overridden with `MAINNET_FORK_BLOCK`. Without an RPC URL both suites explicitly
skip. Fork tests never broadcast.

Additional unit tests inject invalid manager responses, token transfers, mint
payments and deployment configuration to exercise defensive failure paths.
Those fault-injection mocks are separate from the real mainnet integration tests.

Migrator unit and fuzz tests cover NAV-based quantities, exact batch rounding,
custody and treasury accounting, approvals, duplicate Buildings and Base receipts,
operator rotation, failed-call retries, callback rejection/reentry, and deployment
guards. `BuildingMigratorForkTest` uses the already-deployed FactoryNFT, Building,
TownHall, and HUNT at block **26,073,640**. It includes existing unlocked Buildings
and freshly minted locked Buildings, the 10-to-9 conversion at 1,200 HUNT NAV,
atomic failure cases, and operator fulfillment. `MIGRATION_FORK_BLOCK` is separate
from the older general fork block because FactoryNFT did not exist at that block.

```sh
MAINNET_RPC_URL=https://eth.drpc.org ./.tools/forge test \
  --match-contract 'BuildingMigrator.*Test|DeployBuildingMigratorTest' -vv
```

Run the coverage gate with the archive RPC configured:

```sh
./script/check-coverage.sh
```

The gate requires the RPC URL, runs the complete suite, writes
`coverage/summary.txt` and `coverage/lcov.info`, and fails unless every reported
project source and deployment script reaches 100% in all four metrics. It also
requires entries for all three production contracts and both deployment scripts.
Only third-party libraries and test fixtures are excluded; the interfaces have
no executable bodies. Coverage uses Foundry's standard unoptimized compilation,
without `--ir-minimum`, while normal tests use the production IR configuration.
The router groups balance snapshots and scopes temporary variables so both
compiler paths work without removing any checks.

| Source | Lines | Statements | Branches | Functions |
| --- | --- | --- | --- | --- |
| FactoryNFT | 100% (60/60) | 100% (72/72) | 100% (11/11) | 100% (13/13) |
| FactoryZapRouter | 100% (107/107) | 100% (181/181) | 100% (38/38) | 100% (4/4) |
| BuildingMigrator | 100% (54/54) | 100% (65/65) | 100% (13/13) | 100% (7/7) |
| DeployFactory | 100% (15/15) | 100% (19/19) | 100% (10/10) | 100% (1/1) |
| DeployBuildingMigrator | 100% (9/9) | 100% (11/11) | 100% (4/4) | 100% (1/1) |

Verified on September 29, 2026 with the toolchain above: 113 tests passed, zero
failures and zero skips with the mainnet forks enabled at blocks 26,039,501 and
26,073,640. This includes four fuzz cases with 1,000 runs each and three stateful invariants
checked over 32,768 actions with zero reverts. The deployment test verifies the
approval/CREATE nonce sequence, seed funding and configuration/nonce failure
guards. Formatting checks passed. Production bytecode is below the EVM size
limits. Foundry's heuristic lint warnings about guarded
external calls, exact balance checks, bounded loops and deadline timestamps were
reviewed; no blanket warning suppression was added.
