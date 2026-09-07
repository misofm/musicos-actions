# Composition Routed Stake

Raw-cap actions accept the Composition capability as `admin_cap` and manage Composition-owned Recording shares. `create_stake` returns an unshared canonical `RoutedStake`; callers may register it before sharing. `unstake` returns principal as `Balance<RecordingShare>`, and `restake` consumes a caller-supplied balance. Permissionless reward delivery remains `routed_stake::routed_stake::sweep`; while the Composition pool has no registered stake, a sweep parks the reward at that pool's address (folded in later by `pool::sweep_and_deposit`), so `unregister`/`unstake` never wait on a Composition holder.

The adapter verifies the Recording belongs to the Composition, the routed stake derives from the Composition, and every earning pool derives from the supplied Recording. Composing a positive `settled_funds_value` reader snapshot into `create_stake` requires a network E2E across a real consensus commit.

```sh
sui move build
sui move test --coverage
```
