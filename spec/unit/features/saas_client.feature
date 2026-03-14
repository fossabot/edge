Feature: SaaS protocol client unit behavior
  Rule: Initialization and recurring communication
    Scenario: Initialization registers timers and performs registration
      Given the nginx mock environment with timer capture is reset
      And a default SaaS client config
      And default bundle_loader and health dependencies
      And registration succeeds
      When the client is initialized
      Then initialization succeeds
      And two recurring timers are registered at heartbeat 5 and event flush 60
      And the register endpoint is called once with bearer auth

    Scenario: BUG-5 init fails when registration fails and client stays uninitialized
      Given the nginx mock environment with timer capture is reset
      And a default SaaS client config
      And default bundle_loader and health dependencies
      And registration fails with transport error
      When the client is initialized
      Then initialization fails
      And queue_event returns not initialized error

    Scenario: Heartbeat config hint triggers conditional pull and ack
      Given the nginx mock environment with timer capture is reset
      And a default SaaS client config
      And bundle_loader starts with hash "base-hash" and version "v1"
      And default bundle_loader and health dependencies
      And registration succeeds
      And heartbeat succeeds with config update available
      And config pull returns 200 with bundle hash "hash-new" and version "v2"
      And the client is initialized
      When the heartbeat timer callback runs
      Then a conditional config pull includes If-None-Match with current hash
      And the bundle is applied and acked as applied

    Scenario: Manual pull returns early on not modified
      Given the nginx mock environment with timer capture is reset
      And a default SaaS client config
      And default bundle_loader and health dependencies
      And registration succeeds
      And config pull returns 304
      And the client is initialized
      When I trigger pull_config manually
      Then manual pull succeeds with no bundle load

  Rule: Circuit breaker and retries
    Scenario: Circuit opens after five failures and closes after half-open probe successes
      Given the nginx mock environment with timer capture is reset
      And a default SaaS client config
      And default bundle_loader and health dependencies
      And registration succeeds
      And config poll interval is 999999 seconds
      And heartbeat returns retriable failure 5 times
      And heartbeat succeeds 2 times
      And the client is initialized
      When the heartbeat timer callback runs 5 times
      Then the circuit state becomes disconnected
      And reachable metric is set to 0
      Given time advances by 30 seconds
      When the heartbeat timer callback runs
      Then the circuit state becomes half_open
      When the heartbeat timer callback runs
      Then the circuit state becomes connected
      And reachable metric is set to 1

    Scenario: Exponential backoff suppresses immediate retry after failure
      Given the nginx mock environment with timer capture is reset
      And a default SaaS client config
      And default bundle_loader and health dependencies
      And registration succeeds
      And heartbeat returns retriable failure 1 times
      And heartbeat succeeds 1 times
      And the client is initialized
      When the heartbeat timer callback runs
      Then backoff suppresses immediate retry and allows retry after 2.1 seconds

    Scenario: Non-retriable heartbeat status does not disconnect edge
      Given the nginx mock environment with timer capture is reset
      And a default SaaS client config
      And default bundle_loader and health dependencies
      And registration succeeds
      And heartbeat responds with non-retriable status 401
      And the client is initialized
      When the heartbeat timer callback runs
      Then the circuit state becomes connected

  Rule: Event buffering and delivery
    Scenario: Events are batched with idempotency key and success metric
      Given the nginx mock environment with timer capture is reset
      And a default SaaS client config
      And default bundle_loader and health dependencies
      And registration succeeds
      And events endpoint accepts one batch
      And the client is initialized
      And I queue events with ids: 1, 2
      When the event flush timer callback runs
      Then the event batch uses an Idempotency-Key header
      And events_sent_total has one success increment

    Scenario: Event failures keep buffered events and count error
      Given the nginx mock environment with timer capture is reset
      And a default SaaS client config
      And default bundle_loader and health dependencies
      And registration succeeds
      And events endpoint fails with status 500
      And the client is initialized
      And I queue events with ids: 10, 11
      When the event flush timer callback runs
      Then events_sent_total has one error increment

    Scenario: Buffer overflow drops oldest events first
      Given the nginx mock environment with timer capture is reset
      And a default SaaS client config
      And default bundle_loader and health dependencies
      And registration succeeds
      And events endpoint accepts one batch
      And events endpoint accepts one batch
      And the client is initialized
      And I queue events with ids: 1, 2, 3, 4
      When I force flush events
      Then buffer overflow keeps only newest events and flushes 3 events total

    Scenario: Clock skew detection is attached to events payloads
      Given the nginx mock environment with timer capture is reset
      And a default SaaS client config
      And default bundle_loader and health dependencies
      And registration succeeds
      And heartbeat succeeds with no update and server time skew of 20 seconds
      And events endpoint accepts one batch
      And the client is initialized
      And I queue events with ids: 55
      When the heartbeat timer callback runs
      And the event flush timer callback runs
      Then the events payload flags clock skew

  Rule: Uninitialized client guards
    Scenario: flush_events returns 0 when client is not initialized
      Given the nginx mock environment with timer capture is reset
      And a default SaaS client config
      And default bundle_loader and health dependencies
      When I call flush_events on a fresh client
      Then flush events returns 0

    Scenario: pull_config returns error when client is not initialized
      Given the nginx mock environment with timer capture is reset
      And a default SaaS client config
      And default bundle_loader and health dependencies
      When I call pull_config on a fresh client
      Then pull_config returns not initialized error

  Rule: Auth token security
    Scenario: edge token with newline character uses empty bearer in requests
      Given the nginx mock environment with timer capture is reset
      And a default SaaS client config with token containing newline
      And default bundle_loader and health dependencies
      And registration succeeds
      When the client is initialized
      Then initialization succeeds
      And the register endpoint used empty bearer auth

  Rule: Event coalescing
    Scenario: two coalesceable events with same signature produce one buffered then one summary on flush
      Given the nginx mock environment with timer capture is reset
      And a default SaaS client config
      And default bundle_loader and health dependencies
      And registration succeeds
      And events endpoint accepts one batch
      And the client is initialized
      When I queue a coalesceable event with route "/api/v1/test"
      And I queue the same coalesceable event again
      And I force flush events
      Then the flushed batch includes the original and coalesced summary event

  Rule: Subject ID hashing
    Scenario: queue_event with subject_id hashes the ID and removes raw field
      Given the nginx mock environment with timer capture is reset
      And a default SaaS client config
      And default bundle_loader and health dependencies
      And registration succeeds
      And events endpoint accepts one batch
      And the client is initialized
      When I queue an event with subject_id "user-secret-123"
      And I force flush events
      Then the flushed event has subject_id_hash and no raw subject_id

  Rule: Non-retriable event flush status
    Scenario: non-retriable status 401 on event flush counts as error
      Given the nginx mock environment with timer capture is reset
      And a default SaaS client config
      And default bundle_loader and health dependencies
      And registration succeeds
      And events endpoint fails with status 401
      And the client is initialized
      And I queue events with ids: 1
      When I force flush events
      Then events_sent_total has one error increment

  Rule: Bundle load rejection ack
    Scenario: config pull with bundle load rejection acks as rejected
      Given the nginx mock environment with timer capture is reset
      And a default SaaS client config
      And default bundle_loader and health dependencies
      And registration succeeds
      And config poll interval is 999999 seconds
      And heartbeat succeeds with config update available
      And config pull returns 200 with rejecting bundle
      And the ack endpoint accepts the rejection
      And the client is initialized
      When the heartbeat timer callback runs
      Then the bundle is acked as rejected

  Rule: Half-open circuit failure reopens circuit
    Scenario: failure during half_open state transitions circuit back to disconnected
      Given the nginx mock environment with timer capture is reset
      And a default SaaS client config
      And default bundle_loader and health dependencies
      And registration succeeds
      And config poll interval is 999999 seconds
      And heartbeat returns retriable failure 5 times
      And heartbeat returns retriable failure 1 times
      And the client is initialized
      When the heartbeat timer callback runs 5 times
      Then the circuit state becomes disconnected
      Given time advances by 30 seconds
      When the heartbeat timer callback runs
      Then the circuit state becomes disconnected

  Rule: Heartbeat string body extract_payload
    Scenario: heartbeat response with JSON string body is correctly parsed
      Given the nginx mock environment with timer capture is reset
      And a default SaaS client config
      And default bundle_loader and health dependencies
      And registration succeeds
      And config poll interval is 999999 seconds
      And heartbeat succeeds with JSON string body
      And the client is initialized
      When the heartbeat timer callback runs
      Then the circuit state becomes connected

  Rule: Timer premature callback
    Scenario: heartbeat timer with premature true returns without making HTTP request
      Given the nginx mock environment with timer capture is reset
      And a default SaaS client config
      And default bundle_loader and health dependencies
      And registration succeeds
      And the client is initialized
      When the heartbeat timer callback runs with premature true
      Then no heartbeat request was made

  Rule: Transport error paths
    Scenario: event flush transport error counts as error metric
      Given the nginx mock environment with timer capture is reset
      And a default SaaS client config
      And default bundle_loader and health dependencies
      And registration succeeds
      And events endpoint fails with transport error
      And the client is initialized
      And I queue events with ids: 1
      When the event flush timer callback runs
      Then events_sent_total has one error increment

    Scenario: heartbeat transport errors open circuit after threshold
      Given the nginx mock environment with timer capture is reset
      And a default SaaS client config
      And default bundle_loader and health dependencies
      And registration succeeds
      And config poll interval is 999999 seconds
      And heartbeat fails with transport error 5 times
      And the client is initialized
      When the heartbeat timer callback runs 5 times
      Then the circuit state becomes disconnected

    Scenario: config pull transport error does not apply bundle
      Given the nginx mock environment with timer capture is reset
      And a default SaaS client config
      And default bundle_loader and health dependencies
      And registration succeeds
      And config poll interval is 999999 seconds
      And heartbeat succeeds with config update available
      And config pull fails with transport error
      And the client is initialized
      When the heartbeat timer callback runs
      Then no bundle was applied

    Scenario: config ack transport error does not prevent bundle from being applied
      Given the nginx mock environment with timer capture is reset
      And a default SaaS client config
      And bundle_loader starts with hash "base-hash" and version "v1"
      And default bundle_loader and health dependencies
      And registration succeeds
      And config poll interval is 999999 seconds
      And heartbeat succeeds with config update available
      And config pull returns 200 with bundle hash "hash-new" and version "v2"
      And config ack fails with transport error
      And the client is initialized
      When the heartbeat timer callback runs
      Then the bundle was applied 1 times

  Rule: Register error statuses
    Scenario: register non-retriable 401 status fails initialization
      Given the nginx mock environment with timer capture is reset
      And a default SaaS client config
      And default bundle_loader and health dependencies
      And registration fails with http status 401
      When the client is initialized
      Then initialization fails
      And queue_event returns not initialized error

    Scenario: register retriable 503 status fails initialization
      Given the nginx mock environment with timer capture is reset
      And a default SaaS client config
      And default bundle_loader and health dependencies
      And registration fails with http status 503
      When the client is initialized
      Then initialization fails

  Rule: Event flush retry and circuit guard
    Scenario: event flush backoff suppresses immediate retry after 500 failure
      Given the nginx mock environment with timer capture is reset
      And a default SaaS client config
      And default bundle_loader and health dependencies
      And registration succeeds
      And events endpoint fails with status 500
      And events endpoint accepts one batch
      And the client is initialized
      And I queue events with ids: 1
      When I force flush events
      Then the events endpoint was called 1 times
      Given time advances by 3 seconds
      When I force flush events
      Then the events endpoint was called 2 times

    Scenario: flush returns 0 when circuit is open before half-open window
      Given the nginx mock environment with timer capture is reset
      And a default SaaS client config
      And default bundle_loader and health dependencies
      And registration succeeds
      And config poll interval is 999999 seconds
      And heartbeat fails with transport error 5 times
      And the client is initialized
      And I queue events with ids: 1
      When the heartbeat timer callback runs 5 times
      Then the circuit state becomes disconnected
      When I force flush events
      Then force flush returns 0 events

  Rule: Config pull non-retriable status
    Scenario: config pull non-retriable 403 does not apply bundle
      Given the nginx mock environment with timer capture is reset
      And a default SaaS client config
      And default bundle_loader and health dependencies
      And registration succeeds
      And config poll interval is 999999 seconds
      And heartbeat succeeds with config update available
      And config pull returns non-retriable status 403
      And the client is initialized
      When the heartbeat timer callback runs
      Then no bundle was applied

  Rule: queue_event input validation
    Scenario: queue_event with non-table argument returns validation error
      Given the nginx mock environment with timer capture is reset
      And a default SaaS client config
      And default bundle_loader and health dependencies
      And registration succeeds
      And the client is initialized
      Then queue_event with non-table argument returns error

  Rule: Heartbeat periodic config poll
    Scenario: heartbeat triggers periodic config pull when poll interval has elapsed
      Given the nginx mock environment with timer capture is reset
      And a default SaaS client config
      And default bundle_loader and health dependencies
      And registration succeeds
      And config poll interval is 1 seconds
      And the client is initialized
      Given time advances by 2 seconds
      And heartbeat succeeds with no update and server time skew of 0 seconds
      And config pull returns 304
      When the heartbeat timer callback runs
      Then the config pull endpoint was called
