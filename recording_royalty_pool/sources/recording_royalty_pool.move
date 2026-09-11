// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Raw-cap, custody-agnostic royalty-pool actions for musicos Recordings.
///
/// Every mutating action requires the Recording's own admin capability. The
/// canonical pool remains derived from the Recording and is returned unshared.
module recording_royalty_pool::recording_royalty_pool;

use hikida::hikida;
use musicos::recording::{Recording, RecordingAdminCap};
use royalty_pool::pool::{Self, RoyaltyPool};
use sui::coin::Coin;
use sui::event::emit;
use sui::transfer::Receiving;

// === Events ===

/// Complete provenance and initial pool snapshot for a newly created pool.
/// The dependency's creation event remains first; this action event follows
/// it with the recording, composition, and admin-cap identities.
public struct RecordingRoyaltyPoolCreatedEvent<phantom RecordingShare, phantom CompositionShare, phantom Currency>
    has copy, drop {
    recording_id: address,
    composition_id: address,
    admin_cap_id: address,
    pool_id: address,
    pool_balance: u64,
    staked_shares: u64,
    cumulative_reward_per_share: u256,
    carry: u128,
    cumulative_deposits: u128,
}

/// Complete provenance, input coin identities, and before/after pool snapshot
/// for a successful coin receive and deposit.
public struct RecordingCoinsDepositedEvent<phantom RecordingShare, phantom CompositionShare, phantom Currency>
    has copy, drop {
    recording_id: address,
    composition_id: address,
    admin_cap_id: address,
    pool_id: address,
    amount: u64,
    pool_balance_before: u64,
    pool_balance_after: u64,
    staked_shares: u64,
    reward_per_share_before: u256,
    reward_per_share_after: u256,
    carry_before: u128,
    carry_after: u128,
    cumulative_deposits_before: u128,
    cumulative_deposits_after: u128,
    coin_ids: vector<address>,
}

/// Complete provenance, accumulator source amount, and before/after pool
/// snapshot for a successful funds-accumulator redemption and deposit.
public struct RecordingFundsDepositedEvent<phantom RecordingShare, phantom CompositionShare, phantom Currency>
    has copy, drop {
    recording_id: address,
    composition_id: address,
    admin_cap_id: address,
    pool_id: address,
    amount: u64,
    pool_balance_before: u64,
    pool_balance_after: u64,
    staked_shares: u64,
    reward_per_share_before: u256,
    reward_per_share_after: u256,
    carry_before: u128,
    carry_after: u128,
    cumulative_deposits_before: u128,
    cumulative_deposits_after: u128,
}

/// Create and return the canonical unshared pool derived from `recording`.
/// Emits `RecordingRoyaltyPoolCreatedEvent` after successful creation.
public fun new_pool<RecordingShare, CompositionShare, Currency>(
    recording: &mut Recording<RecordingShare, CompositionShare>,
    admin_cap: &RecordingAdminCap<RecordingShare>,
): RoyaltyPool<RecordingShare, Currency> {
    let recording_id = object::id(recording).to_address();
    let composition_id = recording.composition_id().to_address();
    let admin_cap_id = object::id(admin_cap).to_address();
    let pool = pool::new(recording.uid_mut(admin_cap));
    emit(RecordingRoyaltyPoolCreatedEvent<RecordingShare, CompositionShare, Currency> {
        recording_id,
        composition_id,
        admin_cap_id,
        pool_id: object::id(&pool).to_address(),
        pool_balance: pool.balance().value(),
        staked_shares: pool.staked_shares(),
        cumulative_reward_per_share: pool.cumulative_reward_per_share(),
        carry: pool.carry(),
        cumulative_deposits: pool.cumulative_deposits(),
    });
    pool
}

/// Receive selected coins sent to the Recording and deposit their balance
/// into the canonical pool derived from that same Recording.
/// Emits `RecordingCoinsDepositedEvent` after successful deposit.
public fun receive_and_deposit<RecordingShare, CompositionShare, Currency>(
    recording: &mut Recording<RecordingShare, CompositionShare>,
    admin_cap: &RecordingAdminCap<RecordingShare>,
    pool: &mut RoyaltyPool<RecordingShare, Currency>,
    coins: vector<Receiving<Coin<Currency>>>,
) {
    pool.assert_derived_from(object::id(recording));
    let recording_id = object::id(recording).to_address();
    let composition_id = recording.composition_id().to_address();
    let admin_cap_id = object::id(admin_cap).to_address();
    let pool_id = object::id(pool).to_address();
    let pool_balance_before = pool.balance().value();
    let staked_shares = pool.staked_shares();
    let reward_per_share_before = pool.cumulative_reward_per_share();
    let carry_before = pool.carry();
    let cumulative_deposits_before = pool.cumulative_deposits();
    let coin_ids = coins.map_ref!(|coin| sui::transfer::receiving_object_id(coin).to_address());
    let received = hikida::receive_balance(recording.uid_mut(admin_cap), coins);
    let amount = received.value();
    pool.deposit(received);
    emit(RecordingCoinsDepositedEvent<RecordingShare, CompositionShare, Currency> {
        recording_id,
        composition_id,
        admin_cap_id,
        pool_id,
        amount,
        pool_balance_before,
        pool_balance_after: pool.balance().value(),
        staked_shares,
        reward_per_share_before,
        reward_per_share_after: pool.cumulative_reward_per_share(),
        carry_before,
        carry_after: pool.carry(),
        cumulative_deposits_before,
        cumulative_deposits_after: pool.cumulative_deposits(),
        coin_ids,
    });
}

