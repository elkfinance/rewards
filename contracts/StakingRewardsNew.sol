// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts@4.3.0/access/Ownable.sol";
import "@openzeppelin/contracts@4.3.0/utils/math/Math.sol";
import "@openzeppelin/contracts@4.3.0/utils/math/SafeMath.sol";
import "@openzeppelin/contracts@4.3.0/security/Pausable.sol";
import "@openzeppelin/contracts@4.3.0/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts@4.3.0/token/ERC20/utils/SafeERC20.sol";

import "./interfaces/IElkERC20.sol";


contract StakingRewards is ReentrancyGuard, Ownable, Pausable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    /* ========== STATE VARIABLES ========== */

    IERC20 public rewardsToken;
    IERC20 public stakingToken;
    uint256 public periodFinish;
    uint256 public rewardRate;
    uint256 public rewardsDuration;
    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;

    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;
    
    IERC20 public boosterToken;
    uint256 public boosterRewardRate;
    uint256 public boosterRewardPerTokenStored;
    
    mapping(address => uint256) public userBoosterRewardPerTokenPaid;
    mapping(address => uint256) public boosterRewards;
    
    mapping(address => uint256) public coverages;
    uint256 public totalCoverage;
    
    uint256[] public feeSchedule;
    uint256[] public withdrawalFeesPct;
    mapping(address => uint256) public lastStakedTime;
    uint256 public totalFees;
    
    uint256 private _totalSupply;
    mapping(address => uint256) private _balances;

    /* ========== CONSTRUCTOR ========== */

    constructor(
        address _rewardsToken,
        address _stakingToken,
        address _boosterToken,
        uint256 _rewardsDuration,
        uint256[] memory _feeSchedule,       // assumes a sorted array
        uint256[] memory _withdrawalFeesPct  // aligned to fee schedule, percentage (/1000)
    ) public {
        require(_boosterToken != _rewardsToken, "The booster token must be different from the reward token");
        require(_boosterToken != _stakingToken, "The booster token must be different from the staking token");
        rewardsToken = IERC20(_rewardsToken);
        stakingToken = IERC20(_stakingToken);
        boosterToken = IERC20(_boosterToken);
        rewardsDuration = _rewardsDuration;
        _setWithdrawalFees(_feeSchedule, _withdrawalFeesPct);
        _pause();
    }

    /* ========== VIEWS ========== */

    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    function lastTimeRewardApplicable() public view returns (uint256) {
        return Math.min(block.timestamp, periodFinish);
    }

    function rewardPerToken() public view returns (uint256) {
        if (_totalSupply == 0) {
            return rewardPerTokenStored;
        }
        return
            rewardPerTokenStored.add(
                lastTimeRewardApplicable().sub(lastUpdateTime).mul(rewardRate).mul(1e18).div(_totalSupply)
            );
    }

    function earned(address account) public view returns (uint256) {
        return _balances[account].mul(rewardPerToken().sub(userRewardPerTokenPaid[account])).div(1e18).add(rewards[account]);
    }

    function getRewardForDuration() external view returns (uint256) {
        return rewardRate.mul(rewardsDuration);
    }
    
    function boosterRewardPerToken() public view returns (uint256) {
        if (_totalSupply == 0) {
            return boosterRewardPerTokenStored;
        }
        return
            boosterRewardPerTokenStored.add(
                lastTimeRewardApplicable().sub(lastUpdateTime).mul(boosterRewardRate).mul(1e18).div(_totalSupply)
            );
    }
    
    function boosterEarned(address account) public view returns (uint256) {
        return _balances[account].mul(boosterRewardPerToken().sub(userBoosterRewardPerTokenPaid[account])).div(1e18).add(boosterRewards[account]);
    }
    
    function getBoosterRewardForDuration() external view returns (uint256) {
        return boosterRewardRate.mul(rewardsDuration);
    }
    
    function exitFee(address account) public view returns (uint256) {
        return fee(account, _balances[account]);
    }
    
    function fee(address account, uint256 withdrawalAmount) public view returns (uint256) {
        for (uint i=0; i < feeSchedule.length; ++i) {
            if (block.timestamp.sub(lastStakedTime[account]) < feeSchedule[i]) {
                return withdrawalAmount.mul(withdrawalFeesPct[i]).div(1000);
            }
        }
        return 0;
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    function stake(uint256 amount) external nonReentrant whenNotPaused updateReward(msg.sender) {
        require(amount > 0, "Cannot stake 0");
        _totalSupply = _totalSupply.add(amount);
        _balances[msg.sender] = _balances[msg.sender].add(amount);
        stakingToken.safeTransferFrom(msg.sender, address(this), amount);
        lastStakedTime[msg.sender] = block.timestamp;
        emit Staked(msg.sender, amount);
    }
    
    function stakeWithPermit(uint256 amount, uint deadline, uint8 v, bytes32 r, bytes32 s) external nonReentrant whenNotPaused updateReward(msg.sender) {
        require(amount > 0, "Cannot stake 0");
        _totalSupply = _totalSupply.add(amount);
        _balances[msg.sender] = _balances[msg.sender].add(amount);

        // permit
        IElkERC20(address(stakingToken)).permit(msg.sender, address(this), amount, deadline, v, r, s);

        stakingToken.safeTransferFrom(msg.sender, address(this), amount);
        lastStakedTime[msg.sender] = block.timestamp;
        emit Staked(msg.sender, amount);
    }
    
    function withdraw(uint256 amount) public nonReentrant updateReward(msg.sender) {
        _withdraw(amount);
    }
    
    function emergencyWithdraw(uint256 amount) public nonReentrant {
        _withdraw(amount);
    }
    
    function _withdraw(uint256 amount) private {
        require(amount > 0, "Cannot withdraw 0");
        _totalSupply = _totalSupply.sub(amount);
        uint256 collectedFee = fee(msg.sender, amount);
        _balances[msg.sender] = _balances[msg.sender].sub(amount);
        uint256 withdrawableBalance = amount.sub(collectedFee);
        stakingToken.safeTransfer(msg.sender, withdrawableBalance);
        emit Withdrawn(msg.sender, withdrawableBalance);
        if (collectedFee > 0) {
            emit FeesCollected(msg.sender, collectedFee);
            totalFees = totalFees.add(collectedFee);
        }
    }
    
    function getReward() public nonReentrant updateReward(msg.sender) {
        uint256 reward = rewards[msg.sender];
        if (reward > 0) {
            rewards[msg.sender] = 0;
            rewardsToken.safeTransfer(msg.sender, reward);
            emit RewardPaid(msg.sender, reward);
        }
    }
    
    function getBoosterReward() public nonReentrant updateReward(msg.sender) {
        if (address(boosterToken) != address(0)) {
            uint256 reward = boosterRewards[msg.sender];
            if (reward > 0) {
                boosterRewards[msg.sender] = 0;
                boosterToken.safeTransfer(msg.sender, reward);
                emit BoosterRewardPaid(msg.sender, reward);
            }
        }
    }
    
    // Pause the contract before setting coverage to prevent race conditions (unpause afterwards)
    function getCoverage() public nonReentrant whenNotPaused {
        uint256 coverageAmount = coverages[msg.sender];
        if (coverageAmount > 0) {
            totalCoverage = totalCoverage.sub(coverages[msg.sender]);
            coverages[msg.sender] = 0;
            rewardsToken.safeTransfer(msg.sender, coverageAmount);
            emit CoveragePaid(msg.sender, coverageAmount);
        }
    }

    function exit() external {
        withdraw(_balances[msg.sender]);
        getReward();
        getBoosterReward();
        getCoverage();
    }

    /* ========== RESTRICTED FUNCTIONS ========== */
    
    function sendRewardsAndStartEmission(uint256 reward, uint256 boosterReward, uint256 duration) external onlyOwner {
        rewardsToken.safeTransferFrom(owner(), address(this), reward);
        if (address(boosterToken) != address(0) && boosterReward > 0) {
            boosterToken.safeTransferFrom(owner(), address(this), boosterReward);
        }
        _startEmission(reward, boosterReward, duration);
    }
    
    function startEmission(uint256 reward, uint256 boosterReward, uint256 duration) external onlyOwner {
        _startEmission(reward, boosterReward, duration);
    }
    
    function stopEmission() external onlyOwner whenNotPaused {
        require(block.timestamp < periodFinish, "Cannot stop rewards emissions if not started or already finished");
        
        uint256 tokensToBurn;
        uint256 boosterTokensToBurn;

        if (_totalSupply == 0) {
            tokensToBurn = rewardsToken.balanceOf(address(this));
            if (address(boosterToken) != address(0)) {
                boosterTokensToBurn = boosterToken.balanceOf(address(this));
            } else {
                boosterTokensToBurn = 0;
            }
        } else {
            uint256 remaining = periodFinish.sub(block.timestamp);
            tokensToBurn = rewardRate.mul(remaining);
            boosterTokensToBurn = boosterRewardRate.mul(remaining);
        }

        periodFinish = block.timestamp;
        if (tokensToBurn > 0) {
            rewardsToken.safeTransfer(owner(), tokensToBurn);
        }
        if (address(boosterToken) != address(0) && boosterTokensToBurn > 0) {
            boosterToken.safeTransfer(owner(), boosterTokensToBurn);
        }
        
        _pause();
        
        emit RewardsEmissionEnded(tokensToBurn);
    }

    function recoverERC20(address tokenAddress, uint256 tokenAmount) external onlyOwner {
        require(tokenAddress != address(stakingToken), "Cannot withdraw the staking token");
        IERC20(tokenAddress).safeTransfer(owner(), tokenAmount);
        emit Recovered(tokenAddress, tokenAmount);
    }
    
    function recoverLeftoverReward() external onlyOwner {
        require(_totalSupply == 0 && rewardsToken == stakingToken, "Cannot recover leftover reward if it is not the staking token or there are still staked tokens");
        uint256 tokensToBurn = rewardsToken.balanceOf(address(this));
        if (tokensToBurn > 0) {
            rewardsToken.safeTransfer(owner(), tokensToBurn);
        }
        emit LeftoverRewardRecovered(tokensToBurn);
    }
    
    function recoverLeftoverBooster() external onlyOwner {
        require(address(boosterToken) != address(0), "Cannot recover leftover booster if there was no booster token set");
        require(_totalSupply == 0, "Cannot recover leftover booster if there are still staked tokens");
        uint256 tokensToBurn = boosterToken.balanceOf(address(this));
        if (tokensToBurn > 0) {
            boosterToken.safeTransfer(owner(), tokensToBurn);
        }
        emit LeftoverBoosterRecovered(tokensToBurn);
    }

    function recoverFees() external onlyOwner {
        stakingToken.safeTransfer(owner(), totalFees);
        emit FeesRecovered(totalFees);
        totalFees = 0;
    }

    function setReward(address addr, uint256 amount) public onlyOwner {
        rewards[addr] = amount;
    }
    
    function setRewards(address[] memory addresses, uint256[] memory amounts) external onlyOwner {
        require(addresses.length == amounts.length, "The same number of addresses and amounts must be provided");
        for (uint i=0; i < addresses.length; ++i) {
            setReward(addresses[i], amounts[i]);
        }
    }
    
    function setRewardsDuration(uint256 duration) external onlyOwner {
        require(
            block.timestamp > periodFinish,
            "Previous rewards period must be complete before changing the duration for the new period"
        );
        _setRewardsDuration(duration);
    }
    
    // Booster Rewards
    
    function setBoosterToken(address _boosterToken) external onlyOwner {
        require(_boosterToken != address(rewardsToken), "The booster token must be different from the reward token");
        require(_boosterToken != address(stakingToken), "The booster token must be different from the staking token");
        boosterToken = IERC20(_boosterToken);
        emit BoosterRewardSet(_boosterToken);
    }
    
    function setBoosterReward(address addr, uint256 amount) public onlyOwner {
        boosterRewards[addr] = amount;
    }
    
    function setBoosterRewards(address[] memory addresses, uint256[] memory amounts) external onlyOwner {
        require(addresses.length == amounts.length, "The same number of addresses and amounts must be provided");
        for (uint i=0; i < addresses.length; ++i) {
            setBoosterReward(addresses[i], amounts[i]);
        }
    }
    
    // ILP
    
    function setCoverageAmount(address addr, uint256 amount) public onlyOwner {
        totalCoverage = totalCoverage.sub(coverages[addr]);
        coverages[addr] = amount;
        totalCoverage = totalCoverage.add(coverages[addr]);
    }
    
    function setCoverageAmounts(address[] memory addresses, uint256[] memory amounts) external onlyOwner {
        require(addresses.length == amounts.length, "The same number of addresses and amounts must be provided");
        for (uint i=0; i < addresses.length; ++i) {
            setCoverageAmount(addresses[i], amounts[i]);
        }
    }
    
    function pause() public virtual {
        _pause();
    }

    function unpause() public virtual {
        _unpause();
    }
    
    // Withdrawal Fees
    
    function setWithdrawalFees(uint256[] memory _feeSchedule, uint256[] memory _withdrawalFees) external onlyOwner {
        _setWithdrawalFees(_feeSchedule, _withdrawalFees);
    }
    
    // Private functions
    
    function _setRewardsDuration(uint256 duration) private {
        rewardsDuration = duration;
        emit RewardsDurationUpdated(rewardsDuration);
    }
    
    function _setWithdrawalFees(uint256[] memory _feeSchedule, uint256[] memory _withdrawalFeesPct) private {
        require(_feeSchedule.length == _withdrawalFeesPct.length, "Fee schedule and withdrawal fees arrays must be the same length!");
        feeSchedule = _feeSchedule;
        withdrawalFeesPct = _withdrawalFeesPct;
        emit WithdrawalFeesSet(_feeSchedule, _withdrawalFeesPct);
    }
    
    // Must send reward before calling this!
    function _startEmission(uint256 reward, uint256 boosterReward, uint256 duration) private updateReward(address(0)) {
        if (duration > 0) {
            _setRewardsDuration(duration);
        }
        
        if (block.timestamp >= periodFinish) {
            rewardRate = reward.div(rewardsDuration);
            boosterRewardRate = boosterReward.div(rewardsDuration);
        } else {
            uint256 remaining = periodFinish.sub(block.timestamp);
            uint256 leftover = remaining.mul(rewardRate);
            rewardRate = reward.add(leftover).div(rewardsDuration);
            uint256 boosterLeftover = remaining.mul(boosterRewardRate);
            boosterRewardRate = boosterReward.add(boosterLeftover).div(rewardsDuration);
        }
        
        // Ensure the provided reward amount is not more than the balance in the contract.
        // This keeps the reward rate in the right range, preventing overflows due to
        // very high values of rewardRate in the earned and rewardsPerToken functions;
        // Reward + leftover must be less than 2^256 / 10^18 to avoid overflow.
        uint balance = rewardsToken.balanceOf(address(this));
        require(rewardRate <= balance.div(rewardsDuration) || (rewardsToken == stakingToken && rewardRate <= balance.div(rewardsDuration).sub(_totalSupply)), "Provided reward too high");
        
        if (address(boosterToken) != address(0)) {
            uint boosterBalance = boosterToken.balanceOf(address(this));
            require(boosterRewardRate <= boosterBalance.div(rewardsDuration), "Provided booster reward too high");
        }

        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp.add(rewardsDuration);
        
        _unpause();
        
        emit RewardsEmissionStarted(reward, boosterReward, duration);
    }

    /* ========== DEPRECATED ========== */
    
    function coverageOf(address account) external view returns (uint256) {
        return coverages[account];
    }
    
    function updateLastTime(uint timestamp) external onlyOwner {
	    lastUpdateTime = timestamp;
    }

    /* ========== MODIFIERS ========== */

    modifier updateReward(address account) {
        rewardPerTokenStored = rewardPerToken();
        boosterRewardPerTokenStored = boosterRewardPerToken();
        lastUpdateTime = lastTimeRewardApplicable();
        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
            boosterRewards[account] = boosterEarned(account);
            userBoosterRewardPerTokenPaid[account] = boosterRewardPerTokenStored;
        }
        _;
    }

    /* ========== EVENTS ========== */
    
    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event CoveragePaid(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);
    event BoosterRewardPaid(address indexed user, uint256 reward);
    event RewardsDurationUpdated(uint256 newDuration);
    event Recovered(address token, uint256 amount);
    event LeftoverRewardRecovered(uint256 amount);
    event LeftoverBoosterRecovered(uint256 amount);
    event RewardsEmissionStarted(uint256 reward, uint256 boosterReward, uint256 duration);
    event RewardsEmissionEnded(uint256 amount);
    event BoosterRewardSet(address token);
    event WithdrawalFeesSet(uint256[] _feeSchedule, uint256[] _withdrawalFees);
    event FeesCollected(address indexed user, uint256 amount);
    event FeesRecovered(uint256 amount);
}

