// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity >=0.8.0;

// @dev copied from perpetual protocol
library LibFormatter {
    function formatDecimals(uint256 num, uint8 fromDecimals, uint8 toDecimals) internal pure returns (uint256) {
        if (fromDecimals == toDecimals) {
            return num;
        }
        return fromDecimals >= toDecimals
            ? num / 10 ** (fromDecimals - toDecimals)
            : num * 10 ** (toDecimals - fromDecimals);
    }
}
