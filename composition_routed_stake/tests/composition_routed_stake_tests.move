// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module composition_routed_stake::composition_routed_stake_tests;

use composition_routed_stake::composition_routed_stake as action;
use musicos::composition::{Self, Composition, CompositionAdminCap};
use musicos::recording::{Self, Recording, RecordingAdminCap};
use royalty_pool::pool::{Self, RoyaltyPool};
use royalty_pool::stake::{Self, Stake};
use routed_stake::routed_stake::{Self, RoutedStake};
use std::unit_test::{assert_eq, destroy};
use sui::balance::{Self, Balance};
use sui::derived_object;
use sui::event;
use vault::vault;

const EPoolNotForRecording: u64 = 0;
const EStakeNotForComposition: u64 = 1;
const ERecordingNotForComposition: u64 = 2;
const ENoValueToRedeem: u64 = 3;
const EStakeExists: u64 = 2;
const EPoolsRegistered: u64 = 1;
const EZeroBalance: u64 = 0;

public struct RECORDING_SHARE() has drop;
public struct FOREIGN_RECORDING_SHARE() has drop;
public struct COMPOSITION_SHARE() has drop;
public struct CURRENCY() has drop;

fun fixture(
    ctx: &mut TxContext,
): (
    Composition<COMPOSITION_SHARE>,
    CompositionAdminCap<COMPOSITION_SHARE>,
    Recording<RECORDING_SHARE, COMPOSITION_SHARE>,
    RecordingAdminCap<RECORDING_SHARE>,
) {
    let (composition, composition_cap) =
        composition::new_for_testing<COMPOSITION_SHARE>("Composition", 2_000, ctx);
    let (recording, recording_cap) =
        recording::new_for_testing<RECORDING_SHARE, COMPOSITION_SHARE>(
            object::id(&composition),
            ctx,
        );
    (composition, composition_cap, recording, recording_cap)
}

#[test]
fun complete_return_oriented_lifecycle_routes_rewards_and_releases_principal() {
    let ctx = &mut tx_context::dummy();
    let (mut composition, composition_cap, mut recording, recording_cap) = fixture(ctx);
    let composition_id = object::id(&composition);
    let mut recording_pool =
        pool::new<RECORDING_SHARE, CURRENCY>(recording.uid_mut(&recording_cap));
    let mut composition_pool =
        pool::new<COMPOSITION_SHARE, CURRENCY>(composition.uid_mut(&composition_cap));
    let mut composition_holder = stake::new(
        balance::create_for_testing<COMPOSITION_SHARE>(1_000),
        ctx,
    );
    composition_pool.register_stake(&mut composition_holder);

    // Unit-test framework delivery exercises the action shape. A network E2E
    // is still required to prove positive consensus-settled accumulator timing.
    balance::create_for_testing<RECORDING_SHARE>(200).send_funds(composition_id.to_address());
    let mut routed = action::create_stake(
        &mut composition,
        &composition_cap,
        &recording,
        200,
        ctx,
    );
    assert_eq!(
        object::id(&routed).to_address(),
        action::stake_address<RECORDING_SHARE, COMPOSITION_SHARE>(&composition),
    );
    assert_eq!(routed.value(), 200);

    // Returned-value composability: register before the caller chooses to share.
    action::register(
        &mut composition,
        &composition_cap,
        &recording,
        &mut routed,
        &mut recording_pool,
    );
    recording_pool.deposit(balance::create_for_testing<CURRENCY>(1_000));
    routed.sweep(&mut recording_pool, &mut composition_pool, composition_id);
    let reward = composition_pool.claim_rewards(&mut composition_holder);
    assert_eq!(reward.value(), 1_000);

    let swept = event::events_by_type<
        routed_stake::RoutedStakeSweptEvent<RECORDING_SHARE, COMPOSITION_SHARE, CURRENCY>,
    >();
    assert_eq!(swept.length(), 1);
    let (event_stake_id, event_parent_id, swept_value) =
        routed_stake::swept_event_fields(&swept[0]);
    assert_eq!(event_stake_id, object::id(&routed));
    assert_eq!(event_parent_id, composition_id);
    assert_eq!(swept_value, 1_000);

    action::unregister(
        &mut composition,
        &composition_cap,
        &recording,
        &mut routed,
        &mut recording_pool,
    );
    let principal = action::unstake(&mut composition, &composition_cap, &mut routed);
    assert_eq!(principal.value(), 200);
    assert!(!routed.has_stake());
    let unstaked = event::events_by_type<
        routed_stake::RoutedStakeUnstakedEvent<RECORDING_SHARE, COMPOSITION_SHARE>,
    >();
    let (unstaked_id, unstaked_parent, unstaked_value) =
        routed_stake::unstaked_event_fields(&unstaked[0]);
    assert_eq!(unstaked_id, object::id(&routed));
    assert_eq!(unstaked_parent, composition_id);
    assert_eq!(unstaked_value, 200);

    action::restake(
        &mut composition,
        &composition_cap,
        &mut routed,
        principal,
        ctx,
    );
    assert_eq!(routed.value(), 200);
    let restaked = event::events_by_type<
        routed_stake::RoutedStakeRestakedEvent<RECORDING_SHARE, COMPOSITION_SHARE>,
    >();
    assert_eq!(restaked.length(), 1);
    action::register(
        &mut composition,
        &composition_cap,
        &recording,
        &mut routed,
        &mut recording_pool,
    );
    action::unregister(
        &mut composition,
        &composition_cap,
        &recording,
        &mut routed,
        &mut recording_pool,
    );
    let principal = action::unstake(&mut composition, &composition_cap, &mut routed);

    composition_pool.unregister_stake(&mut composition_holder);
    balance::destroy_for_testing(principal);
    balance::destroy_for_testing(reward);
    balance::destroy_for_testing(stake::destroy(composition_holder));
    destroy(routed);
    destroy(recording_pool);
    destroy(composition_pool);
    destroy(recording);
    destroy(recording_cap);
    destroy(composition);
    destroy(composition_cap);
}

