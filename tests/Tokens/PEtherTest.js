const {
  etherUnsigned,
  etherMantissa,
  UInt256Max
} = require('../Utils/Ethereum');

const {
  makeRegistryProxy,
  makePToken,
  setBorrowRate,
  pretendBorrow
} = require('../Utils/DeFiPie');

const blocksPerYear = 2102400;

describe('PEther', function () {
  let root, admin, accounts;
  beforeEach(async () => {
    [root, admin, ...accounts] = saddle.accounts;
  });

  describe('constructor', () => {
    it("fails when 0 initial exchange rate", async () => {
      await expect(makePToken({ kind: 'pether', exchangeRate: 0 })).rejects.toRevert("revert initial exchange rate must be greater than zero.");
    });

    it("succeeds with erc-20 underlying and non-zero exchange rate", async () => {
      const pToken = await makePToken({ kind: 'pether'});
      expect(await call(pToken, 'getMyAdmin')).toEqual(root);
    });

    it("succeeds what admin in pToken contract from registry", async () => {
        const pToken = await makePToken({ kind: 'pether'});
        const registryAddress = await call(pToken, 'registry');
        const registry = await saddle.getContractAt('RegistryHarness', registryAddress);
        const admin = await call(registry, 'admin');
        expect(await call(pToken, 'getMyAdmin')).toEqual(admin);
    });
  });

  describe('name, symbol, decimals', () => {
    let pToken;

    beforeEach(async () => {
      pToken = await makePToken({ kind: 'pether'});
    });

    it('should return correct name', async () => {
      expect(await call(pToken, 'name')).toEqual("DeFiPie ETH");
    });

    it('should return correct symbol', async () => {
      expect(await call(pToken, 'symbol')).toEqual("pETH");
    });

    it('should return correct decimals', async () => {
        expect(await call(pToken, 'decimals')).toEqualNumber(8);
    });
  });

  describe('balanceOfUnderlying', () => {
    it("has an underlying balance", async () => {
      const pToken = await makePToken({ kind: 'pether', supportMarket: true, exchangeRate: 2 });
      await send(pToken, 'harnessSetBalance', [root, 100]);
      expect(await call(pToken, 'balanceOfUnderlying', [root])).toEqualNumber(2e12); // 1e8 = 2e18, 100 = 2e12
    });
  });

  describe('borrowRatePerBlock', () => {
    it("has a borrow rate", async () => {
      const pToken = await makePToken({ kind: 'pether', supportMarket: true, interestRateModelOpts: { kind: 'jump-rate', baseRate: .05, multiplier: 0.45, kink: 0.95, jump: 5 } });
      const perBlock = await call(pToken, 'borrowRatePerBlock');
      expect(Math.abs(perBlock * blocksPerYear - 5e16)).toBeLessThanOrEqual(1e8);
    });
  });

  describe('supplyRatePerBlock', () => {
    it("returns 0 if there's no supply", async () => {
      const pToken = await makePToken({ kind: 'pether', supportMarket: true, interestRateModelOpts: { kind: 'jump-rate', baseRate: .05, multiplier: 0.45, kink: 0.95, jump: 5 } });
      const perBlock = await call(pToken, 'supplyRatePerBlock');
      await expect(perBlock).toEqualNumber(0);
    });

    it("has a supply rate", async () => {
      const baseRate = 0.05;
      const multiplier = 0.45;
      const kink = 0.95;
      const jump = 5 * multiplier;
      const pToken = await makePToken({ kind: 'pether', supportMarket: true, interestRateModelOpts: { kind: 'jump-rate', baseRate, multiplier, kink, jump } });
      await send(pToken, 'harnessSetReserveFactorFresh', [etherMantissa(.01)]);
      await send(pToken, 'harnessExchangeRateDetails', [1, 1, 0]);
      await send(pToken, 'harnessSetExchangeRate', [etherMantissa(1)]);
      // Full utilization (Over the kink so jump is included), 1% reserves
      const borrowRate = baseRate + multiplier * kink + jump * .05;
      const expectedSuplyRate = borrowRate * .99;

      const perBlock = await call(pToken, 'supplyRatePerBlock');
      expect(Math.abs(perBlock * blocksPerYear - expectedSuplyRate * 1e18)).toBeLessThanOrEqual(1e8);
    });
  });

  describe("borrowBalanceCurrent", () => {
    let borrower;
    let pToken;

    beforeEach(async () => {
      borrower = accounts[0];
      pToken = await makePToken({kind: 'pether'});
    });

    beforeEach(async () => {
      await setBorrowRate(pToken, .001);
      await send(pToken.interestRateModel, 'setFailBorrowRate', [false]);
    });

    it("reverts if interest accrual fails", async () => {
      await send(pToken.interestRateModel, 'setFailBorrowRate', [true]);
      // make sure we accrue interest
      await send(pToken, 'harnessFastForward', [1]);
      await expect(send(pToken, 'borrowBalanceCurrent', [borrower])).rejects.toRevert("revert INTEREST_RATE_MODEL_ERROR");
    });

    it("returns successful result from borrowBalanceStored with no interest", async () => {
      await setBorrowRate(pToken, 0);
      await pretendBorrow(pToken, borrower, 1, 1, 5e18);
      expect(await call(pToken, 'borrowBalanceCurrent', [borrower])).toEqualNumber(5e18)
    });

    it("returns successful result from borrowBalanceCurrent with no interest", async () => {
      await setBorrowRate(pToken, 0);
      await pretendBorrow(pToken, borrower, 1, 3, 5e18);
      expect(await send(pToken, 'harnessFastForward', [5])).toSucceed();
      expect(await call(pToken, 'borrowBalanceCurrent', [borrower])).toEqualNumber(5e18 * 3)
    });
  });

  describe("borrowBalanceStored", () => {
    let borrower;
    let pToken;

    beforeEach(async () => {
      borrower = accounts[0];
      pToken = await makePToken({ kind: 'pether', controllerOpts: { kind: 'bool' } });
    });

    it("returns 0 for account with no borrows", async () => {
      expect(await call(pToken, 'borrowBalanceStored', [borrower])).toEqualNumber(0)
    });

    it("returns stored principal when account and market indexes are the same", async () => {
      await pretendBorrow(pToken, borrower, 1, 1, 5e18);
      expect(await call(pToken, 'borrowBalanceStored', [borrower])).toEqualNumber(5e18);
    });

    it("returns calculated balance when market index is higher than account index", async () => {
      await pretendBorrow(pToken, borrower, 1, 3, 5e18);
      expect(await call(pToken, 'borrowBalanceStored', [borrower])).toEqualNumber(5e18 * 3);
    });

    it("has undefined behavior when market index is lower than account index", async () => {
      // The market index < account index should NEVER happen, so we don't test this case
    });

    it("reverts on overflow of principal", async () => {
      await pretendBorrow(pToken, borrower, 1, 3, UInt256Max());
      await expect(call(pToken, 'borrowBalanceStored', [borrower])).rejects.toRevert("revert borrowBalanceStored: borrowBalanceStoredInternal failed");
    });

    it("reverts on non-zero stored principal with zero account index", async () => {
      await pretendBorrow(pToken, borrower, 0, 3, 5);
      await expect(call(pToken, 'borrowBalanceStored', [borrower])).rejects.toRevert("revert borrowBalanceStored: borrowBalanceStoredInternal failed");
    });
  });

  describe('exchangeRateStored', () => {
    let pToken, exchangeRate = 2;

    beforeEach(async () => {
      pToken = await makePToken({ kind: 'pether', exchangeRate });
    });

    it("returns initial exchange rate with zero pTokenSupply", async () => {
      const result = await call(pToken, 'exchangeRateStored');
      expect(result).toEqualNumber(2e28); // init exchangeRate = 1e18, pie decimals is 18, ppie decimals is 8, result 1e28
    });

    it("calculates with single pTokenSupply and single total borrow", async () => {
      const pTokenSupply = 1, totalBorrows = 1, totalReserves = 0;
      await send(pToken, 'harnessExchangeRateDetails', [pTokenSupply, totalBorrows, totalReserves]);
      const result = await call(pToken, 'exchangeRateStored');
      expect(result).toEqualNumber(etherMantissa(1));
    });

    it("calculates with pTokenSupply and total borrows", async () => {
      const pTokenSupply = 100e18, totalBorrows = 10e18, totalReserves = 0;
      await send(pToken, 'harnessExchangeRateDetails', [pTokenSupply, totalBorrows, totalReserves].map(etherUnsigned));
      const result = await call(pToken, 'exchangeRateStored');
      expect(result).toEqualNumber(etherMantissa(.1));
    });

    it("calculates with cash and pTokenSupply", async () => {
      const pTokenSupply = 5e16, totalBorrows = 0, totalReserves = 0;
      expect(
          await send(pToken, 'harnessDoTransferIn', [root, etherMantissa(5)], {value: 5000000000000000000})
      ).toSucceed();
      await send(pToken, 'harnessExchangeRateDetails', [pTokenSupply, totalBorrows, totalReserves].map(etherUnsigned));
      const result = await call(pToken, 'exchangeRateStored');
      expect(result).toEqualNumber(etherMantissa(100));
    });

    it("calculates with cash, borrows, reserves and pTokenSupply", async () => {
      const pTokenSupply = 5e18, totalBorrows = 5e18, totalReserves = 5e16;
      expect(
          await send(pToken, 'harnessDoTransferIn', [root, etherMantissa(5)], {value: 5000000000000000000})
      ).toSucceed();
      await send(pToken, 'harnessExchangeRateDetails', [pTokenSupply, totalBorrows, totalReserves].map(etherUnsigned));
      const result = await call(pToken, 'exchangeRateStored');
      expect(result).toEqualNumber(etherMantissa(1.99));
    });
  });

  describe('getCash', () => {
    it("gets the cash", async () => {
      const pToken = await makePToken({kind: 'pether'});
      const result = await call(pToken, 'getCash');
      expect(result).toEqualNumber(0);
    });
  });

  describe('add reserves', () => {
    it("add reserves", async () => {
      const pToken = await makePToken({kind: 'pether'});

      const value = 100;
      await send (pToken, '_addReserves', {value: value});
      const result = await call(pToken, 'getCash');
      expect(result).toEqualNumber(value);
    });
  });

  describe("implementation address", () => {
    it("set implementation address", async () => {
        let registryProxy = await makeRegistryProxy();
        let pToken = await makePToken({kind: 'pether', registryProxy: registryProxy});

        pToken = await saddle.getContractAt('PETHDelegator', pToken._address);
        let admin = await call(registryProxy, "admin");

        await send(pToken, '_setImplementation', [accounts[1]], {from: admin});
        expect(await call(pToken, 'implementation')).toEqual(accounts[1]);
    });

    it("set implementation address, not UNAUTHORIZED", async () => {
        let pToken = await makePToken({kind: 'pether'});

        pToken = await saddle.getContractAt('PETHDelegator', pToken._address);

        let result = await send(pToken, '_setImplementation', [accounts[2]], {from: accounts[2]});
        expect(result).toHaveTokenFailure('UNAUTHORIZED', 'SET_NEW_IMPLEMENTATION');
    });
  });
});
