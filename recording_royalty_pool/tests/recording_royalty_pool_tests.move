// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module recording_royalty_pool::recording_royalty_pool_tests;

use musicos::recording::{Self, Recording, RecordingAdminCap};
use recording_royalty_pool::recording_royalty_pool as action;
use royalty_pool::pool::{Self, RoyaltyDepositedEvent, RoyaltyPool, RoyaltyPoolCreatedEvent};
use royalty_pool::stake;
use std::unit_test::{assert_eq, destroy};
use sui::accumulator::AccumulatorRoot;
use sui::balance;
use sui::coin::{Self, Coin};
use sui::event;
use sui::test_scenario;
use vault::vault;

const ENoCoinsToReceive: u64 = 0;
const EPoolNotDerivedFromParent: u64 = 0;

public struct RECORDING_SHARE() has drop;
public struct FOREIGN_SHARE() has drop;
public struct COMPOSITION_SHARE() has drop;
public struct CURRENCY() has drop;

fun fixture(ctx: &mut TxContext): (Recording<RECORDING_SHARE, COMPOSITION_SHARE>, RecordingAdminCap<RECORDING_SHARE>) {
    recording::new_for_testing<RECORDING_SHARE, COMPOSITION_SHARE>(
        object::id_from_address(@0xC0),
        ctx,
    )
}

#[test]
fun new_pool_is_returned_unshared_with_exact_parent_and_event() {
    let ctx = &mut tx_context::dummy();
    let (mut recording, admin_cap) = fixture(ctx);
    let recording_id = object::id(&recording);
    let composition_id = recording.composition_id();
    let admin_cap_id = object::id(&admin_cap).to_address();
    let events_before_address = event::num_events();
    let expected = action::pool_address<RECORDING_SHARE, COMPOSITION_SHARE, CURRENCY>(&recording);
    assert_eq!(event::num_events(), events_before_address);
    let pool = action::new_pool<RECORDING_SHARE, COMPOSITION_SHARE, CURRENCY>(
        &mut recording,
        &admin_cap,
    );

    assert_eq!(object::id(&pool).to_address(), expected);
    pool.assert_derived_from(recording_id);
    let events = event::events_by_type<RoyaltyPoolCreatedEvent<RECORDING_SHARE, CURRENCY>>();
    assert_eq!(events.length(), 1);
    let (pool_id, parent_id, _, _, _, _, _, _) = pool::created_event_fields(&events[0]);
    assert_eq!(pool_id, object::id_address(&pool));
    assert_eq!(parent_id, recording_id.to_address());
    let action_events = event::events_by_type<
        action::RecordingRoyaltyPoolCreatedEvent<
            RECORDING_SHARE,
            COMPOSITION_SHARE,
            CURRENCY,
        >
    >();
    assert_eq!(action_events.length(), 1);
    let (
        event_recording_id,
        event_composition_id,
        event_admin_cap_id,
        event_pool_id,
        pool_balance,
        staked_shares,
        reward_per_share,
        carry,
        cumulative_deposits,
    ) = action::created_event_fields(&action_events[0]);
    assert_eq!(event_recording_id, recording_id.to_address());
    assert_eq!(event_composition_id, composition_id.to_address());
    assert_eq!(event_admin_cap_id, admin_cap_id);
    assert_eq!(event_pool_id, object::id(&pool).to_address());
    assert_eq!(pool_balance, pool.balance().value());
    assert_eq!(staked_shares, pool.staked_shares());
    assert_eq!(reward_per_share, pool.cumulative_reward_per_share());
    assert_eq!(carry, pool.carry());
    assert_eq!(cumulative_deposits, pool.cumulative_deposits());

    destroy(pool);
    destroy(recording);
    destroy(admin_cap);
}

#[test]
fun fresh_stake_registers_before_pool_is_shared() {
    let mut scenario = test_scenario::begin(@0xA);
    let (mut recording, admin_cap) = fixture(scenario.ctx());
    let expected = action::pool_address<RECORDING_SHARE, COMPOSITION_SHARE, CURRENCY>(&recording);
    let mut pool = action::new_pool<RECORDING_SHARE, COMPOSITION_SHARE, CURRENCY>(
        &mut recording,
        &admin_cap,
    );
    let mut holder = stake::new(balance::create_for_testing<RECORDING_SHARE>(100), scenario.ctx());
    pool.register_stake(&mut holder);
    assert_eq!(pool.staked_shares(), 100);
    pool.unregister_stake(&mut holder);
    pool.share();
    balance::destroy_for_testing(stake::destroy(holder));

    scenario.next_tx(@0xB);
    let pool: RoyaltyPool<RECORDING_SHARE, CURRENCY> =
        scenario.take_shared_by_id(object::id_from_address(expected));
    test_scenario::return_shared(pool);
    destroy(recording);
    destroy(admin_cap);
    scenario.end();
}

