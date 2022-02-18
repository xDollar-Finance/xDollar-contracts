// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;

import './Interfaces/IDefaultPool.sol';
import './Interfaces/IActivePool.sol';
import "./Dependencies/IERC20.sol";
import "./Dependencies/SafeMath.sol";
import "./Dependencies/Ownable.sol";
import "./Dependencies/CheckContract.sol";
import "./Dependencies/console.sol";

/*
 * The Default Pool holds the ETH and LUSD debt (but not LUSD tokens) from liquidations that have been redistributed
 * to active troves but not yet "applied", i.e. not yet recorded on a recipient active trove's struct.
 *
 * When a trove makes an operation that applies its pending ETH and LUSD debt, its pending ETH and LUSD debt is moved
 * from the Default Pool to the Active Pool.
 */
contract DefaultPool is Ownable, CheckContract, IDefaultPool {
    using SafeMath for uint256;

    string constant public NAME = "DefaultPool";

    address public troveManagerAddress;
    address public activePoolAddress;
    uint256 internal ETH;  // deposited ETH tracker
    uint256 internal LUSDDebt;  // debt
    IERC20 public collToken;
    IActivePool activePool;

    enum Functions { SET_ADDRESS }  
    uint256 private constant _TIMELOCK = 2 days;
    mapping(Functions => uint256) public timelock;

    event TroveManagerAddressChanged(address _newTroveManagerAddress);
    event DefaultPoolLUSDDebtUpdated(uint _LUSDDebt);
    event DefaultPoolETHBalanceUpdated(uint _ETH);
    event CollTokenAddressUpdated(address _collTokenAddress);

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

    // --- Dependency setters ---

    function setAddresses(
        address _troveManagerAddress,
        address _activePoolAddress,
        address _collTokenAddress
    )
        external
        onlyOwner
        notLocked(Functions.SET_ADDRESS)
    {
        checkContract(_troveManagerAddress);
        checkContract(_activePoolAddress);
        checkContract(_collTokenAddress);

        troveManagerAddress = _troveManagerAddress;
        activePoolAddress = _activePoolAddress;
        collToken = IERC20(_collTokenAddress);
        activePool = IActivePool(_activePoolAddress);

        emit TroveManagerAddressChanged(_troveManagerAddress);
        emit ActivePoolAddressChanged(_activePoolAddress);
        emit CollTokenAddressUpdated(_collTokenAddress);

        _renounceOwnership();
        timelock[Functions.SET_ADDRESS] = 1;
    }

    // --- Getters for public variables. Required by IPool interface ---

    /*
    * Returns the ETH state variable.
    *
    * Not necessarily equal to the the contract's raw ETH balance - ether can be forcibly sent to contracts.
    */
    function getETH() external view override returns (uint) {
        return ETH;
    }

    function getLUSDDebt() external view override returns (uint) {
        return LUSDDebt;
    }

    // --- Pool functionality ---

    function sendETHToActivePool(uint _amount) external override {
        _requireCallerIsTroveManager();
        address cachedActivePoolAddress = activePoolAddress; // cache to save an SLOAD
        ETH = ETH.sub(_amount);
        emit DefaultPoolETHBalanceUpdated(ETH);
        emit EtherSent(cachedActivePoolAddress, _amount);

        bool success = collToken.approve(address(cachedActivePoolAddress), _amount);
        require(success, "DefaultPool: Can't approve active pool to use Collateral");
        activePool.depositColl(_amount);
    }

    function increaseLUSDDebt(uint _amount) external override {
        _requireCallerIsTroveManager();
        LUSDDebt = LUSDDebt.add(_amount);
        emit DefaultPoolLUSDDebtUpdated(LUSDDebt);
    }

    function decreaseLUSDDebt(uint _amount) external override {
        _requireCallerIsTroveManager();
        LUSDDebt = LUSDDebt.sub(_amount);
        emit DefaultPoolLUSDDebtUpdated(LUSDDebt);
    }

    // --- 'require' functions ---

    function _requireCallerIsActivePool() internal view {
        require(msg.sender == activePoolAddress, "DefaultPool: Caller is not the ActivePool");
    }

    function _requireCallerIsTroveManager() internal view {
        require(msg.sender == troveManagerAddress, "DefaultPool: Caller is not the TroveManager");
    }

    // This function is used to replace the commented-out fallback function to receive funds and apply
    // additional logics.
    function depositColl(uint _amount) external override {
        _requireCallerIsActivePool();
        bool success = collToken.transferFrom(msg.sender, address(this), _amount);
        require(success, "DefaultPool: receiveWETH failed");
        ETH = ETH.add(_amount);
        emit DefaultPoolETHBalanceUpdated(ETH);
    } 
}
