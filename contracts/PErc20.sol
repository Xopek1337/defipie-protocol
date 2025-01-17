// SPDX-License-Identifier: MIT
pragma solidity ^0.7.6;

import "./PToken.sol";
import "./RegistryInterface.sol";

/**
 * @title DeFiPie's PErc20 Contract
 * @notice PTokens which wrap an EIP-20 underlying
 * @author DeFiPie
 */
contract PErc20 is PToken, PErc20Interface, PErc20ExtInterface {
    /**
     * @notice Initialize the new money market
     * @param underlying_ The address of the underlying asset
     * @param registry_ The address of the Registry
     * @param controller_ The address of the Controller
     * @param interestRateModel_ The address of the interest rate model
     * @param initialExchangeRateMantissa_ The initial exchange rate, scaled by 1e18
     * @param initialReserveFactorMantissa_ The initial reserve factor, scaled by 1e18
     * @param name_ ERC-20 name of this token
     * @param symbol_ ERC-20 symbol of this token
     * @param decimals_ ERC-20 decimal precision of this token
     */
    function initialize(
        address underlying_,
        RegistryInterface registry_,
        ControllerInterface controller_,
        InterestRateModel interestRateModel_,
        uint initialExchangeRateMantissa_,
        uint initialReserveFactorMantissa_,
        string memory name_,
        string memory symbol_,
        uint8 decimals_
    ) public {

        // PToken initialize does the bulk of the work
        super.initialize(registry_, controller_, interestRateModel_, initialExchangeRateMantissa_, initialReserveFactorMantissa_, name_, symbol_, decimals_);

        // Set underlying and sanity check it
        underlying = underlying_;
        EIP20Interface(underlying).totalSupply();

        startBorrowTimestamp = block.timestamp + controller.getBorrowDelay();
    }

    /*** User Interface ***/

    /**
     * @notice Sender supplies assets into the market and receives pTokens in exchange
     * @dev Accrues interest whether or not the operation succeeds, unless reverted
     * @param mintAmount The amount of the underlying asset to supply
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function mint(uint mintAmount) external override returns (uint) {
        (uint err,,) = mintInternal(mintAmount);
        return err;
    }

    function mintFresh(address minter, uint mintAmount) internal override returns (uint, uint, uint) {
        (uint error, uint actualMintAmount, uint mintTokens) = super.mintFresh(minter, mintAmount);

        // for fee token only
        if (error == uint(Error.NO_ERROR) && mintAmount != actualMintAmount) {
            updateFeeFactor(mintAmount, actualMintAmount);
        }

        return (error, actualMintAmount, mintTokens);
    }

    /**
     * @notice Sender redeems pTokens in exchange for the underlying asset
     * @dev Accrues interest whether or not the operation succeeds, unless reverted
     * @param redeemTokens The number of pTokens to redeem into underlying
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function redeem(uint redeemTokens) external override returns (uint) {
        (uint err,) = redeemInternal(redeemTokens);
        return err;
    }

    /**
     * @notice Sender redeems pTokens in exchange for a specified amount of underlying asset
     * @dev Accrues interest whether or not the operation succeeds, unless reverted
     * @param redeemAmount The amount of underlying to redeem
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function redeemUnderlying(uint redeemAmount) external override returns (uint) {
        (uint err,) = redeemUnderlyingInternal(redeemAmount);
        return err;
    }

    /**
      * @notice Sender borrows assets from the protocol to their own address
      * @param borrowAmount The amount of the underlying asset to borrow
      * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
      */
    function borrow(uint borrowAmount) external override returns (uint) {
        require(block.timestamp >= startBorrowTimestamp, "PErc20::borrow: borrow is not started");
        return borrowInternal(borrowAmount);
    }

    /**
     * @notice Sender repays their own borrow
     * @param repayAmount The amount to repay
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function repayBorrow(uint repayAmount) external override returns (uint) {
        (uint err,,) = repayBorrowInternal(repayAmount);
        return err;
    }

    /**
     * @notice Sender repays a borrow belonging to borrower
     * @param borrower the account with the debt being payed off
     * @param repayAmount The amount to repay
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function repayBorrowBehalf(address borrower, uint repayAmount) external override returns (uint) {
        (uint err,,) = repayBorrowBehalfInternal(borrower, repayAmount);
        return err;
    }

    /**
     * @notice Borrows are repaid by another user (possibly the borrower).
     * @param payer the account paying off the borrow
     * @param borrower the account with the debt being payed off
     * @param repayAmount the amount of undelrying tokens being returned
     * @return (uint, uint) An error code (0=success, otherwise a failure, see ErrorReporter.sol), the actual repayment amount and transfer amount from msg.sender
     */
    function repayBorrowFresh(address payer, address borrower, uint repayAmount) internal override returns (uint, uint, uint) {
        (uint error, uint actualRepayAmount, uint transferRepayAmount) = super.repayBorrowFresh(payer, borrower, repayAmount);

        // for fee token only
        if (error == uint(Error.NO_ERROR) && transferRepayAmount != actualRepayAmount) {
            updateFeeFactor(transferRepayAmount, actualRepayAmount);
        }

        return (error, actualRepayAmount, transferRepayAmount);
    }

    function updateFeeFactor(uint userTransferAmount, uint receiveFromUser) internal {
        /* Calculate fee factor:
         *  fee factor = 1e18 - receiveFromUser * 1e18 / userTransferAmount
         *  for example 1e18 - 85 * 1e18 / 100 = 1e18 - 0.85e18 = 0.15e18
         */
        uint calcFeeFactorMantissa = sub_(1e18, div_(mul_(receiveFromUser, 1e18), userTransferAmount));
        uint currentFeeFactor = controller.getFeeFactorMantissa(address(this));

        if (calcFeeFactorMantissa != currentFeeFactor) {
            if (currentFeeFactor == 0 || calcFeeFactorMantissa % 10000 == 0 || userTransferAmount > 10000) {
                controller._setFeeFactor(address(this), calcFeeFactorMantissa);
            }
        }
    }

    /**
     * @notice The sender liquidates the borrowers collateral.
     * The collateral seized is transferred to the liquidator.
     * @param borrower The borrower of this pToken to be liquidated
     * @param repayAmount The amount of the underlying borrowed asset to repay
     * @param pTokenCollateral The market in which to seize collateral from the borrower
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function liquidateBorrow(address borrower, uint repayAmount, PTokenInterface pTokenCollateral) external override returns (uint) {
        (uint err,) = liquidateBorrowInternal(borrower, repayAmount, pTokenCollateral);
        return err;
    }

    /**
     * @notice The sender adds to reserves.
     * @param addAmount The amount of underlying token to add as reserves
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function _addReserves(uint addAmount) external override returns (uint) {
        return _addReservesInternal(addAmount);
    }

    /*** Safe Token ***/

    /**
     * @notice Gets balance of this contract in terms of the underlying
     * @dev This excludes the value of the current message, if any
     * @return The quantity of underlying tokens owned by this contract
     */
    function getCashPrior() internal view override returns (uint) {
        EIP20Interface token = EIP20Interface(underlying);
        return token.balanceOf(address(this));
    }

    /**
     * @dev Similar to EIP20 transfer, except it handles a False result from `transferFrom` and reverts in that case.
     *      This will revert due to insufficient balance or insufficient allowance.
     *      This function returns the actual amount received,
     *      which may be less than `amount` if there is a fee attached to the transfer.
     *
     *      Note: This wrapper safely handles non-standard ERC-20 tokens that do not return a value.
     *            See here: https://medium.com/coinmonks/missing-return-value-bug-at-least-130-tokens-affected-d67bf08521ca
     */
    function doTransferIn(address from, uint amount) internal override returns (uint) {
        EIP20NonStandardInterface token = EIP20NonStandardInterface(underlying);
        uint balanceBefore = EIP20Interface(underlying).balanceOf(address(this));
        token.transferFrom(from, address(this), amount);

        bool success;
        assembly {
            switch returndatasize()
            case 0 {                       // This is a non-standard ERC-20
                success := not(0)          // set success to true
            }
            case 32 {                      // This is a compliant ERC-20
                returndatacopy(0, 0, 32)
                success := mload(0)        // Set `success = returndata` of external call
            }
            default {                      // This is an excessively non-compliant ERC-20, revert.
                revert(0, 0)
            }
        }
        require(success, "TOKEN_TRANSFER_IN_FAILED");

        // Calculate the amount that was *actually* transferred
        uint balanceAfter = EIP20Interface(underlying).balanceOf(address(this));
        require(balanceAfter >= balanceBefore, "TOKEN_TRANSFER_IN_OVERFLOW");
        return balanceAfter - balanceBefore;   // underflow already checked above, just subtract
    }

    /**
     * @dev Similar to EIP20 transfer, except it handles a False success from `transfer` and returns an explanatory
     *      error code rather than reverting. If caller has not called checked protocol's balance, this may revert due to
     *      insufficient cash held in this contract. If caller has checked protocol's balance prior to this call, and verified
     *      it is >= amount, this should not revert in normal conditions.
     *
     *      Note: This wrapper safely handles non-standard ERC-20 tokens that do not return a value.
     *            See here: https://medium.com/coinmonks/missing-return-value-bug-at-least-130-tokens-affected-d67bf08521ca
     */
    function doTransferOut(address payable to, uint amount) internal virtual override {
        EIP20NonStandardInterface token = EIP20NonStandardInterface(underlying);
        token.transfer(to, amount);

        bool success;
        assembly {
            switch returndatasize()
            case 0 {                      // This is a non-standard ERC-20
                success := not(0)          // set success to true
            }
            case 32 {                     // This is a complaint ERC-20
                returndatacopy(0, 0, 32)
                success := mload(0)        // Set `success = returndata` of external call
            }
            default {                     // This is an excessively non-compliant ERC-20, revert.
                revert(0, 0)
            }
        }
        require(success, "TOKEN_TRANSFER_OUT_FAILED");
    }
}