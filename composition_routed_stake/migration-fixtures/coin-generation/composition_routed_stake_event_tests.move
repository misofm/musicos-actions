// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module composition_routed_stake::composition_routed_stake_event_tests;

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
public struct OU() has drop;

fun expected_created_bytes(
    composition_id: address,
    admin_cap_id: address,
    recording_id: address,
    routed_stake_id: address,
    stake_id: address,
    sender: address,
    principal_value: u64,
    registration_count: u64,
): vector<u8> {
    let mut bytes = bcs::to_bytes(&composition_id);
    bytes.append(bcs::to_bytes(&admin_cap_id));
    bytes.append(bcs::to_bytes(&recording_id));
    bytes.append(bcs::to_bytes(&routed_stake_id));
    bytes.append(bcs::to_bytes(&stake_id));
    bytes.append(bcs::to_bytes(&sender));
    bytes.append(bcs::to_bytes(&principal_value));
    bytes.append(bcs::to_bytes(&registration_count));
    bytes
}

fun expected_registered_bytes(
    composition_id: address,
    admin_cap_id: address,
    recording_id: address,
    routed_stake_id: address,
    stake_id: address,
    pool_id: address,
    principal_value: u64,
    registration_count_before: u64,
    registration_count_after: u64,
    pool_staked_shares_before: u64,
    pool_staked_shares_after: u64,
    pool_balance: u64,
    pool_index: u256,
    registration_debt: u256,
    pool_carry: u128,
    pool_deposits: u128,
): vector<u8> {
    let mut bytes = bcs::to_bytes(&composition_id);
    bytes.append(bcs::to_bytes(&admin_cap_id));
    bytes.append(bcs::to_bytes(&recording_id));
    bytes.append(bcs::to_bytes(&routed_stake_id));
    bytes.append(bcs::to_bytes(&stake_id));
    bytes.append(bcs::to_bytes(&pool_id));
    bytes.append(bcs::to_bytes(&principal_value));
    bytes.append(bcs::to_bytes(&registration_count_before));
    bytes.append(bcs::to_bytes(&registration_count_after));
    bytes.append(bcs::to_bytes(&pool_staked_shares_before));
    bytes.append(bcs::to_bytes(&pool_staked_shares_after));
    bytes.append(bcs::to_bytes(&pool_balance));
    bytes.append(bcs::to_bytes(&pool_index));
    bytes.append(bcs::to_bytes(&registration_debt));
    bytes.append(bcs::to_bytes(&pool_carry));
    bytes.append(bcs::to_bytes(&pool_deposits));
    bytes
}

fun expected_unregistered_bytes(
    composition_id: address,
    admin_cap_id: address,
    recording_id: address,
    routed_stake_id: address,
    stake_id: address,
    pool_id: address,
    principal_value: u64,
    registration_count_before: u64,
    registration_count_after: u64,
    pool_staked_shares_before: u64,
    pool_staked_shares_after: u64,
    pool_balance: u64,
    pool_index: u256,
    registration_debt: u256,
    pool_carry: u128,
    pool_deposits: u128,
    forfeited_scaled_reward: u256,
): vector<u8> {
    let mut bytes = bcs::to_bytes(&composition_id);
    bytes.append(bcs::to_bytes(&admin_cap_id));
    bytes.append(bcs::to_bytes(&recording_id));
    bytes.append(bcs::to_bytes(&routed_stake_id));
    bytes.append(bcs::to_bytes(&stake_id));
    bytes.append(bcs::to_bytes(&pool_id));
    bytes.append(bcs::to_bytes(&principal_value));
    bytes.append(bcs::to_bytes(&registration_count_before));
    bytes.append(bcs::to_bytes(&registration_count_after));
    bytes.append(bcs::to_bytes(&pool_staked_shares_before));
    bytes.append(bcs::to_bytes(&pool_staked_shares_after));
    bytes.append(bcs::to_bytes(&pool_balance));
    bytes.append(bcs::to_bytes(&pool_index));
    bytes.append(bcs::to_bytes(&registration_debt));
    bytes.append(bcs::to_bytes(&pool_carry));
    bytes.append(bcs::to_bytes(&pool_deposits));
    bytes.append(bcs::to_bytes(&forfeited_scaled_reward));
    bytes
}

fun expected_unstaked_bytes(
    composition_id: address,
    admin_cap_id: address,
    routed_stake_id: address,
    stake_id: address,
    principal_value: u64,
): vector<u8> {
    let mut bytes = bcs::to_bytes(&composition_id);
    bytes.append(bcs::to_bytes(&admin_cap_id));
    bytes.append(bcs::to_bytes(&routed_stake_id));
    bytes.append(bcs::to_bytes(&stake_id));
    bytes.append(bcs::to_bytes(&principal_value));
    bytes
}

