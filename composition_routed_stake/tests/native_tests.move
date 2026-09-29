// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module composition_routed_stake::native_tests;

use std::unit_test::{assert_eq, destroy};
use sui::balance;
use sui::bcs;
use sui::derived_object;
use sui::event;
use sui::test_scenario;
use vault::vault;
use share::share::{Self, Issuance, Share};
use musicos::composition::{Self, Composition, CompositionAdminCap};
use musicos::recording::{Self, Recording, RecordingAdminCap};
use royalty_pool::pool::{Self, RoyaltyPool};
use royalty_pool::stake;
use routed_stake::routed_stake::{Self, RoutedStake};
use composition_routed_stake::composition_routed_stake as action;

public struct USD has drop {}
public struct EUR has drop {}

public struct Fixture {
    composition: Composition,
    cap: CompositionAdminCap,
    recording: Recording,
    recording_cap: RecordingAdminCap,
    composition_issuance: Issuance,
    recording_issuance: Issuance,
    composition_shares: Share,
    recording_shares: Share,
    source: RoyaltyPool<USD>,
    destination: RoyaltyPool<USD>,
}

fun fixture(ctx: &mut TxContext): Fixture {
    let (mut composition, cap) = composition::new(ctx);
    let (mut recording, recording_cap) = recording::new(&composition, ctx);
    let mut registry = share::registry_for_testing(ctx);
    let (composition_issuance, composition_shares) =
        share::initialize_for_testing(&mut registry, composition.uid_mut(&cap));
    let (recording_issuance, recording_shares) =
        share::initialize_for_testing(&mut registry, recording.uid_mut(&recording_cap));
    let source = pool::new<USD>(recording.uid_mut(&recording_cap), &recording_issuance);
    let destination = pool::new<USD>(composition.uid_mut(&cap), &composition_issuance);
    destroy(registry);
    Fixture { composition, cap, recording, recording_cap, composition_issuance,
        recording_issuance, composition_shares, recording_shares, source, destination }
}

fun create(f: &mut Fixture, amount: u64, ctx: &mut TxContext): RoutedStake {
    let shares = f.recording_shares.split(amount);
    action::create_stake(&mut f.composition, &f.cap, &f.recording,
        &f.composition_issuance, &f.recording_issuance, shares, ctx)
}

fun register(f: &mut Fixture, routed: &mut RoutedStake) {
    action::register(&mut f.composition, &f.cap, &f.recording, routed, &mut f.source);
}

fun unregister(f: &mut Fixture, routed: &mut RoutedStake) {
    action::unregister(&mut f.composition, &f.cap, &f.recording, routed, &mut f.source);
}

#[test]
fun full_native_lifecycle_conserves_principal_and_routes_rewards() {
    let ctx = &mut tx_context::dummy();
    let mut fixture_f = fixture(ctx);
    let f = &mut fixture_f;
    let mut routed = create(f, 200, ctx);
    let wrapper_id = object::id(&routed);
    let first_stake_id = object::id(routed.stake());
    assert_eq!(wrapper_id.to_address(),
        action::stake_address(&f.composition, object::id(&f.recording_issuance)));
    let mut holder_a = stake::new(f.composition_shares.split(300), ctx);
    let mut holder_b = stake::new(f.composition_shares.split(700), ctx);
    f.destination.register_stake(&mut holder_a);
    f.destination.register_stake(&mut holder_b);
    register(f, &mut routed);
    f.source.deposit(balance::create_for_testing<USD>(1000));
    assert_eq!(routed.sweep(&mut f.source, &mut f.destination, object::id(&f.composition)), 1000);
    let a = f.destination.claim_rewards(&mut holder_a);
    let b = f.destination.claim_rewards(&mut holder_b);
    assert_eq!(a.value(), 300);
    assert_eq!(b.value(), 700);
    assert_eq!(routed.sweep(&mut f.source, &mut f.destination, object::id(&f.composition)), 0);
    unregister(f, &mut routed);
    let principal = action::unstake(&mut f.composition, &f.cap, &mut routed);
    assert_eq!(principal.value(), 200);
    assert_eq!(principal.issuance_id(), object::id(&f.recording_issuance));
    action::restake(&mut f.composition, &f.cap, &mut routed, principal, ctx);
    assert_eq!(object::id(&routed), wrapper_id);
    assert!(object::id(routed.stake()) != first_stake_id);
    let principal = action::unstake(&mut f.composition, &f.cap, &mut routed);
    f.recording_shares.join(principal);
    assert_eq!(f.recording_shares.value(), share::max_supply!());
    destroy(a); destroy(b); destroy(holder_a); destroy(holder_b); destroy(routed); destroy(fixture_f);
}

