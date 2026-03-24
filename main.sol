// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/// @title ConstalEval
/// @notice Aurora lattice telemetry kernel for autonomous web3 tracking.
abstract contract CelestialOwnable {
    error CO_NotOwner();
    error CO_ZeroOwner();
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    address private _owner;
    constructor(address initialOwner) {
        if (initialOwner == address(0)) revert CO_ZeroOwner();
        _owner = initialOwner;
        emit OwnershipTransferred(address(0), initialOwner);
    }
    modifier onlyOwner() {
        if (msg.sender != _owner) revert CO_NotOwner();
        _;
    }
    function owner() public view returns (address) { return _owner; }
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert CO_ZeroOwner();
        address prev = _owner;
        _owner = newOwner;
        emit OwnershipTransferred(prev, newOwner);
    }
}

abstract contract NovaPausable is CelestialOwnable {
    error NP_Paused();
    error NP_NotPaused();
    event PauseStateChanged(bool paused, uint64 atBlock, address indexed actor);
    bool private _paused;
    constructor(address initialOwner) CelestialOwnable(initialOwner) {}
    modifier whenNotPaused() { if (_paused) revert NP_Paused(); _; }
    modifier whenPaused() { if (!_paused) revert NP_NotPaused(); _; }
    function paused() public view returns (bool) { return _paused; }
    function pause() external onlyOwner whenNotPaused { _paused = true; emit PauseStateChanged(true, uint64(block.number), msg.sender); }
    function unpause() external onlyOwner whenPaused { _paused = false; emit PauseStateChanged(false, uint64(block.number), msg.sender); }
}

abstract contract PrismReentrancyGuard {
    error PR_ReentrantCall();
    uint256 private constant _STATUS_IDLE = 1;
    uint256 private constant _STATUS_ENTERED = 2;
    uint256 private _status = _STATUS_IDLE;
    modifier nonReentrant() {
        if (_status == _STATUS_ENTERED) revert PR_ReentrantCall();
        _status = _STATUS_ENTERED;
        _;
        _status = _STATUS_IDLE;
    }
}

contract ConstalEval is NovaPausable, PrismReentrancyGuard {
    error CE_BadAddress();
    error CE_InvalidFee();
    error CE_TooLarge();
    error CE_InvalidRoute();
    error CE_WindowOutOfBounds();
    error CE_FutureEpoch();

    event TrackerBootstrapped(bytes32 indexed laneHash, address indexed admin, uint256 epochSeed);
    event LedgerAnchorChanged(address indexed previousAnchor, address indexed nextAnchor);
    event MirrorRelayChanged(address indexed previousRelay, address indexed nextRelay);
    event BeaconUploaded(bytes32 indexed beaconId, uint48 indexed routeId, uint96 score, uint32 drift, uint64 seenAt);
    event RoutePaced(uint48 indexed routeId, uint32 cadence, uint16 confidenceBps, bool live);
    event OperatorSet(address indexed operator, bool enabled);
    event FeeTweaked(uint16 previousBps, uint16 nextBps);
    event TreasuryShifted(address indexed previousTreasury, address indexed nextTreasury);
    event FeeHarvested(address indexed collector, uint256 amount);

    struct BeaconFrame { uint96 score; uint64 timestamp; uint32 drift; uint16 confidenceBps; uint8 channel; bool finalized; }
    struct RouteConfig { uint32 cadence; uint64 lastPulse; uint16 confidenceFloorBps; uint8 channel; bool live; }

    uint256 public constant SCALE = 1e18;
    uint16 public constant MAX_BPS = 10_000;
    uint16 public constant MAX_FEE_BPS = 1_200;
    uint32 public constant MIN_WINDOW = 30;
    uint32 public constant MAX_WINDOW = 86_400;
    uint48 public constant MAX_ROUTE_ID = 65_535;

    address public immutable genesisSentinel;
    address public immutable genesisAtlas;
    bytes32 public immutable laneHash;
    uint256 public immutable deploymentEntropy;
    uint64 public immutable deployedAt;

    address public treasury;
    address public ledgerAnchor;
    address public mirrorRelay;
    uint16 public feeBps;
    uint256 public accruedFees;

    mapping(address => bool) public operators;
    mapping(uint48 => RouteConfig) public routes;
    mapping(bytes32 => BeaconFrame) public beaconFrames;
    mapping(bytes32 => bool) public laneTags;
    mapping(uint48 => bytes32[]) private _routeBeacons;

    modifier onlyOperator() { if (!operators[msg.sender] && msg.sender != owner()) revert CE_BadAddress(); _; }

    constructor(address initialOwner, address treasury_, address ledgerAnchor_, address mirrorRelay_, uint16 initialFeeBps, bytes32 laneSalt) NovaPausable(initialOwner) {
        if (treasury_ == address(0) || ledgerAnchor_ == address(0) || mirrorRelay_ == address(0)) revert CE_BadAddress();
        if (initialFeeBps > MAX_FEE_BPS) revert CE_InvalidFee();
        genesisSentinel = 0xA4f6C1A8f6A3b4cF8d9E44E4D5d6Bb0A1C2D3E4F;
        genesisAtlas = 0xB7D1eC92F4aB8c51d7A4e15fA0C4d8eF47A13dB8;
        laneHash = keccak256(abi.encodePacked(block.chainid, address(this), laneSalt));
        deploymentEntropy = uint256(keccak256(abi.encodePacked(block.prevrandao, block.timestamp, blockhash(block.number - 1))));
        deployedAt = uint64(block.timestamp);
        treasury = treasury_; ledgerAnchor = ledgerAnchor_; mirrorRelay = mirrorRelay_; feeBps = initialFeeBps;
        operators[initialOwner] = true;
