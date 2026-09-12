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
use royalty_pool::stake::{Self, Stake};
use routed_stake::routed_stake::{Self, RoutedStake};
use std::type_name;
use sui::balance::Balance;
use sui::event::emit;

/// The RoyaltyPool is not derived from the supplied Recording.
const EPoolNotForRecording: u64 = 0;
/// The RoutedStake is not derived from the supplied Composition.
const EStakeNotForComposition: u64 = 1;
/// The Recording does not belong to the supplied Composition.
const ERecordingNotForComposition: u64 = 2;
/// Zero shares cannot create a routed stake.
const ENoValueToRedeem: u64 = 3;

// === Events ===

/// Complete provenance and post-call snapshot for a newly created routed
/// stake. The dependency's own creation events remain in their original
/// order; this adapter event follows them.
public struct CompositionRoutedStakeCreatedEvent<phantom RecordingShare, phantom CompositionShare>
    has copy, drop {
    composition_id: address,
    admin_cap_id: address,
    recording_id: address,
    routed_stake_id: address,
    stake_id: address,
    sender: address,
    principal_value: u64,
    registration_count: u64,
}

/// Complete registration snapshot after the wrapped stake is registered.
public struct CompositionRoutedStakeRegisteredEvent<phantom RecordingShare, phantom CompositionShare, phantom Currency>
    has copy, drop {
    composition_id: address,
    admin_cap_id: address,
    recording_id: address,
    routed_stake_id: address,
    stake_id: address,
    pool_id: address,
    principal_value: u64,
    registration_count_before: u64,
    registration_count_after: u64,
    pool_staked_shares_before: u64,
    pool_staked_shares_after: u64,
    pool_balance: u64,
    pool_cumulative_reward_per_share: u256,
    registration_debt: u256,
    pool_carry: u128,
    pool_cumulative_deposits: u128,
}

/// Complete unregistration snapshot. `forfeited_scaled_reward` is the
/// sub-base-unit residue removed by a successful pool unregister, in
/// `shares * index - debt` units.
public struct CompositionRoutedStakeUnregisteredEvent<phantom RecordingShare, phantom CompositionShare, phantom Currency>
    has copy, drop {
    composition_id: address,
    admin_cap_id: address,
    recording_id: address,
    routed_stake_id: address,
    stake_id: address,
    pool_id: address,
    principal_value: u64,
    registration_count_before: u64,
    registration_count_after: u64,
    pool_staked_shares_before: u64,
    pool_staked_shares_after: u64,
    pool_balance: u64,
    pool_cumulative_reward_per_share: u256,
    registration_debt: u256,
    pool_carry: u128,
    pool_cumulative_deposits: u128,
    forfeited_scaled_reward: u256,
}

/// Complete provenance for a successful removal of the wrapped principal.
public struct CompositionRoutedStakeUnstakedEvent<phantom RecordingShare, phantom CompositionShare>
    has copy, drop {
    composition_id: address,
    admin_cap_id: address,
    routed_stake_id: address,
    stake_id: address,
    principal_value: u64,
}

/// Complete provenance for a successful refill. A restake always creates a
/// fresh wrapped stake object while retaining the routed wrapper ID.
public struct CompositionRoutedStakeRestakedEvent<phantom RecordingShare, phantom CompositionShare>
    has copy, drop {
    composition_id: address,
    admin_cap_id: address,
    routed_stake_id: address,
    stake_id: address,
    sender: address,
    principal_value: u64,
    registration_count: u64,
}

