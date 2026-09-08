// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module composition_royalty_pool::composition_royalty_pool_tests;

use composition_royalty_pool::composition_royalty_pool as action;
use hikida::hikida;
use musicos::composition::{Self, Composition, CompositionAdminCap};
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

public struct COMPOSITION_SHARE() has drop;
public struct FOREIGN_SHARE() has drop;
public struct CURRENCY() has drop;

fun fixture(ctx: &mut TxContext): (Composition<COMPOSITION_SHARE>, CompositionAdminCap<COMPOSITION_SHARE>) {
    composition::new_for_testing<COMPOSITION_SHARE>("Composition", 1_000, ctx)
}

#[test]
fun new_pool_is_returned_unshared_with_exact_parent_and_event() {
    let ctx = &mut tx_context::dummy();
    let (mut composition, admin_cap) = fixture(ctx);
    let composition_id = object::id(&composition);
    let expected = action::pool_address<COMPOSITION_SHARE, CURRENCY>(&composition);
    let pool = action::new_pool<COMPOSITION_SHARE, CURRENCY>(&mut composition, &admin_cap);

    assert_eq!(object::id(&pool).to_address(), expected);
    pool.assert_derived_from(composition_id);
    let events = event::events_by_type<RoyaltyPoolCreatedEvent<COMPOSITION_SHARE, CURRENCY>>();
    assert_eq!(events.length(), 1);
    let (pool_id, parent_id) = pool::created_event_fields(&events[0]);
    assert_eq!(pool_id, object::id(&pool));
    assert_eq!(parent_id, composition_id);

    destroy(pool);
    destroy(composition);
    destroy(admin_cap);
}

#[test]
fun fresh_stake_registers_before_pool_is_shared() {
    let mut scenario = test_scenario::begin(@0xA);
    let (mut composition, admin_cap) = fixture(scenario.ctx());
    let expected = action::pool_address<COMPOSITION_SHARE, CURRENCY>(&composition);
    let mut pool = action::new_pool<COMPOSITION_SHARE, CURRENCY>(&mut composition, &admin_cap);
    let mut holder = stake::new(
        balance::create_for_testing<COMPOSITION_SHARE>(100),
        scenario.ctx(),
    );
    pool.register_stake(&mut holder);
    assert_eq!(pool.staked_shares(), 100);
    pool.unregister_stake(&mut holder);
    pool.share();
    balance::destroy_for_testing(stake::destroy(holder));

    scenario.next_tx(@0xB);
    let pool: RoyaltyPool<COMPOSITION_SHARE, CURRENCY> =
        scenario.take_shared_by_id(object::id_from_address(expected));
    test_scenario::return_shared(pool);
    destroy(composition);
    destroy(admin_cap);
    scenario.end();
}

#[test]
fun receive_deposits_only_into_canonical_pool_and_emits_event() {
    let mut scenario = test_scenario::begin(@0xA);
    let (mut composition, admin_cap) = fixture(scenario.ctx());
    let composition_id = object::id(&composition);
    let mut pool = action::new_pool<COMPOSITION_SHARE, CURRENCY>(&mut composition, &admin_cap);
    let mut holder = stake::new(
        balance::create_for_testing<COMPOSITION_SHARE>(100),
        scenario.ctx(),
    );
    pool.register_stake(&mut holder);
    let paid = coin::from_balance(balance::create_for_testing<CURRENCY>(500), scenario.ctx());
    let paid_id = object::id(&paid);
    transfer::public_transfer(paid, composition_id.to_address());

    scenario.next_tx(@0xB);
    let receiving = test_scenario::receiving_ticket_by_id<Coin<CURRENCY>>(paid_id);
    action::receive_and_deposit(
        &mut composition,
        &admin_cap,
        &mut pool,
        vector[receiving],
    );
    let reward = pool.claim_rewards(&mut holder);
    assert_eq!(reward.value(), 500);
    let events = event::events_by_type<RoyaltyDepositedEvent<COMPOSITION_SHARE, CURRENCY>>();
    assert_eq!(events.length(), 1);
    let (event_pool_id, value) = pool::deposited_event_fields(&events[0]);
    assert_eq!(event_pool_id, object::id(&pool));
    assert_eq!(value, 500);

    pool.unregister_stake(&mut holder);
    balance::destroy_for_testing(stake::destroy(holder));
    balance::destroy_for_testing(reward);
    destroy(pool);
    destroy(composition);
    destroy(admin_cap);
    scenario.end();
}