#[test]
fun receive_deposits_only_into_canonical_pool_and_emits_event() {
    let mut scenario = test_scenario::begin(@0xA);
    let (mut recording, admin_cap) = fixture(scenario.ctx());
    let recording_id = object::id(&recording);
    let composition_id = recording.composition_id();
    let admin_cap_id = object::id(&admin_cap).to_address();
    let mut pool = action::new_pool<RECORDING_SHARE, COMPOSITION_SHARE, CURRENCY>(
        &mut recording,
        &admin_cap,
    );
    let mut holder = stake::new(balance::create_for_testing<RECORDING_SHARE>(100), scenario.ctx());
    pool.register_stake(&mut holder);
    let pool_id = object::id(&pool).to_address();
    let pool_balance_before = pool.balance().value();
    let staked_shares = pool.staked_shares();
    let reward_per_share_before = pool.cumulative_reward_per_share();
    let carry_before = pool.carry();
    let cumulative_deposits_before = pool.cumulative_deposits();
    let zero = coin::from_balance(balance::create_for_testing<CURRENCY>(0), scenario.ctx());
    let zero_id = object::id(&zero);
    let paid = coin::from_balance(balance::create_for_testing<CURRENCY>(500), scenario.ctx());
    let paid_id = object::id(&paid);
    transfer::public_transfer(zero, recording_id.to_address());
    transfer::public_transfer(paid, recording_id.to_address());

    scenario.next_tx(@0xB);
    let zero_receiving = test_scenario::receiving_ticket_by_id<Coin<CURRENCY>>(zero_id);
    let paid_receiving = test_scenario::receiving_ticket_by_id<Coin<CURRENCY>>(paid_id);
    action::receive_and_deposit(
        &mut recording,
        &admin_cap,
        &mut pool,
        vector[zero_receiving, paid_receiving],
    );
    let pool_balance_after = pool.balance().value();
    let reward_per_share_after = pool.cumulative_reward_per_share();
    let carry_after = pool.carry();
    let cumulative_deposits_after = pool.cumulative_deposits();
    let reward = pool.claim_rewards(&mut holder);
    assert_eq!(reward.value(), 500);
    let events = event::events_by_type<RoyaltyDepositedEvent<RECORDING_SHARE, CURRENCY>>();
    assert_eq!(events.length(), 1);
    let (event_pool_id, value, _, _, _, _, _, _, _) = pool::deposited_event_fields(&events[0]);
    assert_eq!(event_pool_id, object::id_address(&pool));
    assert_eq!(value, 500);
    let action_events = event::events_by_type<
        action::RecordingCoinsDepositedEvent<
            RECORDING_SHARE,
            COMPOSITION_SHARE,
            CURRENCY,
        >
    >();
    assert_eq!(action_events.length(), 1);
    let (
        event_recording_id,
        event_composition_id,
        event_admin_cap_id,
        event_pool_id,
        amount,
        event_pool_balance_before,
        event_pool_balance_after,
        event_staked_shares,
        event_reward_per_share_before,
        event_reward_per_share_after,
        event_carry_before,
        event_carry_after,
        event_cumulative_deposits_before,
        event_cumulative_deposits_after,
        event_coin_ids,
    ) = action::coins_deposited_event_fields(&action_events[0]);
    assert_eq!(event_recording_id, recording_id.to_address());
    assert_eq!(event_composition_id, composition_id.to_address());
    assert_eq!(event_admin_cap_id, admin_cap_id);
    assert_eq!(event_pool_id, pool_id);
    assert_eq!(amount, 500);
    assert_eq!(event_pool_balance_before, pool_balance_before);
    assert_eq!(event_pool_balance_after, pool_balance_after);
    assert_eq!(event_staked_shares, staked_shares);
    assert_eq!(event_reward_per_share_before, reward_per_share_before);
    assert_eq!(event_reward_per_share_after, reward_per_share_after);
    assert_eq!(event_carry_before, carry_before);
    assert_eq!(event_carry_after, carry_after);
    assert_eq!(event_cumulative_deposits_before, cumulative_deposits_before);
    assert_eq!(event_cumulative_deposits_after, cumulative_deposits_after);
    assert_eq!(event_coin_ids, vector[zero_id.to_address(), paid_id.to_address()]);

    pool.unregister_stake(&mut holder);
    balance::destroy_for_testing(stake::destroy(holder));
    balance::destroy_for_testing(reward);
    destroy(pool);
    destroy(recording);
    destroy(admin_cap);
    scenario.end();
}

