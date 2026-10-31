# plea (PLEA)

A fixed-supply ERC-20 token, built with Foundry on OpenZeppelin Contracts v5.4.0.

| Property | Value |
| --- | --- |
| Solidity contract | `PleaToken` (`src/PleaToken.sol`) |
| `name()` | `plea` |
| `symbol()` | `PLEA` |
| `decimals()` | 18 |
| Total supply | 1,000,000,000 PLEA = `1000000000000000000000000000` minor units (`TOTAL_SUPPLY`) |
| Constructor arguments | none |

## Behaviour

- The constructor mints the whole supply once to `msg.sender` (the deployer; on the launch, the factory).
- There is no owner and no admin role. Nothing can mint, pause, blacklist, freeze, seize or burn a holder's balance.
- Transfers carry no fee, tax or burn, so the launch flows (factory to distributor, distributor to claimants, pool seed and swaps through the Uniswap v4 PoolManager) move exactly the amounts they state.
- Standard OpenZeppelin ERC-20 semantics apply: transfers to the zero address revert, an allowance of `type(uint256).max` is never decreased, and failures revert with the ERC-6093 custom errors.

## Build and test

```sh
forge build
forge test
forge fmt --check
```

The compiler is pinned to solc 0.8.26 in `foundry.toml`, with `bytecode_hash = "none"`. Dependencies (`forge-std` v1.9.7 and `openzeppelin-contracts` v5.4.0) are vendored as plain files under `lib/`.

`test/PleaToken.t.sol` covers metadata, the initial mint, transfers, allowances, revert cases (insufficient balance, insufficient allowance, zero receiver, zero spender), the absence of mint or ownership entry points, and a fuzz test that transfers conserve supply.

## Deployment parameters

- Chain: Ethereum mainnet (chain id 1), deployed by the IMD launch factory via `launchCustom`.
- Token constructor arguments: none. The supply goes to the factory, which distributes it per the launch economics (10% to the swarm's MerkleDistributor, 70% to seed the PLEA/IMD Uniswap v4 pool, 20% to the requester's remainder address).
- No application contracts are deployed alongside the token.

## Assumptions

- "Minted once to the deployer" means `msg.sender` of the constructor. On the launch, that is the factory, which then pays all of it out.
- The brief asks for no transfer rules, so the token is plain ERC-20 with no fees or limits.

## Operational responsibilities

- There are no privileged functions and nothing to configure after launch, so the token has no "After launch" settings.
- Deployment, source verification and pool creation are done by IMD's launch process, not by this repository. Nothing here holds keys or sends transactions.
- Tests passing are not a security audit. The contract is a minimal wrapper around audited OpenZeppelin code, but an independent review before release is still recommended.