fun expected_restaked_bytes(
    composition_id: address,
    admin_cap_id: address,
    routed_stake_id: address,
    stake_id: address,
    sender: address,
    principal_value: u64,
    registration_count: u64,
): vector<u8> {
    let mut bytes = bcs::to_bytes(&composition_id);
    bytes.append(bcs::to_bytes(&admin_cap_id));
    bytes.append(bcs::to_bytes(&routed_stake_id));
    bytes.append(bcs::to_bytes(&stake_id));
    bytes.append(bcs::to_bytes(&sender));
    bytes.append(bcs::to_bytes(&principal_value));
    bytes.append(bcs::to_bytes(&registration_count));
    bytes
}

fun fixture(ctx: &mut TxContext): (
    Composition<C>,
    CompositionAdminCap<C>,
    Recording<R, C>,
    RecordingAdminCap<R>,
) {
    let (composition, composition_cap) =
        composition::new_for_testing<C>(b"Composition".to_string(), 2_000, ctx);
    let (recording, recording_cap) =
        recording::new_for_testing<R, C>(object::id(&composition), ctx);
    (composition, composition_cap, recording, recording_cap)
}

fun assert_created_bcs(
    event: &action::CompositionRoutedStakeCreatedEvent<R, C>,
    composition_id: address,
    admin_cap_id: address,
    recording_id: address,
    routed_stake_id: address,
    stake_id: address,
    sender: address,
    principal_value: u64,
    registration_count: u64,
) {
    let mut bytes = bcs::new(bcs::to_bytes(event));
    assert_eq!(bytes.peel_address(), composition_id);
    assert_eq!(bytes.peel_address(), admin_cap_id);
    assert_eq!(bytes.peel_address(), recording_id);
    assert_eq!(bytes.peel_address(), routed_stake_id);
    assert_eq!(bytes.peel_address(), stake_id);
    assert_eq!(bytes.peel_address(), sender);
    assert_eq!(bytes.peel_u64(), principal_value);
    assert_eq!(bytes.peel_u64(), registration_count);
    assert!(bytes.into_remainder_bytes().is_empty());
}

fun assert_registered_bcs<Currency>(
    event: &action::CompositionRoutedStakeRegisteredEvent<R, C, Currency>,
    composition_id: address,
    admin_cap_id: address,
    recording_id: address,
    routed_stake_id: address,
    stake_id: address,
    pool_id: address,
    principal_value: u64,
    registration_count_before: u64,
    registration_count_after: u64,
    pool_staked_shares_before: u64,
    pool_staked_shares_after: u64,
    pool_balance: u64,
    pool_index: u256,
    registration_debt: u256,
    pool_carry: u128,
    pool_deposits: u128,
) {
    let mut bytes = bcs::new(bcs::to_bytes(event));
    assert_eq!(bytes.peel_address(), composition_id);
    assert_eq!(bytes.peel_address(), admin_cap_id);
    assert_eq!(bytes.peel_address(), recording_id);
    assert_eq!(bytes.peel_address(), routed_stake_id);
    assert_eq!(bytes.peel_address(), stake_id);
    assert_eq!(bytes.peel_address(), pool_id);
    assert_eq!(bytes.peel_u64(), principal_value);
    assert_eq!(bytes.peel_u64(), registration_count_before);
    assert_eq!(bytes.peel_u64(), registration_count_after);
    assert_eq!(bytes.peel_u64(), pool_staked_shares_before);
    assert_eq!(bytes.peel_u64(), pool_staked_shares_after);
    assert_eq!(bytes.peel_u64(), pool_balance);
    assert_eq!(bytes.peel_u256(), pool_index);
    assert_eq!(bytes.peel_u256(), registration_debt);
    assert_eq!(bytes.peel_u128(), pool_carry);
    assert_eq!(bytes.peel_u128(), pool_deposits);
    assert!(bytes.into_remainder_bytes().is_empty());
}

