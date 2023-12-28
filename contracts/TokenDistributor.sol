// SPDX-License-Identifier: GPL-2.0-or-later
// (C) Florence Finance, 2023 - https://florence.finance/

pragma solidity 0.8.19;

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/security/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {GnosisSafeL2} from "./interfaces/IGnosisSafeL2.sol";

/// @title TokenDistributor
/// @dev This contract manages the distribution of a specific ERC20 token in exchange for Ethereum (ETH).
/// It sets up a time-bound token distribution event, where users can exchange ETH for tokens at a predefined rate.
/// The contract enforces contribution limits per address and employs a Gnosis Safe for secure ETH handling.
/// Additionally, it includes emergency features like pausing and token withdrawal by the owner for responsive actions in unforeseen scenarios.
contract TokenDistributor is Ownable2Step, Pausable, ReentrancyGuard {
    using Math for uint256;
    using SafeERC20 for IERC20Metadata;

    error DistributionNotStarted();
    error DistributionEnded();
    error EthAmountMustBeGreaterThanZero();
    error AddressCapExceeded();
    error RefundFailed();
    error SendingEthToSafeFailed();

    IERC20Metadata public immutable token;
    uint256 public immutable tokenDecimals;

    uint256 public totalTokensToDistribute;
    uint256 public ethPerToken;
    uint256 public maxEthContributionPerAddress;

    uint256 public distributionStartTimestamp;
    uint256 public distributionEndTimestamp;

    GnosisSafeL2 public safe;

    uint256 public tokensDistributed;
    uint256 public ethContributed;

    mapping(address => uint256) public ethContributedAddress;

    event InitializeDistributor(uint256 totalTokensToDistribute, uint256 ethPerToken, uint256 maxEthContributionPerAddress, uint256 distributionStartTimestamp, uint256 distributionEndTimestamp, address safe);
    event Contribute(address indexed user, uint256 ethAmount, uint256 tokenAmount);
    event EmergencyWithdrawTokens(uint256 amount);

    /// @notice Initializes a new TokenDistributor contract.
    /// @param _token The ERC20 token to be distributed.
    constructor(IERC20Metadata _token) {
        token = _token;
        tokenDecimals = _token.decimals();
    }

    /// @notice Sets up the token distribution parameters.
    /// @dev Can only be called once and by the contract owner.
    /// @param _totalTokensToDistribute Total number of tokens available for distribution.
    /// @param _ethPerToken Rate of ETH to Token conversion.
    /// @param _maxEthContributionPerAddress Maximum ETH amount an address can contribute.
    /// @param _distributionStartTimestamp Timestamp for when the distribution starts.
    /// @param _distributionEndTimestamp Timestamp for when the distribution ends.
    /// @param _safe Gnosis Safe address for securing the contributed ETH.
    function initializeDistributor(
        uint256 _totalTokensToDistribute,
        uint256 _ethPerToken,
        uint256 _maxEthContributionPerAddress,
        uint256 _distributionStartTimestamp,
        uint256 _distributionEndTimestamp,
        GnosisSafeL2 _safe
    ) external onlyOwner {
        require(distributionStartTimestamp == 0, "already initialized");
        require(token.balanceOf(address(this)) == _totalTokensToDistribute, "totalTokensToDistribute must match token balance of contract");
        require(_ethPerToken > 0, "ethPerToken must be greater 0");
        require(_maxEthContributionPerAddress > 0, "maxEthContributionPerAddress must be greater 0");
        require(_distributionStartTimestamp >= block.timestamp, "distributionStartTimestamp must be in the future");
        require(_distributionEndTimestamp > _distributionStartTimestamp, "distributionEndTimestamp must be after distributionStartTimestamp");
        require(_safe.getThreshold() > 2, "safe threshold must be greater 2");

        totalTokensToDistribute = _totalTokensToDistribute;
        ethPerToken = _ethPerToken;
        maxEthContributionPerAddress = _maxEthContributionPerAddress;
        distributionStartTimestamp = _distributionStartTimestamp;
        distributionEndTimestamp = _distributionEndTimestamp;
        safe = _safe;

        emit InitializeDistributor(_totalTokensToDistribute, _ethPerToken, _maxEthContributionPerAddress, _distributionStartTimestamp, _distributionEndTimestamp, address(_safe));
    }

    /// @notice Allows users to contribute ETH and receive tokens.
    /// @dev Enforces contribution limits and timeframe, manages token distribution and ETH forwarding to Gnosis Safe.
    /// @dev Emits a Contribute event on successful contribution.
    function contribute() external payable whenNotPaused nonReentrant {
        if (distributionStartTimestamp == 0 || block.timestamp < distributionStartTimestamp) {
            revert DistributionNotStarted();
        }
        if (tokensDistributed >= totalTokensToDistribute || block.timestamp >= distributionEndTimestamp) {
            revert DistributionEnded();
        }

        uint256 amountEth = msg.value;

        if (amountEth == 0) {
            revert EthAmountMustBeGreaterThanZero();
        }
        if (ethContributedAddress[msg.sender] + amountEth > maxEthContributionPerAddress) {
            revert AddressCapExceeded();
        }

        uint256 amountToken = Math.mulDiv(amountEth, 10 ** tokenDecimals, ethPerToken, Math.Rounding.Down);
        uint256 availableTokens = totalTokensToDistribute - tokensDistributed;

        if (amountToken > availableTokens) {
            amountToken = availableTokens;
            uint256 adjustedEthAmount = Math.mulDiv(amountToken, ethPerToken, 10 ** tokenDecimals, Math.Rounding.Up);
            uint256 excessEth = amountEth - adjustedEthAmount;

            (bool refundSent, ) = msg.sender.call{value: excessEth}("");
            if (!refundSent) {
                revert RefundFailed();
            }

            amountEth = adjustedEthAmount;
        }

        ethContributedAddress[msg.sender] += amountEth;
        ethContributed += amountEth;

        (bool sent, ) = address(safe).call{value: amountEth}("");
        if (!sent) {
            revert SendingEthToSafeFailed();
        }

        tokensDistributed += amountToken;
        token.safeTransfer(msg.sender, amountToken);
        emit Contribute(msg.sender, amountEth, amountToken);
    }

    /// @notice Allows the owner to withdraw tokens from the contract in case of emergency.
    /// @param amount The amount of tokens to withdraw.
    /// @dev Only callable by the owner.
    function emergencyWithdrawTokens(uint256 amount) external onlyOwner whenPaused {
        token.safeTransfer(msg.sender, amount);
        emit EmergencyWithdrawTokens(amount);
    }

    /// @notice Pauses the contract, disabling new contributions.
    /// @dev Only callable by the owner.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpauses the contract, enabling contributions again.
    /// @dev Only callable by the owner.
    function unpause() external onlyOwner {
        _unpause();
    }


}