#[test]
fun vault_admin_borrow_action_put_back_and_borrow_again() {
    let ctx = &mut tx_context::dummy();
    let (mut composition, composition_cap, mut recording, recording_cap) = fixture(ctx);
    let mut routed = routed_stake::new<RECORDING_SHARE, COMPOSITION_SHARE>(
        composition.uid_mut(&composition_cap),
        balance::create_for_testing<RECORDING_SHARE>(100),
        ctx,
    );
    let mut pool = pool::new<RECORDING_SHARE, CURRENCY>(recording.uid_mut(&recording_cap));
    let mut registry = vault::new_registry_for_testing(ctx);
    let (mut vault, vault_admin_cap) = vault::new(&mut registry, composition_cap, ctx);

    let (borrowed_cap, receipt) = vault.borrow_as_admin(&vault_admin_cap);
    let borrowed_cap_id = object::id(&borrowed_cap).to_address();
    action::register(
        &mut composition,
        &borrowed_cap,
        &recording,
        &mut routed,
        &mut pool,
    );
    let registered = event::events_by_type<action::CompositionRoutedStakeRegisteredEvent<RECORDING_SHARE, COMPOSITION_SHARE, CURRENCY>>();
    let (_, registered_cap_id, _, _, _, _, _, _, _, _, _, _, _, _, _, _) = action::registered_event_fields(&registered[0]);
    assert_eq!(registered_cap_id, borrowed_cap_id);
    vault.put_back(borrowed_cap, receipt);
    let (borrowed_again, second_receipt) = vault.borrow_as_admin(&vault_admin_cap);
    let borrowed_again_id = object::id(&borrowed_again).to_address();
    action::unregister(
        &mut composition,
        &borrowed_again,
        &recording,
        &mut routed,
        &mut pool,
    );
    let unregistered = event::events_by_type<action::CompositionRoutedStakeUnregisteredEvent<RECORDING_SHARE, COMPOSITION_SHARE, CURRENCY>>();
    let (_, unregistered_cap_id, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _) = action::unregistered_event_fields(&unregistered[0]);
    assert_eq!(unregistered_cap_id, borrowed_again_id);
    vault.put_back(borrowed_again, second_receipt);

    let composition_cap = vault.withdraw_cap(&vault_admin_cap);
    let composition_cap_id = object::id(&composition_cap).to_address();
    let principal = action::unstake(&mut composition, &composition_cap, &mut routed);
    let unstaked = event::events_by_type<action::CompositionRoutedStakeUnstakedEvent<RECORDING_SHARE, COMPOSITION_SHARE>>();
    let (_, unstaked_cap_id, _, _, _) = action::unstaked_event_fields(&unstaked[0]);
    assert_eq!(unstaked_cap_id, composition_cap_id);
    balance::destroy_for_testing(principal);
    destroy(routed);
    destroy(pool);
    destroy(composition_cap);
    destroy(vault_admin_cap);
    destroy(vault);
    destroy(registry);
    destroy(recording);
    destroy(recording_cap);
    destroy(composition);
}

