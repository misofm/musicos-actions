# Composition routed stake

Routes rewards earned by native Recording shares into the Composition's native
share royalty pool. All administrative actions accept the Composition's matching
admin capability. Payout currencies remain generic; ownership uses issuance IDs.

## Creation

`create_stake(composition, admin_cap, recording, composition_issuance,
recording_issuance, shares, ctx)` consumes a positive native Share and returns an
unshared RoutedStake. It verifies:

- The recording references this composition.
- Each issuance's subject is its corresponding music object.
- The deposited Share belongs to the recording issuance.
- The admin capability belongs to this composition.

These actions temporarily support issuance directly on music objects. A future
rights/licensing-object adapter must establish that relationship explicitly.
Core music identity alone does not establish ownership or license rights.

Native shares are passed directly; there is no share-coin accumulator redemption.
The caller chooses custody and when to share the returned routed stake.

## Lifecycle

`register` and `unregister` verify the recording relationship, routed-stake parent,
source pool derivation, source issuance, and composition admin cap. Registration
is independent for each payout currency. Unregister requires whole accrued rewards
to be swept first.

`unstake` returns the native Share once registrations are removed. `restake`
accepts shares of the original issuance only. The routed wrapper persists, while
the inner stake gets a fresh ID. Source and destination issuance IDs cannot change.

The underlying `sweep` is permissionless and sends rewards only to the configured
Composition issuance's pool. Rewards are parked at the destination pool address
when no holders are registered, so lifecycle exit is not blocked by that state.

`stake_address(composition, issuance_id)` predicts the wrapper ID. Issuance IDs
replace the old share-type parameters; indexers must use object/issuance IDs.

## Events and tests

Created, Unstaked, and Restaked action events have no share type parameters.
Registered and Unregistered events retain only the payout Currency parameter.
Their fields record object identities, principal values, and accounting snapshots.
The underlying pool and routed-stake modules emit their own events as well.

Native tests cover authenticated issuance and splitting, pro-rata reward routing,
principal conservation, lifecycle events, payout-currency separation, wide payout
counters, wrong-object/cap/issuance rejection, and empty/registered wrapper guards.
Coin-share redemption and share-phantom event separation are obsolete APIs.

```sh
sui move build
sui move test --coverage
sui move coverage source --module composition_routed_stake
```