fun assert_unregistered_bcs<Currency>(
    event: &action::CompositionRoutedStakeUnregisteredEvent<R, C, Currency>,
    composition_id: address,
    admin_cap_id: address,
    recording_id: address,
    routed_stake_id: address,
    stake_id: address,
    pool_id: address,
    principal_value: u64,
    registration_count_before: u64,
    registration_count_after: u64,
    pool_staked_shares_before: u64,
    pool_staked_shares_after: u64,
    pool_balance: u64,
    pool_index: u256,
    registration_debt: u256,
    pool_carry: u128,
    pool_deposits: u128,
    forfeited_scaled_reward: u256,
) {
    let mut bytes = bcs::new(bcs::to_bytes(event));
    assert_eq!(bytes.peel_address(), composition_id);
    assert_eq!(bytes.peel_address(), admin_cap_id);
    assert_eq!(bytes.peel_address(), recording_id);
    assert_eq!(bytes.peel_address(), routed_stake_id);
    assert_eq!(bytes.peel_address(), stake_id);
    assert_eq!(bytes.peel_address(), pool_id);
    assert_eq!(bytes.peel_u64(), principal_value);
    assert_eq!(bytes.peel_u64(), registration_count_before);
    assert_eq!(bytes.peel_u64(), registration_count_after);
    assert_eq!(bytes.peel_u64(), pool_staked_shares_before);
    assert_eq!(bytes.peel_u64(), pool_staked_shares_after);
    assert_eq!(bytes.peel_u64(), pool_balance);
    assert_eq!(bytes.peel_u256(), pool_index);
    assert_eq!(bytes.peel_u256(), registration_debt);
    assert_eq!(bytes.peel_u128(), pool_carry);
    assert_eq!(bytes.peel_u128(), pool_deposits);
    assert_eq!(bytes.peel_u256(), forfeited_scaled_reward);
    assert!(bytes.into_remainder_bytes().is_empty());
}

fun assert_unstaked_bcs(
    event: &action::CompositionRoutedStakeUnstakedEvent<R, C>,
    composition_id: address,
    admin_cap_id: address,
    routed_stake_id: address,
    stake_id: address,
    principal_value: u64,
) {
    let mut bytes = bcs::new(bcs::to_bytes(event));
    assert_eq!(bytes.peel_address(), composition_id);
    assert_eq!(bytes.peel_address(), admin_cap_id);
    assert_eq!(bytes.peel_address(), routed_stake_id);
    assert_eq!(bytes.peel_address(), stake_id);
    assert_eq!(bytes.peel_u64(), principal_value);
    assert!(bytes.into_remainder_bytes().is_empty());
}

fun assert_restaked_bcs(
    event: &action::CompositionRoutedStakeRestakedEvent<R, C>,
    composition_id: address,
    admin_cap_id: address,
    routed_stake_id: address,
    stake_id: address,
    sender: address,
    principal_value: u64,
    registration_count: u64,
) {
    let mut bytes = bcs::new(bcs::to_bytes(event));
    assert_eq!(bytes.peel_address(), composition_id);
    assert_eq!(bytes.peel_address(), admin_cap_id);
    assert_eq!(bytes.peel_address(), routed_stake_id);
    assert_eq!(bytes.peel_address(), stake_id);
    assert_eq!(bytes.peel_address(), sender);
    assert_eq!(bytes.peel_u64(), principal_value);
    assert_eq!(bytes.peel_u64(), registration_count);
    assert!(bytes.into_remainder_bytes().is_empty());
}

fun assert_created(
    event: &action::CompositionRoutedStakeCreatedEvent<R, C>,
    composition_id: address,
    admin_cap_id: address,
    recording_id: address,
    routed_id: address,
    stake_id: address,
    sender: address,
) {
    let (c, a, r, w, s, tx_sender, principal, registrations) =
        action::created_event_fields(event);
    assert_eq!(c, composition_id); assert_eq!(a, admin_cap_id); assert_eq!(r, recording_id);
    assert_eq!(w, routed_id); assert_eq!(s, stake_id); assert_eq!(tx_sender, sender);
    assert_eq!(principal, 200); assert_eq!(registrations, 0);
    assert_eq!(bcs::to_bytes(event).length(), 208);
    assert_eq!(
        bcs::to_bytes(event),
        expected_created_bytes(composition_id, admin_cap_id, recording_id, routed_id, stake_id, sender, 200, 0),
    );
    assert_created_bcs(event, composition_id, admin_cap_id, recording_id, routed_id, stake_id, sender, 200, 0);
}

