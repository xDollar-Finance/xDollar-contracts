// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;

import "../Interfaces/IStableCollActivePool.sol";
import "../Interfaces/IStableCollBorrowerOperations.sol";
import "../Interfaces/IStableCollTroveManager.sol";
import "../Interfaces/ILUSDToken.sol";
import "../Dependencies/LiquityBase.sol";
import "../Dependencies/Ownable.sol";
import "../Dependencies/CheckContract.sol";
import "../Dependencies/console.sol";

contract StableCollBorrowerOperations is LiquityBase, Ownable, CheckContract, IStableCollBorrowerOperations {
    string constant public NAME = "StableCollBorrowerOperations";

    // --- Connected contract declarations ---

    IStableCollTroveManager public stableCollTroveManager;

    address public borrowingFeePool;

    ILUSDToken public LUSDToken;
    IERC20 public collToken;
    bool isAddressesSet = false;
    uint private collDecimalAdjustment;

    enum Functions { SET_BORROWING_FEE_POOL }  
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

    /* --- Variable container structs  ---

    Used to hold, return and assign variables inside a function, in order to avoid the error:
    "CompilerError: Stack too deep". */

     struct LocalVariables_adjustTrove {
        uint stableCollChange;
        uint collChange;
        uint netDebtChange;
        bool isCollIncrease;
        uint debt;
        uint coll;
        uint newICR;
        uint LUSDFee;
        uint newDebt;
        uint newColl;
        uint debtCeiling;
    }

    struct LocalVariables_openTrove {
        uint LUSDFee;
        uint stableCollAmount;
        uint netDebt;
        uint arrayIndex;
        uint debtCeiling;
    }

    struct ContractsCache {
        IStableCollTroveManager stableCollTroveManager;
        IStableCollActivePool stableCollActivePool;
        ILUSDToken LUSDToken;
    }

    enum BorrowerOperation {
        openTrove,
        closeTrove,
        adjustTrove
    }

    event StableCollTroveManagerAddressChanged(address _newStableCollTroveManagerAddress);
    event StableCollActivePoolAddressChanged(address _stableCollActivePoolAddress);
    event CollTokenAddressChanged(address _collTokenAddress);
    event BorrowingFeePoolChanged(address _borrowingFeePool);

    event TroveCreated(address indexed _borrower, uint arrayIndex);
    event TroveUpdated(address indexed _borrower, uint _debt, uint _coll, BorrowerOperation operation);
    event LUSDBorrowingFeePaid(address indexed _borrower, uint _LUSDFee);
    
    // --- Dependency setters ---

    function setAddresses(
        address _stableCollTroveManagerAddress,
        address _stableCollActivePoolAddress,
        address _LUSDTokenAddress,
        address _collTokenAddress,
        uint _collDecimalAdjustment
    )
        external
        override
        onlyOwner
    {
        require(!isAddressesSet, "StableCollBorrowerOperations: Addresses are already set!");
        isAddressesSet = true;

        // This makes impossible to open a trove with zero withdrawn LUSD
        assert(MIN_NET_DEBT > 0);

        checkContract(_stableCollTroveManagerAddress);
        checkContract(_stableCollActivePoolAddress);
        checkContract(_LUSDTokenAddress);
        checkContract(_collTokenAddress);

        stableCollTroveManager = IStableCollTroveManager(_stableCollTroveManagerAddress);
        stableCollActivePool = IStableCollActivePool(_stableCollActivePoolAddress);
        LUSDToken = ILUSDToken(_LUSDTokenAddress);
        collToken = IERC20(_collTokenAddress);

        emit StableCollTroveManagerAddressChanged(_stableCollTroveManagerAddress);
        emit StableCollActivePoolAddressChanged(_stableCollActivePoolAddress);
        emit CollTokenAddressChanged(_collTokenAddress);

        collDecimalAdjustment = _collDecimalAdjustment;
    }

    function setBorrowingFeePool(address _borrowingFeePool) external onlyOwner notLocked(Functions.SET_BORROWING_FEE_POOL) {
        borrowingFeePool = _borrowingFeePool;

        emit BorrowingFeePoolChanged(_borrowingFeePool);

        timelock[Functions.SET_BORROWING_FEE_POOL] = 1;
    }

    // --- Borrower Trove Operations ---

    function openTrove(uint _LUSDAmount) external override {
        // Replace payable with an explicit token transfer.

        _LUSDAmount = _LUSDAmount.div(collDecimalAdjustment).div(STABLE_COLL_COLLATERAL_RARIO_DIVISOR).mul(STABLE_COLL_COLLATERAL_RARIO_DIVISOR).mul(collDecimalAdjustment);

        ContractsCache memory contractsCache = ContractsCache(stableCollTroveManager, stableCollActivePool, LUSDToken);
        LocalVariables_openTrove memory vars;
        vars.stableCollAmount = _getStableCollAmount(_LUSDAmount);
        require(collToken.transferFrom(msg.sender, address(this), vars.stableCollAmount), "StableCollBorrowerOperations: Collateral transfer failed on openTrove");  

        _requireTroveisNotActive(contractsCache.stableCollTroveManager, msg.sender);

        vars.LUSDFee = _triggerBorrowingFee(contractsCache.stableCollTroveManager, contractsCache.LUSDToken, _LUSDAmount);
        vars.netDebt = _LUSDAmount.add(vars.LUSDFee);
        vars.debtCeiling = contractsCache.stableCollTroveManager.getDebtCeiling();

        _requireAtLeastMinNetDebt(vars.netDebt);
        _requireActivePoolDebtBelowDebtCeiling(vars.netDebt, getEntireSystemStableDebt(), vars.debtCeiling);   

        // Set the trove struct's properties
        contractsCache.stableCollTroveManager.setTroveStatus(msg.sender, 1);
        contractsCache.stableCollTroveManager.increaseTroveColl(msg.sender, vars.stableCollAmount);
        contractsCache.stableCollTroveManager.increaseTroveDebt(msg.sender, vars.netDebt);

        vars.arrayIndex = contractsCache.stableCollTroveManager.addTroveOwnerToArray(msg.sender);
        emit TroveCreated(msg.sender, vars.arrayIndex);

        // Move the ether to the Active Pool, and mint the LUSDAmount to the borrower
        _activePoolAddColl(contractsCache.stableCollActivePool, vars.stableCollAmount);
        _withdrawLUSD(contractsCache.stableCollActivePool, contractsCache.LUSDToken, msg.sender, _LUSDAmount, vars.netDebt);

        emit TroveUpdated(msg.sender, vars.netDebt, vars.stableCollAmount, BorrowerOperation.openTrove);
        emit LUSDBorrowingFeePaid(msg.sender, vars.LUSDFee);
    }

    // Send ETH as collateral to a trove
    function addColl(uint _StableCollAmount) external override {
        // Replace payable with an explicit token transfer.

        //route coll amount to be divisorable by 101
        _StableCollAmount = _StableCollAmount.div(STABLE_COLL_COLLATERAL_RARIO_DIVIDEND).mul(STABLE_COLL_COLLATERAL_RARIO_DIVIDEND);        
        require(collToken.transferFrom(msg.sender, address(this), _StableCollAmount), 
                "StableCollBorrowerOps: Collateral transfer failed on adjustTrove");
        _adjustTrove(msg.sender, _StableCollAmount.mul(collDecimalAdjustment).div(STABLE_COLL_COLLATERAL_RARIO), true);
    }

    // Withdraw ETH collateral from a trove
    function withdrawColl(uint _StableCollAmount) external override {
        
        //route coll amount to be divisorable by 101        
        _StableCollAmount = _StableCollAmount.div(STABLE_COLL_COLLATERAL_RARIO_DIVIDEND).mul(STABLE_COLL_COLLATERAL_RARIO_DIVIDEND);
        _adjustTrove(msg.sender, _StableCollAmount, false);
    }

    // Withdraw LUSD tokens from a trove: mint new LUSD tokens to the owner, and increase the trove's debt accordingly
    function withdrawLUSD(uint _LUSDAmount) external override {

        //route coll amount to be divisorable by 100                
        _LUSDAmount = _LUSDAmount.div(collDecimalAdjustment).div(STABLE_COLL_COLLATERAL_RARIO_DIVISOR).mul(STABLE_COLL_COLLATERAL_RARIO_DIVISOR).mul(collDecimalAdjustment);
        require(collToken.transferFrom(msg.sender, address(this), _getStableCollAmount(_LUSDAmount)), 
                "StableCollBorrowerOps: Collateral transfer failed on adjustTrove");        
        _adjustTrove(msg.sender, _LUSDAmount, true);
    }

    // Repay LUSD tokens to a Trove: Burn the repaid LUSD tokens, and reduce the trove's debt accordingly
    function repayLUSD(uint _LUSDAmount) external override {

        //route coll amount to be divisorable by 100                        
        _LUSDAmount = _LUSDAmount.div(collDecimalAdjustment).div(STABLE_COLL_COLLATERAL_RARIO_DIVISOR).mul(STABLE_COLL_COLLATERAL_RARIO_DIVISOR).mul(collDecimalAdjustment);
        _adjustTrove(msg.sender, _LUSDAmount, false);
    }

    function adjustTrove(uint _LUSDChange, bool _isDebtIncrease) external override {
        // Replace payable with an explicit token transfer.

        //route coll amount to be divisorable by 100                                
        _LUSDChange = _LUSDChange.div(collDecimalAdjustment).div(STABLE_COLL_COLLATERAL_RARIO_DIVISOR).mul(STABLE_COLL_COLLATERAL_RARIO_DIVISOR).mul(collDecimalAdjustment);
        if (_isDebtIncrease) {
            require(collToken.transferFrom(msg.sender, address(this), _getStableCollAmount(_LUSDChange)), 
                    "StableCollBorrowerOps: Collateral transfer failed on adjustTrove");
        }
        _adjustTrove(msg.sender, _LUSDChange, _isDebtIncrease);
    }

    /*
    * _adjustTrove(): Alongside a debt change, this function can perform either a collateral top-up or a collateral withdrawal. 
    *
    * It therefore expects either a positive _StableCollAmount, or a positive _collWithdrawal argument.
    *
    * If both are positive, it will revert.
    */
    function _adjustTrove(address _borrower, uint _LUSDChange, bool _isDebtIncrease) internal {
        ContractsCache memory contractsCache = ContractsCache(stableCollTroveManager, stableCollActivePool, LUSDToken);
        LocalVariables_adjustTrove memory vars;

        _requireNonZeroDebtChange(_LUSDChange);

        if (_isDebtIncrease) {
            vars.collChange = _getStableCollAmount(_LUSDChange);
            vars.isCollIncrease =  true;
        } else {
            vars.collChange = _LUSDChange.div(collDecimalAdjustment);
            vars.isCollIncrease =  false;
        }

        _requireTroveisActive(contractsCache.stableCollTroveManager, _borrower);

        // Confirm the operation is a borrower adjusting their own trove.
        assert(msg.sender == _borrower);

        vars.debtCeiling = contractsCache.stableCollTroveManager.getDebtCeiling();

        vars.netDebtChange = _LUSDChange;

        // If the adjustment incorporates a debt increase and system is in Normal Mode, then trigger a borrowing fee
        if (_isDebtIncrease) { 
            vars.LUSDFee = _triggerBorrowingFee(contractsCache.stableCollTroveManager, contractsCache.LUSDToken, _LUSDChange);
            vars.netDebtChange = vars.netDebtChange.add(vars.LUSDFee); // The raw debt change includes the fee
            _requireActivePoolDebtBelowDebtCeiling(vars.netDebtChange, getEntireSystemStableDebt(), vars.debtCeiling);
        }

        vars.debt = contractsCache.stableCollTroveManager.getTroveDebt(_borrower);
        vars.coll = contractsCache.stableCollTroveManager.getTroveColl(_borrower);

        if (!_isDebtIncrease) {
            assert(vars.collChange <= vars.coll); 
        }

        // Get the trove's old ICR before the adjustment, and what its new ICR will be after the adjustment
        (vars.newColl, vars.newDebt, vars.newICR) = _getNewICRFromTroveChange(vars.coll, vars.debt, vars.collChange, vars.isCollIncrease, vars.netDebtChange, _isDebtIncrease, 1e18 /* price */);

        // Check the adjustment satisfies all conditions
        _requireValidAdjustment(_isDebtIncrease, vars);
            
        // When the adjustment is a debt repayment, check it's a valid amount and that the caller has enough LUSD
        if (!_isDebtIncrease) {
            _requireValidLUSDRepayment(vars.debt, vars.netDebtChange);
            _requireAtLeastMinNetDebt(vars.debt.sub(vars.netDebtChange));
            _requireSufficientLUSDBalance(contractsCache.LUSDToken, _borrower, vars.netDebtChange);
        }

        (vars.newColl, vars.newDebt) = _updateTroveFromAdjustment(contractsCache.stableCollTroveManager, _borrower, vars.collChange, vars.isCollIncrease, vars.netDebtChange, _isDebtIncrease);

        emit TroveUpdated(_borrower, vars.newDebt, vars.newColl, BorrowerOperation.adjustTrove);
        emit LUSDBorrowingFeePaid(msg.sender,  vars.LUSDFee);

        // Use the unmodified _LUSDChange here, as we don't send the fee to the user
        _moveTokensAndETHfromAdjustment(
            contractsCache.stableCollActivePool,
            contractsCache.LUSDToken,
            msg.sender,
            vars.collChange,
            vars.isCollIncrease,
            _LUSDChange,
            _isDebtIncrease,
            vars.netDebtChange
        );
    }

    function closeTrove() external override {
        IStableCollTroveManager stableCollTroveManagerCached = stableCollTroveManager;
        IStableCollActivePool stableCollActivePoolCached = stableCollActivePool;
        ILUSDToken LUSDTokenCached = LUSDToken;

        _requireTroveisActive(stableCollTroveManagerCached, msg.sender);

        uint coll = stableCollTroveManagerCached.getTroveColl(msg.sender);
        uint debt = stableCollTroveManagerCached.getTroveDebt(msg.sender);

        _requireSufficientLUSDBalance(LUSDTokenCached, msg.sender, debt);

        (uint totalColl, uint totalDebt, uint newTCR) = _getNewTCRFromTroveChange(coll, false, debt, false, 1e18 /* price */);
        _requireNewTCREqualsToMSCR(totalColl, totalDebt, newTCR);

        stableCollTroveManagerCached.closeTrove(msg.sender);

        emit TroveUpdated(msg.sender, 0, 0, BorrowerOperation.closeTrove);

        // Burn the repaid LUSD from the user's balance and the gas compensation from the Gas Pool
        _repayLUSD(stableCollActivePoolCached, LUSDTokenCached, msg.sender, debt);

        // Send the collateral back to the user
        stableCollActivePoolCached.sendETH(msg.sender, coll);
    }

    // --- Helper functions ---

    function _triggerBorrowingFee(IStableCollTroveManager _stableCollTroveManager, ILUSDToken _LUSDToken, uint _LUSDAmount) internal returns (uint) {
        uint LUSDFee = _stableCollTroveManager.getBorrowingFee(_LUSDAmount);
        _LUSDToken.mint(borrowingFeePool, LUSDFee);

        return LUSDFee;
    }

    function _getUSDValue(uint _coll, uint _price) internal view returns (uint) {
        uint usdValue = _price.mul(_coll).mul(collDecimalAdjustment).div(DECIMAL_PRECISION);

        return usdValue;
    }

    function _getCollChange(
        uint _collReceived,
        uint _requestedCollWithdrawal
    )
        internal
        pure
        returns(uint collChange, bool isCollIncrease)
    {
        if (_collReceived != 0) {
            collChange = _collReceived;
            isCollIncrease = true;
        } else {
            collChange = _requestedCollWithdrawal;
        }
    }

    // Update trove's coll and debt based on whether they increase or decrease
    function _updateTroveFromAdjustment
    (
        IStableCollTroveManager _troveManager,
        address _borrower,
        uint _collChange,
        bool _isCollIncrease,
        uint _debtChange,
        bool _isDebtIncrease
    )
        internal
        returns (uint, uint)
    {
        uint newColl = (_isCollIncrease) ? _troveManager.increaseTroveColl(_borrower, _collChange)
                                        : _troveManager.decreaseTroveColl(_borrower, _collChange);
        uint newDebt = (_isDebtIncrease) ? _troveManager.increaseTroveDebt(_borrower, _debtChange)
                                        : _troveManager.decreaseTroveDebt(_borrower, _debtChange);

        return (newColl, newDebt);
    }

    function _moveTokensAndETHfromAdjustment
    (
        IStableCollActivePool _activePool,
        ILUSDToken _LUSDToken,
        address _borrower,
        uint _collChange,
        bool _isCollIncrease,
        uint _LUSDChange,
        bool _isDebtIncrease,
        uint _netDebtChange
    )
        internal
    {
        if (_isDebtIncrease) {
            _withdrawLUSD(_activePool, _LUSDToken, _borrower, _LUSDChange, _netDebtChange);
        } else {
            _repayLUSD(_activePool, _LUSDToken, _borrower, _LUSDChange);
        }

        if (_isCollIncrease) {
            _activePoolAddColl(_activePool, _collChange);
        } else {
            _activePool.sendETH(_borrower, _collChange);
        }
    }

    // Send ETH to Active Pool and increase its recorded ETH balance
    function _activePoolAddColl(IStableCollActivePool _activePool, uint _amount) internal {
        uint256 allowance = collToken.allowance(address(this), address(_activePool));
        if (allowance < _amount) {
            bool success = collToken.approve(address(_activePool), type(uint256).max);
            require(success, "StableCollBorrowerOperations: Cannot approve ActivePool to spend collateral");
        }
        _activePool.depositColl(_amount);
    }

    // Issue the specified amount of LUSD to _account and increases the total active debt (_netDebtIncrease potentially includes a LUSDFee)
    function _withdrawLUSD(IStableCollActivePool _activePool, ILUSDToken _LUSDToken, address _account, uint _LUSDAmount, uint _netDebtIncrease) internal {
        _activePool.increaseLUSDDebt(_netDebtIncrease);
        _LUSDToken.mint(_account, _LUSDAmount);
    }

    // Burn the specified amount of LUSD from _account and decreases the total active debt
    function _repayLUSD(IStableCollActivePool _activePool, ILUSDToken _LUSDToken, address _account, uint _LUSD) internal {
        _activePool.decreaseLUSDDebt(_LUSD);
        _LUSDToken.burn(_account, _LUSD);
    }

    // --- 'Require' wrapper functions ---

    function _requireSingularCollChange(uint _WETHAmount, uint _collWithdrawal) internal view {
        require(_WETHAmount == 0 || _collWithdrawal == 0, "StableCollBorrowerOperations: Cannot withdraw and add coll");
    }

    function _requireCallerIsBorrower(address _borrower) internal view {
        require(msg.sender == _borrower, "StableCollBorrowerOps: Caller must be the borrower for a withdrawal");
    }

    function _requireNonZeroAdjustment(uint _WETHAmount, uint _collWithdrawal, uint _LUSDChange) internal view {
        require(_WETHAmount != 0 || _collWithdrawal != 0 || _LUSDChange != 0, "StableCollBorrowerOps: There must be either a collateral change or a debt change");
    }

    function _requireTroveisActive(IStableCollTroveManager _troveManager, address _borrower) internal view {
        uint status = _troveManager.getTroveStatus(_borrower);
        require(status == 1, "StableCollBorrowerOps: Trove does not exist or is closed");
    }

    function _requireTroveisNotActive(IStableCollTroveManager _troveManager, address _borrower) internal view {
        uint status = _troveManager.getTroveStatus(_borrower);
        require(status != 1, "StableCollBorrowerOps: Trove is active");
    }

    function _requireNonZeroDebtChange(uint _LUSDChange) internal pure {
        require(_LUSDChange > 0, "StableCollBorrowerOps: Debt increase requires non-zero debtChange");
    }
   
    function _requireNotInRecoveryMode(uint _price) internal view {
        require(!_checkRecoveryMode(_price, collDecimalAdjustment), "StableCollBorrowerOps: Operation not permitted during Recovery Mode");
    }

    function _requireNoCollWithdrawal(uint _collWithdrawal) internal pure {
        require(_collWithdrawal == 0, "StableCollBorrowerOps: Collateral withdrawal not permitted Recovery Mode");
    }

    function _requireValidAdjustment
    (
        bool _isDebtIncrease, 
        LocalVariables_adjustTrove memory _vars
    ) 
        internal 
        view 
    {
        /* 
        * Ensure:
        *
        * - The new ICR is above MCR
        * - The adjustment won't pull the TCR below CCR
        */
        _requireICREqualsToMSCR(_vars.newColl, _vars.newDebt, _vars.newICR);
        (uint totalColl, uint totalDebt, uint newTCR) = _getNewTCRFromTroveChange(_vars.collChange, _vars.isCollIncrease, _vars.netDebtChange, _isDebtIncrease, 1e18 /* price */);
        _requireNewTCREqualsToMSCR(totalColl, totalDebt, newTCR);  
    }

    function _requireICREqualsToMSCR(uint _newColl, uint _newDebt, uint _newICR) internal pure {
        require((_newColl == 0 && _newDebt == 0) || _newICR == MSCR, "StableCollBorrowerOps: An operation that would result in ICR != MSCR is not permitted");
    }

    function _requireICRisAboveCCR(uint _newICR) internal pure {
        require(_newICR >= CCR, "StableCollBorrowerOps: Operation must leave trove with ICR >= CCR");
    }

    function _requireNewICRisAboveOldICR(uint _newICR, uint _oldICR) internal pure {
        require(_newICR >= _oldICR, "StableCollBorrowerOps: Cannot decrease your Trove's ICR in Recovery Mode");
    }

        function _requireNewTCREqualsToMSCR(uint _totalColl, uint _totalDebt, uint _newTCR) internal pure {
        require((_totalColl == 0 && _totalDebt == 0) || _newTCR == MSCR, "StableCollBorrowerOps: An operation that would result in TCR != MSCR is not permitted");
    }

    function _requireAtLeastMinNetDebt(uint _netDebt) internal pure {
        require (_netDebt >= MIN_NET_DEBT, "StableCollBorrowerOps: Trove's net debt must be greater than minimum");
    }

    function _requireActivePoolDebtBelowDebtCeiling(uint _netDebt, uint _activePoolLUSDDebt, uint _debtCeiling) internal pure {
        require (_netDebt.add( _activePoolLUSDDebt) <= _debtCeiling, "StableCollBorrowerOps: Trove's net debt must be less than debt ceiling");
    }

    function _requireValidLUSDRepayment(uint _currentDebt, uint _debtRepayment) internal pure {
        require(_debtRepayment <= _currentDebt, "StableCollBorrowerOps: Amount repaid must not be larger than the Trove's debt");
    }

     function _requireSufficientLUSDBalance(ILUSDToken _LUSDToken, address _borrower, uint _debtRepayment) internal view {
        require(_LUSDToken.balanceOf(_borrower) >= _debtRepayment, "StableCollBorrowerOps: Caller doesnt have enough LUSD to make repayment");
    }

    function _requireValidMaxFeePercentage(uint _maxFeePercentage, bool _isRecoveryMode) internal pure {
        if (_isRecoveryMode) {
            require(_maxFeePercentage <= DECIMAL_PRECISION,
                "Max fee percentage must less than or equal to 100%");
        } else {
            require(_maxFeePercentage >= BORROWING_FEE_FLOOR && _maxFeePercentage <= DECIMAL_PRECISION,
                "Max fee percentage must be between 0.5% and 100%");
        }
    }

    // --- ICR and TCR getters ---

    // Compute the new collateral ratio, considering the change in coll and debt. Assumes 0 pending rewards.
    function _getNewNominalICRFromTroveChange
    (
        uint _coll,
        uint _debt,
        uint _collChange,
        bool _isCollIncrease,
        uint _debtChange,
        bool _isDebtIncrease
    )
        view
        internal
        returns (uint)
    {
        (uint newColl, uint newDebt) = _getNewTroveAmounts(_coll, _debt, _collChange, _isCollIncrease, _debtChange, _isDebtIncrease);

        uint newNICR = LiquityMath._computeNominalCR(newColl, newDebt, collDecimalAdjustment);
        return newNICR;
    }

    // Compute the new collateral ratio, considering the change in coll and debt. Assumes 0 pending rewards.
    function _getNewICRFromTroveChange
    (
        uint _coll,
        uint _debt,
        uint _collChange,
        bool _isCollIncrease,
        uint _debtChange,
        bool _isDebtIncrease,
        uint _price
    )
        view
        internal
        returns (uint, uint, uint)
    {
        (uint newColl, uint newDebt) = _getNewTroveAmounts(_coll, _debt, _collChange, _isCollIncrease, _debtChange, _isDebtIncrease);

        uint newICR = LiquityMath._computeCR(newColl, newDebt, _price, collDecimalAdjustment);
        return (newColl, newDebt, newICR);
    }

    function _getNewTroveAmounts(
        uint _coll,
        uint _debt,
        uint _collChange,
        bool _isCollIncrease,
        uint _debtChange,
        bool _isDebtIncrease
    )
        internal
        pure
        returns (uint, uint)
    {
        uint newColl = _coll;
        uint newDebt = _debt;

        newColl = _isCollIncrease ? _coll.add(_collChange) :  _coll.sub(_collChange);
        newDebt = _isDebtIncrease ? _debt.add(_debtChange) : _debt.sub(_debtChange);

        return (newColl, newDebt);
    }

    function _getNewTCRFromTroveChange
    (
        uint _collChange,
        bool _isCollIncrease,
        uint _debtChange,
        bool _isDebtIncrease,
        uint _price
    )
        internal
        view
        returns (uint, uint, uint)
    {
        uint totalColl = getEntireSystemStableColl();
        uint totalDebt = getEntireSystemStableDebt();

        totalColl = _isCollIncrease ? totalColl.add(_collChange) : totalColl.sub(_collChange);
        totalDebt = _isDebtIncrease ? totalDebt.add(_debtChange) : totalDebt.sub(_debtChange);

        uint newTCR = LiquityMath._computeCR(totalColl, totalDebt, _price, collDecimalAdjustment);
        return (totalColl, totalDebt, newTCR);
    }

    function getCompositeDebt(uint _debt) external pure override returns (uint) {
        return _getCompositeDebt(_debt);
    }
    
    function _getStableCollAmount(uint _LUSDDebt) internal view returns (uint) {
        return _LUSDDebt.mul(STABLE_COLL_COLLATERAL_RARIO).div(DECIMAL_PRECISION).div(collDecimalAdjustment);
    }
}