/// The private settled-value path with a positive snapshot: the full amount
/// is redeemed and deposited, the action event carries exact before/after
/// pool metrics, and the sole staker can claim every unit.
#[test]
fun settled_value_helper_deposits_full_amount_and_emits_event() {
    let mut scenario = test_scenario::begin(@0xA);
    let (mut recording, admin_cap) = fixture(scenario.ctx());
    let recording_id = object::id(&recording);
    let mut pool = action::new_pool<RECORDING_SHARE, COMPOSITION_SHARE, CURRENCY>(
        &mut recording,
        &admin_cap,
    );
    let mut holder = stake::new(
        balance::create_for_testing<RECORDING_SHARE>(100),
        scenario.ctx(),
    );
    pool.register_stake(&mut holder);
    let composition_id = recording.composition_id();
    let admin_cap_id = object::id(&admin_cap).to_address();
    let pool_id = object::id(&pool).to_address();
    let pool_balance_before = pool.balance().value();
    let staked_shares = pool.staked_shares();
    let reward_per_share_before = pool.cumulative_reward_per_share();
    let carry_before = pool.carry();
    let cumulative_deposits_before = pool.cumulative_deposits();
    balance::create_for_testing<CURRENCY>(321).send_funds(recording_id.to_address());

    scenario.next_tx(@0xB);
    action::redeem_settled_value_and_deposit_for_testing(&mut recording, &admin_cap, &mut pool, 321);
    let pool_balance_after = pool.balance().value();
    let reward_per_share_after = pool.cumulative_reward_per_share();
    let carry_after = pool.carry();
    let cumulative_deposits_after = pool.cumulative_deposits();
    let action_events = event::events_by_type<
        action::RecordingFundsDepositedEvent<
            RECORDING_SHARE,
            COMPOSITION_SHARE,
            CURRENCY,
        >
    >();
    assert_eq!(action_events.length(), 1);
    let (
        event_recording_id,
        event_composition_id,
        event_admin_cap_id,
        event_pool_id,
        amount,
        event_pool_balance_before,
        event_pool_balance_after,
        event_staked_shares,
        event_reward_per_share_before,
        event_reward_per_share_after,
        event_carry_before,
        event_carry_after,
        event_cumulative_deposits_before,
        event_cumulative_deposits_after,
    ) = action::funds_deposited_event_fields(&action_events[0]);
    assert_eq!(event_recording_id, recording_id.to_address());
    assert_eq!(event_composition_id, composition_id.to_address());
    assert_eq!(event_admin_cap_id, admin_cap_id);
    assert_eq!(event_pool_id, pool_id);
    assert_eq!(amount, 321);
    assert_eq!(event_pool_balance_before, pool_balance_before);
    assert_eq!(event_pool_balance_after, pool_balance_after);
    assert_eq!(event_staked_shares, staked_shares);
    assert_eq!(event_reward_per_share_before, reward_per_share_before);
    assert_eq!(event_reward_per_share_after, reward_per_share_after);
    assert_eq!(event_carry_before, carry_before);
    assert_eq!(event_carry_after, carry_after);
    assert_eq!(event_cumulative_deposits_before, cumulative_deposits_before);
    assert_eq!(event_cumulative_deposits_after, cumulative_deposits_after);
    let reward = pool.claim_rewards(&mut holder);
    assert_eq!(reward.value(), 321);

    pool.unregister_stake(&mut holder);
    balance::destroy_for_testing(stake::destroy(holder));
    balance::destroy_for_testing(reward);
    destroy(pool);
    destroy(recording);
    destroy(admin_cap);
    scenario.end();
}

#[test]
fun vault_admin_borrow_action_put_back_and_borrow_again() {
    let ctx = &mut tx_context::dummy();
    let (mut recording, admin_cap) = fixture(ctx);
    let mut registry = vault::new_registry_for_testing(ctx);
    let (mut vault, vault_admin_cap) = vault::new(&mut registry, admin_cap, ctx);
    let (borrowed_cap, receipt) = vault.borrow_as_admin(&vault_admin_cap);
    let pool = action::new_pool<RECORDING_SHARE, COMPOSITION_SHARE, CURRENCY>(
        &mut recording,
        &borrowed_cap,
    );
    vault.put_back(borrowed_cap, receipt);
    let (borrowed_again, second_receipt) = vault.borrow_as_admin(&vault_admin_cap);
    assert_eq!(
        object::id(&pool).to_address(),
        action::pool_address<RECORDING_SHARE, COMPOSITION_SHARE, CURRENCY>(&recording),
    );
    vault.put_back(borrowed_again, second_receipt);

    let admin_cap = vault.withdraw_cap(&vault_admin_cap);
    destroy(pool);
    destroy(admin_cap);
    destroy(vault_admin_cap);
    destroy(vault);
    destroy(registry);
    destroy(recording);
}

