/*
 * Copyright (c) 2025 Bima Kharisma Wicaksana
 * GitHub: https://github.com/bimakw
 *
 * Licensed under MIT License with Attribution Requirement.
 * See LICENSE file for details.
 */

/// Lending Module - Simple collateralized lending protocol.
/// Demonstrates lending/borrowing mechanics with liquidation.
module sui_defi_vault::lending {
    use sui::object::{Self, UID, ID};
    use sui::tx_context::{Self, TxContext};
    use sui::transfer;
    use sui::coin::{Self, Coin};
    use sui::sui::SUI;
    use sui::balance::{Self, Balance};
    use sui::clock::{Self, Clock};
    use sui::event;

    /// Error codes
    const EInsufficientCollateral: u64 = 0;
    const EExceedsMaxBorrow: u64 = 1;
    const ENoActiveLoan: u64 = 2;
    const ENotLiquidatable: u64 = 3;
    const EInvalidAmount: u64 = 4;
    const EPoolEmpty: u64 = 5;

    /// Collateral factor (75% = can borrow up to 75% of collateral value)
    const COLLATERAL_FACTOR_BPS: u64 = 7500;
    /// Liquidation threshold (85% = liquidatable if debt > 85% of collateral)
    const LIQUIDATION_THRESHOLD_BPS: u64 = 8500;
    /// Liquidation bonus (5% discount for liquidators)
    const LIQUIDATION_BONUS_BPS: u64 = 500;
    /// Interest rate per year (10% APY)
    const INTEREST_RATE_BPS: u64 = 1000;
    /// Seconds per year
    const SECONDS_PER_YEAR: u64 = 31536000;

    /// Lending pool for SUI
    public struct LendingPool has key {
        id: UID,
        available_liquidity: Balance<SUI>,
        total_borrowed: u64,
        total_deposits: u64,
    }

    /// Individual loan position
    public struct LoanPosition has key, store {
        id: UID,
        pool_id: ID,
        borrower: address,
        collateral: Balance<SUI>,
        borrowed_amount: u64,
        interest_accumulated: u64,
        last_update_time: u64,
    }

    /// Events
    public struct Deposit has copy, drop {
        depositor: address,
        amount: u64,
    }

    public struct Borrow has copy, drop {
        borrower: address,
        collateral: u64,
        borrowed: u64,
    }

    public struct Repay has copy, drop {
        borrower: address,
        amount: u64,
        interest_paid: u64,
    }

    public struct Liquidation has copy, drop {
        liquidator: address,
        borrower: address,
        debt_repaid: u64,
        collateral_seized: u64,
    }

    /// Initialize lending pool
    fun init(ctx: &mut TxContext) {
        let pool = LendingPool {
            id: object::new(ctx),
            available_liquidity: balance::zero(),
            total_borrowed: 0,
            total_deposits: 0,
        };

        transfer::share_object(pool);
    }

    /// Calculate accrued interest
    fun calculate_interest(
        borrowed_amount: u64,
        last_update: u64,
        current_time: u64
    ): u64 {
        let time_elapsed = (current_time - last_update) / 1000; // Convert ms to seconds

        // Simple interest: principal * rate * time / year
        (borrowed_amount * INTEREST_RATE_BPS * time_elapsed) / (10000 * SECONDS_PER_YEAR)
    }

    /// Deposit SUI to lending pool
    public entry fun deposit(
        pool: &mut LendingPool,
        deposit_coin: Coin<SUI>,
        ctx: &TxContext
    ) {
        let amount = coin::value(&deposit_coin);
        let depositor = tx_context::sender(ctx);

        assert!(amount > 0, EInvalidAmount);

        balance::join(&mut pool.available_liquidity, coin::into_balance(deposit_coin));
        pool.total_deposits = pool.total_deposits + amount;

        event::emit(Deposit {
            depositor,
            amount,
        });
    }

    /// Borrow with collateral
    public entry fun borrow(
        pool: &mut LendingPool,
        collateral_coin: Coin<SUI>,
        borrow_amount: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let collateral_amount = coin::value(&collateral_coin);
        let borrower = tx_context::sender(ctx);

        assert!(collateral_amount > 0, EInsufficientCollateral);
        assert!(borrow_amount > 0, EInvalidAmount);

        // Check collateral factor
        let max_borrow = (collateral_amount * COLLATERAL_FACTOR_BPS) / 10000;
        assert!(borrow_amount <= max_borrow, EExceedsMaxBorrow);

        // Check pool liquidity
        assert!(balance::value(&pool.available_liquidity) >= borrow_amount, EPoolEmpty);

        // Create loan position
        let position = LoanPosition {
            id: object::new(ctx),
            pool_id: object::id(pool),
            borrower,
            collateral: coin::into_balance(collateral_coin),
            borrowed_amount: borrow_amount,
            interest_accumulated: 0,
            last_update_time: clock::timestamp_ms(clock),
        };

        // Update pool state
        pool.total_borrowed = pool.total_borrowed + borrow_amount;

        // Transfer borrowed amount
        let borrowed_coin = coin::from_balance(
            balance::split(&mut pool.available_liquidity, borrow_amount),
            ctx
        );

        event::emit(Borrow {
            borrower,
            collateral: collateral_amount,
            borrowed: borrow_amount,
        });

        transfer::public_transfer(borrowed_coin, borrower);
        transfer::transfer(position, borrower);
    }