/// Redeem Composition-owned Recording shares and return a new unshared routed
/// stake derived from the Composition.
public fun create_stake<RecordingShare, CompositionShare>(
    composition: &mut Composition<CompositionShare>,
    admin_cap: &CompositionAdminCap<CompositionShare>,
    recording: &Recording<RecordingShare, CompositionShare>,
    value: u64,
    ctx: &mut TxContext,
): RoutedStake<RecordingShare, CompositionShare> {
    let composition_id = object::id(composition);
    assert_recording_for_composition(recording, composition_id);
    let admin_cap_id = object::id(admin_cap).to_address();
    let recording_id = object::id(recording).to_address();
    let sender = tx_context::sender(ctx);
    let uid = composition.uid_mut(admin_cap);
    assert!(value > 0, ENoValueToRedeem);
    let shares = hikida::redeem_balance<RecordingShare>(uid, value);
    let routed = routed_stake::new(uid, shares, ctx);
    let stake_id = object::id(routed.stake()).to_address();
    emit(CompositionRoutedStakeCreatedEvent<RecordingShare, CompositionShare> {
        composition_id: composition_id.to_address(),
        admin_cap_id,
        recording_id,
        routed_stake_id: object::id(&routed).to_address(),
        stake_id,
        sender,
        principal_value: routed.value(),
        registration_count: stake::registration_count(routed.stake()),
    });
    routed
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
    let composition_id = composition_id.to_address();
    let admin_cap_id = object::id(admin_cap).to_address();
    let recording_id = object::id(recording).to_address();
    let routed_stake_id = object::id(routed).to_address();
    let pool_id = object::id(pool).to_address();
    let mut stake_id = @0x0;
    let mut principal = 0;
    let mut registration_count_before = 0;
    if (routed.has_stake()) {
        let wrapped = routed.stake();
        stake_id = object::id(wrapped).to_address();
        principal = wrapped.value();
        registration_count_before = stake::registration_count(wrapped);
    };
    let pool_staked_shares_before = pool.staked_shares();
    routed.register(composition.uid_mut(admin_cap), pool);
    let wrapped = routed.stake();
    let currency = type_name::with_defining_ids<Currency>();
    let registration = stake::get_registration(wrapped, &currency);
    emit(CompositionRoutedStakeRegisteredEvent<RecordingShare, CompositionShare, Currency> {
        composition_id,
        admin_cap_id,
        recording_id,
        routed_stake_id,
        stake_id,
        pool_id,
        principal_value: principal,
        registration_count_before,
        registration_count_after: stake::registration_count(wrapped),
        pool_staked_shares_before,
        pool_staked_shares_after: pool.staked_shares(),
        pool_balance: pool.balance().value(),
        pool_cumulative_reward_per_share: pool.cumulative_reward_per_share(),
        registration_debt: stake::registration_debt(registration),
        pool_carry: pool.carry(),
        pool_cumulative_deposits: pool.cumulative_deposits(),
    });
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
    let composition_id = composition_id.to_address();
    let admin_cap_id = object::id(admin_cap).to_address();
    let recording_id = object::id(recording).to_address();
    let routed_stake_id = object::id(routed).to_address();
    let pool_id = object::id(pool).to_address();
    let currency = type_name::with_defining_ids<Currency>();
    let mut stake_id = @0x0;
    let mut principal = 0;
    let mut registration_count_before = 0;
    let mut registration_debt = 0;
    if (routed.has_stake()) {
        let wrapped = routed.stake();
        stake_id = object::id(wrapped).to_address();
        principal = wrapped.value();
        registration_count_before = stake::registration_count(wrapped);
        if (stake::has_registration(wrapped, &currency)) {
            registration_debt = stake::registration_debt(
                stake::get_registration(wrapped, &currency),
            );
        };
    };
    let pool_staked_shares_before = pool.staked_shares();
    routed.unregister(composition.uid_mut(admin_cap), pool);
    let forfeited_scaled_reward =
        (principal as u256) * pool.cumulative_reward_per_share() - registration_debt;
    let wrapped = routed.stake();
    emit(CompositionRoutedStakeUnregisteredEvent<RecordingShare, CompositionShare, Currency> {
        composition_id,
        admin_cap_id,
        recording_id,
        routed_stake_id,
        stake_id,
        pool_id,
        principal_value: principal,
        registration_count_before,
        registration_count_after: stake::registration_count(wrapped),
        pool_staked_shares_before,
        pool_staked_shares_after: pool.staked_shares(),
        pool_balance: pool.balance().value(),
        pool_cumulative_reward_per_share: pool.cumulative_reward_per_share(),
        registration_debt,
        pool_carry: pool.carry(),
        pool_cumulative_deposits: pool.cumulative_deposits(),
        forfeited_scaled_reward,
    });
}

/// Remove the routed position and return its Recording-share principal.
public fun unstake<RecordingShare, CompositionShare>(
    composition: &mut Composition<CompositionShare>,
    admin_cap: &CompositionAdminCap<CompositionShare>,
    routed: &mut RoutedStake<RecordingShare, CompositionShare>,
): Balance<RecordingShare> {
    let composition_id = object::id(composition);
    assert_stake_for_composition(routed, composition_id);
    let composition_id = composition_id.to_address();
    let admin_cap_id = object::id(admin_cap).to_address();
    let routed_stake_id = object::id(routed).to_address();
    let mut stake_id = @0x0;
    if (routed.has_stake()) {
        stake_id = object::id(routed.stake()).to_address();
    };
    let principal = routed.unstake(composition.uid_mut(admin_cap));
    emit(CompositionRoutedStakeUnstakedEvent<RecordingShare, CompositionShare> {
        composition_id,
        admin_cap_id,
        routed_stake_id,
        stake_id,
        principal_value: principal.value(),
    });
    principal
}

