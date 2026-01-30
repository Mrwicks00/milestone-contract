;; MilestoneXYZ - Decentralized Freelance Marketplace
;; A trustless platform connecting clients and freelancers through milestone-based escrow contracts

;; Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-PROJECT-NOT-FOUND (err u101))
(define-constant ERR-MILESTONE-NOT-FOUND (err u102))
(define-constant ERR-INVALID-STATUS (err u103))
(define-constant ERR-INSUFFICIENT-FUNDS (err u104))
(define-constant ERR-ALREADY-EXISTS (err u105))
(define-constant ERR-DEADLINE-PASSED (err u106))
(define-constant ERR-INVALID-AMOUNT (err u107))
(define-constant ERR-DISPUTE-EXISTS (err u108))
(define-constant ERR-INVALID-DECISION (err u109))
(define-constant ERR-NOT-READY (err u110))
(define-constant ERR-INVALID-RATING (err u111))
(define-constant ERR-ALREADY-RATED (err u112))

;; Platform fee percentages (in basis points: 100 = 1%)
(define-constant FEE-BRONZE u300) ;; 3%
(define-constant FEE-SILVER u250) ;; 2.5%
(define-constant FEE-GOLD u200) ;; 2%
(define-constant FEE-PLATINUM u150) ;; 1.5%
(define-constant FEE-CLIENT u100) ;; 1%
(define-constant FEE-DISPUTE u500) ;; 5%

;; Tier thresholds
(define-constant TIER-SILVER-THRESHOLD u6)
(define-constant TIER-GOLD-THRESHOLD u21)
(define-constant TIER-PLATINUM-THRESHOLD u51)

;; Auto-approval timeout (in blocks, ~72 hours = 432 blocks at 10 min/block)
(define-constant AUTO-APPROVE-TIMEOUT u432)

;; Minimum project value (10 STX)
(define-constant MIN-PROJECT-VALUE u10000000)

;; Data Variables
(define-data-var project-nonce uint u0)
(define-data-var milestone-nonce uint u0)
(define-data-var dispute-nonce uint u0)
(define-data-var platform-treasury principal CONTRACT-OWNER)

;; Project Status
(define-constant STATUS-OPEN "open")
(define-constant STATUS-ACTIVE "active")
(define-constant STATUS-COMPLETED "completed")
(define-constant STATUS-CANCELLED "cancelled")
(define-constant STATUS-DISPUTED "disputed")

;; Milestone Status
(define-constant MILESTONE-PENDING "pending")
(define-constant MILESTONE-SUBMITTED "submitted")
(define-constant MILESTONE-APPROVED "approved")
(define-constant MILESTONE-REVISION "revision")
(define-constant MILESTONE-DISPUTED "disputed")

;; Dispute Status
(define-constant DISPUTE-OPEN "open")
(define-constant DISPUTE-EVIDENCE "evidence")
(define-constant DISPUTE-REVIEW "review")
(define-constant DISPUTE-RESOLVED "resolved")

;; Data Maps

;; Projects
(define-map projects
  { project-id: uint }
  {
    client: principal,
    freelancer: (optional principal),
    title: (string-utf8 256),
    description: (string-utf8 2048),
    total-budget: uint,
    escrow-balance: uint,
    status: (string-ascii 20),
    created-at: uint,
    deadline: uint,
    category: (string-ascii 50),
    milestones-count: uint,
    completed-milestones: uint,
  }
)

;; Milestones
(define-map milestones
  { milestone-id: uint }
  {
    project-id: uint,
    title: (string-utf8 256),
    description: (string-utf8 1024),
    payment-amount: uint,
    deadline: uint,
    status: (string-ascii 20),
    submitted-at: (optional uint),
    approved-at: (optional uint),
    deliverable-hash: (optional (buff 64)),
    revision-count: uint,
  }
)

;; Disputes
(define-map disputes
  { dispute-id: uint }
  {
    milestone-id: uint,
    project-id: uint,
    raised-by: principal,
    reason: (string-utf8 512),
    evidence-hash: (buff 64),
    arbitrator: (optional principal),
    status: (string-ascii 20),
    decision: (optional (string-ascii 20)),
    payment-allocation: (optional uint),
    created-at: uint,
    resolved-at: (optional uint),
  }
)

