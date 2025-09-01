module jq721::jq721;

use kiosk::kiosk_lock_rule as kiosk_lock;
use kiosk::royalty_rule;
use std::string::{Self, utf8, String};
use sui::clock::Clock;
use sui::coin::Coin;
use sui::display;
use sui::event;
use sui::package;
use sui::transfer_policy::{TransferPolicy, TransferPolicyCap};
use sui::tx_context::sender;
use sui::vec_map::{Self, VecMap};

public struct Collection has key, store {
    id: UID,
    initialized: bool, //if collection is initialized
    supply: u64, //total mintable supply
    minted_supply: u64, //minted supply
    metadata_count: u64, //max value of supply as in created pending metadata
    metadata_count_real: u64, //real metadata count, can be less than supply if some are removed
    is_immutable: bool, //if supply is immutable
    ejected: bool, //if collection is ejected from joystiq core
    next_token_id: u64, //next token id to be minted
    starting_token_id: u64, //starting token id for the collection
    fixed_metadata: bool, //if metadata is fixed
    package: std::ascii::String,
}

public struct NFT has key, store {
    id: UID,
    token_id: u64,
    name: String,
    image_url: String,
    description: String,
    attributes: VecMap<String, String>,
}

public struct PendingMetadata has drop, store {
    token_id: u64,
    name: String,
    image_url: String,
    description: String,
    attributes: VecMap<String, String>,
}

public struct FixedMetadata has drop, store {
    name: String,
    image_url: String,
    description: String,
    attributes: VecMap<String, String>,
    name_format: Option<String>, // "{name} {token_id}"
}

public struct MintEvent has copy, drop {
    object_id: ID,
    recipient: address,
    token_id: u64,
}

public struct CreateEvent has copy, drop {
    token_id: u64,
}

fun format_name(
    name_format: &string::String,
    name: &string::String,
    token_id: u64,
): string::String {
    let mut result = *name_format;

    // Define the placeholder strings manually
    let name_placeholder = string::utf8(vector[
        123,
        110,
        97,
        109,
        101,
        125, // "{name}"
    ]);
    let token_placeholder = string::utf8(vector[
        123,
        116,
        111,
        107,
        101,
        110,
        95,
        105,
        100,
        125, // "{token_id}"
    ]);

    let token_id_str = token_id.to_string();

    let idx_name = string::index_of(&result, &name_placeholder);
    if (idx_name < string::length(&result)) {
        let before = string::substring(&result, 0, idx_name);
        let after = string::substring(
            &result,
            idx_name + string::length(&name_placeholder),
            string::length(&result),
        );
        result = before;
        string::append(&mut result, *name);
        string::append(&mut result, after);
    };

    let idx_token = string::index_of(&result, &token_placeholder);
    if (idx_token < string::length(&result)) {
        let before = string::substring(&result, 0, idx_token);
        let after = string::substring(
            &result,
            idx_token + string::length(&token_placeholder),
            string::length(&result),
        );
        result = before;
        string::append(&mut result, token_id_str);
        string::append(&mut result, after);
    };

    result
}

//helper function to conver fixedmetadata to pendingmetadata with token_id input and name formatted
fun fixed_metadata_to_pending(fixed_metadata: &FixedMetadata, token_id: u64): PendingMetadata {
    let mut name = fixed_metadata.name;

    if (fixed_metadata.name_format.is_some()) {
        let format = fixed_metadata.name_format.borrow();
        name = format_name(format, &fixed_metadata.name, token_id);
    };

    PendingMetadata {
        token_id,
        name,
        image_url: fixed_metadata.image_url,
        description: fixed_metadata.description,
        attributes: fixed_metadata.attributes,
    }
}