    /// Repay loan and get back collateral
    public entry fun repay(
        pool: &mut LendingPool,
        position: LoanPosition,
        mut repayment: Coin<SUI>,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let repayer = tx_context::sender(ctx);
        let current_time = clock::timestamp_ms(clock);

        // Calculate total debt with interest
        let interest = calculate_interest(
            position.borrowed_amount,
            position.last_update_time,
            current_time
        ) + position.interest_accumulated;

        let total_debt = position.borrowed_amount + interest;
        let repayment_amount = coin::value(&repayment);

        assert!(repayment_amount >= total_debt, EInvalidAmount);

        // Take only what's needed
        let debt_coin = coin::split(&mut repayment, total_debt, ctx);
        balance::join(&mut pool.available_liquidity, coin::into_balance(debt_coin));

        // Update pool state
        pool.total_borrowed = pool.total_borrowed - position.borrowed_amount;

        // Return collateral
        let borrowed_amt = position.borrowed_amount;
        let LoanPosition {
            id,
            pool_id: _,
            borrower: _,
            collateral,
            borrowed_amount: _,
            interest_accumulated: _,
            last_update_time: _,
        } = position;

        let collateral_coin = coin::from_balance(collateral, ctx);
        transfer::public_transfer(collateral_coin, repayer);

        // Return excess payment
        if (coin::value(&repayment) > 0) {
            transfer::public_transfer(repayment, repayer);
        } else {
            coin::destroy_zero(repayment);
        };

        object::delete(id);

        event::emit(Repay {
            borrower: repayer,
            amount: borrowed_amt,
            interest_paid: interest,
        });
    }

    /// Liquidate undercollateralized position
    public entry fun liquidate(
        pool: &mut LendingPool,
        position: LoanPosition,
        mut repayment: Coin<SUI>,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let liquidator = tx_context::sender(ctx);
        let current_time = clock::timestamp_ms(clock);

        // Calculate total debt
        let interest = calculate_interest(
            position.borrowed_amount,
            position.last_update_time,
            current_time
        ) + position.interest_accumulated;

        let total_debt = position.borrowed_amount + interest;
        let collateral_value = balance::value(&position.collateral);

        // Check if position is liquidatable
        let liquidation_threshold = (collateral_value * LIQUIDATION_THRESHOLD_BPS) / 10000;
        assert!(total_debt > liquidation_threshold, ENotLiquidatable);

        // Calculate collateral to seize (with bonus)
        let collateral_to_seize = (total_debt * (10000 + LIQUIDATION_BONUS_BPS)) / 10000;
        let actual_seize = if (collateral_to_seize > collateral_value) {
            collateral_value
        } else {
            collateral_to_seize
        };

        // Repay debt
        let debt_coin = coin::split(&mut repayment, total_debt, ctx);
        balance::join(&mut pool.available_liquidity, coin::into_balance(debt_coin));

        // Update pool state
        pool.total_borrowed = pool.total_borrowed - position.borrowed_amount;

        // Extract position
        let LoanPosition {
            id,
            pool_id: _,
            borrower,
            mut collateral,
            borrowed_amount: _,
            interest_accumulated: _,
            last_update_time: _,
        } = position;

        // Transfer seized collateral to liquidator
        let seized_coin = coin::from_balance(
            balance::split(&mut collateral, actual_seize),
            ctx
        );
        transfer::public_transfer(seized_coin, liquidator);

        // Return remaining collateral to borrower (if any)
        let remaining = balance::value(&collateral);
        if (remaining > 0) {
            let remaining_coin = coin::from_balance(collateral, ctx);
            transfer::public_transfer(remaining_coin, borrower);
        } else {
            balance::destroy_zero(collateral);
        };

        // Return excess payment
        if (coin::value(&repayment) > 0) {
            transfer::public_transfer(repayment, liquidator);
        } else {
            coin::destroy_zero(repayment);
        };

        object::delete(id);

        event::emit(Liquidation {
            liquidator,
            borrower,
            debt_repaid: total_debt,
            collateral_seized: actual_seize,
        });
    }

    /// View functions
    public fun get_total_debt(position: &LoanPosition, clock: &Clock): u64 {
        let current_time = clock::timestamp_ms(clock);
        let interest = calculate_interest(
            position.borrowed_amount,
            position.last_update_time,
            current_time
        );
        position.borrowed_amount + position.interest_accumulated + interest
    }

    public fun get_collateral(position: &LoanPosition): u64 {
        balance::value(&position.collateral)
    }

    public fun get_health_factor(position: &LoanPosition, clock: &Clock): u64 {
        let debt = get_total_debt(position, clock);
        let collateral = balance::value(&position.collateral);

        if (debt == 0) {
            return 1_000_000_000 // Max health
        };

        (collateral * LIQUIDATION_THRESHOLD_BPS * 1000) / (debt * 10000)
    }

    public fun is_liquidatable(position: &LoanPosition, clock: &Clock): bool {
        get_health_factor(position, clock) < 1000 // Health factor < 1.0
    }

    public fun pool_available_liquidity(pool: &LendingPool): u64 {
        balance::value(&pool.available_liquidity)
    }

    public fun pool_total_borrowed(pool: &LendingPool): u64 {
        pool.total_borrowed
    }

    public fun pool_utilization_rate(pool: &LendingPool): u64 {
        let total = balance::value(&pool.available_liquidity) + pool.total_borrowed;
        if (total == 0) {
            0
        } else {
            (pool.total_borrowed * 10000) / total
        }
    }

    #[test_only]
    public fun init_for_testing(ctx: &mut TxContext) {
        init(ctx);
    }
}