;; User Reputation
(define-map reputation
  { user: principal }
  {
    total-projects: uint,
    completed-projects: uint,
    total-earned: uint,
    total-spent: uint,
    average-rating: uint,
    total-ratings: uint,
    disputes-raised: uint,
    disputes-lost: uint,
    on-time-deliveries: uint,
    late-deliveries: uint,
    tier: (string-ascii 20),
  }
)

;; Project Ratings (one rating per project per user)
(define-map project-ratings
  {
    project-id: uint,
    rater: principal,
  }
  {
    rating: uint,
    review: (string-utf8 512),
    created-at: uint,
  }
)

;; Milestone to Project mapping
(define-map milestone-to-project
  { milestone-id: uint }
  { project-id: uint }
)

;; User projects tracking
(define-map user-projects
  {
    user: principal,
    index: uint,
  }
  { project-id: uint }
)

(define-map user-project-count
  { user: principal }
  { count: uint }
)

;; Private Helper Functions

;; Calculate platform fee based on user tier
(define-private (calculate-fee
    (amount uint)
    (user principal)
    (is-client bool)
  )
  (let (
      (user-rep (default-to {
        total-projects: u0,
        completed-projects: u0,
        total-earned: u0,
        total-spent: u0,
        average-rating: u0,
        total-ratings: u0,
        disputes-raised: u0,
        disputes-lost: u0,
        on-time-deliveries: u0,
        late-deliveries: u0,
        tier: "bronze",
      }
        (map-get? reputation { user: user })
      ))
      (tier (get tier user-rep))
      (fee-rate (if is-client
        FEE-CLIENT
        (if (is-eq tier "platinum")
          FEE-PLATINUM
          (if (is-eq tier "gold")
            FEE-GOLD
            (if (is-eq tier "silver")
              FEE-SILVER
              FEE-BRONZE
            )
          )
        )
      ))
    )
    (/ (* amount fee-rate) u10000)
  )
)

;; Calculate user tier based on completed projects and rating
(define-private (calculate-tier
    (completed-projects uint)
    (average-rating uint)
  )
  (if (and (>= completed-projects TIER-PLATINUM-THRESHOLD) (>= average-rating u450))
    "platinum"
    (if (>= completed-projects TIER-GOLD-THRESHOLD)
      "gold"
      (if (>= completed-projects TIER-SILVER-THRESHOLD)
        "silver"
        "bronze"
      )
    )
  )
)

;; Update user reputation
(define-private (update-user-reputation
    (user principal)
    (updates {
      total-projects-delta: uint,
      completed-projects-delta: uint,
      earned-delta: uint,
      spent-delta: uint,
      disputes-raised-delta: uint,
      disputes-lost-delta: uint,
      on-time-delta: uint,
      late-delta: uint,
    })
  )
  (let (
      (current-rep (default-to {
        total-projects: u0,
        completed-projects: u0,
        total-earned: u0,
        total-spent: u0,
        average-rating: u0,
        total-ratings: u0,
        disputes-raised: u0,
        disputes-lost: u0,
        on-time-deliveries: u0,
        late-deliveries: u0,
        tier: "bronze",
      }
        (map-get? reputation { user: user })
      ))
      (new-total-projects (+ (get total-projects current-rep) (get total-projects-delta updates)))
      (new-completed-projects (+ (get completed-projects current-rep)
        (get completed-projects-delta updates)
      ))
      (new-total-earned (+ (get total-earned current-rep) (get earned-delta updates)))
      (new-total-spent (+ (get total-spent current-rep) (get spent-delta updates)))
      (new-disputes-raised (+ (get disputes-raised current-rep) (get disputes-raised-delta updates)))
      (new-disputes-lost (+ (get disputes-lost current-rep) (get disputes-lost-delta updates)))
      (new-on-time (+ (get on-time-deliveries current-rep) (get on-time-delta updates)))
      (new-late (+ (get late-deliveries current-rep) (get late-delta updates)))
      (new-tier (calculate-tier new-completed-projects (get average-rating current-rep)))
    )
    (map-set reputation { user: user } {
      total-projects: new-total-projects,
      completed-projects: new-completed-projects,
      total-earned: new-total-earned,
      total-spent: new-total-spent,
      average-rating: (get average-rating current-rep),
      total-ratings: (get total-ratings current-rep),
      disputes-raised: new-disputes-raised,
      disputes-lost: new-disputes-lost,
      on-time-deliveries: new-on-time,
      late-deliveries: new-late,
      tier: new-tier,
    })
    (ok true)
  )
)