fun assert_registered(
    event: &action::CompositionRoutedStakeRegisteredEvent<R, C, U>,
    composition_id: address,
    admin_cap_id: address,
    recording_id: address,
    routed_id: address,
    stake_id: address,
    pool_id: address,
    count_before: u64,
    count_after: u64,
) {
    let (c, a, r, w, s, p, principal, cb, ca, sb, sa, balance, index, debt, carry, deposits) =
        action::registered_event_fields(event);
    assert_eq!(c, composition_id); assert_eq!(a, admin_cap_id); assert_eq!(r, recording_id);
    assert_eq!(w, routed_id); assert_eq!(s, stake_id); assert_eq!(p, pool_id);
    assert_eq!(principal, 200); assert_eq!(cb, count_before); assert_eq!(ca, count_after);
    assert_eq!(sb, 0); assert_eq!(sa, 200); assert_eq!(balance, 0);
    assert_eq!(index, 0); assert_eq!(debt, 0); assert_eq!(carry, 0); assert_eq!(deposits, 0);
    assert_eq!(bcs::to_bytes(event).length(), 336);
    assert_eq!(
        bcs::to_bytes(event),
        expected_registered_bytes(composition_id, admin_cap_id, recording_id, routed_id, stake_id, pool_id, 200, count_before, count_after, 0, 200, 0, 0, 0, 0, 0),
    );
    assert_registered_bcs(event, composition_id, admin_cap_id, recording_id, routed_id, stake_id, pool_id, 200, count_before, count_after, 0, 200, 0, 0, 0, 0, 0);
}

fun assert_unregistered(
    event: &action::CompositionRoutedStakeUnregisteredEvent<R, C, U>,
    composition_id: address,
    admin_cap_id: address,
    recording_id: address,
    routed_id: address,
    stake_id: address,
    pool_id: address,
    count_before: u64,
    count_after: u64,
) {
    let (c, a, r, w, s, p, principal, cb, ca, sb, sa, balance, index, debt, carry, deposits, forfeited) =
        action::unregistered_event_fields(event);
    assert_eq!(c, composition_id); assert_eq!(a, admin_cap_id); assert_eq!(r, recording_id);
    assert_eq!(w, routed_id); assert_eq!(s, stake_id); assert_eq!(p, pool_id);
    assert_eq!(principal, 200); assert_eq!(cb, count_before); assert_eq!(ca, count_after);
    assert_eq!(sb, 200); assert_eq!(sa, 0); assert_eq!(balance, 0);
    assert_eq!(index, 0); assert_eq!(debt, 0); assert_eq!(carry, 0); assert_eq!(deposits, 0);
    assert_eq!(forfeited, 0); assert_eq!(bcs::to_bytes(event).length(), 368);
    assert_eq!(
        bcs::to_bytes(event),
        expected_unregistered_bytes(composition_id, admin_cap_id, recording_id, routed_id, stake_id, pool_id, 200, count_before, count_after, 200, 0, 0, 0, 0, 0, 0, 0),
    );
    assert_unregistered_bcs(event, composition_id, admin_cap_id, recording_id, routed_id, stake_id, pool_id, 200, count_before, count_after, 200, 0, 0, 0, 0, 0, 0, 0);
}

