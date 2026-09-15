// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// End-to-end royalty claiming through the action, under `test_scenario`:
/// a published (shared) Composition, its shared canonical pool, two
/// independent share holders, a third-party payer, and the admin folding
/// revenue in via both action paths (coin receipt and the settled-value
/// redemption helper). Every claim amount is the exact pro-rata floor and
/// the pool ends holding only sub-unit residue.
#[test_only]
module composition_royalty_pool::composition_royalty_pool_claim_e2e_tests;

use composition_royalty_pool::composition_royalty_pool as action;
use musicos::composition::{Self, Composition, CompositionAdminCap};
use royalty_pool::pool::RoyaltyPool;
use royalty_pool::stake::{Self, Stake};
use std::unit_test::{assert_eq, destroy};
use sui::balance;
use sui::clock;
use sui::coin::{Self, Coin};
use sui::test_scenario::{Self, Scenario};

const ADMIN: address = @0xAD;
const HOLDER_A: address = @0xA;
const HOLDER_B: address = @0xB;
const PAYER: address = @0x9A;

public struct COMPOSITION_SHARE() has drop;
public struct CURRENCY() has drop;

fun holder_registers(sc: &mut Scenario, holder: address, shares: u64) {
    sc.next_tx(holder);
    let mut pool = sc.take_shared<RoyaltyPool<COMPOSITION_SHARE, CURRENCY>>();
    let mut s = stake::new(balance::create_for_testing<COMPOSITION_SHARE>(shares), sc.ctx());
    pool.register_stake(&mut s);
    test_scenario::return_shared(pool);
    transfer::public_transfer(s, holder);
}

fun holder_claims(sc: &mut Scenario, holder: address, expected: u64) {
    sc.next_tx(holder);
    let mut pool = sc.take_shared<RoyaltyPool<COMPOSITION_SHARE, CURRENCY>>();
    let mut s = sc.take_from_sender<Stake<COMPOSITION_SHARE>>();
    assert_eq!(pool.pending_rewards(&s), expected);
    let reward = pool.claim_rewards(&mut s);
    assert_eq!(reward.value(), expected);
    assert_eq!(pool.pending_rewards(&s), 0);
    destroy(reward);
    test_scenario::return_shared(pool);
    sc.return_to_sender(s);
}

#[test]
fun holders_claim_exact_pro_rata_across_receive_and_redeem_paths() {
    let mut sc = test_scenario::begin(ADMIN);

    // --- ADMIN: publish the composition (shared) and share its canonical pool ---
    let (mut composition, cap) =
        composition::new_for_testing<COMPOSITION_SHARE>("Composition", 1_000, sc.ctx());
    let composition_id = object::id(&composition);
    action::new_pool<COMPOSITION_SHARE, CURRENCY>(&mut composition, &cap).share();
    let clock = clock::create_for_testing(sc.ctx());
    composition.publish(&cap, &clock);
    clock.destroy_for_testing();
    transfer::public_transfer(cap, ADMIN);

    // --- Holders stake 300 and 100 composition shares ---
    holder_registers(&mut sc, HOLDER_A, 300);
    holder_registers(&mut sc, HOLDER_B, 100);

    // --- PAYER sends a 1_001 coin to the composition's address ---
    sc.next_tx(PAYER);
    let paid = coin::from_balance(balance::create_for_testing<CURRENCY>(1_001), sc.ctx());
    let paid_id = object::id(&paid);
    transfer::public_transfer(paid, composition_id.to_address());

    // --- ADMIN folds it in through the action ---
    sc.next_tx(ADMIN);
    let mut composition = sc.take_shared<Composition<COMPOSITION_SHARE>>();
    let cap = sc.take_from_sender<CompositionAdminCap<COMPOSITION_SHARE>>();
    let mut pool = sc.take_shared<RoyaltyPool<COMPOSITION_SHARE, CURRENCY>>();
    let ticket = test_scenario::receiving_ticket_by_id<Coin<CURRENCY>>(paid_id);
    action::receive_and_deposit(&mut composition, &cap, &mut pool, vector[ticket]);
    assert_eq!(pool.balance().value(), 1_001);
    test_scenario::return_shared(pool);
    test_scenario::return_shared(composition);
    sc.return_to_sender(cap);

    // ⌊300·1001/400⌋ = 750, ⌊100·1001/400⌋ = 250; 1 unit of residue stays.
    holder_claims(&mut sc, HOLDER_A, 750);
    holder_claims(&mut sc, HOLDER_B, 250);

    // --- PAYER sends 400 through the funds accumulator; ADMIN redeems it ---
    sc.next_tx(PAYER);
    balance::create_for_testing<CURRENCY>(400).send_funds(composition_id.to_address());

    sc.next_tx(ADMIN);
    let mut composition = sc.take_shared<Composition<COMPOSITION_SHARE>>();
    let cap = sc.take_from_sender<CompositionAdminCap<COMPOSITION_SHARE>>();
    let mut pool = sc.take_shared<RoyaltyPool<COMPOSITION_SHARE, CURRENCY>>();
    action::redeem_settled_value_and_deposit_for_testing(&mut composition, &cap, &mut pool, 400);
    test_scenario::return_shared(pool);
    test_scenario::return_shared(composition);
    sc.return_to_sender(cap);

    // Lifetime floors: A ⌊300·1401/400⌋ = 1050 → 300 more; B ⌊100·1401/400⌋ = 350 → 100 more.
    holder_claims(&mut sc, HOLDER_A, 300);
    holder_claims(&mut sc, HOLDER_B, 100);

    sc.next_tx(ADMIN);
    let pool = sc.take_shared<RoyaltyPool<COMPOSITION_SHARE, CURRENCY>>();
    assert_eq!(pool.balance().value(), 1);          // 1401 − 1400: sub-unit residue only
    assert_eq!(pool.cumulative_deposits(), 1_401);
    test_scenario::return_shared(pool);
    sc.end();
}
