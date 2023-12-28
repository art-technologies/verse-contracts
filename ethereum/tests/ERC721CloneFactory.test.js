const { ethers } = require("hardhat");
const { expect } = require("chai");


describe("LondonTokenFactory", function () {

    let deployer;
    let signer1;
    let signer2;

    before(async function () {
        // Get signers/accounts
        const signers = await ethers.getUnnamedSigners();
        [deployer, signer1, signer2] = signers;
    });

    before(async function() {
        this.accounts = await ethers.getSigners();
        [deployer, signer1, signer2] = await ethers.getSigners();
    });

    describe("Base", function() {
        it("deploy base", async function() {
            const factoryContract = await ethers.getContractFactory("LondonTokenFactory");
            this.factory = await factoryContract.connect(deployer).deploy(...params).then(f => f.deployed());
        })
    })
});