;; Add project to user's project list
(define-private (add-user-project
    (user principal)
    (project-id uint)
  )
  (let (
      (current-count (default-to { count: u0 } (map-get? user-project-count { user: user })))
      (index (get count current-count))
    )
    (map-set user-projects {
      user: user,
      index: index,
    } { project-id: project-id }
    )
    (map-set user-project-count { user: user } { count: (+ index u1) })
    (ok true)
  )
)

;; Public Functions

;; Create a new project
(define-public (create-project
    (title (string-utf8 256))
    (description (string-utf8 2048))
    (total-budget uint)
    (deadline uint)
    (category (string-ascii 50))
    (milestones-count uint)
  )
  (let (
      (project-id (+ (var-get project-nonce) u1))
      (client tx-sender)
      (client-fee (calculate-fee total-budget client true))
    )
    ;; Validations
    (asserts! (>= total-budget MIN-PROJECT-VALUE) ERR-INVALID-AMOUNT)
    (asserts! (> milestones-count u0) ERR-INVALID-AMOUNT)
    (asserts! (> deadline block-height) ERR-DEADLINE-PASSED)

    ;; Transfer total budget to contract as escrow
    (try! (stx-transfer? total-budget client (as-contract tx-sender)))

    ;; Transfer client fee to treasury
    (try! (stx-transfer? client-fee client (var-get platform-treasury)))

    ;; Create project
    (map-set projects { project-id: project-id } {
      client: client,
      freelancer: none,
      title: title,
      description: description,
      total-budget: total-budget,
      escrow-balance: total-budget,
      status: STATUS-OPEN,
      created-at: block-height,
      deadline: deadline,
      category: category,
      milestones-count: milestones-count,
      completed-milestones: u0,
    })

    ;; Update nonce
    (var-set project-nonce project-id)

    ;; Add to user's projects
    (unwrap! (add-user-project client project-id) ERR-INVALID-AMOUNT)

    ;; Update client reputation
    (unwrap!
      (update-user-reputation client {
        total-projects-delta: u1,
        completed-projects-delta: u0,
        earned-delta: u0,
        spent-delta: u0,
        disputes-raised-delta: u0,
        disputes-lost-delta: u0,
        on-time-delta: u0,
        late-delta: u0,
      })
      ERR-INVALID-AMOUNT
    )

    (ok project-id)
  )
)

;; Accept proposal and assign freelancer to project
(define-public (accept-proposal
    (project-id uint)
    (freelancer principal)
  )
  (let ((project (unwrap! (map-get? projects { project-id: project-id }) ERR-PROJECT-NOT-FOUND)))
    ;; Only client can accept proposals
    (asserts! (is-eq tx-sender (get client project)) ERR-NOT-AUTHORIZED)
    ;; Project must be open
    (asserts! (is-eq (get status project) STATUS-OPEN) ERR-INVALID-STATUS)

    ;; Update project with freelancer and set to active
    (map-set projects { project-id: project-id }
      (merge project {
        freelancer: (some freelancer),
        status: STATUS-ACTIVE,
      })
    )

    ;; Add to freelancer's projects
    (unwrap! (add-user-project freelancer project-id) ERR-INVALID-AMOUNT)

    ;; Update freelancer reputation
    (unwrap!
      (update-user-reputation freelancer {
        total-projects-delta: u1,
        completed-projects-delta: u0,
        earned-delta: u0,
        spent-delta: u0,
        disputes-raised-delta: u0,
        disputes-lost-delta: u0,
        on-time-delta: u0,
        late-delta: u0,
      })
      ERR-INVALID-AMOUNT
    )

    (ok true)
  )
)

