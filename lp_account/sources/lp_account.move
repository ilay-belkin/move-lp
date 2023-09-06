/// The module used to create user resource account and deploy LP coins under that account.
module lp::lp_account {
    use std::signer;

    use aptos_framework::account::{Self, SignerCapability};

    /// When called from wrong account.
    const ERR_NOT_ENOUGH_PERMISSIONS: u64 = 1701;

    /// Temporary storage for user resource account signer capability.
    struct CapabilityStorage has key { signer_cap: SignerCapability }

    /// Creates new resource account for LP, puts signer capability into storage
    /// and deploys LP coin type.
    /// Can be executed only from admin account.
    public entry fun initialize_lp_account(
        admin: &signer,
        lp_coin_metadata_serialized: vector<u8>,
        lp_coin_code: vector<u8>
    ) {
        assert!(signer::address_of(admin) == @admin, ERR_NOT_ENOUGH_PERMISSIONS);

        let (lp_acc, signer_cap) =
            account::create_resource_account(admin, b"lp_seed");
        aptos_framework::code::publish_package_txn(
            &lp_acc,
            lp_coin_metadata_serialized,
            vector[lp_coin_code]
        );
        move_to(admin, CapabilityStorage { signer_cap });
    }

    /// Destroys temporary storage for resource account signer capability and returns signer capability.
    /// It needs for initialization of liquidswap.
    public fun retrieve_signer_cap(admin: &signer): SignerCapability acquires CapabilityStorage {
        assert!(signer::address_of(admin) == @admin, ERR_NOT_ENOUGH_PERMISSIONS);
        let CapabilityStorage { signer_cap } =
            move_from<CapabilityStorage>(signer::address_of(admin));
        signer_cap
    }
}