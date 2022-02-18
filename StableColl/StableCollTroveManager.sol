// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;

import "../Interfaces/IStableCollTroveManager.sol";
import "../Interfaces/ILUSDToken.sol";
import "../Interfaces/ILQTYToken.sol";
import "../Dependencies/LiquityBase.sol";
import "../Dependencies/Ownable.sol";
import "../Dependencies/CheckContract.sol";
import "../Dependencies/console.sol";
import "../Dependencies/BaseMath.sol";

contract StableCollTroveManager is LiquityBase, Ownable, CheckContract, IStableCollTroveManager {
    string constant public NAME = "StableCollTroveManager";

    // --- Connected contract declarations ---

    address public stableCollBorrowerOperationsAddress;

    ILUSDToken public override lusdToken;

    ILQTYToken public override lqtyToken;

    address public collTokenAddress;

    bool isAddressesSet = false;
    uint public debtCeilingPlus;
    uint private collDecimalAdjustment;

    enum Functions { SET_DEBT_CEILING }  
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

    // --- Data structures ---
    enum Status {
        nonExistent,
        active,
        closedByOwner
    }

    // Store the necessary data for a trove
    struct Trove {
        uint debt;
        uint coll;
        uint stake; /* To be removed */
        Status status;
        uint128 arrayIndex;
    }

    mapping (address => Trove) public Troves;

    // Array of all active trove addresses - used to to compute an approximate hint off-chain, for the sorted list insertion
    address[] public TroveOwners;

    struct ContractsCache {
        IStableCollActivePool stableCollActivePool;
        ILUSDToken lusdToken;
    }

    // --- Events ---
    event StableCollBorrowerOperationsAddressChanged(address _newStableCollBorrowerOperationsAddress);
    event LUSDTokenAddressChanged(address _newLUSDTokenAddress);
    event StableCollActivePoolAddressChanged(address _stableCollActivePoolAddress);
    event DebtCeilingPlusChanged(uint _debtCeilingPlus);


    // --- Dependency setter ---

    function setAddresses(
        address _stableCollBorrowerOperationsAddress,
        address _stableCollActivePoolAddress,
        address _lusdTokenAddress,
        address _collTokenAddress,
        uint _collDecimalAdjustment
    )
        external
        override
        onlyOwner
    {
        require(!isAddressesSet, "StableCollTroveManager: Addresses are already set!");
        isAddressesSet = true;

        checkContract(_stableCollBorrowerOperationsAddress);
        checkContract(_stableCollActivePoolAddress);
        checkContract(_lusdTokenAddress);

        stableCollBorrowerOperationsAddress = _stableCollBorrowerOperationsAddress;
        stableCollActivePool = IStableCollActivePool(_stableCollActivePoolAddress);
        lusdToken = ILUSDToken(_lusdTokenAddress);
        collTokenAddress = _collTokenAddress;
        collDecimalAdjustment = _collDecimalAdjustment;

        emit StableCollBorrowerOperationsAddressChanged(_stableCollBorrowerOperationsAddress);
        emit StableCollActivePoolAddressChanged(_stableCollActivePoolAddress);
        emit LUSDTokenAddressChanged(_lusdTokenAddress);
    }

    function setDebtCeilingPlus(uint _debtCeilingPlus) external onlyOwner notLocked(Functions.SET_DEBT_CEILING) {
        debtCeilingPlus = _debtCeilingPlus;

        emit DebtCeilingPlusChanged(_debtCeilingPlus);

        timelock[Functions.SET_DEBT_CEILING] = 1;
    }

    // --- Getters ---

    function getTroveOwnersCount() external view override returns (uint) {
        return TroveOwners.length;
    }

    function getTroveFromTroveOwnersArray(uint _index) external view override returns (address) {
        return TroveOwners[_index];
    }


    // Return the Troves entire debt and coll.
    function getEntireDebtAndColl(
        address _borrower
    )
        public
        view
        override
        returns (uint debt, uint coll)
    {
        debt = Troves[_borrower].debt;
        coll = Troves[_borrower].coll;
    }

    function closeTrove(address _borrower) external override {
        _requireCallerIsBorrowerOperations();
        return _closeTrove(_borrower, Status.closedByOwner);
    }

    function _closeTrove(address _borrower, Status closedStatus) internal {
        assert(closedStatus != Status.nonExistent && closedStatus != Status.active);

        uint TroveOwnersArrayLength = TroveOwners.length;
        _requireMoreThanOneTroveInSystem(TroveOwnersArrayLength);

        Troves[_borrower].status = closedStatus;
        Troves[_borrower].coll = 0;
        Troves[_borrower].debt = 0;

        _removeTroveOwner(_borrower, TroveOwnersArrayLength);
    }

    // Push the owner's address to the Trove owners list, and record the corresponding array index on the Trove struct
    function addTroveOwnerToArray(address _borrower) external override returns (uint index) {
        _requireCallerIsBorrowerOperations();
        return _addTroveOwnerToArray(_borrower);
    }

    function _addTroveOwnerToArray(address _borrower) internal returns (uint128 index) {
        /* Max array size is 2**128 - 1, i.e. ~3e30 troves. No risk of overflow, since troves have minimum LUSD
        debt of liquidation reserve plus MIN_NET_DEBT. 3e30 LUSD dwarfs the value of all wealth in the world ( which is < 1e15 USD). */

        // Push the Troveowner to the array
        TroveOwners.push(_borrower);

        // Record the index of the new Troveowner on their Trove struct
        index = uint128(TroveOwners.length.sub(1));
        Troves[_borrower].arrayIndex = index;

        return index;
    }

    /*
    * Remove a Trove owner from the TroveOwners array, not preserving array order. Removing owner 'B' does the following:
    * [A B C D E] => [A E C D], and updates E's Trove struct to point to its new array index.
    */
    function _removeTroveOwner(address _borrower, uint TroveOwnersArrayLength) internal {
        Status troveStatus = Troves[_borrower].status;
        // It’s set in caller function `_closeTrove`
        assert(troveStatus != Status.nonExistent && troveStatus != Status.active);

        uint128 index = Troves[_borrower].arrayIndex;
        uint length = TroveOwnersArrayLength;
        uint idxLast = length.sub(1);

        assert(index <= idxLast);

        address addressToMove = TroveOwners[idxLast];

        TroveOwners[index] = addressToMove;
        Troves[addressToMove].arrayIndex = index;
        emit TroveIndexUpdated(addressToMove, index);

        TroveOwners.pop();
    }

    // --- Recovery Mode and TCR functions ---

    function getTCR(uint _price) external view override returns (uint) {
        return _getTCR(_price, collDecimalAdjustment);
    }

    // --- Borrowing fee functions ---

    function getBorrowingRate() public view override returns (uint) { /* mark */
        return STABLE_COLL_BORROWING_RATE;
    }

    function getBorrowingFee(uint _LUSDDebt) external view override returns (uint) { /* mark */
        return _calcBorrowingFee(getBorrowingRate(), _LUSDDebt);
    }

    function _calcBorrowingFee(uint _borrowingRate, uint _LUSDDebt) internal pure returns (uint) { /* mark */
        return _borrowingRate.mul(_LUSDDebt).div(DECIMAL_PRECISION);
    }

    function getDebtCeiling() public view override returns (uint) { /* mark */
        return STABLE_COLL_DEBT_CEILING.add(debtCeilingPlus);
    }

    function getStableCollAmount(uint _LUSDDebt) public view override returns (uint) { /* mark */
        return _LUSDDebt.mul(STABLE_COLL_COLLATERAL_RARIO).div(DECIMAL_PRECISION).div(collDecimalAdjustment);
    }

    // --- 'require' wrapper functions ---

    function _requireCallerIsBorrowerOperations() internal view {
        require(msg.sender == stableCollBorrowerOperationsAddress, "StableCollTroveManager: Caller is not the BorrowerOperations contract");
    }

    function _requireTroveIsActive(address _borrower) internal view {
        require(Troves[_borrower].status == Status.active, "StableCollTroveManager: Trove does not exist or is closed");
    }

    function _requireLUSDBalanceCoversRedemption(ILUSDToken _lusdToken, address _redeemer, uint _amount) internal view {
        require(_lusdToken.balanceOf(_redeemer) >= _amount, "StableCollTroveManager: Requested redemption amount must be <= user's LUSD token balance");
    }

    function _requireMoreThanOneTroveInSystem(uint TroveOwnersArrayLength) internal view {
        require (TroveOwnersArrayLength > 1, "StableCollTroveManager: Only one trove in the system");
    }

    function _requireAmountGreaterThanZero(uint _amount) internal pure {
        require(_amount > 0, "StableCollTroveManager: Amount must be greater than zero");
    }

    function _requireTCRoverMCR(uint _price) internal view {
        require(_getTCR(_price, collDecimalAdjustment) >= MCR, "StableCollTroveManager: Cannot redeem when TCR < MCR");
    }

    // --- Trove property getters ---

    function getTroveStatus(address _borrower) external view override returns (uint) { /* mark */
        return uint(Troves[_borrower].status);
    }

    function getTroveDebt(address _borrower) external view override returns (uint) {
        return Troves[_borrower].debt;
    }

    function getTroveColl(address _borrower) external view override returns (uint) {
        return Troves[_borrower].coll;
    }

    // --- Trove property setters, called by BorrowerOperations ---

    function setTroveStatus(address _borrower, uint _num) external override { /* mark */
        _requireCallerIsBorrowerOperations();
        Troves[_borrower].status = Status(_num);
    }

    function increaseTroveColl(address _borrower, uint _collIncrease) external override returns (uint) {
        _requireCallerIsBorrowerOperations();
        uint newColl = Troves[_borrower].coll.add(_collIncrease);
        Troves[_borrower].coll = newColl;
        return newColl;
    }

    function decreaseTroveColl(address _borrower, uint _collDecrease) external override returns (uint) {
        _requireCallerIsBorrowerOperations();
        uint newColl = Troves[_borrower].coll.sub(_collDecrease);
        Troves[_borrower].coll = newColl;
        return newColl;
    }

    function increaseTroveDebt(address _borrower, uint _debtIncrease) external override returns (uint) {
        _requireCallerIsBorrowerOperations();
        uint newDebt = Troves[_borrower].debt.add(_debtIncrease);
        Troves[_borrower].debt = newDebt;
        return newDebt;
    }

    function decreaseTroveDebt(address _borrower, uint _debtDecrease) external override returns (uint) {
        _requireCallerIsBorrowerOperations();
        uint newDebt = Troves[_borrower].debt.sub(_debtDecrease);
        Troves[_borrower].debt = newDebt;
        return newDebt;
    }
}