fun mint_internal(
    collection: &mut Collection,
    transfer_policy: &TransferPolicy<NFT>,
    amount: u64,
    ctx: &mut TxContext,
) {
    let mut minted_amount = 0;

    if (collection.supply != 0) {
        assert!(collection.minted_supply + amount <= collection.supply, 0x2);
        assert!(collection.minted_supply + amount <= collection.metadata_count, 0x3);
    } else if (!collection.fixed_metadata) {
        assert!(collection.minted_supply + amount <= collection.metadata_count_real, 0x3);
    };

    while (minted_amount < amount) {
        let mut metadata: PendingMetadata;

        if (collection.fixed_metadata) {
            metadata =
                fixed_metadata_to_pending(
                    sui::dynamic_field::borrow<String, FixedMetadata>(
                        &collection.id,
                        utf8(b"fixed_metadata"),
                    ),
                    collection.next_token_id,
                );
        } else {
            metadata =
                sui::dynamic_field::remove<String, PendingMetadata>(
                    &mut collection.id,
                    collection.next_token_id.to_string(),
                );
        };

        let PendingMetadata { token_id, name, image_url, description, attributes } = metadata;

        let nft = NFT {
            id: object::new(ctx),
            token_id: token_id,
            name: name,
            image_url: image_url,
            description: description,
            attributes: attributes,
        };

        event::emit(MintEvent {
            object_id: *nft.id.as_inner(),
            recipient: sender(ctx),
            token_id: nft.token_id,
        });

        let (mut kiosk_obj, kiosk_cap) = sui::kiosk::new(ctx);
        //kiosk_obj.set_owner_custom(&kiosk_cap, recipient);

        sui::kiosk::lock(&mut kiosk_obj, &kiosk_cap, transfer_policy, nft);

        collection.minted_supply = collection.minted_supply + 1;
        collection.next_token_id = collection.next_token_id + 1; // Increment next token id for future mints

        transfer::public_transfer(kiosk_cap, sender(ctx)); // Transfer the KioskOwnerCap to the sender
        transfer::public_share_object(kiosk_obj);

        minted_amount = minted_amount + 1;
    }
}

public entry fun mint_unpaid(
    collection: &mut Collection,
    collection_jq_config: &mut joystiq::nft_core::Collection,
    transfer_policy: &TransferPolicy<NFT>,
    group_index: u64,
    amount: u64,
    merkle_proof: Option<vector<vector<u8>>>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(amount > 0, 0x4); // Ensure amount is greater than 0

    // Validate joystiq core rules
    if (collection.ejected) {
        abort 0x5 // Collection is ejected, cannot mint
    };

    let mut token_ids: vector<u64> = vector::empty<u64>();
    let mut i = 0;
    while (i < amount) {
        token_ids.push_back(collection.next_token_id + i);
        i = i + 1;
    };

    joystiq::nft_core::validate_unpaid(
        collection_jq_config,
        token_ids,
        group_index,
        merkle_proof,
        clock,
        ctx,
    );

    mint_internal(
        collection,
        transfer_policy,
        amount,
        ctx,
    );
}

public entry fun mint<T>(
    collection: &mut Collection,
    collection_jq_config: &mut joystiq::nft_core::Collection,
    jq_core_root: &mut joystiq::nft_core::Root,
    transfer_policy: &TransferPolicy<NFT>,
    group_index: u64,
    amount: u64,
    merkle_proof: Option<vector<vector<u8>>>,
    clock: &Clock,
    coin: Coin<T>,
    ctx: &mut TxContext,
) {
    assert!(amount > 0, 0x4); // Ensure amount is greater than 0

    // Validate joystiq core rules
    if (collection.ejected) {
        abort 0x5 // Collection is ejected, cannot mint
    };

    let mut token_ids: vector<u64> = vector::empty<u64>();
    let mut i = 0;
    while (i < amount) {
        token_ids.push_back(collection.next_token_id + i);
        i = i + 1;
    };

    joystiq::nft_core::validate(
        jq_core_root,
        collection_jq_config,
        token_ids,
        group_index,
        merkle_proof,
        clock,
        coin,
        ctx,
    );

    mint_internal(
        collection,
        transfer_policy,
        amount,
        ctx,
    );
}

public entry fun mint_paid2<T1, T2>(
    collection: &mut Collection,
    collection_jq_config: &mut joystiq::nft_core::Collection,
    jq_core_root: &mut joystiq::nft_core::Root,
    transfer_policy: &TransferPolicy<NFT>,
    group_index: u64,
    amount: u64,
    merkle_proof: Option<vector<vector<u8>>>,
    clock: &Clock,
    coin: Coin<T1>,
    coin2: Coin<T2>,
    ctx: &mut TxContext,
) {
    assert!(amount > 0, 0x4); // Ensure amount is greater than 0

    // Validate joystiq core rules
    if (collection.ejected) {
        abort 0x5 // Collection is ejected, cannot mint
    };

    let mut token_ids: vector<u64> = vector::empty<u64>();
    let mut i = 0;
    while (i < amount) {
        token_ids.push_back(collection.next_token_id + i);
        i = i + 1;
    };

    joystiq::nft_core::validate_2(
        jq_core_root,
        collection_jq_config,
        token_ids,
        group_index,
        merkle_proof,
        clock,
        coin,
        coin2,
        ctx,
    );

    mint_internal(
        collection,
        transfer_policy,
        amount,
        ctx,
    );
}

