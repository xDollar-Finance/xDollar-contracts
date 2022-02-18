// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;

import "../Interfaces/ILQTYToken.sol";
import "../Interfaces/ICommunityIssuance.sol";
import "../Dependencies/BaseMath.sol";
import "../Dependencies/LiquityMath.sol";
import "../Dependencies/Ownable.sol";
import "../Dependencies/CheckContract.sol";
import "../Dependencies/SafeMath.sol";


contract CommunityIssuance is ICommunityIssuance, Ownable, CheckContract, BaseMath {
    using SafeMath for uint;

    // --- Data ---
    string constant public NAME = "CommunityIssuance";

    uint constant public SECONDS_IN_ONE_MINUTE = 60;

    uint constant public MINUTES_IN_ONE_YEAR = 60 * 24 * 365;

    ILQTYToken public lqtyToken;
    mapping (address => bool) public rewardTokens;
    address[] public rewardTokenList;

    address public stabilityPoolAddress;

    uint public totalLQTYIssued;
    mapping (address => uint) public rewardTokenRatio;
    uint public lastIssueTime; // last issue time
    uint public issuanceFactor; // issue amount per minute
    uint public lastUnIssued; // UnIssused amount since last issuance update

    uint public immutable deploymentTime;

    // --- Events ---

    event LQTYTokenAddressSet(address _lqtyTokenAddress);
    event RewardTokenAdded(address _rewardTokenAddress, uint rewardRatio);
    event RewardRatioUpdated(address _rewardTokenAddress, uint rewardRatio);
    event StabilityPoolAddressSet(address _stabilityPoolAddress);
    event TotalLQTYIssuedUpdated(uint _totalLQTYIssued);

    enum Functions {
        SET_ADDRESS,
        ADD_REWARD_TOKEN,
        SET_ISSUANCE_FACTOR,
        SET_REWARD_TOKEN_RATIO
    }
    uint private constant _TIMELOCK = 1 days;
    mapping(Functions => uint) public timelock;

    // --- Time lock
    modifier notLocked(Functions _fn) {
        require(timelock[_fn] != 1 && timelock[_fn] <= block.timestamp, "Function is timelocked");
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

    // --- Functions ---

    constructor() public {
        uint syncTime = block.timestamp;
        deploymentTime = syncTime;
        lastIssueTime = syncTime;
    }
    
    function setAddresses
    (
        address _lqtyTokenAddress,
        address _stabilityPoolAddress
    )
        external
        onlyOwner
        override
        notLocked(Functions.SET_ADDRESS)
    {
        checkContract(_lqtyTokenAddress);
        checkContract(_stabilityPoolAddress);

        lqtyToken = ILQTYToken(_lqtyTokenAddress);
        stabilityPoolAddress = _stabilityPoolAddress;
        checkContract(_stabilityPoolAddress);

        // When LQTYToken deployed, it should have transferred CommunityIssuance's LQTY entitlement
        uint LQTYBalance = lqtyToken.balanceOf(address(this));
        //set default ISSUANCE_FACTOR for one year
        issuanceFactor = LQTYBalance.div(MINUTES_IN_ONE_YEAR);

        emit LQTYTokenAddressSet(_lqtyTokenAddress);
        emit StabilityPoolAddressSet(_stabilityPoolAddress);

        timelock[Functions.SET_ADDRESS] = 1;
    }

    function setIssuanceFactor(uint _issuanceFactor) external onlyOwner notLocked(Functions.SET_ISSUANCE_FACTOR) {	
        require(_issuanceFactor > 0, "CommunityIssuance: Issuance Factor cannot be zero");	
        issuanceFactor = _issuanceFactor;	

        timelock[Functions.SET_ISSUANCE_FACTOR] = 1;	
    }

    function addRewardToken
    (
        address _rewardTokenAddress,
        uint _rewardRatio
    )
        external
        onlyOwner
        override
        notLocked(Functions.ADD_REWARD_TOKEN)
    {
        require(!rewardTokens[_rewardTokenAddress], "CommunityIssuance: rewardTokenAddress already exists");
        require(_rewardRatio > 0, "CommunityIssuance: rewardRatio cannot be zero");
        checkContract(_rewardTokenAddress);

        rewardTokens[_rewardTokenAddress] = true;
        rewardTokenRatio[_rewardTokenAddress] = _rewardRatio;
        rewardTokenList.push(_rewardTokenAddress);

        emit RewardTokenAdded(_rewardTokenAddress, _rewardRatio);
        timelock[Functions.ADD_REWARD_TOKEN] = 1;
    }

    function setRewardTokenRatio
    (
        address _rewardTokenAddress,
        uint _rewardRatio
    )
        external
        onlyOwner
        override
        notLocked(Functions.SET_REWARD_TOKEN_RATIO)
    {
        require(rewardTokens[_rewardTokenAddress], "CommunityIssuance: rewardTokenAddress does not exist");
        require(_rewardRatio >= 0, "CommunityIssuance: rewardRatio must be at least zero");

        rewardTokenRatio[_rewardTokenAddress] = _rewardRatio;

        emit RewardRatioUpdated(_rewardTokenAddress, _rewardRatio);
        timelock[Functions.SET_REWARD_TOKEN_RATIO] = 1;
    }

    function issueLQTY() external override returns (uint) {
        _requireCallerIsStabilityPool();

        uint issuance = _getCumulativeIssuanceAmount().add(lastUnIssued);
        uint LQTYBalance = lqtyToken.balanceOf(address(this));
        uint issuable = 0;
        if (LQTYBalance > issuance) {
            issuable = issuance;
        } else {
            issuable = LQTYBalance;
        }
        totalLQTYIssued = totalLQTYIssued.add(issuable);
        lastIssueTime = block.timestamp;
        lastUnIssued = issuance.sub(issuable);
        emit TotalLQTYIssuedUpdated(issuable);
        return issuable;
    }

    function _getCumulativeIssuanceAmount() internal view returns (uint) {
        uint timePassedInMinutes = block.timestamp.sub(lastIssueTime).div(SECONDS_IN_ONE_MINUTE);
        uint cumulativeIssuanceAmount = issuanceFactor.mul(timePassedInMinutes);
        return cumulativeIssuanceAmount;
    }

    function sendLQTY(address _account, uint _LQTYamount) external override {
        _requireCallerIsStabilityPool();

        lqtyToken.transfer(_account, _LQTYamount);

        // Transfer additional rewards
        for (uint i = 0; i < rewardTokenList.length; i++) {
            IERC20(rewardTokenList[i]).transfer(_account, _LQTYamount.div(DECIMAL_PRECISION).mul(rewardTokenRatio[rewardTokenList[i]]));
        }
    }

    // --- 'require' functions ---

    function _requireCallerIsStabilityPool() internal view {
        require(msg.sender == stabilityPoolAddress, "CommunityIssuance: caller is not SP");
    }
}