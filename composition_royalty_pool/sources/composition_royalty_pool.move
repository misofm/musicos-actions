// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Raw-cap, custody-agnostic royalty-pool actions for musicos Compositions.
///
/// Every mutating action requires the Composition's own admin capability.
/// The canonical pool remains derived from the Composition, and callers
/// decide when to register stakes and share a newly returned pool.
module composition_royalty_pool::composition_royalty_pool;

use hikida::hikida;
use musicos::composition::{Composition, CompositionAdminCap};
use royalty_pool::pool::{Self, RoyaltyPool};
use sui::coin::Coin;
use sui::event::emit;
use sui::transfer::Receiving;

// === Events ===

/// Complete provenance and initial pool snapshot for a newly created pool.
/// The dependency's creation event remains first; this action event follows
/// it with the composition and admin-cap identities used by the action.
public struct CompositionRoyaltyPoolCreatedEvent<phantom CompositionShare, phantom Currency>
    has copy, drop {
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
public struct CompositionCoinsDepositedEvent<phantom CompositionShare, phantom Currency>
    has copy, drop {
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
public struct CompositionFundsDepositedEvent<phantom CompositionShare, phantom Currency>
    has copy, drop {
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

/// Create and return the canonical unshared pool derived from `composition`.
/// Emits `CompositionRoyaltyPoolCreatedEvent` after successful creation.
public fun new_pool<CompositionShare, Currency>(
    composition: &mut Composition<CompositionShare>,
    admin_cap: &CompositionAdminCap<CompositionShare>,
): RoyaltyPool<CompositionShare, Currency> {
    let composition_id = object::id(composition).to_address();
    let admin_cap_id = object::id(admin_cap).to_address();
    let pool = pool::new(composition.uid_mut(admin_cap));
    emit(CompositionRoyaltyPoolCreatedEvent<CompositionShare, Currency> {
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

/// Receive selected coins sent to the Composition and deposit their balance
/// into the canonical pool derived from that same Composition.
/// Emits `CompositionCoinsDepositedEvent` after successful deposit.
public fun receive_and_deposit<CompositionShare, Currency>(
    composition: &mut Composition<CompositionShare>,
    admin_cap: &CompositionAdminCap<CompositionShare>,
    pool: &mut RoyaltyPool<CompositionShare, Currency>,
    coins: vector<Receiving<Coin<Currency>>>,
) {
    pool.assert_derived_from(object::id(composition));
    let composition_id = object::id(composition).to_address();
    let admin_cap_id = object::id(admin_cap).to_address();
    let pool_id = object::id(pool).to_address();
    let pool_balance_before = pool.balance().value();
    let staked_shares = pool.staked_shares();
    let reward_per_share_before = pool.cumulative_reward_per_share();
    let carry_before = pool.carry();
    let cumulative_deposits_before = pool.cumulative_deposits();
    let coin_ids = coins.map_ref!(|coin| sui::transfer::receiving_object_id(coin).to_address());
    let received = hikida::receive_balance(composition.uid_mut(admin_cap), coins);
    let amount = received.value();
    pool.deposit(received);
    emit(CompositionCoinsDepositedEvent<CompositionShare, Currency> {
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

/// Redeem `value` from the Composition's funds accumulator and deposit it
/// into the canonical pool derived from that same Composition.
/// Emits `CompositionFundsDepositedEvent` after successful deposit.
public fun redeem_and_deposit<CompositionShare, Currency>(
    composition: &mut Composition<CompositionShare>,
    admin_cap: &CompositionAdminCap<CompositionShare>,
    pool: &mut RoyaltyPool<CompositionShare, Currency>,
    value: u64,
) {
    pool.assert_derived_from(object::id(composition));
    let composition_id = object::id(composition).to_address();
    let admin_cap_id = object::id(admin_cap).to_address();
    let pool_id = object::id(pool).to_address();
    let pool_balance_before = pool.balance().value();
    let staked_shares = pool.staked_shares();
    let reward_per_share_before = pool.cumulative_reward_per_share();
    let carry_before = pool.carry();
    let cumulative_deposits_before = pool.cumulative_deposits();
    let redeemed = hikida::redeem_balance<Currency>(composition.uid_mut(admin_cap), value);
    let amount = redeemed.value();
    pool.deposit(redeemed);
    emit(CompositionFundsDepositedEvent<CompositionShare, Currency> {
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

/// Canonical pool address for this Composition, share type, and Currency.
public fun pool_address<CompositionShare, Currency>(
    composition: &Composition<CompositionShare>,
): address {
    pool::derived_address<CompositionShare, Currency>(object::id(composition))
}

// === Test Functions ===

#[test_only]
public fun created_event_fields<CompositionShare, Currency>(
    event: &CompositionRoyaltyPoolCreatedEvent<CompositionShare, Currency>,
): (address, address, address, u64, u64, u256, u128, u128) {
    (
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
public fun coins_deposited_event_fields<CompositionShare, Currency>(
    event: &CompositionCoinsDepositedEvent<CompositionShare, Currency>,
): (address, address, address, u64, u64, u64, u64, u256, u256, u128, u128, u128, u128, vector<address>) {
    (
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
public fun funds_deposited_event_fields<CompositionShare, Currency>(
    event: &CompositionFundsDepositedEvent<CompositionShare, Currency>,
): (address, address, address, u64, u64, u64, u64, u256, u256, u128, u128, u128, u128) {
    (
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