#[test, expected_failure]
fun duplicate_pool_derivation_claim_aborts() {
    let ctx = &mut tx_context::dummy();
    let (mut recording, admin_cap) = fixture(ctx);
    let _first = action::new_pool<RECORDING_SHARE, COMPOSITION_SHARE, CURRENCY>(
        &mut recording,
        &admin_cap,
    );
    let _second = action::new_pool<RECORDING_SHARE, COMPOSITION_SHARE, CURRENCY>(
        &mut recording,
        &admin_cap,
    );
    abort
}

#[test, expected_failure(abort_code = EPoolNotDerivedFromParent, location = pool)]
fun receive_rejects_wrong_parent_pool() {
    let ctx = &mut tx_context::dummy();
    let (mut recording, admin_cap) = fixture(ctx);
    let (mut foreign, foreign_cap) =
        recording::new_for_testing<FOREIGN_SHARE, COMPOSITION_SHARE>(
            object::id_from_address(@0xC0),
            ctx,
        );
    let mut wrong_pool = pool::new<RECORDING_SHARE, CURRENCY>(foreign.uid_mut(&foreign_cap));
    action::receive_and_deposit(&mut recording, &admin_cap, &mut wrong_pool, vector[]);
    abort
}

#[test, expected_failure(abort_code = ENoCoinsToReceive, location = action)]
fun empty_receive_aborts() {
    let ctx = &mut tx_context::dummy();
    let (mut recording, admin_cap) = fixture(ctx);
    let mut pool = action::new_pool<RECORDING_SHARE, COMPOSITION_SHARE, CURRENCY>(
        &mut recording,
        &admin_cap,
    );
    action::receive_and_deposit(&mut recording, &admin_cap, &mut pool, vector[]);
    abort
}

#[test, expected_failure(abort_code = 1, location = pool)] // ENoStakedShares
fun receive_with_no_staked_shares_aborts_on_pool_guard() {
    let mut scenario = test_scenario::begin(@0xA);
    let (mut recording, admin_cap) = fixture(scenario.ctx());
    let recording_id = object::id(&recording);
    let mut pool = action::new_pool<RECORDING_SHARE, COMPOSITION_SHARE, CURRENCY>(
        &mut recording,
        &admin_cap,
    );
    let paid = coin::from_balance(balance::create_for_testing<CURRENCY>(1), scenario.ctx());
    let paid_id = object::id(&paid);
    transfer::public_transfer(paid, recording_id.to_address());

    scenario.next_tx(@0xB);
    let receiving = test_scenario::receiving_ticket_by_id<Coin<CURRENCY>>(paid_id);
    action::receive_and_deposit(
        &mut recording,
        &admin_cap,
        &mut pool,
        vector[receiving],
    );
    abort
}

#[test, expected_failure(abort_code = 6, location = pool)] // EInvalidValue
fun receive_zero_value_with_active_stake_aborts_on_pool_guard() {
    let mut scenario = test_scenario::begin(@0xA);
    let (mut recording, admin_cap) = fixture(scenario.ctx());
    let recording_id = object::id(&recording);
    let mut pool = action::new_pool<RECORDING_SHARE, COMPOSITION_SHARE, CURRENCY>(
        &mut recording,
        &admin_cap,
    );
    let mut holder = stake::new(
        balance::create_for_testing<RECORDING_SHARE>(100),
        scenario.ctx(),
    );
    pool.register_stake(&mut holder);
    let zero = coin::from_balance(balance::create_for_testing<CURRENCY>(0), scenario.ctx());
    let zero_id = object::id(&zero);
    transfer::public_transfer(zero, recording_id.to_address());

    scenario.next_tx(@0xB);
    let receiving = test_scenario::receiving_ticket_by_id<Coin<CURRENCY>>(zero_id);
    action::receive_and_deposit(
        &mut recording,
        &admin_cap,
        &mut pool,
        vector[receiving],
    );
    abort
}

