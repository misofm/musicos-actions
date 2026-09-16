// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module composition_routed_stake::composition_routed_stake_replay_event_tests;

use composition_routed_stake::composition_routed_stake as action;
use musicos::composition::{Self, Composition, CompositionAdminCap};
use musicos::recording::{Self, Recording, RecordingAdminCap};
use royalty_pool::pool::{Self, RoyaltyPool};
use royalty_pool::stake::{Self, Stake};
use routed_stake::routed_stake::RoutedStake;
use std::unit_test::{assert_eq, destroy};
use sui::balance;
use sui::bcs;
use sui::event;

public struct R() has drop;
public struct C() has drop;
public struct U1() has drop;
public struct U2() has drop;

fun fixture(ctx: &mut TxContext): (
    Composition<C>,
    CompositionAdminCap<C>,
    Recording<R, C>,
    RecordingAdminCap<R>,
) {
    let (composition, cap) = composition::new_for_testing<C>("Composition", 2_000, ctx);
    let (recording, recording_cap) = recording::new_for_testing<R, C>(object::id(&composition), ctx);
    (composition, cap, recording, recording_cap)
}

fun replay_created(
    event: &action::CompositionRoutedStakeCreatedEvent<R, C>,
    composition_id: address,
    cap_id: address,
    recording_id: address,
    sender: address,
    wrapper: &mut address,
    stake_id: &mut address,
    principal: &mut u64,
    registrations: &mut u64,
) {
    let mut bytes = bcs::new(bcs::to_bytes(event));
    assert_eq!(bytes.peel_address(), composition_id);
    assert_eq!(bytes.peel_address(), cap_id);
    assert_eq!(bytes.peel_address(), recording_id);
    *wrapper = bytes.peel_address();
    *stake_id = bytes.peel_address();
    assert_eq!(bytes.peel_address(), sender);
    *principal = bytes.peel_u64();
    *registrations = bytes.peel_u64();
    assert!(bytes.into_remainder_bytes().is_empty());
}

fun replay_registered<Currency>(
    event: &action::CompositionRoutedStakeRegisteredEvent<R, C, Currency>,
    composition_id: address,
    cap_id: address,
    recording_id: address,
    pool_id: address,
    expected_wrapper: address,
    expected_stake: address,
    expected_principal: u64,
    expected_count: u64,
    expected_pool_shares: u64,
    pool: &RoyaltyPool<R, Currency>,
    projected_count: &mut u64,
    projected_principal: &mut u64,
) {
    let mut bytes = bcs::new(bcs::to_bytes(event));
    assert_eq!(bytes.peel_address(), composition_id);
    assert_eq!(bytes.peel_address(), cap_id);
    assert_eq!(bytes.peel_address(), recording_id);
    assert_eq!(bytes.peel_address(), expected_wrapper);
    assert_eq!(bytes.peel_address(), expected_stake);
    assert_eq!(bytes.peel_address(), pool_id);
    let principal = bytes.peel_u64();
    let count_before = bytes.peel_u64();
    let count_after = bytes.peel_u64();
    assert_eq!(principal, expected_principal);
    assert_eq!(count_before, expected_count);
    assert_eq!(count_after, expected_count + 1);
    assert_eq!(bytes.peel_u64(), expected_pool_shares);
    assert_eq!(bytes.peel_u64(), expected_pool_shares + expected_principal);
    let pool_balance = bytes.peel_u64();
    let pool_index = bytes.peel_u256();
    let registration_debt = bytes.peel_u256();
    let pool_carry = bytes.peel_u128();
    let pool_deposits = bytes.peel_u128();
    assert_eq!(pool_balance, pool.balance().value());
    assert_eq!(pool_index, pool.cumulative_reward_per_share());
    assert_eq!(registration_debt, 0);
    assert_eq!(pool_carry, pool.carry());
    assert_eq!(pool_deposits, pool.cumulative_deposits());
    assert_eq!(pool.staked_shares(), expected_pool_shares + expected_principal);
    assert!(bytes.into_remainder_bytes().is_empty());
    *projected_count = count_after;
    *projected_principal = principal;
}

