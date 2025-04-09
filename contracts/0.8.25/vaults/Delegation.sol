// SPDX-FileCopyrightText: 2025 Lido <info@lido.fi>
// SPDX-License-Identifier: GPL-3.0

// See contracts/COMPILERS.md
pragma solidity 0.8.25;

import {Math256} from "contracts/common/lib/Math256.sol";

import {IStakingVault, StakingVaultDeposit} from "./interfaces/IStakingVault.sol";
import {Dashboard} from "./Dashboard.sol";

/**
 * @title Delegation
 * @notice This contract is a contract-owner of StakingVault and includes an additional delegation layer.
 */
contract Delegation is Dashboard {
    /**
     * @notice Maximum combined feeBP value; equals to 100%.
     */
    uint256 private constant MAX_FEE_BP = TOTAL_BASIS_POINTS;

    /**
     * @notice bitwise AND mask that clamps the value to positive int128 range
     */
    uint256 private constant ADJUSTMENT_CLAMP_MASK = uint256(uint128(type(int128).max));

    /**
     * @notice maximum value that can be set via manual adjustment
     */
    uint256 public constant MANUAL_ACCRUED_REWARDS_ADJUSTMENT_LIMIT = 10_000_000 ether;

    /**
     * @notice Node operator manager role:
     * - confirms confirm expiry;
     * - confirms ownership transfer;
     * - assigns NODE_OPERATOR_FEE_CONFIRM_ROLE;
     * - assigns NODE_OPERATOR_FEE_CLAIM_ROLE.
     */
    bytes32 public constant NODE_OPERATOR_MANAGER_ROLE = keccak256("vaults.Delegation.NodeOperatorManagerRole");

    /**
     * @notice Claims node operator fee.
     */
    bytes32 public constant NODE_OPERATOR_FEE_CLAIM_ROLE = keccak256("vaults.Delegation.NodeOperatorFeeClaimRole");

    /**
     * @notice adjusts rewards to allow fee correction during side deposits or consolidations
     */
    bytes32 public constant NODE_OPERATOR_REWARDS_ADJUST_ROLE =
        keccak256("vaults.Delegation.NodeOperatorRewardsAdjustRole");

    /**
     * @notice Node operator fee in basis points cannot exceed 100%, or 10,000 basis points.
     * The node operator's unclaimed fee in ether is returned by `nodeOperatorUnclaimedFee()`.
     */
    uint256 public nodeOperatorFeeBP;

    /**
     * @notice The last report for which node operator fee was claimed. Updated on each claim.
     */
    IStakingVault.Report public nodeOperatorFeeClaimedReport;

    /**
     * @notice adjustment to allow fee correction during side deposits or consolidations.
     *          - can be increased manually by `increaseAccruedRewardsAdjustment` by NODE_OPERATOR_REWARDS_ADJUST_ROLE
     *          - can be set via `setAccruedRewardsAdjustment` to by `_confirmingRoles()`
     *          - increased automatically with `unguaranteedDepositToBeaconChain` by total ether amount of deposits
     *          - reset to zero after `claimNodeOperatorFee`
     *        This amount will be deducted from rewards during NO fee calculation and can be used effectively reduce fees to zero.
     *
     */
    uint256 public accruedRewardsAdjustment;

    /**
     * @notice Constructs the contract.
     * @dev Stores token addresses in the bytecode to reduce gas costs.
     * @param _weth Address of the weth token contract.
     * @param _lidoLocator Address of the Lido locator contract.
     */
    constructor(address _weth, address _lidoLocator) Dashboard(_weth, _lidoLocator) {}

    /**
     * @notice Initializes the contract:
     * - sets up the roles;
     * - sets the confirm expiry to 7 days (can be changed later by DEFAULT_ADMIN_ROLE and NODE_OPERATOR_MANAGER_ROLE).
     * @dev The msg.sender here is VaultFactory. The VaultFactory is temporarily granted
     * DEFAULT_ADMIN_ROLE AND NODE_OPERATOR_MANAGER_ROLE to be able to set initial fees and roles in VaultFactory.
     * All the roles are revoked from VaultFactory by the end of the initialization.
     */
    function initialize(address _defaultAdmin, uint256 _confirmExpiry) external override {
        _initialize(_defaultAdmin, _confirmExpiry);

        // the next line implies that the msg.sender is an operator
        // however, the msg.sender is the VaultFactory, and the role will be revoked
        // at the end of the initialization
        _grantRole(NODE_OPERATOR_MANAGER_ROLE, _defaultAdmin);
        _setRoleAdmin(NODE_OPERATOR_MANAGER_ROLE, NODE_OPERATOR_MANAGER_ROLE);
        _setRoleAdmin(NODE_OPERATOR_FEE_CLAIM_ROLE, NODE_OPERATOR_MANAGER_ROLE);
        _setRoleAdmin(NODE_OPERATOR_REWARDS_ADJUST_ROLE, NODE_OPERATOR_MANAGER_ROLE);
    }

    /**
     * @notice Returns the accumulated unclaimed node operator fee in ether,
     * calculated as: U = (R * F) / T
     * where:
     * - U is the node operator unclaimed fee;
     * - R is the StakingVault rewards accrued since the last node operator fee claim;
     * - F is `nodeOperatorFeeBP`;
     * - T is the total basis points, 10,000.
     * @return uint256: the amount of unclaimed fee in ether.
     */
    function nodeOperatorUnclaimedFee() public view returns (uint256) {
        return _calculateFee(nodeOperatorFeeBP, nodeOperatorFeeClaimedReport);
    }

    /**
     * @notice Returns the unreserved amount of ether,
     * i.e. the amount of ether that is not locked in the StakingVault
     * and not reserved for node operator fees.
     * This amount does not account for the current balance of the StakingVault and
     * can return a value greater than the actual balance of the StakingVault.
     * @return uint256: the amount of unreserved ether.
     */
    function unreserved() public view returns (uint256) {
        uint256 reserved = stakingVault().locked() + nodeOperatorUnclaimedFee();
        uint256 valuation = stakingVault().valuation();

        return reserved > valuation ? 0 : valuation - reserved;
    }

    /**
     * @notice Returns the amount of ether that can be withdrawn from the staking vault.
     * @dev This is the amount of ether that is not locked in the StakingVault and not reserved for node operator fees.
     * @dev This method overrides the Dashboard's withdrawableEther() method
     * @return The amount of ether that can be withdrawn.
     */
    function withdrawableEther() external view override returns (uint256) {
        return Math256.min(address(stakingVault()).balance, unreserved());
    }

    /**
     * @notice Sets the confirm expiry.
     * Confirm expiry is a period during which the confirm is counted. Once the period is over,
     * the confirm is considered expired, no longer counts and must be recasted.
     * @param _newConfirmExpiry The new confirm expiry in seconds.
     */
    function setConfirmExpiry(uint256 _newConfirmExpiry) external onlyConfirmed(_confirmingRoles()) {
        _setConfirmExpiry(_newConfirmExpiry);
    }

    /**
     * @notice Sets the node operator fee.
     * The node operator fee is the percentage (in basis points) of node operator's share of the StakingVault rewards.
     * The node operator fee cannot exceed 100%.
     * Note that the function reverts if the node operator fee is unclaimed and all the confirms must be recasted to execute it again,
     * which is why the deciding confirm must make sure that `nodeOperatorUnclaimedFee()` is 0 before calling this function.
     * @param _newNodeOperatorFeeBP The new node operator fee in basis points.
     */
    function setNodeOperatorFeeBP(uint256 _newNodeOperatorFeeBP) external onlyConfirmed(_confirmingRoles()) {
        if (_newNodeOperatorFeeBP > MAX_FEE_BP) revert FeeValueExceed100Percent();
        if (nodeOperatorUnclaimedFee() > 0) revert NodeOperatorFeeUnclaimed();
        uint256 oldNodeOperatorFeeBP = nodeOperatorFeeBP;
        nodeOperatorFeeBP = _newNodeOperatorFeeBP;

        emit NodeOperatorFeeBPSet(msg.sender, oldNodeOperatorFeeBP, _newNodeOperatorFeeBP);
    }

    /**
     * @notice Claims the node operator fee.
     * Note that the authorized role is NODE_OPERATOR_FEE_CLAIMER_ROLE, not NODE_OPERATOR_MANAGER_ROLE,
     * although NODE_OPERATOR_MANAGER_ROLE is the admin role for NODE_OPERATOR_FEE_CLAIMER_ROLE.
     * @param _recipient The address to which the node operator fee will be sent.
     */
    function claimNodeOperatorFee(address _recipient) external onlyRole(NODE_OPERATOR_FEE_CLAIM_ROLE) {
        uint256 fee = nodeOperatorUnclaimedFee();
        nodeOperatorFeeClaimedReport = stakingVault().latestReport();
        _claimFee(_recipient, fee);
    }

    /**
     * @notice Increases accrued rewards adjustment to correct fee calculation due to non-rewards ether on CL
     *         Note that the authorized role is NODE_OPERATOR_FEE_CLAIM_ROLE, not NODE_OPERATOR_MANAGER_ROLE,
     *         although NODE_OPERATOR_MANAGER_ROLE is the admin role for NODE_OPERATOR_FEE_CLAIM_ROLE.
     * @param _adjustmentIncrease amount to increase adjustment by
     * @dev will revert if final adjustment is more than `MANUAL_ACCRUED_REWARDS_ADJUSTMENT_LIMIT`
     */
    function increaseAccruedRewardsAdjustment(
        uint256 _adjustmentIncrease
    ) external onlyRole(NODE_OPERATOR_REWARDS_ADJUST_ROLE) {
        uint256 newAdjustment = accruedRewardsAdjustment + _adjustmentIncrease;
        // sanity check, though value will be cast safely during fee calculation
        if (newAdjustment > MANUAL_ACCRUED_REWARDS_ADJUSTMENT_LIMIT) revert IncreasedOverLimit();
        _setAccruedRewardsAdjustment(newAdjustment);
    }

    /**
     * @notice set `accruedRewardsAdjustment` to a new proposed value if `_confirmingRoles()` agree
     * @param _newAdjustment ew adjustment amount
     * @param _currentAdjustment current adjustment value for invalidating old confirmations
     * @dev will revert if new adjustment is more than `MANUAL_ACCRUED_REWARDS_ADJUSTMENT_LIMIT`
     */
    function setAccruedRewardsAdjustment(
        uint256 _newAdjustment,
        uint256 _currentAdjustment
    ) external onlyConfirmed(_confirmingRoles()) {
        if (accruedRewardsAdjustment != _currentAdjustment)
            revert InvalidatedAdjustmentVote(accruedRewardsAdjustment, _currentAdjustment);
        if (_newAdjustment > MANUAL_ACCRUED_REWARDS_ADJUSTMENT_LIMIT) revert IncreasedOverLimit();
        _setAccruedRewardsAdjustment(_newAdjustment);
    }

    /**
     *  @notice Withdraws ether from vault and deposits directly to provided validators bypassing the default PDG process,
     *          allowing validators to be proven post-factum via `proveUnknownValidatorsToPDG`
     *          clearing them for future top-up deposits via `PDG.depositToBeaconChain`.
     *          Additionally, increases accrued rewards adjustment by total amount of deposits to correct fee calculation
     * @param _deposits array of StakingVaultDeposit structs containing deposit data
     * @return totalAmount total amount of ether deposited to beacon chain
     * @dev requires the caller to have the `UNGUARANTEED_BEACON_CHAIN_DEPOSIT_ROLE`
     * @dev can be used as PDG shortcut if the node operator is trusted to not frontrun provided deposits
     */
    function unguaranteedDepositToBeaconChain(
        StakingVaultDeposit[] calldata _deposits
    ) public override returns (uint256 totalAmount) {
        totalAmount = super.unguaranteedDepositToBeaconChain(_deposits);

        _setAccruedRewardsAdjustment(accruedRewardsAdjustment + totalAmount);
    }

    // ==================== Internal Functions ====================

    /**
     * @dev Modifier that checks if the requested amount is less than or equal to the unreserved amount.
     * @param _ether The amount of ether to check.
     */
    modifier onlyIfUnreserved(uint256 _ether) {
        uint256 withdrawable = unreserved();
        if (_ether > withdrawable) revert RequestedAmountExceedsUnreserved();
        _;
    }

    /**
     * @dev Calculates the node operator fee amount based on the fee and the last claimed report.
     * @param _feeBP The fee in basis points.
     * @param _lastClaimedReport The last claimed report.
     * @return The accrued fee amount.
     */
    function _calculateFee(
        uint256 _feeBP,
        IStakingVault.Report memory _lastClaimedReport
    ) internal view returns (uint256) {
        IStakingVault.Report memory latestReport = stakingVault().latestReport();

        // cast down safely clamping to int128.max
        int128 adjustment = int128(int256(accruedRewardsAdjustment & ADJUSTMENT_CLAMP_MASK));

        int128 rewardsAccrued = int128(latestReport.valuation - _lastClaimedReport.valuation) -
            (latestReport.inOutDelta - _lastClaimedReport.inOutDelta) -
            adjustment;

        return rewardsAccrued > 0 ? (uint256(uint128(rewardsAccrued)) * _feeBP) / TOTAL_BASIS_POINTS : 0;
    }

    /**
     * @dev Claims the node operator fee amount.
     * @param _recipient The address to which the fee will be sent.
     * @param _fee The accrued fee amount.
     * @dev Use `Permissions._unsafeWithdraw()` to avoid the `WITHDRAW_ROLE` check.
     */
    function _claimFee(address _recipient, uint256 _fee) internal onlyIfUnreserved(_fee) {
        if (_recipient == address(0)) revert ZeroArgument("_recipient");
        if (_fee == 0) revert ZeroArgument("_fee");

        if (accruedRewardsAdjustment != 0) _setAccruedRewardsAdjustment(0);

        stakingVault().withdraw(_recipient, _fee);
    }

    /**
     * @notice sets InOut adjustment for correct fee calculation
     * @param _newAdjustment new adjustment value
     */
    function _setAccruedRewardsAdjustment(uint256 _newAdjustment) internal {
        uint256 oldAdjustment = accruedRewardsAdjustment;

        if (_newAdjustment == oldAdjustment) revert SameAdjustment();

        accruedRewardsAdjustment = _newAdjustment;

        emit AccruedRewardsAdjustmentSet(_newAdjustment, oldAdjustment);
    }

    /**
     * @notice Returns the roles that can:
     * - change the confirm expiry;
     * - set the node operator fee;
     * - set rewards adjustment
     * - transfer the ownership of the StakingVault.
     * @return roles is an array of roles that form the confirming roles.
     */
    function _confirmingRoles() internal pure override returns (bytes32[] memory roles) {
        roles = new bytes32[](2);
        roles[0] = DEFAULT_ADMIN_ROLE;
        roles[1] = NODE_OPERATOR_MANAGER_ROLE;
    }

    /**
     * @dev Overrides the Permissions' internal withdraw function to add a check for the unreserved amount.
     * Cannot withdraw more than the unreserved amount: which is the amount of ether
     * that is not locked in the StakingVault and not reserved for node operator fees.
     * Does not include a check for the balance of the StakingVault, this check is present
     * on the StakingVault itself.
     * @param _recipient The address to which the ether will be sent.
     * @param _ether The amount of ether to withdraw.
     */
    function _withdraw(address _recipient, uint256 _ether) internal override onlyIfUnreserved(_ether) {
        super._withdraw(_recipient, _ether);
    }

    // ==================== Events ====================

    /**
     * @dev Emitted when the node operator fee is set.
     * @param oldNodeOperatorFeeBP The old node operator fee.
     * @param newNodeOperatorFeeBP The new node operator fee.
     */
    event NodeOperatorFeeBPSet(address indexed sender, uint256 oldNodeOperatorFeeBP, uint256 newNodeOperatorFeeBP);

    /**
     * @dev Emitted when the new rewards adjustment is set.
     * @param newAdjustment the new adjustment value
     * @param oldAdjustment previous adjustment value
     */
    event AccruedRewardsAdjustmentSet(uint256 newAdjustment, uint256 oldAdjustment);

    // ==================== Errors ====================

    /**
     * @dev Error emitted when the node operator fee is unclaimed.
     */
    error NodeOperatorFeeUnclaimed();

    /**
     * @dev Error emitted when the combined feeBPs exceed 100%.
     */
    error FeeValueExceed100Percent();

    /**
     * @dev Error emitted when the requested amount exceeds the unreserved amount.
     */
    error RequestedAmountExceedsUnreserved();

    /**
     * @dev Error emitted when the increased adjustment exceeds the `MANUAL_ACCRUED_REWARDS_ADJUSTMENT_LIMIT`.
     */
    error IncreasedOverLimit();

    /**
     * @dev Error emitted when the adjustment setting vote is not valid due to changed state
     */
    error InvalidatedAdjustmentVote(uint256 currentAdjustment, uint256 currentAtPropositionAdjustment);

    /**
     * @dev Error emitted when trying to set same value for adjustment
     */
    error SameAdjustment();
}
