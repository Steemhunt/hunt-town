# FactoryNFT

HUNT-backed ERC1155 units for the Hunt Town Web3 product factory. `FactoryNFT` holds
the collateral itself; `FactoryZapRouter` buys the HUNT needed to mint through
Uniswap V4. Both contracts are non-upgradeable.

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
any unit was minted or burned after `expectedSupply` was read, so a mint placed
in front of a pending deposit makes the deposit fail instead of capturing part
of it. A plain HUNT transfer to the contract also raises NAV but carries no such
guard, so team deposits always go through `deposit`. Incoming HUNT immediately
raises NAV; there is no reward checkpoint, claim function, or holding-period
restriction.

Operating rules for deposits:

- Submit deposits through a private relay so the transaction is not visible in
  the public mempool. A public deposit can be blocked repeatedly by a one-unit
  mint that costs the attacker only gas.
- When a deposit reverts with `SupplyChanged`, look at what changed the supply
  before retrying with the new value. Retrying blindly after a front-running
  mint hands that minter a share of the deposit.
- The guard does not cover a holder who minted well before a predictable
  deposit. Keep deposit timing irregular and each deposit small relative to the
  backing; with the 5% redemption fee, capturing a deposit only pays when it
  exceeds roughly 5% of the backing after the attacker's own mint.

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
from any caller and is permissionless. Mint, burn, deposit and both transfer
entrypoints reject reentrancy. Contract recipients must accept
ERC1155 safe-mint/transfer callbacks.

The owner can change the metadata URI, `royaltyOperator`, and transfer validator,
and transfer ownership through OpenZeppelin's two-step process. The royalty
rate is fixed at 3%; the redemption fee is fixed at 5%. The owner has no
collateral withdrawal, unbacked mint, arbitrary-call or upgrade function.
FactoryNFT assumes the canonical, exact-transfer HUNT token and does not support
fee-on-transfer or rebasing collateral.

## Marketplace royalties

OpenZeppelin's ERC2981 reports a 3% royalty payable to `royaltyOperator`, initially
`0xdd15e36BEf873Ca3ceC9411c98878734576aDfb2`. The operator receives marketplace
currencies, buys HUNT externally, and deposits that HUNT into FactoryNFT.

FactoryNFT implements OpenSea's `ICreatorToken` interface (`0xad0d7f6c`) and calls
the configured validator's amount-aware `validateTransfer` before each pair in
a transfer or batch transfer. Mint and redemption bypass marketplace validation.
`getTransferValidationFunction()` returns `0x1854b241` and `false`. No Limit Break
token library is imported; the external validator supplies the transfer policy.

The Ethereum deployment script selects OpenSea's
`StrictAuthorizedTransferSecurityRegistry` at
`0xA000027A9B2802E1ddf7000061001e5c005A0000`. It does not require token-type
registration. An owner may replace the validator; setting it to zero disables
validation. Validator policy can restrict marketplaces and ordinary transfers,
but cannot independently withdraw FactoryNFT's HUNT.

After deployment, configure and enable 3% creator earnings in OpenSea Studio.
Restricted Seaport orders need the supported SignedZone authorization flow.
Do not broadly exempt marketplace operators as a substitute for that flow.
Setting a validator alone does not prove royalty enforcement. Local mock tests
exercise the integration hooks; full OpenSea order fulfillment remains a
deployment integration check.

References: [OpenSea creator-fee enforcement](https://docs.opensea.io/docs/creator-fee-enforcement),
[OpenZeppelin ERC2981](https://docs.openzeppelin.com/contracts/5.x/api/token/common).

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

## Deployment

`script/DeployFactory.s.sol` targets Ethereum and uses:

- HUNT: `0x9AAb071B4129B083B01cB5A0Cb513Ce7ecA26fa5`
- V4 PoolManager: `0x000000000004444c5dc75cB358380D2e3dE08A90`
- The royalty operator and validator described above.

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

## Verification

Unit and fuzz tests cover backing arithmetic, rounding, revenue deposits,
bulk/sequential redemption, reserve conservation, owner permissions, royalties,
validator hooks, callbacks and transaction rollback. Stateful invariants cover
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
skip. Fork tests never broadcast and do not test signed OpenSea order fulfillment.

Additional unit tests inject invalid manager responses, token transfers, mint
payments and deployment configuration to exercise defensive failure paths.
Those fault-injection mocks are separate from the real mainnet integration tests.

Run the coverage gate with the archive RPC configured:

```sh
./script/check-coverage.sh
```

The gate requires the RPC URL, runs the complete suite, writes
`coverage/summary.txt` and `coverage/lcov.info`, and fails unless every reported
project source and deployment script reaches 100% in all four metrics. It also
requires entries for both production contracts and the deployment script.
Only third-party libraries and test fixtures are excluded; the interfaces have
no executable bodies. Coverage uses Foundry's standard unoptimized compilation,
without `--ir-minimum`, while normal tests use the production IR configuration.
The router groups balance snapshots and scopes temporary variables so both
compiler paths work without removing any checks.

| Source | Lines | Statements | Branches | Functions |
| --- | --- | --- | --- | --- |
| FactoryNFT | 100% (83/83) | 100% (98/98) | 100% (14/14) | 100% (20/20) |
| FactoryZapRouter | 100% (107/107) | 100% (181/181) | 100% (38/38) | 100% (4/4) |
| DeployFactory | 100% (15/15) | 100% (19/19) | 100% (10/10) | 100% (1/1) |

Verified on September 27, 2026 with the toolchain above: 86 tests passed, zero
failures and zero skips with the mainnet fork enabled at block 26,039,501. This
includes three fuzz cases with 1,000 runs each and three stateful invariants
checked over 32,768 actions with zero reverts. The deployment test verifies the
approval/CREATE nonce sequence, seed funding and configuration/nonce failure
guards. Formatting checks passed. Production bytecode is below the EVM size
limits. Foundry's heuristic lint warnings about guarded
external calls, exact balance checks, bounded loops and deadline timestamps were
reviewed; no blanket warning suppression was added.
