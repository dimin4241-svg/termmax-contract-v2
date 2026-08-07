# TermMax V2 stale-NAV bad-debt proof bundle

## Claim being proven

After a legitimate matured-order settlement realizes bad debt, `TermMaxVaultV2` records the bad debt but does not immediately reduce the principal used by `totalAssets()`. Until some LP later calls `dealBadDebt()`, an ordinary LP can redeem their own shares against the stale higher NAV. The amount they receive above their loss-adjusted economic share is conserved as additional loss imposed on the LPs who remain in the vault.

This bundle deliberately separates:

- **prerequisite:** a legitimate vault order becomes economically underwater and the curator performs the normal maturity `redeemOrder()`;
- **attacker action:** an ordinary LP calls ERC-4626 `redeem()` on their own shares after settlement and before the bad debt is dealt.

The ordinary LP does not require curator, owner, guardian, allocator, oracle, or governance privileges.

## 1. Current upstream root cause

Current upstream files:

- `contracts/v2/vault/OrderManagerV2.sol`
- `contracts/v2/vault/TermMaxVaultV2.sol`
- `contracts/v2/TermMaxOrderV2.sol`

The relevant state transition is:

1. `OrderManagerV2.redeemOrder()` calls `order.redeemAll(address(this))`.
2. If `badDebt != 0`, it only executes `_badDebtMapping[collateral] += badDebt`.
3. It does **not** subtract that bad debt from `_accretingPrincipal` or `_totalFt`.
4. `TermMaxVaultV2.totalAssets()` still returns the accrued principal derived from `_accretingPrincipal`.
5. Ordinary ERC-4626 redemption uses that stale `totalAssets()` quote and calls `withdrawAssets()`.
6. Only the separate later `dealBadDebt()` path subtracts bad debt from `_accretingPrincipal` and `_totalFt`.

`TermMaxOrderV2.redeemAll()` does not impose a dust-sized bad-debt cap; it derives bad debt from the FT claim left unrecovered at maturity.

Therefore the accounting window is structural, not a rounding artifact.

## 2. Exact production-fork proof

PoC:

`test/v2/mainnet-fork/mainnet/TermMaxVaultStaleNavForkPoC.t.sol`

Properties:

- exact historical Ethereum pre-transaction state;
- real deployed vault/order/market/GT contracts;
- real historical settlement caller;
- real historical LP and real historical shares;
- no `vm.store`;
- no `deal()`;
- no synthetic vault shares;
- no oracle modification;
- no contract deployment or patching.

The PoC replays the real `redeemOrder()` settlement, verifies the historical `badDebt` and delivered collateral, proves `totalAssets()` remains unchanged, then lets the real LP call ordinary `redeem()`.

Saved successful runtime excerpt:

`production-evidence/production_stale_nav_positive_runtime_excerpt.log`

Measured exact-fork result:

```text
real bad debt raw:                              10182136
delivered collateral raw:                       0
delivered collateral value in asset raw:        0
realized net loss raw:                           10182136
ordinary redeem payout raw:                      2500188576954679599849599
fair economic payout raw:                        2500188576954679594758531
loss shifted to remaining LPs raw:               5091068
Suite result: ok. 1 passed; 0 failed
```

This historical asset uses 18 decimals, so this event proves the production exploit path and conservation of the transfer, **not** a material historical dollar loss.

## 3. Material-scale regression using only normal protocol calls

PoC:

`test/v2/VaultBadDebtScaleAudit.t.sol`

CI:

`.github/workflows/stale-nav-scaled-loss-regression.yml`

Saved result:

`production-evidence/stale_nav_scaled_loss_excerpt.log`

The regression inherits the protocol's own `VaultTestV2` setup and uses normal calls only:

- burns the unrelated upstream seed position through `market.burn()` rather than editing balances/storage;
- two independent LPs each deposit 500,000 DAI through public ERC-4626 `deposit()`;
- curator configures a 1,000,000 DAI virtual reserve through the real `updateOrdersConfiguration()` API;
- the order receives scaled exposure through the same `buyXt()` path used by upstream `testBadDebt()`;
- a borrower legitimately issues 800,000 DAI FT against 800 ETH while the collateral is initially worth about 1.6M DAI;
- a 75% external collateral-price shock models a normal market-risk event, leaving the position underwater;
- curator performs normal maturity `redeemOrder()`;
- the attacker then performs only ordinary ERC-4626 `redeem()` on their own shares.

No `vm.store`, `deal()`, token balance overwrite, synthetic shares, or patched contract behavior is used.

Successful measured result, with the test debt token using 8 decimals:

