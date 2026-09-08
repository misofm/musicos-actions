// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// End-to-end royalty claiming through the action, under `test_scenario`:
/// a published (shared) Recording, its shared canonical pool, two independent
/// share holders, a third-party payer, and the admin folding revenue in via
/// both action paths. Every claim is the exact pro-rata floor.
#[test_only]
module recording_royalty_pool::recording_royalty_pool_claim_e2e_tests;

use musicos::recording::{Self, Recording, RecordingAdminCap};
use recording_royalty_pool::recording_royalty_pool as action;
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

public struct RECORDING_SHARE() has drop;
public struct COMPOSITION_SHARE() has drop;
public struct CURRENCY() has drop;

fun holder_registers(sc: &mut Scenario, holder: address, shares: u64) {
    sc.next_tx(holder);
    let mut pool = sc.take_shared<RoyaltyPool<RECORDING_SHARE, CURRENCY>>();
    let mut s = stake::new(balance::create_for_testing<RECORDING_SHARE>(shares), sc.ctx());
    pool.register_stake(&mut s);
    test_scenario::return_shared(pool);
    transfer::public_transfer(s, holder);
}

fun holder_claims(sc: &mut Scenario, holder: address, expected: u64) {
    sc.next_tx(holder);
    let mut pool = sc.take_shared<RoyaltyPool<RECORDING_SHARE, CURRENCY>>();
    let mut s = sc.take_from_sender<Stake<RECORDING_SHARE>>();
    assert_eq!(pool.pending_rewards(&s), expected);
    let reward = pool.claim_rewards(&mut s);
    assert_eq!(reward.value(), expected);
    destroy(reward);
    test_scenario::return_shared(pool);
    sc.return_to_sender(s);
}

#[test]
fun holders_claim_exact_pro_rata_across_receive_and_redeem_paths() {
    let mut sc = test_scenario::begin(ADMIN);

    let (mut recording, cap) = recording::new_for_testing<RECORDING_SHARE, COMPOSITION_SHARE>(
        object::id_from_address(@0xC0),
        sc.ctx(),
    );
    let recording_id = object::id(&recording);
    action::new_pool<RECORDING_SHARE, COMPOSITION_SHARE, CURRENCY>(&mut recording, &cap).share();
    let clock = clock::create_for_testing(sc.ctx());
    recording.publish(&cap, &clock);
    clock.destroy_for_testing();
    transfer::public_transfer(cap, ADMIN);

    holder_registers(&mut sc, HOLDER_A, 7);
    holder_registers(&mut sc, HOLDER_B, 3);

    sc.next_tx(PAYER);
    let paid = coin::from_balance(balance::create_for_testing<CURRENCY>(1_000), sc.ctx());
    let paid_id = object::id(&paid);
    transfer::public_transfer(paid, recording_id.to_address());

    sc.next_tx(ADMIN);
    let mut recording = sc.take_shared<Recording<RECORDING_SHARE, COMPOSITION_SHARE>>();
    let cap = sc.take_from_sender<RecordingAdminCap<RECORDING_SHARE>>();
    let mut pool = sc.take_shared<RoyaltyPool<RECORDING_SHARE, CURRENCY>>();
    let ticket = test_scenario::receiving_ticket_by_id<Coin<CURRENCY>>(paid_id);
    action::receive_and_deposit(&mut recording, &cap, &mut pool, vector[ticket]);
    test_scenario::return_shared(pool);
    test_scenario::return_shared(recording);
    sc.return_to_sender(cap);

    // 1000 over 10 shares: 700 / 300, exact.
    holder_claims(&mut sc, HOLDER_A, 700);
    holder_claims(&mut sc, HOLDER_B, 300);

    sc.next_tx(PAYER);
    balance::create_for_testing<CURRENCY>(5).send_funds(recording_id.to_address());

    sc.next_tx(ADMIN);
    let mut recording = sc.take_shared<Recording<RECORDING_SHARE, COMPOSITION_SHARE>>();
    let cap = sc.take_from_sender<RecordingAdminCap<RECORDING_SHARE>>();
    let mut pool = sc.take_shared<RoyaltyPool<RECORDING_SHARE, CURRENCY>>();
    action::redeem_and_deposit(&mut recording, &cap, &mut pool, 5);
    test_scenario::return_shared(pool);
    test_scenario::return_shared(recording);
    sc.return_to_sender(cap);

    // 5 over 10 shares: A ⌊7·1005/10⌋ − 700 = 703 − 700 = 3; B ⌊3·1005/10⌋ − 300 = 301 − 300 = 1.
    holder_claims(&mut sc, HOLDER_A, 3);
    holder_claims(&mut sc, HOLDER_B, 1);

    sc.next_tx(ADMIN);
    let pool = sc.take_shared<RoyaltyPool<RECORDING_SHARE, CURRENCY>>();
    assert_eq!(pool.balance().value(), 1);          // 0.5 + 0.5 of residue
    test_scenario::return_shared(pool);
    sc.end();
}