#[test]
fun no_destination_stakers_parks_rewards_and_allows_exit() {
    let ctx = &mut tx_context::dummy();
    let mut fixture_f = fixture(ctx);
    let f = &mut fixture_f;
    let mut routed = create(f, 200, ctx);
    register(f, &mut routed);
    f.source.deposit(balance::create_for_testing<USD>(500));
    assert_eq!(routed.sweep(&mut f.source, &mut f.destination, object::id(&f.composition)), 500);
    let events = event::events_by_type<routed_stake::RoutedStakeSweptEvent<USD>>();
    let (_, _, value, parked) = routed_stake::swept_event_summary(&events[0]);
    assert_eq!(value, 500); assert!(parked);
    unregister(f, &mut routed);
    let principal = action::unstake(&mut f.composition, &f.cap, &mut routed);
    f.recording_shares.join(principal);
    assert_eq!(f.recording_shares.value(), share::max_supply!());
    destroy(routed); destroy(fixture_f);
}

#[test]
fun created_event_has_exact_payload() {
    let ctx = &mut tx_context::dummy();
    let mut fixture_f = fixture(ctx);
    let f = &mut fixture_f;
    let mut routed = create(f, 200, ctx);
    let cid = object::id(&f.composition).to_address();
    let capid = object::id(&f.cap).to_address();
    let rid = object::id(&f.recording).to_address();
    let wid = object::id(&routed).to_address();
    let sid = object::id(routed.stake()).to_address();
    let _pid = object::id(&f.source).to_address();
    let created = event::events_by_type<action::CompositionRoutedStakeCreatedEvent>();
    assert_eq!(created.length(), 1);
    let (c, cap, r, w, s, sender, value, count) = action::created_event_fields(&created[0]);
    assert_eq!(c, cid); assert_eq!(cap, capid); assert_eq!(r, rid);
    assert_eq!(w, wid); assert_eq!(s, sid); assert_eq!(sender, ctx.sender());
    assert_eq!(value, 200); assert_eq!(count, 0);
    assert_eq!(bcs::to_bytes(&created[0]).length(), 208);
    destroy(routed); destroy(fixture_f);
}

#[test]
fun registered_event_has_exact_payload() {
    let ctx = &mut tx_context::dummy();
    let mut fixture_f = fixture(ctx);
    let f = &mut fixture_f;
    let mut routed = create(f, 200, ctx);
    let cid = object::id(&f.composition).to_address();
    let capid = object::id(&f.cap).to_address();
    let rid = object::id(&f.recording).to_address();
    let wid = object::id(&routed).to_address();
    let sid = object::id(routed.stake()).to_address();
    let pid = object::id(&f.source).to_address();
    register(f, &mut routed);
    let events = event::events_by_type<action::CompositionRoutedStakeRegisteredEvent<USD>>();
    assert_eq!(events.length(), 1);
    let (c,cap,r,w,s,p,v,before,after,pb,pa,balance,index,debt,carry,deposits) =
        action::registered_event_fields(&events[0]);
    assert_eq!(c,cid); assert_eq!(cap,capid); assert_eq!(r,rid); assert_eq!(w,wid);
    assert_eq!(s,sid); assert_eq!(p,pid); assert_eq!(v,200);
    assert_eq!(before,0); assert_eq!(after,1); assert_eq!(pb,0); assert_eq!(pa,200);
    assert_eq!(balance,0); assert_eq!(index,0); assert_eq!(debt,0);
    assert_eq!(carry,0); assert_eq!(deposits,0);
    assert_eq!(bcs::to_bytes(&events[0]).length(), 336);
    destroy(routed); destroy(fixture_f);
}

