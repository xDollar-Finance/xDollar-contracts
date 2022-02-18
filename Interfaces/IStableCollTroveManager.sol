// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;

import "./ILiquityBase.sol";
import "./IStabilityPool.sol";
import "./ILUSDToken.sol";
import "./ILQTYToken.sol";


// Common interface for the Trove Manager.
interface IStableCollTroveManager is ILiquityBase {
    
    // --- Events ---

    event StableCollBorrowerOperationsAddressChanged(address _newStableCollBorrowerOperationsAddress);
    event LUSDTokenAddressChanged(address _newLUSDTokenAddress);
    event StableCollActivePoolAddressChanged(address _stableCollActivePoolAddress);
    event BorrowingRatePlusChanged(uint _borrowingRatePlus);

    event TroveUpdated(address indexed _borrower, uint _debt, uint _coll, uint stake, uint8 operation);
    event TroveLiquidated(address indexed _borrower, uint _debt, uint _coll, uint8 operation);
    event BaseRateUpdated(uint _baseRate);
    event LastFeeOpTimeUpdated(uint _lastFeeOpTime);
    event TotalStakesUpdated(uint _newTotalStakes);
    event SystemSnapshotsUpdated(uint _totalStakesSnapshot, uint _totalCollateralSnapshot);
    event LTermsUpdated(uint _L_ETH, uint _L_LUSDDebt);
    event TroveSnapshotsUpdated(uint _L_ETH, uint _L_LUSDDebt);
    event TroveIndexUpdated(address _borrower, uint _newIndex);

    // --- Functions ---

    function setAddresses(
        address _stableCollBorrowerOperationsAddress,
        address _stableCollActivePoolAddress,
        address _lusdTokenAddress,
        address _collTokenAddress,
        uint _collDecimalAdjustment
    ) external;

    function lusdToken() external view returns (ILUSDToken);
    function lqtyToken() external view returns (ILQTYToken);

    function getTroveOwnersCount() external view returns (uint);

    function getTroveFromTroveOwnersArray(uint _index) external view returns (address);

    function addTroveOwnerToArray(address _borrower) external returns (uint index);

    function getEntireDebtAndColl(address _borrower) external view returns (
        uint debt, 
        uint coll
    );

    function closeTrove(address _borrower) external;

    function getBorrowingRate() external view returns (uint);
    function getBorrowingFee(uint LUSDDebt) external view returns (uint);

    function getDebtCeiling() external view returns (uint);

    function getStableCollAmount(uint _LUSDDebt) external view returns (uint);
    
    function getTroveStatus(address _borrower) external view returns (uint);
    
    function getTroveDebt(address _borrower) external view returns (uint);

    function getTroveColl(address _borrower) external view returns (uint);

    function setTroveStatus(address _borrower, uint num) external;

    function increaseTroveColl(address _borrower, uint _collIncrease) external returns (uint);

    function decreaseTroveColl(address _borrower, uint _collDecrease) external returns (uint); 

    function increaseTroveDebt(address _borrower, uint _debtIncrease) external returns (uint); 

    function decreaseTroveDebt(address _borrower, uint _collDecrease) external returns (uint); 

    function getTCR(uint _price) external view returns (uint);
}