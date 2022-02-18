// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;

import "../Dependencies/CheckContract.sol";
import "../Dependencies/SafeMath.sol";
import "../Dependencies/Ownable.sol";
import "../Interfaces/ILQTYToken.sol";
import "../Dependencies/console.sol";

/*
* Based upon OpenZeppelin's ERC20 contract:
* https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/token/ERC20/ERC20.sol
*  
* and their EIP2612 (ERC20Permit / ERC712) functionality:
* https://github.com/OpenZeppelin/openzeppelin-contracts/blob/53516bc555a454862470e7860a9b5254db4d00f5/contracts/token/ERC20/ERC20Permit.sol
* 
*
*  --- Functionality added specific to the LQTYToken ---
* 
* 1) Transfer protection: blacklist of addresses that are invalid recipients (i.e. core Liquity contracts) in external 
* transfer() and transferFrom() calls. The purpose is to protect users from losing tokens by mistakenly sending LQTY directly to a Liquity
* core contract, when they should rather call the right function.
*
* 2) sendToLQTYStaking(): callable only by Liquity core contracts, which move LQTY tokens from user -> LQTYStaking contract.
*
* 3) Supply hard-capped at 100 million
*
* 4) CommunityIssuance and LockupContractFactory addresses are set at deployment
*
* 5) The bug bounties / hackathons allocation of 2 million tokens is minted at deployment to an EOA

* 6) 32 million tokens are minted at deployment to the CommunityIssuance contract
*
* 7) The LP rewards allocation of (1 + 1/3) million tokens is minted at deployent to a Staking contract
*
* 8) (64 + 2/3) million tokens are minted at deployment to the Liquity multisig
*
* 9) Until one year from deployment:
* -Liquity multisig may only transfer() tokens to LockupContracts that have been deployed via & registered in the 
*  LockupContractFactory 
* -approve(), increaseAllowance(), decreaseAllowance() revert when called by the multisig
* -transferFrom() reverts when the multisig is the sender
* -sendToLQTYStaking() reverts when the multisig is the sender, blocking the multisig from staking its LQTY.
* 
* After one year has passed since deployment of the LQTYToken, the restrictions on multisig operations are lifted
* and the multisig has the same rights as any other address.
*/

