Feature: autonaming
  In order for users to have a more intuitive interface
  they should be able to skip naming cards in some cases
  
  Background:
    Given I log in as Joe User
    And I create Phrase card "Book+*type+*autoname" with content "Book 1"
  
  Scenario: Simple cardtype autoname       
    When I go to new Book
    Then I should see "Book 1"
    When I press "Submit"
    And I go to new Book
    Then I should see "Book 2"
    