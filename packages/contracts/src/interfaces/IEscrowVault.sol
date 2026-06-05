// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title  IEscrowVault
/// @notice Interface for the Agos EscrowVault.
///
///         EscrowVault is the trustless job payment system for agent-to-agent
///         commerce. A client agent locks USDC for a job. A worker agent does
///         the work. Funds release on approval, refund on failure, or an admin
///         resolves if there is a dispute.
///
///         Full job lifecycle:
///
///         CREATED → ACCEPTED → SUBMITTED → COMPLETED
///                            ↘ DISPUTED  → RESOLVED
///                ↘ CANCELLED
///         CREATED/ACCEPTED → EXPIRED  (deadline passed, no submission)
///
interface IEscrowVault {

    // ═══════════════════════════════════════════════════════════════
    // TYPES
    // ═══════════════════════════════════════════════════════════════

    /// @notice All possible states a job can be in.
    ///         States only ever move forward — there is no going back.
    enum JobStatus {
        CREATED,    // 0 — job funded, waiting for worker to accept
        ACCEPTED,   // 1 — worker accepted, work in progress
        SUBMITTED,  // 2 — worker submitted deliverable hash
        COMPLETED,  // 3 — client approved, USDC released to worker
        DISPUTED,   // 4 — either party raised a dispute
        RESOLVED,   // 5 — admin resolved dispute, funds sent to winner
        CANCELLED,  // 6 — client cancelled before worker accepted
        EXPIRED     // 7 — deadline passed, client refunded
    }

    /// @notice Full job record stored on-chain.
    struct Job {
        bytes32   jobId;            // unique identifier
        bytes32   clientAgentId;    // agentId of the client
        bytes32   workerAgentId;    // agentId of the worker (0 until accepted)
        address   clientWallet;     // wallet address that funded the job
        address   workerWallet;     // wallet address that will receive payment (0 until accepted)
        uint128   amount;           // USDC locked (6 decimals)
        uint128   platformFee;      // fee taken on completion (computed at creation)
        uint48    deadline;         // unix timestamp — must submit before this
        uint48    createdAt;        // unix timestamp of creation
        uint48    resolvedAt;       // unix timestamp of final resolution (0 if not yet)
        bytes32   deliverableHash;  // keccak256 of work submitted by worker
        JobStatus status;           // current state
        bool      exists;           // true once created — never reset
    }

    // ═══════════════════════════════════════════════════════════════
    // EVENTS
    // ═══════════════════════════════════════════════════════════════

    /// @notice Emitted when a new job is created and USDC is locked.
    event JobCreated(
        bytes32 indexed jobId,
        bytes32 indexed clientAgentId,
        address indexed clientWallet,
        uint128         amount,
        uint48          deadline
    );

    /// @notice Emitted when a worker accepts a job.
    event JobAccepted(
        bytes32 indexed jobId,
        bytes32 indexed workerAgentId,
        address indexed workerWallet
    );

    /// @notice Emitted when a worker submits their deliverable.
    event WorkSubmitted(
        bytes32 indexed jobId,
        bytes32 indexed workerAgentId,
        bytes32         deliverableHash
    );

    /// @notice Emitted when the client approves work. USDC sent to worker.
    event JobCompleted(
        bytes32 indexed jobId,
        address indexed workerWallet,
        uint128         amountPaid,
        uint128         platformFee
    );

    /// @notice Emitted when a dispute is raised.
    event JobDisputed(
        bytes32 indexed jobId,
        address indexed raisedBy
    );

    /// @notice Emitted when admin resolves a dispute.
    event DisputeResolved(
        bytes32 indexed jobId,
        address indexed winner,
        uint128         amountPaid
    );

    /// @notice Emitted when client cancels before worker accepts.
    event JobCancelled(
        bytes32 indexed jobId,
        address indexed clientWallet,
        uint128         refundAmount
    );

    /// @notice Emitted when client claims refund after deadline.
    event JobExpired(
        bytes32 indexed jobId,
        address indexed clientWallet,
        uint128         refundAmount
    );

    /// @notice Emitted when platform fee settings are updated.
    event FeeUpdated(uint16 newFeeBps, address newFeeRecipient);

    // ═══════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════

    error ZeroAdmin();
    error ZeroAmount();
    error ZeroAddress();
    error ZeroAgentId();
    error ZeroDeadline();
    error DeadlineInPast(uint48 deadline, uint48 currentTime);
    error DeadlineTooShort(uint48 deadline, uint48 minimumDeadline);
    error JobNotFound(bytes32 jobId);
    error JobAlreadyExists(bytes32 jobId);

    // Status transition errors — tell caller exactly what state job is in
    error JobNotCreated(bytes32 jobId, JobStatus current);
    error JobNotAccepted(bytes32 jobId, JobStatus current);
    error JobNotSubmitted(bytes32 jobId, JobStatus current);
    error JobNotDisputed(bytes32 jobId, JobStatus current);
    error JobAlreadyFinished(bytes32 jobId, JobStatus current);

