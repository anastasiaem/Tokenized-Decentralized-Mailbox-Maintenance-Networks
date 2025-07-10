;; Community Notification Contract
;; Alerts neighbors about postal service disruptions

;; Constants
(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_UNAUTHORIZED (err u500))
(define-constant ERR_NOTIFICATION_NOT_FOUND (err u501))
(define-constant ERR_ALREADY_VOTED (err u502))
(define-constant ERR_VOTING_CLOSED (err u503))
(define-constant ERR_INSUFFICIENT_TOKENS (err u504))
(define-constant ERR_INVALID_PRIORITY (err u505))

;; Data Variables
(define-data-var next-notification-id uint u1)
(define-data-var next-proposal-id uint u1)
(define-data-var notification-reward uint u25)
(define-data-var voting-period uint u1008) ;; blocks (approximately 1 week)

;; Data Maps
(define-map notifications
  { notification-id: uint }
  {
    sender: principal,
    title: (string-ascii 100),
    message: (string-ascii 500),
    notification-type: (string-ascii 30),
    priority: uint,
    affected-area: (string-ascii 200),
    timestamp: uint,
    active: bool,
    acknowledgments: uint
  }
)

(define-map notification-tokens
  { holder: principal }
  { balance: uint }
)

(define-map notification-acknowledgments
  { notification-id: uint, user: principal }
  { timestamp: uint, feedback: (optional (string-ascii 200)) }
)

(define-map emergency-alerts
  { alert-id: uint }
  {
    issuer: principal,
    alert-type: (string-ascii 50),
    severity: uint,
    description: (string-ascii 600),
    affected-areas: (string-ascii 300),
    timestamp: uint,
    resolved: bool,
    resolution-notes: (optional (string-ascii 400))
  }
)

(define-map community-proposals
  { proposal-id: uint }
  {
    proposer: principal,
    title: (string-ascii 150),
    description: (string-ascii 800),
    proposal-type: (string-ascii 40),
    voting-deadline: uint,
    votes-for: uint,
    votes-against: uint,
    status: (string-ascii 20)
  }
)

(define-map proposal-votes
  { proposal-id: uint, voter: principal }
  { vote: bool, timestamp: uint, reasoning: (optional (string-ascii 300)) }
)

(define-map service-subscriptions
  { user: principal, notification-type: (string-ascii 30) }
  { subscribed: bool, preferences: (string-ascii 100) }
)

;; Data Variables for alerts
(define-data-var next-alert-id uint u1)

;; Token Functions
(define-private (mint-notification-tokens (recipient principal) (amount uint))
  (let ((current-balance (default-to u0 (get balance (map-get? notification-tokens { holder: recipient })))))
    (map-set notification-tokens
      { holder: recipient }
      { balance: (+ current-balance amount) }
    )
    (ok true)
  )
)

(define-private (burn-notification-tokens (holder principal) (amount uint))
  (let ((current-balance (default-to u0 (get balance (map-get? notification-tokens { holder: holder })))))
    (if (>= current-balance amount)
      (begin
        (map-set notification-tokens
          { holder: holder }
          { balance: (- current-balance amount) }
        )
        (ok true)
      )
      ERR_INSUFFICIENT_TOKENS
    )
  )
)

;; Public Functions
(define-public (send-notification (title (string-ascii 100)) (message (string-ascii 500)) (notification-type (string-ascii 30)) (priority uint) (affected-area (string-ascii 200)))
  (let ((notification-id (var-get next-notification-id)))
    (if (and (>= priority u1) (<= priority u5))
      (begin
        (map-set notifications
          { notification-id: notification-id }
          {
            sender: tx-sender,
            title: title,
            message: message,
            notification-type: notification-type,
            priority: priority,
            affected-area: affected-area,
            timestamp: block-height,
            active: true,
            acknowledgments: u0
          }
        )
        (var-set next-notification-id (+ notification-id u1))
        (unwrap! (mint-notification-tokens tx-sender (var-get notification-reward)) (err u999))
        (ok notification-id)
      )
      ERR_INVALID_PRIORITY
    )
  )
)

(define-public (acknowledge-notification (notification-id uint) (feedback (optional (string-ascii 200))))
  (let ((notification (unwrap! (map-get? notifications { notification-id: notification-id }) ERR_NOTIFICATION_NOT_FOUND)))
    (if (get active notification)
      (begin
        (map-set notification-acknowledgments
          { notification-id: notification-id, user: tx-sender }
          { timestamp: block-height, feedback: feedback }
        )
        (map-set notifications
          { notification-id: notification-id }
          (merge notification { acknowledgments: (+ (get acknowledgments notification) u1) })
        )
        (unwrap! (mint-notification-tokens tx-sender (/ (var-get notification-reward) u2)) (err u999))
        (ok true)
      )
      (err u506) ;; Notification not active
    )
  )
)

