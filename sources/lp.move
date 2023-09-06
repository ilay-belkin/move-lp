module lp::liquidity_pool {
    use std::signer;

    use aptos_framework::event;
    use aptos_framework::account::{Self, SignerCapability};
    use aptos_framework::coin::{Self, Coin};

    use std::string;
    use std::string::String;

    use lp::lp_coin::{LPCoin};
    use lp::lp_account;
    use staking::staking;

    use std::vector;
    use std::option;

    /// Stores resource account signer capability under pool admin account.
    struct PoolAccountCapability has key { signer_cap: SignerCapability }

    struct LiquidityPool<phantom CoinType> has key {
        native_reserve: Coin<CoinType>,
        providers: vector<address>,
        rewards_to_distribute: u64,
        ve_reward_limit: u64,
        lp_mint_cap: coin::MintCapability<LPCoin<CoinType>>,
        lp_burn_cap: coin::BurnCapability<LPCoin<CoinType>>,
    }

    // Events
    struct EventsStore<phantom CoinType> has key {
        pool_created_handle: event::EventHandle<PoolCreatedEvent<CoinType>>,
        liquidity_provided_handle: event::EventHandle<LiquidityProvidedEvent<CoinType>>,
        liquidity_removed_handle: event::EventHandle<LiquidityRemovedEvent<CoinType>>,
        reward_sent_handle: event::EventHandle<RewardSentEvent<CoinType>>,
        reward_burn_handle: event::EventHandle<RewardBurnEvent<CoinType>>
    }

    struct PoolCreatedEvent<phantom CoinType> has drop, store {
        creator: address,
    }

    struct LiquidityProvidedEvent<phantom CoinType> has drop, store {
        added_val: u64,
        lp_tokens_received: u64,
    }

    struct RewardSentEvent<phantom CoinType> has drop, store {
        receiver: address,
        lp_tokens_received: u64
    }

    struct RewardBurnEvent<phantom CoinType> has drop, store {
        amount: u64
    }

    struct LiquidityRemovedEvent<phantom CoinType> has drop, store {
        removed_val: u64,
        lp_tokens_burned: u64,
    }

    /// When coins used to create pair have wrong ordering.
    const EACCESS_DENIED: u64 = 100;
    const EPOOL_ALREADY_EXIST: u64 = 200;
    const EPOOL_DOES_NOT_EXIST: u64 = 210;
    const EWRONG_PAIR_ORDERING: u64 = 300;
    const EZERO_LIQUIDITY: u64 = 400;
    const EZERO_AMOUNT: u64 = 500;
    const EEMPTY_COIN_IN: u64 = 600;
    const EDIFFERENT_DECIMALS: u64 = 700;
    const EZERO_LP_SUPPLY: u64 = 1000;

    /// Constants
    const SYMBOL_PREFIX_LENGTH: u64 = 10;
    const NAME_PREFIX_LENGTH: u64 = 32;

    #[test_only]
    public fun init_for_test(admin: &signer, signer_cap: SignerCapability) {
        move_to(admin, PoolAccountCapability { signer_cap });
    }

    public entry fun initialize(admin: &signer) {
        assert!(signer::address_of(admin) == @admin, EACCESS_DENIED);

        let signer_cap = lp_account::retrieve_signer_cap(admin);
        move_to(admin, PoolAccountCapability { signer_cap });
    }

    /// Register liquidity pool for coin type.
    public fun register<CoinType>(lp_admin: &signer) acquires PoolAccountCapability {
        assert!(signer::address_of(lp_admin) == @admin, EACCESS_DENIED);
        assert!(!exists<LiquidityPool<CoinType>>(@lp_res_account), EPOOL_ALREADY_EXIST);

        let pool_cap = borrow_global<PoolAccountCapability>(signer::address_of(lp_admin));
        let pool_account = account::create_signer_with_capability(&pool_cap.signer_cap);

        let (lp_name, lp_symbol) = generate_lp_name_and_symbol<CoinType>();
        let (
            lp_burn_cap,
            lp_freeze_cap,
            lp_mint_cap
        ) =
            coin::initialize<LPCoin<CoinType>>(
                &pool_account,
                lp_name,
                lp_symbol,
                coin::decimals<CoinType>(),
                true
            );
        coin::destroy_freeze_cap(lp_freeze_cap);

        let pool = LiquidityPool<CoinType> {
            native_reserve: coin::zero<CoinType>(),
            providers: vector::empty(),
            rewards_to_distribute: 0,
            ve_reward_limit: 100 * 100000000,
            lp_mint_cap,
            lp_burn_cap,
        };
        move_to(&pool_account, pool);

        let events_store = EventsStore<CoinType> {
            pool_created_handle: account::new_event_handle(&pool_account),
            liquidity_provided_handle: account::new_event_handle(&pool_account),
            liquidity_removed_handle: account::new_event_handle(&pool_account),
            reward_sent_handle: account::new_event_handle(&pool_account),
            reward_burn_handle: account::new_event_handle(&pool_account)
        };
        event::emit_event(
            &mut events_store.pool_created_handle,
            PoolCreatedEvent<CoinType> {
                creator: signer::address_of(lp_admin)
            },
        );
        move_to(&pool_account, events_store);
    }

    public entry fun provide_liquidity<CoinType>(
        lp_provider: &signer,
        amount: u64,
    ) acquires LiquidityPool, EventsStore {
        assert!(amount > 0, EZERO_AMOUNT);

        let coin_y = coin::withdraw<CoinType>(lp_provider, amount);
        let lp_coins = mint_lp_coins<CoinType>(coin_y);
        let lp_provider_address = signer::address_of(lp_provider);
        if (!coin::is_account_registered<LPCoin<CoinType>>(lp_provider_address)) {
            coin::register<LPCoin<CoinType>>(lp_provider);
        };
        coin::deposit(lp_provider_address, lp_coins);

        let pool = borrow_global_mut<LiquidityPool<CoinType>>(@lp_res_account);
        if (!vector::contains(&pool.providers, &lp_provider_address)) {
            vector::push_back(&mut pool.providers, lp_provider_address);
        };
    }

    public fun mint_lp_coins<CoinType>(
        coin: Coin<CoinType>,
    ): Coin<LPCoin<CoinType>> acquires LiquidityPool, EventsStore {
        let provided_val = lock<CoinType>(coin);
        let pool = borrow_global_mut<LiquidityPool<CoinType>>(@lp_res_account);

        let lp_coins = coin::mint<LPCoin<CoinType>>(provided_val, &pool.lp_mint_cap);
        let events_store = borrow_global_mut<EventsStore<CoinType>>(@lp_res_account);
        event::emit_event(
            &mut events_store.liquidity_provided_handle,
            LiquidityProvidedEvent<CoinType> {
                added_val: provided_val,
                lp_tokens_received: provided_val
            });
        lp_coins
    }

    public fun add_to_reward<CoinType>(
        amount: u64
    ) acquires LiquidityPool {
        let pool = borrow_global_mut<LiquidityPool<CoinType>>(@lp_res_account);
        pool.rewards_to_distribute = pool.rewards_to_distribute + amount;
    }

    #[view]
    public fun get_rewards_to_distribute<CoinType>(_: address): u64 acquires LiquidityPool {
        let pool = borrow_global<LiquidityPool<CoinType>>(@lp_res_account);
        pool.rewards_to_distribute
    }

    public entry fun harvest<CoinType>(_: &signer) acquires LiquidityPool, EventsStore {
        let pool = borrow_global_mut<LiquidityPool<CoinType>>(@lp_res_account);

        let lp_supply_opt = coin::supply<LPCoin<CoinType>>();
        let lp_supply = *option::borrow(&lp_supply_opt);
        assert!(lp_supply > 0, EZERO_LP_SUPPLY);

        let rewards_total = pool.rewards_to_distribute;

        let i = 0;
        let size = vector::length(&pool.providers);
        let amount_left = rewards_total;

        while (i < size) {
            let provider_address = *vector::borrow(&pool.providers, i);
            let provider_lp_balance = coin::balance<LPCoin<CoinType>>(provider_address);

            let ve_balance = staking::balance_of(provider_address);

            if (ve_balance >= (pool.ve_reward_limit as u128)) {
                let provider_reward = ((rewards_total as u256) * (provider_lp_balance as u256) / (lp_supply as u256) as u64);

                if (provider_reward > amount_left ) {
                    amount_left = 0
                } else {
                    amount_left = amount_left - provider_reward;
                };

                let lp_coins = coin::mint<LPCoin<CoinType>>(provider_reward, &pool.lp_mint_cap);
                coin::deposit(provider_address, lp_coins);

                let events_store = borrow_global_mut<EventsStore<CoinType>>(@lp_res_account);
                event::emit_event(
                    &mut events_store.reward_sent_handle,
                    RewardSentEvent<CoinType> {
                        receiver: provider_address,
                        lp_tokens_received: provider_reward
                    }
                );
            };
            i = i + 1;
        };
        pool.rewards_to_distribute = 0; // burn undistributed rewards

        if (amount_left > 0) {
            let events_store = borrow_global_mut<EventsStore<CoinType>>(@lp_res_account);
            event::emit_event(
                &mut events_store.reward_burn_handle,
                RewardBurnEvent<CoinType> {
                    amount: amount_left
                });

        }
    }

    public entry fun withdraw_liquidity<CoinType>(
        lp_provider: &signer,
        amount: u64
    ) acquires LiquidityPool, EventsStore {
        assert!(amount > 0, EZERO_AMOUNT);
        let lp_coins = coin::withdraw<LPCoin<CoinType>>(lp_provider, amount);
        let coins = burn<CoinType>(lp_coins);
        let lp_provider_address = signer::address_of(lp_provider);
        if (!coin::is_account_registered<CoinType>(lp_provider_address)) {
            coin::register<CoinType>(lp_provider);
        };
        coin::deposit(lp_provider_address, coins);

        let pool = borrow_global_mut<LiquidityPool<CoinType>>(@lp_res_account);
        if (coin::balance<LPCoin<CoinType>>(lp_provider_address) == 0) {
            let (contains, index) = vector::index_of(&pool.providers, &lp_provider_address);
            if (contains) {
                vector::remove(&mut pool.providers, index);
            }
        }
    }

    public fun burn<CoinType>(lp_coins: Coin<LPCoin<CoinType>>): Coin<CoinType> acquires LiquidityPool, EventsStore {
        assert!(exists<LiquidityPool<CoinType>>(@lp_res_account), EPOOL_DOES_NOT_EXIST);

        let burned_lp_coins_val = coin::value(&lp_coins);
        let pool = borrow_global_mut<LiquidityPool<CoinType>>(@lp_res_account);

        // Withdraw those values from reserves
        let coins_to_return = coin::extract(&mut pool.native_reserve, burned_lp_coins_val);
        coin::burn(lp_coins, &pool.lp_burn_cap);

        let events_store = borrow_global_mut<EventsStore<CoinType>>(@lp_res_account);
        event::emit_event(
            &mut events_store.liquidity_removed_handle,
            LiquidityRemovedEvent<CoinType> {
                removed_val: burned_lp_coins_val,
                lp_tokens_burned: burned_lp_coins_val
            });

        coins_to_return
    }

    public entry fun emergency_withdraw<CoinType>(admin: &signer, amount: u64) acquires LiquidityPool {
        let admin_addr = signer::address_of(admin);
        assert!(admin_addr == @admin, EACCESS_DENIED);
        assert!(amount > 0, EZERO_AMOUNT);

        let pool = borrow_global_mut<LiquidityPool<CoinType>>(@lp_res_account);
        let coins_to_return = coin::extract(&mut pool.native_reserve, amount);
        if (!coin::is_account_registered<CoinType>(admin_addr)) {
            coin::register<CoinType>(admin);
        };
        coin::deposit(admin_addr, coins_to_return);
    }

    public entry fun rebalance_transfer<CoinType>(admin: &signer, amount: u64) acquires LiquidityPool, EventsStore {
        // asserts
        let admin_addr = signer::address_of(admin);
        assert!(admin_addr == @admin, EACCESS_DENIED);
        assert!(amount > 0, EZERO_AMOUNT);
        let pool = borrow_global_mut<LiquidityPool<CoinType>>(@lp_res_account);

        // transfer
        let coins_to_return = coin::extract(&mut pool.native_reserve, amount);
        if (!coin::is_account_registered<CoinType>(admin_addr)) {
            coin::register<CoinType>(admin);
        };
        coin::deposit(admin_addr, coins_to_return);

        // events
        let events_store = borrow_global_mut<EventsStore<CoinType>>(@lp_res_account);

        event::emit_event(
            &mut events_store.liquidity_removed_handle,
            LiquidityRemovedEvent<CoinType> {
                removed_val: amount,
                lp_tokens_burned: 0
            });
    }

    public fun lock<CoinType>(coin: Coin<CoinType>): u64 acquires LiquidityPool {
        assert!(exists<LiquidityPool<CoinType>>(@lp_res_account), EPOOL_DOES_NOT_EXIST);
        let pool = borrow_global_mut<LiquidityPool<CoinType>>(@lp_res_account);

        let provided_val = coin::value<CoinType>(&coin);
        assert!(provided_val > 0, EZERO_LIQUIDITY);

        coin::merge(&mut pool.native_reserve, coin);
        provided_val
    }

    public fun release<CoinType>(admin: &signer, amount: u64): Coin<CoinType> acquires LiquidityPool {
        assert!(
            signer::address_of(admin) == @admin || signer::address_of(admin) == @admin,
            EACCESS_DENIED);

        assert!(exists<LiquidityPool<CoinType>>(@lp_res_account), EPOOL_DOES_NOT_EXIST);
        let pool = borrow_global_mut<LiquidityPool<CoinType>>(@lp_res_account);

        // Withdraw those values from reserves
        coin::extract(&mut pool.native_reserve, amount)
    }

    public fun reserves<CoinType>(): u64 acquires LiquidityPool {
        assert!(exists<LiquidityPool<CoinType>>(@lp_res_account), EPOOL_DOES_NOT_EXIST);

        let liquidity_pool = borrow_global<LiquidityPool<CoinType>>(@lp_res_account);
        coin::value(&liquidity_pool.native_reserve)
    }

    public fun generate_lp_name_and_symbol<CoinType>(): (String, String) {
        let lp_name = string::utf8(b"LP-");
        string::append(&mut lp_name, coin::name<CoinType>());
        let lp_symbol = string::utf8(b"LP-");
        string::append(&mut lp_symbol, coin::symbol<CoinType>());
        (prefix(lp_name, NAME_PREFIX_LENGTH), prefix(lp_name, SYMBOL_PREFIX_LENGTH))
    }

    public fun min_u64(a: u64, b: u64): u64 {
        if (a < b) a else b
    }

    fun prefix(str: String, max_len: u64): String {
        let prefix_length = min_u64(string::length(&str), max_len);
        string::sub_string(&str, 0, prefix_length)
    }

    public entry fun set_ve_reward_limit<CoinType>(admin: &signer, value: u64) acquires LiquidityPool {
        let admin_addr = signer::address_of(admin);
        assert!(admin_addr == @admin, EACCESS_DENIED);

        let liquidity_pool = borrow_global_mut<LiquidityPool<CoinType>>(@lp_res_account);
        liquidity_pool.ve_reward_limit = value;
    }
}