#[test, expected_failure(abort_code = EPoolNotDerivedFromParent, location = pool)]
fun redeem_all_rejects_wrong_parent_pool_even_on_empty_snapshot() {
    let mut scenario = test_scenario::begin(@0x0);
    sui::accumulator::create_for_testing(scenario.ctx());
    scenario.next_tx(@0xA);
    let (mut recording, admin_cap) = fixture(scenario.ctx());
    let (mut foreign, foreign_cap) =
        recording::new_for_testing<FOREIGN_SHARE, COMPOSITION_SHARE>(
            object::id_from_address(@0xC0),
            scenario.ctx(),
        );
    let mut wrong_pool = pool::new<RECORDING_SHARE, CURRENCY>(foreign.uid_mut(&foreign_cap));
    let root = scenario.take_shared<AccumulatorRoot>();
    action::redeem_all_and_deposit(&mut recording, &admin_cap, &mut wrong_pool, &root);
    abort
}

#[test, expected_failure(abort_code = EPoolNotDerivedFromParent, location = pool)]
fun settled_value_helper_rejects_wrong_parent_pool() {
    let ctx = &mut tx_context::dummy();
    let (mut recording, admin_cap) = fixture(ctx);
    let (mut foreign, foreign_cap) =
        recording::new_for_testing<FOREIGN_SHARE, COMPOSITION_SHARE>(
            object::id_from_address(@0xC0),
            ctx,
        );
    let mut wrong_pool = pool::new<RECORDING_SHARE, CURRENCY>(foreign.uid_mut(&foreign_cap));
    action::redeem_settled_value_and_deposit_for_testing(
        &mut recording,
        &admin_cap,
        &mut wrong_pool,
        1,
    );
    abort
}

/// The on-chain reader path against a real (empty) `AccumulatorRoot`: called
/// twice in a row with a registered stake, both calls are silent no-ops.
#[test]
fun redeem_all_is_an_idempotent_no_op_without_settled_funds() {
    let mut scenario = test_scenario::begin(@0x0);
    sui::accumulator::create_for_testing(scenario.ctx());
    scenario.next_tx(@0xA);
    let (mut recording, admin_cap) = fixture(scenario.ctx());
    let mut pool = action::new_pool<RECORDING_SHARE, COMPOSITION_SHARE, CURRENCY>(
        &mut recording,
        &admin_cap,
    );
    let mut holder = stake::new(balance::create_for_testing<RECORDING_SHARE>(100), scenario.ctx());
    pool.register_stake(&mut holder);
    let root = scenario.take_shared<AccumulatorRoot>();
    let events_before = event::num_events();
    action::redeem_all_and_deposit(&mut recording, &admin_cap, &mut pool, &root);
    action::redeem_all_and_deposit(&mut recording, &admin_cap, &mut pool, &root);
    assert_eq!(event::num_events(), events_before);
    assert_eq!(pool.balance().value(), 0);
    assert_eq!(pool.cumulative_deposits(), 0);
    assert_eq!(pool.pending_rewards(&holder), 0);
    test_scenario::return_shared(root);
    pool.unregister_stake(&mut holder);
    balance::destroy_for_testing(stake::destroy(holder));
    destroy(pool);
    destroy(recording);
    destroy(admin_cap);
    scenario.end();
}

/// The private settled-value path is total at zero even with a registered
/// stake: no abort, no action event, no pool event, pool untouched.
#[test]
fun settled_value_helper_is_a_silent_no_op_at_zero() {
    let ctx = &mut tx_context::dummy();
    let (mut recording, admin_cap) = fixture(ctx);
    let mut pool = action::new_pool<RECORDING_SHARE, COMPOSITION_SHARE, CURRENCY>(
        &mut recording,
        &admin_cap,
    );
    let mut holder = stake::new(balance::create_for_testing<RECORDING_SHARE>(100), ctx);
    pool.register_stake(&mut holder);
    let events_before = event::num_events();
    action::redeem_settled_value_and_deposit_for_testing(&mut recording, &admin_cap, &mut pool, 0);
    assert_eq!(event::num_events(), events_before);
    assert_eq!(pool.cumulative_deposits(), 0);
    pool.unregister_stake(&mut holder);
    balance::destroy_for_testing(stake::destroy(holder));
    destroy(pool);
    destroy(recording);
    destroy(admin_cap);
}

