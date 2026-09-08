// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Raw-cap lifecycle actions for Recording shares owned by a Composition.
///
/// The returned routed stake is unshared so callers can register it before
/// sharing. Reward sweeping remains the permissionless operation provided by
/// `routed_stake`; this package adds only protocol-specific parent checks.
module composition_routed_stake::composition_routed_stake;

use hikida::hikida;
use musicos::composition::{Composition, CompositionAdminCap};
use musicos::recording::Recording;
use royalty_pool::pool::{Self, RoyaltyPool};
use routed_stake::routed_stake::{Self, RoutedStake};
use sui::balance::Balance;

/// The RoyaltyPool is not derived from the supplied Recording.
const EPoolNotForRecording: u64 = 0;
/// The RoutedStake is not derived from the supplied Composition.
const EStakeNotForComposition: u64 = 1;
/// The Recording does not belong to the supplied Composition.
const ERecordingNotForComposition: u64 = 2;

/// Redeem Composition-owned Recording shares and return a new unshared routed
/// stake derived from the Composition.
public fun create_stake<RecordingShare, CompositionShare>(
    composition: &mut Composition<CompositionShare>,
    admin_cap: &CompositionAdminCap<CompositionShare>,
    recording: &Recording<RecordingShare, CompositionShare>,
    value: u64,
    ctx: &mut TxContext,
): RoutedStake<RecordingShare, CompositionShare> {
    assert_recording_for_composition(recording, object::id(composition));
    let uid = composition.uid_mut(admin_cap);
    let shares = hikida::redeem_balance<RecordingShare>(uid, value);
    routed_stake::new(uid, shares, ctx)
}

/// Register the routed stake with the canonical pool derived from `recording`.
public fun register<RecordingShare, CompositionShare, Currency>(
    composition: &mut Composition<CompositionShare>,
    admin_cap: &CompositionAdminCap<CompositionShare>,
    recording: &Recording<RecordingShare, CompositionShare>,
    routed: &mut RoutedStake<RecordingShare, CompositionShare>,
    pool: &mut RoyaltyPool<RecordingShare, Currency>,
) {
    let composition_id = object::id(composition);
    assert_recording_for_composition(recording, composition_id);
    assert_stake_for_composition(routed, composition_id);
    assert_pool_for_recording(pool, object::id(recording));
    routed.register(composition.uid_mut(admin_cap), pool)
}

/// Unregister the routed stake from the canonical Recording pool after all
/// claimable rewards have been swept.
public fun unregister<RecordingShare, CompositionShare, Currency>(
    composition: &mut Composition<CompositionShare>,
    admin_cap: &CompositionAdminCap<CompositionShare>,
    recording: &Recording<RecordingShare, CompositionShare>,
    routed: &mut RoutedStake<RecordingShare, CompositionShare>,
    pool: &mut RoyaltyPool<RecordingShare, Currency>,
) {
    let composition_id = object::id(composition);
    assert_recording_for_composition(recording, composition_id);
    assert_stake_for_composition(routed, composition_id);
    assert_pool_for_recording(pool, object::id(recording));
    routed.unregister(composition.uid_mut(admin_cap), pool)
}

/// Remove the routed position and return its Recording-share principal.
public fun unstake<RecordingShare, CompositionShare>(
    composition: &mut Composition<CompositionShare>,
    admin_cap: &CompositionAdminCap<CompositionShare>,
    routed: &mut RoutedStake<RecordingShare, CompositionShare>,
): Balance<RecordingShare> {
    assert_stake_for_composition(routed, object::id(composition));
    routed.unstake(composition.uid_mut(admin_cap))
}

/// Refill an empty routed stake with caller-supplied Recording-share principal.
public fun restake<RecordingShare, CompositionShare>(
    composition: &mut Composition<CompositionShare>,
    admin_cap: &CompositionAdminCap<CompositionShare>,
    routed: &mut RoutedStake<RecordingShare, CompositionShare>,
    shares: Balance<RecordingShare>,
    ctx: &mut TxContext,
) {
    assert_stake_for_composition(routed, object::id(composition));
    routed.restake(composition.uid_mut(admin_cap), shares, ctx)
}

/// Canonical routed-stake address for this Composition and RecordingShare.
public fun stake_address<RecordingShare, CompositionShare>(
    composition: &Composition<CompositionShare>,
): address {
    routed_stake::derived_address<RecordingShare>(object::id(composition))
}

fun assert_recording_for_composition<RecordingShare, CompositionShare>(
    recording: &Recording<RecordingShare, CompositionShare>,
    composition_id: ID,
) {
    assert!(recording.composition_id() == composition_id, ERecordingNotForComposition)
}

fun assert_pool_for_recording<RecordingShare, Currency>(
    pool: &RoyaltyPool<RecordingShare, Currency>,
    recording_id: ID,
) {
    assert!(
        object::id(pool).to_address()
            == pool::derived_address<RecordingShare, Currency>(recording_id),
        EPoolNotForRecording,
    )
}

fun assert_stake_for_composition<RecordingShare, CompositionShare>(
    routed: &RoutedStake<RecordingShare, CompositionShare>,
    composition_id: ID,
) {
    assert!(
        object::id(routed).to_address()
            == routed_stake::derived_address<RecordingShare>(composition_id),
        EStakeNotForComposition,
    )
}
