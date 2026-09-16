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
use sui::accumulator::AccumulatorRoot;
use sui::balance;
use sui::coin::Coin;
use sui::coin_registry::Currency as ShareCurrency;
use sui::event::emit;
use sui::transfer::Receiving;

// === Errors ===

/// Empty coin input is rejected by this Action even though Hikida is total.
const ENoCoinsToReceive: u64 = 0;

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
    coin_count: u64,
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
    share_currency: &ShareCurrency<CompositionShare>,
): RoyaltyPool<CompositionShare, Currency> {
    let composition_id = object::id(composition).to_address();
    let admin_cap_id = object::id(admin_cap).to_address();
    let pool = pool::new(composition.uid_mut(admin_cap), share_currency);
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
    let coin_count = coins.length();
    let uid = composition.uid_mut(admin_cap);
    assert!(!coins.is_empty(), ENoCoinsToReceive);
    let received = hikida::receive_coins_as_balance(uid, coins);
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
        coin_count,
    });
}

/// Redeem all funds settled at the Composition's address at the start of the
/// current consensus commit and deposit them into the canonical pool derived
/// from that same Composition.
///
/// This is the only accumulator redemption path: callers cannot select an
/// amount, so a permissionless crank cannot fragment revenue. The call is an
/// authorized no-op that emits no event when the settled snapshot is zero or
/// when the pool has no registered stake. With no stakers nothing is
/// redeemed: the funds stay in the Composition's accumulator until a stake
/// registers, rather than being folded into a pool nobody can claim from.
/// Either no-op lets an item cranked in an earlier consensus commit, or an
/// unstaked item, pass through a batched crank untouched. The framework
/// snapshot is capped at `u64::MAX`; excess and newly sent funds settle for a
/// later call.
///
/// The snapshot is written only by consensus settlement, so within one commit
/// it is constant: redeeming the same Composition twice in one PTB, or from two
/// transactions in the same commit, withdraws the snapshot twice and the
/// network fails that whole transaction with `InsufficientFundsForWithdraw`
/// (a transaction-level failure, not a Move abort). Crankers must include
/// each object at most once per PTB and treat that status as retry next
/// commit.
/// Emits `CompositionFundsDepositedEvent` after a successful deposit.
public fun redeem_all_and_deposit<CompositionShare, Currency>(
    composition: &mut Composition<CompositionShare>,
    admin_cap: &CompositionAdminCap<CompositionShare>,
    pool: &mut RoyaltyPool<CompositionShare, Currency>,
    root: &AccumulatorRoot,
) {
    let value = balance::settled_funds_value<Currency>(root, object::id(composition).to_address());
    redeem_settled_value_and_deposit<CompositionShare, Currency>(
        composition,
        admin_cap,
        pool,
        value,
    )
}

/// Redeem a previously read settled snapshot when it is positive and the pool
/// has registered stake. The pool derivation is checked before either
/// short-circuit so a wrong pool is rejected even when there is nothing to do.
fun redeem_settled_value_and_deposit<CompositionShare, Currency>(
    composition: &mut Composition<CompositionShare>,
    admin_cap: &CompositionAdminCap<CompositionShare>,
    pool: &mut RoyaltyPool<CompositionShare, Currency>,
    value: u64,
) {
    pool.assert_derived_from(object::id(composition));
    // Intentionally short-circuits before `uid_mut(admin_cap)`: Composition admin
    // caps are matched by phantom share type only (no object-id check exists
    // to skip), so returning early is security-neutral.
    if (value == 0 || pool.staked_shares() == 0) return;
    let composition_id = object::id(composition).to_address();
    let admin_cap_id = object::id(admin_cap).to_address();
    let pool_id = object::id(pool).to_address();
    let pool_balance_before = pool.balance().value();
    let staked_shares = pool.staked_shares();
    let reward_per_share_before = pool.cumulative_reward_per_share();
    let carry_before = pool.carry();
    let cumulative_deposits_before = pool.cumulative_deposits();
    let uid = composition.uid_mut(admin_cap);
    let redeemed = hikida::redeem_balance<Currency>(uid, value);
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
): (address, address, address, u64, u64, u64, u64, u256, u256, u128, u128, u128, u128, u64) {
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
        event.coin_count,
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

#[test_only]
public fun redeem_settled_value_and_deposit_for_testing<CompositionShare, Currency>(
    composition: &mut Composition<CompositionShare>,
    admin_cap: &CompositionAdminCap<CompositionShare>,
    pool: &mut RoyaltyPool<CompositionShare, Currency>,
    value: u64,
) {
    redeem_settled_value_and_deposit<CompositionShare, Currency>(
        composition,
        admin_cap,
        pool,
        value,
    )
}