#[test]
fun unregistered_event_has_exact_payload() {
    let ctx = &mut tx_context::dummy();
    let mut fixture_f = fixture(ctx);
    let f = &mut fixture_f;
    let mut routed = create(f, 200, ctx);
    let cid = object::id(&f.composition).to_address();
    let capid = object::id(&f.cap).to_address();
    let rid = object::id(&f.recording).to_address();
    let wid = object::id(&routed).to_address();
    let sid = object::id(routed.stake()).to_address();
    let pid = object::id(&f.source).to_address();
    register(f, &mut routed);
    unregister(f, &mut routed);
    let events = event::events_by_type<action::CompositionRoutedStakeUnregisteredEvent<USD>>();
    let (c,cap,r,w,s,p,v,before,after,pb,pa,balance,index,debt,carry,deposits,residue) =
        action::unregistered_event_fields(&events[0]);
    assert_eq!(c,cid); assert_eq!(cap,capid); assert_eq!(r,rid); assert_eq!(w,wid);
    assert_eq!(s,sid); assert_eq!(p,pid); assert_eq!(v,200);
    assert_eq!(before,1); assert_eq!(after,0); assert_eq!(pb,200); assert_eq!(pa,0);
    assert_eq!(balance,0); assert_eq!(index,0); assert_eq!(debt,0);
    assert_eq!(carry,0); assert_eq!(deposits,0); assert_eq!(residue,0);
    assert_eq!(bcs::to_bytes(&events[0]).length(), 368);
    destroy(routed); destroy(fixture_f);
}

#[test]
fun unstaked_event_has_exact_payload() {
    let ctx = &mut tx_context::dummy();
    let mut fixture_f = fixture(ctx);
    let f = &mut fixture_f;
    let mut routed = create(f, 200, ctx);
    let cid = object::id(&f.composition).to_address();
    let capid = object::id(&f.cap).to_address();
    let _rid = object::id(&f.recording).to_address();
    let wid = object::id(&routed).to_address();
    let sid = object::id(routed.stake()).to_address();
    let _pid = object::id(&f.source).to_address();
    register(f, &mut routed);
    unregister(f, &mut routed);
    let principal = action::unstake(&mut f.composition,&f.cap,&mut routed);
    let events = event::events_by_type<action::CompositionRoutedStakeUnstakedEvent>();
    let (c,cap,w,s,v) = action::unstaked_event_fields(&events[0]);
    assert_eq!(c,cid); assert_eq!(cap,capid); assert_eq!(w,wid); assert_eq!(s,sid); assert_eq!(v,200);
    assert_eq!(bcs::to_bytes(&events[0]).length(),136);
    destroy(principal);
    destroy(routed); destroy(fixture_f);
}

#[test]
fun restaked_event_has_exact_payload() {
    let ctx = &mut tx_context::dummy();
    let mut fixture_f = fixture(ctx);
    let f = &mut fixture_f;
    let mut routed = create(f, 200, ctx);
    let cid = object::id(&f.composition).to_address();
    let capid = object::id(&f.cap).to_address();
    let _rid = object::id(&f.recording).to_address();
    let wid = object::id(&routed).to_address();
    let sid = object::id(routed.stake()).to_address();
    let _pid = object::id(&f.source).to_address();
    register(f, &mut routed);
    unregister(f, &mut routed);
    let principal = action::unstake(&mut f.composition,&f.cap,&mut routed);
    action::restake(&mut f.composition,&f.cap,&mut routed,principal,ctx);
    let events = event::events_by_type<action::CompositionRoutedStakeRestakedEvent>();
    let (c,cap,w,s,sender,v,count) = action::restaked_event_fields(&events[0]);
    assert_eq!(c,cid); assert_eq!(cap,capid); assert_eq!(w,wid);
    assert_eq!(s,object::id(routed.stake()).to_address()); assert!(s != sid);
    assert_eq!(sender,ctx.sender()); assert_eq!(v,200); assert_eq!(count,0);
    assert_eq!(bcs::to_bytes(&events[0]).length(),176);
    destroy(routed); destroy(fixture_f);
}

