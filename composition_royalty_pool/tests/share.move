// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Test-only native Share fixtures for composition royalty actions.
#[test_only]
module composition_royalty_pool::share;

use musicos::composition::{Composition, CompositionAdminCap};
use royalty_pool::pool::RoyaltyPool;
use share::share::{Self, Issuance, Share};
use std::unit_test::destroy;

public fun bootstrap(
    composition: &mut Composition,
    cap: &CompositionAdminCap,
    ctx: &mut TxContext,
): (Issuance, Share) {
    let mut registry = share::registry_for_testing(ctx);
    let (issuance, shares) = share::initialize_for_testing(&mut registry, composition.uid_mut(cap));
    destroy(registry);
    (issuance, shares)
}

public fun for_pool<Currency>(pool: &RoyaltyPool<Currency>, value: u64): Share {
    share::create_for_testing_from_id(pool.issuance_id(), value)
}
