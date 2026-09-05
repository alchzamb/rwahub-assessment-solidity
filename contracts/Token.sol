// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.7.0;

import "./IERC20.sol";
import "./IMintableToken.sol";
import "./IDividends.sol";
import "./SafeMath.sol";

contract Token is IERC20, IMintableToken, IDividends {
  // ------------------------------------------ //
  // ----- BEGIN: DO NOT EDIT THIS SECTION ---- //
  // ------------------------------------------ //
  using SafeMath for uint256;
  uint256 public totalSupply;
  uint256 public decimals = 18;
  string public name = "Test token";
  string public symbol = "TEST";
  mapping (address => uint256) public balanceOf;
  // ------------------------------------------ //
  // ----- END: DO NOT EDIT THIS SECTION ------ //  
  // ------------------------------------------ //

  event Transfer(address indexed from, address indexed to, uint256 value);
  event Approval(address indexed owner, address indexed spender, uint256 value);

  // Scaling factor used to preserve precision when accumulating
  // dividend-per-token amounts that would otherwise round down to 0.
  uint256 private constant PRECISION = 1e18;

  mapping (address => mapping (address => uint256)) private allowances;

  // ----- Holder tracking (for getNumTokenHolders / getTokenHolder) -----
  // Holders with a non-zero balance, stored 0-indexed internally.
  address[] private holders;
  // 1-based index into `holders` for O(1) lookup/removal. 0 = not a holder.
  mapping (address => uint256) private holderIndex;

  // ----- Dividend accounting (accumulator / "reward per share" pattern) -----
  // Running total of dividend-per-token (scaled by PRECISION), incremented
  // on every recordDividend() call. Avoids looping over holders on payout.
  uint256 private accDividendPerToken;
  // Snapshot of `accDividendPerToken` at the last time each holder's
  // pending dividend was settled into `storedDividend`.
  mapping (address => uint256) private dividendSnapshot;
  // Dividend amount already settled and withdrawable for each holder.
  mapping (address => uint256) private storedDividend;

  // Settle any dividend accrued since the holder's last snapshot into
  // their withdrawable balance. Must be called with the holder's balance
  // BEFORE it changes, and before the holder list is updated.
  function _settleDividend(address account) private {
    uint256 owed = balanceOf[account].mul(accDividendPerToken.sub(dividendSnapshot[account])) / PRECISION;
    if (owed > 0) {
      storedDividend[account] = storedDividend[account].add(owed);
    }
    dividendSnapshot[account] = accDividendPerToken;
  }

  // Add/remove `account` from the holder list based on its CURRENT balance.
  // Removal uses swap-with-last-and-pop for O(1) cost; holder order is not
  // preserved (not required by the interface).
  function _syncHolderStatus(address account) private {
    bool isHolder = holderIndex[account] != 0;
    bool hasBalance = balanceOf[account] > 0;

    if (hasBalance && !isHolder) {
      holders.push(account);
      holderIndex[account] = holders.length; // 1-based
    } else if (!hasBalance && isHolder) {
      uint256 idx = holderIndex[account];
      uint256 lastIdx = holders.length;
      address lastHolder = holders[lastIdx - 1];

      holders[idx - 1] = lastHolder;
      holderIndex[lastHolder] = idx;

      holders.pop();
      holderIndex[account] = 0;
    }
  }

  // Internal transfer used by both `transfer` and `transferFrom`.
  function _transfer(address from, address to, uint256 value) private {
    require(balanceOf[from] >= value, "Token: insufficient balance");

    // Settle dividends for both parties using their balances BEFORE the move.
    _settleDividend(from);
    _settleDividend(to);

    balanceOf[from] = balanceOf[from].sub(value);
    balanceOf[to] = balanceOf[to].add(value);

    _syncHolderStatus(from);
    _syncHolderStatus(to);

    emit Transfer(from, to, value);
  }

  // ------------------- IERC20 -------------------

  function allowance(address owner, address spender) external view override returns (uint256) {
    return allowances[owner][spender];
  }

  function transfer(address to, uint256 value) external override returns (bool) {
    _transfer(msg.sender, to, value);
    return true;
  }

  function approve(address spender, uint256 value) external override returns (bool) {
    allowances[msg.sender][spender] = value;
    emit Approval(msg.sender, spender, value);
    return true;
  }

  function transferFrom(address from, address to, uint256 value) external override returns (bool) {
    allowances[from][msg.sender] = allowances[from][msg.sender].sub(value, "Token: allowance exceeded");
    _transfer(from, to, value);
    return true;
  }

  // ------------------- IMintableToken -------------------

  function mint() external payable override {
    require(msg.value > 0, "Token: no ETH supplied");

    _settleDividend(msg.sender);

    balanceOf[msg.sender] = balanceOf[msg.sender].add(msg.value);
    totalSupply = totalSupply.add(msg.value);

    _syncHolderStatus(msg.sender);

    emit Transfer(address(0), msg.sender, msg.value);
  }

  function burn(address payable dest) external override {
    uint256 amount = balanceOf[msg.sender];
    require(amount > 0, "Token: nothing to burn");

    _settleDividend(msg.sender);

    balanceOf[msg.sender] = 0;
    totalSupply = totalSupply.sub(amount);

    _syncHolderStatus(msg.sender);

    emit Transfer(msg.sender, address(0), amount);

    // Effects are all applied above (CEI) before this external call.
    dest.transfer(amount);
  }

  // ------------------- IDividends -------------------

  function getNumTokenHolders() external view override returns (uint256) {
    return holders.length;
  }

  function getTokenHolder(uint256 index) external view override returns (address) {
    if (index == 0 || index > holders.length) {
      return address(0);
    }
    return holders[index - 1];
  }

  function recordDividend() external payable override {
    require(msg.value > 0, "Token: no ETH supplied");
    require(totalSupply > 0, "Token: no token holders");

    accDividendPerToken = accDividendPerToken.add(msg.value.mul(PRECISION) / totalSupply);
  }

  function getWithdrawableDividend(address payee) external view override returns (uint256) {
    uint256 pending = balanceOf[payee].mul(accDividendPerToken.sub(dividendSnapshot[payee])) / PRECISION;
    return storedDividend[payee].add(pending);
  }

  function withdrawDividend(address payable dest) external override {
    _settleDividend(msg.sender);

    uint256 amount = storedDividend[msg.sender];
    storedDividend[msg.sender] = 0;

    dest.transfer(amount);
  }
}
