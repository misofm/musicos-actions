// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// End-to-end royalty flow through the routed-stake action under
/// `test_scenario`: a published Composition owning shares of a published
/// Recording, both canonical pools shared, a routed stake created/registered
/// through the action and shared, an independent recording holder, two
/// composition holders, a stranger who sweeps, and the admin's exit. Every
/// amount is the exact pro-rata floor at each hop.
#[test_only]
module composition_routed_stake::composition_routed_stake_claim_e2e_tests;

use composition_routed_stake::composition_routed_stake as action;
use miso::composition::{Self, Composition, CompositionAdminCap};
use miso::recording::{Self, Recording, RecordingAdminCap};
use royalty_pool::pool::{Self, RoyaltyPool};
use royalty_pool::stake::{Self, Stake};
use routed_stake::routed_stake::{Self, RoutedStake};
use std::unit_test::{assert_eq, destroy};
use sui::balance;
use sui::clock;
use sui::test_scenario::{Self, Scenario};

const ADMIN: address = @0xAD;
const RECORDING_ADMIN: address = @0x2A;
const RECORDING_HOLDER: address = @0x2B;
const HOLDER_C1: address = @0xC1;
const HOLDER_C2: address = @0xC2;
const STRANGER: address = @0x51;

public struct RECORDING_SHARE() has drop;
public struct COMPOSITION_SHARE() has drop;
public struct CURRENCY() has drop;

const COMPOSITION_CUT: u64 = 2_000;

/// Publish a composition and a recording of it, share both canonical pools,
/// and settle the composition's recording-share cut at its address. Then the
/// admin creates, registers and shares the routed stake through the action.
fun setup(sc: &mut Scenario): ID {
    let (mut composition, ccap) =
        composition::new_for_testing<COMPOSITION_SHARE>("Composition", 2_000, sc.ctx());
    let composition_id = object::id(&composition);
    let (mut recording, rcap) =
        recording::new_for_testing<RECORDING_SHARE, COMPOSITION_SHARE>(composition_id, sc.ctx());
    pool::new<COMPOSITION_SHARE, CURRENCY>(composition.uid_mut(&ccap)).share();
    pool::new<RECORDING_SHARE, CURRENCY>(recording.uid_mut(&rcap)).share();
    let clock = clock::create_for_testing(sc.ctx());
    composition.publish(&ccap, &clock);
    recording.publish(&rcap, &clock);
    clock.destroy_for_testing();
    transfer::public_transfer(ccap, ADMIN);
    transfer::public_transfer(rcap, RECORDING_ADMIN);
    balance::create_for_testing<RECORDING_SHARE>(COMPOSITION_CUT).send_funds(composition_id.to_address());

    sc.next_tx(ADMIN);
    let mut composition = sc.take_shared<Composition<COMPOSITION_SHARE>>();
    let ccap = sc.take_from_sender<CompositionAdminCap<COMPOSITION_SHARE>>();
    let recording = sc.take_shared<Recording<RECORDING_SHARE, COMPOSITION_SHARE>>();
    let mut recording_pool = sc.take_shared<RoyaltyPool<RECORDING_SHARE, CURRENCY>>();
    let mut routed = action::create_stake(&mut composition, &ccap, &recording, COMPOSITION_CUT, sc.ctx());
    action::register(&mut composition, &ccap, &recording, &mut routed, &mut recording_pool);
    routed_stake::share(routed);
    test_scenario::return_shared(recording_pool);
    test_scenario::return_shared(recording);
    test_scenario::return_shared(composition);
    sc.return_to_sender(ccap);
    composition_id
}

fun register_holder<S>(sc: &mut Scenario, holder: address, shares: u64) {
    sc.next_tx(holder);
    let mut pool = sc.take_shared<RoyaltyPool<S, CURRENCY>>();
    let mut s = stake::new(balance::create_for_testing<S>(shares), sc.ctx());
    pool.register_stake(&mut s);
    test_scenario::return_shared(pool);
    transfer::public_transfer(s, holder);
}

fun holder_claims<S>(sc: &mut Scenario, holder: address, expected: u64) {
    sc.next_tx(holder);
    let mut pool = sc.take_shared<RoyaltyPool<S, CURRENCY>>();
    let mut s = sc.take_from_sender<Stake<S>>();
    assert_eq!(pool.pending_rewards(&s), expected);
    let reward = pool.claim_rewards(&mut s);
    assert_eq!(reward.value(), expected);
    destroy(reward);
    test_scenario::return_shared(pool);
    sc.return_to_sender(s);
}

fun stranger_sweeps(sc: &mut Scenario, composition_id: ID, expected: u64) {
    sc.next_tx(STRANGER);
    let mut recording_pool = sc.take_shared<RoyaltyPool<RECORDING_SHARE, CURRENCY>>();
    let mut composition_pool = sc.take_shared<RoyaltyPool<COMPOSITION_SHARE, CURRENCY>>();
    let mut routed = sc.take_shared<RoutedStake<RECORDING_SHARE, COMPOSITION_SHARE>>();
    assert_eq!(recording_pool.pending_rewards(routed.stake()), expected);
    let before = composition_pool.balance().value();
    routed.sweep(&mut recording_pool, &mut composition_pool, composition_id);
    assert_eq!(recording_pool.pending_rewards(routed.stake()), 0);
    if (composition_pool.staked_shares() > 0) {
        assert_eq!(composition_pool.balance().value(), before + expected);
    };
    test_scenario::return_shared(recording_pool);
    test_scenario::return_shared(composition_pool);
    test_scenario::return_shared(routed);
}

