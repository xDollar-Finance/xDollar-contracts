// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;

// Common interface for the Trove Manager.
interface IBorrowerOperations {

    // --- Events ---

    event TroveManagerAddressChanged(address _newTroveManagerAddress);
    event ActivePoolAddressChanged(address _activePoolAddress);
    event DefaultPoolAddressChanged(address _defaultPoolAddress);
    event StabilityPoolAddressChanged(address _stabilityPoolAddress);
    event GasPoolAddressChanged(address _gasPoolAddress);
    event CollSurplusPoolAddressChanged(address _collSurplusPoolAddress);
    event PriceFeedAddressChanged(address  _newPriceFeedAddress);
    event SortedTrovesAddressChanged(address _sortedTrovesAddress);
    event WETHTokenAddressChanged(address _wethTokenAddress);
    event FeeAdminAddressChanged(address _feeAdminAddress);
    event BorrowingFeePoolAddressChanged(address _borrowingFeePoolAddress);  

    event TroveCreated(address indexed _borrower, uint arrayIndex);
    event TroveUpdated(address indexed _borrower, uint _debt, uint _coll, uint stake, uint8 operation);
    event LUSDBorrowingFeePaid(address indexed _borrower, uint _LUSDFee);

    // --- Functions ---

    function setAddresses(
        address _troveManagerAddress,
        address _activePoolAddress,
        address _defaultPoolAddress,
        address _stabilityPoolAddress,
        address _gasPoolAddress,
        address _collSurplusPoolAddress,
        address _priceFeedAddress,
        address _sortedTrovesAddress,
        address _lusdTokenAddress,
        address _wethTokenAddress,
        uint collDecimalAdjustment
    ) external;

    function setBorrowingFeePoolAddress(address _borrowingFeePoolAddress) external;

    function openTrove(uint _maxFee, uint _LUSDAmount, uint _WETHAmount, address _upperHint, address _lowerHint) external;

    function addColl(uint _WETHAmount, address _upperHint, address _lowerHint) external;

    function moveETHGainToTrove(address _user, uint _WETHAmount, address _upperHint, address _lowerHint) external;

    function withdrawColl(uint _amount, address _upperHint, address _lowerHint) external;

    function withdrawLUSD(uint _maxFee, uint _amount, address _upperHint, address _lowerHint) external;

    function repayLUSD(uint _amount, address _upperHint, address _lowerHint) external;

    function closeTrove() external;

    function adjustTrove(uint _maxFee, uint _WETHAmount, uint _collWithdrawal, uint _debtChange, bool isDebtIncrease, address _upperHint, address _lowerHint) external;

    function claimCollateral() external;

    function getCompositeDebt(uint _debt) external pure returns (uint);
}