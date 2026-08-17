# Phase 3 enumeration scenarios, seeded from the desktop client's tst_syncing
# suite (progress.md appendix). Wording kept close to the client's so the files
# stay diff-comparable. Each scenario runs against BOTH backends unless tagged
# @classicOnly / @ocisOnly (AC-1).
@enumeration
Feature: Syncing all files and folders from the server

  Background:
    Given a signed-in domain

  Scenario: Items appear without being downloaded
    Given the server has a file "report.pdf"
    When the domain is enumerated
    Then the item "report.pdf" is listed
    And the item "report.pdf" is not materialised

  Scenario: Server-side additions are reflected
    Given the domain has been enumerated
    When a file "added.txt" is created on the server
    And the domain observes changes
    Then the item "added.txt" is listed

  Scenario: Server-side deletions are reflected
    Given the server has a file "doomed.txt"
    And the domain has been enumerated
    When the file "doomed.txt" is deleted on the server
    And the domain observes changes
    Then the item "doomed.txt" is not listed

  Scenario: A large folder enumerates completely across pages
    Given the server has a folder "Big" containing 500 files
    When the domain enumerates the folder "Big"
    Then 500 items are listed
