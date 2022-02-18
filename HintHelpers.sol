// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;

import "./Interfaces/ITroveManager.sol";
import "./Interfaces/ISortedTroves.sol";
import "./Dependencies/LiquityBase.sol";
import "./Dependencies/Ownable.sol";
import "./Dependencies/CheckContract.sol";

contract HintHelpers is LiquityBase, Ownable, CheckContract {
    string constant public NAME = "HintHelpers";

    ISortedTroves public sortedTroves;
    ITroveManager public troveManager;

    uint private _collDecimalAdjustment;

    enum Functions { SET_ADDRESS }  
    uint256 private constant _TIMELOCK = 2 days;
    mapping(Functions => uint256) public timelock;

    // --- Events ---

    event SortedTrovesAddressChanged(address _sortedTrovesAddress);
    event TroveManagerAddressChanged(address _troveManagerAddress);

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
        address _sortedTrovesAddress,
        address _troveManagerAddress,
        uint collDecimalAdjustment
    )
        external
        onlyOwner
        notLocked(Functions.SET_ADDRESS)
    {
        checkContract(_sortedTrovesAddress);
        checkContract(_troveManagerAddress);

        sortedTroves = ISortedTroves(_sortedTrovesAddress);
        troveManager = ITroveManager(_troveManagerAddress);
        _collDecimalAdjustment = collDecimalAdjustment;

        emit SortedTrovesAddressChanged(_sortedTrovesAddress);
        emit TroveManagerAddressChanged(_troveManagerAddress);

        _renounceOwnership();
        timelock[Functions.SET_ADDRESS] = 1;
    }

    // --- Functions ---

    /* getRedemptionHints() - Helper function for finding the right hints to pass to redeemCollateral().
     *
     * It simulates a redemption of `_LUSDamount` to figure out where the redemption sequence will start and what state the final Trove
     * of the sequence will end up in.
     *
     * Returns three hints:
     *  - `firstRedemptionHint` is the address of the first Trove with ICR >= MCR (i.e. the first Trove that will be redeemed).
     *  - `partialRedemptionHintNICR` is the final nominal ICR of the last Trove of the sequence after being hit by partial redemption,
     *     or zero in case of no partial redemption.
     *  - `truncatedLUSDamount` is the maximum amount that can be redeemed out of the the provided `_LUSDamount`. This can be lower than
     *    `_LUSDamount` when redeeming the full amount would leave the last Trove of the redemption sequence with less net debt than the
     *    minimum allowed value (i.e. MIN_NET_DEBT).
     *
     * The number of Troves to consider for redemption can be capped by passing a non-zero value as `_maxIterations`, while passing zero
     * will leave it uncapped.
     */

    function getRedemptionHints(
        uint _LUSDamount, 
        uint _price,
        uint _maxIterations
    )
        external
        view
        returns (
            address firstRedemptionHint,
            uint partialRedemptionHintNICR,
            uint truncatedLUSDamount
        )
    {
        ISortedTroves sortedTrovesCached = sortedTroves;

        uint remainingLUSD = _LUSDamount;
        address currentTroveuser = sortedTrovesCached.getLast();

        while (currentTroveuser != address(0) && troveManager.getCurrentICR(currentTroveuser, _price) < MCR) {
            currentTroveuser = sortedTrovesCached.getPrev(currentTroveuser);
        }

        firstRedemptionHint = currentTroveuser;

        if (_maxIterations == 0) {
            _maxIterations = uint(-1);
        }

        while (currentTroveuser != address(0) && remainingLUSD > 0 && _maxIterations-- > 0) {
            uint netLUSDDebt = _getNetDebt(troveManager.getTroveDebt(currentTroveuser))
                .add(troveManager.getPendingLUSDDebtReward(currentTroveuser));

            if (netLUSDDebt > remainingLUSD) {
                if (netLUSDDebt > MIN_NET_DEBT) {
                    uint maxRedeemableLUSD = LiquityMath._min(remainingLUSD, netLUSDDebt.sub(MIN_NET_DEBT));

                    uint ETH = troveManager.getTroveColl(currentTroveuser)
                        .add(troveManager.getPendingETHReward(currentTroveuser));

                    uint newColl = ETH.sub(maxRedeemableLUSD.mul(DECIMAL_PRECISION).div(_price).div(_collDecimalAdjustment));
                    uint newDebt = netLUSDDebt.sub(maxRedeemableLUSD);

                    uint compositeDebt = _getCompositeDebt(newDebt);
                    partialRedemptionHintNICR = LiquityMath._computeNominalCR(newColl, compositeDebt, _collDecimalAdjustment);

                    remainingLUSD = remainingLUSD.sub(maxRedeemableLUSD);
                }
                break;
            } else {
                remainingLUSD = remainingLUSD.sub(netLUSDDebt);
            }

            currentTroveuser = sortedTrovesCached.getPrev(currentTroveuser);
        }

        truncatedLUSDamount = _LUSDamount.sub(remainingLUSD);
    }

    /* getApproxHint() - return address of a Trove that is, on average, (length / numTrials) positions away in the 
    sortedTroves list from the correct insert position of the Trove to be inserted. 
    
    Note: The output address is worst-case O(n) positions away from the correct insert position, however, the function 
    is probabilistic. Input can be tuned to guarantee results to a high degree of confidence, e.g:

    Submitting numTrials = k * sqrt(length), with k = 15 makes it very, very likely that the ouput address will 
    be <= sqrt(length) positions away from the correct insert position.
    */
    function getApproxHint(uint _CR, uint _numTrials, uint _inputRandomSeed)
        external
        view
        returns (address hintAddress, uint diff, uint latestRandomSeed)
    {
        uint arrayLength = troveManager.getTroveOwnersCount();

        if (arrayLength == 0) {
            return (address(0), 0, _inputRandomSeed);
        }

        hintAddress = sortedTroves.getLast();
        diff = LiquityMath._getAbsoluteDifference(_CR, troveManager.getNominalICR(hintAddress));
        latestRandomSeed = _inputRandomSeed;

        uint i = 1;

        while (i < _numTrials) {
            latestRandomSeed = uint(keccak256(abi.encodePacked(latestRandomSeed)));

            uint arrayIndex = latestRandomSeed % arrayLength;
            address currentAddress = troveManager.getTroveFromTroveOwnersArray(arrayIndex);
            uint currentNICR = troveManager.getNominalICR(currentAddress);

            // check if abs(current - CR) > abs(closest - CR), and update closest if current is closer
            uint currentDiff = LiquityMath._getAbsoluteDifference(currentNICR, _CR);

            if (currentDiff < diff) {
                diff = currentDiff;
                hintAddress = currentAddress;
            }
            i++;
        }
    }

    function computeNominalCR(uint _coll, uint _debt) external view returns (uint) {
        return LiquityMath._computeNominalCR(_coll, _debt, _collDecimalAdjustment);
    }

    function computeCR(uint _coll, uint _debt, uint _price) external view returns (uint) {
        return LiquityMath._computeCR(_coll, _debt, _price, _collDecimalAdjustment);
    }
}