#[test]
fun maximum_native_supply_round_trips() {
    let ctx = &mut tx_context::dummy();
    let mut fixture_f = fixture(ctx);
    let f = &mut fixture_f;
    let mut routed = create(f, share::max_supply!(), ctx);
    let principal = action::unstake(&mut f.composition,&f.cap,&mut routed);
    assert_eq!(principal.value(),share::max_supply!());
    f.recording_shares.join(principal);
    assert_eq!(f.recording_shares.value(),share::max_supply!());
    destroy(routed); destroy(fixture_f);
}

#[test]
fun payout_currencies_have_independent_registrations() {
    let ctx = &mut tx_context::dummy();
    let mut fixture_f = fixture(ctx);
    let f = &mut fixture_f;
    let mut euro = pool::new<EUR>(f.recording.uid_mut(&f.recording_cap),&f.recording_issuance);
    let mut routed = create(f, 1, ctx);
    register(f,&mut routed);
    action::register(&mut f.composition,&f.cap,&f.recording,&mut routed,&mut euro);
    assert_eq!(stake::registration_count(routed.stake()),2);
    assert_eq!(event::events_by_type<action::CompositionRoutedStakeRegisteredEvent<USD>>().length(),1);
    assert_eq!(event::events_by_type<action::CompositionRoutedStakeRegisteredEvent<EUR>>().length(),1);
    action::unregister(&mut f.composition,&f.cap,&f.recording,&mut routed,&mut euro);
    unregister(f,&mut routed);
    assert_eq!(stake::registration_count(routed.stake()),0);
    destroy(routed); destroy(euro); destroy(fixture_f);
}

#[test]
fun cumulative_payouts_exceed_u64_without_truncating_events() {
    let ctx = &mut tx_context::dummy();
    let mut fixture_f = fixture(ctx);
    let f = &mut fixture_f;
    let mut holder = stake::new(f.recording_shares.split(1),ctx);
    f.source.register_stake(&mut holder);
    let maximum = 18446744073709551615u64;
    f.source.deposit(balance::create_for_testing<USD>(maximum));
    destroy(f.source.claim_rewards(&mut holder));
    f.source.deposit(balance::create_for_testing<USD>(maximum));
    destroy(f.source.claim_rewards(&mut holder));
    let mut routed = create(f,1,ctx);
    register(f,&mut routed);
    let events = event::events_by_type<action::CompositionRoutedStakeRegisteredEvent<USD>>();
    let (_,_,_,_,_,_,_,_,_,_,_,_,index,debt,_,deposits) = action::registered_event_fields(&events[0]);
    assert_eq!(deposits,2 * (maximum as u128));
    assert!(index > (maximum as u256)); assert_eq!(debt,index);
    unregister(f,&mut routed);
    destroy(routed); destroy(holder); destroy(fixture_f);
}

#[test, expected_failure(abort_code = action::ENoValueToRedeem)]
fun zero_principal_rejected() {
    let ctx = &mut tx_context::dummy();
    let mut fixture_f = fixture(ctx);
    let f = &mut fixture_f;
    let _r = create(f,0,ctx); destroy(_r);
    destroy(fixture_f);
}

#[test, expected_failure(abort_code = derived_object::EObjectAlreadyExists)]
fun duplicate_route_rejected() {
    let ctx = &mut tx_context::dummy();
    let mut fixture_f = fixture(ctx);
    let f = &mut fixture_f;
    let _a =create(f,1,ctx); destroy(_a); let _b =create(f,1,ctx); destroy(_b);
    destroy(fixture_f);
}

#[test, expected_failure(abort_code = composition::EUnauthorized)]
fun foreign_creation_cap_rejected() {
    let ctx = &mut tx_context::dummy();
    let mut fixture_f = fixture(ctx);
    let f = &mut fixture_f;
    let mut fixture_g = fixture(ctx);
    let g = &mut fixture_g; let shares=f.recording_shares.split(1); let _r =action::create_stake(&mut f.composition,&g.cap,&f.recording,&f.composition_issuance,&f.recording_issuance,shares,ctx); destroy(_r); destroy(fixture_g);
    destroy(fixture_f);
}

