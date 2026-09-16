// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module composition_routed_stake::composition_routed_stake_edge_event_tests;

use composition_routed_stake::composition_routed_stake as action;
use musicos::composition::{Self, Composition, CompositionAdminCap};
use musicos::recording::{Self, Recording, RecordingAdminCap};
use royalty_pool::pool::{Self, RoyaltyPool};
use royalty_pool::stake::{Self, Stake};
use std::unit_test::{assert_eq, destroy};
use sui::balance;
use sui::bcs;
use sui::event;
use routed_stake::routed_stake;

public struct R1() has drop;
public struct C1() has drop;
public struct R2() has drop;
public struct C2() has drop;
public struct K1() has drop;
public struct K2() has drop;

fun fixture<RecordingShare, CompositionShare>(
    ctx: &mut TxContext,
): (
    Composition<CompositionShare>,
    CompositionAdminCap<CompositionShare>,
    Recording<RecordingShare, CompositionShare>,
    RecordingAdminCap<RecordingShare>,
) {
    let (composition, composition_cap) =
        composition::new_for_testing<CompositionShare>("Composition", 2_000, ctx);
    let (recording, recording_cap) =
        recording::new_for_testing<RecordingShare, CompositionShare>(
            object::id(&composition),
            ctx,
        );
    (composition, composition_cap, recording, recording_cap)
}

fun adapter_counts<RecordingShare, CompositionShare>(): (u64, u64, u64, u64, u64) {
    (
        event::events_by_type<action::CompositionRoutedStakeCreatedEvent<RecordingShare, CompositionShare>>().length(),
        event::events_by_type<action::CompositionRoutedStakeUnstakedEvent<RecordingShare, CompositionShare>>().length(),
        event::events_by_type<action::CompositionRoutedStakeRestakedEvent<RecordingShare, CompositionShare>>().length(),
        event::events_by_type<action::CompositionRoutedStakeRegisteredEvent<RecordingShare, CompositionShare, K1>>().length(),
        event::events_by_type<action::CompositionRoutedStakeUnregisteredEvent<RecordingShare, CompositionShare, K1>>().length(),
    )
}

