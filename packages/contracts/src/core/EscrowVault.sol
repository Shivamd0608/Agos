// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../interfaces/IEscrowVault.sol";

/// @title  EscrowVault
/// @notice Trustless job payment system for agent-to-agent commerce.
///
///         Core guarantee:
///         ────────────────────────────────────────────────────────
///         USDC locked in this vault can ONLY leave in three ways:
///           1. approveWork()    → worker wallet (job completed)
///           2. cancel()/refund() → client wallet (job failed/expired)
///           3. resolveDispute() → winner wallet (dispute resolved by admin)
///
///         No other code path moves USDC out. This is enforced by the
///         strict status machine — every write function checks the
///         current status before doing anything.
///
///         Status machine (forward-only, no going back):
///         ────────────────────────────────────────────────────────
///         CREATED → ACCEPTED → SUBMITTED → COMPLETED
///                            ↘ DISPUTED  → RESOLVED
///                ↘ CANCELLED
///         CREATED/ACCEPTED → EXPIRED  (after deadline, via refund())
///
///         Roles:
///         ────────────────────────────────────────────────────────
///         DEPOSITOR_ROLE  — AgentWallet instances. createJob, acceptJob.
///         RESOLVER_ROLE   — Admin/multisig. resolveDispute only.
///         FEE_ADMIN_ROLE  — Admin. setFee only.
///
contract EscrowVault is IEscrowVault, AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ═══════════════════════════════════════════════════════════════
    // CONSTANTS
    // ═══════════════════════════════════════════════════════════════

    /// @notice Maximum platform fee: 5% = 500 basis points.
    ///         Hardcoded — cannot be overridden by any admin call.
    uint16  public constant MAX_FEE_BPS      = 500;

    /// @notice Minimum job duration: 1 hour.
    ///         Prevents jobs with deadlines in the immediate past or next block.
    uint48  public constant MIN_JOB_DURATION = 1 hours;

    // ═══════════════════════════════════════════════════════════════
    // ROLES
    // ═══════════════════════════════════════════════════════════════

    /// @notice AgentWallet instances hold this role.
    ///         Required to call createJob() and acceptJob().
    bytes32 public constant DEPOSITOR_ROLE = keccak256("DEPOSITOR_ROLE");

    /// @notice Admin or multisig. Only address allowed to resolveDispute().
    bytes32 public constant RESOLVER_ROLE  = keccak256("RESOLVER_ROLE");

    /// @notice Admin. Allowed to call setFee().
    bytes32 public constant FEE_ADMIN_ROLE = keccak256("FEE_ADMIN_ROLE");

    // ═══════════════════════════════════════════════════════════════
    // STATE
    // ═══════════════════════════════════════════════════════════════

    /// @dev The USDC contract on this chain.
    IERC20  public immutable usdc;

    /// @dev Platform fee in basis points. Mutable by FEE_ADMIN_ROLE.
    uint16  private _feeBps;

    /// @dev Address that collected fees go to.
    address private _feeRecipient;

    /// @dev Total USDC locked across all active jobs.
    ///      Increases on createJob, decreases on completion/refund/cancel.
    uint128 private _totalLocked;

    /// @dev jobId → Job struct
    mapping(bytes32 => Job) private _jobs;

    /// @dev Global nonce for jobId uniqueness.
    uint256 private _nonce;

    // ═══════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════

    /// @param admin_        Address granted all admin roles initially.
    /// @param usdcToken_    USDC contract address on this chain.
    /// @param feeBps_       Initial platform fee in basis points.
    /// @param feeRecipient_ Initial fee recipient address.
    constructor(
        address admin_,
        address usdcToken_,
        uint16  feeBps_,
        address feeRecipient_
    ) {
        if (admin_        == address(0)) revert ZeroAdmin();
        if (usdcToken_    == address(0)) revert ZeroAddress();
        if (feeRecipient_ == address(0)) revert ZeroAddress();
        if (feeBps_        > MAX_FEE_BPS)
            revert FeeBpsTooHigh(feeBps_, MAX_FEE_BPS);

        usdc          = IERC20(usdcToken_);
        _feeBps       = feeBps_;
        _feeRecipient = feeRecipient_;

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(DEPOSITOR_ROLE,     admin_); // admin can test without wallet
        _grantRole(RESOLVER_ROLE,      admin_);
        _grantRole(FEE_ADMIN_ROLE,     admin_);
    }

    // ═══════════════════════════════════════════════════════════════
    // MODIFIERS
    // ═══════════════════════════════════════════════════════════════

    /// @dev Reverts if job does not exist.
    modifier jobMustExist(bytes32 jobId) {
        if (!_jobs[jobId].exists) revert JobNotFound(jobId);
        _;
    }

    /// @dev Reverts if job is not in the expected status.
    modifier onlyStatus(bytes32 jobId, JobStatus expected) {
        JobStatus current = _jobs[jobId].status;
        if (current != expected) {
            if      (expected == JobStatus.CREATED)   revert JobNotCreated(jobId, current);
            else if (expected == JobStatus.ACCEPTED)  revert JobNotAccepted(jobId, current);
            else if (expected == JobStatus.SUBMITTED) revert JobNotSubmitted(jobId, current);
            else if (expected == JobStatus.DISPUTED)  revert JobNotDisputed(jobId, current);
            else revert JobAlreadyFinished(jobId, current);
        }
        _;
    }

    /// @dev Reverts if caller is not the job's client wallet.
    modifier onlyClient(bytes32 jobId) {
        if (msg.sender != _jobs[jobId].clientWallet)
            revert NotClientWallet(jobId, msg.sender);
        _;
    }

    /// @dev Reverts if caller is not the job's worker wallet.
    modifier onlyWorker(bytes32 jobId) {
        if (msg.sender != _jobs[jobId].workerWallet)
            revert NotWorkerWallet(jobId, msg.sender);
        _;
    }

    // ═══════════════════════════════════════════════════════════════
    // WRITE — job lifecycle
    // ═══════════════════════════════════════════════════════════════

    /// @notice Create a new job and lock `amount` USDC in this vault.
    ///
    ///         Caller must have called usdc.approve(escrowVault, amount)
    ///         BEFORE calling this function.
    ///
    ///         Platform fee is computed and stored now so the worker
    ///         knows exactly what they will receive when they accept.
    ///         Fee never changes after job creation.
    ///
    /// @param  clientAgentId   bytes32 agentId of the calling agent
    /// @param  amount          USDC amount to lock (6 decimals)
    /// @param  deadline        unix timestamp — work must be submitted before this
    /// @param  salt            unique bytes32 to prevent jobId collisions
    /// @return jobId           the new job's unique identifier
    function createJob(
        bytes32 clientAgentId,
        uint128 amount,
        uint48  deadline,
        bytes32 salt
    )
        external
        nonReentrant
        onlyRole(DEPOSITOR_ROLE)
        returns (bytes32 jobId)
    {
        // ── Input validation ──────────────────────────────────────
        if (clientAgentId == bytes32(0)) revert ZeroAgentId();
        if (amount        == 0)          revert ZeroAmount();

        if (deadline == 0)
            revert ZeroDeadline();
        if (deadline <= block.timestamp)
            revert DeadlineInPast(deadline, uint48(block.timestamp));
        if (deadline < uint48(block.timestamp) + MIN_JOB_DURATION)
            revert DeadlineTooShort(deadline, uint48(block.timestamp) + MIN_JOB_DURATION);

        // ── Compute jobId ─────────────────────────────────────────
        // Unique: clientAgentId + caller address + salt + global nonce
        // The nonce prevents identical jobs from same agent with same salt
        jobId = keccak256(
            abi.encodePacked(clientAgentId, msg.sender, salt, _nonce++)
        );

        if (_jobs[jobId].exists) revert JobAlreadyExists(jobId);

        // ── Compute platform fee ──────────────────────────────────
        // Fee locked at creation. Worker always knows exact receivable.
        // Integer division floors down — rounds in favour of the worker.
        uint128 fee = uint128((uint256(amount) * _feeBps) / 10_000);

        // ── Pull USDC from caller into this vault ─────────────────
        // SafeERC20 handles tokens that return false instead of reverting
        usdc.safeTransferFrom(msg.sender, address(this), uint256(amount));

        // ── Write job to storage ──────────────────────────────────
        _jobs[jobId] = Job({
            jobId:           jobId,
            clientAgentId:   clientAgentId,
            workerAgentId:   bytes32(0),       // set on acceptJob()
            clientWallet:    msg.sender,
            workerWallet:    address(0),       // set on acceptJob()
            amount:          amount,
            platformFee:     fee,
            deadline:        deadline,
            createdAt:       uint48(block.timestamp),
            resolvedAt:      0,
            deliverableHash: bytes32(0),       // set on submitWork()
            status:          JobStatus.CREATED,
            exists:          true
        });

        // ── Update global locked tracker ──────────────────────────
        _totalLocked += amount;

        emit JobCreated(jobId, clientAgentId, msg.sender, amount, deadline);
    }

    /// @notice Worker accepts a job, committing to deliver work.
    ///
    ///         Job transitions: CREATED → ACCEPTED
    ///
    ///         Worker cannot be the same wallet as the client.
    ///         No USDC moves here — it stays locked from createJob.
    ///
    /// @param  jobId          job to accept
    /// @param  workerAgentId  agentId of the accepting worker
    function acceptJob(bytes32 jobId, bytes32 workerAgentId)
        external
        nonReentrant
        onlyRole(DEPOSITOR_ROLE)
        jobMustExist(jobId)
        onlyStatus(jobId, JobStatus.CREATED)
    {
        if (workerAgentId == bytes32(0)) revert ZeroAgentId();

        Job storage job = _jobs[jobId];

        // Worker cannot be the same wallet as client
        if (msg.sender == job.clientWallet)
            revert WorkerCannotBeClient(jobId);

        // Deadline must not have passed
        if (block.timestamp > job.deadline)
            revert DeadlineNotPassed(jobId, job.deadline, uint48(block.timestamp));

        job.workerAgentId = workerAgentId;
        job.workerWallet  = msg.sender;
        job.status        = JobStatus.ACCEPTED;

        emit JobAccepted(jobId, workerAgentId, msg.sender);
    }

    /// @notice Worker submits deliverable as an on-chain hash.
    ///
    ///         Job transitions: ACCEPTED → SUBMITTED
    ///
    ///         `deliverableHash` is keccak256 of the actual deliverable.
    ///         The real deliverable lives off-chain (IPFS, URL, database).
    ///         The hash is the on-chain proof that the work was submitted
    ///         at a specific time — it cannot be backdated or altered.
    ///
    ///         Must be submitted before deadline.
    ///
    /// @param  jobId            job this submission belongs to
    /// @param  deliverableHash  keccak256 of the work product
    function submitWork(bytes32 jobId, bytes32 deliverableHash)
        external
        nonReentrant
        jobMustExist(jobId)
        onlyStatus(jobId, JobStatus.ACCEPTED)
        onlyWorker(jobId)
    {
        if (deliverableHash == bytes32(0)) revert ZeroAgentId(); // reuse zero check

        Job storage job = _jobs[jobId];

        // Must submit before deadline
        if (block.timestamp > job.deadline)
            revert DeadlineNotPassed(jobId, job.deadline, uint48(block.timestamp));

        job.deliverableHash = deliverableHash;
        job.status          = JobStatus.SUBMITTED;

        emit WorkSubmitted(jobId, job.workerAgentId, deliverableHash);
    }

    /// @notice Client approves the submitted work.
    ///
    ///         Job transitions: SUBMITTED → COMPLETED
    ///
    ///         Releases USDC:
    ///           worker receives: amount - platformFee
    ///           feeRecipient receives: platformFee (if > 0)
    ///
    ///         Only callable by clientWallet.
    ///
    /// @param  jobId  job to approve
    function approveWork(bytes32 jobId)
        external
        nonReentrant
        jobMustExist(jobId)
        onlyStatus(jobId, JobStatus.SUBMITTED)
        onlyClient(jobId)
    {
        Job storage job = _jobs[jobId];

        job.status     = JobStatus.COMPLETED;
        job.resolvedAt = uint48(block.timestamp);

        uint128 fee        = job.platformFee;
        uint128 workerPays = job.amount - fee;

        // ── Update locked tracker ─────────────────────────────────
        _totalLocked -= job.amount;

        // ── Send USDC to worker ───────────────────────────────────
        usdc.safeTransfer(job.workerWallet, uint256(workerPays));

        // ── Send fee to recipient (only if fee > 0) ───────────────
        if (fee > 0) {
            usdc.safeTransfer(_feeRecipient, uint256(fee));
        }

        emit JobCompleted(jobId, job.workerWallet, workerPays, fee);
    }

    /// @notice Either client or worker raises a dispute on submitted work.
    ///
    ///         Job transitions: SUBMITTED → DISPUTED
    ///
    ///         Once disputed, funds are frozen until resolveDispute() is called.
    ///         Only callable by clientWallet or workerWallet.
    ///
    /// @param  jobId  job to dispute
    function dispute(bytes32 jobId)
        external
        nonReentrant
        jobMustExist(jobId)
        onlyStatus(jobId, JobStatus.SUBMITTED)
    {
        Job storage job = _jobs[jobId];

        // Only client or worker can raise a dispute
        if (msg.sender != job.clientWallet && msg.sender != job.workerWallet)
            revert NotJobParticipant(jobId, msg.sender);

        job.status = JobStatus.DISPUTED;

        emit JobDisputed(jobId, msg.sender);
    }

    /// @notice Admin resolves a dispute and sends funds to the winner.
    ///
    ///         Job transitions: DISPUTED → RESOLVED
    ///
    ///         If payClient = true:  full amount refunded to client.
    ///         If payClient = false: worker receives amount - fee,
    ///                               fee goes to feeRecipient.
    ///
    ///         Only RESOLVER_ROLE can call this.
    ///
    /// @param  jobId      disputed job
    /// @param  payClient  true = client wins, false = worker wins
    function resolveDispute(bytes32 jobId, bool payClient)
        external
        nonReentrant
        onlyRole(RESOLVER_ROLE)
        jobMustExist(jobId)
        onlyStatus(jobId, JobStatus.DISPUTED)
    {
        Job storage job = _jobs[jobId];

        job.status     = JobStatus.RESOLVED;
        job.resolvedAt = uint48(block.timestamp);

        _totalLocked -= job.amount;

        if (payClient) {
            // ── Client wins: full refund ──────────────────────────
            usdc.safeTransfer(job.clientWallet, uint256(job.amount));

            emit DisputeResolved(jobId, job.clientWallet, job.amount);

        } else {
            // ── Worker wins: pay worker minus fee ─────────────────
            uint128 fee        = job.platformFee;
            uint128 workerPays = job.amount - fee;

            usdc.safeTransfer(job.workerWallet, uint256(workerPays));

            if (fee > 0) {
                usdc.safeTransfer(_feeRecipient, uint256(fee));
            }

            emit DisputeResolved(jobId, job.workerWallet, workerPays);
        }
    }

    /// @notice Client cancels a job that has not yet been accepted.
    ///
    ///         Job transitions: CREATED → CANCELLED
    ///
    ///         Full amount refunded to client. No fee taken.
    ///         Only callable by clientWallet.
    ///         Only available when status is CREATED (not yet accepted).
    ///
    /// @param  jobId  job to cancel
    function cancel(bytes32 jobId)
        external
        nonReentrant
        jobMustExist(jobId)
        onlyStatus(jobId, JobStatus.CREATED)
        onlyClient(jobId)
    {
        Job storage job = _jobs[jobId];

        job.status     = JobStatus.CANCELLED;
        job.resolvedAt = uint48(block.timestamp);

        _totalLocked -= job.amount;

        // Full refund — no fee on cancellation
        usdc.safeTransfer(job.clientWallet, uint256(job.amount));

        emit JobCancelled(jobId, job.clientWallet, job.amount);
    }

    /// @notice Client claims refund after deadline passes.
    ///
    ///         Job transitions: CREATED/ACCEPTED → EXPIRED
    ///
    ///         Available when:
    ///           - Job is CREATED and deadline has passed (worker never accepted)
    ///           - Job is ACCEPTED and deadline has passed (worker accepted but never submitted)
    ///
    ///         Full amount refunded to client. No fee taken.
    ///         Only callable by clientWallet.
    ///
    /// @param  jobId  expired job
    function refund(bytes32 jobId)
        external
        nonReentrant
        jobMustExist(jobId)
        onlyClient(jobId)
    {
        Job storage job = _jobs[jobId];

        // Only available from CREATED or ACCEPTED (not yet submitted)
        if (job.status != JobStatus.CREATED && job.status != JobStatus.ACCEPTED)
            revert JobAlreadyFinished(jobId, job.status);

        // Deadline must have passed
        if (block.timestamp <= job.deadline)
            revert DeadlineNotPassed(jobId, job.deadline, uint48(block.timestamp));

        job.status     = JobStatus.EXPIRED;
        job.resolvedAt = uint48(block.timestamp);

        _totalLocked -= job.amount;

        // Full refund — no fee on expired jobs
        usdc.safeTransfer(job.clientWallet, uint256(job.amount));

        emit JobExpired(jobId, job.clientWallet, job.amount);
    }

    // ═══════════════════════════════════════════════════════════════
    // WRITE — admin
    // ═══════════════════════════════════════════════════════════════

    /// @notice Update platform fee settings.
    ///         New fee only affects jobs created AFTER this call.
    ///         Existing locked jobs keep their fee from creation time.
    ///
    /// @param  newFeeBps       fee in basis points — cannot exceed MAX_FEE_BPS
    /// @param  newFeeRecipient address to receive future fees
    function setFee(uint16 newFeeBps, address newFeeRecipient)
        external
        onlyRole(FEE_ADMIN_ROLE)
    {
        if (newFeeBps       > MAX_FEE_BPS) revert FeeBpsTooHigh(newFeeBps, MAX_FEE_BPS);
        if (newFeeRecipient == address(0)) revert ZeroAddress();

        _feeBps       = newFeeBps;
        _feeRecipient = newFeeRecipient;

        emit FeeUpdated(newFeeBps, newFeeRecipient);
    }

    // ═══════════════════════════════════════════════════════════════
    // READ
    // ═══════════════════════════════════════════════════════════════

    /// @notice Return the full Job struct for a given jobId.
    function getJob(bytes32 jobId)
        external view
        returns (Job memory)
    {
        return _jobs[jobId];
    }

    /// @notice Return only the current status of a job.
    ///         Gas-efficient — does not load the full struct.
    function getJobStatus(bytes32 jobId)
        external view
        jobMustExist(jobId)
        returns (JobStatus)
    {
        return _jobs[jobId].status;
    }

    /// @notice True if a job exists with this jobId.
    function jobExists(bytes32 jobId)
        external view
        returns (bool)
    {
        return _jobs[jobId].exists;
    }

    /// @notice Amount worker will receive if job is approved.
    ///         Returns 0 if job does not exist.
    function workerReceivable(bytes32 jobId)
        external view
        returns (uint128)
    {
        Job storage job = _jobs[jobId];
        if (!job.exists) return 0;
        return job.amount - job.platformFee;
    }

    /// @notice Current platform fee in basis points.
    function feeBps() external view returns (uint16) {
        return _feeBps;
    }

    /// @notice Current fee recipient.
    function feeRecipient() external view returns (address) {
        return _feeRecipient;
    }

    /// @notice Total USDC currently locked across all active jobs.
    function totalLocked() external view returns (uint128) {
        return _totalLocked;
    }
}