#[test, expected_failure(abort_code = action::ERecordingNotForComposition)]
fun foreign_recording_rejected() {
    let ctx = &mut tx_context::dummy();
    let mut fixture_f = fixture(ctx);
    let f = &mut fixture_f;
    let mut fixture_g = fixture(ctx);
    let g = &mut fixture_g; let shares=f.recording_shares.split(1); let _r =action::create_stake(&mut f.composition,&f.cap,&g.recording,&f.composition_issuance,&g.recording_issuance,shares,ctx); destroy(_r); destroy(fixture_g);
    destroy(fixture_f);
}

#[test, expected_failure(abort_code = action::EStakeNotForComposition)]
fun foreign_destination_issuance_rejected() {
    let ctx = &mut tx_context::dummy();
    let mut fixture_f = fixture(ctx);
    let f = &mut fixture_f;
    let mut fixture_g = fixture(ctx);
    let g = &mut fixture_g; let shares=f.recording_shares.split(1); let _r =action::create_stake(&mut f.composition,&f.cap,&f.recording,&g.composition_issuance,&f.recording_issuance,shares,ctx); destroy(_r); destroy(fixture_g);
    destroy(fixture_f);
}

#[test, expected_failure(abort_code = action::ERecordingNotForComposition)]
fun foreign_source_issuance_rejected() {
    let ctx = &mut tx_context::dummy();
    let mut fixture_f = fixture(ctx);
    let f = &mut fixture_f;
    let mut fixture_g = fixture(ctx);
    let g = &mut fixture_g; let shares=f.recording_shares.split(1); let _r =action::create_stake(&mut f.composition,&f.cap,&f.recording,&f.composition_issuance,&g.recording_issuance,shares,ctx); destroy(_r); destroy(fixture_g);
    destroy(fixture_f);
}

#[test, expected_failure(abort_code = action::EPoolNotForRecording)]
fun foreign_native_shares_rejected() {
    let ctx = &mut tx_context::dummy();
    let mut fixture_f = fixture(ctx);
    let f = &mut fixture_f;
    let mut fixture_g = fixture(ctx);
    let g = &mut fixture_g; let shares=g.recording_shares.split(1); let _r =action::create_stake(&mut f.composition,&f.cap,&f.recording,&f.composition_issuance,&f.recording_issuance,shares,ctx); destroy(_r); destroy(fixture_g);
    destroy(fixture_f);
}

#[test, expected_failure(abort_code = pool::EAlreadyRegistered)]
fun double_registration_rejected() {
    let ctx = &mut tx_context::dummy();
    let mut fixture_f = fixture(ctx);
    let f = &mut fixture_f;
    let mut r=create(f,1,ctx); register(f,&mut r); register(f,&mut r); destroy(r);
    destroy(fixture_f);
}

#[test, expected_failure(abort_code = pool::ENotRegistered)]
fun unregister_without_registration_rejected() {
    let ctx = &mut tx_context::dummy();
    let mut fixture_f = fixture(ctx);
    let f = &mut fixture_f;
    let mut r=create(f,1,ctx); unregister(f,&mut r); destroy(r);
    destroy(fixture_f);
}

#[test, expected_failure(abort_code = stake::EPoolsRegistered)]
fun unstake_registered_position_rejected() {
    let ctx = &mut tx_context::dummy();
    let mut fixture_f = fixture(ctx);
    let f = &mut fixture_f;
    let mut r=create(f,1,ctx); register(f,&mut r); let _p =action::unstake(&mut f.composition,&f.cap,&mut r); destroy(_p); destroy(r);
    destroy(fixture_f);
}

#[test, expected_failure(abort_code = pool::ELastClaimIndexMismatch)]
fun unregister_with_pending_rewards_rejected() {
    let ctx = &mut tx_context::dummy();
    let mut fixture_f = fixture(ctx);
    let f = &mut fixture_f;
    let mut r=create(f,1,ctx); register(f,&mut r); f.source.deposit(balance::create_for_testing<USD>(1)); unregister(f,&mut r); destroy(r);
    destroy(fixture_f);
}

