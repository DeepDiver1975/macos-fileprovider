# Phase 7 (user-facing configuration) acceptance scenarios (progress.md Task 7.10).
# They join the Phase 5 lifecycle group per AC-5 and run under AC-3's
# ten-consecutive-green rule. Wording is kept behavioural so the same scenario
# reads against both backends where it applies.
#
# AC-1 tagging: space selection is an oCIS capability, so those scenarios carry
# @ocisOnly with the difference stated (never a silent skip). Sign-out and orphan
# detection apply to both backends and stay untagged. The runner and step library
# that drive these against live Docker fixtures are Mac + Docker gated (Task 6.3).
@configuration
Feature: Configure accounts and space selection

  Background:
    Given a signed-in account

  @ocisOnly
  Scenario: Select a space adds its domain and it enumerates
    Given the account has an unselected space "Project Falcon"
    When the space "Project Falcon" is selected
    Then a domain for "Project Falcon" exists
    And the domain for "Project Falcon" enumerates its files

  @ocisOnly
  Scenario: Deselect a space preserving downloads keeps files on disk
    Given the space "Project Falcon" is selected
    And the file "Project Falcon/report.pdf" has been downloaded
    When the space "Project Falcon" is deselected keeping downloaded files
    Then the domain for "Project Falcon" no longer exists
    And the file "report.pdf" remains on disk as a local copy

  @ocisOnly
  Scenario: Deselect a space with removeAll deletes the downloaded files
    Given the space "Project Falcon" is selected
    And the file "Project Falcon/report.pdf" has been downloaded
    When the space "Project Falcon" is deselected removing downloaded files
    Then the domain for "Project Falcon" no longer exists
    And the file "report.pdf" is gone from disk

  Scenario: Sign out with two spaces selected removes both domains and the credential
    Given the account has two selected spaces
    When the account signs out
    Then both domains are removed
    And the account's credential is deleted

  Scenario: Orphan detection after a registry wipe
    Given the account has a selected space
    And the account registry is wiped
    When the app reconciles the domain list
    Then the space's domain is reported as an orphan
    And the orphan domain is not removed without confirmation

  @ocisOnly
  Scenario: The refresh race keeps both spaces authenticated
    Given the account has two selected spaces sharing one refresh token
    And the access token is forced to expire
    When both domains refresh the token concurrently
    Then both spaces stay authenticated
    And only one token refresh reaches the server