;; Create a milestone for a project
(define-public (create-milestone
    (project-id uint)
    (title (string-utf8 256))
    (description (string-utf8 1024))
    (payment-amount uint)
    (deadline uint)
  )
  (let (
      (project (unwrap! (map-get? projects { project-id: project-id })
        ERR-PROJECT-NOT-FOUND
      ))
      (milestone-id (+ (var-get milestone-nonce) u1))
    )
    ;; Only client can create milestones
    (asserts! (is-eq tx-sender (get client project)) ERR-NOT-AUTHORIZED)
    ;; Project must be active or open
    (asserts!
      (or
        (is-eq (get status project) STATUS-ACTIVE)
        (is-eq (get status project) STATUS-OPEN)
      )
      ERR-INVALID-STATUS
    )
    ;; Payment amount must not exceed escrow balance
    (asserts! (<= payment-amount (get escrow-balance project))
      ERR-INSUFFICIENT-FUNDS
    )
    ;; Deadline must be in the future
    (asserts! (> deadline block-height) ERR-DEADLINE-PASSED)

    ;; Create milestone
    (map-set milestones { milestone-id: milestone-id } {
      project-id: project-id,
      title: title,
      description: description,
      payment-amount: payment-amount,
      deadline: deadline,
      status: MILESTONE-PENDING,
      submitted-at: none,
      approved-at: none,
      deliverable-hash: none,
      revision-count: u0,
    })

    ;; Map milestone to project
    (map-set milestone-to-project { milestone-id: milestone-id } { project-id: project-id })

    ;; Update nonce
    (var-set milestone-nonce milestone-id)

    (ok milestone-id)
  )
)

;; Submit milestone deliverable
(define-public (submit-milestone
    (milestone-id uint)
    (deliverable-hash (buff 64))
  )
  (let (
      (milestone (unwrap! (map-get? milestones { milestone-id: milestone-id })
        ERR-MILESTONE-NOT-FOUND
      ))
      (project-id (get project-id milestone))
      (project (unwrap! (map-get? projects { project-id: project-id })
        ERR-PROJECT-NOT-FOUND
      ))
      (freelancer (unwrap! (get freelancer project) ERR-NOT-AUTHORIZED))
    )
    ;; Only assigned freelancer can submit
    (asserts! (is-eq tx-sender freelancer) ERR-NOT-AUTHORIZED)
    ;; Milestone must be pending or in revision
    (asserts!
      (or
        (is-eq (get status milestone) MILESTONE-PENDING)
        (is-eq (get status milestone) MILESTONE-REVISION)
      )
      ERR-INVALID-STATUS
    )

    ;; Update milestone
    (map-set milestones { milestone-id: milestone-id }
      (merge milestone {
        status: MILESTONE-SUBMITTED,
        submitted-at: (some block-height),
        deliverable-hash: (some deliverable-hash),
      })
    )

    (ok true)
  )
)