#[test, expected_failure(abort_code = routed_stake::EStakeExists)]
fun restake_filled_wrapper_rejected() {
    let ctx = &mut tx_context::dummy();
    let mut fixture_f = fixture(ctx);
    let f = &mut fixture_f;
    let mut r=create(f,1,ctx); let shares=f.recording_shares.split(1); action::restake(&mut f.composition,&f.cap,&mut r,shares,ctx); destroy(r);
    destroy(fixture_f);
}

#[test, expected_failure(abort_code = stake::EZeroBalance)]
fun restake_zero_principal_rejected() {
    let ctx = &mut tx_context::dummy();
    let mut fixture_f = fixture(ctx);
    let f = &mut fixture_f;
    let mut r=create(f,1,ctx); destroy(action::unstake(&mut f.composition,&f.cap,&mut r)); let shares=f.recording_shares.split(0); action::restake(&mut f.composition,&f.cap,&mut r,shares,ctx); destroy(r);
    destroy(fixture_f);
}

#[test, expected_failure(abort_code = routed_stake::EIssuanceMismatch)]
fun restake_foreign_issuance_rejected() {
    let ctx = &mut tx_context::dummy();
    let mut fixture_f = fixture(ctx);
    let f = &mut fixture_f;
    let mut r=create(f,1,ctx); destroy(action::unstake(&mut f.composition,&f.cap,&mut r)); let shares=f.composition_shares.split(1); action::restake(&mut f.composition,&f.cap,&mut r,shares,ctx); destroy(r);
    destroy(fixture_f);
}

#[test, expected_failure(abort_code = composition::EUnauthorized)]
fun register_foreign_cap_rejected() {
    let ctx = &mut tx_context::dummy();
    let mut fixture_f = fixture(ctx);
    let f = &mut fixture_f;
    let mut fixture_g = fixture(ctx);
    let g = &mut fixture_g; let mut r=create(f,1,ctx); action::register(&mut f.composition,&g.cap,&f.recording,&mut r,&mut f.source); destroy(fixture_g); destroy(r);
    destroy(fixture_f);
}

#[test, expected_failure(abort_code = action::ERecordingNotForComposition)]
fun register_foreign_recording_rejected() {
    let ctx = &mut tx_context::dummy();
    let mut fixture_f = fixture(ctx);
    let f = &mut fixture_f;
    let mut fixture_g = fixture(ctx);
    let g = &mut fixture_g; let mut r=create(f,1,ctx); action::register(&mut f.composition,&f.cap,&g.recording,&mut r,&mut f.source); destroy(fixture_g); destroy(r);
    destroy(fixture_f);
}

#[test, expected_failure(abort_code = action::EPoolNotForRecording)]
fun register_foreign_pool_rejected() {
    let ctx = &mut tx_context::dummy();
    let mut fixture_f = fixture(ctx);
    let f = &mut fixture_f;
    let mut fixture_g = fixture(ctx);
    let g = &mut fixture_g; let mut r=create(f,1,ctx); action::register(&mut f.composition,&f.cap,&f.recording,&mut r,&mut g.source); destroy(fixture_g); destroy(r);
    destroy(fixture_f);
}

#[test, expected_failure(abort_code = action::EStakeNotForComposition)]
fun register_foreign_wrapper_rejected() {
    let ctx = &mut tx_context::dummy();
    let mut fixture_f = fixture(ctx);
    let f = &mut fixture_f;
    let mut fixture_g = fixture(ctx);
    let g = &mut fixture_g; let mut r=create(g,1,ctx); action::register(&mut f.composition,&f.cap,&f.recording,&mut r,&mut f.source); destroy(fixture_g); destroy(r);
    destroy(fixture_f);
}

