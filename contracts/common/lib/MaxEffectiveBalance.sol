// SPDX-FileCopyrightText: 2025 Lido <info@lido.fi>
// SPDX-License-Identifier: GPL-3.0

/* See contracts/COMPILERS.md */
// solhint-disable-next-line lido/fixed-compiler-version
pragma solidity >=0.8.9 <0.9.0;

/**
 * @title A lib for EIP-7251: Increase the MAX_EFFECTIVE_BALANCE.
 * Allow to send consolidation and compound requests for validators.
 */
library MaxEffectiveBalance {
    error NoConsolidationRequests();
    error InvalidPubkeyArrayLength();
    error MismatchedArrayLengths(uint256 sourceLength, uint256 targetLength);
    error ConsolidationFeeReadFailed();
    error ConsolidationFeeInvalidData();
    error ConsolidationRequestAdditionFailed(bytes callData);
    error ConsolidationRequestsRequired(uint256 index);

    address internal constant CONSOLIDATION_REQUEST = 0x0000BBdDc7CE488642fb579F8B00f3a590007251;
    uint256 internal constant PUBLIC_KEY_LENGTH = 48;

    function getConsolidationRequestFee() internal view returns (uint256) {
        (bool success, bytes memory feeData) = CONSOLIDATION_REQUEST.staticcall("");

        if (!success) {
            revert ConsolidationFeeReadFailed();
        }

        if (feeData.length != 32) {
            revert ConsolidationFeeInvalidData();
        }

        return abi.decode(feeData, (uint256));
    }

    function addCompoundRequests(bytes calldata pubkeys, uint256 feePerRequest) internal {
        _validatePubkeys(pubkeys);
        _addRequest(pubkeys, pubkeys, feePerRequest);
    }

    function addConsolidationRequests(
        bytes calldata sourcePubkeys,
        bytes calldata targetPubkeys,
        uint256 feePerRequest
    ) internal {
        _validatePubkeys(sourcePubkeys);
        _validatePubkeys(targetPubkeys);

        if (_countPubkeys(targetPubkeys) != 1) {
            _addConsolidationRequestsForSingleTarget(sourcePubkeys, targetPubkeys, feePerRequest);
        } else {
            _addConsolidationRequests(sourcePubkeys, targetPubkeys, feePerRequest);
        }
    }

    function _addConsolidationRequests(
        bytes calldata sourcePubkeys,
        bytes calldata targetPubkeys,
        uint256 feePerRequest
    ) private {
        if (sourcePubkeys.length != targetPubkeys.length) {
            revert MismatchedArrayLengths(sourcePubkeys.length, targetPubkeys.length);
        }

        uint256 requestsCount = _countPubkeys(sourcePubkeys);
        for (uint256 i = 0; i < requestsCount; i++) {
            if (sourcePubkeys[i] == targetPubkeys[i]) {
                revert ConsolidationRequestsRequired(i);
            }
        }

        _addRequest(sourcePubkeys, targetPubkeys, feePerRequest);
    }

    function _addConsolidationRequestsForSingleTarget(
        bytes calldata sourcePubkeys,
        bytes calldata targetPubkey,
        uint256 feePerRequest
    ) private {
        uint256 requestsCount = _countPubkeys(sourcePubkeys);
        for (uint256 i = 0; i < requestsCount; i++) {
            if (sourcePubkeys[i] == targetPubkey) {
                revert ConsolidationRequestsRequired(i);
            }
        }

        bytes memory request = new bytes(96);

        assembly {
            calldatacopy(add(request, 80), targetPubkeys.offset, PUBLIC_KEY_LENGTH)
        }

        for (uint256 i = 0; i < requestsCount; i++) {
            assembly {
                calldatacopy(add(request, 32), add(sourcePubkeys.offset, mul(i, PUBLIC_KEY_LENGTH)), PUBLIC_KEY_LENGTH)
            }

            (bool success, ) = CONSOLIDATION_REQUEST.call{value: feePerRequest}(request);

            if (!success) {
                revert ConsolidationRequestAdditionFailed(request);
            }
        }
    }

    function _addRequest(bytes calldata sourcePubkeys, bytes calldata targetPubkeys, uint256 feePerRequest) private {
        uint256 requestsCount = _countPubkeys(sourcePubkeys);

        bytes memory request = new bytes(96);
        for (uint256 i = 0; i < requestsCount; i++) {
            assembly {
                calldatacopy(add(request, 32), add(sourcePubkeys.offset, mul(i, PUBLIC_KEY_LENGTH)), PUBLIC_KEY_LENGTH)
                calldatacopy(add(request, 80), add(targetPubkeys.offset, mul(i, PUBLIC_KEY_LENGTH)), PUBLIC_KEY_LENGTH)
            }

            (bool success, ) = CONSOLIDATION_REQUEST.call{value: feePerRequest}(request);

            if (!success) {
                revert ConsolidationRequestAdditionFailed(request);
            }
        }
    }

    function _validatePubkeys(bytes calldata pubkeys) private pure {
        if (pubkeys.length % PUBLIC_KEY_LENGTH != 0) {
            revert InvalidPubkeyArrayLength();
        }

        uint256 keysCount = pubkeys.length / PUBLIC_KEY_LENGTH;
        if (keysCount == 0) {
            revert NoConsolidationRequests();
        }
    }

    function _countPubkeys(bytes calldata pubkeys) private pure returns (uint256) {
        return (pubkeys.length / PUBLIC_KEY_LENGTH);
    }
}
