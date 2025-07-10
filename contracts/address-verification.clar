;; Address Verification Contract
;; Ensures accurate postal routing information

;; Constants
(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_UNAUTHORIZED (err u300))
(define-constant ERR_ADDRESS_NOT_FOUND (err u301))
(define-constant ERR_ADDRESS_ALREADY_EXISTS (err u302))
(define-constant ERR_INSUFFICIENT_VERIFICATIONS (err u303))
(define-constant ERR_ALREADY_VERIFIED (err u304))
(define-constant ERR_INSUFFICIENT_TOKENS (err u305))

;; Data Variables
(define-data-var next-address-id uint u1)
(define-data-var verification-reward uint u75)
(define-data-var required-verifications uint u3)

;; Data Maps
(define-map addresses
  { address-id: uint }
  {
    owner: principal,
    street-address: (string-ascii 200),
    city: (string-ascii 50),
    state: (string-ascii 30),
    zip-code: (string-ascii 10),
    country: (string-ascii 30),
    address-type: (string-ascii 20),
    verified: bool,
    verification-count: uint,
    timestamp-created: uint,
    timestamp-verified: (optional uint)
  }
)

(define-map address-tokens
  { holder: principal }
  { balance: uint }
)

(define-map address-verifications
  { address-id: uint, verifier: principal }
  {
    verification-timestamp: uint,
    verification-method: (string-ascii 50),
    notes: (optional (string-ascii 300))
  }
)

(define-map address-changes
  { change-id: uint }
  {
    address-id: uint,
    requester: principal,
    old-address: (string-ascii 200),
    new-address: (string-ascii 200),
    reason: (string-ascii 200),
    approved: bool,
    timestamp: uint
  }
)

(define-map user-addresses
  { user: principal, address-id: uint }
  { is-primary: bool }
)

;; Data Variables for address changes
(define-data-var next-change-id uint u1)

;; Token Functions
(define-private (mint-address-tokens (recipient principal) (amount uint))
  (let ((current-balance (default-to u0 (get balance (map-get? address-tokens { holder: recipient })))))
    (map-set address-tokens
      { holder: recipient }
      { balance: (+ current-balance amount) }
    )
    (ok true)
  )
)

(define-private (burn-address-tokens (holder principal) (amount uint))
  (let ((current-balance (default-to u0 (get balance (map-get? address-tokens { holder: holder })))))
    (if (>= current-balance amount)
      (begin
        (map-set address-tokens
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
(define-public (register-address (street-address (string-ascii 200)) (city (string-ascii 50)) (state (string-ascii 30)) (zip-code (string-ascii 10)) (country (string-ascii 30)) (address-type (string-ascii 20)))
  (let ((address-id (var-get next-address-id)))
    (map-set addresses
      { address-id: address-id }
      {
        owner: tx-sender,
        street-address: street-address,
        city: city,
        state: state,
        zip-code: zip-code,
        country: country,
        address-type: address-type,
        verified: false,
        verification-count: u0,
        timestamp-created: block-height,
        timestamp-verified: none
      }
    )
    (map-set user-addresses
      { user: tx-sender, address-id: address-id }
      { is-primary: true }
    )
    (var-set next-address-id (+ address-id u1))
    (unwrap! (mint-address-tokens tx-sender (var-get verification-reward)) (err u999))
    (ok address-id)
  )
)

(define-public (verify-address (address-id uint) (verification-method (string-ascii 50)) (notes (optional (string-ascii 300))))
  (let ((address (unwrap! (map-get? addresses { address-id: address-id }) ERR_ADDRESS_NOT_FOUND)))
    (if (is-some (map-get? address-verifications { address-id: address-id, verifier: tx-sender }))
      ERR_ALREADY_VERIFIED
      (begin
        (map-set address-verifications
          { address-id: address-id, verifier: tx-sender }
          {
            verification-timestamp: block-height,
            verification-method: verification-method,
            notes: notes
          }
        )
        (let ((new-count (+ (get verification-count address) u1)))
          (map-set addresses
            { address-id: address-id }
            (merge address {
              verification-count: new-count,
              verified: (>= new-count (var-get required-verifications)),
              timestamp-verified: (if (>= new-count (var-get required-verifications)) (some block-height) none)
            })
          )
        )
        (unwrap! (mint-address-tokens tx-sender (var-get verification-reward)) (err u999))
        (unwrap! (mint-address-tokens (get owner address) (/ (var-get verification-reward) u2)) (err u999))
        (ok true)
      )
    )
  )
)

(define-public (request-address-change (address-id uint) (new-address (string-ascii 200)) (reason (string-ascii 200)))
  (let ((address (unwrap! (map-get? addresses { address-id: address-id }) ERR_ADDRESS_NOT_FOUND))
        (change-id (var-get next-change-id)))
    (if (is-eq (get owner address) tx-sender)
      (begin
        (map-set address-changes
          { change-id: change-id }
          {
            address-id: address-id,
            requester: tx-sender,
            old-address: (get street-address address),
            new-address: new-address,
            reason: reason,
            approved: false,
            timestamp: block-height
          }
        )
        (var-set next-change-id (+ change-id u1))
        (ok change-id)
      )
      ERR_UNAUTHORIZED
    )
  )
)

(define-public (approve-address-change (change-id uint))
  (let ((change (unwrap! (map-get? address-changes { change-id: change-id }) (err u306))))
    (if (get approved change)
      (err u307) ;; Already approved
      (begin
        (map-set address-changes
          { change-id: change-id }
          (merge change { approved: true })
        )
        (let ((address (unwrap! (map-get? addresses { address-id: (get address-id change) }) ERR_ADDRESS_NOT_FOUND)))
          (map-set addresses
            { address-id: (get address-id change) }
            (merge address {
              street-address: (get new-address change),
              verified: false,
              verification-count: u0,
              timestamp-verified: none
            })
          )
        )
        (unwrap! (mint-address-tokens tx-sender (* (var-get verification-reward) u2)) (err u999))
        (ok true)
      )
    )
  )
)

(define-public (transfer-address-tokens (recipient principal) (amount uint))
  (let ((sender-balance (default-to u0 (get balance (map-get? address-tokens { holder: tx-sender }))))
        (recipient-balance (default-to u0 (get balance (map-get? address-tokens { holder: recipient })))))
    (if (>= sender-balance amount)
      (begin
        (map-set address-tokens { holder: tx-sender } { balance: (- sender-balance amount) })
        (map-set address-tokens { holder: recipient } { balance: (+ recipient-balance amount) })
        (ok true)
      )
      ERR_INSUFFICIENT_TOKENS
    )
  )
)

;; Read-only Functions
(define-read-only (get-address-token-balance (holder principal))
  (default-to u0 (get balance (map-get? address-tokens { holder: holder })))
)

(define-read-only (get-address-details (address-id uint))
  (map-get? addresses { address-id: address-id })
)

(define-read-only (get-address-verification (address-id uint) (verifier principal))
  (map-get? address-verifications { address-id: address-id, verifier: verifier })
)

(define-read-only (get-address-change (change-id uint))
  (map-get? address-changes { change-id: change-id })
)

(define-read-only (get-user-address (user principal) (address-id uint))
  (map-get? user-addresses { user: user, address-id: address-id })
)

(define-read-only (get-next-address-id)
  (var-get next-address-id)
)

(define-read-only (get-next-change-id)
  (var-get next-change-id)
)