#[test]
fun generic_event_dimensions_are_independent() {
    let ctx = &mut tx_context::dummy();
    let (mut composition_one, cap_one, mut recording_one, recording_cap_one) =
        fixture<R1, C1>(ctx);
    let (mut composition_two, cap_two, mut recording_two, recording_cap_two) =
        fixture<R2, C2>(ctx);
    let mut pool_one = pool::new_for_testing<R1, K1>(recording_one.uid_mut(&recording_cap_one));
    let mut pool_two = pool::new_for_testing<R2, K2>(recording_two.uid_mut(&recording_cap_two));
    balance::create_for_testing<R1>(11).send_funds(object::id(&composition_one).to_address());
    balance::create_for_testing<R2>(22).send_funds(object::id(&composition_two).to_address());

    let mut routed_one = action::create_stake(
        &mut composition_one, &cap_one, &recording_one, 11, ctx,
    );
    let mut routed_two = action::create_stake(
        &mut composition_two, &cap_two, &recording_two, 22, ctx,
    );
    action::register(
        &mut composition_one, &cap_one, &recording_one, &mut routed_one, &mut pool_one,
    );
    action::register(
        &mut composition_two, &cap_two, &recording_two, &mut routed_two, &mut pool_two,
    );

    let created_one = event::events_by_type<action::CompositionRoutedStakeCreatedEvent<R1, C1>>();
    let created_two = event::events_by_type<action::CompositionRoutedStakeCreatedEvent<R2, C2>>();
    assert_eq!(created_one.length(), 1);
    assert_eq!(created_two.length(), 1);
    let (_, _, _, _, _, _, value_one, _) = action::created_event_fields(&created_one[0]);
    let (_, _, _, _, _, _, value_two, _) = action::created_event_fields(&created_two[0]);
    assert_eq!(value_one, 11); assert_eq!(value_two, 22);
    assert_eq!(bcs::to_bytes(&created_one[0]).length(), 208);
    assert_eq!(bcs::to_bytes(&created_two[0]).length(), 208);

    let registered_one = event::events_by_type<action::CompositionRoutedStakeRegisteredEvent<R1, C1, K1>>();
    let registered_two = event::events_by_type<action::CompositionRoutedStakeRegisteredEvent<R2, C2, K2>>();
    assert_eq!(registered_one.length(), 1);
    assert_eq!(registered_two.length(), 1);
    let (_, _, _, _, stake_one, pool_id_one, principal_one, before_one, after_one, _, _, _, _, debt_one, _, _) =
        action::registered_event_fields(&registered_one[0]);
    let (_, _, _, _, stake_two, pool_id_two, principal_two, before_two, after_two, _, _, _, _, debt_two, _, _) =
        action::registered_event_fields(&registered_two[0]);
    assert_eq!(stake_one, object::id(routed_one.stake()).to_address());
    assert_eq!(stake_two, object::id(routed_two.stake()).to_address());
    assert_eq!(pool_id_one, object::id(&pool_one).to_address());
    assert_eq!(pool_id_two, object::id(&pool_two).to_address());
    assert_eq!(principal_one, 11); assert_eq!(principal_two, 22);
    assert_eq!(before_one, 0); assert_eq!(after_one, 1);
    assert_eq!(before_two, 0); assert_eq!(after_two, 1);
    assert_eq!(debt_one, 0); assert_eq!(debt_two, 0);

    action::unregister(
        &mut composition_one, &cap_one, &recording_one, &mut routed_one, &mut pool_one,
    );
    action::unregister(
        &mut composition_two, &cap_two, &recording_two, &mut routed_two, &mut pool_two,
    );
    balance::destroy_for_testing(action::unstake(&mut composition_one, &cap_one, &mut routed_one));
    balance::destroy_for_testing(action::unstake(&mut composition_two, &cap_two, &mut routed_two));
    destroy(routed_one); destroy(routed_two);
    destroy(pool_one); destroy(pool_two);
    destroy(recording_one); destroy(recording_cap_one);
    destroy(recording_two); destroy(recording_cap_two);
    destroy(composition_one); destroy(cap_one);
    destroy(composition_two); destroy(cap_two);
}

#[test]
fun foreign_same_share_cap_is_accepted_as_type_only_credential() {
    let ctx = &mut tx_context::dummy();
    let (mut composition, composition_cap, recording, recording_cap) = fixture<R1, C1>(ctx);
    let (foreign_composition, foreign_cap) =
        composition::new_for_testing<C1>("Foreign", 2_000, ctx);
    let composition_id = object::id(&composition).to_address();
    let foreign_cap_id = object::id(&foreign_cap).to_address();
    balance::create_for_testing<R1>(7).send_funds(composition_id);
    let mut routed = action::create_stake(
        &mut composition, &foreign_cap, &recording, 7, ctx,
    );
    let created = event::events_by_type<action::CompositionRoutedStakeCreatedEvent<R1, C1>>();
    assert_eq!(created.length(), 1);
    let (_, admin_cap_id, _, _, _, _, principal, _) = action::created_event_fields(&created[0]);
    assert_eq!(admin_cap_id, foreign_cap_id);
    assert_eq!(principal, 7);
    balance::destroy_for_testing(action::unstake(&mut composition, &foreign_cap, &mut routed));
    destroy(routed); destroy(recording); destroy(recording_cap);
    destroy(composition); destroy(composition_cap);
    destroy(foreign_composition); destroy(foreign_cap);
}

