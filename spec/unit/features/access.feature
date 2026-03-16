Feature: Access phase dispatcher routing

  Rule: hybrid mode
    Scenario: hybrid mode routes known provider path through wrapper
      Given nginx mode is "hybrid" and uri is "/openai/v1/chat/completions"
      When the access dispatcher runs
      Then wrapper access_handler is called

    Scenario: hybrid mode routes non-provider path through decision_api
      Given nginx mode is "hybrid" and uri is "/api/internal/metrics"
      When the access dispatcher runs
      Then decision_api access_handler is called

  Rule: wrapper mode
    Scenario: wrapper mode routes all paths through wrapper
      Given nginx mode is "wrapper" and uri is "/openai/v1/chat/completions"
      When the access dispatcher runs
      Then wrapper access_handler is called

  Rule: reverse_proxy mode
    Scenario: reverse_proxy mode routes through decision_api
      Given nginx mode is "reverse_proxy" and uri is "/api/v1/data"
      When the access dispatcher runs
      Then decision_api access_handler is called

  Rule: decision_service mode
    Scenario: decision_service mode calls neither handler
      Given nginx mode is "decision_service" and uri is "/openai/v1/chat"
      When the access dispatcher runs
      Then neither handler is called
