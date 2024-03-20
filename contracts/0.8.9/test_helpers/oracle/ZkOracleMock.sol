// SPDX-FileCopyrightText: 2023 Lido <info@lido.fi>
// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.9;

import { ILidoZKOracle } from "../../oracle/Multiprover.sol";

contract ZkOracleMock is ILidoZKOracle {

    struct Report {
        bool success;
        uint256 clBalanceGwei;
        uint256 numValidators;
        uint256 exitedValidators;
    }

    mapping(uint256 => Report) public reports;

    function addReport(uint256 refSlot, Report memory report) external {
        reports[refSlot] = report;
    }

    function removeReport(uint256 refSlot) external {
        delete reports[refSlot];
    }

    function getReport(uint256 refSlot) external view override
        returns (bool success, uint256 clBalanceGwei, uint256 numValidators, uint256 exitedValidators)
    {
        Report memory report = reports[refSlot];
        return (report.success, report.clBalanceGwei, report.numValidators, report.exitedValidators);
    }
}
