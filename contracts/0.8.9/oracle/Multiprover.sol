// SPDX-FileCopyrightText: 2024 Lido <info@lido.fi>
// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.9;

import { AccessControlEnumerable } from "../utils/access/AccessControlEnumerable.sol";
import { SafeCast } from "@openzeppelin/contracts-v4.4/utils/math/SafeCast.sol";

interface ILidoZKOracle {
    function getReport(uint256 refSlot) external view returns  (
        bool success,
        uint256 clBalanceGwei,
        uint256 numValidators,
        uint256 exitedValidators
	);
}

contract Multiprover is ILidoZKOracle, AccessControlEnumerable {
    using SafeCast for uint256;

    error AdminCannotBeZero();

    // zk Oracles commetee
    error DuplicateMember();
    error NonMember();
    error QuorumTooSmall(uint256 minQuorum, uint256 receivedQuorum);
    error AddressCannotBeZero();

    error NoConsensus();

    event MemberAdded(address indexed addr, uint256 newTotalMembers, uint256 newQuorum);
    event MemberRemoved(address indexed addr, uint256 newTotalMembers, uint256 newQuorum);
    event QuorumSet(uint256 newQuorum, uint256 totalMembers, uint256 prevQuorum);

    /// @notice An ACL role granting the permission to modify members list members and
    /// change the quorum by calling addMember, removeMember, and setQuorum functions.
    bytes32 public constant MANAGE_MEMBERS_AND_QUORUM_ROLE =
        keccak256("MANAGE_MEMBERS_AND_QUORUM_ROLE");

    /// @dev A quorum value that effectively disables the oracle.
    uint256 internal constant UNREACHABLE_QUORUM = type(uint256).max;

    /// @dev Oracle committee members' addresses array
    address[] internal _memberAddresses;

    /// @dev Oracle committee members quorum value, must be larger than totalMembers // 2
    uint256 internal _quorum;

    constructor(
        address admin
    ) {
        if (admin == address(0)) revert AdminCannotBeZero();

        _setupRole(DEFAULT_ADMIN_ROLE, admin);
    }

    function getMembers() external view returns (
        address[] memory addresses
    ) {
        return _memberAddresses;
    }

    function addMember(address addr, uint256 quorum)
        external
        onlyRole(MANAGE_MEMBERS_AND_QUORUM_ROLE)
    {
        _addMember(addr, quorum);
    }

    function removeMember(address addr, uint256 quorum)
        external
        onlyRole(MANAGE_MEMBERS_AND_QUORUM_ROLE)
    {
        _removeMember(addr, quorum);
    }

    function getQuorum() external view returns (uint256) {
        return _quorum;
    }

    function setQuorum(uint256 quorum) external {
        // access control is performed inside the next call
        _setQuorumAndCheckConsensus(quorum, _memberAddresses.length);
    }

    ///
    /// Implementation: members
    ///

    function isMember(address addr) internal view returns (bool) {
        for (uint i = 0; i < _memberAddresses.length; i++) {
            if (_memberAddresses[i] == addr) {
                return true;
            }
        }
        return false;
    }


    function _addMember(address addr, uint256 quorum) internal {
        if (isMember(addr)) revert DuplicateMember();
        if (addr == address(0)) revert AddressCannotBeZero();

        _memberAddresses.push(addr);

        uint256 newTotalMembers = _memberAddresses.length;

        emit MemberAdded(addr, newTotalMembers, quorum);

        _setQuorumAndCheckConsensus(quorum, newTotalMembers);
    }

    function _removeMember(address addr, uint256 quorum) internal {
        require(isMember(addr), "Address not a member");

        for (uint i = 0; i < _memberAddresses.length; i++) {
            if (_memberAddresses[i] == addr) {
                // Move the last element into the place to delete
                _memberAddresses[i] = _memberAddresses[_memberAddresses.length - 1];
                // Remove the last element
                _memberAddresses.pop();
                break;
            }
        }

        uint256 newTotalMembers = _memberAddresses.length - 1;

        emit MemberRemoved(addr, newTotalMembers, quorum);

        _setQuorumAndCheckConsensus(quorum, newTotalMembers);
    }

    function _setQuorumAndCheckConsensus(uint256 quorum, uint256 totalMembers) internal {
        if (quorum <= totalMembers / 2) {
            revert QuorumTooSmall(totalMembers / 2 + 1, quorum);
        }

        uint256 prevQuorum = _quorum;
        if (quorum != prevQuorum) {
            _checkRole(MANAGE_MEMBERS_AND_QUORUM_ROLE, _msgSender());
            _quorum = quorum;
            emit QuorumSet(quorum, totalMembers, prevQuorum);
        }
    }

    ///
    /// Implementation: LidoZKOracle
    ///

    function getReport(uint256 refSlot) external view override returns  (
        bool success,
        uint256 clBalanceGwei,
        uint256 numValidators,
        uint256 exitedValidators
    ) {
        refSlot;
        return (true, 100, 100, 100);
    }

    ///
    /// Implementation: Auto-resettable fuse
    /// 
}