#[test]
fun supplied_foreign_cap_id_is_provenance_for_all_five_actions() {
    let ctx = &mut tx_context::dummy();
    let (mut composition, composition_cap, mut recording, recording_cap) = fixture<R1, C1>(ctx);
    let (foreign_composition, foreign_cap) = composition::new_for_testing<C1>("Foreign", 2_000, ctx);
    let foreign_cap_id = object::id(&foreign_cap).to_address();
    let composition_id = object::id(&composition).to_address();
    let mut pool = pool::new_for_testing<R1, K1>(recording.uid_mut(&recording_cap));
    balance::create_for_testing<R1>(5).send_funds(composition_id);
    let mut routed = action::create_stake(&mut composition, &foreign_cap, &recording, 5, ctx);
    let created = event::events_by_type<action::CompositionRoutedStakeCreatedEvent<R1, C1>>();
    let (_, created_cap, _, _, _, _, _, _) = action::created_event_fields(&created[0]);
    assert_eq!(created_cap, foreign_cap_id);
    action::register(&mut composition, &foreign_cap, &recording, &mut routed, &mut pool);
    let registered = event::events_by_type<action::CompositionRoutedStakeRegisteredEvent<R1, C1, K1>>();
    let (_, registered_cap, _, _, _, _, _, _, _, _, _, _, _, _, _, _) = action::registered_event_fields(&registered[0]);
    assert_eq!(registered_cap, foreign_cap_id);
    action::unregister(&mut composition, &foreign_cap, &recording, &mut routed, &mut pool);
    let unregistered = event::events_by_type<action::CompositionRoutedStakeUnregisteredEvent<R1, C1, K1>>();
    let (_, unregistered_cap, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _) = action::unregistered_event_fields(&unregistered[0]);
    assert_eq!(unregistered_cap, foreign_cap_id);
    let principal = action::unstake(&mut composition, &foreign_cap, &mut routed);
    let unstaked = event::events_by_type<action::CompositionRoutedStakeUnstakedEvent<R1, C1>>();
    let (_, unstaked_cap, _, _, _) = action::unstaked_event_fields(&unstaked[0]);
    assert_eq!(unstaked_cap, foreign_cap_id);
    action::restake(&mut composition, &foreign_cap, &mut routed, principal, ctx);
    let restaked = event::events_by_type<action::CompositionRoutedStakeRestakedEvent<R1, C1>>();
    let (_, restaked_cap, _, _, _, _, _) = action::restaked_event_fields(&restaked[0]);
    assert_eq!(restaked_cap, foreign_cap_id);
    action::register(&mut composition, &foreign_cap, &recording, &mut routed, &mut pool);
    action::unregister(&mut composition, &foreign_cap, &recording, &mut routed, &mut pool);
    balance::destroy_for_testing(action::unstake(&mut composition, &foreign_cap, &mut routed));
    destroy(routed); destroy(pool); destroy(recording); destroy(recording_cap);
    destroy(composition); destroy(composition_cap); destroy(foreign_composition); destroy(foreign_cap);
}

#[test]
fun max_u64_principal_round_trips_with_fixed_payload() {
    let ctx = &mut tx_context::dummy();
    let (mut composition, composition_cap, recording, recording_cap) = fixture<R1, C1>(ctx);
    let maximum = 18_446_744_073_709_551_615u64;
    balance::create_for_testing<R1>(maximum).send_funds(object::id(&composition).to_address());
    let mut routed = action::create_stake(
        &mut composition, &composition_cap, &recording, maximum, ctx,
    );
    assert_eq!(routed.value(), maximum);
    let events = event::events_by_type<action::CompositionRoutedStakeCreatedEvent<R1, C1>>();
    assert_eq!(events.length(), 1);
    let (_, _, _, _, _, _, principal, registrations) = action::created_event_fields(&events[0]);
    assert_eq!(principal, maximum); assert_eq!(registrations, 0);
    assert_eq!(bcs::to_bytes(&events[0]).length(), 208);
    balance::destroy_for_testing(action::unstake(&mut composition, &composition_cap, &mut routed));
    destroy(routed); destroy(recording); destroy(recording_cap);
    destroy(composition); destroy(composition_cap);
}

