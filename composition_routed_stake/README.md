# Composition Routed Stake

Raw-cap actions accept the Composition capability as `admin_cap` and manage Composition-owned Recording shares. `create_stake` returns an unshared canonical `RoutedStake`; callers may register it before sharing. `unstake` returns principal as `Balance<RecordingShare>`, and `restake` consumes a caller-supplied balance. Permissionless reward delivery remains `routed_stake::routed_stake::sweep`; while the Composition pool has no registered stake, a sweep parks the reward at that pool's address (folded in later by `pool::sweep_and_deposit`), so `unregister`/`unstake` never wait on a Composition holder.

The adapter verifies the Recording belongs to the Composition, the routed stake derives from the Composition, and every earning pool derives from the supplied Recording. Guards and dependency calls retain their original order. `CompositionAdminCap<CompositionShare>` is a type-only credential here: the supplied cap's ID is recorded as provenance, but is not runtime-matched to the Composition.

Successful actions append one adapter event after the unchanged dependency call succeeds. The events preserve every relevant identity and post-call snapshot while retaining the dependency events and their ordering:

* `CompositionRoutedStakeCreatedEvent<RecordingShare, CompositionShare>` — exact order and types: `composition_id: address`, `admin_cap_id: address`, `recording_id: address`, `routed_stake_id: address`, `stake_id: address`, `sender: address`, `principal_value: u64`, `registration_count: u64`; 208-byte payload.
* `CompositionRoutedStakeRegisteredEvent<RecordingShare, CompositionShare, Currency>` — exact order and types: `composition_id: address`, `admin_cap_id: address`, `recording_id: address`, `routed_stake_id: address`, `stake_id: address`, `pool_id: address`, `principal_value: u64`, `registration_count_before: u64`, `registration_count_after: u64`, `pool_staked_shares_before: u64`, `pool_staked_shares_after: u64`, `pool_balance: u64`, `pool_cumulative_reward_per_share: u256`, `registration_debt: u256`, `pool_carry: u128`, `pool_cumulative_deposits: u128`; 336-byte payload.
* `CompositionRoutedStakeUnregisteredEvent<RecordingShare, CompositionShare, Currency>` — exact order and types: `composition_id: address`, `admin_cap_id: address`, `recording_id: address`, `routed_stake_id: address`, `stake_id: address`, `pool_id: address`, `principal_value: u64`, `registration_count_before: u64`, `registration_count_after: u64`, `pool_staked_shares_before: u64`, `pool_staked_shares_after: u64`, `pool_balance: u64`, `pool_cumulative_reward_per_share: u256`, `registration_debt: u256`, `pool_carry: u128`, `pool_cumulative_deposits: u128`, `forfeited_scaled_reward: u256`; 368-byte payload.
* `CompositionRoutedStakeUnstakedEvent<RecordingShare, CompositionShare>` — exact order and types: `composition_id: address`, `admin_cap_id: address`, `routed_stake_id: address`, `stake_id: address`, `principal_value: u64`; 136-byte payload.
* `CompositionRoutedStakeRestakedEvent<RecordingShare, CompositionShare>` — exact order and types: `composition_id: address`, `admin_cap_id: address`, `routed_stake_id: address`, `stake_id: address`, `sender: address`, `principal_value: u64`, `registration_count: u64`; 176-byte payload and a fresh wrapped stake ID.

In the registration events, `registration_count_before`/`registration_count_after` and `pool_staked_shares_before`/`pool_staked_shares_after` are the pre/post dependency-mutation snapshots. `principal_value`, both count fields, both share fields and `pool_balance` are `u64`; `pool_cumulative_reward_per_share`, `registration_debt` and `forfeited_scaled_reward` are scaled `u256`; `pool_carry` and `pool_cumulative_deposits` are `u128`. The Registered event records the newly inserted debt and post-call pool snapshots. The Unregistered event records the removed registration's pre-call debt, post-call pool snapshots, and `forfeited_scaled_reward = shares * index - registration_debt`. IDs are provenance from the supplied objects, including the supplied cap ID; no cap-ID equality check is added.

Views, `stake_address`, direct routed-stake operations and failed actions do not emit adapter events. A missing stake or registration is left to the dependency guard rather than being preempted by a snapshot.

The unfunded redemption unit test proves only the current accumulator split and returned-balance behavior; it does not prove network settlement and must not be read as acceptance of overdraw. Composing a positive `settled_funds_value` reader snapshot into `create_stake` requires a network E2E across a real consensus commit. The package tests cover the return-oriented lifecycle, published E2Es, independent generic instantiations and currencies, exact field-by-field BCS payloads, max-u64 principal handling, accounting residue, guard precedence and silent views/direct sweeps.

```sh
# Testnet (strict lint; production-only coverage summary must be 100%).
sui move build --build-env testnet --path composition_routed_stake --lint --warnings-are-errors
sui move test --test --build-env testnet --path composition_routed_stake --coverage --lint --warnings-are-errors
sui move coverage summary --build-env testnet --path composition_routed_stake --summarize-functions

# Mainnet (strict lint; production-only coverage summary must be 100%).
sui move build --build-env mainnet --path composition_routed_stake --lint --warnings-are-errors
sui move test --test --build-env mainnet --path composition_routed_stake --coverage --lint --warnings-are-errors
sui move coverage summary --build-env mainnet --path composition_routed_stake --summarize-functions
```