fun replay_unregistered<Currency>(
    event: &action::CompositionRoutedStakeUnregisteredEvent<R, C, Currency>,
    composition_id: address,
    cap_id: address,
    recording_id: address,
    pool_id: address,
    expected_wrapper: address,
    expected_stake: address,
    expected_principal: u64,
    expected_count: u64,
    expected_pool_shares: u64,
    pool: &RoyaltyPool<R, Currency>,
    projected_count: &mut u64,
) {
    let mut bytes = bcs::new(bcs::to_bytes(event));
    assert_eq!(bytes.peel_address(), composition_id);
    assert_eq!(bytes.peel_address(), cap_id);
    assert_eq!(bytes.peel_address(), recording_id);
    assert_eq!(bytes.peel_address(), expected_wrapper);
    assert_eq!(bytes.peel_address(), expected_stake);
    assert_eq!(bytes.peel_address(), pool_id);
    assert_eq!(bytes.peel_u64(), expected_principal);
    let count_before = bytes.peel_u64();
    let count_after = bytes.peel_u64();
    assert_eq!(count_before, expected_count);
    assert_eq!(count_after, expected_count - 1);
    assert_eq!(bytes.peel_u64(), expected_pool_shares);
    assert_eq!(bytes.peel_u64(), expected_pool_shares - expected_principal);
    let pool_balance = bytes.peel_u64();
    let pool_index = bytes.peel_u256();
    let debt = bytes.peel_u256();
    assert_eq!(debt, 0);
    let pool_carry = bytes.peel_u128();
    let pool_deposits = bytes.peel_u128();
    let forfeited = bytes.peel_u256();
    assert_eq!(pool_balance, pool.balance().value());
    assert_eq!(pool_index, pool.cumulative_reward_per_share());
    assert_eq!(pool_carry, pool.carry());
    assert_eq!(pool_deposits, pool.cumulative_deposits());
    assert_eq!(forfeited, 0);
    assert_eq!(pool.staked_shares(), expected_pool_shares - expected_principal);
    assert!(bytes.into_remainder_bytes().is_empty());
    *projected_count = count_after;
}

fun replay_unstaked(
    event: &action::CompositionRoutedStakeUnstakedEvent<R, C>,
    composition_id: address,
    cap_id: address,
    expected_wrapper: address,
    expected_stake: address,
    expected_principal: u64,
    projected_stake: &mut address,
    projected_principal: &mut u64,
    projected_count: &mut u64,
) {
    let mut bytes = bcs::new(bcs::to_bytes(event));
    assert_eq!(bytes.peel_address(), composition_id);
    assert_eq!(bytes.peel_address(), cap_id);
    assert_eq!(bytes.peel_address(), expected_wrapper);
    assert_eq!(bytes.peel_address(), expected_stake);
    assert_eq!(bytes.peel_u64(), expected_principal);
    assert!(bytes.into_remainder_bytes().is_empty());
    *projected_stake = @0x0;
    *projected_principal = 0;
    *projected_count = 0;
}

fun replay_restaked(
    event: &action::CompositionRoutedStakeRestakedEvent<R, C>,
    composition_id: address,
    cap_id: address,
    sender: address,
    expected_wrapper: address,
    projected_stake: &mut address,
    projected_principal: &mut u64,
    projected_count: &mut u64,
) {
    let mut bytes = bcs::new(bcs::to_bytes(event));
    assert_eq!(bytes.peel_address(), composition_id);
    assert_eq!(bytes.peel_address(), cap_id);
    assert_eq!(bytes.peel_address(), expected_wrapper);
    *projected_stake = bytes.peel_address();
    assert_eq!(bytes.peel_address(), sender);
    *projected_principal = bytes.peel_u64();
    *projected_count = bytes.peel_u64();
    assert!(bytes.into_remainder_bytes().is_empty());
}

fun assert_projection(
    routed: &RoutedStake<R, C>,
    projected_wrapper: address,
    projected_stake: address,
    projected_principal: u64,
    projected_count: u64,
) {
    assert_eq!(object::id(routed).to_address(), projected_wrapper);
    assert!(routed.has_stake());
    assert_eq!(object::id(routed.stake()).to_address(), projected_stake);
    assert_eq!(routed.value(), projected_principal);
    assert_eq!(stake::registration_count(routed.stake()), projected_count);
}

