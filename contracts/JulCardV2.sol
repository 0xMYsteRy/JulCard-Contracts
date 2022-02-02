//SPDX-License-Identifier: UNLICENSED

// Solidity files have to start with this pragma.
// It will be used by the Solidity compiler to validate its version.
pragma solidity ^0.7.0;
pragma abicoder v2;
// We import this library to be able to use console.log
// import "hardhat/console.sol";
import "./libraries/TransferHelper.sol";
import "./interfaces/PriceOracle.sol";
import "./interfaces/IWETH9.sol";
import "./interfaces/ISwapper.sol";
import "./interfaces/ERC20Interface.sol";
import "./libraries/SafeMath.sol";
import "./OwnerConstants.sol";
import "./SignerRole.sol";

// This is the main building block for smart contracts.
contract JulCardV2 is OwnerConstants, SignerRole {
  //  bytes4 public constant PAY_MONTHLY_FEE = bytes4(keccak256(bytes('payMonthlyFee')));
  bytes4 public constant PAY_MONTHLY_FEE = 0x529a8d6c;
  //  bytes4 public constant WITHDRAW = bytes4(keccak256(bytes('withdraw')));
  bytes4 public constant WITHDRAW = 0x855511cc;
  //  bytes4 public constant BUYGOODS = bytes4(keccak256(bytes('buyGoods')));
  bytes4 public constant BUYGOODS = 0xa8fd19f2;
  //  bytes4 public constant SET_USER_MAIN_MARKET = bytes4(keccak256(bytes('setUserMainMarket')));
  bytes4 public constant SET_USER_MAIN_MARKET = 0x4a22142e;
  
  uint256 public constant CARD_VALIDATION_TIME = 10 minutes; // 30 days in prodcution

  using SafeMath for uint256;

  address public immutable WETH;
  // this is main currency for master wallet, master wallet will get always this token. normally we use USDC for this token.
  address public immutable USDT;
  // this is juld token address, which is used for setting of user's daily level and cashback.
  address public immutable juld;
  // default market , which is used when user didn't select any market for his main market
  address public defaultMarket;

  address public swapper;

  // Price oracle address, which is used for verification of swapping assets amount
  address public priceOracle;

  // Governor can set followings:
  address public governorAddress; // Governance address

  /*** Main Actions ***/
  // user's sepnd amount in a day.
  mapping(address => uint256) public usersSpendAmountDay;
  // user's spend date
  // it is needed to calculate how much assets user sold in a day.
  mapping(address => uint256) public usersSpendTime;
  // current user level of each user. 1~5 level enabled.
  mapping(address => uint256) public usersLevel;
  // the time juld amount is updated
  mapping(address => uint256) public usersjuldUpdatedTime;
  // specific user's daily spend limit.
  // this value should be zero in default.
  // if this value is not 0, then return the value and if 0, return limt for user's level.

  // user's deposited balance.
  // user  => ( market => balances)
  mapping(address => mapping(address => uint256)) public usersBalances;

  /// @notice A list of all assets
  address[] public allMarkets;

  // store user's main asset used when user make payment.
  mapping(address => address) public userMainMarket;
  mapping(address => uint256) public userValidTimes;

  //prevent reentrancy attack
  uint256 private constant _NOT_ENTERED = 1;
  uint256 private constant _ENTERED = 2;
  uint256 private _status;
  bool private initialized;
  mapping(uint256 => bool) public _paymentIds;
  struct SignKeys {
    uint8 v;
    bytes32 r;
    bytes32 s;
  }
  struct SignData {
    bytes4 method;
    uint256 id;
    address market;
    address userAddr;
    uint256 amount;
    uint256 validTime;
    address signer;
  }
  // emit event

  event UserBalanceChanged(
    address indexed userAddr,
    address indexed market,
    uint256 amount
  );

  event GovernorAddressChanged(
    address indexed previousGovernor,
    address indexed newGovernor
  );
  event PriceOracleChanged(
    address owner,
    address newOracleAddress,
    address beforePriceOracle
  );
  event SwapperChanged(
    address owner,
    address newSwapper,
    address beforeSwapper
  );
  event MonthlyFeePaid(
    address userAddr,
    uint256 userValidTime,
    uint256 usdAmount
  );
  event UserDeposit(address userAddr, address market, uint256 amount);
  event UserMainMarketChanged(
    uint256 id,
    address userAddr,
    address market,
    address beforeMarket
  );
  event UserWithdraw(
    uint256 id,
    address userAddr,
    address market,
    uint256 amount,
    uint256 remainedBalance
  );
  event UserLevelChanged(address userAddr, uint256 newLevel);
  event SignerBuyGoods(
    uint256 id,
    address relayer,
    address market,
    address userAddr,
    uint256 usdAmount
  );

  // verified
  /**
   * Contract initialization.
   *
   * The `constructor` is executed only once when the contract is created.
   * The `public` modifier makes a function callable from outside the contract.
   */
  constructor(
    address _WETH,
    address _USDT,
    address _juldAddress,
    address _initialSigner
  ) SignerRole(_initialSigner) {
    // The totalSupply is assigned to transaction sender, which is the account
    // that is deploying the contract.
    WETH = _WETH;
    juld = _juldAddress;
    USDT = _USDT;
  }

  // verified
  receive() external payable {
    // require(msg.sender == WETH, 'Not WETH9');
  }

  // verified
  function initialize(
    address _owner,
    address _priceOracle,
    address _financialAddress,
    address _masterAddress,
    address _treasuryAddress,
    address _governorAddress,
    address _monthlyFeeAddress,
    address _stakeContractAddress,
    address _swapper
  ) public {
    require(!initialized, "already initalized");
    owner = _owner;
    _addSigner(_owner);
    priceOracle = _priceOracle;
    treasuryAddress = _treasuryAddress;
    financialAddress = _financialAddress;
    masterAddress = _masterAddress;
    governorAddress = _governorAddress;
    monthlyFeeAddress = _monthlyFeeAddress;
    stakeContractAddress = _stakeContractAddress;
    swapper = _swapper;
    // levelValidationPeriod = 30 days;
    levelValidationPeriod = 10 minutes; //for testing
    //private variables initialize.
    _status = _NOT_ENTERED;
    //initialize OwnerConstants arrays
    JulDStakeAmounts = [
      1000 ether,
      2500 ether,
      10000 ether,
      25000 ether,
      100000 ether
    ];
    DailyLimits = [
      100 ether,
      250 ether,
      500 ether,
      2500 ether,
      5000 ether,
      10000 ether
    ];
    CashBackPercents = [10, 200, 300, 400, 500, 600];
    stakePercent = 15 * (100 + 15);
    buyFeePercent = 100;
    withdrawFeePercent = 10;
    monthlyFeeAmount = 6.99 ether;
    juldMonthlyProfit = 1000;
    
    initialized = true;
    addMarket(WETH);
    addMarket(USDT);
    addMarket(juld);
    defaultMarket = WETH;
  }

  /// modifier functions
  // verified
  modifier onlyGovernor() {
    require(_msgSender() == governorAddress, "og");
    _;
  }
  // verified
  modifier marketSupported(address market) {
    bool marketExist = false;
    for (uint256 i = 0; i < allMarkets.length; i++) {
      if (allMarkets[i] == market) {
        marketExist = true;
      }
    }
    require(marketExist, "mns");
    _;
  }
  // verified
  modifier marketEnabled(address market) {
    require(_marketEnabled[market], "mdnd");
    _;
  }
  // verified
  modifier noExpired(address userAddr) {
    require(!getUserExpired(userAddr), "user expired");
    _;
  }

  /**
   * @dev Prevents a contract from calling itself, directly or indirectly.
   * Calling a `nonReentrant` function from another `nonReentrant`
   * function is not supported. It is possible to prevent this from happening
   * by making the `nonReentrant` function external, and make it call a
   * `private` function that does the actual work.
   */
  // verified
  modifier nonReentrant() {
    // On the first call to nonReentrant, _notEntered will be true
    require(_status != _ENTERED, "rc");

    // Any calls to nonReentrant after this point will fail
    _status = _ENTERED;

    _;

    // By storing the original value once again, a refund is triggered (see
    // https://eips.ethereum.org/EIPS/eip-2200)
    _status = _NOT_ENTERED;
  }

  modifier validSignOfSigner(
    SignData calldata sign_data,
    SignKeys calldata sign_key
  ) {
    require(
      isSigner(
        ecrecover(
          toEthSignedMessageHash(
            keccak256(
              abi.encodePacked(
                this,
                sign_data.method,
                sign_data.id,
                sign_data.userAddr,
                sign_data.market,
                sign_data.amount,
                sign_data.validTime
              )
            )
          ),
          sign_key.v,
          sign_key.r,
          sign_key.s
        )
      ),
      "ssst"
    );
    _;
  }
  modifier validSignOfUser(
    SignData calldata sign_data,
    SignKeys calldata sign_key
  ) {
    require(
      sign_data.userAddr ==
        ecrecover(
          toEthSignedMessageHash(
            keccak256(
              abi.encodePacked(
                this,
                sign_data.method,
                sign_data.id,
                sign_data.userAddr,
                sign_data.market,
                sign_data.amount,
                sign_data.validTime
              )
            )
          ),
          sign_key.v,
          sign_key.r,
          sign_key.s
        ),
      "usst"
    );
    _;
  }

  function getUserMainMarket(address userAddr) public view returns (address) {
    if (userMainMarket[userAddr] == address(0)) {
      return defaultMarket; // return default market
    }
    address market = userMainMarket[userAddr];
    if (_marketEnabled[market] == false) {
      return defaultMarket; // return default market
    }
    return market;
  }

  // verified
  function getUserExpired(address _userAddr) public view returns (bool) {
    if (userValidTimes[_userAddr] + 25 days > block.timestamp) {
      return false;
    }
    return true;
  }

  // set Governance address
  function setGovernor(address newGovernor) public onlyGovernor {
    address oldGovernor = governorAddress;
    governorAddress = newGovernor;
    emit GovernorAddressChanged(oldGovernor, newGovernor);
  }

  // verified
  function addMarket(address market) public onlyGovernor {
    _addMarketInternal(market);
  }

  // verified
  function setPriceOracle(address _priceOracle) public onlyGovernor {
    // address beforeAddress = priceOracle;
    priceOracle = _priceOracle;
    // emit PriceOracleChanged(governorAddress, priceOracle, beforeAddress);
  }

  // verified
  function setSwapper(address _swapper) public onlyOwner {
    // address beforeAddress = _swapper;
    swapper = _swapper;
    // emit SwapperChanged(governorAddress, swapper, beforeAddress);
  }

  // verified
  function addSigner(address _signer) public onlyGovernor {
    _addSigner(_signer);
  }

  // verified
  function removeSigner(address _signer) public onlyGovernor {
    _removeSigner(_signer);
  }

  // function setDefaultMarket(address market)
  //   public
  //   marketEnabled(market)
  //   marketSupported(market)
  //   onlyGovernor
  // {
  //   defaultMarket = market;
  // }

  ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

  //returns today's spend amount
  function getSpendAmountToday(address userAddr) public view returns (uint256) {
    uint256 currentDate = block.timestamp / 1 days;
    if (usersSpendTime[userAddr] != currentDate) {
      return 0;
    }
    return usersSpendAmountDay[userAddr];
  }

  function onUpdateUserBalance(
    address userAddr,
    address market,
    uint256 amount,
    uint256 beforeAmount
  ) internal returns (bool) {
    emit UserBalanceChanged(userAddr, market, amount);
    if (market != juld) return true;
    uint256 newLevel = getLevel(usersBalances[userAddr][market]);
    uint256 beforeLevel = getLevel(beforeAmount);
    if (newLevel != beforeLevel)
      usersjuldUpdatedTime[userAddr] = block.timestamp;
    if (newLevel == usersLevel[userAddr]) return true;
    if (newLevel < usersLevel[userAddr]) {
      usersLevel[userAddr] = newLevel;
      emit UserLevelChanged(userAddr, newLevel);
    } else {
      if (
        usersjuldUpdatedTime[userAddr] + levelValidationPeriod < block.timestamp
      ) {
        usersLevel[userAddr] = newLevel;
        emit UserLevelChanged(userAddr, newLevel);
      } else {
        // do somrthing ...
      }
    }
    return false;
  }

  function getUserLevel(address userAddr) public view returns (uint256) {
    uint256 newLevel = getLevel(usersBalances[userAddr][juld]);
    if (newLevel < usersLevel[userAddr]) {
      return newLevel;
    } else {
      if (
        usersjuldUpdatedTime[userAddr] + levelValidationPeriod < block.timestamp
      ) {
        return newLevel;
      } else {
        // do something ...
      }
    }
    return usersLevel[userAddr];
  }

  // decimal of usdAmount is 18
  function withinLimits(address userAddr, uint256 usdAmount)
    public
    view
    returns (bool)
  {
    if (usdAmount <= getUserLimit(userAddr)) return true;
    return false;
  }

  function getUserLimit(address userAddr) public view returns (uint256) {
    uint256 dailyLimit = userDailyLimits[userAddr];
    if (dailyLimit != 0) return dailyLimit;
    uint256 userLevel = getUserLevel(userAddr);
    return getDailyLimit(userLevel);
  }

  ////////////////////////////////////////////////////////////////////////////////////////////////////////////////
  //verified
  function _addMarketInternal(address assetAddr) internal {
    for (uint256 i = 0; i < allMarkets.length; i++) {
      require(allMarkets[i] != assetAddr, "maa");
    }
    allMarkets.push(assetAddr);
    _marketEnabled[assetAddr] = true;
  }

  // verified
  /**
   * @notice Return all of the markets
   * @dev The automatic getter may be used to access an individual market.
   * @return The list of market addresses
   */
  function getAllMarkets() public view returns (address[] memory) {
    return allMarkets;
  }

  // verified
  function deposit(address market, uint256 amount)
    public
    marketEnabled(market)
    nonReentrant
    noEmergency
  {
    TransferHelper.safeTransferFrom(market, msg.sender, address(this), amount);
    _addUserBalance(market, msg.sender, amount);
    emit UserDeposit(msg.sender, market, amount);
  }

  // verified
  function depositETH() public payable marketEnabled(WETH) nonReentrant {
    IWETH9(WETH).deposit{ value: msg.value }();
    _addUserBalance(WETH, msg.sender, msg.value);
    emit UserDeposit(msg.sender, WETH, msg.value);
  }

  // verified
  function _addUserBalance(
    address market,
    address userAddr,
    uint256 amount
  ) internal marketEnabled(market) {
    uint256 beforeAmount = usersBalances[userAddr][market];
    usersBalances[userAddr][market] += amount;
    onUpdateUserBalance(
      userAddr,
      market,
      usersBalances[userAddr][market],
      beforeAmount
    );
  }

  function setUserMainMarket(
    uint256 id,
    address market,
    uint256 validTime,
    uint8 v,
    bytes32 r,
    bytes32 s
  ) public {
    address userAddr = msg.sender;
    if (getUserMainMarket(userAddr) == market) return;
    require(
      isSigner(
        ecrecover(
          toEthSignedMessageHash(
            keccak256(
              abi.encodePacked(
                this,
                SET_USER_MAIN_MARKET,
                id,
                userAddr,
                market,
                uint256(0),
                validTime
              )
            )
          ),
          v,
          r,
          s
        )
      ),
      "summ"
    );
    require(_paymentIds[id] == false, "pru");
    _paymentIds[id] = true;
    require(validTime > block.timestamp, "expired");
    address beforeMarket = getUserMainMarket(userAddr);
    userMainMarket[userAddr] = market;
    emit UserMainMarketChanged(id, userAddr, market, beforeMarket);
  }

  // verified
  function payMonthlyFee(
    SignData calldata _data,
    SignKeys calldata user_key,
    address  market
  ) public nonReentrant
    marketEnabled(market)
    noEmergency
    validSignOfUser(_data, user_key)
    onlySigner
  {
    address userAddr = _data.userAddr;
    require(userValidTimes[userAddr] <= block.timestamp, "e");
    require(monthlyFeeAmount <= _data.amount, "over paid");

    // increase valid period
    uint256 _tempVal;
    // extend user's valid time
    uint256 _monthlyFee = getMonthlyFeeAmount(market == juld);

    userValidTimes[userAddr] = block.timestamp + CARD_VALIDATION_TIME;
    
    if (stakeContractAddress != address(0)) {
      _tempVal = (_monthlyFee * 10000) / (10000 + stakePercent);
    }
    uint256 beforeAmount = usersBalances[userAddr][market];
    calculateAmount(
      market,
      userAddr,
      _tempVal,
      monthlyFeeAddress,
      stakeContractAddress,
      stakePercent
    );
    onUpdateUserBalance(
      userAddr,
      market,
      usersBalances[userAddr][market],
      beforeAmount
    );
    emit MonthlyFeePaid(userAddr, userValidTimes[userAddr], _monthlyFee);
  }

  // verified
  function withdraw(
    uint256 id,
    address market,
    uint256 amount,
    uint256 validTime,
    uint8 v,
    bytes32 r,
    bytes32 s
  ) public nonReentrant {
    address userAddr = msg.sender;
    require(
      isSigner(
        ecrecover(
          toEthSignedMessageHash(
            keccak256(
              abi.encodePacked(
                this,
                WITHDRAW,
                id,
                userAddr,
                market,
                amount,
                validTime
              )
            )
          ),
          v,
          r,
          s
        )
      ),
      "ssst"
    );
    require(_paymentIds[id] == false, "pru");
    _paymentIds[id] = true;
    require(validTime > block.timestamp, "expired");
    uint256 beforeAmount = usersBalances[userAddr][market];
    require(beforeAmount >= amount, "ib");
    usersBalances[userAddr][market] = beforeAmount - amount;
    if (market == WETH) {
      IWETH9(WETH).withdraw(amount);
      if (treasuryAddress != address(0)) {
        uint256 feeAmount = (amount * withdrawFeePercent) / 10000;
        if (feeAmount > 0) {
          TransferHelper.safeTransferETH(treasuryAddress, feeAmount);
        }
        TransferHelper.safeTransferETH(msg.sender, amount - feeAmount);
      } else {
        TransferHelper.safeTransferETH(msg.sender, amount);
      }
    } else {
      if (treasuryAddress != address(0)) {
        uint256 feeAmount = (amount * withdrawFeePercent) / 10000;
        if (feeAmount > 0) {
          TransferHelper.safeTransfer(market, treasuryAddress, feeAmount);
        }
        TransferHelper.safeTransfer(market, msg.sender, amount - feeAmount);
      } else {
        TransferHelper.safeTransfer(market, msg.sender, amount);
      }
    }
    onUpdateUserBalance(
      userAddr,
      market,
      usersBalances[userAddr][market],
      beforeAmount
    );
    emit UserWithdraw(
      id,
      userAddr,
      market,
      amount,
      usersBalances[userAddr][market]
    );
  }

  // decimal of usdAmount is 18
  function buyGoods(
    SignData calldata _data,
    SignKeys calldata signer_key
  )
    external
    nonReentrant
    marketEnabled(_data.market)
    noExpired(_data.userAddr)
    noEmergency
    validSignOfSigner(_data, signer_key)
  {
    require(_paymentIds[_data.id] == false, "pru");
    _paymentIds[_data.id] = true;
    if (_data.market == juld) {
      require(juldPaymentEnable, "jsy");
    }
    require(getUserMainMarket(_data.userAddr) == _data.market, "jsy2");
    _makePayment(_data.market, _data.userAddr, _data.amount);
    emit SignerBuyGoods(
      _data.id,
      _data.signer,
      _data.market,
      _data.userAddr,
      _data.amount
    );
  }

  // deduce user assets using usd amount
  // decimal of usdAmount is 18
  // verified
  function _makePayment(
    address market,
    address userAddr,
    uint256 usdAmount
  ) internal {
    uint256 spendAmount = calculateAmount(
      market,
      userAddr,
      usdAmount,
      masterAddress,
      treasuryAddress,
      buyFeePercent
    );

    uint256 currentDate = block.timestamp / 1 days;
    uint256 beforeAmount = usersBalances[userAddr][market];
    uint256 totalSpendAmount;

    if (usersSpendTime[userAddr] != currentDate) {
      usersSpendTime[userAddr] = currentDate;
      totalSpendAmount = spendAmount;
    } else {
      totalSpendAmount = usersSpendAmountDay[userAddr] + spendAmount;
    }

    require(withinLimits(userAddr, totalSpendAmount), "odl");
    cashBack(userAddr, spendAmount);
    usersSpendAmountDay[userAddr] = totalSpendAmount;
    onUpdateUserBalance(
      userAddr,
      market,
      usersBalances[userAddr][market],
      beforeAmount
    );
  }

  // calculate aseet amount from market and required usd amount
  // decimal of usdAmount is 18
  // spendAmount is decimal 18
  function calculateAmount(
    address market,
    address userAddr,
    uint256 usdAmount,
    address targetAddress,
    address feeAddress,
    uint256 feePercent
  ) internal returns (uint256 spendAmount) {
    uint256 addFeeUsdAmount;
    if (feeAddress != address(0)) {
      addFeeUsdAmount = usdAmount + (usdAmount * feePercent) / 10000;
    } else {
      addFeeUsdAmount = usdAmount;
    }
    // change addFeeUsdAmount to USDT asset amounts
    // uint256 assetAmountIn = getAssetAmount(market, addFeeUsdAmount);
    // assetAmountIn = assetAmountIn + assetAmountIn / 10; //price tolerance = 10%
    uint256 usdtTotalAmount = convertUsdAmountToAssetAmount(
      addFeeUsdAmount,
      USDT
    );
    if (market != USDT) {
      // we need to change somehting here, because if there are not pair {market, USDT} , then we have to add another path
      // so please check the path is exist and if no, please add market, weth, usdt to path
      address[] memory path = ISwapper(swapper).getOptimumPath(market, USDT);
      uint256[] memory amounts = ISwapper(swapper).getAmountsIn(
        usdtTotalAmount,
        path
      );
      require(amounts[0] <= usersBalances[userAddr][market], "ua");
      usersBalances[userAddr][market] =
        usersBalances[userAddr][market] -
        amounts[0];
      TransferHelper.safeTransfer(
        path[0],
        ISwapper(swapper).GetReceiverAddress(path),
        amounts[0]
      );
      ISwapper(swapper)._swap(amounts, path, address(this));
    } else {
      require(addFeeUsdAmount <= usersBalances[userAddr][market], "uat");
      usersBalances[userAddr][market] =
        usersBalances[userAddr][market] -
        addFeeUsdAmount;
    }
    require(targetAddress != address(0), "mis");
    uint256 usdtAmount = convertUsdAmountToAssetAmount(usdAmount, USDT);
    require(usdtTotalAmount >= usdtAmount, "sp");
    TransferHelper.safeTransfer(USDT, targetAddress, usdtAmount);
    uint256 fee = usdtTotalAmount.sub(usdtAmount);
    if (feeAddress != address(0))
      TransferHelper.safeTransfer(USDT, feeAddress, fee);
    spendAmount = convertAssetAmountToUsdAmount(usdtTotalAmount, USDT);
  }

  function convertUsdAmountToAssetAmount(
    uint256 usdAmount,
    address assetAddress
  ) public view returns (uint256) {
    ERC20Interface token = ERC20Interface(assetAddress);
    uint256 tokenDecimal = uint256(token.decimals());
    uint256 defaultDecimal = 18;
    if (defaultDecimal == tokenDecimal) {
      return usdAmount;
    } else if (defaultDecimal > tokenDecimal) {
      return usdAmount.div(10**(defaultDecimal.sub(tokenDecimal)));
    } else {
      return usdAmount.mul(10**(tokenDecimal.sub(defaultDecimal)));
    }
  }

  function convertAssetAmountToUsdAmount(
    uint256 assetAmount,
    address assetAddress
  ) public view returns (uint256) {
    ERC20Interface token = ERC20Interface(assetAddress);
    uint256 tokenDecimal = uint256(token.decimals());
    uint256 defaultDecimal = 18;
    if (defaultDecimal == tokenDecimal) {
      return assetAmount;
    } else if (defaultDecimal > tokenDecimal) {
      return assetAmount.mul(10**(defaultDecimal.sub(tokenDecimal)));
    } else {
      return assetAmount.div(10**(tokenDecimal.sub(defaultDecimal)));
    }
  }

  function cashBack(address userAddr, uint256 usdAmount) internal {
    if (!cashBackEnable) return;
    uint256 cashBackPercent = getCashBackPercent(getUserLevel(userAddr));
    uint256 juldAmount = getAssetAmount(
      juld,
      (usdAmount * cashBackPercent) / 10000
    );
    // require(ERC20Interface(juld).balanceOf(address(this)) >= juldAmount , "insufficient juld");
    if (usersBalances[financialAddress][juld] > juldAmount) {
      usersBalances[financialAddress][juld] =
        usersBalances[financialAddress][juld] -
        juldAmount;
      //needs extra check that owner deposited how much juld for cashBack
      _addUserBalance(juld, userAddr, juldAmount);
    }
  }

  // verified
  function getUserAssetAmount(address userAddr, address market)
    public
    view
    marketSupported(market)
    returns (uint256)
  {
    return usersBalances[userAddr][market];
  }

  // verified
  function getBatchUserAssetAmount(address userAddr)
    public
    view
    returns (uint256[] memory, uint256[] memory)
  {
    uint256[] memory assets = new uint256[](allMarkets.length);
    uint256[] memory decimals = new uint256[](allMarkets.length);

    for (uint256 i = 0; i < allMarkets.length; i++) {
      assets[i] = usersBalances[userAddr][allMarkets[i]];
      ERC20Interface token = ERC20Interface(allMarkets[i]);
      uint256 tokenDecimal = uint256(token.decimals());
      decimals[i] = tokenDecimal;
    }
    return (assets, decimals);
  }

  function getUserBalanceInUsd(address userAddr) public view returns (uint256) {
    address market = getUserMainMarket(userAddr);
    uint256 assetAmount = usersBalances[userAddr][market];
    uint256 usdAmount = getUsdAmount(market, assetAmount);
    return usdAmount;
  }

  // verified not
  //usdamount deciaml = 8
  function getUsdAmount(address market, uint256 assetAmount)
    public
    view
    returns (uint256 usdAmount)
  {
    uint256 usdPrice = PriceOracle(priceOracle).getUnderlyingPrice(market);
    require(usdPrice > 0, "usd price error");
    usdAmount = (assetAmount * usdPrice) / (10**8);
  }

  // verified not
  function getAssetAmount(address market, uint256 usdAmount)
    public
    view
    returns (uint256 assetAmount)
  {
    uint256 usdPrice = PriceOracle(priceOracle).getUnderlyingPrice(market);
    require(usdPrice > 0, "usd price error");
    assetAmount = (usdAmount * (10**8)) / usdPrice;
  }

  // verified
  function toEthSignedMessageHash(bytes32 hash)
    internal
    pure
    returns (bytes32)
  {
    return
      keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash));
  }

  // verified
  function encodePackedData(
    bytes4 method,
    uint256 id,
    address addr,
    address market,
    uint256 amount,
    uint256 validTime
  ) public view returns (bytes32) {
    return
      keccak256(
        abi.encodePacked(this, method, id, addr, market, amount, validTime)
      );
  }

  // verified
  function getecrecover(
    bytes4 method,
    uint256 id,
    address addr,
    address market,
    uint256 amount,
    uint256 validTime,
    uint8 v,
    bytes32 r,
    bytes32 s
  ) public view returns (address) {
    return
      ecrecover(
        toEthSignedMessageHash(
          keccak256(
            abi.encodePacked(this, method, id, addr, market, amount, validTime)
          )
        ),
        v,
        r,
        s
      );
  }

  function getBlockTime() public view returns (uint256) {
    return block.timestamp;
  }

  // test function
  function withdrawTokens(address token, address to) public onlyOwner {
    // bellow line will be uncommented in production version
    // require(!_marketEnabled[market],"me");
    if (token == address(0)) {
      TransferHelper.safeTransferETH(to, address(this).balance);
    } else {
      TransferHelper.safeTransfer(
        token,
        to,
        ERC20Interface(token).balanceOf(address(this))
      );
    }
  }
}