/// Refill an empty routed stake with caller-supplied Recording-share principal.
public fun restake<RecordingShare, CompositionShare>(
    composition: &mut Composition<CompositionShare>,
    admin_cap: &CompositionAdminCap<CompositionShare>,
    routed: &mut RoutedStake<RecordingShare, CompositionShare>,
    shares: Balance<RecordingShare>,
    ctx: &mut TxContext,
) {
    let composition_id = object::id(composition);
    assert_stake_for_composition(routed, composition_id);
    let admin_cap_id = object::id(admin_cap).to_address();
    let routed_stake_id = object::id(routed).to_address();
    let sender = tx_context::sender(ctx);
    routed.restake(composition.uid_mut(admin_cap), shares, ctx);
    let wrapped = routed.stake();
    emit(CompositionRoutedStakeRestakedEvent<RecordingShare, CompositionShare> {
        composition_id: composition_id.to_address(),
        admin_cap_id,
        routed_stake_id,
        stake_id: object::id(wrapped).to_address(),
        sender,
        principal_value: wrapped.value(),
        registration_count: stake::registration_count(wrapped),
    });
}

// === Test Functions ===

#[test_only]
public fun created_event_fields<RecordingShare, CompositionShare>(
    event: &CompositionRoutedStakeCreatedEvent<RecordingShare, CompositionShare>,
): (address, address, address, address, address, address, u64, u64) {
    (
        event.composition_id,
        event.admin_cap_id,
        event.recording_id,
        event.routed_stake_id,
        event.stake_id,
        event.sender,
        event.principal_value,
        event.registration_count,
    )
}

#[test_only]
public fun registered_event_fields<RecordingShare, CompositionShare, Currency>(
    event: &CompositionRoutedStakeRegisteredEvent<RecordingShare, CompositionShare, Currency>,
): (address, address, address, address, address, address, u64, u64, u64, u64, u64, u64, u256, u256, u128, u128) {
    (
        event.composition_id,
        event.admin_cap_id,
        event.recording_id,
        event.routed_stake_id,
        event.stake_id,
        event.pool_id,
        event.principal_value,
        event.registration_count_before,
        event.registration_count_after,
        event.pool_staked_shares_before,
        event.pool_staked_shares_after,
        event.pool_balance,
        event.pool_cumulative_reward_per_share,
        event.registration_debt,
        event.pool_carry,
        event.pool_cumulative_deposits,
    )
}

#[test_only]
public fun unregistered_event_fields<RecordingShare, CompositionShare, Currency>(
    event: &CompositionRoutedStakeUnregisteredEvent<RecordingShare, CompositionShare, Currency>,
): (address, address, address, address, address, address, u64, u64, u64, u64, u64, u64, u256, u256, u128, u128, u256) {
    (
        event.composition_id,
        event.admin_cap_id,
        event.recording_id,
        event.routed_stake_id,
        event.stake_id,
        event.pool_id,
        event.principal_value,
        event.registration_count_before,
        event.registration_count_after,
        event.pool_staked_shares_before,
        event.pool_staked_shares_after,
        event.pool_balance,
        event.pool_cumulative_reward_per_share,
        event.registration_debt,
        event.pool_carry,
        event.pool_cumulative_deposits,
        event.forfeited_scaled_reward,
    )
}

#[test_only]
public fun unstaked_event_fields<RecordingShare, CompositionShare>(
    event: &CompositionRoutedStakeUnstakedEvent<RecordingShare, CompositionShare>,
): (address, address, address, address, u64) {
    (
        event.composition_id,
        event.admin_cap_id,
        event.routed_stake_id,
        event.stake_id,
        event.principal_value,
    )
}

#[test_only]
public fun restaked_event_fields<RecordingShare, CompositionShare>(
    event: &CompositionRoutedStakeRestakedEvent<RecordingShare, CompositionShare>,
): (address, address, address, address, address, u64, u64) {
    (
        event.composition_id,
        event.admin_cap_id,
        event.routed_stake_id,
        event.stake_id,
        event.sender,
        event.principal_value,
        event.registration_count,
    )
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