/// Redeem `value` from the Recording's funds accumulator and deposit it into
/// the canonical pool derived from that same Recording.
/// Emits `RecordingFundsDepositedEvent` after successful deposit.
public fun redeem_and_deposit<RecordingShare, CompositionShare, Currency>(
    recording: &mut Recording<RecordingShare, CompositionShare>,
    admin_cap: &RecordingAdminCap<RecordingShare>,
    pool: &mut RoyaltyPool<RecordingShare, Currency>,
    value: u64,
) {
    pool.assert_derived_from(object::id(recording));
    let recording_id = object::id(recording).to_address();
    let composition_id = recording.composition_id().to_address();
    let admin_cap_id = object::id(admin_cap).to_address();
    let pool_id = object::id(pool).to_address();
    let pool_balance_before = pool.balance().value();
    let staked_shares = pool.staked_shares();
    let reward_per_share_before = pool.cumulative_reward_per_share();
    let carry_before = pool.carry();
    let cumulative_deposits_before = pool.cumulative_deposits();
    let redeemed = hikida::redeem_balance<Currency>(recording.uid_mut(admin_cap), value);
    let amount = redeemed.value();
    pool.deposit(redeemed);
    emit(RecordingFundsDepositedEvent<RecordingShare, CompositionShare, Currency> {
        recording_id,
        composition_id,
        admin_cap_id,
        pool_id,
        amount,
        pool_balance_before,
        pool_balance_after: pool.balance().value(),
        staked_shares,
        reward_per_share_before,
        reward_per_share_after: pool.cumulative_reward_per_share(),
        carry_before,
        carry_after: pool.carry(),
        cumulative_deposits_before,
        cumulative_deposits_after: pool.cumulative_deposits(),
    });
}

/// Canonical pool address for this Recording, share type, and Currency.
public fun pool_address<RecordingShare, CompositionShare, Currency>(
    recording: &Recording<RecordingShare, CompositionShare>,
): address {
    pool::derived_address<RecordingShare, Currency>(object::id(recording))
}

// === Test Functions ===

#[test_only]
public fun created_event_fields<RecordingShare, CompositionShare, Currency>(
    event: &RecordingRoyaltyPoolCreatedEvent<RecordingShare, CompositionShare, Currency>,
): (address, address, address, address, u64, u64, u256, u128, u128) {
    (
        event.recording_id,
        event.composition_id,
        event.admin_cap_id,
        event.pool_id,
        event.pool_balance,
        event.staked_shares,
        event.cumulative_reward_per_share,
        event.carry,
        event.cumulative_deposits,
    )
}

#[test_only]
public fun coins_deposited_event_fields<RecordingShare, CompositionShare, Currency>(
    event: &RecordingCoinsDepositedEvent<RecordingShare, CompositionShare, Currency>,
): (address, address, address, address, u64, u64, u64, u64, u256, u256, u128, u128, u128, u128, vector<address>) {
    (
        event.recording_id,
        event.composition_id,
        event.admin_cap_id,
        event.pool_id,
        event.amount,
        event.pool_balance_before,
        event.pool_balance_after,
        event.staked_shares,
        event.reward_per_share_before,
        event.reward_per_share_after,
        event.carry_before,
        event.carry_after,
        event.cumulative_deposits_before,
        event.cumulative_deposits_after,
        event.coin_ids,
    )
}

#[test_only]
public fun funds_deposited_event_fields<RecordingShare, CompositionShare, Currency>(
    event: &RecordingFundsDepositedEvent<RecordingShare, CompositionShare, Currency>,
): (address, address, address, address, u64, u64, u64, u64, u256, u256, u128, u128, u128, u128) {
    (
        event.recording_id,
        event.composition_id,
        event.admin_cap_id,
        event.pool_id,
        event.amount,
        event.pool_balance_before,
        event.pool_balance_after,
        event.staked_shares,
        event.reward_per_share_before,
        event.reward_per_share_after,
        event.carry_before,
        event.carry_after,
        event.cumulative_deposits_before,
        event.cumulative_deposits_after,
    )
}
