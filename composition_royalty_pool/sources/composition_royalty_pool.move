// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Raw-cap, custody-agnostic royalty-pool actions for musicos Compositions.
///
/// Every mutating action requires the Composition's own admin capability.
/// The canonical pool remains derived from the Composition, and callers
/// decide when to register stakes and share a newly returned pool.
module composition_royalty_pool::composition_royalty_pool;

use hikida::hikida;
use musicos::composition::{Composition, CompositionAdminCap};
use royalty_pool::pool::{Self, RoyaltyPool};
use sui::coin::Coin;
use sui::transfer::Receiving;

/// Create and return the canonical unshared pool derived from `composition`.
public fun new_pool<CompositionShare, Currency>(
    composition: &mut Composition<CompositionShare>,
    admin_cap: &CompositionAdminCap<CompositionShare>,
): RoyaltyPool<CompositionShare, Currency> {
    pool::new(composition.uid_mut(admin_cap))
}

/// Receive selected coins sent to the Composition and deposit their balance
/// into the canonical pool derived from that same Composition.
public fun receive_and_deposit<CompositionShare, Currency>(
    composition: &mut Composition<CompositionShare>,
    admin_cap: &CompositionAdminCap<CompositionShare>,
    pool: &mut RoyaltyPool<CompositionShare, Currency>,
    coins: vector<Receiving<Coin<Currency>>>,
) {
    pool.assert_derived_from(object::id(composition));
    let received = hikida::receive_balance(composition.uid_mut(admin_cap), coins);
    pool.deposit(received)
}

/// Redeem `value` from the Composition's funds accumulator and deposit it
/// into the canonical pool derived from that same Composition.
public fun redeem_and_deposit<CompositionShare, Currency>(
    composition: &mut Composition<CompositionShare>,
    admin_cap: &CompositionAdminCap<CompositionShare>,
    pool: &mut RoyaltyPool<CompositionShare, Currency>,
    value: u64,
) {
    pool.assert_derived_from(object::id(composition));
    let redeemed = hikida::redeem_balance<Currency>(composition.uid_mut(admin_cap), value);
    pool.deposit(redeemed)
}

/// Canonical pool address for this Composition, share type, and Currency.
public fun pool_address<CompositionShare, Currency>(
    composition: &Composition<CompositionShare>,
): address {
    pool::derived_address<CompositionShare, Currency>(object::id(composition))
}
