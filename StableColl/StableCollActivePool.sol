// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;

import '../Interfaces/IStableCollActivePool.sol';
import "../Dependencies/IERC20.sol";
import "../Dependencies/SafeMath.sol";
import "../Dependencies/Ownable.sol";
import "../Dependencies/CheckContract.sol";
import "../Dependencies/console.sol";

/*
 * The Active Pool holds the ETH collateral and LUSD debt (but not LUSD tokens) for all active troves.
 *
 * When a trove is liquidated, it's ETH and LUSD debt are transferred from the Active Pool, to either the
 * Stability Pool, the Default Pool, or both, depending on the liquidation conditions.
 *
 */
contract StableCollActivePool is Ownable, CheckContract, IStableCollActivePool {
    using SafeMath for uint256;

    string constant public NAME = "StableCollActivePool";

    address public stableCollBorrowerOperationsAddress;
    address public stableCollTroveManagerAddress;
    uint256 internal ETH;  // deposited ether tracker
    uint256 internal LUSDDebt;

    IERC20 public collToken;

    enum Functions { SET_ADDRESS }  
    uint256 private constant _TIMELOCK = 1 days;
    mapping(Functions => uint256) public timelock;

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

    // --- Events ---

    event StableCollBorrowerOperationsAddressChanged(address _newStableCollBorrowerOperationsAddress);
    event StableCollTroveManagerAddressChanged(address _newStableCollTroveManagerAddress);
    event StableCollActivePoolLUSDDebtUpdated(uint _LUSDDebt);
    event StableCollActivePoolETHBalanceUpdated(uint _ETH);
    event CollTokenAddressChanged(address _collTokenAddress);

    // --- Contract setters ---

    function setAddresses(
        address _stableCollBorrowerOperationsAddress,
        address _stableCollTroveManagerAddress,
        address _collTokenAddress
    )
        external
        onlyOwner
        notLocked(Functions.SET_ADDRESS)
    {
        checkContract(_stableCollBorrowerOperationsAddress);
        checkContract(_stableCollTroveManagerAddress);
        checkContract(_collTokenAddress);

        stableCollBorrowerOperationsAddress = _stableCollBorrowerOperationsAddress;
        stableCollTroveManagerAddress = _stableCollTroveManagerAddress;
        collToken = IERC20(_collTokenAddress);

        emit StableCollBorrowerOperationsAddressChanged(_stableCollBorrowerOperationsAddress);
        emit StableCollTroveManagerAddressChanged(_stableCollTroveManagerAddress);
        emit CollAddressChanged(_collTokenAddress);

        _renounceOwnership();

        timelock[Functions.SET_ADDRESS] = 1;
    }

    // --- Getters for public variables. Required by IPool interface ---

    /*
    * Returns the ETH state variable.
    *
    *Not necessarily equal to the the contract's raw ETH balance - ether can be forcibly sent to contracts.
    */
    function getETH() external view override returns (uint) {
        return ETH;
    }

    function getLUSDDebt() external view override returns (uint) {
        return LUSDDebt;
    }

    // --- Pool functionality ---

    function sendETH(address _account, uint _amount) external override {
        _requireCallerIsBOorTroveM();
        ETH = ETH.sub(_amount);

        bool success = collToken.transfer(_account, _amount);
        require(success, "ActivePool: sending ETH failed");

        emit StableCollActivePoolETHBalanceUpdated(ETH);
        emit EtherSent(_account, _amount);
    }

    function increaseLUSDDebt(uint _amount) external override {
        _requireCallerIsBOorTroveM();
        LUSDDebt = LUSDDebt.add(_amount);
        emit StableCollActivePoolLUSDDebtUpdated(LUSDDebt);
    }

    function decreaseLUSDDebt(uint _amount) external override {
        _requireCallerIsBOorTroveM();
        LUSDDebt = LUSDDebt.sub(_amount);
        emit StableCollActivePoolLUSDDebtUpdated(LUSDDebt);
    }

    // --- 'require' functions ---

    function _requireCallerIsBorrowerOperations() internal view {
        require(
            msg.sender == stableCollBorrowerOperationsAddress,
            "StableCollActivePool: Caller is BO");
    }

    function _requireCallerIsBOorTroveM() internal view {
        require(
            msg.sender == stableCollBorrowerOperationsAddress ||
            msg.sender == stableCollTroveManagerAddress,
            "StableCollActivePool: Caller is neither BorrowerOperations nor TroveManager");
    }

    // This function is used to replace the commented-out fallback function to receive funds and apply
    // additional logics.
    function depositColl(uint _amount) external override { /* mark */
        _requireCallerIsBorrowerOperations();
        bool success = collToken.transferFrom(msg.sender, address(this), _amount);
        require(success, "StableCollActivePool: depositColl failed");
        ETH = ETH.add(_amount);
        emit StableCollActivePoolETHBalanceUpdated(ETH);
    } 

    // --- Fallback function ---
    // 
    // Fallback is often used for smart contract to receive Ether from other contracts and wallets.
    // In Polygon, this means receiving MATIC. To enable an ERC20 token as collateral, we don't need
    // this function anymore.
    //
    // receive() external payable {
    //     _requireCallerIsBorrowerOperationsOrDefaultPool();
    //     ETH = ETH.add(msg.value);
    //     emit ActivePoolETHBalanceUpdated(ETH);
    // }
}