#[test, expected_failure(abort_code = derived_object::EObjectAlreadyExists, location = sui::derived_object)]
fun duplicate_routed_stake_derivation_claim_aborts() {
    let ctx = &mut tx_context::dummy();
    let (mut composition, admin_cap, recording, _recording_cap) = fixture(ctx);
    let composition_id = object::id(&composition);
    balance::create_for_testing<RECORDING_SHARE>(2).send_funds(composition_id.to_address());
    let _first = action::create_stake(&mut composition, &admin_cap, &recording, 1, ctx);
    let _second = action::create_stake(&mut composition, &admin_cap, &recording, 1, ctx);
    abort
}

#[test, expected_failure(abort_code = ERecordingNotForComposition, location = action)]
fun create_rejects_recording_from_wrong_composition() {
    let ctx = &mut tx_context::dummy();
    let (mut composition, admin_cap) =
        composition::new_for_testing<COMPOSITION_SHARE>("Composition", 2_000, ctx);
    let (foreign_recording, _foreign_cap) =
        recording::new_for_testing<RECORDING_SHARE, COMPOSITION_SHARE>(
            object::id_from_address(@0xBAD),
            ctx,
        );
    let _routed = action::create_stake(&mut composition, &admin_cap, &foreign_recording, 1, ctx);
    abort
}

#[test, expected_failure(abort_code = ERecordingNotForComposition, location = action)]
fun register_rejects_recording_from_wrong_composition() {
    let ctx = &mut tx_context::dummy();
    let (mut composition, admin_cap, mut recording, recording_cap) = fixture(ctx);
    let (foreign_recording, _foreign_cap) =
        recording::new_for_testing<RECORDING_SHARE, COMPOSITION_SHARE>(
            object::id_from_address(@0xBAD),
            ctx,
        );
    let mut routed = routed_stake::new<RECORDING_SHARE, COMPOSITION_SHARE>(
        composition.uid_mut(&admin_cap),
        balance::create_for_testing<RECORDING_SHARE>(100),
        ctx,
    );
    let mut pool = pool::new<RECORDING_SHARE, CURRENCY>(recording.uid_mut(&recording_cap));
    action::register(
        &mut composition,
        &admin_cap,
        &foreign_recording,
        &mut routed,
        &mut pool,
    );
    abort
}

#[test, expected_failure(abort_code = EStakeNotForComposition, location = action)]
fun register_rejects_routed_stake_from_wrong_composition() {
    let ctx = &mut tx_context::dummy();
    let (mut composition, admin_cap, mut recording, recording_cap) = fixture(ctx);
    let (mut foreign, foreign_cap) =
        composition::new_for_testing<COMPOSITION_SHARE>("Foreign", 2_000, ctx);
    let mut foreign_routed = routed_stake::new<RECORDING_SHARE, COMPOSITION_SHARE>(
        foreign.uid_mut(&foreign_cap),
        balance::create_for_testing<RECORDING_SHARE>(100),
        ctx,
    );
    let mut pool = pool::new<RECORDING_SHARE, CURRENCY>(recording.uid_mut(&recording_cap));
    action::register(
        &mut composition,
        &admin_cap,
        &recording,
        &mut foreign_routed,
        &mut pool,
    );
    abort
}

#[test, expected_failure(abort_code = EPoolNotForRecording, location = action)]
fun register_rejects_pool_from_wrong_recording() {
    let ctx = &mut tx_context::dummy();
    let (mut composition, admin_cap, recording, _recording_cap) = fixture(ctx);
    let mut routed = routed_stake::new<RECORDING_SHARE, COMPOSITION_SHARE>(
        composition.uid_mut(&admin_cap),
        balance::create_for_testing<RECORDING_SHARE>(100),
        ctx,
    );
    let (mut foreign_recording, foreign_cap) =
        recording::new_for_testing<FOREIGN_RECORDING_SHARE, COMPOSITION_SHARE>(
            object::id(&composition),
            ctx,
        );
    let mut wrong_pool =
        pool::new<RECORDING_SHARE, CURRENCY>(foreign_recording.uid_mut(&foreign_cap));
    action::register(
        &mut composition,
        &admin_cap,
        &recording,
        &mut routed,
        &mut wrong_pool,
    );
    abort
}