;; Approve milestone and release payment
(define-public (approve-milestone (milestone-id uint))
  (let (
      (milestone (unwrap! (map-get? milestones { milestone-id: milestone-id })
        ERR-MILESTONE-NOT-FOUND
      ))
      (project-id (get project-id milestone))
      (project (unwrap! (map-get? projects { project-id: project-id })
        ERR-PROJECT-NOT-FOUND
      ))
      (freelancer (unwrap! (get freelancer project) ERR-NOT-AUTHORIZED))
      (payment-amount (get payment-amount milestone))
      (freelancer-fee (calculate-fee payment-amount freelancer false))
      (net-payment (- payment-amount freelancer-fee))
      (is-on-time (match (get submitted-at milestone)
        submitted-block (<= submitted-block (get deadline milestone))
        false
      ))
    )
    ;; Only client can approve
    (asserts! (is-eq tx-sender (get client project)) ERR-NOT-AUTHORIZED)
    ;; Milestone must be submitted
    (asserts! (is-eq (get status milestone) MILESTONE-SUBMITTED)
      ERR-INVALID-STATUS
    )
    ;; Sufficient escrow balance
    (asserts! (>= (get escrow-balance project) payment-amount)
      ERR-INSUFFICIENT-FUNDS
    )

    ;; Transfer payment to freelancer (minus platform fee)
    (try! (as-contract (stx-transfer? net-payment tx-sender freelancer)))

    ;; Transfer freelancer fee to treasury
    (try! (as-contract (stx-transfer? freelancer-fee tx-sender (var-get platform-treasury))))

    ;; Update milestone
    (map-set milestones { milestone-id: milestone-id }
      (merge milestone {
        status: MILESTONE-APPROVED,
        approved-at: (some block-height),
      })
    )

    ;; Update project
    (let (
        (new-escrow-balance (- (get escrow-balance project) payment-amount))
        (new-completed-milestones (+ (get completed-milestones project) u1))
        (all-milestones-completed (is-eq new-completed-milestones (get milestones-count project)))
        (new-status (if all-milestones-completed
          STATUS-COMPLETED
          (get status project)
        ))
      )
      (map-set projects { project-id: project-id }
        (merge project {
          escrow-balance: new-escrow-balance,
          completed-milestones: new-completed-milestones,
          status: new-status,
        })
      )

      ;; Update freelancer reputation
      (unwrap!
        (update-user-reputation freelancer {
          total-projects-delta: u0,
          completed-projects-delta: (if all-milestones-completed
            u1
            u0
          ),
          earned-delta: net-payment,
          spent-delta: u0,
          disputes-raised-delta: u0,
          disputes-lost-delta: u0,
          on-time-delta: (if is-on-time
            u1
            u0
          ),
          late-delta: (if is-on-time
            u0
            u1
          ),
        })
        ERR-INVALID-AMOUNT
      )

      ;; Update client reputation if project completed
      (if all-milestones-completed
        (unwrap!
          (update-user-reputation (get client project) {
            total-projects-delta: u0,
            completed-projects-delta: u1,
            earned-delta: u0,
            spent-delta: payment-amount,
            disputes-raised-delta: u0,
            disputes-lost-delta: u0,
            on-time-delta: u0,
            late-delta: u0,
          })
          ERR-INVALID-AMOUNT
        )
        true
      )
    )

    (ok true)
  )
)

;; Request revision on milestone
(define-public (request-revision
    (milestone-id uint)
    (feedback (string-utf8 512))
  )
  (let (
      (milestone (unwrap! (map-get? milestones { milestone-id: milestone-id })
        ERR-MILESTONE-NOT-FOUND
      ))
      (project-id (get project-id milestone))
      (project (unwrap! (map-get? projects { project-id: project-id })
        ERR-PROJECT-NOT-FOUND
      ))
    )
    ;; Only client can request revision
    (asserts! (is-eq tx-sender (get client project)) ERR-NOT-AUTHORIZED)
    ;; Milestone must be submitted
    (asserts! (is-eq (get status milestone) MILESTONE-SUBMITTED)
      ERR-INVALID-STATUS
    )

    ;; Update milestone
    (map-set milestones { milestone-id: milestone-id }
      (merge milestone {
        status: MILESTONE-REVISION,
        revision-count: (+ (get revision-count milestone) u1),
      })
    )

    (ok true)
  )
)

;; Auto-approve milestone after timeout
(define-public (auto-approve-milestone (milestone-id uint))
  (let (
      (milestone (unwrap! (map-get? milestones { milestone-id: milestone-id })
        ERR-MILESTONE-NOT-FOUND
      ))
      (project-id (get project-id milestone))
      (project (unwrap! (map-get? projects { project-id: project-id })
        ERR-PROJECT-NOT-FOUND
      ))
      (submitted-at (unwrap! (get submitted-at milestone) ERR-NOT-READY))
      (freelancer (unwrap! (get freelancer project) ERR-NOT-AUTHORIZED))
    )
    ;; Milestone must be submitted
    (asserts! (is-eq (get status milestone) MILESTONE-SUBMITTED)
      ERR-INVALID-STATUS
    )
    ;; Timeout period must have passed
    (asserts! (>= (- block-height submitted-at) AUTO-APPROVE-TIMEOUT)
      ERR-NOT-READY
    )

    ;; Call approve-milestone
    (approve-milestone milestone-id)
  )
)