#[test, expected_failure(abort_code = 3, location = royalty_pool::pool)]
fun unregister_without_registration_reaches_dependency_guard() {
    let ctx = &mut tx_context::dummy();
    let (mut composition, composition_cap, mut recording, recording_cap) = fixture<R1, C1>(ctx);
    let mut pool = pool::new_for_testing<R1, K1>(recording.uid_mut(&recording_cap));
    balance::create_for_testing<R1>(5).send_funds(object::id(&composition).to_address());
    let mut routed = action::create_stake(
        &mut composition, &composition_cap, &recording, 5, ctx,
    );
    action::unregister(
        &mut composition, &composition_cap, &recording, &mut routed, &mut pool,
    );
    abort
}

#[test, expected_failure(abort_code = 1, location = routed_stake)]
fun unstake_empty_wrapper_reaches_dependency_guard() {
    let ctx = &mut tx_context::dummy();
    let (mut composition, composition_cap, recording, _recording_cap) = fixture<R1, C1>(ctx);
    balance::create_for_testing<R1>(5).send_funds(object::id(&composition).to_address());
    let mut routed = action::create_stake(
        &mut composition, &composition_cap, &recording, 5, ctx,
    );
    balance::destroy_for_testing(action::unstake(&mut composition, &composition_cap, &mut routed));
    let _principal = action::unstake(&mut composition, &composition_cap, &mut routed);
    abort
}

#[test]
fun views_stake_address_and_direct_sweep_are_adapter_silent() {
    let ctx = &mut tx_context::dummy();
    let (mut composition, composition_cap, mut recording, recording_cap) = fixture<R1, C1>(ctx);
    let mut source = pool::new_for_testing<R1, K1>(recording.uid_mut(&recording_cap));
    let mut destination = pool::new_for_testing<C1, K1>(composition.uid_mut(&composition_cap));
    balance::create_for_testing<R1>(8).send_funds(object::id(&composition).to_address());
    let mut routed = action::create_stake(
        &mut composition, &composition_cap, &recording, 8, ctx,
    );
    action::register(
        &mut composition, &composition_cap, &recording, &mut routed, &mut source,
    );
    let before_total_events = event::num_events();
    let (before_created, before_unstaked, before_restaked, before_registered, before_unregistered) =
        adapter_counts<R1, C1>();
    let expected_address = object::id(&routed).to_address();
    assert_eq!(action::stake_address<R1, C1>(&composition), expected_address);
    assert!(routed.has_stake());
    assert_eq!(routed.value(), 8);
    let wrapped = routed.stake();
    assert_eq!(stake::value(wrapped), 8);
    let (after_views_created, after_views_unstaked, after_views_restaked, after_views_registered, after_views_unregistered) =
        adapter_counts<R1, C1>();
    assert_eq!(before_created, after_views_created);
    assert_eq!(before_unstaked, after_views_unstaked);
    assert_eq!(before_restaked, after_views_restaked);
    assert_eq!(before_registered, after_views_registered);
    assert_eq!(before_unregistered, after_views_unregistered);
    assert_eq!(event::num_events(), before_total_events);

    source.deposit(balance::create_for_testing<K1>(1));
    routed.sweep(&mut source, &mut destination, object::id(&composition));
    let (after_sweep_created, after_sweep_unstaked, after_sweep_restaked, after_sweep_registered, after_sweep_unregistered) =
        adapter_counts<R1, C1>();
    assert_eq!(after_views_created, after_sweep_created);
    assert_eq!(after_views_unstaked, after_sweep_unstaked);
    assert_eq!(after_views_restaked, after_sweep_restaked);
    assert_eq!(after_views_registered, after_sweep_registered);
    assert_eq!(after_views_unregistered, after_sweep_unregistered);
    assert_eq!(event::num_events(), before_total_events + 3);

    action::unregister(
        &mut composition, &composition_cap, &recording, &mut routed, &mut source,
    );
    balance::destroy_for_testing(action::unstake(&mut composition, &composition_cap, &mut routed));
    destroy(routed); destroy(source); destroy(destination);
    destroy(recording); destroy(recording_cap);
    destroy(composition); destroy(composition_cap);
}