#[test]
fun adapter_events_have_exact_payloads_and_fresh_stake_identity() {
    let ctx = &mut tx_context::dummy();
    let sender = tx_context::sender(ctx);
    let (mut composition, composition_cap, mut recording, recording_cap) = fixture(ctx);
    let composition_id = object::id(&composition).to_address();
    let admin_cap_id = object::id(&composition_cap).to_address();
    let recording_id = object::id(&recording).to_address();
    let mut recording_pool = pool::new_for_testing<R, U>(recording.uid_mut(&recording_cap));
    let mut other_pool = pool::new_for_testing<R, OU>(recording.uid_mut(&recording_cap));
    balance::create_for_testing<R>(200).send_funds(composition_id);

    let mut routed = action::create_stake(&mut composition, &composition_cap, &recording, 200, ctx);
    let routed_id = object::id(&routed).to_address();
    let first_stake_id = object::id(routed.stake()).to_address();
    let created = event::events_by_type<action::CompositionRoutedStakeCreatedEvent<R, C>>();
    assert_eq!(created.length(), 1);
    assert_created(&created[0], composition_id, admin_cap_id, recording_id, routed_id, first_stake_id, sender);

    action::register(&mut composition, &composition_cap, &recording, &mut routed, &mut recording_pool);
    let pool_id = object::id(&recording_pool).to_address();
    let registered = event::events_by_type<action::CompositionRoutedStakeRegisteredEvent<R, C, U>>();
    assert_eq!(registered.length(), 1);
    assert_registered(&registered[0], composition_id, admin_cap_id, recording_id, routed_id, first_stake_id, pool_id, 0, 1);

    action::register(&mut composition, &composition_cap, &recording, &mut routed, &mut other_pool);
    let other_pool_id = object::id(&other_pool).to_address();
    let other_registered = event::events_by_type<action::CompositionRoutedStakeRegisteredEvent<R, C, OU>>();
    assert_eq!(other_registered.length(), 1);
    let (_, _, _, _, _, p, _, cb, ca, _, _, _, _, _, _, _) =
        action::registered_event_fields(&other_registered[0]);
    assert_eq!(p, other_pool_id); assert_eq!(cb, 1); assert_eq!(ca, 2);
    assert_eq!(bcs::to_bytes(&other_registered[0]).length(), 336);

    action::unregister(&mut composition, &composition_cap, &recording, &mut routed, &mut recording_pool);
    let unregistered = event::events_by_type<action::CompositionRoutedStakeUnregisteredEvent<R, C, U>>();
    assert_eq!(unregistered.length(), 1);
    assert_unregistered(&unregistered[0], composition_id, admin_cap_id, recording_id, routed_id, first_stake_id, pool_id, 2, 1);

    action::unregister(&mut composition, &composition_cap, &recording, &mut routed, &mut other_pool);
    let other_unregistered = event::events_by_type<action::CompositionRoutedStakeUnregisteredEvent<R, C, OU>>();
    assert_eq!(other_unregistered.length(), 1);
    let (_, _, _, _, _, p, _, cb, ca, _, _, _, _, _, _, _, forfeited) =
        action::unregistered_event_fields(&other_unregistered[0]);
    assert_eq!(p, other_pool_id); assert_eq!(cb, 1); assert_eq!(ca, 0); assert_eq!(forfeited, 0);
    assert_eq!(bcs::to_bytes(&other_unregistered[0]).length(), 368);

    let principal = action::unstake(&mut composition, &composition_cap, &mut routed);
    let unstaked = event::events_by_type<action::CompositionRoutedStakeUnstakedEvent<R, C>>();
    assert_eq!(unstaked.length(), 1);
    let (c, a, w, s, value) = action::unstaked_event_fields(&unstaked[0]);
    assert_eq!(c, composition_id); assert_eq!(a, admin_cap_id); assert_eq!(w, routed_id);
    assert_eq!(s, first_stake_id); assert_eq!(value, 200); assert_eq!(value, principal.value());
    assert_eq!(bcs::to_bytes(&unstaked[0]).length(), 136);
    assert_eq!(
        bcs::to_bytes(&unstaked[0]),
        expected_unstaked_bytes(composition_id, admin_cap_id, routed_id, first_stake_id, 200),
    );
    assert_unstaked_bcs(&unstaked[0], composition_id, admin_cap_id, routed_id, first_stake_id, 200);

    action::restake(&mut composition, &composition_cap, &mut routed, principal, ctx);
    let second_stake_id = object::id(routed.stake()).to_address();
    assert!(second_stake_id != first_stake_id);
    let restaked = event::events_by_type<action::CompositionRoutedStakeRestakedEvent<R, C>>();
    assert_eq!(restaked.length(), 1);
    let (c, a, w, s, tx_sender, value, registrations) = action::restaked_event_fields(&restaked[0]);
    assert_eq!(c, composition_id); assert_eq!(a, admin_cap_id); assert_eq!(w, routed_id);
    assert_eq!(s, second_stake_id); assert_eq!(tx_sender, sender);
    assert_eq!(value, 200); assert_eq!(registrations, 0);
    assert_eq!(bcs::to_bytes(&restaked[0]).length(), 176);
    assert_eq!(
        bcs::to_bytes(&restaked[0]),
        expected_restaked_bytes(composition_id, admin_cap_id, routed_id, second_stake_id, sender, 200, 0),
    );
    assert_restaked_bcs(&restaked[0], composition_id, admin_cap_id, routed_id, second_stake_id, sender, 200, 0);

    balance::destroy_for_testing(action::unstake(&mut composition, &composition_cap, &mut routed));
    destroy(routed); destroy(recording_pool); destroy(other_pool);
    destroy(recording); destroy(recording_cap); destroy(composition); destroy(composition_cap);
}

