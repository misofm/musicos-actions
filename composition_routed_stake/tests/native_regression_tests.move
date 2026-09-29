// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Native-share accounting regressions retained from the archived coin suite.
#[test_only]
module composition_routed_stake::native_regression_tests;

use composition_routed_stake::composition_routed_stake as action;
use musicos::composition::{Self, Composition, CompositionAdminCap};
use musicos::recording::{Self, Recording, RecordingAdminCap};
use royalty_pool::pool::{Self, RoyaltyPool};
use royalty_pool::stake;
use routed_stake::routed_stake::{Self, RoutedStake};
use share::share::{Self, Issuance, Share};
use std::unit_test::{assert_eq, destroy};
use sui::balance;
use sui::event;

public struct USD has drop {}
public struct EUR has drop {}

public struct Fixture {
    composition: Composition,
    composition_cap: CompositionAdminCap,
    recording: Recording,
    recording_cap: RecordingAdminCap,
    composition_issuance: Issuance,
    recording_issuance: Issuance,
    composition_shares: Share,
    recording_shares: Share,
    source_usd: RoyaltyPool<USD>,
    source_eur: RoyaltyPool<EUR>,
    destination_usd: RoyaltyPool<USD>,
    destination_eur: RoyaltyPool<EUR>,
}

fun fixture(ctx: &mut TxContext): Fixture {
    let (mut composition, composition_cap) = composition::new(ctx);
    let (mut recording, recording_cap) = recording::new(&composition, ctx);
    let mut registry = share::registry_for_testing(ctx);
    let (composition_issuance, composition_shares) =
        share::initialize_for_testing(&mut registry, composition.uid_mut(&composition_cap));
    let (recording_issuance, recording_shares) =
        share::initialize_for_testing(&mut registry, recording.uid_mut(&recording_cap));
    let source_usd = pool::new<USD>(recording.uid_mut(&recording_cap), &recording_issuance);
    let source_eur = pool::new<EUR>(recording.uid_mut(&recording_cap), &recording_issuance);
    let destination_usd = pool::new<USD>(composition.uid_mut(&composition_cap), &composition_issuance);
    let destination_eur = pool::new<EUR>(composition.uid_mut(&composition_cap), &composition_issuance);
    destroy(registry);
    Fixture { composition, composition_cap, recording, recording_cap,
        composition_issuance, recording_issuance, composition_shares, recording_shares,
        source_usd, source_eur, destination_usd, destination_eur }
}

fun create(f: &mut Fixture, value: u64, ctx: &mut TxContext): RoutedStake {
    let shares = f.recording_shares.split(value);
    action::create_stake(&mut f.composition, &f.composition_cap, &f.recording,
        &f.composition_issuance, &f.recording_issuance, shares, ctx)
}

#[test]
fun entry_after_existing_holder_preserves_rounding_and_forfeiture() {
    let ctx = &mut tx_context::dummy();
    let mut fixture_f = fixture(ctx);
    let f = &mut fixture_f;
    let mut holder = stake::new(f.recording_shares.split(3), ctx);
    f.source_usd.register_stake(&mut holder);
    f.source_usd.deposit(balance::create_for_testing<USD>(1));

    let mut routed = create(f, 2, ctx);
    action::register(&mut f.composition, &f.composition_cap, &f.recording,
        &mut routed, &mut f.source_usd);
    let registered = event::events_by_type<action::CompositionRoutedStakeRegisteredEvent<USD>>();
    assert_eq!(registered.length(), 1);
    let (_, _, _, _, _, _, principal, before, after, pool_before, pool_after,
        pool_balance, index, debt, carry, deposits) = action::registered_event_fields(&registered[0]);
    assert_eq!(principal, 2); assert_eq!(before, 0); assert_eq!(after, 1);
    assert_eq!(pool_before, 3); assert_eq!(pool_after, 5); assert_eq!(pool_balance, 1);
    assert_eq!(index, 333_333_333_333_333_333u256);
    assert_eq!(debt, 666_666_666_666_666_666u256);
    assert_eq!(carry, 1u128); assert_eq!(deposits, 1u128);

    f.source_usd.deposit(balance::create_for_testing<USD>(2));
    action::unregister(&mut f.composition, &f.composition_cap, &f.recording,
        &mut routed, &mut f.source_usd);
    let unregistered = event::events_by_type<action::CompositionRoutedStakeUnregisteredEvent<USD>>();
    assert_eq!(unregistered.length(), 1);
    let (_, _, _, _, _, _, principal, before, after, pool_before, pool_after,
        pool_balance, index, debt, carry, deposits, forfeited) =
        action::unregistered_event_fields(&unregistered[0]);
    assert_eq!(principal, 2); assert_eq!(before, 1); assert_eq!(after, 0);
    assert_eq!(pool_before, 5); assert_eq!(pool_after, 3); assert_eq!(pool_balance, 3);
    assert_eq!(index, 733_333_333_333_333_333u256);
    assert_eq!(debt, 666_666_666_666_666_666u256);
    assert_eq!(carry, 1u128); assert_eq!(deposits, 3u128);
    assert_eq!(forfeited, 800_000_000_000_000_000u256);

    let reward = f.source_usd.claim_rewards(&mut holder);
    assert_eq!(reward.value(), 2);
    destroy(reward);
    f.source_usd.unregister_stake(&mut holder);
    f.recording_shares.join(holder.destroy());
    f.recording_shares.join(action::unstake(&mut f.composition, &f.composition_cap, &mut routed));
    assert_eq!(f.recording_shares.value(), share::max_supply!());
    destroy(routed); destroy(fixture_f);
}