#[test, expected_failure(abort_code = routed_stake::ENoStake)]
fun register_empty_wrapper_rejected() {
    let ctx = &mut tx_context::dummy();
    let mut fixture_f = fixture(ctx);
    let f = &mut fixture_f;
    let mut r=create(f,1,ctx); destroy(action::unstake(&mut f.composition,&f.cap,&mut r)); register(f,&mut r); destroy(r);
    destroy(fixture_f);
}

#[test, expected_failure(abort_code = composition::EUnauthorized)]
fun unregister_foreign_cap_rejected() {
    let ctx = &mut tx_context::dummy();
    let mut fixture_f = fixture(ctx);
    let f = &mut fixture_f;
    let mut fixture_g = fixture(ctx);
    let g = &mut fixture_g; let mut r=create(f,1,ctx); action::unregister(&mut f.composition,&g.cap,&f.recording,&mut r,&mut f.source); destroy(fixture_g); destroy(r);
    destroy(fixture_f);
}

#[test, expected_failure(abort_code = action::ERecordingNotForComposition)]
fun unregister_foreign_recording_rejected() {
    let ctx = &mut tx_context::dummy();
    let mut fixture_f = fixture(ctx);
    let f = &mut fixture_f;
    let mut fixture_g = fixture(ctx);
    let g = &mut fixture_g; let mut r=create(f,1,ctx); action::unregister(&mut f.composition,&f.cap,&g.recording,&mut r,&mut f.source); destroy(fixture_g); destroy(r);
    destroy(fixture_f);
}

#[test, expected_failure(abort_code = action::EPoolNotForRecording)]
fun unregister_foreign_pool_rejected() {
    let ctx = &mut tx_context::dummy();
    let mut fixture_f = fixture(ctx);
    let f = &mut fixture_f;
    let mut fixture_g = fixture(ctx);
    let g = &mut fixture_g; let mut r=create(f,1,ctx); action::unregister(&mut f.composition,&f.cap,&f.recording,&mut r,&mut g.source); destroy(fixture_g); destroy(r);
    destroy(fixture_f);
}

#[test, expected_failure(abort_code = action::EStakeNotForComposition)]
fun unregister_foreign_wrapper_rejected() {
    let ctx = &mut tx_context::dummy();
    let mut fixture_f = fixture(ctx);
    let f = &mut fixture_f;
    let mut fixture_g = fixture(ctx);
    let g = &mut fixture_g; let mut r=create(g,1,ctx); action::unregister(&mut f.composition,&f.cap,&f.recording,&mut r,&mut f.source); destroy(fixture_g); destroy(r);
    destroy(fixture_f);
}

#[test, expected_failure(abort_code = routed_stake::ENoStake)]
fun unregister_empty_wrapper_rejected() {
    let ctx = &mut tx_context::dummy();
    let mut fixture_f = fixture(ctx);
    let f = &mut fixture_f;
    let mut r=create(f,1,ctx); destroy(action::unstake(&mut f.composition,&f.cap,&mut r)); unregister(f,&mut r); destroy(r);
    destroy(fixture_f);
}

#[test, expected_failure(abort_code = composition::EUnauthorized)]
fun unstake_foreign_cap_rejected() {
    let ctx = &mut tx_context::dummy();
    let mut fixture_f = fixture(ctx);
    let f = &mut fixture_f;
    let mut fixture_g = fixture(ctx);
    let g = &mut fixture_g; let mut r=create(f,1,ctx); let _p =action::unstake(&mut f.composition,&g.cap,&mut r); destroy(_p); destroy(fixture_g); destroy(r);
    destroy(fixture_f);
}

#[test, expected_failure(abort_code = composition::EUnauthorized)]
fun restake_foreign_cap_rejected() {
    let ctx = &mut tx_context::dummy();
    let mut fixture_f = fixture(ctx);
    let f = &mut fixture_f;
    let mut fixture_g = fixture(ctx);
    let g = &mut fixture_g; let mut r=create(f,1,ctx); let shares=action::unstake(&mut f.composition,&f.cap,&mut r); action::restake(&mut f.composition,&g.cap,&mut r,shares,ctx); destroy(fixture_g); destroy(r);
    destroy(fixture_f);
}

