// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module composition_routed_stake::composition_routed_stake_high_width_event_tests;

use composition_routed_stake::composition_routed_stake as action;
use musicos::composition::{Self, Composition, CompositionAdminCap};
use musicos::recording::{Self, Recording, RecordingAdminCap};
use royalty_pool::pool::{Self, RoyaltyPool};
use royalty_pool::stake::{Self, Stake};
use std::unit_test::{assert_eq, destroy};
use sui::balance;
use sui::bcs;
use sui::event;

public struct R() has drop;
public struct C() has drop;
public struct U() has drop;

fun fixture(ctx: &mut TxContext): (
    Composition<C>,
    CompositionAdminCap<C>,
    Recording<R, C>,
    RecordingAdminCap<R>,
) {
    let (composition, composition_cap) =
        composition::new_for_testing<C>("Composition", 2_000, ctx);
    let (recording, recording_cap) =
        recording::new_for_testing<R, C>(object::id(&composition), ctx);
    (composition, composition_cap, recording, recording_cap)
}

fun assert_registered_exact(
    event: &action::CompositionRoutedStakeRegisteredEvent<R, C, U>,
    composition_id: address,
    cap_id: address,
    recording_id: address,
    wrapper_id: address,
    stake_id: address,
    pool_id: address,
    expected_index: u256,
    expected_deposits: u128,
) {
    let mut bytes = bcs::new(bcs::to_bytes(event));
    assert_eq!(bytes.peel_address(), composition_id);
    assert_eq!(bytes.peel_address(), cap_id);
    assert_eq!(bytes.peel_address(), recording_id);
    assert_eq!(bytes.peel_address(), wrapper_id);
    assert_eq!(bytes.peel_address(), stake_id);
    assert_eq!(bytes.peel_address(), pool_id);
    assert_eq!(bytes.peel_u64(), 1);
    assert_eq!(bytes.peel_u64(), 0);
    assert_eq!(bytes.peel_u64(), 1);
    assert_eq!(bytes.peel_u64(), 1);
    assert_eq!(bytes.peel_u64(), 2);
    assert_eq!(bytes.peel_u64(), 1);
    assert_eq!(bytes.peel_u256(), expected_index);
    assert_eq!(bytes.peel_u256(), expected_index);
    assert_eq!(bytes.peel_u128(), 0);
    assert_eq!(bytes.peel_u128(), expected_deposits);
    assert!(bytes.into_remainder_bytes().is_empty());
}

fun assert_unregistered_exact(
    event: &action::CompositionRoutedStakeUnregisteredEvent<R, C, U>,
    composition_id: address,
    cap_id: address,
    recording_id: address,
    wrapper_id: address,
    stake_id: address,
    pool_id: address,
    expected_index: u256,
    expected_deposits: u128,
) {
    let mut bytes = bcs::new(bcs::to_bytes(event));
    assert_eq!(bytes.peel_address(), composition_id);
    assert_eq!(bytes.peel_address(), cap_id);
    assert_eq!(bytes.peel_address(), recording_id);
    assert_eq!(bytes.peel_address(), wrapper_id);
    assert_eq!(bytes.peel_address(), stake_id);
    assert_eq!(bytes.peel_address(), pool_id);
    assert_eq!(bytes.peel_u64(), 1);
    assert_eq!(bytes.peel_u64(), 1);
    assert_eq!(bytes.peel_u64(), 0);
    assert_eq!(bytes.peel_u64(), 2);
    assert_eq!(bytes.peel_u64(), 1);
    assert_eq!(bytes.peel_u64(), 1);
    assert_eq!(bytes.peel_u256(), expected_index);
    assert_eq!(bytes.peel_u256(), expected_index);
    assert_eq!(bytes.peel_u128(), 0);
    assert_eq!(bytes.peel_u128(), expected_deposits);
    assert_eq!(bytes.peel_u256(), 0);
    assert!(bytes.into_remainder_bytes().is_empty());
}

#[test]
fun cumulative_deposits_cross_u64_with_exact_registration_snapshots() {
    let ctx = &mut tx_context::dummy();
    let maximum = 18_446_744_073_709_551_615u64;
    let scale = 1_000_000_000_000_000_000u256;
    let (mut composition, composition_cap, mut recording, recording_cap) = fixture(ctx);
    let composition_id = object::id(&composition).to_address();
    let cap_id = object::id(&composition_cap).to_address();
    let recording_id = object::id(&recording).to_address();
    let mut pool = pool::new_for_testing<R, U>(recording.uid_mut(&recording_cap));
    let pool_id = object::id(&pool).to_address();
    let mut holder = stake::new(balance::create_for_testing<R>(1), ctx);
    pool.register_stake(&mut holder);

    // Claim the first maximum deposit, then add one unit. This makes the
    // cumulative total exceed u64 while retaining a positive pool balance.
    pool.deposit(balance::create_for_testing<U>(maximum));
    let first_reward = pool.claim_rewards(&mut holder);
    assert_eq!(first_reward.value(), maximum);
    balance::destroy_for_testing(first_reward);
    pool.deposit(balance::create_for_testing<U>(1));
    let expected_deposits = (maximum as u128) + 1;
    let expected_index = ((maximum as u256) + 1u256) * scale;
    assert!(expected_deposits > (maximum as u128));
    assert!(expected_index > (maximum as u256));
    assert_eq!(pool.cumulative_deposits(), expected_deposits);
    assert_eq!(pool.cumulative_reward_per_share(), expected_index);

    balance::create_for_testing<R>(1).send_funds(composition_id);
    let mut routed = action::create_stake(&mut composition, &composition_cap, &recording, 1, ctx);
    let wrapper_id = object::id(&routed).to_address();
    let stake_id = object::id(routed.stake()).to_address();
    action::register(&mut composition, &composition_cap, &recording, &mut routed, &mut pool);
    let registered = event::events_by_type<action::CompositionRoutedStakeRegisteredEvent<R, C, U>>();
    assert_eq!(registered.length(), 1);
    assert_registered_exact(
        &registered[0], composition_id, cap_id, recording_id, wrapper_id, stake_id, pool_id,
        expected_index, expected_deposits,
    );

    action::unregister(&mut composition, &composition_cap, &recording, &mut routed, &mut pool);
    let unregistered = event::events_by_type<action::CompositionRoutedStakeUnregisteredEvent<R, C, U>>();
    assert_eq!(unregistered.length(), 1);
    assert_unregistered_exact(
        &unregistered[0], composition_id, cap_id, recording_id, wrapper_id, stake_id, pool_id,
        expected_index, expected_deposits,
    );

    let holder_reward = pool.claim_rewards(&mut holder);
    assert_eq!(holder_reward.value(), 1);
    balance::destroy_for_testing(holder_reward);
    pool.unregister_stake(&mut holder);
    balance::destroy_for_testing(stake::destroy(holder));
    balance::destroy_for_testing(action::unstake(&mut composition, &composition_cap, &mut routed));
    destroy(routed); destroy(pool); destroy(recording); destroy(recording_cap);
    destroy(composition); destroy(composition_cap);
}
