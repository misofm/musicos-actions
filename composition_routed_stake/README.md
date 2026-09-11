# Composition Routed Stake

Raw-cap actions accept the Composition capability as `admin_cap` and manage Composition-owned Recording shares. `create_stake` returns an unshared canonical `RoutedStake`; callers may register it before sharing. `unstake` returns principal as `Balance<RecordingShare>`, and `restake` consumes a caller-supplied balance. Permissionless reward delivery remains `routed_stake::routed_stake::sweep`; while the Composition pool has no registered stake, a sweep parks the reward at that pool's address (folded in later by `pool::sweep_and_deposit`), so `unregister`/`unstake` never wait on a Composition holder.

The adapter verifies the Recording belongs to the Composition, the routed stake derives from the Composition, and every earning pool derives from the supplied Recording. Guards and dependency calls retain their original order. `CompositionAdminCap<CompositionShare>` is a type-only credential here: the supplied cap's ID is recorded as provenance, but is not runtime-matched to the Composition.

Successful actions append one adapter event after the unchanged dependency call succeeds. The events preserve every relevant identity and post-call snapshot while retaining the dependency events and their ordering:

* `CompositionRoutedStakeCreatedEvent<RecordingShare, CompositionShare>` — ordered addresses `composition_id`, `admin_cap_id`, `recording_id`, `routed_stake_id`, `stake_id`, `sender`, then `principal_value: u64` and `registration_count: u64`; 208-byte payload.
* `CompositionRoutedStakeRegisteredEvent<RecordingShare, CompositionShare, Currency>` — `composition_id`, `admin_cap_id`, `recording_id`, `routed_stake_id`, `stake_id`, `pool_id`, `principal_value`, registration counts, pool shares, `pool_balance`, index, debt, carry and cumulative deposits; 336-byte payload.
* `CompositionRoutedStakeUnregisteredEvent<RecordingShare, CompositionShare, Currency>` — the same ordered fields, plus `forfeited_scaled_reward` (`shares * index - registration_debt`); 368-byte payload.
* `CompositionRoutedStakeUnstakedEvent<RecordingShare, CompositionShare>` — `composition_id`, `admin_cap_id`, `routed_stake_id`, `stake_id`, `principal_value`; 136-byte payload.
* `CompositionRoutedStakeRestakedEvent<RecordingShare, CompositionShare>` — `composition_id`, `admin_cap_id`, `routed_stake_id`, `stake_id`, `sender`, `principal_value`, `registration_count`; 176-byte payload and a fresh wrapped stake ID.

In the registration events, `principal_value`, registration counts, pool shares and `pool_balance` are `u64`; the pool index, registration debt and forfeited residue are scaled `u256`; pool carry and cumulative deposits are `u128`. Registered snapshots contain the newly inserted debt; unregistered snapshots contain the removed debt and `shares * index - registration_debt` residue. IDs are provenance from the supplied objects, including the supplied cap ID; no cap-ID equality check is added.

Views, `stake_address`, direct routed-stake operations and failed actions do not emit adapter events. A missing stake or registration is left to the dependency guard rather than being preempted by a snapshot.

Composing a positive `settled_funds_value` reader snapshot into `create_stake` requires a network E2E across a real consensus commit. The package tests cover the return-oriented lifecycle, published E2Es, independent generic instantiations and currencies, exact field-by-field BCS payloads, max-u64 principal handling, accounting residue, guard precedence and silent views/direct sweeps.

```sh
sui move build --build-env testnet
sui move test --test --build-env testnet --coverage
sui move coverage summary --build-env testnet --summarize-functions
```