#[test, expected_failure(abort_code = EPoolNotForRecording, location = action)]
fun unregister_rejects_pool_from_wrong_recording() {
    let ctx = &mut tx_context::dummy();
    let (mut composition, admin_cap, recording, _recording_cap) = fixture(ctx);
    let mut routed = routed_stake::new<RECORDING_SHARE, COMPOSITION_SHARE>(
        composition.uid_mut(&admin_cap),
        balance::create_for_testing<RECORDING_SHARE>(100),
        ctx,
    );
    let (mut foreign_recording, foreign_cap) =
        recording::new_for_testing<FOREIGN_RECORDING_SHARE, COMPOSITION_SHARE>(
            object::id(&composition),
            ctx,
        );
    let mut wrong_pool =
        pool::new<RECORDING_SHARE, CURRENCY>(foreign_recording.uid_mut(&foreign_cap));
    action::unregister(
        &mut composition,
        &admin_cap,
        &recording,
        &mut routed,
        &mut wrong_pool,
    );
    abort
}

#[test, expected_failure(abort_code = ENoValueToRedeem, location = action)]
fun create_with_zero_redemption_aborts() {
    let ctx = &mut tx_context::dummy();
    let (mut composition, admin_cap, recording, _recording_cap) = fixture(ctx);
    let _routed = action::create_stake(&mut composition, &admin_cap, &recording, 0, ctx);
    abort
}

#[test]
fun create_overdraw_uses_existing_accumulator_behavior() {
    let ctx = &mut tx_context::dummy();
    let (mut composition, admin_cap, recording, recording_cap) = fixture(ctx);
    let routed = action::create_stake(&mut composition, &admin_cap, &recording, 1, ctx);
    destroy(routed);
    destroy(recording); destroy(recording_cap); destroy(composition); destroy(admin_cap);
}

#[test, expected_failure(abort_code = ENoValueToRedeem, location = action)]
fun zero_redemption_precedes_duplicate_derivation_claim() {
    let ctx = &mut tx_context::dummy();
    let (mut composition, admin_cap, recording, _recording_cap) = fixture(ctx);
    let composition_id = object::id(&composition);
    balance::create_for_testing<RECORDING_SHARE>(1).send_funds(composition_id.to_address());
    let _first = action::create_stake(&mut composition, &admin_cap, &recording, 1, ctx);
    let _second = action::create_stake(&mut composition, &admin_cap, &recording, 0, ctx);
    abort
}

#[test, expected_failure(abort_code = EStakeExists, location = routed_stake)]
fun restake_rejects_filled_wrapper() {
    let ctx = &mut tx_context::dummy();
    let (mut composition, admin_cap, _recording, _recording_cap) = fixture(ctx);
    let mut routed = routed_stake::new<RECORDING_SHARE, COMPOSITION_SHARE>(
        composition.uid_mut(&admin_cap),
        balance::create_for_testing<RECORDING_SHARE>(100),
        ctx,
    );
    action::restake(
        &mut composition,
        &admin_cap,
        &mut routed,
        balance::create_for_testing<RECORDING_SHARE>(1),
        ctx,
    );
    abort
}

#[test, expected_failure(abort_code = EZeroBalance, location = stake)]
fun restake_rejects_zero_balance() {
    let ctx = &mut tx_context::dummy();
    let (mut composition, admin_cap, _recording, _recording_cap) = fixture(ctx);
    let mut routed = routed_stake::new<RECORDING_SHARE, COMPOSITION_SHARE>(
        composition.uid_mut(&admin_cap),
        balance::create_for_testing<RECORDING_SHARE>(100),
        ctx,
    );
    balance::destroy_for_testing(action::unstake(&mut composition, &admin_cap, &mut routed));
    action::restake(
        &mut composition,
        &admin_cap,
        &mut routed,
        balance::zero<RECORDING_SHARE>(),
        ctx,
    );
    abort
}

#[test, expected_failure(abort_code = EPoolsRegistered, location = stake)]
fun unstake_rejects_registered_position() {
    let ctx = &mut tx_context::dummy();
    let (mut composition, admin_cap, mut recording, recording_cap) = fixture(ctx);
    let mut routed = routed_stake::new<RECORDING_SHARE, COMPOSITION_SHARE>(
        composition.uid_mut(&admin_cap),
        balance::create_for_testing<RECORDING_SHARE>(100),
        ctx,
    );
    let mut pool = pool::new<RECORDING_SHARE, CURRENCY>(recording.uid_mut(&recording_cap));
    action::register(&mut composition, &admin_cap, &recording, &mut routed, &mut pool);
    let _principal: Balance<RECORDING_SHARE> = action::unstake(&mut composition, &admin_cap, &mut routed);
    abort
}