/// With no registered stake, a positive snapshot is not redeemed at all: the
/// pool is untouched and no event is emitted. Once a stake registers, the same
/// funds are redeemed in full and the staker can claim every unit.
#[test]
fun zero_stakers_is_a_no_op_and_funds_remain_redeemable_after_a_stake_registers() {
    let mut scenario = test_scenario::begin(@0xA);
    let (mut recording, admin_cap) = fixture(scenario.ctx());
    let recording_id = object::id(&recording);
    let mut pool = action::new_pool<RECORDING_SHARE, COMPOSITION_SHARE, CURRENCY>(
        &mut recording,
        &admin_cap,
    );
    balance::create_for_testing<CURRENCY>(321).send_funds(recording_id.to_address());

    scenario.next_tx(@0xB);
    assert_eq!(pool.staked_shares(), 0);
    let events_before = event::num_events();
    action::redeem_settled_value_and_deposit_for_testing(&mut recording, &admin_cap, &mut pool, 321);
    assert_eq!(event::num_events(), events_before);
    assert_eq!(pool.balance().value(), 0);
    assert_eq!(pool.cumulative_deposits(), 0);
    assert_eq!(
        event::events_by_type<RoyaltyDepositedEvent<RECORDING_SHARE, CURRENCY>>().length(),
        0,
    );

    scenario.next_tx(@0xC);
    let mut holder = stake::new(balance::create_for_testing<RECORDING_SHARE>(100), scenario.ctx());
    pool.register_stake(&mut holder);
    action::redeem_settled_value_and_deposit_for_testing(&mut recording, &admin_cap, &mut pool, 321);
    let action_events = event::events_by_type<
        action::RecordingFundsDepositedEvent<
            RECORDING_SHARE,
            COMPOSITION_SHARE,
            CURRENCY,
        >
    >();
    assert_eq!(action_events.length(), 1);
    let (_, _, _, _, amount, balance_before, balance_after, staked, _, _, _, _, deposits_before, deposits_after) =
        action::funds_deposited_event_fields(&action_events[0]);
    assert_eq!(amount, 321);
    assert_eq!(balance_before, 0);
    assert_eq!(balance_after, 321);
    assert_eq!(staked, 100);
    assert_eq!(deposits_before, 0);
    assert_eq!(deposits_after, 321);
    assert_eq!(pool.cumulative_deposits(), 321);
    let reward = pool.claim_rewards(&mut holder);
    assert_eq!(reward.value(), 321);

    pool.unregister_stake(&mut holder);
    balance::destroy_for_testing(stake::destroy(holder));
    balance::destroy_for_testing(reward);
    destroy(pool);
    destroy(recording);
    destroy(admin_cap);
    scenario.end();
}

/// Unit-VM boundary pin, not a same-commit idempotency claim: after a funded
/// helper call, `redeem_all_and_deposit` in the same transaction reads the
/// unit VM's always-zero snapshot and deposits nothing. On the network the
/// snapshot is constant within a commit, so a second redemption of the same
/// Recording in one PTB withdraws the snapshot again and the whole transaction
/// fails with `InsufficientFundsForWithdraw`; only a call in a later commit is
/// a no-op. See `same_tx_duplicate_redemptions_withdraw_twice_in_the_unit_vm`.
#[test]
fun second_redeem_all_in_the_same_tx_sees_the_vm_zero_snapshot() {
    let mut scenario = test_scenario::begin(@0x0);
    sui::accumulator::create_for_testing(scenario.ctx());
    scenario.next_tx(@0xA);
    let (mut recording, admin_cap) = fixture(scenario.ctx());
    let recording_id = object::id(&recording);
    let mut pool = action::new_pool<RECORDING_SHARE, COMPOSITION_SHARE, CURRENCY>(
        &mut recording,
        &admin_cap,
    );
    let mut holder = stake::new(balance::create_for_testing<RECORDING_SHARE>(100), scenario.ctx());
    pool.register_stake(&mut holder);
    balance::create_for_testing<CURRENCY>(500).send_funds(recording_id.to_address());

    scenario.next_tx(@0xB);
    action::redeem_settled_value_and_deposit_for_testing(&mut recording, &admin_cap, &mut pool, 500);
    let events_after_first = event::num_events();
    let root = scenario.take_shared<AccumulatorRoot>();
    action::redeem_all_and_deposit(&mut recording, &admin_cap, &mut pool, &root);
    assert_eq!(event::num_events(), events_after_first);
    assert_eq!(pool.cumulative_deposits(), 500);
    assert_eq!(
        event::events_by_type<RoyaltyDepositedEvent<RECORDING_SHARE, CURRENCY>>().length(),
        1,
    );
    let reward = pool.claim_rewards(&mut holder);
    assert_eq!(reward.value(), 500);

    test_scenario::return_shared(root);
    pool.unregister_stake(&mut holder);
    balance::destroy_for_testing(stake::destroy(holder));
    balance::destroy_for_testing(reward);
    destroy(pool);
    destroy(recording);
    destroy(admin_cap);
    scenario.end();
}

