// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;

import "./IPool.sol";


interface IStableCollActivePool is IPool {
    // --- Events ---
    event StableCollBorrowerOperationsAddressChanged(address _newStableCollBorrowerOperationsAddress);
    event StableCollTroveManagerAddressChanged(address _newStableCollTroveManagerAddress);
    event StableCollActivePoolLUSDDebtUpdated(uint _LUSDDebt);
    event StableCollActivePoolETHBalanceUpdated(uint _ETH);
    event CollAddressChanged(address _collTokenAddress);

    // --- Functions ---
    function sendETH(address _account, uint _amount) external;
}
