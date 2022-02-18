// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;

import './Interfaces/IActivePool.sol';
import "./Interfaces/ICollSurplusPool.sol";
import "./Interfaces/IDefaultPool.sol";
import "./Interfaces/IFeeForwarder.sol";
import "./Interfaces/IStabilityPool.sol";
import "./Dependencies/IERC20.sol";
import "./Dependencies/SafeMath.sol";
import "./Dependencies/Ownable.sol";
import "./Dependencies/CheckContract.sol";
import "./Dependencies/console.sol";

/*
 * The Active Pool holds the ETH collateral and LUSD debt (but not LUSD tokens) for all active troves.
 *
 * When a trove is liquidated, it's ETH and LUSD debt are transferred from the Active Pool, to either the
 * Stability Pool, the Default Pool, or both, depending on the liquidation conditions.
 *
 */
contract ActivePool is Ownable, CheckContract, IActivePool {
    using SafeMath for uint256;

    string constant public NAME = "ActivePool";

    address public borrowerOperationsAddress;
    address public troveManagerAddress;
    address public stabilityPoolAddress;
    address public collSurplusPoolAddress;
    address public defaultPoolAddress;
    uint256 internal ETH;  // deposited ether tracker
    uint256 internal LUSDDebt;

    enum Functions { SET_ADDRESS }  
    uint256 private constant _TIMELOCK = 2 days;
    mapping(Functions => uint256) public timelock;

    ICollSurplusPool collSurplusPool;
    IStabilityPool stabilityPool;
    IDefaultPool defaultPool;
    IERC20 public collToken;


    // --- Events ---

    event BorrowerOperationsAddressChanged(address _newBorrowerOperationsAddress);
    event TroveManagerAddressChanged(address _newTroveManagerAddress);
    event DefaultPoolAddressChanged(address _defaultPoolAddress);
    event StabilityPoolAddressChanged(address _stabilityPoolAddress);    
    event CollSurplusPoolAddressChanged(address _collSurplusPoolAddress);
    event ActivePoolLUSDDebtUpdated(uint _LUSDDebt);
    event ActivePoolETHBalanceUpdated(uint _ETH);
    event WETHAddressChanged(address _collTokenAddress);

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

    // --- Contract setters ---

    function setAddresses(
        address _borrowerOperationsAddress,
        address _troveManagerAddress,
        address _stabilityPoolAddress,
        address _defaultPoolAddress,
        address _collSurplusPoolAddress,
        address _collTokenAddress
    )
        external
        onlyOwner 
        notLocked(Functions.SET_ADDRESS)
    {
        checkContract(_borrowerOperationsAddress);
        checkContract(_troveManagerAddress);
        checkContract(_stabilityPoolAddress);
        checkContract(_defaultPoolAddress);
        checkContract(_collSurplusPoolAddress);

        borrowerOperationsAddress = _borrowerOperationsAddress;
        troveManagerAddress = _troveManagerAddress;
        stabilityPoolAddress = _stabilityPoolAddress;
        defaultPoolAddress = _defaultPoolAddress;
        collSurplusPoolAddress = _collSurplusPoolAddress;
        defaultPool = IDefaultPool(_defaultPoolAddress);
        collSurplusPool = ICollSurplusPool(_collSurplusPoolAddress);
        stabilityPool = IStabilityPool(_stabilityPoolAddress);
        collToken = IERC20(_collTokenAddress);


        emit BorrowerOperationsAddressChanged(_borrowerOperationsAddress);
        emit TroveManagerAddressChanged(_troveManagerAddress);
        emit StabilityPoolAddressChanged(_stabilityPoolAddress);
        emit CollSurplusPoolAddressChanged(_collSurplusPoolAddress);
        emit DefaultPoolAddressChanged(_defaultPoolAddress);
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
        _requireCallerIsBOorTroveMorSP();
        ETH = ETH.sub(_amount);
        emit ActivePoolETHBalanceUpdated(ETH);
        emit EtherSent(_account, _amount);
        if ( _account == stabilityPoolAddress ) {
            bool success = collToken.approve(address(_account), type(uint256).max);
            require(success, "BorrowerOperations: Cannot approve StabilityPool to spend collateral");
            stabilityPool.depositColl(_amount);
        } else if ( _account == defaultPoolAddress) {
            bool success = collToken.approve(address(_account), type(uint256).max);
            require(success, "BorrowerOperations: Cannot approve DefaultPool to spend collateral");
            defaultPool.depositColl(_amount);
        } else if (_account == collSurplusPoolAddress) {
            bool success = collToken.approve(address(_account), type(uint256).max);
            require(success, "BorrowerOperations: Cannot approve CollSurplusPool to spend collateral");
            collSurplusPool.depositColl(_amount);
        } else {
            bool success = collToken.transfer(_account, _amount);
            require(success, "ActivePool: User sending ETH failed");
        }
    }

    function notifyFee(address _feeForwarderAddress, uint _amount) external override {
        _requireCallerIsTroveManager();
        bool success = collToken.approve(_feeForwarderAddress, _amount);
        require(success, "ActivePool: Cannot approve FeeForwarder to spend collateral");
        IFeeForwarder(_feeForwarderAddress).poolNotifyFixedTarget(address(collToken), _amount);
    }

    function increaseLUSDDebt(uint _amount) external override {
        _requireCallerIsBOorTroveM();
        LUSDDebt  = LUSDDebt.add(_amount);
        ActivePoolLUSDDebtUpdated(LUSDDebt);
    }

    function decreaseLUSDDebt(uint _amount) external override {
        _requireCallerIsBOorTroveMorSP();
        LUSDDebt = LUSDDebt.sub(_amount);
        ActivePoolLUSDDebtUpdated(LUSDDebt);
    }

    // --- 'require' functions ---

    function _requireCallerIsBorrowerOperationsOrDefaultPool() internal view {
        require(
            msg.sender == borrowerOperationsAddress ||
            msg.sender == defaultPoolAddress,
            "ActivePool: Caller is neither BO nor Default Pool");
    }

    function _requireCallerIsBOorTroveMorSP() internal view {
        require(
            msg.sender == borrowerOperationsAddress ||
            msg.sender == troveManagerAddress ||
            msg.sender == stabilityPoolAddress,
            "ActivePool: Caller is neither BorrowerOperations nor TroveManager nor StabilityPool");
    }

    function _requireCallerIsBOorTroveM() internal view {
        require(
            msg.sender == borrowerOperationsAddress ||
            msg.sender == troveManagerAddress,
            "ActivePool: Caller is neither BorrowerOperations nor TroveManager");
    }

    function _requireCallerIsTroveManager() internal view {
        require(
            msg.sender == troveManagerAddress,
            "ActivePool: Caller is not TroveManager");
    }

    // This function is used to replace the commented-out fallback function to receive funds and apply	
    // additional logics.	
    function depositColl(uint _amount) external override {	
        _requireCallerIsBorrowerOperationsOrDefaultPool();	
        bool success = collToken.transferFrom(msg.sender, address(this), _amount);	
        require(success, "ActivePool: depositColl failed");	
        ETH = ETH.add(_amount);	
        emit ActivePoolETHBalanceUpdated(ETH);	
    }
}