/// Two helper calls with the same snapshot value in ONE transaction withdraw
/// twice. The Action has no in-transaction dedupe; on the network the second
/// withdrawal exceeds the settled balance and the whole transaction fails with
/// `InsufficientFundsForWithdraw` (not a Move abort), which the unit VM cannot
/// show because it never checks withdrawals against a balance. Crankers must
/// include each Recording at most once per PTB.
#[test]
fun same_tx_duplicate_redemptions_withdraw_twice_in_the_unit_vm() {
    let ctx = &mut tx_context::dummy();
    let (mut recording, admin_cap) = fixture(ctx);
    let mut pool = action::new_pool<RECORDING_SHARE, COMPOSITION_SHARE, CURRENCY>(
        &mut recording,
        &admin_cap,
    );
    let mut holder = stake::new(balance::create_for_testing<RECORDING_SHARE>(100), ctx);
    pool.register_stake(&mut holder);
    action::redeem_settled_value_and_deposit_for_testing(&mut recording, &admin_cap, &mut pool, 321);
    action::redeem_settled_value_and_deposit_for_testing(&mut recording, &admin_cap, &mut pool, 321);
    assert_eq!(pool.cumulative_deposits(), 642);
    assert_eq!(
        event::events_by_type<RoyaltyDepositedEvent<RECORDING_SHARE, CURRENCY>>().length(),
        2,
    );
    let reward = pool.claim_rewards(&mut holder);
    assert_eq!(reward.value(), 642);
    pool.unregister_stake(&mut holder);
    balance::destroy_for_testing(stake::destroy(holder));
    balance::destroy_for_testing(reward);
    destroy(pool);
    destroy(recording);
    destroy(admin_cap);
}

/// The framework caps the settled snapshot at `u64::MAX`; the helper must not
/// abort there (`pool.deposit` widens to u128) and the sole staker can claim
/// the full amount.
#[test]
fun u64_max_snapshot_deposits_without_abort() {
    let ctx = &mut tx_context::dummy();
    let (mut recording, admin_cap) = fixture(ctx);
    let mut pool = action::new_pool<RECORDING_SHARE, COMPOSITION_SHARE, CURRENCY>(
        &mut recording,
        &admin_cap,
    );
    let mut holder = stake::new(balance::create_for_testing<RECORDING_SHARE>(100), ctx);
    pool.register_stake(&mut holder);
    let max = std::u64::max_value!();
    action::redeem_settled_value_and_deposit_for_testing(&mut recording, &admin_cap, &mut pool, max);
    assert_eq!(pool.cumulative_deposits(), max as u128);
    assert_eq!(pool.balance().value(), max);
    let reward = pool.claim_rewards(&mut holder);
    assert_eq!(reward.value(), max);
    pool.unregister_stake(&mut holder);
    balance::destroy_for_testing(stake::destroy(holder));
    balance::destroy_for_testing(reward);
    destroy(pool);
    destroy(recording);
    destroy(admin_cap);
}

