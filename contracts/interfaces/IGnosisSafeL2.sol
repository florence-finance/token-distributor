// SPDX-License-Identifier: GPL-2.0-or-later
// (C) Florence Finance, 2023 - https://florence.finance/

pragma solidity 0.8.19;

/// @dev Reduced interface to validate the passed safe contract.
interface GnosisSafeL2 {
    function getThreshold() external view returns (uint256);
}