```text
bad debt raw:                              40000000000000  = 400,000 DAI
delivered collateral raw:                  400000000000000000000 = 400 ETH
delivered collateral value in debt raw:   20000000000000  = 200,000 DAI
realized net loss raw:                      20000000000000  = 200,000 DAI
exiting LP shares:                          50000000000000
stale redeem payout raw:                    50954835207920  = 509,548.35207920 DAI
fair loss-adjusted payout raw:              41053845108910  = 410,538.45108910 DAI
loss shifted to remaining LPs raw:          9900990099010   = 99,009.90099010 DAI
Suite result: ok. 1 passed; 0 failed
```

The test contains an explicit assertion that the shifted loss must exceed **50,000 DAI**. It passed.

It also proves conservation:

```text
early LP's stale-NAV overpayment ~= additional economic loss left to remaining LPs
```

within two raw debt-token units.

## 4. The scale is inside production-configured vault capacity

Current upstream deployment data in:

`script/deploy/deploydata/eth-mainnet-vaults.json`

contains USDC vault configurations with:

```text
TermMax USDC Reactor maxCapacity = 20,000,000,000,000 raw USDC = 20,000,000 USDC
Keyrock USDC          maxCapacity = 100,000,000,000,000 raw USDC = 100,000,000 USDC
```

The material regression uses roughly 1.01M DAI of vault capital, far below those production-configured scales. The regression therefore demonstrates a material instance of the accounting flaw without requiring a vault size beyond the protocol's real intended deployment range.

This does **not** claim that a 99k exploitable loss exists on mainnet at this exact moment. It proves that the flaw itself is not dust-bounded and can redistribute six-figure user value when an otherwise legitimate vault suffers a material realized default.

## 5. Current-state and historical negative controls

### Current Ethereum snapshot

`production-evidence/current_negative_recovery_scan.json`

At snapshot block `25,701,126`, the scanner found 9 V2 vaults but no currently registered matured order with `economic recovery < FT face`. Existing known USDC vault nominal assets included approximately 3.348M USDC and 674k USDC.

Therefore this bundle does **not** claim a currently ready six-figure atomic theft from an already-matured order.

### Prime Yield USDC historical event

A historical Prime Yield USDC settlement recorded 939,875 raw USDC bad debt and delivered 9,267 raw wstrBTC. Exact ERC-4626 historical conversion showed that 9,267 raw wstrBTC converted to 9,267 raw strBTC (0.00009267 strBTC). The break-even strBTC price required for this collateral to cover the 0.939875 USDC bad debt was only about $10,142/strBTC.

That event is therefore deliberately excluded as a material stale-NAV loss candidate; a positive `badDebt` field alone is not treated as proof of economic loss.

Evidence:

`production-evidence/prime_yield_wstrbtc_value.json`

This negative control is included to show that the proof distinguishes recorded bad debt from actual uncovered economic loss.

## 6. Upstream reachability control

The unmodified upstream `test/v2/VaultV2.t.sol::testBadDebt()` itself executes this order of operations:

1. curator calls `redeemOrder()`;
2. an LP calls ordinary `redeem()`;
3. bad debt remains recorded;
4. only afterwards does the LP call `dealBadDebt()`.

Successful audit run:

`production-evidence/upstream_baddebt_scale_excerpt.log`

This demonstrates that `redeemOrder -> LP redeem -> dealBadDebt` is reachable under the protocol's own test model and is not an invented call sequence.

## 7. Exact economic identity

Let:

- `N` = stale nominal `totalAssets()` after settlement;
- `S` = total share supply;
- `s` = shares held by the early LP;
- `L` = realized settlement loss (`badDebt - economic value of delivered collateral`).

The stale ERC-4626 payout is approximately:

`P_stale = s / S * N`

The loss-adjusted economic payout is approximately:

`P_fair = s / S * (N - L)`

Therefore:

`P_stale - P_fair ~= s / S * L`

Because ordinary `redeem()` reduces nominal principal by `P_stale` while leaving the recorded bad debt untouched, the same amount is removed from the economic assets available to remaining LPs. The production-fork and material regression tests both assert this conservation relation directly.

## 8. Scope of the security claim

What is proven:

- the root cause exists in current upstream code;
- the stale-NAV window is reached by real production settlement behavior;
- an ordinary LP can use `redeem()` during that window;
- the early LP's excess payout is conserved as additional loss to remaining LPs;
- the mechanism is not rounding/dust-bounded;
- a normal protocol regression demonstrates 99,009.90099010 DAI shifted between LPs;
- that test scale is below real production-configured vault capacities.

What is **not** claimed:

- an ordinary LP can create or configure vault orders;
- an ordinary LP can call `redeemOrder()`;
- a six-figure underwater matured order is available on Ethereum mainnet today;
- every positive `badDebt` event is an economic loss.

The security issue is an opportunistic but permissionless **loss-shifting exit after a legitimate realized default**, not a claim that an attacker can manufacture the default without privileged protocol configuration or market-risk conditions.
