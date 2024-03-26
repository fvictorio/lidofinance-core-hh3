// SPDX-FileCopyrightText: 2023 Lido <info@lido.fi>
// SPDX-License-Identifier: GPL-3.0

/* See contracts/COMPILERS.md */
pragma solidity 0.8.9;

import "@openzeppelin/contracts-v4.4/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts-v4.4/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts-v4.4/token/ERC20/utils/SafeERC20.sol";

import {ILidoLocator} from "../common/interfaces/ILidoLocator.sol";
import {Versioned} from "./utils/Versioned.sol";
import {TriggerableExitMock} from "./TriggerableExitMock.sol";

interface ILido {
    /**
     * @notice A payable function supposed to be called only by WithdrawalVault contract
     * @dev We need a dedicated function because funds received by the default payable function
     * are treated as a user deposit
     */
    function receiveWithdrawals() external payable;
}

interface ITriggerableExit {
    function triggerExit(bytes memory validatorPubkey) external payable;
    function getExitFee() external view returns (uint);
}


/**
 * @title A vault for temporary storage of withdrawals
 */
contract WithdrawalVault is Versioned {
    using SafeERC20 for IERC20;
    //
    // CONSTANTS
    //
    // bytes32 internal constant LIDO_LOCATOR_POSITION = keccak256("lido.WithdrawalVault.lidoLocator");
    bytes32 internal constant LIDO_LOCATOR_POSITION = 0xc0b60c351b70494e3ab52c5bef06f2292b0f5ac139efc05620bc15f3425d97d1;
    // bytes32 internal constant LIDO_LOCATOR_POSITION = keccak256("lido.WithdrawalVault.triggerableExit");
    bytes32 internal constant TRIGGERABLE_EXIT_POSITION = 0x2406e554a04ea2a6933d1967461eb6998042fe053bf0118b17e6017532b551a4;

    // Events
    /**
     * Emitted when the ERC20 `token` recovered (i.e. transferred)
     * to the Lido treasury address by `requestedBy` sender.
     */
    event ERC20Recovered(address indexed requestedBy, address indexed token, uint256 amount);

    /**
     * Emitted when the ERC721-compatible `token` (NFT) recovered (i.e. transferred)
     * to the Lido treasury address by `requestedBy` sender.
     */
    event ERC721Recovered(address indexed requestedBy, address indexed token, uint256 tokenId);

    event LocatorContractSet(address locatorAddress);
    event TriggerableExitContractSet(address triggerableExit);

    // Errors
    error NotLido();
    error NotEnoughEther(uint256 requested, uint256 balance);
    error ZeroAmount();

    /**
     * @param _lidoLocator Address of the Lido Locator contract.
     */
    function initialize(address _lidoLocator, address _triggerableExit) external onlyInit {
        // Initializations for v1 --> v2
        _initialize_v2(_lidoLocator, _triggerableExit);

        initialized();
    }

     function finalizeUpgrade_v2(address _lidoLocator, address _triggerableExit) external {
        require(hasInitialized(), "CONTRACT_NOT_INITIALIZED");

        _checkContractVersion(1);

        _initialize_v2(_lidoLocator, _triggerableExit);
    }

    function _initialize_v2(address _locator, address _triggerableExit) internal {
        _onlyNonZeroAddress(_locator);
        _onlyNonZeroAddress(_triggerableExit);

        LIDO_LOCATOR_POSITION.setStorageAddress(_locator);
        TRIGGERABLE_EXIT_POSITION.setStorageAddress(_triggerableExit);

        _setContractVersion(2);

        emit LocatorContractSet(_locator);
        emit TriggerableExitContractSet(_triggerableExit);
    }

    function getLocator() public view returns (ILidoLocator) {
        return ILidoLocator(LIDO_LOCATOR_POSITION.getStorageAddress());
    }

    function getTriggerableExit() public view returns (ITriggerableExit) {
        return ITriggerableExit(TRIGGERABLE_EXIT_POSITION.getStorageAddress());
    }

    /**
     * @notice Withdraw `_amount` of accumulated withdrawals to Lido contract
     * @dev Can be called only by the Lido contract
     * @param _amount amount of ETH to withdraw
     */
    function withdrawWithdrawals(uint256 _amount) external {
        if (msg.sender != address(getLocator().lido())) {
            revert NotLido();
        }
        if (_amount == 0) {
            revert ZeroAmount();
        }

        uint256 balance = address(this).balance;
        if (_amount > balance) {
            revert NotEnoughEther(_amount, balance);
        }

        ILido(getLocator().lido()).receiveWithdrawals{value: _amount}();
    }

    /**
     * Transfers a given `_amount` of an ERC20-token (defined by the `_token` contract address)
     * currently belonging to the burner contract address to the Lido treasury address.
     *
     * @param _token an ERC20-compatible token
     * @param _amount token amount
     */
    function recoverERC20(IERC20 _token, uint256 _amount) external {
        if (_amount == 0) {
            revert ZeroAmount();
        }

        emit ERC20Recovered(msg.sender, address(_token), _amount);

        _token.safeTransfer(getLocator().treasury(), _amount);
    }

    /**
     * Transfers a given token_id of an ERC721-compatible NFT (defined by the token contract address)
     * currently belonging to the burner contract address to the Lido treasury address.
     *
     * @param _token an ERC721-compatible token
     * @param _tokenId minted token id
     */
    function recoverERC721(IERC721 _token, uint256 _tokenId) external {
        emit ERC721Recovered(msg.sender, address(_token), _tokenId);

        _token.transferFrom(address(this), getLocator().treasury(), _tokenId);
    }

    event Received(address from, uint256 value);

    receive() external payable {}

    function forcedExit(bytes[] calldata pubkeys, address sender) external payable {
        //only VEBO

        uint256 vaultBalance = address(this).balance - msg.value;
        uint256 fee = msg.value;

        uint256 keysCount = pubkeys.length;
        for(uint256 i = 0; i < keysCount; ++i) {
            uint256 beforeBalance = address(this).balance;
            getTriggerableExit().triggerExit{value: fee}(pubkeys[i]);
            fee = fee - (beforeBalance - address(this).balance);
        }

        //return unspent fee to sender
        address(sender).call{value: fee}("");

        assert(address(this).balance == vaultBalance);
    }
}