contract LQTYToken is Ownable, CheckContract, ILQTYToken {
    using SafeMath for uint256;

    // --- ERC20 Data ---

    string constant internal _NAME = "Space Token";
    string constant internal _SYMBOL = "SPACE";
    string constant internal _VERSION = "1";
    uint8 constant internal  _DECIMALS = 18;

    mapping (address => uint256) private _balances;
    mapping (address => mapping (address => uint256)) private _allowances;
    uint private _totalSupply;

    // --- EIP 2612 Data ---

    // keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    bytes32 private constant _PERMIT_TYPEHASH = 0x6e71edae12b1b97f4d1f60370fef10105fa2faae0126114a169c64845d6126c9;
    // keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant _TYPE_HASH = 0x8b73c3c69bb8fe3d512ecc4cf759cc79239f7b179b0ffacaa9a75d522b39400f;

    // Cache the domain separator as an immutable value, but also store the chain id that it corresponds to, in order to
    // invalidate the cached domain separator if the chain id changes.
    bytes32 private immutable _CACHED_DOMAIN_SEPARATOR;
    uint256 private immutable _CACHED_CHAIN_ID;

    bytes32 private immutable _HASHED_NAME;
    bytes32 private immutable _HASHED_VERSION;
    
    mapping (address => uint256) private _nonces;

    // --- LQTYToken specific data ---

    // uint for use with SafeMath
    uint internal _10_MILLION = 1e25;    // 1e7 * 1e18 = 1e25

    uint internal immutable deploymentStartTime;
    address public immutable multisigAddress;

    mapping(address => bool) public communityIssuanceAddresses;

    uint internal immutable lpRewardsEntitlement;

    enum Functions { ADD_COMMUNITY_ISSUANCE_ADDRESS, REMOVE_COMMUNITY_ISSUANCE_ADDRESS, TRANSFER_TO_NEW_COMMUNITY_ISSUANCE_CONTRACT }  
    uint256 private constant _TIMELOCK = 1 days;
    mapping(Functions => uint256) public timelock;

    // --- Events ---

    event CommunityIssuanceAddressSet(address _communityIssuanceAddress);
    event LockupContractFactoryAddressSet(address _lockupContractFactoryAddress);

    // --- Time lock
    modifier notLocked(Functions _fn) {
        require(
        timelock[_fn] != 1 && timelock[_fn] <= block.timestamp,
        "Function is timelocked"
        );
        _;
    }
    //unlock timelock
    function unlockFunction(Functions _fn) public onlyOwner {
        timelock[_fn] = block.timestamp + _TIMELOCK;
    }
    //lock timelock
    function lockFunction(Functions _fn) public onlyOwner {
        timelock[_fn] = 1;
    }

    // --- Functions ---
    constructor
    (
        address _initialSetupMultisigAddress,
        address _multisigAddress,
        address _stakingRewardMultisigAddress,
        address _communityEcosystemPartnerVestingAddress,
        address _treasuryAddress,
        address _investorMultisig
    ) 
        public 
    {
        checkContract(_initialSetupMultisigAddress);
        checkContract(_stakingRewardMultisigAddress);
        checkContract(_communityEcosystemPartnerVestingAddress);
        checkContract(_treasuryAddress);
        checkContract(_investorMultisig);

        multisigAddress = _multisigAddress;
        deploymentStartTime  = block.timestamp;
        
        bytes32 hashedName = keccak256(bytes(_NAME));
        bytes32 hashedVersion = keccak256(bytes(_VERSION));

        _HASHED_NAME = hashedName;
        _HASHED_VERSION = hashedVersion;
        _CACHED_CHAIN_ID = _chainID();
        _CACHED_DOMAIN_SEPARATOR = _buildDomainSeparator(_TYPE_HASH, hashedName, hashedVersion);
        
        // --- Initial XDO allocations ---
        // 1. Initial setup including marketing, bounties, expenses and airdrop.
        _mint(_initialSetupMultisigAddress, _10_MILLION.mul(1)); // Allocate 10 million for initial setup

        // 2. Community rewards for stability pools and other stakings.
        uint _lpRewardsEntitlement = _10_MILLION.div(10);  // Allocate 1 million for LP rewards
        lpRewardsEntitlement = _lpRewardsEntitlement;
        _mint(_multisigAddress, _lpRewardsEntitlement);

        uint _initialSPRewardsEntitlement = _10_MILLION.mul(7).div(100); // Allocate 0.7 million for initial SP rewards
        _mint(_multisigAddress, _initialSPRewardsEntitlement);

        _mint(_stakingRewardMultisigAddress, _10_MILLION.mul(4683).div(100)); // Allocate (470 - 0.7 - 1) =  468.3 million to community.

        // 3. Team vesting
        _mint(_multisigAddress, _10_MILLION.mul(20)); // Allocate 200 million to team vesting.
        
        // 4. Ecosystem and partner shares to support the growth of xDollar.
        _mint(_communityEcosystemPartnerVestingAddress, _10_MILLION.mul(17)); // Allocate 170 million to parter and ecosystem.

        // 5. Investor multisig
        _mint(_investorMultisig, _10_MILLION.mul(10)); // Allocate 100 million to future investors.

        // 6. Treasury multisig
        _mint(_treasuryAddress, _10_MILLION.mul(5)); // Allocate 50 million to Treasury.

        // Total XDO supply is 10 + 1 + 0.7 + 468.3 + 200 + 170 + 100 + 50 = 1B
    }

    // --- External functions ---

    function totalSupply() external view override returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) external view override returns (uint256) {
        return _balances[account];
    }

    function getDeploymentStartTime() external view override returns (uint256) {
        return deploymentStartTime;
    }

    function getLpRewardsEntitlement() external view override returns (uint256) {
        return lpRewardsEntitlement;
    }

    function transfer(address recipient, uint256 amount) external override returns (bool) {
        _requireValidRecipient(recipient);
  
        // Otherwise, standard transfer functionality
        _transfer(msg.sender, recipient, amount);
        return true;
    }

    function allowance(address owner, address spender) external view override returns (uint256) {
        return _allowances[owner][spender];
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address sender, address recipient, uint256 amount) external override returns (bool) {        
        _requireValidRecipient(recipient);

        _transfer(sender, recipient, amount);
        _approve(sender, msg.sender, _allowances[sender][msg.sender].sub(amount, "ERC20: transfer amount exceeds allowance"));
        return true;
    }

    function increaseAllowance(address spender, uint256 addedValue) external override returns (bool) {        
        _approve(msg.sender, spender, _allowances[msg.sender][spender].add(addedValue));
        return true;
    }

    function decreaseAllowance(address spender, uint256 subtractedValue) external override returns (bool) {        
        _approve(msg.sender, spender, _allowances[msg.sender][spender].sub(subtractedValue, "ERC20: decreased allowance below zero"));
        return true;
    }

    function addCommunityIssuanceAddress(address newCommunityIssuanceAddress) external onlyOwner notLocked(Functions.ADD_COMMUNITY_ISSUANCE_ADDRESS) {
        communityIssuanceAddresses[newCommunityIssuanceAddress] = true;
        timelock[Functions.ADD_COMMUNITY_ISSUANCE_ADDRESS] = 1;
    }

    function removeCommunityIssuanceAddress(address newCommunityIssuanceAddress) external onlyOwner notLocked(Functions.REMOVE_COMMUNITY_ISSUANCE_ADDRESS) {
        communityIssuanceAddresses[newCommunityIssuanceAddress] = false;
        timelock[Functions.REMOVE_COMMUNITY_ISSUANCE_ADDRESS] = 1;
    }

    function transferToNewCommunityIssuanceContract(address newCommunityIssuanceAddress, uint256 amount) external onlyOwner notLocked(Functions.TRANSFER_TO_NEW_COMMUNITY_ISSUANCE_CONTRACT) {
        _requireRecipientIsCommunityIssuance(newCommunityIssuanceAddress);
        _transfer(msg.sender, newCommunityIssuanceAddress, amount);
        timelock[Functions.TRANSFER_TO_NEW_COMMUNITY_ISSUANCE_CONTRACT] = 1;
    }

    // --- EIP 2612 functionality ---

    function domainSeparator() public view override returns (bytes32) {    
        if (_chainID() == _CACHED_CHAIN_ID) {
            return _CACHED_DOMAIN_SEPARATOR;
        } else {
            return _buildDomainSeparator(_TYPE_HASH, _HASHED_NAME, _HASHED_VERSION);
        }
    }

    function permit
    (
        address owner, 
        address spender, 
        uint amount, 
        uint deadline, 
        uint8 v, 
        bytes32 r, 
        bytes32 s
    ) 
        external 
        override 
    {            
        require(deadline >= now, 'LQTY: expired deadline');
        bytes32 digest = keccak256(abi.encodePacked('\x19\x01', 
                         domainSeparator(), keccak256(abi.encode(
                         _PERMIT_TYPEHASH, owner, spender, amount, 
                         _nonces[owner]++, deadline))));
        address recoveredAddress = ecrecover(digest, v, r, s);
        require(recoveredAddress != address(0), "recoveredAddress is zero address!");
        require(recoveredAddress == owner, 'LQTY: invalid signature');
        _approve(owner, spender, amount);
    }

    function nonces(address owner) external view override returns (uint256) { // FOR EIP 2612
        return _nonces[owner];
    }

    // --- Internal operations ---

    function _chainID() private pure returns (uint256 chainID) {
        assembly {
            chainID := chainid()
        }
    }

    function _buildDomainSeparator(bytes32 typeHash, bytes32 name, bytes32 version) private view returns (bytes32) {
        return keccak256(abi.encode(typeHash, name, version, _chainID(), address(this)));
    }

    function _transfer(address sender, address recipient, uint256 amount) internal {
        require(sender != address(0), "ERC20: transfer from the zero address");
        require(recipient != address(0), "ERC20: transfer to the zero address");

        _balances[sender] = _balances[sender].sub(amount, "ERC20: transfer amount exceeds balance");
        _balances[recipient] = _balances[recipient].add(amount);
        emit Transfer(sender, recipient, amount);
    }

    function _mint(address account, uint256 amount) internal {
        require(account != address(0), "ERC20: mint to the zero address");

        _totalSupply = _totalSupply.add(amount);
        _balances[account] = _balances[account].add(amount);
        emit Transfer(address(0), account, amount);
    }

    function _approve(address owner, address spender, uint256 amount) internal {
        require(owner != address(0), "ERC20: approve from the zero address");
        require(spender != address(0), "ERC20: approve to the zero address");

        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    // --- 'require' functions ---
    
    function _requireValidRecipient(address _recipient) internal view {
        require(
            _recipient != address(0) && 
            _recipient != address(this),
            "LQTY: Cannot transfer tokens directly to the LQTY token contract or the zero address"
        );
        require(
            communityIssuanceAddresses[_recipient] == false,
            "LQTY: Cannot transfer tokens directly to the community issuance"
        );
    }

    function _requireRecipientIsCommunityIssuance(address _recipient) internal view {
        require(communityIssuanceAddresses[_recipient], 
        "LQTYToken: recipient must be a CommunityIssuance contract");
    }

    // --- Optional functions ---

    function name() external view override returns (string memory) {
        return _NAME;
    }

    function symbol() external view override returns (string memory) {
        return _SYMBOL;
    }

    function decimals() external view override returns (uint8) {
        return _DECIMALS;
    }

    function version() external view override returns (string memory) {
        return _VERSION;
    }

    function permitTypeHash() external view override returns (bytes32) {
        return _PERMIT_TYPEHASH;
    }
}