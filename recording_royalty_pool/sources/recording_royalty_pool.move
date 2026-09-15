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
use sui::accumulator::AccumulatorRoot;
use sui::balance;
use sui::coin::Coin;
use sui::event::emit;
use sui::transfer::Receiving;

// === Errors ===

/// Empty coin input is rejected by this Action even though Hikida is total.
const ENoCoinsToReceive: u64 = 0;

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
    coin_count: u64,
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
    let coin_count = coins.length();
    let uid = recording.uid_mut(admin_cap);
    assert!(!coins.is_empty(), ENoCoinsToReceive);
    let received = hikida::receive_coins_as_balance(uid, coins);
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
        coin_count,
    });
}

/// Redeem all funds settled at the Recording's address at the start of the
/// current consensus commit and deposit them into the canonical pool derived
/// from that same Recording.
///
/// This is the only accumulator redemption path: callers cannot select an
/// amount, so a permissionless crank cannot fragment revenue. The call is an
/// authorized no-op that emits no event when the settled snapshot is zero or
/// when the pool has no registered stake. With no stakers nothing is
/// redeemed: the funds stay in the Recording's accumulator until a stake
/// registers, rather than being folded into a pool nobody can claim from.
/// Either no-op lets an item cranked in an earlier consensus commit, or an
/// unstaked item, pass through a batched crank untouched. The framework
/// snapshot is capped at `u64::MAX`; excess and newly sent funds settle for a
/// later call.
///
/// The snapshot is written only by consensus settlement, so within one commit
/// it is constant: redeeming the same Recording twice in one PTB, or from two
/// transactions in the same commit, withdraws the snapshot twice and the
/// network fails that whole transaction with `InsufficientFundsForWithdraw`
/// (a transaction-level failure, not a Move abort). Crankers must include
/// each object at most once per PTB and treat that status as retry next
/// commit.
/// Emits `RecordingFundsDepositedEvent` after a successful deposit.
public fun redeem_all_and_deposit<RecordingShare, CompositionShare, Currency>(
    recording: &mut Recording<RecordingShare, CompositionShare>,
    admin_cap: &RecordingAdminCap<RecordingShare>,
    pool: &mut RoyaltyPool<RecordingShare, Currency>,
    root: &AccumulatorRoot,
) {
    let value = balance::settled_funds_value<Currency>(root, object::id(recording).to_address());
    redeem_settled_value_and_deposit<RecordingShare, CompositionShare, Currency>(
        recording,
        admin_cap,
        pool,
        value,
    )
}

/// Redeem a previously read settled snapshot when it is positive and the pool
/// has registered stake. The pool derivation is checked before either
/// short-circuit so a wrong pool is rejected even when there is nothing to do.
fun redeem_settled_value_and_deposit<RecordingShare, CompositionShare, Currency>(
    recording: &mut Recording<RecordingShare, CompositionShare>,
    admin_cap: &RecordingAdminCap<RecordingShare>,
    pool: &mut RoyaltyPool<RecordingShare, Currency>,
    value: u64,
) {
    pool.assert_derived_from(object::id(recording));
    // Intentionally short-circuits before `uid_mut(admin_cap)`: Recording admin
    // caps are matched by phantom share type only (no object-id check exists
    // to skip), so returning early is security-neutral.
    if (value == 0 || pool.staked_shares() == 0) return;
    let recording_id = object::id(recording).to_address();
    let composition_id = recording.composition_id().to_address();
    let admin_cap_id = object::id(admin_cap).to_address();
    let pool_id = object::id(pool).to_address();
    let pool_balance_before = pool.balance().value();
    let staked_shares = pool.staked_shares();
    let reward_per_share_before = pool.cumulative_reward_per_share();
    let carry_before = pool.carry();
    let cumulative_deposits_before = pool.cumulative_deposits();
    let uid = recording.uid_mut(admin_cap);
    let redeemed = hikida::redeem_balance<Currency>(uid, value);
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
): (address, address, address, address, u64, u64, u64, u64, u256, u256, u128, u128, u128, u128, u64) {
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
        event.coin_count,
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

#[test_only]
public fun redeem_settled_value_and_deposit_for_testing<RecordingShare, CompositionShare, Currency>(
    recording: &mut Recording<RecordingShare, CompositionShare>,
    admin_cap: &RecordingAdminCap<RecordingShare>,
    pool: &mut RoyaltyPool<RecordingShare, Currency>,
    value: u64,
) {
    redeem_settled_value_and_deposit<RecordingShare, CompositionShare, Currency>(
        recording,
        admin_cap,
        pool,
        value,
    )
}
