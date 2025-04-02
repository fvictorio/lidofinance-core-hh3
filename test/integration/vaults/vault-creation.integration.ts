import { expect } from "chai";
import { ContractRunner, ContractTransactionReceipt } from "ethers";
import { ethers } from "hardhat";

import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";

import { Delegation, StakingVault } from "typechain-types";

import { certainAddress, days, ether, generatePredeposit, generateValidator, impersonate } from "lib";
import { getProtocolContext, getRandomSigners, ProtocolContext } from "lib/protocol";

import { Snapshot } from "test/suite";

import { connectToHub, setupLido } from "../../../lib/protocol/vaults";

const SAMPLE_PUBKEY = "0x" + "ab".repeat(48);
const VAULT_NODE_OPERATOR_FEE = 3_00n; // 3% node operator fee

const reserveRatio = 10_00n; // 10% of ETH allocation as reserve
const rebalanceThreshold = 8_00n; // 8% is a threshold to force rebalance on the vault

describe("Scenario: Vault creation", () => {
  let ctx: ProtocolContext;

  let delegation: Delegation;
  let stakingVault: StakingVault;
  let owner: HardhatEthersSigner,
    nodeOperatorManager: HardhatEthersSigner,
    funder: HardhatEthersSigner,
    withdrawer: HardhatEthersSigner,
    locker: HardhatEthersSigner,
    assetRecoverer: HardhatEthersSigner,
    minter: HardhatEthersSigner,
    burner: HardhatEthersSigner,
    rebalancer: HardhatEthersSigner,
    depositPausers: HardhatEthersSigner,
    depositResumers: HardhatEthersSigner,
    validatorExitRequesters: HardhatEthersSigner,
    validatorWithdrawalTriggerers: HardhatEthersSigner,
    disconnecters: HardhatEthersSigner,
    nodeOperatorFeeClaimers: HardhatEthersSigner,
    stranger: HardhatEthersSigner;

  let allRoles: HardhatEthersSigner[];
  let snapshot: string;
  let originalSnapshot: string;

  before(async () => {
    ctx = await getProtocolContext();

    originalSnapshot = await Snapshot.take();

    const { depositSecurityModule, stakingVaultFactory } = ctx.contracts;
    await depositSecurityModule.DEPOSIT_CONTRACT();

    allRoles = await getRandomSigners(20);
    [
      owner,
      nodeOperatorManager,
      assetRecoverer,
      funder,
      withdrawer,
      locker,
      minter,
      burner,
      rebalancer,
      depositPausers,
      depositResumers,
      validatorExitRequesters,
      validatorWithdrawalTriggerers,
      disconnecters,
      nodeOperatorFeeClaimers,
      stranger,
    ] = allRoles;

    // Owner can create a vault with operator as a node operator
    const deployTx = await stakingVaultFactory.connect(owner).createVaultWithDelegation(
      {
        defaultAdmin: owner,
        nodeOperatorManager: nodeOperatorManager,
        assetRecoverer: assetRecoverer,
        nodeOperatorFeeBP: VAULT_NODE_OPERATOR_FEE,
        confirmExpiry: days(7n),
        funders: [funder],
        withdrawers: [withdrawer],
        minters: [minter],
        lockers: [locker],
        burners: [burner],
        rebalancers: [rebalancer],
        depositPausers: [depositPausers],
        depositResumers: [depositResumers],
        validatorExitRequesters: [validatorExitRequesters],
        validatorWithdrawalTriggerers: [validatorWithdrawalTriggerers],
        disconnecters: [disconnecters],
        nodeOperatorFeeClaimers: [nodeOperatorFeeClaimers],
      },
      "0x",
    );
    const createVaultTxReceipt = (await deployTx.wait()) as ContractTransactionReceipt;
    const createVaultEvents = ctx.getEvents(createVaultTxReceipt, "VaultCreated");

    expect(createVaultEvents.length).to.equal(1n);

    stakingVault = await ethers.getContractAt("StakingVault", createVaultEvents[0].args?.vault);
    delegation = await ethers.getContractAt("Delegation", createVaultEvents[0].args?.owner);
    await setupLido(ctx);
    // only equivalent of 10.0% of TVL can be minted as stETH on the vault
  });

  beforeEach(async () => (snapshot = await Snapshot.take()));

  afterEach(async () => await Snapshot.restore(snapshot));

  after(async () => await Snapshot.restore(originalSnapshot));

  async function generateFeesToClaim() {
    const { vaultHub } = ctx.contracts;
    const hubSigner = await impersonate(await vaultHub.getAddress(), ether("100"));
    const rewards = ether("1");
    await stakingVault.connect(hubSigner).report(rewards, 0n, 0n);
  }

  it("Allows withdrawer role to fund an withdraw funds for dedicated roles", async () => {
    await expect(delegation.connect(funder).fund({ value: 2n }))
      .to.emit(stakingVault, "Funded")
      .withArgs(delegation, 2n);

    expect(await delegation.connect(owner).withdrawableEther()).to.equal(2n);

    await expect(await delegation.connect(withdrawer).withdraw(stranger, 2n))
      .to.emit(stakingVault, "Withdrawn")
      .withArgs(delegation, stranger, 2n);
    expect(await delegation.connect(owner).withdrawableEther()).to.equal(0);
  });

  it("Allows deposit pauser/resumer role to pause/resume deposits to validators", async () => {
    await expect(delegation.connect(depositPausers).pauseBeaconChainDeposits()).to.emit(
      stakingVault,
      "BeaconChainDepositsPaused",
    );
    await expect(delegation.connect(depositResumers).resumeBeaconChainDeposits()).to.emit(
      stakingVault,
      "BeaconChainDepositsResumed",
    );
  });

  it("Allows  vault owner to ask Node Operator to withdraw funds from validator(s)", async () => {
    const vaultOwnerAddress = await stakingVault.owner();
    const vaultOwner: ContractRunner = await impersonate(vaultOwnerAddress, ether("10000"));
    await expect(stakingVault.connect(vaultOwner).requestValidatorExit(SAMPLE_PUBKEY))
      .to.emit(stakingVault, "ValidatorExitRequested")
      .withArgs(vaultOwner, SAMPLE_PUBKEY, SAMPLE_PUBKEY);
  });

  it("Allows vault owner to trigger validator withdrawal", async () => {
    const vaultOwnerAddress = await stakingVault.owner();
    const vaultOwner: ContractRunner = await impersonate(vaultOwnerAddress, ether("10000"));

    await expect(
      stakingVault
        .connect(vaultOwner)
        .triggerValidatorWithdrawal(SAMPLE_PUBKEY, [ether("1")], vaultOwnerAddress, { value: 1n }),
    )
      .to.emit(stakingVault, "ValidatorWithdrawalTriggered")
      .withArgs(vaultOwnerAddress, SAMPLE_PUBKEY, [ether("1")], vaultOwnerAddress, 0);
  });

  it("Allows NO Fee claimer role to claim NO's fee", async () => {
    await delegation.connect(funder).fund({ value: ether("1") });
    await delegation.connect(nodeOperatorManager).setNodeOperatorFeeBP(1n);
    await delegation.connect(owner).setNodeOperatorFeeBP(1n);

    await expect(
      delegation.connect(nodeOperatorFeeClaimers).claimNodeOperatorFee(stranger),
    ).to.be.revertedWithCustomError(ctx.contracts.vaultHub, "ZeroArgument");

    await generateFeesToClaim();

    await expect(delegation.connect(nodeOperatorFeeClaimers).claimNodeOperatorFee(stranger))
      .to.emit(stakingVault, "Withdrawn")
      .withArgs(delegation, stranger, 100000000000000n);
  });

  describe("Reverts stETH related actions when not connected to hub", () => {
    it("Reverts on minting stETH", async () => {
      await delegation.connect(funder).fund({ value: ether("1") });
      await delegation.connect(owner).grantRole(await delegation.LOCK_ROLE(), minter.address);

      await expect(delegation.connect(minter).mintStETH(locker, 1n)).to.be.revertedWithCustomError(
        ctx.contracts.vaultHub,
        "NotConnectedToHub",
      );
    });

    it("Reverts on burning stETH", async () => {
      const { lido, vaultHub, locator } = ctx.contracts;

      // suppose user somehow got 1 share and tries to burn it via the delegation contract on disconnected vault
      const accountingSigner = await impersonate(await locator.accounting(), ether("1"));
      await lido.connect(accountingSigner).mintShares(burner, 1n);

      await expect(delegation.connect(burner).burnStETH(1n)).to.be.revertedWithCustomError(
        vaultHub,
        "NotConnectedToHub",
      );
    });
  });

  describe("Allows stETH related actions only after connecting to Hub", () => {
    beforeEach(async () => {
      // adding some stETH to be able to call getTotalShares to get shareLimit
      await delegation.connect(funder).fund({ value: ether("1") });
      await delegation.connect(locker).lock(ether("1"));

      const treasuryFeeBP = 5_00n; // 5% of the treasury fee
      const shareLimit = (await ctx.contracts.lido.getTotalShares()) / 10n; // 10% of total shares

      await connectToHub(ctx, stakingVault, { reserveRatio, treasuryFeeBP, rebalanceThreshold, shareLimit });
    });

    it("Allows Minter role to mint stETH", async () => {
      const { vaultHub } = ctx.contracts;

      // add some stETH to the vault to have valuation
      await delegation.connect(funder).fund({ value: ether("1") });

      await expect(delegation.connect(minter).mintStETH(stranger, 1n))
        .to.emit(vaultHub, "MintedSharesOnVault")
        .withArgs(stakingVault, 1n);
    });

    it("Allows Burner role to burn stETH", async () => {
      const { vaultHub, lido } = ctx.contracts;

      // add some stETH to the vault to have valuation, mint shares and approve stETH
      await delegation.connect(funder).fund({ value: ether("1") });
      await delegation.connect(minter).mintStETH(burner, 1n);
      await lido.connect(burner).approve(delegation, 1n);

      await expect(delegation.connect(burner).burnStETH(1n))
        .to.emit(vaultHub, "BurnedSharesOnVault")
        .withArgs(stakingVault, 1n);
    });
  });

  it("NO Manager can spawn a validator using ETH from the Vault ", async () => {
    const pdg = ctx.contracts.predepositGuarantee.connect(nodeOperatorManager);

    await delegation.connect(funder).fund({ value: ether("32") });

    await pdg.topUpNodeOperatorBalance(nodeOperatorManager, { value: ether("1") });

    const vaultWC = await stakingVault.withdrawalCredentials();
    const validator = generateValidator(vaultWC);
    const predepositData = generatePredeposit(validator);

    await expect(pdg.predeposit(stakingVault, [predepositData]))
      .to.emit(stakingVault, "DepositedToBeaconChain")
      .withArgs(ctx.contracts.predepositGuarantee.address, 1, 1000000000000000000n);
  });

  it("NO manager and Vault owner can vote for transferring ownership of the vault", async () => {
    const newOwner = certainAddress("new-owner");

    await expect(await delegation.connect(nodeOperatorManager).transferStakingVaultOwnership(newOwner)).to.emit(
      delegation,
      "RoleMemberConfirmed",
    );

    await expect(delegation.connect(owner).transferStakingVaultOwnership(newOwner))
      .to.emit(stakingVault, "OwnershipTransferred")
      .withArgs(delegation, newOwner);

    expect(await stakingVault.owner()).to.equal(newOwner);
  });
});
