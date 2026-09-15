# Release Revenue Distributor

Raw-cap actions accept the Release capability as `admin_cap`, receive or redeem Release-held revenue, and route it to the Recording addresses fixed by the immutable tracklist. A successful receive emits one `ReleaseCoinsReceivedEvent` with the Release and admin-cap addresses, receiving coin IDs in caller order, and the combined amount. A successful accumulator redemption emits one `ReleaseFundsRedeemedEvent` with the same authorization identities and redeemed amount.

Each positive-input distribution then emits one `ReleaseTrackRevenueDistributedEvent` per track, in tracklist order, including the Release address, track index, composition and recording addresses, split basis points, total input, and rounded amount. It emits one `ReleaseRevenueDistributedEvent` summary with track count, total input, total distributed, and remainder. All event IDs are primitive addresses. Flooring remainder returns to the Release.

`redeem_all_and_distribute` is the only accumulator redemption path and the fixed permissionless-crank primitive for custody adapters: it reads the canonical `AccumulatorRoot` snapshot and redeems the full settled value (up to the framework's `u64::MAX` bound), so no caller can select an amount or fragment revenue into dust-sized distributions. An empty snapshot is an authorized no-op that emits no event, so a Release cranked in an earlier consensus commit passes through a batched crank untouched. Newly sent funds and flooring remainder become eligible after a later consensus settlement.

The no-op holds only across commits: the snapshot is written solely by consensus settlement and is constant within a commit, so redeeming the same Release twice in one PTB, or from two crankers in the same commit, withdraws the snapshot twice and the network fails that whole transaction with `InsufficientFundsForWithdraw` (not a Move abort). A crank must include each Release at most once per PTB and retry that status next commit.

The balance-splitting primitive is intentionally private: the package exposes no public donation path unrelated to Release custody. Receiving a real zero-valued coin still consumes that coin and emits the source receipt, while zero-input track and summary events are suppressed. An empty receiving vector retains the `ENoCoinsToReceive` abort. The Move VM covers the zero snapshot through the public entry, and the positive settled-value path (full distribution, later redemption of requeued remainder, the unit VM's zero snapshot after a funded call, same-transaction duplicate withdrawals, the `u64::MAX` cap, and batches containing an empty-snapshot Release) through the private helper `redeem_settled_value_and_distribute_for_testing`. A positive `settled_funds_value -> redeem_all_and_distribute` snapshot and accumulator overdraw rejection require a network E2E across a real consensus commit; the VM neither settles accumulators nor checks withdrawals against a balance.

```sh
sui move build
sui move test --coverage
```