#[test]
fun two_currencies_route_independently_through_one_native_stake() {
    let ctx = &mut tx_context::dummy();
    let mut fixture_f = fixture(ctx);
    let f = &mut fixture_f;
    let mut holder = stake::new(f.composition_shares.split(100), ctx);
    f.destination_usd.register_stake(&mut holder);
    f.destination_eur.register_stake(&mut holder);
    let mut routed = create(f, 100, ctx);
    action::register(&mut f.composition, &f.composition_cap, &f.recording,
        &mut routed, &mut f.source_usd);
    action::register(&mut f.composition, &f.composition_cap, &f.recording,
        &mut routed, &mut f.source_eur);
    assert_eq!(stake::registration_count(routed.stake()), 2);
    f.source_usd.deposit(balance::create_for_testing<USD>(9));
    f.source_eur.deposit(balance::create_for_testing<EUR>(17));
    let parent_id = object::id(&f.composition);
    assert_eq!(routed.sweep(&mut f.source_usd, &mut f.destination_usd, parent_id), 9);
    assert_eq!(routed.sweep(&mut f.source_eur, &mut f.destination_eur, parent_id), 17);
    let usd = f.destination_usd.claim_rewards(&mut holder);
    let eur = f.destination_eur.claim_rewards(&mut holder);
    assert_eq!(usd.value(), 9); assert_eq!(eur.value(), 17);
    destroy(usd); destroy(eur);
    assert_eq!(event::events_by_type<routed_stake::RoutedStakeSweptEvent<USD>>().length(), 1);
    assert_eq!(event::events_by_type<routed_stake::RoutedStakeSweptEvent<EUR>>().length(), 1);
    action::unregister(&mut f.composition, &f.composition_cap, &f.recording,
        &mut routed, &mut f.source_usd);
    assert_eq!(stake::registration_count(routed.stake()), 1);
    action::unregister(&mut f.composition, &f.composition_cap, &f.recording,
        &mut routed, &mut f.source_eur);
    assert_eq!(stake::registration_count(routed.stake()), 0);
    f.destination_usd.unregister_stake(&mut holder);
    f.destination_eur.unregister_stake(&mut holder);
    f.composition_shares.join(holder.destroy());
    f.recording_shares.join(action::unstake(&mut f.composition, &f.composition_cap, &mut routed));
    assert_eq!(f.recording_shares.value(), share::max_supply!());
    assert_eq!(f.composition_shares.value(), share::max_supply!());
    destroy(routed); destroy(fixture_f);
}

#[test]
fun unregistration_event_preserves_cumulative_values_past_u64() {
    let ctx = &mut tx_context::dummy();
    let mut fixture_f = fixture(ctx);
    let f = &mut fixture_f;
    let maximum = 18_446_744_073_709_551_615u64;
    let mut holder = stake::new(f.recording_shares.split(1), ctx);
    f.source_usd.register_stake(&mut holder);
    f.source_usd.deposit(balance::create_for_testing<USD>(maximum));
    destroy(f.source_usd.claim_rewards(&mut holder));
    f.source_usd.deposit(balance::create_for_testing<USD>(maximum));
    destroy(f.source_usd.claim_rewards(&mut holder));
    let mut routed = create(f, 1, ctx);
    action::register(&mut f.composition, &f.composition_cap, &f.recording,
        &mut routed, &mut f.source_usd);
    action::unregister(&mut f.composition, &f.composition_cap, &f.recording,
        &mut routed, &mut f.source_usd);
    let events = event::events_by_type<action::CompositionRoutedStakeUnregisteredEvent<USD>>();
    assert_eq!(events.length(), 1);
    let (_, _, _, _, _, _, principal, before, after, pool_before, pool_after,
        pool_balance, index, debt, carry, deposits, forfeited) =
        action::unregistered_event_fields(&events[0]);
    assert_eq!(principal, 1); assert_eq!(before, 1); assert_eq!(after, 0);
    assert_eq!(pool_before, 2); assert_eq!(pool_after, 1); assert_eq!(pool_balance, 0);
    assert_eq!(index, 2u256 * (maximum as u256) * 1_000_000_000_000_000_000u256);
    assert_eq!(debt, index); assert_eq!(carry, 0u128);
    assert_eq!(deposits, 2u128 * (maximum as u128));
    assert!(deposits > (maximum as u128)); assert_eq!(forfeited, 0u256);
    f.source_usd.unregister_stake(&mut holder);
    f.recording_shares.join(holder.destroy());
    f.recording_shares.join(action::unstake(&mut f.composition, &f.composition_cap, &mut routed));
    destroy(routed); destroy(fixture_f);
}
