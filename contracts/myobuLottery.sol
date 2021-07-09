//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
import "./Standards/ERC721/ERC721.sol";
import "./Interfaces/IMyobuLottery.sol";
import "./Interfaces/IWETH.sol";
import "./Utils/Counters.sol";
import "./Chainlink/VRFConsumerBase.sol";

/**
 * @dev Uses chainlink on the Rinkeby Testnet.
 * VRF Coordinator: 0xb3dCcb4Cf7a26f6cf6B120Cf5A73875B7BBc655B
 * Chainlink token: 0x01BE23585060835E02B77ef475b0Cc51aA1e0709
 * Key Hash: 0x2ed0feb3e7fd2022120aa84fab1945545a9f2ffc9076fd6156fa96eaff4c1311
 * Fee: (not hardcoded, subject to change): 0.1 LINK
 */

/**
 * @title Myobu Lottery Contract
 * @author Myobu Devs
 */
contract MyobuLottery is
    VRFConsumerBase(
        0xb3dCcb4Cf7a26f6cf6B120Cf5A73875B7BBc655B,
        0x01BE23585060835E02B77ef475b0Cc51aA1e0709
    ),
    IMyobuLottery,
    ERC721("Myobu lottery ticket", "MLT")
{
    /// @dev Using counters for lottery ID's
    using Counters for Counters.Counter;

    /**
     * @dev
     * _myobu: The Myobu token contract
     * _WETH: The WETH contract used to wrap ETH
     * _chainlinkKeyHash: The chainlink key hash
     * _chainlinkFee: The amount of link to pay for random numbers
     * _feeReceiver: Where all the ticket sale fees will be sent to
     * _tokenID: Used to mint NFTs, increases for each NFT minted
     * _lastClaimedTokenID: Used to store the last tokenID that fees were claimed for
     * _rewardClaimed: Used to store if the reward has been claimed for the current lottery, resets per lottery
     * _inClaimReward: Used to store if its waiting for an oracle response, so claimReward() can't be called multiple times
     * and waste all the LINK in the contract
     * _lotteryID: A counter of how much lotteries there have been, increases by 1 each new lottery
     * _lottery: A mapping of Lottery ID => The lottery struct that stores information
     */
    IERC20 private _myobu;
    // solhint-disable-next-line
    IWETH private _WETH;
    bytes32 private _chainlinkKeyHash;
    uint256 private _chainlinkFee;
    address private _feeReceiver;
    uint256 private _tokenID;
    uint256 private _lastClaimedTokenID;
    bool private _rewardClaimed;
    bool private _inClaimReward;
    Counters.Counter private _lotteryID;
    mapping(uint256 => Lottery) private _lottery;

    /**
     * @dev Modifier that requires that there is no lottery ongoing (ended)
     */
    modifier onlyEnded {
        require(
            _lottery[_lotteryID.current()].endTimestamp <= block.timestamp,
            "MLT: Lottery needs to have ended for this"
        );
        _;
    }

    /**
     * @dev Modifier that requires that there is a lottery in progress (on)
     */
    modifier onlyOn {
        require(
            _lottery[_lotteryID.current()].endTimestamp > block.timestamp,
            "MLT: No lottery is on right now"
        );
        _;
    }

    /**
     * @dev Defines the Myobu and WETH token contracts, the chainlink fee and keyhash
     */
    constructor() {
        _myobu = IERC20(0x9d9884974dC707Da41d394B5D267Dd13364e9D3B);
        _feeReceiver = address(0x000000000000000000000000000000000000dEaD);
        _WETH = IWETH(0xc778417E063141139Fce010982780140Aa0cD5Ab);
        _chainlinkKeyHash = 0x2ed0feb3e7fd2022120aa84fab1945545a9f2ffc9076fd6156fa96eaff4c1311;
        _chainlinkFee = 0.1e18;
        /// @dev So the owner can be able to start the lottery
        _rewardClaimed = true;
        /// @dev Start token ID's at 1
        _tokenID = 1;
    }

    /**
     * @dev Attempt to transfer ETH, if failed wrap the ETH and send WETH. So that the
     * transfer always succeeds
     * @param to: The address to send ETH to
     * @param amount: The amount to send
     */
    function transferOrWrapETH(address to, uint256 amount) internal {
        // solhint-disable-next-line
        if (!payable(to).send(amount)) {
            _WETH.deposit{value: amount}();
            _WETH.transfer(to, amount);
        }
    }

    /**
     * @dev Buys tickets with ETH, requires that he has at least (_minimumMyobuBalance) myobu,
     * and then loops over how much tickets he needs and mints the ERC721 tokens
     * If there is too much ETH sent, refund unneeded ETH
     * Emits TicketsBought()
     */
    function buyTickets() external payable override onlyOn {
        uint256 ticketPrice = _lottery[_lotteryID.current()].ticketPrice;
        uint256 minimumMyobuBalance = _lottery[_lotteryID.current()]
        .minimumMyobuBalance;
        uint256 amountOfTickets = msg.value / ticketPrice;
        require(amountOfTickets != 0, "MLT: Not enough ETH");
        require(
            _myobu.balanceOf(_msgSender()) >= minimumMyobuBalance,
            "MLT: You don't have enough myobu"
        );
        uint256 neededETH = amountOfTickets * ticketPrice;
        /// @dev Refund unneeded eth
        if (msg.value > neededETH) {
            transferOrWrapETH(_msgSender(), msg.value - neededETH);
        }
        uint256 tokenID = _tokenID;
        _tokenID += amountOfTickets;
        for (uint256 i = tokenID; i < amountOfTickets + tokenID; i++) {
            _mint(_msgSender(), i);
        }
        emit TicketsBought(_msgSender(), amountOfTickets, ticketPrice);
    }

    /**
     * @return The amount of unclaimed fees, can be claimed using claimFees()
     */
    function unclaimedFees() public view override returns (uint256) {
        uint256 ticketFee = _lottery[_lotteryID.current()].ticketFee;
        uint256 ticketPrice = _lottery[_lotteryID.current()].ticketPrice;
        uint256 unclaimedTicketSales = _tokenID - _lastClaimedTokenID;
        return ((unclaimedTicketSales * ticketPrice) * ticketFee) / 10000;
    }

    /**
     * @dev Function that claims fees, saves gas so that its doesn't happen per ticket buy.
     * Emits FeesClaimed()
     */
    function claimFees() public override {
        uint256 fee = unclaimedFees();
        _lastClaimedTokenID = _tokenID;
        transferOrWrapETH(_feeReceiver, fee);
        emit FeesClaimed(fee, _msgSender());
    }

    /**
     * @dev Function that distributes the reward, requests for randomness, completes at fufillRandomness()
     * If nobody bought a ticket, makes rewardsClaimed true and returns nothing
     * Checks for _inClaimReward so that its not called more than once, wasting LINK.
     */
    function claimReward()
        external
        override
        onlyEnded
        returns (bytes32 requestId)
    {
        require(!_rewardClaimed, "MLT: Reward already claimed");
        require(!_inClaimReward, "MLT: Reward is being claimed");
        /// @dev So it doesn't fail if nobody bought any tickets
        if (_lottery[_lotteryID.current()].startingTokenID == _tokenID) {
            _rewardClaimed = true;
            return 0;
        }
        require(
            LINK.balanceOf(address(this)) >= _chainlinkFee,
            "MLT: Put some LINK into the contract"
        );
        _inClaimReward = true;
        return requestRandomness(_chainlinkKeyHash, _chainlinkFee);
    }

    /**
     * @dev Gets a winner and sends him his amount won in $ETH, if failed send WETH, if he doesn't have myobu at the time of winning
     * send the _feeReceiver the jackpot
     * Emits LotteryWon();
     */
    function fulfillRandomness(bytes32, uint256 randomness) internal override {
        /// @dev Get a random number in range of the token IDs
        uint256 x = _lottery[_lotteryID.current()].startingTokenID;
        uint256 y = _tokenID;
        /// @dev The winning token ID
        uint256 resultInRange = x + (randomness % (y - x));
        address winner = ownerOf(resultInRange);
        uint256 amountWon = jackpot();
        uint256 minimumMyobuBalance = _lottery[_lotteryID.current()]
        .minimumMyobuBalance;
        if (_myobu.balanceOf(winner) < minimumMyobuBalance) {
            /// @dev He sold his myobu, give the jackpot to the fee receiver.
            winner = _feeReceiver;
        }
        transferOrWrapETH(winner, amountWon);
        _rewardClaimed = true;
        delete _inClaimReward;
        emit LotteryWon(winner, amountWon, resultInRange);
    }

    /**
     * @dev Starts a new lottery, Can only be done by the owner.
     * Emits LotteryCreated()
     * @param lotteryLength: How long the lottery will be in seconds
     * @param ticketPrice: The price of a ticket in ETH
     * @param ticketFee: The percentage of the ticket price that is sent to the fee receiver
     * @param minimumMyobuBalance: The minimum amount of myobu someone needs to buy tickets or get the reward
     * @param percentageToKeepForNextLottery: The percentage that will be kept as reward for the lottery after
     */
    function createLottery(
        uint256 lotteryLength,
        uint256 ticketPrice,
        uint256 ticketFee,
        uint256 minimumMyobuBalance,
        uint256 percentageToKeepForNextLottery
    ) external onlyOwner onlyEnded {
        /// @dev Cannot execute it now, must be executed seperately
        require(
            _rewardClaimed,
            "MLT: Claim the reward before starting a new lottery"
        );
        require(
            percentageToKeepForNextLottery + ticketFee < 10000,
            "MLT: You can not take everything or more as a fee"
        );
        require(
            lotteryLength <= 2629744,
            "MLT: Must be under or equal to 1 month"
        );
        /// @dev Check if fees haven't been claimed, if they haven't claim them
        if (unclaimedFees() != 0) {
            claimFees();
        }
        /// @dev For the new lottery
        delete _rewardClaimed;
        _lotteryID.increment();
        uint256 newLotteryID = _lotteryID.current();
        _lottery[newLotteryID] = Lottery(
            _tokenID,
            block.timestamp,
            block.timestamp + lotteryLength,
            ticketPrice,
            ticketFee,
            minimumMyobuBalance,
            percentageToKeepForNextLottery
        );
        emit LotteryCreated(
            newLotteryID,
            lotteryLength,
            ticketPrice,
            ticketFee,
            minimumMyobuBalance,
            percentageToKeepForNextLottery
        );
    }

    /**
     * @return The current jackpot
     * @dev Balance - The percentage for the next lottery - Unclaimed Fees
     */
    function jackpot() public view override returns (uint256) {
        uint256 balance = address(this).balance;
        uint256 percentageToKeepForNextLottery = _lottery[_lotteryID.current()]
        .percentageToKeepForNextLottery;
        uint256 amountToKeepForNextLottery = (balance *
            percentageToKeepForNextLottery) / 10000;
        return balance - amountToKeepForNextLottery - unclaimedFees();
    }

    /**
     * @dev Function so that anyone can contribute to the jackpot when there is a lottery ongoing
     */
    // solhint-disable-next-line
    receive() external payable onlyOn {}

    /// @dev Getter functions : Start

    /**
     * @return The Myobu Token
     */
    function myobu() external view override returns (IERC20) {
        return _myobu;
    }

    /**
     * @return The amount of link to pay for a VRF call
     */
    function chainlinkFee() external view override returns (uint256) {
        return _chainlinkFee;
    }

    /**
     * @return Where all the ticket fees will be sent to
     */
    function feeReceiver() external view override returns (address) {
        return _feeReceiver;
    }

    /**
     * @return The current lottery ID
     */
    function currentLotteryID() external view override returns (uint256) {
        return _lotteryID.current();
    }

    /**
     * @return The info of a lottery (A struct)
     * See the Lottery struct for more info
     * @param lotteryID: The ID of the lottery to get info for
     */
    function lottery(uint256 lotteryID)
        external
        view
        override
        returns (Lottery memory)
    {
        return _lottery[lotteryID];
    }

    /**
     * @return Returns if the reward has been claimed, can only be viewed when there is no
     * lottery in progress or will return false.
     */
    function rewardClaimed() external view override onlyEnded returns (bool) {
        return _rewardClaimed;
    }

    /**
     * @return The last token ID fees have been claimed on for the current lottery
     */
    function lastClaimedTokenID() external view override returns (uint256) {
        return _lastClaimedTokenID;
    }

    /// @dev Getter functions : End

    /**
     * @dev If there is unneeded LINK in the contract, the owner can recover them using this function
     */
    function recoverLINK(uint256 amount) external onlyOwner {
        LINK.transfer(_msgSender(), amount);
    }

    /**
     * @dev In case the Myobu token gets changed later on, the owner can call this to change it
     * @param newMyobu: The new myobu token contract
     */
    function setMyobu(IERC20 newMyobu) external onlyOwner {
        _myobu = newMyobu;
    }

    /**
     * @dev Sets the address that receives all the fees
     * @param newFeeReceiver: The new address that will recieve all the fees
     */
    function setFeeReceiver(address newFeeReceiver) external onlyOwner {
        _feeReceiver = newFeeReceiver;
    }

    /**
     * @dev Changes the chainlink VRF oracle fee in case it needs to be changed later on
     * @param newChainlinkFee: The new amount of LINK to pay for a VRF Oracle call
     */
    function setChainlinkFee(uint256 newChainlinkFee) external onlyOwner {
        _chainlinkFee = newChainlinkFee;
    }

    /**
     * @dev Extends the duration of the current lottery and checks if its the new duration is over 1 month, reverts if it is
     * @param extraTime: The time in seconds to extend it by
     */
    function extendCurrentLottery(uint256 extraTime) external onlyOwner onlyOn {
        uint256 currentLotteryEnd = _lottery[_lotteryID.current()].endTimestamp;
        uint256 currentLotteryStart = _lottery[_lotteryID.current()]
        .startTimestamp;
        require(
            currentLotteryEnd + extraTime <= currentLotteryStart + 2629744,
            "MLT: Must be under or equal to 1 month"
        );
        _lottery[_lotteryID.current()].endTimestamp += extraTime;
    }
}
