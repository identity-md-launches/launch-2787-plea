# PLEA test coverage

The existing `PleaToken.t.sol` is preserved. `PleaToken.behavior.t.sol` adds
constructor and CREATE2 deployment checks, boundary examples, failure paths and
nine fuzz properties. `PleaToken.invariant.t.sol` drives the production token
through `handlers/PleaTokenHandler.sol` and checks four invariants after every
random action.

The expected allocation is specified independently as `1_000_000_000 * 10 ** 18`.
It is not inferred from the token's reported supply. The constructor tests also
check the mint event and distinguish the direct contract deployer from both its
caller and the transaction origin.

## Property selection

The five discovery passes from the supplied Pashov fizz guide, together with the
Trail of Bits property-testing review, produce these checks:

| Discovery pass | Property and evidence | Where checked |
| --- | --- | --- |
| Conservation | Supply remains exactly the requested allocation; all balances in the closed actor set sum to it. `src/PleaToken.sol:11` and `:14` specify the only mint. | Supply invariant; constructor and transfer examples. |
| State transitions | Direct and delegated transfers move the exact requested amount; approval replaces a spending budget; a rejected operation preserves balances and allowances. Public entry points are inherited from `ERC20.sol:99`, `:120` and `:142`. | Balance and allowance invariants; event, revocation, isolation and rollback tests. |
| Round trips | Sending tokens out and back restores balances exactly; splitting a transfer has the same result as one transfer. There is no conversion or transfer fee in this token. | Round-trip handler and two fuzz properties. |
| Adversarial inputs | Insufficient balance or allowance cannot move tokens. The deployer has no special access to a holder's funds. Every holder can still transfer its whole balance after a random sequence. | Checked rejection handlers, unauthorized-spend examples and `afterInvariant()`. |
| Token-specific behavior | Self-transfers preserve balances, zero transfers succeed for valid addresses, zero recipients/spenders reject, and only maximum uint256 approval is unlimited. Metadata remains `plea`, `PLEA`, 18. | Boundary examples, random aliasing, approval invariant and metadata invariant. |

The allowance properties follow the vendored OpenZeppelin ERC-20's documented
finite/infinite approval behavior. Rejection of a zero `from` address is checked
without prescribing whether allowance or sender validation must run first.

## Stateful harness

Five named actors receive equal portions of the actual constructor allocation
through ordinary transfers. There is no token balance/storage injection. Successful
transfers stay within this actor set; attempted zero-address transfers must reject.
The conservation property therefore accounts for every token in this scenario.

The handler maintains expected balances and a separate allowance table using the
initial allocation and requested successful operations. It never copies the
token's post-call balances or allowances into that model. An approval replaces
the corresponding budget; a finite delegated spend consumes it, including when
sender and recipient coincide. Expected failures leave the model unchanged, so
the invariants also detect partial updates and changes to unrelated accounts.

Nine targeted actions mix transfers, approvals, revocations, delegated spends,
unbounded delegated amounts, excessive direct spends, invalid recipients, invalid
spenders and round trips. Bounded amounts explicitly include zero, one base unit,
the whole available balance and one less. Approvals include zero, uint256 maximum,
maximum minus one, and ordinary finite amounts. Actor selection permits all role
aliases, including self-approval and self-transfer.

Only these actions are targeted; neither the token nor inherited test utilities
are called directly by the invariant runner. `fail-on-revert = true` makes an
unexpected handler revert a failure. Expected token reverts are checked explicitly
with their error data. The deterministic handler test exercises positive spending,
finite exhaustion, infinite approval, revocation and rejection counters.

Inline settings specify 1,000 runs per new fuzz property and 256 invariant runs
with depth 128. `afterInvariant()` sweeps every holder's full balance to the first
actor and checks that the complete supply is still transferable and accounted for.

## Running locally

No new dependencies, RPC, fork or external service are required. The supplied
protected launch checks informed the token-level properties; this suite does not
recreate the factory or Uniswap pool integration.

```sh
export FOUNDRY_OUT=test/scratch/out
export FOUNDRY_CACHE_PATH=test/scratch/cache
export FOUNDRY_FUZZ_SEED=0xbf8a58040ff79acbefcd170ba3d04c68ea7b68962c875e41aba1fe94983e5e6d
forge build --offline
forge test --offline
```

The scratch directory holds only disposable build artifacts. All test sources
needed by the suite are outside it. No implementation defect was found in this
review or in the seeded runs.