;; Raise a dispute
(define-public (raise-dispute
    (milestone-id uint)
    (reason (string-utf8 512))
    (evidence-hash (buff 64))
  )
  (let (
      (milestone (unwrap! (map-get? milestones { milestone-id: milestone-id })
        ERR-MILESTONE-NOT-FOUND
      ))
      (project-id (get project-id milestone))
      (project (unwrap! (map-get? projects { project-id: project-id })
        ERR-PROJECT-NOT-FOUND
      ))
      (freelancer (unwrap! (get freelancer project) ERR-NOT-AUTHORIZED))
      (dispute-id (+ (var-get dispute-nonce) u1))
    )
    ;; Only client or freelancer can raise dispute
    (asserts!
      (or
        (is-eq tx-sender (get client project))
        (is-eq tx-sender freelancer)
      )
      ERR-NOT-AUTHORIZED
    )
    ;; Milestone must be submitted
    (asserts! (is-eq (get status milestone) MILESTONE-SUBMITTED)
      ERR-INVALID-STATUS
    )

    ;; Create dispute
    (map-set disputes { dispute-id: dispute-id } {
      milestone-id: milestone-id,
      project-id: project-id,
      raised-by: tx-sender,
      reason: reason,
      evidence-hash: evidence-hash,
      arbitrator: none,
      status: DISPUTE-OPEN,
      decision: none,
      payment-allocation: none,
      created-at: block-height,
      resolved-at: none,
    })

    ;; Update milestone status
    (map-set milestones { milestone-id: milestone-id }
      (merge milestone { status: MILESTONE-DISPUTED })
    )

    ;; Update project status
    (map-set projects { project-id: project-id }
      (merge project { status: STATUS-DISPUTED })
    )

    ;; Update nonce
    (var-set dispute-nonce dispute-id)

    ;; Update reputation
    (unwrap!
      (update-user-reputation tx-sender {
        total-projects-delta: u0,
        completed-projects-delta: u0,
        earned-delta: u0,
        spent-delta: u0,
        disputes-raised-delta: u1,
        disputes-lost-delta: u0,
        on-time-delta: u0,
        late-delta: u0,
      })
      ERR-INVALID-AMOUNT
    )

    (ok dispute-id)
  )
)

;; Assign arbitrator to dispute (only contract owner)
(define-public (assign-arbitrator
    (dispute-id uint)
    (arbitrator principal)
  )
  (let ((dispute (unwrap! (map-get? disputes { dispute-id: dispute-id }) ERR-DISPUTE-EXISTS)))
    ;; Only contract owner can assign arbitrators
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    ;; Dispute must be open
    (asserts! (is-eq (get status dispute) DISPUTE-OPEN) ERR-INVALID-STATUS)

    ;; Update dispute
    (map-set disputes { dispute-id: dispute-id }
      (merge dispute {
        arbitrator: (some arbitrator),
        status: DISPUTE-REVIEW,
      })
    )

    (ok true)
  )
)