(define-public (issue-emergency-alert (alert-type (string-ascii 50)) (severity uint) (description (string-ascii 600)) (affected-areas (string-ascii 300)))
  (let ((alert-id (var-get next-alert-id)))
    (if (and (>= severity u1) (<= severity u5))
      (begin
        (map-set emergency-alerts
          { alert-id: alert-id }
          {
            issuer: tx-sender,
            alert-type: alert-type,
            severity: severity,
            description: description,
            affected-areas: affected-areas,
            timestamp: block-height,
            resolved: false,
            resolution-notes: none
          }
        )
        (var-set next-alert-id (+ alert-id u1))
        (unwrap! (mint-notification-tokens tx-sender (* (var-get notification-reward) severity)) (err u999))
        (ok alert-id)
      )
      (err u507) ;; Invalid severity
    )
  )
)

(define-public (resolve-emergency-alert (alert-id uint) (resolution-notes (string-ascii 400)))
  (let ((alert (unwrap! (map-get? emergency-alerts { alert-id: alert-id }) (err u508))))
    (if (get resolved alert)
      (err u509) ;; Already resolved
      (begin
        (map-set emergency-alerts
          { alert-id: alert-id }
          (merge alert {
            resolved: true,
            resolution-notes: (some resolution-notes)
          })
        )
        (unwrap! (mint-notification-tokens tx-sender (* (var-get notification-reward) u3)) (err u999))
        (ok true)
      )
    )
  )
)

(define-public (create-proposal (title (string-ascii 150)) (description (string-ascii 800)) (proposal-type (string-ascii 40)))
  (let ((proposal-id (var-get next-proposal-id)))
    (map-set community-proposals
      { proposal-id: proposal-id }
      {
        proposer: tx-sender,
        title: title,
        description: description,
        proposal-type: proposal-type,
        voting-deadline: (+ block-height (var-get voting-period)),
        votes-for: u0,
        votes-against: u0,
        status: "active"
      }
    )
    (var-set next-proposal-id (+ proposal-id u1))
    (unwrap! (mint-notification-tokens tx-sender (* (var-get notification-reward) u2)) (err u999))
    (ok proposal-id)
  )
)

(define-public (vote-on-proposal (proposal-id uint) (vote bool) (reasoning (optional (string-ascii 300))))
  (let ((proposal (unwrap! (map-get? community-proposals { proposal-id: proposal-id }) (err u510))))
    (if (> block-height (get voting-deadline proposal))
      ERR_VOTING_CLOSED
      (if (is-some (map-get? proposal-votes { proposal-id: proposal-id, voter: tx-sender }))
        ERR_ALREADY_VOTED
        (begin
          (map-set proposal-votes
            { proposal-id: proposal-id, voter: tx-sender }
            { vote: vote, timestamp: block-height, reasoning: reasoning }
          )
          (map-set community-proposals
            { proposal-id: proposal-id }
            (merge proposal {
              votes-for: (if vote (+ (get votes-for proposal) u1) (get votes-for proposal)),
              votes-against: (if vote (get votes-against proposal) (+ (get votes-against proposal) u1))
            })
          )
          (unwrap! (mint-notification-tokens tx-sender (var-get notification-reward)) (err u999))
          (ok true)
        )
      )
    )
  )
)

(define-public (subscribe-to-notifications (notification-type (string-ascii 30)) (preferences (string-ascii 100)))
  (begin
    (map-set service-subscriptions
      { user: tx-sender, notification-type: notification-type }
      { subscribed: true, preferences: preferences }
    )
    (unwrap! (mint-notification-tokens tx-sender (/ (var-get notification-reward) u4)) (err u999))
    (ok true)
  )
)

(define-public (transfer-notification-tokens (recipient principal) (amount uint))
  (let ((sender-balance (default-to u0 (get balance (map-get? notification-tokens { holder: tx-sender }))))
        (recipient-balance (default-to u0 (get balance (map-get? notification-tokens { holder: recipient })))))
    (if (>= sender-balance amount)
      (begin
        (map-set notification-tokens { holder: tx-sender } { balance: (- sender-balance amount) })
        (map-set notification-tokens { holder: recipient } { balance: (+ recipient-balance amount) })
        (ok true)
      )
      ERR_INSUFFICIENT_TOKENS
    )
  )
)

;; Read-only Functions
(define-read-only (get-notification-token-balance (holder principal))
  (default-to u0 (get balance (map-get? notification-tokens { holder: holder })))
)

(define-read-only (get-notification-details (notification-id uint))
  (map-get? notifications { notification-id: notification-id })
)

(define-read-only (get-notification-acknowledgment (notification-id uint) (user principal))
  (map-get? notification-acknowledgments { notification-id: notification-id, user: user })
)

(define-read-only (get-emergency-alert (alert-id uint))
  (map-get? emergency-alerts { alert-id: alert-id })
)

(define-read-only (get-proposal-details (proposal-id uint))
  (map-get? community-proposals { proposal-id: proposal-id })
)

(define-read-only (get-proposal-vote (proposal-id uint) (voter principal))
  (map-get? proposal-votes { proposal-id: proposal-id, voter: voter })
)

(define-read-only (get-subscription (user principal) (notification-type (string-ascii 30)))
  (map-get? service-subscriptions { user: user, notification-type: notification-type })
)

(define-read-only (get-next-notification-id)
  (var-get next-notification-id)
)

(define-read-only (get-next-proposal-id)
  (var-get next-proposal-id)
)

(define-read-only (get-next-alert-id)
  (var-get next-alert-id)
)
