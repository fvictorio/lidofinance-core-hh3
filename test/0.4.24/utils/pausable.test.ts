import { expect } from "chai";
import { ethers } from "hardhat";

import { PausableMockWithExposedApi } from "typechain-types";

describe("Pausable", () => {
  let pausable: PausableMockWithExposedApi;

  beforeEach(async () => {
    pausable = await ethers.deployContract("PausableMockWithExposedApi");
    expect(await pausable.isStopped()).to.equal(true);
  });

  context("isStopped", () => {
    it("Returns true if stopped", async () => {
      expect(await pausable.isStopped()).to.equal(true);
    });

    it("Returns false if not stopped", async () => {
      await expect(pausable.resume()).to.emit(pausable, "Resumed");

      expect(await pausable.isStopped()).to.equal(false);
    });
  });

  context("resume", async () => {
    it("Resumes the contract", async () => {
      await expect(pausable.resume()).to.emit(pausable, "Resumed");
      expect(await pausable.isStopped()).to.equal(false);
    });

    it("Reverts if already resumed", async () => {
      await expect(pausable.resume()).to.emit(pausable, "Resumed");

      await expect(pausable.resume()).to.be.revertedWith("CONTRACT_IS_ACTIVE");
      expect(await pausable.isStopped()).to.equal(false);
    });
  });

  context("stop", async () => {
    beforeEach(async () => {
      await expect(pausable.resume()).to.emit(pausable, "Resumed");
    });

    it("Stops the contract", async () => {
      await expect(pausable.stop()).to.emit(pausable, "Stopped");
      expect(await pausable.isStopped()).to.equal(true);
    });

    it("Reverts if already stopped", async () => {
      await expect(pausable.stop()).to.emit(pausable, "Stopped");

      await expect(pausable.stop()).to.be.revertedWith("CONTRACT_IS_STOPPED");
      expect(await pausable.isStopped()).to.equal(true);
    });
  });
});