#[test]
fun positive_direct_redemption_deposits_after_transaction_boundary() {
    let mut scenario = test_scenario::begin(@0xA);
    let (mut composition, admin_cap) = fixture(scenario.ctx());
    let composition_id = object::id(&composition);
    let mut pool = action::new_pool<COMPOSITION_SHARE, CURRENCY>(
        &mut composition,
        &admin_cap,
    );
    let mut holder = stake::new(
        balance::create_for_testing<COMPOSITION_SHARE>(100),
        scenario.ctx(),
    );
    pool.register_stake(&mut holder);
    balance::create_for_testing<CURRENCY>(321).send_funds(composition_id.to_address());

    scenario.next_tx(@0xB);
    action::redeem_and_deposit(&mut composition, &admin_cap, &mut pool, 321);
    let reward = pool.claim_rewards(&mut holder);
    assert_eq!(reward.value(), 321);

    pool.unregister_stake(&mut holder);
    balance::destroy_for_testing(stake::destroy(holder));
    balance::destroy_for_testing(reward);
    destroy(pool);
    destroy(composition);
    destroy(admin_cap);
    scenario.end();
}

#[test]
fun vault_admin_borrow_action_put_back_and_borrow_again() {
    let ctx = &mut tx_context::dummy();
    let (mut composition, admin_cap) = fixture(ctx);
    let mut registry = vault::new_registry_for_testing(ctx);
    let (mut vault, vault_admin_cap) = vault::new(&mut registry, admin_cap, ctx);
    let (borrowed_cap, receipt) = vault.borrow_as_admin(&vault_admin_cap);
    let pool = action::new_pool<COMPOSITION_SHARE, CURRENCY>(
        &mut composition,
        &borrowed_cap,
    );
    vault.put_back(borrowed_cap, receipt);
    let (borrowed_again, second_receipt) = vault.borrow_as_admin(&vault_admin_cap);
    assert_eq!(
        object::id(&pool).to_address(),
        action::pool_address<COMPOSITION_SHARE, CURRENCY>(&composition),
    );
    vault.put_back(borrowed_again, second_receipt);

    let admin_cap = vault.withdraw_cap(&vault_admin_cap);
    destroy(pool);
    destroy(admin_cap);
    destroy(vault_admin_cap);
    destroy(vault);
    destroy(registry);
    destroy(composition);
}

#[test, expected_failure]
fun duplicate_pool_derivation_claim_aborts() {
    let ctx = &mut tx_context::dummy();
    let (mut composition, admin_cap) = fixture(ctx);
    let _first = action::new_pool<COMPOSITION_SHARE, CURRENCY>(&mut composition, &admin_cap);
    let _second = action::new_pool<COMPOSITION_SHARE, CURRENCY>(&mut composition, &admin_cap);
    abort
}

#[test, expected_failure(abort_code = EPoolNotDerivedFromParent, location = pool)]
fun receive_rejects_wrong_parent_pool() {
    let ctx = &mut tx_context::dummy();
    let (mut composition, admin_cap) = fixture(ctx);
    let (mut foreign, foreign_cap) =
        composition::new_for_testing<FOREIGN_SHARE>("Foreign", 1_000, ctx);
    let mut wrong_pool = pool::new<COMPOSITION_SHARE, CURRENCY>(foreign.uid_mut(&foreign_cap));
    action::receive_and_deposit(&mut composition, &admin_cap, &mut wrong_pool, vector[]);
    abort
}

#[test, expected_failure(abort_code = ENoCoinsToReceive, location = hikida)]
fun empty_receive_aborts() {
    let ctx = &mut tx_context::dummy();
    let (mut composition, admin_cap) = fixture(ctx);
    let mut pool = action::new_pool<COMPOSITION_SHARE, CURRENCY>(&mut composition, &admin_cap);
    action::receive_and_deposit(&mut composition, &admin_cap, &mut pool, vector[]);
    abort
}

#[test, expected_failure(abort_code = ENoValueToRedeem, location = hikida)]
fun zero_redeem_aborts() {
    let ctx = &mut tx_context::dummy();
    let (mut composition, admin_cap) = fixture(ctx);
    let mut pool = action::new_pool<COMPOSITION_SHARE, CURRENCY>(&mut composition, &admin_cap);
    action::redeem_and_deposit(&mut composition, &admin_cap, &mut pool, 0);
    abort
}

#[test, expected_failure]
fun overdraw_redeem_aborts_on_empty_accumulator() {
    let ctx = &mut tx_context::dummy();
    let (mut composition, admin_cap) = fixture(ctx);
    let mut pool = action::new_pool<COMPOSITION_SHARE, CURRENCY>(&mut composition, &admin_cap);
    action::redeem_and_deposit(&mut composition, &admin_cap, &mut pool, 1);
    abort
}