public entry fun create(
    token_id: u64,
    name: String,
    image_url: String,
    description: String,
    attributes_keys: vector<String>,
    attributes_values: vector<String>,
    collection: &mut Collection,
    publisher: &mut sui::package::Publisher,
    _ctx: &mut TxContext,
) {
    assert!(collection.initialized, 0x2); // Ensure collection is initialized
    assert!(collection.package == *publisher.package(), 0x3); // only original publisher can initialize collection

    let metadata = PendingMetadata {
        token_id,
        //name: utf8(name),
        name: name,
        image_url: image_url,
        description: description,
        attributes: vec_map::from_keys_values(
            attributes_keys,
            attributes_values,
        ),
    };

    event::emit(CreateEvent {
        token_id,
    });

    // pending metadata update
    if (sui::dynamic_field::exists_(&collection.id, token_id.to_string())) {
        let existing_metadata = sui::dynamic_field::borrow_mut<String, PendingMetadata>(
            &mut collection.id,
            token_id.to_string(),
        );

        existing_metadata.name = metadata.name;
        existing_metadata.image_url = metadata.image_url;
        existing_metadata.description = metadata.description;
        existing_metadata.attributes = metadata.attributes;
    } else {
        //pending metadata creation
        if (collection.supply != 0) {
            assert!(collection.metadata_count + 1 <= collection.supply, 0x3);
        };
        sui::dynamic_field::add(
            &mut collection.id,
            token_id.to_string(),
            metadata,
        );

        //only increase supply values if metadata is being created now, not updated
        collection.metadata_count = collection.metadata_count + 1;
        collection.metadata_count_real = collection.metadata_count_real + 1; // Increase real metadata count
    }
}

public entry fun eject_collection(
    collection: &mut Collection,
    publisher: &mut sui::package::Publisher,
    _ctx: &mut TxContext,
) {
    assert!(collection.package == *publisher.package(), 0x3); // only original publisher can initialize collection
    collection.ejected = true;
}

public entry fun transfer_collection_ownership(
    collection: &mut Collection,
    publisher: sui::package::Publisher,
    policy_cap: TransferPolicyCap<NFT>,
    new_owner: address,
    _ctx: &mut TxContext,
) {
    assert!(collection.package == *publisher.package(), 0x3); // only original publisher can initialize collection
    transfer::public_transfer(policy_cap, new_owner); // Transfer the policy cap to the new owner
    transfer::public_transfer(publisher, new_owner); // Transfer the publisher object to the new owner
}

public entry fun update_collection(
    collection: &mut Collection,
    collection_name: String,
    collection_description: String,
    collection_media_url: String,
    supply: u64,
    fixed_metadata: bool,
    //royalty_bps: u16,
    //fixed mata stuff
    fm_name: String,
    fm_image_url: String,
    fm_description: String,
    fm_attributes_keys: vector<String>,
    fm_attributes_values: vector<String>,
    fm_name_format: Option<String>, // "{name} {token_id}"
    policy: &mut TransferPolicy<NFT>,
    policy_cap: &mut TransferPolicyCap<NFT>, //TODO: mut
    display: &mut display::Display<NFT>,
    publisher: &mut sui::package::Publisher,
    _ctx: &mut TxContext,
) {
    assert!(collection.is_immutable == false, 0x2); // collection must be mutable to change
    assert!(collection.package == *publisher.package(), 0x3); // only original publisher can update collection

    if (supply != 0 && supply < collection.minted_supply) {
        abort 0x1 // Cannot reduce supply below current minimum
    };

    collection.supply = supply;

    if (fixed_metadata) {
        collection.metadata_count = supply;
    } else {
        collection.metadata_count = collection.metadata_count_real; // Reset metadata count if not fixed
    };

    // Update display object
    display::edit<NFT>(
        display,
        utf8(b"collection_name"),
        collection_name,
    );
    display::edit<NFT>(
        display,
        utf8(b"collection_description"),
        collection_description,
    );
    display::edit<NFT>(
        display,
        utf8(b"collection_media_url"),
        collection_media_url,
    );
    display::update_version(display);

    //fixed metadata
    collection.fixed_metadata = fixed_metadata;

    if (fixed_metadata) {
        if (sui::dynamic_field::exists_(&collection.id, utf8(b"fixed_metadata"))) {
            let existing_metadata = sui::dynamic_field::borrow_mut<String, FixedMetadata>(
                &mut collection.id,
                utf8(b"fixed_metadata"),
            );

            existing_metadata.name = fm_name;
            existing_metadata.image_url = fm_image_url;
            existing_metadata.description = fm_description;
            existing_metadata.attributes =
                vec_map::from_keys_values(
                    fm_attributes_keys,
                    fm_attributes_values,
                );
            existing_metadata.name_format = fm_name_format;
        } else {
            let fixed_metadata = FixedMetadata {
                name: fm_name,
                image_url: fm_image_url,
                description: fm_description,
                attributes: vec_map::from_keys_values(
                    fm_attributes_keys,
                    fm_attributes_values,
                ),
                name_format: fm_name_format,
            };
            sui::dynamic_field::add(
                &mut collection.id,
                utf8(b"fixed_metadata"),
                fixed_metadata,
            );
        }
    };
}