#[test, expected_failure(abort_code = 1, location = routed_stake)]
fun register_empty_wrapper_reaches_dependency_no_stake_guard() {
    let ctx = &mut tx_context::dummy();
    let (mut composition, cap, mut recording, recording_cap) = fixture(ctx);
    balance::create_for_testing<RECORDING_SHARE>(1).send_funds(object::id(&composition).to_address());
    let mut routed = action::create_stake(&mut composition, &cap, &recording, 1, ctx);
    balance::destroy_for_testing(action::unstake(&mut composition, &cap, &mut routed));
    let mut pool = pool::new<RECORDING_SHARE, CURRENCY>(recording.uid_mut(&recording_cap));
    action::register(&mut composition, &cap, &recording, &mut routed, &mut pool);
    abort
}

#[test, expected_failure(abort_code = 1, location = routed_stake)]
fun unregister_empty_wrapper_reaches_dependency_no_stake_guard() {
    let ctx = &mut tx_context::dummy();
    let (mut composition, cap, mut recording, recording_cap) = fixture(ctx);
    balance::create_for_testing<RECORDING_SHARE>(1).send_funds(object::id(&composition).to_address());
    let mut routed = action::create_stake(&mut composition, &cap, &recording, 1, ctx);
    balance::destroy_for_testing(action::unstake(&mut composition, &cap, &mut routed));
    let mut pool = pool::new<RECORDING_SHARE, CURRENCY>(recording.uid_mut(&recording_cap));
    action::unregister(&mut composition, &cap, &recording, &mut routed, &mut pool);
    abort
}

#[test, expected_failure(abort_code = 2, location = royalty_pool::pool)]
fun duplicate_currency_registration_reaches_pool_guard() {
    let ctx = &mut tx_context::dummy();
    let (mut composition, cap, mut recording, recording_cap) = fixture(ctx);
    balance::create_for_testing<RECORDING_SHARE>(1).send_funds(object::id(&composition).to_address());
    let mut routed = action::create_stake(&mut composition, &cap, &recording, 1, ctx);
    let mut pool = pool::new<RECORDING_SHARE, CURRENCY>(recording.uid_mut(&recording_cap));
    action::register(&mut composition, &cap, &recording, &mut routed, &mut pool);
    action::register(&mut composition, &cap, &recording, &mut routed, &mut pool);
    abort
}

#[test, expected_failure(abort_code = 4, location = royalty_pool::pool)]
fun unregister_against_other_registered_pool_reaches_pool_id_guard() {
    let ctx = &mut tx_context::dummy();
    let (mut composition, cap, mut recording, recording_cap) = fixture(ctx);
    let (mut other_recording, other_recording_cap) =
        recording::new_for_testing<RECORDING_SHARE, COMPOSITION_SHARE>(object::id(&composition), ctx);
    balance::create_for_testing<RECORDING_SHARE>(1).send_funds(object::id(&composition).to_address());
    let mut routed = action::create_stake(&mut composition, &cap, &recording, 1, ctx);
    let mut pool = pool::new<RECORDING_SHARE, CURRENCY>(recording.uid_mut(&recording_cap));
    let mut other_pool = pool::new<RECORDING_SHARE, CURRENCY>(other_recording.uid_mut(&other_recording_cap));
    action::register(&mut composition, &cap, &recording, &mut routed, &mut pool);
    routed.unregister(composition.uid_mut(&cap), &mut other_pool);
    abort
}

#[test, expected_failure(abort_code = 5, location = royalty_pool::pool)]
fun unregister_positive_whole_reward_reaches_last_claim_guard() {
    let ctx = &mut tx_context::dummy();
    let (mut composition, cap, mut recording, recording_cap) = fixture(ctx);
    balance::create_for_testing<RECORDING_SHARE>(1).send_funds(object::id(&composition).to_address());
    let mut routed = action::create_stake(&mut composition, &cap, &recording, 1, ctx);
    let mut pool = pool::new<RECORDING_SHARE, CURRENCY>(recording.uid_mut(&recording_cap));
    action::register(&mut composition, &cap, &recording, &mut routed, &mut pool);
    pool.deposit(balance::create_for_testing<CURRENCY>(1));
    action::unregister(&mut composition, &cap, &recording, &mut routed, &mut pool);
    abort
}