#[test]
fun event_only_replay_matches_two_currency_lifecycle_views() {
    let ctx = &mut tx_context::dummy();
    let sender = tx_context::sender(ctx);
    let (mut composition, cap, mut recording, recording_cap) = fixture(ctx);
    let composition_id = object::id(&composition).to_address();
    let cap_id = object::id(&cap).to_address();
    let recording_id = object::id(&recording).to_address();
    let mut pool_one = pool::new_for_testing<R, U1>(recording.uid_mut(&recording_cap));
    let mut pool_two = pool::new_for_testing<R, U2>(recording.uid_mut(&recording_cap));
    let pool_one_id = object::id(&pool_one).to_address();
    let pool_two_id = object::id(&pool_two).to_address();
    balance::create_for_testing<R>(11).send_funds(composition_id);

    let mut projected_wrapper = @0x0;
    let mut projected_stake = @0x0;
    let mut projected_principal = 0;
    let mut projected_count = 0;
    let mut routed = action::create_stake(&mut composition, &cap, &recording, 11, ctx);
    let created = event::events_by_type<action::CompositionRoutedStakeCreatedEvent<R, C>>();
    replay_created(&created[0], composition_id, cap_id, recording_id, sender, &mut projected_wrapper, &mut projected_stake, &mut projected_principal, &mut projected_count);
    assert_projection(&routed, projected_wrapper, projected_stake, projected_principal, projected_count);

    action::register(&mut composition, &cap, &recording, &mut routed, &mut pool_one);
    let registered_one = event::events_by_type<action::CompositionRoutedStakeRegisteredEvent<R, C, U1>>();
    replay_registered(&registered_one[0], composition_id, cap_id, recording_id, pool_one_id, projected_wrapper, projected_stake, projected_principal, projected_count, 0, &pool_one, &mut projected_count, &mut projected_principal);
    assert_projection(&routed, projected_wrapper, projected_stake, projected_principal, projected_count);

    action::register(&mut composition, &cap, &recording, &mut routed, &mut pool_two);
    let registered_two = event::events_by_type<action::CompositionRoutedStakeRegisteredEvent<R, C, U2>>();
    replay_registered(&registered_two[0], composition_id, cap_id, recording_id, pool_two_id, projected_wrapper, projected_stake, projected_principal, projected_count, 0, &pool_two, &mut projected_count, &mut projected_principal);
    assert_projection(&routed, projected_wrapper, projected_stake, projected_principal, projected_count);

    action::unregister(&mut composition, &cap, &recording, &mut routed, &mut pool_one);
    let unregistered_one = event::events_by_type<action::CompositionRoutedStakeUnregisteredEvent<R, C, U1>>();
    replay_unregistered(&unregistered_one[0], composition_id, cap_id, recording_id, pool_one_id, projected_wrapper, projected_stake, projected_principal, projected_count, 11, &pool_one, &mut projected_count);
    assert_projection(&routed, projected_wrapper, projected_stake, projected_principal, projected_count);
    action::unregister(&mut composition, &cap, &recording, &mut routed, &mut pool_two);
    let unregistered_two = event::events_by_type<action::CompositionRoutedStakeUnregisteredEvent<R, C, U2>>();
    replay_unregistered(&unregistered_two[0], composition_id, cap_id, recording_id, pool_two_id, projected_wrapper, projected_stake, projected_principal, projected_count, 11, &pool_two, &mut projected_count);
    assert_projection(&routed, projected_wrapper, projected_stake, projected_principal, projected_count);

    let principal = action::unstake(&mut composition, &cap, &mut routed);
    let unstaked = event::events_by_type<action::CompositionRoutedStakeUnstakedEvent<R, C>>();
    replay_unstaked(&unstaked[0], composition_id, cap_id, projected_wrapper, projected_stake, projected_principal, &mut projected_stake, &mut projected_principal, &mut projected_count);
    assert_eq!(principal.value(), 11); assert_eq!(projected_principal, 0); assert_eq!(projected_count, 0);
    assert!(!routed.has_stake()); assert_eq!(routed.value(), 0);

    action::restake(&mut composition, &cap, &mut routed, principal, ctx);
    let restaked = event::events_by_type<action::CompositionRoutedStakeRestakedEvent<R, C>>();
    replay_restaked(&restaked[0], composition_id, cap_id, sender, projected_wrapper, &mut projected_stake, &mut projected_principal, &mut projected_count);
    assert_projection(&routed, projected_wrapper, projected_stake, projected_principal, projected_count);

    action::register(&mut composition, &cap, &recording, &mut routed, &mut pool_one);
    let registered_again = event::events_by_type<action::CompositionRoutedStakeRegisteredEvent<R, C, U1>>();
    replay_registered(&registered_again[1], composition_id, cap_id, recording_id, pool_one_id, projected_wrapper, projected_stake, projected_principal, projected_count, 0, &pool_one, &mut projected_count, &mut projected_principal);
    assert_projection(&routed, projected_wrapper, projected_stake, projected_principal, projected_count);
    action::unregister(&mut composition, &cap, &recording, &mut routed, &mut pool_one);
    let unregistered_again = event::events_by_type<action::CompositionRoutedStakeUnregisteredEvent<R, C, U1>>();
    replay_unregistered(&unregistered_again[1], composition_id, cap_id, recording_id, pool_one_id, projected_wrapper, projected_stake, projected_principal, projected_count, 11, &pool_one, &mut projected_count);
    assert_projection(&routed, projected_wrapper, projected_stake, projected_principal, projected_count);
    let final_principal = action::unstake(&mut composition, &cap, &mut routed);
    let unstaked_again = event::events_by_type<action::CompositionRoutedStakeUnstakedEvent<R, C>>();
    replay_unstaked(&unstaked_again[1], composition_id, cap_id, projected_wrapper, projected_stake, projected_principal, &mut projected_stake, &mut projected_principal, &mut projected_count);
    assert_eq!(final_principal.value(), 11); assert!(!routed.has_stake());
    balance::destroy_for_testing(final_principal);
    destroy(routed); destroy(pool_one); destroy(pool_two);
    destroy(recording); destroy(recording_cap); destroy(composition); destroy(cap);
}
