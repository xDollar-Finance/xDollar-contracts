// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;

// Common interface for the Trove Manager.
interface IStableCollBorrowerOperations {

    // --- Events ---

    event StableCollTroveManagerAddressChanged(address _newStableCollTroveManagerAddress);
    event StableCollActivePoolAddressChanged(address _stableCollActivePoolAddress);
    event CollTokenAddressChanged(address _collTokenAddress);
    event BorrowingFeePoolChanged(address _borrowingFeePool);

    event TroveCreated(address indexed _borrower, uint arrayIndex);
    event TroveUpdated(address indexed _borrower, uint _debt, uint _coll, uint8 operation);
    event LUSDBorrowingFeePaid(address indexed _borrower, uint _LUSDFee);

    // --- Functions ---

    function setAddresses(
        address _stableCollTroveManagerAddress,
        address _stableCollActivePoolAddress,
        address _LUSDTokenAddress,
        address _collTokenAddress,
        uint _collDecimalAdjustment
    ) external;

    function openTrove(uint _LUSDAmount) external;

    function addColl(uint _StableCollAmount) external;

    function withdrawColl(uint _StableCollAmount) external;

    function withdrawLUSD(uint _LUSDAmount) external;

    function repayLUSD(uint _LUSDAmount) external;

    function closeTrove() external;

    function adjustTrove(uint _LUSDChange, bool isDebtIncrease) external;

    function getCompositeDebt(uint _debt) external pure returns (uint);
}