;; Resolve dispute (only assigned arbitrator)
(define-public (resolve-dispute
    (dispute-id uint)
    (decision (string-ascii 20))
    (freelancer-allocation uint)
  )
  (let (
      (dispute (unwrap! (map-get? disputes { dispute-id: dispute-id }) ERR-DISPUTE-EXISTS))
      (arbitrator (unwrap! (get arbitrator dispute) ERR-NOT-AUTHORIZED))
      (milestone-id (get milestone-id dispute))
      (milestone (unwrap! (map-get? milestones { milestone-id: milestone-id })
        ERR-MILESTONE-NOT-FOUND
      ))
      (project-id (get project-id dispute))
      (project (unwrap! (map-get? projects { project-id: project-id })
        ERR-PROJECT-NOT-FOUND
      ))
      (freelancer (unwrap! (get freelancer project) ERR-NOT-AUTHORIZED))
      (payment-amount (get payment-amount milestone))
      (dispute-fee (/ (* payment-amount FEE-DISPUTE) u10000))
      (net-pot (- payment-amount dispute-fee))
      ;; Calculate proportional share for freelancer
      ;; (alloc * net_pot) / total
      (freelancer-share (/ (* freelancer-allocation net-pot) payment-amount))
      (client-share (- net-pot freelancer-share))
      ;; Determine loser for reputation (freelancer wins if > 50% of original)
      (loser (if (> freelancer-allocation (/ payment-amount u2))
        (get client project)
        freelancer
      ))
    )
    ;; Only assigned arbitrator can resolve
    (asserts! (is-eq tx-sender arbitrator) ERR-NOT-AUTHORIZED)
    ;; Dispute must be in review
    (asserts! (is-eq (get status dispute) DISPUTE-REVIEW) ERR-INVALID-STATUS)
    ;; Allocation must not exceed payment amount
    (asserts! (<= freelancer-allocation payment-amount) ERR-INVALID-AMOUNT)

    ;; Transfer freelancer share (if any)
    (if (> freelancer-share u0)
      (begin
        (try! (as-contract (stx-transfer? freelancer-share tx-sender freelancer)))
        true
      )
      true
    )

    ;; Transfer client share (if any)
    (if (> client-share u0)
      (begin
        (try! (as-contract (stx-transfer? client-share tx-sender (get client project))))
        true
      )
      true
    )

    ;; Collect dispute fee
    (if (> dispute-fee u0)
      (begin
        (try! (as-contract (stx-transfer? dispute-fee tx-sender (var-get platform-treasury))))
        true
      )
      true
    )

    ;; Update dispute
    (map-set disputes { dispute-id: dispute-id }
      (merge dispute {
        status: DISPUTE-RESOLVED,
        decision: (some decision),
        payment-allocation: (some freelancer-allocation),
        resolved-at: (some block-height),
      })
    )

    ;; Update milestone
    (map-set milestones { milestone-id: milestone-id }
      (merge milestone {
        status: MILESTONE-APPROVED,
        approved-at: (some block-height),
      })
    )

    ;; Update project
    (let (
        (new-escrow-balance (- (get escrow-balance project) payment-amount))
        (new-completed-milestones (+ (get completed-milestones project) u1))
        (all-milestones-completed (is-eq new-completed-milestones (get milestones-count project)))
        (new-status (if all-milestones-completed
          STATUS-COMPLETED
          STATUS-ACTIVE
        ))
      )
      (map-set projects { project-id: project-id }
        (merge project {
          escrow-balance: new-escrow-balance,
          completed-milestones: new-completed-milestones,
          status: new-status,
        })
      )
    )

    ;; Update loser's reputation
    (unwrap!
      (update-user-reputation loser {
        total-projects-delta: u0,
        completed-projects-delta: u0,
        earned-delta: u0,
        spent-delta: u0,
        disputes-raised-delta: u0,
        disputes-lost-delta: u1,
        on-time-delta: u0,
        late-delta: u0,
      })
      ERR-INVALID-AMOUNT
    )

    (ok true)
  )
)

;; Cancel project (only if no milestones completed)
(define-public (cancel-project (project-id uint))
  (let (
      (project (unwrap! (map-get? projects { project-id: project-id })
        ERR-PROJECT-NOT-FOUND
      ))
      (refund-amount (get escrow-balance project))
    )
    ;; Only client can cancel
    (asserts! (is-eq tx-sender (get client project)) ERR-NOT-AUTHORIZED)
    ;; No milestones should be completed
    (asserts! (is-eq (get completed-milestones project) u0) ERR-INVALID-STATUS)
    ;; Project must not be disputed
    (asserts! (not (is-eq (get status project) STATUS-DISPUTED))
      ERR-INVALID-STATUS
    )

    ;; Refund escrow to client
    (if (> refund-amount u0)
      (begin
        (try! (as-contract (stx-transfer? refund-amount tx-sender (get client project))))
        true
      )
      true
    )

    ;; Update project
    (map-set projects { project-id: project-id }
      (merge project {
        status: STATUS-CANCELLED,
        escrow-balance: u0,
      })
    )

    (ok true)
  )
)