fun admin_exits(sc: &mut Scenario) {
    sc.next_tx(ADMIN);
    let mut composition = sc.take_shared<Composition<COMPOSITION_SHARE>>();
    let ccap = sc.take_from_sender<CompositionAdminCap<COMPOSITION_SHARE>>();
    let recording = sc.take_shared<Recording<RECORDING_SHARE, COMPOSITION_SHARE>>();
    let mut recording_pool = sc.take_shared<RoyaltyPool<RECORDING_SHARE, CURRENCY>>();
    let mut routed = sc.take_shared<RoutedStake<RECORDING_SHARE, COMPOSITION_SHARE>>();
    action::unregister(&mut composition, &ccap, &recording, &mut routed, &mut recording_pool);
    let principal = action::unstake(&mut composition, &ccap, &mut routed);
    assert_eq!(principal.value(), COMPOSITION_CUT);
    assert!(!routed.has_stake());
    destroy(principal);
    test_scenario::return_shared(routed);
    test_scenario::return_shared(recording_pool);
    test_scenario::return_shared(recording);
    test_scenario::return_shared(composition);
    sc.return_to_sender(ccap);
}

#[test]
fun recording_revenue_reaches_composition_holders_exactly() {
    let mut sc = test_scenario::begin(ADMIN);
    let composition_id = setup(&mut sc);

    // Recording holder stakes 8_000 beside the composition's 2_000.
    register_holder<RECORDING_SHARE>(&mut sc, RECORDING_HOLDER, 8_000);
    // Composition holders stake 100 and 200.
    register_holder<COMPOSITION_SHARE>(&mut sc, HOLDER_C1, 100);
    register_holder<COMPOSITION_SHARE>(&mut sc, HOLDER_C2, 200);

    // Recording revenue: 10_001 (the recording pool accepts deposits from anyone).
    sc.next_tx(STRANGER);
    let mut recording_pool = sc.take_shared<RoyaltyPool<RECORDING_SHARE, CURRENCY>>();
    recording_pool.deposit(balance::create_for_testing<CURRENCY>(10_001));
    test_scenario::return_shared(recording_pool);

    // Composition's cut: ⌊2000·10001/10000⌋ = 2000, swept by a stranger.
    stranger_sweeps(&mut sc, composition_id, 2_000);
    // Recording holder: ⌊8000·10001/10000⌋ = 8000; 1 unit of residue in the recording pool.
    holder_claims<RECORDING_SHARE>(&mut sc, RECORDING_HOLDER, 8_000);
    // Composition holders: ⌊100·2000/300⌋ = 666, ⌊200·2000/300⌋ = 1333; 1 unit of residue.
    holder_claims<COMPOSITION_SHARE>(&mut sc, HOLDER_C1, 666);
    holder_claims<COMPOSITION_SHARE>(&mut sc, HOLDER_C2, 1_333);

    // Second round: 3 units → composition owed ⌊2000·(10001+3)/10000⌋ − 2000 = 0 (2000.8);
    // the zero sweep is a no-op, nothing is lost: a further 2 units lift it to 2001.
    sc.next_tx(STRANGER);
    let mut recording_pool = sc.take_shared<RoyaltyPool<RECORDING_SHARE, CURRENCY>>();
    recording_pool.deposit(balance::create_for_testing<CURRENCY>(3));
    test_scenario::return_shared(recording_pool);
    stranger_sweeps(&mut sc, composition_id, 0);
    sc.next_tx(STRANGER);
    let mut recording_pool = sc.take_shared<RoyaltyPool<RECORDING_SHARE, CURRENCY>>();
    recording_pool.deposit(balance::create_for_testing<CURRENCY>(2));
    test_scenario::return_shared(recording_pool);
    stranger_sweeps(&mut sc, composition_id, 1);
    // Composition holders' lifetime floors: ⌊100·2001/300⌋ = 667 → 1 more; ⌊200·2001/300⌋ = 1334 → 1 more.
    holder_claims<COMPOSITION_SHARE>(&mut sc, HOLDER_C1, 1);
    holder_claims<COMPOSITION_SHARE>(&mut sc, HOLDER_C2, 1);

    sc.next_tx(ADMIN);
    let composition_pool = sc.take_shared<RoyaltyPool<COMPOSITION_SHARE, CURRENCY>>();
    let recording_pool = sc.take_shared<RoyaltyPool<RECORDING_SHARE, CURRENCY>>();
    assert_eq!(composition_pool.balance().value(), 0);        // 2001 − 2001: no residue left
    assert_eq!(recording_pool.balance().value(), 10_006 - 8_000 - 2_001); // 5 = residues of both stakes
    test_scenario::return_shared(composition_pool);
    test_scenario::return_shared(recording_pool);

    admin_exits(&mut sc);
    sc.end();
}

/// protocol-actions #1: with no composition holder registered, the sweep
/// still drains the routed position (reward parked at the composition pool's
/// address for a later `sweep_and_deposit`), so the admin can exit.
#[test]
fun admin_can_exit_while_composition_pool_has_no_stakers() {
    let mut sc = test_scenario::begin(ADMIN);
    let composition_id = setup(&mut sc);

    sc.next_tx(STRANGER);
    let mut recording_pool = sc.take_shared<RoyaltyPool<RECORDING_SHARE, CURRENCY>>();
    recording_pool.deposit(balance::create_for_testing<CURRENCY>(500));
    test_scenario::return_shared(recording_pool);

    stranger_sweeps(&mut sc, composition_id, 500);
    admin_exits(&mut sc);
    sc.end();
}