    error NotClientWallet(bytes32 jobId, address caller);
    error NotWorkerWallet(bytes32 jobId, address caller);
    error NotJobParticipant(bytes32 jobId, address caller);
    error WorkerCannotBeClient(bytes32 jobId);
    error DeadlineNotPassed(bytes32 jobId, uint48 deadline, uint48 currentTime);
    error FeeBpsTooHigh(uint16 provided, uint16 maximum);
    error USDCTransferFailed();

    // ═══════════════════════════════════════════════════════════════
    // WRITE — job lifecycle
    // ═══════════════════════════════════════════════════════════════

    /// @notice Create a new job and lock USDC in the vault.
    ///
    ///         Caller must have approved EscrowVault to spend `amount` USDC
    ///         before calling this function.
    ///
    ///         Platform fee is computed and LOCKED at creation time so the
    ///         worker always knows exactly how much they will receive.
    ///
    /// @param  clientAgentId  agentId of the calling agent (client)
    /// @param  amount         USDC to lock (6 decimals)
    /// @param  deadline       unix timestamp by which work must be submitted
    /// @param  salt           unique value to prevent jobId collisions
    /// @return jobId          unique identifier for this job
    function createJob(
        bytes32 clientAgentId,
        uint128 amount,
        uint48  deadline,
        bytes32 salt
    ) external returns (bytes32 jobId);

    /// @notice Worker accepts a job and commits to delivering work.
    ///         Job must be in CREATED status.
    ///         Caller cannot be the same wallet as the client.
    ///
    /// @param  jobId         job to accept
    /// @param  workerAgentId agentId of the accepting worker
    function acceptJob(bytes32 jobId, bytes32 workerAgentId) external;

    /// @notice Worker submits their deliverable as an on-chain hash.
    ///         Job must be in ACCEPTED status.
    ///         `deliverableHash` is keccak256 of the actual deliverable
    ///         (stored off-chain — e.g. IPFS CID, URL, JSON hash).
    ///         Must be called before deadline.
    ///
    /// @param  jobId            job this submission belongs to
    /// @param  deliverableHash  keccak256 hash of the work product
    function submitWork(bytes32 jobId, bytes32 deliverableHash) external;

    /// @notice Client approves the submitted work.
    ///         Releases USDC to worker minus platform fee.
    ///         Job must be in SUBMITTED status.
    ///         Only callable by clientWallet.
    ///
    /// @param  jobId  job to approve
    function approveWork(bytes32 jobId) external;

    /// @notice Raise a dispute on a submitted job.
    ///         Callable by either client or worker wallet.
    ///         Job must be in SUBMITTED status.
    ///         Admin must then call resolveDispute().
    ///
    /// @param  jobId  job to dispute
    function dispute(bytes32 jobId) external;

    /// @notice Admin resolves a dispute. Sends USDC to the winner.
    ///         Job must be in DISPUTED status.
    ///         Caller must hold RESOLVER_ROLE.
    ///
    /// @param  jobId         disputed job
    /// @param  payClient     true = refund client, false = pay worker
    function resolveDispute(bytes32 jobId, bool payClient) external;

    /// @notice Client cancels a job that has not yet been accepted.
    ///         Returns USDC to client. Job must be in CREATED status.
    ///         Only callable by clientWallet.
    ///
    /// @param  jobId  job to cancel
    function cancel(bytes32 jobId) external;

    /// @notice Client claims a refund after deadline has passed
    ///         without the worker submitting work.
    ///         Job must be in CREATED or ACCEPTED status.
    ///         Only callable by clientWallet.
    ///
    /// @param  jobId  expired job
    function refund(bytes32 jobId) external;

    // ═══════════════════════════════════════════════════════════════
    // WRITE — admin
    // ═══════════════════════════════════════════════════════════════

    /// @notice Update platform fee settings.
    ///         Caller must hold FEE_ADMIN_ROLE.
    ///         Fee is capped at MAX_FEE_BPS — cannot be set higher.
    ///         New fee only applies to jobs created AFTER this call.
    ///
    /// @param  newFeeBps       fee in basis points (100 = 1%, 50 = 0.5%)
    /// @param  newFeeRecipient address that receives collected fees
    function setFee(uint16 newFeeBps, address newFeeRecipient) external;

    // ═══════════════════════════════════════════════════════════════
    // READ
    // ═══════════════════════════════════════════════════════════════

    /// @notice Get full job struct by jobId.
    function getJob(bytes32 jobId) external view returns (Job memory);

    /// @notice Get current status of a job.
    function getJobStatus(bytes32 jobId) external view returns (JobStatus);

    /// @notice Returns true if jobId exists.
    function jobExists(bytes32 jobId) external view returns (bool);

    /// @notice Returns the amount the worker will receive if approved.
    ///         = amount - platformFee
    function workerReceivable(bytes32 jobId) external view returns (uint128);

    /// @notice Current fee in basis points.
    function feeBps() external view returns (uint16);

    /// @notice Current fee recipient address.
    function feeRecipient() external view returns (address);

    /// @notice Maximum fee that can ever be set (immutable).
    function MAX_FEE_BPS() external view returns (uint16);

    /// @notice Minimum job duration in seconds.
    function MIN_JOB_DURATION() external view returns (uint48);

    /// @notice Total USDC currently locked across all active jobs.
    function totalLocked() external view returns (uint128);
}