#[test]
fun unregister_event_captures_nontrivial_pool_accounting() {
    let ctx = &mut tx_context::dummy();
    let (mut composition, composition_cap, mut recording, recording_cap) = fixture(ctx);
    let composition_id = object::id(&composition).to_address();
    let mut source = pool::new_for_testing<R, U>(recording.uid_mut(&recording_cap));
    let mut destination = pool::new_for_testing<C, U>(composition.uid_mut(&composition_cap));
    balance::create_for_testing<R>(3).send_funds(composition_id);
    let mut routed = action::create_stake(&mut composition, &composition_cap, &recording, 3, ctx);
    let first_stake_id = object::id(routed.stake()).to_address();
    action::register(&mut composition, &composition_cap, &recording, &mut routed, &mut source);
    source.deposit(balance::create_for_testing<U>(10));
    routed.sweep(&mut source, &mut destination, object::id(&composition));
    action::unregister(&mut composition, &composition_cap, &recording, &mut routed, &mut source);

    let events = event::events_by_type<action::CompositionRoutedStakeUnregisteredEvent<R, C, U>>();
    assert_eq!(events.length(), 1);
    let (_, _, _, _, _, _, principal, cb, ca, sb, sa, pool_balance, index, debt, carry, deposits, forfeited) =
        action::unregistered_event_fields(&events[0]);
    assert_eq!(principal, 3); assert_eq!(cb, 1); assert_eq!(ca, 0);
    assert_eq!(sb, 3); assert_eq!(sa, 0); assert_eq!(pool_balance, 1);
    assert_eq!(index, 3_333_333_333_333_333_333u256);
    assert_eq!(debt, 9_000_000_000_000_000_000u256);
    assert_eq!(carry, 1u128);
    assert_eq!(deposits, 10); assert_eq!(forfeited, 999_999_999_999_999_999u256);
    assert_eq!(bcs::to_bytes(&events[0]).length(), 368);
    assert_eq!(
        bcs::to_bytes(&events[0]),
        expected_unregistered_bytes(object::id(&composition).to_address(), object::id(&composition_cap).to_address(), object::id(&recording).to_address(), object::id(&routed).to_address(), first_stake_id, object::id(&source).to_address(), 3, 1, 0, 3, 0, 1, index, debt, carry, deposits, forfeited),
    );
    assert_unregistered_bcs(&events[0], object::id(&composition).to_address(), object::id(&composition_cap).to_address(), object::id(&recording).to_address(), object::id(&routed).to_address(), first_stake_id, object::id(&source).to_address(), 3, 1, 0, 3, 0, 1, index, debt, carry, deposits, forfeited);

    balance::destroy_for_testing(action::unstake(&mut composition, &composition_cap, &mut routed));
    destroy(routed); destroy(source); destroy(destination);
    destroy(recording); destroy(recording_cap); destroy(composition); destroy(composition_cap);
}

#[test]
fun registration_events_capture_nonzero_entry_accounting_with_holder() {
    let ctx = &mut tx_context::dummy();
    let (mut composition, composition_cap, mut recording, recording_cap) = fixture(ctx);
    let composition_id = object::id(&composition).to_address();
    let composition_cap_id = object::id(&composition_cap).to_address();
    let recording_id = object::id(&recording).to_address();
    let mut pool = pool::new_for_testing<R, U>(recording.uid_mut(&recording_cap));
    let mut holder = stake::new(balance::create_for_testing<R>(3), ctx);
    pool.register_stake(&mut holder);
    let pool_id = object::id(&pool).to_address();
    balance::create_for_testing<R>(2).send_funds(composition_id);
    pool.deposit(balance::create_for_testing<U>(1));
    let mut routed = action::create_stake(&mut composition, &composition_cap, &recording, 2, ctx);
    let stake_id = object::id(routed.stake()).to_address();
    action::register(&mut composition, &composition_cap, &recording, &mut routed, &mut pool);
    let registered = event::events_by_type<action::CompositionRoutedStakeRegisteredEvent<R, C, U>>();
    assert_eq!(registered.length(), 1);
    let (_, _, _, _, _, _, principal, cb, ca, sb, sa, pool_balance, index, debt, carry, deposits) =
        action::registered_event_fields(&registered[0]);
    assert_eq!(principal, 2); assert_eq!(cb, 0); assert_eq!(ca, 1);
    assert_eq!(sb, 3); assert_eq!(sa, 5); assert_eq!(pool_balance, 1);
    assert_eq!(index, 333_333_333_333_333_333u256);
    assert_eq!(debt, 666_666_666_666_666_666u256);
    assert_eq!(carry, 1u128); assert_eq!(deposits, 1);
    assert_registered_bcs(&registered[0], composition_id, composition_cap_id, recording_id, object::id(&routed).to_address(), stake_id, pool_id, 2, 0, 1, 3, 5, 1, index, debt, carry, deposits);

    pool.deposit(balance::create_for_testing<U>(2));
    action::unregister(&mut composition, &composition_cap, &recording, &mut routed, &mut pool);
    let unregistered = event::events_by_type<action::CompositionRoutedStakeUnregisteredEvent<R, C, U>>();
    assert_eq!(unregistered.length(), 1);
    let (_, _, _, _, _, _, principal, cb, ca, sb, sa, pool_balance, index, debt, carry, deposits, forfeited) =
        action::unregistered_event_fields(&unregistered[0]);
    assert_eq!(principal, 2); assert_eq!(cb, 1); assert_eq!(ca, 0);
    assert_eq!(sb, 5); assert_eq!(sa, 3); assert_eq!(pool_balance, 3);
    assert_eq!(index, 733_333_333_333_333_333u256);
    assert_eq!(debt, 666_666_666_666_666_666u256);
    assert_eq!(carry, 1u128); assert_eq!(deposits, 3);
    assert_eq!(forfeited, 800_000_000_000_000_000u256);
    assert_unregistered_bcs(&unregistered[0], composition_id, composition_cap_id, recording_id, object::id(&routed).to_address(), stake_id, pool_id, 2, 1, 0, 5, 3, 3, index, debt, carry, deposits, forfeited);

    let holder_reward = pool.claim_rewards(&mut holder);
    assert_eq!(holder_reward.value(), 2);
    balance::destroy_for_testing(holder_reward);
    pool.unregister_stake(&mut holder);
    balance::destroy_for_testing(stake::destroy(holder));
    balance::destroy_for_testing(action::unstake(&mut composition, &composition_cap, &mut routed));
    destroy(routed); destroy(pool); destroy(recording); destroy(recording_cap);
    destroy(composition); destroy(composition_cap);
}

