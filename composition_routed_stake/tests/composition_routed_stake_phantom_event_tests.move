// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module composition_routed_stake::composition_routed_stake_phantom_event_tests;

use composition_routed_stake::composition_routed_stake as action;
use musicos::composition::{Self, Composition, CompositionAdminCap};
use musicos::recording::{Self, Recording, RecordingAdminCap};
use royalty_pool::pool::{Self, RoyaltyPool};
use std::unit_test::{assert_eq, destroy};
use sui::balance;
use sui::event;

public struct R1() has drop;
public struct R2() has drop;
public struct C1() has drop;
public struct C2() has drop;
public struct U1() has drop;
public struct U2() has drop;

fun fixture<RecordingShare, CompositionShare>(
    ctx: &mut TxContext,
): (
    Composition<CompositionShare>,
    CompositionAdminCap<CompositionShare>,
    Recording<RecordingShare, CompositionShare>,
    RecordingAdminCap<RecordingShare>,
) {
    let (composition, cap) = composition::new_for_testing<CompositionShare>("Composition", 2_000, ctx);
    let (recording, recording_cap) = recording::new_for_testing<RecordingShare, CompositionShare>(object::id(&composition), ctx);
    (composition, cap, recording, recording_cap)
}

fun assert_created<RecordingShare, CompositionShare>(
    event: &action::CompositionRoutedStakeCreatedEvent<RecordingShare, CompositionShare>,
    composition_id: address,
    cap_id: address,
    recording_id: address,
    routed_id: address,
    principal: u64,
    sender: address,
) {
    let (c, cap, r, routed, _, tx_sender, value, registrations) = action::created_event_fields(event);
    assert_eq!(c, composition_id); assert_eq!(cap, cap_id); assert_eq!(r, recording_id);
    assert_eq!(routed, routed_id); assert_eq!(tx_sender, sender);
    assert_eq!(value, principal); assert_eq!(registrations, 0);
}

fun assert_registered<RecordingShare, CompositionShare, Currency>(
    event: &action::CompositionRoutedStakeRegisteredEvent<RecordingShare, CompositionShare, Currency>,
    composition_id: address,
    cap_id: address,
    recording_id: address,
    routed_id: address,
    pool_id: address,
    principal: u64,
    count_before: u64,
    count_after: u64,
    shares_before: u64,
    shares_after: u64,
) {
    let (c, cap, r, routed, _, pool, value, cb, ca, sb, sa, balance, index, debt, carry, deposits) =
        action::registered_event_fields(event);
    assert_eq!(c, composition_id); assert_eq!(cap, cap_id); assert_eq!(r, recording_id);
    assert_eq!(routed, routed_id); assert_eq!(pool, pool_id); assert_eq!(value, principal);
    assert_eq!(cb, count_before); assert_eq!(ca, count_after);
    assert_eq!(sb, shares_before); assert_eq!(sa, shares_after);
    assert_eq!(balance, 0); assert_eq!(index, 0); assert_eq!(debt, 0);
    assert_eq!(carry, 0); assert_eq!(deposits, 0);
}

fun assert_unregistered<RecordingShare, CompositionShare, Currency>(
    event: &action::CompositionRoutedStakeUnregisteredEvent<RecordingShare, CompositionShare, Currency>,
    composition_id: address,
    cap_id: address,
    recording_id: address,
    routed_id: address,
    pool_id: address,
    principal: u64,
    count_before: u64,
    count_after: u64,
    shares_before: u64,
    shares_after: u64,
) {
    let (c, cap, r, routed, _, pool, value, cb, ca, sb, sa, balance, index, debt, carry, deposits, forfeited) =
        action::unregistered_event_fields(event);
    assert_eq!(c, composition_id); assert_eq!(cap, cap_id); assert_eq!(r, recording_id);
    assert_eq!(routed, routed_id); assert_eq!(pool, pool_id); assert_eq!(value, principal);
    assert_eq!(cb, count_before); assert_eq!(ca, count_after);
    assert_eq!(sb, shares_before); assert_eq!(sa, shares_after);
    assert_eq!(balance, 0); assert_eq!(index, 0); assert_eq!(debt, 0);
    assert_eq!(carry, 0); assert_eq!(deposits, 0); assert_eq!(forfeited, 0);
}

