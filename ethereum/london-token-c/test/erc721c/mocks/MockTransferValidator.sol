// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @dev Stand-in for the Limit Break transfer validator, etched at the default validator address
///      in unit tests. `validateTransfer` is reached through a STATICCALL (it is declared `view`
///      in ITransferValidator), so it only reads the reject switch; tests use `vm.expectCall` to
///      assert whether and how it was called.
contract MockTransferValidator {
    error MockTransferRejected(address caller, address from, address to, uint256 tokenId);

    bool public rejectAll;
    mapping(address collection => uint16 tokenType) public tokenTypeOf;

    function setRejectAll(bool reject) external {
        rejectAll = reject;
    }

    function validateTransfer(address caller, address from, address to, uint256 tokenId)
        external
        view
    {
        if (rejectAll) revert MockTransferRejected(caller, from, to, tokenId);
    }

    function setTokenTypeOfCollection(address collection, uint16 tokenType) external {
        tokenTypeOf[collection] = tokenType;
    }

    // -----------------------------------------------------------------
    // List / collection management (subset of validator v5). Collection
    // configuration only accepts the collection itself as caller, so tests
    // prove LondonTokenC self-configures during initialization.
    // -----------------------------------------------------------------

    error MockNotListOwner(uint48 id, address caller);
    error MockNotCollection(address collection, address caller);

    struct Policy {
        uint8 rulesetId;
        address customRuleset;
        uint8 globalOptions;
        uint16 rulesetOptions;
        uint48 listId;
    }

    uint48 public lastListId;
    mapping(uint48 id => address owner) public listOwners;
    mapping(uint48 id => string name) public listNames;
    mapping(uint48 id => mapping(uint8 listType => address[] accounts)) internal _listAccounts;
    mapping(address collection => Policy policy) internal _policies;

    function createList(string calldata name) external returns (uint48 id) {
        id = ++lastListId;
        listOwners[id] = msg.sender;
        listNames[id] = name;
    }

    function addAccountsToList(uint48 id, uint8 listType, address[] calldata accounts) external {
        if (listOwners[id] != msg.sender) revert MockNotListOwner(id, msg.sender);
        for (uint256 i; i < accounts.length; ++i) {
            _listAccounts[id][listType].push(accounts[i]);
        }
    }

    function reassignOwnershipOfList(uint48 id, address newOwner) external {
        if (listOwners[id] != msg.sender) revert MockNotListOwner(id, msg.sender);
        listOwners[id] = newOwner;
    }

    function setRulesetOfCollection(
        address collection,
        uint8 rulesetId,
        address customRuleset,
        uint8 globalOptions,
        uint16 rulesetOptions
    ) external {
        if (msg.sender != collection) {
            revert MockNotCollection(collection, msg.sender);
        }
        Policy storage p = _policies[collection];
        p.rulesetId = rulesetId;
        p.customRuleset = customRuleset;
        p.globalOptions = globalOptions;
        p.rulesetOptions = rulesetOptions;
    }

    function applyListToCollection(address collection, uint48 id) external {
        if (msg.sender != collection) revert MockNotCollection(collection, msg.sender);
        _policies[collection].listId = id;
    }

    function listAccounts(uint48 id, uint8 listType) external view returns (address[] memory) {
        return _listAccounts[id][listType];
    }

    function policyOf(address collection) external view returns (Policy memory) {
        return _policies[collection];
    }
}
