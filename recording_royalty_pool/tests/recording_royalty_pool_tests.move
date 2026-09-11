// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module recording_royalty_pool::recording_royalty_pool_tests;

use hikida::hikida;
use musicos::recording::{Self, Recording, RecordingAdminCap};
use recording_royalty_pool::recording_royalty_pool as action;
use royalty_pool::pool::{Self, RoyaltyDepositedEvent, RoyaltyPool, RoyaltyPoolCreatedEvent};
use royalty_pool::stake;
use std::unit_test::{assert_eq, destroy};
use sui::balance;
use sui::coin::{Self, Coin};
use sui::event;
use sui::test_scenario;
use vault::vault;

const ENoCoinsToReceive: u64 = 0;
const ENoValueToRedeem: u64 = 1;
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
    let (pool_id, parent_id) = pool::created_event_fields(&events[0]);
    assert_eq!(pool_id, object::id(&pool));
    assert_eq!(parent_id, recording_id);
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
    let (event_pool_id, value) = pool::deposited_event_fields(&events[0]);
    assert_eq!(event_pool_id, object::id(&pool));
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

#[test]
fun positive_direct_redemption_deposits_after_transaction_boundary() {
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
    action::redeem_and_deposit(&mut recording, &admin_cap, &mut pool, 321);
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

#[test, expected_failure(abort_code = ENoCoinsToReceive, location = hikida)]
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

#[test, expected_failure(abort_code = ENoValueToRedeem, location = hikida)]
fun zero_redeem_aborts() {
    let ctx = &mut tx_context::dummy();
    let (mut recording, admin_cap) = fixture(ctx);
    let mut pool = action::new_pool<RECORDING_SHARE, COMPOSITION_SHARE, CURRENCY>(
        &mut recording,
        &admin_cap,
    );
    action::redeem_and_deposit(&mut recording, &admin_cap, &mut pool, 0);
    abort
}

#[test, expected_failure]
fun overdraw_redeem_aborts_on_empty_accumulator() {
    let ctx = &mut tx_context::dummy();
    let (mut recording, admin_cap) = fixture(ctx);
    let mut pool = action::new_pool<RECORDING_SHARE, COMPOSITION_SHARE, CURRENCY>(
        &mut recording,
        &admin_cap,
    );
    action::redeem_and_deposit(&mut recording, &admin_cap, &mut pool, 1);
    abort
}