#[test, expected_failure(abort_code = ERecordingNotForComposition, location = action)]
fun composite_recording_wrapper_pool_guards_preserve_recording_first() {
    let ctx = &mut tx_context::dummy();
    let (mut composition, cap, _recording, _recording_cap) = fixture(ctx);
    let (mut foreign_composition, foreign_cap) =
        composition::new_for_testing<COMPOSITION_SHARE>("Foreign", 2_000, ctx);
    let (mut foreign_recording, foreign_recording_cap) =
        recording::new_for_testing<RECORDING_SHARE, COMPOSITION_SHARE>(object::id_from_address(@0xBAD), ctx);
    let mut foreign_routed = routed_stake::new<RECORDING_SHARE, COMPOSITION_SHARE>(
        foreign_composition.uid_mut(&foreign_cap),
        balance::create_for_testing<RECORDING_SHARE>(1),
        ctx,
    );
    let mut wrong_pool = pool::new<RECORDING_SHARE, CURRENCY>(foreign_recording.uid_mut(&foreign_recording_cap));
    action::register(&mut composition, &cap, &foreign_recording, &mut foreign_routed, &mut wrong_pool);
    abort
}

#[test, expected_failure(abort_code = EStakeNotForComposition, location = action)]
fun wrong_parent_precedes_empty_wrapper_unstake() {
    let ctx = &mut tx_context::dummy();
    let (mut composition, cap, _recording, _recording_cap) = fixture(ctx);
    let (mut foreign_composition, foreign_cap) = composition::new_for_testing<COMPOSITION_SHARE>("Foreign", 2_000, ctx);
    let mut foreign_routed = routed_stake::new<RECORDING_SHARE, COMPOSITION_SHARE>(foreign_composition.uid_mut(&foreign_cap), balance::create_for_testing<RECORDING_SHARE>(1), ctx);
    balance::destroy_for_testing(routed_stake::unstake(&mut foreign_routed, foreign_composition.uid_mut(&foreign_cap)));
    let principal = action::unstake(&mut composition, &cap, &mut foreign_routed);
    balance::destroy_for_testing(principal);
    abort
}

#[test, expected_failure(abort_code = EStakeNotForComposition, location = action)]
fun wrong_parent_precedes_filled_wrapper_unstake() {
    let ctx = &mut tx_context::dummy();
    let (mut composition, cap, _recording, _recording_cap) = fixture(ctx);
    let (mut foreign_composition, foreign_cap) = composition::new_for_testing<COMPOSITION_SHARE>("Foreign", 2_000, ctx);
    let mut foreign_routed = routed_stake::new<RECORDING_SHARE, COMPOSITION_SHARE>(foreign_composition.uid_mut(&foreign_cap), balance::create_for_testing<RECORDING_SHARE>(1), ctx);
    let principal = action::unstake(&mut composition, &cap, &mut foreign_routed);
    balance::destroy_for_testing(principal);
    abort
}

#[test, expected_failure(abort_code = EStakeNotForComposition, location = action)]
fun wrong_parent_precedes_zero_balance_restake() {
    let ctx = &mut tx_context::dummy();
    let (mut composition, cap, _recording, _recording_cap) = fixture(ctx);
    let (mut foreign_composition, foreign_cap) = composition::new_for_testing<COMPOSITION_SHARE>("Foreign", 2_000, ctx);
    let mut foreign_routed = routed_stake::new<RECORDING_SHARE, COMPOSITION_SHARE>(foreign_composition.uid_mut(&foreign_cap), balance::create_for_testing<RECORDING_SHARE>(1), ctx);
    action::restake(&mut composition, &cap, &mut foreign_routed, balance::zero<RECORDING_SHARE>(), ctx);
    abort
}

#[test, expected_failure(abort_code = EStakeExists, location = routed_stake)]
fun filled_restake_precedes_zero_balance_guard() {
    let ctx = &mut tx_context::dummy();
    let (mut composition, cap, _recording, _recording_cap) = fixture(ctx);
    let mut routed = routed_stake::new<RECORDING_SHARE, COMPOSITION_SHARE>(composition.uid_mut(&cap), balance::create_for_testing<RECORDING_SHARE>(1), ctx);
    action::restake(&mut composition, &cap, &mut routed, balance::zero<RECORDING_SHARE>(), ctx);
    abort
}