public entry fun initialize_collection(
    collection_name: String,
    collection_description: String,
    collection_media_url: String,
    supply_amount: u64,
    is_immutable: bool,
    royalty_bps: u16,
    starting_token_id: u64,
    fixed_metadata: bool,
    //fixed mata stuff
    fm_name: String,
    fm_image_url: String,
    fm_description: String,
    fm_attributes_keys: vector<String>,
    fm_attributes_values: vector<String>,
    fm_name_format: Option<String>, // "{name} {token_id}"
    policy: &mut TransferPolicy<NFT>,
    policy_cap: &mut TransferPolicyCap<NFT>, //TODO: mut
    collection: &mut Collection,
    publisher: &mut sui::package::Publisher,
    ctx: &mut TxContext,
) {
    assert!(collection.initialized == false, 0x2); // Collection must not be initialized
    assert!(collection.package == *publisher.package(), 0x3); // only original publisher can initialize collection
    // Define the Collection display object
    let mut display_object = display::new<NFT>(publisher, ctx);
    display::add<NFT>(&mut display_object, utf8(b"collection_name"), collection_name);
    display::add<NFT>(
        &mut display_object,
        utf8(b"collection_description"),
        collection_description,
    );
    display::add<NFT>(
        &mut display_object,
        utf8(b"collection_media_url"),
        collection_media_url,
    );
    display::add<NFT>(&mut display_object, utf8(b"name"), utf8(b"{name}"));
    display::add<NFT>(&mut display_object, utf8(b"description"), utf8(b"{description}"));
    display::add<NFT>(&mut display_object, utf8(b"image_url"), utf8(b"{image_url}"));
    display::add<NFT>(&mut display_object, utf8(b"attributes"), utf8(b"{attributes}"));
    display::update_version(&mut display_object);
    // Transfer display object to the sender
    transfer::public_transfer(display_object, sender(ctx));

    // Update collection properties
    collection.initialized = true;
    collection.is_immutable = is_immutable;
    collection.supply = supply_amount;
    collection.next_token_id = starting_token_id; // Initialize next token ID
    collection.starting_token_id = starting_token_id; // Set starting token ID
    collection.fixed_metadata = fixed_metadata;
    if (fixed_metadata) {
        collection.metadata_count = supply_amount;

        let fixed_metadata = FixedMetadata {
            name: fm_name,
            image_url: fm_image_url,
            description: fm_description,
            attributes: vec_map::from_keys_values(
                fm_attributes_keys,
                fm_attributes_values,
            ),
            name_format: fm_name_format,
        };
        sui::dynamic_field::add(
            &mut collection.id,
            utf8(b"fixed_metadata"),
            fixed_metadata,
        );
    };

    // Add kiosk lock rule
    kiosk_lock::add<NFT>(policy, policy_cap);

    // Add royalty rule if needed
    royalty_rule::add<NFT>(policy, policy_cap, royalty_bps, 0);
}

public struct JQ721 has drop {}

fun init(otw: JQ721, ctx: &mut TxContext) {
    // Claim publisher for display
    let publisher = package::claim(otw, ctx);

    // Create TransferPolicy and Cap
    let (policy, policy_cap) = sui::transfer_policy::new<NFT>(&publisher, ctx);

    // Create collection object
    let collection = Collection {
        id: object::new(ctx),
        initialized: false, // Collection is not initialized yet
        supply: 0,
        minted_supply: 0,
        metadata_count: 0, // Initialize metadata count to 0
        metadata_count_real: 0, // Initialize real metadata count to 0
        is_immutable: false,
        ejected: false,
        fixed_metadata: false, // Initialize fixed metadata to false
        next_token_id: 0, // Initialize next token ID to 0
        starting_token_id: 0, // Initialize starting token ID to 0
        package: *publisher.package(),
    };

    // Transfer ownerships
    transfer::public_share_object(collection);
    transfer::public_share_object(policy);
    transfer::public_transfer(policy_cap, sender(ctx));
    //transfer::public_transfer(display, sender(ctx));
    transfer::public_transfer(publisher, sender(ctx));
}
