# ==============================================================================
# Tytul:        T04_instance_abort.ps1
# Opis:         Definicja testu T4 (Instance abort) dla tests/run_test.ps1; opis w TESTS.md / TESTS_PL.md.
# Description [EN]: Definition of test T4 (Instance abort) for tests/run_test.ps1; see TESTS.md.
#
# Autor:        KCB Kris
# Data:         2026-11-16
# Wersja:       1.1 (Expected: oczekiwanie A4 / A4 expectation)
# Konwencje:    <repo>/SETTINGS.md
#
# Wymagania [PL]:    - czyta ja tests/run_test.ps1
# Requirements [EN]: - read by tests/run_test.ps1
#
# Uzycie [PL]:       .\tests\run_test.ps1 -Test T4
# Usage [EN]:        .\tests\run_test.ps1 -Test T4
# ==============================================================================
@{
    Id          = 'T4'
    Title       = 'Instance abort'
    Kind        = 'abort'          # relocate, poweroff, abort, kill-sm, kill-ext, link-down, none
    Target      = 'ggcdb1'
    Destructive = $false      # TESTS.md: may leave the lab broken
    Back        = $true      # needs a measured <test>-back run to the base state
    PreSec      = 60             # load before the fault
    PostSec     = 120            # observation after t_lag_ok
    TimeoutSec  = 900            # give up waiting for recovery
    Notes       = 'Same segment list as T2.'
    # A4 (video): written to expected.json and summary.json before the fault; 'nie wiemy' = no guess
    Expected    = @{
        Hypothesis = 'GoldenGate follows the service to ggrac2 although node 1 and its ACFS stay up (risk: XAG stays on ggrac1 without a database)'
        Source     = 'MAA 26ai (--use_local_services, Task 3 and 7), lab verification report'
        FinalNode  = 'ggrac2'      # GoldenGate node at the end
        Recovers   = $true       # recovers without a human
        RtoS       = 'nie wiemy'      # number = upper bound in seconds
        DataLoss   = 0         # rows lost
    }
}
