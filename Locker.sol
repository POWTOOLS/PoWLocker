// SPDX-License-Identifier: MIT
pragma solidity >=0.7.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract PowLocker is Ownable, ReentrancyGuard {
    using SafeMath for uint256;

    struct Items {
        address tokenAddress;
        address withdrawalAddress;
        uint256 tokenAmount;
        uint256 withdrawn;
        uint256 unlockTime;
    }

    uint256 public ethFee = 2 ether;
    // base 1000, 0.5% = value * 5 / 1000
    uint256 public lpFeePercent = 10;
    address payable public feeWithdrawalAddress;

    // for statistic
    uint256 public totalEthFees = 2 ether;

    uint256 public depositId;
    uint256[] public allDepositIds;

    mapping(uint256 => Items) public lockedToken;

    mapping(address => uint256[]) public depositsByWithdrawalAddress;
    mapping(address => uint256[]) public depositsByTokenAddress;

    // Token -> { sender1: locked amount, ... }
    mapping(address => mapping(address => uint256)) public walletTokenBalance;

    event Log(string message);
    event LogBytes(bytes data);
    event TokensLocked(
        address indexed tokenAddress,
        address indexed sender,
        uint256 amount,
        uint256 unlockTime,
        uint256 depositId
    );
    event TokensWithdrawn(
        address indexed tokenAddress,
        address indexed receiver,
        uint256 amount
    );
    event TransferLockOwnership(
        uint256 depositId,
        address indexed sender,
        address indexed receiver,
        uint256 amount
    );
    event ExtendUnlockTime(uint256 depositId, uint256 unlockTime);

    constructor() public {
        feeWithdrawalAddress = payable(msg.sender);
    }

    function lockTokens(
        address _tokenAddress,
        uint256 _amount,
        uint256 _unlockTime,
        bool _feeInEth
    ) external payable returns (uint256 _id) {
        require(_amount > 0, "Tokens amount must be greater than 0");
        require(_unlockTime < 10000000000, "Unix timestamp must be in seconds, not milliseconds");
        require(_unlockTime > block.timestamp, "Unlock time must be in future");
        require((_feeInEth && _amount >= ethFee) || !_feeInEth, "ETH fee not provided");

        require(IERC20(_tokenAddress).approve(address(this), _amount), "Failed to approve tokens");
        require(IERC20(_tokenAddress).transferFrom(msg.sender, address(this), _amount), "Failed to transfer tokens to locker");

        uint256 lockAmount = _amount;
        if (_feeInEth) {
            totalEthFees = totalEthFees.add(msg.value);
        } else {
            uint256 fee = lockAmount.mul(lpFeePercent).div(1000);
            lockAmount = lockAmount.sub(fee);
            try IERC20(_tokenAddress).transfer(feeWithdrawalAddress, fee) {
                emit Log("LP fee sent");
            } catch Error(string memory reason) {
                emit Log(reason);
                revert("An error occur while send fees. Try paying fee with ETH");
            } catch (bytes memory reason) {
                emit LogBytes(reason);
                revert("An error occur while send fees. Try paying fee with ETH");
            }
        }

        walletTokenBalance[_tokenAddress][msg.sender] = walletTokenBalance[_tokenAddress][msg.sender].add(_amount);

        address _withdrawalAddress = msg.sender;
        _id = ++depositId;
        lockedToken[_id].tokenAddress = _tokenAddress;
        lockedToken[_id].withdrawalAddress = _withdrawalAddress;
        lockedToken[_id].tokenAmount = lockAmount;
        lockedToken[_id].withdrawn = 0;
        lockedToken[_id].unlockTime = _unlockTime;

        allDepositIds.push(_id);
        depositsByWithdrawalAddress[_withdrawalAddress].push(_id);
        depositsByTokenAddress[_tokenAddress].push(_id);

        emit TokensLocked(
            _tokenAddress,
            msg.sender,
            _amount,
            _unlockTime,
            depositId
        );
    }

    function withdrawTokens(uint256 _id, uint256 _amount) external {
        require(block.timestamp >= lockedToken[_id].unlockTime, "Tokens are locked");
        require(msg.sender == lockedToken[_id].withdrawalAddress, "Can withdraw from the address used for locking");
        require(lockedToken[_id].tokenAmount > lockedToken[_id].withdrawn, "Tokens already withdrawn");

        address tokenAddress = lockedToken[_id].tokenAddress;
        address withdrawalAddress = lockedToken[_id].withdrawalAddress;
        uint256 balance = walletTokenBalance[tokenAddress][msg.sender];

        require(balance >= _amount, "Insufficient funds");
        require(IERC20(tokenAddress).transfer(withdrawalAddress, _amount), "Failed to transfer tokens");

        uint256 withdrawn = lockedToken[_id].withdrawn;
        lockedToken[_id].withdrawn = withdrawn.add(_amount);
        walletTokenBalance[tokenAddress][msg.sender] = balance.sub(_amount);

        if (lockedToken[_id].withdrawn >= lockedToken[_id].tokenAmount) {
            // Remove depositId from withdrawal addresses mapping
            uint256 i;
            uint256 j;
            uint256 byWLength = depositsByWithdrawalAddress[withdrawalAddress].length;
            uint256[] memory newDepositsByWithdrawal = new uint256[](byWLength - 1);

            for (j = 0; j < byWLength; j++) {
                if (depositsByWithdrawalAddress[withdrawalAddress][j] == _id) {
                    for (i = j; i < byWLength - 1; i++) {
                        newDepositsByWithdrawal[i] = depositsByWithdrawalAddress[withdrawalAddress][i + 1];
                    }
                    break;
                } else {
                    newDepositsByWithdrawal[j] = depositsByWithdrawalAddress[withdrawalAddress][j];
                }
            }
            depositsByWithdrawalAddress[withdrawalAddress] = newDepositsByWithdrawal;

            // Remove depositId from tokens mapping
            uint256 byTLength = depositsByTokenAddress[tokenAddress].length;
            uint256[] memory newDepositsByToken = new uint256[](byTLength - 1);
            for (j = 0; j < byTLength; j++) {
                if (depositsByTokenAddress[tokenAddress][j] == _id) {
                    for (i = j; i < byTLength - 1; i++) {
                        newDepositsByToken[i] = depositsByTokenAddress[tokenAddress][i + 1];
                    }
                    break;
                } else {
                    newDepositsByToken[j] = depositsByTokenAddress[tokenAddress][j];
                }
            }
            depositsByTokenAddress[tokenAddress] = newDepositsByToken;
        }

        emit TokensWithdrawn(tokenAddress, withdrawalAddress, _amount);
    }

    function extendUnlockTime(uint256 _id, uint256 _unlockTime) external {
        require(msg.sender == lockedToken[_id].withdrawalAddress, "You are not the lock owner");
        require(_unlockTime < 10000000000, "Unix timestamp must be in seconds, not milliseconds");
        require(_unlockTime > block.timestamp, "Unlock time must be in future");
        lockedToken[_id].unlockTime = _unlockTime;
        emit ExtendUnlockTime(_id, _unlockTime);
    }

    function transferLockOwnership(uint256 _id, address _newWithdrawalAddress) external {
        address withdrawalAddress = lockedToken[_id].withdrawalAddress;
        require(msg.sender == withdrawalAddress, "You are not the lock owner");
        require(msg.sender != _newWithdrawalAddress, "You can not transfer lock to yourself");

        uint256 i;
        uint256 j;
        uint256 byWLength = depositsByWithdrawalAddress[withdrawalAddress].length;
        uint256[] memory newDepositsByWithdrawal = new uint256[](byWLength - 1);
        address tokenAddress = lockedToken[_id].tokenAddress;
        uint256 balance = walletTokenBalance[tokenAddress][msg.sender];
        walletTokenBalance[tokenAddress][msg.sender] = balance.sub(balance);

        for (j = 0; j < byWLength; j++) {
            if (depositsByWithdrawalAddress[withdrawalAddress][j] == _id) {
                for (i = j; i < byWLength - 1; i++) {
                    newDepositsByWithdrawal[i] = depositsByWithdrawalAddress[withdrawalAddress][i + 1];
                }
                break;
            } else {
                newDepositsByWithdrawal[j] = depositsByWithdrawalAddress[withdrawalAddress][j];
            }
        }

        walletTokenBalance[tokenAddress][_newWithdrawalAddress] = walletTokenBalance[tokenAddress][_newWithdrawalAddress].add(balance);
        depositsByWithdrawalAddress[withdrawalAddress] = newDepositsByWithdrawal;
        lockedToken[_id].withdrawalAddress = _newWithdrawalAddress;
        depositsByWithdrawalAddress[_newWithdrawalAddress].push(_id);

        emit TransferLockOwnership(_id, msg.sender, withdrawalAddress, balance);
    }

    function getTotalTokenBalance(address _tokenAddress) public view returns (uint256) {
        return IERC20(_tokenAddress).balanceOf(address(this));
    }

    function getTokenBalanceByAddress(address _tokenAddress, address _walletAddress) public view returns (uint256) {
        return walletTokenBalance[_tokenAddress][_walletAddress];
    }

    function getAllDepositIds() public view returns (uint256[] memory) {
        return allDepositIds;
    }

    function getDepositDetails(uint256 _id) public view returns (address, address, uint256, uint256, uint256) {
        return (
            lockedToken[_id].tokenAddress,
            lockedToken[_id].withdrawalAddress,
            lockedToken[_id].tokenAmount,
            lockedToken[_id].withdrawn,
            lockedToken[_id].unlockTime
        );
    }

    function getDepositsByWithdrawalAddress(address _withdrawalAddress) public view returns (uint256[] memory) {
        return depositsByWithdrawalAddress[_withdrawalAddress];
    }

    function getDepositsByTokenAddress(address _tokenAddress) public view returns (uint256[] memory) {
        return depositsByTokenAddress[_tokenAddress];
    }

    function setFeeWithdrawalAddress(address payable _address) external onlyOwner {
        require(_address != address(0), "Address can not be dead address");
        feeWithdrawalAddress = _address;
    }

    function setEthFee(uint256 fee) external onlyOwner {
        require(fee > 0, "Fee is too small");
        ethFee = fee;
    }

    function setLpFee(uint256 percent) external onlyOwner {
        require(percent > 0, "Percent is too small");
        lpFeePercent = percent;
    }

    function withdrawFees() external onlyOwner {
        require(address(this).balance > 0, "Insufficient funds");
        feeWithdrawalAddress.transfer(address(this).balance);
    }
}