#[test]
fun u64_max_principal_crosses_every_lifecycle_event_and_return() {
    let ctx = &mut tx_context::dummy();
    let sender = tx_context::sender(ctx);
    let maximum = 18_446_744_073_709_551_615u64;
    let (mut composition, composition_cap, mut recording, recording_cap) = fixture(ctx);
    let composition_id = object::id(&composition).to_address();
    let cap_id = object::id(&composition_cap).to_address();
    let recording_id = object::id(&recording).to_address();
    let mut pool = pool::new_for_testing<R, U>(recording.uid_mut(&recording_cap));
    let pool_id = object::id(&pool).to_address();
    balance::create_for_testing<R>(maximum).send_funds(composition_id);
    let mut routed = action::create_stake(&mut composition, &composition_cap, &recording, maximum, ctx);
    let wrapper_id = object::id(&routed).to_address();
    let first_stake_id = object::id(routed.stake()).to_address();
    let created = event::events_by_type<action::CompositionRoutedStakeCreatedEvent<R, C>>();
    assert_created_bcs(&created[0], composition_id, cap_id, recording_id, wrapper_id, first_stake_id, sender, maximum, 0);
    action::register(&mut composition, &composition_cap, &recording, &mut routed, &mut pool);
    let registered = event::events_by_type<action::CompositionRoutedStakeRegisteredEvent<R, C, U>>();
    assert_registered_bcs(&registered[0], composition_id, cap_id, recording_id, wrapper_id, first_stake_id, pool_id, maximum, 0, 1, 0, maximum, 0, 0, 0, 0, 0);
    action::unregister(&mut composition, &composition_cap, &recording, &mut routed, &mut pool);
    let unregistered = event::events_by_type<action::CompositionRoutedStakeUnregisteredEvent<R, C, U>>();
    assert_unregistered_bcs(&unregistered[0], composition_id, cap_id, recording_id, wrapper_id, first_stake_id, pool_id, maximum, 1, 0, maximum, 0, 0, 0, 0, 0, 0, 0);
    let first_principal = action::unstake(&mut composition, &composition_cap, &mut routed);
    let unstaked = event::events_by_type<action::CompositionRoutedStakeUnstakedEvent<R, C>>();
    assert_eq!(first_principal.value(), maximum);
    assert_unstaked_bcs(&unstaked[0], composition_id, cap_id, wrapper_id, first_stake_id, maximum);
    action::restake(&mut composition, &composition_cap, &mut routed, first_principal, ctx);
    let second_stake_id = object::id(routed.stake()).to_address();
    assert!(second_stake_id != first_stake_id);
    let restaked = event::events_by_type<action::CompositionRoutedStakeRestakedEvent<R, C>>();
    assert_restaked_bcs(&restaked[0], composition_id, cap_id, wrapper_id, second_stake_id, sender, maximum, 0);
    action::register(&mut composition, &composition_cap, &recording, &mut routed, &mut pool);
    let registered_again = event::events_by_type<action::CompositionRoutedStakeRegisteredEvent<R, C, U>>();
    assert_eq!(registered_again.length(), 2);
    assert_registered_bcs(&registered_again[1], composition_id, cap_id, recording_id, wrapper_id, second_stake_id, pool_id, maximum, 0, 1, 0, maximum, 0, 0, 0, 0, 0);
    action::unregister(&mut composition, &composition_cap, &recording, &mut routed, &mut pool);
    let unregistered_again = event::events_by_type<action::CompositionRoutedStakeUnregisteredEvent<R, C, U>>();
    assert_eq!(unregistered_again.length(), 2);
    assert_unregistered_bcs(&unregistered_again[1], composition_id, cap_id, recording_id, wrapper_id, second_stake_id, pool_id, maximum, 1, 0, maximum, 0, 0, 0, 0, 0, 0, 0);
    let final_principal = action::unstake(&mut composition, &composition_cap, &mut routed);
    let unstaked_again = event::events_by_type<action::CompositionRoutedStakeUnstakedEvent<R, C>>();
    assert_eq!(unstaked_again.length(), 2);
    assert_unstaked_bcs(&unstaked_again[1], composition_id, cap_id, wrapper_id, second_stake_id, maximum);
    assert_eq!(final_principal.value(), maximum);
    balance::destroy_for_testing(final_principal);
    destroy(routed); destroy(pool); destroy(recording); destroy(recording_cap);
    destroy(composition); destroy(composition_cap);
}