fun assert_unstaked<RecordingShare, CompositionShare>(
    event: &action::CompositionRoutedStakeUnstakedEvent<RecordingShare, CompositionShare>,
    composition_id: address,
    cap_id: address,
    routed_id: address,
    stake_id: address,
    principal: u64,
) {
    let (c, cap, routed, stake, value) = action::unstaked_event_fields(event);
    assert_eq!(c, composition_id); assert_eq!(cap, cap_id); assert_eq!(routed, routed_id);
    assert_eq!(stake, stake_id); assert_eq!(value, principal);
}

fun assert_restaked<RecordingShare, CompositionShare>(
    event: &action::CompositionRoutedStakeRestakedEvent<RecordingShare, CompositionShare>,
    composition_id: address,
    cap_id: address,
    routed_id: address,
    stake_id: address,
    principal: u64,
    sender: address,
) {
    let (c, cap, routed, stake, tx_sender, value, registrations) = action::restaked_event_fields(event);
    assert_eq!(c, composition_id); assert_eq!(cap, cap_id); assert_eq!(routed, routed_id);
    assert_eq!(stake, stake_id); assert_eq!(tx_sender, sender);
    assert_eq!(value, principal); assert_eq!(registrations, 0);
}

#[test]
fun all_event_families_keep_recording_composition_and_currency_phantoms_separate() {
    let ctx = &mut tx_context::dummy();
    let sender = tx_context::sender(ctx);
    let (mut a, a_cap, mut a_recording, a_recording_cap) = fixture<R1, C1>(ctx);
    let (mut b, b_cap, mut b_recording, b_recording_cap) = fixture<R2, C1>(ctx);
    let (mut c, c_cap, mut c_recording, c_recording_cap) = fixture<R1, C2>(ctx);
    let a_id = object::id(&a).to_address(); let b_id = object::id(&b).to_address(); let c_id = object::id(&c).to_address();
    let a_cap_id = object::id(&a_cap).to_address(); let b_cap_id = object::id(&b_cap).to_address(); let c_cap_id = object::id(&c_cap).to_address();
    let a_recording_id = object::id(&a_recording).to_address(); let b_recording_id = object::id(&b_recording).to_address(); let c_recording_id = object::id(&c_recording).to_address();
    let mut a_u1 = pool::new<R1, U1>(a_recording.uid_mut(&a_recording_cap));
    let mut a_u2 = pool::new<R1, U2>(a_recording.uid_mut(&a_recording_cap));
    let mut b_u1 = pool::new<R2, U1>(b_recording.uid_mut(&b_recording_cap));
    let mut c_u1 = pool::new<R1, U1>(c_recording.uid_mut(&c_recording_cap));
    balance::create_for_testing<R1>(11).send_funds(a_id);
    balance::create_for_testing<R2>(22).send_funds(b_id);
    balance::create_for_testing<R1>(33).send_funds(c_id);
    let mut a_routed = action::create_stake(&mut a, &a_cap, &a_recording, 11, ctx);
    let mut b_routed = action::create_stake(&mut b, &b_cap, &b_recording, 22, ctx);
    let mut c_routed = action::create_stake(&mut c, &c_cap, &c_recording, 33, ctx);
    let a_routed_id = object::id(&a_routed).to_address(); let b_routed_id = object::id(&b_routed).to_address(); let c_routed_id = object::id(&c_routed).to_address();
    let a_stake_id = object::id(a_routed.stake()).to_address(); let b_stake_id = object::id(b_routed.stake()).to_address(); let c_stake_id = object::id(c_routed.stake()).to_address();

    let a_created = event::events_by_type<action::CompositionRoutedStakeCreatedEvent<R1, C1>>();
    let b_created = event::events_by_type<action::CompositionRoutedStakeCreatedEvent<R2, C1>>();
    let c_created = event::events_by_type<action::CompositionRoutedStakeCreatedEvent<R1, C2>>();
    assert_eq!(a_created.length(), 1); assert_eq!(b_created.length(), 1); assert_eq!(c_created.length(), 1);
    assert_created(&a_created[0], a_id, a_cap_id, a_recording_id, a_routed_id, 11, sender);
    assert_created(&b_created[0], b_id, b_cap_id, b_recording_id, b_routed_id, 22, sender);
    assert_created(&c_created[0], c_id, c_cap_id, c_recording_id, c_routed_id, 33, sender);
    assert!(a_routed_id != b_routed_id); assert!(a_routed_id != c_routed_id); assert!(b_routed_id != c_routed_id);

    action::register(&mut a, &a_cap, &a_recording, &mut a_routed, &mut a_u1);
    action::register(&mut a, &a_cap, &a_recording, &mut a_routed, &mut a_u2);
    action::register(&mut b, &b_cap, &b_recording, &mut b_routed, &mut b_u1);
    action::register(&mut c, &c_cap, &c_recording, &mut c_routed, &mut c_u1);
    let a_u1_id = object::id(&a_u1).to_address(); let a_u2_id = object::id(&a_u2).to_address();
    let b_u1_id = object::id(&b_u1).to_address(); let c_u1_id = object::id(&c_u1).to_address();
    let a_reg_u1 = event::events_by_type<action::CompositionRoutedStakeRegisteredEvent<R1, C1, U1>>();
    let a_reg_u2 = event::events_by_type<action::CompositionRoutedStakeRegisteredEvent<R1, C1, U2>>();
    let b_reg_u1 = event::events_by_type<action::CompositionRoutedStakeRegisteredEvent<R2, C1, U1>>();
    let c_reg_u1 = event::events_by_type<action::CompositionRoutedStakeRegisteredEvent<R1, C2, U1>>();
    assert_eq!(a_reg_u1.length(), 1); assert_eq!(a_reg_u2.length(), 1); assert_eq!(b_reg_u1.length(), 1); assert_eq!(c_reg_u1.length(), 1);
    assert_registered(&a_reg_u1[0], a_id, a_cap_id, a_recording_id, a_routed_id, a_u1_id, 11, 0, 1, 0, 11);
    assert_registered(&a_reg_u2[0], a_id, a_cap_id, a_recording_id, a_routed_id, a_u2_id, 11, 1, 2, 0, 11);
    assert_registered(&b_reg_u1[0], b_id, b_cap_id, b_recording_id, b_routed_id, b_u1_id, 22, 0, 1, 0, 22);
    assert_registered(&c_reg_u1[0], c_id, c_cap_id, c_recording_id, c_routed_id, c_u1_id, 33, 0, 1, 0, 33);

    action::unregister(&mut a, &a_cap, &a_recording, &mut a_routed, &mut a_u1);
    action::unregister(&mut a, &a_cap, &a_recording, &mut a_routed, &mut a_u2);
    action::unregister(&mut b, &b_cap, &b_recording, &mut b_routed, &mut b_u1);
    action::unregister(&mut c, &c_cap, &c_recording, &mut c_routed, &mut c_u1);
    let a_unreg_u1 = event::events_by_type<action::CompositionRoutedStakeUnregisteredEvent<R1, C1, U1>>();
    let a_unreg_u2 = event::events_by_type<action::CompositionRoutedStakeUnregisteredEvent<R1, C1, U2>>();
    let b_unreg_u1 = event::events_by_type<action::CompositionRoutedStakeUnregisteredEvent<R2, C1, U1>>();
    let c_unreg_u1 = event::events_by_type<action::CompositionRoutedStakeUnregisteredEvent<R1, C2, U1>>();
    assert_eq!(a_unreg_u1.length(), 1); assert_eq!(a_unreg_u2.length(), 1); assert_eq!(b_unreg_u1.length(), 1); assert_eq!(c_unreg_u1.length(), 1);
    assert_unregistered(&a_unreg_u1[0], a_id, a_cap_id, a_recording_id, a_routed_id, a_u1_id, 11, 2, 1, 11, 0);
    assert_unregistered(&a_unreg_u2[0], a_id, a_cap_id, a_recording_id, a_routed_id, a_u2_id, 11, 1, 0, 11, 0);
    assert_unregistered(&b_unreg_u1[0], b_id, b_cap_id, b_recording_id, b_routed_id, b_u1_id, 22, 1, 0, 22, 0);
    assert_unregistered(&c_unreg_u1[0], c_id, c_cap_id, c_recording_id, c_routed_id, c_u1_id, 33, 1, 0, 33, 0);

    let a_principal = action::unstake(&mut a, &a_cap, &mut a_routed);
    let b_principal = action::unstake(&mut b, &b_cap, &mut b_routed);
    let c_principal = action::unstake(&mut c, &c_cap, &mut c_routed);
    let a_unstaked = event::events_by_type<action::CompositionRoutedStakeUnstakedEvent<R1, C1>>();
    let b_unstaked = event::events_by_type<action::CompositionRoutedStakeUnstakedEvent<R2, C1>>();
    let c_unstaked = event::events_by_type<action::CompositionRoutedStakeUnstakedEvent<R1, C2>>();
    assert_eq!(a_unstaked.length(), 1); assert_eq!(b_unstaked.length(), 1); assert_eq!(c_unstaked.length(), 1);
    assert_unstaked(&a_unstaked[0], a_id, a_cap_id, a_routed_id, a_stake_id, 11);
    assert_unstaked(&b_unstaked[0], b_id, b_cap_id, b_routed_id, b_stake_id, 22);
    assert_unstaked(&c_unstaked[0], c_id, c_cap_id, c_routed_id, c_stake_id, 33);
    action::restake(&mut a, &a_cap, &mut a_routed, a_principal, ctx);
    action::restake(&mut b, &b_cap, &mut b_routed, b_principal, ctx);
    action::restake(&mut c, &c_cap, &mut c_routed, c_principal, ctx);
    let a_restake = event::events_by_type<action::CompositionRoutedStakeRestakedEvent<R1, C1>>();
    let b_restake = event::events_by_type<action::CompositionRoutedStakeRestakedEvent<R2, C1>>();
    let c_restake = event::events_by_type<action::CompositionRoutedStakeRestakedEvent<R1, C2>>();
    assert_eq!(a_restake.length(), 1); assert_eq!(b_restake.length(), 1); assert_eq!(c_restake.length(), 1);
    let (_, _, _, a_fresh, _, _, _) = action::restaked_event_fields(&a_restake[0]);
    let (_, _, _, b_fresh, _, _, _) = action::restaked_event_fields(&b_restake[0]);
    let (_, _, _, c_fresh, _, _, _) = action::restaked_event_fields(&c_restake[0]);
    assert_restaked(&a_restake[0], a_id, a_cap_id, a_routed_id, a_fresh, 11, sender);
    assert_restaked(&b_restake[0], b_id, b_cap_id, b_routed_id, b_fresh, 22, sender);
    assert_restaked(&c_restake[0], c_id, c_cap_id, c_routed_id, c_fresh, 33, sender);
    assert!(a_fresh != a_stake_id); assert!(b_fresh != b_stake_id); assert!(c_fresh != c_stake_id);

    action::register(&mut a, &a_cap, &a_recording, &mut a_routed, &mut a_u1);
    action::register(&mut a, &a_cap, &a_recording, &mut a_routed, &mut a_u2);
    action::register(&mut b, &b_cap, &b_recording, &mut b_routed, &mut b_u1);
    action::register(&mut c, &c_cap, &c_recording, &mut c_routed, &mut c_u1);
    assert_eq!(event::events_by_type<action::CompositionRoutedStakeRegisteredEvent<R1, C1, U1>>().length(), 2);
    assert_eq!(event::events_by_type<action::CompositionRoutedStakeRegisteredEvent<R1, C1, U2>>().length(), 2);
    assert_eq!(event::events_by_type<action::CompositionRoutedStakeRegisteredEvent<R2, C1, U1>>().length(), 2);
    assert_eq!(event::events_by_type<action::CompositionRoutedStakeRegisteredEvent<R1, C2, U1>>().length(), 2);
    action::unregister(&mut a, &a_cap, &a_recording, &mut a_routed, &mut a_u1);
    action::unregister(&mut a, &a_cap, &a_recording, &mut a_routed, &mut a_u2);
    action::unregister(&mut b, &b_cap, &b_recording, &mut b_routed, &mut b_u1);
    action::unregister(&mut c, &c_cap, &c_recording, &mut c_routed, &mut c_u1);
    balance::destroy_for_testing(action::unstake(&mut a, &a_cap, &mut a_routed));
    balance::destroy_for_testing(action::unstake(&mut b, &b_cap, &mut b_routed));
    balance::destroy_for_testing(action::unstake(&mut c, &c_cap, &mut c_routed));
    destroy(a_routed); destroy(b_routed); destroy(c_routed);
    destroy(a_u1); destroy(a_u2); destroy(b_u1); destroy(c_u1);
    destroy(a_recording); destroy(a_recording_cap); destroy(b_recording); destroy(b_recording_cap); destroy(c_recording); destroy(c_recording_cap);
    destroy(a); destroy(a_cap); destroy(b); destroy(b_cap); destroy(c); destroy(c_cap);
}