#[test, expected_failure(abort_code = routed_stake::ENoStake)]
fun unstake_empty_wrapper_rejected() {
    let ctx = &mut tx_context::dummy();
    let mut fixture_f = fixture(ctx);
    let f = &mut fixture_f;
    let mut r=create(f,1,ctx); destroy(action::unstake(&mut f.composition,&f.cap,&mut r)); destroy(action::unstake(&mut f.composition,&f.cap,&mut r)); destroy(r);
    destroy(fixture_f);
}

#[test]
fun borrowed_vault_cap_authorizes_native_actions() {
    let ctx = &mut tx_context::dummy();
    let mut fixture_f = fixture(ctx);
    let f = &mut fixture_f;
    let mut routed = create(f,100,ctx);
    let Fixture { mut composition, cap, recording, recording_cap,
        composition_issuance, recording_issuance, composition_shares,
        recording_shares, mut source, destination } = fixture_f;
    let mut registry = vault::new_registry_for_testing(ctx);
    let (mut vault, vault_cap) = vault::new(&mut registry,cap,ctx);
    let (borrowed,receipt) = vault.borrow_as_admin(&vault_cap);
    action::register(&mut composition,&borrowed,&recording,&mut routed,&mut source);
    vault.put_back(borrowed,receipt);
    let (borrowed,receipt) = vault.borrow_as_admin(&vault_cap);
    action::unregister(&mut composition,&borrowed,&recording,&mut routed,&mut source);
    vault.put_back(borrowed,receipt);
    let cap = vault.withdraw_vaulted_cap(&vault_cap);
    destroy(action::unstake(&mut composition,&cap,&mut routed));
    destroy(composition);destroy(cap);destroy(recording);destroy(recording_cap);
    destroy(composition_issuance);destroy(recording_issuance);
    destroy(composition_shares);destroy(recording_shares);destroy(source);destroy(destination);
    destroy(routed);destroy(vault);destroy(vault_cap);destroy(registry);
}

#[test]
fun stranger_sweeps_shared_pools_and_holder_claims() {
    let mut scenario = test_scenario::begin(@0xA);
    let mut fixture_f = fixture(scenario.ctx());
    let f = &mut fixture_f;
    let mut routed = create(f,200,scenario.ctx());
    register(f,&mut routed);
    let mut holder = stake::new(f.composition_shares.split(100),scenario.ctx());
    f.destination.register_stake(&mut holder);
    f.source.deposit(balance::create_for_testing<USD>(1000));
    let cid = object::id(&f.composition);
    let source_id = object::id(&f.source);
    let destination_id = object::id(&f.destination);
    let Fixture { composition, cap, recording, recording_cap,
        composition_issuance, recording_issuance, composition_shares,
        recording_shares, source, destination } = fixture_f;
    composition.publish(&cap);
    recording.publish(&recording_cap);
    transfer::public_transfer(cap,@0xA);
    transfer::public_transfer(recording_cap,@0xA);
    transfer::public_transfer(holder,@0xB);
    source.share(); destination.share(); routed.share();
    destroy(composition_issuance);destroy(recording_issuance);
    destroy(composition_shares);destroy(recording_shares);

    scenario.next_tx(@0xC);
    let mut source = test_scenario::take_shared_by_id<RoyaltyPool<USD>>(&scenario,source_id);
    let mut destination = test_scenario::take_shared_by_id<RoyaltyPool<USD>>(&scenario,destination_id);
    let mut routed = scenario.take_shared<RoutedStake>();
    assert_eq!(routed.sweep(&mut source,&mut destination,cid),1000);
    test_scenario::return_shared(source);
    test_scenario::return_shared(destination);
    test_scenario::return_shared(routed);

    scenario.next_tx(@0xB);
    let mut holder = scenario.take_from_sender<stake::Stake>();
    let mut destination = test_scenario::take_shared_by_id<RoyaltyPool<USD>>(&scenario,destination_id);
    let reward = destination.claim_rewards(&mut holder);
    assert_eq!(reward.value(),1000);
    destroy(reward);
    scenario.return_to_sender(holder);
    test_scenario::return_shared(destination);
    scenario.end();
}