/// Batch safety: three Recordings cranked in one transaction. One has an
/// empty settled snapshot and one has funds but no stakers; both pass through
/// silently while the funded, staked one is deposited in full. The unstaked
/// one is then redeemed once its stake registers.
#[test]
fun batch_with_zero_snapshot_and_zero_staker_items_still_deposits_the_others() {
    let mut scenario = test_scenario::begin(@0x0);
    sui::accumulator::create_for_testing(scenario.ctx());
    scenario.next_tx(@0xA);
    let (mut recording_a, cap_a) = fixture(scenario.ctx());
    let (mut recording_b, cap_b) = fixture(scenario.ctx());
    let (mut recording_c, cap_c) = fixture(scenario.ctx());
    let mut pool_a = action::new_pool<RECORDING_SHARE, COMPOSITION_SHARE, CURRENCY>(
        &mut recording_a,
        &cap_a,
    );
    let mut pool_b = action::new_pool<RECORDING_SHARE, COMPOSITION_SHARE, CURRENCY>(
        &mut recording_b,
        &cap_b,
    );
    let mut pool_c = action::new_pool<RECORDING_SHARE, COMPOSITION_SHARE, CURRENCY>(
        &mut recording_c,
        &cap_c,
    );
    let mut holder_a = stake::new(balance::create_for_testing<RECORDING_SHARE>(10), scenario.ctx());
    let mut holder_b = stake::new(balance::create_for_testing<RECORDING_SHARE>(10), scenario.ctx());
    pool_a.register_stake(&mut holder_a);
    pool_b.register_stake(&mut holder_b);
    balance::create_for_testing<CURRENCY>(1_000).send_funds(object::id(&recording_a).to_address());
    balance::create_for_testing<CURRENCY>(250).send_funds(object::id(&recording_c).to_address());

    scenario.next_tx(@0xB);
    let root = scenario.take_shared<AccumulatorRoot>();
    action::redeem_settled_value_and_deposit_for_testing(&mut recording_a, &cap_a, &mut pool_a, 1_000);
    action::redeem_all_and_deposit(&mut recording_b, &cap_b, &mut pool_b, &root);
    action::redeem_settled_value_and_deposit_for_testing(&mut recording_c, &cap_c, &mut pool_c, 250);

    let action_events = event::events_by_type<
        action::RecordingFundsDepositedEvent<
            RECORDING_SHARE,
            COMPOSITION_SHARE,
            CURRENCY,
        >
    >();
    assert_eq!(action_events.length(), 1);
    let (event_recording_id, _, _, event_pool_id, amount, _, _, _, _, _, _, _, _, _) =
        action::funds_deposited_event_fields(&action_events[0]);
    assert_eq!(event_recording_id, object::id(&recording_a).to_address());
    assert_eq!(event_pool_id, object::id(&pool_a).to_address());
    assert_eq!(amount, 1_000);
    assert_eq!(pool_a.cumulative_deposits(), 1_000);
    assert_eq!(pool_b.cumulative_deposits(), 0);
    assert_eq!(pool_c.cumulative_deposits(), 0);
    assert_eq!(pool_c.balance().value(), 0);

    scenario.next_tx(@0xC);
    let mut holder_c = stake::new(balance::create_for_testing<RECORDING_SHARE>(10), scenario.ctx());
    pool_c.register_stake(&mut holder_c);
    action::redeem_settled_value_and_deposit_for_testing(&mut recording_c, &cap_c, &mut pool_c, 250);
    assert_eq!(pool_c.cumulative_deposits(), 250);
    let reward_c = pool_c.claim_rewards(&mut holder_c);
    assert_eq!(reward_c.value(), 250);
    let reward_a = pool_a.claim_rewards(&mut holder_a);
    assert_eq!(reward_a.value(), 1_000);
    assert_eq!(pool_b.pending_rewards(&holder_b), 0);

    test_scenario::return_shared(root);
    pool_a.unregister_stake(&mut holder_a);
    pool_b.unregister_stake(&mut holder_b);
    pool_c.unregister_stake(&mut holder_c);
    balance::destroy_for_testing(stake::destroy(holder_a));
    balance::destroy_for_testing(stake::destroy(holder_b));
    balance::destroy_for_testing(stake::destroy(holder_c));
    balance::destroy_for_testing(reward_a);
    balance::destroy_for_testing(reward_c);
    destroy(pool_a);
    destroy(pool_b);
    destroy(pool_c);
    destroy(recording_a);
    destroy(recording_b);
    destroy(recording_c);
    destroy(cap_a);
    destroy(cap_b);
    destroy(cap_c);
    scenario.end();
}

/// The unit VM records accumulator withdrawals without checking them against
/// a balance (`withdraw_from_accumulator_address` only tracks per-transaction
/// totals), so an overdraw of an empty accumulator succeeds locally. This
/// pins that boundary explicitly: overdraw rejection is a network property
/// covered by the testnet checklist, not by this suite. The previous
/// `expected_failure` overdraw test passed only through its own trailing
/// `abort`.
#[test]
fun overdraw_is_not_enforced_by_the_unit_vm() {
    let ctx = &mut tx_context::dummy();
    let (mut recording, admin_cap) = fixture(ctx);
    let mut pool = action::new_pool<RECORDING_SHARE, COMPOSITION_SHARE, CURRENCY>(
        &mut recording,
        &admin_cap,
    );
    let mut holder = stake::new(balance::create_for_testing<RECORDING_SHARE>(100), ctx);
    pool.register_stake(&mut holder);
    action::redeem_settled_value_and_deposit_for_testing(&mut recording, &admin_cap, &mut pool, 1);
    assert_eq!(pool.cumulative_deposits(), 1);
    let reward = pool.claim_rewards(&mut holder);
    assert_eq!(reward.value(), 1);
    pool.unregister_stake(&mut holder);
    balance::destroy_for_testing(stake::destroy(holder));
    balance::destroy_for_testing(reward);
    destroy(pool);
    destroy(recording);
    destroy(admin_cap);
}
