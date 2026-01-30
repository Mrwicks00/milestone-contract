;; Test Token (TEST)
;; A SIP-010 fungible token for testing the MilestoneXYZ contract on mainnet
;; This token has no real value and is only for testing purposes

(impl-trait .sip-010-trait.sip-010-trait)

;; Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-NOT-AUTHORIZED (err u401))
(define-constant ERR-INSUFFICIENT-BALANCE (err u402))
(define-constant ERR-INVALID-AMOUNT (err u403))

;; Token configuration
(define-fungible-token test-token)
(define-constant TOKEN-NAME "Test Token")
(define-constant TOKEN-SYMBOL "TEST")
(define-constant TOKEN-DECIMALS u6)
(define-constant INITIAL-SUPPLY u1000000000000) ;; 1,000,000 tokens with 6 decimals

;; Data variables
(define-data-var token-uri (optional (string-utf8 256)) none)

;; Initialize contract with initial supply to deployer
(begin
  (ft-mint? test-token INITIAL-SUPPLY CONTRACT-OWNER)
)

;; SIP-010 Functions

;; Transfer tokens
(define-public (transfer (amount uint) (sender principal) (recipient principal) (memo (optional (buff 34))))
  (begin
    (asserts! (is-eq tx-sender sender) ERR-NOT-AUTHORIZED)
    (asserts! (> amount u0) ERR-INVALID-AMOUNT)
    (try! (ft-transfer? test-token amount sender recipient))
    (match memo to-print (print to-print) 0x)
    (ok true)
  )
)

;; Get token name
(define-read-only (get-name)
  (ok TOKEN-NAME)
)

;; Get token symbol
(define-read-only (get-symbol)
  (ok TOKEN-SYMBOL)
)

;; Get token decimals
(define-read-only (get-decimals)
  (ok TOKEN-DECIMALS)
)

;; Get balance of a principal
(define-read-only (get-balance (account principal))
  (ok (ft-get-balance test-token account))
)

;; Get total supply
(define-read-only (get-total-supply)
  (ok (ft-get-supply test-token))
)

;; Get token URI
(define-read-only (get-token-uri)
  (ok (var-get token-uri))
)

;; Additional Functions for Testing

;; Mint tokens (only contract owner)
(define-public (mint (amount uint) (recipient principal))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (asserts! (> amount u0) ERR-INVALID-AMOUNT)
    (ft-mint? test-token amount recipient)
  )
)

;; Burn tokens
(define-public (burn (amount uint))
  (begin
    (asserts! (> amount u0) ERR-INVALID-AMOUNT)
    (ft-burn? test-token amount tx-sender)
  )
)

;; Set token URI (only contract owner)
(define-public (set-token-uri (new-uri (optional (string-utf8 256))))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (var-set token-uri new-uri)
    (ok true)
  )
)

;; Airdrop tokens to multiple recipients (for testing)
(define-public (airdrop (recipients (list 100 {recipient: principal, amount: uint})))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (ok (map airdrop-to-recipient recipients))
  )
)

(define-private (airdrop-to-recipient (entry {recipient: principal, amount: uint}))
  (unwrap-panic (ft-mint? test-token (get amount entry) (get recipient entry)))
)