;; Rate user after project completion
(define-public (rate-user
    (project-id uint)
    (rating uint)
    (review (string-utf8 512))
  )
  (let (
      (project (unwrap! (map-get? projects { project-id: project-id })
        ERR-PROJECT-NOT-FOUND
      ))
      (freelancer (unwrap! (get freelancer project) ERR-NOT-AUTHORIZED))
      (rated-user (if (is-eq tx-sender (get client project))
        freelancer
        (get client project)
      ))
      (existing-rating (map-get? project-ratings {
        project-id: project-id,
        rater: tx-sender,
      }))
    )
    ;; Project must be completed
    (asserts! (is-eq (get status project) STATUS-COMPLETED) ERR-INVALID-STATUS)
    ;; Only client or freelancer can rate
    (asserts!
      (or
        (is-eq tx-sender (get client project))
        (is-eq tx-sender freelancer)
      )
      ERR-NOT-AUTHORIZED
    )
    ;; Rating must be between 1 and 5 (stored as 100-500 for precision)
    (asserts! (and (>= rating u100) (<= rating u500)) ERR-INVALID-RATING)
    ;; Cannot rate twice
    (asserts! (is-none existing-rating) ERR-ALREADY-RATED)

    ;; Store rating
    (map-set project-ratings {
      project-id: project-id,
      rater: tx-sender,
    } {
      rating: rating,
      review: review,
      created-at: block-height,
    })

    ;; Update rated user's reputation
    (let (
        (user-rep (default-to {
          total-projects: u0,
          completed-projects: u0,
          total-earned: u0,
          total-spent: u0,
          average-rating: u0,
          total-ratings: u0,
          disputes-raised: u0,
          disputes-lost: u0,
          on-time-deliveries: u0,
          late-deliveries: u0,
          tier: "bronze",
        }
          (map-get? reputation { user: rated-user })
        ))
        (total-ratings (get total-ratings user-rep))
        (current-avg (get average-rating user-rep))
        (new-total-ratings (+ total-ratings u1))
        (new-avg (/ (+ (* current-avg total-ratings) rating) new-total-ratings))
        (new-tier (calculate-tier (get completed-projects user-rep) new-avg))
      )
      (map-set reputation { user: rated-user }
        (merge user-rep {
          average-rating: new-avg,
          total-ratings: new-total-ratings,
          tier: new-tier,
        })
      )
    )

    (ok true)
  )
)

;; Update platform treasury (only contract owner)
(define-public (set-platform-treasury (new-treasury principal))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (var-set platform-treasury new-treasury)
    (ok true)
  )
)

;; Read-Only Functions

;; Get project details
(define-read-only (get-project (project-id uint))
  (map-get? projects { project-id: project-id })
)

;; Get milestone details
(define-read-only (get-milestone (milestone-id uint))
  (map-get? milestones { milestone-id: milestone-id })
)

;; Get dispute details
(define-read-only (get-dispute (dispute-id uint))
  (map-get? disputes { dispute-id: dispute-id })
)

;; Get user reputation
(define-read-only (get-reputation (user principal))
  (map-get? reputation { user: user })
)

;; Get user tier
(define-read-only (get-user-tier (user principal))
  (let ((user-rep (default-to {
      total-projects: u0,
      completed-projects: u0,
      total-earned: u0,
      total-spent: u0,
      average-rating: u0,
      total-ratings: u0,
      disputes-raised: u0,
      disputes-lost: u0,
      on-time-deliveries: u0,
      late-deliveries: u0,
      tier: "bronze",
    }
      (map-get? reputation { user: user })
    )))
    (ok (get tier user-rep))
  )
)

;; Get project rating
(define-read-only (get-project-rating
    (project-id uint)
    (rater principal)
  )
  (map-get? project-ratings {
    project-id: project-id,
    rater: rater,
  })
)

;; Get user's project by index
(define-read-only (get-user-project
    (user principal)
    (index uint)
  )
  (map-get? user-projects {
    user: user,
    index: index,
  })
)

;; Get user's total project count
(define-read-only (get-user-project-count (user principal))
  (default-to { count: u0 } (map-get? user-project-count { user: user }))
)

;; Calculate platform fee for amount
(define-read-only (get-platform-fee
    (amount uint)
    (user principal)
    (is-client bool)
  )
  (ok (calculate-fee amount user is-client))
)

;; Get current nonces
(define-read-only (get-nonces)
  (ok {
    project-nonce: (var-get project-nonce),
    milestone-nonce: (var-get milestone-nonce),
    dispute-nonce: (var-get dispute-nonce),
  })
)

;; Get platform treasury
(define-read-only (get-platform-treasury)
  (ok (var-get platform-treasury))
)

;; Check if milestone can be auto-approved
(define-read-only (can-auto-approve (milestone-id uint))
  (match (map-get? milestones { milestone-id: milestone-id })
    milestone (match (get submitted-at milestone)
      submitted-at (ok (and
        (is-eq (get status milestone) MILESTONE-SUBMITTED)
        (>= (- block-height submitted-at) AUTO-APPROVE-TIMEOUT)
      ))
      (ok false)
    )
    (ok false)
  )
)