#[test]
fun u256_and_u128_snapshots_preserve_max_deposit() {
    let ctx = &mut tx_context::dummy();
    let maximum = 18_446_744_073_709_551_615u64;
    let (mut composition, composition_cap, mut recording, recording_cap) = fixture(ctx);
    let composition_id = object::id(&composition).to_address();
    let cap_id = object::id(&composition_cap).to_address();
    let recording_id = object::id(&recording).to_address();
    let mut pool = pool::new_for_testing<R, U>(recording.uid_mut(&recording_cap));
    let mut holder = stake::new(balance::create_for_testing<R>(1), ctx);
    pool.register_stake(&mut holder);
    pool.deposit(balance::create_for_testing<U>(maximum));
    balance::create_for_testing<R>(1).send_funds(composition_id);
    let mut routed = action::create_stake(&mut composition, &composition_cap, &recording, 1, ctx);
    let wrapper_id = object::id(&routed).to_address();
    let stake_id = object::id(routed.stake()).to_address();
    action::register(&mut composition, &composition_cap, &recording, &mut routed, &mut pool);
    let registered = event::events_by_type<action::CompositionRoutedStakeRegisteredEvent<R, C, U>>();
    let (_, _, _, _, _, _, _, _, _, sb, sa, pool_balance, index, debt, carry, deposits) = action::registered_event_fields(&registered[0]);
    assert_eq!(sb, 1); assert_eq!(sa, 2); assert_eq!(pool_balance, maximum);
    assert!(index > 18_446_744_073_709_551_615u256); assert!(debt > 18_446_744_073_709_551_615u256);
    assert_eq!(carry, 0); assert_eq!(deposits, maximum as u128);
    assert_registered_bcs(&registered[0], composition_id, cap_id, recording_id, wrapper_id, stake_id, object::id(&pool).to_address(), 1, 0, 1, 1, 2, maximum, index, debt, carry, deposits);
    action::unregister(&mut composition, &composition_cap, &recording, &mut routed, &mut pool);
    let unregistered = event::events_by_type<action::CompositionRoutedStakeUnregisteredEvent<R, C, U>>();
    let (_, _, _, _, _, _, _, _, _, sb, sa, pool_balance, index, debt, carry, deposits, forfeited) = action::unregistered_event_fields(&unregistered[0]);
    assert_eq!(sb, 2); assert_eq!(sa, 1); assert_eq!(pool_balance, maximum);
    assert!(index > 18_446_744_073_709_551_615u256); assert!(debt > 18_446_744_073_709_551_615u256);
    assert_eq!(carry, 0); assert_eq!(deposits, maximum as u128); assert_eq!(forfeited, 0);
    assert_unregistered_bcs(&unregistered[0], composition_id, cap_id, recording_id, wrapper_id, stake_id, object::id(&pool).to_address(), 1, 1, 0, 2, 1, maximum, index, debt, carry, deposits, forfeited);
    let holder_reward = pool.claim_rewards(&mut holder);
    assert_eq!(holder_reward.value(), maximum);
    balance::destroy_for_testing(holder_reward);
    pool.unregister_stake(&mut holder);
    balance::destroy_for_testing(stake::destroy(holder));
    balance::destroy_for_testing(action::unstake(&mut composition, &composition_cap, &mut routed));
    destroy(routed); destroy(pool); destroy(recording); destroy(recording_cap);
    destroy(composition); destroy(composition_cap);
}
