// SPDX-License-Identifier: MIT
pragma solidity ^0.7.6;
pragma abicoder v2;

import '../Registry.sol';

contract Governor {
    /// @notice The name of this contract
    string public constant name = "DeFiPie Governor";

    uint public threshold = 15_000_000e8; // 15M pPIE or ~300K PIE
    uint public quorum = 150_000_000e8; // 150M pPIE or ~3M PIE
    uint public delay = 1; // 1 block

    uint public period;

    /// @notice The number of votes in support of a proposal required in order for a quorum to be reached and for a vote to succeed
    function quorumVotes() public view returns (uint) { return quorum; }

    /// @notice The number of votes required in order for a voter to become a proposer
    function proposalThreshold() public view returns (uint) { return threshold; }

    /// @notice The maximum number of actions that can be included in a proposal
    function proposalMaxOperations() public pure returns (uint) { return 10; } // 10 actions

    /// @notice The delay before voting on a proposal may take place, once proposed
    function votingDelay() public view returns (uint) { return delay; }

    /// @notice The duration of voting on a proposal, in blocks
    function votingPeriod() public view virtual returns (uint) { return period; }

    /// @notice The address of the DeFiPie Protocol Timelock
    TimelockInterface public timelock;

    /// @notice The address of the Registry
    Registry public registry;

    /// @notice The address of the Governor Guardian
    address public guardian;

    /// @notice The total number of proposals
    uint public proposalCount;

    /// @notice id Unique id for looking up a proposal
    /// @notice proposer Creator of the proposal
    /// @notice eta The timestamp that the proposal will be available for execution, set once the vote succeeds
    /// @notice targets the ordered list of target addresses for calls to be made
    /// @notice values The ordered list of values (i.e. msg.value) to be passed to the calls to be made
    /// @notice signatures The ordered list of function signatures to be called
    /// @notice calldatas The ordered list of calldata to be passed to each call
    /// @notice startBlock The block at which voting begins: holders must delegate their votes prior to this block
    /// @notice endBlock The block at which voting ends: votes must be cast prior to this block
    /// @notice forVotes Current number of votes in favor of this proposal
    /// @notice againstVotes Current number of votes in opposition to this proposal
    /// @notice canceled Flag marking whether the proposal has been canceled
    /// @notice executed Flag marking whether the proposal has been executed
    /// @notice receipts Receipts of ballots for the entire set of voters

    struct Proposal {
        uint id;
        address proposer;
        uint eta;
        address[] targets;
        uint[] values;
        string[] signatures;
        bytes[] calldatas;
        uint startBlock;
        uint endBlock;
        uint forVotes;
        uint againstVotes;
        bool canceled;
        bool executed;
        mapping (address => Receipt) receipts;
    }

    /// @notice Ballot receipt record for a voter
    /// @notice hasVoted Whether or not a vote has been cast
    /// @notice support Whether or not the voter supports the proposal
    /// @notice votes The number of votes the voter had, which were cast

    struct Receipt {
        bool hasVoted;
        bool support;
        uint96 votes;
    }

    /// @notice Possible states that a proposal may be in
    enum ProposalState {
        Pending,
        Active,
        Canceled,
        Defeated,
        Succeeded,
        Queued,
        Expired,
        Executed
    }

    /// @notice The official record of all proposals ever proposed
    mapping (uint => Proposal) public proposals;

    /// @notice The latest proposal for each proposer
    mapping (address => uint) public latestProposalIds;

    /// @notice The EIP-712 typehash for the contract's domain
    bytes32 public constant DOMAIN_TYPEHASH = keccak256("EIP712Domain(string name,uint256 chainId,address verifyingContract)");

    /// @notice The EIP-712 typehash for the ballot struct used by the contract
    bytes32 public constant BALLOT_TYPEHASH = keccak256("Ballot(uint256 proposalId,bool support)");

    /// @notice An event emitted when a new proposal is created
    event ProposalCreated(
        uint id,
        address proposer,
        address[] targets,
        uint[] values,
        string[] signatures,
        bytes[] calldatas,
        uint startBlock,
        uint endBlock,
        string description
    );

    /// @notice An event emitted when a vote has been cast on a proposal
    event VoteCast(address voter, uint proposalId, bool support, uint votes);

    /// @notice An event emitted when a proposal has been canceled
    event ProposalCanceled(uint id);

    /// @notice An event emitted when a proposal has been queued in the Timelock
    event ProposalQueued(uint id, uint eta);

    /// @notice An event emitted when a proposal has been executed in the Timelock
    event ProposalExecuted(uint id);

    event NewQuorum(uint indexed newQuorum);
    event NewThreshold(uint indexed newThreshold);
    event NewVotingDelay(uint indexed newVotingDelay);
    event NewVotingPeriod(uint indexed newVotingPeriod);

    constructor(address timelock_, address registry_, address guardian_, uint period_) {
        timelock = TimelockInterface(timelock_);
        registry = Registry(registry_);
        guardian = guardian_;
        period = period_;
    }

    function propose(
        address[] memory targets,
        uint[] memory values,
        string[] memory signatures,
        bytes[] memory calldatas,
        string memory description
    ) public returns (uint) {
        require(PPieInterface(registry.pPIE()).getPriorVotes(msg.sender, sub256(block.number, 1)) > proposalThreshold(), "Governor::propose: proposer votes below proposal threshold");
        require(targets.length == values.length && targets.length == signatures.length && targets.length == calldatas.length, "Governor::propose: proposal function information parity mismatch");
        require(targets.length != 0, "Governor::propose: must provide actions");
        require(targets.length <= proposalMaxOperations(), "Governor::propose: too many actions");

        uint latestProposalId = latestProposalIds[msg.sender];
        if (latestProposalId != 0) {
            ProposalState proposersLatestProposalState = state(latestProposalId);
            require(proposersLatestProposalState != ProposalState.Active, "Governor::propose: one live proposal per proposer, found an already active proposal");
            require(proposersLatestProposalState != ProposalState.Pending, "Governor::propose: one live proposal per proposer, found an already pending proposal");
        }

        uint startBlock = add256(block.number, votingDelay());
        uint endBlock = add256(startBlock, votingPeriod());

        proposalCount++;
        Proposal storage newProposal = proposals[proposalCount];
        newProposal.id = proposalCount;
        newProposal.proposer = msg.sender;
        newProposal.targets = targets;
        newProposal.values = values;
        newProposal.signatures = signatures;
        newProposal.calldatas = calldatas;
        newProposal.startBlock = startBlock;
        newProposal.endBlock = endBlock;

        latestProposalIds[newProposal.proposer] = newProposal.id;

        emit ProposalCreated(newProposal.id, msg.sender, targets, values, signatures, calldatas, startBlock, endBlock, description);
        return newProposal.id;
    }

    function queue(uint proposalId) public {
        require(state(proposalId) == ProposalState.Succeeded, "Governor::queue: proposal can only be queued if it is succeeded");
        Proposal storage proposal = proposals[proposalId];
        uint eta = add256(block.timestamp, timelock.delay());
        for (uint i = 0; i < proposal.targets.length; i++) {
            _queueOrRevert(proposal.targets[i], proposal.values[i], proposal.signatures[i], proposal.calldatas[i], eta);
        }
        proposal.eta = eta;
        emit ProposalQueued(proposalId, eta);
    }

    function _queueOrRevert(address target, uint value, string memory signature, bytes memory data, uint eta) internal {
        require(!timelock.queuedTransactions(keccak256(abi.encode(target, value, signature, data, eta))), "Governor::_queueOrRevert: proposal action already queued at eta");
        timelock.queueTransaction(target, value, signature, data, eta);
    }

    function execute(uint proposalId) public payable {
        require(state(proposalId) == ProposalState.Queued, "Governor::execute: proposal can only be executed if it is queued");
        Proposal storage proposal = proposals[proposalId];
        proposal.executed = true;
        for (uint i = 0; i < proposal.targets.length; i++) {
            timelock.executeTransaction{value: proposal.values[i]}(proposal.targets[i], proposal.values[i], proposal.signatures[i], proposal.calldatas[i], proposal.eta);
        }
        emit ProposalExecuted(proposalId);
    }

    function cancel(uint proposalId) public {
        ProposalState state_ = state(proposalId);
        require(state_ != ProposalState.Executed, "Governor::cancel: cannot cancel executed proposal");

        Proposal storage proposal = proposals[proposalId];
        require(msg.sender == guardian || PPieInterface(registry.pPIE()).getPriorVotes(proposal.proposer, sub256(block.number, 1)) < proposalThreshold(), "Governor::cancel: proposer above threshold");

        proposal.canceled = true;
        for (uint i = 0; i < proposal.targets.length; i++) {
            timelock.cancelTransaction(proposal.targets[i], proposal.values[i], proposal.signatures[i], proposal.calldatas[i], proposal.eta);
        }

        emit ProposalCanceled(proposalId);
    }

    function getActions(
        uint proposalId
    ) public view returns (
        address[] memory targets,
        uint[] memory values,
        string[] memory signatures,
        bytes[] memory calldatas
    ) {
        Proposal storage p = proposals[proposalId];
        return (p.targets, p.values, p.signatures, p.calldatas);
    }

    function getReceipt(uint proposalId, address voter) public view returns (Receipt memory) {
        return proposals[proposalId].receipts[voter];
    }

    function getForVotes(uint proposalId) public view returns (uint) {
        return proposals[proposalId].forVotes;
    }

    function state(uint proposalId) public view returns (ProposalState) {
        require(proposalCount >= proposalId && proposalId > 0, "Governor::state: invalid proposal id");
        Proposal storage proposal = proposals[proposalId];
        if (proposal.canceled) {
            return ProposalState.Canceled;
        } else if (block.number <= proposal.startBlock) {
            return ProposalState.Pending;
        } else if (block.number <= proposal.endBlock) {
            return ProposalState.Active;
        } else if (proposal.forVotes <= proposal.againstVotes || proposal.forVotes < quorumVotes()) {
            return ProposalState.Defeated;
        } else if (proposal.eta == 0) {
            return ProposalState.Succeeded;
        } else if (proposal.executed) {
            return ProposalState.Executed;
        } else if (block.timestamp >= add256(proposal.eta, timelock.GRACE_PERIOD())) {
            return ProposalState.Expired;
        } else {
            return ProposalState.Queued;
        }
    }

    function castVote(uint proposalId, bool support) public {
        _castVote(msg.sender, proposalId, support);
    }

    function castVoteBySig(uint proposalId, bool support, uint8 v, bytes32 r, bytes32 s) public {
        bytes32 domainSeparator = keccak256(abi.encode(DOMAIN_TYPEHASH, keccak256(bytes(name)), getChainId(), address(this)));
        bytes32 structHash = keccak256(abi.encode(BALLOT_TYPEHASH, proposalId, support));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        address signatory = ecrecover(digest, v, r, s);
        require(signatory != address(0), "Governor::castVoteBySig: invalid signature");
        _castVote(signatory, proposalId, support);
    }

    function _castVote(address voter, uint proposalId, bool support) internal {
        require(state(proposalId) == ProposalState.Active, "Governor::_castVote: voting is closed");
        Proposal storage proposal = proposals[proposalId];
        Receipt storage receipt = proposal.receipts[voter];
        require(receipt.hasVoted == false, "Governor::_castVote: voter already voted");
        uint96 votes = PPieInterface(registry.pPIE()).getPriorVotes(voter, proposal.startBlock);

        if (support) {
            proposal.forVotes = add256(proposal.forVotes, votes);
        } else {
            proposal.againstVotes = add256(proposal.againstVotes, votes);
        }

        receipt.hasVoted = true;
        receipt.support = support;
        receipt.votes = votes;

        emit VoteCast(voter, proposalId, support, votes);
    }

    function setQuorum(uint newQuorum) external {
        require(msg.sender == guardian, "Governor::setQuorum: sender must be gov guardian");
        quorum = newQuorum;

        emit NewQuorum(newQuorum);
    }

    function setThreshold(uint newThreshold) external {
        require(msg.sender == guardian, "Governor::setThreshold: sender must be gov guardian");
        threshold = newThreshold;

        emit NewThreshold(newThreshold);
    }

    function setVotingDelay(uint newVotingDelay) external {
        require(msg.sender == guardian, "Governor::setVotingDelay: sender must be gov guardian");
        delay = newVotingDelay;

        emit NewVotingDelay(newVotingDelay);
    }

    function setVotingPeriod(uint newVotingPeriod) external {
        require(msg.sender == guardian, "Governor::setVotingPeriod: sender must be gov guardian");
        period = newVotingPeriod;

        emit NewVotingPeriod(newVotingPeriod);
    }

    function __acceptAdmin() public {
        require(msg.sender == guardian, "Governor::__acceptAdmin: sender must be gov guardian");
        timelock.acceptAdmin();
    }

    function __abdicate() public {
        require(msg.sender == guardian, "Governor::__abdicate: sender must be gov guardian");
        guardian = address(0);
    }

    function __queueSetTimelockPendingAdmin(address newPendingAdmin, uint eta) public {
        require(msg.sender == guardian, "Governor::__queueSetTimelockPendingAdmin: sender must be gov guardian");
        timelock.queueTransaction(address(timelock), 0, "setPendingAdmin(address)", abi.encode(newPendingAdmin), eta);
    }

    function __executeSetTimelockPendingAdmin(address newPendingAdmin, uint eta) public {
        require(msg.sender == guardian, "Governor::__executeSetTimelockPendingAdmin: sender must be gov guardian");
        timelock.executeTransaction(address(timelock), 0, "setPendingAdmin(address)", abi.encode(newPendingAdmin), eta);
    }

    function add256(uint256 a, uint256 b) internal pure returns (uint) {
        uint c = a + b;
        require(c >= a, "addition overflow");
        return c;
    }

    function sub256(uint256 a, uint256 b) internal pure returns (uint) {
        require(b <= a, "subtraction underflow");
        return a - b;
    }

    function getChainId() internal view returns (uint) {
        uint chainId;
        assembly { chainId := chainid() }
        return chainId;
    }
}

interface TimelockInterface {
    function delay() external view returns (uint);
    function GRACE_PERIOD() external view returns (uint);
    function acceptAdmin() external;
    function queuedTransactions(bytes32 hash) external view returns (bool);
    function queueTransaction(address target, uint value, string calldata signature, bytes calldata data, uint eta) external returns (bytes32);
    function cancelTransaction(address target, uint value, string calldata signature, bytes calldata data, uint eta) external;
    function executeTransaction(address target, uint value, string calldata signature, bytes calldata data, uint eta) external payable returns (bytes memory);
}

interface PPieInterface {
    function getPriorVotes(address account, uint blockNumber) external view returns (uint96);
}
